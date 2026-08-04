local Transport = {}
Transport.__index = Transport

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, item in pairs(value) do
    result[copy(key)] = copy(item)
  end
  return result
end

function Transport.new()
  return setmetatable({
    queued = {},
    history = {},
    active = {},
    cancel_count = 0,
  }, Transport)
end

function Transport:request(request, callback)
  local record = {
    request = copy(request),
    callback = callback,
    cancelled = false,
    responses = 0,
  }
  self.queued[#self.queued + 1] = record
  self.history[#self.history + 1] = record
  self.active[record] = true
  local owner = self
  local handle = {}
  function handle:cancel()
    if record.cancelled then
      return
    end
    record.cancelled = true
    owner.cancel_count = owner.cancel_count + 1
    owner.active[record] = nil
  end
  return handle
end

function Transport:take(method, url)
  for index, record in ipairs(self.queued) do
    local request = record.request
    if (method == nil or request.method == method) and (url == nil or request.url == url) then
      table.remove(self.queued, index)
      return record
    end
  end
end

function Transport:respond(record, response, transport_error)
  assert(type(record) == "table", "request record is required")
  self.active[record] = nil
  record.responses = record.responses + 1
  record.callback(response, transport_error)
end

function Transport:active_count()
  local count = 0
  for _ in pairs(self.active) do
    count = count + 1
  end
  return count
end

function Transport:queued_count()
  return #self.queued
end

function Transport:requested_url(url)
  for _, record in ipairs(self.history) do
    if record.request.url == url then
      return true
    end
  end
  return false
end

return {
  new = Transport.new,
}
