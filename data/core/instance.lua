local discovery = require "core.instance_discovery"

local Instance = {}
Instance.__index = Instance

local function new_id()
  local stamp = math.floor((system.get_time() or os.clock()) * 1000000)
  return string.format("%x-%x", system.get_process_id(), stamp % 0xffffffff)
end

local function endpoint_for(id)
  local paths = discovery.paths()
  if PLATFORM == "Windows" then
    return "\\\\.\\pipe\\pragtical-" .. id
  end
  return paths.sockets .. PATHSEP .. id .. ".sock"
end

function Instance.new(options)
  options = options or {}
  local self = setmetatable({}, Instance)
  self.instance_id = options.instance_id or new_id()
  self.pid = system.get_process_id()
  self.started_at = os.time()
  self.endpoint = options.endpoint or endpoint_for(self.instance_id)
  self.project_roots = options.project_roots or {}
  self.protocol_version = 1
  self.version = 1
  self.published_path = nil
  return self
end

function Instance:descriptor()
  return {
    version = self.version,
    instance_id = self.instance_id,
    pid = self.pid,
    endpoint = self.endpoint,
    started_at = self.started_at,
    project_roots = self.project_roots,
    protocol_version = self.protocol_version,
  }
end

function Instance:update_projects(projects)
  self.project_roots = {}
  for _, project in ipairs(projects or {}) do
    if type(project) == "string" then
      self.project_roots[#self.project_roots + 1] = project
    elseif type(project) == "table" and type(project.path) == "string" then
      self.project_roots[#self.project_roots + 1] = project.path
    end
  end
  if self.published_path then return self:publish() end
end

function Instance:publish()
  local path, err = discovery.publish(self:descriptor())
  if path then self.published_path = path end
  return path, err
end

function Instance:remove()
  if self.published_path then discovery.remove(self.instance_id) end
  self.published_path = nil
end

return Instance
