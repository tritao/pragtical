#include "api/api.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#include "terminal_runtime.h"

#ifdef _WIN32
#include <windows.h>
#endif

#define WORKBENCH_RUNTIME "WorkbenchRuntime"
#define WORKBENCH_RUNTIME_MAX_ARGUMENTS 255
#define WORKBENCH_RUNTIME_MAX_ENVIRONMENT 255
#define WORKBENCH_RUNTIME_MAX_OUTPUT (16u * 1024u * 1024u)

typedef struct {
  terminal_runtime_t *runtime;
} workbench_runtime;

typedef struct {
  char *data;
  size_t length;
  size_t capacity;
  int failed;
} output_buffer;

static workbench_runtime *check_runtime(lua_State *L) {
  workbench_runtime *runtime = luaL_checkudata(L, 1, WORKBENCH_RUNTIME);
  if (!runtime->runtime)
    luaL_error(L, "Workbench runtime is closed");
  return runtime;
}

static void free_strings(char **values) {
  if (!values) return;
  for (int index = 0; values[index]; ++index)
    free(values[index]);
  free(values);
}

static char *copy_string(const char *value) {
  size_t length = strlen(value) + 1;
  char *result = malloc(length);
  if (result) memcpy(result, value, length);
  return result;
}

static char **copy_arguments(lua_State *L, int index, const char *command) {
  index = lua_absindex(L, index);
  char **arguments = calloc(WORKBENCH_RUNTIME_MAX_ARGUMENTS + 2, sizeof(*arguments));
  if (!arguments) return NULL;
  arguments[0] = copy_string(command);
  if (!arguments[0]) {
    free_strings(arguments);
    return NULL;
  }
  if (!lua_istable(L, index)) return arguments;
  for (int item = 1; item <= WORKBENCH_RUNTIME_MAX_ARGUMENTS; ++item) {
    lua_rawgeti(L, index, item);
    if (lua_isnil(L, -1)) {
      lua_pop(L, 1);
      break;
    }
    const char *value = luaL_checkstring(L, -1);
    arguments[item] = copy_string(value);
    lua_pop(L, 1);
    if (!arguments[item]) {
      free_strings(arguments);
      return NULL;
    }
  }
  return arguments;
}

static char **copy_environment(lua_State *L, int index) {
  index = lua_absindex(L, index);
#ifdef _WIN32
  wchar_t *keys[WORKBENCH_RUNTIME_MAX_ENVIRONMENT] = {0};
  wchar_t *values[WORKBENCH_RUNTIME_MAX_ENVIRONMENT] = {0};
  int count = 0;
  if (lua_istable(L, index)) {
    lua_pushnil(L);
    while (count < WORKBENCH_RUNTIME_MAX_ENVIRONMENT && lua_next(L, index) != 0) {
      const char *key = luaL_checkstring(L, -2);
      const char *value = luaL_checkstring(L, -1);
      int key_length = MultiByteToWideChar(CP_UTF8, 0, key, -1, NULL, 0);
      int value_length = MultiByteToWideChar(CP_UTF8, 0, value, -1, NULL, 0);
      if (key_length <= 0 || value_length <= 0) {
        lua_pop(L, 1);
        lua_settop(L, index);
        goto error;
      }
      keys[count] = malloc(sizeof(wchar_t) * (size_t)key_length);
      values[count] = malloc(sizeof(wchar_t) * (size_t)value_length);
      if (!keys[count] || !values[count]
          || !MultiByteToWideChar(CP_UTF8, 0, key, -1, keys[count], key_length)
          || !MultiByteToWideChar(CP_UTF8, 0, value, -1, values[count], value_length)) {
        lua_pop(L, 1);
        lua_settop(L, index);
        goto error;
      }
      ++count;
      lua_pop(L, 1);
    }
  }
  if (count == 0) return calloc(1, sizeof(char *));
  size_t length = 1;
  for (int item = 0; item < count; ++item) {
    size_t key_length = wcslen(keys[item]);
    size_t value_length = wcslen(values[item]);
    if (key_length > SIZE_MAX - 3
        || value_length > SIZE_MAX - key_length - 3) {
      lua_settop(L, index);
      goto error;
    }
    length += key_length + value_length + 2;
  }
  wchar_t *block = calloc(length, sizeof(wchar_t));
  char **environment = calloc(2, sizeof(char *));
  if (!block || !environment) {
    free(block);
    free(environment);
    goto error;
  }
  wchar_t *cursor = block;
  for (int item = 0; item < count; ++item) {
    size_t key_length = wcslen(keys[item]);
    size_t value_length = wcslen(values[item]);
    memcpy(cursor, keys[item], key_length * sizeof(wchar_t));
    cursor += key_length;
    *cursor++ = L'=';
    memcpy(cursor, values[item], (value_length + 1) * sizeof(wchar_t));
    cursor += value_length + 1;
  }
  for (int item = 0; item < count; ++item) {
    free(keys[item]);
    free(values[item]);
  }
  environment[0] = (char *)block;
  return environment;

error:
  for (int item = 0; item < count; ++item) {
    free(keys[item]);
    free(values[item]);
  }
  return NULL;
#else
  char **environment = calloc(WORKBENCH_RUNTIME_MAX_ENVIRONMENT * 2 + 1,
    sizeof(*environment));
  if (!environment) return NULL;
  if (!lua_istable(L, index)) return environment;
  lua_pushnil(L);
  int item = 0;
  while (lua_next(L, index) != 0 && item < WORKBENCH_RUNTIME_MAX_ENVIRONMENT * 2) {
    const char *key = luaL_checkstring(L, -2);
    const char *value = luaL_checkstring(L, -1);
    environment[item++] = copy_string(key);
    environment[item++] = copy_string(value);
    lua_pop(L, 1);
    if (!environment[item - 1] || !environment[item - 2]) {
      free_strings(environment);
      return NULL;
    }
  }
  return environment;
#endif
}

static int runtime_gc(lua_State *L) {
  workbench_runtime *runtime = luaL_checkudata(L, 1, WORKBENCH_RUNTIME);
  if (runtime->runtime) {
    terminal_runtime_free(runtime->runtime);
    runtime->runtime = NULL;
  }
  return 0;
}

static int runtime_new(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  lua_getfield(L, 1, "command");
  const char *command = luaL_optstring(L, -1, NULL);
  lua_getfield(L, 1, "shell");
  if (!command) command = luaL_optstring(L, -1, NULL);
  if (!command) return luaL_error(L, "Workbench runtime requires a command or shell");
  lua_pop(L, 2);

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
  lua_getfield(L, 1, "args");
  char **arguments = copy_arguments(L, -1, command);
  lua_pop(L, 1);
  lua_getfield(L, 1, "environment");
  char **environment = copy_environment(L, -1);
  lua_pop(L, 1);
  lua_getfield(L, 1, "cwd");
  const char *cwd = luaL_optstring(L, -1, NULL);
  lua_pop(L, 1);
  if (!arguments || !environment) {
    free_strings(arguments);
    free_strings(environment);
    return luaL_error(L, "failed to allocate Workbench runtime arguments");
  }

  terminal_runtime_t *native = terminal_runtime_new(columns, rows, scrollback,
    term, command, (const char **)arguments, (const char **)environment, cwd);
  free_strings(arguments);
  free_strings(environment);
  if (!native)
    return luaL_error(L, "failed to create Workbench runtime: %s",
      terminal_runtime_last_error());
  workbench_runtime *runtime = lua_newuserdata(L, sizeof(*runtime));
  runtime->runtime = native;
  luaL_setmetatable(L, WORKBENCH_RUNTIME);
  return 1;
}

static void output_callback(char *data, int length, void *user_data) {
  output_buffer *buffer = user_data;
  if (buffer->failed || length <= 0) return;
  size_t required = buffer->length + (size_t)length;
  if (required > WORKBENCH_RUNTIME_MAX_OUTPUT) {
    buffer->failed = 1;
    return;
  }
  if (required > buffer->capacity) {
    size_t capacity = buffer->capacity ? buffer->capacity : 4096;
    while (capacity < required) capacity *= 2;
    char *data_copy = realloc(buffer->data, capacity);
    if (!data_copy) {
      buffer->failed = 1;
      return;
    }
    buffer->data = data_copy;
    buffer->capacity = capacity;
  }
  memcpy(buffer->data + buffer->length, data, (size_t)length);
  buffer->length = required;
}

static int runtime_poll(lua_State *L) {
  workbench_runtime *runtime = check_runtime(L);
  output_buffer buffer = {0};
  terminal_runtime_poll(runtime->runtime, output_callback, &buffer, NULL);
  if (buffer.failed) {
    free(buffer.data);
    return luaL_error(L, "Workbench runtime output exceeded the frame limit");
  }
  lua_pushlstring(L, buffer.data ? buffer.data : "", buffer.length);
  free(buffer.data);
  return 1;
}

static int runtime_write(lua_State *L) {
  workbench_runtime *runtime = check_runtime(L);
  size_t length;
  const char *data = luaL_checklstring(L, 2, &length);
  lua_pushinteger(L, terminal_runtime_write(runtime->runtime, data, length));
  return 1;
}

static int runtime_resize(lua_State *L) {
  workbench_runtime *runtime = check_runtime(L);
  terminal_runtime_resize(runtime->runtime, (int)luaL_checkinteger(L, 2),
    (int)luaL_checkinteger(L, 3));
  lua_pushboolean(L, 1);
  return 1;
}

static int runtime_exited(lua_State *L) {
  workbench_runtime *runtime = check_runtime(L);
  int exit_code, signal;
  if (!terminal_runtime_exited(runtime->runtime, &exit_code, &signal)) {
    lua_pushboolean(L, 0);
    return 1;
  }
  lua_pushinteger(L, exit_code);
  lua_pushinteger(L, signal);
  return 2;
}

static int runtime_close(lua_State *L) {
  workbench_runtime *runtime = check_runtime(L);
  terminal_runtime_free(runtime->runtime);
  runtime->runtime = NULL;
  lua_pushboolean(L, 1);
  return 1;
}

int luaopen_workbench_runtime(lua_State *L) {
  static const luaL_Reg methods[] = {
    { "__gc", runtime_gc },
    { "write", runtime_write },
    { "resize", runtime_resize },
    { "poll", runtime_poll },
    { "exited", runtime_exited },
    { "close", runtime_close },
    { NULL, NULL },
  };
  luaL_newmetatable(L, WORKBENCH_RUNTIME);
  luaL_setfuncs(L, methods, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);
  static const luaL_Reg functions[] = {
    { "new", runtime_new },
    { NULL, NULL },
  };
  luaL_newlib(L, functions);
  return 1;
}
