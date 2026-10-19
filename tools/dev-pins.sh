#!/usr/bin/env bash
# The Debian packages the engine stages link against, pinned by sha256 instead
# of installed from a live archive
# (mica-build-tools:docs/spec/package-versions.md; the shape mica-system-base
# uses for its own build closures). Each stage of the engine Dockerfile declares
# its roots in pins/<stage>.roots; this resolves their closure against the
# mica-build-env image that stage builds FROM, writes one `source` row per
# archive in locks/upstream.lock and the names of each stage's closure in
# pins/<stage>.<arch>. The build installs those archives with dpkg.
#
#   bash tools/dev-pins.sh check                   the rows still belong to the pinned build-env images (offline)
#   bash tools/dev-pins.sh resolve                 re-resolve every stage and architecture (network, docker)
#   bash tools/dev-pins.sh shas <stage> <arch>     the sha256 of that closure, in install order
#   bash tools/dev-pins.sh fetch <arch> <dir>      every archive of that architecture into <dir>/<sha256>.deb
#
# The closure is what the image lacks, so it is valid for one mica-build-env
# release: pins/resolved-for records the release and the image digests it was
# resolved against, and `check` refuses a build whose build-env lock names
# others. Moving to another build-env release re-resolves it.
set -euo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="${REPO_ROOT}/locks/upstream.lock"
PINS="${REPO_ROOT}/pins"
STAGES=(go)
die() { echo "dev-pins.sh: error: $*" >&2; exit 1; }

# The Debian snapshot these build packages come from (pins/snapshot). It is not
# the Base apt row: the build-env images carry packages newer than the root's
# snapshot, so apt would resolve downgrades against them.
apt_source() {
    sed 's/#.*//; /^[[:space:]]*$/d' "${PINS}/snapshot"
}

# rows <arch>: the source rows of locks/upstream.lock for that architecture.
rows() { awk -F'\t' -v a="$2" '$1 == "source" && $3 == a' "${1}"; }

# resolved_for: the build-env release and stage image digests of locks/mica-build-env.lock.
resolved_for() {
    local lock="${REPO_ROOT}/locks/mica-build-env.lock" stage
    printf '# The mica-build-env release and images the closure below was resolved against.\n'
    printf '# tools/dev-pins.sh check refuses a build when locks/mica-build-env.lock names others.\n'
    printf 'RELEASE=%s\n' "$(awk -F'\t' '$1 == "release" { print $3 }' "${lock}")"
    for stage in "${STAGES[@]}"; do
        printf 'IMAGE_%s=%s\n' "${stage^^}" "$("${REPO_ROOT}/bin/mica-tools" from --ref "mica-build-env:${stage}")"
    done
    apt_source | sed 's/^/SNAPSHOT=/'
}

case "${1:-}" in
check)
    [ "$#" -eq 1 ] || die "usage: bash tools/dev-pins.sh check"
    [ -f "${PINS}/resolved-for" ] || die "pins/resolved-for does not exist; run bash tools/dev-pins.sh resolve"
    diff="$(diff <(cat "${PINS}/resolved-for") <(resolved_for) || true)"
    [ -z "${diff}" ] || die "the pinned build closure was resolved against other inputs than this tree names:
${diff}
Re-resolve it: bash tools/dev-pins.sh resolve"
    for stage in "${STAGES[@]}"; do
        for arch in amd64 arm64; do
            [ -s "${PINS}/${stage}.${arch}" ] || die "pins/${stage}.${arch} is missing or empty; run bash tools/dev-pins.sh resolve"
            bash "${REPO_ROOT}/tools/dev-pins.sh" shas "${stage}" "${arch}" >/dev/null
        done
    done
    echo "dev-pins.sh: the pinned build closure belongs to mica-build-env $(sed -n 's/^RELEASE=//p' "${PINS}/resolved-for")"
    ;;
resolve)
    [ "$#" -eq 1 ] || die "usage: bash tools/dev-pins.sh resolve"
    command -v docker >/dev/null 2>&1 || die "docker is required"
    source_line="$(apt_source)"
    [ -n "${source_line}" ] || die "pins/snapshot names no Debian archive"
    WORK="$(mktemp -d "${REPO_ROOT}/_out/dev-pins.XXXXXX")"
    trap 'rm -rf "${WORK}"' EXIT
    : >"${WORK}/rows"
    host="$("${REPO_ROOT}/bin/mica-tools" from --ref mica-build-env:base)"
    for stage in "${STAGES[@]}"; do
        roots="$(sed 's/#.*//; /^[[:space:]]*$/d' "${PINS}/${stage}.roots" | tr '\n' ' ')"
        [ -n "${roots}" ] || die "pins/${stage}.roots names no package"
        image="$("${REPO_ROOT}/bin/mica-tools" from --ref "mica-build-env:${stage}")"
        for arch in amd64 arm64; do
            # The stage image's own dpkg status, copied out without running it.
            container="$(docker create --platform "linux/${arch}" "${image}" /bin/true)"
            docker cp "${container}:/var/lib/dpkg/status" "${WORK}/status" >/dev/null
            docker rm -f "${container}" >/dev/null
            printf '%s\n' "${source_line}" >"${WORK}/sources.list"
            docker run --rm --label ai-agent=true --platform linux/amd64 -v "${WORK}:/w" -e "ARCH=${arch}" -e "ROOTS=${roots}" "${host}" bash -euo pipefail -c '
                o=(-o Dir::Etc::SourceList=/w/sources.list -o Dir::Etc::SourceParts=- -o Dir::State::status=/w/status
                   -o Dir::State::Lists=/tmp/lists -o Dir::Cache=/tmp/cache -o APT::Architecture="${ARCH}" -o APT::Architectures="${ARCH}"
                   -o Debug::NoLocking=1 -o Acquire::Languages=none)
                mkdir -p /tmp/lists/partial /tmp/cache/archives/partial
                apt-get "${o[@]}" -qq update >&2
                apt-get "${o[@]}" install --print-uris -qq --no-install-recommends ${ROOTS} | while read -r url file _ _; do
                    url="${url:1:${#url}-2}"  # apt prints the URL in single quotes
                    name="${file%%_*}"; version="${file#*_}"; version="${version%_*}"; version="$(printf "%b" "${version//%/\\x}")"
                    show="$(apt-cache "${o[@]}" show --no-all-versions "${name}:${ARCH}=${version}")"
                    sha="$(sed -n "s/^SHA256: //p" <<<"${show}")"; sha="${sha%%$'"'"'\n'"'"'*}"
                    printf "%s\t%s\t%s\t%s\t%s\n" "${name}" "${ARCH}" "${version}" "${sha}" "${url}"
                done' >"${WORK}/${stage}-${arch}"
            [ -s "${WORK}/${stage}-${arch}" ] || die "apt resolved nothing for ${stage} ${arch}"
            # The install order apt printed, which dpkg then takes in one call.
            cut -f1 "${WORK}/${stage}-${arch}" >"${PINS}/${stage}.${arch}"
            cat "${WORK}/${stage}-${arch}" >>"${WORK}/rows"
            echo "dev-pins.sh: ${stage} ${arch}: $(wc -l <"${PINS}/${stage}.${arch}") archives"
        done
    done
    # One row per archive, shared where two stages need the same one.
    sort -u "${WORK}/rows" | awk -F'\t' '{ print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 }' >"${WORK}/source-rows"
    dup="$(cut -f1,2 "${WORK}/source-rows" | sort | uniq -d)"
    [ -z "${dup}" ] || die "two versions resolve for the same package and architecture: ${dup}"
    {
        grep -v $'^source\t' "${LOCK}"
        sed 's/^/source\t/' "${WORK}/source-rows"
    } >"${WORK}/lock"
    # mica-lock v1 order: kinds as the spec lists them, then key.
    {
        head -n1 "${WORK}/lock"
        grep '^#' <(tail -n +2 "${WORK}/lock") || true
        grep $'^image\t' "${WORK}/lock" | sort || true
        grep $'^source\t' "${WORK}/lock" | sort -t$'\t' -k2,2 -k3,3 || true
        grep $'^git\t' "${WORK}/lock" | sort -t$'\t' -k2,2 || true
    } >"${LOCK}"
    checked="$("${REPO_ROOT}/bin/mica-tools" upstream check "${LOCK}" 2>&1 || true)"
    [ "${checked}" = valid ] || die "the rewritten locks/upstream.lock is ${checked}"
    resolved_for >"${PINS}/resolved-for"
    echo "dev-pins.sh: locks/upstream.lock carries $(rows "${LOCK}" amd64 | wc -l) amd64 and $(rows "${LOCK}" arm64 | wc -l) arm64 source rows"
    ;;
shas)
    [ "$#" -eq 3 ] || die "usage: bash tools/dev-pins.sh shas <stage> <arch>"
    [ -f "${PINS}/${2}.${3}" ] || die "pins/${2}.${3} does not exist; run bash tools/dev-pins.sh resolve"
    while IFS= read -r name; do
        [ -n "${name}" ] || continue
        sha="$(awk -F'\t' -v n="${name}" -v a="${3}" '$1 == "source" && $2 == n && $3 == a { print $5 }' "${LOCK}")"
        [ -n "${sha}" ] || die "locks/upstream.lock has no source row for ${name} ${3}"
        printf '%s\n' "${sha}"
    done <"${PINS}/${2}.${3}"
    ;;
fetch)
    [ "$#" -eq 3 ] || die "usage: bash tools/dev-pins.sh fetch <arch> <dir>"
    mkdir -p "${3}"
    n=0
    while IFS=$'\t' read -r _ name arch version sha url; do
        [ "${arch}" = "${2}" ] || continue
        out="${3}/${sha}.deb"
        if [ ! -f "${out}" ]; then
            curl -fsSL --retry 3 --max-time 600 -o "${out}.part" "${url}" || die "downloading ${url} failed"
            got="$(sha256sum "${out}.part" | cut -d' ' -f1)"
            [ "${got}" = "${sha}" ] || { rm -f "${out}.part"; die "${name} ${version} ${arch} downloads with sha256 ${got}, and locks/upstream.lock pins ${sha}"; }
            mv "${out}.part" "${out}"
        elif [ "$(sha256sum "${out}" | cut -d' ' -f1)" != "${sha}" ]; then
            die "${out} does not hash to ${sha}; delete it and run again"
        fi
        n=$((n + 1))
    done < <(rows "${LOCK}" "${2}")
    [ "${n}" -gt 0 ] || die "locks/upstream.lock has no source row for ${2}"
    echo "dev-pins.sh: ${n} pinned archive(s) for ${2} in ${3}"
    ;;
*)
    die "usage: bash tools/dev-pins.sh resolve | shas <stage> <arch> | fetch <arch> <dir>"
    ;;
esac
