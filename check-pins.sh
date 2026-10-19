#!/usr/bin/env bash
# Fail when a git pin of locks/upstream.lock has a newer upstream release. Reads, never writes;
# tools/upgrade.sh moves the pins it reports.
#
#   bash check-pins.sh                    # live, needs network
#   bash check-pins.sh --releases-dir DIR # against recorded JSON
#
# The tag prefix is taken from the pin (moby tags the engine docker-v<version>);
# every tree is compared with its newest release, whatever its major; release age
# is never a verdict. docker/cli publishes tags and no GitHub releases, so its tags
# are read instead, and a tag with a suffix (-rc.1) is not a release.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

UPSTREAM_LOCK="${HERE}/locks/upstream.lock"
RELEASES_DIR=""

usage() {
    cat >&2 <<'USAGE'
usage: check-pins.sh [--releases-dir DIR] [--upstream-lock FILE]

  --releases-dir DIR   read DIR/<component>.json instead of fetching from
                       GitHub; the fixture path used by the test suite
  --upstream-lock FILE read FILE instead of locks/upstream.lock

Exit status: 0 every pin is current, 1 at least one pin is behind, 2 the check
could not be carried out (a missing pin, an unreachable upstream, a component
with nothing comparable to compare against).
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --releases-dir) RELEASES_DIR="${2:?--releases-dir needs a directory}"; shift 2 ;;
        --upstream-lock) UPSTREAM_LOCK="${2:?--upstream-lock needs a file}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown argument '$1'" >&2; usage; exit 2 ;;
    esac
done

[ -f "${UPSTREAM_LOCK}" ] || { echo "error: ${UPSTREAM_LOCK} not found" >&2; exit 2; }

# component (the git row's name) | upstream repository | releases or tags
COMPONENTS=(
    "moby|moby/moby|releases"
    "cli|docker/cli|tags"
    "compose|docker/compose|releases"
    "containerd|containerd/containerd|releases"
    "runc|opencontainers/runc|releases"
    "tini|krallin/tini|releases"
)

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

if [ -n "${RELEASES_DIR}" ]; then
    [ -d "${RELEASES_DIR}" ] || { echo "error: --releases-dir ${RELEASES_DIR} is not a directory" >&2; exit 2; }
    echo "reading recorded upstream responses from ${RELEASES_DIR} (no network)"
else
    # -L: a moved repository answers 301. -f: a rate limit is a failed check.
    echo "asking six upstreams for their releases"
    for row in "${COMPONENTS[@]}"; do
        IFS='|' read -r name repo kind <<< "${row}"
        headers=(-H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28')
        [ -z "${GITHUB_TOKEN:-}" ] || headers+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
        curl -fsSL --max-time 60 \
            "${headers[@]}" \
            "https://api.github.com/repos/${repo}/${kind}?per_page=100" \
            -o "${WORK}/${name}.${kind}.json" \
            || { echo "error: could not read ${kind} for ${repo}. The check did not run; this is not a pass." >&2; exit 2; }
        # A tag is read as a published release of that name.
        if [ "${kind}" = tags ]; then
            python3 -c 'import json, sys; json.dump([{"tag_name": t["name"]} for t in json.load(open(sys.argv[1]))], open(sys.argv[2], "w"))' \
                "${WORK}/${name}.${kind}.json" "${WORK}/${name}.json"
        else
            mv "${WORK}/${name}.${kind}.json" "${WORK}/${name}.json"
        fi
    done
    RELEASES_DIR="${WORK}"
fi

rc=0
python3 - "${UPSTREAM_LOCK}" "${RELEASES_DIR}" "${COMPONENTS[@]}" <<'PY' || rc=$?
import json
import os
import re
import sys

upstream_lock, releases_dir = sys.argv[1], sys.argv[2]
rows = [r.split("|")[:2] for r in sys.argv[3:]]

# The tag of each git row: git <name> <url> <ref> <commit>.
pins = {}
with open(upstream_lock, encoding="utf-8") as fh:
    for line in fh:
        cols = line.rstrip("\n").split("\t")
        if cols[0] == "git" and len(cols) == 5:
            pins[cols[1]] = cols[3]

TAG_CORE = re.compile(r"^(\d+(?:\.\d+)*)$")


def core(tag, prefix):
    """The dotted-numeric core of TAG when it carries exactly PREFIX, else None."""
    if not tag.startswith(prefix):
        return None
    m = TAG_CORE.match(tag[len(prefix):])
    return tuple(int(p) for p in m.group(1).split(".")) if m else None


def newer(a, b):
    """Numeric, component-wise, zero-padded: 1.10 is above 1.9, and 1.29 below 1.29.1."""
    width = max(len(a), len(b))
    return a + (0,) * (width - len(a)) > b + (0,) * (width - len(b))


def show(v):
    return ".".join(str(p) for p in v)


behind, errors = [], []
lines = []

for name, repo in rows:
    pin = pins.get(name)
    if not pin:
        errors.append(f"{name}: {upstream_lock} has no git row for {name}")
        continue

    prefix = re.match(r"^\D*", pin).group(0)
    pin_core = core(pin, prefix)
    if pin_core is None:
        errors.append(f"{name}: pinned tag '{pin}' is not <prefix><dotted numbers>; this check cannot compare it")
        continue

    path = os.path.join(releases_dir, f"{name}.json")
    try:
        with open(path, encoding="utf-8") as fh:
            releases = json.load(fh)
    except (OSError, ValueError) as exc:
        errors.append(f"{name}: cannot read {path}: {exc}")
        continue
    if not isinstance(releases, list) or not releases:
        errors.append(f"{name}: {path} holds no releases; an upstream with no releases is a failed read, not a current pin")
        continue

    published = {}
    comparable, skipped = {}, 0
    for rel in releases:
        if rel.get("draft") or rel.get("prerelease"):
            continue
        tag = rel.get("tag_name") or ""
        c = core(tag, prefix)
        if c is None:
            skipped += 1
            continue
        comparable[c] = tag
        published[c] = (rel.get("published_at") or "")[:10] or "?"

    if not comparable:
        errors.append(
            f"{name}: none of {len(releases)} upstream releases carry the pin's tag convention "
            f"('{prefix}' + dotted numbers, as in '{pin}'); {skipped} were skipped. Either upstream "
            f"changed how it tags or the pin did, and comparing nothing is not a pass"
        )
        continue

    if pin_core not in comparable:
        errors.append(
            f"{name}: the pinned tag '{pin}' is not among upstream's {len(comparable)} comparable releases. "
            f"A pin upstream does not publish cannot be checked for freshness"
        )
        continue

    top = max(comparable)
    if newer(top, pin_core):
        behind.append((name, pin, comparable[top], published.get(top, "?")))
        lines.append(f"BEHIND     {name:<13} {pin:<10} -> {comparable[top]} ({published.get(top, '?')})")
    else:
        lines.append(f"UNCHANGED  {name:<13} {pin:<10} newest upstream release, released {published.get(pin_core, '?')}"
                     + (f", {skipped} tag(s) skipped as a different convention" if skipped else ""))

print()
for line in lines:
    print(line)
print()

if len(lines) + len(errors) != len(rows):
    errors.append(f"internal: {len(rows)} components declared but {len(lines) + len(errors)} accounted for")

sys.stdout.flush()

if errors:
    for e in errors:
        print(f"error: {e}", file=sys.stderr)
    print(f"RESULT: FAILED ({len(errors)} component(s) could not be checked)", file=sys.stderr)
    sys.exit(2)

if behind:
    print(f"RESULT: BEHIND ({len(behind)} of {len(rows)} pins have a newer upstream release)", file=sys.stderr)
    print(file=sys.stderr)
    for name, pin, newest, date in behind:
        print(f"  {name}: pinned at {pin}, upstream released {newest} on {date}.", file=sys.stderr)
    print(file=sys.stderr)
    print("  To act on this: `make upgrade` moves every pin to its latest release and bumps the", file=sys.stderr)
    print("  package; the weekly upgrade workflow does the same and releases it when it is green.", file=sys.stderr)
    sys.exit(1)

print(f"RESULT: PASS (all {len(rows)} pins are at their newest upstream release)")
PY

exit "${rc}"
