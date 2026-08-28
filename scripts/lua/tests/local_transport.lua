local common = require "core.common"
local test = require "core.test"

local available, transport = pcall(require, "local_transport")

test.describe("local transport", function()
  test.test("supports bounded framed exchange with multiple clients", function()
    test.skip_if(not available, "local transport is unavailable in this build")

    local directory = USERDIR .. PATHSEP .. "local-transport-tests"
    local ok, mkdir_error = common.mkdirp(directory)
    test.ok(ok, mkdir_error)
    local endpoint = directory .. PATHSEP .. "exchange-"
      .. tostring(system.get_process_id()) .. "-" .. tostring(math.floor(system.get_time() * 1000000))
    local server, listen_error = transport.listen(endpoint, {
      max_frame_size = 64,
      max_queued_bytes = 128,
    })
    test.not_nil(server, listen_error)

    local no_client, no_client_error = server:accept(0)
    test.is_nil(no_client)
    test.equal(no_client_error, "would_block")

    local first = assert(transport.connect(endpoint, {
      max_frame_size = 64,
      max_queued_bytes = 128,
    }))
    local second = assert(transport.connect(endpoint, {
      max_frame_size = 64,
      max_queued_bytes = 128,
    }))
    local first_server = assert(server:accept(0))
    local second_server = assert(server:accept(0))

    test.ok(first:send("hello"))
    test.equal(first_server:receive(0), "hello")
    local oversized, oversized_error = first:send(string.rep("x", 65))
    test.is_nil(oversized)
    test.equal(oversized_error, "invalid_frame")

    second:close()
    local closed, closed_error = second_server:receive(0)
    test.is_nil(closed)
    test.equal(closed_error, "closed")

    first:close()
    first_server:close()
    second_server:close()
    server:close()
    test.is_nil(system.get_file_info(endpoint))

    local closed_send, closed_send_error = first:send("after close")
    test.is_nil(closed_send)
    test.equal(closed_send_error, "closed")
    local closed_accept, closed_accept_error = server:accept(0)
    test.is_nil(closed_accept)
    test.equal(closed_accept_error, "closed")
  end)
end)
