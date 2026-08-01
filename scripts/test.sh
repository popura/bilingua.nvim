#!/usr/bin/env sh
set -eu

nvim --headless -u tests/minimal_init.lua \
  -c "luafile tests/runner.lua" \
  -c "qa!"
