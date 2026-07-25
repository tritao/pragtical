project(
  'sqlite',
  'c',
  version: '3.53.4',
  meson_version: '>= 0.63',
  default_options: ['c_std=c11', 'warning_level=0']
)

sqlite_library = static_library(
  'sqlite3',
  'sqlite3.c',
  c_args: [
    '-DSQLITE_THREADSAFE=1',
    '-DSQLITE_DEFAULT_MEMSTATUS=0',
    '-DSQLITE_OMIT_LOAD_EXTENSION',
  ],
  install: false
)

sqlite_dep = declare_dependency(
  link_with: sqlite_library,
  include_directories: include_directories('.')
)
