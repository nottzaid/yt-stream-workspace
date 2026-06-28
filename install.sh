#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/yt-stream-workspace"
HYPR_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"
FORCE=0
INSTALL_DEPS=0
HYPR_SOURCE=0

for arg in "$@"; do
    case "$arg" in
    --force)
        FORCE=1
        ;;
    --deps)
        INSTALL_DEPS=1
        ;;
    --hypr-source)
        HYPR_SOURCE=1
        ;;
    -h|--help)
        printf 'Usage: ./install.sh [--force] [--deps] [--hypr-source]\n'
        printf '  --deps         install Arch/CachyOS runtime dependencies with pacman\n'
        printf '  --hypr-source  append the source line to ~/.config/hypr/hyprland.conf if missing\n'
        exit 0
        ;;
    *)
        printf 'install.sh: unknown argument: %s\n' "$arg" >&2
        exit 2
        ;;
esac
done

if [[ "$INSTALL_DEPS" == 1 ]]; then
    if ! command -v pacman >/dev/null 2>&1; then
        printf 'install.sh: --deps requires pacman; install dependencies manually for this distro\n' >&2
        exit 1
    fi
    sudo pacman -S --needed wf-recorder wl-mirror jq ffmpeg pipewire-pulse kitty wtype iproute2
fi

install -Dm755 "$ROOT/bin/workspace-stream" "$BIN_DIR/workspace-stream"

mkdir -p "$CONFIG_DIR" "$HYPR_DIR"
if [[ ! -e "$CONFIG_DIR/config" || "$FORCE" == 1 ]]; then
    install -Dm644 "$ROOT/config.example" "$CONFIG_DIR/config"
else
    printf 'Keeping existing config: %s\n' "$CONFIG_DIR/config"
fi

if [[ ! -e "$HYPR_DIR/yt-stream-workspace.conf" || "$FORCE" == 1 ]]; then
    install -Dm644 "$ROOT/hyprland/yt-stream-workspace.conf" "$HYPR_DIR/yt-stream-workspace.conf"
else
    printf 'Keeping existing Hyprland snippet: %s\n' "$HYPR_DIR/yt-stream-workspace.conf"
fi

if [[ "$HYPR_SOURCE" == 1 ]]; then
    HYPR_CONF="$HYPR_DIR/hyprland.conf"
    SOURCE_LINE='source = ~/.config/hypr/yt-stream-workspace.conf'
    if [[ ! -e "$HYPR_CONF" ]]; then
        printf 'install.sh: cannot use --hypr-source; missing %s\n' "$HYPR_CONF" >&2
        exit 1
    fi
    if grep -Fqx "$SOURCE_LINE" "$HYPR_CONF"; then
        printf 'Hyprland source line already present in %s\n' "$HYPR_CONF"
    else
        BACKUP="$HYPR_CONF.yt-stream-workspace.bak.$(date +%Y%m%d-%H%M%S)"
        cp "$HYPR_CONF" "$BACKUP"
        printf '\n# yt-stream-workspace\n%s\n' "$SOURCE_LINE" >>"$HYPR_CONF"
        printf 'Added Hyprland source line to %s\n' "$HYPR_CONF"
        printf 'Backup: %s\n' "$BACKUP"
    fi
fi

printf 'Installed workspace-stream to %s/workspace-stream\n' "$BIN_DIR"
printf 'Config: %s/config\n' "$CONFIG_DIR"
printf 'Hyprland snippet: %s/yt-stream-workspace.conf\n' "$HYPR_DIR"
printf '\n'
printf 'Add this line to hyprland.conf if you have not already:\n'
printf 'source = ~/.config/hypr/yt-stream-workspace.conf\n'
printf '\n'
printf 'Then reload Hyprland and run: workspace-stream self-test\n'
printf 'For prerequisite diagnostics, run: workspace-stream doctor\n'
