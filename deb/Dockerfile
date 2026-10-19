# syntax=docker/dockerfile:1@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
# check=skip=InvalidDefaultArgInFrom
# Stages, asserts and packs mica-docker (tools/package.sh). The binaries arrive
# through the `bin` context, the configuration through `overlay`, and the packer
# (`mica-tools deb pack`) through `tools`, the pinned mica-build-tools checkout. Runs at the
# target architecture on the mica-build-env base image, and installs nothing: the
# Depends are declared in mica-docker.control with their floors.
ARG MICA_BUILD_BASE

FROM ${MICA_BUILD_BASE} AS pack

COPY --from=tools package.json /tools/package.json
COPY --from=tools src /tools/src
COPY mica-docker.control copyright payload.manifest docker.service docker.openrc /in/

COPY --from=overlay etc/docker/daemon.json /in/etc/docker/

COPY --from=bin dockerd docker-proxy docker docker-compose containerd containerd-shim-runc-v2 runc docker-init /in/bin/
COPY --from=bin upstream.lock /in/upstream.lock

ARG MICA_DEB_VERSION
ARG MICA_DEB_ARCH
ARG SOURCE_DATE_EPOCH
ARG MICA_DEB_SOURCE_REPO

# No conffiles: the root is an immutable dm-verity image. The start-up files, one
# per init, are shipped and not enabled: micad enables the one of the product's
# init from container.enabled.
RUN set -eu; \
    install -d -m 0755 /stage/etc /stage/etc/docker /stage/etc/init.d \
                       /stage/usr /stage/usr/bin /stage/usr/lib /stage/usr/lib/systemd \
                       /stage/usr/lib/systemd/system \
                       /stage/usr/libexec /stage/usr/libexec/docker /stage/usr/libexec/docker/cli-plugins \
                       /stage/usr/share /stage/usr/share/doc /stage/usr/share/doc/mica-docker \
                       /stage/usr/share/mica-docker; \
    for b in dockerd docker-proxy docker containerd containerd-shim-runc-v2 runc docker-init; do \
        install -m 0755 "/in/bin/${b}" "/stage/usr/bin/${b}"; \
    done; \
    install -m 0755 /in/bin/docker-compose /stage/usr/libexec/docker/cli-plugins/docker-compose; \
    install -m 0644 /in/etc/docker/daemon.json /stage/etc/docker/daemon.json; \
    install -m 0644 /in/docker.service /stage/usr/lib/systemd/system/docker.service; \
    install -m 0755 /in/docker.openrc  /stage/etc/init.d/docker; \
    install -m 0644 /in/copyright /stage/usr/share/doc/mica-docker/copyright; \
    install -m 0644 /in/upstream.lock /stage/usr/share/mica-docker/upstream.lock

# The staged tree (mode, type, symlink target) is exactly payload.manifest.
RUN set -eu; \
    grep -v '^#' /in/payload.manifest | grep -v '^$' | LC_ALL=C sort > /tmp/declared; \
    [ -s /tmp/declared ] || { echo "error: /in/payload.manifest declares no paths" >&2; exit 1; }; \
    find /stage -mindepth 1 -printf '%#m %y /%P\t%l\n' \
        | awk -F'\t' '{ if ($2 == "") print $1; else print $1 " -> " $2 }' \
        | LC_ALL=C sort > /tmp/staged; \
    if ! diff -u /tmp/declared /tmp/staged; then \
        echo "error: the staged tree is not deb/payload.manifest ('-' declared only, '+' staged only)" >&2; \
        exit 1; \
    fi; \
    echo "docker-deb: the staged tree is exactly the $(wc -l < /tmp/declared) declared paths"

RUN set -eu; \
    bun /tools/src/cli.ts deb pack --root /stage --control /in/mica-docker.control \
            --arch "${MICA_DEB_ARCH}" --out /out

RUN set -eu; \
    got="$(find /out -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')"; \
    want="mica-docker_${MICA_DEB_VERSION}_${MICA_DEB_ARCH}.deb "; \
    [ "${got}" = "${want}" ] || { echo "error: /out holds '${got}', expected '${want}'" >&2; exit 1; }; \
    echo "docker-deb: /out holds ${want}and no other archive"

FROM scratch AS out
COPY --from=pack /out/ /
