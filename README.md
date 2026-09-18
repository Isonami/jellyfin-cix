# Jellyfin 12.1 for CIX Sky1

This repo contains patches required for jellyfin hardware acceleration on Radxa o6n running on "Radxa OS".

FFmpeg patches are comming from: https://github.com/Sky1-Linux/ffmpeg-sky1

GPU driver from CIX ppa: https://github.com/cixtech/cix-developer-docs/wiki/CIX%20PPA%20User%20Manual%20%28Open%E2%80%90Source%20Driver%20Edition%29

Patches for Jellyfin server and UI were writen by Agent.

Transcode options where discovered by manual experiments and validated with Agent.

## Upgrades

For future Jellyfin release upgrades, use the project skill at
`.pi/skills/update-jellyfin-patches/SKILL.md` (or
`/skill:update-jellyfin-patches`). See `AGENTS.md` for persistent invariants.

This tree carries CIX Sky1 support for Jellyfin Server and Jellyfin Web 12.1,
plus the patched Jellyfin FFmpeg 8 package.

## Patches

- `patches/jellyfin-12.1-cix-sky1.patch` applies to `jellyfin/jellyfin` tag `v12.1`.
- `patches/jellyfin-web-12.1-cix-sky1.patch` applies to `jellyfin/jellyfin-web` tag `v12.1`.
- `patches/0101-cix-sky1-v4l2m2m-ffmpeg8.patch` is packaged by
  `build-jellyfin-ffmpeg-sky1.sh`.

The server patch adds a distinct `cix` hardware acceleration type. It uses
explicit V4L2M2M decoding and encoding and Mali OpenCL scaling for SDR and HDR.
HDR is bicubic-scaled first while OpenCL converts NV12 to P010, then tone-mapped at the reduced resolution.

Apply the patches to clean checkouts with:

```bash
git -C jellyfin checkout v12.1
git -C jellyfin apply ../patches/jellyfin-12.1-cix-sky1.patch

git -C jellyfin-web checkout v12.1
git -C jellyfin-web apply ../patches/jellyfin-web-12.1-cix-sky1.patch
```

## Image build

The build context expects the patched trees at `jellyfin-server/` and
`jellyfin-web/`.

Build the complete stack with a required image tag:

```bash
./build.sh registry.example.com/jellyfin-cix:12.1-sky1.4
```

This checks out clean Jellyfin Server and Web `v12.1` sources, applies both CIX
patches, downloads and verifies the newest CIX GPU package, builds the patched
Jellyfin FFmpeg package, creates stable package inputs under `dist/`, builds
Jellyfin Server and Web, and assembles the final image. Run `./build.sh --help`
for repository, ref, engine, and package overrides.

`jellyfin-server/` and `jellyfin-web/` are disposable build checkouts: the
script resets and cleans them before every build so local changes cannot leak
into the image.

The final Docker build consumes:

- `dist/jellyfin-ffmpeg-sky1_arm64.deb`
- `dist/cix-gpu-umd_arm64.deb`

Download and verify the newest CIX GPU userspace package published for Debian
Trixie ARM64:

```bash
./download-cix-gpu-umd.sh
```

Override `SUITE`, `ARCH`, `COMPONENT`, `REPO_URL`, or `OUTPUT_DIR` through the
environment when needed. The script reads the repository's `Packages.gz`, uses
Debian version ordering, verifies the advertised size and SHA-256 digest, keeps
the versioned `.deb`, and creates the stable filename consumed by the
Dockerfile.

To rebuild only the final image after both stable package inputs already exist,
use:

```bash
IMAGE_TAG=jellyfin-cix:12.1-sky1.4 ./build-jellyfin-cix-image.sh
```

The default platform is `linux/arm64`. nerdctl requires `buildctl` and a
running BuildKit daemon for both the FFmpeg and final Dockerfile builds.

## Test deployment

For initial validation, privileged mode avoids device-cgroup and group-ID
mismatches:

```bash
nerdctl --snapshotter=overlayfs run -d \
  --name jellyfin-cix-test \
  --net=host \
  --privileged \
  -v /path/to/config:/config \
  -v /path/to/cache:/cache \
  -v /path/to/media:/media:ro \
  jellyfin-cix:12.1-sky1.4
```

A production deployment should replace `--privileged` with access to the CIX
video, Mali, DRM, and DMA-heap devices required by the installed BSP.

In **Dashboard → Playback → Transcoding**:

1. Select **CIX Sky1 (V4L2M2M + OpenCL)**.
2. Enable the desired hardware decoders, including HEVC/AV1/VP9 as needed.
3. Enable hardware encoding.
4. Enable tone mapping for HDR-to-SDR clients.
5. Optionally enable HEVC encoding for compatible clients.

Expected HDR filter ordering:

```text
format=nv12,hwupload=derive_device=opencl,
scale_opencl=...:format=p010le:algo=bicubic,
tonemap_opencl=...:format=nv12,
hwdownload,format=nv12
```

Expected SDR filter ordering:

```text
format=nv12,hwupload=derive_device=opencl,
scale_opencl=...:format=nv12:algo=bicubic,
hwdownload,format=nv12
```
