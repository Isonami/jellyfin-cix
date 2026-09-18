#!/usr/bin/env bash
# Build an arm64 Jellyfin FFmpeg Debian package with CIX Sky1 V4L2M2M support.
# The local patch is derived from Sky1-Linux/ffmpeg-sky1 commits cb09195c,
# 96b7be03, and 5bf7db7c. It intentionally excludes automatic decoder
# selection while retaining the Sky1 multi-plane buffer-copy correction.
#
# Environment overrides:
#   JELLYFIN_REF   jellyfin-ffmpeg tag/branch (default: v7.1.4-3)
#   DISTRO         Jellyfin build target (default: trixie)
#   ARCH           Jellyfin build architecture (default: arm64)
#   BUILD_ROOT     disposable source/build directory (default: .build)
#   OUTPUT_DIR     package output directory (default: dist)
#   SKY1_REVISION  local Debian version suffix (default: 2)
#   PREPARE_ONLY   set to 1 to clone and patch without starting the build
#   CONTAINER_ENGINE  docker, podman, or nerdctl executable
#   BUILD_NETWORK     optional build/run network (for example: host)
#   NERDCTL_SNAPSHOTTER nerdctl snapshotter (default: overlayfs)
#
# The Jellyfin build wrapper only detects docker/podman. This script creates a
# temporary docker-compatible command shim when nerdctl is selected.
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY="https://github.com/jellyfin/jellyfin-ffmpeg.git"
readonly JELLYFIN_REF="${JELLYFIN_REF:-v7.1.4-3}"
readonly DISTRO="${DISTRO:-trixie}"
readonly ARCH="${ARCH:-arm64}"
readonly BUILD_ROOT="${BUILD_ROOT:-${SCRIPT_DIR}/.build}"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/dist}"
readonly SOURCE_DIR="${BUILD_ROOT}/jellyfin-ffmpeg"
readonly PATCH_FILE_FF7="${SCRIPT_DIR}/patches/0096-cix-sky1-v4l2m2m-ffmpeg7.patch"
readonly PATCH_FILE_FF8="${SCRIPT_DIR}/patches/0101-cix-sky1-v4l2m2m-ffmpeg8.patch"
readonly SKY1_REVISION="${SKY1_REVISION:-2}"
readonly PREPARE_ONLY="${PREPARE_ONLY:-0}"

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

for command in git python3; do
    command -v "${command}" >/dev/null 2>&1 || fail "${command} is required"
done
for patch_file in "${PATCH_FILE_FF7}" "${PATCH_FILE_FF8}"; do
    [[ -f "${patch_file}" ]] || fail "patch not found: ${patch_file}"
done
[[ "${SKY1_REVISION}" =~ ^[0-9]+$ ]] || fail "SKY1_REVISION must be numeric"

case "${DISTRO}" in
    bookworm|trixie|jammy|noble|resolute) ;;
    *) fail "unsupported DISTRO '${DISTRO}'" ;;
esac
case "${ARCH}" in
    amd64|arm64) ;;
    *) fail "unsupported ARCH '${ARCH}'" ;;
esac

mkdir -p "${BUILD_ROOT}" "${OUTPUT_DIR}"
OUTPUT_DIR="$(cd -- "${OUTPUT_DIR}" && pwd)"

# SOURCE_DIR is intentionally disposable so every build starts from the exact
# requested Jellyfin ref and cannot accidentally include previous changes.
rm -rf -- "${SOURCE_DIR}"
printf 'Cloning jellyfin-ffmpeg ref %s...\n' "${JELLYFIN_REF}"
git clone --filter=blob:none --branch "${JELLYFIN_REF}" --single-branch \
    "${REPOSITORY}" "${SOURCE_DIR}"

# Jellyfin carries a large Debian quilt series, including an RK3588 patch that
# modifies configure and Makefile. Applying Sky1 directly to the source makes
# that earlier patch fuzzy, which dpkg-source deliberately rejects. Install the
# Sky1 change as the final quilt patch instead.
package_version="$(python3 - "${SOURCE_DIR}/debian/changelog" <<'PY'
from pathlib import Path
import re
import sys
header = Path(sys.argv[1]).read_text().splitlines()[0]
match = re.match(r"^\S+ \(([^)]+)\)", header)
if not match:
    raise SystemExit(f"cannot parse changelog header: {header}")
print(match.group(1))
PY
)"
case "${package_version}" in
    7.*) selected_patch="${PATCH_FILE_FF7}" ;;
    8.*) selected_patch="${PATCH_FILE_FF8}" ;;
    *) fail "unsupported jellyfin-ffmpeg version '${package_version}'; expected FFmpeg 7 or 8" ;;
esac
patch_name="$(basename -- "${selected_patch}")"
printf 'Adding final Debian quilt patch %s...\n' "${patch_name}"
cp "${selected_patch}" "${SOURCE_DIR}/debian/patches/${patch_name}"
printf '%s\n' "${patch_name}" >> "${SOURCE_DIR}/debian/patches/series"

# Give the package a distinct version so it can coexist in an APT repository
# without being confused with the unmodified Jellyfin build.
python3 - "${SOURCE_DIR}/debian/changelog" "${SKY1_REVISION}" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
revision = sys.argv[2]
text = path.read_text()
lines = text.splitlines(keepends=True)
match = re.match(r"^(\S+) \(([^)]+)\)(.*)$", lines[0].rstrip("\n"))
if not match:
    raise SystemExit(f"cannot parse changelog header: {lines[0].rstrip()}")
version = match.group(2)
suffix = f"+sky1.{revision}"
if not version.endswith(suffix):
    version += suffix
newline = "\n" if lines[0].endswith("\n") else ""
lines[0] = f"{match.group(1)} ({version}){match.group(3)}{newline}"
path.write_text("".join(lines))
print(f"Package version: {version}")
PY

# Check the queued patch itself; dpkg-source will apply it after Jellyfin's
# existing series inside the build container.
for expected in \
    'ff_av1_v4l2m2m_decoder' \
    'ff_vp9_v4l2m2m_encoder' \
    'V4L2_PIX_FMT_AV01' \
    'ff_v4l2_format_v4l2_matches_codec' \
    'out->num_planes == 1'; do
    grep -F -q -- "${expected}" "${SOURCE_DIR}/debian/patches/${patch_name}" \
        || fail "Sky1 quilt patch is missing '${expected}'"
done
[[ "$(tail -n 1 "${SOURCE_DIR}/debian/patches/series")" == "${patch_name}" ]] \
    || fail "Sky1 patch is not last in debian/patches/series"

printf 'Prepared source: %s\n' "${SOURCE_DIR}"
git -C "${SOURCE_DIR}" diff --stat

if [[ "${PREPARE_ONLY}" == "1" ]]; then
    printf 'PREPARE_ONLY=1; skipping package build.\n'
    exit 0
fi

# Upstream's ./build recognizes docker and podman but not nerdctl. It also
# prefers docker whenever both are present, so install a narrowly scoped docker
# shim when the caller explicitly selects podman or nerdctl.
container_engine="${CONTAINER_ENGINE:-}"
if [[ -z "${container_engine}" ]]; then
    for candidate in docker podman nerdctl; do
        if command -v "${candidate}" >/dev/null 2>&1; then
            container_engine="${candidate}"
            break
        fi
    done
fi
[[ -n "${container_engine}" ]] || fail "docker, podman, or nerdctl is required for the package build"
engine_path="$(command -v "${container_engine}" 2>/dev/null || true)"
[[ -n "${engine_path}" ]] || fail "container engine not found: ${container_engine}"
engine_name="$(basename -- "${container_engine}")"

case "${engine_name}" in
    docker)
        ;;
    podman)
        shim_dir="${BUILD_ROOT}/container-cli-shim"
        mkdir -p "${shim_dir}"
        cat >"${shim_dir}/docker" <<EOF
#!/bin/sh
exec "${engine_path}" "\$@"
EOF
        chmod +x "${shim_dir}/docker"
        export PATH="${shim_dir}:${PATH}"
        printf 'Using podman through Docker compatibility shim: %s\n' "${engine_path}"
        ;;
    nerdctl)
        command -v buildctl >/dev/null 2>&1 \
            || fail "nerdctl package builds require buildctl and a running BuildKit daemon"
        shim_dir="${BUILD_ROOT}/container-cli-shim"
        mkdir -p "${shim_dir}"
        nerdctl_snapshotter="${NERDCTL_SNAPSHOTTER:-overlayfs}"
        build_network="${BUILD_NETWORK:-}"
        cat >"${shim_dir}/docker" <<EOF
#!/bin/sh
subcommand="\${1:-}"
if [ "\$#" -gt 0 ]; then shift; fi
case "\${subcommand}" in
    build)
        if [ -n "${build_network}" ]; then
            exec "${engine_path}" --snapshotter="${nerdctl_snapshotter}" build --network "${build_network}" "\$@"
        fi
        exec "${engine_path}" --snapshotter="${nerdctl_snapshotter}" build "\$@"
        ;;
    run)
        if [ -n "${build_network}" ]; then
            exec "${engine_path}" --snapshotter="${nerdctl_snapshotter}" run --net "${build_network}" "\$@"
        fi
        exec "${engine_path}" --snapshotter="${nerdctl_snapshotter}" run "\$@"
        ;;
    *) exec "${engine_path}" --snapshotter="${nerdctl_snapshotter}" "\${subcommand}" "\$@" ;;
esac
EOF
        chmod +x "${shim_dir}/docker"
        export PATH="${shim_dir}:${PATH}"
        printf 'Using nerdctl through Docker compatibility shim: %s\n' "${engine_path}"
        ;;
    *)
        fail "unsupported container engine: ${container_engine}"
        ;;
esac

# The repository build wrapper produces .deb files using the selected CLI.
printf 'Building Jellyfin FFmpeg for %s/%s...\n' "${DISTRO}" "${ARCH}"
(
    cd "${SOURCE_DIR}"
    ./build "${DISTRO}" "${ARCH}" "${OUTPUT_DIR}"
)

printf 'Build complete. Artifacts:\n'
find "${OUTPUT_DIR}" -maxdepth 1 -type f -printf '  %p\n' | sort
