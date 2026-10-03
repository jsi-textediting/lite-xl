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

static const char *get_piece_data(TextBuffer *buf, const PieceNode *node) {
  if (node->source == BUFFER_SRC_MMAP) {
    return buf->mmap_data + node->offset;
  } else {
    return buf->heap_data + node->offset;
  }
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

static size_t find_offset_by_lineno_uncached(TextBuffer *buf, size_t lineno) {
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
        const char *data = get_piece_data(buf, node);
        const char *p = data;
        const char *end = data + node->length;
        while (p < end) {
          const char *nl = (const char *)memchr(p, '\n', end - p);
          if (!nl) break;
          target_lf--;
          if (target_lf == 0) {
            return accum_offset + (size_t)(nl - data) + 1; /* Position immediately after '\n' */
          }
          p = nl + 1;
        }
      }
      accum_offset += node->length;
      target_lf -= node->line_feed_cnt;
      node = node->right;
    }
  }
  return buf->total_size;
}

static size_t find_offset_by_lineno(TextBuffer *buf, size_t lineno) {
  if (lineno <= 1) return 0;
  if (line_cache.buf == buf && line_cache.lineno == lineno) return line_cache.offset;
  size_t off = find_offset_by_lineno_uncached(buf, lineno);
  line_cache.buf = buf;
  line_cache.lineno = lineno;
  line_cache.offset = off;
  return off;
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
      left_lfc = count_newlines(get_piece_data(buf, node), piece_off);
      right_lfc = node->line_feed_cnt - left_lfc;
      right_node = node_new(buf, node->source, node->offset + piece_off, right_len, right_lfc);
      if (!right_node) {
        free(new_node);
        new_node = NULL;
      }
    }
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

static bool buffer_remove_raw(TextBuffer *buf, size_t off1, size_t len) {
  if (len == 0 || buf->total_size == 0) return true;
  line_cache.buf = NULL;
  size_t off2 = off1 + len;
  if (off2 > buf->total_size) off2 = buf->total_size;

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

    const char *data = get_piece_data(buf, p);
    size_t del_lfc = count_newlines(data + (del_start - p_start), del_len);

    if (del_start == p_start && del_end == p_end) {
      /* Entire piece deleted */
      /* The emptied node stays in the tree (zero length): all traversals
       * tolerate it, and removal would need an augmented RB-tree delete. */
      ptrdiff_t delta_size = -((ptrdiff_t)p->length);
      ptrdiff_t delta_lf = -((ptrdiff_t)p->line_feed_cnt);
      p->length = 0;
      p->line_feed_cnt = 0;
      update_aggregates_to_root(buf, p, delta_size, delta_lf);
      buf->total_size -= del_len;
      buf->total_lines -= del_lfc;
    } else if (del_start == p_start) {
      /* Trim left side */
      size_t trim = del_len;
      ptrdiff_t delta_size = -((ptrdiff_t)trim);
      ptrdiff_t delta_lf = -((ptrdiff_t)del_lfc);
      p->offset += trim;
      p->length -= trim;
      p->line_feed_cnt -= del_lfc;
      update_aggregates_to_root(buf, p, delta_size, delta_lf);
      buf->total_size -= trim;
      buf->total_lines -= del_lfc;
    } else if (del_end == p_end) {
      /* Trim right side */
      size_t trim = del_len;
      ptrdiff_t delta_size = -((ptrdiff_t)trim);
      ptrdiff_t delta_lf = -((ptrdiff_t)del_lfc);
      p->length -= trim;
      p->line_feed_cnt -= del_lfc;
      update_aggregates_to_root(buf, p, delta_size, delta_lf);
      buf->total_size -= trim;
      buf->total_lines -= del_lfc;
    } else {
      /* Split middle */
      size_t left_len = del_start - p_start;
      size_t right_len = p_end - del_end;
      size_t left_lfc = count_newlines(data, left_len);
      size_t right_lfc = p->line_feed_cnt - left_lfc - del_lfc;

      PieceNode *right_node = node_new(buf, p->source, p->offset + (del_end - p_start), right_len, right_lfc);
      if (!right_node) return false;

      ptrdiff_t delta_size = -((ptrdiff_t)(p->length - left_len));
      ptrdiff_t delta_lf = -((ptrdiff_t)(p->line_feed_cnt - left_lfc));
      p->length = left_len;
      p->line_feed_cnt = left_lfc;
      update_aggregates_to_root(buf, p, delta_size, delta_lf);

      insert_node_right(buf, p, right_node);

      buf->total_size -= del_len;
      buf->total_lines -= del_lfc;
    }

    /* The removed bytes are gone: what followed them now starts at del_start. */
    curr_off = del_start;
    off2 -= del_len;
  }
  return true;
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

static void buffer_destroy(TextBuffer *buf) {
  if (!buf) return;
  if (line_cache.buf == buf) line_cache.buf = NULL;
  free_tree(buf, buf->root);
  free(buf->nil_node);
  buffer_release_mmap(buf);
  if (buf->heap_data) {
    free(buf->heap_data);
  }
  free(buf);
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
  return *ud;
}

static int mm_len(lua_State *L) {
  TextBuffer *buf = check_buffer(L, 1);
  lua_pushinteger(L, (lua_Integer)buf->total_lines);
  return 1;
}

static int mm_index(lua_State *L) {
  TextBuffer *buf = check_buffer(L, 1);
  if (lua_isinteger(L, 2)) {
    lua_Integer lineno = lua_tointeger(L, 2);
    if (lineno < 1 || (size_t)lineno > buf->total_lines) {
      lua_pushnil(L);
      return 1;
    }
    size_t start_off = find_offset_by_lineno(buf, (size_t)lineno);
    size_t end_off = find_offset_by_lineno(buf, (size_t)lineno + 1);
    if (end_off < start_off) end_off = start_off;
    size_t line_len = end_off - start_off;

    /* Extract line string */
    luaL_Buffer b;
    luaL_buffinit(L, &b);
    size_t rem = line_len;
    size_t curr_off = start_off;
    while (rem > 0 && curr_off < buf->total_size) {
      size_t piece_off = 0;
      PieceNode *p = find_piece_by_offset(buf, curr_off, &piece_off);
      if (!p || piece_off >= p->length) break;
      size_t avail = p->length - piece_off;
      size_t chunk = rem < avail ? rem : avail;
      if (chunk == 0) break;
      const char *data = get_piece_data(buf, p);
      luaL_addlstring(&b, data + piece_off, chunk);
      rem -= chunk;
      curr_off += chunk;
    }
    luaL_pushresult(&b);
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

static int f_buffer_get_text(lua_State *L) {
  TextBuffer *buf = check_buffer(L, 1);
  size_t line1 = (size_t)luaL_checkinteger(L, 2);
  size_t col1 = (size_t)luaL_checkinteger(L, 3);
  size_t line2 = (size_t)luaL_checkinteger(L, 4);
  size_t col2 = (size_t)luaL_checkinteger(L, 5);

  size_t off1 = find_offset_by_lineno(buf, line1) + (col1 > 0 ? col1 - 1 : 0);
  size_t off2 = find_offset_by_lineno(buf, line2) + (col2 > 0 ? col2 - 1 : 0);
  if (off1 > off2) { size_t tmp = off1; off1 = off2; off2 = tmp; }
  if (off2 > buf->total_size) off2 = buf->total_size;

  luaL_Buffer b;
  luaL_buffinit(L, &b);
  size_t rem = off2 - off1;
  size_t curr_off = off1;
  while (rem > 0 && curr_off < buf->total_size) {
    size_t piece_off = 0;
    PieceNode *p = find_piece_by_offset(buf, curr_off, &piece_off);
    if (!p || piece_off >= p->length) break;
    size_t avail = p->length - piece_off;
    size_t chunk = rem < avail ? rem : avail;
    if (chunk == 0) break;
    const char *data = get_piece_data(buf, p);
    luaL_addlstring(&b, data + piece_off, chunk);
    rem -= chunk;
    curr_off += chunk;
  }
  luaL_pushresult(&b);
  return 1;
}

static int f_buffer_insert(lua_State *L) {
  TextBuffer *buf = check_buffer(L, 1);
  size_t line = (size_t)luaL_checkinteger(L, 2);
  size_t col = (size_t)luaL_checkinteger(L, 3);
  size_t len = 0;
  const char *text = luaL_checklstring(L, 4, &len);

  size_t off = find_offset_by_lineno(buf, line) + (col > 0 ? col - 1 : 0);
  if (off > buf->total_size) off = buf->total_size;

  bool ok = buffer_insert_raw(buf, off, text, len);
  lua_pushboolean(L, ok);
  return 1;
}

static int f_buffer_remove(lua_State *L) {
  TextBuffer *buf = check_buffer(L, 1);
  size_t line1 = (size_t)luaL_checkinteger(L, 2);
  size_t col1 = (size_t)luaL_checkinteger(L, 3);
  size_t line2 = (size_t)luaL_checkinteger(L, 4);
  size_t col2 = (size_t)luaL_checkinteger(L, 5);

  size_t off1 = find_offset_by_lineno(buf, line1) + (col1 > 0 ? col1 - 1 : 0);
  size_t off2 = find_offset_by_lineno(buf, line2) + (col2 > 0 ? col2 - 1 : 0);
  if (off1 > off2) { size_t tmp = off1; off1 = off2; off2 = tmp; }
  if (off2 > buf->total_size) off2 = buf->total_size;

  bool ok = buffer_remove_raw(buf, off1, off2 - off1);
  lua_pushboolean(L, ok);
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
    size_t chunk = p->length - piece_off;
    if (!sink_write(sink, get_piece_data(buf, p) + piece_off, chunk)) return false;
    curr_off += chunk;
  }
  return curr_off == buf->total_size;
}

static int f_buffer_save(lua_State *L) {
  TextBuffer *buf = check_buffer(L, 1);
  const char *path = luaL_checkstring(L, 2);

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
