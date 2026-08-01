local ok, err = xpcall(function()
  require("tests.run")
end, debug.traceback)

if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
end
