#include "api/api.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef _WIN32
#include <sys/stat.h>
#else
#include <direct.h>
#include <sys/stat.h>
#endif

#ifndef PRAGTICAL_SOURCE_DATA_DIR
#define PRAGTICAL_SOURCE_DATA_DIR "data"
#endif

int luaopen_sqlite(lua_State *L);
int luaopen_workbench_transport(lua_State *L);
int luaopen_workbench_runtime(lua_State *L);

typedef struct {
  const char *data_root;
  const char *data_dir;
  const char *endpoint;
  const char *workspace;
  int once;
} agent_options;

static int system_get_file_info(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  struct stat info;
  if (stat(path, &info) != 0) {
    lua_pushnil(L);
    return 1;
  }
  lua_newtable(L);
  lua_pushstring(L, S_ISDIR(info.st_mode) ? "dir" : "file");
  lua_setfield(L, -2, "type");
  lua_pushinteger(L, (lua_Integer)info.st_size);
  lua_setfield(L, -2, "size");
  return 1;
}

static int system_mkdir(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
#ifdef _WIN32
  int result = _mkdir(path);
#else
  int result = mkdir(path, 0755);
#endif
  if (result == 0) {
    lua_pushboolean(L, 1);
    return 1;
  }
  lua_pushnil(L);
  lua_pushstring(L, strerror(errno));
  return 2;
}

static int system_absolute_path(lua_State *L) {
  lua_pushvalue(L, 1);
  return 1;
}

static void install_system_stub(lua_State *L) {
  static const luaL_Reg functions[] = {
    { "get_file_info", system_get_file_info },
    { "mkdir", system_mkdir },
    { "absolute_path", system_absolute_path },
    { NULL, NULL },
  };
  luaL_newlib(L, functions);
  lua_setglobal(L, "system");
}

static void set_global_string(lua_State *L, const char *name, const char *value) {
  lua_pushstring(L, value);
  lua_setglobal(L, name);
}

static int set_lua_paths(lua_State *L, const char *data_root) {
  lua_getglobal(L, "package");
  lua_getfield(L, -1, "path");
  const char *old_path = lua_tostring(L, -1);
  size_t length = strlen(data_root) * 2 + (old_path ? strlen(old_path) : 0) + 32;
  char *path = malloc(length);
  if (!path) {
    lua_pop(L, 2);
    return 0;
  }
  snprintf(path, length, "%s/?.lua;%s/?/init.lua;%s",
    data_root, data_root, old_path ? old_path : "");
  lua_pop(L, 1);
  lua_pushstring(L, path);
  lua_setfield(L, -2, "path");
  lua_pop(L, 1);
  free(path);
  return 1;
}

static void register_module(lua_State *L, const char *name, lua_CFunction loader) {
  luaL_requiref(L, name, loader, 1);
  lua_pop(L, 1);
}

static void usage(const char *program) {
  fprintf(stderr, "Usage: %s [--data-root PATH] [--data-dir PATH] [--endpoint PATH] "
    "[--workspace ID] [--once]\n", program);
}

static int parse_options(int argc, char **argv, agent_options *options) {
  options->data_root = PRAGTICAL_SOURCE_DATA_DIR;
  options->data_dir = getenv("PRAGTICAL_USERDIR");
  if (!options->data_dir) options->data_dir = ".pragtical-agent";
  options->endpoint = NULL;
  options->workspace = "default";
  options->once = 0;
  for (int index = 1; index < argc; ++index) {
    const char *argument = argv[index];
    if (strcmp(argument, "--once") == 0) {
      options->once = 1;
    } else if (strcmp(argument, "--data-root") == 0 && index + 1 < argc) {
      options->data_root = argv[++index];
    } else if (strcmp(argument, "--data-dir") == 0 && index + 1 < argc) {
      options->data_dir = argv[++index];
    } else if (strcmp(argument, "--endpoint") == 0 && index + 1 < argc) {
      options->endpoint = argv[++index];
    } else if (strcmp(argument, "--workspace") == 0 && index + 1 < argc) {
      options->workspace = argv[++index];
    } else if (strcmp(argument, "--help") == 0) {
      usage(argv[0]);
      return 0;
    } else {
      usage(argv[0]);
      return -1;
    }
  }
  return 1;
}

static int run_agent(lua_State *L, const agent_options *options) {
  const char *separator = "/";
  size_t path_length = strlen(options->data_dir) + strlen(separator)
    + strlen("workbench.sqlite3") + 1;
  char *storage_path = malloc(path_length);
  if (!storage_path) return 0;
  snprintf(storage_path, path_length, "%s%sworkbench.sqlite3",
    options->data_dir, separator);

  const char *endpoint = options->endpoint;
  size_t endpoint_length = 0;
  char *default_endpoint = NULL;
  if (!endpoint) {
    endpoint_length = strlen(options->data_dir) + strlen(separator)
      + strlen("workbench.sock") + 1;
    default_endpoint = malloc(endpoint_length);
    if (!default_endpoint) {
      free(storage_path);
      return 0;
    }
    snprintf(default_endpoint, endpoint_length, "%s%sworkbench.sock",
      options->data_dir, separator);
    endpoint = default_endpoint;
  }

  lua_getglobal(L, "require");
  lua_pushliteral(L, "plugins.workbench.agent");
  if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
    fprintf(stderr, "Unable to load Workbench agent: %s\n", lua_tostring(L, -1));
    lua_pop(L, 1);
    free(default_endpoint);
    free(storage_path);
    return 0;
  }
  lua_getfield(L, -1, "run");
  lua_newtable(L);
  lua_pushstring(L, options->data_dir);
  lua_setfield(L, -2, "data_dir");
  lua_pushstring(L, storage_path);
  lua_setfield(L, -2, "storage_path");
  lua_pushstring(L, endpoint);
  lua_setfield(L, -2, "endpoint");
  lua_pushstring(L, options->workspace);
  lua_setfield(L, -2, "workspace_id");
  lua_pushboolean(L, options->once);
  lua_setfield(L, -2, "once");
  if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
    fprintf(stderr, "Workbench agent failed: %s\n", lua_tostring(L, -1));
    lua_pop(L, 2);
    free(default_endpoint);
    free(storage_path);
    return 0;
  }
  lua_pop(L, 2);
  free(default_endpoint);
  free(storage_path);
  return 1;
}

int main(int argc, char **argv) {
  agent_options options;
  int parsed = parse_options(argc, argv, &options);
  if (parsed <= 0) return parsed == 0 ? 0 : 2;

  lua_State *L = luaL_newstate();
  if (!L) {
    fprintf(stderr, "Unable to create the Workbench agent Lua state\n");
    return 1;
  }
  luaL_openlibs(L);
  set_global_string(L, "USERDIR", options.data_dir);
  set_global_string(L, "PATHSEP", "/");
  set_global_string(L, "PLATFORM", "agent");
  lua_pushboolean(L, 1);
  lua_setglobal(L, "PRAGTICAL_AGENT");
  install_system_stub(L);
  if (!set_lua_paths(L, options.data_root)) {
    fprintf(stderr, "Unable to configure Workbench agent Lua paths\n");
    lua_close(L);
    return 1;
  }
  register_module(L, "sqlite", luaopen_sqlite);
  register_module(L, "workbench_transport", luaopen_workbench_transport);
  register_module(L, "workbench_runtime", luaopen_workbench_runtime);
  int result = run_agent(L, &options) ? 0 : 1;
  lua_close(L);
  return result;
}
