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

# <name>|<github owner/repo>|<revision>|<subdirectory containing src/ ("." for repo root)>|<sha256 of the GitHub archive tarball>
# (hash = sha256 of https://github.com/<repo>/archive/<revision>.tar.gz)
set(LITE_TS_GRAMMARS
    "c|tree-sitter/tree-sitter-c|2a265d69a4caf57108a73ad2ed1e6922dd2f998c|.|b79cec7ba0b0133f7d1f406340b294466af514c3e1a042555ed0cc8d5cec5d29"
    "cpp|tree-sitter/tree-sitter-cpp|e5cea0ec884c5c3d2d1e41a741a66ce13da4d945|.|8154b5b842b7a41f88ce6831738d6743af62e4c85598cf9d2f80384f0f356be0"
    "lua|MunifTanjim/tree-sitter-lua|db16e76558122e834ee214c8dc755b4a3edc82a9|.|d202ba8ecc11b3494c22e186811c059d0023647df14a6013cc2d5c1112c6d34d"
    "python|tree-sitter/tree-sitter-python|710796b8b877a970297106e5bbc8e2afa47f86ec|.|305ec775a502976af581ea63ffe39e1d6f1661719131db1204bb7182da386442"
    "javascript|tree-sitter/tree-sitter-javascript|6fbef40512dcd9f0a61ce03a4c9ae7597b36ab5c|.|4a720a2da28221f9468783e27bea4c1ba0983f18847bc72eea3b8c70185f2698"
    "typescript|tree-sitter/tree-sitter-typescript|75b3874edb2dc714fb1fd77a32013d0f8699989f|typescript|96ce4d1b513767d414bcca408efd9b49879162cceecdbed79a88e8ad2184f385"
    "tsx|tree-sitter/tree-sitter-typescript|75b3874edb2dc714fb1fd77a32013d0f8699989f|tsx|96ce4d1b513767d414bcca408efd9b49879162cceecdbed79a88e8ad2184f385"
    "rust|tree-sitter/tree-sitter-rust|e86119bdb4968b9799f6a014ca2401c178d54b5f|.|536562c1ff345bb51e3158903e9afcbf5ea0f4963a37598fe1ecd8ab4718a497"
    "go|tree-sitter/tree-sitter-go|5e73f476efafe5c768eda19bbe877f188ded6144|.|c5bf6d3b9c61207c61d889e6bd69783338749c91ffee71cbb92f3835272eff44"
    "json|tree-sitter/tree-sitter-json|46aa487b3ade14b7b05ef92507fdaa3915a662a3|.|b6276cc85e113e3e752b208bcac6351cf4af69fde261606746ce35893c57cd6e"
    "markdown|MDeiml/tree-sitter-markdown|413285231ce8fa8b11e7074bbe265b48aa7277f9|tree-sitter-markdown|4fa440823981567d2e486f4a1b85c16781adf983c066a22169cfcd7273c679b3"
    "markdown_inline|MDeiml/tree-sitter-markdown|413285231ce8fa8b11e7074bbe265b48aa7277f9|tree-sitter-markdown-inline|4fa440823981567d2e486f4a1b85c16781adf983c066a22169cfcd7273c679b3"
    "bash|tree-sitter/tree-sitter-bash|0c46d792d54c536be5ff7eb18eb95c70fccdb232|.|698387b4d30a32672dc48d6af421a689dd7b9141d259638072d88c95245599cd"
    "query|nvim-treesitter/tree-sitter-query|930202c2a80965a7a9ca018b5b2a08b25dfa7f12|.|64b6ec6ee7fef248a491db225519a42c10c1298c0ba2726d8cab688e9007cd18"
    "vim|neovim/tree-sitter-vim|11b688a1f0e97c0c4e3dbabf4a38016335f4d237|.|d8cfe9e74f1418ec219a37fef99f54b5f80e906971f7bba1e04d5711efbd5e80"
    "vimdoc|neovim/tree-sitter-vimdoc|2694c3d27e2ca98a0ccde72f33887394300d524e|.|cc212eb2a7fd20ab1fa759d44aee823d010eb3e03d6ce424f62fbe700890cbca"
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
    list(GET _fields 4 _sha256)

    # Grammars sharing a repository (typescript/tsx, markdown/markdown_inline) share one download.
    # Downloaded with file(DOWNLOAD) rather than FetchContent so that a failed
    # download only skips this grammar (warning) instead of aborting configure.
    string(MAKE_C_IDENTIFIER "ts_grammar_${_repo}_${_rev}" _fc_name)
    string(TOLOWER "${_fc_name}" _fc_name)
    set(_dl_root "${CMAKE_BINARY_DIR}/_deps/${_fc_name}")
    if(NOT DEFINED _fc_root_${_fc_name})
        set(_fc_root_${_fc_name} "")
        if(NOT EXISTS "${_dl_root}-src/.extracted")
            set(_tarball "${_dl_root}.tar.gz")
            # The hash is checked by hand: with EXPECTED_HASH a mismatch is a fatal
            # error even with STATUS (GitHub archives are not guaranteed byte-stable).
            file(DOWNLOAD "https://github.com/${_repo}/archive/${_rev}.tar.gz" "${_tarball}"
                STATUS _dl_status)
            list(GET _dl_status 0 _dl_code)
            if(_dl_code EQUAL 0)
                file(SHA256 "${_tarball}" _dl_hash)
                if(NOT _dl_hash STREQUAL _sha256)
                    set(_dl_code 1)
                    set(_dl_status "1;SHA256 mismatch: expected ${_sha256}, got ${_dl_hash}")
                endif()
            endif()
            if(_dl_code EQUAL 0)
                file(REMOVE_RECURSE "${_dl_root}-src" "${_dl_root}-tmp")
                file(ARCHIVE_EXTRACT INPUT "${_tarball}" DESTINATION "${_dl_root}-tmp")
                file(GLOB _top "${_dl_root}-tmp/*")
                list(GET _top 0 _top)
                file(RENAME "${_top}" "${_dl_root}-src")
                file(REMOVE_RECURSE "${_dl_root}-tmp")
                file(WRITE "${_dl_root}-src/.extracted" "")
            else()
                file(REMOVE "${_tarball}")
                message(WARNING "tree-sitter grammar '${_name}': download of ${_repo}@${_rev} failed (${_dl_status}), skipping")
            endif()
        endif()
        if(EXISTS "${_dl_root}-src/.extracted")
            set(_fc_root_${_fc_name} "${_dl_root}-src")
        endif()
    endif()
    if(NOT _fc_root_${_fc_name})
        continue()
    endif()
    set(${_fc_name}_SOURCE_DIR "${_fc_root_${_fc_name}}")

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
