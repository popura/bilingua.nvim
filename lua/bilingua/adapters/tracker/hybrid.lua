local errors = require("bilingua.domain.error")
local ranges = require("bilingua.util.ranges")

local Hybrid = {}
Hybrid.__index = Hybrid

local function deep_copy(value, seen)
  if type(value) ~= "table" then
    return value
  end
  local visited = seen or {}
  if visited[value] then
    return visited[value]
  end
  local copy = {}
  visited[value] = copy
  for key, item in pairs(value) do
    copy[deep_copy(key, visited)] = deep_copy(item, visited)
  end
  return copy
end

local function append_index(index, key, value)
  if not index[key] then
    index[key] = {}
  end
  index[key][#index[key] + 1] = value
end

local function maximum_id(snapshot)
  local maximum = 0
  for _, unit_id in ipairs(snapshot.order) do
    local value = tonumber(unit_id:match("(%d+)$"))
    if value and value > maximum then
      maximum = value
    end
  end
  return maximum
end

local function id_prefix(side)
  return side == "source" and "src" or "tgt"
end

local function normalize_content(unit)
  local normalized = unit.content_text:gsub("\r\n", "\n"):gsub("\r", "\n")
  normalized = normalized:gsub("⟦BIL:%d+⟧", "⟦BIL⟧")
  normalized = normalized:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  return normalized
end

local function joined_content(snapshot, ids)
  local parts = {}
  for _, id in ipairs(ids) do
    parts[#parts + 1] = normalize_content(snapshot.units[id])
  end
  return table.concat(parts, " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
end

local function structural_key(unit)
  return unit.kind .. "\0" .. table.concat(unit.structural_path or {}, "\0")
end

local function ordinal_index(order)
  local result = {}
  for ordinal, id in ipairs(order) do
    result[id] = ordinal
  end
  return result
end

local function interval(text, range)
  if type(range) ~= "table" or type(range.start) ~= "table" or type(range.finish) ~= "table" then
    return nil
  end
  local ok, first, finish = pcall(function()
    return ranges.position_to_offset(text, range.start),
      ranges.position_to_offset(text, range.finish)
  end)
  if not ok or first > finish then
    return nil
  end
  return { first = first, finish = finish, length = math.max(1, finish - first) }
end

local function overlap(left, right)
  return math.max(0, math.min(left.finish, right.finish) - math.max(left.first, right.first))
end

local function add_relation(
  relations,
  matched_old,
  matched_new,
  kind,
  old_ids,
  new_ids,
  confidence,
  reason
)
  for _, id in ipairs(old_ids) do
    matched_old[id] = true
  end
  for _, id in ipairs(new_ids) do
    matched_new[id] = true
  end
  relations[#relations + 1] = {
    kind = kind,
    old_ids = old_ids,
    provisional_new_ids = new_ids,
    confidence = confidence,
    reason = reason,
  }
end

local function fingerprint_indexes(previous, current)
  local old_by_fingerprint = {}
  local new_by_fingerprint = {}
  for _, id in ipairs(previous.order) do
    append_index(old_by_fingerprint, previous.units[id].fingerprint, id)
  end
  for _, id in ipairs(current.order) do
    append_index(new_by_fingerprint, current.units[id].fingerprint, id)
  end
  return old_by_fingerprint, new_by_fingerprint
end

local function match_unique_fingerprints(previous, current, relations, matched_old, matched_new)
  local old_by_fingerprint, new_by_fingerprint = fingerprint_indexes(previous, current)
  for fingerprint, old_ids in pairs(old_by_fingerprint) do
    local new_ids = new_by_fingerprint[fingerprint]
    if #old_ids == 1 and new_ids and #new_ids == 1 then
      local old_id, new_id = old_ids[1], new_ids[1]
      if previous.units[old_id].kind == current.units[new_id].kind then
        add_relation(
          relations,
          matched_old,
          matched_new,
          "same",
          { old_id },
          { new_id },
          1,
          "unique exact fingerprint and kind"
        )
      end
    end
  end
  return old_by_fingerprint, new_by_fingerprint
end

local function best_anchor_candidates(previous, current, anchor_hints, matched_old, matched_new)
  local current_text = current.adapter_state and current.adapter_state.text or ""
  local best_for_old = {}
  local best_for_new = {}
  for _, old_id in ipairs(previous.order) do
    local hint = anchor_hints[old_id]
    if not matched_old[old_id] and hint and hint.invalid ~= true then
      local old_interval = interval(current_text, hint.range)
      if old_interval then
        for _, new_id in ipairs(current.order) do
          if
            not matched_new[new_id] and previous.units[old_id].kind == current.units[new_id].kind
          then
            local new_interval = interval(current_text, current.units[new_id].span)
            if new_interval then
              local intersection = overlap(old_interval, new_interval)
              local old_ratio = intersection / old_interval.length
              local new_ratio = intersection / new_interval.length
              if old_ratio >= 0.5 and new_ratio >= 0.5 then
                local score = old_ratio + new_ratio
                local old_best = best_for_old[old_id]
                if not old_best or score > old_best.score then
                  best_for_old[old_id] = { id = new_id, score = score, tied = false }
                elseif score == old_best.score then
                  old_best.tied = true
                end
                local new_best = best_for_new[new_id]
                if not new_best or score > new_best.score then
                  best_for_new[new_id] = { id = old_id, score = score, tied = false }
                elseif score == new_best.score then
                  new_best.tied = true
                end
              end
            end
          end
        end
      end
    end
  end
  return best_for_old, best_for_new
end

local function match_anchors(previous, current, anchor_hints, relations, matched_old, matched_new)
  local best_for_old, best_for_new =
    best_anchor_candidates(previous, current, anchor_hints, matched_old, matched_new)
  for _, old_id in ipairs(previous.order) do
    local candidate = best_for_old[old_id]
    if candidate and not candidate.tied then
      local reverse = best_for_new[candidate.id]
      if
        reverse
        and not reverse.tied
        and reverse.id == old_id
        and not matched_new[candidate.id]
      then
        local same = previous.units[old_id].fingerprint == current.units[candidate.id].fingerprint
        add_relation(
          relations,
          matched_old,
          matched_new,
          same and "same" or "edited",
          { old_id },
          { candidate.id },
          same and 1 or 0.9,
          "mutual strong anchor overlap"
        )
      end
    end
  end
end

local function consecutive_unmatched(order, start, maximum, matched)
  local ids = {}
  for ordinal = start, math.min(#order, start + maximum - 1) do
    local id = order[ordinal]
    if matched[id] then
      break
    end
    ids[#ids + 1] = id
  end
  return ids
end

local function match_splits(previous, current, relations, matched_old, matched_new)
  for _, old_id in ipairs(previous.order) do
    if not matched_old[old_id] then
      local old_unit = previous.units[old_id]
      for start = 1, #current.order do
        if not matched_new[current.order[start]] then
          local candidates = consecutive_unmatched(current.order, start, 4, matched_new)
          for count = 2, #candidates do
            local ids = {}
            local kinds_match = true
            for index = 1, count do
              ids[index] = candidates[index]
              if current.units[ids[index]].kind ~= old_unit.kind then
                kinds_match = false
              end
            end
            if kinds_match and normalize_content(old_unit) == joined_content(current, ids) then
              add_relation(
                relations,
                matched_old,
                matched_new,
                "split",
                { old_id },
                ids,
                0.9,
                "one old unit equals consecutive new units after whitespace normalization"
              )
              break
            end
          end
        end
        if matched_old[old_id] then
          break
        end
      end
    end
  end
end

local function match_merges(previous, current, relations, matched_old, matched_new)
  for _, new_id in ipairs(current.order) do
    if not matched_new[new_id] then
      local new_unit = current.units[new_id]
      for start = 1, #previous.order do
        if not matched_old[previous.order[start]] then
          local candidates = consecutive_unmatched(previous.order, start, 4, matched_old)
          for count = 2, #candidates do
            local ids = {}
            local kinds_match = true
            for index = 1, count do
              ids[index] = candidates[index]
              if previous.units[ids[index]].kind ~= new_unit.kind then
                kinds_match = false
              end
            end
            if kinds_match and joined_content(previous, ids) == normalize_content(new_unit) then
              add_relation(
                relations,
                matched_old,
                matched_new,
                "merge",
                ids,
                { new_id },
                0.9,
                "consecutive old units equal one new unit after whitespace normalization"
              )
              break
            end
          end
        end
        if matched_new[new_id] then
          break
        end
      end
    end
  end
end

local function fingerprint_is_duplicated(id, snapshot, own_index, other_index)
  local fingerprint = snapshot.units[id].fingerprint
  return #(own_index[fingerprint] or {}) > 1 or #(other_index[fingerprint] or {}) > 1
end

local function match_unique_structure(
  previous,
  current,
  old_fingerprints,
  new_fingerprints,
  relations,
  matched_old,
  matched_new
)
  local old_by_key = {}
  local new_by_key = {}
  for _, id in ipairs(previous.order) do
    if
      not matched_old[id]
      and not fingerprint_is_duplicated(id, previous, old_fingerprints, new_fingerprints)
    then
      append_index(old_by_key, structural_key(previous.units[id]), id)
    end
  end
  for _, id in ipairs(current.order) do
    if
      not matched_new[id]
      and not fingerprint_is_duplicated(id, current, new_fingerprints, old_fingerprints)
    then
      append_index(new_by_key, structural_key(current.units[id]), id)
    end
  end
  for key, old_ids in pairs(old_by_key) do
    local new_ids = new_by_key[key]
    if #old_ids == 1 and new_ids and #new_ids == 1 then
      add_relation(
        relations,
        matched_old,
        matched_new,
        "edited",
        { old_ids[1] },
        { new_ids[1] },
        0.75,
        "unique structural path and kind"
      )
    end
  end
end

local function match_positional_edits(
  previous,
  current,
  old_fingerprints,
  new_fingerprints,
  relations,
  matched_old,
  matched_new
)
  local limit = math.min(#previous.order, #current.order)
  for ordinal = 1, limit do
    local old_id, new_id = previous.order[ordinal], current.order[ordinal]
    if
      not matched_old[old_id]
      and not matched_new[new_id]
      and previous.units[old_id].kind == current.units[new_id].kind
      and not fingerprint_is_duplicated(old_id, previous, old_fingerprints, new_fingerprints)
      and not fingerprint_is_duplicated(new_id, current, new_fingerprints, old_fingerprints)
    then
      add_relation(
        relations,
        matched_old,
        matched_new,
        "edited",
        { old_id },
        { new_id },
        0.65,
        "same unmatched ordinal and kind"
      )
    end
  end
end

local function match_ambiguous_fingerprints(
  _previous,
  _current,
  old_fingerprints,
  new_fingerprints,
  relations,
  matched_old,
  matched_new
)
  for fingerprint, old_ids in pairs(old_fingerprints) do
    local new_ids = new_fingerprints[fingerprint]
    if new_ids then
      local remaining_old = {}
      local remaining_new = {}
      for _, id in ipairs(old_ids) do
        if not matched_old[id] then
          remaining_old[#remaining_old + 1] = id
        end
      end
      for _, id in ipairs(new_ids) do
        if not matched_new[id] then
          remaining_new[#remaining_new + 1] = id
        end
      end
      if #remaining_old > 0 and #remaining_new > 0 then
        add_relation(
          relations,
          matched_old,
          matched_new,
          "ambiguous",
          remaining_old,
          remaining_new,
          0,
          "indistinguishable duplicate fingerprints without strong anchors"
        )
      end
    end
  end
end

local function mark_moves(relations, previous, current)
  local old_ordinals = ordinal_index(previous.order)
  local new_ordinals = ordinal_index(current.order)
  local pairs = {}
  for _, relation in ipairs(relations) do
    if
      (relation.kind == "same" or relation.kind == "edited")
      and #relation.old_ids == 1
      and #relation.provisional_new_ids == 1
    then
      pairs[#pairs + 1] = relation
    end
  end
  for _, relation in ipairs(pairs) do
    local old_position = old_ordinals[relation.old_ids[1]]
    local new_position = new_ordinals[relation.provisional_new_ids[1]]
    for _, other in ipairs(pairs) do
      local other_old = old_ordinals[other.old_ids[1]]
      local other_new = new_ordinals[other.provisional_new_ids[1]]
      if (old_position - other_old) * (new_position - other_new) < 0 then
        relation.kind = "move"
        relation.confidence = math.min(relation.confidence, 0.9)
        relation.reason = "matched-neighbor order changed"
        break
      end
    end
  end
end

local function relation_position(relation, old_ordinals, new_ordinals, new_count)
  local position = math.huge
  for _, id in ipairs(relation.provisional_new_ids) do
    position = math.min(position, new_ordinals[id])
  end
  if position ~= math.huge then
    return position
  end
  for _, id in ipairs(relation.old_ids) do
    position = math.min(position, new_count + old_ordinals[id])
  end
  return position
end

function Hybrid.new()
  return setmetatable({ api_version = 1, id = "hybrid" }, Hybrid)
end

function Hybrid:capabilities()
  return {
    anchors = true,
    structural_paths = true,
    fingerprints = true,
    structural_edits = true,
  }
end

function Hybrid:reconcile(request)
  if
    type(request) ~= "table"
    or type(request.previous) ~= "table"
    or type(request.current) ~= "table"
  then
    return nil,
      errors.new(
        errors.codes.INVALID_ARGUMENT,
        "Tracker reconciliation requires two snapshots",
        false
      )
  end
  local previous, current = request.previous, request.current
  local side = request.side or current.side
  if side ~= "source" and side ~= "target" then
    return nil,
      errors.new(
        errors.codes.INVALID_ARGUMENT,
        "Tracker reconciliation requires a valid side",
        false
      )
  end

  local relations = {}
  local matched_old = {}
  local matched_new = {}
  local old_fingerprints, new_fingerprints =
    match_unique_fingerprints(previous, current, relations, matched_old, matched_new)
  match_anchors(previous, current, request.anchor_hints or {}, relations, matched_old, matched_new)
  match_splits(previous, current, relations, matched_old, matched_new)
  match_merges(previous, current, relations, matched_old, matched_new)
  match_unique_structure(
    previous,
    current,
    old_fingerprints,
    new_fingerprints,
    relations,
    matched_old,
    matched_new
  )
  match_positional_edits(
    previous,
    current,
    old_fingerprints,
    new_fingerprints,
    relations,
    matched_old,
    matched_new
  )
  match_ambiguous_fingerprints(
    previous,
    current,
    old_fingerprints,
    new_fingerprints,
    relations,
    matched_old,
    matched_new
  )

  for _, old_id in ipairs(previous.order) do
    if not matched_old[old_id] then
      add_relation(
        relations,
        matched_old,
        matched_new,
        "delete",
        { old_id },
        {},
        1,
        "no current unit candidate"
      )
    end
  end
  for _, new_id in ipairs(current.order) do
    if not matched_new[new_id] then
      add_relation(
        relations,
        matched_old,
        matched_new,
        "insert",
        {},
        { new_id },
        1,
        "no previous unit candidate"
      )
    end
  end
  mark_moves(relations, previous, current)

  local provisional_to_stable = {}
  for _, relation in ipairs(relations) do
    if relation.kind == "same" or relation.kind == "edited" or relation.kind == "move" then
      provisional_to_stable[relation.provisional_new_ids[1]] = relation.old_ids[1]
    elseif relation.kind == "split" then
      provisional_to_stable[relation.provisional_new_ids[1]] = relation.old_ids[1]
    elseif relation.kind == "merge" then
      provisional_to_stable[relation.provisional_new_ids[1]] = relation.old_ids[1]
    end
  end
  local next_id = maximum_id(previous) + 1
  for _, provisional_id in ipairs(current.order) do
    if not provisional_to_stable[provisional_id] then
      provisional_to_stable[provisional_id] = ("%s:u:%06d"):format(id_prefix(side), next_id)
      next_id = next_id + 1
    end
  end

  local snapshot = deep_copy(current)
  snapshot.units = {}
  snapshot.order = {}
  for _, provisional_id in ipairs(current.order) do
    local stable_id = provisional_to_stable[provisional_id]
    local unit = deep_copy(current.units[provisional_id])
    unit.id = stable_id
    snapshot.units[stable_id] = unit
    snapshot.order[#snapshot.order + 1] = stable_id
  end

  local old_ordinals = ordinal_index(previous.order)
  local new_ordinals = ordinal_index(current.order)
  table.sort(relations, function(left, right)
    return relation_position(left, old_ordinals, new_ordinals, #current.order)
      < relation_position(right, old_ordinals, new_ordinals, #current.order)
  end)

  local report = {
    matches = {},
    old_to_new = {},
    new_to_old = {},
    affected_old_ids = {},
    affected_new_ids = {},
    ambiguous = false,
    snapshot = snapshot,
  }
  local affected_old, affected_new = {}, {}
  for _, old_id in ipairs(previous.order) do
    report.old_to_new[old_id] = {}
  end
  for _, stable_id in ipairs(snapshot.order) do
    report.new_to_old[stable_id] = {}
  end

  for _, relation in ipairs(relations) do
    local stable_new_ids = {}
    for _, provisional_id in ipairs(relation.provisional_new_ids) do
      stable_new_ids[#stable_new_ids + 1] = provisional_to_stable[provisional_id]
    end
    report.matches[#report.matches + 1] = {
      old_ids = deep_copy(relation.old_ids),
      new_ids = stable_new_ids,
      kind = relation.kind,
      confidence = relation.confidence,
      reason = relation.reason,
    }
    if relation.kind ~= "ambiguous" then
      for _, old_id in ipairs(relation.old_ids) do
        report.old_to_new[old_id] = deep_copy(stable_new_ids)
      end
      for _, stable_id in ipairs(stable_new_ids) do
        report.new_to_old[stable_id] = deep_copy(relation.old_ids)
      end
    else
      report.ambiguous = true
    end
    if relation.kind ~= "same" then
      for _, old_id in ipairs(relation.old_ids) do
        if not affected_old[old_id] then
          affected_old[old_id] = true
          report.affected_old_ids[#report.affected_old_ids + 1] = old_id
        end
      end
      for _, stable_id in ipairs(stable_new_ids) do
        if not affected_new[stable_id] then
          affected_new[stable_id] = true
          report.affected_new_ids[#report.affected_new_ids + 1] = stable_id
        end
      end
    end
  end
  return report
end

return { new = Hybrid.new }
