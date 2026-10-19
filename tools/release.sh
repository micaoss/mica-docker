#!/usr/bin/env bash
# Publish _out/debs/{amd64,arm64}/pool of a clean HEAD for the published GitHub
# Release <tag> of this repository (mica-build-tools:docs/spec/release-lock.md):
#   - the one mica-docker archive of each pool passes `mica-tools pool guard`
#     against the previous release: a package at a released version keeps its
#     inputs hash and its bytes, and no version goes lower;
#   - `mica-tools release pool` pushes ghcr.io/micaoss/mica-docker:pool.<arch>.<tag>
#     and reads them back anonymously;
#   - the lock (release, pool and package rows) passes `mica-tools lock check`,
#     and `mica-tools release attach` attaches it and SHA256SUMS listing only it,
#     read back anonymously.
# Nothing published is ever replaced.
#
#   GH_TOKEN=<token with contents:write and packages:write> bash tools/release.sh <YYYYMMDD-HHMM>
#
# Run by release.yml for the release the user cut with
# `gh release create <YYYYMMDD-HHMM> --target <commit of main>`.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="${REPO_ROOT}/bin/mica-tools"
PACKAGE=mica-docker
ARCHES=(amd64 arm64)
die() { echo "release.sh: error: $*" >&2; exit 1; }

[ "$#" -eq 1 ] || die "usage: bash tools/release.sh <YYYYMMDD-HHMM>"
TAG="$1"
cd "${REPO_ROOT}"
[ -n "${GH_TOKEN:-}" ] || die "GH_TOKEN must be set; releasing is CI's, with its own token"

# The tag is a UTC time naming this clean HEAD, on origin/main.
COMMIT="$("${TOOLS}" release check "${TAG}")" || die "${TAG} is not a release this checkout can publish; nothing was published"
"${TOOLS}" locks check --ci >/dev/null

VERSION="$(sed -n 's/^Version: //p' deb/mica-docker.control)"
for arch in "${ARCHES[@]}"; do
    deb="_out/debs/${arch}/pool/${PACKAGE}_${VERSION}_${arch}.deb"
    [ -f "${deb}" ] || die "${deb} does not exist; ${PACKAGE} is released at its declared version"
    [ "$(find "_out/debs/${arch}/pool" -maxdepth 1 -type f -name '*.deb' | wc -l)" -eq 1 ] ||
        die "_out/debs/${arch}/pool holds another archive beside ${deb##*/}"
    "${TOOLS}" pool guard --before "${TAG}" "${arch}" "${deb}" | sed 's/^/release.sh: /'
done

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
LOCK="$(basename "$(git remote get-url origin)" .git).lock"
"${TOOLS}" release pool "${TAG}" $(printf -- '--arch %s ' "${ARCHES[@]}") >"${WORK}/rows"
{
    echo "# mica-lock v1"
    printf 'release\t%s\t%s\t%s\n' "${LOCK%.lock}" "${TAG}" "${COMMIT}"
    cat "${WORK}/rows"
} >"${WORK}/${LOCK}"
result="$("${TOOLS}" lock check "${WORK}/${LOCK}")" || die "the lock this release writes is ${result}"
"${TOOLS}" release attach "${TAG}" "${WORK}/${LOCK}" \
    --notes "${LOCK%.lock} ${COMMIT}: ${LOCK} (mica-lock v1) names the package pools of this release. Verify with SHA256SUMS." ||
    die "the assets of ${TAG} were not attached"
sed 's/^/release.sh:   /' "${WORK}/${LOCK}"
