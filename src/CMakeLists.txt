# ===========================================================================
# Sources
# ===========================================================================
set(LITE_SOURCES
    api/api.c
    api/renderer.c
    api/renwindow.c
    api/system.c
    api/utf8.c
    api/buffer.c
    custom_events.c
    renderer.c
    renwindow.c
    rencache.c
    main.c
)

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
    editingcore::editingcore
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

# macOS: link system frameworks required by bundle_open.m (the dirmonitor
# fsevents backend in libeditingcore adds its own)
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
