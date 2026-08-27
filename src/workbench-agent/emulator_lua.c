#include "api/api.h"

#include <stdlib.h>

#include "terminal_emulator.h"

#define WORKBENCH_EMULATOR "WorkbenchEmulator"

typedef struct {
  terminal_emulator_t *emulator;
} workbench_emulator;

static workbench_emulator *check_emulator(lua_State *L) {
  workbench_emulator *emulator = luaL_checkudata(L, 1, WORKBENCH_EMULATOR);
  if (!emulator->emulator)
    luaL_error(L, "Workbench emulator is closed");
  return emulator;
}

static int emulator_gc(lua_State *L) {
  workbench_emulator *emulator = luaL_checkudata(L, 1, WORKBENCH_EMULATOR);
  if (emulator->emulator) {
    terminal_emulator_free(emulator->emulator);
    emulator->emulator = NULL;
  }
  return 0;
}

static int emulator_new(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  lua_getfield(L, 1, "columns");
  int columns = (int)luaL_optinteger(L, -1, 80);
  lua_pop(L, 1);
  lua_getfield(L, 1, "rows");
  int rows = (int)luaL_optinteger(L, -1, 24);
  lua_pop(L, 1);
  lua_getfield(L, 1, "scrollback_limit");
  int scrollback = (int)luaL_optinteger(L, -1, 10000);
  lua_pop(L, 1);
  lua_getfield(L, 1, "term");
  const char *term = luaL_optstring(L, -1, "xterm-256color");
  lua_pop(L, 1);

  if (columns < 1 || rows < 1 || scrollback < 1)
    return luaL_error(L, "Workbench emulator dimensions are invalid");
  terminal_emulator_t *native = terminal_emulator_new(columns, rows,
    scrollback, term);
  if (!native) return luaL_error(L, "failed to create Workbench emulator");

  workbench_emulator *emulator = lua_newuserdata(L, sizeof(*emulator));
  emulator->emulator = native;
  luaL_setmetatable(L, WORKBENCH_EMULATOR);
  return 1;
}

static int emulator_feed(lua_State *L) {
  workbench_emulator *emulator = check_emulator(L);
  size_t length;
  const char *data = luaL_checklstring(L, 2, &length);
  lua_pushinteger(L, terminal_emulator_feed(emulator->emulator, data, length));
  return 1;
}

static int emulator_checkpoint(lua_State *L) {
  workbench_emulator *emulator = check_emulator(L);
  size_t size = terminal_emulator_checkpoint_size(emulator->emulator);
  if (!size) return luaL_error(L, "failed to size Workbench emulator checkpoint");
  char *data = malloc(size);
  if (!data) return luaL_error(L, "failed to allocate Workbench emulator checkpoint");
  size_t written = 0;
  if (!terminal_emulator_checkpoint(emulator->emulator, data, size, &written)) {
    free(data);
    return luaL_error(L, "failed to serialize Workbench emulator checkpoint");
  }
  lua_pushlstring(L, data, written);
  free(data);
  return 1;
}

static int emulator_restore_checkpoint(lua_State *L) {
  workbench_emulator *emulator = check_emulator(L);
  size_t length;
  const char *data = luaL_checklstring(L, 2, &length);
  if (!terminal_emulator_restore_checkpoint(emulator->emulator, data, length)) {
    lua_pushboolean(L, 0);
    lua_pushliteral(L, "invalid Workbench emulator checkpoint");
    return 2;
  }
  lua_pushboolean(L, 1);
  return 1;
}

static int emulator_close(lua_State *L) {
  workbench_emulator *emulator = check_emulator(L);
  terminal_emulator_free(emulator->emulator);
  emulator->emulator = NULL;
  lua_pushboolean(L, 1);
  return 1;
}

int luaopen_workbench_emulator(lua_State *L) {
  static const luaL_Reg methods[] = {
    { "__gc", emulator_gc },
    { "feed", emulator_feed },
    { "checkpoint", emulator_checkpoint },
    { "restore_checkpoint", emulator_restore_checkpoint },
    { "close", emulator_close },
    { NULL, NULL },
  };
  luaL_newmetatable(L, WORKBENCH_EMULATOR);
  luaL_setfuncs(L, methods, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);
  static const luaL_Reg functions[] = {
    { "new", emulator_new },
    { NULL, NULL },
  };
  luaL_newlib(L, functions);
  return 1;
}
