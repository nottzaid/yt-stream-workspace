#!/usr/bin/env bash
set -Eeuo pipefail

BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/yt-stream-workspace"
HYPR_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"

printf 'This removes only files installed by yt-stream-workspace.\n'
printf 'It does not edit hyprland.conf; remove any source line manually if needed.\n'

rm -f "$BIN_DIR/workspace-stream"
rm -f "$HYPR_DIR/yt-stream-workspace.conf"

if [[ -d "$CONFIG_DIR" ]]; then
    rm -f "$CONFIG_DIR/config"
    rmdir "$CONFIG_DIR" 2>/dev/null || true
fi

printf 'Uninstalled yt-stream-workspace files.\n'
