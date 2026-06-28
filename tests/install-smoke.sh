#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export XDG_BIN_HOME="$HOME/.local/bin"
export XDG_CONFIG_HOME="$HOME/.config"

mkdir -p "$XDG_CONFIG_HOME/hypr"
printf '# test Hyprland config\n' >"$XDG_CONFIG_HOME/hypr/hyprland.conf"

"$ROOT/install.sh" --hypr-source >/tmp/yt-stream-workspace-install-smoke.log

test -x "$XDG_BIN_HOME/workspace-stream"
test -r "$XDG_CONFIG_HOME/yt-stream-workspace/config"
test -r "$XDG_CONFIG_HOME/hypr/yt-stream-workspace.conf"
grep -Fqx 'source = ~/.config/hypr/yt-stream-workspace.conf' \
    "$XDG_CONFIG_HOME/hypr/hyprland.conf"

"$XDG_BIN_HOME/workspace-stream" --help >/dev/null

"$ROOT/uninstall.sh" >/tmp/yt-stream-workspace-uninstall-smoke.log
test ! -e "$XDG_BIN_HOME/workspace-stream"
test ! -e "$XDG_CONFIG_HOME/hypr/yt-stream-workspace.conf"

printf 'install smoke test passed\n'
