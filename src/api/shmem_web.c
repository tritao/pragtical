#include "api.h"

static int shmem_unsupported(lua_State *L) {
  luaL_checkstring(L, 1);
  luaL_checkinteger(L, 2);
  lua_pushnil(L);
  lua_pushliteral(L, "shared memory is not supported in web builds");
  return 2;
}

static const luaL_Reg shmem_web_lib[] = {
  { "open", shmem_unsupported },
  { NULL, NULL }
};

int luaopen_shmem(lua_State *L) {
  luaL_newlib(L, shmem_web_lib);
  return 1;
}
