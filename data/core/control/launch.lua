local discovery = require "core.instance_discovery"
local Control = require "core.control"

local launch = {}

local function error_message(error)
  return type(error) == "table" and error.message or tostring(error or "forwarding failed")
end

function launch.forward(paths, options)
  options = options or {}
  if #paths == 0 or options.new_instance then return false, {} end
  local transport_available, transport = pcall(require, "local_transport")
  if not transport_available then return false, {} end

  local target = options.target_path or paths[1]
  local descriptor, selection_error = discovery.select(target, {
    transport = transport,
    instance_id = options.instance_id,
    require_project = not options.reuse_instance and not options.instance_id
      and not options.directory_mode,
  })
  if not descriptor then return false, {}, selection_error end

  local control = Control.new()
  local client, connect_error = control:connect(descriptor.endpoint, {
    client_id = "launcher:" .. tostring(system.get_process_id()),
  })
  if not client then return false, {}, connect_error end
  local hello, hello_error = client:request_sync("control.hello", {
    client_id = "launcher:" .. tostring(system.get_process_id()),
  })
  if not hello then
    client:close()
    return false, {}, hello_error
  end
  if hello.protocol_version ~= 1 or type(hello.instance_id) ~= "string" then
    client:close()
    return false, {}, {
      code = "unsupported_version",
      message = "control endpoint returned an incompatible hello response",
      retryable = false,
    }
  end

  local accepted = {}
  local function request(index, method, params)
    local _, request_error = client:request_sync(method, params)
    if request_error then return nil, error_message(request_error) end
    accepted[index] = true
    return true
  end

  local target_info = system.get_file_info(target)
  if target_info and target_info.type == "dir"
      and options.directory_mode then
    local method = options.directory_mode == "add" and "project.add" or "project.change"
    local ok, request_error = request(1, method, { path = target })
    if not ok then client:close(); return false, accepted, request_error end
  else
    for index, path in ipairs(paths) do
      local info = system.get_file_info(path)
      if info and info.type == "dir" then
        local ok, request_error = request(index, "window.focus", {})
        if not ok then client:close(); return false, accepted, request_error end
      else
        local ok, request_error = request(index, "editor.open", { path = path })
        if not ok then client:close(); return false, accepted, request_error end
      end
    end
  end
  local focused, focus_error = client:request_sync("window.focus", {})
  client:close()
  if focus_error then return false, accepted, error_message(focus_error) end
  return true, accepted
end

return launch
