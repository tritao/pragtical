local Protocol = require "core.control.protocol"
local Errors = require "core.control.errors"

local Server = {}
Server.__index = Server

local function now()
  return system and system.get_time and system.get_time() or os.clock()
end

function Server.new(transport, endpoint, registry, options)
  options = options or {}
  options.max_frame_size = options.max_frame_size or Protocol.max_payload
  options.max_queued_bytes = options.max_queued_bytes or (8 * 1024 * 1024)
  options.max_requests_per_poll = options.max_requests_per_poll or 64
  options.max_accepts_per_poll = options.max_accepts_per_poll or 16
  options.frame_timeout = options.frame_timeout or 10
  options.idle_timeout = options.idle_timeout or 300
  local native, err = transport.listen(endpoint, {
    max_frame_size = options.max_frame_size,
    max_queued_bytes = options.max_queued_bytes,
  })
  if not native then return nil, err end
  return setmetatable({
    transport = native,
    endpoint = endpoint,
    registry = registry,
    options = options,
    clients = {},
    sequence = 0,
    request_sequence = 0,
    closed = false,
  }, Server)
end

local function close_connection(client)
  if client.connection then pcall(client.connection.close, client.connection) end
  client.connection = nil
end

function Server:_remove(index)
  close_connection(self.clients[index])
  table.remove(self.clients, index)
end

function Server:_queue(client, message)
  local payload, code, detail = Protocol.encode(message)
  if not payload then return nil, Errors.new(code, detail, false) end
  if client.outgoing_bytes + #payload > self.options.max_queued_bytes then
    return nil, Errors.new("busy", "control output queue is full", true)
  end
  client.outgoing[#client.outgoing + 1] = payload
  client.outgoing_bytes = client.outgoing_bytes + #payload
  return true
end

function Server:_flush(client)
  if not client.connection then return nil, "closed" end
  local flushed, flush_error = client.connection:flush()
  if not flushed and flush_error ~= "would_block" then return nil, flush_error end
  if not flushed then return true end
  while #client.outgoing > 0 do
    local payload = client.outgoing[1]
    local sent, send_error = client.connection:send(payload)
    if sent then
      table.remove(client.outgoing, 1)
      client.outgoing_bytes = client.outgoing_bytes - #payload
    elseif send_error == "would_block" then
      -- The transport owns the frame after a would_block result.
      table.remove(client.outgoing, 1)
      client.outgoing_bytes = client.outgoing_bytes - #payload
      return true
    else
      return nil, send_error
    end
  end
  return true
end

function Server:_respond(client, request_id, result, error)
  local response = error
    and Protocol.error_response(request_id, error.code, error.message, error.retryable)
    or Protocol.response(request_id, result)
  local ok, queue_error = self:_queue(client, response)
  if not ok then return nil, queue_error end
  return true
end

function Server:_handle(client, message)
  if message.kind ~= "request" then
    local ok, error_result = self:_respond(client,
      "invalid-" .. tostring(self.request_sequence), nil,
      Errors.new("invalid_request", "control server accepts requests only", false))
    client.close_after_flush = true
    return ok, error_result
  end
  if client.request_ids[message.id] then
    local ok, error_result = self:_respond(client, message.id, nil,
      Errors.new("invalid_request", "request id is not unique", false))
    client.close_after_flush = true
    return ok, error_result
  end
  client.request_ids[message.id] = true
  if not client.hello and message.method ~= "control.hello" then
    local ok, error_result = self:_respond(client, message.id, nil,
      Errors.new("permission_denied", "control.hello is required first", false))
    client.close_after_flush = true
    return ok, error_result
  end
  local is_hello = message.method == "control.hello"
  local result, dispatch_error = self.registry:dispatch(message.method, message.params, {
    server = self,
    client = client,
  }, self.options.development)
  if dispatch_error then
    return self:_respond(client, message.id, nil, dispatch_error)
  end
  if is_hello then client.hello = true end
  return self:_respond(client, message.id, result)
end

function Server:_read(client)
  for _ = 1, self.options.max_requests_per_poll do
    local payload, receive_error = client.connection:receive(0)
    if not payload then
      if receive_error == "would_block" then
        local current = now()
        local pending = client.connection.has_pending_frame
          and client.connection:has_pending_frame()
        if pending then
          client.frame_started_at = client.frame_started_at or current
          if current - client.frame_started_at >= self.options.frame_timeout then
            return nil, "timeout"
          end
        elseif current - client.last_activity >= self.options.idle_timeout then
          return nil, "timeout"
        end
        return true
      end
      if receive_error == "invalid_frame" then
        close_connection(client)
        return nil, receive_error
      end
      close_connection(client)
      return nil, receive_error or "closed"
    end
    client.last_activity = now()
    client.frame_started_at = nil
    local message, code, detail = Protocol.decode(payload)
    if not message then
      local response_error = Errors.new(code, detail, false)
      self:_respond(client, "invalid-" .. tostring(self.request_sequence), nil, response_error)
      client.close_after_flush = true
      return true
    end
    self.request_sequence = self.request_sequence + 1
    local ok, handle_error = self:_handle(client, message)
    if not ok then return nil, handle_error and handle_error.message or "closed" end
  end
  return true
end

function Server:poll()
  if self.closed then return 0 end
  local handled = 0
  for _ = 1, self.options.max_accepts_per_poll do
    local connection, accept_error = self.transport:accept(0)
    if not connection then
      if accept_error ~= "would_block" and accept_error ~= "timeout"
          and accept_error ~= "unauthorized" then
        break
      end
      break
    end
    self.clients[#self.clients + 1] = {
      connection = connection,
      outgoing = {},
      outgoing_bytes = 0,
      request_ids = {},
      hello = false,
      close_after_flush = false,
      connected_at = now(),
      last_activity = now(),
      frame_started_at = nil,
    }
  end
  local index = 1
  while index <= #self.clients do
    local client = self.clients[index]
    local alive = self:_read(client)
    if alive then
      local flushed, flush_error = self:_flush(client)
      if not flushed or (client.close_after_flush and #client.outgoing == 0) then
        self:_remove(index)
      else
        index = index + 1
      end
    else
      self:_remove(index)
    end
    handled = handled + 1
  end
  return handled
end

function Server:publish(name, data)
  if self.closed then return nil, "closed" end
  self.sequence = self.sequence + 1
  local event = Protocol.event(self.sequence, name, data)
  for index = #self.clients, 1, -1 do
    local client = self.clients[index]
    if client.hello then
      local ok = self:_queue(client, event)
      if not ok then self:_remove(index) end
    end
  end
  return self.sequence
end

function Server:close()
  if self.closed then return end
  self.closed = true
  for index = #self.clients, 1, -1 do self:_remove(index) end
  self.transport:close()
end

return Server
