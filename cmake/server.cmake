# lite-xl-server: headless, POSIX-only remote editing server.
#
# Included from the top-level CMakeLists.txt when LITE_BUILD_SERVER (or
# LITE_SERVER_ONLY) is ON, after Lua, PCRE2 and SDL3 have been made available.
# It shares src/api/{system,process,dirmonitor,regex,utf8,buffer}.c with the
# editor; system.c is compiled with -DLITE_SERVER which drops the window,
# event-loop, clipboard and dialog code so no renderer is needed.
#
# Options (see the top-level CMakeLists.txt):
#   LITE_BUILD_SERVER   build the server next to the editor
#   LITE_SERVER_ONLY    build only the server (skips FreeType and the editor,
#                       and builds SDL without video/GPU/audio/joystick/...)
#   LITE_SERVER_STATIC  link the server fully static (glibc: dlopen warning)

if(WIN32)
    message(FATAL_ERROR
        "LITE_BUILD_SERVER: lite-xl-server is POSIX-only (Linux, macOS, BSD). "
        "On Windows only the Lite XL client is supported.")
endif()

option(LITE_SERVER_STATIC "Link lite-xl-server statically" OFF)

set(_srv_src "${CMAKE_SOURCE_DIR}/src")

# ── dirmonitor backend (same auto-detection as src/CMakeLists.txt) ──────────
set(_srv_dirmon "${LITE_DIRMONITOR_BACKEND}")
if(_srv_dirmon STREQUAL "")
    include(CheckIncludeFile)
    include(CheckFunctionExists)
    if(APPLE)
        check_include_file("CoreServices/CoreServices.h" _srv_have_cs)
        set(_srv_dirmon "dummy")
        if(_srv_have_cs)
            set(_srv_dirmon "fsevents")
        endif()
    else()
        check_include_file("sys/inotify.h" _srv_have_inotify)
        if(_srv_have_inotify)
            set(_srv_dirmon "inotify")
        else()
            check_function_exists(kqueue _srv_have_kqueue)
            if(_srv_have_kqueue)
                set(_srv_dirmon "kqueue")
            else()
                set(_srv_dirmon "dummy")
            endif()
        endif()
    endif()
endif()
if(_srv_dirmon STREQUAL "inodewatcher" OR _srv_dirmon STREQUAL "win32")
    message(FATAL_ERROR "dirmonitor backend '${_srv_dirmon}' is not supported by lite-xl-server")
endif()
message(STATUS "lite-xl-server dirmonitor backend: ${_srv_dirmon}")

set(LITE_SERVER_SOURCES
    "${_srv_src}/server/main.c"
    "${_srv_src}/server/stdio.c"
    "${_srv_src}/server/fsops.c"
    "${_srv_src}/api/system.c"
    "${_srv_src}/api/process.c"
    "${_srv_src}/api/regex.c"
    "${_srv_src}/api/utf8.c"
    "${_srv_src}/api/buffer.c"
    "${_srv_src}/api/dirmonitor.c"
    "${_srv_src}/api/dirmonitor/${_srv_dirmon}.c"
    "${_srv_src}/arena_allocator.c"
    "${_srv_src}/custom_events.c"
)

add_executable(lite-xl-server ${LITE_SERVER_SOURCES})
target_include_directories(lite-xl-server PRIVATE "${_srv_src}" "${_srv_src}/server")
target_compile_definitions(lite-xl-server PRIVATE
    LITE_SERVER
    PCRE2_STATIC
    "LITE_PROJECT_VERSION_STR=\"${LITE_VERSION}\""
    "LITE_ARCH_TUPLE=\"${LITE_ARCH_TUPLE}\""
)
target_link_libraries(lite-xl-server PRIVATE
    ${_lite_lua_target}
    SDL3::SDL3-static
    pcre2-8
)
if(APPLE)
    target_link_options(lite-xl-server PRIVATE -framework CoreServices -framework Foundation)
else()
    find_library(_srv_m_lib m)
    find_library(_srv_dl_lib dl)
    if(_srv_m_lib)
        target_link_libraries(lite-xl-server PRIVATE ${_srv_m_lib})
    endif()
    if(_srv_dl_lib)
        target_link_libraries(lite-xl-server PRIVATE ${_srv_dl_lib})
    endif()
endif()
if(LITE_SERVER_STATIC AND NOT APPLE)
    target_link_options(lite-xl-server PRIVATE -static)
endif()
# Footprint: SDL's "dynamic API" table references every SDL function, which
# keeps all of SDL (video, render, ...) in the binary. The server needs a
# handful of core functions only, so build SDL without it and let the linker
# drop unreferenced sections. (Only for LITE_SERVER_ONLY, where nothing else
# links SDL.)
if(LITE_SERVER_ONLY AND TARGET SDL3-static)
    # SDL has no supported switch for this; src/dynapi/SDL_dynapi.h turns it off
    # for static analyzers, which is what __RESHARPER__ selects.
    target_compile_definitions(SDL3-static PRIVATE __RESHARPER__)
    target_compile_options(SDL3-static PRIVATE -ffunction-sections -fdata-sections)
    target_compile_options(lite-xl-server PRIVATE -ffunction-sections -fdata-sections)
    if(APPLE)
        target_link_options(lite-xl-server PRIVATE -Wl,-dead_strip)
    else()
        target_link_options(lite-xl-server PRIVATE -Wl,--gc-sections)
    endif()
endif()
# the line counter / scanner is the hot loop of lineindex and search
set_source_files_properties("${_srv_src}/server/fsops.c" PROPERTIES COMPILE_OPTIONS "-O2")

# ── install ─────────────────────────────────────────────────────────────────
if(LITE_PORTABLE)
    set(_srv_bin_dir ".")
    set(_srv_data_dir "data")
else()
    include(GNUInstallDirs)
    set(_srv_bin_dir "${CMAKE_INSTALL_BINDIR}")
    set(_srv_data_dir "${CMAKE_INSTALL_DATADIR}/lite-xl")
endif()
install(TARGETS lite-xl-server RUNTIME DESTINATION "${_srv_bin_dir}")
install(DIRECTORY "${CMAKE_SOURCE_DIR}/data/server/" DESTINATION "${_srv_data_dir}/server")
if(LITE_SERVER_ONLY)
    # the editor install normally ships data/core as a whole
    install(DIRECTORY "${CMAKE_SOURCE_DIR}/data/core/remote/" DESTINATION "${_srv_data_dir}/core/remote")
endif()
