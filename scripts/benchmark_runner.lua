local ok, err = xpcall(function()
  dofile("scripts/benchmark.lua")
end, debug.traceback)

if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
end
