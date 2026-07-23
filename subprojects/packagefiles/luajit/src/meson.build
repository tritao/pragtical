ljlib_src = files(
    'lib_base.c',
    'lib_bit.c',
    'lib_buffer.c',
    'lib_debug.c',
    'lib_ffi.c',
    'lib_io.c',
    'lib_jit.c',
    'lib_math.c',
    'lib_os.c',
    'lib_package.c',
    'lib_string.c',
    'lib_table.c',
    'utf8_wrappers.c',
)

ljcore_src = files(
    'lib_aux.c',
    'lib_init.c',
    'lj_alloc.c',
    'lj_api.c',
    'lj_asm.c',
    'lj_assert.c',
    'lj_bc.c',
    'lj_bcread.c',
    'lj_bcwrite.c',
    'lj_buf.c',
    'lj_carith.c',
    'lj_ccall.c',
    'lj_ccallback.c',
    'lj_cconv.c',
    'lj_cdata.c',
    'lj_char.c',
    'lj_clib.c',
    'lj_cparse.c',
    'lj_crecord.c',
    'lj_ctype.c',
    'lj_debug.c',
    'lj_dispatch.c',
    'lj_err.c',
    'lj_ffrecord.c',
    'lj_func.c',
    'lj_gc.c',
    'lj_gdbjit.c',
    'lj_ir.c',
    'lj_lex.c',
    'lj_lib.c',
    'lj_load.c',
    'lj_mcode.c',
    'lj_meta.c',
    'lj_obj.c',
    'lj_opt_dce.c',
    'lj_opt_fold.c',
    'lj_opt_loop.c',
    'lj_opt_mem.c',
    'lj_opt_narrow.c',
    'lj_opt_sink.c',
    'lj_opt_split.c',
    'lj_parse.c',
    'lj_prng.c',
    'lj_profile.c',
    'lj_record.c',
    'lj_serialize.c',
    'lj_snap.c',
    'lj_state.c',
    'lj_str.c',
    'lj_strfmt.c',
    'lj_strfmt_num.c',
    'lj_strscan.c',
    'lj_tab.c',
    'lj_trace.c',
    'lj_udata.c',
    'lj_vmevent.c',
    'lj_vmmath.c',
)

src_inc = include_directories('.')

minilua = executable('minilua', 'host/minilua.c',
                     dependencies: system_deps_native,
                     native: true)

# Generate the revision timestamp while configuring the subproject. Meson's
# vcs_tag() creates a PHONY build target so it can detect Git changes, which
# makes this command run on every incremental build.
relver_data = configuration_data()
relver_data.set('VCS_CT', 'ROLLING')

git_command = find_program('git', required: false)
if git_command.found()
    git_timestamp = run_command(
        [git_command, 'show', '-s', '--format=%ct'],
        check: false
    ).stdout().strip()
    if git_timestamp != ''
        relver_data.set('VCS_CT', git_timestamp)
    endif
endif

relver = configure_file(
    input: 'luajit_relver.txt.in',
    output: 'luajit_relver.txt',
    configuration: relver_data
)

luajit_rolling_h = files('luajit_rolling.h')

luajit_h = custom_target('luajit_h',
                         command: [minilua, '@INPUT@', '@OUTPUT@'],
                         input: ['host/genversion.lua', 'luajit_rolling.h', relver],
                         output: 'luajit.h')

subdir('host')

hdrgen = [
    'bcdef',
    'ffdef',
    'libdef',
    'recdef',
]

genheaders = [luajit_h]

foreach h: hdrgen
    genheaders += custom_target(h,
                                command: [buildvm, '-m', h, '-o', '@OUTPUT@', ljlib_src],
                                output: 'lj_@0@.h'.format(h))
endforeach

custom_target('vmdef',
              command: [buildvm, '-m', 'vmdef', '-o', '@OUTPUT@', ljlib_src],
              output: 'vmdef.lua', build_by_default: true, install: true,
              install_dir: join_paths(get_option('data_dir'), 'jit'))

genheaders += custom_target('folddef',
                            command: [buildvm, '-m', 'folddef', '-o', '@OUTPUT@', files('lj_opt_fold.c')],
                            output: 'lj_folddef.h')

ljvm = custom_target(ljvm_bout,
                     command: [buildvm, '-m', ljvm_mode, '-o', '@OUTPUT@'],
                     output: ljvm_bout)

if get_option('amalg')
    luajit_lib = static_library('luajit', 'ljamalg.c', 'utf8_wrappers.c', genheaders, ljvm,
                                dependencies: system_deps)
else
    luajit_lib = static_library('luajit', ljlib_src, ljcore_src, genheaders, ljvm,
                                dependencies: system_deps)
endif

install_subdir(
    'jit',
    strip_directory: true,
    install_dir: join_paths(get_option('data_dir'), 'jit'),
    exclude_files: ['.gitignore']
)
