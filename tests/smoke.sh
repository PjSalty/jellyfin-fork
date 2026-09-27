#!/usr/bin/env bash
#
# Script: smoke.sh
# Description: Two-replica smoke test. A migrate Job seeds the schema once,
#              then a leader and a replica boot with migrations gated off.
#              Asserts: both healthy, wizard on the leader, a token minted on
#              the leader authenticates on the replica (read-through), browse
#              works on both, the replica armed no scheduled tasks, and the
#              rffmpeg shims dispatch to a worker then fall back locally.
# Usage: ./tests/smoke.sh   (expects ../upstream to be assembled, see build/assemble.sh)
#

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TESTS_DIR
# JELLYFIN_HOST: localhost for a native docker daemon; the dind service alias in CI.
HOST="${JELLYFIN_HOST:-localhost}"
readonly LEADER_URL="http://${HOST}:8096"
readonly REPLICA_URL="http://${HOST}:8097"
readonly COMPOSE="docker compose -f ${TESTS_DIR}/docker-compose.yml"

info() { echo "[smoke] $*"; }
die()  { echo "[smoke] FAIL: $*" >&2; exit 1; }

cleanup() {
    rc=$?
    if [ "${rc}" -ne 0 ]; then
        for svc in migrate jellyfin-leader jellyfin-replica transcode-worker; do
            echo "[smoke] ${svc} logs (last 120 lines, health spam filtered):" >&2
            ${COMPOSE} logs "${svc}" 2>/dev/null | grep -viE 'healthcheckservice|health check' | tail -120 >&2 || true
        done
    fi
    ${COMPOSE} down -v >/dev/null 2>&1 || true
    exit "${rc}"
}
trap cleanup EXIT

wait_healthy() {
    url="$1"
    for _ in $(seq 1 240); do
        if [ "$(curl -s "${url}/health")" = "Healthy" ]; then
            return 0
        fi
        sleep 2
    done
    return 1
}

info "generating dispatch ssh keys"
# Generated inside a container: the GitLab dind runner image has no
# ssh-keygen, and docker is a given for this test anyway.
docker run --rm -v "${TESTS_DIR}/.sshkeys:/keys" alpine:3.22 sh -c '
    apk add --no-cache openssh-keygen >/dev/null
    [ -f /keys/id_ed25519 ] || ssh-keygen -q -t ed25519 -N "" -f /keys/id_ed25519
    [ -f /keys/ssh_host_ed25519_key ] || ssh-keygen -q -t ed25519 -N "" -f /keys/ssh_host_ed25519_key
    printf "[transcode-worker]:2222 %s\n" "$(cut -d" " -f1-2 /keys/ssh_host_ed25519_key.pub)" > /keys/known_hosts
    chmod 644 /keys/known_hosts /keys/*.pub
' || die "ssh key generation failed"

info "starting stack (builds the patched server image, runs the migrate pass)"
${COMPOSE} up -d --build
wait_healthy "${LEADER_URL}" || die "leader never became healthy"
wait_healthy "${REPLICA_URL}" || die "replica never became healthy"

info "asserting the skip-gate engaged on both serving pods"
# Exact phrase from patch 0002; plain grep drains the stream (grep -q closes
# the pipe early and pipefail then fails on compose logs' SIGPIPE).
${COMPOSE} logs jellyfin-leader | grep "migration machinery will not run" > /dev/null || die "leader skip-gate log line missing"
${COMPOSE} logs jellyfin-replica | grep "migration machinery will not run" > /dev/null || die "replica skip-gate log line missing"

info "completing the startup wizard on the leader"
wizard() {
    step="$1"; shift
    if ! curl -sf "$@" > /dev/null; then
        die "wizard step failed: ${step}"
    fi
}
wizard configuration -X POST "${LEADER_URL}/Startup/Configuration" -H 'Content-Type: application/json' \
    -d '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}'
wizard first-user-get "${LEADER_URL}/Startup/User"
wizard first-user-set -X POST "${LEADER_URL}/Startup/User" -H 'Content-Type: application/json' \
    -d '{"Name":"smoke","Password":"smoketest"}'
wizard complete -X POST "${LEADER_URL}/Startup/Complete"

info "authenticating on the leader"
auth_header='X-Emby-Authorization: MediaBrowser Client="smoke", Device="ci", DeviceId="ci", Version="1"'
token="$(curl -sf -X POST "${LEADER_URL}/Users/AuthenticateByName" \
    -H 'Content-Type: application/json' -H "${auth_header}" \
    -d '{"Username":"smoke","Pw":"smoketest"}' | jq -r '.AccessToken')"
if [ -z "${token}" ] || [ "${token}" = "null" ]; then
    die "authentication failed on the leader"
fi
user_id="$(curl -sf "${LEADER_URL}/Users/Me" -H "X-Emby-Token: ${token}" | jq -r '.Id')"

info "asserting the LEADER-minted token works on the REPLICA (read-through)"
code="$(curl -s -o /dev/null -w '%{http_code}' "${REPLICA_URL}/Users/Me" -H "X-Emby-Token: ${token}")"
[ "${code}" = "200" ] || die "replica rejected a leader-minted token (http ${code}): read-through broken"

info "browsing on both pods"
curl -sf "${LEADER_URL}/Users/${user_id}/Items?Recursive=true" -H "X-Emby-Token: ${token}" > /dev/null || die "browse failed on leader"
curl -sf "${REPLICA_URL}/Users/${user_id}/Items?Recursive=true" -H "X-Emby-Token: ${token}" > /dev/null || die "browse failed on replica"

info "asserting the Limit=0 count-only path returns a well-formed empty page (patch 0008)"
# This suite deliberately runs with NO media library, so an item-count assertion here
# would be vacuous (0 == 0). What IS worth asserting without media is the shape of the
# early return: patch 0008 skips the item query entirely when Limit=0 (the call
# Folder.FillUserDataDtoValues makes per folder), so that path must still answer 200
# with an Items array and a non-null TotalRecordCount rather than null or a 500.
browse="Recursive=true&SortBy=SortName"
zero="$(curl -sf "${LEADER_URL}/Users/${user_id}/Items?${browse}&Limit=0&StartIndex=0" \
    -H "X-Emby-Token: ${token}")" || die "Limit=0 browse failed outright"
[ "$(echo "${zero}" | jq -r '.Items | length')" = "0" ] || die "Limit=0 returned items"
zero_count="$(echo "${zero}" | jq -r '.TotalRecordCount')"
if [ -z "${zero_count}" ] || [ "${zero_count}" = "null" ]; then
    die "Limit=0 returned no TotalRecordCount: the early return skipped the count too"
fi

info "asserting the Latest row answers an empty cutoff with an empty array (patch 0010)"
# GetLatestItemList now reads the top-N DateCreated cutoff as its own statement and
# returns early when no group matched. With no media that early return is the ONLY
# branch this suite can reach, so assert its shape: 200 with a JSON array, not a 500
# or null. The same-items-before-and-after check needs a library; the live-DB run
# that measured the change compared ids on a populated one.
latest="$(curl -sf "${LEADER_URL}/Users/${user_id}/Items/Latest?Limit=16" \
    -H "X-Emby-Token: ${token}")" || die "Items/Latest failed outright"
[ "$(echo "${latest}" | jq -r 'type')" = "array" ] || die "Items/Latest did not return an array"

info "asserting a Season listing with user data still answers (patch 0011)"
# Season.GetItemsInternal takes a repository count for the Limit=0 shape that
# Folder.FillUserDataDtoValues issues per Season DTO. Without media no Season exists,
# so this only proves the listing path that would build those DTOs still answers 200
# with an Items array; a populated library is needed to compare UnplayedItemCount
# against the in-memory path (the live-DB run checked membership across 710 seasons).
seasons="$(curl -sf "${LEADER_URL}/Users/${user_id}/Items?Recursive=true&IncludeItemTypes=Season&Limit=2000" \
    -H "X-Emby-Token: ${token}")" || die "Season listing failed outright"
[ "$(echo "${seasons}" | jq -r '.Items | type')" = "array" ] || die "Season listing returned no Items array"

info "asserting a user update DELETES old permissions instead of orphaning them (patch 0006)"
# Regression guard. Permission.UserId / Preference.UserId are Guid? (optional), so
# UpdateUserAsync's dbUser.Permissions.Clear() makes EF SEVER the relationship
# (UPDATE ... SET "UserId" = NULL) rather than delete the rows. Unpatched, every call
# strands the user's whole permission set as unreachable NULL-UserId rows: invisible to
# the app (queries filter on UserId; NULL matches nothing) and to UNIQUE(UserId, Kind)
# (a btree treats NULLs as distinct). Prod reached 29,637 orphans against 407 live rows.
#
# ForgotPassword is the one in-tree caller of UpdateUserAsync reachable over the API, so
# it is the trigger. Unpatched, this assertion fails with 24 orphaned permissions.
pgq() {
    ${COMPOSE} exec -T postgres psql -U jellyfin -d jellyfin -qAt -c "$1" | tr -d '[:space:]'
}
orphans_before="$(pgq 'SELECT count(*) FROM "Permissions" WHERE "UserId" IS NULL;')"
[ "${orphans_before}" = "0" ] || die "started dirty: ${orphans_before} orphaned permission rows before the update"

curl -sf -X POST "${LEADER_URL}/Users/ForgotPassword" \
    -H 'Content-Type: application/json' -d '{"EnteredUsername":"smoke"}' > /dev/null \
    || die "ForgotPassword (the UpdateUserAsync trigger) failed"

orphans_after="$(pgq 'SELECT count(*) FROM "Permissions" WHERE "UserId" IS NULL;')"
pref_orphans="$(pgq 'SELECT count(*) FROM "Preferences" WHERE "UserId" IS NULL;')"
[ "${orphans_after}" = "0" ] \
    || die "user update orphaned ${orphans_after} permission rows (severed to NULL UserId instead of deleted)"
[ "${pref_orphans}" = "0" ] \
    || die "user update orphaned ${pref_orphans} preference rows (severed to NULL UserId instead of deleted)"

# The user must still HAVE its permissions: deleting too much is the other failure mode.
live_perms="$(pgq 'SELECT count(*) FROM "Permissions" WHERE "UserId" IS NOT NULL;')"
[ "${live_perms}" -gt 0 ] \
    || die "user update deleted the live permission rows too (${live_perms} remain): access control is broken"

info "asserting the count rewrite equals the grouped construction, NULL keys included (patch 0008)"
# GetGroupedCount counts DISTINCT grouping keys; ApplyGroupingFilter instead materialises
# one representative id per group and counts those. They are the same number by
# construction, and this asserts it in SQL so a future rebase cannot let the two drift.
#
# The case that matters is a NULL PresentationUniqueKey: SELECT DISTINCT keeps NULL as a
# group (matching GROUP BY), whereas count(DISTINCT col) would silently drop it and put
# every folder's UnplayedItemCount off by one. A freshly wizarded server already carries
# NULL-key rows (the PlaylistsFolder and the PLACEHOLDER sentinel), so this has teeth
# here even though this suite mounts no media - and it covers the one thing a real
# library cannot, since a populated library's hot path has no NULL keys at all.
null_keys="$(pgq 'SELECT count(*) FROM "BaseItems" WHERE "PresentationUniqueKey" IS NULL;')"
[ "${null_keys}" -ge 1 ] \
    || die "no NULL PresentationUniqueKey rows exist, so the NULL-group assertion below would prove nothing"

grouped="$(pgq 'SELECT count(*) FROM "BaseItems" b WHERE b."Id" IN (
    SELECT (SELECT b1."Id" FROM "BaseItems" b1
            WHERE (b0."PresentationUniqueKey" = b1."PresentationUniqueKey"
                   OR (b0."PresentationUniqueKey" IS NULL AND b1."PresentationUniqueKey" IS NULL))
            LIMIT 1)
    FROM "BaseItems" b0 GROUP BY b0."PresentationUniqueKey");')"
distinct="$(pgq 'SELECT count(*) FROM (SELECT DISTINCT "PresentationUniqueKey" FROM "BaseItems") t;')"
[ "${grouped}" = "${distinct}" ] \
    || die "grouped construction counts ${grouped} but the distinct-key count is ${distinct}: patch 0008 has diverged (NULL-key handling is the usual cause)"

info "asserting the replica disarmed background work"
# Exact phrase from patch 0004.
${COMPOSE} logs jellyfin-replica | grep "scheduled task triggers stay disarmed" > /dev/null || die "replica role log line missing"

info "dispatch: registering the worker with rffmpeg on the leader"
${COMPOSE} exec -T jellyfin-leader rffmpeg init -y > /dev/null || die "rffmpeg init failed"
${COMPOSE} exec -T jellyfin-leader rffmpeg add transcode-worker > /dev/null || die "rffmpeg add failed"

info "dispatch: encoding through the shim (must land on the worker)"
${COMPOSE} exec -T jellyfin-leader ffmpeg-dispatch \
    -f lavfi -i testsrc=duration=1:size=320x240:rate=10 \
    -c:v libx264 -f null - > /dev/null 2>&1 || die "dispatched encode failed"
${COMPOSE} exec -T jellyfin-leader cat /config/log/rffmpeg.log \
    | grep "Running command on host 'transcode-worker'" > /dev/null \
    || die "encode did not dispatch to the worker"

info "dispatch: stopping the worker; the shim must fall back to local ffmpeg"
${COMPOSE} stop transcode-worker > /dev/null 2>&1
${COMPOSE} exec -T jellyfin-leader ffprobe-dispatch -version > /dev/null 2>&1 || die "fallback ffprobe failed"
${COMPOSE} exec -T jellyfin-leader tail -20 /config/log/rffmpeg.log \
    | grep "Running command on host 'localhost'" > /dev/null \
    || die "fallback did not engage"

info "PASS"
