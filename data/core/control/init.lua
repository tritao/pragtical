local core = require "core"
local style = require "core.style"
local Client = require "core.control.client"
local Errors = require "core.control.errors"
local Registry = require "core.control.registry"
local Server = require "core.control.server"
local Instance = require "core.instance"
local Discovery = require "core.instance_discovery"

local transport_available, transport = pcall(require, "local_transport")

local Control = {}
Control.__index = Control

local function valid_params(params)
  return type(params) == "table" and params or nil, "params must be a map"
end

local function valid_path(params, name)
  if type(params) ~= "table" or type(params[name or "path"]) ~= "string"
      or params[name or "path"] == "" then
    return nil, (name or "path") .. " is required"
  end
  return { path = params[name or "path"] }
end

local function document_id(doc)
  if not doc.control_document_id then
    doc.control_document_id = string.format("document:%d", #core.docs + 1)
  end
  return doc.control_document_id
end

local function find_document(params)
  for _, doc in ipairs(core.docs) do
    if params.document_id and document_id(doc) == params.document_id then return doc end
    if params.path and doc.abs_filename == params.path then return doc end
  end
end

local function valid_transfer(params)
  if type(params) ~= "table" then return nil, "transfer must be a map" end
  for _, name in ipairs({ "transfer_id", "source_instance_id", "document_id", "path" }) do
    if type(params[name]) ~= "string" or params[name] == "" then
      return nil, name .. " is required"
    end
  end
  if params.modified ~= false then
    return nil, "only saved, unmodified documents can be transferred"
  end
  return {
    transfer_id = params.transfer_id,
    source_instance_id = params.source_instance_id,
    document_id = params.document_id,
    path = params.path,
    modified = false,
  }
end

local function show_transfer_error(message)
  if core.status_view then
    core.status_view:show_message("!", style.error, message)
  end
end

function Control.new(options)
  options = options or {}
  local self = setmetatable({
    registry = Registry.new(),
    instance = Instance.new(options.instance),
    server = nil,
    peer_clients = {},
    pending_transfers = {},
    pending_transfer_order = {},
    active_transfers = {},
    transfer_sequence = 0,
    available = transport_available,
    options = {
      max_frame_size = options.max_frame_size or 16 * 1024 * 1024,
      max_queued_bytes = options.max_queued_bytes or 8 * 1024 * 1024,
      max_accepts_per_poll = options.max_accepts_per_poll or 32,
      max_requests_per_poll = options.max_requests_per_poll or 32,
      max_messages_per_poll = options.max_messages_per_poll or 32,
      frame_timeout = options.frame_timeout or 10,
      idle_timeout = options.idle_timeout or 300,
      request_timeout = options.request_timeout or 10,
      development = options.development == true,
    },
  }, Control)
  self:_register_defaults()
  return self
end

function Control:_register_defaults()
  self:register {
    method = "control.hello",
    validate = function(params)
      params = params or {}
      if type(params) ~= "table" then return nil, "params must be a map" end
      return { client_id = type(params.client_id) == "string" and params.client_id or nil }
    end,
    execute = function(params)
      return {
        protocol_version = 1,
        instance_id = self.instance.instance_id,
        capabilities = {
          "control.ping", "instance.status", "window.focus", "editor.open",
          "editor.documents", "editor.save", "project.add", "project.change",
          "tab.drag.start", "tab.drag.offer", "tab.drag.accept",
          "tab.drag.complete", "tab.drag.cancel",
        },
      }
    end,
  }
  self:register {
    method = "control.ping",
    validate = valid_params,
    execute = function() return { ok = true } end,
  }
  self:register {
    method = "instance.status",
    validate = valid_params,
    execute = function() return self.instance:descriptor() end,
  }
  self:register {
    method = "window.focus",
    validate = valid_params,
    execute = function()
      if core.window then
        if system.get_window_mode(core.window) == "minimized" then
          system.set_window_mode(core.window, "normal")
        end
        system.raise_window(core.window)
      end
      core.redraw = true
      return { focused = true }
    end,
  }
  self:register {
    method = "editor.open",
    validate = function(params) return valid_path(params) end,
    execute = function(params)
      local absolute = system.absolute_path(params.path) or params.path
      core.open_file(absolute)
      core.redraw = true
      self:publish("document.opened", { path = absolute })
      return { path = absolute }
    end,
  }
  self:register {
    method = "editor.documents",
    validate = valid_params,
    execute = function()
      local result = {}
      for _, doc in ipairs(core.docs) do
        result[#result + 1] = {
          document_id = document_id(doc),
          path = doc.abs_filename,
          modified = doc:is_dirty(),
          saved = doc.abs_filename ~= nil,
        }
      end
      return { documents = result }
    end,
  }
  self:register {
    method = "editor.save",
    validate = function(params)
      if type(params) ~= "table"
          or (type(params.path) ~= "string" and type(params.document_id) ~= "string") then
        return nil, "path or document_id is required"
      end
      return params
    end,
    execute = function(params)
      local doc = find_document(params)
      if not doc then return nil, Errors.new("not_found", "document was not found", false) end
      if not doc.abs_filename then
        return nil, Errors.new("invalid_argument", "document has no path", false)
      end
      doc:save()
      return { document_id = document_id(doc), path = doc.abs_filename, modified = false }
    end,
  }
  self:register {
    method = "project.add",
    validate = function(params) return valid_path(params) end,
    execute = function(params)
      local path = system.absolute_path(params.path) or params.path
      local info = system.get_file_info(path)
      if not info or info.type ~= "dir" then
        return nil, Errors.new("not_found", "project directory was not found", false)
      end
      local project = core.add_project(path)
      self:update_instance()
      self:publish("project.changed", { path = project.path })
      return { path = project.path }
    end,
  }
  self:register {
    method = "project.change",
    validate = function(params) return valid_path(params) end,
    execute = function(params)
      local path = system.absolute_path(params.path) or params.path
      local info = system.get_file_info(path)
      if not info or info.type ~= "dir" then
        return nil, Errors.new("not_found", "project directory was not found", false)
      end
      core.open_project(path)
      return { path = path }
    end,
  }
  self:register {
    method = "tab.drag.offer",
    validate = valid_transfer,
    execute = function(params)
      if params.source_instance_id == self.instance.instance_id then
        return nil, Errors.new("invalid_argument", "a tab cannot be offered to its source", false)
      end
      local info = system.get_file_info(params.path)
      if not info or info.type ~= "file" then
        return nil, Errors.new("not_found", "transferred document was not found", false)
      end
      self.pending_transfers[params.transfer_id] = params
      self.pending_transfer_order[#self.pending_transfer_order + 1] = params.transfer_id
      core.redraw = true
      self:publish("tab.drag.offer", params)
      return { offered = true, transfer_id = params.transfer_id }
    end,
  }
  self:register {
    method = "tab.drag.cancel",
    validate = valid_transfer,
    execute = function(params)
      self.pending_transfers[params.transfer_id] = nil
      self:publish("tab.drag.cancel", params)
      return { cancelled = true, transfer_id = params.transfer_id }
    end,
  }
  self:register {
    method = "tab.drag.complete",
    validate = valid_transfer,
    execute = function(params)
      local doc = self.active_transfers[params.transfer_id]
      if not doc or doc.abs_filename ~= params.path
          or document_id(doc) ~= params.document_id then
        return nil, Errors.new("not_found", "tab transfer is no longer active", false)
      end
      if doc:is_dirty() or not doc.abs_filename then
        self.active_transfers[params.transfer_id] = nil
        return nil, Errors.new("invalid_argument", "modified documents cannot be transferred", false)
      end
      for _, view in ipairs(core.get_views_referencing_doc(doc)) do
        local node = core.root_view.root_node:get_node_for_view(view)
        if node then node:close_view(core.root_view.root_node, view) end
      end
      self.active_transfers[params.transfer_id] = nil
      self:_close_transfer_peers(params.transfer_id)
      self:publish("tab.drag.complete", params)
      return { closed = true, transfer_id = params.transfer_id }
    end,
  }
end

function Control:register(definition)
  return self.registry:register(definition)
end

function Control:update_instance()
  self.instance:update_projects(core.projects)
end

function Control:_close_transfer_peers(transfer_id)
  for index = #self.peer_clients, 1, -1 do
    local peer = self.peer_clients[index]
    if peer.transfer_id == transfer_id then
      peer.client:close()
      table.remove(self.peer_clients, index)
    end
  end
end

function Control:_queue_peer_transfer(peer, transfer)
  local request, request_error = peer.client:request("control.hello", {
    client_id = "instance:" .. self.instance.instance_id,
  }, function(result, error_result)
    if error_result or not result or result.protocol_version ~= 1
        or type(result.instance_id) ~= "string" then
      peer.client:close()
      peer.failed = true
      return
    end
    local offered, offer_error = peer.client:request("tab.drag.offer", transfer,
      function(_, response_error)
        if response_error then peer.failed = true end
      end)
    if not offered then peer.failed = true end
  end)
  if not request then
    peer.failed = true
    return nil, request_error
  end
  return true
end

function Control:begin_tab_drag(doc)
  if not self.server or not doc then return nil end
  if not doc.abs_filename or doc:is_dirty() then
    show_transfer_error("Only saved, unmodified documents can move between instances")
    return nil
  end
  self.transfer_sequence = self.transfer_sequence + 1
  local transfer = {
    transfer_id = self.instance.instance_id .. ":transfer:" .. tostring(self.transfer_sequence),
    source_instance_id = self.instance.instance_id,
    document_id = document_id(doc),
    path = doc.abs_filename,
    modified = false,
  }
  self.active_transfers[transfer.transfer_id] = doc
  self:publish("tab.drag.start", transfer)
  for _, descriptor in ipairs(Discovery.list(transport)) do
    if descriptor.instance_id ~= self.instance.instance_id then
      local client = self:connect(descriptor.endpoint, {
        client_id = "instance:" .. self.instance.instance_id,
        request_timeout = 2,
      })
      if client then
        local peer = {
          client = client,
          transfer_id = transfer.transfer_id,
        }
        self.peer_clients[#self.peer_clients + 1] = peer
        self:_queue_peer_transfer(peer, transfer)
      end
    end
  end
  return transfer
end

function Control:pending_tab_drag()
  while #self.pending_transfer_order > 0 do
    local transfer_id = table.remove(self.pending_transfer_order, 1)
    local transfer = self.pending_transfers[transfer_id]
    if transfer then return transfer end
  end
end

function Control:_complete_tab_drag_at_destination(transfer)
  local info = system.get_file_info(transfer.path)
  if not info or info.type ~= "file" then
    return nil, Errors.new("not_found", "transferred document was not found", false)
  end
  local ok, open_error = pcall(core.open_file, transfer.path)
  if not ok then
    return nil, Errors.new("internal", open_error, false)
  end
  self:publish("tab.drag.accept", transfer)

  local descriptor, selection_error = Discovery.select(nil, {
    transport = transport,
    instance_id = transfer.source_instance_id,
  })
  if not descriptor then return nil, Errors.new(selection_error or "not_found",
    "source instance is unavailable", true) end
  local client, connect_error = self:connect(descriptor.endpoint, {
    client_id = "instance:" .. self.instance.instance_id,
    request_timeout = 2,
  })
  if not client then return nil, Errors.new("timeout", tostring(connect_error), true) end
  local peer = {
    client = client,
    transfer_id = transfer.transfer_id,
  }
  self.peer_clients[#self.peer_clients + 1] = peer
  local hello, hello_error = client:request("control.hello", {
    client_id = "instance:" .. self.instance.instance_id,
  }, function(result, error_result)
    if error_result or not result or result.protocol_version ~= 1
        or type(result.instance_id) ~= "string" then
      peer.failed = true
      return
    end
    local complete = client:request("tab.drag.complete", transfer, function(_, complete_error)
      peer.failed = complete_error ~= nil
      client:close()
    end)
    if not complete then peer.failed = true end
  end)
  if not hello then
    client:close()
    return nil, hello_error
  end
  return { accepted = true, transfer_id = transfer.transfer_id }
end

function Control:accept_tab_drag(transfer_id)
  local transfer = self.pending_transfers[transfer_id]
  if not transfer then return nil, Errors.new("not_found", "tab offer is no longer available", false) end
  self.pending_transfers[transfer_id] = nil
  local result, error_result = self:_complete_tab_drag_at_destination(transfer)
  if not result then
    self.pending_transfers[transfer_id] = transfer
    self.pending_transfer_order[#self.pending_transfer_order + 1] = transfer_id
    return nil, error_result
  end
  return result
end

function Control:finish_tab_drag(transfer)
  if not transfer then return end
  if self.active_transfers[transfer.transfer_id] then
    self.active_transfers[transfer.transfer_id] = nil
    self:publish("tab.drag.cancel", transfer)
    for _, peer in ipairs(self.peer_clients) do
      if peer.transfer_id == transfer.transfer_id and not peer.failed then
        local cancel = peer.client:request("tab.drag.cancel", transfer,
          function(_, error_result)
            peer.failed = error_result ~= nil
            peer.done = true
            peer.client:close()
          end, 2)
        if not cancel then
          peer.failed = true
          peer.done = true
          peer.client:close()
        end
      end
    end
  end
  for index = #self.peer_clients, 1, -1 do
    local peer = self.peer_clients[index]
    if peer.transfer_id == transfer.transfer_id and (peer.done or peer.failed) then
      peer.client:close()
      table.remove(self.peer_clients, index)
    end
  end
end

function Control:start()
  self:update_instance()
  if not self.available then return nil, "unsupported" end
  local runtime_ready, runtime_error = Discovery.ensure_runtime()
  if not runtime_ready then return nil, runtime_error end
  local server, err = Server.new(transport, self.instance.endpoint, self.registry,
    self.options)
  if not server then return nil, err end
  self.server = server
  local published, publish_error = self.instance:publish()
  if not published then
    self.server:close()
    self.server = nil
    return nil, publish_error
  end
  return true
end

function Control:poll()
  local count = self.server and self.server:poll() or 0
  for index = #self.peer_clients, 1, -1 do
    local peer = self.peer_clients[index]
    local _, error_message = peer.client:poll()
    if peer.done or peer.failed or error_message then
      peer.client:close()
      table.remove(self.peer_clients, index)
    end
  end
  return count
end

function Control:publish(name, data)
  if self.server then return self.server:publish(name, data) end
end

function Control:connect(endpoint, options)
  if not self.available then return nil, "unsupported" end
  options = options or {}
  options.request_timeout = options.request_timeout or self.options.request_timeout
  options.max_frame_size = options.max_frame_size or self.options.max_frame_size
  options.max_queued_bytes = options.max_queued_bytes or self.options.max_queued_bytes
  options.max_messages_per_poll = options.max_messages_per_poll or 32
  return Client.connect(transport, endpoint, options)
end

function Control:stop()
  for index = #self.peer_clients, 1, -1 do
    self.peer_clients[index].client:close()
    table.remove(self.peer_clients, index)
  end
  if self.server then self.server:close(); self.server = nil end
  self.instance:remove()
end

return Control
