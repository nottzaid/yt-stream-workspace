#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

XDG_BIN_HOME="$TMP/custom bin"
XDG_CONFIG_HOME="$TMP/custom config"
export XDG_BIN_HOME XDG_CONFIG_HOME

HYPR_DIR="$XDG_CONFIG_HOME/hypr"
CONFIG_DIR="$XDG_CONFIG_HOME/yt-stream-workspace"
REQUIRE_LINE='require("yt-stream-workspace")'
printf -v QUOTED_BIN '%q' "$XDG_BIN_HOME/workspace-stream"

# A missing Hyprland root config must fail before writing a partial install.
if XDG_BIN_HOME="$TMP/missing-bin" XDG_CONFIG_HOME="$TMP/missing-config" \
    "$ROOT/install.sh" --hypr-source >"$TMP/missing.log" 2>&1; then
    printf 'install unexpectedly accepted a missing hyprland.lua\n' >&2
    exit 1
fi
test ! -e "$TMP/missing-bin/workspace-stream"
test ! -e "$TMP/missing-config/yt-stream-workspace/config"

mkdir -p "$HYPR_DIR"
printf -- '-- test Hyprland config\n' >"$HYPR_DIR/hyprland.lua"
cp "$HYPR_DIR/hyprland.lua" "$TMP/original-hyprland.lua"

"$ROOT/install.sh" --hypr-source >"$TMP/install.log"

# Whatever the installer appends must still be a valid Lua chunk; Hyprland
# refuses to load a hyprland.lua with a syntax error.
LUAC="$(command -v luac || command -v luac5.4 || true)"
if [[ -n "$LUAC" ]]; then
    "$LUAC" -p "$HYPR_DIR/hyprland.lua"
else
    printf 'luac not installed; hyprland.lua syntax check skipped\n'
fi

test -x "$XDG_BIN_HOME/workspace-stream"
test -r "$CONFIG_DIR/config"
test -r "$HYPR_DIR/yt-stream-workspace.lua"
grep -Fqx "$REQUIRE_LINE" "$HYPR_DIR/hyprland.lua"
grep -Fq "$QUOTED_BIN" "$HYPR_DIR/yt-stream-workspace.lua"
test -e "$CONFIG_DIR/hypr-source-added"
test "$(sed -n '1p' "$CONFIG_DIR/.install-state/bin")" = created
test "$(sed -n '1p' "$CONFIG_DIR/.install-state/config")" = created
test "$(sed -n '1p' "$CONFIG_DIR/.install-state/hypr-snippet")" = created

"$XDG_BIN_HOME/workspace-stream" --help >/dev/null

"$ROOT/uninstall.sh" >"$TMP/uninstall.log"
test ! -e "$XDG_BIN_HOME/workspace-stream"
test ! -e "$HYPR_DIR/yt-stream-workspace.lua"
test -r "$CONFIG_DIR/config"
if grep -Fqx "$REQUIRE_LINE" "$HYPR_DIR/hyprland.lua"; then
    printf 'uninstall left its owned Hyprland require line behind\n' >&2
    exit 1
fi
cmp "$TMP/original-hyprland.lua" "$HYPR_DIR/hyprland.lua"

"$ROOT/install.sh" >"$TMP/reinstall.log"
"$ROOT/uninstall.sh" --purge >"$TMP/purge.log"
test ! -e "$CONFIG_DIR/config"

# Existing files and a pre-existing require line are user-owned. A forced
# installation must back them up, and uninstall must restore them byte-for-byte.
mkdir -p "$XDG_BIN_HOME" "$CONFIG_DIR" "$HYPR_DIR"
printf '#!/usr/bin/env bash\nprintf "personal executable\\n"\n' \
    >"$XDG_BIN_HOME/workspace-stream"
chmod 700 "$XDG_BIN_HOME/workspace-stream"
printf 'YTWS_OUTPUT=PERSONAL\n' >"$CONFIG_DIR/config"
printf '%s\n' '-- user module' >"$HYPR_DIR/yt-stream-workspace.lua"
printf '%s\n' '-- user config' "$REQUIRE_LINE" >"$HYPR_DIR/hyprland.lua"

cp "$XDG_BIN_HOME/workspace-stream" "$TMP/original-bin"
cp "$CONFIG_DIR/config" "$TMP/original-config"
cp "$HYPR_DIR/yt-stream-workspace.lua" "$TMP/original-module"

"$ROOT/install.sh" --force --hypr-source >"$TMP/forced-install.log"
test ! -e "$CONFIG_DIR/hypr-source-added"
test "$(sed -n '1p' "$CONFIG_DIR/.install-state/bin")" = replaced
test "$(sed -n '1p' "$CONFIG_DIR/.install-state/config")" = replaced
test "$(sed -n '1p' "$CONFIG_DIR/.install-state/hypr-snippet")" = replaced

"$ROOT/uninstall.sh" --purge >"$TMP/forced-uninstall.log"
cmp "$TMP/original-bin" "$XDG_BIN_HOME/workspace-stream"
cmp "$TMP/original-config" "$CONFIG_DIR/config"
cmp "$TMP/original-module" "$HYPR_DIR/yt-stream-workspace.lua"
grep -Fqx "$REQUIRE_LINE" "$HYPR_DIR/hyprland.lua"
test "$(stat -c %a "$XDG_BIN_HOME/workspace-stream")" = 700

rm -rf "$XDG_BIN_HOME" "$XDG_CONFIG_HOME"

# A symlinked hyprland.lua (dotfiles managers) is edited through the link and
# stays a link through install and uninstall.
mkdir -p "$HYPR_DIR" "$TMP/dotfiles"
printf -- '-- dotfiles config\n' >"$TMP/dotfiles/hyprland.lua"
cp "$TMP/dotfiles/hyprland.lua" "$TMP/original-dotfiles.lua"
ln -s "$TMP/dotfiles/hyprland.lua" "$HYPR_DIR/hyprland.lua"
"$ROOT/install.sh" --hypr-source >"$TMP/symlink-install.log"
test -L "$HYPR_DIR/hyprland.lua"
grep -Fqx "$REQUIRE_LINE" "$TMP/dotfiles/hyprland.lua"
"$ROOT/uninstall.sh" --purge >"$TMP/symlink-uninstall.log"
test -L "$HYPR_DIR/hyprland.lua"
cmp "$TMP/original-dotfiles.lua" "$TMP/dotfiles/hyprland.lua"
rm -rf "$XDG_BIN_HOME" "$XDG_CONFIG_HOME"

# A read-only hyprland.lua (for example in a Nix store) must be refused before
# anything is installed.
mkdir -p "$HYPR_DIR"
printf -- '-- read-only config\n' >"$HYPR_DIR/hyprland.lua"
chmod 444 "$HYPR_DIR/hyprland.lua"
if "$ROOT/install.sh" --hypr-source >"$TMP/readonly.log" 2>&1; then
    printf 'install unexpectedly edited a read-only hyprland.lua\n' >&2
    exit 1
fi
grep -Fq 'not writable' "$TMP/readonly.log"
test ! -e "$XDG_BIN_HOME/workspace-stream"
chmod 644 "$HYPR_DIR/hyprland.lua"
rm -rf "$XDG_BIN_HOME" "$XDG_CONFIG_HOME"

# An installation made before the Lua migration owns a source line in
# hyprland.conf and a .conf snippet; uninstall removes exactly those.
mkdir -p "$HYPR_DIR" "$CONFIG_DIR/.install-state"
LEGACY_LINE="source = $HYPR_DIR/yt-stream-workspace.conf"
printf '# user conf\n' >"$HYPR_DIR/hyprland.conf"
cp "$HYPR_DIR/hyprland.conf" "$TMP/original-hyprland.conf"
printf '\n# yt-stream-workspace\n%s\n' "$LEGACY_LINE" >>"$HYPR_DIR/hyprland.conf"
printf '%s\n' "$LEGACY_LINE" >"$CONFIG_DIR/hypr-source-added"
printf 'bind = SUPER,F11,exec,true\n' >"$HYPR_DIR/yt-stream-workspace.conf"
printf 'created\n' >"$CONFIG_DIR/.install-state/hypr-snippet"
"$ROOT/uninstall.sh" >"$TMP/legacy-uninstall.log"
cmp "$TMP/original-hyprland.conf" "$HYPR_DIR/hyprland.conf"
test ! -e "$HYPR_DIR/yt-stream-workspace.conf"

printf 'install smoke test passed\n'
