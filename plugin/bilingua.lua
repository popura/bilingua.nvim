if vim.g.loaded_bilingua_nvim == 1 then
  return
end
vim.g.loaded_bilingua_nvim = 1

require("bilingua")._load()
