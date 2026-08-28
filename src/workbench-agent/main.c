#include "api/api.h"

#ifdef PRAGTICAL_NET
#include <SDL3/SDL.h>
#endif

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef _WIN32
#include <dirent.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#else
#include <direct.h>
#include <sys/stat.h>
#include <windows.h>
#endif

#ifndef PRAGTICAL_SOURCE_DATA_DIR
#define PRAGTICAL_SOURCE_DATA_DIR "data"
#endif

int luaopen_sqlite(lua_State *L);
int luaopen_workbench_transport(lua_State *L);
int luaopen_workbench_runtime(lua_State *L);
int luaopen_workbench_emulator(lua_State *L);
#ifdef PRAGTICAL_NET
int luaopen_net(lua_State *L);
#endif

typedef struct {
  const char *data_root;
  const char *data_dir;
  const char *endpoint;
  const char *storage_path;
  const char *workspace;
  int once;
} agent_options;

typedef struct {
#ifdef _WIN32
  HANDLE handle;
#else
  int fd;
#endif
} workbench_lock;

static char *copy_string(const char *value) {
  size_t length = value ? strlen(value) : 0;
  char *copy = malloc(length + 1);
  if (!copy) return NULL;
  if (length) memcpy(copy, value, length);
  copy[length] = '\0';
  return copy;
}

static char *join_path(const char *directory, const char *name) {
  size_t directory_length = strlen(directory);
  size_t name_length = strlen(name);
  int needs_separator = directory_length > 0
    && directory[directory_length - 1] != '/'
    && directory[directory_length - 1] != '\\';
  size_t length = directory_length + (size_t)needs_separator + name_length + 1;
  char *path = malloc(length);
  if (!path) return NULL;
  snprintf(path, length, "%s%s%s", directory,
    needs_separator ? "/" : "", name);
  return path;
}

static int is_directory(const struct stat *info) {
#ifdef _WIN32
  return (info->st_mode & _S_IFMT) == _S_IFDIR;
#else
  return S_ISDIR(info->st_mode);
#endif
}

static int make_directory(const char *path) {
#ifdef _WIN32
  if (_mkdir(path) == 0) return 1;
#else
  if (mkdir(path, 0700) == 0) return 1;
#endif
  if (errno != EEXIST) return 0;
  struct stat info;
  return stat(path, &info) == 0 && is_directory(&info);
}

static int ensure_directory(const char *path) {
  if (!path || !path[0]) return 0;
  char *copy = copy_string(path);
  if (!copy) return 0;
  for (char *cursor = copy; *cursor; ++cursor) {
    if (*cursor != '/' && *cursor != '\\') continue;
    if (cursor == copy || (cursor == copy + 2 && copy[1] == ':')) continue;
    char separator = *cursor;
    *cursor = '\0';
    if (copy[0] && !make_directory(copy)) {
      free(copy);
      return 0;
    }
    *cursor = separator;
  }
  int result = make_directory(copy);
  free(copy);
  return result;
}

/* Acquire ownership before Lua opens SQLite or the transport endpoint. This
   also means stale endpoint cleanup can never race another agent. */
static int acquire_workbench_lock(const char *path, workbench_lock *lock) {
#ifdef _WIN32
  lock->handle = CreateFileA(path, GENERIC_READ | GENERIC_WRITE, 0, NULL,
    OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  if (lock->handle == INVALID_HANDLE_VALUE) {
    /* The primary agent deliberately opens the lock without sharing. A
       second agent therefore reports the ownership conflict from CreateFile
       before it can reach LockFileEx. */
    return GetLastError() == ERROR_SHARING_VIOLATION ? 0 : -1;
  }
  OVERLAPPED overlapped = {0};
  if (LockFileEx(lock->handle, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY,
      0, 1, 0, &overlapped)) return 1;
  DWORD error = GetLastError();
  CloseHandle(lock->handle);
  lock->handle = INVALID_HANDLE_VALUE;
  return error == ERROR_LOCK_VIOLATION || error == ERROR_SHARING_VIOLATION ? 0 : -1;
#else
  int flags = O_RDWR | O_CREAT;
#ifdef O_CLOEXEC
  flags |= O_CLOEXEC;
#endif
  lock->fd = open(path, flags, 0600);
  if (lock->fd < 0) return -1;
  fchmod(lock->fd, 0600);
  struct flock request = {0};
  request.l_type = F_WRLCK;
  request.l_whence = SEEK_SET;
  if (fcntl(lock->fd, F_SETLK, &request) == 0) return 1;
  int error = errno;
  close(lock->fd);
  lock->fd = -1;
  return error == EACCES || error == EAGAIN ? 0 : -1;
#endif
}

static void release_workbench_lock(workbench_lock *lock) {
#ifdef _WIN32
  if (lock->handle != INVALID_HANDLE_VALUE) {
    OVERLAPPED overlapped = {0};
    UnlockFileEx(lock->handle, 0, 1, 0, &overlapped);
    CloseHandle(lock->handle);
    lock->handle = INVALID_HANDLE_VALUE;
  }
#else
  if (lock->fd >= 0) {
    struct flock request = {0};
    request.l_type = F_UNLCK;
    request.l_whence = SEEK_SET;
    fcntl(lock->fd, F_SETLK, &request);
    close(lock->fd);
    lock->fd = -1;
  }
#endif
}

static int system_get_file_info(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  struct stat info;
  if (stat(path, &info) != 0) {
    lua_pushnil(L);
    return 1;
  }
  lua_newtable(L);
  lua_pushstring(L, is_directory(&info) ? "dir" : "file");
  lua_setfield(L, -2, "type");
  lua_pushinteger(L, (lua_Integer)info.st_size);
  lua_setfield(L, -2, "size");
#ifndef _WIN32
  lua_pushinteger(L, (lua_Integer)info.st_dev);
  lua_setfield(L, -2, "device");
  lua_pushinteger(L, (lua_Integer)info.st_ino);
  lua_setfield(L, -2, "inode");
  lua_pushinteger(L, (lua_Integer)info.st_nlink);
  lua_setfield(L, -2, "links");
#endif
  return 1;
}

static int system_mkdir(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
#ifdef _WIN32
  int result = _mkdir(path);
#else
  int result = mkdir(path, 0700);
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

static int system_list_dir(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
#ifndef _WIN32
  DIR *directory = opendir(path);
  if (!directory) {
    lua_pushnil(L);
    lua_pushstring(L, strerror(errno));
    return 2;
  }
  lua_newtable(L);
  lua_Integer index = 1;
  struct dirent *entry;
  while ((entry = readdir(directory)) != NULL) {
    if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0)
      continue;
    lua_pushstring(L, entry->d_name);
    lua_rawseti(L, -2, index++);
  }
  closedir(directory);
  return 1;
#else
  size_t length = strlen(path) + 4;
  char *pattern = malloc(length);
  if (!pattern) return luaL_error(L, "out of memory listing Workbench files");
  snprintf(pattern, length, "%s\\*", path);
  WIN32_FIND_DATAA data;
  HANDLE search = FindFirstFileA(pattern, &data);
  free(pattern);
  if (search == INVALID_HANDLE_VALUE) {
    lua_pushnil(L);
    lua_pushfstring(L, "Windows directory error: %lu",
      (unsigned long)GetLastError());
    return 2;
  }
  lua_newtable(L);
  lua_Integer index = 1;
  do {
    if (strcmp(data.cFileName, ".") != 0 && strcmp(data.cFileName, "..") != 0) {
      lua_pushstring(L, data.cFileName);
      lua_rawseti(L, -2, index++);
    }
  } while (FindNextFileA(search, &data));
  FindClose(search);
  return 1;
#endif
}

#ifdef PRAGTICAL_NET
static int system_get_time(lua_State *L) {
  double now = SDL_GetPerformanceCounter() / (double)SDL_GetPerformanceFrequency();
  lua_pushnumber(L, now);
  return 1;
}
#endif

static void install_system_stub(lua_State *L) {
  static const luaL_Reg functions[] = {
    { "get_file_info", system_get_file_info },
    { "mkdir", system_mkdir },
    { "absolute_path", system_absolute_path },
    { "list_dir", system_list_dir },
#ifdef PRAGTICAL_NET
    { "get_time", system_get_time },
#endif
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
    "[--storage-path PATH] [--workspace ID] [--once]\n", program);
}

static int parse_options(int argc, char **argv, agent_options *options) {
  options->data_root = PRAGTICAL_SOURCE_DATA_DIR;
  options->data_dir = getenv("PRAGTICAL_USERDIR");
  if (!options->data_dir) options->data_dir = ".pragtical-agent";
  options->endpoint = NULL;
  options->storage_path = NULL;
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
    } else if (strcmp(argument, "--storage-path") == 0 && index + 1 < argc) {
      options->storage_path = argv[++index];
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
  char *storage_path = options->storage_path
    ? copy_string(options->storage_path)
    : join_path(options->data_dir, "workbench.sqlite3");
  if (!storage_path) return 0;

  const char *endpoint = options->endpoint;
  char *default_endpoint = NULL;
  if (!endpoint) {
    default_endpoint = join_path(options->data_dir, "workbench.sock");
    if (!default_endpoint) {
      free(storage_path);
      return 0;
    }
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

  if (!ensure_directory(options.data_dir)) {
    fprintf(stderr, "Unable to create Workbench data directory: %s\n",
      options.data_dir);
    return 1;
  }
  char *lock_path = join_path(options.data_dir, "workbench.lock");
  if (!lock_path) {
    fprintf(stderr, "Unable to allocate Workbench lock path\n");
    return 1;
  }
  workbench_lock lock;
#ifdef _WIN32
  lock.handle = INVALID_HANDLE_VALUE;
#else
  lock.fd = -1;
#endif
  int lock_result = acquire_workbench_lock(lock_path, &lock);
  if (lock_result <= 0) {
    fprintf(stderr, "%s: %s\n",
      lock_result == 0 ? "workspace_in_use" : "Unable to acquire Workbench lock",
      lock_path);
    free(lock_path);
    return lock_result == 0 ? 3 : 1;
  }
  free(lock_path);

  lua_State *L = luaL_newstate();
  if (!L) {
    fprintf(stderr, "Unable to create the Workbench agent Lua state\n");
    release_workbench_lock(&lock);
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
    release_workbench_lock(&lock);
    return 1;
  }
  register_module(L, "sqlite", luaopen_sqlite);
  register_module(L, "workbench_transport", luaopen_workbench_transport);
  register_module(L, "workbench_runtime", luaopen_workbench_runtime);
  register_module(L, "workbench_emulator", luaopen_workbench_emulator);
#ifdef PRAGTICAL_NET
  register_module(L, "net", luaopen_net);
#endif
  int result = run_agent(L, &options) ? 0 : 1;
  lua_close(L);
  release_workbench_lock(&lock);
  return result;
}
