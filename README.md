# yt-stream-workspace

Stream one Hyprland workspace to YouTube while private workspaces remain local.

```text
stream workspace → headless output YT-STREAM → wf-recorder → YouTube
                         │
                         └→ wl-mirror preview on the physical monitor
```

Viewers see exactly one Hyprland output, `YT-STREAM`. While a session runs,
Hyprland itself keeps that boundary: the `yt-stream-workspace.lua` module reacts
inside the compositor's own event handlers, before a frame can be rendered or
captured, so no other workspace and no special workspace is ever shown there,
whichever key, script, or monitor change tries. Bars, notifications, launchers,
and other layer surfaces on the stream output are painted black in the capture
unless their namespace is allowed, and windows of password managers are always
painted black.

Desktop and microphone audio are still mixed globally.

## Install

The supported fast path is Arch/CachyOS with Hyprland:

```sh
git clone https://github.com/muradkant/yt-stream-workspace.git
cd yt-stream-workspace
./install.sh --deps --hypr-source
hyprctl reload
workspace-stream doctor
workspace-stream self-test
```

`--deps` installs `wf-recorder`, `wl-mirror`, `jq`, `ffmpeg`, `pipewire-pulse`,
`kitty`, `wtype`, and `iproute2` through pacman. On another distribution,
install those commands yourself and run `./install.sh --hypr-source`.
`swaybg` adds an optional virtual-output wallpaper; `shellcheck` strengthens
development checks.

Installation writes:

```text
~/.local/bin/workspace-stream
~/.config/yt-stream-workspace/config
~/.config/hypr/yt-stream-workspace.lua
```

With `--hypr-source`, it backs up `hyprland.lua` (Hyprland 0.55+ replaced the
hyprlang `.conf` format with Lua), appends `require("yt-stream-workspace")`
only when absent, and records ownership so `./uninstall.sh` removes only the
lines this installation added. A symlinked `hyprland.lua` is edited through the
link; a read-only one is refused before anything is installed. The module calls
no external command for its bindings, so non-default XDG paths need nothing
special.

The installer records whether it created or replaced each managed file.
Replaced executables and modules are backed up and restored by uninstall. A
normal uninstall preserves the user configuration; `--purge` removes a created
config or restores a replaced one:

```sh
./uninstall.sh          # preserve config
./uninstall.sh --purge  # remove created config or restore replaced config
```

## Stream

Prepare workspace 3:

```sh
workspace-stream start 3
```

This moves workspace 3 to a `1920x1080@60` headless output at scale 1.5, below
and apart from your monitors so the pointer never wanders onto it, selects a
working VAAPI H.264 render node, and creates the audio mix. A fullscreen preview
of the stream lives on its own workspace, `stream-preview`, on the monitor
workspace 3 came from. If you were working in workspace 3, you keep working in
it.

Input is in the stream exactly when the stream output has focus, and the
physical monitor then shows the preview:

- `Super+F11` (`workspace-stream enter`) works in the stream; the pointer keeps
  its place on the preview.
- `Super+F12` (`workspace-stream leave`) returns to the workspace you came from.
- Your ordinary workspace keys work too: the stream workspace's key enters,
  any other key leaves, and a new workspace opened from the stream appears on
  the physical monitor.
- `Super+F10` (`workspace-stream curtain`) raises the curtain: viewers
  instantly see an empty workspace and hear nothing, while the stream
  workspace moves to your monitor so you can fix whatever needed hiding.
  Press it again to resume.

Rebind the keys after the require line, for example
`YTWS.bind({ enter = "SUPER + F9", curtain = false })`.

Validate locally before publishing:

```sh
workspace-stream test 5
```

The test starts a temporary RTMP receiver, records only `YT-STREAM`, injects a
tone, and requires H.264 at the configured dimensions plus non-silent AAC.

Start and stop YouTube delivery:

```sh
workspace-stream live       # asks for the stream key without echo
workspace-stream stop-live  # leaves the prepared workspace intact
workspace-stream stop       # restores workspace, output, audio, and processes
```

`live` returns once YouTube is acknowledging the stream. From then on the
session's supervisor keeps it going: if the connection drops or stalls (no data
acknowledged for 10 seconds), it reconnects with a short backoff for as long as
you stay live, and a desktop notification says so. A key YouTube refuses three
times in a row stops with a clear message instead of retrying forever. To go
live from a key binding, set `YTWS_STREAM_KEY_COMMAND` (for example a
`secret-tool` or `pass` lookup) or `YTWS_STREAM_KEY_FILE` (mode 600). The key
reaches the supervisor through a private pipe and is removed from every log;
wf-recorder's own command line does contain it, which matters only on a machine
shared with other users.

While you are live the screen does not blank or lock: a blanked headless
output freezes the stream, and a lock screen is drawn on the stream output too.

`workspace-stream self-test` performs the entire local lifecycle on a temporary
workspace: virtual output, test terminal, keyboard handoff, return to the
physical monitor, RTMP, video, audio, and cleanup.

`workspace-stream status` reports the YouTube state (live time, delivered
bitrate, reconnects, or the reason it stopped), what the stream shows, where
your input is, the layer surfaces on the stream output and whether each is
hidden, and the corrections the guard has made. `status --json` gives the same
for a bar widget.

## Preview performance

The preview defaults to `wl-mirror`'s `auto` backend. It tries the GPU DMA-BUF
paths before shared memory; current Hyprland and wl-mirror releases normally
select `extcopy-dmabuf`. To reject a slower fallback instead of accepting it:

```sh
YTWS_MIRROR_BACKEND=extcopy-dmabuf
```

The recorder is also kept on the GPU: wf-recorder captures `YT-STREAM` through
DMA-BUF and H.264 encoding uses a tested VAAPI render node. `--no-damage` keeps
moving output paced at the configured 60 fps rather than recording only damage
events.

There is still an unavoidable distinction from a normal workspace. A normal
workspace is presented once; this design renders the headless output and then
presents a copied GPU buffer in a physical-output window. That can add a frame
of preview latency even when no frames are dropped. Hyprland's compositor-native
monitor mirroring is deliberately not used: it removes the physical output from
the logical layout and migrates its private workspaces onto the captured output,
which breaks the isolation contract.

`workspace-stream test` verifies encoded frame rate and media shape. It cannot
measure human-perceived input-to-preview latency. If preview motion is uneven,
first run `workspace-stream doctor`, require `extcopy-dmabuf`, and inspect the
persistent logs before changing resolution or frame rate.

## Configure

Edit `~/.config/yt-stream-workspace/config`:

```sh
YTWS_OUTPUT=YT-STREAM
YTWS_WIDTH=1920
YTWS_HEIGHT=1080
YTWS_FPS=60
YTWS_SCALE=1.5
YTWS_MIRROR_BACKEND=auto
YTWS_VIDEO_BITRATE=12M
YTWS_VIDEO_GOP=120
```

Leave `YTWS_VAAPI_DEVICE` unset unless detection chooses badly. The script tests
each `/dev/dri/renderD*` with a tiny FFmpeg H.264 encode and keeps the first
working node. Intel integrated graphics commonly provide this path; MX110/130
class NVIDIA GPUs do not provide NVENC.

The default audio graph sends desktop output to both the real speakers and a
stream sink, then loops the default microphone into that stream sink. If a
private application's audio must not leak, give it a separate PipeWire routing
policy before going live; visual separation cannot solve audio routing.

## Diagnose

```sh
workspace-stream status
workspace-stream doctor
```

If startup fails midway, `workspace-stream stop` is the first recovery step.
If the local RTMP port is occupied, change `YTWS_TEST_RTMP_PORT` (default
19350). If encoding fails, inspect `/dev/dri/renderD*` and set the tested node as
`YTWS_VAAPI_DEVICE`.

Logs survive session cleanup:

```sh
workspace-stream logs
```

They are stored under
`${XDG_STATE_HOME:-~/.local/state}/yt-stream-workspace`. Runtime ownership state
remains separate under `XDG_RUNTIME_DIR` and is removed after successful
cleanup.

The recorder's safety-critical shape is always:

```sh
wf-recorder -o YT-STREAM --audio=yt_stream_mix.monitor ...
```

Never substitute process location for `-o` output selection.

## Verify and develop

Repository checks are reproducible without modifying the real home directory:

```sh
make test   # syntax, ShellCheck, CLI/config behavior
make smoke  # isolated install, command load, and owned-config uninstall
```

Runtime verification needs a live Hyprland/PipeWire session:

```sh
workspace-stream self-test
```

[Architecture](docs/ARCHITECTURE.md) defines the capture, audio, state, and
cleanup contracts.
