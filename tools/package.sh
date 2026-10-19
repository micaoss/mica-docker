#!/usr/bin/env bash
# Pack _out/engine/<arch> as mica-docker_<version>_<arch>.deb, the version and
# SOURCE_DATE_EPOCH deb/mica-docker.control declares
# (mica-build-tools:docs/spec/package-versions.md): Version is
# <Docker version>-<revision>, its upstream part the moby tag (docker-v<version>) of
# locks/upstream.lock, and Source-Date-Epoch is bumped with it.
#
#   bash tools/package.sh --arch <amd64|arm64> [--out <dir>] [--no-cache]
#
# Writes <dir>/<arch>/pool/ (default _out/debs); _out/debs is indexed beside the
# pool with `mica-tools pool index`: Packages, SHA256SUMS and manifest.txt. The binaries must be complete, of the target
# architecture and stamped by the current locks/upstream.lock.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die() { echo "package.sh: error: $*" >&2; exit 1; }

ARCH="" OUT_ROOT="${REPO_ROOT}/_out/debs" NO_CACHE=()
while [ "$#" -gt 0 ]; do
    case "$1" in
    --arch) ARCH="${2-}"; shift 2 ;;
    --out) OUT_ROOT="${2-}"; shift 2 ;;
    --no-cache) NO_CACHE=(--no-cache); shift ;;
    *) die "usage: bash tools/package.sh --arch <amd64|arm64> [--out <dir>] [--no-cache]" ;;
    esac
done
case "${ARCH}" in
amd64) ELF_ARCH=x86-64 ;;
arm64) ELF_ARCH=aarch64 ;;
*) die "--arch must be amd64 or arm64" ;;
esac

TOOLS="${REPO_ROOT}/bin/mica-tools"
CONTROL="${REPO_ROOT}/deb/mica-docker.control"
VERSION="$(sed -n 's/^Version: //p' "${CONTROL}")"
[[ "${VERSION}" =~ ^([0-9]+(\.[0-9]+)*)-([1-9][0-9]*)$ ]] || die "deb/mica-docker.control Version '${VERSION}' is not <Docker version>-<revision>"
TAG="$("${TOOLS}" upstream get git moby ref)"
[ "docker-v${BASH_REMATCH[1]}" = "${TAG}" ] || die "deb/mica-docker.control Version ${VERSION}: its upstream part ${BASH_REMATCH[1]} is not the moby tag ${TAG} of locks/upstream.lock"
EPOCH="$(sed -n 's/^Source-Date-Epoch: //p' "${CONTROL}")"
[[ "${EPOCH}" =~ ^[1-9][0-9]*$ ]] || die "deb/mica-docker.control Source-Date-Epoch '${EPOCH}' is not whole seconds"

BIN="${REPO_ROOT}/_out/engine/${ARCH}"
BINARIES=(dockerd docker-proxy docker docker-compose containerd containerd-shim-runc-v2 runc docker-init)
missing=""
for b in "${BINARIES[@]}"; do
    [ -f "${BIN}/${b}" ] || missing="${missing} ${b}"
done
[ -z "${missing}" ] || die "${BIN} is missing${missing}; run MICA_ARCH=${ARCH} make engine"
bash "${REPO_ROOT}/tools/stamp.sh" --check "${BIN}"
for b in "${BINARIES[@]}"; do
    case "$(file -b "${BIN}/${b}")" in
    *"ELF 64-bit"*"${ELF_ARCH}"*) ;;
    *) die "${BIN}/${b} is not an ${ELF_ARCH} ELF; run MICA_ARCH=${ARCH} make engine" ;;
    esac
done

# shellcheck disable=SC1091
. "${REPO_ROOT}/tools/buildx.sh"
buildx_builder "${ARCH}"

ORIGIN="$(git -C "${REPO_ROOT}" remote get-url origin)"
SOURCE_REPO="$(basename "${ORIGIN%/}" .git)"
BASE="$("${TOOLS}" from --ref mica-build-env:base)"
"${TOOLS}" sync

STAGE="${REPO_ROOT}/_out/stage/${ARCH}"
rm -rf "${STAGE}"
mkdir -p "${STAGE}"
cp "${BINARIES[@]/#/${BIN}/}" "${BIN}/upstream.lock" "${STAGE}/"

DEST="${OUT_ROOT}/${ARCH}"
rm -rf "${DEST}"
docker buildx build --builder "${BUILDER}" --platform "linux/${ARCH}" ${NO_CACHE[@]+"${NO_CACHE[@]}"} \
    --build-arg "MICA_BUILD_BASE=${BASE}" \
    --build-arg "MICA_DEB_VERSION=${VERSION}" \
    --build-arg "MICA_DEB_ARCH=${ARCH}" \
    --build-arg "SOURCE_DATE_EPOCH=${EPOCH}" \
    --build-arg "MICA_DEB_SOURCE_REPO=${SOURCE_REPO}" \
    --build-context "overlay=${REPO_ROOT}/overlay" \
    --build-context "bin=${STAGE}" \
    --build-context "tools=${REPO_ROOT}/repos/mica-build-tools" \
    -f "${REPO_ROOT}/deb/Dockerfile" \
    -o "type=local,dest=${DEST}/pool" \
    "${REPO_ROOT}/deb"

want="mica-docker_${VERSION}_${ARCH}.deb"
[ "$(ls -A "${DEST}/pool")" = "${want}" ] || die "${DEST}/pool holds '$(ls -A "${DEST}/pool" | tr '\n' ' ')', expected ${want}"
# The index is the release's pool, _out/debs; a rebuild elsewhere (tests/package-gate.sh --reproduce) is compared by its bytes alone.
if [ "${OUT_ROOT}" = "${REPO_ROOT}/_out/debs" ]; then
    "${TOOLS}" pool index --arch "${ARCH}" >/dev/null
    [ -s "${DEST}/Packages" ] || die "mica-tools pool index wrote no Packages for ${DEST}/pool"
fi
echo "package.sh: ${DEST#"${REPO_ROOT}"/}/pool/${want} on ${BASE}"
