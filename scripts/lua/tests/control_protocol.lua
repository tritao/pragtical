local MessagePack = require "core.control.msgpack"
local Protocol = require "core.control.protocol"
local test = require "core.test"

test.describe("core control protocol", function()
  test.test("round trips versioned requests, responses, and events", function()
    local request = Protocol.request("client:42", "editor.open", { path = "é.c", offset = -42 })
    local payload = assert(Protocol.encode(request))
    local decoded = assert(Protocol.decode(payload))
    test.equal(decoded.version, 1)
    test.equal(decoded.kind, "request")
    test.equal(decoded.id, "client:42")
    test.equal(decoded.params.path, "é.c")
    test.equal(decoded.params.offset, -42)

    local response = assert(Protocol.decode(assert(Protocol.encode(
      Protocol.response("client:42", { ok = true })))))
    test.equal(response.result.ok, true)

    local event = assert(Protocol.decode(assert(Protocol.encode(
      Protocol.event(1, "document.opened", { path = "file.c" })))))
    test.equal(event.sequence, 1)
  end)

  test.test("rejects unsupported versions and malformed envelopes", function()
    local value = { version = 2, kind = "request", id = "x", method = "control.ping", params = {} }
    local decoded, code = Protocol.decode(MessagePack.encode(value))
    test.not_ok(decoded)
    test.equal(code, "unsupported_version")

    local invalid, invalid_code = Protocol.decode(MessagePack.encode({
      version = 1, kind = "request", id = "x", params = {}
    }))
    test.not_ok(invalid)
    test.equal(invalid_code, "invalid_request")
  end)

  test.test("ignores unknown fields and preserves structured errors", function()
    local payload = assert(Protocol.encode({
      version = 1, kind = "response", id = "x", result = {}, future_field = "ignored"
    }))
    local response = assert(Protocol.decode(payload))
    test.equal(response.future_field, nil)

    local error_response = Protocol.error_response("x", "not_found", "missing", false)
    local decoded = assert(Protocol.decode(assert(Protocol.encode(error_response))))
    test.equal(decoded.error.code, "not_found")
    test.equal(decoded.error.retryable, false)
  end)

  test.test("bounds nesting and payload sizes", function()
    local nested = {}
    local value = nested
    for _ = 1, 40 do
      value.child = {}
      value = value.child
    end
    local _, nested_code = Protocol.encode({
      version = 1, kind = "request", id = "x", method = "control.ping",
      params = nested,
    })
    test.equal(nested_code, "invalid_request")

    local oversized, oversized_code = Protocol.decode(
      string.rep("x", Protocol.max_payload_size + 1))
    test.is_nil(oversized)
    test.equal(oversized_code, "invalid_request")
  end)
end)
