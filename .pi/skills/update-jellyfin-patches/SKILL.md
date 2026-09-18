---
name: update-jellyfin-patches
description: Port, audit, test, and regenerate the CIX Sky1 Jellyfin Server and Jellyfin Web patches for a newer Jellyfin release. Use when upgrading Jellyfin versions, rebasing CIX support, resolving patch failures, or changing the default Jellyfin refs used by the complete image build.
compatibility: Requires git, .NET/Node toolchains or a supported container engine, and this jellyfin-cix project layout.
---

# Update Jellyfin CIX patches

Run this workflow from the project root containing `build.sh`, `Dockerfile.cix`,
`patches/`, `jellyfin-server/`, and `jellyfin-web/`.

## Safety rules

- Treat `jellyfin-server/` and `jellyfin-web/` as disposable checkouts.
- Preserve the old versioned patches until the new patches pass validation.
- Never force an old hunk into a similarly named method without tracing the new
  command-generation path.
- Do not infer hardware support from FFmpeg codec presence alone; keep Jellyfin
  capability probing and runtime fallbacks.
- Do not introduce automatic V4L2M2M decoder selection.
- Do not change established filter ordering without an on-device benchmark and
  a successful decode of the resulting stream.

## 1. Establish the upgrade target

1. Identify the target stable Server and Web tags and record their exact commit
   IDs. Prefer matching release tags unless Jellyfin documents a different Web
   pairing.
2. Read the target release notes and inspect its build requirements:
   - `.NET SDK`/target framework and runtime identifier
   - Node version and package manager lockfile
   - official Jellyfin container tag and Debian base
   - expected `jellyfin-ffmpeg` package/ref
3. Record the current defaults and patches before editing:

```bash
./build.sh --help
git -C jellyfin-server status --short
git -C jellyfin-web status --short
```

Use a temporary migration area under `.build/patch-update/`; do not destroy the
only patched tree until its diff is safely represented under `patches/`.

## 2. Create clean target checkouts

```bash
rm -rf .build/patch-update
mkdir -p .build/patch-update

git clone --filter=blob:none --branch "$NEW_SERVER_REF" --single-branch \
  https://github.com/jellyfin/jellyfin.git \
  .build/patch-update/server

git clone --filter=blob:none --branch "$NEW_WEB_REF" --single-branch \
  https://github.com/jellyfin/jellyfin-web.git \
  .build/patch-update/web
```

Attempt the prior patches with `git apply --3way` when the old blob objects are
available. Otherwise use `git apply --reject` only to locate conflicts, then
port each change deliberately. Remove every `.rej` file after resolving it.

## 3. Re-audit the Server integration

Locate symbols by name rather than relying on old line numbers. At minimum,
inspect:

- `MediaBrowser.Model/Entities/HardwareAccelerationType.cs`
  - Append lowercase `cix`; never renumber existing values.
  - Confirm JSON/configuration serialization still emits `"cix"`.
- `MediaBrowser.MediaEncoding/Encoder/EncoderValidator.cs`
  - Probe CIX V4L2M2M decoders actually supplied by the patched FFmpeg.
  - Probe `h264_v4l2m2m`, `hevc_v4l2m2m`, and `vp9_v4l2m2m` encoders.
  - Confirm OpenCL scale, tone-map, overlay, and required options remain probed.
- `MediaBrowser.Controller/MediaEncoding/EncodingHelper.cs`
  - H.264/HEVC encoder mapping and explicit VP9 encoder selection.
  - Explicit CIX decoder mapping for supported H.264, HEVC, MPEG-1/2/4, VC-1,
    VP8, VP9, and AV1 decoders.
  - OpenCL initialization and filter-device selection.
  - CIX filter dispatch and safe software fallback.
  - Suppression of unsupported V4L2M2M profile and level arguments.
  - Even dimension alignment rather than legacy 64-pixel truncation.
  - Subtitle, deinterlace, rotation, direct-stream, and seek paths.

Search globally for every switch or comparison over `HardwareAccelerationType`.
Classify each occurrence as “CIX needs a branch” or “generic behavior is
correct”; do not assume the three files above remain sufficient.

### Required filter invariants

SDR:

```text
format=nv12,
hwupload=derive_device=opencl,
scale_opencl=...:format=nv12:algo=bicubic,
hwdownload,
format=nv12
```

HDR-to-SDR:

```text
format=nv12,
hwupload=derive_device=opencl,
scale_opencl=...:format=p010le:algo=bicubic,
tonemap_opencl=...:format=nv12,
hwdownload,
format=nv12
```

Sky1 currently exposes decoded system-memory frames as NV12, including 10-bit
sources. Do not reintroduce CPU-side `format=p010le` before upload. The scaler
must perform NV12-to-P010 conversion on OpenCL before tone mapping.

## 4. Re-audit Jellyfin Web

Find the current transcoding settings route and codec capability constants.
Ensure:

- The selector exposes `CIX Sky1 (V4L2M2M + OpenCL)` with wire value `cix`.
- CIX appears in the correct hardware-decoding codec lists.
- HEVC/VP9 10-bit controls are visible where supported.
- Hardware encoding and tone-mapping controls are not hidden for CIX.
- Generated SDK enum typing does not prevent posting or displaying `cix`.

Follow any UI refactor rather than preserving obsolete component structure.
Use Jellyfin's current localization pattern if labels have moved to translation
resources.

## 5. Add or update tests

Prefer focused regression tests over snapshotting an entire FFmpeg command.
Cover, where the target test architecture permits:

- `cix` enum serialization round-trip and stable existing numeric values.
- H.264, HEVC, and VP9 encoder selection plus software fallback.
- Explicit decoder selection and disabled-codec fallback.
- SDR filter order and NV12 output.
- HDR order: NV12 upload → P010 OpenCL scale → NV12 tone map.
- Missing OpenCL capability fallback.
- Absence of V4L2M2M profile/level arguments.

Run the relevant Server test projects and the Web production build. Also run
formatters or lint commands required by the target release.

## 6. Regenerate versioned patches

After the target checkouts contain only the intended changes:

```bash
git -C .build/patch-update/server diff --check
git -C .build/patch-update/web diff --check

git -C .build/patch-update/server diff --binary \
  > "patches/jellyfin-${NEW_VERSION}-cix-sky1.patch"
git -C .build/patch-update/web diff --binary \
  > "patches/jellyfin-web-${NEW_VERSION}-cix-sky1.patch"
```

Verify each patch against another clean checkout or by reversing it in the
patched checkout:

```bash
git -C .build/patch-update/server apply --check \
  --reverse "../../../patches/jellyfin-${NEW_VERSION}-cix-sky1.patch"
git -C .build/patch-update/web apply --check \
  --reverse "../../../patches/jellyfin-web-${NEW_VERSION}-cix-sky1.patch"
```

Inspect `git diff --stat` and the complete patches. Reject generated files,
build outputs, lockfile churn not required by the release, and unrelated
formatting.

## 7. Update build defaults

Update together:

- `build`
  - `JELLYFIN_SERVER_REF`
  - `JELLYFIN_WEB_REF`
  - default Server/Web patch paths
  - `JELLYFIN_FFMPEG_REF` when required
- `Dockerfile.cix`
  - .NET SDK image
  - Node image
  - default Jellyfin base image
- `README-CIX.md`
  - release/version examples and patch inventory

The build also accepts `JELLYFIN_SERVER_PATCH` and `JELLYFIN_WEB_PATCH`, which
can be used to test new patches before changing defaults.

## 8. End-to-end validation

Run a complete tagged build:

```bash
./build.sh "jellyfin-cix:${NEW_VERSION}-test"
```

On a Sky1 host, verify:

1. Jellyfin starts and reports the intended Server/Web/FFmpeg versions.
2. Mali OpenCL is detected.
3. Expected V4L2M2M decoders and H.264/HEVC/VP9 encoders are advertised.
4. SDR and HDR HLS transcodes use the required filter ordering.
5. Produced segments decode with `ffmpeg -v error -xerror`.
6. Playback seeking, subtitles, deinterlacing, rotation, and audio transcoding
   do not break the CIX path.
7. At least one 4K HDR → 1080p SDR benchmark records wall time and CPU time.
8. Container logs contain no repeated fallback, device-open, or filter
   reinitialization errors.

Use explicit device mappings for production. `--privileged` is acceptable only
for initial board validation.

## 9. Completion report

Report:

- old and new refs with exact commit IDs
- files/symbols changed and any upstream refactors encountered
- generated patch paths
- build and test commands with pass/fail counts
- on-device FFmpeg command/filter chain observed
- benchmark comparison
- known limitations and deferred work

Do not call the upgrade complete if patches merely apply; compilation, tests,
image construction, and on-device transcoding are separate required checks.
