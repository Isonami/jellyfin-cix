# Jellyfin CIX Sky1 agent guide

## Project skill

When updating the CIX patches to a newer Jellyfin Server or Jellyfin Web
release, load and follow:

- `.pi/skills/update-jellyfin-patches/SKILL.md`
- Pi command: `/skill:update-jellyfin-patches`

Do not simply make an old patch apply. Re-audit the new release's encoder
selection, hardware-decoder dispatch, filter construction, capability probing,
and dashboard codec visibility before regenerating patches.

## Persistent CIX requirements

- Use a distinct lowercase `HardwareAccelerationType.cix` wire value without
  renumbering existing enum members.
- Select V4L2M2M decoders explicitly; do not enable FFmpeg automatic decoder
  selection.
- Use Sky1 V4L2M2M H.264/HEVC/VP9 encoders only when advertised by FFmpeg.
- Do not emit unsupported V4L2M2M profile/level options.
- SDR: NV12 upload → bicubic `scale_opencl` → NV12 download.
- HDR: NV12 upload → bicubic `scale_opencl` with P010 output →
  `tonemap_opencl` with NV12 output → download. Scaling performs the format
  conversion on the GPU and must precede tone mapping.
- Preserve software fallbacks for unsupported filters, rotation, deinterlace,
  and subtitle paths.
- Keep the FFmpeg Sky1 multi-plane buffer-copy and packet `data_offset` fixes.

## Build checkouts

`jellyfin-server/` and `jellyfin-web/` are disposable. The top-level `build.sh`
script resets and cleans them before checking out the configured refs and
applying the configured patches. Never keep unique work only in those trees;
regenerate the versioned files under `patches/` first.
