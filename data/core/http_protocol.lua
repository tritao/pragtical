---Scheduler-independent HTTP/1.1 protocol helpers shared by the GUI client
---and headless Workbench providers. This module does not load core, net, or
---any coroutine scheduler.
local protocol = {}

local function append_header(headers, key, value)
  key = key:lower()
  if headers[key] == nil then
    headers[key] = value
  elseif type(headers[key]) == "table" then
    headers[key][#headers[key] + 1] = value
  else
    headers[key] = { headers[key], value }
  end
end

function protocol.append_header(headers, key, value)
  append_header(headers, key, value)
end

function protocol.header(headers, key)
  if not headers then return nil end
  local value = headers[key:lower()]
  if type(value) == "table" then return value[#value] end
  return value
end

function protocol.parse_url(url)
  local scheme, host, port, path = url:match("^(https?)://([^/:?#]+):?(%d*)(.*)$")
  if not scheme or host == "" then return nil, "invalid URL" end
  port = tonumber(port) or (scheme == "https" and 443 or 80)
  path = path ~= "" and path or "/"
  return { protocol = scheme, host = host, port = port, path = path }
end

function protocol.join_path(base, path)
  if path:sub(1, 1) ~= "/" then path = "/" .. path end
  return (base:gsub("/$", "")) .. path
end

function protocol.build_origin(scheme, host, port)
  local default_port = scheme == "https" and 443 or 80
  if port == default_port then return scheme .. "://" .. host end
  return scheme .. "://" .. host .. ":" .. port
end

local function resolve_relative_path(base_path, relative_path)
  local dir = base_path:gsub("[^/]*$", "")
  if dir == "" then dir = "/" end

  local path = relative_path:sub(1, 1) == "/" and relative_path or (dir .. relative_path)
  local trailing_slash = path:sub(-1) == "/"
  local segments = {}

  for segment in path:gmatch("[^/]+") do
    if segment == ".." then
      if #segments > 0 then table.remove(segments) end
    elseif segment ~= "." and segment ~= "" then
      segments[#segments + 1] = segment
    end
  end

  local normalized = "/" .. table.concat(segments, "/")
  if trailing_slash and normalized ~= "/" then normalized = normalized .. "/" end
  return normalized
end

function protocol.resolve_redirect_url(parsed, location)
  if location:match("^[%a][%w+%.%-]*://") then return location end
  if location:sub(1, 2) == "//" then return parsed.protocol .. ":" .. location end

  local origin = protocol.build_origin(parsed.protocol, parsed.host, parsed.port)
  local base_path = parsed.path:match("^[^?#]*") or "/"
  if location:sub(1, 1) == "/" then return origin .. location end
  if location:sub(1, 1) == "?" or location:sub(1, 1) == "#" then
    return origin .. base_path .. location
  end

  local location_path, location_suffix = location:match("^([^?#]*)(.*)$")
  return origin .. resolve_relative_path(base_path, location_path) .. location_suffix
end

local function escape_header(value)
  return tostring(value):gsub("[\r\n]", "")
end

local function header_name(key)
  key = key:gsub("^(%a)", function(first) return first:upper() end)
  return key:gsub("-(%a)", function(first) return "-" .. first:upper() end)
end

---Build a complete HTTP/1.1 request.
---@param method string
---@param path string
---@param host string
---@param port integer
---@param scheme string
---@param headers table<string,string>?
---@param body string?
---@param user_agent string?
---@param connection string?
function protocol.build_request(method, path, host, port, scheme, headers, body,
    user_agent, connection)
  local values = {}
  for key, value in pairs(headers or {}) do
    values[key:lower()] = escape_header(value)
  end

  if not values["user-agent"] and user_agent then
    values["user-agent"] = user_agent
  end
  values.host = values.host or protocol.build_origin(scheme, host, port):gsub("^https?://", "")
  values.connection = values.connection or connection or "close"
  if body ~= nil then values["content-length"] = tostring(#body) end

  local lines = { string.format("%s %s HTTP/1.1", method, path) }
  for key, value in pairs(values) do
    lines[#lines + 1] = header_name(key) .. ": " .. value
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = body or ""
  return table.concat(lines, "\r\n")
end

function protocol.parse_header_lines(lines)
  if #lines == 0 then return nil, {} end
  local status = tonumber(lines[1] and lines[1]:match("^HTTP/%d+%.%d+ (%d%d%d)"))
  if not status then return nil, {} end

  local headers = {}
  for index = 2, #lines do
    local key, value = lines[index]:match("^([^:]+):%s*(.*)$")
    if key and value then append_header(headers, key, value) end
  end
  return status, headers
end

---Parse a response buffer. A missing header terminator is an incomplete result
---and returns nil without an error; malformed status lines return an error.
function protocol.parse_headers(data)
  local boundary = data:find("\r\n\r\n", 1, true)
  if not boundary then return nil end
  local raw = data:sub(1, boundary - 1)
  local lines = {}
  for line in (raw .. "\r\n"):gmatch("(.-)\r\n") do lines[#lines + 1] = line end
  local status, headers = protocol.parse_header_lines(lines)
  if not status then return nil, "invalid HTTP response" end
  return { status = status, headers = headers, body = data:sub(boundary + 4) }, boundary + 4
end

---Consume an HTTP chunked body incrementally.
---@param buffer string
---@param state table
---@return string remaining, string decoded, boolean done
function protocol.consume_chunked(buffer, state)
  local decoded = {}
  while not state.done do
    if state.awaiting_trailers then
      if buffer:sub(1, 2) == "\r\n" then
        buffer = buffer:sub(3)
        state.done = true
      else
        local trailers_end = buffer:find("\r\n\r\n", 1, true)
        if not trailers_end then return buffer, table.concat(decoded), false end
        buffer = buffer:sub(trailers_end + 4)
        state.done = true
      end
    elseif state.size == nil then
      local line_end = buffer:find("\r\n", 1, true)
      if not line_end then return buffer, table.concat(decoded), false end
      local line = buffer:sub(1, line_end - 1)
      local size_text = line:match("^%s*([0-9A-Fa-f]+)")
      local size = size_text and tonumber(size_text, 16)
      if not size then return nil, nil, nil, "invalid HTTP chunk size" end
      buffer = buffer:sub(line_end + 2)
      if size == 0 then
        if buffer:sub(1, 2) == "\r\n" then
          buffer = buffer:sub(3)
          state.done = true
        else
          state.awaiting_trailers = true
        end
      else
        state.size = size
      end
    else
      if #buffer < state.size + 2 then return buffer, table.concat(decoded), false end
      if buffer:sub(state.size + 1, state.size + 2) ~= "\r\n" then
        return nil, nil, nil, "invalid HTTP chunk terminator"
      end
      decoded[#decoded + 1] = buffer:sub(1, state.size)
      buffer = buffer:sub(state.size + 3)
      state.size = nil
    end
  end
  return buffer, table.concat(decoded), true
end

local SSE = {}
SSE.__index = SSE

local function sse_reset(self)
  self.data = {}
  self.event = nil
  self.retry = nil
end

function SSE.new(last_event_id)
  local parser = setmetatable({
    pending = "",
    last_event_id = last_event_id,
    data = {},
  }, SSE)
  sse_reset(parser)
  return parser
end

function SSE:dispatch(events)
  if #self.data == 0 then
    sse_reset(self)
    return
  end
  events[#events + 1] = {
    event = self.event or "message",
    data = table.concat(self.data, "\n"),
    id = self.last_event_id,
    retry = self.retry,
  }
  sse_reset(self)
end

function SSE:line(line, events)
  if line == "" then
    self:dispatch(events)
    return
  end
  if line:sub(1, 1) == ":" then return end

  local field, value = line:match("^([^:]*):?(.*)$")
  if not field then return end
  if value:sub(1, 1) == " " then value = value:sub(2) end
  if field == "event" then
    self.event = value
  elseif field == "data" then
    self.data[#self.data + 1] = value
  elseif field == "id" then
    if not value:find("\0", 1, true) then self.last_event_id = value end
  elseif field == "retry" then
    local retry = tonumber(value)
    if retry and retry >= 0 then self.retry = retry end
  end
end

function SSE:feed(chunk)
  self.pending = self.pending .. chunk
  local events = {}
  while true do
    local index = self.pending:find("\n", 1, true)
    if not index then break end
    local line = self.pending:sub(1, index - 1)
    self.pending = self.pending:sub(index + 1)
    if line:sub(-1) == "\r" then line = line:sub(1, -2) end
    self:line(line, events)
  end
  return events
end

function SSE:finish()
  local events = {}
  if #self.pending > 0 then
    local line = self.pending
    if line:sub(-1) == "\r" then line = line:sub(1, -2) end
    self.pending = ""
    self:line(line, events)
  end
  self:dispatch(events)
  return events
end

protocol.SSE = SSE

return protocol
