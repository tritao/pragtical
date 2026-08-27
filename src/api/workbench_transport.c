#ifndef _WIN32
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#endif

#include "api.h"

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef _WIN32
#include <fcntl.h>
#include <poll.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#else
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include <windows.h>
#include <sddl.h>
#endif

#define WORKBENCH_CONNECTION "WorkbenchTransportConnection"
#define WORKBENCH_SERVER "WorkbenchTransportServer"
#define WORKBENCH_MAX_FRAME (16u * 1024u * 1024u)
#define WORKBENCH_PIPE_BUFFER (64u * 1024u)
#ifndef _WIN32
#define WORKBENCH_ENDPOINT_MAX 108
#else
#define WORKBENCH_ENDPOINT_MAX 260
#endif

typedef struct {
#ifdef _WIN32
  HANDLE handle;
#else
  int fd;
#endif
  int closed;
  unsigned char read_header[sizeof(uint32_t)];
  size_t read_header_offset;
  unsigned char *read_buffer;
  size_t read_length;
  size_t read_offset;
  int read_frame_active;
  unsigned char *write_buffer;
  size_t write_length;
  size_t write_offset;
#ifdef _WIN32
  HANDLE read_event;
  OVERLAPPED read_overlapped;
  int read_pending;
  size_t *read_pending_offset;
  HANDLE write_event;
  OVERLAPPED write_overlapped;
  int write_pending;
#endif
} workbench_connection;

typedef struct {
#ifdef _WIN32
  HANDLE handle;
#else
  int fd;
#endif
  int closed;
  char path[WORKBENCH_ENDPOINT_MAX];
} workbench_server;

static int build_frame(const char *data, size_t length,
    unsigned char **frame, size_t *frame_length) {
  if (length > WORKBENCH_MAX_FRAME || length > UINT32_MAX) return 0;
  *frame_length = sizeof(uint32_t) + length;
  *frame = malloc(*frame_length ? *frame_length : 1);
  if (!*frame) return 0;
  uint32_t network_length = ((uint32_t)length >> 24)
    | (((uint32_t)length >> 8) & 0x0000ff00u)
    | (((uint32_t)length << 8) & 0x00ff0000u)
    | ((uint32_t)length << 24);
  memcpy(*frame, &network_length, sizeof(network_length));
  if (length > 0) memcpy(*frame + sizeof(network_length), data, length);
  return 1;
}

#ifndef _WIN32
static int wait_for_fd(int fd, short events, int timeout_ms) {
  struct pollfd descriptor = { fd, events, 0 };
  int result;
  do {
    result = poll(&descriptor, 1, timeout_ms);
  } while (result < 0 && errno == EINTR);
  if (result <= 0) return result;
  if (descriptor.revents & POLLNVAL) return -1;
  if (descriptor.revents & POLLERR) return -1;
  if (descriptor.revents & events) return 1;
  if (descriptor.revents & POLLHUP) return -1;
  return 0;
}

static int read_incremental(int fd, void *buffer, size_t length,
    size_t *offset, int timeout_ms) {
  while (*offset < length) {
    int ready = wait_for_fd(fd, POLLIN, timeout_ms);
    if (ready <= 0) return ready;
    ssize_t count = read(fd, (char *)buffer + *offset, length - *offset);
    if (count == 0) return -1;
    if (count < 0) {
      if (errno == EINTR) continue;
      if (errno == EAGAIN || errno == EWOULDBLOCK)
        return 0;
      return -1;
    }
    *offset += (size_t)count;
  }
  return 1;
}

static int write_all(int fd, const void *buffer, size_t length) {
  const char *cursor = buffer;
  while (length > 0) {
    ssize_t count = write(fd, cursor, length);
    if (count < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    if (count == 0) return -1;
    cursor += count;
    length -= (size_t)count;
  }
  return 1;
}

static void clear_write_buffer(workbench_connection *connection) {
  free(connection->write_buffer);
  connection->write_buffer = NULL;
  connection->write_length = 0;
  connection->write_offset = 0;
}

static void clear_read_state(workbench_connection *connection) {
  free(connection->read_buffer);
  connection->read_buffer = NULL;
  connection->read_header_offset = 0;
  connection->read_length = 0;
  connection->read_offset = 0;
  connection->read_frame_active = 0;
}

/* Drain at most what the kernel accepts right now. The agent's event loop
   calls this independently for every client, so a slow reader cannot stall
   mutations, runtime polling, or other clients. */
static int flush_write_buffer(workbench_connection *connection) {
  while (connection->write_offset < connection->write_length) {
    int flags = MSG_DONTWAIT;
#ifdef MSG_NOSIGNAL
    flags |= MSG_NOSIGNAL;
#endif
    ssize_t count = send(connection->fd,
      connection->write_buffer + connection->write_offset,
      connection->write_length - connection->write_offset, flags);
    if (count > 0) {
      connection->write_offset += (size_t)count;
      continue;
    }
    if (count < 0 && (errno == EINTR)) continue;
    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return 0;
    return -1;
  }
  clear_write_buffer(connection);
  return 1;
}

static int close_fd(int *fd) {
  if (*fd >= 0) {
    close(*fd);
    *fd = -1;
  }
  return 1;
}

static int connection_gc(lua_State *L) {
  workbench_connection *connection = luaL_checkudata(L, 1, WORKBENCH_CONNECTION);
  if (!connection->closed) {
    close_fd(&connection->fd);
    connection->closed = 1;
  }
  clear_write_buffer(connection);
  clear_read_state(connection);
  return 0;
}

static int server_gc(lua_State *L) {
  workbench_server *server = luaL_checkudata(L, 1, WORKBENCH_SERVER);
  if (!server->closed) {
    close_fd(&server->fd);
    unlink(server->path);
    server->closed = 1;
  }
  return 0;
}

static workbench_connection *check_connection(lua_State *L) {
  workbench_connection *connection = luaL_checkudata(L, 1, WORKBENCH_CONNECTION);
  if (connection->closed) luaL_error(L, "Workbench transport connection is closed");
  return connection;
}

static workbench_server *check_server(lua_State *L) {
  workbench_server *server = luaL_checkudata(L, 1, WORKBENCH_SERVER);
  if (server->closed) luaL_error(L, "Workbench transport server is closed");
  return server;
}

static int connection_close(lua_State *L) {
  workbench_connection *connection = luaL_checkudata(L, 1, WORKBENCH_CONNECTION);
  if (!connection->closed) {
    close_fd(&connection->fd);
    connection->closed = 1;
  }
  clear_write_buffer(connection);
  clear_read_state(connection);
  return 0;
}

static int connection_send(lua_State *L) {
  workbench_connection *connection = check_connection(L);
  size_t length;
  const char *data = luaL_checklstring(L, 2, &length);
  if (length > WORKBENCH_MAX_FRAME) return luaL_error(L, "Workbench frame is too large");
  uint32_t network_length = ((uint32_t)length >> 24)
    | (((uint32_t)length >> 8) & 0x0000ff00u)
    | (((uint32_t)length << 8) & 0x00ff0000u)
    | ((uint32_t)length << 24);
  if (connection->write_buffer) {
    if (write_all(connection->fd,
        connection->write_buffer + connection->write_offset,
        connection->write_length - connection->write_offset) < 0) {
      clear_write_buffer(connection);
      return luaL_error(L, "failed to write Workbench frame: %s", strerror(errno));
    }
    clear_write_buffer(connection);
  }
  if (write_all(connection->fd, &network_length, sizeof(network_length)) < 0
      || write_all(connection->fd, data, length) < 0) {
    return luaL_error(L, "failed to write Workbench frame: %s", strerror(errno));
  }
  lua_pushboolean(L, 1);
  return 1;
}

static int connection_send_nonblocking(lua_State *L) {
  workbench_connection *connection = check_connection(L);
  size_t length;
  const char *data = luaL_checklstring(L, 2, &length);
  if (length > WORKBENCH_MAX_FRAME) return luaL_error(L, "Workbench frame is too large");
  if (connection->write_buffer) {
    int flushed = flush_write_buffer(connection);
    if (flushed == 0) {
      lua_pushnil(L);
      lua_pushliteral(L, "would_block");
      return 2;
    }
    if (flushed < 0) {
      connection->closed = 1;
      close_fd(&connection->fd);
      clear_write_buffer(connection);
      lua_pushnil(L);
      lua_pushliteral(L, "closed");
      return 2;
    }
  }
  if (!build_frame(data, length, &connection->write_buffer,
      &connection->write_length))
    return luaL_error(L, "out of memory writing Workbench frame");
  connection->write_offset = 0;
  int flushed = flush_write_buffer(connection);
  if (flushed > 0) {
    lua_pushboolean(L, 1);
    return 1;
  }
  if (flushed == 0) {
    lua_pushnil(L);
    lua_pushliteral(L, "would_block");
    return 2;
  }
  connection->closed = 1;
  close_fd(&connection->fd);
  clear_write_buffer(connection);
  lua_pushnil(L);
  lua_pushliteral(L, "closed");
  return 2;
}

static int connection_flush(lua_State *L) {
  workbench_connection *connection = check_connection(L);
  if (!connection->write_buffer) {
    lua_pushboolean(L, 1);
    return 1;
  }
  int flushed = flush_write_buffer(connection);
  if (flushed > 0) {
    lua_pushboolean(L, 1);
    return 1;
  }
  if (flushed == 0) {
    lua_pushnil(L);
    lua_pushliteral(L, "would_block");
    return 2;
  }
  connection->closed = 1;
  close_fd(&connection->fd);
  clear_write_buffer(connection);
  lua_pushnil(L);
  lua_pushliteral(L, "closed");
  return 2;
}

static int connection_receive(lua_State *L) {
  workbench_connection *connection = check_connection(L);
  int timeout_ms = (int)luaL_optinteger(L, 2, -1);
  int result;
  if (!connection->read_frame_active) {
    result = read_incremental(connection->fd, connection->read_header,
      sizeof(connection->read_header), &connection->read_header_offset,
      timeout_ms);
    if (result == 0) {
      lua_pushnil(L);
      lua_pushliteral(L, "timeout");
      return 2;
    }
    if (result < 0) {
      connection->closed = 1;
      close_fd(&connection->fd);
      clear_write_buffer(connection);
      clear_read_state(connection);
      lua_pushnil(L);
      lua_pushliteral(L, "closed");
      return 2;
    }

    uint32_t network_length;
    memcpy(&network_length, connection->read_header, sizeof(network_length));
    uint32_t length = ((network_length >> 24) & 0x000000ffu)
      | ((network_length >> 8) & 0x0000ff00u)
      | ((network_length << 8) & 0x00ff0000u)
      | (network_length << 24);
    if (length > WORKBENCH_MAX_FRAME) {
      clear_read_state(connection);
      return luaL_error(L, "Workbench frame is too large");
    }
    connection->read_length = length;
    connection->read_offset = 0;
    connection->read_frame_active = 1;
    if (length > 0) {
      connection->read_buffer = malloc(length);
      if (!connection->read_buffer) {
        clear_read_state(connection);
        return luaL_error(L, "out of memory reading Workbench frame");
      }
    }
  }

  result = read_incremental(connection->fd, connection->read_buffer,
    connection->read_length, &connection->read_offset, timeout_ms);
  if (result == 0) {
    lua_pushnil(L);
    lua_pushliteral(L, "timeout");
    return 2;
  }
  if (result < 0) {
    connection->closed = 1;
    close_fd(&connection->fd);
    clear_write_buffer(connection);
    clear_read_state(connection);
    lua_pushnil(L);
    lua_pushliteral(L, "closed");
    return 2;
  }
  lua_pushlstring(L, connection->read_buffer
    ? (const char *)connection->read_buffer : "", connection->read_length);
  clear_read_state(connection);
  return 1;
}

static int server_close(lua_State *L) {
  workbench_server *server = luaL_checkudata(L, 1, WORKBENCH_SERVER);
  if (!server->closed) {
    close_fd(&server->fd);
    unlink(server->path);
    server->closed = 1;
  }
  return 0;
}

static int server_accept(lua_State *L) {
  workbench_server *server = check_server(L);
  int timeout_ms = (int)luaL_optinteger(L, 2, -1);
  if (timeout_ms >= 0) {
    int ready = wait_for_fd(server->fd, POLLIN, timeout_ms);
    if (ready == 0) {
      lua_pushnil(L);
      lua_pushliteral(L, "timeout");
      return 2;
    }
    if (ready < 0) {
      lua_pushnil(L);
      lua_pushliteral(L, "closed");
      return 2;
    }
  }
  int fd;
  do {
    fd = accept(server->fd, NULL, NULL);
  } while (fd < 0 && errno == EINTR);
  if (fd < 0) {
    lua_pushnil(L);
    lua_pushfstring(L, "failed to accept Workbench client: %s", strerror(errno));
    return 2;
  }
#ifdef SO_PEERCRED
  struct ucred peer;
  socklen_t peer_length = sizeof(peer);
  if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &peer, &peer_length) < 0
      || peer.uid != geteuid()) {
    close(fd);
    lua_pushnil(L);
    lua_pushliteral(L, "unauthorized");
    return 2;
  }
#endif
  workbench_connection *connection = lua_newuserdata(L, sizeof(*connection));
  memset(connection, 0, sizeof(*connection));
  connection->fd = fd;
  luaL_setmetatable(L, WORKBENCH_CONNECTION);
  return 1;
}

static int validate_endpoint(const char *path, int require_socket) {
  struct stat info;
  if (lstat(path, &info) < 0) return 0;
  if ((require_socket && !S_ISSOCK(info.st_mode))
      || info.st_uid != geteuid()
      || (info.st_mode & 0077) != 0) {
    errno = EACCES;
    return -1;
  }
  return 1;
}

static int prepare_endpoint(const char *path) {
  char parent[WORKBENCH_ENDPOINT_MAX];
  const char *separator = strrchr(path, '/');
  if (separator) {
    size_t length = (size_t)(separator - path);
    if (length == 0) length = 1;
    if (length >= sizeof(parent)) {
      errno = ENAMETOOLONG;
      return -1;
    }
    memcpy(parent, path, length);
    parent[length] = '\0';
    struct stat parent_info;
    if (stat(parent, &parent_info) < 0) return -1;
    if (!S_ISDIR(parent_info.st_mode) || parent_info.st_uid != geteuid()
        || (parent_info.st_mode & 0022) != 0) {
      errno = EACCES;
      return -1;
    }
  }

  struct stat info;
  if (lstat(path, &info) == 0) {
    if (!S_ISSOCK(info.st_mode) || info.st_uid != geteuid()
        || unlink(path) < 0)
      {
        errno = EACCES;
        return -1;
      }
  } else if (errno != ENOENT) {
    return -1;
  }
  return 0;
}

static int connect_socket(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  if (strlen(path) >= WORKBENCH_ENDPOINT_MAX)
    return luaL_error(L, "Workbench endpoint path is too long");
  int endpoint_status = validate_endpoint(path, 1);
  if (endpoint_status < 0) {
    lua_pushnil(L);
    lua_pushfstring(L, "Workbench endpoint is not owned by the current user: %s",
      strerror(errno));
    return 2;
  }
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) {
    lua_pushnil(L);
    lua_pushfstring(L, "failed to create Workbench socket: %s", strerror(errno));
    return 2;
  }
  struct sockaddr_un address;
  memset(&address, 0, sizeof(address));
  address.sun_family = AF_UNIX;
  strcpy(address.sun_path, path);
  if (connect(fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
    int error = errno;
    close(fd);
    lua_pushnil(L);
    lua_pushfstring(L, "failed to connect to Workbench agent: %s", strerror(error));
    return 2;
  }
  workbench_connection *connection = lua_newuserdata(L, sizeof(*connection));
  memset(connection, 0, sizeof(*connection));
  connection->fd = fd;
  luaL_setmetatable(L, WORKBENCH_CONNECTION);
  return 1;
}

static int listen_socket(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  if (strlen(path) >= WORKBENCH_ENDPOINT_MAX)
    return luaL_error(L, "Workbench endpoint path is too long");
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) {
    lua_pushnil(L);
    lua_pushfstring(L, "failed to create Workbench socket: %s", strerror(errno));
    return 2;
  }
  struct sockaddr_un address;
  memset(&address, 0, sizeof(address));
  address.sun_family = AF_UNIX;
  strcpy(address.sun_path, path);
  if (prepare_endpoint(path) < 0
      || bind(fd, (struct sockaddr *)&address, sizeof(address)) < 0
      || listen(fd, 8) < 0
      || chmod(path, 0600) < 0) {
    int error = errno;
    close(fd);
    lua_pushnil(L);
    lua_pushfstring(L, "failed to listen for Workbench clients: %s", strerror(error));
    return 2;
  }
  workbench_server *server = lua_newuserdata(L, sizeof(*server));
  server->fd = fd;
  server->closed = 0;
  strcpy(server->path, path);
  luaL_setmetatable(L, WORKBENCH_SERVER);
  return 1;
}
#else
static int pipe_name(const char *endpoint, char *name, size_t capacity) {
  static const char prefix[] = "\\\\.\\pipe\\pragtical-workbench-";
  if (strncmp(endpoint, "\\\\.\\pipe\\", 9) == 0) {
    if (strlen(endpoint) >= capacity) return 0;
    strcpy(name, endpoint);
    return 1;
  }
  uint32_t hash = 2166136261u;
  for (const unsigned char *cursor = (const unsigned char *)endpoint;
      *cursor; ++cursor) {
    hash ^= *cursor;
    hash *= 16777619u;
  }
  return snprintf(name, capacity, "%s%08x", prefix, hash) > 0
    && strlen(name) < capacity;
}

static HANDLE create_pipe(const char *name) {
  PSECURITY_DESCRIPTOR descriptor = NULL;
  SECURITY_ATTRIBUTES attributes = {0};
  attributes.nLength = sizeof(attributes);
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorA(
      "D:P(A;;GA;;;CO)", SDDL_REVISION_1, &descriptor, NULL))
    return INVALID_HANDLE_VALUE;
  attributes.lpSecurityDescriptor = descriptor;
  HANDLE handle = CreateNamedPipeA(name,
    PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
    PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
    2, WORKBENCH_PIPE_BUFFER, WORKBENCH_PIPE_BUFFER, 0, &attributes);
  DWORD error = GetLastError();
  LocalFree(descriptor);
  SetLastError(error);
  return handle;
}

static int pipe_wait_data(HANDLE handle, int timeout_ms, DWORD *available) {
  ULONGLONG started = GetTickCount64();
  for (;;) {
    if (PeekNamedPipe(handle, NULL, 0, NULL, available, NULL)) {
      if (*available > 0) return 1;
    } else if (GetLastError() == ERROR_BROKEN_PIPE) {
      return -1;
    } else {
      return -1;
    }
    if (timeout_ms == 0) return 0;
    if (timeout_ms > 0
        && GetTickCount64() - started >= (ULONGLONG)timeout_ms)
      return 0;
    Sleep(1);
  }
}

static int finish_pending_read(workbench_connection *connection, int timeout_ms) {
  if (!connection->read_pending) return 1;
  DWORD wait = WaitForSingleObject(connection->read_event,
    timeout_ms < 0 ? INFINITE : (DWORD)timeout_ms);
  if (wait == WAIT_TIMEOUT) return 0;
  if (wait != WAIT_OBJECT_0) return -1;

  DWORD count = 0;
  if (!GetOverlappedResult(connection->handle, &connection->read_overlapped,
      &count, FALSE))
    return -1;
  connection->read_pending = 0;
  if (connection->read_event) {
    CloseHandle(connection->read_event);
    connection->read_event = NULL;
  }
  size_t *offset = connection->read_pending_offset;
  connection->read_pending_offset = NULL;
  if (count == 0 || !offset) return -1;
  *offset += count;
  return 1;
}

static int read_pipe(workbench_connection *connection, void *buffer,
    size_t length, size_t *offset, int timeout_ms) {
  int result = finish_pending_read(connection, timeout_ms);
  if (result <= 0) return result;

  while (*offset < length) {
    DWORD available = 0;
    int ready = pipe_wait_data(connection->handle, timeout_ms, &available);
    if (ready <= 0) return ready;
    size_t remaining = length - *offset;
    DWORD requested = (DWORD)(remaining > UINT32_MAX ? UINT32_MAX : remaining);
    if (available < requested) requested = available;
    if (requested == 0) return 0;

    if (!connection->read_event) {
      connection->read_event = CreateEventA(NULL, TRUE, FALSE, NULL);
      if (!connection->read_event) return -1;
    }
    ResetEvent(connection->read_event);
    memset(&connection->read_overlapped, 0,
      sizeof(connection->read_overlapped));
    connection->read_overlapped.hEvent = connection->read_event;
    connection->read_pending = 1;
    connection->read_pending_offset = offset;
    BOOL read = ReadFile(connection->handle,
      (char *)buffer + *offset, requested, NULL,
      &connection->read_overlapped);
    if (read) {
      result = finish_pending_read(connection, 0);
      if (result <= 0) return result;
      continue;
    }
    DWORD error = GetLastError();
    if (error != ERROR_IO_PENDING) {
      connection->read_pending = 0;
      connection->read_pending_offset = NULL;
      if (connection->read_event) {
        CloseHandle(connection->read_event);
        connection->read_event = NULL;
      }
      return -1;
    }
    result = finish_pending_read(connection, timeout_ms);
    if (result <= 0) return result;
  }
  return 1;
}

static void clear_read_state(workbench_connection *connection) {
  if (connection->read_pending) {
    CancelIoEx(connection->handle, &connection->read_overlapped);
    connection->read_pending = 0;
    connection->read_pending_offset = NULL;
  }
  if (connection->read_event) {
    CloseHandle(connection->read_event);
    connection->read_event = NULL;
  }
  free(connection->read_buffer);
  connection->read_buffer = NULL;
  connection->read_header_offset = 0;
  connection->read_length = 0;
  connection->read_offset = 0;
  connection->read_frame_active = 0;
}

static int write_pipe(HANDLE handle, const void *buffer, size_t length) {
  const char *cursor = buffer;
  while (length > 0) {
    DWORD requested = (DWORD)(length > UINT32_MAX ? UINT32_MAX : length);
    OVERLAPPED overlapped = {0};
    overlapped.hEvent = CreateEventA(NULL, TRUE, FALSE, NULL);
    if (!overlapped.hEvent) return -1;
    DWORD count = 0;
    BOOL written = WriteFile(handle, cursor, requested, &count, &overlapped);
    if (!written && GetLastError() == ERROR_IO_PENDING) {
      if (WaitForSingleObject(overlapped.hEvent, INFINITE) != WAIT_OBJECT_0
          || !GetOverlappedResult(handle, &overlapped, &count, FALSE)) {
        CloseHandle(overlapped.hEvent);
        return -1;
      }
      written = TRUE;
    }
    CloseHandle(overlapped.hEvent);
    if (!written || count == 0) return -1;
    cursor += count;
    length -= count;
  }
  return 1;
}

static void clear_write_buffer(workbench_connection *connection) {
  if (connection->write_pending) {
    CancelIoEx(connection->handle, &connection->write_overlapped);
    connection->write_pending = 0;
  }
  if (connection->write_event) {
    CloseHandle(connection->write_event);
    connection->write_event = NULL;
  }
  free(connection->write_buffer);
  connection->write_buffer = NULL;
  connection->write_length = 0;
  connection->write_offset = 0;
}

static int flush_write_buffer(workbench_connection *connection) {
  for (;;) {
    if (connection->write_pending) {
      DWORD count = 0;
      if (!GetOverlappedResult(connection->handle, &connection->write_overlapped,
          &count, FALSE)) {
        DWORD error = GetLastError();
        if (error == ERROR_IO_INCOMPLETE) return 0;
        return -1;
      }
      connection->write_pending = 0;
      if (count == 0) return -1;
      connection->write_offset += count;
    }

    if (connection->write_offset >= connection->write_length) {
      clear_write_buffer(connection);
      return 1;
    }

    if (!connection->write_event) {
      connection->write_event = CreateEventA(NULL, TRUE, FALSE, NULL);
      if (!connection->write_event) return -1;
    }
    ResetEvent(connection->write_event);
    memset(&connection->write_overlapped, 0,
      sizeof(connection->write_overlapped));
    connection->write_overlapped.hEvent = connection->write_event;
    DWORD remaining = (DWORD)(connection->write_length - connection->write_offset);
    BOOL written = WriteFile(connection->handle,
      connection->write_buffer + connection->write_offset, remaining, NULL,
      &connection->write_overlapped);
    if (written) {
      DWORD count = 0;
      if (!GetOverlappedResult(connection->handle, &connection->write_overlapped,
          &count, FALSE) || count == 0)
        return -1;
      connection->write_offset += count;
      continue;
    }
    DWORD error = GetLastError();
    if (error == ERROR_IO_PENDING) {
      connection->write_pending = 1;
      return 0;
    }
    return -1;
  }
}

static int connection_gc(lua_State *L) {
  workbench_connection *connection = luaL_checkudata(L, 1, WORKBENCH_CONNECTION);
  if (!connection->closed) {
    clear_write_buffer(connection);
    clear_read_state(connection);
    CloseHandle(connection->handle);
    connection->handle = INVALID_HANDLE_VALUE;
    connection->closed = 1;
  } else {
    clear_write_buffer(connection);
    clear_read_state(connection);
  }
  return 0;
}

static int server_gc(lua_State *L) {
  workbench_server *server = luaL_checkudata(L, 1, WORKBENCH_SERVER);
  if (!server->closed) {
    CloseHandle(server->handle);
    server->handle = INVALID_HANDLE_VALUE;
    server->closed = 1;
  }
  return 0;
}

static workbench_connection *check_connection(lua_State *L) {
  workbench_connection *connection = luaL_checkudata(L, 1, WORKBENCH_CONNECTION);
  if (connection->closed) luaL_error(L, "Workbench transport connection is closed");
  return connection;
}

static workbench_server *check_server(lua_State *L) {
  workbench_server *server = luaL_checkudata(L, 1, WORKBENCH_SERVER);
  if (server->closed) luaL_error(L, "Workbench transport server is closed");
  return server;
}

static int connection_close(lua_State *L) {
  workbench_connection *connection = luaL_checkudata(L, 1, WORKBENCH_CONNECTION);
  if (!connection->closed) {
    clear_write_buffer(connection);
    clear_read_state(connection);
    CloseHandle(connection->handle);
    connection->handle = INVALID_HANDLE_VALUE;
    connection->closed = 1;
  } else {
    clear_write_buffer(connection);
    clear_read_state(connection);
  }
  return 0;
}

static int connection_send(lua_State *L) {
  workbench_connection *connection = check_connection(L);
  size_t length;
  const char *data = luaL_checklstring(L, 2, &length);
  if (length > WORKBENCH_MAX_FRAME) return luaL_error(L, "Workbench frame is too large");
  uint32_t network_length = ((uint32_t)length >> 24)
    | (((uint32_t)length >> 8) & 0x0000ff00u)
    | (((uint32_t)length << 8) & 0x00ff0000u)
    | ((uint32_t)length << 24);
  if (connection->write_buffer) {
    int flushed;
    do {
      flushed = flush_write_buffer(connection);
      if (flushed == 0 && connection->write_event)
        WaitForSingleObject(connection->write_event, INFINITE);
    } while (flushed == 0);
    if (flushed < 0)
      return luaL_error(L, "failed to write Workbench named pipe: %lu",
        (unsigned long)GetLastError());
  }
  if (write_pipe(connection->handle, &network_length, sizeof(network_length)) < 0
      || write_pipe(connection->handle, data, length) < 0) {
    return luaL_error(L, "failed to write Workbench named pipe: %lu",
      (unsigned long)GetLastError());
  }
  lua_pushboolean(L, 1);
  return 1;
}

static int connection_send_nonblocking(lua_State *L) {
  workbench_connection *connection = check_connection(L);
  size_t length;
  const char *data = luaL_checklstring(L, 2, &length);
  if (length > WORKBENCH_MAX_FRAME) return luaL_error(L, "Workbench frame is too large");
  if (connection->write_buffer) {
    int flushed = flush_write_buffer(connection);
    if (flushed == 0) {
      lua_pushnil(L);
      lua_pushliteral(L, "would_block");
      return 2;
    }
    if (flushed < 0) {
      connection->closed = 1;
      clear_write_buffer(connection);
      CloseHandle(connection->handle);
      connection->handle = INVALID_HANDLE_VALUE;
      lua_pushnil(L);
      lua_pushliteral(L, "closed");
      return 2;
    }
  }
  if (!build_frame(data, length, &connection->write_buffer,
      &connection->write_length))
    return luaL_error(L, "out of memory writing Workbench frame");
  connection->write_offset = 0;
  int flushed = flush_write_buffer(connection);
  if (flushed > 0) {
    lua_pushboolean(L, 1);
    return 1;
  }
  if (flushed == 0) {
    lua_pushnil(L);
    lua_pushliteral(L, "would_block");
    return 2;
  }
  connection->closed = 1;
  clear_write_buffer(connection);
  CloseHandle(connection->handle);
  connection->handle = INVALID_HANDLE_VALUE;
  lua_pushnil(L);
  lua_pushliteral(L, "closed");
  return 2;
}

static int connection_flush(lua_State *L) {
  workbench_connection *connection = check_connection(L);
  if (!connection->write_buffer) {
    lua_pushboolean(L, 1);
    return 1;
  }
  int flushed = flush_write_buffer(connection);
  if (flushed > 0) {
    lua_pushboolean(L, 1);
    return 1;
  }
  if (flushed == 0) {
    lua_pushnil(L);
    lua_pushliteral(L, "would_block");
    return 2;
  }
  connection->closed = 1;
  clear_write_buffer(connection);
  CloseHandle(connection->handle);
  connection->handle = INVALID_HANDLE_VALUE;
  lua_pushnil(L);
  lua_pushliteral(L, "closed");
  return 2;
}

static int connection_receive(lua_State *L) {
  workbench_connection *connection = check_connection(L);
  int timeout_ms = (int)luaL_optinteger(L, 2, -1);
  int result;
  if (!connection->read_frame_active) {
    result = read_pipe(connection, connection->read_header,
      sizeof(connection->read_header), &connection->read_header_offset,
      timeout_ms);
    if (result == 0) {
      lua_pushnil(L);
      lua_pushliteral(L, "timeout");
      return 2;
    }
    if (result < 0) {
      connection->closed = 1;
      clear_write_buffer(connection);
      clear_read_state(connection);
      CloseHandle(connection->handle);
      connection->handle = INVALID_HANDLE_VALUE;
      lua_pushnil(L);
      lua_pushliteral(L, "closed");
      return 2;
    }

    uint32_t network_length;
    memcpy(&network_length, connection->read_header, sizeof(network_length));
    uint32_t length = ((network_length >> 24) & 0x000000ffu)
      | ((network_length >> 8) & 0x0000ff00u)
      | ((network_length << 8) & 0x00ff0000u)
      | (network_length << 24);
    if (length > WORKBENCH_MAX_FRAME) {
      clear_read_state(connection);
      return luaL_error(L, "Workbench frame is too large");
    }
    connection->read_length = length;
    connection->read_offset = 0;
    connection->read_frame_active = 1;
    if (length > 0) {
      connection->read_buffer = malloc(length);
      if (!connection->read_buffer) {
        clear_read_state(connection);
        return luaL_error(L, "out of memory reading Workbench frame");
      }
    }
  }

  result = read_pipe(connection, connection->read_buffer,
    connection->read_length, &connection->read_offset, timeout_ms);
  if (result == 0) {
    lua_pushnil(L);
    lua_pushliteral(L, "timeout");
    return 2;
  }
  if (result < 0) {
    connection->closed = 1;
    clear_write_buffer(connection);
    clear_read_state(connection);
    CloseHandle(connection->handle);
    connection->handle = INVALID_HANDLE_VALUE;
    lua_pushnil(L);
    lua_pushliteral(L, "closed");
    return 2;
  }
  lua_pushlstring(L, connection->read_buffer
    ? (const char *)connection->read_buffer : "", connection->read_length);
  clear_read_state(connection);
  return 1;
}

static int server_close(lua_State *L) {
  workbench_server *server = luaL_checkudata(L, 1, WORKBENCH_SERVER);
  if (!server->closed) {
    CloseHandle(server->handle);
    server->handle = INVALID_HANDLE_VALUE;
    server->closed = 1;
  }
  return 0;
}

static int server_accept(lua_State *L) {
  workbench_server *server = check_server(L);
  int timeout_ms = (int)luaL_optinteger(L, 2, -1);
  OVERLAPPED overlapped = {0};
  overlapped.hEvent = CreateEventA(NULL, TRUE, FALSE, NULL);
  if (!overlapped.hEvent) return luaL_error(L, "failed to create named pipe event");
  BOOL connected = ConnectNamedPipe(server->handle, &overlapped);
  DWORD connect_error = connected ? ERROR_SUCCESS : GetLastError();
  if (!connected && connect_error != ERROR_IO_PENDING
      && connect_error != ERROR_PIPE_CONNECTED) {
    CloseHandle(overlapped.hEvent);
    lua_pushnil(L);
    lua_pushfstring(L, "failed to accept Workbench named pipe: %lu",
      (unsigned long)connect_error);
    return 2;
  }
  if (!connected && connect_error != ERROR_PIPE_CONNECTED) {
    DWORD wait = WaitForSingleObject(overlapped.hEvent,
      timeout_ms < 0 ? INFINITE : (DWORD)timeout_ms);
    if (wait == WAIT_TIMEOUT) {
      CancelIoEx(server->handle, &overlapped);
      CloseHandle(overlapped.hEvent);
      CloseHandle(server->handle);
      server->handle = create_pipe(server->path);
      if (server->handle == INVALID_HANDLE_VALUE) server->closed = 1;
      lua_pushnil(L);
      lua_pushliteral(L, "timeout");
      return 2;
    }
    if (wait != WAIT_OBJECT_0) {
      CloseHandle(overlapped.hEvent);
      lua_pushnil(L);
      lua_pushliteral(L, "closed");
      return 2;
    }
  }
  CloseHandle(overlapped.hEvent);
  HANDLE connection_handle = server->handle;
  server->handle = create_pipe(server->path);
  if (server->handle == INVALID_HANDLE_VALUE) server->closed = 1;
  workbench_connection *connection = lua_newuserdata(L, sizeof(*connection));
  memset(connection, 0, sizeof(*connection));
  connection->handle = connection_handle;
  luaL_setmetatable(L, WORKBENCH_CONNECTION);
  return 1;
}

static int connect_socket(lua_State *L) {
  const char *endpoint = luaL_checkstring(L, 1);
  char name[WORKBENCH_ENDPOINT_MAX];
  if (!pipe_name(endpoint, name, sizeof(name)))
    return luaL_error(L, "Workbench endpoint path is too long");
  if (!WaitNamedPipeA(name, NMPWAIT_WAIT_FOREVER)) {
    lua_pushnil(L);
    lua_pushfstring(L, "failed to connect to Workbench named pipe: %lu",
      (unsigned long)GetLastError());
    return 2;
  }
  HANDLE handle = CreateFileA(name, GENERIC_READ | GENERIC_WRITE, 0, NULL,
    OPEN_EXISTING, FILE_FLAG_OVERLAPPED, NULL);
  if (handle == INVALID_HANDLE_VALUE) {
    lua_pushnil(L);
    lua_pushfstring(L, "failed to open Workbench named pipe: %lu",
      (unsigned long)GetLastError());
    return 2;
  }
  workbench_connection *connection = lua_newuserdata(L, sizeof(*connection));
  memset(connection, 0, sizeof(*connection));
  connection->handle = handle;
  luaL_setmetatable(L, WORKBENCH_CONNECTION);
  return 1;
}

static int listen_socket(lua_State *L) {
  const char *endpoint = luaL_checkstring(L, 1);
  char name[WORKBENCH_ENDPOINT_MAX];
  if (!pipe_name(endpoint, name, sizeof(name)))
    return luaL_error(L, "Workbench endpoint path is too long");
  HANDLE handle = create_pipe(name);
  if (handle == INVALID_HANDLE_VALUE) {
    lua_pushnil(L);
    lua_pushfstring(L, "failed to listen for Workbench named pipe: %lu",
      (unsigned long)GetLastError());
    return 2;
  }
  workbench_server *server = lua_newuserdata(L, sizeof(*server));
  server->handle = handle;
  server->closed = 0;
  strcpy(server->path, name);
  luaL_setmetatable(L, WORKBENCH_SERVER);
  return 1;
}
#endif

int luaopen_workbench_transport(lua_State *L) {
  static const luaL_Reg connection_methods[] = {
    { "send", connection_send },
    { "send_nonblocking", connection_send_nonblocking },
    { "flush", connection_flush },
    { "receive", connection_receive },
    { "close", connection_close },
    { "__gc", connection_gc },
    { NULL, NULL },
  };
  static const luaL_Reg server_methods[] = {
    { "accept", server_accept },
    { "close", server_close },
    { "__gc", server_gc },
    { NULL, NULL },
  };
  luaL_newmetatable(L, WORKBENCH_CONNECTION);
  luaL_setfuncs(L, connection_methods, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);
  luaL_newmetatable(L, WORKBENCH_SERVER);
  luaL_setfuncs(L, server_methods, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);
#ifndef _WIN32
  static const luaL_Reg library[] = {
    { "connect", connect_socket },
    { "listen", listen_socket },
    { NULL, NULL },
  };
#else
  static const luaL_Reg library[] = {
    { "connect", connect_socket },
    { "listen", listen_socket },
    { NULL, NULL },
  };
#endif
  luaL_newlib(L, library);
  return 1;
}
