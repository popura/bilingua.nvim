local errors = require("bilingua.domain.error")
local ranges = require("bilingua.util.ranges")

local NvimEditor = {}
NvimEditor.__index = NvimEditor

local STATE_RENDERING = {
  clean = { text = "✓", highlight = "DiagnosticOk" },
  dirty_source = { text = "S", highlight = "DiagnosticWarn" },
  dirty_target = { text = "J", highlight = "DiagnosticWarn" },
  syncing_source_to_target = { text = "…", highlight = "DiagnosticInfo" },
  syncing_target_to_source = { text = "…", highlight = "DiagnosticInfo" },
  conflict = { text = "!", highlight = "DiagnosticError" },
  invalid = { text = "×", highlight = "DiagnosticError" },
}

local function buffer_error(message, code)
  return errors.new(code or errors.codes.APPLY, message, false)
end

local function replacement_lines(replacement)
  if replacement == "" then
    return {}
  end
  return vim.split(replacement, "\n", { plain = true })
end

local function buffer_text(buffer)
  return table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, true), "\n")
end

local function side_buffer(self, side)
  return side == "source" and self.source_buf or self.target_buf
end

local function window_for_buffer(buffer)
  for _, window in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(window) and vim.api.nvim_win_get_buf(window) == buffer then
      return window
    end
  end
  return nil
end

local function target_name(source_buf, target_language)
  local source_name = vim.api.nvim_buf_get_name(source_buf)
  local basename = vim.fn.fnamemodify(source_name, ":t")
  if basename == "" then
    basename = "untitled"
  end
  return ("bilingua://%s/%d/%s"):format(target_language, source_buf, basename)
end

function NvimEditor.new(context)
  if type(context) ~= "table" or type(context.source_buf) ~= "number" then
    error("NvimEditor requires a source buffer", 2)
  end
  local namespace_suffix = tostring(context.session_id):gsub("[^%w_-]", "-")
  return setmetatable({
    api_version = 1,
    source_buf = context.source_buf,
    source_window = context.source_window,
    target_buf = nil,
    target_window = nil,
    created_window = nil,
    target_language = context.target_language,
    layout = context.layout,
    ui = context.ui,
    anchor_namespace = vim.api.nvim_create_namespace("bilingua-anchor-" .. namespace_suffix),
    state_namespace = vim.api.nvim_create_namespace("bilingua-state-" .. namespace_suffix),
    augroup = vim.api.nvim_create_augroup(
      "bilingua-session-" .. namespace_suffix,
      { clear = true }
    ),
    apply_guards = {},
    anchors = { source = {}, target = {} },
    subscriptions = {},
    graph = nil,
    cursor_follow_timer = nil,
    cursor_follow_installed = false,
    following_cursor = false,
    disposed = false,
  }, NvimEditor)
end

function NvimEditor:capabilities()
  return {
    atomic_edits = false,
    extmarks = true,
    undo_join = true,
    change_origin = true,
  }
end

function NvimEditor:create_target_view(_, callback)
  if self.disposed or not vim.api.nvim_buf_is_valid(self.source_buf) then
    callback(
      nil,
      buffer_error("The source buffer is no longer valid", errors.codes.INVALID_SOURCE_BUFFER)
    )
    return
  end

  local target = vim.api.nvim_create_buf(false, true)
  self.target_buf = target
  vim.api.nvim_buf_set_name(target, target_name(self.source_buf, self.target_language))
  vim.bo[target].buftype = "nofile"
  vim.bo[target].bufhidden = "hide"
  vim.bo[target].buflisted = false
  vim.bo[target].swapfile = false
  vim.bo[target].undofile = false
  vim.bo[target].filetype = vim.bo[self.source_buf].filetype
  vim.bo[target].modifiable = false

  local command
  if self.layout.direction == "vertical" then
    command = self.layout.target_position == "left" and "leftabove vsplit" or "rightbelow vsplit"
  else
    command = self.layout.target_position == "above" and "leftabove split" or "rightbelow split"
  end
  local ok, split_error = pcall(vim.cmd, command)
  if not ok then
    vim.api.nvim_buf_delete(target, { force = true })
    self.target_buf = nil
    callback(
      nil,
      buffer_error("Unable to create the translation split", errors.codes.APPLY, split_error)
    )
    return
  end

  local target_window = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(target_window, target)
  self.target_window = target_window
  self.created_window = target_window
  if type(self.layout.size) == "number" then
    if self.layout.direction == "vertical" then
      local width = self.layout.size < 1 and math.floor(vim.o.columns * self.layout.size)
        or self.layout.size
      pcall(vim.api.nvim_win_set_width, target_window, math.max(1, width))
    else
      local height = self.layout.size < 1 and math.floor(vim.o.lines * self.layout.size)
        or self.layout.size
      pcall(vim.api.nvim_win_set_height, target_window, math.max(1, height))
    end
  end

  self:install_cursor_follow()
  callback({
    source_buf = self.source_buf,
    target_buf = target,
    source_window = self.source_window,
    target_window = target_window,
  })
end

function NvimEditor:get_document(side)
  local buffer = side_buffer(self, side)
  if
    not buffer
    or not vim.api.nvim_buf_is_valid(buffer)
    or not vim.api.nvim_buf_is_loaded(buffer)
  then
    return nil,
      buffer_error(
        "The requested document buffer is unavailable",
        errors.codes.INVALID_SOURCE_BUFFER
      )
  end
  return {
    text = buffer_text(buffer),
    filetype = vim.bo[buffer].filetype,
    version = vim.api.nvim_buf_get_changedtick(buffer),
    metadata = { endofline = vim.bo[buffer].endofline },
  }
end

function NvimEditor:get_text(side)
  local document, err = self:get_document(side)
  return document and document.text or nil, err
end

function NvimEditor:get_version(side)
  local buffer = side_buffer(self, side)
  if not buffer or not vim.api.nvim_buf_is_valid(buffer) then
    return nil,
      buffer_error(
        "The requested document buffer is unavailable",
        errors.codes.INVALID_SOURCE_BUFFER
      )
  end
  return vim.api.nvim_buf_get_changedtick(buffer)
end

function NvimEditor:apply_edits(side, edits, expected_version, origin)
  local buffer = side_buffer(self, side)
  if not buffer or not vim.api.nvim_buf_is_valid(buffer) then
    return nil, buffer_error("The destination buffer is invalid or not modifiable")
  end
  -- The scratch target stays read-only until its first programmatic translation is complete.
  local temporarily_modifiable = side == "target"
    and origin == "bilingua-initial"
    and not vim.bo[buffer].modifiable
  if not vim.bo[buffer].modifiable and not temporarily_modifiable then
    return nil, buffer_error("The destination buffer is invalid or not modifiable")
  end
  if vim.api.nvim_buf_get_changedtick(buffer) ~= expected_version then
    return nil,
      buffer_error(
        "The destination changed before edit application",
        errors.codes.APPLY_VERSION_MISMATCH
      )
  end

  local original_text = buffer_text(buffer)
  local checked = {}
  for _, edit in ipairs(edits) do
    local ok, first, finish = pcall(function()
      return ranges.position_to_offset(original_text, edit.range.start),
        ranges.position_to_offset(original_text, edit.range.finish)
    end)
    if not ok or first > finish or original_text:sub(first + 1, finish) ~= edit.expected_text then
      return nil, buffer_error("A TextEdit range or expected_text no longer matches")
    end
    checked[#checked + 1] = { edit = edit, first = first, finish = finish }
  end
  table.sort(checked, function(left, right)
    return left.first > right.first
  end)
  for index = 2, #checked do
    if checked[index - 1].first < checked[index].finish then
      return nil, buffer_error("TextEdit ranges overlap")
    end
  end

  if temporarily_modifiable then
    vim.bo[buffer].modifiable = true
  end
  self.apply_guards[buffer] = (self.apply_guards[buffer] or 0) + 1
  local applied, apply_error = xpcall(function()
    for index, checked_edit in ipairs(checked) do
      if index > 1 then
        vim.api.nvim_buf_call(buffer, function()
          pcall(vim.cmd, "undojoin")
        end)
      end
      local edit = checked_edit.edit
      vim.api.nvim_buf_set_text(
        buffer,
        edit.range.start.row,
        edit.range.start.col,
        edit.range.finish.row,
        edit.range.finish.col,
        replacement_lines(edit.replacement)
      )
    end
  end, debug.traceback)
  self.apply_guards[buffer] = self.apply_guards[buffer] - 1

  if not applied then
    self.apply_guards[buffer] = self.apply_guards[buffer] + 1
    pcall(
      vim.api.nvim_buf_set_lines,
      buffer,
      0,
      -1,
      true,
      vim.split(original_text, "\n", { plain = true })
    )
    if temporarily_modifiable then
      vim.bo[buffer].modifiable = false
    end
    self.apply_guards[buffer] = self.apply_guards[buffer] - 1
    return nil,
      errors.new(
        errors.codes.APPLY,
        "Neovim rejected a validated TextEdit",
        false,
        nil,
        apply_error
      )
  end

  if temporarily_modifiable then
    vim.bo[buffer].modifiable = false
  end
  self.last_origin = origin
  return { version = vim.api.nvim_buf_get_changedtick(buffer) }
end

function NvimEditor:subscribe_changes(side, callback)
  local buffer = side_buffer(self, side)
  local subscription = { disposed = false }

  local function reload_change()
    return {
      side = side,
      version = vim.api.nvim_buf_get_changedtick(buffer),
      ranges = {},
      origin = "reload",
      full_reload = true,
    }
  end
  local callbacks
  callbacks = {
    on_lines = function(_, _, changedtick, first, _, new_last)
      if subscription.disposed or self.disposed then
        return true
      end
      local origin = (self.apply_guards[buffer] or 0) > 0 and "plugin" or "user"
      local change = {
        side = side,
        version = changedtick,
        ranges = {
          { start = { row = first, col = 0 }, finish = { row = new_last, col = 0 } },
        },
        origin = origin,
        full_reload = false,
      }
      vim.schedule(function()
        if not subscription.disposed and not self.disposed then
          callback(change)
        end
      end)
    end,
    on_reload = function()
      if subscription.disposed or self.disposed then
        return
      end
      vim.schedule(function()
        if
          not subscription.disposed
          and not self.disposed
          and vim.api.nvim_buf_is_valid(buffer)
        then
          callback(reload_change())
        end
      end)
    end,
    on_detach = function()
      if subscription.disposed or self.disposed then
        return
      end
      vim.schedule(function()
        if subscription.disposed or self.disposed then
          return
        end
        if vim.api.nvim_buf_is_valid(buffer) and vim.api.nvim_buf_is_loaded(buffer) then
          local reattach_ok, reattached = pcall(vim.api.nvim_buf_attach, buffer, false, callbacks)
          if reattach_ok and reattached then
            callback(reload_change())
            return
          end
        end
        callback({
          side = side,
          version = -1,
          ranges = {},
          origin = "unknown",
          full_reload = true,
          detached = true,
        })
      end)
    end,
  }
  local attached = vim.api.nvim_buf_attach(buffer, false, callbacks)
  if not attached then
    return {
      dispose = function()
        subscription.disposed = true
      end,
    }
  end

  subscription.autocmd = vim.api.nvim_create_autocmd("InsertLeave", {
    group = self.augroup,
    buffer = buffer,
    callback = function()
      vim.schedule(function()
        if
          not subscription.disposed
          and not self.disposed
          and vim.api.nvim_buf_is_valid(buffer)
        then
          callback({
            side = side,
            version = vim.api.nvim_buf_get_changedtick(buffer),
            ranges = {},
            origin = "user",
            full_reload = false,
            flush = true,
          })
        end
      end)
    end,
  })

  function subscription:dispose()
    if self.disposed then
      return
    end
    self.disposed = true
    if self.autocmd then
      pcall(vim.api.nvim_del_autocmd, self.autocmd)
    end
    if vim.api.nvim_buf_is_valid(buffer) then
      pcall(vim.api.nvim_buf_detach, buffer)
    end
  end
  self.subscriptions[#self.subscriptions + 1] = subscription
  return subscription
end

function NvimEditor:set_unit_anchors(side, snapshot)
  local buffer = side_buffer(self, side)
  if not buffer or not vim.api.nvim_buf_is_valid(buffer) then
    return nil, buffer_error("Cannot anchor an invalid buffer")
  end
  vim.api.nvim_buf_clear_namespace(buffer, self.anchor_namespace, 0, -1)
  self.anchors[side] = {}
  for _, unit_id in ipairs(snapshot.order) do
    local unit = snapshot.units[unit_id]
    local options = {
      end_row = unit.span.finish.row,
      end_col = unit.span.finish.col,
      right_gravity = false,
      end_right_gravity = true,
      strict = true,
    }
    if vim.fn.has("nvim-0.10") == 1 then
      options.invalidate = true
      options.undo_restore = true
    end
    local mark = vim.api.nvim_buf_set_extmark(
      buffer,
      self.anchor_namespace,
      unit.span.start.row,
      unit.span.start.col,
      options
    )
    self.anchors[side][unit_id] = mark
  end
  return self.anchors[side]
end

function NvimEditor:get_anchor_hints(side)
  local buffer = side_buffer(self, side)
  local hints = {}
  if not buffer or not vim.api.nvim_buf_is_valid(buffer) then
    return hints
  end
  for unit_id, mark in pairs(self.anchors[side]) do
    local position =
      vim.api.nvim_buf_get_extmark_by_id(buffer, self.anchor_namespace, mark, { details = true })
    if #position > 0 then
      local details = position[3] or {}
      hints[unit_id] = {
        range = {
          start = { row = position[1], col = position[2] },
          finish = { row = details.end_row or position[1], col = details.end_col or position[2] },
        },
        invalid = details.invalid == true,
      }
    else
      hints[unit_id] = { invalid = true }
    end
  end
  return hints
end

function NvimEditor:unit_at_cursor(side)
  local buffer = side_buffer(self, side)
  local window = window_for_buffer(buffer)
  if not window then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(window)
  local row, col = cursor[1] - 1, cursor[2]
  for unit_id, hint in pairs(self:get_anchor_hints(side)) do
    if not hint.invalid then
      local first, finish = hint.range.start, hint.range.finish
      local after_start = row > first.row or (row == first.row and col >= first.col)
      local before_finish = row < finish.row or (row == finish.row and col < finish.col)
      if after_start and before_finish then
        return unit_id
      end
    end
  end
  return nil
end

function NvimEditor:focus_side(side)
  local buffer = side_buffer(self, side)
  if not buffer or not vim.api.nvim_buf_is_valid(buffer) then
    return false
  end
  local window = window_for_buffer(buffer)
  if not window then
    vim.cmd(self.layout.direction == "vertical" and "rightbelow vsplit" or "rightbelow split")
    window = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(window, buffer)
  end
  vim.api.nvim_set_current_win(window)
  return true
end

function NvimEditor:focus_group(side, unit_ids)
  if not self:focus_side(side) then
    return false
  end
  local hint = self:get_anchor_hints(side)[unit_ids[1]]
  if not hint or hint.invalid then
    return false
  end
  vim.api.nvim_win_set_cursor(0, { hint.range.start.row + 1, hint.range.start.col })
  return true
end

function NvimEditor:group_id_for_unit(side, unit_id)
  if not self.graph or not unit_id then
    return nil
  end
  if type(self.graph.group_ids_for_unit) == "function" then
    local group_ids = self.graph:group_ids_for_unit(side, unit_id)
    return group_ids and group_ids[1] or nil
  end
  local field = side .. "_unit_ids"
  for _, group_id in ipairs(self.graph.order or {}) do
    for _, candidate in ipairs(self.graph.groups[group_id][field] or {}) do
      if candidate == unit_id then
        return group_id
      end
    end
  end
  return nil
end

function NvimEditor:cancel_cursor_follow()
  local timer = self.cursor_follow_timer
  self.cursor_follow_timer = nil
  if not timer then
    return
  end
  if type(timer.stop) == "function" then
    pcall(timer.stop, timer)
  end
  local closing = false
  if type(timer.is_closing) == "function" then
    local checked, value = pcall(timer.is_closing, timer)
    closing = checked and value == true
  end
  if not closing and type(timer.close) == "function" then
    pcall(timer.close, timer)
  end
end

function NvimEditor:follow_cursor(side)
  if self.disposed or self.following_cursor or not self.graph then
    return
  end
  local unit_id = self:unit_at_cursor(side)
  local group_id = self:group_id_for_unit(side, unit_id)
  local group = group_id and self.graph.groups[group_id] or nil
  if not group then
    return
  end

  local destination_side = side == "source" and "target" or "source"
  local unit_ids = group[destination_side .. "_unit_ids"] or {}
  local hint = unit_ids[1] and self:get_anchor_hints(destination_side)[unit_ids[1]] or nil
  local destination_window = window_for_buffer(side_buffer(self, destination_side))
  if not hint or hint.invalid or not destination_window then
    return
  end

  local target = { hint.range.start.row + 1, hint.range.start.col }
  local current = vim.api.nvim_win_get_cursor(destination_window)
  if current[1] == target[1] and current[2] == target[2] then
    return
  end
  self.following_cursor = true
  pcall(vim.api.nvim_win_call, destination_window, function()
    local original_view = vim.fn.winsaveview()
    vim.api.nvim_win_set_cursor(destination_window, target)
    if self.layout.open_folds == true then
      vim.cmd("normal! zv")
    end
    local destination_view = vim.fn.winsaveview()
    for _, field in ipairs({ "topline", "topfill", "leftcol", "skipcol" }) do
      if original_view[field] ~= nil then
        destination_view[field] = original_view[field]
      end
    end
    vim.fn.winrestview(destination_view)
  end)
  self.following_cursor = false
end

function NvimEditor:schedule_cursor_follow(side)
  if self.disposed or self.following_cursor then
    return
  end
  self:cancel_cursor_follow()
  local timer
  timer = vim.defer_fn(function()
    if self.cursor_follow_timer ~= timer then
      return
    end
    self.cursor_follow_timer = nil
    self:follow_cursor(side)
  end, self.layout.follow_debounce_ms or 50)
  self.cursor_follow_timer = timer
end

function NvimEditor:install_cursor_follow()
  if self.cursor_follow_installed or self.layout.follow_cursor ~= true then
    return
  end
  self.cursor_follow_installed = true
  for _, side in ipairs({ "source", "target" }) do
    local buffer = side_buffer(self, side)
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
      group = self.augroup,
      buffer = buffer,
      desc = "Follow the corresponding Bilingua group",
      callback = function()
        if not self.following_cursor then
          self:schedule_cursor_follow(side)
        end
      end,
    })
  end
end

function NvimEditor:render_group_states(graph)
  self.graph = graph
  for _, side in ipairs({ "source", "target" }) do
    local buffer = side_buffer(self, side)
    if buffer and vim.api.nvim_buf_is_valid(buffer) then
      vim.api.nvim_buf_clear_namespace(buffer, self.state_namespace, 0, -1)
      local field = side .. "_unit_ids"
      for _, group_id in ipairs(graph.order) do
        local group = graph.groups[group_id]
        local unit_id = group[field][1]
        local hint = unit_id and self:get_anchor_hints(side)[unit_id]
        local rendering = STATE_RENDERING[group.state]
        if hint and not hint.invalid and rendering then
          local options = {
            sign_text = self.ui.signs and rendering.text or nil,
            sign_hl_group = rendering.highlight,
            virt_text = self.ui.virtual_text and { { " " .. rendering.text, rendering.highlight } }
              or nil,
            virt_text_pos = "eol",
          }
          vim.api.nvim_buf_set_extmark(
            buffer,
            self.state_namespace,
            hint.range.start.row,
            hint.range.start.col,
            options
          )
        end
      end
    end
  end
end

function NvimEditor:render_initial_progress(progress)
  local buffer = self.target_buf
  if not buffer or not vim.api.nvim_buf_is_valid(buffer) then
    return false
  end
  vim.api.nvim_buf_clear_namespace(buffer, self.state_namespace, 0, -1)
  if
    progress == nil
    or self.ui.show_progress ~= true
    or type(progress.completed) ~= "number"
    or type(progress.total) ~= "number"
  then
    return true
  end
  vim.api.nvim_buf_set_extmark(buffer, self.state_namespace, 0, 0, {
    virt_text = {
      {
        (" Translating %d/%d…"):format(progress.completed, progress.total),
        "DiagnosticInfo",
      },
    },
    virt_text_pos = "eol",
  })
  return true
end

function NvimEditor:set_target_modifiable(value)
  if self.target_buf and vim.api.nvim_buf_is_valid(self.target_buf) then
    vim.bo[self.target_buf].modifiable = value
  end
end

function NvimEditor:set_target_modified(value)
  if self.target_buf and vim.api.nvim_buf_is_valid(self.target_buf) then
    vim.bo[self.target_buf].modified = value
  end
end

function NvimEditor:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  self:cancel_cursor_follow()
  for _, subscription in ipairs(self.subscriptions) do
    subscription:dispose()
  end
  self.subscriptions = {}
  for _, buffer in ipairs({ self.source_buf, self.target_buf }) do
    if buffer and vim.api.nvim_buf_is_valid(buffer) then
      pcall(vim.api.nvim_buf_clear_namespace, buffer, self.anchor_namespace, 0, -1)
      pcall(vim.api.nvim_buf_clear_namespace, buffer, self.state_namespace, 0, -1)
    end
  end
  pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
  if self.created_window and vim.api.nvim_win_is_valid(self.created_window) then
    pcall(vim.api.nvim_win_close, self.created_window, true)
  end
  if self.target_buf and vim.api.nvim_buf_is_valid(self.target_buf) then
    pcall(vim.api.nvim_buf_delete, self.target_buf, { force = true })
  end
  self.anchors = { source = {}, target = {} }
  self.target_buf = nil
  self.target_window = nil
end

return {
  new = NvimEditor.new,
}
