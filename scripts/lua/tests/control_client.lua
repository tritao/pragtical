local Client = require "core.control.client"
local Protocol = require "core.control.protocol"
local test = require "core.test"

test.describe("control client", function()
  test.test("correlates multiple in-flight responses", function()
    local incoming = {}
    local sent = {}
    local connection = {}
    function connection:send(payload)
      sent[#sent + 1] = assert(Protocol.decode(payload))
      if #sent == 2 then
        for index = #sent, 1, -1 do
          incoming[#incoming + 1] = assert(Protocol.encode(
            Protocol.response(sent[index].id, { method = sent[index].method })))
        end
      end
      return true
    end
    function connection:flush() return true end
    function connection:receive()
      if #incoming == 0 then return nil, "would_block" end
      return table.remove(incoming, 1)
    end
    function connection:close() end

    local fake_transport = {
      connect = function() return connection end,
    }
    local client = assert(Client.connect(fake_transport, "fake"))
    local completed = {}
    local first = assert(client:request("control.ping", {}, function(result)
      completed[#completed + 1] = result.method
    end))
    local second = assert(client:request("instance.status", {}, function(result)
      completed[#completed + 1] = result.method
    end))

    client:poll()
    test.ok(first.done)
    test.ok(second.done)
    test.same(completed, { "instance.status", "control.ping" })
    client:close()
  end)
end)
