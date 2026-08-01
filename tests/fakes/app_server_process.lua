local json = require("bilingua.util.json")
local jsonl = require("bilingua.util.jsonl")

local Server = {}
Server.__index = Server

function Server.new()
  return setmetatable({
    outbound = {},
    command = nil,
    options = nil,
    on_exit = nil,
    stdin_closed = false,
    killed = 0,
    parser = jsonl.new(),
  }, Server)
end

function Server:process_factory(command, options, on_exit)
  self.command = vim.deepcopy(command)
  self.options = options
  self.on_exit = on_exit
  local owner = self
  return {
    write = function(_, data)
      if data == nil then
        owner.stdin_closed = true
        return true
      end
      local messages, parse_error = owner.parser:feed(data)
      if not messages then
        error(parse_error.message)
      end
      for _, message in ipairs(messages) do
        owner.outbound[#owner.outbound + 1] = message
      end
      return true
    end,
    kill = function()
      owner.killed = owner.killed + 1
      return true
    end,
  }
end

function Server:take(method)
  for index, message in ipairs(self.outbound) do
    if message.method == method then
      table.remove(self.outbound, index)
      return message
    end
  end
  return nil
end

function Server:respond(request, result, response_error, chunks)
  local response = { id = request.id }
  if response_error then
    response.error = response_error
  else
    response.result = result
  end
  self:emit(response, chunks)
end

function Server:notify(method, params, chunks)
  self:emit({ method = method, params = params }, chunks)
end

function Server:request(id, method, params, chunks)
  self:emit({ id = id, method = method, params = params }, chunks)
end

function Server:emit(message, chunks)
  local encoded = json.encode(message) .. "\n"
  if chunks then
    local offset = 1
    for _, length in ipairs(chunks) do
      if offset > #encoded then
        break
      end
      self.options.stdout(nil, encoded:sub(offset, offset + length - 1))
      offset = offset + length
    end
    if offset <= #encoded then
      self.options.stdout(nil, encoded:sub(offset))
    end
  else
    self.options.stdout(nil, encoded)
  end
end

function Server:emit_raw(chunk)
  self.options.stdout(nil, chunk)
end

function Server:stderr(chunk)
  self.options.stderr(nil, chunk)
end

function Server:exit(code, signal)
  self.on_exit({ code = code or 0, signal = signal or 0 })
end

return {
  new = Server.new,
}
