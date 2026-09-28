#!/bin/sh
#
# Script: web-patches.sh
# Description: Patch the official jellyfin-web bundle at image build. Each
#              patch names how many chunks carry its anchor and every anchor
#              must occur exactly once per chunk, so a web bump that moves the
#              code fails the build instead of shipping a silent no-op.
#              Anchors are minified names from jellyfin-web 12.1: re-derive
#              them on a base bump.
# Usage: web-patches.sh <jellyfin-web dir>
#
set -eu
web="${1:?usage: web-patches.sh <jellyfin-web dir>}"

# chunks <expected count> <anchor>: the chunks that carry the anchor
chunks() {
    found="$(grep -l -F -- "$2" "${web}"/*.js || true)"
    n="$(printf '%s' "${found}" | grep -c . || true)"
    [ "${n}" -eq "$1" ] || { echo "web-patches: expected $1 chunk(s) with: $2, found ${n}: ${found}" >&2; exit 1; }
    printf '%s\n' "${found}"
}

# replace <file> <anchor> <replacement>
replace() {
    count="$(grep -o -F -- "$2" "$1" | wc -l)"
    [ "${count}" -eq 1 ] || { echo "web-patches: anchor occurs ${count} times in $1: $2" >&2; exit 1; }
    ANCHOR="$2" REPL="$3" perl -0pi -e 's/\Q$ENV{ANCHOR}\E/$ENV{REPL}/' "$1"
    grep -q -F -- "$3" "$1" || { echo "web-patches: replacement missing in $1" >&2; exit 1; }
}

# Display language: the settings page kept its old strings until the next
# navigation. Flag a language change on save, reload once the save finished.
reload='window.jfLangReload&&(window.jfLangReload=0,setTimeout(function(){location.reload()},800))'

# Legacy controller (TV, desktop-legacy and mobile-legacy layouts).
set_lang='o.language(e.querySelector("#selectLanguage").value)'
saved='r&&(0,S.A)(f.Ay.translate("SettingsSaved")),g.A.trigger(e,"saved")'
# chunks runs in a command substitution: assign first so a failed lookup
# stops the script under set -e instead of looping over nothing.
files="$(chunks 1 "${set_lang}")"
for f in ${files}; do
    replace "${f}" "${set_lang}" "((o.language()||\"\")!==e.querySelector(\"#selectLanguage\").value&&(window.jfLangReload=1),${set_lang})"
    replace "${f}" "${saved}" "${saved},${reload}"
    echo "web-patches: display language reload (legacy) -> ${f}"
done

# React page of the default modern layout, built into two route chunks.
set_lang='t.language(_(s.language))'
saved='e.sent(),(0,E.A)(x.Ay.translate("SettingsSaved"))'
files="$(chunks 2 "${set_lang}")"
for f in ${files}; do
    replace "${f}" "${set_lang}" "((t.language()||\"\")!==(_(s.language)||\"\")&&(window.jfLangReload=1),${set_lang})"
    replace "${f}" "${saved}" "${saved},${reload}"
    echo "web-patches: display language reload (modern) -> ${f}"
done

# hls.js demuxer worker: hls.js 1.6 builds its worker from factory.toString(),
# and the web client's own minifier leaves that function referencing an outer
# name, so every HLS playback spun up a worker that died with "ReferenceError:
# e is not defined" before hls.js fell back to inline transmuxing. Start
# inline: the same playback path, minus the failed worker and its error.
hls_defaults='t.DefaultConfig.liveBackBufferLength=90,window.Hls=t'
files="$(chunks 2 "${hls_defaults}")"
for f in ${files}; do
    replace "${f}" "${hls_defaults}" 't.DefaultConfig.liveBackBufferLength=90,t.DefaultConfig.enableWorker=!1,window.Hls=t'
    echo "web-patches: hls.js inline transmuxing -> ${f}"
done
