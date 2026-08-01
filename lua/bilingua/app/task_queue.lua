local errors = require("bilingua.domain.error")

local TaskQueue = {}
TaskQueue.__index = TaskQueue

function TaskQueue.new(options)
  local resolved = options or {}
  local maximum = resolved.max_concurrency or 1
  if type(maximum) ~= "number" or maximum < 1 or maximum % 1 ~= 0 then
    error("TaskQueue max_concurrency must be a positive integer", 2)
  end
  return setmetatable({
    max_concurrency = maximum,
    pending = {},
    pending_by_key = {},
    active_by_key = {},
    active_count = 0,
    sequence = 0,
    closed = false,
    pumping = false,
    pump_requested = false,
    last_error = nil,
    idle_callbacks = {},
  }, TaskQueue)
end

local function invoke_cancel(item)
  if type(item.on_cancel) == "function" then
    pcall(item.on_cancel)
  end
end

function TaskQueue:cancel_active(key)
  local record = self.active_by_key[key]
  if not record or record.settled then
    return false
  end
  record.settled = true
  self.active_by_key[key] = nil
  self.active_count = self.active_count - 1
  if record.handle and type(record.handle.cancel) == "function" then
    pcall(record.handle.cancel, record.handle)
  end
  invoke_cancel(record.item)
  return true
end

function TaskQueue:next_pending()
  local best_index
  local best
  for index, item in ipairs(self.pending) do
    if not item.cancelled and self.pending_by_key[item.key] == item then
      if
        not best
        or item.priority > best.priority
        or (item.priority == best.priority and item.sequence < best.sequence)
      then
        best = item
        best_index = index
      end
    end
  end
  if not best then
    return nil
  end
  table.remove(self.pending, best_index)
  self.pending_by_key[best.key] = nil
  return best
end

function TaskQueue:pump()
  if self.pumping then
    self.pump_requested = true
    return
  end
  self.pumping = true
  repeat
    self.pump_requested = false
    while not self.closed and self.active_count < self.max_concurrency do
      local item = self:next_pending()
      if not item then
        break
      end
      local record = { item = item, settled = false, handle = nil }
      self.active_by_key[item.key] = record
      self.active_count = self.active_count + 1

      local function done()
        if record.settled then
          return
        end
        record.settled = true
        if self.active_by_key[item.key] == record then
          self.active_by_key[item.key] = nil
          self.active_count = self.active_count - 1
        end
        self:pump()
      end

      local ran, handle = pcall(item.run, done)
      if not ran then
        self.last_error = errors.new(
          errors.codes.INTERNAL,
          "A queued task raised an internal error",
          false,
          nil,
          handle
        )
        done()
      elseif not record.settled then
        record.handle = handle
      end
    end
  until not self.pump_requested
  self.pumping = false
  self:notify_idle()
end

function TaskQueue:enqueue(item)
  if self.closed then
    return nil, errors.new(errors.codes.SESSION_CLOSED, "The task queue is closed", false)
  end
  if
    type(item) ~= "table"
    or type(item.key) ~= "string"
    or item.key == ""
    or type(item.run) ~= "function"
  then
    return nil,
      errors.new(
        errors.codes.INVALID_ARGUMENT,
        "A queued task requires a key and run function",
        false
      )
  end

  local waiting = self.pending_by_key[item.key]
  if waiting then
    waiting.cancelled = true
    invoke_cancel(waiting)
  end
  if self.active_by_key[item.key] then
    self:cancel_active(item.key)
  end
  self.sequence = self.sequence + 1
  item.priority = item.priority or 0
  item.sequence = self.sequence
  self.pending_by_key[item.key] = item
  self.pending[#self.pending + 1] = item
  self:pump()
  return true
end

function TaskQueue:status()
  local pending = 0
  for _, item in pairs(self.pending_by_key) do
    if not item.cancelled then
      pending = pending + 1
    end
  end
  return {
    active = self.active_count,
    pending = pending,
    closed = self.closed,
  }
end

function TaskQueue:is_idle()
  local status = self:status()
  return status.active == 0 and status.pending == 0
end

function TaskQueue:notify_idle()
  if not self:is_idle() or #self.idle_callbacks == 0 then
    return
  end
  local callbacks = self.idle_callbacks
  self.idle_callbacks = {}
  for _, callback in ipairs(callbacks) do
    local ok, callback_error = pcall(callback)
    if not ok then
      self.last_error = errors.new(
        errors.codes.INTERNAL,
        "A task queue idle callback raised an internal error",
        false,
        nil,
        callback_error
      )
    end
  end
end

function TaskQueue:when_idle(callback)
  if type(callback) ~= "function" then
    error("TaskQueue idle callback must be a function", 2)
  end
  if self:is_idle() then
    local ok, callback_error = pcall(callback)
    if not ok then
      self.last_error = errors.new(
        errors.codes.INTERNAL,
        "A task queue idle callback raised an internal error",
        false,
        nil,
        callback_error
      )
    end
  else
    self.idle_callbacks[#self.idle_callbacks + 1] = callback
  end
  return true
end

function TaskQueue:close()
  if self.closed then
    return true
  end
  self.closed = true
  for _, item in pairs(self.pending_by_key) do
    item.cancelled = true
    invoke_cancel(item)
  end
  self.pending = {}
  self.pending_by_key = {}
  local keys = {}
  for key in pairs(self.active_by_key) do
    keys[#keys + 1] = key
  end
  for _, key in ipairs(keys) do
    self:cancel_active(key)
  end
  self:notify_idle()
  return true
end

return {
  new = TaskQueue.new,
}
