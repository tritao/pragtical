project('plugins', 'c', version: 'GIT', license: 'MIT')

fs = import('fs')
plugin_install_dir = join_paths(get_option('data_dir'), 'plugins')

# Check for valid shell
unix_shell = find_program('sh', required: false).found()
is_msvc = meson.get_compiler('c').get_id() == 'msvc'
if (host_machine.system() == 'windows' and not unix_shell) or is_msvc
    unix_shell = false
    shell_command = find_program('cmd', required: false)
endif

# Install applicable language files if enabled and a shell is available
if get_option('extra_languages') and (unix_shell or shell_command.found())
    if unix_shell
        list_command = run_command(
            'sh', '-c', 'ls ' + 'plugins/language_*',
            check: true
        )
    else
        list_command = run_command(
            'cmd', '/C', 'dir /b/s ' + 'plugins\\language_*',
            check: true
        )
    endif

    sources = list_command.stdout().strip().split('\n')

    install_data(sources,
        install_dir: plugin_install_dir
    )
endif

# Bundle explicitly selected plugins in addition to the language plugins.
# Names may refer to either plugins/<name>.lua or plugins/<name> directories.
foreach plugin_name : get_option('lua_plugins')
    plugin_path = 'plugins/' + plugin_name
    plugin_file = plugin_path + '.lua'

    if fs.is_dir(plugin_path)
        install_subdir(plugin_path, install_dir: plugin_install_dir)
    elif fs.is_file(plugin_file)
        install_data(plugin_file, install_dir: plugin_install_dir)
    elif fs.is_file(plugin_path)
        install_data(plugin_path, install_dir: plugin_install_dir)
    else
        error('Bundled plugin not found: ' + plugin_name)
    endif
endforeach
