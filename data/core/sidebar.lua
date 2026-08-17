local core = require "core"

---@class core.sidebar
local Sidebar = {
  modes = {},
  node = nil,
  active_mode = nil,
  active_view = nil,
  pending_mode = nil,
  state = nil,
  state_loaded = false,
  visible = true
}

local function root_node()
  return core.root_view and core.root_view.root_node
end

local function attached(view)
  local root = root_node()
  return root and view and root:get_node_for_view(view)
end

function Sidebar:load_state(state)
  self.state = type(state) == "table" and state or nil
  self.state_loaded = self.state ~= nil
  self.pending_mode = self.state and self.state.mode or nil
  self.visible = not self.state or self.state.visible ~= false
end

function Sidebar:has_saved_state()
  return self.state_loaded
end

function Sidebar:register(mode, provider, options)
  assert(type(mode) == "string")
  assert(type(provider) == "function" or type(provider) == "table")
  self.modes[mode] = {
    provider = provider,
    view = type(provider) == "table" and provider or nil,
    on_show = options and options.on_show,
    on_hide = options and options.on_hide,
  }

  -- Keep function providers lazy. A saved mode is the one exception because
  -- it needs to be restored when the provider becomes available.
  local view
  local restore = not options or options.restore ~= false
  if type(provider) == "table" or (self.pending_mode == mode and restore) then
    view = self:get_view(mode)
  end
  if view then
    local node = attached(view)
    local slot = self:find_slot()
    if node and slot and node ~= slot then
      node:remove_view(root_node(), view)
      node = nil
    end
    if node and not self.node then
      self.node = node
    end
    if node and not self.active_mode then
      self.active_mode = mode
      self.active_view = view
      self.visible = self.state_loaded and self.state.visible ~= false
        or view.visible ~= false
      view.visible = self.visible
    end
  end
  if self.pending_mode == mode and restore then
    self:show(mode, { restore = true })
  end
  return view
end

function Sidebar:get_view(mode)
  local entry = self.modes[mode]
  if not entry then return nil end
  if not entry.view then
    local state = self.state and self.state.views and self.state.views[mode]
    entry.view = entry.provider(state)
  end
  return entry.view
end

function Sidebar:is_active(mode)
  return self.active_mode == mode
end

function Sidebar:find_slot()
  if self.node and attached(self.node.active_view) then
    return self.node
  end
  for _, entry in pairs(self.modes) do
    local node = attached(entry.view)
    if node then
      self.node = node
      return node
    end
  end
end

function Sidebar:attach(view)
  local node = core.root_view:get_active_node_default()
  view.node = node:split("left", view, { x = true }, true)
  self.node = view.node
  return self.node
end

function Sidebar:show(mode, options)
  local entry = self.modes[mode]
  if not entry then return nil end
  local view = self:get_view(mode)
  if not view then return nil end
  local legacy_node = attached(view)
  local node = self:find_slot() or self:attach(view)
  if legacy_node and legacy_node ~= node then
    -- This is a migration, not a close. Calling try_close here would make a
    -- view lose its plugin-owned lifecycle state before it is reattached.
    legacy_node:remove_view(core.root_view.root_node, view)
  end
  local previous_active = core.active_view
  local old_view = node.active_view

  if old_view ~= view then
    if entry.on_show then entry.on_show() end
    node:replace_view(view)
    view.node = node
    if old_view then
      local old_entry = self.modes[self.active_mode]
      if old_entry and old_entry.on_hide then old_entry.on_hide() end
      old_view.visible = false
    end
  end

  local visible = true
  if options and options.restore then visible = self.visible end
  self.node = node
  self.active_mode = mode
  self.active_view = view
  self.visible = visible
  view.visible = visible

  if visible then
    core.set_active_view(view)
  elseif previous_active and attached(previous_active) then
    core.set_active_view(previous_active)
  else
    core.set_active_view(core.root_view:get_primary_node().active_view)
  end
  core.redraw = true
  return view
end

function Sidebar:unregister(mode)
  local entry = self.modes[mode]
  if not entry then return false end
  local active = self.active_mode == mode
  self.modes[mode] = nil
  if self.pending_mode == mode then self.pending_mode = nil end
  if active then
    self.active_mode = nil
    self.active_view = nil
    if self.modes.files then self:show("files") end
  end
  return true
end

function Sidebar:unregister_view(view)
  local mode
  local entry
  for name, candidate in pairs(self.modes) do
    if candidate.view == view then
      mode = name
      entry = candidate
      break
    end
  end
  if not entry then return false end

  local active = self.active_view == view
  if type(entry.provider) == "function" then
    entry.view = nil
  else
    self.modes[mode] = nil
  end
  if self.pending_mode == mode then self.pending_mode = nil end
  if active then
    self.active_mode = nil
    self.active_view = nil
    if self.modes.files then self:show("files") end
  end
  core.redraw = true
  return true
end

function Sidebar:toggle(mode)
  if mode and self.active_mode ~= mode then
    return self:show(mode)
  end
  if not self.active_view then
    return self:show(mode or self.pending_mode or "files")
  end
  self.visible = not self.visible
  self.active_view.visible = self.visible
  if self.visible then core.set_active_view(self.active_view) end
  core.redraw = true
  return self.active_view
end

function Sidebar:set_visible(mode, visible)
  local view = self:get_view(mode)
  if not view then return false end
  if self.active_mode == mode then
    self.visible = not not visible
    view.visible = self.visible
    if self.visible then core.set_active_view(view) end
    core.redraw = true
  else
    view.visible = not not visible
  end
  return true
end

function Sidebar:get_state()
  local views = {}
  for mode, entry in pairs(self.modes) do
    if entry.view and entry.view.get_state then
      local state = entry.view:get_state()
      if state then views[mode] = state end
    end
  end
  return {
    mode = self.active_mode or self.pending_mode or "files",
    visible = self.active_view and self.active_view.visible ~= false or self.visible,
    views = views
  }
end

return Sidebar
