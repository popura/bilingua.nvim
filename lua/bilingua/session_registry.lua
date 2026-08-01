local errors = require("bilingua.domain.error")

local Registry = {}
Registry.__index = Registry

function Registry.new()
  return setmetatable({
    by_buffer = {},
    by_id = {},
    order = {},
  }, Registry)
end

function Registry:add(session)
  if
    type(session) ~= "table"
    or type(session.id) ~= "string"
    or type(session.source_buf) ~= "number"
    or type(session.target_buf) ~= "number"
  then
    return nil,
      errors.new(
        errors.codes.INVALID_ARGUMENT,
        "A session with source and target buffers is required",
        false
      )
  end
  if
    self.by_id[session.id]
    or self.by_buffer[session.source_buf]
    or self.by_buffer[session.target_buf]
  then
    return nil,
      errors.new(
        errors.codes.INVALID_ARGUMENT,
        "A buffer or session ID is already registered",
        false
      )
  end

  self.by_id[session.id] = session
  self.by_buffer[session.source_buf] = session
  self.by_buffer[session.target_buf] = session
  self.order[#self.order + 1] = session.id
  return true
end

function Registry:remove(session)
  if type(session) ~= "table" or self.by_id[session.id] ~= session then
    return false
  end
  self.by_id[session.id] = nil
  if self.by_buffer[session.source_buf] == session then
    self.by_buffer[session.source_buf] = nil
  end
  if self.by_buffer[session.target_buf] == session then
    self.by_buffer[session.target_buf] = nil
  end
  for index, session_id in ipairs(self.order) do
    if session_id == session.id then
      table.remove(self.order, index)
      break
    end
  end
  return true
end

function Registry:for_buffer(buffer)
  return self.by_buffer[buffer]
end

function Registry:for_id(session_id)
  return self.by_id[session_id]
end

function Registry:list()
  local sessions = {}
  for _, session_id in ipairs(self.order) do
    sessions[#sessions + 1] = self.by_id[session_id]
  end
  return sessions
end

function Registry:clear()
  self.by_buffer = {}
  self.by_id = {}
  self.order = {}
end

local default = Registry.new()

return {
  new = Registry.new,
  default = function()
    return default
  end,
}
