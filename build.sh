#!/usr/bin/env bash
# Build the eight engine binaries for MICA_ARCH (arm64 by default) into
# _out/engine/<arch>/, on the images the pinned mica-build-env release names.
# MICA_ENGINE_OUT overrides the directory; MICA_NO_CACHE=1 builds with no cache.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MICA_ARCH="${MICA_ARCH:-arm64}"
case "${MICA_ARCH}" in
arm64) ELF_ARCH=aarch64 ;;
amd64) ELF_ARCH=x86-64 ;;
*) echo "error: MICA_ARCH is '${MICA_ARCH}'; it must be arm64 or amd64" >&2; exit 1 ;;
esac
OUT="${MICA_ENGINE_OUT:-${HERE}/_out/engine/${MICA_ARCH}}"
NO_CACHE=()
[ "${MICA_NO_CACHE:-}" != 1 ] || NO_CACHE=(--no-cache)
BINARIES=(dockerd docker-proxy docker docker-compose containerd containerd-shim-runc-v2 runc docker-init)

# shellcheck disable=SC1091
. "${HERE}/tools/buildx.sh"
buildx_builder "${MICA_ARCH}"

IMAGE_ARGS=()
for image in base go; do
    ref="$("${HERE}/bin/mica-tools" from --ref "mica-build-env:${image}")"
    IMAGE_ARGS+=(--build-arg "MICA_BUILD_${image^^}=${ref}")
done

rm -rf "${OUT}"
mkdir -p "${OUT}"

# The Debian build packages of the cgo stage, by sha256, fetched and verified here.
# check first: a closure resolved against other build-env images is refused.
bash "${HERE}/tools/dev-pins.sh" check
PINS="${HERE}/_out/pins/${MICA_ARCH}"
bash "${HERE}/tools/dev-pins.sh" fetch "${MICA_ARCH}" "${PINS}"

docker buildx build --builder "${BUILDER}" \
    --platform "linux/${MICA_ARCH}" ${NO_CACHE[@]+"${NO_CACHE[@]}"} \
    "${IMAGE_ARGS[@]}" \
    --build-arg "ELF_ARCH=${ELF_ARCH}" \
    --build-arg "MICA_PINS_GO=$(bash "${HERE}/tools/dev-pins.sh" shas go "${MICA_ARCH}" | tr '\n' ' ')" \
    --build-context "pins=${PINS}" \
    -f "${HERE}/Dockerfile" \
    -o "type=local,dest=${OUT}" \
    "${HERE}"

missing=""
for b in "${BINARIES[@]}"; do
    [ -f "${OUT}/${b}" ] || missing="${missing} ${b}"
done
[ -z "${missing}" ] || {
    echo "error: the build reported success but these binaries are not in ${OUT}:${missing}" >&2
    exit 1
}

bash "${HERE}/tools/stamp.sh" --stamp "${OUT}"

echo "=== ${OUT} ==="
for b in "${BINARIES[@]}"; do
    printf '  %-24s %8s KiB  %s\n' "${b}" "$(($(stat -c%s "${OUT}/${b}") / 1024))" "$(file -b "${OUT}/${b}" | cut -c1-46)"
done
