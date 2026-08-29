#ifndef _WIN32
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif
#endif

#include "ctl_main.h"
#include "api/api.h"

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef _WIN32
#include <dirent.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#else
#include <direct.h>
#include <sys/stat.h>
#include <windows.h>
#endif

#ifndef PRAGTICAL_SOURCE_DATA_DIR
#define PRAGTICAL_SOURCE_DATA_DIR "data"
#endif

#ifndef _WIN32
int luaopen_local_transport(lua_State *L);
#else
int luaopen_local_transport(lua_State *L);
#endif

#define CTL_PATH_MAX 4096

static const char *ctl_base_name(const char *path) {
  const char *slash = strrchr(path, '/');
#ifdef _WIN32
  const char *backslash = strrchr(path, '\\');
  if (!slash || (backslash && backslash > slash)) slash = backslash;
#endif
  return slash ? slash + 1 : path;
}

int ctl_invocation(int argc, char **argv) {
  if (argc > 1 && strcmp(argv[1], "--ctl") == 0) return 1;
  const char *name = ctl_base_name(argv[0]);
#ifdef _WIN32
  return _stricmp(name, "pragtical-ctl.exe") == 0;
#else
  return strcmp(name, "pragtical-ctl") == 0;
#endif
}

static int path_join(char *destination, size_t capacity, const char *left,
    const char *right) {
  size_t length = strlen(left);
  while (length && (left[length - 1] == '/' || left[length - 1] == '\\')) length--;
  int written = snprintf(destination, capacity, "%.*s/%s", (int)length, left, right);
  return written >= 0 && (size_t)written < capacity;
}

static int is_directory(const char *path) {
  struct stat info;
  if (stat(path, &info) != 0) return 0;
#ifdef _WIN32
  return (info.st_mode & _S_IFMT) == _S_IFDIR;
#else
  return S_ISDIR(info.st_mode);
#endif
}

static int is_file(const char *path) {
  struct stat info;
  if (stat(path, &info) != 0) return 0;
#ifdef _WIN32
  return (info.st_mode & _S_IFMT) == _S_IFREG;
#else
  return S_ISREG(info.st_mode);
#endif
}

static int executable_directory(const char *argv0, char *directory, size_t capacity) {
  char executable[CTL_PATH_MAX] = { 0 };
#ifdef __linux__
  ssize_t read_length = readlink("/proc/self/exe", executable, sizeof(executable) - 1);
  if (read_length > 0) executable[read_length] = '\0';
#endif
  if (!executable[0] && argv0) snprintf(executable, sizeof(executable), "%s", argv0);
  char *slash = strrchr(executable, '/');
#ifdef _WIN32
  char *backslash = strrchr(executable, '\\');
  if (!slash || (backslash && backslash > slash)) slash = backslash;
#endif
  if (!slash) return 0;
  size_t directory_length = (size_t)(slash - executable);
  if (!directory_length) directory_length = 1;
  if (directory_length >= capacity) return 0;
  memcpy(directory, executable, directory_length); directory[directory_length] = '\0';
  return 1;
}

static int choose_userdir(const char *argv0, char *userdir, size_t capacity) {
  char executable_dir[CTL_PATH_MAX], candidate[CTL_PATH_MAX];
  if (executable_directory(argv0, executable_dir, sizeof(executable_dir))
      && path_join(candidate, sizeof(candidate), executable_dir, "user")
      && is_directory(candidate)) {
    snprintf(userdir, capacity, "%s", candidate); return 1;
  }
  const char *configured = getenv("PRAGTICAL_USERDIR");
  if (configured && *configured) { snprintf(userdir, capacity, "%s", configured); return strlen(configured) < capacity; }
  const char *config = getenv("XDG_CONFIG_HOME");
  if (config && *config) return path_join(userdir, capacity, config, "pragtical");
  const char *home = getenv(
#ifdef _WIN32
    "USERPROFILE"
#else
    "HOME"
#endif
  );
  if (!home || !*home) return 0;
  if (!path_join(candidate, sizeof(candidate), home, ".config")) return 0;
  return path_join(userdir, capacity, candidate, "pragtical");
}

static int choose_data_root(const char *argv0, char *data_root, size_t capacity) {
  char executable_dir[CTL_PATH_MAX], candidate[CTL_PATH_MAX], parent[CTL_PATH_MAX];
  if (executable_directory(argv0, executable_dir, sizeof(executable_dir))) {
    const char *prefix = getenv("PRAGTICAL_PREFIX");
    if (prefix && *prefix && path_join(candidate, sizeof(candidate), prefix, "share/pragtical")
        && path_join(parent, sizeof(parent), candidate, "core/control/cli.lua") && is_file(parent)) {
      snprintf(data_root, capacity, "%s", candidate); return 1;
    }
    if (path_join(candidate, sizeof(candidate), executable_dir, "../share/pragtical")
        && path_join(parent, sizeof(parent), candidate, "core/control/cli.lua") && is_file(parent)) {
      snprintf(data_root, capacity, "%s", candidate); return 1;
    }
    if (path_join(candidate, sizeof(candidate), executable_dir, "data")
        && path_join(parent, sizeof(parent), candidate, "core/control/cli.lua") && is_file(parent)) {
      snprintf(data_root, capacity, "%s", candidate); return 1;
    }
  }
  snprintf(data_root, capacity, "%s", PRAGTICAL_SOURCE_DATA_DIR);
  return is_file("" PRAGTICAL_SOURCE_DATA_DIR "/core/control/cli.lua");
}

static void push_global_string(lua_State *L, const char *name, const char *value) {
  lua_pushstring(L, value ? value : ""); lua_setglobal(L, name);
}

static int ctl_get_file_info(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  struct stat info;
  if (stat(path, &info) != 0) { lua_pushnil(L); lua_pushstring(L, strerror(errno)); return 2; }
  lua_newtable(L);
  lua_pushinteger(L, (lua_Integer)info.st_size); lua_setfield(L, -2, "size");
#ifdef _WIN32
  int is_dir = (info.st_mode & _S_IFMT) == _S_IFDIR;
  int is_reg = (info.st_mode & _S_IFMT) == _S_IFREG;
#else
  int is_dir = S_ISDIR(info.st_mode);
  int is_reg = S_ISREG(info.st_mode);
#endif
  lua_pushstring(L, is_dir ? "dir" : is_reg ? "file" : "other"); lua_setfield(L, -2, "type");
  struct stat link_info;
#ifndef _WIN32
  lua_pushboolean(L, lstat(path, &link_info) == 0 && S_ISLNK(link_info.st_mode));
#else
  lua_pushboolean(L, 0);
#endif
  lua_setfield(L, -2, "symlink");
  return 1;
}

static int ctl_absolute_path(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
#ifdef _WIN32
  char absolute[CTL_PATH_MAX];
  if (!_fullpath(absolute, path, sizeof(absolute))) return 0;
  lua_pushstring(L, absolute);
#else
  char *absolute = realpath(path, NULL);
  if (!absolute) return 0;
  lua_pushstring(L, absolute); free(absolute);
#endif
  return 1;
}

static int ctl_getcwd(lua_State *L) {
  char cwd[CTL_PATH_MAX];
  if (!getcwd(cwd, sizeof(cwd))) return 0;
  lua_pushstring(L, cwd); return 1;
}

static int ctl_list_dir(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
#ifndef _WIN32
  DIR *directory = opendir(path);
  if (!directory) { lua_pushnil(L); lua_pushstring(L, strerror(errno)); return 2; }
  lua_newtable(L); lua_Integer index = 1; struct dirent *entry;
  while ((entry = readdir(directory))) {
    if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
    lua_pushstring(L, entry->d_name); lua_rawseti(L, -2, index++);
  }
  closedir(directory); return 1;
#else
  char pattern[CTL_PATH_MAX]; if (!path_join(pattern, sizeof(pattern), path, "*")) return 0;
  WIN32_FIND_DATAA data; HANDLE search = FindFirstFileA(pattern, &data);
  if (search == INVALID_HANDLE_VALUE) { lua_pushnil(L); lua_pushfstring(L, "Windows directory error: %lu", (unsigned long)GetLastError()); return 2; }
  lua_newtable(L); lua_Integer index = 1;
  do {
    if (strcmp(data.cFileName, ".") && strcmp(data.cFileName, "..")) { lua_pushstring(L, data.cFileName); lua_rawseti(L, -2, index++); }
  } while (FindNextFileA(search, &data));
  FindClose(search); return 1;
#endif
}

static int ctl_get_time(lua_State *L) {
#ifdef _WIN32
  lua_pushnumber(L, GetTickCount64() / 1000.0);
#else
  struct timespec time; clock_gettime(CLOCK_MONOTONIC, &time);
  lua_pushnumber(L, (lua_Number)time.tv_sec + time.tv_nsec / 1000000000.0);
#endif
  return 1;
}

static int ctl_sleep(lua_State *L) {
  lua_Number seconds = luaL_checknumber(L, 1);
#ifdef _WIN32
  if (seconds > 0) Sleep((DWORD)(seconds * 1000.0));
#else
  if (seconds > 0) {
    struct timespec duration = { (time_t)seconds, (long)((seconds - (time_t)seconds) * 1000000000.0) };
    nanosleep(&duration, NULL);
  }
#endif
  return 0;
}

static int ctl_get_process_id(lua_State *L) {
#ifdef _WIN32
  lua_pushinteger(L, (lua_Integer)GetCurrentProcessId());
#else
  lua_pushinteger(L, (lua_Integer)getpid());
#endif
  return 1;
}

static void install_headless_system(lua_State *L) {
  static const luaL_Reg functions[] = {
    { "get_file_info", ctl_get_file_info },
    { "absolute_path", ctl_absolute_path },
    { "getcwd", ctl_getcwd },
    { "list_dir", ctl_list_dir },
    { "get_time", ctl_get_time },
    { "sleep", ctl_sleep },
    { "get_process_id", ctl_get_process_id },
    { NULL, NULL },
  };
  luaL_newlib(L, functions); lua_setglobal(L, "system");
}

static int configure_lua(lua_State *L, const char *data_root,
    const char *userdir, int argc, char **argv) {
  push_global_string(L, "PATHSEP",
#ifdef _WIN32
    "\\"
#else
    "/"
#endif
  );
  push_global_string(L, "PLATFORM",
#ifdef _WIN32
    "Windows"
#else
    "headless"
#endif
  );
  push_global_string(L, "USERDIR", userdir);
  const char *home = getenv(
#ifdef _WIN32
    "USERPROFILE"
#else
    "HOME"
#endif
  );
  push_global_string(L, "HOME", home);
  lua_newtable(L);
  int start = argc > 1 && strcmp(argv[1], "--ctl") == 0 ? 2 : 1;
  for (int i = start; i < argc; ++i) { lua_pushstring(L, argv[i]); lua_rawseti(L, -2, i - start + 1); }
  lua_setglobal(L, "ARGS");
  lua_getglobal(L, "package"); lua_getfield(L, -1, "path");
  const char *old_path = lua_tostring(L, -1);
  size_t length = strlen(data_root) * 2 + (old_path ? strlen(old_path) : 0) + 16;
  char *path = malloc(length);
  if (!path) { lua_pop(L, 2); return 0; }
  snprintf(path, length, "%s/?.lua;%s/?/init.lua;%s", data_root, data_root, old_path ? old_path : "");
  lua_pop(L, 1); lua_pushstring(L, path); lua_setfield(L, -2, "path"); lua_pop(L, 1); free(path);
  return 1;
}

static int require_cli(lua_State *L) {
  lua_getglobal(L, "require"); lua_pushliteral(L, "core.control.cli");
  if (lua_pcall(L, 1, 1, 0) != LUA_OK) return 0;
  lua_getfield(L, -1, "run"); lua_remove(L, -2);
  return lua_isfunction(L, -1);
}

int ctl_main(int argc, char **argv) {
#ifdef _WIN32
  if (AttachConsole(ATTACH_PARENT_PROCESS)) {
    freopen("CONOUT$", "w", stdout); freopen("CONOUT$", "w", stderr); freopen("CONIN$", "r", stdin);
  }
#else
  signal(SIGPIPE, SIG_IGN);
#endif
  char data_root[CTL_PATH_MAX], userdir[CTL_PATH_MAX];
  if (!choose_data_root(argv[0], data_root, sizeof(data_root))
      || !choose_userdir(argv[0], userdir, sizeof(userdir))) {
    fprintf(stderr, "pragtical-ctl: could not locate the Pragtical data or user directory\n"); return 1;
  }
  lua_State *L = luaL_newstate();
  if (!L) { fprintf(stderr, "pragtical-ctl: could not create Lua state\n"); return 1; }
  luaL_openlibs(L); install_headless_system(L);
  if (!configure_lua(L, data_root, userdir, argc, argv)) {
    fprintf(stderr, "pragtical-ctl: could not configure Lua paths\n"); lua_close(L); return 1;
  }
#ifndef PRAGTICAL_NO_LOCAL_TRANSPORT
  luaL_requiref(L, "local_transport", luaopen_local_transport, 1); lua_pop(L, 1);
#endif
  if (!require_cli(L)) {
    fprintf(stderr, "pragtical-ctl: %s\n", lua_tostring(L, -1) ?: "could not load CLI"); lua_close(L); return 1;
  }
  lua_newtable(L);
  int start = argc > 1 && strcmp(argv[1], "--ctl") == 0 ? 2 : 1;
  for (int i = start; i < argc; ++i) { lua_pushstring(L, argv[i]); lua_rawseti(L, -2, i - start + 1); }
  lua_pushstring(L, argv[0]);
  if (lua_pcall(L, 2, 1, 0) != LUA_OK) {
    fprintf(stderr, "pragtical-ctl: %s\n", lua_tostring(L, -1) ?: "CLI failed"); lua_close(L); return 1;
  }
  int result = (int)luaL_optinteger(L, -1, 1); lua_close(L);
  return result < 0 ? 1 : result > 255 ? 255 : result;
}
