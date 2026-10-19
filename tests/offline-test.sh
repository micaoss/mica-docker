#!/usr/bin/env bash
# tools/offline.sh against stub build.sh and tools/package.sh in a fixture
# checkout: what it refuses, what it runs and in which order, what it prints.
# Offline.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT=$PWD
mkdir -p _out
TMP=$(mktemp -d "$REPO_ROOT/_out/offline-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
PASS_N=0 FAIL_N=0
pass() { PASS_N=$((PASS_N + 1)); echo "PASS: $*"; }
fail() { FAIL_N=$((FAIL_N + 1)); echo "FAIL: $*"; }
says() { case "$1" in *"$2"*) return 0;; *) return 1;; esac; }

FIX="$TMP/repo"
mkdir -p "$FIX/tools" "$FIX/deb" "$FIX/locks"
cp tools/offline.sh "$FIX/tools/"
cp deb/mica-docker.control "$FIX/deb/"
cp locks/upstream.lock "$FIX/locks/"
printf '_out/\n' >"$FIX/.gitignore"
# The stubs log each call; package.sh writes a pool indexed as the real one is.
cat >"$FIX/build.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "build ${MICA_ARCH}" >>"$(dirname "$0")/_out/calls"
[ -z "${DIRTY_BUILD:-}" ] || echo dirty >>"$(dirname "$0")/.gitignore"
EOF
cat >"$FIX/tools/package.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
echo "package $*" >>"${root}/_out/calls"
arch="$2" dest="${root}/_out/debs/$2"
rm -rf "${dest}" && mkdir -p "${dest}/pool"
echo "${arch}" >"${dest}/pool/mica-docker_1-1_${arch}.deb"
echo "Package: mica-docker" >"${dest}/Packages"
[ -n "${NO_SUMS:-}" ] || (cd "${dest}" && sha256sum pool/*.deb >SHA256SUMS)
EOF
git -C "$FIX" init -q
git -C "$FIX" -c user.name=f -c user.email=f@invalid add -A
git -C "$FIX" -c user.name=f -c user.email=f@invalid commit -qm one
mkdir -p "$FIX/_out"

offline() {
    RC=0
    rm -f "$FIX/_out/calls"
    OUT=$(bash "$FIX/tools/offline.sh" 2>&1) || RC=$?
    CALLS=$(cat "$FIX/_out/calls" 2>/dev/null || true)
}

echo change >>"$FIX/.gitignore"
offline
if [ "$RC" -ne 0 ] && says "$OUT" "uncommitted changes" && [ -z "$CALLS" ]; then pass "O1 a dirty tree is refused before any build"; else fail "O1 rc=$RC calls=$CALLS: $OUT"; fi
git -C "$FIX" checkout -q -- .gitignore

offline
if [ "$RC" -eq 0 ] && [ "$CALLS" = "$(printf 'build amd64\npackage --arch amd64\nbuild arm64\npackage --arch arm64')" ] &&
    says "$OUT" "$FIX/_out/debs/amd64/pool" && says "$OUT" "$FIX/_out/debs/arm64/SHA256SUMS" && says "$OUT" "$FIX/_out/debs/arm64/Packages" &&
    says "$OUT" "$(git -C "$FIX" rev-parse HEAD)" && says "$OUT" "warning: no release was compared"; then
    pass "O2 a clean tree builds and packs amd64 then arm64 and prints each pool, Packages and SHA256SUMS"
else fail "O2 rc=$RC calls=$CALLS: $OUT"; fi

RC=0
OUT=$(DIRTY_BUILD=1 bash "$FIX/tools/offline.sh" 2>&1) || RC=$?
if [ "$RC" -ne 0 ] && says "$OUT" "changed during the build"; then pass "O3 a build that changes the tree is refused"; else fail "O3 rc=$RC: $OUT"; fi
git -C "$FIX" checkout -q -- .gitignore

RC=0
OUT=$(NO_SUMS=1 bash "$FIX/tools/offline.sh" 2>&1) || RC=$?
if [ "$RC" -ne 0 ] && says "$OUT" "_out/debs/amd64 is not an indexed pool"; then pass "O4 a pool without its index is refused"; else fail "O4 rc=$RC: $OUT"; fi

echo "RESULT: $FAIL_N failed, $PASS_N passed"
[ "$FAIL_N" -eq 0 ]
