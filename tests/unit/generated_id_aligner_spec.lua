local test = require("tests.testlib")
local plaintext = require("bilingua.adapters.document.plaintext")
local generated_id = require("bilingua.adapters.aligner.generated_id")

-- Preconditions: Source and target snapshots each contain two ordered paragraph
-- units, and construction seeds connect source IDs to target ordinals.
-- Prerequisites: Generated IDs are transport metadata only and mapping groups own
-- baseline fragments for both sides. Verification items: initialization creates
-- two clean one-to-one groups in document order, indexes both sides, and stores
-- the exact normalized baseline content.
test.it("initializes clean groups from construction seeds", function()
  local adapter = plaintext.new()
  local source = assert(adapter:parse({
    side = "source",
    text = "Hello\n\nWorld",
    filetype = "text",
    language = "en",
    editor_version = 1,
  }))
  local target = assert(adapter:parse({
    side = "target",
    text = "こんにちは\n\n世界",
    filetype = "text",
    language = "ja",
    editor_version = 2,
  }))
  local aligner = generated_id.new()
  local graph, err = aligner:initialize({
    source_snapshot = source,
    target_snapshot = target,
    construction_seeds = {
      { source_unit_ids = { source.order[1] }, target_ordinal = 1, kind = "paragraph" },
      { source_unit_ids = { source.order[2] }, target_ordinal = 2, kind = "paragraph" },
    },
    initial_translation_result = {
      replacement_units = {
        {
          corresponds_to_edited_unit_ids = { source.order[1] },
          kind = "paragraph",
          content_text = "こんにちは",
        },
        {
          corresponds_to_edited_unit_ids = { source.order[2] },
          kind = "paragraph",
          content_text = "世界",
        },
      },
    },
  })

  test.eq(nil, err)
  test.eq({ "group:000001", "group:000002" }, graph.order)
  test.eq({ target.order[1] }, graph.groups["group:000001"].target_unit_ids)
  test.eq("Hello", graph.groups["group:000001"].baseline.source.units[1].content_text)
  test.eq("こんにちは", graph.groups["group:000001"].baseline.target.units[1].content_text)
  test.eq("clean", graph.groups["group:000002"].state)
  test.eq({ "group:000002" }, graph.target_index[target.order[2]])
end)

-- Preconditions: Construction seeds cover two source units, while an initial
-- result duplicates the first source ID and omits the second. Prerequisites:
-- Generated-ID alignment may trust ordinals only after codec IDs are independently
-- checked. Verification items: initialization returns E_ALIGNMENT and no partial
-- MappingGraph is exposed.
test.it("rejects incomplete or duplicate initial translation IDs", function()
  local adapter = plaintext.new()
  local source = assert(adapter:parse({
    side = "source",
    text = "A\n\nB",
    filetype = "text",
    language = "en",
    editor_version = 1,
  }))
  local target = assert(adapter:parse({
    side = "target",
    text = "あ\n\nい",
    filetype = "text",
    language = "ja",
    editor_version = 1,
  }))
  local graph, align_error = generated_id.new():initialize({
    source_snapshot = source,
    target_snapshot = target,
    construction_seeds = {
      { source_unit_ids = { source.order[1] }, target_ordinal = 1, kind = "paragraph" },
      { source_unit_ids = { source.order[2] }, target_ordinal = 2, kind = "paragraph" },
    },
    initial_translation_result = {
      replacement_units = {
        { corresponds_to_edited_unit_ids = { source.order[1] } },
        { corresponds_to_edited_unit_ids = { source.order[1] } },
      },
    },
  })

  test.eq(nil, graph)
  test.eq("E_ALIGNMENT", align_error.code)
end)

-- Preconditions: A construction seed names the only source unit, but the model
-- result claims an ID that was never sent. Prerequisites: Generated IDs are an
-- integrity boundary and target ordinals cannot legitimize an unknown source ID.
-- Verification items: initialization rejects the result as E_ALIGNMENT and
-- exposes no partially constructed mapping graph.
test.it("rejects an unknown initial translation ID", function()
  local adapter = plaintext.new()
  local source = assert(adapter:parse({
    side = "source",
    text = "A",
    filetype = "text",
    language = "en",
    editor_version = 1,
  }))
  local target = assert(adapter:parse({
    side = "target",
    text = "あ",
    filetype = "text",
    language = "ja",
    editor_version = 1,
  }))
  local graph, align_error = generated_id.new():initialize({
    source_snapshot = source,
    target_snapshot = target,
    construction_seeds = {
      {
        source_unit_ids = { source.order[1] },
        target_ordinal = 1,
        kind = "paragraph",
      },
    },
    initial_translation_result = {
      replacement_units = {
        {
          corresponds_to_edited_unit_ids = { "src:u:unknown" },
        },
      },
    },
  })

  test.eq(nil, graph)
  test.eq("E_ALIGNMENT", align_error.code)
end)
