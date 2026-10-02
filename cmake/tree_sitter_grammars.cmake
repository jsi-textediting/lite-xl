# Tree-sitter grammars bundled with lite-xl, built as shared libraries into
# libraries/treesitter/parser/<name>.<dll|so> and loaded by the treesit plugin.
#
# Like Lua and SDL, nothing is vendored: each grammar is downloaded at configure
# time from the revision pinned below. Revisions match the nvim-treesitter
# lockfile the bundled queries in data/plugins/treesit/queries were taken from
# (see data/plugins/treesit/queries/REVISION), so grammar and query node names agree.
#
# To add a language: add a line to LITE_TS_GRAMMARS and copy its highlights.scm
# (plus any `; inherits:` parents) into data/plugins/treesit/queries/<name>/.
include(FetchContent)

# <name>|<github owner/repo>|<revision>|<subdirectory containing src/ ("." for repo root)>
set(LITE_TS_GRAMMARS
    "c|tree-sitter/tree-sitter-c|2a265d69a4caf57108a73ad2ed1e6922dd2f998c|."
    "cpp|tree-sitter/tree-sitter-cpp|e5cea0ec884c5c3d2d1e41a741a66ce13da4d945|."
    "lua|MunifTanjim/tree-sitter-lua|db16e76558122e834ee214c8dc755b4a3edc82a9|."
    "python|tree-sitter/tree-sitter-python|710796b8b877a970297106e5bbc8e2afa47f86ec|."
    "javascript|tree-sitter/tree-sitter-javascript|6fbef40512dcd9f0a61ce03a4c9ae7597b36ab5c|."
    "typescript|tree-sitter/tree-sitter-typescript|75b3874edb2dc714fb1fd77a32013d0f8699989f|typescript"
    "tsx|tree-sitter/tree-sitter-typescript|75b3874edb2dc714fb1fd77a32013d0f8699989f|tsx"
    "rust|tree-sitter/tree-sitter-rust|e86119bdb4968b9799f6a014ca2401c178d54b5f|."
    "go|tree-sitter/tree-sitter-go|5e73f476efafe5c768eda19bbe877f188ded6144|."
    "json|tree-sitter/tree-sitter-json|46aa487b3ade14b7b05ef92507fdaa3915a662a3|."
    "markdown|MDeiml/tree-sitter-markdown|413285231ce8fa8b11e7074bbe265b48aa7277f9|tree-sitter-markdown"
    "markdown_inline|MDeiml/tree-sitter-markdown|413285231ce8fa8b11e7074bbe265b48aa7277f9|tree-sitter-markdown-inline"
    "bash|tree-sitter/tree-sitter-bash|0c46d792d54c536be5ff7eb18eb95c70fccdb232|."
    "query|nvim-treesitter/tree-sitter-query|930202c2a80965a7a9ca018b5b2a08b25dfa7f12|."
    "vim|neovim/tree-sitter-vim|11b688a1f0e97c0c4e3dbabf4a38016335f4d237|."
    "vimdoc|neovim/tree-sitter-vimdoc|2694c3d27e2ca98a0ccde72f33887394300d524e|."
)

if(NOT DEFINED LITE_INSTALL_DATA_DIR)
    message(FATAL_ERROR "tree_sitter_grammars.cmake must be included after LITE_INSTALL_DATA_DIR is set")
endif()

set(_ts_parser_dir "${CMAKE_BINARY_DIR}/libraries/treesitter/parser")
if(WIN32)
    set(_ts_parser_suffix ".dll")
else()
    set(_ts_parser_suffix ".so")
endif()

foreach(_entry IN LISTS LITE_TS_GRAMMARS)
    string(REPLACE "|" ";" _fields "${_entry}")
    list(GET _fields 0 _name)
    list(GET _fields 1 _repo)
    list(GET _fields 2 _rev)
    list(GET _fields 3 _subdir)

    # Grammars sharing a repository (typescript/tsx, markdown/markdown_inline) share one download.
    string(MAKE_C_IDENTIFIER "ts_grammar_${_repo}_${_rev}" _fc_name)
    string(TOLOWER "${_fc_name}" _fc_name)
    if(NOT _fc_declared_${_fc_name})
        FetchContent_Declare(${_fc_name}
            URL "https://github.com/${_repo}/archive/${_rev}.tar.gz"
            DOWNLOAD_EXTRACT_TIMESTAMP TRUE
            # Only the sources are needed: don't add_subdirectory() the grammar's own CMakeLists.txt.
            SOURCE_SUBDIR lite-xl-do-not-configure
        )
        FetchContent_MakeAvailable(${_fc_name})
        set(_fc_declared_${_fc_name} TRUE)
    endif()

    set(_src "${${_fc_name}_SOURCE_DIR}/${_subdir}/src")
    if(NOT EXISTS "${_src}/parser.c")
        message(WARNING "tree-sitter grammar '${_name}': ${_src}/parser.c not found, skipping")
        continue()
    endif()
    set(_files "${_src}/parser.c")
    if(EXISTS "${_src}/scanner.c")
        list(APPEND _files "${_src}/scanner.c")
    elseif(EXISTS "${_src}/scanner.cc")
        message(WARNING "tree-sitter grammar '${_name}' has a C++ scanner, skipping")
        continue()
    endif()

    set(_target "ts_grammar_${_name}")
    add_library(${_target} MODULE ${_files})
    set_target_properties(${_target} PROPERTIES
        OUTPUT_NAME "${_name}"
        PREFIX ""
        SUFFIX "${_ts_parser_suffix}"
        C_STANDARD 11
        WINDOWS_EXPORT_ALL_SYMBOLS ON
        LIBRARY_OUTPUT_DIRECTORY "${_ts_parser_dir}"
        RUNTIME_OUTPUT_DIRECTORY "${_ts_parser_dir}"
    )
    foreach(_cfg Debug Release RelWithDebInfo MinSizeRel)
        string(TOUPPER "${_cfg}" _CFG)
        set_target_properties(${_target} PROPERTIES
            LIBRARY_OUTPUT_DIRECTORY_${_CFG} "${_ts_parser_dir}"
            RUNTIME_OUTPUT_DIRECTORY_${_CFG} "${_ts_parser_dir}"
        )
    endforeach()
    target_include_directories(${_target} PRIVATE "${_src}")
    if(MSVC)
        target_compile_definitions(${_target} PRIVATE _CRT_SECURE_NO_WARNINGS)
        target_compile_options(${_target} PRIVATE /utf-8)
    endif()

    install(TARGETS ${_target}
        LIBRARY DESTINATION "${LITE_INSTALL_DATA_DIR}/libraries/treesitter/parser"
        RUNTIME DESTINATION "${LITE_INSTALL_DATA_DIR}/libraries/treesitter/parser"
    )
endforeach()
