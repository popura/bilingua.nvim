local test = require("tests.testlib")
local plaintext = require("bilingua.adapters.document.plaintext")
local markdown = require("bilingua.adapters.document.markdown")
local protected_tokens = require("bilingua.adapters.document.protected_tokens")
local ranges = require("bilingua.util.ranges")

local ADAPTERS = {
  { name = "plaintext", filetype = "text", create = plaintext.new },
  { name = "markdown", filetype = "markdown", create = markdown.new },
}

local function parse(adapter, definition, side, text)
  return assert(adapter:parse({
    side = side,
    text = text,
    filetype = definition.filetype,
    language = side == "source" and "en" or "ja",
    editor_version = 1,
  }))
end

local function identity_result(snapshot)
  local replacements = {}
  for _, unit_id in ipairs(snapshot.order) do
    local unit = snapshot.units[unit_id]
    if not unit.opaque then
      replacements[#replacements + 1] = {
        local_id = "identity:" .. unit_id,
        corresponds_to_edited_unit_ids = { unit_id },
        kind = unit.kind,
        content_text = unit.content_text,
        language = "ja",
      }
    end
  end
  return { replacement_units = replacements }
end

local function verify_snapshot(snapshot, text)
  local seen = {}
  local previous_finish = 0
  for ordinal, unit_id in ipairs(snapshot.order) do
    test.eq(nil, seen[unit_id])
    seen[unit_id] = true
    local unit = snapshot.units[unit_id]
    local first = ranges.position_to_offset(text, unit.span.start)
    local finish = ranges.position_to_offset(text, unit.span.finish)
    test.eq(true, first >= previous_finish)
    test.eq(true, finish >= first)
    test.eq(unit.raw_text, text:sub(first + 1, finish))
    if unit.kind == "paragraph" and not unit.opaque then
      test.eq(
        unit.raw_text,
        assert(protected_tokens.restore(unit.content_text, unit.protected_tokens))
      )
    end
    previous_finish = finish
    test.eq(unit_id, snapshot.order[ordinal])
  end
end

-- Preconditions: Every bundled Document Adapter parses empty, LF, CRLF, and
-- final-newline variants of the same two-paragraph document. Prerequisites:
-- build_initial_target is the adapter-owned rendering path and identity
-- replacements preserve protected literals. Verification items: IDs are unique,
-- spans are ordered/non-overlapping and byte-exact, token restoration is
-- reversible, identity rendering is byte-identical, reparsing is semantically
-- stable, and final-newline metadata matches every input variant.
test.it("applies shared parse and identity-render contracts to every document adapter", function()
  local texts = {
    "",
    "Alpha `x`\n\nBeta",
    "Alpha `x`\n\nBeta\n",
    "Alpha `x`\r\n\r\nBeta",
    "Alpha `x`\r\n\r\nBeta\r\n",
  }
  for _, definition in ipairs(ADAPTERS) do
    local adapter = definition.create()
    for _, text in ipairs(texts) do
      local source = parse(adapter, definition, "source", text)
      verify_snapshot(source, text)
      test.eq(text:sub(-1) == "\n", source.metadata.endofline)

      local built, build_error = adapter:build_initial_target({
        source_snapshot = source,
        result = identity_result(source),
      })
      assert(built, (build_error and build_error.message) or definition.name)
      test.eq(text, built.text)
      local target = parse(adapter, definition, "target", built.text)
      verify_snapshot(target, built.text)
      test.eq(#source.order, #target.order)
      for ordinal, source_id in ipairs(source.order) do
        local source_unit = source.units[source_id]
        local target_unit = target.units[target.order[ordinal]]
        test.eq(source_unit.kind, target_unit.kind)
        test.eq(source_unit.content_text, target_unit.content_text)
        test.eq(source_unit.opaque, target_unit.opaque)
      end
    end
  end
end)

-- Preconditions: Every bundled Document Adapter receives a deterministic SHA-256
-- function through its constructor and parses two ordinary paragraphs.
-- Prerequisites: The adapter owns hashing but must not depend directly on Neovim;
-- a runtime-specific implementation is supplied at the factory boundary.
-- Verification items: unit fingerprints, the document hash, and guarded edit
-- hashes all come from the injected function in their documented order.
test.it("uses an injected SHA-256 function in every document adapter", function()
  for _, definition in ipairs(ADAPTERS) do
    local inputs = {}
    local adapter = definition.create({
      sha256 = function(value)
        inputs[#inputs + 1] = value
        return ("digest:%d"):format(#inputs)
      end,
    })
    local snapshot = parse(adapter, definition, "target", "Alpha\n\nBeta")

    test.eq("digest:1", snapshot.units[snapshot.order[1]].fingerprint)
    test.eq("digest:2", snapshot.units[snapshot.order[2]].fingerprint)
    test.eq("digest:3", snapshot.text_hash)
    test.eq("Alpha\n\nBeta", inputs[3])

    local first = snapshot.units[snapshot.order[1]]
    local edits = assert(adapter:plan_replace({
      snapshot = snapshot,
      destination_unit_ids = { first.id },
      replacement_units = {
        {
          local_id = "replacement",
          corresponds_to_edited_unit_ids = { "src:first" },
          kind = first.kind,
          content_text = "Changed",
        },
      },
      protected_tokens_by_edited_unit_id = { ["src:first"] = {} },
    }))
    test.eq("digest:4", edits[1].expected_hash)
    test.eq("Alpha", inputs[4])
  end
end)

-- Preconditions: Every bundled adapter receives guarded replacement edits for
-- two parsed paragraphs, the first containing a protected inline literal.
-- Prerequisites: plan_replace scopes one destination unit and validate_edits
-- checks the complete virtual document before editor application. Verification
-- items: a one-unit edit preserves the other unit, reversed disjoint edits apply
-- in document order, and overlap, expected-text mismatch, and an unrestored
-- placeholder are rejected as E_VALIDATION.
test.it("applies shared edit validation contracts to every document adapter", function()
  for _, definition in ipairs(ADAPTERS) do
    local adapter = definition.create()
    local snapshot = parse(adapter, definition, "target", "Alpha `x`\n\nBeta")
    local first = snapshot.units[snapshot.order[1]]
    local second = snapshot.units[snapshot.order[2]]
    local token = assert(first.protected_tokens[1])
    local first_edits = assert(adapter:plan_replace({
      snapshot = snapshot,
      destination_unit_ids = { first.id },
      replacement_units = {
        {
          local_id = "first",
          corresponds_to_edited_unit_ids = { "src:first" },
          kind = first.kind,
          content_text = "Changed " .. token.placeholder,
        },
      },
      protected_tokens_by_edited_unit_id = { ["src:first"] = first.protected_tokens },
    }))
    local first_validation = assert(adapter:validate_edits({
      snapshot = snapshot,
      edits = first_edits,
    }))
    test.eq("Changed `x`\n\nBeta", first_validation.text)

    local second_edits = assert(adapter:plan_replace({
      snapshot = snapshot,
      destination_unit_ids = { second.id },
      replacement_units = {
        {
          local_id = "second",
          corresponds_to_edited_unit_ids = { "src:second" },
          kind = second.kind,
          content_text = "Second",
        },
      },
      protected_tokens_by_edited_unit_id = { ["src:second"] = {} },
    }))
    local both = assert(adapter:validate_edits({
      snapshot = snapshot,
      edits = { second_edits[1], first_edits[1] },
    }))
    test.eq("Changed `x`\n\nSecond", both.text)

    local _, overlap_error = adapter:validate_edits({
      snapshot = snapshot,
      edits = { first_edits[1], first_edits[1] },
    })
    test.eq("E_VALIDATION", overlap_error.code)

    local mismatch = vim.deepcopy(first_edits[1])
    mismatch.expected_text = mismatch.expected_text .. "!"
    local _, mismatch_error = adapter:validate_edits({ snapshot = snapshot, edits = { mismatch } })
    test.eq("E_VALIDATION", mismatch_error.code)

    local unresolved = vim.deepcopy(first_edits[1])
    unresolved.replacement = "⟦BIL:9999⟧"
    local _, token_error = adapter:validate_edits({ snapshot = snapshot, edits = { unresolved } })
    test.eq("E_VALIDATION", token_error.code)
  end
end)

-- Preconditions: Every bundled adapter parses two adjacent translatable units and
-- receives an empty replacement list for the second unit. Prerequisites: Semantic
-- Patch uses an empty list to represent deletion, and adapters own surrounding
-- separator syntax. Verification items: planning marks one structural deletion,
-- validation succeeds, and neither adapter leaves trailing separator-only text.
test.it("removes a unit together with its adjacent separator in every adapter", function()
  for _, definition in ipairs(ADAPTERS) do
    local adapter = definition.create()
    local snapshot = parse(adapter, definition, "target", "Alpha\n\nBeta")
    local second = snapshot.units[snapshot.order[2]]
    local edits, plan_error = adapter:plan_replace({
      snapshot = snapshot,
      destination_unit_ids = { second.id },
      replacement_units = {},
      protected_tokens_by_edited_unit_id = {},
      edited_units_by_id = {},
    })

    test.eq(nil, plan_error)
    test.eq(1, #edits)
    test.eq(true, edits[1].metadata.structural)
    test.eq(true, edits[1].metadata.deletion)
    local validated, validation_error = adapter:validate_edits({
      snapshot = snapshot,
      edits = edits,
    })
    test.eq(nil, validation_error)
    test.eq("Alpha", validated.text)
  end
end)
