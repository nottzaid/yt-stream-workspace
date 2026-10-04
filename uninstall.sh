#!/usr/bin/env bash
set -Eeuo pipefail

BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/yt-stream-workspace"
HYPR_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"
HYPR_SOURCE_MARKER="$CONFIG_DIR/hypr-source-added"
INSTALL_STATE_DIR="$CONFIG_DIR/.install-state"
BACKUP_DIR="$INSTALL_STATE_DIR/backups"
BIN_MARKER="$INSTALL_STATE_DIR/bin"
CONFIG_MARKER="$INSTALL_STATE_DIR/config"
SNIPPET_MARKER="$INSTALL_STATE_DIR/hypr-snippet"
PURGE=0

case "${1:-}" in
"")
    ;;
--purge)
    PURGE=1
    ;;
-h|--help)
    printf 'Usage: ./uninstall.sh [--purge]\n'
    printf '  --purge  also remove installer-created config or restore replaced config\n'
    exit 0
    ;;
*)
    printf 'uninstall.sh: unknown argument: %s\n' "$1" >&2
    exit 2
    ;;
esac

printf 'This removes only files installed by yt-stream-workspace.\n'

# Remove the line this installer appended, plus the comment and blank line it
# wrote above it. The file is rewritten through its resolved path so a
# symlinked config stays a symlink; a read-only target is reported, never
# forced.
remove_owned_line() {
    local file="$1"
    local owned="$2"
    local target backup temporary line
    local -a kept=()

    target="$(readlink -f -- "$file")"
    if ! grep -Fqx -- "$owned" "$target"; then
        return 0
    fi
    if [[ ! -w "$target" || ! -w "$(dirname -- "$target")" ]]; then
        printf 'uninstall.sh: %s is not writable; remove this line yourself: %s\n' \
            "$target" "$owned" >&2
        return 1
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "$owned" ]]; then
            if (( ${#kept[@]} )) &&
               [[ "${kept[-1]}" == '-- yt-stream-workspace' ||
                  "${kept[-1]}" == '# yt-stream-workspace' ]]; then
                unset 'kept[-1]'
                # The installer also wrote the blank separator line.
                if (( ${#kept[@]} )) && [[ -z "${kept[-1]}" ]]; then
                    unset 'kept[-1]'
                fi
            fi
            continue
        fi
        kept+=("$line")
    done <"$target"

    backup="$target.yt-stream-workspace-uninstall.bak.$(date +%Y%m%d-%H%M%S)"
    cp -- "$target" "$backup"
    temporary="$(mktemp "$(dirname -- "$target")/.yt-stream-workspace.XXXXXX")"
    if (( ${#kept[@]} )); then
        printf '%s\n' "${kept[@]}" >"$temporary"
    fi
    chmod --reference="$target" "$temporary"
    mv -- "$temporary" "$target"
    printf 'Removed the installer-owned Hyprland line from %s. Backup: %s\n' \
        "$target" "$backup"
}

if [[ -e "$HYPR_SOURCE_MARKER" ]]; then
    owned_line="$(sed -n '1p' "$HYPR_SOURCE_MARKER")"
    case "$owned_line" in
    "")
        # Empty markers were written by versions before 2026-07.
        owned_line='source = ~/.config/hypr/yt-stream-workspace.conf'
        owned_file="$HYPR_DIR/hyprland.conf"
        ;;
    source\ =*)
        owned_file="$HYPR_DIR/hyprland.conf"
        ;;
    *)
        owned_file="$HYPR_DIR/hyprland.lua"
        ;;
    esac
    if [[ -f "$owned_file" ]]; then
        remove_owned_line "$owned_file" "$owned_line" || exit 1
    fi
fi

restore_or_remove() {
    local target="$1"
    local marker="$2"
    local backup="$3"
    local label="$4"

    [[ -r "$marker" ]] || {
        printf 'Preserving unowned %s: %s\n' "$label" "$target"
        return
    }

    case "$(sed -n '1p' "$marker")" in
    created)
        rm -f "$target"
        ;;
    replaced)
        if [[ -e "$backup" ]]; then
            mkdir -p "$(dirname "$target")"
            cp -a -- "$backup" "$target"
            rm -f "$backup"
            printf 'Restored pre-existing %s: %s\n' "$label" "$target"
        else
            printf 'uninstall.sh: missing backup; preserving %s: %s\n' \
                "$label" "$target" >&2
            return
        fi
        ;;
    *)
        printf 'uninstall.sh: invalid ownership marker; preserving %s: %s\n' \
            "$label" "$target" >&2
        return
        ;;
    esac
    rm -f "$marker"
}

restore_or_remove \
    "$BIN_DIR/workspace-stream" "$BIN_MARKER" "$BACKUP_DIR/workspace-stream" \
    "workspace-stream executable"
managed_module="$HYPR_DIR/yt-stream-workspace.lua"
if [[ ! -e "$managed_module" && -e "$HYPR_DIR/yt-stream-workspace.conf" ]]; then
    # Installs made before the Lua migration managed a .conf snippet.
    managed_module="$HYPR_DIR/yt-stream-workspace.conf"
fi
restore_or_remove \
    "$managed_module" "$SNIPPET_MARKER" \
    "$BACKUP_DIR/${managed_module##*/}" "Hyprland module"

rm -f "$HYPR_SOURCE_MARKER"

if [[ "$PURGE" == 1 ]]; then
    restore_or_remove \
        "$CONFIG_DIR/config" "$CONFIG_MARKER" "$BACKUP_DIR/config" \
        "configuration"
else
    printf 'Preserving configuration: %s/config\n' "$CONFIG_DIR"
fi

if [[ -d "$BACKUP_DIR" ]]; then
    rmdir "$BACKUP_DIR" 2>/dev/null || true
fi
if [[ -d "$INSTALL_STATE_DIR" ]]; then
    rmdir "$INSTALL_STATE_DIR" 2>/dev/null || true
fi
if [[ -d "$CONFIG_DIR" ]]; then
    rmdir "$CONFIG_DIR" 2>/dev/null || true
fi

printf 'Uninstalled yt-stream-workspace files.\n'
