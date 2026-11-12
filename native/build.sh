#!/usr/bin/env bash
# Build the native helpers and install them where workspace-stream looks for
# them first:
#   wf-recorder   upstream at a pinned commit, with the patches in wf-recorder/
#   ytws-preview  the copy-free preview client in preview/
#
# Usage: native/build.sh [DIRECTORY]
#   DIRECTORY defaults to ${XDG_DATA_HOME:-~/.local/share}/yt-stream-workspace/bin
set -Eeuo pipefail

WF_RECORDER_UPSTREAM=https://github.com/ammen99/wf-recorder.git
WF_RECORDER_COMMIT=c5de47440e8e81c92befb696cb69819cdb3bfe8a

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEST="${1:-${XDG_DATA_HOME:-$HOME/.local/share}/yt-stream-workspace/bin}"

die() {
    printf 'native/build.sh: %s\n' "$*" >&2
    exit 1
}

for tool in git meson ninja cc c++ pkg-config wayland-scanner; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool is missing: $tool"
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# meson's own output names the missing dependency or the failing file.
build() {
    local name="$1" source="$2"
    shift 2
    if ! { meson setup "$WORK/$name" "$source" --buildtype=release "$@" &&
           ninja -C "$WORK/$name"; } >"$WORK/$name.log" 2>&1; then
        cat "$WORK/$name.log" >&2
        die "building $name failed"
    fi
}

git init -q "$WORK/wf-recorder-src"
git -C "$WORK/wf-recorder-src" fetch -q --depth 1 "$WF_RECORDER_UPSTREAM" "$WF_RECORDER_COMMIT" ||
    die "could not fetch wf-recorder $WF_RECORDER_COMMIT"
git -C "$WORK/wf-recorder-src" checkout -q FETCH_HEAD
git -C "$WORK/wf-recorder-src" apply "$HERE"/wf-recorder/*.patch
build wf-recorder "$WORK/wf-recorder-src" -Dpipewire=enabled -Ddefault_audio_backend=pipewire
[[ "$("$WORK/wf-recorder/wf-recorder" --help 2>&1)" == *--cfr* ]] ||
    die "the built wf-recorder lacks the patches"

build ytws-preview "$HERE/preview"

mkdir -p "$DEST"
for binary in wf-recorder/wf-recorder ytws-preview/ytws-preview; do
    install -m 755 -s "$WORK/$binary" "$DEST/.${binary##*/}.new"
    mv -f "$DEST/.${binary##*/}.new" "$DEST/${binary##*/}"
    printf 'installed %s\n' "$DEST/${binary##*/}"
done
