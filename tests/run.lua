local testlib = require("tests.testlib")

local files = vim.fn.glob("tests/**/*_spec.lua", false, true)
table.sort(files)

for _, file in ipairs(files) do
  dofile(file)
end

testlib.finish()
