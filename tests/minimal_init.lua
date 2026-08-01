vim.opt.runtimepath:prepend(vim.fn.getcwd())

package.path = table.concat({
  vim.fn.getcwd() .. "/?.lua",
  vim.fn.getcwd() .. "/?/init.lua",
  package.path,
}, ";")
