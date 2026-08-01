local errors = require("bilingua.domain.error")

local M = {}

local DEFAULTS = {
  source_language = "auto",
  target_language = "ja",
  mappings = {
    enabled = true,
    start = "<leader>bs",
    toggle = "<leader>bb",
    sync = "<leader>by",
    sync_all = "<leader>ba",
    use_source = "<leader>bo",
    use_japanese = "<leader>bj",
    next = "]b",
    prev = "[b",
    stop = "<leader>bq",
    quit = "<leader>bQ",
  },
  layout = {
    direction = "vertical",
    target_position = "right",
    size = 0.5,
    follow_cursor = true,
    follow_debounce_ms = 50,
    open_folds = false,
  },
  sync = {
    automatic = true,
    debounce_ms = 700,
    on_insert_leave = true,
    max_concurrency = 1,
    context_groups = 1,
    structural_changes = "auto_safe",
    conflict_policy = "manual",
    retry = {
      max_attempts = 3,
      initial_delay_ms = 500,
      max_delay_ms = 3000,
    },
  },
  stop = {
    sync_pending = true,
    timeout_ms = 120000,
  },
  persistence = {
    enabled = false,
  },
  limits = {
    max_document_bytes = 2 * 1024 * 1024,
    max_units = 2000,
    max_task_input_chars = 24000,
    max_task_output_chars = 24000,
    initial_batch_chars = 12000,
    initial_batch_units = 32,
  },
  documents = {
    fallback_to_plaintext = true,
    aliases = {},
    protected_patterns = {},
    routes = {
      markdown = {
        adapter = "markdown",
        tracker = "hybrid",
        aligner = "generated_id",
      },
      text = {
        adapter = "plaintext",
        tracker = "hybrid",
        aligner = "generated_id",
      },
    },
  },
  translation = {
    service = "default",
    backend = "codex_app_server",
    initial_codec = "initial_translation_json_v1",
    patch_codec = "semantic_patch_json_v1",
    timeout_ms = 120000,
    backend_options = {
      command = { "codex", "app-server" },
      model = nil,
      reasoning_effort = nil,
      require_ephemeral = true,
      strict_isolation = true,
      reject_external_instruction_sources = true,
      include_platform_default_reads = false,
      experimental_api = false,
      request_timeout_ms = 10000,
      shutdown_timeout_ms = 500,
    },
  },
  ui = {
    signs = true,
    virtual_text = true,
    notify_backend = true,
    show_progress = true,
  },
  debug = {
    enabled = false,
    log_payloads = false,
    ring_size = 200,
  },
}

local DYNAMIC_TABLES = {
  ["documents.routes"] = true,
  ["documents.aliases"] = true,
  ["translation.backend_options"] = true,
}

local ATOMIC_TABLES = {
  ["documents.protected_patterns"] = true,
}

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

local function merge_known(destination, source, schema, path, warnings)
  for key, value in pairs(source) do
    local current_path = path == "" and tostring(key) or (path .. "." .. tostring(key))
    local expected = schema[key]
    if expected == nil and not DYNAMIC_TABLES[path] then
      warnings[#warnings + 1] = ("Unknown configuration key: %s"):format(current_path)
    elseif
      type(value) == "table"
      and type(expected) == "table"
      and expected[1] == nil
      and not ATOMIC_TABLES[current_path]
    then
      merge_known(destination[key], value, expected, current_path, warnings)
    else
      destination[key] = deep_copy(value)
    end
  end
end

local function invalid(message)
  return nil, errors.new(errors.codes.INVALID_ARGUMENT, message, false)
end

local function require_type(value, expected, path)
  if type(value) ~= expected then
    return invalid(("%s must be %s"):format(path, expected))
  end
  return true
end

local function require_non_empty_string(value, path)
  if type(value) ~= "string" or value == "" then
    return invalid(("%s must be a non-empty string"):format(path))
  end
  return true
end

local function require_boolean(value, path)
  return require_type(value, "boolean", path)
end

local function positive_integer(value, path)
  if type(value) ~= "number" or value < 1 or value % 1 ~= 0 then
    return invalid(("%s must be a positive integer"):format(path))
  end
  return true
end

local function non_negative_integer(value, path)
  if type(value) ~= "number" or value < 0 or value % 1 ~= 0 then
    return invalid(("%s must be a non-negative integer"):format(path))
  end
  return true
end

local function one_of(value, allowed, path)
  for _, candidate in ipairs(allowed) do
    if value == candidate then
      return true
    end
  end
  return invalid(("%s has an unsupported value"):format(path))
end

local function validate_route(route, path)
  if type(route) ~= "table" then
    return invalid(path .. " must be a table")
  end
  for _, field in ipairs({ "adapter", "tracker", "aligner" }) do
    if type(route[field]) ~= "string" or route[field] == "" then
      return invalid(("%s.%s must be a non-empty string"):format(path, field))
    end
  end
  return true
end

local function validate(config)
  local ok, err
  for _, section in ipairs({
    "mappings",
    "layout",
    "sync",
    "stop",
    "persistence",
    "limits",
    "documents",
    "translation",
    "ui",
    "debug",
  }) do
    ok, err = require_type(config[section], "table", section)
    if not ok then
      return nil, err
    end
  end

  ok, err = require_non_empty_string(config.source_language, "source_language")
  if not ok then
    return nil, err
  end
  ok, err = require_non_empty_string(config.target_language, "target_language")
  if not ok then
    return nil, err
  end
  ok, err = require_boolean(config.mappings.enabled, "mappings.enabled")
  if not ok then
    return nil, err
  end
  for key, value in pairs(config.mappings) do
    if key ~= "enabled" and value ~= false and type(value) ~= "string" then
      return invalid(("mappings.%s must be a string or false"):format(key))
    end
  end

  ok, err = one_of(config.layout.direction, { "vertical", "horizontal" }, "layout.direction")
  if not ok then
    return nil, err
  end
  ok, err = one_of(
    config.layout.target_position,
    { "right", "left", "above", "below" },
    "layout.target_position"
  )
  if not ok then
    return nil, err
  end
  if
    type(config.layout.size) ~= "number"
    or config.layout.size <= 0
    or (config.layout.size >= 1 and config.layout.size % 1 ~= 0)
  then
    return invalid("layout.size must be a positive integer or a fraction between zero and one")
  end
  ok, err = require_boolean(config.layout.follow_cursor, "layout.follow_cursor")
  if not ok then
    return nil, err
  end
  ok, err = require_boolean(config.layout.open_folds, "layout.open_folds")
  if not ok then
    return nil, err
  end
  ok, err = non_negative_integer(config.layout.follow_debounce_ms, "layout.follow_debounce_ms")
  if not ok then
    return nil, err
  end

  ok, err = require_boolean(config.sync.automatic, "sync.automatic")
  if not ok then
    return nil, err
  end
  ok, err = require_boolean(config.sync.on_insert_leave, "sync.on_insert_leave")
  if not ok then
    return nil, err
  end
  ok, err = non_negative_integer(config.sync.debounce_ms, "sync.debounce_ms")
  if not ok then
    return nil, err
  end
  ok, err = positive_integer(config.sync.max_concurrency, "sync.max_concurrency")
  if not ok then
    return nil, err
  end
  ok, err = non_negative_integer(config.sync.context_groups, "sync.context_groups")
  if not ok then
    return nil, err
  end
  ok, err = one_of(
    config.sync.structural_changes,
    { "auto_safe", "manual", "disabled" },
    "sync.structural_changes"
  )
  if not ok then
    return nil, err
  end
  if config.sync.conflict_policy ~= "manual" then
    return invalid("sync.conflict_policy must be manual in the initial release")
  end
  ok, err = require_type(config.sync.retry, "table", "sync.retry")
  if not ok then
    return nil, err
  end
  ok, err = positive_integer(config.sync.retry.max_attempts, "sync.retry.max_attempts")
  if not ok then
    return nil, err
  end
  ok, err = non_negative_integer(config.sync.retry.initial_delay_ms, "sync.retry.initial_delay_ms")
  if not ok then
    return nil, err
  end
  ok, err = non_negative_integer(config.sync.retry.max_delay_ms, "sync.retry.max_delay_ms")
  if not ok then
    return nil, err
  end
  if config.sync.retry.max_delay_ms < config.sync.retry.initial_delay_ms then
    return invalid("sync.retry.max_delay_ms must be at least sync.retry.initial_delay_ms")
  end

  ok, err = require_boolean(config.stop.sync_pending, "stop.sync_pending")
  if not ok then
    return nil, err
  end
  ok, err = positive_integer(config.stop.timeout_ms, "stop.timeout_ms")
  if not ok then
    return nil, err
  end
  ok, err = require_boolean(config.persistence.enabled, "persistence.enabled")
  if not ok then
    return nil, err
  end
  if config.persistence.enabled then
    return invalid("persistence.enabled=true is not supported in the initial release")
  end
  for key, value in pairs(config.limits) do
    ok, err = positive_integer(value, "limits." .. tostring(key))
    if not ok then
      return nil, err
    end
  end

  ok, err =
    require_boolean(config.documents.fallback_to_plaintext, "documents.fallback_to_plaintext")
  if not ok then
    return nil, err
  end
  ok, err = require_type(config.documents.routes, "table", "documents.routes")
  if not ok then
    return nil, err
  end
  ok, err = require_type(config.documents.aliases, "table", "documents.aliases")
  if not ok then
    return nil, err
  end
  ok, err =
    require_type(config.documents.protected_patterns, "table", "documents.protected_patterns")
  if not ok then
    return nil, err
  end
  local pattern_count = 0
  local maximum_pattern_index = 0
  for index, pattern in pairs(config.documents.protected_patterns) do
    if type(index) ~= "number" or index < 1 or index % 1 ~= 0 then
      return invalid("documents.protected_patterns must be a string list")
    end
    pattern_count = pattern_count + 1
    maximum_pattern_index = math.max(maximum_pattern_index, index)
    if type(pattern) ~= "string" or pattern == "" then
      return invalid("documents.protected_patterns must contain non-empty strings")
    end
    if not pcall(string.find, "", pattern) then
      return invalid("documents.protected_patterns contains an invalid Lua pattern")
    end
  end
  if pattern_count ~= maximum_pattern_index then
    return invalid("documents.protected_patterns must be a contiguous string list")
  end
  for filetype, route in pairs(config.documents.routes) do
    if type(filetype) ~= "string" or filetype == "" then
      return invalid("documents.routes keys must be non-empty strings")
    end
    ok, err = validate_route(route, "documents.routes." .. filetype)
    if not ok then
      return nil, err
    end
  end
  for alias, route_name in pairs(config.documents.aliases) do
    local path = "documents.aliases." .. tostring(alias)
    if type(alias) ~= "string" or alias == "" then
      return invalid("documents.aliases keys must be non-empty strings")
    end
    ok, err = require_non_empty_string(route_name, path)
    if not ok then
      return nil, err
    end
    if not config.documents.routes[route_name] then
      return invalid(path .. " must reference an existing documents.routes entry")
    end
  end

  for _, field in ipairs({ "service", "backend", "initial_codec", "patch_codec" }) do
    ok, err = require_non_empty_string(config.translation[field], "translation." .. field)
    if not ok then
      return nil, err
    end
  end
  ok, err = positive_integer(config.translation.timeout_ms, "translation.timeout_ms")
  if not ok then
    return nil, err
  end
  ok, err = require_type(config.translation.backend_options, "table", "translation.backend_options")
  if not ok then
    return nil, err
  end
  local backend_options = config.translation.backend_options
  if type(backend_options.command) ~= "table" or #backend_options.command == 0 then
    return invalid("translation.backend_options.command must be a non-empty string list")
  end
  for _, part in ipairs(backend_options.command) do
    if type(part) ~= "string" or part == "" then
      return invalid("translation.backend_options.command must contain non-empty strings")
    end
  end
  for _, field in ipairs({
    "require_ephemeral",
    "strict_isolation",
    "reject_external_instruction_sources",
    "include_platform_default_reads",
    "experimental_api",
  }) do
    ok, err = require_boolean(backend_options[field], "translation.backend_options." .. field)
    if not ok then
      return nil, err
    end
  end
  for _, field in ipairs({ "model", "reasoning_effort" }) do
    local value = backend_options[field]
    if value ~= nil and (type(value) ~= "string" or value == "") then
      return invalid(
        ("translation.backend_options.%s must be nil or a non-empty string"):format(field)
      )
    end
  end
  ok, err = positive_integer(
    backend_options.request_timeout_ms,
    "translation.backend_options.request_timeout_ms"
  )
  if not ok then
    return nil, err
  end
  ok, err = non_negative_integer(
    backend_options.shutdown_timeout_ms,
    "translation.backend_options.shutdown_timeout_ms"
  )
  if not ok then
    return nil, err
  end
  if backend_options.strict_isolation and backend_options.include_platform_default_reads then
    return invalid("strict isolation cannot include platform default readable roots")
  end

  for _, field in ipairs({ "signs", "virtual_text", "notify_backend", "show_progress" }) do
    ok, err = require_boolean(config.ui[field], "ui." .. field)
    if not ok then
      return nil, err
    end
  end
  ok, err = require_boolean(config.debug.enabled, "debug.enabled")
  if not ok then
    return nil, err
  end
  ok, err = require_boolean(config.debug.log_payloads, "debug.log_payloads")
  if not ok then
    return nil, err
  end
  if config.debug.log_payloads then
    return invalid("debug.log_payloads is not supported in the initial release")
  end
  ok, err = positive_integer(config.debug.ring_size, "debug.ring_size")
  if not ok then
    return nil, err
  end
  return true
end

function M.resolve(options)
  if options ~= nil and type(options) ~= "table" then
    return invalid("Configuration options must be a table")
  end
  local resolved = deep_copy(DEFAULTS)
  local warnings = {}
  merge_known(resolved, options or {}, DEFAULTS, "", warnings)
  local valid, validation_error = validate(resolved)
  if not valid then
    return nil, validation_error, warnings
  end
  return resolved, nil, warnings
end

function M.defaults()
  return deep_copy(DEFAULTS)
end

return M
