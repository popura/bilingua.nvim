local M = {}

local function assert_non_negative_integer(value, name)
  if type(value) ~= "number" or value < 0 or value % 1 ~= 0 then
    error(("%s must be a non-negative integer"):format(name), 3)
  end
end

local function line_bounds(text, wanted_row)
  local row = 0
  local start_offset = 0

  while row < wanted_row do
    local newline = text:find("\n", start_offset + 1, true)
    if not newline then
      return nil
    end
    start_offset = newline
    row = row + 1
  end

  local newline = text:find("\n", start_offset + 1, true)
  local finish_offset = newline and (newline - 1) or #text
  return start_offset, finish_offset
end

function M.position_to_offset(text, position)
  if type(text) ~= "string" then
    error("text must be a string", 2)
  end
  if type(position) ~= "table" then
    error("position must be a table", 2)
  end

  assert_non_negative_integer(position.row, "position.row")
  assert_non_negative_integer(position.col, "position.col")

  local start_offset, finish_offset = line_bounds(text, position.row)
  if not start_offset then
    error("position.row is outside the document", 2)
  end
  if position.col > finish_offset - start_offset then
    error("position.col is outside the line", 2)
  end

  return start_offset + position.col
end

function M.offset_to_position(text, offset)
  if type(text) ~= "string" then
    error("text must be a string", 2)
  end
  assert_non_negative_integer(offset, "offset")
  if offset > #text then
    error("offset is outside the document", 2)
  end

  local row = 0
  local line_start = 0
  local search_start = 1

  while true do
    local newline = text:find("\n", search_start, true)
    if not newline or newline > offset then
      break
    end
    row = row + 1
    line_start = newline
    search_start = newline + 1
  end

  return { row = row, col = offset - line_start }
end

return M
