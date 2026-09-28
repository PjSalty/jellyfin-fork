#!/bin/sh
#
# Script: web-patches.sh
# Description: Patch the official jellyfin-web bundle at image build. Every
#              anchor must occur exactly once, in the one chunk the patch
#              targets, so a web bump that moves the code fails the build
#              instead of shipping a silent no-op. Anchors are minified names
#              from jellyfin-web 12.1: re-derive them on a base bump.
# Usage: web-patches.sh <jellyfin-web dir>
#
set -eu
web="${1:?usage: web-patches.sh <jellyfin-web dir>}"

# replace <file> <anchor> <replacement>
replace() {
    count="$(grep -o -F -- "$2" "$1" | wc -l)"
    [ "${count}" -eq 1 ] || { echo "web-patches: anchor occurs ${count} times in $1: $2" >&2; exit 1; }
    ANCHOR="$2" REPL="$3" perl -0pi -e 's/\Q$ENV{ANCHOR}\E/$ENV{REPL}/' "$1"
    grep -q -F -- "$3" "$1" || { echo "web-patches: replacement missing in $1" >&2; exit 1; }
}

# Display language: the settings page kept its old strings until the next
# navigation. Flag a language change on save, reload once the save finished.
set_lang='o.language(e.querySelector("#selectLanguage").value)'
saved='r&&(0,S.A)(f.Ay.translate("SettingsSaved")),g.A.trigger(e,"saved")'
files="$(grep -l -F -- "${set_lang}" "${web}"/*.js || true)"
[ "$(printf '%s' "${files}" | grep -c .)" -eq 1 ] || { echo "web-patches: display settings chunk not found once: ${files}" >&2; exit 1; }
replace "${files}" "${set_lang}" "((o.language()||\"\")!==e.querySelector(\"#selectLanguage\").value&&(window.jfLangReload=1),${set_lang})"
replace "${files}" "${saved}" "${saved},window.jfLangReload&&(window.jfLangReload=0,setTimeout(function(){location.reload()},800))"
echo "web-patches: display language reload -> ${files}"
