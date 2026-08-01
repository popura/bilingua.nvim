local M = {
  failures = {},
  tests = 0,
}

local function render(value)
  if type(value) == "table" then
    return vim.inspect(value)
  end
  return tostring(value)
end

function M.eq(expected, actual)
  if vim.deep_equal(expected, actual) then
    return
  end

  error(("expected %s, got %s"):format(render(expected), render(actual)), 2)
end

function M.it(name, test)
  M.tests = M.tests + 1
  local ok, err = xpcall(test, debug.traceback)
  if ok then
    io.stdout:write(("ok %d - %s\n"):format(M.tests, name))
    return
  end

  M.failures[#M.failures + 1] = { name = name, error = err }
  io.stdout:write(("not ok %d - %s\n%s\n"):format(M.tests, name, err))
end

function M.finish()
  io.stdout:write(("1..%d\n"):format(M.tests))
  if #M.failures > 0 then
    error(("%d test(s) failed"):format(#M.failures), 0)
  end
end

return M
