# Architecture

`yt-stream-workspace` creates a second Hyprland output and records that output
explicitly.

```text
apps on stream workspace
        │
        ▼
Hyprland workspace N ──moved to──▶ headless output YT-STREAM
        │                              │
        │                              ├─ wf-recorder -o YT-STREAM ─▶ RTMP/RTMPS
        │                              │
        │                              └─ wl-mirror preview window
        │                                      │
        ▼                                      ▼
private physical workspaces ◀──────── physical monitor eDP/HDMI/etc.
```

The core invariant is output selection:

- visual capture is safe only when `wf-recorder` records `-o YT-STREAM`;
- where the `wf-recorder` process was launched from does not matter;
- normal keybinds should call `workspace-stream workspace ...` so that leaving
  the stream workspace does not accidentally switch the virtual output.

The implementation stores runtime state in:

```text
$XDG_RUNTIME_DIR/yt-stream-workspace/state
```

That state tracks the stream workspace, original physical monitor, preview
workspace, Pulse/PipeWire modules, mirror process, live process, and selected
VAAPI device.

## Video

Video is captured with:

```text
wf-recorder -o YT-STREAM -c h264_vaapi -d /dev/dri/renderD...
```

The script auto-detects a VAAPI render node by trying a tiny FFmpeg H.264 encode.
On Intel iGPU laptops this usually selects `/dev/dri/renderD128`.

## Audio

The script creates:

- `yt_stream_mix`: a null sink whose monitor is recorded by `wf-recorder`;
- `yt_stream_output`: a combined sink that sends desktop audio both to the real
  speakers/headphones and to the stream mix;
- a loopback from the default microphone into the stream mix.

That gives a convenient “desktop + mic” stream, but it is global audio. Visual
isolation does not imply audio isolation.

## Cleanup

`workspace-stream stop` stops live delivery, kills the mirror/background helper,
unloads the temporary audio modules, moves the workspace back to the original
monitor, removes the headless output, and removes runtime state.
