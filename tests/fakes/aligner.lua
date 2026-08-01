local document = require("bilingua.domain.document")
local errors = require("bilingua.domain.error")
local mapping_graph = require("bilingua.domain.mapping_graph")

local Aligner = {}
Aligner.__index = Aligner

local function default_initialize(request)
  if
    type(request) ~= "table"
    or type(request.source_snapshot) ~= "table"
    or type(request.target_snapshot) ~= "table"
    or type(request.construction_seeds) ~= "table"
  then
    return nil,
      errors.new(
        errors.codes.INVALID_ARGUMENT,
        "Fake Aligner initialization requires snapshots and construction seeds",
        false
      )
  end

  local groups = {}
  for ordinal, seed in ipairs(request.construction_seeds) do
    local target_id = request.target_snapshot.order[seed.target_ordinal]
    if type(seed.source_unit_ids) ~= "table" or not target_id then
      return nil, errors.new(errors.codes.ALIGNMENT, "Fake Aligner received an invalid seed", false)
    end
    local source_fragment, source_error =
      document.fragment(request.source_snapshot, seed.source_unit_ids)
    if not source_fragment then
      return nil, source_error
    end
    local target_fragment, target_error = document.fragment(request.target_snapshot, { target_id })
    if not target_fragment then
      return nil, target_error
    end
    groups[#groups + 1] = {
      id = ("fake-group:%06d"):format(ordinal),
      source_unit_ids = seed.source_unit_ids,
      target_unit_ids = { target_id },
      baseline = {
        source = source_fragment,
        target = target_fragment,
        revision = 0,
      },
      state = "clean",
      source_revision = 0,
      target_revision = 0,
      baseline_revision = 0,
      warnings = {},
      metadata = { fake = true },
    }
  end
  return mapping_graph.new(groups)
end

function Aligner.new(options)
  local resolved = options or {}
  return setmetatable({
    api_version = 1,
    id = resolved.id or "fake_aligner",
    initialize_handler = resolved.initialize,
    reconcile_handler = resolved.reconcile,
    initialize_requests = {},
    reconcile_requests = {},
  }, Aligner)
end

function Aligner:capabilities()
  return {
    overlapping_groups = false,
    structural_edits = true,
    asynchronous = false,
  }
end

function Aligner:initialize(request)
  self.initialize_requests[#self.initialize_requests + 1] = request
  if self.initialize_handler then
    return self.initialize_handler(request)
  end
  return default_initialize(request)
end

function Aligner:reconcile(request)
  self.reconcile_requests[#self.reconcile_requests + 1] = request
  if self.reconcile_handler then
    return self.reconcile_handler(request)
  end
  if type(request) == "table" and type(request.graph) == "table" then
    return request.graph
  end
  return nil,
    errors.new(errors.codes.INVALID_ARGUMENT, "Fake Aligner reconciliation requires a graph", false)
end

return {
  new = Aligner.new,
}
