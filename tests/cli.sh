#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

expect_config_error() {
    local assignment="$1"
    local expected="$2"
    local config="$TMP/config"

    printf '%s\n' "$assignment" >"$config"
    if YTWS_CONFIG="$config" "$ROOT/bin/workspace-stream" doctor \
        >"$TMP/stdout" 2>"$TMP/stderr"; then
        printf 'invalid config unexpectedly passed: %s\n' "$assignment" >&2
        exit 1
    fi
    grep -Fq "$expected" "$TMP/stderr"
}

expect_config_error 'YTWS_WIDTH=1919' 'YTWS_WIDTH must be even for H.264'
expect_config_error 'YTWS_HEIGHT=1079' 'YTWS_HEIGHT must be even for H.264'
expect_config_error 'YTWS_FPS=61' "YTWS_FPS must not exceed YouTube's 60 fps limit"
expect_config_error 'YTWS_SCALE=0' 'YTWS_SCALE must be a positive number'
expect_config_error 'YTWS_TEST_RTMP_PORT=65536' 'YTWS_TEST_RTMP_PORT must be at most 65535'
expect_config_error 'YTWS_VIDEO_GOP=241' 'YTWS_VIDEO_GOP must not exceed four seconds'
expect_config_error 'YTWS_OUTPUT=bad,rule' 'YTWS_OUTPUT may contain only'
expect_config_error 'YTWS_MIX_SINK="bad sink"' 'YTWS_MIX_SINK may contain only'
expect_config_error 'YTWS_MIRROR_BACKEND=unknown' 'YTWS_MIRROR_BACKEND is not a supported'
expect_config_error 'YTWS_STREAM_LAYERS="("' 'YTWS_STREAM_LAYERS must be a regular expression'
expect_config_error 'YTWS_PRIVATE_WINDOWS="a["' 'YTWS_PRIVATE_WINDOWS must be a regular expression'
expect_config_error 'YTWS_PREVIEW_MONITOR="two words"' 'YTWS_PREVIEW_MONITOR must be a Hyprland monitor name'
expect_config_error 'YTWS_NOTIFY=yes' 'YTWS_NOTIFY must be 0 or 1'

XDG_STATE_HOME="$TMP/state" "$ROOT/bin/workspace-stream" logs >"$TMP/logs"
grep -Fqx "$TMP/state/yt-stream-workspace" "$TMP/logs"
grep -Fq 'no diagnostic logs have been written' "$TMP/logs"

printf 'CLI checks passed\n'
