#!/usr/bin/env bash
# tools/base-check.sh against fixtures served over file://: a mica-system-base
# lock and pin, its rootfs layers in a registry layout, a fixture resolver
# standing in for the apt run (MICA_BASE_RESOLVE), and tests/mica-tools-stub.sh
# for bin/mica-tools, whose `locks verify` is mica-build-tools' own to test; the
# apt run itself is exercised by `make base-check` in CI. Offline.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT=$PWD
mkdir -p _out
TMP=$(mktemp -d "$REPO_ROOT/_out/base-check-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
PASS_N=0 FAIL_N=0
pass() { PASS_N=$((PASS_N + 1)); echo "PASS: $*"; }
fail() { FAIL_N=$((FAIL_N + 1)); echo "FAIL: $*"; }
says() { case "$1" in *"$2"*) return 0;; *) return 1;; esac; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
D() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

REG="$TMP/registry"
SITE="$TMP/site"
FIX="$TMP/repo"
TAG=20990101-0000
C40=0123456789abcdef0123456789abcdef01234567
mkdir -p "$FIX/tools" "$FIX/bin" "$FIX/deb" "$FIX/locks/pins" "$REG/v2/micaoss/mica-system-base/blobs" "$REG/v2/micaoss/mica-system-base/manifests"
cp tools/base-check.sh "$FIX/tools/"
cp tests/mica-tools-stub.sh "$FIX/bin/mica-tools"
cp locks/mica-build-env.lock "$FIX/locks/"
cp locks/pins/mica-build-env.pin "$FIX/locks/pins/"
printf 'app\n' >"$FIX/deb/debian-depends"
depends() { printf 'Package: mica-docker\nVersion: 1-1\nDepends: %s\n' "$1" >"$FIX/deb/mica-docker.control"; }
depends 'mica-system, liba (>= 1)' 

rootfs() { # <arch> -> manifest digest of a one-layer root whose dpkg status names <arch>-root
    local d="$TMP/root-$1" ld m
    rm -rf "$d"
    mkdir -p "$d/var/lib/dpkg"
    printf 'Package: %s-root\nStatus: install ok installed\n\nPackage: libcommon\nStatus: install ok installed\nVersion: 2\n\n' "$1" >"$d/var/lib/dpkg/status"
    tar -C "$d" -czf "$TMP/layer.tgz" ./var
    ld="sha256:$(sha "$TMP/layer.tgz")"
    cp "$TMP/layer.tgz" "$REG/v2/micaoss/mica-system-base/blobs/$ld"
    jq -n --arg d "$ld" '{schemaVersion: 2, layers: [{mediaType: "application/vnd.oci.image.layer.v1.tar+gzip", digest: $d}]}' >"$TMP/m.json"
    m="sha256:$(sha "$TMP/m.json")"
    cp "$TMP/m.json" "$REG/v2/micaoss/mica-system-base/manifests/$m"
    printf '%s' "$m"
}
AMD_ROOT=$(rootfs amd64)
ARM_ROOT=$(rootfs arm64)
URI=https://snapshot.debian.org/archive/debian/20260905T000000Z
SEC=https://snapshot.debian.org/archive/debian-security/20260905T000000Z
row() { printf '%s\t%s\t%s\t%s\t%s/pool/main/%s_%s_%s.deb\n' "$1" "$2" "$3" "$(D "$1$2$3")" "${4:-$URI}" "$1" "$3" "$2"; }

# The release: a lock whose upstream rows are <rows file> (row + roots), and its SHA256SUMS; lock and pin committed.
publish() { # <upstream rows file>
    local dir="$SITE/micaoss/mica-system-base/releases/download/$TAG"
    mkdir -p "$dir"
    {
        printf '# mica-lock v1\nrelease\tmica-system-base\t%s\t%s\n' "$TAG" "$C40"
        printf 'image\tmica-system-base\trootfs\tamd64\tghcr.io/micaoss/mica-system-base@%s\n' "$AMD_ROOT"
        printf 'image\tmica-system-base\trootfs\tarm64\tghcr.io/micaoss/mica-system-base@%s\n' "$ARM_ROOT"
        printf 'image\tmica-system-base\trootfs\tindex\tghcr.io/micaoss/mica-system-base:rootfs.%s@sha256:%s\n' "$TAG" "$(D index)"
        sed 's/^/upstream\t/' "$1" | LC_ALL=C sort
        printf 'apt\t%s\t%s\tmain\t/usr/share/keyrings/debian-archive-keyring.gpg\n' "$SEC" trixie-security "$URI" trixie "$URI" trixie-updates
    } >"$dir/mica-system-base.lock"
    (cd "$dir" && sha256sum mica-system-base.lock >SHA256SUMS)
    cp "$dir/mica-system-base.lock" "$FIX/locks/"
    printf '# mica-pin v1\nREPOSITORY=mica-system-base\nRELEASE=%s\nSHA256SUMS=%s\n' "$TAG" "$(sha "$dir/SHA256SUMS")" >"$FIX/locks/pins/mica-system-base.pin"
}
# The fixture resolver: rows for the archives the root lacks, from $RESOLVED-<arch>, after asserting what apt would be given.
cat >"$TMP/resolve" <<'EOF2'
#!/usr/bin/env bash
set -euo pipefail
arch="$1" work="$2"
grep -c "^Package: ${arch}-root$" "$work/status-$arch" >/dev/null || { echo "resolver: not the $arch root status" >&2; exit 9; }
[ "$(ls "$work/sources.d")" = mica-system-base.sources ] || { echo "resolver: sources.d is not the one Base source" >&2; exit 9; }
stanza='Types: deb\nURIs: %s\nSuites: %s\nComponents: main\nCheck-Valid-Until: no\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n'
[ "$(cat "$work/sources.d/mica-system-base.sources")" = "$(printf "$stanza\n$stanza\n$stanza" "$SEC" trixie-security "$URI" trixie "$URI" trixie-updates)" ] ||
    { echo "resolver: the sources are not the apt rows rendered, one stanza each" >&2; exit 9; }
cat "$RESOLVED-$arch"
EOF2
chmod +x "$TMP/resolve"
run() {
    RC=0
    OUT=$(MICA_RELEASE_DOWNLOAD="file://$SITE" MICA_BASE_REGISTRY="file://$REG" MICA_BASE_RESOLVE="$TMP/resolve" RESOLVED="$TMP/resolved" URI="$URI" SEC="$SEC" \
        bash "$FIX/tools/base-check.sh" 2>&1) || RC=$?
}
record() { # [rows file]: locks/upstream.lock with those rows as source rows
    { echo "# mica-lock v1"; [ "$#" -eq 0 ] || sed 's/^/source\t/' "$1" | LC_ALL=C sort; } >"$FIX/locks/upstream.lock"
}

{ printf '%s\tapp,other\n' "$(row liba amd64 1)"; printf '%s\tapp\n' "$(row liba arm64 1)"; } >"$TMP/base-rows"
publish "$TMP/base-rows"
row liba amd64 1 >"$TMP/resolved-amd64"
row liba arm64 1 >"$TMP/resolved-arm64"
record

run
if [ "$RC" -eq 0 ] && says "$OUT" "amd64: 1 archive(s) the root lacks, 1 pinned by mica-system-base, 0 recorded in locks/upstream.lock" && says "$OUT" "mica-system-base $TAG"; then
    pass "S1 archives the root lacks are all Base upstream rows for our roots, on both architectures, with the apt rows as the only sources"
else fail "S1 rc=$RC: $OUT"; fi

row libb arm64 2 "$SEC" >>"$TMP/resolved-arm64"
run
if [ "$RC" -ne 0 ] && says "$OUT" "libb	arm64	2	" && says "$OUT" "record it as a source row of locks/upstream.lock or ask Base to add it under options"; then
    pass "S2 an archive Base does not pin and this repository does not record is refused with its row"
else fail "S2 rc=$RC: $OUT"; fi

row libb arm64 2 "$SEC" >"$TMP/recorded"
record "$TMP/recorded"
run
if [ "$RC" -eq 0 ] && says "$OUT" "arm64: 2 archive(s) the root lacks, 1 pinned by mica-system-base, 1 recorded in locks/upstream.lock"; then
    pass "S3 an archive recorded as a source row of locks/upstream.lock, under any apt row's URI, passes"
else fail "S3 rc=$RC: $OUT"; fi

row liba arm64 1 >"$TMP/resolved-arm64"
run
if [ "$RC" -ne 0 ] && says "$OUT" "locks/upstream.lock records libb	arm64	2" && says "$OUT" "no longer resolves"; then
    pass "S4 a recorded row that no longer resolves is refused"
else fail "S4 rc=$RC: $OUT"; fi

# The engine's build closure (tools/dev-pins.sh) may sit under the Base apt URI when both
# snapshots are one moment; it is a build input listed in pins/, not a runtime record.
row libbuild arm64 3 >"$TMP/recorded"
record "$TMP/recorded"
mkdir -p "$FIX/pins" && printf 'libbuild\n' >"$FIX/pins/c.arm64"
run
if [ "$RC" -eq 0 ] && says "$OUT" "arm64: 1 archive(s) the root lacks, 1 pinned by mica-system-base, 0 recorded"; then
    pass "S4b a build-closure row under the apt URI is not taken for a runtime record"
else fail "S4b rc=$RC: $OUT"; fi
rm -rf "$FIX/pins"
record

printf 'liba\tamd64\t9\t%s\t%s/pool/main/liba_9_amd64.deb\n' "$(D liba-other)" "$URI" >"$TMP/resolved-amd64"
run
if [ "$RC" -ne 0 ] && says "$OUT" "liba	amd64	9	"; then pass "S5 a resolved archive other than Base's row for that package is refused"; else fail "S5 rc=$RC: $OUT"; fi
row liba amd64 1 >"$TMP/resolved-amd64"

STUB_LOCKS_VERIFY=release-mismatch run
if [ "$RC" -ne 0 ] && says "$OUT" "refused release-mismatch" && ! says "$OUT" "archive(s) the root lacks"; then
    pass "S6 a pin mica-tools locks verify refuses stops the check before anything is resolved"
else fail "S6 rc=$RC: $OUT"; fi

L=$(jq -r '.layers[0].digest' "$REG/v2/micaoss/mica-system-base/manifests/$ARM_ROOT")
cp "$REG/v2/micaoss/mica-system-base/blobs/$L" "$TMP/layer.bak" && printf X >>"$REG/v2/micaoss/mica-system-base/blobs/$L"
run
if [ "$RC" -ne 0 ] && says "$OUT" "does not hash to $L"; then pass "S7 a rootfs layer with other bytes is refused"; else fail "S7 rc=$RC: $OUT"; fi
cp "$TMP/layer.bak" "$REG/v2/micaoss/mica-system-base/blobs/$L"

run
if [ "$RC" -eq 0 ]; then pass "S8 the fixture passes again once restored"; else fail "S8 rc=$RC: $OUT"; fi

{ printf '%s\tother\n' "$(row liba amd64 1)"; printf '%s\tapp\n' "$(row liba arm64 1)"; } >"$TMP/other-rows"
publish "$TMP/other-rows"
run
if [ "$RC" -eq 0 ] && says "$OUT" "amd64: 1 archive(s) the root lacks, 1 pinned by mica-system-base"; then
    pass "S9 an archive Base pins for other roots is taken: any upstream row of the Base lock is"
else fail "S9 rc=$RC: $OUT"; fi

publish "$TMP/base-rows"
depends 'mica-system, liba (>= 2)'
run
if [ "$RC" -ne 0 ] && says "$OUT" "deb/mica-docker.control needs liba (>= 2)" && says "$OUT" "mica-system-base $TAG pins 1"; then
    pass "S10 a Depends floor above the version Base pins is refused"
else fail "S10 rc=$RC: $OUT"; fi

depends 'mica-system, libz (>= 1)'
run
if [ "$RC" -ne 0 ] && says "$OUT" "deb/mica-docker.control depends on libz, which mica-system-base $TAG does not pin"; then
    pass "S11 a Depends nothing pins or ships in the root is refused"
else fail "S11 rc=$RC: $OUT"; fi

depends 'mica-system, liba (>= 1), libcommon (>= 2)'
run
if [ "$RC" -eq 0 ] && says "$OUT" "amd64: every declared Depends is satisfied"; then
    pass "S12 a Depends the root itself ships is satisfied from its dpkg status"
else fail "S12 rc=$RC: $OUT"; fi
depends 'mica-system, liba (>= 1)'

echo "RESULT: $FAIL_N failed, $PASS_N passed"
[ "$FAIL_N" -eq 0 ]
