local M = {}

local STANDARD_PATTERNS = {
  { kind = "code", pattern = "`.-`" },
  { kind = "tag", pattern = "%b<>" },
  { kind = "template", pattern = "%{%{.-%}%}" },
  { kind = "template", pattern = "%b{}" },
  { kind = "printf", pattern = "%%[%d%$%.%-%+ #0]*[diuoxXfFeEgGaAcspn]" },
  { kind = "math", pattern = "%$[^%$\n]-%$" },
}

local function collect_pattern_matches(text, pattern, kind, priority, matches)
  local cursor = 1
  while cursor <= #text do
    local first, last = text:find(pattern, cursor)
    if not first then
      break
    end
    if last >= first then
      matches[#matches + 1] = {
        first = first,
        last = last,
        kind = kind,
        priority = priority,
      }
    end
    cursor = math.max(last + 1, first + 1)
  end
end

local function collect_urls(text, matches)
  local cursor = 1
  while cursor <= #text do
    local first, last = text:find("https?://[^%s<>]+", cursor)
    if not first then
      break
    end
    while last >= first and text:sub(last, last):match("[%.%,%;%:%!%?]") do
      last = last - 1
    end
    if last >= first then
      matches[#matches + 1] = {
        first = first,
        last = last,
        kind = "url",
        priority = 1,
      }
    end
    cursor = math.max(last + 1, first + 1)
  end
end

local function collect_markdown_destinations(text, matches)
  local cursor = 1
  while cursor <= #text do
    local opening = text:find("](", cursor, true)
    if not opening then
      break
    end
    local first = opening + 2
    local depth = 1
    local index = first
    local escaped = false
    while index <= #text and depth > 0 do
      local character = text:sub(index, index)
      if escaped then
        escaped = false
      elseif character == "\\" then
        escaped = true
      elseif character == "(" then
        depth = depth + 1
      elseif character == ")" then
        depth = depth - 1
      end
      index = index + 1
    end
    if depth == 0 and index - 2 >= first then
      matches[#matches + 1] = {
        first = first,
        last = index - 2,
        kind = "link_destination",
        priority = 1,
      }
      cursor = index
    else
      cursor = opening + 2
    end
  end
end

local function collect_reference_labels(text, matches)
  local cursor = 1
  while cursor <= #text do
    local first, last = text:find("%]%[[^%]\n]+%]", cursor)
    if not first then
      break
    end
    matches[#matches + 1] = {
      first = first + 1,
      last = last,
      kind = "reference_label",
      priority = 1,
    }
    cursor = last + 1
  end
end

local function non_overlapping_matches(text, custom_patterns)
  local matches = {}
  collect_urls(text, matches)
  collect_markdown_destinations(text, matches)
  collect_reference_labels(text, matches)
  collect_pattern_matches(text, "\\[%p]", "escaped_punctuation", 1, matches)

  for priority, definition in ipairs(STANDARD_PATTERNS) do
    collect_pattern_matches(text, definition.pattern, definition.kind, priority + 1, matches)
  end
  for index, pattern in ipairs(custom_patterns or {}) do
    collect_pattern_matches(text, pattern, "custom", #STANDARD_PATTERNS + index + 1, matches)
  end

  table.sort(matches, function(left, right)
    if left.first ~= right.first then
      return left.first < right.first
    end
    if left.last ~= right.last then
      return left.last > right.last
    end
    return left.priority < right.priority
  end)

  local accepted = {}
  local last_finish = 0
  for _, candidate in ipairs(matches) do
    if candidate.first > last_finish then
      accepted[#accepted + 1] = candidate
      last_finish = candidate.last
    end
  end
  return accepted
end

local function count_plain(text, needle)
  local count = 0
  local cursor = 1
  while true do
    local first, last = text:find(needle, cursor, true)
    if not first then
      return count
    end
    count = count + 1
    cursor = last + 1
  end
end

function M.protect(text, custom_patterns)
  if type(text) ~= "string" then
    error("text must be a string", 2)
  end

  local matches = non_overlapping_matches(text, custom_patterns)
  local result = {}
  local tokens = {}
  local cursor = 1

  for ordinal, match in ipairs(matches) do
    local placeholder = ("⟦BIL:%04d⟧"):format(ordinal)
    result[#result + 1] = text:sub(cursor, match.first - 1)
    result[#result + 1] = placeholder
    tokens[#tokens + 1] = {
      id = ("tok:%04d"):format(ordinal),
      placeholder = placeholder,
      literal = text:sub(match.first, match.last),
      kind = match.kind,
      occurrence = ordinal,
    }
    cursor = match.last + 1
  end

  result[#result + 1] = text:sub(cursor)
  return table.concat(result), tokens
end

function M.restore(text, tokens)
  if type(text) ~= "string" or type(tokens) ~= "table" then
    return nil, "text and tokens are required"
  end

  local known = {}
  for _, token in ipairs(tokens) do
    if type(token.placeholder) ~= "string" or count_plain(text, token.placeholder) ~= 1 then
      return nil, "each protected placeholder must occur exactly once"
    end
    known[token.placeholder] = token.literal
  end

  for placeholder in text:gmatch("⟦BIL:%d+⟧") do
    if known[placeholder] == nil then
      return nil, "an unknown protected placeholder was returned"
    end
  end

  local restored = text
  for _, token in ipairs(tokens) do
    local first, last = restored:find(token.placeholder, 1, true)
    restored = restored:sub(1, first - 1) .. token.literal .. restored:sub(last + 1)
  end
  return restored
end

return M
