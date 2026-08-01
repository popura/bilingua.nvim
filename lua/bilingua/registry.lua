local errors = require("bilingua.domain.error")

local Registry = {}
Registry.__index = Registry

local CATEGORIES = {
  document_adapter = true,
  unit_tracker = true,
  aligner = true,
  translation_backend = true,
  task_codec = true,
  translation_service = true,
}

function Registry.new()
  local entries = {}
  for category in pairs(CATEGORIES) do
    entries[category] = {}
  end
  return setmetatable({ entries = entries }, Registry)
end

function Registry:register(category, name, factory, options)
  if not CATEGORIES[category] then
    return nil, errors.new(errors.codes.INVALID_ARGUMENT, "Unknown registry category", false)
  end
  if type(name) ~= "string" or name == "" or type(factory) ~= "function" then
    return nil,
      errors.new(errors.codes.INVALID_ARGUMENT, "Registry name and factory are required", false)
  end
  if self.entries[category][name] and not (options and options.replace == true) then
    return nil,
      errors.new(
        errors.codes.INVALID_ARGUMENT,
        ("%s '%s' is already registered"):format(category, name),
        false
      )
  end

  self.entries[category][name] = factory
  return true
end

function Registry:get(category, name)
  if not CATEGORIES[category] then
    return nil
  end
  return self.entries[category][name]
end

for category in pairs(CATEGORIES) do
  Registry["register_" .. category] = function(self, name, factory, options)
    return self:register(category, name, factory, options)
  end
  Registry["get_" .. category] = function(self, name)
    return self:get(category, name)
  end
end

local default = Registry.new()
local M = { new = Registry.new }

for category in pairs(CATEGORIES) do
  M["register_" .. category] = function(name, factory, options)
    return default:register(category, name, factory, options)
  end
  M["get_" .. category] = function(name)
    return default:get(category, name)
  end
end

function M.default()
  return default
end

return M
