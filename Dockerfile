# syntax=docker/dockerfile:1@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
# check=skip=InvalidDefaultArgInFrom

# The Docker engine from pinned upstream source: src fetches and verifies, go-cross
# compiles the pure Go binaries for the target from the build platform, cgo builds
# runc and docker-init at the target, verify asserts, artifact exports.
# The cgo stage installs its Debian build packages from the archives
# locks/upstream.lock pins, through the `pins` context (build.sh fetches and
# verifies them); nothing here reads a live archive. The bases are the
# mica-build-env images of locks/mica-build-env.lock (build.sh passes them; no
# defaults).
ARG MICA_BUILD_BASE
ARG MICA_BUILD_GO

FROM --platform=$BUILDPLATFORM ${MICA_BUILD_BASE} AS src
COPY locks/upstream.lock /upstream.lock

# Shallow clone of each git row of locks/upstream.lock at its tag, verified
# against the pinned commit.
RUN --mount=type=cache,target=/root/.cache/git \
    set -eu; \
    fetch() { \
        name="$1"; \
        row="$(awk -F'\t' -v n="${name}" '$1 == "git" && $2 == n' /upstream.lock)"; \
        [ -n "${row}" ] || { echo "error: locks/upstream.lock pins no ${name}" >&2; exit 1; }; \
        url="$(printf '%s\n' "${row}" | cut -f3)"; tag="$(printf '%s\n' "${row}" | cut -f4)"; want="$(printf '%s\n' "${row}" | cut -f5)"; \
        git -c advice.detachedHead=false clone --quiet --depth 1 --branch "${tag}" "${url}" "/src/${name}"; \
        got="$(git -C "/src/${name}" rev-parse HEAD)"; \
        if [ "${want}" != "${got}" ]; then \
            echo "error: ${name} ${tag} is commit ${got}, but locks/upstream.lock pins ${want}. Either the tag was moved upstream or the pin is stale; do not paste the new commit in without finding out which" >&2; exit 1; \
        fi; \
        printf '%s\t%s\t%s\n' "${name}" "${tag}" "${got}" >>/src/pins; \
        echo "ok ${name} ${tag} ${got}"; \
    }; \
    fetch moby; fetch cli; fetch compose; fetch containerd; fetch runc; fetch tini

# Every pure Go binary, cross-compiled: CGO off, so the bytes do not depend on the
# build platform. moby, cli and containerd vendor their modules; compose does
# not, and its modules are downloaded and verified against its go.sum. -s -w drops
# the symbol table and DWARF; a panic still names its functions. No build time
# is embedded, and no VCS stamp.
FROM --platform=$BUILDPLATFORM ${MICA_BUILD_GO} AS go-cross
ARG TARGETARCH
COPY --from=src /src /src
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    set -eu; mkdir -p /out; \
    export CGO_ENABLED=0 GOOS=linux GOARCH="${TARGETARCH}" GOTOOLCHAIN=local; \
    ver() { awk -F'\t' -v n="$1" '$1 == n { print $2 }' /src/pins; }; \
    rev() { awk -F'\t' -v n="$1" '$1 == n { print $3 }' /src/pins; }; \
    moby="$(ver moby)"; moby="${moby#docker-v}"; \
    cd /src/moby; \
    go build -mod=vendor -trimpath -buildvcs=false \
        -tags "netgo osusergo static_build nri_no_wasm exclude_graphdriver_btrfs exclude_graphdriver_zfs" \
        -ldflags "-s -w -X github.com/moby/moby/v2/dockerversion.Version=${moby} -X github.com/moby/moby/v2/dockerversion.GitCommit=$(rev moby | cut -c1-7)" \
        -o /out/dockerd ./cmd/dockerd; \
    go build -mod=vendor -trimpath -buildvcs=false -ldflags "-s -w" -o /out/docker-proxy ./cmd/docker-proxy; \
    cd /src/cli; \
    cp vendor.mod go.mod; cp vendor.sum go.sum; \
    cli="$(ver cli)"; \
    go build -mod=vendor -trimpath -buildvcs=false -tags "osusergo netgo" \
        -ldflags "-s -w -X github.com/docker/cli/cli/version.Version=${cli#v} -X github.com/docker/cli/cli/version.GitCommit=$(rev cli | cut -c1-7)" \
        -o /out/docker ./cmd/docker; \
    cd /src/compose; \
    GOFLAGS=-mod=readonly go build -trimpath -buildvcs=false \
        -ldflags "-s -w -X github.com/docker/compose/v5/internal.Version=$(ver compose)" \
        -o /out/docker-compose ./cmd; \
    cd /src/containerd; \
    ctr="-s -w -X github.com/containerd/containerd/v2/version.Version=$(ver containerd) -X github.com/containerd/containerd/v2/version.Revision=$(rev containerd)"; \
    go build -mod=vendor -trimpath -buildvcs=false -tags "no_btrfs no_zfs urfave_cli_no_docs" -ldflags "${ctr}" -o /out/containerd ./cmd/containerd; \
    go build -mod=vendor -trimpath -buildvcs=false -ldflags "${ctr}" -o /out/containerd-shim-runc-v2 ./cmd/containerd-shim-runc-v2

# runc links libseccomp, so it is built at the target with the pinned build
# packages; docker-init is tini, static because it runs inside containers.
FROM ${MICA_BUILD_GO} AS cgo
ARG MICA_PINS_GO
RUN --mount=type=bind,from=pins,target=/pins \
    set -eu; [ -n "${MICA_PINS_GO}" ] || { echo "error: MICA_PINS_GO is empty; build.sh passes the pinned closure" >&2; exit 1; }; \
    set -- ; for sha in ${MICA_PINS_GO}; do set -- "$@" "/pins/${sha}.deb"; done; \
    dpkg --install "$@"
COPY --from=src /src/runc /src/runc
COPY --from=src /src/tini /src/tini
COPY --from=src /src/pins /src/pins
RUN --mount=type=cache,target=/root/.cache/go-build \
    set -eu; mkdir -p /out; cd /src/runc; \
    CGO_ENABLED=1 GOTOOLCHAIN=local go build -mod=vendor -trimpath -buildvcs=false -buildmode=pie \
        -tags "seccomp urfave_cli_no_docs" \
        -ldflags "-s -w -X main.gitCommit=$(awk -F'\t' '$1 == "runc" { print $3 }' /src/pins)" \
        -o /out/runc .; \
    /out/runc --version | grep -q 'seccomp' || \
        { echo "error: runc was built without seccomp; every container would run unconfined" >&2; exit 1; }
RUN set -eu; cd /src/tini; \
    tag="$(awk -F'\t' '$1 == "tini" { print $2 }' /src/pins)"; \
    printf '#define TINI_VERSION "%s"\n#define TINI_GIT ""\n' "${tag#v}" >/tmp/tiniConfig.h; \
    gcc -static -Os -std=gnu99 -D_FORTIFY_SOURCE=2 -I/tmp -o /out/docker-init src/tini.c; \
    strip --strip-all /out/docker-init

FROM ${MICA_BUILD_BASE} AS verify
# Each binary is a target ELF; everything but runc is static; NEEDED.txt is recorded.
ARG ELF_ARCH=aarch64
COPY --from=go-cross /out/ /out/
COPY --from=cgo /out/ /out/
RUN set -eu; cd /out; \
    all="dockerd docker-proxy docker docker-compose containerd containerd-shim-runc-v2 runc docker-init"; \
    for b in ${all}; do \
        test -f "$b" || { echo "error: $b was not produced by the build" >&2; exit 1; }; \
        file -b "$b" | grep -q "ELF 64-bit.*${ELF_ARCH}" || \
            { echo "error: $b is not an ${ELF_ARCH} ELF: $(file -b "$b")" >&2; exit 1; }; \
    done; \
    for b in dockerd docker-proxy docker docker-compose containerd containerd-shim-runc-v2 docker-init; do \
        file -b "$b" | grep -q 'statically linked' || \
            { echo "error: $b is dynamically linked; it is built with CGO off (docker-init: -static)" >&2; exit 1; }; \
    done; \
    objdump -p runc | awk '/NEEDED/{print "runc: "$2}' > /out/NEEDED.txt; \
    for b in ${all}; do \
        printf '%-24s %8s KiB  %s\n' "$b" "$(( $(stat -c%s "$b") / 1024 ))" "$(file -b "$b" | cut -c1-38)"; \
    done; \
    sha256sum ${all} > /out/SHA256SUMS

FROM scratch AS artifact
COPY --from=verify /out/ /
