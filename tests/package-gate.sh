#!/usr/bin/env bash
# The package gate (mica-build-tools:docs/spec/build-rules.md section 6) over the pools _out/debs/<arch>/.
#
#   bash tests/package-gate.sh [--arch <amd64|arm64>]... [--reproduce]
#
# Default: both architectures, and one git stamp across them. --reproduce
# rebuilds the engine and each archive with no cache and requires identical
# bytes: every shipped engine binary, then the archive.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT=$PWD

ARCHES=() REPRODUCE=0
while [ "$#" -gt 0 ]; do
    case "$1" in
    --arch) ARCHES+=("${2-}"); shift 2 ;;
    --reproduce) REPRODUCE=1; shift ;;
    *) echo "usage: bash tests/package-gate.sh [--arch <amd64|arm64>]... [--reproduce]" >&2; exit 2 ;;
    esac
done
[ "${#ARCHES[@]}" -gt 0 ] || ARCHES=(amd64 arm64)
command -v dpkg-deb >/dev/null 2>&1 || { echo "error: dpkg-deb is required" >&2; exit 2; }

PASS_N=0 FAIL_N=0
pass() { PASS_N=$((PASS_N + 1)); echo "PASS: $*"; }
fail() { FAIL_N=$((FAIL_N + 1)); echo "FAIL: $*"; }
check() { local label="$1"; shift; if "$@"; then pass "${label}"; else fail "${label}"; fi; }

DECLARED="$(sed -n 's/^Version: //p' deb/mica-docker.control)"
SOURCE_REPO="$(basename "$(git remote get-url origin)" .git)"
MAINTAINER='Mica OS <hi@micaos.dev>'
WORK="$(mktemp -d "${REPO_ROOT}/_out/package-gate.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
grep -v '^#' deb/payload.manifest | grep -v '^$' | awk '{ print substr($3, 2) }' | LC_ALL=C sort >"${WORK}/declared"

VERSIONS=()
for arch in "${ARCHES[@]}"; do
    mapfile -t debs < <(find "_out/debs/${arch}/pool" -maxdepth 1 -type f -name '*.deb' 2>/dev/null | LC_ALL=C sort)
    if [ "${#debs[@]}" -ne 1 ]; then
        fail "${arch}: _out/debs/${arch}/pool holds ${#debs[@]} archives, not one"
        continue
    fi
    deb="${debs[0]}"
    check "${arch}: SHA256SUMS lists exactly pool/$(basename "${deb}") at its digest" \
        bash -c 'cd "$1" && [ "$(sed "s/^[0-9a-f]\{64\}  //" SHA256SUMS)" = "pool/$2" ] && sha256sum --quiet -c SHA256SUMS' _ "_out/debs/${arch}" "$(basename "${deb}")"
    check "${arch}: Packages indexes pool/$(basename "${deb}")" \
        bash -c '[ "$(sed -n "s/^Filename: //p" "$1/Packages")" = "pool/$2" ] && [ "$(sed -n "s/^SHA256: //p" "$1/Packages")" = "$(sha256sum "$1/pool/$2" | cut -d" " -f1)" ]' _ "_out/debs/${arch}" "$(basename "${deb}")"
    field() { dpkg-deb --field "${deb}" "$1"; }
    v="$(field Version)"
    VERSIONS+=("${v}")
    check "${arch}: file name is Package_Version_Architecture" [ "$(basename "${deb}")" = "mica-docker_${v}_${arch}.deb" ]
    check "${arch}: Package mica-docker, Architecture ${arch}" [ "$(field Package)/$(field Architecture)" = "mica-docker/${arch}" ]
    check "${arch}: Version ${v} is the version deb/mica-docker.control declares" [ "${v}" = "${DECLARED}" ]
    check "${arch}: Maintainer ${MAINTAINER}" [ "$(field Maintainer)" = "${MAINTAINER}" ]
    check "${arch}: Mica-Source-Repo ${SOURCE_REPO}, no commit or epoch field" \
        [ "$(field Mica-Source-Repo)/$(field Mica-Source-Commit)$(field Source-Date-Epoch)" = "${SOURCE_REPO}/" ]
    check "${arch}: no Replaces" [ -z "$(field Replaces)" ]
    check "${arch}: Provides mica-container-engine, Conflicts mica-podman" \
        [ "$(field Provides)/$(field Conflicts)" = "mica-container-engine/mica-podman" ]
    check "${arch}: Depends is expanded" bash -c '[ -n "$1" ] && case "$1" in *"\${"*) exit 1 ;; esac' _ "$(field Depends)"
    depends="$(field Depends | tr ',' '\n' | sed 's/|.*//; s/(.*//; s/:any//; s/[[:space:]]//g' | grep -v '^mica-' | LC_ALL=C sort -u | tr '\n' ' ')"
    check "${arch}: Debian Depends are exactly deb/debian-depends (${depends% })" \
        [ "${depends}" = "$(sed 's/#.*//; /^[[:space:]]*$/d' deb/debian-depends | LC_ALL=C sort -u | tr '\n' ' ')" ]
    check "${arch}: control archive holds only control and md5sums (no conffiles, no maintainer scripts)" \
        [ "$(dpkg-deb --ctrl-tarfile "${deb}" | tar -t | sed 's|^\./||; /^$/d' | LC_ALL=C sort | tr '\n' ' ')" = "control md5sums " ]
    dpkg-deb --fsys-tarfile "${deb}" | tar -t | sed 's|^\./||; s|/$||; /^$/d' | LC_ALL=C sort >"${WORK}/${arch}.paths"
    check "${arch}: payload is exactly deb/payload.manifest" cmp -s "${WORK}/declared" "${WORK}/${arch}.paths"
    check "${arch}: no enablement symlink" bash -c '! grep -c "\.wants/" "$1" >/dev/null' _ "${WORK}/${arch}.paths"
    check "${arch}: ships a non-empty copyright" \
        [ "$(dpkg-deb --fsys-tarfile "${deb}" | tar -xO ./usr/share/doc/mica-docker/copyright | wc -c)" -gt 0 ]
    check "${arch}: no Go binary carries a VCS stamp" \
        bash -c 'mkdir -p "$2" && dpkg-deb -x "$1" "$2" || exit 1; for b in usr/bin/dockerd usr/bin/docker usr/bin/containerd usr/bin/runc usr/libexec/docker/cli-plugins/docker-compose; do [ -f "$2/$b" ] && ! grep -a -c vcs.revision "$2/$b" >/dev/null || exit 1; done' _ "${deb}" "${WORK}/${arch}-vcs"
    if [ "${REPRODUCE}" = 1 ]; then
        MICA_ARCH="${arch}" MICA_ENGINE_OUT="${WORK}/engine-${arch}" MICA_NO_CACHE=1 bash build.sh >"${WORK}/${arch}-engine.log" 2>&1 ||
            { tail -20 "${WORK}/${arch}-engine.log"; fail "${arch}: the no-cache engine rebuild failed"; continue; }
        dpkg-deb -x "${deb}" "${WORK}/${arch}-root"
        for b in usr/bin/dockerd usr/bin/docker-proxy usr/bin/docker usr/libexec/docker/cli-plugins/docker-compose \
            usr/bin/containerd usr/bin/containerd-shim-runc-v2 usr/bin/runc usr/bin/docker-init; do
            check "${arch}: a no-cache engine rebuild gives the shipped ${b##*/} byte for byte" \
                cmp -s "${WORK}/${arch}-root/${b}" "${WORK}/engine-${arch}/${b##*/}"
        done
        bash tools/package.sh --arch "${arch}" --out "${WORK}/reproduce" --no-cache >"${WORK}/${arch}.log" 2>&1 ||
            { tail -20 "${WORK}/${arch}.log"; fail "${arch}: the no-cache rebuild failed"; continue; }
        check "${arch}: a no-cache rebuild is byte-identical" cmp -s "${deb}" "${WORK}/reproduce/${arch}/pool/$(basename "${deb}")"
    fi
done
# The gates an archive answers by itself, the same for every repository (mica-build-tools design 3.3.3).
check "mica-tools pool gate over ${ARCHES[*]}" bin/mica-tools pool gate $(printf -- '--arch %s ' "${ARCHES[@]}")
if [ "${#VERSIONS[@]}" -gt 1 ]; then
    check "one version across ${ARCHES[*]}" [ "$(printf '%s\n' "${VERSIONS[@]}" | LC_ALL=C sort -u | wc -l)" -eq 1 ]
fi

echo "RESULT: ${FAIL_N} failed, ${PASS_N} passed"
[ "${FAIL_N}" -eq 0 ]
