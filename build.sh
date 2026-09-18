#!/usr/bin/env bash
# Build the complete Jellyfin CIX Sky1 image.
#
# Usage:
#   ./build.sh <image-tag>
#
# The build checks out clean Jellyfin Server and Web sources, applies the CIX
# patches, downloads the newest CIX GPU userspace package, builds the patched
# Jellyfin FFmpeg Debian package, publishes Jellyfin through the Dockerfile
# stages, and produces the requested final container image.
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

usage() {
    cat <<'EOF'
Usage: ./build.sh <image-tag>

Example:
  ./build.sh ghcr.io/example/jellyfin-cix:12.1-sky1.4

Environment overrides:
  CONTAINER_ENGINE       docker, podman, or nerdctl executable
  PLATFORM               final image platform (default: linux/arm64)
  ARCH                   Debian package architecture (default: arm64)
  DISTRO                  Debian suite (default: trixie)
  JELLYFIN_SERVER_REF     Jellyfin Server ref (default: v12.1)
  JELLYFIN_WEB_REF        Jellyfin Web ref (default: v12.1)
  JELLYFIN_SERVER_REPO    Jellyfin Server repository URL
  JELLYFIN_WEB_REPO       Jellyfin Web repository URL
  JELLYFIN_SERVER_PATCH   server patch path
  JELLYFIN_WEB_PATCH      web patch path
  JELLYFIN_FFMPEG_REF     jellyfin-ffmpeg ref (default: v8.1.2-5)
  SKY1_REVISION           Sky1 Debian revision (default: 2)
  JELLYFIN_BASE_IMAGE     final base image (default: jellyfin/jellyfin:12.1)
  BUILD_ROOT              disposable FFmpeg build directory
  OUTPUT_DIR              package output directory (default: dist)
  BUILD_NETWORK           optional container-build network (for example: host)
  NERDCTL_SNAPSHOTTER     nerdctl snapshotter (default: overlayfs)
  SUITE, COMPONENT,
  REPO_URL                CIX package repository overrides
EOF
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    usage
    exit 0
fi
if [[ $# -ne 1 ]]; then
    usage >&2
    exit 2
fi

readonly IMAGE_TAG=$1
readonly PLATFORM=${PLATFORM:-linux/arm64}
readonly ARCH=${ARCH:-arm64}
readonly DISTRO=${DISTRO:-trixie}
readonly CIX_SUITE=${SUITE:-$DISTRO}
readonly JELLYFIN_SERVER_REF=${JELLYFIN_SERVER_REF:-v12.1}
readonly JELLYFIN_WEB_REF=${JELLYFIN_WEB_REF:-v12.1}
readonly JELLYFIN_SERVER_REPO=${JELLYFIN_SERVER_REPO:-https://github.com/jellyfin/jellyfin.git}
readonly JELLYFIN_WEB_REPO=${JELLYFIN_WEB_REPO:-https://github.com/jellyfin/jellyfin-web.git}
readonly JELLYFIN_SERVER_PATCH=${JELLYFIN_SERVER_PATCH:-${SCRIPT_DIR}/patches/jellyfin-12.1-cix-sky1.patch}
readonly JELLYFIN_WEB_PATCH=${JELLYFIN_WEB_PATCH:-${SCRIPT_DIR}/patches/jellyfin-web-12.1-cix-sky1.patch}
readonly JELLYFIN_FFMPEG_REF=${JELLYFIN_FFMPEG_REF:-v8.1.2-5}
readonly SKY1_REVISION=${SKY1_REVISION:-2}
readonly JELLYFIN_BASE_IMAGE=${JELLYFIN_BASE_IMAGE:-docker.io/jellyfin/jellyfin:12.1}
output_dir=${OUTPUT_DIR:-${SCRIPT_DIR}/dist}
readonly BUILD_ROOT=${BUILD_ROOT:-${SCRIPT_DIR}/.build}

if [[ "$IMAGE_TAG" =~ [[:space:]] ]]; then
    echo "Invalid image tag containing whitespace: $IMAGE_TAG" >&2
    exit 2
fi
if [[ "$ARCH" != "arm64" ]]; then
    echo "CIX GPU userspace and the final image currently require ARCH=arm64" >&2
    exit 2
fi

for path in \
    "$SCRIPT_DIR/download-cix-gpu-umd.sh" \
    "$SCRIPT_DIR/build-jellyfin-ffmpeg-sky1.sh" \
    "$SCRIPT_DIR/build-jellyfin-cix-image.sh" \
    "$SCRIPT_DIR/Dockerfile.cix" \
    "$JELLYFIN_SERVER_PATCH" \
    "$JELLYFIN_WEB_PATCH"; do
    [[ -e "$path" ]] || {
        echo "Required build input not found: $path" >&2
        exit 1
    }
done

for command in git dpkg dpkg-deb; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "Required command not found: $command" >&2
        exit 1
    }
done

mkdir -p "$output_dir"
readonly OUTPUT_DIR="$(cd -- "$output_dir" && pwd)"

prepare_source() {
    local name=$1
    local repository=$2
    local ref=$3
    local target=$4
    local patch_file=$5

    printf '\n==> Checking out %s %s\n' "$name" "$ref"
    if [[ -d "$target/.git" ]]; then
        # These directories are disposable build inputs. Reset them so stale
        # generated files or previous patches cannot leak into the image.
        git -C "$target" reset --hard HEAD
        git -C "$target" clean -ffdx
        git -C "$target" remote set-url origin "$repository"
    else
        rm -rf -- "$target"
        mkdir -p "$target"
        git -C "$target" init --quiet
        git -C "$target" remote add origin "$repository"
    fi

    # Fetching into FETCH_HEAD supports tags, branches, and explicit commits.
    git -C "$target" fetch --force --depth=1 origin "$ref"
    git -C "$target" checkout --force --detach FETCH_HEAD
    git -C "$target" clean -ffdx

    git -C "$target" apply --check "$patch_file"
    git -C "$target" apply "$patch_file"
    git -C "$target" diff --check
    printf 'Applied %s\n' "$(basename -- "$patch_file")"
}

prepare_source \
    "Jellyfin Server" \
    "$JELLYFIN_SERVER_REPO" \
    "$JELLYFIN_SERVER_REF" \
    "$SCRIPT_DIR/jellyfin-server" \
    "$JELLYFIN_SERVER_PATCH"

prepare_source \
    "Jellyfin Web" \
    "$JELLYFIN_WEB_REPO" \
    "$JELLYFIN_WEB_REF" \
    "$SCRIPT_DIR/jellyfin-web" \
    "$JELLYFIN_WEB_PATCH"

[[ -f "$SCRIPT_DIR/jellyfin-server/Jellyfin.Server/Jellyfin.Server.csproj" ]] \
    || { echo "Jellyfin Server project was not found after checkout" >&2; exit 1; }
[[ -f "$SCRIPT_DIR/jellyfin-web/package.json" ]] \
    || { echo "Jellyfin Web package.json was not found after checkout" >&2; exit 1; }

printf '\n==> Downloading latest CIX GPU userspace package\n'
env \
    SUITE="$CIX_SUITE" \
    ARCH="$ARCH" \
    OUTPUT_DIR="$OUTPUT_DIR" \
    "$SCRIPT_DIR/download-cix-gpu-umd.sh"

printf '\n==> Building patched Jellyfin FFmpeg %s\n' "$JELLYFIN_FFMPEG_REF"
env \
    JELLYFIN_REF="$JELLYFIN_FFMPEG_REF" \
    DISTRO="$DISTRO" \
    ARCH="$ARCH" \
    SKY1_REVISION="$SKY1_REVISION" \
    BUILD_ROOT="$BUILD_ROOT" \
    OUTPUT_DIR="$OUTPUT_DIR" \
    CONTAINER_ENGINE="${CONTAINER_ENGINE:-}" \
    BUILD_NETWORK="${BUILD_NETWORK:-}" \
    NERDCTL_SNAPSHOTTER="${NERDCTL_SNAPSHOTTER:-overlayfs}" \
    "$SCRIPT_DIR/build-jellyfin-ffmpeg-sky1.sh"

expected_version="${JELLYFIN_FFMPEG_REF#v}+sky1.${SKY1_REVISION}-${DISTRO}"
ffmpeg_deb=""
shopt -s nullglob
for candidate in "$OUTPUT_DIR"/*.deb; do
    package=$(dpkg-deb --field "$candidate" Package 2>/dev/null || true)
    version=$(dpkg-deb --field "$candidate" Version 2>/dev/null || true)
    architecture=$(dpkg-deb --field "$candidate" Architecture 2>/dev/null || true)
    if [[ "$package" == jellyfin-ffmpeg* \
        && "$version" == "$expected_version" \
        && "$architecture" == "$ARCH" ]]; then
        ffmpeg_deb=$candidate
        break
    fi
done
shopt -u nullglob

if [[ -z "$ffmpeg_deb" ]]; then
    echo "Could not find the expected FFmpeg package:" >&2
    echo "  version:      $expected_version" >&2
    echo "  architecture: $ARCH" >&2
    exit 1
fi

stable_ffmpeg_deb="$OUTPUT_DIR/jellyfin-ffmpeg-sky1_${ARCH}.deb"
if ! ln -f "$ffmpeg_deb" "$stable_ffmpeg_deb" 2>/dev/null; then
    cp -f "$ffmpeg_deb" "$stable_ffmpeg_deb"
fi
printf 'FFmpeg package: %s\n' "$stable_ffmpeg_deb"

# Docker COPY sources must live inside the fixed build context even when the
# caller sends package artifacts to another OUTPUT_DIR.
context_dist="$SCRIPT_DIR/dist"
mkdir -p "$context_dist"
for source in \
    "$stable_ffmpeg_deb" \
    "$OUTPUT_DIR/cix-gpu-umd_${ARCH}.deb"; do
    target="$context_dist/$(basename -- "$source")"
    if [[ "$(readlink -f "$source")" != "$(readlink -f "$target" 2>/dev/null || true)" ]]; then
        if ! ln -f "$source" "$target" 2>/dev/null; then
            cp -f "$source" "$target"
        fi
    fi
done
printf 'FFmpeg build input: %s\n' "$context_dist/jellyfin-ffmpeg-sky1_${ARCH}.deb"
printf 'CIX GPU build input: %s\n' "$context_dist/cix-gpu-umd_${ARCH}.deb"

printf '\n==> Building Jellyfin Server, Web, and final image\n'
env \
    IMAGE_TAG="$IMAGE_TAG" \
    IMAGE_VERSION="${IMAGE_VERSION:-$IMAGE_TAG}" \
    PLATFORM="$PLATFORM" \
    JELLYFIN_BASE_IMAGE="$JELLYFIN_BASE_IMAGE" \
    CONTAINER_ENGINE="${CONTAINER_ENGINE:-}" \
    BUILD_NETWORK="${BUILD_NETWORK:-}" \
    NERDCTL_SNAPSHOTTER="${NERDCTL_SNAPSHOTTER:-overlayfs}" \
    "$SCRIPT_DIR/build-jellyfin-cix-image.sh"

printf '\nBuild complete: %s\n' "$IMAGE_TAG"
