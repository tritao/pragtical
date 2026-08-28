local errors = {
  invalid_request = true,
  unsupported_version = true,
  invalid_argument = true,
  not_found = true,
  ambiguous_target = true,
  permission_denied = true,
  unsupported = true,
  busy = true,
  timeout = true,
  internal = true,
}

local M = {}

function M.is_code(code)
  return type(code) == "string" and errors[code] == true
end

function M.new(code, message, retryable)
  if not M.is_code(code) then code = "internal" end
  return {
    code = code,
    message = tostring(message or code),
    retryable = retryable == true,
  }
end

function M.from(value)
  if type(value) ~= "table" or not M.is_code(value.code)
      or type(value.message) ~= "string"
      or type(value.retryable) ~= "boolean" then
    return nil, "invalid error object"
  end
  return M.new(value.code, value.message, value.retryable)
end

return M
