local test = require("tests.testlib")
local session_module = require("bilingua.app.session")
local plaintext = require("bilingua.adapters.document.plaintext")
local hybrid = require("bilingua.adapters.tracker.hybrid")
local fake_editor = require("tests.fakes.editor")
local fake_aligner = require("tests.fakes.aligner")
local fake_translation = require("tests.fakes.translation_service")

-- Preconditions: The injected editor exposes a two-paragraph source document and
-- the injected translation service returns one normalized result per source unit.
-- Prerequisites: Session startup owns orchestration while adapters own parsing and
-- rendering; Fake Editor, Fake Aligner, and Fake TranslationService are all
-- constructor-injected. Verification items: startup reaches ready, writes a
-- Japanese scratch document, invokes the injected aligner once, creates clean
-- mapping groups and anchors, enables target editing, and submits an initial task
-- without exposing the Session's internals through a global singleton; EditorPort
-- endofline metadata survives even though Neovim's line-array text omits the LF.
test.it("starts a complete plaintext session with injected fakes", function()
  local editor = fake_editor.new("Hello\n\nWorld", "text")
  local aligner = fake_aligner.new()
  editor.documents.source.metadata.endofline = true
  local translator = fake_translation.new(function(task)
    local replacements = {}
    local translations = { "こんにちは", "世界" }
    for index, unit in ipairs(task.edited_after.units) do
      replacements[index] = {
        local_id = ("result:%d"):format(index),
        corresponds_to_edited_unit_ids = { unit.unit_id },
        kind = unit.kind,
        content_text = translations[index],
        language = "ja",
      }
    end
    return {
      schema_version = 1,
      task_id = task.task_id,
      destination_side = "target",
      replacement_units = replacements,
      warnings = {},
      metadata = {},
    }
  end)
  local session = session_module.new({
    id = "session:1",
    editor = editor,
    document_adapter = plaintext.new(),
    unit_tracker = hybrid.new(),
    aligner = aligner,
    translator = translator,
    config = {
      source_language = "en",
      target_language = "ja",
      limits = { max_document_bytes = 1024, max_units = 20 },
    },
  })
  local started, start_error

  session:start(function(ok, err)
    started = ok
    start_error = err
  end)

  test.eq(true, started)
  test.eq(nil, start_error)
  test.eq("ready", session.state)
  test.eq("こんにちは\n\n世界", editor.documents.target.text)
  test.eq(true, editor.target_modifiable)
  test.eq(1, #aligner.initialize_requests)
  test.eq({ "fake-group:000001", "fake-group:000002" }, session.mapping_graph.order)
  test.eq("clean", session.mapping_graph.groups["fake-group:000001"].state)
  test.eq(true, editor.anchors.source ~= nil)
  test.eq(true, editor.anchors.target ~= nil)
  test.eq("initial_translate", translator.submitted[1].kind)
  test.eq(true, session.source_snapshot.metadata.endofline)
end)
