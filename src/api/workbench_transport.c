#include "api.h"

#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifndef _WIN32
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#endif

#define WORKBENCH_CONNECTION "WorkbenchTransportConnection"
#define WORKBENCH_SERVER "WorkbenchTransportServer"
#define WORKBENCH_MAX_FRAME (16u * 1024u * 1024u)
#ifndef _WIN32
#define WORKBENCH_ENDPOINT_MAX 108
#else
#define WORKBENCH_ENDPOINT_MAX 260
#endif

typedef struct {
  int fd;
  int closed;
} workbench_connection;

typedef struct {
  int fd;
  int closed;
  char path[WORKBENCH_ENDPOINT_MAX];
} workbench_server;

#ifndef _WIN32
static int wait_for_fd(int fd, short events, int timeout_ms) {
  struct pollfd descriptor = { fd, events, 0 };
  int result;
  do {
    result = poll(&descriptor, 1, timeout_ms);
  } while (result < 0 && errno == EINTR);
  if (result <= 0) return result;
  if (descriptor.revents & (POLLERR | POLLHUP | POLLNVAL)) return -1;
  return 1;
}

static int read_all(int fd, void *buffer, size_t length, int timeout_ms) {
  char *cursor = buffer;
  while (length > 0) {
    int ready = wait_for_fd(fd, POLLIN, timeout_ms);
    if (ready <= 0) return ready;
    ssize_t count = read(fd, cursor, length);
    if (count == 0) return -1;
    if (count < 0) {
      if (errno == EINTR) continue;
      if (errno == EAGAIN || errno == EWOULDBLOCK) continue;
      return -1;
    }
    cursor += count;
    length -= (size_t)count;
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
    cursor += count;
    length -= (size_t)count;
  }
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
  if (write_all(connection->fd, &network_length, sizeof(network_length)) < 0
      || write_all(connection->fd, data, length) < 0) {
    return luaL_error(L, "failed to write Workbench frame: %s", strerror(errno));
  }
  lua_pushboolean(L, 1);
  return 1;
}

static int connection_receive(lua_State *L) {
  workbench_connection *connection = check_connection(L);
  int timeout_ms = (int)luaL_optinteger(L, 2, -1);
  uint32_t network_length;
  int result = read_all(connection->fd, &network_length, sizeof(network_length), timeout_ms);
  if (result == 0) {
    lua_pushnil(L);
    lua_pushliteral(L, "timeout");
    return 2;
  }
  if (result < 0) {
    connection->closed = 1;
    close_fd(&connection->fd);
    lua_pushnil(L);
    lua_pushliteral(L, "closed");
    return 2;
  }
  uint32_t length = ((network_length >> 24) & 0x000000ffu)
    | ((network_length >> 8) & 0x0000ff00u)
    | ((network_length << 8) & 0x00ff0000u)
    | (network_length << 24);
  if (length > WORKBENCH_MAX_FRAME) return luaL_error(L, "Workbench frame is too large");
  char *data = malloc(length ? length : 1);
  if (!data) return luaL_error(L, "out of memory reading Workbench frame");
  result = read_all(connection->fd, data, length, timeout_ms);
  if (result <= 0) {
    free(data);
    connection->closed = 1;
    close_fd(&connection->fd);
    lua_pushnil(L);
    lua_pushliteral(L, "closed");
    return 2;
  }
  lua_pushlstring(L, data, length);
  free(data);
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
  int fd;
  do {
    fd = accept(server->fd, NULL, NULL);
  } while (fd < 0 && errno == EINTR);
  if (fd < 0) {
    lua_pushnil(L);
    lua_pushfstring(L, "failed to accept Workbench client: %s", strerror(errno));
    return 2;
  }
  workbench_connection *connection = lua_newuserdata(L, sizeof(*connection));
  connection->fd = fd;
  connection->closed = 0;
  luaL_setmetatable(L, WORKBENCH_CONNECTION);
  return 1;
}

static int connect_socket(lua_State *L) {
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
  if (connect(fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
    int error = errno;
    close(fd);
    lua_pushnil(L);
    lua_pushfstring(L, "failed to connect to Workbench agent: %s", strerror(error));
    return 2;
  }
  workbench_connection *connection = lua_newuserdata(L, sizeof(*connection));
  connection->fd = fd;
  connection->closed = 0;
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
  unlink(path);
  if (bind(fd, (struct sockaddr *)&address, sizeof(address)) < 0 || listen(fd, 8) < 0) {
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
static int unsupported(lua_State *L) {
  return luaL_error(L, "Workbench agent transport is not available on this platform yet");
}
#endif

int luaopen_workbench_transport(lua_State *L) {
#ifndef _WIN32
  static const luaL_Reg connection_methods[] = {
    { "send", connection_send },
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
  luaL_Reg library[] = {
    { "connect", connect_socket },
    { "listen", listen_socket },
    { NULL, NULL },
  };
#else
  luaL_Reg library[] = {
    { "connect", unsupported },
    { "listen", unsupported },
    { NULL, NULL },
  };
#endif
  luaL_newlib(L, library);
  return 1;
}
