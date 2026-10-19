#!/usr/bin/env bash
# A stand-in for bin/mica-tools in the fixture checkouts of tests/: the commands
# this repository's own scripts call, answered from the fixture's locks/ as
# mica-build-tools answers them. The tool itself is tested in mica-build-tools;
# these tests cover what the scripts here do with its answers. Each call is
# appended to $MICA_TOOLS_CALLS when that is set; STUB_LOCKS_VERIFY=<rule> makes
# `locks verify` refuse by that rule.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -z "${MICA_TOOLS_CALLS:-}" ] || echo "$*" >>"${MICA_TOOLS_CALLS}"
case "$*" in
sync) mkdir -p "${ROOT}/repos/mica-build-tools/bootstrap" && cp "${BASH_SOURCE[0]}" "${ROOT}/repos/mica-build-tools/bootstrap/mica-tools" ;;
"locks verify")
    [ -z "${STUB_LOCKS_VERIFY:-}" ] || { echo "refused ${STUB_LOCKS_VERIFY}"; exit 1; }
    echo "verified"
    ;;
"upstream check"*) echo valid ;;
"upstream get git "*" ref") awk -F'\t' -v n="$4" '$1 == "git" && $2 == n { print $4 }' "${ROOT}/locks/upstream.lock" ;;
"upstream get git "*" url") awk -F'\t' -v n="$4" '$1 == "git" && $2 == n { print $3 }' "${ROOT}/locks/upstream.lock" ;;
# Not the design's manifest: a hash of the inputs a fixture moves, which is what a caller compares.
"inputs deb "*) cat "${ROOT}/locks/upstream.lock" "${ROOT}"/pins/* 2>/dev/null | sha256sum | cut -d' ' -f1 ;;
# locks update: $STUB_LOCKS_UPDATE, one `<input> <from> -> <to>` line per move, each
# written to its pin as the tool writes it; every other input unchanged.
"locks update")
    moved="${STUB_LOCKS_UPDATE:-}"
    for input in mica-build-env mica-system-base; do
        line="$(grep "^${input} " <<<"${moved}" || true)"
        if [ -n "${line}" ]; then
            echo "${line}"
            sed -i "s/^RELEASE=.*/RELEASE=$(awk '{ print $4 }' <<<"${line}")/" "${ROOT}/locks/pins/${input}.pin"
        else
            echo "${input} $(sed -n 's/^RELEASE=//p' "${ROOT}/locks/pins/${input}.pin") unchanged"
        fi
    done
    line="$(grep '^mica-build-tools ' <<<"${moved}" || true)"
    [ -n "${line}" ] && echo "${line}" || echo "mica-build-tools $(sed -n 's/^COMMIT=//p' "${ROOT}/locks/mica-build-tools.pin") unchanged"
    ;;
"locks move "*) sed -i "s/^RELEASE=.*/RELEASE=$4/" "${ROOT}/locks/pins/$3.pin"; echo "locks/$3.lock and locks/pins/$3.pin: $3 $4" ;;
"from --ref mica-build-env:"*)
    ref="$(awk -F'\t' -v n="${3#mica-build-env:}" '$1 == "image" && $2 == "mica-build-env" && $3 == n && $4 == "index" { print $5 }' "${ROOT}/locks/mica-build-env.lock")"
    [ -n "${ref}" ] || { echo "error: locks/mica-build-env.lock names no index of ${3#mica-build-env:}" >&2; exit 1; }
    echo "${ref}"
    ;;
"from --ref upstream:"*)
    ref="$(awk -F'\t' -v n="${3#upstream:}" '$1 == "image" && $2 == "upstream" && $3 == n { print $5 }' "${ROOT}/locks/mica-build-env.lock" | sort -u)"
    [ -n "${ref}" ] && [ "$(wc -l <<<"${ref}")" -eq 1 ] || { echo "error: locks/mica-build-env.lock names ${3#upstream:} by no one reference" >&2; exit 1; }
    echo "${ref}"
    ;;
*) echo "error: tests/mica-tools-stub.sh does not answer: $*" >&2; exit 2 ;;
esac
