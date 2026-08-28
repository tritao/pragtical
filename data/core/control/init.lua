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

local function document_id(control, doc)
  if not doc.control_document_id then
    control.document_sequence = control.document_sequence + 1
    doc.control_document_id = string.format("document:%d", control.document_sequence)
  end
  return doc.control_document_id
end

local function find_document(control, params)
  for _, doc in ipairs(core.docs) do
    if params.document_id and document_id(control, doc) == params.document_id then return doc end
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
    destination_instance_id = params.destination_instance_id,
  }
end

local function valid_destination_transfer(params)
  local transfer, validation_error = valid_transfer(params)
  if not transfer then return nil, validation_error end
  if type(params.destination_instance_id) ~= "string"
      or params.destination_instance_id == "" then
    return nil, "destination_instance_id is required"
  end
  transfer.destination_instance_id = params.destination_instance_id
  return transfer
end

local function transfer_for_destination(transfer, destination_instance_id)
  local result = {}
  for key, value in pairs(transfer) do result[key] = value end
  result.destination_instance_id = destination_instance_id
  return result
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
    incoming_transfers = {},
    document_sequence = 0,
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
          document_id = document_id(self, doc),
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
      local doc = find_document(self, params)
      if not doc then return nil, Errors.new("not_found", "document was not found", false) end
      if not doc.abs_filename then
        return nil, Errors.new("invalid_argument", "document has no path", false)
      end
      doc:save()
      return { document_id = document_id(self, doc), path = doc.abs_filename, modified = false }
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
      return { path = path, status = "requested" }
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
      if self.pending_transfers[params.transfer_id]
          or self.incoming_transfers[params.transfer_id] then
        return nil, Errors.new("busy", "tab transfer is already pending", true)
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
      if params.destination_instance_id == self.instance.instance_id then
        local incoming = self.incoming_transfers[params.transfer_id]
        self.pending_transfers[params.transfer_id] = nil
        if incoming then
          self:_cancel_incoming_transfer(incoming)
        end
      elseif params.source_instance_id == self.instance.instance_id
          and params.destination_instance_id then
        local active = self.active_transfers[params.transfer_id]
        if active and (not active.destination_instance_id
            or active.destination_instance_id == params.destination_instance_id) then
          self.active_transfers[params.transfer_id] = nil
          active.phase = "canceled"
        end
      end
      self.pending_transfers[params.transfer_id] = nil
      self:publish("tab.drag.cancel", params)
      return { cancelled = true, transfer_id = params.transfer_id }
    end,
  }
  self:register {
    method = "tab.drag.accept",
    validate = valid_destination_transfer,
    execute = function(params)
      if params.source_instance_id ~= self.instance.instance_id then
        return nil, Errors.new("permission_denied", "transfer source does not match this instance", false)
      end
      local active = self.active_transfers[params.transfer_id]
      if not active or active.transfer.path ~= params.path
          or active.transfer.document_id ~= params.document_id then
        return nil, Errors.new("not_found", "tab transfer is no longer active", false)
      end
      if active.phase == "accepted" or active.phase == "completing" then
        if active.destination_instance_id == params.destination_instance_id then
          return { accepted = true, transfer_id = params.transfer_id }
        end
        return nil, Errors.new("busy", "tab transfer already has a destination", true)
      end
      if active.phase ~= "offered" then
        return nil, Errors.new("not_found", "tab transfer is no longer available", false)
      end
      active.phase = "accepted"
      active.destination_instance_id = params.destination_instance_id
      self:_cancel_transfer_peers(params.transfer_id, params.destination_instance_id)
      self:publish("tab.drag.accept", params)
      return { accepted = true, transfer_id = params.transfer_id }
    end,
  }
  self:register {
    method = "tab.drag.complete",
    validate = valid_destination_transfer,
    execute = function(params)
      local active = self.active_transfers[params.transfer_id]
      local doc = active and active.document
      if not active or active.phase ~= "accepted"
          or active.destination_instance_id ~= params.destination_instance_id
          or doc.abs_filename ~= params.path
          or document_id(self, doc) ~= params.document_id then
        return nil, Errors.new("not_found", "tab transfer is no longer active", false)
      end
      if doc:is_dirty() or not doc.abs_filename then
        self.active_transfers[params.transfer_id] = nil
        active.phase = "canceled"
        self:publish("tab.drag.cancel", params)
        return nil, Errors.new("invalid_argument", "modified documents cannot be transferred", false)
      end
      active.phase = "completing"
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
      -- A cancellation request must be allowed to reach every losing
      -- destination. The winning peer can be closed as soon as the source
      -- document completes.
      if not peer.cancel_requested or peer.done or peer.failed then
        peer.client:close()
        table.remove(self.peer_clients, index)
      end
    end
  end
end

function Control:_send_peer_cancel(peer)
  if peer.failed or peer.done or peer.cancel_sent then return end
  if not peer.instance_id then
    peer.cancel_after_hello = true
    return
  end
  if peer.instance_id == peer.cancel_winner then
    peer.done = true
    peer.client:close()
    return
  end
  peer.cancel_sent = true
  local cancel = peer.client:request("tab.drag.cancel",
    transfer_for_destination(peer.transfer, peer.instance_id),
    function(_, error_result)
      peer.failed = error_result ~= nil
      peer.done = true
    end, 2)
  if not cancel then
    peer.failed = true
    peer.done = true
    peer.client:close()
  end
end

function Control:_cancel_transfer_peers(transfer_id, winner)
  for _, peer in ipairs(self.peer_clients) do
    if peer.transfer_id == transfer_id then
      peer.cancel_requested = true
      peer.cancel_winner = winner
      self:_send_peer_cancel(peer)
    end
  end
end

function Control:_queue_peer_transfer(peer, transfer)
  peer.transfer = transfer
  local request, request_error = peer.client:request("control.hello", {
    client_id = "instance:" .. self.instance.instance_id,
  }, function(result, error_result)
    if error_result or not result or result.protocol_version ~= 1
        or type(result.instance_id) ~= "string" then
      peer.client:close()
      peer.failed = true
      return
    end
    peer.instance_id = result.instance_id
    if peer.cancel_requested then
      self:_send_peer_cancel(peer)
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
    document_id = document_id(self, doc),
    path = doc.abs_filename,
    modified = false,
  }
  self.active_transfers[transfer.transfer_id] = {
    document = doc,
    phase = "offered",
    transfer = transfer,
  }
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
          transfer = transfer,
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

function Control:_restore_pending_transfer(transfer)
  if self.pending_transfers[transfer.transfer_id]
      or self.incoming_transfers[transfer.transfer_id] then return end
  self.pending_transfers[transfer.transfer_id] = transfer
  self.pending_transfer_order[#self.pending_transfer_order + 1] = transfer.transfer_id
end

function Control:_rollback_destination(state)
  if not state.opened_new_view or not state.opened_view then return end
  local node = core.root_view.root_node:get_node_for_view(state.opened_view)
  if node then node:remove_view(core.root_view.root_node, state.opened_view) end
  state.opened_view = nil
  core.redraw = true
end

function Control:_send_destination_cancel(state)
  local peer = state.peer
  if not peer or peer.cancel_sent or peer.done then return end
  peer.cancel_sent = true
  local cancel = peer.client:request("tab.drag.cancel",
    transfer_for_destination(state.transfer, self.instance.instance_id),
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

function Control:_cancel_incoming_transfer(state)
  if state.phase == "canceled" or state.phase == "complete" then return end
  state.phase = "canceled"
  self.incoming_transfers[state.transfer.transfer_id] = nil
  self:_rollback_destination(state)
  if state.peer then
    state.peer.done = true
    state.peer.client:close()
  end
  core.redraw = true
end

function Control:_destination_failed(state, error_result)
  if state.phase == "canceled" or state.phase == "complete" then return end
  local accepted = state.phase == "accepted" or state.phase == "completing"
  state.phase = "canceled"
  self.incoming_transfers[state.transfer.transfer_id] = nil
  self:_rollback_destination(state)
  if accepted then
    -- The source has already entered its accepted phase, so release it
    -- explicitly. It must never infer completion from this failure.
    self:_send_destination_cancel(state)
  elseif state.peer then
    state.peer.done = true
    state.peer.client:close()
  end
  local message = type(error_result) == "table" and error_result.message
    or tostring(error_result or "tab transfer failed")
  show_transfer_error("Tab transfer failed: " .. message)
end

function Control:_complete_tab_drag_at_destination(state)
  local transfer = state.transfer
  local info = system.get_file_info(transfer.path)
  if not info or info.type ~= "file" then
    return nil, Errors.new("not_found", "transferred document was not found", false)
  end

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
    transfer = transfer,
  }
  state.peer = peer
  self.peer_clients[#self.peer_clients + 1] = peer
  local hello, hello_error = client:request("control.hello", {
    client_id = "instance:" .. self.instance.instance_id,
  }, function(result, error_result)
    if state.phase ~= "accepting" then return end
    if error_result or not result or result.protocol_version ~= 1
        or type(result.instance_id) ~= "string" then
      self:_destination_failed(state, error_result or "source hello failed")
      return
    end
    peer.instance_id = result.instance_id
    local accepted = client:request("tab.drag.accept",
      transfer_for_destination(transfer, self.instance.instance_id),
      function(accept_result, accept_error)
        if state.phase ~= "accepting" then return end
        if accept_error or not accept_result or accept_result.accepted ~= true then
          self:_destination_failed(state, accept_error or "source rejected tab transfer")
          return
        end
        state.phase = "accepted"
        local existing_doc = find_document(self, { path = transfer.path })
        local existing_views = existing_doc and core.get_views_referencing_doc(existing_doc) or {}
        local ok, view_or_error = pcall(core.open_file, transfer.path)
        if not ok or not view_or_error then
          self:_destination_failed(state, Errors.new("internal",
            ok and "destination could not open transferred document" or view_or_error, false))
          return
        end
        state.opened_view = view_or_error
        state.opened_new_view = true
        for _, existing_view in ipairs(existing_views) do
          if existing_view == view_or_error then state.opened_new_view = false; break end
        end
        self:publish("tab.drag.accept", transfer)
        state.phase = "completing"
        local complete = client:request("tab.drag.complete",
          transfer_for_destination(transfer, self.instance.instance_id),
          function(_, complete_error)
            if complete_error then
              self:_destination_failed(state, complete_error)
              return
            end
            state.phase = "complete"
            self.incoming_transfers[transfer.transfer_id] = nil
            peer.done = true
            client:close()
          end)
        if not complete then
          self:_destination_failed(state, "could not queue transfer completion")
        end
      end)
    if not accepted then self:_destination_failed(state, "could not queue transfer acceptance") end
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
  local state = { transfer = transfer, phase = "accepting" }
  self.incoming_transfers[transfer_id] = state
  local started, start_error = self:_complete_tab_drag_at_destination(state)
  if not started then
    self.incoming_transfers[transfer_id] = nil
    state.phase = "canceled"
    self:_restore_pending_transfer(transfer)
    return nil, start_error
  end
  return { accepted = true, pending = true, transfer_id = transfer_id }
end

function Control:finish_tab_drag(transfer)
  if not transfer then return end
  local active = self.active_transfers[transfer.transfer_id]
  if active and active.phase == "offered" then
    -- Once the source has processed tab.drag.accept, the accepted/completing
    -- phases are terminal from the mouse interaction's point of view. A
    -- release can cancel only the still-unclaimed offer.
    active.phase = "canceling"
    self.active_transfers[transfer.transfer_id] = nil
    self:publish("tab.drag.cancel", transfer)
    self:_cancel_transfer_peers(transfer.transfer_id)
    self:_close_transfer_peers(transfer.transfer_id)
  end
  self:_close_transfer_peers(transfer.transfer_id)
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
