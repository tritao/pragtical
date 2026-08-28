local common = require "core.common"
local MessagePack = require "core.control.msgpack"

local discovery = {}

local function join(a, b)
  return a .. PATHSEP .. b
end

function discovery.runtime_root()
  local runtime = os.getenv("XDG_RUNTIME_DIR")
  if PLATFORM ~= "Windows" and runtime and runtime ~= "" then
    return join(runtime, "pragtical")
  end
  return join(USERDIR, "runtime")
end

function discovery.paths()
  local root = discovery.runtime_root()
  return {
    root = root,
    instances = join(root, "instances"),
    sockets = join(root, "sockets"),
  }
end

function discovery.ensure_runtime()
  local paths = discovery.paths()
  local ok, err = common.mkdirp(paths.instances)
  if not ok then return nil, err end
  ok, err = common.mkdirp(paths.sockets)
  if not ok then return nil, err end
  return true
end

local function descriptor_path(instance_id)
  return discovery.paths().instances .. PATHSEP .. instance_id .. ".msgpack"
end

local function safe_id(instance_id)
  return type(instance_id) == "string"
    and instance_id:match("^[%w][%w_.-]*$") ~= nil
end

function discovery.read(path)
  if not path then return nil end
  local info = system.get_file_info(path)
  if not info or info.type ~= "file" or info.symlink then return nil end
  local file = io.open(path, "rb")
  if not file then return nil end
  local payload = file:read("*a")
  file:close()
  local ok, value, position = pcall(MessagePack.decode, payload)
  if not ok or position ~= #payload + 1 or type(value) ~= "table" then return nil end
  if value.version ~= 1 or not safe_id(value.instance_id)
      or type(value.pid) ~= "number" or value.pid < 1
      or type(value.endpoint) ~= "string" or value.endpoint == ""
      or type(value.started_at) ~= "number"
      or type(value.protocol_version) ~= "number"
      or type(value.project_roots) ~= "table" then
    return nil
  end
  for _, root in ipairs(value.project_roots) do
    if type(root) ~= "string" or root == "" then return nil end
  end
  return value
end

function discovery.publish(descriptor)
  assert(type(descriptor) == "table", "instance descriptor must be a table")
  assert(safe_id(descriptor.instance_id), "invalid instance id")
  local paths = discovery.paths()
  local ok, err = discovery.ensure_runtime()
  if not ok then return nil, err end
  local payload
  local encoded, encode_error = pcall(MessagePack.encode, descriptor)
  if not encoded then return nil, encode_error end
  payload = encode_error
  local path = descriptor_path(descriptor.instance_id)
  local temporary = path .. ".tmp-" .. tostring(descriptor.pid)
  local file = io.open(temporary, "wb")
  if not file then return nil, "cannot create instance descriptor" end
  file:write(payload)
  file:flush()
  file:close()
  if not os.rename(temporary, path) then
    os.remove(temporary)
    return nil, "cannot publish instance descriptor"
  end
  return path
end

function discovery.remove(instance_id)
  if not safe_id(instance_id) then return false end
  local path = descriptor_path(instance_id)
  local info = system.get_file_info(path)
  if info and not info.symlink then os.remove(path); return true end
  return false
end

local function same_or_belongs(path, root)
  return path == root or common.path_belongs_to(path, root)
end

local function normalized(path)
  if type(path) ~= "string" then return nil end
  local absolute = system.absolute_path(path)
  if absolute then return common.normalize_volume(absolute) end
  local normalized_path = common.normalize_path(path)
  if common.is_absolute_path(normalized_path) then
    return common.normalize_volume(normalized_path)
  end
  return common.normalize_volume(system.getcwd() .. PATHSEP .. normalized_path)
end

local function healthy(descriptor, transport)
  if not transport then return true end
  local ok, connection = pcall(transport.connect, descriptor.endpoint, {
    max_frame_size = 1024 * 1024,
    max_queued_bytes = 1024 * 1024,
  })
  if ok and connection then
    pcall(connection.close, connection)
    return true
  end
  return false
end

function discovery.list(transport)
  local paths = discovery.paths()
  local entries = {}
  for _, filename in ipairs(system.list_dir(paths.instances) or {}) do
    if filename:match("^[%w][%w_.-]*%.msgpack$") then
      local descriptor = discovery.read(join(paths.instances, filename))
      if descriptor then
        if healthy(descriptor, transport) then
          entries[#entries + 1] = descriptor
        else
          discovery.remove(descriptor.instance_id)
        end
      end
    end
  end
  table.sort(entries, function(a, b)
    if a.started_at == b.started_at then return a.instance_id < b.instance_id end
    return a.started_at < b.started_at
  end)
  return entries
end

local function choose(candidates)
  if #candidates == 1 then return candidates[1] end
  if #candidates > 1 then return nil, "ambiguous_target" end
end

function discovery.select(target_path, options)
  options = options or {}
  local entries = discovery.list(options.transport)
  if options.instance_id then
    for _, descriptor in ipairs(entries) do
      if descriptor.instance_id == options.instance_id then return descriptor end
    end
    return nil, "not_found"
  end
  if #entries == 0 then return nil, "not_found" end
  local path = normalized(target_path)
  if path then
    local exact = {}
    local containing = {}
    for _, descriptor in ipairs(entries) do
      local matched = false
      for _, root in ipairs(descriptor.project_roots) do
        root = normalized(root)
        if root == path then
          exact[#exact + 1] = descriptor
          matched = true
          break
        end
      end
      if not matched then
        for _, root in ipairs(descriptor.project_roots) do
          root = normalized(root)
          if root and same_or_belongs(path, root) then
            containing[#containing + 1] = descriptor
            break
          end
        end
      end
    end
    local selected, error = choose(exact)
    if selected or error then return selected, error end
    selected, error = choose(containing)
    if selected or error then return selected, error end
    if options.require_project then return nil, "not_found" end
  end
  if options.only_matching then return nil, "not_found" end
  if #entries == 1 then return entries[1] end
  return entries[1]
end

return discovery
