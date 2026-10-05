# ===========================================================================
# Sources
# ===========================================================================
set(LITE_SOURCES
    api/api.c
    api/renderer.c
    api/renwindow.c
    api/regex.c
    api/system.c
    api/process.c
    api/utf8.c
    api/buffer.c
    api/dirmonitor.c
    arena_allocator.c
    custom_events.c
    renderer.c
    renwindow.c
    rencache.c
    main.c
)

# ===========================================================================
# dirmonitor backend  (auto-detected if LITE_DIRMONITOR_BACKEND is empty)
# ===========================================================================
if(LITE_DIRMONITOR_BACKEND STREQUAL "")
    if(WIN32)
        set(LITE_DIRMONITOR_BACKEND "win32")
    elseif(APPLE)
        include(CheckIncludeFile)
        check_include_file("CoreServices/CoreServices.h" _have_coreservices)
        if(_have_coreservices)
            set(LITE_DIRMONITOR_BACKEND "fsevents")
        else()
            set(LITE_DIRMONITOR_BACKEND "dummy")
        endif()
    else()
        # Linux / BSD: prefer inotify, fall back to kqueue, then dummy
        include(CheckFunctionExists)
        include(CheckIncludeFile)
        check_include_file("sys/inotify.h" _have_inotify_h)
        if(_have_inotify_h)
            set(LITE_DIRMONITOR_BACKEND "inotify")
        else()
            check_function_exists(kqueue _have_kqueue)
            if(_have_kqueue)
                set(LITE_DIRMONITOR_BACKEND "kqueue")
            else()
                set(LITE_DIRMONITOR_BACKEND "dummy")
                message(WARNING
                    "No suitable dirmonitor backend found; "
                    "falling back to the dummy (polling) backend.")
            endif()
        endif()
    endif()
    message(STATUS "dirmonitor_backend: ${LITE_DIRMONITOR_BACKEND} (auto-detected)")
else()
    message(STATUS "dirmonitor_backend: ${LITE_DIRMONITOR_BACKEND} (user-specified)")
endif()

# Append the chosen backend source file
if(LITE_DIRMONITOR_BACKEND STREQUAL "inotify")
    list(APPEND LITE_SOURCES api/dirmonitor/inotify.c)
elseif(LITE_DIRMONITOR_BACKEND STREQUAL "fsevents")
    list(APPEND LITE_SOURCES api/dirmonitor/fsevents.c)
elseif(LITE_DIRMONITOR_BACKEND STREQUAL "kqueue")
    list(APPEND LITE_SOURCES api/dirmonitor/kqueue.c)
elseif(LITE_DIRMONITOR_BACKEND STREQUAL "inodewatcher")
    enable_language(CXX)
    list(APPEND LITE_SOURCES api/dirmonitor/inodewatcher.cpp)
elseif(LITE_DIRMONITOR_BACKEND STREQUAL "win32")
    list(APPEND LITE_SOURCES api/dirmonitor/win32.c)
else()
    list(APPEND LITE_SOURCES api/dirmonitor/dummy.c)
endif()

# ===========================================================================
# Platform-specific sources
# ===========================================================================

# Windows: embed the application icon and the exe manifest as resources
if(WIN32)
    enable_language(RC)
    list(APPEND LITE_SOURCES
        "${CMAKE_SOURCE_DIR}/resources/icons/icon.rc"
        "${CMAKE_SOURCE_DIR}/resources/windows/manifest.rc"
    )
    # manifest.rc contains:  IDR_RT_MANIFEST1 RT_MANIFEST "lite-xl.exe.manifest"
    # The manifest file is generated into CMAKE_BINARY_DIR, so tell the RC
    # compiler to search there.
    set_source_files_properties(
        "${CMAKE_SOURCE_DIR}/resources/windows/manifest.rc"
        PROPERTIES COMPILE_FLAGS "/I\"${CMAKE_BINARY_DIR}\""
    )
endif()

# macOS: Objective-C helper for opening files from the Finder / CLI
if(APPLE)
    enable_language(OBJC)
    list(APPEND LITE_SOURCES bundle_open.m)
endif()

# ===========================================================================
# Compile definitions
# ===========================================================================
set(_lite_defines
    PCRE2_STATIC
    "LITE_PROJECT_VERSION_STR=\"${LITE_VERSION}\""
    "LITE_ARCH_TUPLE=\"${LITE_ARCH_TUPLE}\""
)
if(LITE_USE_SDL_RENDERER OR APPLE)
    list(APPEND _lite_defines LITE_USE_SDL_RENDERER)
endif()
if(APPLE AND LITE_BUNDLE)
    list(APPEND _lite_defines MACOS_USE_BUNDLE)
endif()

# ===========================================================================
# Executable
# ===========================================================================
add_executable(lite-xl ${LITE_SOURCES})

target_include_directories(lite-xl PRIVATE .)

target_compile_definitions(lite-xl PRIVATE ${_lite_defines})

target_link_libraries(lite-xl PRIVATE
    ${_lite_lua_target}
    SDL3::SDL3-static
    freetype
    pcre2-8
)

# ===========================================================================
# Platform-specific link settings
# ===========================================================================

# Windows: suppress the console window (mirrors win_subsystem: 'windows')
if(WIN32)
    set_target_properties(lite-xl PROPERTIES WIN32_EXECUTABLE TRUE)
    # Disable the linker's auto-generated manifest so it does not conflict
    # with the custom manifest we embed through manifest.rc (CVT1100 / LNK1123).
    if(MSVC)
        target_link_options(lite-xl PRIVATE /MANIFEST:NO)
    endif()
    # Some of these are already pulled in transitively by SDL3, but listing
    # them explicitly ensures correctness regardless of SDL3 configuration.
    target_link_libraries(lite-xl PRIVATE
        winmm imm32 version setupapi ole32 oleaut32 uuid
    )

# macOS: link system frameworks required by the dirmonitor fsevents backend
# and by bundle_open.m
elseif(APPLE)
    target_link_options(lite-xl PRIVATE
        -framework CoreServices
        -framework Foundation
    )

# Linux / BSD: link libm and libdl where available
else()
    find_library(M_LIB  m)
    find_library(DL_LIB dl)
    if(M_LIB)
        target_link_libraries(lite-xl PRIVATE ${M_LIB})
    endif()
    if(DL_LIB)
        target_link_libraries(lite-xl PRIVATE ${DL_LIB})
    endif()
endif()

# ===========================================================================
# Install (binary only; data files are handled in the root CMakeLists.txt)
# ===========================================================================
if(WIN32 OR LITE_PORTABLE)
    install(TARGETS lite-xl RUNTIME DESTINATION .)
elseif(APPLE AND LITE_BUNDLE)
    # Manually place the binary inside the .app bundle structure.
    # The caller is expected to set CMAKE_INSTALL_PREFIX to the .app path,
    # e.g.:  cmake --install . --prefix /Applications/lite-xl.app
    install(TARGETS lite-xl RUNTIME DESTINATION Contents/MacOS)
else()
    include(GNUInstallDirs)
    install(TARGETS lite-xl RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}")
endif()
