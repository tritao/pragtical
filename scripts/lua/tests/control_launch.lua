local Control = require "core.control"
local Discovery = require "core.instance_discovery"
local launch = require "core.control.launch"
local test = require "core.test"

local project_path = system.absolute_path("data/core")

local function run_project_change(response, response_error)
  local old_select = Discovery.select
  local old_new = Control.new
  local calls = {}
  local client = { closed = false }
  function client:request_sync(method, params, timeout)
    calls[#calls + 1] = { method = method, params = params, timeout = timeout }
    if method == "control.hello" then
      return { protocol_version = 1, instance_id = "target" }
    end
    return response, response_error
  end
  function client:close() self.closed = true end

  Discovery.select = function() return { endpoint = "fake" } end
  Control.new = function()
    return {
      connect = function() return client end,
    }
  end
  local forwarded, accepted, forward_error = launch.forward({ project_path }, {
    target_path = project_path,
    directory_mode = "change",
  })
  Discovery.select = old_select
  Control.new = old_new
  return forwarded, accepted, forward_error, calls, client
end

test.describe("control launch forwarding", function()
  test.test("waits for confirmed project changes", function()
    local forwarded, accepted, forward_error, calls, client = run_project_change(
      { path = project_path, status = "confirmed" })
    test.ok(forwarded, forward_error)
    test.ok(accepted[1])
    test.equal(#calls, 2)
    test.equal(calls[2].method, "project.change")
    test.equal(calls[2].timeout, 300)
    test.ok(client.closed)
  end)

  test.test("does not accept a declined or merely requested project change", function()
    local forwarded, accepted, forward_error = run_project_change(nil, {
      code = "permission_denied",
      message = "project change was declined",
    })
    test.not_ok(forwarded)
    test.is_nil(accepted[1])
    test.equal(forward_error, "project change was declined")

    forwarded, accepted, forward_error = run_project_change(
      { path = project_path, status = "requested" })
    test.not_ok(forwarded)
    test.is_nil(accepted[1])
    test.equal(forward_error, "project change was not confirmed")
  end)
end)
