local core = require "core"
local common = require "core.common"
local style = require "core.style"
local View = require "core.view"

---@class core.sidebar
local Sidebar = {
  modes = {},
  node = nil,
  shell = nil,
  active_mode = nil,
  active_view = nil,
  pending_mode = nil,
  state = nil,
  state_loaded = false,
  visible = true,
  sequence = 0,
}

local SidebarShell = View:extend()

function SidebarShell:__tostring() return "SidebarShell" end

function SidebarShell:new(host)
  SidebarShell.super.new(self)
  self.host = host
  self.visible = true
  self.init_size = true
  self.target_size = 0
  self.hovered_mode = nil
  self.tooltip_mode = nil
end

function SidebarShell:get_tab_height()
  return style.font:get_height() + style.padding.y
end

function SidebarShell:get_content_rect()
  local height = math.max(0, self.size.y - self:get_tab_height())
  return self.position.x, self.position.y + self:get_tab_height(), self.size.x, height
end

function SidebarShell:get_tab_widths()
  local modes = self.host:get_modes()
  local widths = {}
  local total = 0
  for index, entry in ipairs(modes) do
    local width = style.font:get_width(entry.label) + style.padding.x * 2
    widths[index] = width
    total = total + width
  end
  if total > self.size.x and #modes > 0 then
    local width = self.size.x / #modes
    for index in ipairs(modes) do widths[index] = width end
  end
  return modes, widths
end

function SidebarShell:get_tab_at(x, y)
  if y < self.position.y or y >= self.position.y + self:get_tab_height() then
    return nil
  end
  local modes, widths = self:get_tab_widths()
  local offset = self.position.x
  for index, width in ipairs(widths) do
    if x >= offset and x < offset + width then
      return modes[index].mode
    end
    offset = offset + width
  end
end

function SidebarShell:is_truncated(entry, width)
  return style.font:get_width(entry.label) + style.padding.x * 2 > width
end

function SidebarShell:truncate_label(label, width)
  local available = math.max(0, width - style.padding.x * 2)
  if style.font:get_width(label) <= available then return label end
  local dots_width = style.font:get_width("…")
  local length = label:ulen()
  for index = length, 1, -1 do
    local reduced = label:usub(1, index)
    if style.font:get_width(reduced) + dots_width <= available then
      return reduced .. "…"
    end
  end
  return "…"
end

function SidebarShell:layout_content()
  local view = self.host.active_view
  if not view then return end
  local x, y, w, h = self:get_content_rect()
  if not self.host.visible then w, h = 0, 0 end
  view.position.x, view.position.y = x, y
  view.size.x, view.size.y = w, h
  view.visible = self.host.visible
end

function SidebarShell:on_layout()
  self:layout_content()
end

function SidebarShell:sync_target_size()
  local entry = self.host:get_entry(self.host.active_mode)
  local view = self.host.active_view
  if not entry or not view then return end
  -- A panel may change its preferred width from a configuration callback.
  if view.target_size and view.target_size ~= entry.width then
    entry.width = view.target_size
  end
  self.target_size = entry.width or self.target_size
end

function SidebarShell:set_target_size(axis, value)
  if axis ~= "x" then return end
  local entry = self.host:get_entry(self.host.active_mode)
  if entry then entry.width = value end
  self.target_size = value
  local view = self.host.active_view
  if view and view.set_target_size then view:set_target_size(axis, value) end
  return true
end

function SidebarShell:on_scale_change(new_scale, prev_scale)
  self.host:scale_widths(new_scale, prev_scale)
end

function SidebarShell:update()
  self:sync_target_size()
  local dest = self.host.visible and common.round(self.target_size or 0) or 0
  if self.init_size then
    self.size.x = dest
    self.init_size = false
  elseif self.size.x ~= dest then
    self:move_towards(self.size, "x", dest, nil, "sidebar")
    self.size.x = common.round(self.size.x)
    if math.abs(dest - self.size.x) < 2 then self.size.x = dest end
  end

  self:layout_content()
  local view = self.host.active_view
  if view and view.update then view:update() end
  SidebarShell.super.update(self)
end

function SidebarShell:draw()
  if not self.host.visible or self.size.x <= 0 or self.size.y <= 0 then return end
  self:layout_content()
  self:draw_background(style.background2)

  local tab_height = self:get_tab_height()
  local modes, widths = self:get_tab_widths()
  local x = self.position.x
  local y = self.position.y
  renderer.draw_rect(x, y, self.size.x, tab_height, style.background)
  renderer.draw_rect(x, y + tab_height - style.divider_size,
    self.size.x, style.divider_size, style.divider)

  core.push_clip_rect(x, y, self.size.x, tab_height)
  for index, entry in ipairs(modes) do
    local width = widths[index]
    local active = entry.mode == self.host.active_mode
    local hovered = entry.mode == self.hovered_mode
    if active then
      renderer.draw_rect(x, y, width, tab_height, style.line_highlight)
    elseif hovered then
      local color = { table.unpack(style.line_highlight) }
      color[4] = 160
      renderer.draw_rect(x, y, width, tab_height, color)
    end
    local color = (active or hovered) and style.text or style.dim
    local label = self:truncate_label(entry.label, width)
    common.draw_text(style.font, color, label, "left",
      x + style.padding.x, y + style.padding.y / 2,
      math.max(0, width - style.padding.x * 2), tab_height)
    x = x + width
  end
  core.pop_clip_rect()

  local view = self.host.active_view
  if not view or not self.host.visible then return end
  local cx, cy, cw, ch = self:get_content_rect()
  if cw <= 0 or ch <= 0 then return end
  core.push_clip_rect(cx, cy, cw, ch)
  view:draw()
  core.pop_clip_rect()
end

function SidebarShell:update_hover(x, y)
  local mode = self:get_tab_at(x, y)
  if mode ~= self.hovered_mode then
    self.hovered_mode = mode
    core.redraw = true
  end

  local entry = mode and self.host:get_entry(mode)
  local modes, widths = self:get_tab_widths()
  local index = mode and self.host:get_mode_index(mode)
  local truncated = entry and index and self:is_truncated(entry, widths[index])
  if truncated and mode ~= self.tooltip_mode then
    core.status_view:show_tooltip(entry.label)
    self.tooltip_mode = mode
  elseif not truncated and self.tooltip_mode then
    core.status_view:remove_tooltip()
    self.tooltip_mode = nil
  end
end

function SidebarShell:on_mouse_moved(x, y, dx, dy)
  self:layout_content()
  self:update_hover(x, y)
  if self:get_tab_at(x, y) then return true end
  local view = self.host.active_view
  if not view then return true end
  return view:on_mouse_moved(x, y, dx, dy)
end

function SidebarShell:on_mouse_pressed(button, x, y, clicks)
  self:layout_content()
  local mode = self:get_tab_at(x, y)
  local in_tabs = y >= self.position.y
    and y < self.position.y + self:get_tab_height()
  if mode and button == "left" then
    self.host:show(mode)
    return true
  elseif in_tabs then
    return true
  end
  local view = self.host.active_view
  if not view then return true end
  core.set_active_view(view)
  local processed = view:on_mouse_pressed(button, x, y, clicks)
  if core.active_view ~= view and self.host.visible then core.set_active_view(view) end
  return processed
end

function SidebarShell:on_mouse_released(button, x, y, ...)
  local view = self.host.active_view
  return view and view:on_mouse_released(button, x, y, ...)
end

function SidebarShell:on_mouse_wheel(...)
  self:layout_content()
  local view = self.host.active_view
  return view and view:on_mouse_wheel(...)
end

function SidebarShell:on_touch_moved(...)
  local view = self.host.active_view
  return view and view:on_touch_moved(...)
end

function SidebarShell:on_file_dropped(...)
  local view = self.host.active_view
  return view and view:on_file_dropped(...)
end

function SidebarShell:on_mouse_left()
  if self.tooltip_mode then
    core.status_view:remove_tooltip()
    self.tooltip_mode = nil
  end
  self.hovered_mode = nil
  local view = self.host.active_view
  if view then view:on_mouse_left() end
end

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
  if self.state and self.state.widths then
    for mode, width in pairs(self.state.widths) do
      local entry = self.modes[mode]
      if entry then
        entry.width = width
        if entry.view and entry.view.set_target_size then
          entry.view:set_target_size("x", width)
        end
      end
    end
  end
end

function Sidebar:has_saved_state()
  return self.state_loaded
end

function Sidebar:get_entry(mode)
  return mode and self.modes[mode] or nil
end

function Sidebar:get_modes()
  local modes = {}
  for mode, entry in pairs(self.modes) do
    if entry.visible then modes[#modes + 1] = entry end
  end
  table.sort(modes, function(a, b)
    if a.order ~= b.order then return a.order < b.order end
    if a.registered_at ~= b.registered_at then
      return a.registered_at < b.registered_at
    end
    return a.mode < b.mode
  end)
  return modes
end

function Sidebar:get_mode_index(mode)
  for index, entry in ipairs(self:get_modes()) do
    if entry.mode == mode then return index end
  end
end

function Sidebar:register(mode, provider, options)
  assert(type(mode) == "string")
  assert(type(provider) == "function" or type(provider) == "table")
  options = options or {}
  self.sequence = self.sequence + 1
  local old = self.modes[mode]
  local was_active = self.active_mode == mode
  local entry = {
    mode = mode,
    provider = provider,
    view = type(provider) == "table" and provider or nil,
    label = options.label or mode,
    order = options.order or 100,
    visible = options.visible ~= false,
    restore = options.restore ~= false,
    width = self.state and self.state.widths and self.state.widths[mode]
      or options.width or (old and old.width),
    on_show = options.on_show,
    on_hide = options.on_hide,
    registered_at = old and old.registered_at or self.sequence,
  }
  self.modes[mode] = entry

  local view = entry.view
  if view then self:initialize_entry(entry, view) end

  -- Keep function providers lazy. A saved mode is the one exception because
  -- it needs to be restored when the provider becomes available.
  if self.pending_mode == mode and entry.restore then
    self:show(mode, { restore = true })
  elseif was_active then
    self.active_view = nil
    self:show(mode)
  elseif not self.active_mode then
    self:show_fallback()
  end
  core.redraw = true
  return view
end

function Sidebar:initialize_entry(entry, view)
  if entry.width == nil then
    entry.width = view.target_size
      or (view.size and view.size.x > 0 and view.size.x)
      or 200 * SCALE
  end
  if view.set_target_size then view:set_target_size("x", entry.width) end
  if self.active_mode == entry.mode then view.visible = self.visible end
end

function Sidebar:get_view(mode)
  local entry = self.modes[mode]
  if not entry then return nil end
  if not entry.view then
    local state = self.state and self.state.views and self.state.views[mode]
    entry.view = entry.provider(state)
    if entry.view then self:initialize_entry(entry, entry.view) end
  end
  return entry.view
end

function Sidebar:is_active(mode)
  return self.active_mode == mode
end

function Sidebar:find_slot()
  if self.shell then
    local node = attached(self.shell)
    if node then
      self.node = node
      return node
    end
  end
  self.node = nil
end

function Sidebar:attach_shell(view)
  local legacy_node = attached(view)
  local shell = self.shell or SidebarShell(self)
  local node
  if legacy_node and legacy_node.type == "leaf" then
    legacy_node:replace_view(shell)
    node = legacy_node
  else
    local parent = core.root_view:get_active_node_default()
    node = parent:split("left", shell, { x = true }, true)
  end
  shell.node = node
  self.shell = shell
  self.node = node
  return node
end

-- Retain the old attachment entry point for providers that still call it.
-- The returned node now contains the shared shell rather than the provider
-- view itself.
function Sidebar:attach(view)
  local node = self:find_slot()
  if not node then node = self:attach_shell(view) end
  return node
end

function Sidebar:show_fallback()
  local mode = self.modes.files and self.modes.files.visible and "files"
  if not mode then
    local modes = self:get_modes()
    mode = modes[1] and modes[1].mode
  end
  if mode then return self:show(mode) end
end

function Sidebar:capture_width(mode)
  local entry = self.modes[mode]
  if entry and self.shell and self.active_mode == mode then
    entry.width = self.shell.target_size or entry.width
  end
end

function Sidebar:show(mode, options)
  local entry = self.modes[mode]
  if not entry or not entry.visible then return nil end
  local view = self:get_view(mode)
  if not view then return nil end
  local old_mode = self.active_mode
  local old_view = self.active_view
  if old_mode and old_mode ~= mode then self:capture_width(old_mode) end

  -- Older providers may still have attached themselves directly to a node.
  -- Once the shell exists, remove that legacy attachment so switching cannot
  -- leave a second sidebar pane behind.
  local legacy_node = attached(view)
  if legacy_node and legacy_node ~= self.node and self.shell then
    legacy_node:remove_view(root_node(), view)
  end
  local node = self:find_slot()
  if not node then node = self:attach_shell(view) end
  self.shell.target_size = entry.width or view.target_size or view.size.x or 0
  self.node = node

  if old_mode ~= mode then
    local old_entry = old_mode and self.modes[old_mode]
    if old_entry and old_entry.on_hide then old_entry.on_hide() end
    if old_view then old_view.visible = false end
    if entry.on_show then entry.on_show() end
  end

  self.active_mode = mode
  self.active_view = view
  view.visible = self.visible
  self.shell.visible = true
  self.shell:layout_content()

  if self.visible then
    core.set_active_view(view)
  elseif core.active_view == old_view then
    core.set_active_view(core.root_view:get_primary_node().active_view)
  end
  core.redraw = true
  return view
end

function Sidebar:unregister(mode)
  local entry = self.modes[mode]
  if not entry then return false end
  local active = self.active_mode == mode
  local view = entry.view
  if view then
    local node = attached(view)
    if node and node ~= self.node then node:remove_view(root_node(), view) end
  end
  self.modes[mode] = nil
  if self.pending_mode == mode then self.pending_mode = nil end
  if active then
    self.active_mode = nil
    self.active_view = nil
    self:show_fallback()
    if not self.active_mode and self.shell then self.shell.target_size = 0 end
    if not self.active_mode and core.active_view == view then
      core.set_active_view(core.root_view:get_primary_node().active_view)
    end
  end
  core.redraw = true
  return true
end

function Sidebar:unregister_view(view)
  local mode, entry
  for name, candidate in pairs(self.modes) do
    if candidate.view == view then
      mode, entry = name, candidate
      break
    end
  end
  if not entry then return false end

  local active = self.active_view == view
  local node = attached(view)
  if node and node ~= self.node then node:remove_view(root_node(), view) end
  if type(entry.provider) == "function" then
    entry.view = nil
  else
    self.modes[mode] = nil
  end
  if self.pending_mode == mode then self.pending_mode = nil end
  if active then
    self.active_mode = nil
    self.active_view = nil
    self:show_fallback()
    if not self.active_mode and core.active_view == view then
      core.set_active_view(core.root_view:get_primary_node().active_view)
    end
  end
  core.redraw = true
  return true
end

function Sidebar:toggle(mode)
  if mode and self.active_mode ~= mode then return self:show(mode) end
  if not self.active_view then
    return self:show(mode or self.pending_mode or "files") or self:show_fallback()
  end
  self.visible = not self.visible
  self.active_view.visible = self.visible
  if self.visible then
    core.set_active_view(self.active_view)
  elseif core.active_view == self.active_view then
    core.set_active_view(core.root_view:get_primary_node().active_view)
  end
  core.redraw = true
  return self.active_view
end

function Sidebar:set_visible(mode, visible)
  local view = self:get_view(mode)
  if not view then return false end
  if self.active_mode == mode then
    self.visible = not not visible
    view.visible = self.visible
    if self.visible then
      core.set_active_view(view)
    elseif core.active_view == view then
      core.set_active_view(core.root_view:get_primary_node().active_view)
    end
    core.redraw = true
  else
    view.visible = not not visible
  end
  return true
end

function Sidebar:scale_widths(new_scale, prev_scale)
  local ratio = new_scale / prev_scale
  for _, entry in pairs(self.modes) do
    if entry.width then entry.width = entry.width * ratio end
    if entry.view and entry.view.on_scale_change then
      entry.view:on_scale_change(new_scale, prev_scale)
    end
  end
end

function Sidebar:get_state()
  local views, widths = {}, {}
  for mode, entry in pairs(self.modes) do
    if entry.width then widths[mode] = entry.width end
    if entry.view and entry.view.get_state then
      local state = entry.view:get_state()
      if state then views[mode] = state end
    elseif self.state and self.state.views and self.state.views[mode] then
      -- Keep lazy providers' state until they are first shown.
      views[mode] = self.state.views[mode]
    end
  end
  return {
    mode = self.active_mode or self.pending_mode or "files",
    visible = self.active_view and self.active_view.visible ~= false or self.visible,
    views = views,
    widths = widths,
  }
end

return Sidebar
