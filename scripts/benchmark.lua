local markdown = require("bilingua.adapters.document.markdown")
local plaintext = require("bilingua.adapters.document.plaintext")
local hybrid = require("bilingua.adapters.tracker.hybrid")

local MAX_DOCUMENT_BYTES = 2 * 1024 * 1024
local MAX_UNITS = 2000

local function positive_integer(name, default, maximum)
  local raw = os.getenv(name)
  if raw == nil or raw == "" then
    return default
  end
  local value = tonumber(raw)
  if not value or value % 1 ~= 0 or value < 1 or value > maximum then
    error(("%s must be an integer from 1 through %d"):format(name, maximum), 0)
  end
  return value
end

local unit_count = positive_integer("BILINGUA_BENCHMARK_UNITS", MAX_UNITS, MAX_UNITS)
local iterations = positive_integer("BILINGUA_BENCHMARK_ITERATIONS", 3, 100)
local payload_bytes = positive_integer("BILINGUA_BENCHMARK_PAYLOAD_BYTES", 1000, 1000)

local function fixture(revised)
  local paragraphs = {}
  local changed_ordinal = math.floor(unit_count / 2) + 1
  for ordinal = 1, unit_count do
    local marker = revised and ordinal == changed_ordinal and " revised" or ""
    paragraphs[ordinal] = ("Paragraph %04d%s %s"):format(
      ordinal,
      marker,
      string.rep(string.char(96 + ((ordinal - 1) % 26) + 1), payload_bytes)
    )
  end
  return table.concat(paragraphs, "\n\n")
end

local original_text = fixture(false)
local revised_text = fixture(true)
assert(#revised_text <= MAX_DOCUMENT_BYTES, "benchmark fixture exceeds max_document_bytes")

local function parse(adapter, text, previous, editor_version)
  local snapshot = assert(adapter:parse({
    side = "source",
    text = text,
    filetype = adapter.id == "markdown" and "markdown" or "text",
    language = "en",
    editor_version = editor_version,
    previous = previous,
  }))
  assert(#snapshot.order == unit_count, "benchmark adapter produced an unexpected unit count")
  return snapshot
end

local function nvim_sha256(value)
  return vim.fn.sha256(value)
end

local plaintext_adapter = plaintext.new({ sha256 = nvim_sha256 })
local markdown_adapter = markdown.new({ sha256 = nvim_sha256 })
local previous = parse(plaintext_adapter, original_text, nil, 1)
local current = parse(plaintext_adapter, revised_text, previous, 2)
local tracker = hybrid.new()

local function measure(operation)
  operation()
  local samples = {}
  for iteration = 1, iterations do
    collectgarbage("collect")
    local started = vim.loop.hrtime()
    operation()
    samples[iteration] = (vim.loop.hrtime() - started) / 1000000
  end
  table.sort(samples)
  return {
    minimum = samples[1],
    median = samples[math.floor((#samples + 1) / 2)],
    maximum = samples[#samples],
  }
end

local results = {
  {
    name = "plaintext.parse",
    timing = measure(function()
      parse(plaintext_adapter, revised_text, previous, 2)
    end),
  },
  {
    name = "markdown.parse",
    timing = measure(function()
      parse(markdown_adapter, revised_text, nil, 2)
    end),
  },
  {
    name = "hybrid.reconcile",
    timing = measure(function()
      local report = assert(tracker:reconcile({
        side = "source",
        previous = previous,
        current = current,
        changed_ranges = {},
        anchor_hints = {},
      }))
      assert(#report.snapshot.order == unit_count, "benchmark tracker lost document units")
    end),
  },
}

io.stdout:write(
  ("Bilingua benchmark: Neovim %s, units=%d, bytes=%d, iterations=%d\n"):format(
    vim.version().major .. "." .. vim.version().minor .. "." .. vim.version().patch,
    unit_count,
    #revised_text,
    iterations
  )
)
for _, result in ipairs(results) do
  io.stdout:write(
    ("%-20s median=%8.3f ms min=%8.3f ms max=%8.3f ms\n"):format(
      result.name,
      result.timing.median,
      result.timing.minimum,
      result.timing.maximum
    )
  )
end
