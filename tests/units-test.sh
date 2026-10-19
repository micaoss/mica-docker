#!/usr/bin/env bash
# The start-up files and daemon.json against the contract micad relies on: dockerd
# after micad, with no socket activation and no network ordering; the default pid
# file /run/docker.pid; the default minimum API version, so 1.44 stays served; and
# live-restore off (Docker's default), so stopping dockerd stops its containers.
# deb/docker.openrc is sourced as openrc-run would, with its helpers stubbed.
# Offline.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT=$PWD
mkdir -p _out
TMP=$(mktemp -d "$REPO_ROOT/_out/units-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
PASS_N=0 FAIL_N=0
pass() { PASS_N=$((PASS_N + 1)); echo "PASS: $*"; }
fail() { FAIL_N=$((FAIL_N + 1)); echo "FAIL: $*"; }
check() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then pass "${label}"; else fail "${label}"; fi; }

UNIT=deb/docker.service
OPENRC=deb/docker.openrc
JSON=overlay/etc/docker/daemon.json
keys() { sed 's/#.*//' "$UNIT" | sed -n "s/^$1=//p"; }

check "U1 docker.service is ordered after micad.service" [ "$(keys After)" = micad.service ]
check "U2 docker.service has no network, socket or time ordering" \
    bash -c '! sed "s/#.*//" "$1" | grep -E -c "network-online|nss-lookup|time-set|docker\.socket|^(Wants|Requires)=" ' _ "$UNIT"
check "U3 dockerd listens on its own socket, not a socket-activated fd" \
    bash -c '[ "$1" = /usr/bin/dockerd ]' _ "$(keys ExecStart)"
check "U4 Type=notify, Delegate=yes, KillMode=process" \
    [ "$(keys Type)/$(keys Delegate)/$(keys KillMode)" = notify/yes/process ]

# depend() as openrc-run calls it, with need/after/use recording their arguments.
depend_calls="$(sh -c '
    need() { echo "need $*"; }
    after() { echo "after $*"; }
    use() { echo "use $*"; }
    . "$0"
    depend' "$OPENRC")"
check "O1 the OpenRC script starts after micad" grep -x "after micad" <<<"${depend_calls}"
check "O2 the OpenRC script needs nothing but mica-mounts (no containerd, no net)" \
    [ "$(grep '^need ' <<<"${depend_calls}")" = "need mica-mounts" ]
command_args="$(sh -c '. "$0"; echo "${command}|${command_args}"' "$OPENRC")"
check "O3 the OpenRC script runs dockerd with -p /run/docker.pid" [ "${command_args}" = "/usr/bin/dockerd|-p /run/docker.pid" ]

check "J1 daemon.json sets exactly data-root, log-driver and firewall-backend" \
    [ "$(jq -c . "$JSON")" = '{"data-root":"/mica/containers/docker","log-driver":"local","firewall-backend":"nftables"}' ]
check "J2 nothing sets a minimum API version, a pid file or live-restore" \
    bash -c '! grep -r -h -v "^[[:space:]]*#" deb/docker.service deb/docker.openrc overlay | grep -E -c "DOCKER_MIN_API_VERSION|min-api-version|live-restore|\"pidfile\""'

SYSCTL=overlay/usr/lib/sysctl.d/50-mica-docker.conf
check "F1 the sysctl.d file turns on IPv4 and (when present) IPv6 forwarding" \
    [ "$(sed 's/#.*//; /^[[:space:]]*$/d' "$SYSCTL")" = "$(printf 'net.ipv4.ip_forward = 1\n-net.ipv6.conf.all.forwarding = 1')" ]
# start_pre against a fixture /proc/sys: the script's path prefix is rewritten.
mkdir -p "$TMP/proc/sys/net/ipv4"
echo 0 >"$TMP/proc/sys/net/ipv4/ip_forward"
sed -e "s|/proc/sys/|$TMP/proc/sys/|; s|/usr/lib/sysctl.d/50-mica-docker.conf|$REPO_ROOT/$SYSCTL|" "$OPENRC" >"$TMP/docker.openrc"
pre() { sh -c 'eerror() { echo "$*" >&2; }; . "$0"; start_pre' "$TMP/docker.openrc"; }
forwards() { pre && [ "$(cat "$TMP/proc/sys/$1")" = 1 ]; }
check "F2 the OpenRC start_pre writes the forwarding, skipping IPv6 the kernel lacks" forwards net/ipv4/ip_forward
mkdir -p "$TMP/proc/sys/net/ipv6/conf/all"
echo 0 >"$TMP/proc/sys/net/ipv6/conf/all/forwarding"
check "F3 ... and writes IPv6 forwarding where it exists" forwards net/ipv6/conf/all/forwarding
rm -rf "$TMP/proc/sys/net/ipv4"
refuses() { ! pre; }
check "F4 ... and fails when IPv4 forwarding is missing" refuses

echo "RESULT: $FAIL_N failed, $PASS_N passed"
[ "$FAIL_N" -eq 0 ]
