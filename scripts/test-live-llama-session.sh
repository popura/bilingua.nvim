#!/usr/bin/env sh
set -eu

if [ "${BILINGUA_RUN_LIVE_LLAMA:-}" != "1" ]; then
  echo "error: set BILINGUA_RUN_LIVE_LLAMA=1 to acknowledge a real local-model request" >&2
  exit 2
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "error: curl is required" >&2
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

exec "$nvim_bin" --headless -u tests/minimal_init.lua -l scripts/live_llama_session_test.lua
