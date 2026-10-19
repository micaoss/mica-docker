#!/usr/bin/env bash
# tools/upgrade.sh in a fixture checkout: the upstream trees behind (a fixture
# check-pins.sh) move to tags of local repositories, peeled to their commits;
# bin/mica-tools is tests/mica-tools-stub.sh, whose `locks update` reports the
# moves $STUB_LOCKS_UPDATE names. Asserts the rows, the copyright and description
# versions, the version rule, and that a second run changes nothing. The
# mica-build-env move (pins/snapshot and the closure, docker) is not driven here.
# Offline.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT=$PWD
mkdir -p _out
TMP=$(mktemp -d "$REPO_ROOT/_out/upgrade-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
PASS_N=0 FAIL_N=0
pass() { PASS_N=$((PASS_N + 1)); echo "PASS: $*"; }
fail() { FAIL_N=$((FAIL_N + 1)); echo "FAIL: $*"; }
says() { case "$1" in *"$2"*) return 0;; *) return 1;; esac; }

# Upstream trees: moby with an annotated tag, runc with a lightweight one.
mkrepo() { # <name> <tag> [annotated]
    local d="$TMP/upstream/$1"
    git init -q "$d" && git -C "$d" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$2"
    if [ -n "${3:-}" ]; then git -C "$d" -c user.name=t -c user.email=t@t tag -a -m "$2" "$2"; else git -C "$d" tag "$2"; fi
    git -C "$d" rev-parse HEAD
}
MOBY_COMMIT=$(mkrepo moby docker-v29.9.1 annotated)
RUNC_COMMIT=$(mkrepo runc v1.5.2)
RUNC_NEXT=$(mkrepo runc-next v1.5.3)

FIX="$TMP/repo"
mkdir -p "$FIX/tools" "$FIX/bin" "$FIX/deb" "$FIX/locks/pins" "$FIX/pins"
cp tools/upgrade.sh "$FIX/tools/"
cp tests/mica-tools-stub.sh "$FIX/bin/mica-tools"
cp deb/mica-docker.control deb/copyright "$FIX/deb/"
sed -i 's/^Version: .*/Version: 29.8.2-5/; s/^Source-Date-Epoch: .*/Source-Date-Epoch: 1000000000/' "$FIX/deb/mica-docker.control"
python3 - "$FIX/deb/mica-docker.control" <<'PY'
import re, sys
p = sys.argv[1]; t = open(p).read()
t = re.sub(r"Docker [0-9.]+ \(dockerd and the docker CLI\), docker compose", "Docker 29.8.2 (dockerd), the docker CLI 29.9.1, docker compose", t)
t = re.sub(r"runc [0-9.]+ and", "runc 1.5.1 and", t)
open(p, "w").write(t)
PY
sed -i 's/^Comment: moby docker-v[0-9.]*\./Comment: moby docker-v29.8.2./; s/^Comment: opencontainers\/runc v[0-9.]*,/Comment: opencontainers\/runc v1.5.1,/' "$FIX/deb/copyright"
{
    printf '# mica-lock v1\n'
    for n in cli compose containerd tini; do
        awk -F'\t' -v n="$n" '$1 == "git" && $2 == n' locks/upstream.lock
    done
    printf 'git\tmoby\tfile://%s\tdocker-v29.8.2\t%s\n' "$TMP/upstream/moby" "$(printf 'a%.0s' {1..40})"
    printf 'git\trunc\tfile://%s\tv1.5.1\t%s\n' "$TMP/upstream/runc" "$(printf 'c%.0s' {1..40})"
} >"$FIX/locks/upstream.lock"
printf '# mica-tools-pin v1\nREPOSITORY=mica-build-tools\nCOMMIT=%s\n' "$(printf '1%.0s' {1..40})" >"$FIX/locks/mica-build-tools.pin"
for r in mica-build-env mica-system-base; do
    printf '# mica-pin v1\nREPOSITORY=%s\nRELEASE=20260101-0000\nSHA256SUMS=%s\n' "$r" "$(printf '0%.0s' {1..64})" >"$FIX/locks/pins/$r.pin"
done
printf 'SNAPSHOT=fixture\n' >"$FIX/pins/resolved-for"

# check-pins.sh: the trees $BEHIND names, in its own output form.
cat >"$FIX/check-pins.sh" <<'EOS'
#!/usr/bin/env bash
[ -z "${BEHIND:-}" ] && exit 0
printf '%s\n' "${BEHIND}" | while read -r n o t; do printf 'BEHIND     %-13s %-10s -> %s (2026-09-16)\n' "$n" "$o" "$t"; done
exit 1
EOS
chmod +x "$FIX/check-pins.sh"
run() { RC=0; OUT=$(GH_TOKEN=x bash "$FIX/tools/upgrade.sh" 2>&1) || RC=$?; }
field() { sed -n "s/^$1: //p" "$FIX/deb/mica-docker.control"; }
row() { awk -F'\t' -v n="$1" '$1 == "git" && $2 == n { print $4 " " $5 }' "$FIX/locks/upstream.lock"; }

BEHIND="" run
if [ "$RC" -eq 0 ] && says "$OUT" "upgrade.sh: unchanged" && [ "$(field Version)" = 29.8.2-5 ]; then
    pass "U1 every pin at its latest release: unchanged, nothing written"
else fail "U1 rc=$RC: $OUT"; fi

BEHIND="moby docker-v29.8.2 docker-v29.9.1
runc v1.5.1 v1.5.2" run
if [ "$RC" -eq 0 ] && says "$OUT" "upgrade.sh: changed" && [ "$(row moby)" = "docker-v29.9.1 ${MOBY_COMMIT}" ] && [ "$(row runc)" = "v1.5.2 ${RUNC_COMMIT}" ]; then
    pass "U2 the trees behind take the newest tag and the commit it peels to, annotated or lightweight"
else fail "U2 rc=$RC: $OUT / $(row moby) / $(row runc)"; fi
if [ "$(field Version)" = 29.9.1-1 ] && [ "$(field Source-Date-Epoch)" != 1000000000 ]; then
    pass "U3 a new moby tag sets <Docker version>-1 and a new Source-Date-Epoch"
else fail "U3 Version $(field Version), epoch $(field Source-Date-Epoch)"; fi
body() { grep -v -e '^Version: ' -e '^Source-Date-Epoch: ' "$1"; }
if cmp -s <(body deb/mica-docker.control) <(body "$FIX/deb/mica-docker.control") &&
    grep -q "^Comment: moby docker-v29.9.1\.$" "$FIX/deb/copyright" && grep -q "^Comment: opencontainers/runc v1.5.2," "$FIX/deb/copyright"; then
    pass "U4 the description and deb/copyright name the new versions"
else fail "U4 $(diff <(body deb/mica-docker.control) <(body "$FIX/deb/mica-docker.control"); grep -n '^Comment: moby\|^Comment: opencontainers' "$FIX/deb/copyright")"; fi

BEHIND="" run
if [ "$RC" -eq 0 ] && says "$OUT" "upgrade.sh: unchanged" && [ "$(field Version)" = 29.9.1-1 ]; then
    pass "U5 a second run changes nothing"
else fail "U5 rc=$RC: $OUT"; fi

sed -i "s|file://$TMP/upstream/runc\t|file://$TMP/upstream/runc-next\t|" "$FIX/locks/upstream.lock"
BEHIND="runc v1.5.2 v1.5.3" run
if [ "$RC" -eq 0 ] && [ "$(field Version)" = 29.9.1-2 ] && [ "$(row runc)" = "v1.5.3 ${RUNC_NEXT}" ]; then
    pass "U6 another tree's move bumps the revision"
else fail "U6 rc=$RC: $OUT / $(field Version)"; fi

STUB_LOCKS_UPDATE="mica-system-base 20260101-0000 -> 20260202-0000" BEHIND="" run
if [ "$RC" -eq 0 ] && says "$OUT" "mica-system-base 20260101-0000 -> 20260202-0000" && says "$OUT" "upgrade.sh: changed" &&
    [ "$(field Version)" = 29.9.1-2 ]; then
    pass "U7 a Base move locks update reports is a change that leaves the package version, since it decides no byte of it"
else fail "U7 rc=$RC: $OUT / $(field Version)"; fi

STUB_LOCKS_UPDATE="mica-build-tools 1111111111111111111111111111111111111111 -> 2222222222222222222222222222222222222222 (20260928-2122)" BEHIND="" run
if [ "$RC" -eq 0 ] && says "$OUT" "mica-build-tools 1111111111111111111111111111111111111111 -> 2222222222222222222222222222222222222222 (20260928-2122)" &&
    says "$OUT" "upgrade.sh: changed" && [ "$(field Version)" = 29.9.1-2 ]; then
    pass "U8 a tool move is reported with its release and leaves the package version"
else fail "U8 rc=$RC: $OUT / $(field Version)"; fi

echo "RESULT: $FAIL_N failed, $PASS_N passed"
[ "$FAIL_N" -eq 0 ]
