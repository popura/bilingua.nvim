local M = {}

function M.length(value)
  if type(value) ~= "string" then
    error("UTF-8 length requires a string", 2)
  end
  local count = 0
  local index = 1
  while index <= #value do
    local byte = value:byte(index)
    local width
    if byte < 0x80 then
      width = 1
    elseif byte >= 0xc2 and byte <= 0xdf then
      width = 2
    elseif byte >= 0xe0 and byte <= 0xef then
      width = 3
    elseif byte >= 0xf0 and byte <= 0xf4 then
      width = 4
    else
      return nil, ("invalid UTF-8 at byte %d"):format(index)
    end
    if index + width - 1 > #value then
      return nil, ("truncated UTF-8 at byte %d"):format(index)
    end
    for continuation = index + 1, index + width - 1 do
      local continuation_byte = value:byte(continuation)
      if continuation_byte < 0x80 or continuation_byte > 0xbf then
        return nil, ("invalid UTF-8 continuation at byte %d"):format(continuation)
      end
    end
    count = count + 1
    index = index + width
  end
  return count
end

return M
