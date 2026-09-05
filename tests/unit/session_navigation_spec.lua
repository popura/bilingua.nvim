local test = require("tests.testlib")
local session_module = require("bilingua.app.session")
local fake_editor = require("tests.fakes.editor")

local function ready_session()
  local editor = fake_editor.new("One\n\nTwo", "text")
  local active = session_module.new({
    id = "session:navigation",
    editor = editor,
    document_adapter = {},
    unit_tracker = {},
    aligner = {},
    translator = {},
    config = {
      source_language = "en",
      target_language = "ja",
      sync = { automatic = true },
      translation = { backend = "fake" },
    },
  })
  active.source_path = "/tmp/source.txt"
  active.source_buf = 11
  active.target_buf = 12
  active.state = "ready"
  active.health = "healthy"
  active.mapping_graph = {
    order = { "group:1", "group:2" },
    groups = {
      ["group:1"] = {
        id = "group:1",
        state = "clean",
        source_unit_ids = { "source:1" },
        target_unit_ids = { "target:1" },
      },
      ["group:2"] = {
        id = "group:2",
        state = "dirty_target",
        source_unit_ids = { "source:2" },
        target_unit_ids = { "target:2" },
      },
    },
  }
  return active, editor
end

-- Preconditions: A ready Session has two ordered mapping groups and the source
-- cursor is inside the first group. Prerequisites: navigation is expressed only
-- through EditorPort focus operations, so Session does not use Neovim APIs.
-- Verification items: toggle preserves correspondence on the opposite side,
-- next and previous stay on the current side, and their returned group IDs match.
test.it("navigates mapping groups through EditorPort correspondence", function()
  local active, editor = ready_session()
  editor.cursor_units.source = "source:1"

  local toggled = active:toggle(11)
  test.eq("group:1", toggled)
  test.eq("target", editor.focused_side)
  test.eq("target:1", editor.cursor_units.target)

  local next_group = active:next_group(12)
  test.eq("group:2", next_group)
  test.eq("target:2", editor.cursor_units.target)

  local previous_group = active:prev_group(12)
  test.eq("group:1", previous_group)
  test.eq("target:1", editor.cursor_units.target)
end)

-- Preconditions: A ready Session owns both buffers but the source cursor is
-- outside every mapping group. Prerequisites: Session can still identify the
-- source side independently of unit lookup, and EditorPort exposes focus_side.
-- Verification items: Toggle focuses the target buffer, reports success without
-- inventing a group ID, and does not surface the missing-group error.
test.it("toggles to the opposite buffer outside mapping groups", function()
  local active, editor = ready_session()
  editor.cursor_units.source = nil

  local toggled, toggle_error = active:toggle(11)
  test.eq(true, toggled)
  test.eq(nil, toggle_error)
  test.eq("target", editor.focused_side)
end)

-- Preconditions: One dirty group is under the source cursor. Prerequisites: the
-- SyncEngine dependency exposes retry_group and Session resolves the current unit
-- before delegation. Verification items: exactly that group is retried at manual
-- priority 100 and success is returned without exposing the SyncEngine itself.
test.it("synchronizes the mapping group under the current cursor", function()
  local active, editor = ready_session()
  editor.cursor_units.source = "source:2"
  local received
  local received_priority
  active.sync_engine = {
    retry_group = function(_, group_id, priority)
      received, received_priority = group_id, priority
      return true
    end,
  }

  local synced, sync_error = active:sync_current(11)
  test.eq(true, synced)
  test.eq(nil, sync_error)
  test.eq("group:2", received)
  test.eq(100, received_priority)
end)

-- Preconditions: A Session has one clean and one dirty group plus an active job.
-- Prerequisites: public diagnostics include identifiers, counters, and the source
-- path, but no document fragments or mutable internal tables. Verification items:
-- all minimum fields are present, and mutating one returned snapshot cannot alter
-- the next one.
test.it("returns a detached status snapshot without document content", function()
  local active = ready_session()
  active.active_jobs["task:1"] = {}

  local first = active:status_snapshot()
  test.eq("/tmp/source.txt", first.source_path)
  test.eq("session:navigation", first.session_id)
  test.eq("ready", first.state)
  test.eq(1, first.groups.clean)
  test.eq(1, first.groups.dirty_target)
  test.eq(1, first.active_tasks)
  test.eq(nil, first.source_snapshot)

  first.groups.clean = 99
  local second = active:status_snapshot()
  test.eq(1, second.groups.clean)
end)
