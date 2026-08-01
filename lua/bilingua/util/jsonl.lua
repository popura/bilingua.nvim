local errors = require("bilingua.domain.error")
local json = require("bilingua.util.json")

local Parser = {}
Parser.__index = Parser

local function protocol_error(message, details, cause)
  return errors.new(errors.codes.BACKEND_PROTOCOL, message, false, details, cause)
end

function Parser.new(options)
  local resolved = options or {}
  local maximum = resolved.max_line_bytes or (16 * 1024 * 1024)
  if type(maximum) ~= "number" or maximum < 1 or maximum % 1 ~= 0 then
    error("JSONL max_line_bytes must be a positive integer", 2)
  end
  return setmetatable({
    max_line_bytes = maximum,
    buffer = "",
    failed = false,
  }, Parser)
end

function Parser:fail(message, details, cause)
  self.failed = true
  self.buffer = ""
  return nil, protocol_error(message, details, cause)
end

function Parser:decode_line(line, messages)
  if line:sub(-1) == "\r" then
    line = line:sub(1, -2)
  end
  if line:match("^%s*$") then
    return true
  end
  if #line > self.max_line_bytes then
    return self:fail("JSONL record exceeds the byte limit", {
      actual = #line,
      maximum = self.max_line_bytes,
    })
  end
  local value, decode_error = json.decode(line)
  if not value then
    return self:fail("JSONL record is not valid JSON", nil, decode_error)
  end
  messages[#messages + 1] = value
  return true
end

function Parser:feed(chunk)
  if self.failed then
    return nil, protocol_error("JSONL parser is already in a failed state")
  end
  if type(chunk) ~= "string" then
    return self:fail("JSONL chunk must be a string")
  end
  self.buffer = self.buffer .. chunk
  local messages = {}
  while true do
    local newline = self.buffer:find("\n", 1, true)
    if not newline then
      break
    end
    local line = self.buffer:sub(1, newline - 1)
    self.buffer = self.buffer:sub(newline + 1)
    local decoded, decode_error = self:decode_line(line, messages)
    if not decoded then
      return nil, decode_error
    end
  end
  if #self.buffer > self.max_line_bytes then
    return self:fail("JSONL receive buffer exceeds the byte limit", {
      actual = #self.buffer,
      maximum = self.max_line_bytes,
    })
  end
  return messages
end

function Parser:finish()
  if self.failed then
    return nil, protocol_error("JSONL parser is already in a failed state")
  end
  local messages = {}
  if self.buffer ~= "" then
    local line = self.buffer
    self.buffer = ""
    local decoded, decode_error = self:decode_line(line, messages)
    if not decoded then
      return nil, decode_error
    end
  end
  return messages
end

return {
  new = Parser.new,
}
