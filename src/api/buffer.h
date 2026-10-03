#ifndef API_BUFFER_H
#define API_BUFFER_H

#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>
#include <lua.h>
#include <lauxlib.h>

#define API_TYPE_BUFFER "Buffer"

typedef enum {
  BUFFER_SRC_MMAP,   /* Read-only mmap from disk (vis architecture) */
  BUFFER_SRC_HEAP,   /* Dynamically appended in-memory text */
  BUFFER_SRC_REMOTE  /* Lazily fetched chunk of a file that lives on a server */
} BufferSourceType;

typedef struct PieceNode {
  struct PieceNode *parent, *left, *right;
  uint8_t color;             /* RED = 0, BLACK = 1 */
  BufferSourceType source;   /* mmap, heap or remote */
  size_t offset;             /* byte offset into the buffer source (original
                                file offset for BUFFER_SRC_REMOTE) */
  size_t length;             /* byte length of this piece */
  size_t line_feed_cnt;      /* number of '\n' in this piece */

  /* Augmented Red-Black Tree Metadata (VS Code architecture) */
  size_t size_left;          /* sum of length in left subtree */
  size_t lf_cnt_left;        /* sum of line_feed_cnt in left subtree */
} PieceNode;

/* One server-supplied chunk of the original remote file. */
typedef struct {
  size_t orig_off;           /* offset in the original file */
  char *data;                /* NULL unless state == RESIDENT */
  uint32_t len;              /* byte length (> 0) */
  uint32_t lf;               /* number of '\n' in the chunk */
  uint32_t prev, next;       /* LRU list links (resident chunks only) */
  uint8_t state;             /* CHUNK_MISSING / CHUNK_PENDING / CHUNK_RESIDENT */
  uint8_t pins;              /* PIN_USER | PIN_EDIT: never evicted while non-zero */
  uint8_t queued;            /* currently in the request queue */
} RemoteChunk;

typedef struct {
  PieceNode *root;
  PieceNode *nil_node;       /* Sentinel black node */
  const char *mmap_data;     /* Mapped file pointer (NULL if new file) */
  size_t mmap_size;
  char *heap_data;           /* Append buffer for typed text */
  size_t heap_size;
  size_t heap_capacity;
  size_t total_size;         /* Total byte size of document */
  size_t total_lines;        /* Total line count (lf_cnt + 1) */
  int fd;                    /* File descriptor for mmap or -1 */

  /* Remote (BUFFER_SRC_REMOTE) state; unused when remote == false */
  bool remote;
  bool stale;                /* server file changed: reads placeholder, edits refused */
  bool no_enqueue;           /* probing only: do not queue missing chunks */
  RemoteChunk *chunks;       /* sorted by orig_off, contiguous */
  size_t nchunks;
  size_t chunk_size_limit;   /* 0 = no limit on a single chunk length */
  size_t resident_bytes;
  size_t pinned_bytes;       /* part of resident_bytes held by pinned chunks */
  size_t budget;             /* LRU byte budget for resident chunks */
  uint32_t lru_head, lru_tail; /* most / least recently used resident chunk */
  uint32_t *queue;           /* chunk indices waiting for the fetcher */
  size_t qhead, qlen, qcap;
  int err;                   /* reason of the last failed operation */
  char err_msg[128];         /* detail for ERR_SYNC */
  lua_State *sync_L;         /* set only while get_text runs with a sync_fn */
  int sync_fn;
} TextBuffer;

int luaopen_buffer(lua_State *L);

#endif
