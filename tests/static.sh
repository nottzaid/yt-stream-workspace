#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "$ROOT/bin/workspace-stream"
bash -n "$ROOT/install.sh"
bash -n "$ROOT/uninstall.sh"

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$ROOT/bin/workspace-stream" "$ROOT/install.sh" "$ROOT/uninstall.sh"
else
    printf 'shellcheck not installed; skipped\n'
fi

printf 'static checks passed\n'
