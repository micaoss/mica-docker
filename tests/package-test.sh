#!/usr/bin/env bash
# The package metadata and naming: every control template is maintained by
# Mica OS, the copyright header names Mica OS, and no tracked file or path
# carries the disallowed project name (the pattern below spells it as m[o]s so this
# file does not carry it either).
set -euo pipefail
cd "$(dirname "$0")/.."

PASS_N=0 FAIL_N=0
pass() { PASS_N=$((PASS_N + 1)); echo "PASS: $*"; }
fail() { FAIL_N=$((FAIL_N + 1)); echo "FAIL: $*"; }

MAINTAINER='Maintainer: Mica OS <hi@micaos.dev>'
mapfile -t controls < <(git ls-files 'deb/*.control')
[ "${#controls[@]}" -gt 0 ] || { echo "error: no control template found" >&2; exit 1; }
for f in "${controls[@]}"; do
    got="$(grep '^Maintainer:' "${f}" || true)"
    if [ "${got}" = "${MAINTAINER}" ]; then pass "${f} is maintained by Mica OS"; else fail "${f}: '${got}'"; fi
done

for field in 'Upstream-Name: Mica OS' 'Upstream-Contact: Mica OS <hi@micaos.dev>'; do
    if grep -cxF "${field}" deb/copyright >/dev/null; then pass "copyright carries ${field}"; else fail "copyright lacks ${field}"; fi
done

DISALLOWED='(^|[^a-z0-9])m[o]s([^a-z0-9]|$)'
hits="$(git grep -nIiE "${DISALLOWED}" || true)$(git ls-files | grep -iE "${DISALLOWED}" || true)"
if [ -z "${hits}" ]; then pass "no tracked file or path carries the disallowed project name"; else fail "the disallowed project name remains:
${hits}"; fi

echo "RESULT: ${FAIL_N} failed, ${PASS_N} passed"
[ "${FAIL_N}" -eq 0 ]
