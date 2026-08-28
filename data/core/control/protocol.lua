local MessagePack = require "core.control.msgpack"
local Errors = require "core.control.errors"

local protocol = {
  version = 1,
  max_payload_size = 16 * 1024 * 1024,
  max_depth = 32,
}

local kinds = { request = true, response = true, event = true }

local function integer(value)
  return type(value) == "number" and value == math.floor(value)
end

local function fail(code, message)
  return nil, code, message
end

local function validate_error(value)
  if type(value) ~= "table" then
    return fail("invalid_request", "error must be a map")
  end
  if not Errors.is_code(value.code) then
    return fail("invalid_request", "error.code is invalid")
  end
  if type(value.message) ~= "string" then
    return fail("invalid_request", "error.message is required")
  end
  if type(value.retryable) ~= "boolean" then
    return fail("invalid_request", "error.retryable is required")
  end
  return true
end

local function known_fields(message)
  local result = { version = message.version, kind = message.kind }
  if message.kind == "request" then
    result.id, result.method, result.params = message.id, message.method, message.params
  elseif message.kind == "response" then
    result.id, result.result, result.error = message.id, message.result, message.error
  else
    result.sequence, result.event, result.data = message.sequence, message.event, message.data
  end
  return result
end

function protocol.validate(message)
  if type(message) ~= "table" then
    return fail("invalid_request", "message must be a map")
  end
  if not integer(message.version) then
    return fail("invalid_request", "version is required")
  end
  if message.version ~= protocol.version then
    return fail("unsupported_version", "unsupported protocol version: " .. tostring(message.version))
  end
  if type(message.kind) ~= "string" or not kinds[message.kind] then
    return fail("invalid_request", "kind is invalid")
  end

  if message.kind == "request" then
    if type(message.id) ~= "string" or message.id == "" then
      return fail("invalid_request", "request id is required")
    end
    if type(message.method) ~= "string" or message.method == "" then
      return fail("invalid_request", "request method is required")
    end
    if type(message.params) ~= "table" then
      return fail("invalid_request", "request params must be a map")
    end
  elseif message.kind == "response" then
    if type(message.id) ~= "string" or message.id == "" then
      return fail("invalid_request", "response id is required")
    end
    if message.result == nil and message.error == nil then
      return fail("invalid_request", "response result or error is required")
    end
    if message.result ~= nil and message.error ~= nil then
      return fail("invalid_request", "response cannot contain result and error")
    end
    if message.error ~= nil then
      local ok, code, detail = validate_error(message.error)
      if not ok then return nil, code, detail end
    end
  else
    if not integer(message.sequence) or message.sequence < 1 then
      return fail("invalid_request", "event sequence is required")
    end
    if type(message.event) ~= "string" or message.event == "" then
      return fail("invalid_request", "event name is required")
    end
    if type(message.data) ~= "table" then
      return fail("invalid_request", "event data must be a map")
    end
  end
  return true
end

function protocol.encode(message)
  local valid, code, detail = protocol.validate(message)
  if not valid then return nil, code, detail end
  local ok, payload = pcall(MessagePack.encode, known_fields(message))
  if not ok then return nil, "invalid_request", tostring(payload) end
  if #payload > protocol.max_payload_size then
    return nil, "invalid_request", "protocol payload is too large"
  end
  return payload
end

function protocol.decode(payload)
  if type(payload) ~= "string" then
    return nil, "invalid_request", "protocol payload must be a string"
  end
  if #payload > protocol.max_payload_size then
    return nil, "invalid_request", "protocol payload is too large"
  end
  local ok, message, position = pcall(MessagePack.decode, payload)
  if not ok then return nil, "invalid_request", tostring(message) end
  if position ~= #payload + 1 then
    return nil, "invalid_request", "protocol payload contains trailing data"
  end
  local valid, code, detail = protocol.validate(message)
  if not valid then return nil, code, detail end
  return known_fields(message)
end

function protocol.request(id, method, params)
  return { version = protocol.version, kind = "request", id = id,
    method = method, params = params or {} }
end

function protocol.response(id, result)
  return { version = protocol.version, kind = "response", id = id,
    result = result == nil and {} or result }
end

function protocol.error_response(id, code, message, retryable)
  return { version = protocol.version, kind = "response", id = id,
    error = Errors.new(code, message, retryable) }
end

function protocol.event(sequence, name, data)
  return { version = protocol.version, kind = "event", sequence = sequence,
    event = name, data = data or {} }
end

return protocol
