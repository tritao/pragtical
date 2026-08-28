#include "api.h"

static int thread_unsupported(lua_State *L) {
  luaL_checkany(L, 1);
  lua_pushnil(L);
  lua_pushliteral(L, "native threads are not supported in single-threaded web builds");
  return 2;
}

static int thread_cpu_count(lua_State *L) {
  lua_pushinteger(L, 1);
  return 1;
}

static const luaL_Reg thread_web_lib[] = {
  { "create", thread_unsupported },
  { "get_channel", thread_unsupported },
  { "get_cpu_count", thread_cpu_count },
  { NULL, NULL }
};

int luaopen_thread(lua_State *L) {
  luaL_newlib(L, thread_web_lib);
  return 1;
}
