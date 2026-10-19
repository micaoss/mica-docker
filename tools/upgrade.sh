#!/usr/bin/env bash
# Move every pin to its latest release, the rule of README "Inputs", and bump the
# package when what decides its bytes moved.
#
#   bash tools/upgrade.sh    (network; docker when mica-build-env moves)
#
# 1. The six upstream trees: check-pins.sh names those behind, and each git row of
#    locks/upstream.lock takes the newest tag and the commit it peels to.
# 2. mica-build-env, mica-system-base and mica-build-tools: `mica-tools locks update`
#    moves each input of locks/ to its latest release, lock and pin together, and
#    locks/mica-build-tools.pin to the tool's latest release with its bootstrap as
#    bin/mica-tools, verifying everything before it writes anything.
# 3. After a mica-build-env move: pins/snapshot takes the Debian snapshot its images
#    install from (the debian-* source rows of its locks/upstream.lock at that
#    release), and the build closure is re-resolved (tools/dev-pins.sh resolve).
# 4. The component versions of deb/copyright and of the control's description
#    follow the git rows.
# 5. The package: a new moby tag sets Version <Docker version>-1; any other change
#    of `mica-tools inputs deb` bumps the revision; either sets Source-Date-Epoch to
#    the current minute.
#
# Prints one `upgrade.sh: <what> <from> -> <to>` line per move, then
# `upgrade.sh: changed` or `upgrade.sh: unchanged`.
set -euo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
TOOLS="${REPO_ROOT}/bin/mica-tools"
LOCK=locks/upstream.lock
CONTROL=deb/mica-docker.control
die() { echo "upgrade.sh: error: $*" >&2; exit 1; }
say() { echo "upgrade.sh: $*"; }
for t in curl git python3; do command -v "${t}" >/dev/null 2>&1 || die "${t} is required and not on PATH"; done

# A token lifts the anonymous API limit: GITHUB_TOKEN, GH_TOKEN, or gh's own login.
TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-$(gh auth token 2>/dev/null || true)}}"
peel() { # <url> <tag>: the commit the tag names
    local out
    out="$(git ls-remote "$1" "refs/tags/$2" "refs/tags/$2^{}")" || die "git ls-remote $1 failed"
    awk -v t="refs/tags/$2" '$2 == t "^{}" { p = $1 } $2 == t { l = $1 } END { print (p != "" ? p : l) }' <<<"${out}"
}

BEFORE="$("${TOOLS}" inputs deb amd64)"
MOBY_BEFORE="$("${TOOLS}" upstream get git moby ref)"
MOVED=0

# 1. The upstream trees.
set +e
pins="$(GITHUB_TOKEN="${TOKEN}" bash check-pins.sh 2>/dev/null)"
rc=$?
set -e
[ "${rc}" -ne 2 ] || die "check-pins.sh could not compare the upstream trees; run it for the reason"
while read -r _ name old _ new _; do
    url="$("${TOOLS}" upstream get git "${name}" url)"
    commit="$(peel "${url}" "${new}")"
    [[ "${commit}" =~ ^[0-9a-f]{40}$ ]] || die "${url} has no tag ${new}"
    awk -F'\t' -v OFS='\t' -v n="${name}" -v t="${new}" -v c="${commit}" \
        '$1 == "git" && $2 == n { $4 = t; $5 = c } { print }' "${LOCK}" >"${LOCK}.new" && mv "${LOCK}.new" "${LOCK}"
    say "${name} ${old} -> ${new} (${commit})"
    # 4. deb/copyright names each tree by its tag.
    sed -i "s|^\(Comment: .*\b${name} \)${old}\b|\1${new}|" deb/copyright
    MOVED=1
done < <(grep '^BEHIND ' <<<"${pins}" || true)

# 2. The inputs of locks/ and the tool itself.
ENV_MOVED=0
updated="$("${TOOLS}" locks update)" || die "mica-tools locks update failed"
while read -r input from arrow to rest; do
    [ "${arrow}" = "->" ] || continue
    say "${input} ${from} -> ${to}${rest:+ ${rest}}"
    [ "${input}" != mica-build-env ] || ENV_MOVED=1
    MOVED=1
done <<<"${updated}"

# 3. The build closure follows the build-env images.
if [ "${ENV_MOVED}" = 1 ]; then
    release="$(sed -n 's/^RELEASE=//p' locks/pins/mica-build-env.pin)"
    rows="$(curl -fsSL --retry 3 --max-time 60 "https://raw.githubusercontent.com/micaoss/mica-build-env/${release}/locks/upstream.lock")" ||
        die "reading locks/upstream.lock of mica-build-env ${release} failed"
    sources="$(awk -F'\t' '$1 == "source" && $2 ~ /^debian-/ {
            suite = substr($2, 8); uri = $6; sub(/\/dists\/.*/, "", uri)
            print "deb [check-valid-until=no] " uri " " suite " main" }' <<<"${rows}")"
    [ "$(grep -c . <<<"${sources}")" -ge 1 ] || die "mica-build-env ${release} pins no Debian snapshot"
    { sed -n '/^#/p' pins/snapshot | sed "s/mica-build-env images ([0-9-]*)/mica-build-env images (${release})/"
      printf '%s\n' "${sources}"; } >pins/snapshot.new
    mv pins/snapshot.new pins/snapshot
    bash tools/dev-pins.sh resolve >/dev/null
    say "pins/: the build closure re-resolved against mica-build-env ${release}"
fi

[ "${MOVED}" = 1 ] || { say unchanged; exit 0; }

# 4 and 5. The control: versions in the description, then Version and Source-Date-Epoch.
AFTER="$("${TOOLS}" inputs deb amd64)"
MOBY_AFTER="$("${TOOLS}" upstream get git moby ref)"
version="$(sed -n 's/^Version: //p' "${CONTROL}")"
if [ "${MOBY_AFTER}" != "${MOBY_BEFORE}" ]; then
    new_version="${MOBY_AFTER#docker-v}-1"
elif [ "${AFTER}" != "${BEFORE}" ]; then
    new_version="${version%-*}-$((${version##*-} + 1))"
else
    new_version="${version}"
fi
if [ "${new_version}" != "${version}" ]; then
    epoch="$(date -u -d "$(date -u +'%Y-%m-%d %H:%M'):00" +%s)"
    python3 - "${CONTROL}" "${new_version}" "${epoch}" \
        "$("${TOOLS}" upstream get git moby ref)" "$("${TOOLS}" upstream get git cli ref)" \
        "$("${TOOLS}" upstream get git compose ref)" "$("${TOOLS}" upstream get git containerd ref)" \
        "$("${TOOLS}" upstream get git runc ref)" "$("${TOOLS}" upstream get git tini ref)" <<'PY'
import re, sys, textwrap
path, version, epoch, *tags = sys.argv[1:]
moby, cli, compose, containerd, runc, tini = (re.sub(r"^(docker-)?v", "", t) for t in tags)
text = open(path, encoding="utf-8").read()
text = re.sub(r"(?m)^Version: .*$", f"Version: {version}", text)
text = re.sub(r"(?m)^Source-Date-Epoch: .*$", f"Source-Date-Epoch: {epoch}", text)
engine = (f"Docker {moby} (dockerd and the docker CLI)" if moby == cli
          else f"Docker {moby} (dockerd), the docker CLI {cli}")
head, sep, rest = text.partition("Description: Mica OS Docker engine\n")
para, dot, tail = rest.partition("\n .\n")
words = " ".join(line.strip() for line in para.splitlines())
words, n = re.subn(r"^Docker .*?, built from pinned upstream source,",
                   f"{engine}, docker compose {compose}, containerd {containerd}, runc {runc} "
                   f"and tini {tini} as docker-init, built from pinned upstream source,", words)
assert n == 1, "the description's first sentence is not the component list"
para = "\n".join(" " + line for line in textwrap.wrap(words, 76, break_on_hyphens=False))
open(path, "w", encoding="utf-8").write(head + sep + para + dot + tail)
PY
    say "mica-docker ${version} -> ${new_version}"
fi
say changed
