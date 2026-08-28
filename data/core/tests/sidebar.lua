local test = require "core.test"
local core = require "core"
local SidebarHost = require "core.sidebar"
local View = require "core.view"

local TestView = View:extend()

function TestView:new(state)
  TestView.super.new(self)
  self.target_size = 180 * SCALE
  self.value = state and state.value or 0
end

function TestView:set_target_size(axis, value)
  if axis == "x" then
    self.target_size = value
    return true
  end
end

function TestView:get_state()
  return { value = self.value }
end

local sequence = 0

local function mode_name(prefix)
  sequence = sequence + 1
  return "core-sidebar-" .. prefix .. "-" .. tostring(sequence)
end

test.describe("Core sidebar", function()
  local previous_mode
  local previous_visible
  local registered

  test.before_each(function()
    previous_mode = SidebarHost.active_mode
    previous_visible = SidebarHost.visible
    registered = {}
  end)

  test.after_each(function()
    for index = #registered, 1, -1 do
      SidebarHost:unregister(registered[index])
    end
    if previous_mode and SidebarHost.modes[previous_mode] then
      SidebarHost:show(previous_mode)
    else
      SidebarHost:show_fallback()
    end
    if SidebarHost.active_mode and SidebarHost.visible ~= previous_visible then
      SidebarHost:toggle(SidebarHost.active_mode)
    end
  end)

  local function register(name, provider, options)
    registered[#registered + 1] = name
    SidebarHost:register(name, provider, options)
  end

  test.test("sorts visible modes by order and preserves legacy labels", function()
    local first = mode_name("first")
    local second = mode_name("second")
    register(first, function() return TestView() end, {
      label = "First panel",
      order = 80,
    })
    register(second, function() return TestView() end, {
      label = "Second panel",
      order = 70,
    })
    local legacy = mode_name("legacy")
    register(legacy, TestView())

    test.equal(SidebarHost.modes[legacy].label, legacy)
    test.ok(SidebarHost:get_mode_index(second) < SidebarHost:get_mode_index(first))
    test.ok(SidebarHost:get_mode_index(first) < SidebarHost:get_mode_index(legacy))
  end)

  test.test("keeps lazy providers and saved view state independent", function()
    local name = mode_name("lazy")
    local created = 0
    register(name, function(state)
      created = created + 1
      return TestView(state)
    end, { label = "Lazy panel", order = 90 })

    test.equal(created, 0)
    local saved = SidebarHost.state
    SidebarHost:load_state({
      mode = name,
      visible = true,
      views = { [name] = { value = 42 } },
      widths = { [name] = 271 },
    })
    test.equal(created, 0)
    local view = SidebarHost:get_view(name)
    test.equal(created, 1)
    test.equal(view.value, 42)
    test.equal(SidebarHost:get_entry(name).width, 271)
    test.equal(SidebarHost:get_state().views[name].value, 42)
    test.equal(SidebarHost:get_state().widths[name], 271)
    SidebarHost:load_state(saved)
  end)

  test.test("switches tabs without attaching or recreating panel views", function()
    local first = mode_name("switch-first")
    local second = mode_name("switch-second")
    local first_view = TestView()
    local second_view = TestView()
    register(first, first_view, { label = "First", order = 80 })
    register(second, second_view, { label = "Second", order = 90 })

    SidebarHost:show(first)
    core.root_view:update()
    local shell = SidebarHost.shell
    local node = SidebarHost.node
    test.equal(core.root_view.root_node:get_node_for_view(shell), node)
    test.is_nil(core.root_view.root_node:get_node_for_view(first_view))

    SidebarHost:show(second)
    core.root_view:update()
    test.equal(SidebarHost.node, node)
    test.equal(SidebarHost.active_view, second_view)
    test.equal(core.root_view.root_node:get_node_for_view(shell), node)
    test.is_nil(core.root_view.root_node:get_node_for_view(first_view))
    test.is_nil(core.root_view.root_node:get_node_for_view(second_view))
    test.equal(second_view.position.y, shell.position.y + shell:get_tab_height())

    local modes, widths = shell:get_tab_widths()
    local offset = shell.position.x
    for index, entry in ipairs(modes) do
      if entry.mode == first then
        shell:on_mouse_pressed("left", offset + widths[index] / 2,
          shell.position.y + shell:get_tab_height() / 2, 1)
        break
      end
      offset = offset + widths[index]
    end
    test.equal(SidebarHost.active_view, first_view)
  end)

  test.test("restores visibility and falls back after unregistering the active mode", function()
    local name = mode_name("fallback")
    register(name, TestView(), { label = "Fallback", order = 5 })
    SidebarHost:show(name)
    SidebarHost:toggle(name)
    test.ok(not SidebarHost.visible)
    test.equal(SidebarHost.active_mode, name)
    SidebarHost:toggle(name)
    test.ok(SidebarHost.visible)

    test.ok(SidebarHost:unregister(name))
    test.equal(SidebarHost.active_mode, "files")
    test.equal(core.root_view.root_node:get_node_for_view(SidebarHost.shell), SidebarHost.node)
  end)
end)
