#!/usr/bin/env bash
# The Debian packages mica-docker needs, consumed from mica-system-base as its
# README "Consuming a release" requires.
#
#   bash tools/base-check.sh
#
# locks/mica-system-base.lock is the pinned Base release, unchanged, and
# locks/pins/mica-system-base.pin its record (mica-build-tools:docs/spec/release-lock.md
# section 3). The check:
#   1. `mica-tools locks verify` checks the file rules and every pinned lock
#      against its release;
#   2. per architecture, the root's /var/lib/dpkg/status is read from the
#      rootfs image the lock names, by digest;
#   3. apt, with the lock's apt rows as its only sources (one deb822 stanza
#      per row, 1.2.5) and that status, names the archives the root lacks for
#      deb/debian-depends; version, SHA256 and URL come from the signed index;
#   4. each such archive must be an upstream row of the Base lock, whatever
#      roots it is pinned for (mica-system-base:docs/floor-and-options.md, *The
#      upstream rows*), or a source row of locks/upstream.lock under an apt URI
#      with the same columns, the build closure of pins/ aside; a recorded row
#      that no longer resolves is refused;
#   5. every Debian dependency deb/mica-docker.control declares is satisfied,
#      at its declared floor, by the version the root ships or the Base lock
#      pins. The floors are declared, never derived from a live
#      archive at build time.
set -euo pipefail
# One collation for sort and comm: they compare what the other ordered.
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO=micaoss/mica-system-base
LOCK="${REPO_ROOT}/locks/mica-system-base.lock"
RECORD="${REPO_ROOT}/locks/upstream.lock"
ROOTS="${REPO_ROOT}/deb/debian-depends"
REGISTRY="${MICA_BASE_REGISTRY:-https://ghcr.io}"
RESOLVE="${MICA_BASE_RESOLVE:-}"

die() { echo "base-check.sh: error: $*" >&2; exit 1; }
for t in curl jq tar sha256sum; do command -v "${t}" >/dev/null 2>&1 || die "${t} is required and not on PATH"; done
sha() { sha256sum "$1" | cut -d' ' -f1; }

# 1. The pin.
verified="$("${REPO_ROOT}/bin/mica-tools" locks verify)" || die "locks/ does not verify against the releases: ${verified}"
TAG="$(awk -F'\t' '$1 == "release" { print $3 }' "${LOCK}")"

# Under the repository, so a sibling build container can mount it.
mkdir -p "${REPO_ROOT}/_out"
WORK="$(mktemp -d "${REPO_ROOT}/_out/base-check.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
get() { # <url> <out> [curl args]
    local url="$1" out="$2"
    shift 2
    curl -fsSL --max-time 600 -o "${out}" "$@" "${url}" || die "downloading ${url} failed"
}

# 2. The roots' dpkg status.
if [ "${REGISTRY#file://}" = "${REGISTRY}" ]; then
    token="$(curl -fsS --max-time 60 "https://ghcr.io/token?scope=repository:${REPO}:pull&service=ghcr.io" | jq -r '.token // empty')"
    [ -n "${token}" ] || die "no anonymous pull token for ghcr.io/${REPO}"
    printf 'Authorization: Bearer %s\n' "${token}" >"${WORK}/registry-auth"
else
    : >"${WORK}/registry-auth"
fi
for arch in amd64 arm64; do
    ref="$(awk -F'\t' -v a="${arch}" '$1 == "image" && $2 == "mica-system-base" && $3 == "rootfs" && $4 == a { print $5 }' "${LOCK}")"
    [[ "${ref}" =~ ^ghcr\.io/${REPO}@(sha256:[0-9a-f]{64})$ ]] || die "locks/mica-system-base.lock names the ${arch} rootfs as '${ref}', not a digest reference of ghcr.io/${REPO}"
    manifest="${BASH_REMATCH[1]}"
    get "${REGISTRY}/v2/${REPO}/manifests/${manifest}" "${WORK}/manifest-${arch}.json" -H 'Accept: application/vnd.oci.image.manifest.v1+json' -H @"${WORK}/registry-auth"
    [ "sha256:$(sha "${WORK}/manifest-${arch}.json")" = "${manifest}" ] || die "the ${arch} Base rootfs manifest does not hash to ${manifest}"
    : >"${WORK}/status-${arch}"
    while IFS= read -r layer; do
        get "${REGISTRY}/v2/${REPO}/blobs/${layer}" "${WORK}/layer" -H @"${WORK}/registry-auth"
        [ "sha256:$(sha "${WORK}/layer")" = "${layer}" ] || die "a layer of the ${arch} Base rootfs does not hash to ${layer}"
        tar -xzOf "${WORK}/layer" ./var/lib/dpkg/status >"${WORK}/layer-status" 2>/dev/null || true
        [ ! -s "${WORK}/layer-status" ] || cp "${WORK}/layer-status" "${WORK}/status-${arch}"
    done < <(jq -r '.layers[].digest' "${WORK}/manifest-${arch}.json")
    [ -s "${WORK}/status-${arch}" ] || die "the ${arch} Base rootfs carries no var/lib/dpkg/status"
done

# 3. apt in the build image, the Base apt rows alone, against a root's status.
mkdir -p "${WORK}/sources.d"
awk -F'\t' '$1 == "apt" { printf "%sTypes: deb\nURIs: %s\nSuites: %s\nComponents: %s\nCheck-Valid-Until: no\nSigned-By: %s\n", (n++ ? "\n" : ""), $2, $3, $4, $5 }' \
    "${LOCK}" >"${WORK}/sources.d/mica-system-base.sources"
[ -s "${WORK}/sources.d/mica-system-base.sources" ] || die "locks/mica-system-base.lock has no apt row"
sed 's/#.*//; /^[[:space:]]*$/d' "${ROOTS}" >"${WORK}/roots"
[ -s "${WORK}/roots" ] || die "deb/debian-depends names no package"
apt_resolve() { # <arch> <work>: package, arch, version, sha256, url of each archive the root lacks
    local image
    image="$("${REPO_ROOT}/bin/mica-tools" from --ref mica-build-env:base)"
    docker run --rm --label ai-agent=true --platform linux/amd64 -v "$2:/w:ro" "${image}" bash -euo pipefail -c '
        arch="$1"
        o=(-o Dir::Etc::sourcelist=/dev/null -o Dir::Etc::sourceparts=/w/sources.d -o Dir::State::status="/w/status-${arch}"
           -o Dir::State::lists=/tmp/lists -o Dir::Cache=/tmp/cache -o APT::Architecture="${arch}" -o APT::Architectures="${arch}"
           -o Debug::NoLocking=1 -o Acquire::Languages=none)
        mkdir -p /tmp/lists/partial /tmp/cache/archives/partial
        apt-get "${o[@]}" -qq update >&2
        mapfile -t uris < <(sed -n "s/^URIs: //p" /w/sources.d/mica-system-base.sources)
        apt-get "${o[@]}" install --print-uris --no-install-recommends -qq $(cat /w/roots) | while read -r url file _ _; do
            # The source apt fetches it from; the URL it prints is percent-encoded, the index Filename is not.
            uri=""
            for u in "${uris[@]}"; do [[ "${url}" != "'"'"'${u}/"* ]] || uri="${u}"; done
            [ -n "${uri}" ] || { echo "apt fetches ${url} from no apt row" >&2; exit 1; }
            name="${file%%_*}"; version="${file#*_}"; version="${version%_*}"; version="$(printf "%b" "${version//%/\\x}")"
            show="$(apt-cache "${o[@]}" show "${name}=${version}")"
            # First line without a pipe: an early-exiting head would SIGPIPE sed under pipefail.
            sha="$(sed -n "s/^SHA256: //p" <<<"${show}")"; sha="${sha%%$'"'"'\n'"'"'*}"
            file_path="$(sed -n "s/^Filename: //p" <<<"${show}")"; file_path="${file_path%%$'"'"'\n'"'"'*}"
            printf "%s\t%s\t%s\t%s\t%s/%s\n" "${name}" "${arch}" "${version}" "${sha}" "${uri}" "${file_path}"
        done' _ "$1"
}

# 4. Every archive the root lacks: any upstream row of the Base lock, or our source row.
rows() { awk -F'\t' '!/^#/ && NF' "$1" | LC_ALL=C sort; }
awk -F'\t' '$1 == "upstream" { print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 }' "${LOCK}" | LC_ALL=C sort >"${WORK}/base-rows"
# The engine's build closure (pins/<stage>.<arch>, tools/dev-pins.sh) is a build input, not a
# runtime record, even where its snapshot is the Base apt URI.
for f in "${REPO_ROOT}"/pins/*.amd64 "${REPO_ROOT}"/pins/*.arm64; do
    [ -f "${f}" ] && sed "s/\$/\t${f##*.}/" "${f}"
done >"${WORK}/closure"
awk -F'\t' 'FILENAME == ARGV[1] { if ($1 == "apt") u[$2 "/"] = 1; next }
    FILENAME == ARGV[2] { build[$1 "\t" $2] = 1; next }
    $1 == "source" && !(($2 "\t" $3) in build) { for (p in u) if (index($6, p) == 1) { print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6; break } }' \
    "${LOCK}" "${WORK}/closure" "${RECORD}" | LC_ALL=C sort >"${WORK}/recorded"
: >"${WORK}/resolved-all"
bad=0
for arch in amd64 arm64; do
    if [ -n "${RESOLVE}" ]; then
        "${RESOLVE}" "${arch}" "${WORK}" >"${WORK}/resolved-${arch}"
    else
        apt_resolve "${arch}" "${WORK}" >"${WORK}/resolved-${arch}"
    fi
    rows "${WORK}/resolved-${arch}" >"${WORK}/resolved-${arch}.sorted"
    cat "${WORK}/resolved-${arch}.sorted" >>"${WORK}/resolved-all"
    from_base="$(comm -12 "${WORK}/resolved-${arch}.sorted" "${WORK}/base-rows" | grep -c . || true)"
    ours="$(comm -23 "${WORK}/resolved-${arch}.sorted" "${WORK}/base-rows" | comm -12 - "${WORK}/recorded" | grep -c . || true)"
    unrecorded="$(comm -23 "${WORK}/resolved-${arch}.sorted" "${WORK}/base-rows" | comm -23 - "${WORK}/recorded")"
    if [ -n "${unrecorded}" ]; then
        printf 'base-check.sh: error: %s: not pinned by mica-system-base %s and not recorded here; record it as a source row of locks/upstream.lock or ask Base to add it under options:\n%s\n' "${arch}" "${TAG}" "${unrecorded}" >&2
        bad=1
    else
        echo "base-check.sh: ${arch}: $(grep -c . "${WORK}/resolved-${arch}.sorted" || true) archive(s) the root lacks, ${from_base} pinned by mica-system-base, ${ours} recorded in locks/upstream.lock (mica-system-base ${TAG})"
    fi
done
# 5. The declared Depends against what the root ships and the Base lock pins.
CONTROL="${REPO_ROOT}/deb/mica-docker.control"
[ -f "${CONTROL}" ] || die "${CONTROL} does not exist"
for arch in amd64 arm64; do
    # name<TAB>version of everything available to this architecture's root.
    { awk '/^Package: /{p=$2} /^Version: /{if (p != "") {print p "\t" $2; p=""}}' "${WORK}/status-${arch}"
      awk -F'\t' -v a="${arch}" '$2 == a { print $1 "\t" $3 }' "${WORK}/base-rows"
    } | LC_ALL=C sort -u >"${WORK}/available-${arch}"
    while IFS= read -r dep; do
        [ -n "${dep}" ] || continue
        name="${dep%% *}"
        case "${name}" in mica-*) continue ;; esac
        floor=""
        case "${dep}" in *'(>= '*) floor="${dep#*(>= }"; floor="${floor%)}" ;; esac
        got="$(awk -F'\t' -v n="${name}" '$1 == n { print $2; exit }' "${WORK}/available-${arch}")"
        [ -n "${got}" ] || {
            printf 'base-check.sh: error: %s: deb/mica-docker.control depends on %s, which mica-system-base %s does not pin and the root does not ship\n' "${arch}" "${name}" "${TAG}" >&2
            bad=1
            continue
        }
        [ -z "${floor}" ] || dpkg --compare-versions "${got}" ge "${floor}" || {
            printf 'base-check.sh: error: %s: deb/mica-docker.control needs %s (>= %s), and mica-system-base %s pins %s\n' "${arch}" "${name}" "${floor}" "${TAG}" "${got}" >&2
            bad=1
        }
    done < <(sed -n 's/^Depends: //p' "${CONTROL}" | tr ',' '\n' | sed 's/^ *//; s/ *$//')
    [ "${bad}" -ne 0 ] || echo "base-check.sh: ${arch}: every declared Depends is satisfied by mica-system-base ${TAG}"
done

stale="$(LC_ALL=C sort "${WORK}/resolved-all" | comm -13 - "${WORK}/recorded")"
if [ -n "${stale}" ]; then
    printf 'base-check.sh: error: locks/upstream.lock records %s, which no longer resolves against mica-system-base %s\n' "${stale}" "${TAG}" >&2
    bad=1
fi
[ "${bad}" -eq 0 ]
