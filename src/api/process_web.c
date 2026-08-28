#include "api.h"

enum {
  ERROR_PIPE = -1,
  ERROR_WOULDBLOCK = -2,
  ERROR_TIMEDOUT = -3,
  ERROR_INVAL = -4,
  ERROR_NOMEM = -5,
  WAIT_INFINITE = -1,
  WAIT_DEADLINE = -2,
  STREAM_STDIN = 0,
  STREAM_STDOUT = 1,
  STREAM_STDERR = 2,
  REDIRECT_DEFAULT = 0,
  REDIRECT_PIPE = 1,
  REDIRECT_PARENT = 2,
  REDIRECT_DISCARD = 3,
  REDIRECT_STDOUT = 4,
};

static int process_start_web(lua_State *L) {
  lua_pushnil(L);
  lua_pushliteral(L, "subprocesses are not supported in web builds");
  lua_pushinteger(L, ERROR_INVAL);
  return 3;
}

static int process_strerror_web(lua_State *L) {
  luaL_checkinteger(L, 1);
  lua_pushliteral(L, "subprocesses are not supported in web builds");
  return 1;
}

static const luaL_Reg process_web_lib[] = {
  { "start", process_start_web },
  { "strerror", process_strerror_web },
  { NULL, NULL }
};

int luaopen_process(lua_State *L) {
  luaL_newlib(L, process_web_lib);

  API_CONSTANT_DEFINE(L, -1, "ERROR_PIPE", ERROR_PIPE);
  API_CONSTANT_DEFINE(L, -1, "ERROR_WOULDBLOCK", ERROR_WOULDBLOCK);
  API_CONSTANT_DEFINE(L, -1, "ERROR_TIMEDOUT", ERROR_TIMEDOUT);
  API_CONSTANT_DEFINE(L, -1, "ERROR_INVAL", ERROR_INVAL);
  API_CONSTANT_DEFINE(L, -1, "ERROR_NOMEM", ERROR_NOMEM);
  API_CONSTANT_DEFINE(L, -1, "WAIT_INFINITE", WAIT_INFINITE);
  API_CONSTANT_DEFINE(L, -1, "WAIT_DEADLINE", WAIT_DEADLINE);
  API_CONSTANT_DEFINE(L, -1, "STREAM_STDIN", STREAM_STDIN);
  API_CONSTANT_DEFINE(L, -1, "STREAM_STDOUT", STREAM_STDOUT);
  API_CONSTANT_DEFINE(L, -1, "STREAM_STDERR", STREAM_STDERR);
  API_CONSTANT_DEFINE(L, -1, "REDIRECT_DEFAULT", REDIRECT_DEFAULT);
  API_CONSTANT_DEFINE(L, -1, "REDIRECT_PIPE", REDIRECT_PIPE);
  API_CONSTANT_DEFINE(L, -1, "REDIRECT_PARENT", REDIRECT_PARENT);
  API_CONSTANT_DEFINE(L, -1, "REDIRECT_DISCARD", REDIRECT_DISCARD);
  API_CONSTANT_DEFINE(L, -1, "REDIRECT_STDOUT", REDIRECT_STDOUT);

  return 1;
}
