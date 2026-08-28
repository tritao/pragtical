local Protocol = require "core.control.protocol"
local Errors = require "core.control.errors"

local Client = {}
Client.__index = Client

local sequence = 0

local function next_id(prefix)
  sequence = sequence + 1
  return (prefix or "client") .. ":" .. tostring(sequence)
end

function Client.connect(transport, endpoint, options)
  options = options or {}
  options.max_frame_size = options.max_frame_size or Protocol.max_payload_size
  options.max_queued_bytes = options.max_queued_bytes or (8 * 1024 * 1024)
  options.request_timeout = options.request_timeout or 5
  options.max_messages_per_poll = options.max_messages_per_poll or 64
  local connection, err = transport.connect(endpoint, {
    max_frame_size = options.max_frame_size,
    max_queued_bytes = options.max_queued_bytes,
  })
  if not connection then return nil, err end
  return setmetatable({
    connection = connection,
    endpoint = endpoint,
    client_id = options.client_id or next_id("client"),
    outgoing = {},
    outgoing_bytes = 0,
    pending = {},
    events = {},
    event_callbacks = {},
    closed = false,
    options = options,
  }, Client)
end

function Client:_enqueue(payload)
  if self.outgoing_bytes + #payload > self.options.max_queued_bytes then
    return nil, Errors.new("busy", "control client output queue is full", true)
  end
  self.outgoing[#self.outgoing + 1] = payload
  self.outgoing_bytes = self.outgoing_bytes + #payload
  return true
end

function Client:_flush()
  local flushed, err = self.connection:flush()
  if not flushed and err ~= "would_block" then return nil, err end
  if not flushed then return true end
  while #self.outgoing > 0 do
    local payload = self.outgoing[1]
    local sent, send_error = self.connection:send(payload)
    if sent then
      table.remove(self.outgoing, 1)
      self.outgoing_bytes = self.outgoing_bytes - #payload
    elseif send_error == "would_block" then
      table.remove(self.outgoing, 1)
      self.outgoing_bytes = self.outgoing_bytes - #payload
      return true
    else
      return nil, send_error
    end
  end
  return true
end

function Client:request(method, params, callback, timeout)
  if self.closed then return nil, Errors.new("permission_denied", "client is closed", false) end
  local id = next_id(self.client_id)
  local payload, code, detail = Protocol.encode(Protocol.request(id, method, params))
  if not payload then return nil, Errors.new(code, detail, false) end
  local pending = {
    id = id,
    callback = callback,
    deadline = (system.get_time() + (timeout or self.options.request_timeout)),
  }
  self.pending[id] = pending
  local ok, queue_error = self:_enqueue(payload)
  if not ok then
    self.pending[id] = nil
    return nil, queue_error
  end
  return pending
end

function Client:_finish(message)
  local pending = self.pending[message.id]
  if not pending then return end
  self.pending[message.id] = nil
  pending.done = true
  if message.error then
    pending.error = message.error
  else
    pending.result = message.result
  end
  if pending.callback then pending.callback(pending.result, pending.error, pending) end
end

function Client:poll()
  if self.closed then return nil, "closed" end
  local flushed, flush_error = self:_flush()
  if not flushed then self:close(); return nil, flush_error or "closed" end
  local count = 0
  for _ = 1, self.options.max_messages_per_poll do
    local payload, receive_error = self.connection:receive(0)
    if not payload then
      if receive_error == "would_block" then break end
      self:close()
      return nil, receive_error or "closed"
    end
    local message, code, detail = Protocol.decode(payload)
    if not message then
      self:close()
      return nil, Errors.new(code, detail, false)
    end
    if message.kind == "response" then
      self:_finish(message)
    elseif message.kind == "event" then
      self.events[#self.events + 1] = message
      for _, callback in ipairs(self.event_callbacks) do callback(message) end
    end
    count = count + 1
  end
  local now = system.get_time()
  for id, pending in pairs(self.pending) do
    if now >= pending.deadline then
      self.pending[id] = nil
      pending.done = true
      pending.error = Errors.new("timeout", "control request timed out", true)
      if pending.callback then pending.callback(nil, pending.error, pending) end
    end
  end
  return count
end

function Client:request_sync(method, params, timeout)
  local request, err = self:request(method, params, nil, timeout)
  if not request then return nil, err end
  local deadline = system.get_time() + (timeout or self.options.request_timeout)
  while not request.done and system.get_time() < deadline do
    local _, poll_error = self:poll()
    if poll_error and poll_error ~= "would_block" then
      return nil, Errors.new("internal", poll_error, true)
    end
    if not request.done then system.sleep(0.001) end
  end
  if not request.done then
    self.pending[request.id] = nil
    return nil, Errors.new("timeout", "control request timed out", true)
  end
  return request.result, request.error
end

function Client:on_event(callback)
  assert(type(callback) == "function", "control event callback must be a function")
  self.event_callbacks[#self.event_callbacks + 1] = callback
  return function()
    for index, current in ipairs(self.event_callbacks) do
      if current == callback then table.remove(self.event_callbacks, index); break end
    end
  end
end

function Client:close()
  if self.closed then return end
  self.closed = true
  if self.connection then self.connection:close() end
  for id, pending in pairs(self.pending) do
    self.pending[id] = nil
    pending.done = true
    pending.error = Errors.new("timeout", "control connection closed", true)
    if pending.callback then pending.callback(nil, pending.error, pending) end
  end
end

return Client
