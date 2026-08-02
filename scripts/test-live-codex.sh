#!/usr/bin/env sh
set -eu

if [ "${BILINGUA_RUN_LIVE_CODEX:-}" != "1" ]; then
  echo "error: set BILINGUA_RUN_LIVE_CODEX=1 to acknowledge a real Codex request" >&2
  exit 2
fi

if ! command -v codex >/dev/null 2>&1; then
  echo "error: codex CLI is required" >&2
  exit 1
fi

if ! codex login status >/dev/null 2>&1; then
  echo "error: codex CLI is not logged in" >&2
  exit 1
fi

nvim_bin=${BILINGUA_NVIM:-nvim}
if ! command -v "$nvim_bin" >/dev/null 2>&1; then
  echo "error: Neovim executable not found: $nvim_bin" >&2
  exit 1
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")
cd "$repo_root"

exec "$nvim_bin" --headless -u tests/minimal_init.lua -l scripts/live_codex_test.lua
