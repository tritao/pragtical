local Errors = require "core.control.errors"

local Registry = {}
Registry.__index = Registry

function Registry.new()
  return setmetatable({ methods = {} }, Registry)
end

function Registry:register(definition)
  assert(type(definition) == "table", "control method declaration must be a table")
  assert(type(definition.method) == "string" and definition.method ~= "",
    "control method name is required")
  assert(type(definition.execute) == "function",
    "control method execute function is required")
  assert(definition.method:match("^[%a][%w_.-]*$"), "invalid control method name")
  if self.methods[definition.method] then
    return nil, "control method is already registered"
  end
  self.methods[definition.method] = definition
  return true
end

function Registry:unregister(method)
  self.methods[method] = nil
end

function Registry:has(method)
  return self.methods[method] ~= nil
end

function Registry:dispatch(method, params, context, development)
  local definition = self.methods[method]
  if not definition then
    return nil, Errors.new("unsupported", "unsupported control method: " .. tostring(method), false)
  end
  if definition.validate then
    local valid, validation_error
    local ok, validation_failure = xpcall(function()
      valid, validation_error = definition.validate(params)
    end, function(err)
      if development then return debug.traceback(tostring(err), 2) end
      return tostring(err)
    end)
    if not ok then
      return nil, Errors.new("internal", validation_failure, false)
    end
    if not valid then
      if type(validation_error) == "table" then return nil, validation_error end
      return nil, Errors.new("invalid_argument", validation_error or "invalid arguments", false)
    end
    params = valid
  end
  local returned
  local ok, handler_failure = xpcall(function()
    returned = table.pack(definition.execute(params, context))
  end, function(err)
    if development then return debug.traceback(tostring(err), 2) end
    return tostring(err)
  end)
  if not ok then
    return nil, Errors.new("internal", handler_failure, false)
  end
  local result, handler_error = returned[1], returned[2]
  if type(handler_error) == "table" and handler_error.code then
    return nil, Errors.new(handler_error.code, handler_error.message,
      handler_error.retryable)
  end
  if result == nil and handler_error ~= nil then
    return nil, Errors.new("internal", tostring(handler_error), false)
  end
  return result
end

return Registry
