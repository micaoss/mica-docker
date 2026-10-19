#!/usr/bin/env bash
# The archive of _out/debs/<arch>/pool installed and run: a privileged container of
# the mica-build-env base image, the archive's Debian Depends from the apt row of
# locks/mica-system-base.lock (the snapshot the device roots install from), the
# archive with dpkg (mica-system is not installed, so /mica/containers is made, on a
# volume of its own). With IP forwarding off, dockerd refuses to start until the
# package's sysctl.d file is applied; then it starts as docker.service starts it,
# with no default route; then the contract micad relies on (API 1.44, /run/docker.pid,
# daemon.json) and containers as users run them: exit codes, a network with name
# resolution, nftables rules, a published port, local logs, compose, capabilities
# and a device; last, stopping dockerd stops its containers (live-restore off).
# Needs docker and the network (one image pull).
#
#   bash tests/docker-smoke.sh [--arch <amd64|arm64>]   (default: the host's)
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT=$PWD
TOOLS="${REPO_ROOT}/bin/mica-tools"
die() { echo "docker-smoke: error: $*" >&2; exit 2; }

ARCH="$(dpkg --print-architecture 2>/dev/null || { [ "$(uname -m)" = aarch64 ] && echo arm64 || echo amd64; })"
while [ "$#" -gt 0 ]; do
    case "$1" in
    --arch) ARCH="${2-}"; shift 2 ;;
    *) echo "usage: bash tests/docker-smoke.sh [--arch <amd64|arm64>]" >&2; exit 2 ;;
    esac
done
case "${ARCH}" in amd64 | arm64) ;; *) die "--arch must be amd64 or arm64" ;; esac
mapfile -t debs < <(find "_out/debs/${ARCH}/pool" -maxdepth 1 -type f -name 'mica-docker_*.deb' 2>/dev/null)
[ "${#debs[@]}" -eq 1 ] || die "_out/debs/${ARCH}/pool holds ${#debs[@]} mica-docker archives, not one; run MICA_ARCH=${ARCH} make engine deb"
DEB="${REPO_ROOT}/${debs[0]}"

apt="$("${TOOLS}" lock rows locks/mica-system-base.lock apt)"
[ "$(grep -c . <<<"${apt}")" -eq 1 ] || die "locks/mica-system-base.lock does not carry exactly one apt row"
IFS=$'\t' read -r _ uri suites components keyring <<<"${apt}"
SOURCES="Types: deb
URIs: ${uri}
Suites: ${suites}
Components: ${components}
Signed-By: ${keyring}
Check-Valid-Until: no"

vol="mica-docker-smoke-$$"
docker volume create --label ai-agent=true "${vol}" >/dev/null
trap 'docker volume rm "${vol}" >/dev/null 2>&1 || true' EXIT
docker run --rm --label ai-agent=true --privileged --platform "linux/${ARCH}" \
    -v "${REPO_ROOT}:${REPO_ROOT}:ro" -v "${vol}:/mica" \
    -e SOURCES="${SOURCES}" -e DEB="${DEB}" -e IMAGE="${SMOKE_IMAGE:-docker.io/library/busybox:1.37}" \
    "$("${TOOLS}" from --ref mica-build-env:base)" bash -euc '
    printf "%s\n" "${SOURCES}" >/etc/apt/sources.list.d/mica-system-base.sources
    apt-get update -qq >/dev/null
    depends="$(dpkg-deb --field "${DEB}" Depends | tr "," "\n" | sed "s/(.*//; s/[[:space:]]//g" | grep -v "^mica-" | tr "\n" " ")"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends ca-certificates curl iproute2 procps ${depends} >/dev/null
    dpkg --force-depends --install "${DEB}" >/dev/null 2>&1
    install -d /mica/containers
    # Nested in docker, this container is the root of its cgroup namespace and holds
    # processes, so no controller can be delegated below it: move them to a leaf
    # first, as docker:dind does. A device root has its own cgroup tree.
    if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
        mkdir -p /sys/fs/cgroup/init
        xargs -rn1 </sys/fs/cgroup/cgroup.procs >/sys/fs/cgroup/init/cgroup.procs 2>/dev/null || true
        sed "s/[^ ]* */+&/g" /sys/fs/cgroup/cgroup.controllers >/sys/fs/cgroup/cgroup.subtree_control
    fi
    PASS_N=0 FAIL_N=0
    check() { local label="$1"; shift; if "$@" >/tmp/out 2>&1; then PASS_N=$((PASS_N + 1)); echo "PASS: ${label}"; else FAIL_N=$((FAIL_N + 1)); echo "FAIL: ${label}"; tail -5 /tmp/out; fi; }
    # dockerd as docker.service runs it: its ExecStart, no arguments.
    start() {
        exec="$(sed -n "s/^ExecStart=//p" /usr/lib/systemd/system/docker.service)"
        ${exec} >>/tmp/dockerd.log 2>&1 &
        for _ in $(seq 1 150); do docker info >/dev/null 2>&1 && return 0; sleep 0.2; done
        tail -20 /tmp/dockerd.log; return 1
    }
    stop() {
        kill -TERM "$(cat /run/docker.pid)"
        for _ in $(seq 1 300); do [ ! -e /run/docker.pid ] && ! pgrep -x dockerd >/dev/null && return 0; sleep 0.2; done
        return 1
    }
    stopped_all() { pgrep -x sleep && stop && ! pgrep -x sleep; }
    echo "docker-smoke: $(dpkg-deb --field "${DEB}" Package Version | tr "\n" " ")on $(dpkg --print-architecture)"
    # Forwarding off, as a device boots: dockerd refuses to create its bridge; the
    # OpenRC start_pre and the sysctl.d file (as systemd-sysctl applies it) turn it on.
    forwarding() { echo "$1" >/proc/sys/net/ipv4/ip_forward; [ ! -e /proc/sys/net/ipv6/conf/all/forwarding ] || echo "$1" >/proc/sys/net/ipv6/conf/all/forwarding; }
    forwarding 0
    refused() { ! timeout 60 /usr/bin/dockerd >/tmp/refused.log 2>&1 && grep -c "IPv4 forwarding is disabled" /tmp/refused.log; }
    check "S0a with forwarding off dockerd refuses to start" refused
    rm -f /run/docker.pid
    openrc_pre() { sh -c "eerror() { echo \"\$*\" >&2; }; . /etc/init.d/docker; start_pre" && [ "$(cat /proc/sys/net/ipv4/ip_forward)" = 1 ]; }
    check "S0b the OpenRC start_pre turns forwarding on" openrc_pre
    forwarding 0
    check "S0c the sysctl.d file, applied as systemd-sysctl does, turns forwarding on" sh -c "sysctl -q -p /usr/lib/sysctl.d/50-mica-docker.conf && [ \"\$(cat /proc/sys/net/ipv4/ip_forward)\" = 1 ]"
    ip route save table main >/tmp/routes
    ip route flush default
    check "S1 dockerd starts with no default route" start
    ip route restore </tmp/routes 2>/dev/null || true
    check "S2 dockerd wrote its pid to /run/docker.pid" sh -c "[ \"\$(cat /run/docker.pid)\" = \"\$(pgrep -x dockerd)\" ]"
    check "S3 data-root, log driver, firewall and storage are the shipped daemon.json" sh -c "docker info --format \"{{.DockerRootDir}} {{.LoggingDriver}} {{.FirewallBackend.Driver}} {{.Driver}}\" | grep -x \"/mica/containers/docker local nftables overlayfs\""
    check "S4 API 1.44 is served on /run/docker.sock" sh -c "curl -fsS --unix-socket /run/docker.sock http://d/v1.44/version && dpkg --compare-versions \"\$(docker version --format {{.Server.MinAPIVersion}})\" le 1.44"
    check "S5 an image is pulled" docker pull -q "${IMAGE}"
    check "S6 a container runs and its exit code is reported" sh -c "docker run --rm \"${IMAGE}\" true && { docker run --rm \"${IMAGE}\" sh -c \"exit 3\"; [ \$? -eq 3 ]; }"
    docker network create smoke >/dev/null
    docker run -d --name smoke-a --network smoke --network-alias api "${IMAGE}" sleep 600 >/dev/null
    # Absolute names: a bare name would also be tried under the search domains of the
    # host, which the resolver of a CI runner answers with NXDOMAIN.
    check "S7 a container name and an alias resolve on a network" docker run --rm --network smoke "${IMAGE}" sh -c "nslookup smoke-a. && nslookup api."
    check "S8 dockerd wrote its nftables rules" sh -c "nft list tables | grep -c docker"
    docker run -d --name smoke-web -p 18080:80 "${IMAGE}" sh -c "echo ok >/tmp/index.html && exec httpd -f -p 80 -h /tmp" >/dev/null
    sleep 1
    check "S9 a published port answers on the host" sh -c "curl -fsS http://127.0.0.1:18080/index.html | grep -x ok"
    docker run --name smoke-log "${IMAGE}" echo logged >/dev/null
    check "S10 a log is written by the local driver and read back" sh -c "[ \"\$(docker inspect --format \"{{.HostConfig.LogConfig.Type}}\" smoke-log)\" = local ] && docker logs smoke-log | grep -x logged"
    check "S11 cap_add and cap_drop reach the container" sh -c "[ \"\$(docker run --rm --cap-drop ALL \"${IMAGE}\" sed -n \"s/^CapEff:[[:space:]]*//p\" /proc/self/status)\" = 0000000000000000 ] && docker run --rm --cap-drop ALL --cap-add NET_ADMIN \"${IMAGE}\" sed -n \"s/^CapEff:[[:space:]]*//p\" /proc/self/status | grep -x 0000000000001000"
    check "S12 a device is passed in" docker run --rm --device /dev/null:/dev/smoke "${IMAGE}" test -c /dev/smoke
    mkdir -p /tmp/proj
    printf "services:\n  web:\n    image: %s\n    command: [\"sleep\", \"600\"]\n    restart: always\n" "${IMAGE}" >/tmp/proj/compose.yaml
    check "S13 docker compose up -d and down" sh -c "cd /tmp/proj && docker compose -p smoke up -d && [ \"\$(docker inspect --format \"{{.State.Running}}\" smoke-web-1)\" = true ] && docker compose -p smoke down && ! docker inspect smoke-web-1"
    check "S14 docker-init is the init of --init" sh -c "docker run --rm --init \"${IMAGE}\" cat /proc/1/cmdline | tr \"\\0\" \" \" | grep -c docker-init"
    check "S15 stopping dockerd stops its containers (live-restore off)" stopped_all
    echo "RESULT: ${FAIL_N} failed, ${PASS_N} passed"
    [ "${FAIL_N}" -eq 0 ]'
