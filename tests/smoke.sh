#!/usr/bin/env bash
#
# Script: smoke.sh
# Description: Two-replica smoke test. A migrate Job seeds the schema once,
#              then a leader and a replica boot with migrations gated off.
#              Asserts: the migrate pass exited 0 without a startup error, both healthy, wizard on the leader, a token minted on
#              the leader authenticates on the replica (read-through), browse
#              works on both, the replica armed no scheduled tasks, and the
#              rffmpeg shims dispatch to a worker then fall back locally.
# Usage: ./tests/smoke.sh   (expects ../upstream to be assembled, see build/assemble.sh)
#        JELLYFIN_PGSQL_VERSION=<tag>   plugin release to fetch (default in docker-compose.yml)
#        JELLYFIN_PGSQL_LOCAL_DIR=<dir> use an already-published plugin zip + SHA256SUMS
#                                       from <dir> instead of downloading (path with a slash)
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

info "asserting the migrate pass exited 0 without a startup error"
# Before patch 0023 a failed pass logged this line and still exited 0, so the
# exit code alone proves nothing on an older image; check both.
migrate_id="$(${COMPOSE} ps -a -q migrate)"
[ -n "${migrate_id}" ] || die "migrate container not found"
migrate_state="$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "${migrate_id}")"
[ "${migrate_state}" = "exited 0" ] || die "migrate pass ended as '${migrate_state}', expected 'exited 0'"
if ${COMPOSE} logs migrate 2>&1 | grep "Error while starting server" > /dev/null; then
    die "migrate pass logged 'Error while starting server'"
fi
wait_healthy "${LEADER_URL}" || die "leader never became healthy"
wait_healthy "${REPLICA_URL}" || die "replica never became healthy"

info "asserting the skip-gate engaged on both serving pods"
# Exact phrase from patch 0002; plain grep drains the stream (grep -q closes
# the pipe early and pipefail then fails on compose logs' SIGPIPE).
${COMPOSE} logs jellyfin-leader | grep "migration machinery will not run" > /dev/null || die "leader skip-gate log line missing"
${COMPOSE} logs jellyfin-replica | grep "migration machinery will not run" > /dev/null || die "replica skip-gate log line missing"

info "asserting the thread-pool worker floor engaged on both serving pods"
# Exact phrase from patch 0015: the floor only exists if the startup log says so.
# Same plain-grep-drains-the-stream rule as above; 2>&1 keeps any lines compose
# emits on stderr in scope for the grep.
${COMPOSE} logs jellyfin-leader 2>&1 | grep "Thread pool worker floor raised" > /dev/null || die "leader thread-pool floor log line missing"
${COMPOSE} logs jellyfin-replica 2>&1 | grep "Thread pool worker floor raised" > /dev/null || die "replica thread-pool floor log line missing"

info "asserting the image kept its jemalloc preload and ships a PostgreSQL 18 client"
# The payload swap in docker/Dockerfile must not take the LD_PRELOAD target
# with it; the loader only warns per process, so the log is where it shows.
if ${COMPOSE} logs jellyfin-leader 2>&1 | grep "cannot be preloaded" > /dev/null; then
    die "LD_PRELOAD target missing in the image"
fi
# The provider's pre-migration backup runs pg_dump, which refuses a server
# major newer than its own.
${COMPOSE} exec -T jellyfin-leader pg_dump --version | grep -E ' 18\.' > /dev/null \
    || die "pg_dump in the image is not PostgreSQL 18"

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
# 12.x ignores the legacy X-Emby-Authorization / X-Emby-Token headers unless
# EnableLegacyAuthorization is set, and a fresh server leaves it off, so the
# smoke speaks the Authorization: MediaBrowser form throughout.
auth_header='Authorization: MediaBrowser Client="smoke", Device="ci", DeviceId="ci", Version="1"'
token="$(curl -sf -X POST "${LEADER_URL}/Users/AuthenticateByName" \
    -H 'Content-Type: application/json' -H "${auth_header}" \
    -d '{"Username":"smoke","Pw":"smoketest"}' | jq -r '.AccessToken')"
if [ -z "${token}" ] || [ "${token}" = "null" ]; then
    die "authentication failed on the leader"
fi
token_header="Authorization: MediaBrowser Token=\"${token}\""
user_id="$(curl -sf "${LEADER_URL}/Users/Me" -H "${token_header}" | jq -r '.Id')"

info "asserting the legacy token header is refused (12.x default)"
code="$(curl -s -o /dev/null -w '%{http_code}' "${LEADER_URL}/Users/Me" -H "X-Emby-Token: ${token}")"
[ "${code}" = "401" ] || die "legacy X-Emby-Token answered http ${code}, expected 401"

info "asserting the api_key query parameter is accepted (0024: web socket and Download)"
code="$(curl -s -o /dev/null -w '%{http_code}' "${LEADER_URL}/Users/Me?api_key=${token}")"
[ "${code}" = "200" ] || die "api_key query answered http ${code}, expected 200"

info "asserting the LEADER-minted token works on the REPLICA (read-through)"
code="$(curl -s -o /dev/null -w '%{http_code}' "${REPLICA_URL}/Users/Me" -H "${token_header}")"
[ "${code}" = "200" ] || die "replica rejected a leader-minted token (http ${code}): read-through broken"

info "browsing on both pods"
curl -sf "${LEADER_URL}/Users/${user_id}/Items?Recursive=true" -H "${token_header}" > /dev/null || die "browse failed on leader"
curl -sf "${REPLICA_URL}/Users/${user_id}/Items?Recursive=true" -H "${token_header}" > /dev/null || die "browse failed on replica"

info "asserting a user update DELETES old permissions instead of orphaning them"
# Regression guard for what patch 0006 fixed on 10.11 and v12.1 absorbed
# (UpdateUserAsync now syncs Permissions/Preferences in place): clearing the
# collections used to make EF SEVER the rows (UPDATE ... SET "UserId" = NULL)
# instead of deleting them, stranding the user's whole permission set on every
# call. Invisible to the app and to UNIQUE(UserId, Kind), so only SQL sees it.
#
# ForgotPassword is the in-tree caller of UpdateUserAsync reachable over the
# API without a session, so it is the trigger.
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
