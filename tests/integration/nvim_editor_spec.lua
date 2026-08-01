local test = require("tests.testlib")
local nvim_editor = require("bilingua.adapters.editor.nvim")

-- Preconditions: A valid normal source buffer is current in a headless Neovim
-- window. Prerequisites: The editor adapter alone owns scratch-buffer options,
-- change-origin guards, split creation and target cleanup; source options and
-- lifetime remain user-owned. Verification items: target properties match the
-- specification, one guarded edit reports plugin origin, undo and redo report
-- user origin, a stale expected version is rejected without mutation, and dispose
-- retains the source buffer.
test.it("owns a scratch target and guards programmatic changes", function()
  local source_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(source_buf, vim.fn.tempname() .. ".txt")
  vim.api.nvim_buf_set_lines(source_buf, 0, -1, true, { "Source" })
  vim.bo[source_buf].filetype = "text"
  vim.api.nvim_win_set_buf(0, source_buf)
  local editor = nvim_editor.new({
    source_buf = source_buf,
    source_window = vim.api.nvim_get_current_win(),
    session_id = "editor-test",
    target_language = "ja",
    layout = { direction = "vertical", target_position = "right", size = 0.5 },
    ui = { signs = true, virtual_text = true },
  })
  local view, view_error
  editor:create_target_view({}, function(created, err)
    view = created
    view_error = err
  end)

  test.eq(nil, view_error)
  test.eq("nofile", vim.bo[view.target_buf].buftype)
  test.eq("hide", vim.bo[view.target_buf].bufhidden)
  test.eq(false, vim.bo[view.target_buf].buflisted)
  test.eq(false, vim.bo[view.target_buf].swapfile)
  test.eq(false, vim.bo[view.target_buf].undofile)
  test.eq(false, vim.bo[view.target_buf].modifiable)
  test.eq("text", vim.bo[view.target_buf].filetype)

  editor:set_target_modifiable(true)
  local observed
  local subscription = editor:subscribe_changes("target", function(change)
    observed = change
  end)
  local version = assert(editor:get_version("target"))
  local applied, apply_error = editor:apply_edits("target", {
    {
      range = { start = { row = 0, col = 0 }, finish = { row = 0, col = 0 } },
      expected_text = "",
      replacement = "訳文",
    },
  }, version, "bilingua-test")
  vim.wait(100, function()
    return observed ~= nil
  end)

  test.eq(nil, apply_error)
  test.eq("訳文", assert(editor:get_text("target")))
  test.eq("plugin", observed.origin)
  test.eq("target", observed.side)
  test.eq(true, applied.version > version)

  observed = nil
  vim.api.nvim_set_current_win(view.target_window)
  vim.cmd("silent undo")
  vim.wait(100, function()
    return observed ~= nil
  end)

  test.eq("", assert(editor:get_text("target")))
  test.eq("user", observed.origin)
  test.eq("target", observed.side)

  observed = nil
  vim.cmd("silent redo")
  vim.wait(100, function()
    return observed ~= nil
  end)

  test.eq("訳文", assert(editor:get_text("target")))
  test.eq("user", observed.origin)
  test.eq("target", observed.side)

  local stale_applied, stale_error = editor:apply_edits("target", {
    {
      range = { start = { row = 0, col = 0 }, finish = { row = 0, col = #"訳文" } },
      expected_text = "訳文",
      replacement = "古い結果",
    },
  }, version, "bilingua-stale-test")

  test.eq(nil, stale_applied)
  test.eq("E_APPLY_VERSION_MISMATCH", stale_error.code)
  test.eq("訳文", assert(editor:get_text("target")))

  subscription:dispose()
  editor:dispose()
  test.eq(false, vim.api.nvim_buf_is_valid(view.target_buf))
  test.eq(true, vim.api.nvim_buf_is_valid(source_buf))
  vim.api.nvim_buf_delete(source_buf, { force = true })
end)

-- Preconditions: A target scratch buffer exists while an initial translation
-- has completed one of three batches. Prerequisites: ui.show_progress owns a
-- dedicated, content-free virtual-text indicator and does not depend on group
-- state rendering or ui.virtual_text. Verification items: the target receives
-- exactly one "Translating 1/3" extmark and a nil update removes it completely.
test.it("renders and clears initial batch progress on the target", function()
  local source_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(source_buf, vim.fn.tempname() .. ".txt")
  vim.api.nvim_buf_set_lines(source_buf, 0, -1, true, { "Source" })
  vim.api.nvim_win_set_buf(0, source_buf)
  local editor = nvim_editor.new({
    source_buf = source_buf,
    source_window = vim.api.nvim_get_current_win(),
    session_id = "editor-progress",
    target_language = "ja",
    layout = { direction = "vertical", target_position = "right", size = 0.5 },
    ui = { signs = true, virtual_text = false, show_progress = true },
  })
  local view
  editor:create_target_view({}, function(created)
    view = created
  end)

  editor:render_initial_progress({ completed = 1, total = 3 })
  local marks = vim.api.nvim_buf_get_extmarks(
    view.target_buf,
    editor.state_namespace,
    0,
    -1,
    { details = true }
  )
  test.eq(1, #marks)
  test.eq(" Translating 1/3…", marks[1][4].virt_text[1][1])

  editor:render_initial_progress(nil)
  test.eq(
    {},
    vim.api.nvim_buf_get_extmarks(
      view.target_buf,
      editor.state_namespace,
      0,
      -1,
      { details = true }
    )
  )

  editor:dispose()
  vim.api.nvim_buf_delete(source_buf, { force = true })
end)

-- Preconditions: A source subscription has a pending edit that Session would
-- normally debounce. Prerequisites: EditorPort owns a Session augroup and reports
-- InsertLeave as a lightweight flush event without reading or parsing document
-- text in the autocmd callback. Verification items: one scheduled event identifies
-- the source side, has no synthetic changed range, and carries flush=true.
test.it("reports InsertLeave as a scheduled synchronization flush", function()
  local source_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(source_buf, 0, -1, true, { "Source" })
  vim.api.nvim_win_set_buf(0, source_buf)
  local editor = nvim_editor.new({
    source_buf = source_buf,
    source_window = vim.api.nvim_get_current_win(),
    session_id = "editor-insert-leave",
    target_language = "ja",
    layout = { direction = "vertical", target_position = "right", size = 0.5 },
    ui = { signs = true, virtual_text = true },
  })
  local observed
  local subscription = editor:subscribe_changes("source", function(change)
    if change.flush then
      observed = change
    end
  end)

  vim.api.nvim_exec_autocmds("InsertLeave", { buffer = source_buf, modeline = false })
  vim.wait(100, function()
    return observed ~= nil
  end)

  test.eq("source", observed.side)
  test.eq("user", observed.origin)
  test.eq(true, observed.flush)
  test.eq(0, #observed.ranges)

  subscription:dispose()
  editor:dispose()
  vim.api.nvim_buf_delete(source_buf, { force = true })
end)

-- Preconditions: Both Session buffers are visible, anchored, contain two
-- corresponding groups, and target group two is inside a closed manual fold;
-- follow_cursor and open_folds are enabled with a short debounce. Prerequisites:
-- CursorMoved handling stays inside the Editor Adapter, uses the rendered graph,
-- preserves the destination view through winsaveview/winrestview, and never takes
-- focus. Verification items: source group two moves the target cursor to group two,
-- opens its fold while retaining the target topline, preserves source focus, and
-- disposal removes the follow resources.
test.it("follows the corresponding group without stealing window focus", function()
  local plaintext = require("bilingua.adapters.document.plaintext").new()
  local source_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(source_buf, 0, -1, true, { "One", "", "Two" })
  vim.bo[source_buf].filetype = "text"
  vim.api.nvim_win_set_buf(0, source_buf)
  local source_window = vim.api.nvim_get_current_win()
  local editor = nvim_editor.new({
    source_buf = source_buf,
    source_window = source_window,
    session_id = "editor-follow",
    target_language = "ja",
    layout = {
      direction = "vertical",
      target_position = "right",
      size = 0.5,
      follow_cursor = true,
      follow_debounce_ms = 10,
      open_folds = true,
    },
    ui = { signs = true, virtual_text = true },
  })
  local view
  editor:create_target_view({}, function(created)
    view = created
  end)
  editor:set_target_modifiable(true)
  assert(editor:apply_edits("target", {
    {
      range = { start = { row = 0, col = 0 }, finish = { row = 0, col = 0 } },
      expected_text = "",
      replacement = "一\n\n二\n続き",
    },
  }, assert(editor:get_version("target")), "bilingua-test"))

  local source = assert(plaintext:parse({
    side = "source",
    text = assert(editor:get_text("source")),
    filetype = "text",
    language = "en",
    editor_version = assert(editor:get_version("source")),
  }))
  local target = assert(plaintext:parse({
    side = "target",
    text = assert(editor:get_text("target")),
    filetype = "text",
    language = "ja",
    editor_version = assert(editor:get_version("target")),
  }))
  editor:set_unit_anchors("source", source)
  editor:set_unit_anchors("target", target)
  editor:render_group_states({
    order = { "group:1", "group:2" },
    groups = {
      ["group:1"] = {
        state = "clean",
        source_unit_ids = { source.order[1] },
        target_unit_ids = { target.order[1] },
      },
      ["group:2"] = {
        state = "clean",
        source_unit_ids = { source.order[2] },
        target_unit_ids = { target.order[2] },
      },
    },
  })

  vim.api.nvim_win_set_cursor(view.target_window, { 1, 0 })
  vim.api.nvim_win_call(view.target_window, function()
    vim.wo.foldmethod = "manual"
    vim.wo.foldenable = true
    vim.cmd("3,4fold")
  end)
  local target_topline = vim.api.nvim_win_call(view.target_window, function()
    return vim.fn.winsaveview().topline
  end)
  test.eq(
    3,
    vim.api.nvim_win_call(view.target_window, function()
      return vim.fn.foldclosed(3)
    end)
  )
  test.eq({ 1, 0 }, vim.api.nvim_win_get_cursor(view.target_window))
  vim.api.nvim_set_current_win(source_window)
  vim.api.nvim_win_set_cursor(source_window, { 3, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = source_buf, modeline = false })
  vim.wait(200, function()
    return vim.api.nvim_win_get_cursor(view.target_window)[1] == 3
  end)

  test.eq(source_window, vim.api.nvim_get_current_win())
  test.eq({ 3, 0 }, vim.api.nvim_win_get_cursor(view.target_window))
  test.eq(
    -1,
    vim.api.nvim_win_call(view.target_window, function()
      return vim.fn.foldclosed(3)
    end)
  )
  test.eq(
    target_topline,
    vim.api.nvim_win_call(view.target_window, function()
      return vim.fn.winsaveview().topline
    end)
  )

  editor:dispose()
  test.eq(false, vim.api.nvim_buf_is_valid(view.target_buf))
  vim.api.nvim_buf_delete(source_buf, { force = true })
end)
