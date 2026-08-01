local test = require("tests.testlib")
local config_module = require("bilingua.config")
local registry_module = require("bilingua.registry")
local standard_registry = require("bilingua.standard_registry")

local function context(registry, available, analyzer, warnings)
  return {
    registry = registry,
    sha256 = function(value)
      return "digest:" .. value
    end,
    document_runtime = {
      markdown_available = function()
        return available, available and nil or "markdown parser unavailable"
      end,
      analyze_markdown = analyzer,
    },
    warn = function(message)
      warnings[#warnings + 1] = message
    end,
  }
end

-- Preconditions: Three standard Markdown factory contexts report respectively an
-- unavailable parser with fallback enabled, an unavailable parser with fallback
-- disabled, and an available parser/query analyzer. Prerequisites: Neovim-specific
-- Tree-sitter access is injected at the composition boundary and its query lives
-- under queries/markdown. Verification items: the first context warns and returns
-- Plaintext, the second returns a Markdown adapter that fails parse with E_PARSE,
-- the third invokes analysis and marks its snapshot as tree_sitter-derived, and
-- the query captures front matter and tables as opaque structures.
test.it("selects Tree-sitter Markdown or the configured safe fallback", function()
  local registry = registry_module.new()
  assert(standard_registry.register(registry))
  local factory = assert(registry:get_document_adapter("markdown"))

  local warnings = {}
  local fallback_config = config_module.defaults()
  local fallback = factory(fallback_config, context(registry, false, nil, warnings))
  test.eq("plaintext", fallback.id)
  test.eq(1, #warnings)

  local strict_config = config_module.defaults()
  strict_config.documents.fallback_to_plaintext = false
  local unavailable = factory(strict_config, context(registry, false, nil, {}))
  test.eq("markdown", unavailable.id)
  local missing_snapshot, missing_error = unavailable:parse({
    side = "source",
    text = "# Heading",
    filetype = "markdown",
    language = "en",
    editor_version = 1,
  })
  test.eq(nil, missing_snapshot)
  test.eq("E_PARSE", missing_error.code)

  local analyzed = 0
  local available = factory(
    fallback_config,
    context(registry, true, function(text)
      analyzed = analyzed + 1
      return { capture_count = #text > 0 and 1 or 0 }
    end, {})
  )
  local snapshot = assert(available:parse({
    side = "source",
    text = "# Heading",
    filetype = "markdown",
    language = "en",
    editor_version = 1,
  }))
  test.eq("markdown", available.id)
  test.eq(1, analyzed)
  test.eq("tree_sitter", snapshot.metadata.parser)

  local query = assert(io.open("queries/markdown/bilingua.scm", "rb"))
  local query_source = assert(query:read("*a"))
  query:close()
  test.eq(true, query_source:find("@bilingua.translatable", 1, true) ~= nil)
  test.eq(true, query_source:find("@bilingua.opaque", 1, true) ~= nil)
  test.eq(true, query_source:find("(minus_metadata)", 1, true) ~= nil)
  test.eq(true, query_source:find("(plus_metadata)", 1, true) ~= nil)
  test.eq(true, query_source:find("(pipe_table)", 1, true) ~= nil)
end)
