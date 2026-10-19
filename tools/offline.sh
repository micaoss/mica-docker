#!/usr/bin/env bash
# Build this repository's outputs from a clean checkout with only the inputs it
# already pins (locks/): the engine and the
# mica-docker archive for amd64 and arm64, as indexed pools, exactly as
# build.sh and tools/package.sh write them. No GitHub release is read.
#
#   bash tools/offline.sh
#
# Writes _out/debs/<arch>/pool/, _out/debs/<arch>/Packages and
# _out/debs/<arch>/SHA256SUMS, and prints them.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die() { echo "offline.sh: error: $*" >&2; exit 1; }
cd "${REPO_ROOT}"

[ -z "$(git status --porcelain)" ] || die "the checkout has uncommitted changes; an offline build is made from a clean commit only"
COMMIT="$(git rev-parse HEAD)"

for arch in amd64 arm64; do
    MICA_ARCH="${arch}" bash build.sh
    bash tools/package.sh --arch "${arch}"
done
[ -z "$(git status --porcelain)" ] || die "the checkout changed during the build; its archives name no commit"
[ "$(git rev-parse HEAD)" = "${COMMIT}" ] || die "HEAD moved during the build"

echo "offline.sh: built ${COMMIT}"
echo "offline.sh: warning: no release was compared, so the inputs guard (mica-tools pool guard) was not applied to mica-docker $(sed -n 's/^Version: //p' deb/mica-docker.control)" >&2
for arch in amd64 arm64; do
    dist="${REPO_ROOT}/_out/debs/${arch}"
    [ -s "${dist}/Packages" ] && [ -s "${dist}/SHA256SUMS" ] && (cd "${dist}" && sha256sum --quiet -c SHA256SUMS) ||
        die "_out/debs/${arch} is not an indexed pool (pool/, Packages, SHA256SUMS)"
    echo "offline.sh: ${dist}/pool ($(find "${dist}/pool" -maxdepth 1 -name '*.deb' | wc -l) archive)"
    echo "offline.sh: ${dist}/Packages ${dist}/SHA256SUMS"
done
