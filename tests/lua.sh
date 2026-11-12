#!/usr/bin/env bash
# Scenario tests for the Hyprland module, run against a model of Hyprland's
# Lua API so they need neither Hyprland nor a display.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LUA="$(command -v lua5.4 || command -v lua5.5 || command -v lua || true)"
if [[ -z "$LUA" ]]; then
    printf 'lua not installed; module tests skipped\n'
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/yt-stream-workspace"

YTWS_ROOT="$ROOT" XDG_RUNTIME_DIR="$TMP" HYPRLAND_INSTANCE_SIGNATURE=test \
    "$LUA" "$ROOT/tests/lua/module_test.lua"
