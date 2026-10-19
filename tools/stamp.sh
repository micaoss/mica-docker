#!/usr/bin/env bash
# Record which locks/upstream.lock _out/engine/<arch> was built from, and refuse a
# stale one. The engine embeds no build time, so SOURCE_DATE_EPOCH is the pack's alone.
#
#   bash tools/stamp.sh --stamp <dir>   # write <dir>/upstream.lock (locks/upstream.lock unchanged)
#   bash tools/stamp.sh --check <dir>   # refuse a missing or different stamp
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="${REPO_ROOT}/locks/upstream.lock"
die() { echo "stamp.sh: error: $*" >&2; exit 1; }
[ -f "${LOCK}" ] || die "${LOCK} does not exist"

[ "$#" -eq 2 ] && [ -d "$2" ] || die "usage: bash tools/stamp.sh --stamp|--check <dir>"
case "$1" in
--stamp)
    cp "${LOCK}" "$2/upstream.lock"
    ;;
--check)
    rebuild="MICA_ARCH=$(basename "$2") make engine"
    [ -f "$2/upstream.lock" ] || die "$2 carries no upstream.lock, so its binaries cannot be matched to locks/upstream.lock; rebuild: ${rebuild}"
    cmp -s "$2/upstream.lock" "${LOCK}" || die "$2 was built from a different locks/upstream.lock than the one in this tree:
$(diff "$2/upstream.lock" "${LOCK}" | grep '^[<>]' || true)
Rebuild -- ${rebuild} -- or restore locks/upstream.lock."
    ;;
*) die "usage: bash tools/stamp.sh --stamp|--check <dir>" ;;
esac
