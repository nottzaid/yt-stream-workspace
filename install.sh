#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/yt-stream-workspace"
HYPR_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"
HYPR_SOURCE_MARKER="$CONFIG_DIR/hypr-source-added"
INSTALL_STATE_DIR="$CONFIG_DIR/.install-state"
BACKUP_DIR="$INSTALL_STATE_DIR/backups"
BIN_MARKER="$INSTALL_STATE_DIR/bin"
CONFIG_MARKER="$INSTALL_STATE_DIR/config"
SNIPPET_MARKER="$INSTALL_STATE_DIR/hypr-snippet"
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
        printf '  --force        replace existing project files after backing them up\n'
        printf '  --deps         install Arch/CachyOS runtime dependencies with pacman\n'
        printf '  --hypr-source  append a require line for yt-stream-workspace to hyprland.lua if missing\n'
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

HYPR_LUA="$HYPR_DIR/hyprland.lua"
REQUIRE_LINE='require("yt-stream-workspace")'
REQUIRE_COMMENT='-- yt-stream-workspace'
if [[ "$HYPR_SOURCE" == 1 ]]; then
    if [[ ! -e "$HYPR_LUA" ]]; then
        printf 'install.sh: cannot use --hypr-source; missing %s\n' "$HYPR_LUA" >&2
        exit 1
    fi
    # hyprland.lua is often a symlink into a dotfiles tree or a read-only
    # store; edit the file it resolves to, and refuse before installing
    # anything when that file cannot be edited.
    HYPR_LUA_TARGET="$(readlink -f -- "$HYPR_LUA")"
    if ! grep -Fqx "$REQUIRE_LINE" "$HYPR_LUA_TARGET" && [[ ! -w "$HYPR_LUA_TARGET" ]]; then
        printf 'install.sh: cannot use --hypr-source; %s is not writable\n' "$HYPR_LUA_TARGET" >&2
        printf 'Add this line to your Hyprland config yourself: %s\n' "$REQUIRE_LINE" >&2
        exit 1
    fi
fi

backup_unowned_file() {
    local target="$1"
    local marker="$2"
    local backup="$3"

    if [[ ! -e "$marker" ]]; then
        mkdir -p "$BACKUP_DIR"
        cp -a -- "$target" "$backup"
        printf 'replaced\n' >"$marker"
    fi
}

mark_created() {
    local marker="$1"
    [[ -e "$marker" ]] || printf 'created\n' >"$marker"
}

mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$HYPR_DIR" "$INSTALL_STATE_DIR"

if [[ -e "$BIN_DIR/workspace-stream" ]]; then
    backup_unowned_file \
        "$BIN_DIR/workspace-stream" "$BIN_MARKER" "$BACKUP_DIR/workspace-stream"
else
    mark_created "$BIN_MARKER"
fi
install -Dm755 "$ROOT/bin/workspace-stream" "$BIN_DIR/workspace-stream"

if [[ ! -e "$CONFIG_DIR/config" ]]; then
    mark_created "$CONFIG_MARKER"
    install -Dm644 "$ROOT/config.example" "$CONFIG_DIR/config"
elif [[ "$FORCE" == 1 ]]; then
    backup_unowned_file "$CONFIG_DIR/config" "$CONFIG_MARKER" "$BACKUP_DIR/config"
    install -Dm644 "$ROOT/config.example" "$CONFIG_DIR/config"
else
    printf 'Keeping existing config: %s\n' "$CONFIG_DIR/config"
fi

install_hypr_module() {
    local target="$HYPR_DIR/yt-stream-workspace.lua"
    local quoted_bin escaped_bin temporary

    printf -v quoted_bin '%q' "$BIN_DIR/workspace-stream"
    escaped_bin="${quoted_bin//\\/\\\\}"
    escaped_bin="${escaped_bin//&/\\&}"
    escaped_bin="${escaped_bin//|/\\|}"
    temporary="$(mktemp "$HYPR_DIR/.yt-stream-workspace.lua.XXXXXX")"
    sed "s|~/.local/bin/workspace-stream|$escaped_bin|g" \
        "$ROOT/hyprland/yt-stream-workspace.lua" >"$temporary"
    install -m 644 "$temporary" "$target"
    rm -f "$temporary"
}

if [[ ! -e "$HYPR_DIR/yt-stream-workspace.lua" ]]; then
    mark_created "$SNIPPET_MARKER"
    install_hypr_module
elif [[ "$FORCE" == 1 ]]; then
    backup_unowned_file \
        "$HYPR_DIR/yt-stream-workspace.lua" \
        "$SNIPPET_MARKER" \
        "$BACKUP_DIR/yt-stream-workspace.lua"
    install_hypr_module
else
    printf 'Keeping existing Hyprland module: %s\n' "$HYPR_DIR/yt-stream-workspace.lua"
fi

if [[ "$HYPR_SOURCE" == 1 ]]; then
    if grep -Fqx "$REQUIRE_LINE" "$HYPR_LUA_TARGET"; then
        printf 'Hyprland require line already present in %s\n' "$HYPR_LUA"
    else
        BACKUP="$HYPR_LUA_TARGET.yt-stream-workspace.bak.$(date +%Y%m%d-%H%M%S)"
        cp -- "$HYPR_LUA_TARGET" "$BACKUP"
        printf '\n%s\n%s\n' "$REQUIRE_COMMENT" "$REQUIRE_LINE" >>"$HYPR_LUA_TARGET"
        printf '%s\n' "$REQUIRE_LINE" >"$HYPR_SOURCE_MARKER"
        printf 'Added Hyprland require line to %s\n' "$HYPR_LUA_TARGET"
        printf 'Backup: %s\n' "$BACKUP"
    fi
fi

printf 'Installed workspace-stream to %s/workspace-stream\n' "$BIN_DIR"
printf 'Config: %s/config\n' "$CONFIG_DIR"
printf 'Hyprland module: %s/yt-stream-workspace.lua\n' "$HYPR_DIR"
printf '\n'
printf 'Add this line to hyprland.lua if you have not already:\n'
printf 'require("yt-stream-workspace")\n'
printf '\n'
printf 'Then reload Hyprland and run: workspace-stream self-test\n'
printf 'For prerequisite diagnostics, run: workspace-stream doctor\n'
