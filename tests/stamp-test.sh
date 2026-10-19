#!/usr/bin/env bash
# tools/stamp.sh and the checks tools/package.sh runs before any docker call,
# against a fixture _out/engine/<arch> of host ELF files: a stale, unstamped or
# incomplete directory is refused by name and never packed.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT=$PWD
mkdir -p "$REPO_ROOT/_out"
TMP=$(mktemp -d "$REPO_ROOT/_out/stamp-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
PASS_N=0 FAIL_N=0
pass() { PASS_N=$((PASS_N + 1)); echo "PASS: $*"; }
fail() { FAIL_N=$((FAIL_N + 1)); echo "FAIL: $*"; }
says() { case "$1" in *"$2"*) return 0;; *) return 1;; esac; }

case "$(uname -m)" in
x86_64) ARCH=amd64 ELF=x86-64 ;;
aarch64 | arm64) ARCH=arm64 ELF=aarch64 ;;
*) echo "error: no fixture architecture for $(uname -m)" >&2; exit 1 ;;
esac
HOST_ELF=""
for c in /bin/true /usr/bin/true /bin/ls /usr/bin/ls; do
    case "$(file -bL "${c}" 2>/dev/null)" in *"ELF 64-bit"*"${ELF}"*) HOST_ELF="${c}"; break ;; esac
done
[ -n "${HOST_ELF}" ] || { echo "error: no ${ELF} ELF found on this host for the fixture" >&2; exit 1; }

FIX="$TMP/fixture"
OUT="$FIX/_out/engine/$ARCH"
mkdir -p "$FIX/tools" "$FIX/bin" "$FIX/locks" "$FIX/deb" "$OUT" "$TMP/bin"
cp locks/upstream.lock locks/mica-build-env.lock "$FIX/locks/"
cp deb/mica-docker.control "$FIX/deb/"
cp tools/stamp.sh tools/package.sh tools/buildx.sh "$FIX/tools/"
cp tests/mica-tools-stub.sh "$FIX/bin/mica-tools"
BINARIES=(dockerd docker-proxy docker docker-compose containerd containerd-shim-runc-v2 runc docker-init)
for b in "${BINARIES[@]}"; do cp "$HOST_ELF" "$OUT/$b"; done
# Any docker call is recorded: packing starts only after every check passed.
printf '#!/bin/sh\necho "$@" >>"%s/docker.calls"\nexit 99\n' "$TMP" >"$TMP/bin/docker"
chmod +x "$TMP/bin/docker"

package() {
    RC=0
    rm -f "$TMP/docker.calls"
    OUT_TEXT=$(PATH="$TMP/bin:$PATH" bash "$FIX/tools/package.sh" --arch "$ARCH" 2>&1) || RC=$?
}
stamp() { bash "$FIX/tools/stamp.sh" "$@" 2>&1; }

stamp --stamp "$OUT" >/dev/null
if cmp -s "$OUT/upstream.lock" "$FIX/locks/upstream.lock"; then pass "S1 --stamp records locks/upstream.lock unchanged"; else fail "S1 $(ls "$OUT")"; fi

if stamp --check "$OUT" >/dev/null; then pass "S2 a freshly stamped directory passes --check"; else fail "S2 $(stamp --check "$OUT")"; fi

sed -i 's/^Source-Date-Epoch: .*/Source-Date-Epoch: 1800000000/' "$FIX/deb/mica-docker.control"
if stamp --check "$OUT" >/dev/null; then pass "S2b an epoch bump alone keeps the directory (the engine embeds no build time)"; else fail "S2b $(stamp --check "$OUT")"; fi
cp deb/mica-docker.control "$FIX/deb/"

sed -i 's/^\(git\trunc\t[^\t]*\t\)[^\t]*/\1v1.99.9/' "$FIX/locks/upstream.lock"
RC=0; T="$(stamp --check "$OUT")" || RC=$?
if [ "$RC" -ne 0 ] && says "$T" "was built from a different locks/upstream.lock" && says "$T" "v1.99.9"; then
    pass "S3 a version bump makes the directory refuse, showing the difference"
else fail "S3 rc=$RC: $T"; fi

package
if [ "$RC" -ne 0 ] && says "$OUT_TEXT" "was built from a different locks/upstream.lock" && [ ! -e "$TMP/docker.calls" ]; then
    pass "S4 package.sh refuses a stale directory before any docker call"
else fail "S4 rc=$RC: $OUT_TEXT"; fi

cp locks/upstream.lock "$FIX/locks/"
package
if [ -e "$TMP/docker.calls" ] && ! says "$OUT_TEXT" "different" && ! says "$OUT_TEXT" "missing"; then
    pass "S5 a current, complete directory passes every check and reaches docker"
else fail "S5 rc=$RC: $OUT_TEXT"; fi

rm -f "$OUT/upstream.lock"
package
if [ "$RC" -ne 0 ] && says "$OUT_TEXT" "carries no upstream.lock" && [ ! -e "$TMP/docker.calls" ]; then
    pass "S6 an unstamped directory is refused"
else fail "S6 rc=$RC: $OUT_TEXT"; fi
stamp --stamp "$OUT" >/dev/null

rm -f "$OUT/runc"
package
if [ "$RC" -ne 0 ] && says "$OUT_TEXT" "runc" && says "$OUT_TEXT" "make engine" && [ ! -e "$TMP/docker.calls" ]; then
    pass "S7 a missing binary is refused with the command that builds it"
else fail "S7 rc=$RC: $OUT_TEXT"; fi

echo "text" >"$OUT/runc"
package
if [ "$RC" -ne 0 ] && says "$OUT_TEXT" "is not an ${ELF} ELF" && [ ! -e "$TMP/docker.calls" ]; then
    pass "S8 a binary of another architecture is refused"
else fail "S8 rc=$RC: $OUT_TEXT"; fi

cp "$HOST_ELF" "$OUT/runc"
sed -i 's/^Version: .*/Version: 9.9.9-1/' "$FIX/deb/mica-docker.control"
package
if [ "$RC" -ne 0 ] && says "$OUT_TEXT" "its upstream part 9.9.9 is not the moby tag" && [ ! -e "$TMP/docker.calls" ]; then
    pass "S9 a declared Version whose upstream part is not the pinned moby tag is refused"
else fail "S9 rc=$RC: $OUT_TEXT"; fi
cp deb/mica-docker.control "$FIX/deb/"

echo "RESULT: $FAIL_N failed, $PASS_N passed"
[ "$FAIL_N" -eq 0 ]
