# tree_sitter native module for lite-xl (libraries/tree_sitter/init.<ext>).
#
# Like Lua and SDL, nothing is vendored: lua-tree-sitter (and its tree-sitter
# submodule) is downloaded at configure time, and the small glue (plugin entry
# point and <lua.h> shims) is generated into the build directory.
#
# Built against resources/include/lite_xl_plugin_api.h, NOT against Lua itself:
# native modules inherit Lua's ABI constants (LUA_REGISTRYINDEX, struct layouts)
# from that header, so a module built for another Lua version than the one
# lite-xl bundles crashes at the first API call. Regenerate the header with
# scripts/generate_plugin_api.py whenever the bundled Lua changes, then rebuild.
include(FetchContent)

FetchContent_Declare(lua_tree_sitter
    GIT_REPOSITORY https://github.com/xcb-xwii/lua-tree-sitter
    GIT_TAG        v0.1.2
    GIT_SUBMODULES tree-sitter
    GIT_SHALLOW    TRUE
)
FetchContent_MakeAvailable(lua_tree_sitter)

set(_lts_dir "${lua_tree_sitter_SOURCE_DIR}")
set(_gen_dir "${CMAKE_BINARY_DIR}/tree_sitter_gen")

# Shims: lua-tree-sitter includes <lua.h> & co.; route them to the plugin API.
file(WRITE "${_gen_dir}/include/lua.h"
"/* lua-tree-sitter includes <lua.h>; use lite-xl's plugin API instead of linking Lua. */
#include <lite_xl_plugin_api.h>
")
file(WRITE "${_gen_dir}/include/lauxlib.h" "#include <lua.h>\n")
file(WRITE "${_gen_dir}/include/lualib.h"  "#include <lua.h>\n")

# Entry point, adapted from https://github.com/Evergreen-lxl/lite-xl-tree-sitter (MIT).
file(WRITE "${_gen_dir}/plugin.c"
"#define LITE_XL_PLUGIN_ENTRYPOINT

#include <lua.h>

#include <lts/util.h>

int luaopen_lua_tree_sitter(lua_State *L);

LTS_EXPORT int luaopen_lite_xl_tree_sitter(lua_State *L, void *XL) {
	lite_xl_plugin_init(XL);
	return luaopen_lua_tree_sitter(L);
}
")

file(GLOB _lts_sources
    "${_lts_dir}/src/*.c"
    "${_lts_dir}/src/query/*.c"
    "${_lts_dir}/src/range/*.c"
)
set(_ts_lib "${_lts_dir}/tree-sitter/lib/src/lib.c")

add_library(tree_sitter_module MODULE
    "${_gen_dir}/plugin.c"
    ${_lts_sources}
    ${_ts_lib}
)
set_target_properties(tree_sitter_module PROPERTIES
    OUTPUT_NAME init
    PREFIX ""
    C_STANDARD 11
    C_VISIBILITY_PRESET hidden
    LIBRARY_OUTPUT_DIRECTORY         "${CMAKE_BINARY_DIR}/libraries/tree_sitter"
    RUNTIME_OUTPUT_DIRECTORY         "${CMAKE_BINARY_DIR}/libraries/tree_sitter"
)
foreach(_cfg Debug Release RelWithDebInfo MinSizeRel)
    string(TOUPPER "${_cfg}" _CFG)
    set_target_properties(tree_sitter_module PROPERTIES
        LIBRARY_OUTPUT_DIRECTORY_${_CFG} "${CMAKE_BINARY_DIR}/libraries/tree_sitter"
        RUNTIME_OUTPUT_DIRECTORY_${_CFG} "${CMAKE_BINARY_DIR}/libraries/tree_sitter"
    )
endforeach()

# Order matters: our shims for <lua.h> & co. must win over any real Lua header.
target_include_directories(tree_sitter_module BEFORE PRIVATE
    "${_gen_dir}/include"
    "${CMAKE_SOURCE_DIR}/resources/include"
    "${_lts_dir}/include"
    "${_lts_dir}/tree-sitter/lib/include"
)
set_source_files_properties("${_ts_lib}" PROPERTIES
    INCLUDE_DIRECTORIES "${_lts_dir}/tree-sitter/lib/include;${_lts_dir}/tree-sitter/lib/src"
    COMPILE_DEFINITIONS "TREE_SITTER_HIDE_SYMBOLS;TREE_SITTER_HIDDEN_SYMBOLS;_POSIX_C_SOURCE=200112L;_DEFAULT_SOURCE"
)
if(MSVC)
    target_compile_definitions(tree_sitter_module PRIVATE _CRT_SECURE_NO_WARNINGS)
endif()

if(NOT DEFINED LITE_INSTALL_DATA_DIR)
    if(WIN32 OR LITE_PORTABLE)
        set(LITE_INSTALL_DATA_DIR "data")
    elseif(APPLE AND LITE_BUNDLE)
        set(LITE_INSTALL_DATA_DIR "Contents/Resources")
    else()
        include(GNUInstallDirs)
        set(LITE_INSTALL_DATA_DIR "${CMAKE_INSTALL_DATADIR}/lite-xl")
    endif()
endif()

# Installed into <datadir>/libraries/tree_sitter/ so Lite XL's package.cpath
# can find and load it as a system library without requiring manual copy to <userdir>.
install(TARGETS tree_sitter_module
    LIBRARY DESTINATION "${LITE_INSTALL_DATA_DIR}/libraries/tree_sitter"
    RUNTIME DESTINATION "${LITE_INSTALL_DATA_DIR}/libraries/tree_sitter"
)
