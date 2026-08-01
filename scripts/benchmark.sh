#!/usr/bin/env sh
set -eu

nvim --headless -u tests/minimal_init.lua \
  -c "luafile scripts/benchmark_runner.lua" \
  -c "qa!"
