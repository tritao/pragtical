local Client = require "core.control.client"
local Discovery = require "core.instance_discovery"
local json = require "core.json"

local cli = {}

local EXIT_USAGE = 2
local EXIT_DISCOVERY = 3
local EXIT_CONNECTION = 4
local EXIT_REMOTE = 5
local EXIT_PROTOCOL = 6
local EXIT_INTERNAL = 7

local function usage(stream)
  stream:write([[
Usage: pragtical-ctl [OPTIONS] COMMAND

Commands:
  list                         List running Pragtical instances
  status                       Show instance status
  focus                        Focus the instance window
  open PATH...                 Open one or more files
  documents                    List open documents
  save                         Save all open documents
  project add PATH             Add a project
  project change PATH          Change the active project
  call METHOD [JSON]           Call a public control method

Options:
  --instance ID                Select an instance explicitly
  --project PATH               Select an instance by project path
  --timeout DURATION           Request timeout (seconds, or e.g. 500ms)
  --output text|json           Select human or machine-readable output
  -h, --help                   Show this help
]])
end

local function parse_timeout(value)
  if type(value) ~= "string" then return nil end
  local multiplier = 1
  local number = value
  if value:match("ms$") then
    multiplier = 0.001
    number = value:sub(1, -3)
  elseif value:match("s$") then
    number = value:sub(1, -2)
  end
  local seconds = tonumber(number)
  if not seconds or seconds <= 0 or seconds * multiplier > 2147483 then return nil end
  return seconds * multiplier
end

local function error_value(code, message, retryable)
  return { code = code, message = tostring(message or code), retryable = retryable == true }
end

local function normalize_error(value, fallback_code)
  if type(value) == "table" and type(value.code) == "string"
      and type(value.message) == "string" then
    return value
  end
  return error_value(fallback_code, value)
end

local function exit_code(error)
  if error.code == "usage" then return EXIT_USAGE end
  if error.code == "not_found" or error.code == "ambiguous_target"
      or error.code == "discovery" then return EXIT_DISCOVERY end
  if error.code == "timeout" or error.code == "connection" then return EXIT_CONNECTION end
  if error.code == "protocol" or error.code == "invalid_request"
      or error.code == "unsupported_version" then return EXIT_PROTOCOL end
  if error.code == "internal" then return EXIT_INTERNAL end
  return EXIT_REMOTE
end

local function encode(value)
  local ok, output = pcall(json.encode, value)
  return ok and output or nil
end

local function fail(options, code, message, retryable)
  local error = error_value(code, message, retryable)
  if options.output == "json" then
    io.stdout:write(encode({ error = error }) or
      '{"error":{"code":"internal","message":"could not encode error","retryable":false}}', "\n")
  else
    io.stderr:write("pragtical-ctl: ", error.code, ": ", error.message, "\n")
  end
  return exit_code(error)
end

local function print_result(options, command, value)
  if options.output == "json" then
    if command == "list" then json.array(value) end
    if type(value) == "table" and value.documents then json.array(value.documents) end
    local output = encode(value)
    if not output then return fail(options, "internal", "could not encode JSON output") end
    io.stdout:write(output, "\n")
    return 0
  end

  if command == "list" then
    if #value == 0 then io.stdout:write("No running Pragtical instances.\n"); return 0 end
    for _, instance in ipairs(value) do
      io.stdout:write(instance.instance_id or "(unknown)")
      if instance.pid then io.stdout:write(" (pid ", tostring(instance.pid), ")") end
      io.stdout:write("\n  endpoint: ", tostring(instance.endpoint or ""), "\n")
      for _, root in ipairs(instance.project_roots or {}) do
        io.stdout:write("  project: ", root, "\n")
      end
    end
    return 0
  end
  if command == "open" then
    for _, result in ipairs(value.opened or {}) do io.stdout:write(tostring(result.path or ""), "\n") end
    return 0
  end
  if type(value) == "table" and value.focused ~= nil then
    io.stdout:write(value.focused and "focused\n" or "not focused\n")
    return 0
  end
  if type(value) == "table" and value.documents then
    for _, document in ipairs(value.documents) do
      io.stdout:write(document.document_id or "(unknown)", "\t",
        document.path or "(untitled)",
        document.modified and "\tmodified" or "", "\n")
    end
    return 0
  end
  if type(value) == "table" and value.path then io.stdout:write(value.path, "\n"); return 0 end
  local output = encode(value)
  if output then io.stdout:write(output, "\n") end
  return 0
end

local transport_available, transport = pcall(require, "local_transport")

local function request(options, argv0, target, method, params)
  if not transport_available then return nil, error_value("connection", "local control transport is unavailable") end
  local descriptor, selection_error = Discovery.select(target, {
    transport = transport,
    instance_id = options.instance,
  })
  if not descriptor then return nil, error_value(selection_error or "not_found", "could not select a Pragtical instance") end
  local client, connect_error = Client.connect(transport, descriptor.endpoint, {
    client_id = "ctl:" .. tostring(system.get_process_id()),
    request_timeout = options.timeout,
  })
  if not client then return nil, error_value("connection", connect_error, true) end
  local hello, hello_error = client:request_sync("control.hello", {
    client_id = "ctl:" .. tostring(system.get_process_id()),
  })
  if not hello then
    client:close()
    return nil, normalize_error(hello_error, "protocol")
  end
  if hello.protocol_version ~= 1 or type(hello.instance_id) ~= "string" then
    client:close()
    return nil, error_value("unsupported_version", "control endpoint returned an incompatible hello response")
  end
  local result, request_error = client:request_sync(method, params or {})
  client:close()
  if request_error then return nil, normalize_error(request_error, "protocol") end
  return result
end

local function path_params(path)
  return { path = path }
end

local function is_map(value)
  if type(value) ~= "table" then return false end
  for key in pairs(value) do if type(key) ~= "string" then return false end end
  return true
end

function cli.run(arguments, argv0)
  local options = { output = "text", timeout = 5 }
  local index = 1
  while index <= #arguments do
    local argument = arguments[index]
    local name, value = argument:match("^(%-%-[%w-]+)=(.*)$")
    name = name or argument
    if name == "-h" or name == "--help" then usage(io.stdout); return 0 end
    if name == "--instance" or name == "--project" or name == "--timeout" or name == "--output" then
      if not value then index = index + 1; value = arguments[index] end
      if not value then return fail(options, "usage", name .. " requires a value") end
    elseif name:sub(1, 1) == "-" then
      return fail(options, "usage", "unknown option: " .. argument)
    else
      break
    end
    if name == "--instance" then options.instance = value
    elseif name == "--project" then options.project = value
    elseif name == "--timeout" then
      options.timeout = parse_timeout(value)
      if not options.timeout then return fail(options, "usage", "invalid timeout") end
    elseif name == "--output" then
      if value ~= "text" and value ~= "json" then return fail(options, "usage", "output must be text or json") end
      options.output = value
    end
    index = index + 1
  end

  local command = arguments[index]
  if not command then usage(io.stderr); return EXIT_USAGE end
  index = index + 1
  if command == "list" then
    if index <= #arguments then return fail(options, "usage", "list takes no arguments") end
    local instances, list_error = Discovery.list(transport_available and transport or nil)
    if not instances then return fail(options, "discovery", list_error) end
    if options.instance then
      local filtered = {}
      for _, instance in ipairs(instances) do
        if instance.instance_id == options.instance then filtered[#filtered + 1] = instance end
      end
      instances = filtered
    end
    return print_result(options, command, instances)
  end
  if command == "open" then
    if index > #arguments then return fail(options, "usage", "open requires at least one path") end
    local opened = {}
    for path_index = index, #arguments do
      local path = arguments[path_index]
      local result, request_error = request(options, argv0, options.project or path,
        "editor.open", path_params(path))
      if request_error then return fail(options, request_error.code, request_error.message, request_error.retryable) end
      opened[#opened + 1] = result
    end
    return print_result(options, command, { opened = opened })
  end

  local method, target, params
  if command == "status" then method = "instance.status"
  elseif command == "focus" then method = "window.focus"
  elseif command == "documents" then method = "editor.documents"
  elseif command == "save" then method = "editor.save"
  elseif command == "project" then
    local action, path = arguments[index], arguments[index + 1]
    if (action ~= "add" and action ~= "change") or not path or arguments[index + 2] then
      return fail(options, "usage", "project requires add|change and a path")
    end
    method = "project." .. action
    target, params = options.project or path, path_params(path)
  elseif command == "call" then
    local call_method, parameters = arguments[index], arguments[index + 1]
    if not call_method or arguments[index + 2] then
      return fail(options, "usage", "call requires METHOD and optional JSON parameters")
    end
    method = call_method
    if parameters then
      local decoded, decode_error = json.decode(parameters)
      if not decoded or not is_map(decoded) then return fail(options, "usage", decode_error or "call parameters must be a JSON object") end
      params = decoded
    else
      params = {}
    end
  else
    return fail(options, "usage", "unknown command: " .. command)
  end
  if arguments[index] and command ~= "call" and command ~= "project" then
    return fail(options, "usage", command .. " takes no arguments")
  end
  local result, request_error = request(options, argv0, target, method, params or {})
  if request_error then return fail(options, request_error.code, request_error.message, request_error.retryable) end
  return print_result(options, command, result)
end

return cli
