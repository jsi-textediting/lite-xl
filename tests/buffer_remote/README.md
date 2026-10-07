# buffer_remote tests

Tests for the remote (lazy, chunk-table backed) piece source in `src/api/buffer.c`
plus regression tests for the local mmap/heap path. They run on POSIX (Linux, WSL)
and build `buffer.c` as a Lua module together with a sanitized Lua interpreter.

    tests/buffer_remote/run.sh                 # all tests, ASAN + UBSAN + LeakSanitizer
    tests/buffer_remote/run.sh test_fuzz.lua   # one test
    SAN=0 tests/buffer_remote/run.sh           # without sanitizers (timings)
    FUZZ_STEPS=2000 FUZZ_SEEDS=6 tests/buffer_remote/run.sh test_fuzz.lua
    SPARSE_CHUNKS=1000000 ...                  # size of the sparse-table test

Needs `gcc` and the Lua sources (default `build/_deps/lua-src/src`, created by the
CMake configure step; override with `LUA_SRC=`). Build products go to `OUT`
(default `/tmp/buffer_remote_build`).

* `test_basic.lua`  local buffers: open/read/empty/no trailing newline, random edits
  (including removals spanning several pieces) against a string model, save round trip.
* `test_remote.lua` parity with the local engine for many chunk sizes, CRLF, missing
  final newline, empty file, lines longer than a chunk; placeholder/missing/dedupe/cancel;
  supply validation; edits needing bytes; `get_text` with `sync_fn`; LRU, pinning,
  budgets; stale; `edit_script`/`rebase`; argument validation; a 1,000,000 chunk sparse
  table (open time, memory, jumps, a tiny edit script).
* `test_fuzz.lua`   random insert/remove/evict/stale/rebase sequences with a lazy fake
  server and tiny budgets, compared with a string model; the edit script applied to the
  original file must always equal the model.
* `util.lua`        shared helpers (fake fetcher, edit-script applier, text generators).

## Remote buffer API summary

Chunk indices are 1-based everywhere in Lua. `orig_off` values are 0-based file offsets.

    buffer.open_remote{size=N, chunks={{len,lf},...} | {len1,lf1,len2,lf2,...},
                       ends_with_nl=<bool, required>, chunk_size=65536, budget=268435456} -> buf
    buf:is_remote()                    -> bool
    buf[i]                             -> line, or "\xe2\x80\xa6\n" (placeholder) if not loaded
    buf:missing([max=256])             -> { {idx, orig_off, len}, ... }  (drains the queue)
    buf:supply(idx, data)              -> true | false, err
    buf:cancel(idx)                    -> bool   (give a pending chunk up so it can be requested again)
    buf:is_resident(line1 [, line2])   -> bool   (never queues anything)
    buf:evict(idx)                     -> true | false, "pinned"|"bad chunk index"
    buf:pin(idx, bool), buf:set_budget(bytes), buf:stats()   (stats().held_bytes: kept for pending reads)
    buf:loaded_chunks()                -> { idx, ... }  (loaded at least once since open/rebase)
    buf:chunk_matches(idx, data)       -> bool | nil    (same bytes as loaded; nil if never loaded)
    buf:get_text(l1,c1,l2,c2 [, sync_fn(idx, orig_off, len) -> data]) -> text | nil, err
    buf:insert(...) / buf:remove(...)  -> true | false, "not loaded"|"stale"|"out of memory"
    buf:edit_script()                  -> script, inserts  (unedited: the original file, no virtual newline)
    buf:rebase(size, chunks, ends_with_nl) -> true   (error if the table is inconsistent; ends_with_nl required)
    buf:set_stale(bool)
