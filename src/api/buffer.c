#include "buffer.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
  #include <windows.h>
#else
  #include <sys/mman.h>
  #include <sys/stat.h>
  #include <fcntl.h>
  #include <unistd.h>
#endif

#define CHUNK_SIZE 65536

/*
 * NOTE (POSIX): the file is mapped with mmap(MAP_PRIVATE) and pieces read
 * straight from the mapping. If another process truncates the file while it
 * is mapped, touching pages beyond the new EOF raises SIGBUS. This is a known
 * limitation and is intentionally not guarded against.
 */

/* Single-entry cache for find_offset_by_lineno (sequential line access).
 * Invalidated on any edit and when the cached buffer is destroyed. */
static struct {
  const TextBuffer *buf;
  size_t lineno;
  size_t offset;
} line_cache = { NULL, 0, 0 };

/* ========================================================================= */
/* Remote chunk cache                                                        */
/*                                                                           */
/* Invariants:                                                               */
/*  - Every BUFFER_SRC_REMOTE piece lies inside exactly one chunk (pieces    */
/*    are only ever split or trimmed, never merged), so its bytes are        */
/*    chunk->data + (piece->offset - chunk->orig_off).                       */
/*  - Line/size aggregates live in the tree and never depend on residency;   */
/*    evicting or supplying a chunk therefore cannot change any offset, and  */
/*    the line cache stays valid.                                            */
/*  - Bytes are only needed to (a) read text, (b) count/locate newlines      */
/*    inside a piece that covers just part of a chunk. Whole-chunk pieces    */
/*    use the lf count from the server table and need no data.               */
/*  - Chunks at a partial piece boundary created by an edit are pinned       */
/*    (PIN_EDIT) so the geometry around edits stays computable. Pins are     */
/*    dropped by rebase. Eviction itself only happens inside supply/evict/   */
/*    set_budget (never inside a read), so an operation can never lose bytes */
/*    it is using; get_text with a sync_fn additionally disables automatic   */
/*    eviction until it has finished copying.                                */
/*  - A line read that fails holds every chunk it needs (hold = the current  */
/*    fetch round), and later reads renew the hold, so a line whose chunks   */
/*    exceed the budget still becomes and stays readable instead of being    */
/*    evicted piecemeal forever. A sync get_text holds the chunks a          */
/*    following remove at the same positions needs. Holds lapse after        */
/*    HOLD_ROUNDS missing() calls without a read.                            */
/* ========================================================================= */

#define PLACEHOLDER_LINE "\xe2\x80\xa6\n"
#define PLACEHOLDER_LEN 4
#define DEFAULT_REMOTE_BUDGET ((size_t)256 * 1024 * 1024)
#define CHUNK_NONE UINT32_MAX
#define HOLD_ROUNDS 4

enum { CHUNK_MISSING = 0, CHUNK_PENDING = 1, CHUNK_RESIDENT = 2 };
enum { PIN_USER = 1, PIN_EDIT = 2 };
enum { ERR_NONE = 0, ERR_NOT_LOADED, ERR_STALE, ERR_NOMEM, ERR_SYNC, ERR_NOT_REMOTE };

static const char *buf_err_string(const TextBuffer *buf) {
  switch (buf->err) {
    case ERR_NOT_LOADED: return "not loaded";
    case ERR_STALE: return "stale";
    case ERR_NOMEM: return "out of memory";
    case ERR_SYNC: return buf->err_msg;
    case ERR_NOT_REMOTE: return "not a remote buffer";
    default: return "failed";
  }
}

static void buf_set_err(TextBuffer *buf, int err) {
  if (buf->err == ERR_NONE) buf->err = err;
}

static void set_err_msg(TextBuffer *buf, const char *prefix, const char *msg) {
  snprintf(buf->err_msg, sizeof(buf->err_msg), "%s%s", prefix, msg ? msg : "");
  buf_set_err(buf, ERR_SYNC);
}

static size_t count_newlines(const char *data, size_t len) {
  size_t count = 0;
  const char *end = data + len;
  while (data < end) {
    const char *p = (const char *)memchr(data, '\n', end - data);
    if (!p) break;
    count++;
    data = p + 1;
  }
  return count;
}

/* Index of the chunk containing orig file offset pos, or CHUNK_NONE. */
static uint32_t chunk_find(const TextBuffer *buf, size_t pos) {
  size_t lo = 0, hi = buf->nchunks;
  while (lo < hi) {
    size_t mid = lo + (hi - lo) / 2;
    const RemoteChunk *c = &buf->chunks[mid];
    if (pos < c->orig_off) hi = mid;
    else if (pos >= c->orig_off + c->len) lo = mid + 1;
    else return (uint32_t)mid;
  }
  return CHUNK_NONE;
}

static void lru_unlink(TextBuffer *buf, uint32_t i) {
  RemoteChunk *c = &buf->chunks[i];
  if (c->prev != CHUNK_NONE) buf->chunks[c->prev].next = c->next;
  else buf->lru_head = c->next;
  if (c->next != CHUNK_NONE) buf->chunks[c->next].prev = c->prev;
  else buf->lru_tail = c->prev;
  c->prev = c->next = CHUNK_NONE;
}

static void lru_push_front(TextBuffer *buf, uint32_t i) {
  RemoteChunk *c = &buf->chunks[i];
  c->prev = CHUNK_NONE;
  c->next = buf->lru_head;
  if (buf->lru_head != CHUNK_NONE) buf->chunks[buf->lru_head].prev = i;
  buf->lru_head = i;
  if (buf->lru_tail == CHUNK_NONE) buf->lru_tail = i;
}

static void chunk_evict(TextBuffer *buf, uint32_t i) {
  RemoteChunk *c = &buf->chunks[i];
  if (c->state != CHUNK_RESIDENT) return;
  lru_unlink(buf, i);
  free(c->data);
  c->data = NULL;
  c->state = CHUNK_MISSING;
  buf->resident_bytes -= c->len;
  if (c->pins) buf->pinned_bytes -= c->len; /* defensive: pinned chunks are never evicted */
}

/* Changes the pin bits of a chunk, keeping pinned_bytes (resident pinned
 * bytes, which do not count against the budget) in step. */
static void chunk_set_pins(TextBuffer *buf, uint32_t i, uint8_t pins) {
  RemoteChunk *c = &buf->chunks[i];
  if (c->state == CHUNK_RESIDENT) {
    if (!c->pins && pins) buf->pinned_bytes += c->len;
    else if (c->pins && !pins) buf->pinned_bytes -= c->len;
  }
  c->pins = pins;
}

/* True while a recent read needs the chunk (see the invariants above). */
static bool chunk_held(const TextBuffer *buf, const RemoteChunk *c) {
  return c->hold != 0 && buf->round - c->hold < HOLD_ROUNDS;
}

/* Evict least recently used unpinned, unheld chunks until the unpinned
 * resident bytes are within budget. Pinned chunks (edit sites) are exempt so
 * that a pile of edits can never starve the cache of room for the chunks being
 * read; held chunks are exempt so that the reads needing them can complete. */
static void evict_to_budget(TextBuffer *buf, uint32_t keep) {
  if (!buf->remote || buf->sync_L) return;
  uint32_t i = buf->lru_tail;
  while (buf->resident_bytes - buf->pinned_bytes > buf->budget && i != CHUNK_NONE) {
    uint32_t prev = buf->chunks[i].prev;
    if (i != keep && buf->chunks[i].pins == 0 && !chunk_held(buf, &buf->chunks[i])) chunk_evict(buf, i);
    i = prev;
  }
}

/* FNV-1a: remembers what a chunk held so a later file version can be compared. */
static uint64_t hash_bytes(const char *data, size_t len) {
  uint64_t h = 14695981039346656037ULL;
  for (size_t i = 0; i < len; i++) {
    h ^= (unsigned char)data[i];
    h *= 1099511628211ULL;
  }
  return h;
}

static bool queue_push(TextBuffer *buf, uint32_t idx) {
  if (buf->qhead > 0 && buf->qhead == buf->qlen) buf->qhead = buf->qlen = 0;
  if (buf->qlen == buf->qcap) {
    if (buf->qhead > buf->qcap / 2) {
      memmove(buf->queue, buf->queue + buf->qhead, (buf->qlen - buf->qhead) * sizeof(uint32_t));
      buf->qlen -= buf->qhead;
      buf->qhead = 0;
    } else {
      size_t ncap = buf->qcap ? buf->qcap * 2 : 64;
      uint32_t *nq = (uint32_t *)realloc(buf->queue, ncap * sizeof(uint32_t));
      if (!nq) return false;
      buf->queue = nq;
      buf->qcap = ncap;
    }
  }
  buf->queue[buf->qlen++] = idx;
  return true;
}

/* Forget every pending request (all pending chunks become missing again). */
static void queue_reset(TextBuffer *buf) {
  for (size_t i = 0; i < buf->nchunks; i++) {
    RemoteChunk *c = &buf->chunks[i];
    c->queued = 0;
    if (c->state == CHUNK_PENDING) c->state = CHUNK_MISSING;
  }
  buf->qhead = buf->qlen = 0;
}

/* Validate and store the bytes of chunk idx. On failure *err is set. */
static bool chunk_supply(TextBuffer *buf, uint32_t idx, const char *data, size_t len, const char **err) {
  RemoteChunk *c = &buf->chunks[idx];
  if (c->state == CHUNK_RESIDENT) return true;
  if (len != c->len) { *err = "length mismatch"; return false; }
  if (count_newlines(data, len) != c->lf) { *err = "newline count mismatch"; return false; }
  if (idx == buf->nchunks - 1 && (data[len - 1] == '\n') == buf->virtual_nl) {
    *err = "final newline mismatch";
    return false;
  }
  char *copy = (char *)malloc(len);
  if (!copy) { *err = "out of memory"; return false; }
  memcpy(copy, data, len);
  c->data = copy;
  c->hash = hash_bytes(data, len);
  c->hashed = 1;
  c->state = CHUNK_RESIDENT;
  buf->resident_bytes += len;
  if (c->pins) buf->pinned_bytes += len;
  lru_push_front(buf, idx);
  evict_to_budget(buf, idx);
  return true;
}

static const char *chunk_fetch_sync(TextBuffer *buf, uint32_t idx) {
  lua_State *L = buf->sync_L;
  RemoteChunk *c = &buf->chunks[idx];
  if (buf->err == ERR_SYNC) return NULL;
  lua_pushvalue(L, buf->sync_fn);
  lua_pushinteger(L, (lua_Integer)idx + 1);
  lua_pushinteger(L, (lua_Integer)c->orig_off);
  lua_pushinteger(L, (lua_Integer)c->len);
  if (lua_pcall(L, 3, 1, 0) != LUA_OK) {
    set_err_msg(buf, "sync_fn: ", lua_type(L, -1) == LUA_TSTRING ? lua_tostring(L, -1) : "error");
    lua_pop(L, 1);
    return NULL;
  }
  if (lua_type(L, -1) != LUA_TSTRING) {
    lua_pop(L, 1);
    set_err_msg(buf, "sync_fn: no data returned", NULL);
    return NULL;
  }
  size_t n = 0;
  const char *s = lua_tolstring(L, -1, &n);
  const char *err = NULL;
  bool ok = chunk_supply(buf, idx, s, n, &err);
  lua_pop(L, 1);
  if (!ok) {
    set_err_msg(buf, "sync_fn: ", err);
    return NULL;
  }
  return c->data;
}

/* Bytes of chunk idx, or NULL when they are not available right now. Unless
 * probing, a missing chunk is queued for the fetcher (deduplicated). */
static const char *chunk_data(TextBuffer *buf, uint32_t idx) {
  RemoteChunk *c = &buf->chunks[idx];
  if (buf->stale) {
    buf_set_err(buf, ERR_STALE);
    return NULL;
  }
  if (buf->record_touch && buf->ntouched < sizeof(buf->touched) / sizeof(buf->touched[0]))
    buf->touched[buf->ntouched++] = idx;
  if (!buf->no_enqueue && chunk_held(buf, c)) c->hold = buf->round; /* still needed */
  if (c->state == CHUNK_RESIDENT) {
    if (buf->lru_head != idx) {
      lru_unlink(buf, idx);
      lru_push_front(buf, idx);
    }
    return c->data;
  }
  if (buf->sync_L) return chunk_fetch_sync(buf, idx);
  buf_set_err(buf, ERR_NOT_LOADED);
  if (!buf->no_enqueue) {
    if (c->state == CHUNK_MISSING) {
      if (c->queued) {
        c->state = CHUNK_PENDING; /* cancelled earlier, its queue entry is still there */
      } else if (queue_push(buf, idx)) {
        c->state = CHUNK_PENDING;
        c->queued = 1;
      }
    }
  }
  return NULL;
}

/* Pin the chunk holding orig offset pos when pos is not on a chunk boundary
 * (a piece edge there needs the chunk bytes to count newlines later). */
static void pin_boundary(TextBuffer *buf, size_t pos) {
  uint32_t idx = chunk_find(buf, pos);
  if (idx == CHUNK_NONE) return;
  if (pos != buf->chunks[idx].orig_off) chunk_set_pins(buf, idx, buf->chunks[idx].pins | PIN_EDIT);
}

/* Chunk backing a remote piece plus the piece's start offset inside it. */
static uint32_t piece_chunk(const TextBuffer *buf, const PieceNode *node, size_t *coff) {
  uint32_t idx = chunk_find(buf, node->offset);
  if (idx == CHUNK_NONE) return CHUNK_NONE;
  const RemoteChunk *c = &buf->chunks[idx];
  if (node->offset + node->length > c->orig_off + c->len) return CHUNK_NONE;
  *coff = node->offset - c->orig_off;
  return idx;
}

/* Contiguous bytes of piece starting at off (at least one byte if off <
 * node->length): sets *out and *avail. False when not currently readable. */
static bool piece_read(TextBuffer *buf, const PieceNode *node, size_t off, const char **out, size_t *avail) {
  if (node->source == BUFFER_SRC_REMOTE) {
    size_t coff = 0;
    uint32_t idx = piece_chunk(buf, node, &coff);
    if (idx == CHUNK_NONE) {
      buf_set_err(buf, ERR_NOT_LOADED);
      return false;
    }
    const char *d = chunk_data(buf, idx);
    if (!d) return false;
    *out = d + coff + off;
  } else if (node->source == BUFFER_SRC_MMAP) {
    *out = buf->mmap_data + node->offset + off;
  } else {
    *out = buf->heap_data + node->offset + off;
  }
  *avail = node->length - off;
  return true;
}

/* Number of '\n' in piece bytes [off, off+len). Whole-chunk remote pieces and
 * sub-ranges that need no data never touch the chunk bytes. */
static bool piece_count_lf(TextBuffer *buf, const PieceNode *node, size_t off, size_t len, size_t *out) {
  if (node->source != BUFFER_SRC_REMOTE) {
    const char *data;
    size_t avail;
    piece_read(buf, node, off, &data, &avail);
    *out = count_newlines(data, len);
    return true;
  }
  if (off == 0 && len == node->length) {
    *out = node->line_feed_cnt;
    return true;
  }
  if (len == 0) {
    *out = 0;
    return true;
  }
  const char *data;
  size_t avail;
  if (!piece_read(buf, node, off, &data, &avail)) return false;
  *out = count_newlines(data, len);
  return true;
}

static PieceNode *node_new(TextBuffer *buf, BufferSourceType src, size_t off, size_t len, size_t lfc) {
  PieceNode *node = (PieceNode *)malloc(sizeof(PieceNode));
  if (!node) return NULL;
  node->parent = buf->nil_node;
  node->left = buf->nil_node;
  node->right = buf->nil_node;
  node->color = 0; /* RED by default */
  node->source = src;
  node->offset = off;
  node->length = len;
  node->line_feed_cnt = lfc;
  node->size_left = 0;
  node->lf_cnt_left = 0;
  return node;
}

static void rotate_left(TextBuffer *buf, PieceNode *x) {
  PieceNode *y = x->right;
  x->right = y->left;
  if (y->left != buf->nil_node) {
    y->left->parent = x;
  }
  y->parent = x->parent;
  if (x->parent == buf->nil_node) {
    buf->root = y;
  } else if (x == x->parent->left) {
    x->parent->left = y;
  } else {
    x->parent->right = y;
  }
  y->left = x;
  x->parent = y;

  /* Update augmented tree metadata */
  y->size_left += x->size_left + x->length;
  y->lf_cnt_left += x->lf_cnt_left + x->line_feed_cnt;
}

static void rotate_right(TextBuffer *buf, PieceNode *y) {
  PieceNode *x = y->left;
  y->left = x->right;
  if (x->right != buf->nil_node) {
    x->right->parent = y;
  }
  x->parent = y->parent;
  if (y->parent == buf->nil_node) {
    buf->root = x;
  } else if (y == y->parent->right) {
    y->parent->right = x;
  } else {
    y->parent->left = x;
  }
  x->right = y;
  y->parent = x;

  /* Update augmented tree metadata */
  y->size_left -= (x->size_left + x->length);
  y->lf_cnt_left -= (x->lf_cnt_left + x->line_feed_cnt);
}

static void update_aggregates_to_root(TextBuffer *buf, PieceNode *node, ptrdiff_t delta_size, ptrdiff_t delta_lf) {
  while (node->parent != buf->nil_node) {
    if (node == node->parent->left) {
      node->parent->size_left += delta_size;
      node->parent->lf_cnt_left += delta_lf;
    }
    node = node->parent;
  }
}

static void rb_insert_fixup(TextBuffer *buf, PieceNode *z) {
  while (z->parent->color == 0) {
    if (z->parent == z->parent->parent->left) {
      PieceNode *y = z->parent->parent->right;
      if (y->color == 0) {
        z->parent->color = 1;
        y->color = 1;
        z->parent->parent->color = 0;
        z = z->parent->parent;
      } else {
        if (z == z->parent->right) {
          z = z->parent;
          rotate_left(buf, z);
        }
        z->parent->color = 1;
        z->parent->parent->color = 0;
        rotate_right(buf, z->parent->parent);
      }
    } else {
      PieceNode *y = z->parent->parent->left;
      if (y->color == 0) {
        z->parent->color = 1;
        y->color = 1;
        z->parent->parent->color = 0;
        z = z->parent->parent;
      } else {
        if (z == z->parent->left) {
          z = z->parent;
          rotate_right(buf, z);
        }
        z->parent->color = 1;
        z->parent->parent->color = 0;
        rotate_left(buf, z->parent->parent);
      }
    }
  }
  buf->root->color = 1;
}

static PieceNode *build_tree_from_array(TextBuffer *buf, PieceNode **nodes, int start, int end) {
  if (start > end) return buf->nil_node;
  int mid = start + (end - start) / 2;
  PieceNode *node = nodes[mid];

  node->left = build_tree_from_array(buf, nodes, start, mid - 1);
  if (node->left != buf->nil_node) {
    node->left->parent = node;
  }

  node->right = build_tree_from_array(buf, nodes, mid + 1, end);
  if (node->right != buf->nil_node) {
    node->right->parent = node;
  }

  /* Compute size_left and lf_cnt_left from left subtree */
  node->size_left = 0;
  node->lf_cnt_left = 0;
  PieceNode *curr = node->left;
  while (curr != buf->nil_node) {
    node->size_left += curr->size_left + curr->length;
    node->lf_cnt_left += curr->lf_cnt_left + curr->line_feed_cnt;
    curr = curr->right;
  }

  node->color = 1; /* Black for balanced array tree */
  return node;
}

static void free_tree(TextBuffer *buf, PieceNode *node) {
  if (node == buf->nil_node || !node) return;
  free_tree(buf, node->left);
  free_tree(buf, node->right);
  free(node);
}

static PieceNode *find_piece_by_offset(TextBuffer *buf, size_t offset, size_t *out_piece_offset) {
  PieceNode *node = buf->root;
  while (node != buf->nil_node) {
    if (node->left != buf->nil_node && offset < node->size_left) {
      node = node->left;
    } else {
      if (node->left != buf->nil_node) {
        offset -= node->size_left;
      }
      if (offset < node->length) {
        if (out_piece_offset) *out_piece_offset = offset;
        return node;
      }
      if (offset == node->length && node->right == buf->nil_node) {
        if (out_piece_offset) *out_piece_offset = offset;
        return node;
      }
      offset -= node->length;
      node = node->right;
    }
  }
  return NULL;
}

static bool find_offset_by_lineno_uncached(TextBuffer *buf, size_t lineno, size_t *out) {
  size_t target_lf = lineno - 1;
  PieceNode *node = buf->root;
  size_t accum_offset = 0;

  while (node != buf->nil_node) {
    if (node->left != buf->nil_node && target_lf <= node->lf_cnt_left) {
      node = node->left;
    } else {
      if (node->left != buf->nil_node) {
        accum_offset += node->size_left;
        target_lf -= node->lf_cnt_left;
      }
      if (target_lf <= node->line_feed_cnt) {
        /* The target newline is inside this piece */
        const char *data = NULL;
        size_t avail = 0;
        if (!piece_read(buf, node, 0, &data, &avail)) return false;
        const char *p = data;
        const char *end = data + node->length;
        while (p < end) {
          const char *nl = (const char *)memchr(p, '\n', end - p);
          if (!nl) break;
          target_lf--;
          if (target_lf == 0) {
            *out = accum_offset + (size_t)(nl - data) + 1; /* Position immediately after '\n' */
            return true;
          }
          p = nl + 1;
        }
      }
      accum_offset += node->length;
      target_lf -= node->line_feed_cnt;
      node = node->right;
    }
  }
  *out = buf->total_size;
  return true;
}

/* Byte offset of the start of line lineno. False if bytes needed to locate it
 * are not loaded (the chunks are queued and buf->err is set). Only successful
 * lookups are cached: the cache holds offsets, which never depend on which
 * remote chunks are resident. */
static bool find_offset_by_lineno(TextBuffer *buf, size_t lineno, size_t *out) {
  if (lineno <= 1) {
    *out = 0;
    return true;
  }
  if (line_cache.buf == buf && line_cache.lineno == lineno) {
    *out = line_cache.offset;
    return true;
  }
  size_t off = 0;
  if (!find_offset_by_lineno_uncached(buf, lineno, &off)) return false;
  line_cache.buf = buf;
  line_cache.lineno = lineno;
  line_cache.offset = off;
  *out = off;
  return true;
}

static bool append_to_heap(TextBuffer *buf, const char *text, size_t len, size_t *out_offset) {
  if (buf->heap_size + len > buf->heap_capacity) {
    size_t new_cap = buf->heap_capacity == 0 ? 4096 : buf->heap_capacity * 2;
    while (new_cap < buf->heap_size + len) new_cap *= 2;
    char *new_data = (char *)realloc(buf->heap_data, new_cap);
    if (!new_data) return false;
    buf->heap_data = new_data;
    buf->heap_capacity = new_cap;
  }
  *out_offset = buf->heap_size;
  memcpy(buf->heap_data + buf->heap_size, text, len);
  buf->heap_size += len;
  return true;
}

/* Insert a piece node as the right child or successor */
static void insert_node_right(TextBuffer *buf, PieceNode *target, PieceNode *new_node) {
  if (target->right == buf->nil_node) {
    target->right = new_node;
    new_node->parent = target;
  } else {
    PieceNode *curr = target->right;
    while (curr->left != buf->nil_node) {
      curr = curr->left;
    }
    curr->left = new_node;
    new_node->parent = curr;
  }
  update_aggregates_to_root(buf, new_node, new_node->length, new_node->line_feed_cnt);
  rb_insert_fixup(buf, new_node);
}

static bool buffer_insert_raw(TextBuffer *buf, size_t global_offset, const char *text, size_t len) {
  if (len == 0) return true;
  buf->err = ERR_NONE;
  if (buf->remote && buf->stale) {
    buf->err = ERR_STALE;
    return false;
  }
  line_cache.buf = NULL;
  size_t heap_off = 0;
  size_t old_heap_size = buf->heap_size;
  if (!append_to_heap(buf, text, len, &heap_off)) return false;

  size_t lfc = count_newlines(text, len);

  /* Allocate every node up front so that failure leaves the tree untouched. */
  PieceNode *new_node = node_new(buf, BUFFER_SRC_HEAP, heap_off, len, lfc);
  PieceNode *right_node = NULL;
  size_t piece_off = 0;
  PieceNode *node = NULL;
  size_t right_len = 0, left_lfc = 0, right_lfc = 0;

  if (new_node && buf->root != buf->nil_node) {
    node = find_piece_by_offset(buf, global_offset, &piece_off);
    if (node && piece_off > 0 && piece_off < node->length) {
      right_len = node->length - piece_off;
      if (!piece_count_lf(buf, node, 0, piece_off, &left_lfc)) {
        free(new_node); /* bytes not loaded: buf->err is set, nothing was changed */
        new_node = NULL;
      } else {
        right_lfc = node->line_feed_cnt - left_lfc;
        right_node = node_new(buf, node->source, node->offset + piece_off, right_len, right_lfc);
        if (!right_node) {
          buf_set_err(buf, ERR_NOMEM);
          free(new_node);
          new_node = NULL;
        }
      }
    }
  } else if (!new_node) {
    buf_set_err(buf, ERR_NOMEM);
  }
  if (!new_node) {
    buf->heap_size = old_heap_size; /* roll back the heap append */
    return false;
  }

  buf->total_size += len;
  buf->total_lines += lfc;

  if (buf->root == buf->nil_node) {
    new_node->color = 1;
    buf->root = new_node;
    return true;
  }

  if (!node) {
    /* Append at end */
    PieceNode *curr = buf->root;
    while (curr->right != buf->nil_node) curr = curr->right;
    insert_node_right(buf, curr, new_node);
    return true;
  }

  if (piece_off == 0) {
    /* Insert before node */
    if (node->left == buf->nil_node) {
      node->left = new_node;
      new_node->parent = node;
      update_aggregates_to_root(buf, new_node, (ptrdiff_t)len, (ptrdiff_t)lfc);
      rb_insert_fixup(buf, new_node);
    } else {
      PieceNode *pred = node->left;
      while (pred->right != buf->nil_node) pred = pred->right;
      insert_node_right(buf, pred, new_node);
    }
  } else if (piece_off == node->length) {
    /* Insert after node */
    insert_node_right(buf, node, new_node);
  } else {
    /* Split piece into left, new, and right */
    if (node->source == BUFFER_SRC_REMOTE) pin_boundary(buf, node->offset + piece_off);
    /* Left part stays in current node */
    ptrdiff_t delta_size = -((ptrdiff_t)right_len);
    ptrdiff_t delta_lf = -((ptrdiff_t)right_lfc);
    node->length = piece_off;
    node->line_feed_cnt = left_lfc;
    update_aggregates_to_root(buf, node, delta_size, delta_lf);

    /* Insert middle (new text) */
    insert_node_right(buf, node, new_node);

    /* Insert right */
    insert_node_right(buf, new_node, right_node);
  }

  return true;
}

/* Removes (or, with dry, only validates) the bytes [off1, off2). A dry run
 * performs every newline count the real run needs and changes nothing, so a
 * remote removal either succeeds completely or fails with the tree untouched. */
static bool buffer_remove_range(TextBuffer *buf, size_t off1, size_t off2, bool dry) {
  size_t curr_off = off1;
  while (curr_off < off2 && buf->total_size > 0) {
    size_t piece_off = 0;
    PieceNode *p = find_piece_by_offset(buf, curr_off, &piece_off);
    if (!p) break;

    size_t p_start = curr_off - piece_off;
    size_t p_end = p_start + p->length;
    size_t del_start = curr_off > p_start ? curr_off : p_start;
    size_t del_end = off2 < p_end ? off2 : p_end;
    size_t del_len = del_end - del_start;

    if (del_len == 0) break;

    size_t del_lfc = 0;
    if (!piece_count_lf(buf, p, del_start - p_start, del_len, &del_lfc)) return false;

    if (del_start == p_start && del_end == p_end) {
      /* Entire piece deleted */
      /* The emptied node stays in the tree (zero length): all traversals
       * tolerate it, and removal would need an augmented RB-tree delete. */
      if (!dry) {
        ptrdiff_t delta_size = -((ptrdiff_t)p->length);
        ptrdiff_t delta_lf = -((ptrdiff_t)p->line_feed_cnt);
        p->length = 0;
        p->line_feed_cnt = 0;
        update_aggregates_to_root(buf, p, delta_size, delta_lf);
        buf->total_size -= del_len;
        buf->total_lines -= del_lfc;
      }
    } else if (del_start == p_start) {
      /* Trim left side */
      if (!dry) {
        size_t trim = del_len;
        ptrdiff_t delta_size = -((ptrdiff_t)trim);
        ptrdiff_t delta_lf = -((ptrdiff_t)del_lfc);
        p->offset += trim;
        p->length -= trim;
        p->line_feed_cnt -= del_lfc;
        update_aggregates_to_root(buf, p, delta_size, delta_lf);
        buf->total_size -= trim;
        buf->total_lines -= del_lfc;
        if (p->source == BUFFER_SRC_REMOTE) pin_boundary(buf, p->offset);
      }
    } else if (del_end == p_end) {
      /* Trim right side */
      if (!dry) {
        size_t trim = del_len;
        ptrdiff_t delta_size = -((ptrdiff_t)trim);
        ptrdiff_t delta_lf = -((ptrdiff_t)del_lfc);
        p->length -= trim;
        p->line_feed_cnt -= del_lfc;
        update_aggregates_to_root(buf, p, delta_size, delta_lf);
        buf->total_size -= trim;
        buf->total_lines -= del_lfc;
        if (p->source == BUFFER_SRC_REMOTE) pin_boundary(buf, p->offset + p->length);
      }
    } else {
      /* Split middle */
      size_t left_len = del_start - p_start;
      size_t right_len = p_end - del_end;
      size_t left_lfc = 0;
      if (!piece_count_lf(buf, p, 0, left_len, &left_lfc)) return false;
      if (!dry) {
        size_t right_lfc = p->line_feed_cnt - left_lfc - del_lfc;

        PieceNode *right_node = node_new(buf, p->source, p->offset + (del_end - p_start), right_len, right_lfc);
        if (!right_node) {
          buf_set_err(buf, ERR_NOMEM);
          return false;
        }

        ptrdiff_t delta_size = -((ptrdiff_t)(p->length - left_len));
        ptrdiff_t delta_lf = -((ptrdiff_t)(p->line_feed_cnt - left_lfc));
        p->length = left_len;
        p->line_feed_cnt = left_lfc;
        update_aggregates_to_root(buf, p, delta_size, delta_lf);

        insert_node_right(buf, p, right_node);

        buf->total_size -= del_len;
        buf->total_lines -= del_lfc;
        if (p->source == BUFFER_SRC_REMOTE) {
          pin_boundary(buf, p->offset + p->length);
          pin_boundary(buf, right_node->offset);
        }
      }
    }

    if (dry) {
      curr_off = del_end;
    } else {
      /* The removed bytes are gone: what followed them now starts at del_start. */
      curr_off = del_start;
      off2 -= del_len;
    }
  }
  return true;
}

static bool buffer_remove_raw(TextBuffer *buf, size_t off1, size_t len) {
  if (len == 0 || buf->total_size == 0) return true;
  buf->err = ERR_NONE;
  if (buf->remote && buf->stale) {
    buf->err = ERR_STALE;
    return false;
  }
  line_cache.buf = NULL;
  size_t off2 = off1 + len;
  if (off2 > buf->total_size) off2 = buf->total_size;

  if (buf->remote && !buffer_remove_range(buf, off1, off2, true)) return false;
  return buffer_remove_range(buf, off1, off2, false);
}

/* ========================================================================= */
/* Public Buffer API                                                         */
/* ========================================================================= */

static TextBuffer *buffer_create(void) {
  TextBuffer *buf = (TextBuffer *)calloc(1, sizeof(TextBuffer));
  if (!buf) return NULL;
  buf->fd = -1;

  buf->nil_node = (PieceNode *)calloc(1, sizeof(PieceNode));
  if (!buf->nil_node) {
    free(buf);
    return NULL;
  }
  buf->nil_node->color = 1; /* BLACK */
  buf->nil_node->left = buf->nil_node;
  buf->nil_node->right = buf->nil_node;
  buf->nil_node->parent = buf->nil_node;

  buf->root = buf->nil_node;
  buf->total_lines = 1;
  buf->lru_head = buf->lru_tail = CHUNK_NONE;
  buf->budget = DEFAULT_REMOTE_BUDGET;
  buf->round = 1;
  return buf;
}

#ifdef _WIN32
static wchar_t *utf8_to_wide(const char *s) {
  int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
  if (n <= 0) return NULL;
  wchar_t *w = (wchar_t *)malloc((size_t)n * sizeof(wchar_t));
  if (!w) return NULL;
  if (!MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n)) {
    free(w);
    return NULL;
  }
  return w;
}

static void retarget_mmap_nodes(TextBuffer *buf, PieceNode *node, size_t heap_base) {
  if (!node || node == buf->nil_node) return;
  retarget_mmap_nodes(buf, node->left, heap_base);
  retarget_mmap_nodes(buf, node->right, heap_base);
  if (node->source == BUFFER_SRC_MMAP) {
    node->source = BUFFER_SRC_HEAP;
    node->offset += heap_base;
  }
}
#endif

static void buffer_release_mmap(TextBuffer *buf) {
  if (buf->mmap_data) {
#ifdef _WIN32
    UnmapViewOfFile(buf->mmap_data);
#else
    munmap((void *)buf->mmap_data, buf->mmap_size);
#endif
    buf->mmap_data = NULL;
    buf->mmap_size = 0;
  }
  if (buf->fd >= 0) {
#ifdef _WIN32
    CloseHandle((HANDLE)(intptr_t)buf->fd);
#else
    close(buf->fd);
#endif
    buf->fd = -1;
  }
}

#ifdef _WIN32
/* Copy the mapped file into the heap, point all mmap pieces at the copy and
 * release the mapping (Windows cannot replace a file that is still mapped). */
static bool buffer_materialize_mmap(TextBuffer *buf) {
  if (!buf->mmap_data) return true;
  size_t base = 0;
  if (!append_to_heap(buf, buf->mmap_data, buf->mmap_size, &base)) return false;
  retarget_mmap_nodes(buf, buf->root, base);
  buffer_release_mmap(buf);
  return true;
}
#endif

static void buffer_free_remote(TextBuffer *buf) {
  for (size_t i = 0; i < buf->nchunks; i++) free(buf->chunks[i].data);
  free(buf->chunks);
  free(buf->queue);
  buf->chunks = NULL;
  buf->queue = NULL;
  buf->nchunks = buf->qhead = buf->qlen = buf->qcap = 0;
  buf->resident_bytes = buf->pinned_bytes = 0;
  buf->lru_head = buf->lru_tail = CHUNK_NONE;
}

/* Releases everything the buffer owns except the TextBuffer struct itself. */
static void buffer_free_contents(TextBuffer *buf) {
  free_tree(buf, buf->root);
  free(buf->nil_node);
  buffer_release_mmap(buf);
  if (buf->heap_data) {
    free(buf->heap_data);
  }
  buffer_free_remote(buf);
}

static void buffer_destroy(TextBuffer *buf) {
  if (!buf) return;
  if (line_cache.buf == buf) line_cache.buf = NULL;
  buffer_free_contents(buf);
  free(buf);
}

/* Turns an empty buffer into an all-REMOTE tree built from a server-supplied
 * chunk table; no file data is read. Takes ownership of chunks on success (on
 * failure the caller still owns it). ends_with_nl follows buffer_from_file:
 * a non-empty file lacking a final '\n' gets a virtual one as a heap piece and
 * an empty file becomes a single "\n". */
static bool remote_setup(TextBuffer *buf, RemoteChunk *chunks, size_t n, size_t size, size_t total_lf, bool ends_with_nl) {
  PieceNode **nodes = NULL;
  if (n > 0) {
    nodes = (PieceNode **)malloc(sizeof(PieceNode *) * n);
    if (!nodes) return false;
    for (size_t i = 0; i < n; i++) {
      nodes[i] = node_new(buf, BUFFER_SRC_REMOTE, chunks[i].orig_off, chunks[i].len, chunks[i].lf);
      if (!nodes[i]) {
        for (size_t j = 0; j < i; j++) free(nodes[j]);
        free(nodes);
        return false;
      }
    }
    buf->root = build_tree_from_array(buf, nodes, 0, (int)n - 1);
    free(nodes);
  }
  buf->chunks = chunks;
  buf->nchunks = n;
  buf->remote = true;
  buf->virtual_nl = size > 0 && !ends_with_nl;
  buf->total_size = size;
  buf->total_lines = total_lf;
  bool ok = true;
  if (size == 0) {
    ok = buffer_insert_raw(buf, 0, "\n", 1);
    buf->total_lines = 1;
  } else if (!ends_with_nl) {
    ok = buffer_insert_raw(buf, buf->total_size, "\n", 1);
  }
  if (!ok) {
    buf->chunks = NULL; /* ownership stays with the caller on failure */
    buf->nchunks = 0;
  }
  return ok;
}

static TextBuffer *buffer_from_file(const char *path) {
  TextBuffer *buf = buffer_create();
  if (!buf) return NULL;

#ifdef _WIN32
  wchar_t *wpath = utf8_to_wide(path);
  if (!wpath) {
    buffer_destroy(buf);
    return NULL;
  }
  HANDLE hFile = CreateFileW(wpath, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                             NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
  free(wpath);
  if (hFile == INVALID_HANDLE_VALUE) {
    buffer_destroy(buf);
    return NULL;
  }
  LARGE_INTEGER sz;
  if (!GetFileSizeEx(hFile, &sz)) {
    CloseHandle(hFile);
    buffer_destroy(buf);
    return NULL;
  }
  if (sz.QuadPart == 0) {
    CloseHandle(hFile);
    if (!buffer_insert_raw(buf, 0, "\n", 1)) {
      buffer_destroy(buf);
      return NULL;
    }
    buf->total_lines = 1;
    return buf;
  }
  HANDLE hMap = CreateFileMappingW(hFile, NULL, PAGE_READONLY, 0, 0, NULL);
  if (!hMap) {
    CloseHandle(hFile);
    buffer_destroy(buf);
    return NULL;
  }
  const char *view = (const char *)MapViewOfFile(hMap, FILE_MAP_READ, 0, 0, 0);
  CloseHandle(hMap);
  if (!view) {
    CloseHandle(hFile);
    buffer_destroy(buf);
    return NULL;
  }
  buf->mmap_data = view;
  buf->mmap_size = (size_t)sz.QuadPart;
  buf->fd = (int)(intptr_t)hFile;
#else
  int fd = open(path, O_RDONLY);
  if (fd < 0) {
    buffer_destroy(buf);
    return NULL;
  }
  struct stat st;
  if (fstat(fd, &st) < 0) {
    close(fd);
    buffer_destroy(buf);
    return NULL;
  }
  if (st.st_size == 0) {
    close(fd);
    if (!buffer_insert_raw(buf, 0, "\n", 1)) {
      buffer_destroy(buf);
      return NULL;
    }
    buf->total_lines = 1;
    return buf;
  }
  buf->mmap_data = (const char *)mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
  if (buf->mmap_data == MAP_FAILED) {
    buf->mmap_data = NULL;
    close(fd);
    buffer_destroy(buf);
    return NULL;
  }
  buf->mmap_size = (size_t)st.st_size;
  buf->fd = fd;
#endif

  buf->total_size = buf->mmap_size;

  /* Split into chunks of CHUNK_SIZE and build initial balanced tree */
  size_t num_chunks = (buf->mmap_size + CHUNK_SIZE - 1) / CHUNK_SIZE;
  if (num_chunks == 0) num_chunks = 1;
  PieceNode **nodes = (PieceNode **)malloc(sizeof(PieceNode *) * num_chunks);
  if (!nodes) {
    buffer_destroy(buf);
    return NULL;
  }

  size_t offset = 0;
  size_t total_lfc = 0;
  for (size_t i = 0; i < num_chunks; i++) {
    size_t len = buf->mmap_size - offset;
    if (len > CHUNK_SIZE) len = CHUNK_SIZE;
    size_t lfc = count_newlines(buf->mmap_data + offset, len);
    total_lfc += lfc;
    nodes[i] = node_new(buf, BUFFER_SRC_MMAP, offset, len, lfc);
    if (!nodes[i]) {
      for (size_t j = 0; j < i; j++) free(nodes[j]);
      free(nodes);
      buffer_destroy(buf); /* root is still nil: nothing else to free */
      return NULL;
    }
    offset += len;
  }

  buf->root = build_tree_from_array(buf, nodes, 0, (int)num_chunks - 1);
  free(nodes);
  buf->total_lines = total_lfc;
  if (buf->mmap_data[buf->mmap_size - 1] != '\n') {
    if (!buffer_insert_raw(buf, buf->total_size, "\n", 1)) {
      buffer_destroy(buf);
      return NULL;
    }
  }
  return buf;
}

/* ========================================================================= */
/* Lua Metamethods & Bindings                                                */
/* ========================================================================= */

static int f_buffer_open(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  TextBuffer *buf = buffer_from_file(path);
  if (!buf) {
    return luaL_error(L, "failed to open and map file '%s'", path);
  }
  TextBuffer **ud = (TextBuffer **)lua_newuserdata(L, sizeof(TextBuffer *));
  *ud = buf;
  luaL_setmetatable(L, API_TYPE_BUFFER);
  return 1;
}

static int f_buffer_new(lua_State *L) {
  TextBuffer *buf = buffer_create();
  if (!buf) return luaL_error(L, "out of memory");
  if (!buffer_insert_raw(buf, 0, "\n", 1)) {
    buffer_destroy(buf);
    return luaL_error(L, "out of memory");
  }
  buf->total_lines = 1;
  TextBuffer **ud = (TextBuffer **)lua_newuserdata(L, sizeof(TextBuffer *));
  *ud = buf;
  luaL_setmetatable(L, API_TYPE_BUFFER);
  return 1;
}

static TextBuffer *check_buffer(lua_State *L, int idx) {
  TextBuffer **ud = (TextBuffer **)luaL_checkudata(L, idx, API_TYPE_BUFFER);
  TextBuffer *buf = *ud;
  /* Heal transient state left behind if a previous call was aborted by a Lua
   * error (e.g. out of memory) while a sync_fn or probe was active. */
  buf->sync_L = NULL;
  buf->no_enqueue = false;
  buf->record_touch = false;
  buf->err = ERR_NONE;
  return buf;
}

/* True when every remote chunk backing bytes [off, off+len) is readable now.
 * Missing chunks are all queued (unless probing) so one pass requests them all. */
static bool buffer_range_ready(TextBuffer *buf, size_t off, size_t len) {
  if (!buf->remote) return true;
  bool ok = true;
  size_t end = off + len;
  if (end > buf->total_size) end = buf->total_size;
  while (off < end) {
    size_t piece_off = 0;
    PieceNode *p = find_piece_by_offset(buf, off, &piece_off);
    if (!p || piece_off >= p->length) break;
    if (p->source == BUFFER_SRC_REMOTE) {
      size_t coff = 0;
      uint32_t idx = piece_chunk(buf, p, &coff);
      if (idx == CHUNK_NONE) buf_set_err(buf, ERR_NOT_LOADED);
      if (idx == CHUNK_NONE || !chunk_data(buf, idx)) {
        ok = false;
        if (buf->err == ERR_SYNC || buf->err == ERR_STALE) return false;
      }
    }
    off += p->length - piece_off;
  }
  return ok;
}

/* Holds the chunks recorded in buf->touched and every remote chunk backing
 * bytes [off, end), resident or not. Reads nothing and queues nothing. */
static void hold_chunks(TextBuffer *buf, size_t off, size_t end) {
  for (size_t i = 0; i < buf->ntouched; i++) buf->chunks[buf->touched[i]].hold = buf->round;
  buf->ntouched = 0;
  if (end > buf->total_size) end = buf->total_size;
  while (off < end) {
    size_t piece_off = 0;
    PieceNode *p = find_piece_by_offset(buf, off, &piece_off);
    if (!p || piece_off >= p->length) break;
    if (p->source == BUFFER_SRC_REMOTE) {
      size_t coff = 0;
      uint32_t idx = piece_chunk(buf, p, &coff);
      if (idx != CHUNK_NONE) buf->chunks[idx].hold = buf->round;
    }
    off += p->length - piece_off;
  }
}

static int push_failure(lua_State *L, const TextBuffer *buf) {
  lua_pushboolean(L, 0);
  lua_pushstring(L, buf_err_string(buf));
  return 2;
}

static int mm_len(lua_State *L) {
  TextBuffer *buf = check_buffer(L, 1);
  lua_pushinteger(L, (lua_Integer)buf->total_lines);
  return 1;
}

/* buf[i] for a line that cannot be read right now (chunks not resident or the
 * buffer is stale) yields this string; it always ends in "\n" like any line. */
static int mm_index(lua_State *L) {
  TextBuffer *buf = check_buffer(L, 1);
  if (lua_isinteger(L, 2)) {
    lua_Integer lineno = lua_tointeger(L, 2);
    if (lineno < 1 || (size_t)lineno > buf->total_lines) {
      lua_pushnil(L);
      return 1;
    }
    size_t start_off = 0, end_off = 0;
    /* Look up both ends even if the first fails so every chunk is queued. */
    buf->ntouched = 0;
    buf->record_touch = buf->remote;
    bool found = find_offset_by_lineno(buf, (size_t)lineno, &start_off);
    found = find_offset_by_lineno(buf, (size_t)lineno + 1, &end_off) && found;
    buf->record_touch = false;
    bool ok = found;
    if (ok) {
      if (end_off < start_off) end_off = start_off;
      ok = buffer_range_ready(buf, start_off, end_off - start_off);
    }
    if (!ok) {
      /* Keep what this line needs (including the chunk with the newline before
       * it) until it can be shown, whatever the budget. */
      if (buf->remote && !buf->stale)
        hold_chunks(buf, found && start_off > 0 ? start_off - 1 : 0, found ? end_off : 0);
      lua_pushlstring(L, PLACEHOLDER_LINE, PLACEHOLDER_LEN);
      return 1;
    }
    size_t line_len = end_off - start_off;

    /* Extract line string */
    luaL_Buffer b;
    luaL_buffinit(L, &b);
    size_t rem = line_len;
    size_t curr_off = start_off;
    bool read_ok = true;
    while (rem > 0 && curr_off < buf->total_size) {
      size_t piece_off = 0;
      PieceNode *p = find_piece_by_offset(buf, curr_off, &piece_off);
      if (!p || piece_off >= p->length) break;
      const char *data = NULL;
      size_t avail = 0;
      if (!piece_read(buf, p, piece_off, &data, &avail)) {
        read_ok = false;
        break;
      }
      size_t chunk = rem < avail ? rem : avail;
      if (chunk == 0) break;
      luaL_addlstring(&b, data, chunk);
      rem -= chunk;
      curr_off += chunk;
    }
    luaL_pushresult(&b);
    if (!read_ok) {
      lua_pop(L, 1);
      lua_pushlstring(L, PLACEHOLDER_LINE, PLACEHOLDER_LEN);
    }
    return 1;
  }

  /* Method lookup */
  const char *key = luaL_checkstring(L, 2);
  if (strcmp(key, "lines") == 0) {
    lua_pushvalue(L, 1); /* Return buffer itself as lines table */
    return 1;
  }
  luaL_getmetatable(L, API_TYPE_BUFFER);
  lua_getfield(L, -1, key);
  return 1;
}

static void sync_leave(TextBuffer *buf) {
  buf->sync_L = NULL;
  evict_to_budget(buf, CHUNK_NONE);
}

static int f_buffer_get_text(lua_State *L) {
  TextBuffer *buf = check_buffer(L, 1);
  size_t line1 = (size_t)luaL_checkinteger(L, 2);
  size_t col1 = (size_t)luaL_checkinteger(L, 3);
  size_t line2 = (size_t)luaL_checkinteger(L, 4);
  size_t col2 = (size_t)luaL_checkinteger(L, 5);
  /* Optional sync_fn(idx, orig_off, len) -> data fetches non-resident chunks
   * on the spot (explicit user actions only). Without it unloaded text fails
   * with nil, "not loaded". */
  if (buf->remote && lua_isfunction(L, 6)) {
    buf->sync_L = L;
    buf->sync_fn = 6;
  }

  size_t off1 = 0, off2 = 0;
  buf->ntouched = 0;
  buf->record_touch = buf->sync_L != NULL;
  bool ok = find_offset_by_lineno(buf, line1, &off1);
  ok = find_offset_by_lineno(buf, line2, &off2) && ok;
  buf->record_touch = false;
  if (ok) {
    off1 += (col1 > 0 ? col1 - 1 : 0);
    off2 += (col2 > 0 ? col2 - 1 : 0);
    if (off1 > off2) { size_t tmp = off1; off1 = off2; off2 = tmp; }
    if (off2 > buf->total_size) off2 = buf->total_size;
    ok = buffer_range_ready(buf, off1, off2 - off1);
  }
  if (!ok) {
    sync_leave(buf);
    lua_pushnil(L);
    lua_pushstring(L, buf_err_string(buf));
    return 2;
  }

  luaL_Buffer b;
  luaL_buffinit(L, &b);
  size_t rem = off2 - off1;
  size_t curr_off = off1;
  bool read_ok = true;
  while (rem > 0 && curr_off < buf->total_size) {
    size_t piece_off = 0;
    PieceNode *p = find_piece_by_offset(buf, curr_off, &piece_off);
    if (!p || piece_off >= p->length) break;
    const char *data = NULL;
    size_t avail = 0;
    if (!piece_read(buf, p, piece_off, &data, &avail)) {
      read_ok = false;
      break;
    }
    size_t chunk = rem < avail ? rem : avail;
    if (chunk == 0) break;
    luaL_addlstring(&b, data, chunk);
    rem -= chunk;
    curr_off += chunk;
  }
  luaL_pushresult(&b);
  if (buf->sync_L && read_ok) {
    /* An explicit read is usually followed by an edit of the same range (a
     * remove saves its text for undo first): keep the chunks that edit needs,
     * i.e. those locating both lines and those at both ends of the range. */
    hold_chunks(buf, off1, off1 < off2 ? off1 + 1 : off1);
    if (off1 < off2) hold_chunks(buf, off2 - 1, off2);
  }
  sync_leave(buf);
  if (!read_ok) {
    lua_pop(L, 1);
    lua_pushnil(L);
    lua_pushstring(L, buf_err_string(buf));
    return 2;
  }
  return 1;
}

static int f_buffer_insert(lua_State *L) {
  TextBuffer *buf = check_buffer(L, 1);
  size_t line = (size_t)luaL_checkinteger(L, 2);
  size_t col = (size_t)luaL_checkinteger(L, 3);
  size_t len = 0;
  const char *text = luaL_checklstring(L, 4, &len);

  if (buf->remote && buf->stale) {
    buf->err = ERR_STALE;
    return push_failure(L, buf);
  }
  size_t off = 0;
  if (!find_offset_by_lineno(buf, line, &off)) return push_failure(L, buf);
  off += (col > 0 ? col - 1 : 0);
  if (off > buf->total_size) off = buf->total_size;

  if (!buffer_insert_raw(buf, off, text, len)) return push_failure(L, buf);
  lua_pushboolean(L, 1);
  return 1;
}

static int f_buffer_remove(lua_State *L) {
  TextBuffer *buf = check_buffer(L, 1);
  size_t line1 = (size_t)luaL_checkinteger(L, 2);
  size_t col1 = (size_t)luaL_checkinteger(L, 3);
  size_t line2 = (size_t)luaL_checkinteger(L, 4);
  size_t col2 = (size_t)luaL_checkinteger(L, 5);

  if (buf->remote && buf->stale) {
    buf->err = ERR_STALE;
    return push_failure(L, buf);
  }
  size_t off1 = 0, off2 = 0;
  bool found = find_offset_by_lineno(buf, line1, &off1);
  found = find_offset_by_lineno(buf, line2, &off2) && found;
  if (!found) return push_failure(L, buf);
  off1 += (col1 > 0 ? col1 - 1 : 0);
  off2 += (col2 > 0 ? col2 - 1 : 0);
  if (off1 > off2) { size_t tmp = off1; off1 = off2; off2 = tmp; }
  if (off2 > buf->total_size) off2 = buf->total_size;

  if (!buffer_remove_raw(buf, off1, off2 - off1)) return push_failure(L, buf);
  lua_pushboolean(L, 1);
  return 1;
}

#ifdef _WIN32
typedef HANDLE SaveSink;
static bool sink_write(SaveSink h, const char *d, size_t n) {
  while (n > 0) {
    DWORD c = n > (1u << 30) ? (1u << 30) : (DWORD)n, w = 0;
    if (!WriteFile(h, d, c, &w, NULL) || w == 0) return false;
    d += w;
    n -= w;
  }
  return true;
}
#else
typedef FILE *SaveSink;
static bool sink_write(SaveSink fp, const char *d, size_t n) {
  return fwrite(d, 1, n, fp) == n;
}
#endif

/* Writes the whole document to sink; false on write error or inconsistent tree. */
static bool write_pieces(TextBuffer *buf, SaveSink sink) {
  size_t curr_off = 0;
  while (curr_off < buf->total_size) {
    size_t piece_off = 0;
    PieceNode *p = find_piece_by_offset(buf, curr_off, &piece_off);
    if (!p || piece_off >= p->length) break;
    const char *data = NULL;
    size_t chunk = 0;
    if (!piece_read(buf, p, piece_off, &data, &chunk)) return false;
    if (!sink_write(sink, data, chunk)) return false;
    curr_off += chunk;
  }
  return curr_off == buf->total_size;
}

static int f_buffer_save(lua_State *L) {
  TextBuffer *buf = check_buffer(L, 1);
  const char *path = luaL_checkstring(L, 2);
  if (buf->remote)
    return luaL_error(L, "remote buffers cannot be saved to a path, use edit_script()");

  char tmp_path[4096];
  int n;
#ifdef _WIN32
  n = snprintf(tmp_path, sizeof(tmp_path), "%s.tmp.%lu", path, (unsigned long)GetCurrentProcessId());
#else
  n = snprintf(tmp_path, sizeof(tmp_path), "%s.tmp.%ld", path, (long)getpid());
#endif
  if (n < 0 || (size_t)n >= sizeof(tmp_path))
    return luaL_error(L, "path too long '%s'", path);

  /* Always write to a temp file and replace the original afterwards: pieces
   * may still be read from the original file's mapping, so it must never be
   * truncated in place. */
#ifdef _WIN32
  wchar_t *wpath = utf8_to_wide(path);
  wchar_t *wtmp = utf8_to_wide(tmp_path);
  if (!wpath || !wtmp) {
    free(wpath);
    free(wtmp);
    return luaL_error(L, "invalid path '%s'", path);
  }
  HANDLE h = CreateFileW(wtmp, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  if (h == INVALID_HANDLE_VALUE) {
    free(wpath);
    free(wtmp);
    return luaL_error(L, "could not open file '%s' for writing", path);
  }
  bool ok = write_pieces(buf, h);
  if (ok && !FlushFileBuffers(h)) ok = false;
  if (!CloseHandle(h)) ok = false;
  if (!ok) {
    DeleteFileW(wtmp);
    free(wpath);
    free(wtmp);
    return luaL_error(L, "error writing to '%s'", path);
  }

  DWORD mv_flags = MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH;
  bool moved = MoveFileExW(wtmp, wpath, mv_flags) != 0;
  if (!moved && buf->mmap_data) {
    /* The target may be the file we have mapped, which Windows will not
     * replace. Copy the mapping into memory, unmap it and retry. */
    if (buffer_materialize_mmap(buf))
      moved = MoveFileExW(wtmp, wpath, mv_flags) != 0;
  }
  if (!moved) {
    DeleteFileW(wtmp);
    free(wpath);
    free(wtmp);
    return luaL_error(L, "could not replace file '%s'", path);
  }
  free(wpath);
  free(wtmp);
#else
  FILE *fp = fopen(tmp_path, "wb");
  if (!fp) return luaL_error(L, "could not open file '%s' for writing", path);

  bool ok = write_pieces(buf, fp);
  if (ok && fflush(fp) != 0) ok = false;
  if (ok && fsync(fileno(fp)) != 0) ok = false;
  if (fclose(fp) != 0) ok = false;
  if (!ok) {
    remove(tmp_path);
    return luaL_error(L, "error writing to '%s'", path);
  }
  if (rename(tmp_path, path) != 0) {
    remove(tmp_path);
    return luaL_error(L, "could not rename temp file to '%s'", path);
  }
#endif

  lua_pushboolean(L, 1);
  return 1;
}

/* ========================================================================= */
/* Remote buffer API                                                         */
/* ========================================================================= */

/* Reads a chunk table: {{len, lf}, ...} or flat {len1, lf1, len2, lf2, ...}.
 * Uses only non-throwing Lua calls so the allocation below cannot leak.
 * Returns NULL on success (caller owns *out) or an error message. */
static const char *parse_chunks(lua_State *L, int tidx, size_t size, size_t limit,
                                RemoteChunk **out, size_t *out_n, size_t *out_lf) {
  *out = NULL;
  *out_n = 0;
  *out_lf = 0;
  size_t cnt = (size_t)lua_rawlen(L, tidx);
  bool flat = false;
  if (cnt > 0) {
    lua_rawgeti(L, tidx, 1);
    flat = lua_type(L, -1) == LUA_TNUMBER;
    lua_pop(L, 1);
  }
  if (flat && (cnt & 1)) return "flat chunk table must hold len,lf pairs";
  size_t n = flat ? cnt / 2 : cnt;
  if (n >= CHUNK_NONE || n >= (size_t)INT32_MAX) return "too many chunks";
  if (n == 0) return size == 0 ? NULL : "empty chunk table for a non-empty file";
  if (size == 0) return "chunks given for an empty file";
  RemoteChunk *ch = (RemoteChunk *)calloc(n, sizeof(RemoteChunk));
  if (!ch) return "out of memory";
  size_t sum = 0, lf_sum = 0;
  const char *err = NULL;
  for (size_t i = 0; i < n && !err; i++) {
    lua_Integer len = 0, lf = 0;
    int ok1 = 0, ok2 = 0;
    if (flat) {
      lua_rawgeti(L, tidx, (lua_Integer)(2 * i + 1));
      lua_rawgeti(L, tidx, (lua_Integer)(2 * i + 2));
      len = lua_tointegerx(L, -2, &ok1);
      lf = lua_tointegerx(L, -1, &ok2);
      lua_pop(L, 2);
    } else {
      lua_rawgeti(L, tidx, (lua_Integer)(i + 1));
      if (lua_type(L, -1) != LUA_TTABLE) {
        lua_pop(L, 1);
        err = "chunk entry must be {len, lf}";
        break;
      }
      lua_rawgeti(L, -1, 1);
      lua_rawgeti(L, -2, 2);
      len = lua_tointegerx(L, -2, &ok1);
      lf = lua_tointegerx(L, -1, &ok2);
      lua_pop(L, 3);
    }
    if (!ok1 || !ok2) err = "chunk len/lf must be integers";
    else if (len <= 0 || (uint64_t)len > UINT32_MAX) err = "chunk length out of range";
    else if (limit && (size_t)len > limit) err = "chunk longer than chunk_size";
    else if (lf < 0 || lf > len) err = "chunk lf out of range";
    else if ((size_t)len > size - sum) err = "chunks are larger than size";
    else {
      ch[i].orig_off = sum;
      ch[i].len = (uint32_t)len;
      ch[i].lf = (uint32_t)lf;
      ch[i].prev = ch[i].next = CHUNK_NONE;
      sum += (size_t)len;
      lf_sum += (size_t)lf;
    }
  }
  if (!err && sum != size) err = "chunk lengths do not add up to size";
  if (err) {
    free(ch);
    return err;
  }
  *out = ch;
  *out_n = n;
  *out_lf = lf_sum;
  return NULL;
}

/* buffer.open_remote{size=N, chunks={{len,lf},...}, ends_with_nl=bool,
 *                    chunk_size=65536 [, budget=bytes]} -> buf */
static int f_buffer_open_remote(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  lua_getfield(L, 1, "size");
  lua_Integer size = luaL_checkinteger(L, -1);
  lua_getfield(L, 1, "chunks");
  luaL_checktype(L, -1, LUA_TTABLE);
  int chunks_idx = lua_gettop(L);
  lua_getfield(L, 1, "ends_with_nl");
  /* required: guessing would hide or invent the last line */
  if (!lua_isboolean(L, -1)) return luaL_error(L, "open_remote: ends_with_nl must be a boolean");
  bool ends_with_nl = lua_toboolean(L, -1);
  lua_getfield(L, 1, "chunk_size");
  lua_Integer chunk_size = lua_isnil(L, -1) ? 0 : luaL_checkinteger(L, -1);
  lua_getfield(L, 1, "budget");
  lua_Integer budget = lua_isnil(L, -1) ? -1 : luaL_checkinteger(L, -1);
  if (size < 0) return luaL_error(L, "open_remote: negative size");
  if (chunk_size < 0) return luaL_error(L, "open_remote: negative chunk_size");

  TextBuffer **ud = (TextBuffer **)lua_newuserdata(L, sizeof(TextBuffer *));
  *ud = NULL;
  luaL_setmetatable(L, API_TYPE_BUFFER);
  TextBuffer *buf = buffer_create();
  if (!buf) return luaL_error(L, "out of memory");
  *ud = buf; /* owned by the userdata (freed by __gc) from here on */
  buf->chunk_size_limit = (size_t)chunk_size;
  if (budget >= 0) buf->budget = (size_t)budget;

  RemoteChunk *chunks = NULL;
  size_t n = 0, lf = 0;
  const char *err = parse_chunks(L, chunks_idx, (size_t)size, buf->chunk_size_limit, &chunks, &n, &lf);
  if (err) return luaL_error(L, "open_remote: %s", err);
  if (!remote_setup(buf, chunks, n, (size_t)size, lf, ends_with_nl)) {
    free(chunks);
    return luaL_error(L, "out of memory");
  }
  return 1;
}

static int f_buffer_is_remote(lua_State *L) {
  TextBuffer *buf = check_buffer(L, 1);
  lua_pushboolean(L, buf->remote);
  return 1;
}

/* buf:missing([max]) -> { {idx, orig_off, len}, ... } (idx is 1-based).
 * Drains the request queue; drained chunks stay pending until supplied or
 * cancelled, so they are never requested twice. */
static int f_buffer_missing(lua_State *L) {
  TextBuffer *buf = check_buffer(L, 1);
  lua_Integer max = luaL_optinteger(L, 2, 256);
  if (max <= 0) max = 256;
  lua_newtable(L);
  if (!buf->remote) return 1;
  if (++buf->round == 0) buf->round = 1; /* 0 means "not held" */
  lua_Integer count = 0;
  while (buf->qhead < buf->qlen && count < max) {
    uint32_t idx = buf->queue[buf->qhead++];
    RemoteChunk *c = &buf->chunks[idx];
    c->queued = 0;
    if (c->state != CHUNK_PENDING) continue;
    lua_createtable(L, 3, 0);
    lua_pushinteger(L, (lua_Integer)idx + 1);
    lua_rawseti(L, -2, 1);
    lua_pushinteger(L, (lua_Integer)c->orig_off);
    lua_rawseti(L, -2, 2);
    lua_pushinteger(L, (lua_Integer)c->len);
    lua_rawseti(L, -2, 3);
    lua_rawseti(L, -2, ++count);
  }
  if (buf->qhead == buf->qlen) buf->qhead = buf->qlen = 0;
  return 1;
}

/* Checks a 1-based chunk index argument; returns CHUNK_NONE if out of range. */
static uint32_t check_chunk_arg(lua_State *L, TextBuffer *buf, int arg) {
  lua_Integer i = luaL_checkinteger(L, arg);
  if (!buf->remote || i < 1 || (uint64_t)i > buf->nchunks) return CHUNK_NONE;
  return (uint32_t)(i - 1);
}

/* buf:supply(idx, data) -> true | false, err */
static int f_buffer_supply(lua_State *L) {
  TextBuffer *buf = check_buffer(L, 1);
  uint32_t idx = check_chunk_arg(L, buf, 2);
  size_t len = 0;
  const char *data = luaL_checklstring(L, 3, &len);
  if (!buf->remote) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, "not a remote buffer");
    return 2;
  }
  if (buf->stale) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, "stale");
    return 2;
  }
  if (idx == CHUNK_NONE) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, "bad chunk index");
    return 2;
  }
  const char *err = NULL;
  if (!chunk_supply(buf, idx, data, len, &err)) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, err);
    return 2;
  }
  lua_pushboolean(L, 1);
  return 1;
}

/* buf:cancel(idx): a failed fetch gives up its pending state so the chunk can
 * be requested again later. */
static int f_buffer_cancel(lua_State *L) {
  TextBuffer *buf = check_buffer(L, 1);
  uint32_t idx = check_chunk_arg(L, buf, 2);
  if (idx != CHUNK_NONE && buf->chunks[idx].state == CHUNK_PENDING)
    buf->chunks[idx].state = CHUNK_MISSING;
  lua_pushboolean(L, idx != CHUNK_NONE);
  return 1;
}

/* buf:evict(idx) -> true | false, "pinned" | "bad chunk index" */
static int f_buffer_evict(lua_State *L) {
  TextBuffer *buf = check_buffer(L, 1);
  uint32_t idx = check_chunk_arg(L, buf, 2);
  if (idx == CHUNK_NONE) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, "bad chunk index");
    return 2;
  }
  if (buf->chunks[idx].state == CHUNK_RESIDENT) {
    if (buf->chunks[idx].pins) {
      lua_pushboolean(L, 0);
      lua_pushstring(L, "pinned");
      return 2;
    }
    chunk_evict(buf, idx);
  }
  lua_pushboolean(L, 1);
  return 1;
}

/* buf:pin(idx, bool): explicit pin (independent of the automatic edit pins). */
static int f_buffer_pin(lua_State *L) {
  TextBuffer *buf = check_buffer(L, 1);
  uint32_t idx = check_chunk_arg(L, buf, 2);
  bool on = lua_toboolean(L, 3);
  if (idx == CHUNK_NONE) {
    lua_pushboolean(L, 0);
    return 1;
  }
  if (on) chunk_set_pins(buf, idx, buf->chunks[idx].pins | PIN_USER);
  else chunk_set_pins(buf, idx, buf->chunks[idx].pins & (uint8_t)~PIN_USER);
  lua_pushboolean(L, 1);
  return 1;
}

static int f_buffer_set_budget(lua_State *L) {
  TextBuffer *buf = check_buffer(L, 1);
  lua_Integer n = luaL_checkinteger(L, 2);
  buf->budget = n < 0 ? 0 : (size_t)n;
  evict_to_budget(buf, CHUNK_NONE);
  return 0;
}

/* buf:is_resident(line1 [, line2]) -> bool: can those lines be read right now
 * without any fetch? Never queues anything. */
static int f_buffer_is_resident(lua_State *L) {
  TextBuffer *buf = check_buffer(L, 1);
  lua_Integer l1 = luaL_checkinteger(L, 2);
  lua_Integer l2 = luaL_optinteger(L, 3, l1);
  if (l1 < 1) l1 = 1;
  if (l2 > (lua_Integer)buf->total_lines) l2 = (lua_Integer)buf->total_lines;
  if (!buf->remote) {
    lua_pushboolean(L, 1);
    return 1;
  }
  if (buf->stale || l2 < l1) {
    lua_pushboolean(L, 0);
    return 1;
  }
  buf->no_enqueue = true;
  size_t start = 0, end = 0;
  bool ok = find_offset_by_lineno(buf, (size_t)l1, &start) &&
            find_offset_by_lineno(buf, (size_t)l2 + 1, &end);
  if (ok) ok = buffer_range_ready(buf, start, end > start ? end - start : 0);
  buf->no_enqueue = false;
  lua_pushboolean(L, ok);
  return 1;
}

/* buf:set_stale(bool): while stale, remote reads give placeholders, edits
 * fail with "stale" and nothing is queued. Setting it drops pending requests. */
static int f_buffer_set_stale(lua_State *L) {
  TextBuffer *buf = check_buffer(L, 1);
  bool stale = lua_toboolean(L, 2);
  if (buf->remote && stale) queue_reset(buf);
  buf->stale = buf->remote && stale;
  return 0;
}

static int f_buffer_stats(lua_State *L) {
  TextBuffer *buf = check_buffer(L, 1);
  size_t resident = 0, pending = 0, pinned = 0, held_bytes = 0;
  for (size_t i = 0; i < buf->nchunks; i++) {
    const RemoteChunk *c = &buf->chunks[i];
    if (c->state == CHUNK_RESIDENT) resident++;
    if (c->state == CHUNK_PENDING) pending++;
    if (c->pins) pinned++;
    if (c->state == CHUNK_RESIDENT && !c->pins && chunk_held(buf, c)) held_bytes += c->len;
  }
  lua_createtable(L, 0, 10);
  lua_pushinteger(L, (lua_Integer)held_bytes);
  lua_setfield(L, -2, "held_bytes");
  lua_pushinteger(L, (lua_Integer)buf->nchunks);
  lua_setfield(L, -2, "chunks");
  lua_pushinteger(L, (lua_Integer)resident);
  lua_setfield(L, -2, "resident");
  lua_pushinteger(L, (lua_Integer)pending);
  lua_setfield(L, -2, "pending");
  lua_pushinteger(L, (lua_Integer)pinned);
  lua_setfield(L, -2, "pinned");
  lua_pushinteger(L, (lua_Integer)buf->resident_bytes);
  lua_setfield(L, -2, "resident_bytes");
  lua_pushinteger(L, (lua_Integer)buf->pinned_bytes);
  lua_setfield(L, -2, "pinned_bytes");
  lua_pushinteger(L, (lua_Integer)buf->budget);
  lua_setfield(L, -2, "budget");
  lua_pushinteger(L, (lua_Integer)(buf->qlen - buf->qhead));
  lua_setfield(L, -2, "queued");
  lua_pushinteger(L, (lua_Integer)buf->total_size);
  lua_setfield(L, -2, "size");
  return 1;
}

/* buf:loaded_chunks() -> { idx, ... }: every chunk loaded at least once since
 * open/rebase (resident or evicted since); these are the ones that can be
 * compared against another version of the file with chunk_matches. */
static int f_buffer_loaded_chunks(lua_State *L) {
  TextBuffer *buf = check_buffer(L, 1);
  lua_newtable(L);
  lua_Integer n = 0;
  for (size_t i = 0; i < buf->nchunks; i++) {
    if (!buf->chunks[i].hashed) continue;
    lua_pushinteger(L, (lua_Integer)i + 1);
    lua_rawseti(L, -2, ++n);
  }
  return 1;
}

/* buf:chunk_matches(idx, data) -> bool | nil: whether data equals the bytes
 * this buffer loaded for chunk idx (nil if it never loaded them). Compares the
 * bytes when resident, else a 64-bit fingerprint. */
static int f_buffer_chunk_matches(lua_State *L) {
  TextBuffer *buf = check_buffer(L, 1);
  uint32_t idx = check_chunk_arg(L, buf, 2);
  size_t len = 0;
  const char *data = luaL_checklstring(L, 3, &len);
  if (idx == CHUNK_NONE || !buf->chunks[idx].hashed) {
    lua_pushnil(L);
    return 1;
  }
  const RemoteChunk *c = &buf->chunks[idx];
  bool same = len == c->len;
  if (same && c->state == CHUNK_RESIDENT) same = memcmp(c->data, data, len) == 0;
  else if (same) same = hash_bytes(data, len) == c->hash;
  lua_pushboolean(L, same);
  return 1;
}

/* Appends {keep=true, off=off, len=len} as element idx of the script table at stack index 2. */
static void push_keep(lua_State *L, lua_Integer idx, size_t off, size_t len) {
  lua_createtable(L, 0, 3);
  lua_pushboolean(L, 1);
  lua_setfield(L, -2, "keep");
  lua_pushinteger(L, (lua_Integer)off);
  lua_setfield(L, -2, "off");
  lua_pushinteger(L, (lua_Integer)len);
  lua_setfield(L, -2, "len");
  lua_rawseti(L, 2, idx);
}

static PieceNode *node_first(TextBuffer *buf) {
  PieceNode *n = buf->root;
  if (n != buf->nil_node) {
    while (n->left != buf->nil_node) n = n->left;
  }
  return n;
}

/* In-order successor (nil_node after the last piece). */
static PieceNode *node_next(TextBuffer *buf, PieceNode *n) {
  if (n->right != buf->nil_node) {
    n = n->right;
    while (n->left != buf->nil_node) n = n->left;
    return n;
  }
  PieceNode *pa = n->parent;
  while (pa != buf->nil_node && n == pa->right) {
    n = pa;
    pa = n->parent;
  }
  return pa;
}

/* True when the document is exactly the server file plus the virtual final
 * newline added at open (nothing else edited, or every edit undone). */
static bool only_virtual_nl(TextBuffer *buf) {
  if (!buf->virtual_nl || buf->nchunks == 0) return false;
  const RemoteChunk *last = &buf->chunks[buf->nchunks - 1];
  size_t orig_size = last->orig_off + last->len, pos = 0;
  bool seen_nl = false;
  for (PieceNode *n = node_first(buf); n != buf->nil_node; n = node_next(buf, n)) {
    if (n->length == 0) continue;
    if (seen_nl) return false;
    if (n->source == BUFFER_SRC_REMOTE) {
      if (n->offset != pos) return false;
      pos += n->length;
    } else if (n->length == 1 && buf->heap_data[n->offset] == '\n' && pos == orig_size) {
      seen_nl = true;
    } else {
      return false;
    }
  }
  return seen_nl;
}

/* buf:edit_script() -> script, inserts
 * script  = { {keep=true, off=<orig offset>, len=n} | {ins=<index in inserts>}, ... }
 * inserts = { string, ... }
 * Contiguous remote pieces are coalesced into one keep; empty pieces skipped.
 * The virtual final newline of a file lacking one is only part of the script
 * once the document has really been changed, so an unedited document always
 * yields the original file (a single keep). */
static int f_buffer_edit_script(lua_State *L) {
  TextBuffer *buf = check_buffer(L, 1);
  if (!buf->remote) {
    lua_pushnil(L);
    lua_pushstring(L, "not a remote buffer");
    return 2;
  }
  bool skip_heap = only_virtual_nl(buf);
  lua_newtable(L);  /* script, index 2 */
  lua_newtable(L);  /* inserts, index 3 */
  lua_Integer nscript = 0, nins = 0;
  bool have_keep = false;
  size_t keep_off = 0, keep_len = 0;

  for (PieceNode *n = node_first(buf); n != buf->nil_node; n = node_next(buf, n)) {
    if (n->length > 0 && !(skip_heap && n->source != BUFFER_SRC_REMOTE)) {
      if (n->source == BUFFER_SRC_REMOTE) {
        if (have_keep && keep_off + keep_len == n->offset) {
          keep_len += n->length;
        } else {
          if (have_keep) {
            push_keep(L, ++nscript, keep_off, keep_len);
          }
          have_keep = true;
          keep_off = n->offset;
          keep_len = n->length;
        }
      } else {
        if (have_keep) {
          push_keep(L, ++nscript, keep_off, keep_len);
          have_keep = false;
        }
        lua_pushlstring(L, buf->heap_data + n->offset, n->length);
        lua_rawseti(L, 3, ++nins);
        lua_createtable(L, 0, 1);
        lua_pushinteger(L, nins);
        lua_setfield(L, -2, "ins");
        lua_rawseti(L, 2, ++nscript);
      }
    }
  }
  if (have_keep) {
    push_keep(L, ++nscript, keep_off, keep_len);
  }
  lua_pushvalue(L, 2);
  lua_pushvalue(L, 3);
  return 2;
}

/* buf:rebase(size, chunks, ends_with_nl): after a successful edit-only save,
 * replace the whole document with an all-REMOTE tree for the new server file.
 * Heap text, request queue, cached chunks, pins and the stale flag are all
 * reset (callers refetch what they display). On error the buffer is unchanged. */
static int f_buffer_rebase(lua_State *L) {
  TextBuffer *buf = check_buffer(L, 1);
  lua_Integer size = luaL_checkinteger(L, 2);
  luaL_checktype(L, 3, LUA_TTABLE);
  luaL_checktype(L, 4, LUA_TBOOLEAN);
  bool ends_with_nl = lua_toboolean(L, 4);
  if (!buf->remote) return luaL_error(L, "rebase: not a remote buffer");
  if (size < 0) return luaL_error(L, "rebase: negative size");

  RemoteChunk *chunks = NULL;
  size_t n = 0, lf = 0;
  const char *err = parse_chunks(L, 3, (size_t)size, buf->chunk_size_limit, &chunks, &n, &lf);
  if (err) return luaL_error(L, "rebase: %s", err);
  TextBuffer *nb = buffer_create();
  if (!nb) {
    free(chunks);
    return luaL_error(L, "out of memory");
  }
  nb->budget = buf->budget;
  nb->chunk_size_limit = buf->chunk_size_limit;
  if (!remote_setup(nb, chunks, n, (size_t)size, lf, ends_with_nl)) {
    free(chunks);
    buffer_destroy(nb);
    return luaL_error(L, "out of memory");
  }
  TextBuffer old = *buf;
  *buf = *nb;
  free(nb);
  line_cache.buf = NULL;
  buffer_free_contents(&old);
  lua_pushboolean(L, 1);
  return 1;
}

static int mm_gc(lua_State *L) {
  TextBuffer **ud = (TextBuffer **)luaL_checkudata(L, 1, API_TYPE_BUFFER);
  if (*ud) {
    buffer_destroy(*ud);
    *ud = NULL;
  }
  return 0;
}

static const luaL_Reg buffer_methods[] = {
  { "open",     f_buffer_open     },
  { "new",      f_buffer_new      },
  { "get_text", f_buffer_get_text },
  { "insert",   f_buffer_insert   },
  { "remove",   f_buffer_remove   },
  { "save",     f_buffer_save     },
  { "open_remote", f_buffer_open_remote },
  { "is_remote",   f_buffer_is_remote   },
  { "missing",     f_buffer_missing     },
  { "supply",      f_buffer_supply      },
  { "cancel",      f_buffer_cancel      },
  { "evict",       f_buffer_evict       },
  { "pin",         f_buffer_pin         },
  { "set_budget",  f_buffer_set_budget  },
  { "is_resident", f_buffer_is_resident },
  { "set_stale",   f_buffer_set_stale   },
  { "stats",       f_buffer_stats       },
  { "loaded_chunks", f_buffer_loaded_chunks },
  { "chunk_matches", f_buffer_chunk_matches },
  { "edit_script", f_buffer_edit_script },
  { "rebase",      f_buffer_rebase      },
  { NULL, NULL }
};

int luaopen_buffer(lua_State *L) {
  luaL_newmetatable(L, API_TYPE_BUFFER);
  luaL_setfuncs(L, buffer_methods, 0);
  lua_pushcfunction(L, mm_len);
  lua_setfield(L, -2, "__len");
  lua_pushcfunction(L, mm_index);
  lua_setfield(L, -2, "__index");
  lua_pushcfunction(L, mm_gc);
  lua_setfield(L, -2, "__gc");

  luaL_newlib(L, buffer_methods);
  return 1;
}
