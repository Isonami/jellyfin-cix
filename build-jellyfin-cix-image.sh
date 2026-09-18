#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

IMAGE_TAG=${IMAGE_TAG:-jellyfin-cix:12.1-sky1.4}
IMAGE_VERSION=${IMAGE_VERSION:-$IMAGE_TAG}
PLATFORM=${PLATFORM:-linux/arm64}
JELLYFIN_BASE_IMAGE=${JELLYFIN_BASE_IMAGE:-docker.io/jellyfin/jellyfin:12.1}
BUILD_NETWORK=${BUILD_NETWORK:-}
NERDCTL_SNAPSHOTTER=${NERDCTL_SNAPSHOTTER:-overlayfs}
ENGINE=${CONTAINER_ENGINE:-}

if [[ -z "$ENGINE" ]]; then
    for candidate in docker podman nerdctl; do
        if command -v "$candidate" >/dev/null 2>&1; then
            ENGINE=$candidate
            break
        fi
    done
fi

if [[ -z "$ENGINE" ]]; then
    echo "No Docker, Podman, or nerdctl executable found" >&2
    exit 1
fi

network_args=()
if [[ -n "$BUILD_NETWORK" ]]; then
    network_args=(--network "$BUILD_NETWORK")
fi

common_args=(
    --platform "$PLATFORM"
    "${network_args[@]}"
    --build-arg "JELLYFIN_BASE_IMAGE=$JELLYFIN_BASE_IMAGE"
    --build-arg "IMAGE_VERSION=$IMAGE_VERSION"
    -f Dockerfile.cix
    -t "$IMAGE_TAG"
    .
)

case "$(basename "$ENGINE")" in
    docker)
        "$ENGINE" buildx build --load "${common_args[@]}"
        ;;
    podman)
        "$ENGINE" build "${common_args[@]}"
        ;;
    nerdctl)
        if ! command -v buildctl >/dev/null 2>&1; then
            echo "nerdctl image builds require buildctl and a running BuildKit daemon" >&2
            exit 1
        fi
        "$ENGINE" --snapshotter="$NERDCTL_SNAPSHOTTER" build "${common_args[@]}"
        ;;
    *)
        echo "Unsupported container engine: $ENGINE" >&2
        exit 1
        ;;
esac

echo "Built $IMAGE_TAG"
