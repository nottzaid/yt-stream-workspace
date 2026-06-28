# yt-stream-workspace

Stream one Hyprland workspace to YouTube while continuing to use private
workspaces locally.

This project creates a headless Hyprland output named `YT-STREAM`, moves one
workspace onto it, mirrors that output back to your real monitor for local
interaction, and records only that output with `wf-recorder`.

```text
stream workspace ─▶ headless output YT-STREAM ─▶ wf-recorder ─▶ YouTube
                         │
                         └▶ wl-mirror preview on your physical monitor
```

The default mode is `1920x1080 @ 60 Hz`, scale `1.5`, encoded with VAAPI H.264.

## Fast path

On an Arch/CachyOS Hyprland machine:

```bash
git clone git@github.com:muradkant/yt-stream-workspace.git
cd yt-stream-workspace
./install.sh --deps --hypr-source
```

Reload Hyprland, then run:

```bash
workspace-stream doctor
workspace-stream self-test
workspace-stream start 3
```

Use `Super+F11` to enter/control the stream workspace and `Super+F12` to return
to your private workspace.

## What this does and does not guarantee

The important rule:

```bash
wf-recorder -o YT-STREAM ...
```

It is the `-o YT-STREAM` output selection that isolates the video. Launching
`wf-recorder` “inside” the mirrored workspace is not the thing that protects you.
Process location does not define the capture source.

If you use:

```bash
workspace-stream live
```

the wrapper records `YT-STREAM` explicitly. Your private physical workspaces are
not part of that video capture while the stream workspace remains assigned to
`YT-STREAM`.

Limits you should understand:

- Audio is mixed globally by default: desktop audio plus microphone. A private
  app can leak through audio even if its pixels are not visible.
- Notifications, global overlays, pinned windows, or popups rendered on
  `YT-STREAM` can appear in the stream.
- Raw Hyprland commands can defeat the convenience guardrails. The recommended
  keybinds route normal workspace switching through `workspace-stream`.
- This is practical streaming isolation, not a security sandbox.

## Requirements

Tested on:

- Hyprland / wlroots
- PipeWire with PulseAudio compatibility (`pactl`)
- VAAPI H.264 encoding, usually Intel iGPU
- Arch/CachyOS

Install dependencies on Arch:

```bash
sudo pacman -S wf-recorder wl-mirror jq ffmpeg pipewire-pulse kitty wtype iproute2
```

Optional:

```bash
sudo pacman -S swaybg shellcheck
```

`swaybg` is only used for an optional wallpaper on the virtual output.
`shellcheck` is only used by the static test if installed.

NVIDIA note: MX110/MX130-class GPUs do not provide NVENC, so they cannot offload
this H.264 stream through `h264_nvenc`. On those laptops the Intel iGPU VAAPI
path is the useful hardware encoder.

## Install

```bash
git clone git@github.com:muradkant/yt-stream-workspace.git
cd yt-stream-workspace
./install.sh
```

This installs:

- `~/.local/bin/workspace-stream`
- `~/.config/yt-stream-workspace/config`
- `~/.config/hypr/yt-stream-workspace.conf`

Add this to your `hyprland.conf` if it is not already present. The installer can
do this for you with `./install.sh --hypr-source`.

```ini
source = ~/.config/hypr/yt-stream-workspace.conf
```

Then reload Hyprland:

```bash
hyprctl reload
```

Check that the machine has the expected runtime pieces:

```bash
workspace-stream doctor
```

The installed Hyprland snippet provides:

- `Super+F11`: enter/control the stream workspace
- `Super+F12`: leave back to the physical workspace
- commented examples for replacing `Super+1..0` with safe wrapper bindings

For best isolation during normal navigation, replace your existing workspace
bindings with wrapper bindings such as:

```ini
bind = SUPER,1,exec,~/.local/bin/workspace-stream workspace 1
bind = SUPER,2,exec,~/.local/bin/workspace-stream workspace 2
bind = SUPER,3,exec,~/.local/bin/workspace-stream workspace 3
bind = SUPER,4,exec,~/.local/bin/workspace-stream workspace 4
bind = SUPER,5,exec,~/.local/bin/workspace-stream workspace 5
bind = SUPER,6,exec,~/.local/bin/workspace-stream workspace 6
bind = SUPER,7,exec,~/.local/bin/workspace-stream workspace 7
bind = SUPER,8,exec,~/.local/bin/workspace-stream workspace 8
bind = SUPER,9,exec,~/.local/bin/workspace-stream workspace 9
bind = SUPER,0,exec,~/.local/bin/workspace-stream workspace 10
```

## Configure

Edit:

```bash
~/.config/yt-stream-workspace/config
```

Important defaults:

```bash
YTWS_OUTPUT=YT-STREAM
YTWS_WIDTH=1920
YTWS_HEIGHT=1080
YTWS_FPS=60
YTWS_SCALE=1.5
YTWS_VIDEO_BITRATE=12M
YTWS_VIDEO_GOP=120
```

Leave `YTWS_VAAPI_DEVICE` unset unless auto-detection chooses the wrong render
node. The script tests `/dev/dri/renderD*` and chooses the first node that can
perform a tiny VAAPI H.264 encode.

## Workflow

Prepare workspace 3 as the streamed workspace:

```bash
workspace-stream start 3
```

What happens:

- workspace 3 is moved to `YT-STREAM`;
- a fullscreen `wl-mirror` preview appears on your physical monitor;
- the virtual output is `1920x1080@60`, scale `1.5`;
- a mixed stream audio source is prepared.

Enter/control the stream workspace:

```bash
workspace-stream enter
```

or press `Super+F11`.

Leave back to your private physical workspace:

```bash
workspace-stream leave
```

or press `Super+F12`.

Run the local validation test before going live:

```bash
workspace-stream test 5
```

This starts a temporary local RTMP receiver, records `YT-STREAM`, injects a test
tone into the stream mix, and verifies the resulting file has H.264 video at the
configured resolution plus non-silent AAC audio.

Start YouTube delivery:

```bash
workspace-stream live
```

It prompts for your YouTube stream key without echoing it.

Stop only YouTube delivery:

```bash
workspace-stream stop-live
```

Stop everything and restore the desktop/audio state:

```bash
workspace-stream stop
```

## Automated self-test

When no stream session is active:

```bash
workspace-stream self-test
```

The self-test creates a temporary workspace, launches a small terminal target,
starts the virtual output, verifies keyboard input reaches the stream workspace,
leaves back to the physical monitor, and runs the local RTMP/audio/video test.

## Raw wf-recorder usage

If you do not use `workspace-stream live`, the minimum safety-critical part is:

```bash
wf-recorder -o YT-STREAM ...
```

Do not rely on launching the command from a particular workspace. Always specify
the output.

The wrapper’s default recording args are equivalent to:

```bash
wf-recorder \
  -o YT-STREAM \
  --no-damage \
  -r 60 \
  -c h264_vaapi \
  -d /dev/dri/renderD128 \
  -p rc_mode=CBR \
  -p b=12M \
  -p maxrate=12M \
  -p bufsize=24M \
  -p g=120 \
  -p profile=high \
  -b 2 \
  --audio=yt_stream_mix.monitor \
  -C aac \
  -P b=128k \
  -R 48000
```

The actual VAAPI device is auto-detected and can differ from `/dev/dri/renderD128`.

## Troubleshooting

Check status:

```bash
workspace-stream status
```

If startup fails halfway:

```bash
workspace-stream stop
```

If the local RTMP test says the port is in use, change:

```bash
YTWS_TEST_RTMP_PORT=19351
```

If video encoding fails, inspect your render nodes:

```bash
ls -l /dev/dri/renderD*
```

Then set a known-good device in the config:

```bash
YTWS_VAAPI_DEVICE=/dev/dri/renderD128
```

If private audio must never leak, do not use the default global audio mix. Run
private applications on a different sink/source routing policy before going live.

## Development

Static checks:

```bash
make test
```

Runtime validation:

```bash
workspace-stream self-test
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for details.
