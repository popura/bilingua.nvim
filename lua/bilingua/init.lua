local config_module = require("bilingua.config")
local coordinator_module = require("bilingua.app.coordinator")
local errors = require("bilingua.domain.error")
local nvim_editor = require("bilingua.adapters.editor.nvim")
local nvim_runtime = require("bilingua.ui.nvim_runtime")
local registry_module = require("bilingua.registry")
local session_factory_module = require("bilingua.app.session_factory")
local session_registry = require("bilingua.session_registry")
local standard_registry = require("bilingua.standard_registry")

local M = {}

local configured_options = {}
local resolved_config = config_module.defaults()
local configuration_error
local commands_loaded = false
local coordinator

local function deep_copy(value, seen)
  if type(value) ~= "table" then
    return value
  end
  local visited = seen or {}
  if visited[value] then
    return visited[value]
  end
  local copy = {}
  visited[value] = copy
  for key, item in pairs(value) do
    copy[deep_copy(key, visited)] = deep_copy(item, visited)
  end
  return copy
end

local ATOMIC_CONFIG_TABLES = {
  ["documents.protected_patterns"] = true,
  ["translation.backend_options.command"] = true,
}

local function deep_merge(destination, source, path)
  local parent_path = path or ""
  for key, value in pairs(source or {}) do
    local current_path = parent_path == "" and tostring(key)
      or (parent_path .. "." .. tostring(key))
    if
      type(value) == "table"
      and type(destination[key]) == "table"
      and not ATOMIC_CONFIG_TABLES[current_path]
      and value[1] == nil
      and destination[key][1] == nil
    then
      deep_merge(destination[key], value, current_path)
    else
      destination[key] = deep_copy(value)
    end
  end
  return destination
end

local function session_options(options)
  local overrides = deep_copy(options or {})
  overrides.force = nil
  overrides.source_buf = nil
  if overrides.backend ~= nil then
    overrides.translation = overrides.translation or {}
    overrides.translation.backend = overrides.backend
    overrides.backend = nil
  end
  return overrides
end

local function resolve_session_config(options)
  if configuration_error then
    return nil, configuration_error
  end
  local merged = deep_merge(deep_copy(configured_options), session_options(options))
  return config_module.resolve(merged)
end

local function ensure_runtime()
  if coordinator then
    return coordinator
  end
  local registry = registry_module.default()
  local registered, registration_error = standard_registry.register(registry)
  if not registered then
    configuration_error = registration_error
  end
  local platform = nvim_runtime.new()
  local factory = session_factory_module.new({
    registry = registry,
    scheduler = platform.scheduler,
    sha256 = platform.sha256,
    backend_runtime = platform.backend_runtime,
    document_runtime = platform.document_runtime,
    warn = platform.warn,
    editor_factory = function(config, context)
      return nvim_editor.new({
        session_id = context.session_id,
        source_buf = context.source_buf,
        source_window = context.source_window,
        target_language = config.target_language,
        layout = config.layout,
        ui = config.ui,
      })
    end,
  })
  coordinator = coordinator_module.new({
    session_factory = factory,
    sessions = session_registry.default(),
    environment = platform.environment,
    resolve_config = resolve_session_config,
  })
  return coordinator
end

local function unsupported_nvim()
  if vim.fn.has("nvim-0.10") == 1 then
    return nil
  end
  return errors.new(errors.codes.UNSUPPORTED_NVIM, "Bilingua requires Neovim 0.10 or newer", false)
end

function M.setup(options)
  local resolved, setup_error, warnings = config_module.resolve(options)
  configured_options = deep_copy(options or {})
  configuration_error = setup_error
  if not resolved then
    return nil, setup_error, warnings
  end
  resolved_config = resolved
  ensure_runtime()
  if commands_loaded then
    require("bilingua.commands").configure(resolved_config)
  end
  for _, warning in ipairs(warnings or {}) do
    vim.notify("Bilingua: " .. warning, vim.log.levels.WARN, { title = "Bilingua" })
  end
  return true, nil, warnings
end

function M.start(options, callback)
  local version_error = unsupported_nvim()
  if version_error then
    if callback then
      callback(nil, version_error)
    end
    return nil, version_error
  end
  local requested = options or {}
  if type(requested) ~= "table" then
    local argument_error =
      errors.new(errors.codes.INVALID_ARGUMENT, "start options must be a table", false)
    if callback then
      callback(nil, argument_error)
    end
    return nil, argument_error
  end
  local session_config, config_error, warnings = resolve_session_config(requested)
  if not session_config then
    if callback then
      callback(nil, config_error)
    end
    return nil, config_error
  end
  for _, warning in ipairs(warnings or {}) do
    vim.notify("Bilingua: " .. warning, vim.log.levels.WARN, { title = "Bilingua" })
  end

  local runtime = ensure_runtime()
  local accepted, start_error = runtime:start(requested, function(status, err)
    if status then
      require("bilingua.commands").install_session_mappings(
        session_config,
        status.source_buf,
        status.target_buf
      )
    end
    if callback then
      callback(status, err)
    end
  end)
  return accepted, start_error
end

function M.toggle()
  return ensure_runtime():toggle()
end
function M.sync_current()
  return ensure_runtime():sync_current()
end
function M.sync_all()
  return ensure_runtime():sync_all()
end
function M.use_source()
  return ensure_runtime():use_source()
end
function M.use_japanese()
  return ensure_runtime():use_japanese()
end
function M.next_group()
  return ensure_runtime():next_group()
end
function M.prev_group()
  return ensure_runtime():prev_group()
end
function M.retry_current(callback)
  return ensure_runtime():retry_current(function(value, err, session_config)
    if
      type(value) == "table"
      and type(session_config) == "table"
      and value.source_buf
      and value.target_buf
    then
      require("bilingua.commands").install_session_mappings(
        session_config,
        value.source_buf,
        value.target_buf
      )
    end
    if callback then
      callback(value, err)
    end
  end)
end
function M.restart_backend(callback)
  return ensure_runtime():restart_backend(callback)
end
function M.status()
  return ensure_runtime():status()
end
function M._dispose_all()
  return ensure_runtime():force_dispose_all()
end

function M.stop(options, callback)
  local status = ensure_runtime():status()
  return ensure_runtime():stop(options, function(ok, err)
    if ok and status then
      require("bilingua.commands").remove_session_mappings(status.source_buf, status.target_buf)
    end
    if callback then
      callback(ok, err)
    end
  end)
end

function M.quit(options, callback)
  local status = ensure_runtime():status()
  return ensure_runtime():quit(options, function(ok, err)
    if ok and status then
      require("bilingua.commands").remove_session_mappings(status.source_buf, status.target_buf)
    end
    if callback then
      callback(ok, err)
    end
  end)
end

function M._load()
  commands_loaded = true
  local commands = require("bilingua.commands")
  commands.register(M)
  commands.configure(resolved_config)
end

return M
