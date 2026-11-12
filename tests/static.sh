#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "$ROOT/bin/workspace-stream"
bash -n "$ROOT/install.sh"
bash -n "$ROOT/uninstall.sh"
bash -n "$ROOT/native/build.sh"
bash -n "$ROOT/tests/cli.sh"
bash -n "$ROOT/tests/install-smoke.sh"
bash -n "$ROOT/tests/lua.sh"
bash -n "$ROOT/tests/supervisor.sh"

LUAC="$(command -v luac || command -v luac5.4 || true)"
if [[ -n "$LUAC" ]]; then
    "$LUAC" -p "$ROOT/hyprland/yt-stream-workspace.lua" "$ROOT"/tests/lua/*.lua
else
    printf 'luac not installed; Lua syntax check skipped\n'
fi

# Match literal shell defaults; expansion here would weaken the assertion.
# shellcheck disable=SC2016
grep -Fqx 'YTWS_WALLPAPER="$HOME/Pictures/background.jpg"' "$ROOT/config.example"
# shellcheck disable=SC2016
grep -Fq 'WALLPAPER="${YTWS_WALLPAPER:-$HOME/Pictures/background.jpg}"' \
    "$ROOT/bin/workspace-stream"

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck \
        "$ROOT/bin/workspace-stream" \
        "$ROOT/install.sh" \
        "$ROOT/uninstall.sh" \
        "$ROOT/native/build.sh" \
        "$ROOT/tests/cli.sh" \
        "$ROOT/tests/install-smoke.sh" \
        "$ROOT/tests/lua.sh" \
        "$ROOT/tests/supervisor.sh"
else
    printf 'shellcheck not installed; skipped\n'
fi

"$ROOT/tests/cli.sh"
"$ROOT/tests/lua.sh"
"$ROOT/tests/supervisor.sh"

printf 'static checks passed\n'
