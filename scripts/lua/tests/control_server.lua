local Protocol = require "core.control.protocol"
local MessagePack = require "core.control.msgpack"
local Registry = require "core.control.registry"
local Server = require "core.control.server"
local test = require "core.test"

local function fake_connection(messages)
  local sent = {}
  local connection = { sent = sent, closed = false }
  function connection:receive()
    if #messages == 0 then return nil, "would_block" end
    return table.remove(messages, 1)
  end
  function connection:send(payload)
    sent[#sent + 1] = assert(Protocol.decode(payload))
    return true
  end
  function connection:flush() return true end
  function connection:close() self.closed = true end
  return connection
end

local function fake_transport(connection)
  local listening = { connection = connection, accepted = false, closed = false }
  function listening:accept()
    if self.accepted then return nil, "would_block" end
    self.accepted = true
    return self.connection
  end
  function listening:close() self.closed = true end
  return {
    listen = function(_, options)
      test.equal(options.max_frame_size, Protocol.max_payload_size)
      return listening
    end,
  }, listening
end

test.describe("control server", function()
  test.test("requires hello and returns structured dispatch errors", function()
    local registry = Registry.new()
    registry:register {
      method = "control.hello",
      execute = function() return { protocol_version = 1 } end,
    }
    registry:register {
      method = "control.ping",
      execute = function() return { ok = true } end,
    }
    registry:register {
      method = "test.failure",
      execute = function() error("secret stack details") end,
    }
    registry:register {
      method = "test.validation",
      validate = function() error("secret validation details") end,
      execute = function() return {} end,
    }

    local connection = fake_connection {
      assert(Protocol.encode(Protocol.request("before-hello", "control.ping", {}))),
    }
    local transport, listening = fake_transport(connection)
    local server = assert(Server.new(transport, "fake", registry))
    server:poll()

    test.equal(connection.sent[1].error.code, "permission_denied")
    test.equal(#connection.sent, 1)
    test.ok(connection.closed)
    test.ok(not listening.closed)
    server:close()
    test.ok(listening.closed)

    connection = fake_connection {
      assert(Protocol.encode(Protocol.request("hello", "control.hello", {}))),
      assert(Protocol.encode(Protocol.request("unknown", "test.unknown", {}))),
      assert(Protocol.encode(Protocol.request("failure", "test.failure", {}))),
      assert(Protocol.encode(Protocol.request("validation", "test.validation", {}))),
    }
    transport, listening = fake_transport(connection)
    server = assert(Server.new(transport, "fake", registry))
    server:poll()
    test.equal(connection.sent[1].result.protocol_version, 1)
    test.equal(connection.sent[2].error.code, "unsupported")
    test.equal(connection.sent[3].error.code, "internal")
    test.ok(not connection.sent[3].error.message:match("stack traceback"))
    test.equal(connection.sent[4].error.code, "internal")
    test.ok(not connection.sent[4].error.message:match("stack traceback"))
    server:close()
  end)

  test.test("reports malformed versions before closing the client", function()
    local connection = fake_connection {
      MessagePack.encode({
        version = 2, kind = "request", id = "version", method = "control.ping",
        params = {},
      }),
    }
    local transport = fake_transport(connection)
    local server = assert(Server.new(transport, "fake", Registry.new()))
    server:poll()

    test.equal(connection.sent[1].error.code, "unsupported_version")
    test.ok(connection.closed)
    server:close()
  end)
end)
