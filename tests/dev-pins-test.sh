#!/usr/bin/env bash
# tools/dev-pins.sh in a fixture checkout: the staleness gate, the sha256 list a
# stage installs, and the fetch that verifies every archive. Offline (file://).
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT=$PWD
mkdir -p _out
TMP=$(mktemp -d "$REPO_ROOT/_out/dev-pins-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
PASS_N=0 FAIL_N=0
pass() { PASS_N=$((PASS_N + 1)); echo "PASS: $*"; }
fail() { FAIL_N=$((FAIL_N + 1)); echo "FAIL: $*"; }
says() { case "$1" in *"$2"*) return 0;; *) return 1;; esac; }

FIX="$TMP/repo"
mkdir -p "$FIX/tools" "$FIX/bin" "$FIX/locks/pins" "$FIX/pins" "$TMP/archive"
cp tools/dev-pins.sh "$FIX/tools/"
cp tests/mica-tools-stub.sh "$FIX/bin/mica-tools"
cp locks/mica-build-env.lock "$FIX/locks/"
cp locks/pins/mica-build-env.pin "$FIX/locks/pins/"
printf 'deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/20990101T000000Z trixie main\ndeb [check-valid-until=no] https://snapshot.debian.org/archive/debian-security/20990101T000000Z trixie-security main\n' >"$FIX/pins/snapshot"
printf 'libfoo-dev\n' >"$FIX/pins/go.roots"
# Two archives, on disk, served over file://.
for n in libfoo libfoo-dev; do printf '%s archive\n' "$n" >"$TMP/archive/$n.deb"; done
SHA_FOO=$(sha256sum "$TMP/archive/libfoo.deb" | cut -d' ' -f1)
SHA_DEV=$(sha256sum "$TMP/archive/libfoo-dev.deb" | cut -d' ' -f1)
{
    printf '# mica-lock v1\n'
    printf 'source\tlibfoo\tamd64\t1-1\t%s\tfile://%s/libfoo.deb\n' "$SHA_FOO" "$TMP/archive"
    printf 'source\tlibfoo-dev\tamd64\t1-1\t%s\tfile://%s/libfoo-dev.deb\n' "$SHA_DEV" "$TMP/archive"
} >"$FIX/locks/upstream.lock"
printf 'libfoo\nlibfoo-dev\n' >"$FIX/pins/go.amd64"
for f in go.arm64; do printf 'libfoo\n' >"$FIX/pins/$f"; done
# The arm64 and other rows the check asks for.
{
    cat "$FIX/locks/upstream.lock"
    printf 'source\tlibfoo\tarm64\t1-1\t%s\tfile://%s/libfoo.deb\n' "$SHA_FOO" "$TMP/archive"
} >"$TMP/lock" && mv "$TMP/lock" "$FIX/locks/upstream.lock"
resolved() {
    {
        printf '# The mica-build-env release and images the closure below was resolved against.\n'
        printf '# tools/dev-pins.sh check refuses a build when locks/mica-build-env.lock names others.\n'
        printf 'RELEASE=%s\n' "$(awk -F'\t' '$1 == "release" { print $3 }' "$FIX/locks/mica-build-env.lock")"
        for s in go; do printf 'IMAGE_%s=%s\n' "$(echo "$s" | tr '[:lower:]' '[:upper:]')" "$("$FIX/bin/mica-tools" from --ref "mica-build-env:$s")"; done
        sed 's/#.*//; /^[[:space:]]*$/d; s/^/SNAPSHOT=/' "$FIX/pins/snapshot"
    } >"$FIX/pins/resolved-for"
}
resolved
run() { RC=0; OUT=$(bash "$FIX/tools/dev-pins.sh" "$@" 2>&1) || RC=$?; }

run check
if [ "$RC" -eq 0 ] && says "$OUT" "belongs to mica-build-env"; then pass "P1 a closure resolved against this tree's build-env images passes"; else fail "P1 rc=$RC: $OUT"; fi

sed -i 's/^IMAGE_GO=.*/IMAGE_GO=ghcr.io\/micaoss\/mica-build-env:go.20990101-0000@sha256:0000000000000000000000000000000000000000000000000000000000000000/' "$FIX/pins/resolved-for"
run check
if [ "$RC" -ne 0 ] && says "$OUT" "resolved against other inputs" && says "$OUT" "Re-resolve it"; then
    pass "P2 a build-env image other than the one the closure was resolved against is refused"
else fail "P2 rc=$RC: $OUT"; fi
resolved

sed -i 's|20990101T000000Z|20990202T000000Z|' "$FIX/pins/snapshot"
run check
if [ "$RC" -ne 0 ] && says "$OUT" "resolved against other inputs"; then pass "P3 another Debian snapshot than the closure was resolved from is refused"; else fail "P3 rc=$RC: $OUT"; fi
sed -i 's|20990202T000000Z|20990101T000000Z|' "$FIX/pins/snapshot"

run shas go amd64
if [ "$RC" -eq 0 ] && [ "$OUT" = "$(printf '%s\n%s' "$SHA_FOO" "$SHA_DEV")" ]; then pass "P4 shas lists the closure of a stage in install order"; else fail "P4 rc=$RC: $OUT"; fi

printf 'libfoo\nlibbar\n' >"$FIX/pins/go.amd64"
run shas go amd64
if [ "$RC" -ne 0 ] && says "$OUT" "no source row for libbar amd64"; then pass "P5 a stage naming a package the lock does not pin is refused"; else fail "P5 rc=$RC: $OUT"; fi
printf 'libfoo\nlibfoo-dev\n' >"$FIX/pins/go.amd64"

run fetch amd64 "$TMP/out"
if [ "$RC" -eq 0 ] && [ -f "$TMP/out/$SHA_FOO.deb" ] && [ -f "$TMP/out/$SHA_DEV.deb" ] && says "$OUT" "2 pinned archive(s) for amd64"; then
    pass "P6 fetch writes every archive of an architecture under its sha256"
else fail "P6 rc=$RC: $OUT"; fi

printf 'other bytes\n' >"$TMP/out/$SHA_FOO.deb"
run fetch amd64 "$TMP/out"
if [ "$RC" -ne 0 ] && says "$OUT" "does not hash to $SHA_FOO"; then pass "P7 a cached archive with other bytes is refused, not re-downloaded"; else fail "P7 rc=$RC: $OUT"; fi
rm -f "$TMP/out/$SHA_FOO.deb"

printf 'tampered\n' >"$TMP/archive/libfoo.deb"
run fetch amd64 "$TMP/out"
if [ "$RC" -ne 0 ] && says "$OUT" "downloads with sha256" && [ ! -f "$TMP/out/$SHA_FOO.deb" ]; then
    pass "P8 an archive that downloads with other bytes is refused and not kept"
else fail "P8 rc=$RC: $OUT"; fi

echo "RESULT: $FAIL_N failed, $PASS_N passed"
[ "$FAIL_N" -eq 0 ]
