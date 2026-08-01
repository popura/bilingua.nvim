local test = require("tests.testlib")
local session_module = require("bilingua.app.session")
local plaintext = require("bilingua.adapters.document.plaintext")
local nvim_editor = require("bilingua.adapters.editor.nvim")
local hybrid = require("bilingua.adapters.tracker.hybrid")
local generated_id = require("bilingua.adapters.aligner.generated_id")
local fake_translation = require("tests.fakes.translation_service")

local function buffer_text(buffer)
  return table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, true), "\n")
end

local function source_buffer(text)
  local buffer = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buffer, vim.fn.tempname() .. ".txt")
  vim.api.nvim_buf_set_lines(buffer, 0, -1, true, vim.split(text, "\n", { plain = true }))
  vim.bo[buffer].filetype = "text"
  vim.api.nvim_win_set_buf(0, buffer)
  return buffer, vim.api.nvim_get_current_win()
end

local function file_source_buffer(text)
  local path = vim.fn.tempname() .. ".txt"
  local written = vim.fn.writefile(vim.split(text, "\n", { plain = true }), path)
  assert(written == 0, "unable to create source fixture")
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local buffer = vim.api.nvim_get_current_buf()
  vim.bo[buffer].filetype = "text"
  return buffer, vim.api.nvim_get_current_win(), path
end

local function editor_for(buffer, window, id)
  return nvim_editor.new({
    source_buf = buffer,
    source_window = window,
    session_id = id,
    target_language = "ja",
    layout = {
      direction = "vertical",
      target_position = "right",
      size = 0.5,
      follow_cursor = false,
      follow_debounce_ms = 10,
    },
    ui = { signs = true, virtual_text = true },
  })
end

local function config()
  return {
    source_language = "en",
    target_language = "ja",
    limits = {
      max_document_bytes = 4096,
      max_units = 50,
      max_task_output_chars = 4096,
      initial_batch_chars = 2048,
      initial_batch_units = 8,
    },
    sync = {
      automatic = false,
      on_insert_leave = true,
      debounce_ms = 10,
      max_concurrency = 1,
      context_groups = 1,
      structural_changes = "auto_safe",
    },
    stop = { sync_pending = false, timeout_ms = 1000 },
  }
end

local function translator()
  return fake_translation.new(function(task)
    local initial = task.kind == "initial_translate"
    local target_to_source = task.edited_side == "target"
    return {
      schema_version = 1,
      task_id = task.task_id,
      destination_side = target_to_source and "source" or "target",
      replacement_units = {
        {
          local_id = initial and "initial:1" or "patch:1",
          corresponds_to_edited_unit_ids = { task.edited_after.units[1].unit_id },
          kind = "paragraph",
          content_text = initial and "こんにちは"
            or (target_to_source and "Hello!" or "こんにちは！"),
          language = target_to_source and "en" or "ja",
        },
      },
      warnings = {},
      metadata = {},
    }
  end)
end

local function start_session(id, text, source_factory)
  local source, source_window, source_path = (source_factory or source_buffer)(text)
  local editor = editor_for(source, source_window, id)
  local service = translator()
  local session = session_module.new({
    id = id,
    editor = editor,
    document_adapter = plaintext.new(),
    unit_tracker = hybrid.new(),
    aligner = generated_id.new(),
    translator = service,
    config = config(),
  })
  session.source_buf = source
  local started, start_error
  session:start(function(ok, err)
    started, start_error = ok, err
  end)
  assert(started, start_error and start_error.message)
  session.target_buf = editor.target_buf
  return session, editor, service, source, source_path
end

-- Preconditions: A real listed source buffer is active in headless Neovim and a
-- Fake TranslationService can answer initial and patch tasks. Prerequisites:
-- Session orchestration uses the concrete NvimEditor for split creation, buffer
-- attachment, extmarks and nvim_buf_set_text while all backend work stays fake.
-- Verification items: startup creates an editable Japanese scratch buffer, a
-- source edit is observed and synchronized, and force stop removes the target,
-- autocmd and extmark resources while retaining the source buffer.
test.it("runs and cleans up a complete headless Session", function()
  local active, editor, service, source = start_session("session:nvim-e2e", "Hello")
  local target = editor.target_buf
  local augroup = editor.augroup
  local anchor_namespace = editor.anchor_namespace
  local state_namespace = editor.state_namespace

  test.eq("ready", active.state)
  test.eq("nofile", vim.bo[target].buftype)
  test.eq(true, vim.bo[target].modifiable)
  test.eq("こんにちは", buffer_text(target))
  test.eq(true, #vim.api.nvim_buf_get_extmarks(source, anchor_namespace, 0, -1, {}) > 0)

  vim.api.nvim_buf_set_text(source, 0, 0, 0, 5, { "Hello there" })
  vim.wait(500, function()
    return #active.pending_changes.source > 0
  end, 10)
  local synced, sync_error
  local sync_finished = false
  vim.schedule(function()
    synced, sync_error = active:sync_all()
    sync_finished = true
  end)
  vim.wait(500, function()
    return sync_finished
  end, 10)

  test.eq(true, synced)
  test.eq(nil, sync_error)
  test.eq("こんにちは！", buffer_text(target))

  local stopped, stop_error = active:stop({ force = true })
  test.eq(true, stopped)
  test.eq(nil, stop_error)
  test.eq("stopped", active.state)
  test.eq("closed", service.state)
  test.eq(false, vim.api.nvim_buf_is_valid(target))
  test.eq(true, vim.api.nvim_buf_is_valid(source))
  test.eq(0, #vim.api.nvim_buf_get_extmarks(source, anchor_namespace, 0, -1, {}))
  test.eq(0, #vim.api.nvim_buf_get_extmarks(source, state_namespace, 0, -1, {}))
  local autocmd_ok, autocmds = pcall(vim.api.nvim_get_autocmds, { group = augroup })
  test.eq(true, not autocmd_ok or #autocmds == 0)

  vim.api.nvim_buf_delete(source, { force = true })
end)

-- Preconditions: A concrete ready Session has editable source and translated
-- target buffers, with the target cursor inside their shared mapping group.
-- Prerequisites: Target edits travel through nvim_buf_attach, Session and
-- SyncEngine before the Editor Adapter applies a guarded source edit; Toggle uses
-- the same extmark correspondence, and a clean normal stop needs no force flag.
-- Verification items: one Japanese edit updates the source, Toggle follows the
-- shared mapping group both ways, and normal stop closes only the target and service.
test.it("synchronizes target edits and toggles a concrete Session before normal stop", function()
  local active, editor, service, source = start_session("session:nvim-target", "Hello")
  local target = editor.target_buf

  vim.api.nvim_buf_set_text(target, 0, 0, 0, #"こんにちは", { "こんにちはね" })
  vim.wait(500, function()
    return #active.pending_changes.target > 0
  end, 10)
  local synced, sync_error
  local sync_finished = false
  vim.schedule(function()
    synced, sync_error = active:sync_all()
    sync_finished = true
  end)
  vim.wait(500, function()
    return sync_finished
  end, 10)

  test.eq(true, synced)
  test.eq(nil, sync_error)
  test.eq("Hello!", buffer_text(source))
  test.eq("group:000001", active:toggle(target))
  test.eq(source, vim.api.nvim_get_current_buf())
  test.eq("group:000001", active:toggle(source))
  test.eq(target, vim.api.nvim_get_current_buf())

  local stopped, stop_error = active:stop({ force = false })
  test.eq(true, stopped)
  test.eq(nil, stop_error)
  test.eq("stopped", active.state)
  test.eq("closed", service.state)
  test.eq(false, vim.api.nvim_buf_is_valid(target))
  test.eq(true, vim.api.nvim_buf_is_valid(source))
  vim.api.nvim_buf_delete(source, { force = true })
end)

-- Preconditions: A ready Session owns a clean source buffer opened from a real
-- file, then later receives a user edit on its target. Prerequisites: NvimEditor
-- observes :checktime through on_reload and normalizes a reusable :edit! detach;
-- Session reparses the complete document and compares both sides with the baseline.
-- Verification items: reload reports origin=reload and full_reload=true, a clean
-- reload synchronizes its target, and a second reload conflicts with a dirty target
-- without submitting a translation for that conflict.
test.it("handles disk reloads and conflicts with a dirty target", function()
  local active, editor, service, source, path =
    start_session("session:nvim-reload", "Hello", file_source_buffer)
  local target = editor.target_buf
  vim.bo[source].autoread = true

  local function saw_reload()
    for _, change in ipairs(active.pending_changes.source) do
      if change.origin == "reload" and change.full_reload then
        return true
      end
    end
    return false
  end

  local function reload_source(text, command)
    test.eq(0, vim.fn.writefile({ text }, path))
    vim.api.nvim_set_current_win(editor.source_window)
    vim.cmd("silent " .. command)
    vim.wait(500, saw_reload, 10)
  end

  reload_source("Hello reloaded", "checktime")
  test.eq(path, vim.api.nvim_buf_get_name(source))
  test.eq("Hello reloaded", buffer_text(source))
  test.eq(true, saw_reload())
  local synced, sync_error = active:sync_all()
  test.eq(true, synced)
  test.eq(nil, sync_error)
  test.eq("こんにちは！", buffer_text(target))
  test.eq("clean", active.mapping_graph.groups["group:000001"].state)
  test.eq(2, #service.submitted)

  vim.api.nvim_buf_set_text(target, 0, 0, 0, #"こんにちは！", { "手動訳" })
  vim.wait(500, function()
    return #active.pending_changes.target > 0
  end, 10)
  reload_source("Hello conflict", "edit!")
  local conflict_synced, conflict_error = active:sync_all()
  test.eq(true, conflict_synced)
  test.eq(nil, conflict_error)
  test.eq("conflict", active.mapping_graph.groups["group:000001"].state)
  test.eq("Hello conflict", buffer_text(source))
  test.eq("手動訳", buffer_text(target))
  test.eq(2, #service.submitted)

  assert(active:stop({ force = true }))
  vim.api.nvim_buf_delete(source, { force = true })
  test.eq(0, vim.fn.delete(path))
end)

-- Preconditions: A ready concrete Session owns a real source and target buffer.
-- Prerequisites: NvimEditor reports nvim_buf_attach on_detach asynchronously and
-- Session treats loss of either owned buffer as force disposal without syncing.
-- Verification items: wiping the source invokes autonomous disposal exactly once,
-- closes the Fake TranslationService, deletes the target, and reaches stopped.
test.it("force-disposes a headless Session when its source is wiped", function()
  local active, editor, service, source = start_session("session:nvim-detach", "Hello")
  local target = editor.target_buf
  local dispose_count = 0
  active.on_auto_dispose = function(_, side)
    test.eq("source", side)
    dispose_count = dispose_count + 1
  end

  vim.api.nvim_buf_delete(source, { force = true })
  vim.wait(500, function()
    return active.state == "stopped"
  end, 10)

  test.eq("stopped", active.state)
  test.eq("closed", service.state)
  test.eq(false, vim.api.nvim_buf_is_valid(target))
  test.eq(1, dispose_count)
  test.eq(1, #service.submitted)
end)

-- Preconditions: One real source buffer contains two disjoint replacement ranges.
-- Prerequisites: NvimEditor validates every range against one version, applies in
-- reverse order, and joins only edits belonging to the same synchronization.
-- Verification items: both replacements appear, one Neovim undo restores the
-- complete pre-application text, and disposing the editor retains the source.
test.it("joins a multi-edit application into one Neovim undo step", function()
  local source, source_window = source_buffer("A\n\nB")
  local editor = editor_for(source, source_window, "session:nvim-undo")
  local view
  editor:create_target_view({}, function(created, err)
    assert(created, err and err.message)
    view = created
  end)
  local version = assert(editor:get_version("source"))
  local applied, apply_error = editor:apply_edits("source", {
    {
      range = { start = { row = 0, col = 0 }, finish = { row = 0, col = 1 } },
      expected_text = "A",
      replacement = "Alpha",
    },
    {
      range = { start = { row = 2, col = 0 }, finish = { row = 2, col = 1 } },
      expected_text = "B",
      replacement = "Beta",
    },
  }, version, "bilingua-test")

  test.eq(nil, apply_error)
  test.eq(true, applied.version > version)
  test.eq("Alpha\n\nBeta", buffer_text(source))
  vim.api.nvim_buf_call(source, function()
    vim.cmd("silent undo")
  end)
  test.eq("A\n\nB", buffer_text(source))

  editor:dispose()
  test.eq(false, vim.api.nvim_buf_is_valid(view.target_buf))
  test.eq(true, vim.api.nvim_buf_is_valid(source))
  vim.api.nvim_buf_delete(source, { force = true })
end)

-- Preconditions: Two independent concrete Sessions own distinct real source and
-- target buffers in the same headless Neovim instance. Prerequisites: Editor
-- namespaces, augroups, subscriptions, graphs and TranslationServices are
-- Session-scoped. Verification items: editing and syncing Session one changes
-- only its target; stopping it leaves Session two ready and valid; and each stop
-- closes only its own target and service.
test.it("keeps concurrent headless Sessions isolated", function()
  local first, first_editor, first_service, first_source =
    start_session("session:nvim-first", "First")
  local first_target = first_editor.target_buf

  vim.cmd("new")
  local second, second_editor, second_service, second_source =
    start_session("session:nvim-second", "Second")
  local second_target = second_editor.target_buf
  local second_source_window = second_editor.source_window

  vim.api.nvim_buf_set_text(first_source, 0, 0, 0, 5, { "First changed" })
  vim.wait(500, function()
    return #first.pending_changes.source > 0
  end, 10)
  local synced, sync_error
  local sync_finished = false
  vim.schedule(function()
    synced, sync_error = first:sync_all()
    sync_finished = true
  end)
  vim.wait(500, function()
    return sync_finished
  end, 10)

  test.eq(true, synced)
  test.eq(nil, sync_error)
  test.eq("こんにちは！", buffer_text(first_target))
  test.eq("こんにちは", buffer_text(second_target))
  test.eq(0, #second.pending_changes.source)
  test.eq("ready", second.state)

  assert(first:stop({ force = true }))
  test.eq(false, vim.api.nvim_buf_is_valid(first_target))
  test.eq("closed", first_service.state)
  test.eq(true, vim.api.nvim_buf_is_valid(second_target))
  test.eq(true, vim.api.nvim_buf_is_valid(second_source))
  test.eq("ready", second.state)
  test.eq("open", second_service.state)

  assert(second:stop({ force = true }))
  test.eq(false, vim.api.nvim_buf_is_valid(second_target))
  test.eq("closed", second_service.state)
  vim.api.nvim_buf_delete(first_source, { force = true })
  vim.api.nvim_buf_delete(second_source, { force = true })
  if vim.api.nvim_win_is_valid(second_source_window) then
    pcall(vim.api.nvim_win_close, second_source_window, true)
  end
end)
