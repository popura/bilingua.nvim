local errors = require("bilingua.domain.error")

local M = {
  registered = false,
  global_start_mapping = nil,
  session_mappings = {},
  augroup = nil,
}

local PLUG_COMMANDS = {
  Start = "BilinguaStart",
  Toggle = "BilinguaToggle",
  Sync = "BilinguaSync",
  SyncAll = "BilinguaSyncAll",
  UseSource = "BilinguaUseSource",
  UseJapanese = "BilinguaUseJapanese",
  Next = "BilinguaNext",
  Prev = "BilinguaPrev",
  Status = "BilinguaStatus",
  Retry = "BilinguaRetry",
  RestartBackend = "BilinguaRestartBackend",
  Stop = "BilinguaStop",
  Quit = "BilinguaQuit",
}

local BUFFER_MAPPINGS = {
  toggle = "Toggle",
  sync = "Sync",
  sync_all = "SyncAll",
  use_source = "UseSource",
  use_japanese = "UseJapanese",
  next = "Next",
  prev = "Prev",
  stop = "Stop",
  quit = "Quit",
}

local function report(err)
  local normalized = err
  if type(normalized) ~= "table" or type(normalized.code) ~= "string" then
    normalized = errors.new(errors.codes.INTERNAL, "An unexpected Bilingua error occurred", false)
  end
  vim.notify(
    ("Bilingua: %s [%s]"):format(normalized.message, normalized.code),
    vim.log.levels.ERROR,
    { title = "Bilingua" }
  )
end

local function call(operation)
  local called, value, err = pcall(operation)
  if not called then
    report(errors.new(errors.codes.INTERNAL, "A Bilingua command failed", false))
    return
  end
  if not value and err then
    report(err)
  end
end

local function call_async(operation)
  local delivered = false
  local called, accepted, immediate_error = pcall(operation, function(value, err)
    delivered = true
    if not value and err then
      report(err)
    end
  end)
  if not called then
    report(errors.new(errors.codes.INTERNAL, "A Bilingua command failed", false))
  elseif not accepted and immediate_error and not delivered then
    report(immediate_error)
  end
end

local function groups_line(groups)
  local dirty = (groups.dirty_source or 0) + (groups.dirty_target or 0)
  local syncing = (groups.syncing_source_to_target or 0) + (groups.syncing_target_to_source or 0)
  return ("Groups: %d clean / %d dirty / %d syncing / %d conflict / %d error"):format(
    groups.clean or 0,
    dirty,
    syncing,
    groups.conflict or 0,
    groups.invalid or 0
  )
end

local function automatic_sync_line(status)
  if status.automatic_sync_paused then
    return "Auto sync: paused"
  end
  return "Auto sync: " .. (status.automatic_sync and "enabled" or "disabled")
end

function M.format_status(status)
  return table.concat({
    "Session: " .. tostring(status.state or "unknown"),
    "Health: " .. tostring(status.health or "unknown"),
    "Source: " .. tostring(status.source_path or status.source_buf or "unknown"),
    "Target buffer: " .. tostring(status.target_buf or "unknown"),
    "Source language: " .. tostring(status.source_language or "unknown"),
    "Target language: " .. tostring(status.target_language or "unknown"),
    "Document adapter: " .. tostring(status.document_adapter or "unknown"),
    "Tracker: " .. tostring(status.tracker or "unknown"),
    "Aligner: " .. tostring(status.aligner or "unknown"),
    "Backend: " .. tostring(status.backend or "unknown"),
    "Model: " .. tostring(status.model or "unresolved"),
    groups_line(status.groups or {}),
    "Active tasks: " .. tostring(status.active_tasks or 0),
    automatic_sync_line(status),
  }, "\n")
end

function M.register(api)
  if M.registered then
    return true
  end
  M.registered = true
  M.augroup = vim.api.nvim_create_augroup("bilingua-global", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = M.augroup,
    desc = "Dispose all Bilingua Sessions",
    callback = function()
      if type(api._dispose_all) == "function" then
        pcall(api._dispose_all)
      end
    end,
  })

  for suffix, command in pairs(PLUG_COMMANDS) do
    vim.keymap.set("n", "<Plug>(Bilingua" .. suffix .. ")", "<Cmd>" .. command .. "<CR>", {
      silent = true,
    })
  end

  vim.api.nvim_create_user_command("BilinguaStart", function(command)
    call_async(function(callback)
      return api.start({
        source_language = command.args ~= "" and command.args or nil,
        force = command.bang,
      }, callback)
    end)
  end, { nargs = "?", bang = true })
  vim.api.nvim_create_user_command("BilinguaToggle", function()
    call(api.toggle)
  end, {})
  vim.api.nvim_create_user_command("BilinguaSync", function()
    call(api.sync_current)
  end, {})
  vim.api.nvim_create_user_command("BilinguaSyncAll", function()
    call(api.sync_all)
  end, {})
  vim.api.nvim_create_user_command("BilinguaUseSource", function()
    call(api.use_source)
  end, {})
  vim.api.nvim_create_user_command("BilinguaUseJapanese", function()
    call(api.use_japanese)
  end, {})
  vim.api.nvim_create_user_command("BilinguaNext", function()
    call(api.next_group)
  end, {})
  vim.api.nvim_create_user_command("BilinguaPrev", function()
    call(api.prev_group)
  end, {})
  vim.api.nvim_create_user_command("BilinguaStatus", function()
    call(function()
      local status, status_error = api.status()
      if not status then
        return nil, status_error
      end
      vim.notify(M.format_status(status), vim.log.levels.INFO, { title = "Bilingua" })
      return true
    end)
  end, {})
  vim.api.nvim_create_user_command("BilinguaRetry", function()
    call_async(function(callback)
      return api.retry_current(callback)
    end)
  end, {})
  vim.api.nvim_create_user_command("BilinguaRestartBackend", function()
    call_async(function(callback)
      return api.restart_backend(callback)
    end)
  end, {})
  vim.api.nvim_create_user_command("BilinguaStop", function(command)
    call_async(function(callback)
      return api.stop({ force = command.bang }, callback)
    end)
  end, { bang = true })
  vim.api.nvim_create_user_command("BilinguaQuit", function(command)
    call_async(function(callback)
      return api.quit({ force = command.bang }, callback)
    end)
  end, { bang = true })
  return true
end

local function usable_mapping(value)
  return type(value) == "string" and value ~= ""
end

function M.configure(config)
  if M.global_start_mapping then
    pcall(vim.keymap.del, "n", M.global_start_mapping)
    M.global_start_mapping = nil
  end
  if config.mappings.enabled and usable_mapping(config.mappings.start) then
    vim.keymap.set("n", config.mappings.start, "<Plug>(BilinguaStart)", {
      silent = true,
      desc = "Start Bilingua Session",
    })
    M.global_start_mapping = config.mappings.start
  end
end

function M.install_session_mappings(config, source_buf, target_buf)
  if not config.mappings.enabled then
    return
  end
  for _, buffer in ipairs({ source_buf, target_buf }) do
    if buffer and vim.api.nvim_buf_is_valid(buffer) then
      M.session_mappings[buffer] = M.session_mappings[buffer] or {}
      for name, suffix in pairs(BUFFER_MAPPINGS) do
        local lhs = config.mappings[name]
        if usable_mapping(lhs) then
          vim.keymap.set("n", lhs, "<Plug>(Bilingua" .. suffix .. ")", {
            buffer = buffer,
            silent = true,
            desc = "Bilingua " .. suffix,
          })
          M.session_mappings[buffer][#M.session_mappings[buffer] + 1] = lhs
        end
      end
    end
  end
end

function M.remove_session_mappings(source_buf, target_buf)
  for _, buffer in ipairs({ source_buf, target_buf }) do
    for _, lhs in ipairs(M.session_mappings[buffer] or {}) do
      if vim.api.nvim_buf_is_valid(buffer) then
        pcall(vim.keymap.del, "n", lhs, { buffer = buffer })
      end
    end
    M.session_mappings[buffer] = nil
  end
end

return M
