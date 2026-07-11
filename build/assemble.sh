#!/usr/bin/env bash
#
# Script: assemble.sh
# Description: Rebuild the server source tree from pristine upstream plus patches.
# Usage: ./build/assemble.sh [output-dir]
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/jellyfin/jellyfin}"
UPSTREAM_REF="$(tr -d '[:space:]' < "${REPO_ROOT}/UPSTREAM_REF")"
OUT="${1:-${REPO_ROOT}/upstream}"

rm -rf "${OUT}"
git clone --quiet --depth 1 --branch "${UPSTREAM_REF}" "${UPSTREAM_REPO}" "${OUT}"

cd "${OUT}"
git -c user.name="assemble" -c user.email="assemble@localhost" am "${REPO_ROOT}"/patches/*.patch

patch_count="$(find "${REPO_ROOT}/patches" -name '*.patch' | wc -l)"
echo "assembled ${UPSTREAM_REF} + ${patch_count} patches into ${OUT}"
