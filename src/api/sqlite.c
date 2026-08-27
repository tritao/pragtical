#include "api.h"

#include <limits.h>
#include <stddef.h>
#include <string.h>
#include <sqlite3.h>

#define API_TYPE_SQLITE "SQLiteDatabase"
#define API_TYPE_SQLITE_BLOB "SQLiteBlob"

typedef struct {
  sqlite3 *handle;
} sqlite_database_t;

typedef struct {
  size_t length;
  unsigned char data[];
} sqlite_blob_t;

static sqlite_database_t *check_database(lua_State *L, int index) {
  sqlite_database_t *database = luaL_checkudata(L, index, API_TYPE_SQLITE);
  if (!database->handle)
    luaL_error(L, "SQLite database is closed");
  return database;
}

static int push_database_error(lua_State *L, sqlite3 *handle, int result,
    const char *message) {
  lua_pushnil(L);
  lua_newtable(L);
  lua_pushinteger(L, result);
  lua_setfield(L, -2, "code");
  lua_pushinteger(L, handle ? sqlite3_extended_errcode(handle) : result);
  lua_setfield(L, -2, "extended_code");
  lua_pushstring(L, message ? message
    : (handle ? sqlite3_errmsg(handle) : "database is unavailable"));
  lua_setfield(L, -2, "message");
  lua_pushstring(L, sqlite3_errstr(result));
  lua_setfield(L, -2, "name");
  return 2;
}

static int execute_sql(sqlite3 *handle, const char *sql, char **error_message) {
  int result = sqlite3_exec(handle, sql, NULL, NULL, error_message);
  if (result != SQLITE_OK && error_message && !*error_message)
    *error_message = sqlite3_mprintf("%s", sqlite3_errmsg(handle));
  return result;
}

static int bind_value(lua_State *L, sqlite3_stmt *statement, int index, int value_index) {
  int result;
  switch (lua_type(L, value_index)) {
    case LUA_TNIL:
      result = sqlite3_bind_null(statement, index);
      break;
    case LUA_TBOOLEAN:
      result = sqlite3_bind_int(statement, index, lua_toboolean(L, value_index));
      break;
    case LUA_TNUMBER:
      if (lua_isinteger(L, value_index))
        result = sqlite3_bind_int64(statement, index, (sqlite3_int64)lua_tointeger(L, value_index));
      else
        result = sqlite3_bind_double(statement, index, lua_tonumber(L, value_index));
      break;
    case LUA_TSTRING: {
      size_t length;
      const char *value = lua_tolstring(L, value_index, &length);
      if (length > (size_t)INT_MAX)
        return luaL_error(L, "SQLite text parameters cannot exceed %d bytes", INT_MAX);
      result = sqlite3_bind_text(statement, index, value, (int)length, SQLITE_TRANSIENT);
      break;
    }
    case LUA_TUSERDATA: {
      sqlite_blob_t *blob = luaL_testudata(L, value_index, API_TYPE_SQLITE_BLOB);
      if (!blob)
        return luaL_error(L, "SQLite parameters must be nil, boolean, number, string, or sqlite.blob");
      result = sqlite3_bind_blob(statement, index, blob->data, (int)blob->length,
        SQLITE_TRANSIENT);
      break;
    }
    default:
      return luaL_error(L, "SQLite parameters must be nil, boolean, number, string, or sqlite.blob");
  }
  return result;
}

static int bind_parameters(lua_State *L, sqlite3_stmt *statement, int parameters_index) {
  if (lua_isnoneornil(L, parameters_index))
    return 0;
  luaL_checktype(L, parameters_index, LUA_TTABLE);
  parameters_index = lua_absindex(L, parameters_index);
  int count = sqlite3_bind_parameter_count(statement);
  for (int index = 1; index <= count; ++index) {
    const char *name = sqlite3_bind_parameter_name(statement, index);
    if (name) {
      lua_getfield(L, parameters_index, name);
      if (lua_isnil(L, -1) && (name[0] == ':' || name[0] == '@' || name[0] == '$')) {
        lua_pop(L, 1);
        lua_getfield(L, parameters_index, name + 1);
      }
    } else {
      lua_rawgeti(L, parameters_index, index);
    }
    int result = bind_value(L, statement, index, -1);
    lua_pop(L, 1);
    if (result != SQLITE_OK)
      return push_database_error(L, sqlite3_db_handle(statement), result, NULL);
  }
  return 0;
}

static void push_column(lua_State *L, sqlite3_stmt *statement, int column) {
  switch (sqlite3_column_type(statement, column)) {
    case SQLITE_INTEGER:
      lua_pushinteger(L, (lua_Integer)sqlite3_column_int64(statement, column));
      break;
    case SQLITE_FLOAT:
      lua_pushnumber(L, sqlite3_column_double(statement, column));
      break;
    case SQLITE_TEXT:
      lua_pushlstring(L, (const char *)sqlite3_column_text(statement, column),
        (size_t)sqlite3_column_bytes(statement, column));
      break;
    case SQLITE_BLOB:
      lua_pushlstring(L, (const char *)sqlite3_column_blob(statement, column),
        (size_t)sqlite3_column_bytes(statement, column));
      break;
    default:
      lua_pushnil(L);
      break;
  }
}

static int database_execute(lua_State *L) {
  sqlite_database_t *database = check_database(L, 1);
  const char *sql = luaL_checkstring(L, 2);
  sqlite3_stmt *statement = NULL;
  int result = sqlite3_prepare_v2(database->handle, sql, -1, &statement, NULL);
  if (result != SQLITE_OK)
    return push_database_error(L, database->handle, result, NULL);

  result = bind_parameters(L, statement, 3);
  if (result != 0) {
    sqlite3_finalize(statement);
    return result;
  }
  while ((result = sqlite3_step(statement)) == SQLITE_ROW) {}
  if (result != SQLITE_DONE) {
    sqlite3_finalize(statement);
    return push_database_error(L, database->handle, result, NULL);
  }
  result = sqlite3_finalize(statement);
  if (result != SQLITE_OK)
    return push_database_error(L, database->handle, result, NULL);
  lua_pushboolean(L, 1);
  return 1;
}

static int database_query(lua_State *L) {
  sqlite_database_t *database = check_database(L, 1);
  const char *sql = luaL_checkstring(L, 2);
  sqlite3_stmt *statement = NULL;
  int result = sqlite3_prepare_v2(database->handle, sql, -1, &statement, NULL);
  if (result != SQLITE_OK)
    return push_database_error(L, database->handle, result, NULL);

  result = bind_parameters(L, statement, 3);
  if (result != 0) {
    sqlite3_finalize(statement);
    return result;
  }
  lua_newtable(L);
  int row = 1;
  while ((result = sqlite3_step(statement)) == SQLITE_ROW) {
    int columns = sqlite3_column_count(statement);
    lua_newtable(L);
    for (int column = 0; column < columns; ++column) {
      push_column(L, statement, column);
      lua_setfield(L, -2, sqlite3_column_name(statement, column));
    }
    lua_rawseti(L, -2, row++);
  }
  if (result != SQLITE_DONE) {
    sqlite3_finalize(statement);
    push_database_error(L, database->handle, result, NULL);
    lua_remove(L, -3);
    return 2;
  }
  result = sqlite3_finalize(statement);
  if (result != SQLITE_OK) {
    push_database_error(L, database->handle, result, NULL);
    lua_remove(L, -3);
    return 2;
  }
  return 1;
}

static int database_changes(lua_State *L) {
  sqlite_database_t *database = check_database(L, 1);
  lua_pushinteger(L, sqlite3_changes(database->handle));
  return 1;
}

static int database_last_insert_rowid(lua_State *L) {
  sqlite_database_t *database = check_database(L, 1);
  lua_pushinteger(L, (lua_Integer)sqlite3_last_insert_rowid(database->handle));
  return 1;
}

static int database_sql(lua_State *L, const char *sql) {
  sqlite_database_t *database = check_database(L, 1);
  char *error_message = NULL;
  int result = execute_sql(database->handle, sql, &error_message);
  if (result != SQLITE_OK) {
    int returns = push_database_error(L, database->handle, result, error_message);
    sqlite3_free(error_message);
    return returns;
  }
  sqlite3_free(error_message);
  lua_pushboolean(L, 1);
  return 1;
}

static int database_begin(lua_State *L) {
  const char *mode = luaL_optstring(L, 2, "immediate");
  const char *sql;
  if (strcmp(mode, "deferred") == 0) sql = "BEGIN DEFERRED";
  else if (strcmp(mode, "immediate") == 0) sql = "BEGIN IMMEDIATE";
  else if (strcmp(mode, "exclusive") == 0) sql = "BEGIN EXCLUSIVE";
  else return luaL_error(L, "SQLite transaction mode must be deferred, immediate, or exclusive");
  return database_sql(L, sql);
}

static int database_commit(lua_State *L) {
  return database_sql(L, "COMMIT");
}

static int database_rollback(lua_State *L) {
  return database_sql(L, "ROLLBACK");
}

static int database_in_transaction(lua_State *L) {
  sqlite_database_t *database = check_database(L, 1);
  lua_pushboolean(L, !sqlite3_get_autocommit(database->handle));
  return 1;
}

static int database_close(lua_State *L) {
  sqlite_database_t *database = luaL_checkudata(L, 1, API_TYPE_SQLITE);
  if (database->handle) {
    int result = sqlite3_close(database->handle);
    if (result != SQLITE_OK) {
      int returns = push_database_error(L, database->handle, result, NULL);
      lua_remove(L, -3);
      return returns;
    }
    database->handle = NULL;
  }
  lua_pushboolean(L, 1);
  return 1;
}

static int database_gc(lua_State *L) {
  sqlite_database_t *database = luaL_checkudata(L, 1, API_TYPE_SQLITE);
  if (database->handle) {
    sqlite3_close(database->handle);
    database->handle = NULL;
  }
  return 0;
}

static int database_tostring(lua_State *L) {
  sqlite_database_t *database = luaL_checkudata(L, 1, API_TYPE_SQLITE);
  lua_pushfstring(L, "SQLiteDatabase(%s)", database->handle ? "open" : "closed");
  return 1;
}

static int sqlite_blob(lua_State *L) {
  size_t length;
  const char *value = luaL_checklstring(L, 1, &length);
  if (length > (size_t)INT_MAX)
    return luaL_error(L, "SQLite blobs cannot exceed %d bytes", INT_MAX);
  sqlite_blob_t *blob = lua_newuserdata(L, sizeof(*blob) + length);
  blob->length = length;
  if (length > 0)
    memcpy(blob->data, value, length);
  luaL_getmetatable(L, API_TYPE_SQLITE_BLOB);
  lua_setmetatable(L, -2);
  return 1;
}

static int sqlite_open(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  int flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX;
  int readonly = 0;
  if (lua_istable(L, 2)) {
    lua_getfield(L, 2, "readonly");
    if (lua_toboolean(L, -1)) {
      readonly = 1;
      flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX;
    }
    lua_pop(L, 1);
  }

  sqlite_database_t *database = lua_newuserdata(L, sizeof(*database));
  database->handle = NULL;
  int result = sqlite3_open_v2(path, &database->handle, flags, NULL);
  if (result != SQLITE_OK) {
    int returns = push_database_error(L, database->handle, result, NULL);
    if (database->handle)
      sqlite3_close(database->handle);
    database->handle = NULL;
    lua_remove(L, -3);
    return returns;
  }
  result = sqlite3_busy_timeout(database->handle, 5000);
  if (result != SQLITE_OK) {
    int returns = push_database_error(L, database->handle, result, NULL);
    sqlite3_close(database->handle);
    database->handle = NULL;
    lua_remove(L, -3);
    return returns;
  }

  const char *pragmas[] = {
    "PRAGMA foreign_keys = ON",
    readonly ? NULL : "PRAGMA journal_mode = WAL",
    "PRAGMA synchronous = FULL",
    "PRAGMA wal_autocheckpoint = 1000",
    NULL,
  };
  for (int index = 0; pragmas[index]; ++index) {
    char *error_message = NULL;
    result = execute_sql(database->handle, pragmas[index], &error_message);
    if (result != SQLITE_OK) {
      int returns = push_database_error(L, database->handle, result, error_message);
      sqlite3_free(error_message);
      sqlite3_close(database->handle);
      database->handle = NULL;
      lua_remove(L, -3);
      return returns;
    }
    sqlite3_free(error_message);
  }
  luaL_getmetatable(L, API_TYPE_SQLITE);
  lua_setmetatable(L, -2);
  return 1;
}

static const luaL_Reg database_methods[] = {
  { "execute", database_execute },
  { "query", database_query },
  { "begin", database_begin },
  { "commit", database_commit },
  { "rollback", database_rollback },
  { "in_transaction", database_in_transaction },
  { "changes", database_changes },
  { "last_insert_rowid", database_last_insert_rowid },
  { "close", database_close },
  { "__gc", database_gc },
  { "__tostring", database_tostring },
  { NULL, NULL }
};

static const luaL_Reg sqlite_functions[] = {
  { "open", sqlite_open },
  { "blob", sqlite_blob },
  { NULL, NULL }
};

int luaopen_sqlite(lua_State *L) {
  luaL_newmetatable(L, API_TYPE_SQLITE);
  luaL_setfuncs(L, database_methods, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);

  luaL_newmetatable(L, API_TYPE_SQLITE_BLOB);
  lua_pop(L, 1);

  luaL_newlib(L, sqlite_functions);
  lua_pushliteral(L, "3");
  lua_setfield(L, -2, "version");
  return 1;
}
