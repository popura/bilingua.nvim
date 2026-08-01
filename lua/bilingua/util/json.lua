local M = {}

M.null = setmetatable({}, {
  __tostring = function()
    return "json.null"
  end,
})

local ARRAY_TAG = {}
local OBJECT_TAG = {}

function M.array(values)
  return setmetatable(values or {}, { __bilingua_json_kind = ARRAY_TAG })
end

function M.object(values)
  return setmetatable(values or {}, { __bilingua_json_kind = OBJECT_TAG })
end

function M.is_array(value)
  local metatable = getmetatable(value)
  return metatable and metatable.__bilingua_json_kind == ARRAY_TAG
end

local function escape_string(value)
  local escaped = value:gsub('[%z\1-\31\\"]', function(character)
    local replacements = {
      ['"'] = '\\"',
      ["\\"] = "\\\\",
      ["\b"] = "\\b",
      ["\f"] = "\\f",
      ["\n"] = "\\n",
      ["\r"] = "\\r",
      ["\t"] = "\\t",
    }
    return replacements[character] or ("\\u%04x"):format(character:byte())
  end)
  return '"' .. escaped .. '"'
end

local function table_kind(value)
  local metatable = getmetatable(value)
  if metatable and metatable.__bilingua_json_kind == ARRAY_TAG then
    return "array"
  end
  if metatable and metatable.__bilingua_json_kind == OBJECT_TAG then
    return "object"
  end

  local count = 0
  local maximum = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return "object"
    end
    count = count + 1
    maximum = math.max(maximum, key)
  end
  if count > 0 and maximum == count then
    return "array"
  end
  return "object"
end

local function encode_value(value, stack, depth)
  if value == M.null then
    return "null"
  end
  local value_type = type(value)
  if value_type == "nil" then
    error("nil cannot be encoded as JSON; use json.null", 0)
  elseif value_type == "boolean" then
    return value and "true" or "false"
  elseif value_type == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      error("non-finite numbers cannot be encoded as JSON", 0)
    end
    return tostring(value)
  elseif value_type == "string" then
    return escape_string(value)
  elseif value_type ~= "table" then
    error(("%s cannot be encoded as JSON"):format(value_type), 0)
  end
  if depth > 256 then
    error("JSON nesting exceeds 256 levels", 0)
  end
  if stack[value] then
    error("cyclic tables cannot be encoded as JSON", 0)
  end
  stack[value] = true

  local parts = {}
  if table_kind(value) == "array" then
    for index = 1, #value do
      parts[index] = encode_value(value[index], stack, depth + 1)
    end
    stack[value] = nil
    return "[" .. table.concat(parts, ",") .. "]"
  end

  local keys = {}
  for key in pairs(value) do
    if type(key) ~= "string" then
      error("JSON object keys must be strings", 0)
    end
    keys[#keys + 1] = key
  end
  table.sort(keys)
  for index, key in ipairs(keys) do
    parts[index] = escape_string(key) .. ":" .. encode_value(value[key], stack, depth + 1)
  end
  stack[value] = nil
  return "{" .. table.concat(parts, ",") .. "}"
end

function M.encode(value)
  return encode_value(value, {}, 0)
end

local function utf8_character(codepoint)
  if codepoint <= 0x7f then
    return string.char(codepoint)
  elseif codepoint <= 0x7ff then
    return string.char(0xc0 + math.floor(codepoint / 0x40), 0x80 + (codepoint % 0x40))
  elseif codepoint <= 0xffff then
    return string.char(
      0xe0 + math.floor(codepoint / 0x1000),
      0x80 + (math.floor(codepoint / 0x40) % 0x40),
      0x80 + (codepoint % 0x40)
    )
  elseif codepoint <= 0x10ffff then
    return string.char(
      0xf0 + math.floor(codepoint / 0x40000),
      0x80 + (math.floor(codepoint / 0x1000) % 0x40),
      0x80 + (math.floor(codepoint / 0x40) % 0x40),
      0x80 + (codepoint % 0x40)
    )
  end
  error("JSON Unicode escape is outside the valid range", 0)
end

local Parser = {}
Parser.__index = Parser

function Parser.new(input)
  return setmetatable({ input = input, index = 1, length = #input, depth = 0 }, Parser)
end

function Parser:fail(message)
  error(("JSON error at byte %d: %s"):format(self.index, message), 0)
end

function Parser:skip_whitespace()
  while self.index <= self.length do
    local byte = self.input:byte(self.index)
    if byte ~= 32 and byte ~= 9 and byte ~= 10 and byte ~= 13 then
      break
    end
    self.index = self.index + 1
  end
end

function Parser:parse_hex_escape()
  local digits = self.input:sub(self.index, self.index + 3)
  if #digits ~= 4 or not digits:match("^%x%x%x%x$") then
    self:fail("invalid Unicode escape")
  end
  self.index = self.index + 4
  return tonumber(digits, 16)
end

function Parser:parse_string()
  self.index = self.index + 1
  local parts = {}
  local chunk_start = self.index

  while self.index <= self.length do
    local byte = self.input:byte(self.index)
    if byte == 34 then
      parts[#parts + 1] = self.input:sub(chunk_start, self.index - 1)
      self.index = self.index + 1
      return table.concat(parts)
    elseif byte == 92 then
      parts[#parts + 1] = self.input:sub(chunk_start, self.index - 1)
      self.index = self.index + 1
      local escape = self.input:sub(self.index, self.index)
      local replacements = {
        ['"'] = '"',
        ["\\"] = "\\",
        ["/"] = "/",
        b = "\b",
        f = "\f",
        n = "\n",
        r = "\r",
        t = "\t",
      }
      if escape == "u" then
        self.index = self.index + 1
        local codepoint = self:parse_hex_escape()
        if codepoint >= 0xd800 and codepoint <= 0xdbff then
          if self.input:sub(self.index, self.index + 1) ~= "\\u" then
            self:fail("high surrogate is missing a low surrogate")
          end
          self.index = self.index + 2
          local low = self:parse_hex_escape()
          if low < 0xdc00 or low > 0xdfff then
            self:fail("invalid low surrogate")
          end
          codepoint = 0x10000 + ((codepoint - 0xd800) * 0x400) + (low - 0xdc00)
        elseif codepoint >= 0xdc00 and codepoint <= 0xdfff then
          self:fail("unexpected low surrogate")
        end
        parts[#parts + 1] = utf8_character(codepoint)
      elseif replacements[escape] then
        parts[#parts + 1] = replacements[escape]
        self.index = self.index + 1
      else
        self:fail("invalid string escape")
      end
      chunk_start = self.index
    elseif byte < 32 then
      self:fail("unescaped control character in string")
    else
      self.index = self.index + 1
    end
  end
  self:fail("unterminated string")
end

function Parser:parse_number()
  local start = self.index
  if self.input:sub(self.index, self.index) == "-" then
    self.index = self.index + 1
  end
  local first = self.input:sub(self.index, self.index)
  if first == "0" then
    self.index = self.index + 1
    if self.input:sub(self.index, self.index):match("%d") then
      self:fail("leading zero in number")
    end
  elseif first:match("[1-9]") then
    repeat
      self.index = self.index + 1
    until not self.input:sub(self.index, self.index):match("%d")
  else
    self:fail("invalid number")
  end
  if self.input:sub(self.index, self.index) == "." then
    self.index = self.index + 1
    if not self.input:sub(self.index, self.index):match("%d") then
      self:fail("fraction requires a digit")
    end
    repeat
      self.index = self.index + 1
    until not self.input:sub(self.index, self.index):match("%d")
  end
  local exponent = self.input:sub(self.index, self.index)
  if exponent == "e" or exponent == "E" then
    self.index = self.index + 1
    local sign = self.input:sub(self.index, self.index)
    if sign == "+" or sign == "-" then
      self.index = self.index + 1
    end
    if not self.input:sub(self.index, self.index):match("%d") then
      self:fail("exponent requires a digit")
    end
    repeat
      self.index = self.index + 1
    until not self.input:sub(self.index, self.index):match("%d")
  end
  local value = tonumber(self.input:sub(start, self.index - 1))
  if not value or value == math.huge or value == -math.huge then
    self:fail("number is outside the supported range")
  end
  return value
end

function Parser:enter_container()
  self.depth = self.depth + 1
  if self.depth > 256 then
    self:fail("nesting exceeds 256 levels")
  end
end

function Parser:parse_array()
  self:enter_container()
  self.index = self.index + 1
  self:skip_whitespace()
  local result = M.array()
  if self.input:sub(self.index, self.index) == "]" then
    self.index = self.index + 1
    self.depth = self.depth - 1
    return result
  end
  while true do
    result[#result + 1] = self:parse_value()
    self:skip_whitespace()
    local delimiter = self.input:sub(self.index, self.index)
    if delimiter == "]" then
      self.index = self.index + 1
      self.depth = self.depth - 1
      return result
    elseif delimiter ~= "," then
      self:fail("array requires a comma or closing bracket")
    end
    self.index = self.index + 1
    self:skip_whitespace()
  end
end

function Parser:parse_object()
  self:enter_container()
  self.index = self.index + 1
  self:skip_whitespace()
  local result = M.object()
  if self.input:sub(self.index, self.index) == "}" then
    self.index = self.index + 1
    self.depth = self.depth - 1
    return result
  end
  while true do
    if self.input:sub(self.index, self.index) ~= '"' then
      self:fail("object keys must be strings")
    end
    local key = self:parse_string()
    if result[key] ~= nil then
      self:fail("duplicate object key")
    end
    self:skip_whitespace()
    if self.input:sub(self.index, self.index) ~= ":" then
      self:fail("object key requires a colon")
    end
    self.index = self.index + 1
    self:skip_whitespace()
    result[key] = self:parse_value()
    self:skip_whitespace()
    local delimiter = self.input:sub(self.index, self.index)
    if delimiter == "}" then
      self.index = self.index + 1
      self.depth = self.depth - 1
      return result
    elseif delimiter ~= "," then
      self:fail("object requires a comma or closing brace")
    end
    self.index = self.index + 1
    self:skip_whitespace()
  end
end

function Parser:parse_value()
  self:skip_whitespace()
  local character = self.input:sub(self.index, self.index)
  if character == '"' then
    return self:parse_string()
  elseif character == "{" then
    return self:parse_object()
  elseif character == "[" then
    return self:parse_array()
  elseif character == "t" and self.input:sub(self.index, self.index + 3) == "true" then
    self.index = self.index + 4
    return true
  elseif character == "f" and self.input:sub(self.index, self.index + 4) == "false" then
    self.index = self.index + 5
    return false
  elseif character == "n" and self.input:sub(self.index, self.index + 3) == "null" then
    self.index = self.index + 4
    return M.null
  elseif character == "-" or character:match("%d") then
    return self:parse_number()
  end
  self:fail("unexpected value")
end

function Parser:parse_document()
  self:skip_whitespace()
  local value = self:parse_value()
  self:skip_whitespace()
  if self.index <= self.length then
    self:fail("trailing content")
  end
  return value
end

function M.decode(input)
  if type(input) ~= "string" then
    return nil, "JSON input must be a string"
  end
  local ok, value = pcall(function()
    return Parser.new(input):parse_document()
  end)
  if not ok then
    return nil, tostring(value)
  end
  return value
end

return M
