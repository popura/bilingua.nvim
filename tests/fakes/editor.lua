local ranges = require("bilingua.util.ranges")

local Editor = {}
Editor.__index = Editor

local function copy_document(document)
  return {
    text = document.text,
    filetype = document.filetype,
    language = document.language,
    version = document.version,
    metadata = document.metadata,
  }
end

function Editor.new(source_text, filetype)
  return setmetatable({
    api_version = 1,
    documents = {
      source = {
        text = source_text,
        filetype = filetype or "text",
        language = "en",
        version = 1,
        metadata = { endofline = source_text:sub(-1) == "\n" },
      },
      target = {
        text = "",
        filetype = filetype or "text",
        language = "ja",
        version = 1,
        metadata = { endofline = false },
      },
    },
    anchors = {},
    subscriptions = {},
    rendered_graph = nil,
    target_modifiable = false,
    target_modified = false,
    disposed = false,
    focused_side = nil,
    cursor_units = {},
  }, Editor)
end

function Editor:capabilities()
  return { atomic_edits = true, extmarks = true }
end

function Editor:create_target_view(_, callback)
  callback({ source_buf = 1, target_buf = 2 })
end

function Editor:get_document(side)
  return copy_document(self.documents[side])
end

function Editor:get_text(side)
  return self.documents[side].text
end

function Editor:get_version(side)
  return self.documents[side].version
end

function Editor:apply_edits(side, edits, expected_version, origin)
  local document = self.documents[side]
  if document.version ~= expected_version then
    return nil,
      { code = "E_APPLY_VERSION_MISMATCH", message = "version mismatch", retryable = true }
  end

  local ordered = {}
  for index, edit in ipairs(edits) do
    ordered[index] = edit
  end
  table.sort(ordered, function(left, right)
    return ranges.position_to_offset(document.text, left.range.start)
      > ranges.position_to_offset(document.text, right.range.start)
  end)

  local text = document.text
  for _, edit in ipairs(ordered) do
    local first = ranges.position_to_offset(text, edit.range.start)
    local finish = ranges.position_to_offset(text, edit.range.finish)
    if text:sub(first + 1, finish) ~= edit.expected_text then
      return nil, { code = "E_APPLY", message = "expected text mismatch", retryable = false }
    end
    text = text:sub(1, first) .. edit.replacement .. text:sub(finish + 1)
  end

  document.text = text
  document.version = document.version + 1
  self.last_origin = origin
  return { version = document.version }
end

function Editor:subscribe_changes(side, callback)
  self.subscriptions[side] = callback
  local disposed = false
  return {
    dispose = function()
      if not disposed then
        disposed = true
        self.subscriptions[side] = nil
      end
    end,
  }
end

function Editor:set_unit_anchors(side, snapshot)
  self.anchors[side] = snapshot
  return {}
end

function Editor:get_anchor_hints()
  return {}
end

function Editor:unit_at_cursor(side)
  return self.cursor_units[side]
end

function Editor:focus_side(side)
  if not self.documents[side] then
    return false
  end
  self.focused_side = side
  return true
end

function Editor:focus_group(side, unit_ids)
  if not self:focus_side(side) or not unit_ids[1] then
    return false
  end
  self.cursor_units[side] = unit_ids[1]
  return true
end

function Editor:render_group_states(graph)
  self.rendered_graph = graph
end

function Editor:set_target_modifiable(value)
  self.target_modifiable = value
end

function Editor:set_target_modified(value)
  self.target_modified = value
end

function Editor:dispose()
  self.disposed = true
  self.documents.target = nil
end

return {
  new = Editor.new,
}
