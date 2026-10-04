# yt-stream-workspace

Stream one Hyprland workspace to YouTube; every other workspace stays private.

```text
workspace N → headless output YT-STREAM → wf-recorder → YouTube
                    └→ preview window on your monitor
```

Viewers see one Hyprland output, `YT-STREAM`, and nothing else:

- The Lua module corrects the layout inside Hyprland's own event handlers,
  before a frame is rendered or captured. No other workspace, and no special
  workspace, ever reaches the output, whatever key, script or monitor change
  tries.
- On the output, layer surfaces (bars, notifications, launchers) are painted
  black in the capture unless allowed, and so are password-manager windows.
- The recorder only ever records `-o YT-STREAM`, never "whatever is focused".

## Install

Arch/CachyOS:

```sh
./install.sh --deps --hypr-source --native
hyprctl reload
workspace-stream doctor && workspace-stream self-test
```

- `--deps` installs the runtime packages (and the build tools with
  `--native`).
- `--hypr-source` adds `require("yt-stream-workspace")` to `hyprland.lua`,
  editing through a symlink and refusing a read-only file.
- `--native` builds the patched recorder and the preview client (see
  [Performance](#performance)) into `~/.local/share/yt-stream-workspace/bin`.
  Without them the tool falls back to stock `wf-recorder` and `wl-mirror`.

Nothing needs configuring to use them: `workspace-stream` looks in that
directory before `PATH`. `workspace-stream doctor` warns while a stock helper
is in use, and `workspace-stream status` prints `recorder: … (patched)` once the
patched one is. If you deploy the script without `install.sh` (a Nix or Home
Manager link, say), run `native/build.sh` yourself on each machine and again
after any change under `native/`; it builds against the system FFmpeg, Mesa and
PipeWire so that VAAPI encoding works.

`./uninstall.sh` removes exactly what was installed and restores what it
replaced. `--purge` also removes the config.

## Use

```sh
workspace-stream start 3     # isolate workspace 3 on the stream output
workspace-stream test 5      # record locally; checks H.264, AAC and sound
workspace-stream live        # go live; asks for the stream key
workspace-stream stop-live   # stop delivery, keep the session
workspace-stream stop        # restore everything
workspace-stream status      # what viewers see and hear, delivery health
```

`start` puts workspace 3 on a 1920x1080@60 headless output, placed below and
apart from your monitors. The physical monitor gets a fullscreen preview on
its own workspace, `stream-preview`. Input goes to the stream exactly when the
stream output has focus:

| Key | Command | Effect |
|---|---|---|
| `Super+F11` | `enter` | work in the stream through the preview |
| `Super+F12` | `leave` | back to the workspace you came from |
| `Super+F10` | `curtain` | viewers see an empty screen and hear nothing; the stream workspace comes to you |

Ordinary workspace keys work too. Rebind with
`YTWS.bind({ enter = "SUPER + F9", curtain = false })` after the require line.

`live` returns once YouTube acknowledges data. A supervisor then keeps
delivery going:

- It reconnects with backoff when the connection drops or stalls (nothing
  acknowledged for 10 s), and notifies you.
- After three refusals in a row it stops and says why, instead of looping.
- It restarts a crashed preview.
- It keeps the screen from blanking or locking while you are live.

To go live from a key binding, set `YTWS_STREAM_KEY_COMMAND` or
`YTWS_STREAM_KEY_FILE` (mode 600). The key never reaches a log, but
wf-recorder's command line does contain it.

## Audio

Viewers hear the null sink `yt_stream_mix`. While something records, plain
PipeWire links feed it the default output device's sound and the default
microphone, and follow either when it changes. Nothing is rerouted and your own
audio is untouched. Between recordings there are no links, so the microphone
stays closed. Set `YTWS_DESKTOP_AUDIO` / `YTWS_MIC` to `none` or a node name to
change the sources.

Desktop audio means everything your speakers play, including private
workspaces' sound.

## Performance

`native/build.sh` builds two helpers that remove the tool's overhead where
Hyprland allows it:

- **`ytws-preview`** captures the stream with ext-image-copy-capture and
  attaches each GPU buffer to its window unchanged. It never draws, captures
  only after the compositor has shown its last frame, and so does nothing while
  hidden or while the stream is still. (wl-mirror redraws and recommits on
  every frame.)
- **Patched wf-recorder** (`native/wf-recorder/*.patch`, on a pinned upstream
  commit):
  - Captures with ext-image-copy-capture. A pending wlr-screencopy frame makes
    Hyprland redraw the output at full rate even when nothing changes.
  - `--cfr` keeps YouTube's constant 60 fps by re-encoding the last frame in
    real time, instead of forcing redraws.
  - Native PipeWire capture of exactly the mix node: no fallback to another
    device, no Pulse round trip.
  - No polling loops.
  - Limited-range BT.709 video, labelled as such.
  - A failure exit status whenever the recording cannot continue.

Measured on an i7-8565U / UHD 620 at 1080p60 (CPU as % of one core, GPU as
render-engine busy time):

| | before | now |
|---|---|---|
| Preview shown, still stream | 12.5% CPU, 28.8% GPU | 0.6% CPU, 0.8% GPU |
| Live, still stream: Hyprland | 13.4% CPU, 40.6% GPU | 2.3% CPU, 4.2% GPU |
| Session running, not live: audio graph | ~11% CPU | 0 |
| Live, content changing every frame: total | 58.8% CPU | 53.4% CPU |

The remaining cost of a busy stream is Hyprland's: rendering the output,
copying each frame to the recorder and to the preview, and compositing the
preview. Hyprland also disables direct scanout while anything is captured.
Native monitor mirroring is not used: it would migrate your private workspaces
onto the captured output.

## Configure

`~/.config/yt-stream-workspace/config` (see `config.example`):

| Setting | Default | |
|---|---|---|
| `YTWS_OUTPUT`, `_WIDTH`, `_HEIGHT`, `_FPS`, `_SCALE` | `YT-STREAM`, 1920, 1080, 60, 1.5 | the stream output |
| `YTWS_VIDEO_BITRATE`, `_GOP`, `YTWS_AUDIO_BITRATE` | 12M, 120, 128k | YouTube's 1080p60 shape |
| `YTWS_DESKTOP_AUDIO`, `YTWS_MIC` | `default` | what viewers hear |
| `YTWS_STREAM_LAYERS` | wallpapers | layer namespaces left visible |
| `YTWS_PRIVATE_WINDOWS` | password managers | window classes always blacked out |
| `YTWS_PREVIEW_MONITOR` | where the workspace was | |
| `YTWS_RECORDER`, `YTWS_PREVIEW` | native builds, else PATH | |
| `YTWS_VAAPI_DEVICE` | first render node that encodes H.264 | |

## Diagnose

`workspace-stream doctor` checks prerequisites. If a start fails midway,
`workspace-stream stop` restores everything. `workspace-stream logs` names the
log directory, `${XDG_STATE_HOME:-~/.local/state}/yt-stream-workspace`, which
outlives sessions.

## How it works

- **Guard.** `hyprland/yt-stream-workspace.lua` keeps one invariant, from
  `workspace.*` and `monitor.*` events: the output shows the stream workspace
  (or the curtain) and no special workspace.
  - Synchronously, it hides any special workspace there and re-activates the
    stream workspace. Workspaces Hyprland migrated onto the output stay
    inactive (never rendered) until the next tick moves them home.
  - It arms before the output exists, so a recreated output's remembered
    workspaces are undone like anything else.
  - After a config reload it re-arms from
    `$XDG_RUNTIME_DIR/yt-stream-workspace/compositor.lua`.
- **Handoff.** Focus changes from any source are followed on the next tick,
  because Hyprland announces a focus change before recording it. The preview
  has `no_focus`, and the pointer is carried between preview and output at the
  matching position.
- **Supervisor.** One detached process per session owns the preview, the
  wallpaper, wf-recorder and the audio links:
  - Commands, and the stream key, arrive on a mode-600 FIFO.
  - Delivery is judged by the socket's `bytes_acked` from `ss`, not by bytes
    written.
  - Helpers stop with TERM.
  - An idle tick forks nothing.
- **State.** Everything lives in the mode-700
  `$XDG_RUNTIME_DIR/yt-stream-workspace/`. The session's configuration is
  snapshotted at `start`, so `stop` always removes what was created. A state
  file from an earlier Hyprland instance is discarded.
  - `stop` verifies helper identity before signalling it, and checks that the
    output is really gone, since Hyprland can report errors with exit status 0.

## Develop

```sh
make test    # syntax, ShellCheck, Lua guard model, CLI and supervisor tests
make smoke   # isolated install and uninstall
native/build.sh /tmp/native   # build the helpers anywhere
workspace-stream self-test    # full lifecycle in a live Hyprland session
```
