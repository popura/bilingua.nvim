local M = {}

local function now_ms()
  local uv = vim.uv or vim.loop
  return math.floor(uv.hrtime() / 1000000)
end

local function timer_handle(milliseconds, callback)
  local uv = vim.uv or vim.loop
  local timer = assert(uv.new_timer())
  local settled = false

  local function close_timer()
    if timer:is_active() then
      timer:stop()
    end
    if not timer:is_closing() then
      timer:close()
    end
  end

  timer:start(milliseconds, 0, function()
    if settled then
      return
    end
    settled = true
    close_timer()
    callback()
  end)

  return {
    cancel = function()
      if settled then
        return
      end
      settled = true
      close_timer()
    end,
  }
end

local function scheduler()
  local instance = {}

  function instance:schedule(callback)
    vim.schedule(callback)
  end

  function instance:defer(milliseconds, callback)
    return timer_handle(milliseconds, function()
      vim.schedule(callback)
    end)
  end

  return instance
end

local function environment()
  return {
    current_buffer = function()
      return vim.api.nvim_get_current_buf()
    end,
    current_window = function()
      return vim.api.nvim_get_current_win()
    end,
    inspect_buffer = function(buffer)
      local valid = vim.api.nvim_buf_is_valid(buffer)
      local loaded = valid and vim.api.nvim_buf_is_loaded(buffer)
      if not valid or not loaded then
        return { valid = valid, loaded = loaded }
      end
      return {
        valid = true,
        loaded = true,
        buftype = vim.bo[buffer].buftype,
        modifiable = vim.bo[buffer].modifiable,
        binary = vim.bo[buffer].binary,
        filetype = vim.bo[buffer].filetype,
        path = vim.api.nvim_buf_get_name(buffer),
      }
    end,
    emit = function(event, data)
      pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = event,
        modeline = false,
        data = data,
      })
    end,
    now_ms = now_ms,
    notify_error = function(error_code)
      vim.notify(
        ("Bilingua: runtime synchronization failed [%s]"):format(error_code),
        vim.log.levels.ERROR,
        { title = "Bilingua" }
      )
    end,
    session_removed = function(source_buf, target_buf)
      local ok, commands = pcall(require, "bilingua.commands")
      if ok then
        commands.remove_session_mappings(source_buf, target_buf)
      end
    end,
    close_buffer = function(buffer, force)
      if not vim.api.nvim_buf_is_valid(buffer) then
        return true
      end
      if force then
        local ok = pcall(vim.api.nvim_buf_delete, buffer, { force = true })
        return ok
      end
      local ok = pcall(vim.api.nvim_buf_call, buffer, function()
        vim.cmd("confirm bdelete")
      end)
      return ok
    end,
  }
end

local function join_path(directory, name)
  return directory:gsub("[\\/]+$", "") .. package.config:sub(1, 1) .. name
end

local function global_instruction_sources(options)
  local codex_home = options.codex_home
  if type(codex_home) ~= "string" or codex_home == "" then
    codex_home = vim.env.CODEX_HOME
  end
  if type(codex_home) ~= "string" or codex_home == "" then
    codex_home = vim.fn.expand("~/.codex")
  end
  local sources = {}
  for _, filename in ipairs({ "AGENTS.override.md", "AGENTS.md" }) do
    local path = join_path(codex_home, filename)
    if vim.fn.filereadable(path) == 1 then
      sources[#sources + 1] = path
    end
  end
  return sources
end

local function backend_runtime(runtime_scheduler, options)
  return {
    schedule = function(callback)
      runtime_scheduler:schedule(callback)
    end,
    timer_factory = timer_handle,
    tempdir_factory = function()
      local path = vim.fn.tempname() .. "-bilingua"
      local created = vim.fn.mkdir(path, "p", 448)
      if created ~= 1 then
        return nil, "could not create an isolated temporary directory"
      end
      return path
    end,
    remove_tree = function(path)
      return vim.fn.delete(path, "rf") == 0
    end,
    realpath = function(path)
      local uv = vim.uv or vim.loop
      return uv.fs_realpath(path)
    end,
    now_ms = now_ms,
    process_factory = function(command, process_options, on_exit)
      return vim.system(command, process_options, on_exit)
    end,
    allowed_instruction_sources = global_instruction_sources(options),
  }
end

local function markdown_query()
  if
    type(vim.treesitter) ~= "table"
    or type(vim.treesitter.get_string_parser) ~= "function"
    or type(vim.treesitter.query) ~= "table"
    or type(vim.treesitter.query.get) ~= "function"
  then
    return nil, "Neovim Tree-sitter APIs are unavailable"
  end
  local loaded, query = pcall(vim.treesitter.query.get, "markdown", "bilingua")
  if not loaded or not query then
    return nil, "the Bilingua Markdown query is unavailable"
  end
  return query
end

local function markdown_parser(text)
  local available, parser = pcall(vim.treesitter.get_string_parser, text, "markdown")
  if not available or not parser then
    return nil, "the Markdown Tree-sitter parser is unavailable"
  end
  return parser
end

local function markdown_available()
  local parser = markdown_parser("")
  local query = markdown_query()
  if not parser or not query then
    return false, "Markdown Tree-sitter parser or Bilingua query is unavailable"
  end
  return true
end

local function analyze_markdown(text)
  local parser, parser_error = markdown_parser(text)
  if not parser then
    return nil, parser_error
  end
  local query, query_error = markdown_query()
  if not query then
    return nil, query_error
  end
  local parsed, trees = pcall(parser.parse, parser)
  local tree = parsed and type(trees) == "table" and trees[1] or nil
  if not tree then
    return nil, "Markdown Tree-sitter parsing failed"
  end
  local root = tree:root()
  local capture_count = 0
  local iterated = pcall(function()
    for _ in query:iter_captures(root, text, 0, -1) do
      capture_count = capture_count + 1
    end
  end)
  if not iterated then
    return nil, "Bilingua Markdown query execution failed"
  end
  return { capture_count = capture_count }
end

function M.new(options)
  local resolved = options or {}
  local runtime_scheduler = scheduler()
  return {
    scheduler = runtime_scheduler,
    environment = environment(),
    backend_runtime = backend_runtime(runtime_scheduler, resolved),
    document_runtime = {
      markdown_available = markdown_available,
      analyze_markdown = analyze_markdown,
    },
    warn = function(message)
      vim.notify("Bilingua: " .. message, vim.log.levels.WARN, { title = "Bilingua" })
    end,
    sha256 = function(value)
      return vim.fn.sha256(value)
    end,
  }
end

return M
