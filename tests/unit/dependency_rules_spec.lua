local test = require("tests.testlib")

local function read_file(path)
  local handle = assert(io.open(path, "rb"))
  local source = assert(handle:read("*a"))
  handle:close()
  return source
end

-- Preconditions: Every application and domain module is present as a Lua source
-- file under its documented layer. Prerequisites: Neovim operations belong to an
-- editor adapter or UI module, and concrete adapters enter the core only through
-- SessionFactory injection. Verification items: neither core layer references the
-- `vim` global or directly requires a module below `bilingua.adapters`.
test.it("keeps application and domain layers behind their declared ports", function()
  for _, directory in ipairs({ "lua/bilingua/app", "lua/bilingua/domain" }) do
    local files = vim.fn.glob(directory .. "/*.lua", false, true)
    table.sort(files)
    test.eq(true, #files > 0)
    for _, path in ipairs(files) do
      local source = read_file(path)
      if source:find("vim.", 1, true) then
        error(path .. " directly references the Neovim global", 0)
      end
      if source:find('require("bilingua.adapters', 1, true) then
        error(path .. " directly requires a concrete adapter", 0)
      end
    end
  end
end)

-- Preconditions: Production Lua modules are rooted below lua/bilingua and the
-- Neovim Editor adapter plus UI composition modules are the only platform-facing
-- layer. Prerequisites: Backends and services may use injected functions such as
-- vim.system, but may not import the Neovim global themselves. Verification items:
-- every direct `vim` reference is confined to the documented Editor/UI allowlist.
test.it("confines direct Neovim API access to the editor adapter and UI layer", function()
  local allowed = {
    ["lua/bilingua/adapters/editor/nvim.lua"] = true,
    ["lua/bilingua/commands.lua"] = true,
    ["lua/bilingua/init.lua"] = true,
  }
  local files = vim.fn.glob("lua/bilingua/**/*.lua", false, true)
  table.sort(files)
  test.eq(true, #files > 0)
  for _, path in ipairs(files) do
    local is_ui = path:find("lua/bilingua/ui/", 1, true) == 1
    if not allowed[path] and not is_ui then
      local source = read_file(path)
      if source:find("vim.", 1, true) then
        error(path .. " directly references the Neovim global outside the Editor/UI layer", 0)
      end
    end
  end
end)
