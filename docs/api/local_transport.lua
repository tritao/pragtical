---@class local_transport
local local_transport = {}

---@class local_transport.listen_options
---@field max_frame_size? integer Maximum accepted payload size (default: 16 MiB).
---@field max_queued_bytes? integer Maximum queued output bytes per connection.

---@class local_transport.server
local server = {}

---@param timeout_ms? integer Zero is nonblocking; a positive value is a bounded wait.
---@return local_transport.connection|nil connection
---@return string? error "would_block", "timeout", "unauthorized", or "closed".
function server:accept(timeout_ms) end

function server:close() end

---@class local_transport.connection
local connection = {}

---@param payload string
---@return boolean|nil ok
---@return string? error "would_block", "queue_overflow", "invalid_frame", or "closed".
function connection:send(payload) end

---@return boolean|nil ok
---@return string? error "would_block" or "closed".
function connection:flush() end

---Whether receive has started reading a header or payload.
---Used by higher protocol layers to enforce frame timeouts.
---@return boolean pending
function connection:has_pending_frame() end

---@param timeout_ms? integer Zero is nonblocking; a positive value is a bounded wait.
---@return string|nil payload
---@return string? error "would_block", "timeout", "invalid_frame", or "closed".
function connection:receive(timeout_ms) end

function connection:close() end

---@param endpoint string
---@param options? local_transport.listen_options
---@return local_transport.server|nil server
---@return string? error
function local_transport.listen(endpoint, options) end

---@param endpoint string
---@param options? local_transport.listen_options
---@return local_transport.connection|nil connection
---@return string? error
function local_transport.connect(endpoint, options) end

return local_transport
