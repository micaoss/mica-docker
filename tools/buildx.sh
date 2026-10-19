#!/usr/bin/env bash
# Sourced by build.sh and tools/package.sh: buildx_builder <arch> sets BUILDER.
# BUILDX_BUILDER wins; otherwise `default` when it offers linux/<arch>, else the
# mica-<arch> docker-container builder, whose buildkit bundles the emulators.
# Output is captured before grep: an early-exiting grep under pipefail inverts.
buildx_builder() {
    local arch="$1" inspect
    command -v docker >/dev/null 2>&1 || { echo "error: docker is required and not on PATH" >&2; return 1; }
    if [ -n "${BUILDX_BUILDER:-}" ]; then
        BUILDER="${BUILDX_BUILDER}"
    else
        inspect="$(docker buildx inspect default 2>/dev/null || true)"
        if printf '%s\n' "${inspect}" | grep -c "linux/${arch}" >/dev/null; then
            BUILDER=default
        else
            BUILDER="mica-${arch}"
            docker buildx inspect "${BUILDER}" >/dev/null 2>&1 ||
                docker buildx create --name "${BUILDER}" --driver docker-container \
                    --driver-opt "image=$("$(dirname "${BASH_SOURCE[0]}")/../bin/mica-tools" from --ref upstream:moby/buildkit:v0.33.0)" >/dev/null
        fi
    fi
    # A docker-container builder's buildkit emulates without listing the
    # platform; only a docker-driver builder is refused for a missing one.
    inspect="$(docker buildx inspect "${BUILDER}" 2>/dev/null || true)"
    case "$(printf '%s\n' "${inspect}" | sed -n 's/^Driver:[[:space:]]*//p')" in
    "") echo "error: \`docker buildx inspect ${BUILDER}\` names no driver" >&2; return 1 ;;
    docker)
        printf '%s\n' "${inspect}" | grep -c "linux/${arch}" >/dev/null || {
            echo "error: the docker-driver builder '${BUILDER}' does not offer linux/${arch}; register the emulator (docker run --privileged --rm tonistiigi/binfmt --install ${arch}) or unset BUILDX_BUILDER" >&2
            return 1
        }
        ;;
    esac
}
