local Control = require "core.control"
local Discovery = require "core.instance_discovery"
local core = require "core"
local test = require "core.test"

local function new_control()
  return Control.new({ instance = { instance_id = "transfer-source" } })
end

local function fake_document(path)
  return {
    abs_filename = path,
    is_dirty = function() return false end,
  }
end

local function transfer()
  return {
    transfer_id = "transfer-source:transfer:1",
    source_instance_id = "transfer-source",
    document_id = "document:1",
    path = system.absolute_path("data/core/control/init.lua"),
    modified = false,
  }
end

local function fake_client()
  local client = { requests = {}, closed = false }
  function client:request(method, params, callback)
    self.requests[#self.requests + 1] = {
      method = method,
      params = params,
      callback = callback,
    }
    return {}
  end
  function client:close() self.closed = true end
  return client
end

test.describe("control tab transfers", function()
  test.test("mouse release cannot cancel an accepted transfer", function()
    local control = new_control()
    local current = transfer()
    local document = fake_document(current.path)
    local cancel_calls = 0
    function control:_cancel_transfer_peers() cancel_calls = cancel_calls + 1 end
    control.active_transfers[current.transfer_id] = {
      document = document,
      phase = "offered",
      transfer = current,
    }

    local accepted, accept_error = control.registry:dispatch("tab.drag.accept", {
      transfer_id = current.transfer_id,
      source_instance_id = current.source_instance_id,
      document_id = current.document_id,
      path = current.path,
      modified = false,
      destination_instance_id = "transfer-destination",
    })
    test.ok(accepted, accept_error and accept_error.message)
    test.equal(control.active_transfers[current.transfer_id].phase, "accepted")

    control:finish_tab_drag(current)
    test.equal(cancel_calls, 1)
    test.equal(control.active_transfers[current.transfer_id].phase, "accepted")
  end)

  test.test("acceptance cancels every non-winning destination", function()
    local control = new_control()
    local current = transfer()
    local losing = fake_client()
    local winning = fake_client()
    control.peer_clients = {
      {
        client = winning,
        transfer_id = current.transfer_id,
        instance_id = "destination-a",
        transfer = current,
      },
      {
        client = losing,
        transfer_id = current.transfer_id,
        instance_id = "destination-b",
        transfer = current,
      },
    }
    control.active_transfers[current.transfer_id] = {
      document = fake_document(current.path),
      phase = "offered",
      transfer = current,
    }

    local accepted, accept_error = control.registry:dispatch("tab.drag.accept", {
      transfer_id = current.transfer_id,
      source_instance_id = current.source_instance_id,
      document_id = current.document_id,
      path = current.path,
      modified = false,
      destination_instance_id = "destination-a",
    })
    test.ok(accepted, accept_error and accept_error.message)
    test.ok(winning.closed)
    test.equal(#losing.requests, 1)
    test.equal(losing.requests[1].method, "tab.drag.cancel")
    test.equal(losing.requests[1].params.destination_instance_id, "destination-b")
  end)

  test.test("destination waits for source acceptance before opening", function()
    local control = new_control()
    local current = transfer()
    local client = fake_client()
    local old_select = Discovery.select
    local old_docs = core.docs
    local before_count = #old_docs

    Discovery.select = function() return { instance_id = "transfer-source", endpoint = "fake" } end
    function control:connect() return client end
    control.pending_transfers[current.transfer_id] = current

    local result, accept_error = control:accept_tab_drag(current.transfer_id)
    test.ok(result, accept_error and accept_error.message)
    test.equal(#client.requests, 1)
    test.equal(client.requests[1].method, "control.hello")
    test.equal(#core.docs, before_count)

    client.requests[1].callback({ protocol_version = 1, instance_id = "transfer-source" })
    test.equal(#client.requests, 2)
    test.equal(client.requests[2].method, "tab.drag.accept")
    test.equal(#core.docs, before_count)

    client:close()
    control.incoming_transfers[current.transfer_id] = nil
    core.docs = old_docs
    Discovery.select = old_select
  end)

  test.test("document IDs remain unique after documents close", function()
    local control = new_control()
    local old_docs = core.docs
    local first = fake_document("first.c")
    local second = fake_document("second.c")
    local third = fake_document("third.c")
    core.docs = { first, second }
    local first_result = control.registry:dispatch("editor.documents", {}, {})
    core.docs = { second, third }
    local second_result = control.registry:dispatch("editor.documents", {}, {})
    core.docs = old_docs

    test.equal(first_result.documents[1].document_id, "document:1")
    test.equal(first_result.documents[2].document_id, "document:2")
    test.equal(second_result.documents[1].document_id, "document:2")
    test.equal(second_result.documents[2].document_id, "document:3")
  end)

  test.test("project changes wait for confirmation before responding", function()
    local control = new_control()
    local old_open_project = core.open_project
    local old_confirm = core.confirm_close_docs_async
    local called_path
    local response
    core.open_project = function(path) called_path = path end
    core.confirm_close_docs_async = function(_, on_confirm, _, path)
      on_confirm(path)
    end
    local path = system.absolute_path("data/core")
    local result, change_error = control.registry:dispatch("project.change", { path = path }, {
      defer = function()
        return function(response_result, response_error)
          response = { result = response_result, error = response_error }
        end
      end,
    })
    core.open_project = old_open_project
    core.confirm_close_docs_async = old_confirm

    test.is_nil(result)
    test.is_nil(change_error)
    test.ok(response)
    test.ok(response.result)
    test.equal(response.result.path, path)
    test.equal(response.result.status, "confirmed")
    test.equal(called_path, path)
  end)
end)
