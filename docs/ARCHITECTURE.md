# Architecture

```text
applications
    │
    ▼
workspace N ──moved to──▶ headless output YT-STREAM
    │                          ├─ wf-recorder -o YT-STREAM → RTMP/RTMPS
    │                          └─ wl-mirror → physical monitor
    ▼
private workspaces on physical outputs
```

## Capture contract

- Viewers see one Hyprland output, `YT-STREAM`; wf-recorder is always started
  with `-o YT-STREAM` and refuses to fall back to another output.
- While a session is active, `hyprland/yt-stream-workspace.lua` keeps an
  invariant from Hyprland's own event handlers (`workspace.active`,
  `workspace.created`, `workspace.move_to_monitor`,
  `workspace.special_active`, `monitor.added`, `monitor.removed`): the output
  shows the stream workspace (or the curtain) and no special workspace. These
  handlers run synchronously inside the action that changed the layout, so a
  correction lands before Hyprland renders the next frame and no capture ever
  contains the wrong workspace.
- The synchronous step needs no destination: it hides any special workspace on
  the output and re-activates the stream workspace there. Foreign workspaces
  left assigned to the output are inactive, so never rendered, and are moved
  to their own monitor on the next event-loop tick, when monitor hot-plugging
  has settled. (Hyprland migrates an unplugged monitor's workspaces before it
  announces the removal, and may migrate them onto the stream output.)
- Hyprland recreates a same-named output with the workspaces it remembers for
  it. The guard is armed before the output exists and finishes activation in
  `monitor.added`, so those reappearances are undone like any other.
- A configuration reload replaces Hyprland's Lua state. The module is
  `require`d from `hyprland.lua`, re-reads
  `$XDG_RUNTIME_DIR/yt-stream-workspace/compositor.lua`, and re-arms itself
  as part of the reload; Hyprland's protected `require` keeps an error in
  another config module from skipping it.
- Layer surfaces whose namespace does not match `YTWS_STREAM_LAYERS`, and
  windows whose class matches `YTWS_PRIVATE_WINDOWS`, carry Hyprland's
  `no_screen_share` rule during a session: every capture paints them black.
- The output sits below the physical layout and does not touch it, so the
  pointer only reaches it on purpose.

## Input handoff

Input is in the stream exactly when the output has focus. Focus changes from
any source (`Super+F11`/`Super+F12`, the stream workspace's key, any other
workspace key, a script) are followed: the physical monitor shows the preview
workspace while the output has focus and the workspace the streamer came from
otherwise. Hyprland emits `monitor.focused` before it records the new focus and
may move the pointer afterwards, so focus-dependent steps run on the next tick.
The preview window has `no_focus`, so showing it never takes input away from
the stream. The pointer is carried between the preview and the output at the
corresponding position.

The curtain switches the output to an empty persistent workspace,
`stream-curtain`, mutes the captured mix, moves the stream workspace to the
physical monitor, and refuses focus on the output until it is lowered.

## Video contract

The recorder uses H.264 VAAPI on a render node proven by a tiny FFmpeg encode:

```text
wf-recorder -o YT-STREAM -c h264_vaapi -d /dev/dri/renderD…
```

Resolution, rate, scale, bitrate, GOP, and device are configuration, but output
selection is invariant.

## Preview contract

`wl-mirror` is a preview, not the capture boundary. A window rule places it
fullscreen on the `stream-preview` workspace without decorations, animation,
blur, or focus.
Its automatic backend order prefers `extcopy-dmabuf`, then other DMA-BUF
paths, before shared-memory fallbacks. `YTWS_MIRROR_BACKEND=extcopy-dmabuf`
makes a path without a CPU framebuffer copy a requirement on systems that
support it.

The preview necessarily adds a presentation stage. Hyprland-native monitor
mirroring is not a safe replacement: Hyprland removes the mirrored physical
monitor from the logical monitor set and migrates its workspaces to another
monitor. If that monitor is `YT-STREAM`, private workspaces cross the capture
boundary. The windowed DMA-BUF mirror preserves monitor ownership and is the
intentional tradeoff.

## Audio contract

The prepared graph contains:

- `yt_stream_mix`, a null sink whose monitor `wf-recorder` captures;
- `yt_stream_output`, a combined sink feeding both the real output and mix;
- a loopback from the default microphone to the mix.

This yields desktop plus microphone with local monitoring. It is deliberately
global: visual isolation does not imply private audio.

## State and cleanup contract

Mode-700 state lives in `$XDG_RUNTIME_DIR/yt-stream-workspace/`:

- `state`: the CLI's record of session-defining configuration, original audio
  devices, created PipeWire/Pulse modules, helper PIDs, the live PID, the VAAPI
  node, and the Hyprland instance signature;
- `session.lua`: the session intent handed to the module;
- `compositor.lua` and `phase`: the module's own state (where each workspace
  came from, the preview monitor, input and curtain state, corrections).

Snapshotting configuration is essential: editing the config during a session
must not change which output or audio resources `stop` removes. A state file
written by an earlier Hyprland instance is recognised by its signature and
discarded.

`workspace-stream stop` stops delivery and helper processes, unloads temporary
audio modules and restores the original sink, asks the module to return the
stream workspace (keeping the streamer in it if they were working there) and
disable its rules, removes the headless output, and deletes runtime state. It
checks helper executable identity before signalling recorded PIDs and verifies
that the virtual output actually disappeared, because Hyprland can report
command errors with a successful process exit status.

Diagnostic logs live separately under
`${XDG_STATE_HOME:-$HOME/.local/state}/yt-stream-workspace`, so cleanup does not
destroy the evidence needed to diagnose a failed start or self-test.

Install-time ownership is separate. Markers record whether the installer
created or replaced the executable, config, and Hyprland module; replacements
have restorable backups. The source marker contains the exact require line
added to `hyprland.lua`.

## Upstream contracts

- [Hyprland output control](https://wiki.hypr.land/Configuring/Advanced-and-Cool/Using-hyprctl/)
  defines named headless output creation and removal.
- [wf-recorder](https://github.com/ammen99/wf-recorder) defines named output
  selection, audio source selection, codec parameters, VAAPI devices, and
  graceful signal handling.
- [wl-mirror](https://github.com/Ferdi265/wl-mirror) defines the preview backend
  preference order.
- [YouTube live encoder settings](https://support.google.com/youtube/answer/2853702)
  define the 60 fps maximum, H.264/AAC/CBR shape, and two-second recommended /
  four-second maximum keyframe interval enforced by configuration validation.
