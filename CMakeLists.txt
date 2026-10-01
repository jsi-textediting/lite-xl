cmake_minimum_required(VERSION 3.28)

project(lite-xl
    VERSION 2.1.7
    LANGUAGES C
)

# ===========================================================================
# Options  (mirrors meson_options.txt)
# ===========================================================================
if(WIN32)
    set(_lite_portable_default ON)
else()
    set(_lite_portable_default OFF)
endif()

option(LITE_USE_SDL_RENDERER
    "Use SDL renderer backend with software fallback" ON)
option(LITE_PORTABLE
    "Portable install layout (data/ sits beside the binary)" ${_lite_portable_default})
option(LITE_BUNDLE
    "Build a macOS .app bundle" OFF)
option(LITE_USE_SYSTEM_LUA
    "Prefer an already-installed Lua 5.4+ over the bundled one" OFF)
set(LITE_DIRMONITOR_BACKEND "" CACHE STRING
    "dirmonitor backend: auto | win32 | inotify | fsevents | kqueue | inodewatcher | dummy")
set(LITE_ARCH_TUPLE "" CACHE STRING
    "Custom architecture tuple, e.g. x86_64-windows (derived automatically when empty)")

# macOS bundle forces SDL renderer on (needed for retina)
if(APPLE AND LITE_BUNDLE)
    set(LITE_USE_SDL_RENDERER ON CACHE BOOL "" FORCE)
endif()

# ===========================================================================
# C standard  (gnu11, same as Meson default_options c_std=gnu11)
# ===========================================================================
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_EXTENSIONS ON)

# ===========================================================================
# Version string (append short git hash on non-release builds)
# ===========================================================================
set(LITE_VERSION "${PROJECT_VERSION}")
if(NOT CMAKE_BUILD_TYPE STREQUAL "Release")
    find_package(Git QUIET)
    if(GIT_FOUND)
        execute_process(
            COMMAND "${GIT_EXECUTABLE}" rev-parse HEAD
            WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
            OUTPUT_VARIABLE _git_hash
            ERROR_QUIET
            OUTPUT_STRIP_TRAILING_WHITESPACE
        )
        if(_git_hash)
            string(SUBSTRING "${_git_hash}" 0 8 _git_short)
            string(APPEND LITE_VERSION " (git-${_git_short})")
        endif()
    endif()
endif()

# Override PROJECT_VERSION so configure_file(@PROJECT_VERSION@) picks up
# the full string including any git suffix.
set(PROJECT_VERSION "${LITE_VERSION}")
set(PROJECT_ASSEMBLY_VERSION
    "${PROJECT_VERSION_MAJOR}.${PROJECT_VERSION_MINOR}.${PROJECT_VERSION_PATCH}.0")

message(STATUS "lite-xl version: ${LITE_VERSION}")

# ===========================================================================
# Architecture tuple
# ===========================================================================
if(LITE_ARCH_TUPLE STREQUAL "")
    string(TOLOWER "${CMAKE_SYSTEM_PROCESSOR}" _cpu)
    string(TOLOWER "${CMAKE_SYSTEM_NAME}"      _sys)
    set(LITE_ARCH_TUPLE "${_cpu}-${_sys}")
endif()
message(STATUS "Architecture tuple: ${LITE_ARCH_TUPLE}")

# ===========================================================================
# Variables used verbatim in configure_file templates
# ===========================================================================
set(PROJECT_BUILD_DIR  "${CMAKE_BINARY_DIR}")
set(PROJECT_SOURCE_DIR "${CMAKE_SOURCE_DIR}")

# ===========================================================================
# Dependencies via FetchContent
# All four are built as static libraries so the resulting binary is
# self-contained on all platforms.
#
# pcre2/freetype/SDL3 each ship their own install() rules (libs, headers,
# cmake config files, man pages, pkgconfig, ...), which by default get
# pulled into *this* project's install output too. EXCLUDE_FROM_ALL on
# their FetchContent_Declare() (CMake 3.28+) keeps the top-level
# cmake_install.cmake from including those subdirectories' install
# scripts at all -- lite-xl only ever needs them as static libraries
# linked into lite-xl.exe, not installed standalone. It also drops their
# non-library targets (pcre2grep, SDL3's test suite, etc.) from the
# default ALL_BUILD target.
# ===========================================================================
include(FetchContent)

# Global: everything static
set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build static libraries only" FORCE)

# ── Lua 5.5.1 ──────────────────────────────────────────────────────────────
if(NOT LITE_USE_SYSTEM_LUA)
    # On Windows apply the Lua Unicode patch if it is present in the tree.
    # FetchContent only downloads / patches once; subsequent configures reuse
    # the cached extraction.
    set(_lua_patch_file
        "${CMAKE_SOURCE_DIR}/subprojects/packagefiles/lua/lua-5.5.1-unicode.diff")
    if(WIN32 AND EXISTS "${_lua_patch_file}")
        FetchContent_Declare(lua
            URL                      https://www.lua.org/ftp/lua-5.5.1.tar.gz
            URL_HASH                 SHA256=1c4b4068d67061f2a2231ad2b5422e77acea1487ea9890f6320af614f4373dce
            DOWNLOAD_EXTRACT_TIMESTAMP TRUE
            # git apply silently skips every file when the build tree sits inside
            # another git repository; the ceiling makes it behave like plain patch.
            PATCH_COMMAND            ${CMAKE_COMMAND} -E env
                                     "GIT_CEILING_DIRECTORIES=${CMAKE_SOURCE_DIR}"
                                     git apply "${_lua_patch_file}"
        )
    else()
        FetchContent_Declare(lua
            URL                      https://www.lua.org/ftp/lua-5.5.1.tar.gz
            URL_HASH                 SHA256=1c4b4068d67061f2a2231ad2b5422e77acea1487ea9890f6320af614f4373dce
            DOWNLOAD_EXTRACT_TIMESTAMP TRUE
        )
        if(WIN32)
            message(WARNING
                "Lua Unicode patch not found at ${_lua_patch_file}. "
                "Non-ASCII file paths may not work correctly on Windows.")
        endif()
    endif()

    FetchContent_MakeAvailable(lua)

    # Lua has no CMakeLists.txt in its official distribution.
    # Build the library target manually from its src/ directory.
    file(GLOB _lua_sources "${lua_SOURCE_DIR}/src/*.c")
    # Exclude the standalone interpreter (lua.c) and compiler (luac.c).
    list(FILTER _lua_sources EXCLUDE REGEX "(lua|luac)\\.c$")

    add_library(lua_static STATIC ${_lua_sources})
    target_include_directories(lua_static PUBLIC "${lua_SOURCE_DIR}/src")
    # LUA_USE_WINDOWS is auto-detected by luaconf.h via _WIN32, so we do not
    # set it manually.  LUA_USE_LINUX / LUA_USE_MACOSX enable readline/dlopen
    # extras that the Meson wrap disables (line_editing=disabled); omit them
    # here so the embedded library stays minimal.
    set_target_properties(lua_static PROPERTIES
        C_STANDARD 11
        C_EXTENSIONS ON
    )
    set(_lite_lua_target lua_static)
else()
    find_package(Lua 5.4 REQUIRED)
    add_library(lua_system_shim INTERFACE)
    target_include_directories(lua_system_shim INTERFACE ${LUA_INCLUDE_DIR})
    target_link_libraries(lua_system_shim INTERFACE ${LUA_LIBRARIES})
    set(_lite_lua_target lua_system_shim)
endif()

# ── PCRE2 10.44 ────────────────────────────────────────────────────────────
set(PCRE2_BUILD_PCRE2_8   ON  CACHE BOOL "" FORCE)
set(PCRE2_BUILD_PCRE2_16  OFF CACHE BOOL "" FORCE)
set(PCRE2_BUILD_PCRE2_32  OFF CACHE BOOL "" FORCE)
set(PCRE2_BUILD_PCRE2_GREP OFF CACHE BOOL "" FORCE)
set(PCRE2_BUILD_TESTS      OFF CACHE BOOL "" FORCE)

FetchContent_Declare(pcre2
    URL                      https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.44/pcre2-10.44.tar.bz2
    URL_HASH                 SHA256=d34f02e113cf7193a1ebf2770d3ac527088d485d4e047ed10e5d217c6ef5de96
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    EXCLUDE_FROM_ALL
)
FetchContent_MakeAvailable(pcre2)

# ── FreeType 2.14.1 ────────────────────────────────────────────────────────
set(FT_DISABLE_ZLIB     TRUE CACHE BOOL "" FORCE)
set(FT_DISABLE_BZIP2    TRUE CACHE BOOL "" FORCE)
set(FT_DISABLE_PNG      TRUE CACHE BOOL "" FORCE)
set(FT_DISABLE_HARFBUZZ TRUE CACHE BOOL "" FORCE)
set(FT_DISABLE_BROTLI   TRUE CACHE BOOL "" FORCE)

FetchContent_Declare(freetype
    URL                      https://download.savannah.gnu.org/releases/freetype/freetype-2.14.1.tar.xz
    URL_HASH                 SHA256=32427e8c471ac095853212a37aef816c60b42052d4d9e48230bab3bdf2936ccc
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    EXCLUDE_FROM_ALL
)
FetchContent_MakeAvailable(freetype)

# ── SDL3 ───────────────────────────────────────────────────────────────────
set(SDL_STATIC ON  CACHE BOOL "" FORCE)
set(SDL_SHARED OFF CACHE BOOL "" FORCE)
set(SDL_TEST   OFF CACHE BOOL "" FORCE)
set(SDL_AUDIO   OFF CACHE BOOL "" FORCE)

FetchContent_Declare(SDL3
    GIT_REPOSITORY https://github.com/libsdl-org/SDL.git
    GIT_TAG        release-3.4.8
    GIT_SHALLOW    TRUE
    EXCLUDE_FROM_ALL
)
FetchContent_MakeAvailable(SDL3)

# ===========================================================================
# Generate config files from templates
# ===========================================================================

# ── start.lua ──────────────────────────────────────────────────────────────
# Template substitutes @PROJECT_VERSION@.
configure_file(
    "${CMAKE_SOURCE_DIR}/data/core/start.lua"
    "${CMAKE_BINARY_DIR}/start.lua"
    @ONLY
)

# ── Windows: exe manifest + InnoSetup installer script ────────────────────
if(WIN32)
    configure_file(
        "${CMAKE_SOURCE_DIR}/resources/windows/lite-xl.exe.manifest.in"
        "${CMAKE_BINARY_DIR}/lite-xl.exe.manifest"
        @ONLY
    )
    configure_file(
        "${CMAKE_SOURCE_DIR}/scripts/innosetup/innosetup.iss.in"
        "${CMAKE_BINARY_DIR}/innosetup.iss"
        @ONLY
    )
endif()

# ── macOS bundle: Info.plist ───────────────────────────────────────────────
if(APPLE AND LITE_BUNDLE)
    string(TIMESTAMP CURRENT_YEAR "%Y")
    configure_file(
        "${CMAKE_SOURCE_DIR}/resources/macos/Info.plist.in"
        "${CMAKE_BINARY_DIR}/Info.plist"
        @ONLY
    )
endif()

# ── Linux: AppStream metainfo XML ─────────────────────────────────────────
if(UNIX AND NOT APPLE AND NOT LITE_PORTABLE)
    # Build the <releases> block from git tags, replicating the Meson logic.
    set(METAINFO_RELEASES "")
    if(GIT_FOUND)
        execute_process(
            COMMAND "${GIT_EXECUTABLE}" tag -l --sort=-version:refname
                    "--format=%(refname:strip=2) %(creatordate:short)"
            WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
            OUTPUT_VARIABLE _git_tags_raw
            ERROR_QUIET
            OUTPUT_STRIP_TRAILING_WHITESPACE
        )
        string(REPLACE "\n" ";" _git_tag_lines "${_git_tags_raw}")
        set(_release_items "")
        foreach(_line IN LISTS _git_tag_lines)
            string(REGEX MATCH "^([^ ]+)[ \t]+(.+)$" _m "${_line}")
            if(NOT _m)
                continue()
            endif()
            set(_ref  "${CMAKE_MATCH_1}")
            set(_date "${CMAKE_MATCH_2}")
            # Skip: must start with 'v', must not contain '-', skip v1.0* series
            if(NOT _ref MATCHES "^v")
                continue()
            endif()
            if(_ref MATCHES "-")
                continue()
            endif()
            if(_ref MATCHES "^v1\\.0")
                continue()
            endif()
            string(APPEND _release_items
                "  <release version=\"${_ref}\" date=\"${_date}\" />\n")
        endforeach()
        if(_release_items)
            set(METAINFO_RELEASES
                "<releases>\n${_release_items}</releases>")
        endif()
    endif()

    configure_file(
        "${CMAKE_SOURCE_DIR}/resources/linux/com.lite_xl.LiteXL.metainfo.xml.in"
        "${CMAKE_BINARY_DIR}/com.lite_xl.LiteXL.metainfo.xml"
        @ONLY
    )
endif()

# ===========================================================================
# Build
# ===========================================================================
add_subdirectory(src)

# ===========================================================================
# Install
# ===========================================================================

# The portable/Windows layout expects data/ to sit beside the binary, which
# doesn't make sense under CMake's system-wide default install prefix
# (Program Files, admin-only on Windows) -- default to a plain, writable
# location under the build tree instead so `cmake --install <build-dir>`
# works without elevation. Only applies when the user hasn't already set
# their own -DCMAKE_INSTALL_PREFIX=...; `cmake --install <build-dir>
# --prefix <path>` still overrides this normally either way.
if((WIN32 OR LITE_PORTABLE) AND CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
    set(CMAKE_INSTALL_PREFIX "${CMAKE_BINARY_DIR}/dist" CACHE PATH
        "Install path prefix, prepended onto install directories." FORCE)
endif()

# ── Portable / Windows layout ──────────────────────────────────────────────
if(WIN32 OR LITE_PORTABLE)
    install(DIRECTORY "${CMAKE_SOURCE_DIR}/data/core/"
            DESTINATION data/core
            PATTERN "start.lua" EXCLUDE)
    install(DIRECTORY "${CMAKE_SOURCE_DIR}/data/fonts/"
            DESTINATION data/fonts)
    install(DIRECTORY "${CMAKE_SOURCE_DIR}/data/plugins/"
            DESTINATION data/plugins)
    install(DIRECTORY "${CMAKE_SOURCE_DIR}/data/colors/"
            DESTINATION data/colors)
    install(DIRECTORY "${CMAKE_SOURCE_DIR}/docs/api/"
            DESTINATION data)
    install(FILES "${CMAKE_BINARY_DIR}/start.lua"
            DESTINATION data/core)
    install(FILES "${CMAKE_SOURCE_DIR}/licenses/licenses.md"
            DESTINATION doc)

# ── macOS bundle layout ────────────────────────────────────────────────────
# Set CMAKE_INSTALL_PREFIX to the .app directory,
# e.g.:  cmake --install . --prefix /Applications/lite-xl.app
elseif(APPLE AND LITE_BUNDLE)
    install(DIRECTORY "${CMAKE_SOURCE_DIR}/data/core/"
            DESTINATION Contents/Resources/core
            PATTERN "start.lua" EXCLUDE)
    install(DIRECTORY "${CMAKE_SOURCE_DIR}/data/fonts/"
            DESTINATION Contents/Resources/fonts)
    install(DIRECTORY "${CMAKE_SOURCE_DIR}/data/plugins/"
            DESTINATION Contents/Resources/plugins)
    install(DIRECTORY "${CMAKE_SOURCE_DIR}/data/colors/"
            DESTINATION Contents/Resources/colors)
    install(DIRECTORY "${CMAKE_SOURCE_DIR}/docs/api/"
            DESTINATION Contents/Resources)
    install(FILES "${CMAKE_BINARY_DIR}/start.lua"
            DESTINATION Contents/Resources/core)
    install(FILES "${CMAKE_SOURCE_DIR}/resources/icons/icon.icns"
            DESTINATION Contents/Resources)
    install(FILES "${CMAKE_BINARY_DIR}/Info.plist"
            DESTINATION Contents)
    install(FILES "${CMAKE_SOURCE_DIR}/licenses/licenses.md"
            DESTINATION Contents/Resources)

# ── Standard FHS layout (Linux, non-bundle macOS) ─────────────────────────
else()
    include(GNUInstallDirs)
    install(DIRECTORY "${CMAKE_SOURCE_DIR}/data/core/"
            DESTINATION "${CMAKE_INSTALL_DATADIR}/lite-xl/core"
            PATTERN "start.lua" EXCLUDE)
    install(DIRECTORY "${CMAKE_SOURCE_DIR}/data/fonts/"
            DESTINATION "${CMAKE_INSTALL_DATADIR}/lite-xl/fonts")
    install(DIRECTORY "${CMAKE_SOURCE_DIR}/data/plugins/"
            DESTINATION "${CMAKE_INSTALL_DATADIR}/lite-xl/plugins")
    install(DIRECTORY "${CMAKE_SOURCE_DIR}/data/colors/"
            DESTINATION "${CMAKE_INSTALL_DATADIR}/lite-xl/colors")
    install(DIRECTORY "${CMAKE_SOURCE_DIR}/docs/api/"
            DESTINATION "${CMAKE_INSTALL_DATADIR}/lite-xl")
    install(FILES "${CMAKE_BINARY_DIR}/start.lua"
            DESTINATION "${CMAKE_INSTALL_DATADIR}/lite-xl/core")
    install(FILES "${CMAKE_SOURCE_DIR}/licenses/licenses.md"
            DESTINATION "${CMAKE_INSTALL_DATADIR}/doc/lite-xl")

    if(UNIX AND NOT APPLE)
        install(FILES
                "${CMAKE_SOURCE_DIR}/resources/icons/lite-xl.svg"
                DESTINATION
                "${CMAKE_INSTALL_DATADIR}/icons/hicolor/scalable/apps")
        install(FILES
                "${CMAKE_SOURCE_DIR}/resources/linux/com.lite_xl.LiteXL.desktop"
                DESTINATION "${CMAKE_INSTALL_DATADIR}/applications")
        install(FILES
                "${CMAKE_BINARY_DIR}/com.lite_xl.LiteXL.metainfo.xml"
                DESTINATION "${CMAKE_INSTALL_DATADIR}/metainfo")
    endif()
endif()
