# yt-stream-workspace

Stream one Hyprland workspace to YouTube, with a local preview.

Requires Hyprland 0.55+ with Lua configuration, PipeWire, and VAAPI H.264
encoding. On Arch/CachyOS:

```sh
./install.sh --deps --hypr-source --native
hyprctl reload
workspace-stream doctor && workspace-stream self-test
```

**Default audio includes your microphone and all desktop sound, including
other workspaces.** Disable either with `YTWS_MIC=none` or
`YTWS_DESKTOP_AUDIO=none`.

Settings: `~/.config/yt-stream-workspace/config`
([reference](config.example)). The stream key appears in the recorder's
command line.

```sh
workspace-stream start 3
workspace-stream test 5     # local video/audio test, seconds
workspace-stream live      # prompts for your YouTube stream key
workspace-stream stop
```

| Key | Action |
|---|---|
| Super+F11 | Control the stream workspace |
| Super+F12 | Return to your previous workspace |
| Super+F10 | Blank video and mute audio |

More commands: `workspace-stream --help`. Uninstall: `./uninstall.sh`.
