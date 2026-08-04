local Process = {}
Process.__index = Process

local function copy_list(values)
  local copy = {}
  for index, value in ipairs(values or {}) do
    copy[index] = value
  end
  return copy
end

function Process.new(options)
  local configured = options or {}
  return setmetatable({
    spawn_error = configured.spawn_error,
    return_nil = configured.return_nil == true,
    command = nil,
    options = nil,
    on_exit = nil,
    process = nil,
    spawn_count = 0,
    kill_count = 0,
    write_log = {},
    stdin_closed = false,
  }, Process)
end

function Process:process_factory(command, options, on_exit)
  self.spawn_count = self.spawn_count + 1
  if self.spawn_error then
    error(self.spawn_error, 0)
  end
  if self.return_nil then
    return nil
  end

  self.command = copy_list(command)
  self.options = options
  self.on_exit = on_exit
  local owner = self
  self.process = {
    write = function(_, data)
      if data == nil then
        owner.stdin_closed = true
      else
        owner.write_log[#owner.write_log + 1] = data
      end
      return true
    end,
    kill = function()
      owner.kill_count = owner.kill_count + 1
      return true
    end,
  }
  return self.process
end

function Process:emit_stdout(chunk, error_message)
  assert(self.options, "process has not been started")
  self.options.stdout(error_message, chunk)
end

function Process:emit_stderr(chunk, error_message)
  assert(self.options, "process has not been started")
  self.options.stderr(error_message, chunk)
end

function Process:exit(code, signal)
  assert(self.on_exit, "process has not been started")
  self.on_exit({ code = code or 0, signal = signal or 0 })
end

function Process:was_killed()
  return self.kill_count > 0
end

function Process:writes()
  return copy_list(self.write_log), self.stdin_closed
end

return {
  new = Process.new,
}
