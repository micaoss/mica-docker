#!/usr/bin/env bash
# The engine build's compile caches (the BuildKit cache mounts of Dockerfile),
# moved between the buildx builder and <dir>/engine-cache.tar so CI can keep them.
#
#   bash tools/build-cache.sh restore <dir>   load <dir>/engine-cache.tar into the builder's cache mounts
#   bash tools/build-cache.sh save <dir>      write the builder's cache mounts to <dir>/engine-cache.tar
#
# MICA_ARCH selects the builder as build.sh does. A cache only speeds the
# compile: every Dockerfile step still runs. One tar file crosses the builder
# boundary, not the caches' many small files.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die() { echo "build-cache.sh: error: $*" >&2; exit 1; }

# <directory name> <cache mount id>, as Dockerfile declares them (an id defaults to the target).
MOUNTS=(
    "go-build /root/.cache/go-build"
    "go-mod /go/pkg/mod"
)

[ "$#" -eq 2 ] || die "usage: bash tools/build-cache.sh restore|save <dir>"
MODE="$1"
DIR="$2"
MICA_ARCH="${MICA_ARCH:-arm64}"
case "${MICA_ARCH}" in amd64 | arm64) ;; *) die "MICA_ARCH is '${MICA_ARCH}'; it must be arm64 or amd64" ;; esac

# shellcheck disable=SC1091
. "${REPO_ROOT}/tools/buildx.sh"
buildx_builder "${MICA_ARCH}"
BASE="$("${REPO_ROOT}/bin/mica-tools" from --ref mica-build-env:base)"
SYNTAX="$(sed -n '1p' "${REPO_ROOT}/Dockerfile")"

mounts=""
names=""
for m in "${MOUNTS[@]}"; do
    mounts="${mounts} --mount=type=cache,id=${m#* },target=/cache/${m%% *}"
    names="${names} ${m%% *}"
done

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
# A new value per run, so the step always runs: --no-cache would also hand the
# step fresh, empty cache mounts.
RUN_ID="$(date +%s%N)"
build() { # <context> [buildx args]
    local context="$1"
    shift
    docker buildx build --builder "${BUILDER}" --platform "linux/${MICA_ARCH}" \
        --build-arg "BASE=${BASE}" --build-arg "RUN_ID=${RUN_ID}" -f "${WORK}/Dockerfile" "$@" "${context}"
}

case "${MODE}" in
restore)
    [ -f "${DIR}/engine-cache.tar" ] || die "${DIR}/engine-cache.tar does not exist"
    cat >"${WORK}/Dockerfile" <<EOF
${SYNTAX}
ARG BASE
FROM \${BASE}
ARG RUN_ID
RUN --mount=type=bind,target=/seed${mounts} \\
    tar -C /cache -xf /seed/engine-cache.tar
EOF
    build "${DIR}" -o type=cacheonly
    echo "build-cache.sh: restored ${DIR}/engine-cache.tar ($(du -h "${DIR}/engine-cache.tar" | cut -f1)) into the ${BUILDER} cache mounts"
    ;;
save)
    cat >"${WORK}/Dockerfile" <<EOF
${SYNTAX}
ARG BASE
FROM \${BASE} AS pack
ARG RUN_ID
RUN${mounts} \\
    mkdir -p /out && tar -C /cache -cf /out/engine-cache.tar${names}
FROM scratch
COPY --from=pack /out/engine-cache.tar /
EOF
    rm -rf "${DIR}"
    mkdir -p "${DIR}"
    build "${WORK}" -o "type=local,dest=${DIR}"
    echo "build-cache.sh: saved the ${BUILDER} cache mounts to ${DIR}/engine-cache.tar ($(du -h "${DIR}/engine-cache.tar" | cut -f1))"
    ;;
*)
    die "usage: bash tools/build-cache.sh restore|save <dir>"
    ;;
esac
