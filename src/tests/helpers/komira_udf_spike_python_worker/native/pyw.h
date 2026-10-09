/*
 * The Python worker runtime's engine side: what proxy_runtime.c,
 * proxy_channel.c and ipc_codec.c share. Test-only spike code for
 * docs/design/udf_runtime_interface.md section 5 (the worker transport).
 *
 * The engine reaches a Python worker process only through the table of
 * komira_udf_runtime.h: proxy_runtime.c implements that table, and each
 * entry becomes one message of komira_udf_wire.h on the worker's control
 * channel. The worker side is pyworker/komira_udf_pyworker.py.
 */
#ifndef KOMIRA_UDF_PYW_H
#define KOMIRA_UDF_PYW_H

#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#include "komira_udf_runtime.h"
#include "komira_udf_wire.h"

/* Two requests of this spike's own, outside the protocol's op table (which
 * has no fork and no host callback):
 *   FORK   engine to zygote: fork one context worker; the new control
 *          socket's worker end arrives with it (SCM_RIGHTS). OK carries the
 *          child's pid, the zygote's thread count at the fork and any
 *          warning os.fork raised.
 *   CLOCK  worker to engine, pipe transport only: the worker read the
 *          clock; the engine calls the host's now_ns for it (with shared
 *          memory the worker counts its reads in the control page). */
#define PYW_OP_FORK 64u
#define PYW_OP_CLOCK 65u

/* The shared region of one worker: one control page, then the
 * engine-to-worker heap, then the worker-to-engine heap. */
#define PYW_CTRL_BYTES 4096u
#define PYW_HEAP_BYTES (8u << 20)
#define PYW_SHM_BYTES (PYW_CTRL_BYTES + 2u * PYW_HEAP_BYTES)

/* Words of the control page (byte offsets). */
#define PYW_CTRL_MAGIC 0u        /* u32, "PYWK" */
#define PYW_CTRL_CLOCK_READS 16u /* u32: the worker's clock reads */
#define PYW_CTRL_CANCEL 32u      /* i32: the running call's cancel flag */
#define PYW_CTRL_RING_HEAD 64u   /* u32, written by the worker */
#define PYW_CTRL_RING_TAIL 128u  /* u32, written by the engine */
#define PYW_CTRL_RING 256u       /* u32[PYW_RING_SLOTS]: released slot ids */
#define PYW_RING_SLOTS 256u
#define PYW_SHM_MAGIC 0x4B575950u

/* Engine-to-worker slots: at most this many held at once. */
#define PYW_MAX_SLOTS 64

#define PYW_ALIGN 64u /* every payload and every IPC body buffer */

/* ---- a growable byte buffer ---------------------------------------------- */

struct pyw_buf {
  uint8_t* p;
  size_t len, cap;
  int oom;
};

void pyw_buf_put(struct pyw_buf* b, const void* src, size_t n);
void pyw_buf_zero(struct pyw_buf* b, size_t n);
void pyw_buf_align(struct pyw_buf* b, size_t a);
void pyw_buf_u32(struct pyw_buf* b, uint32_t v);
void pyw_buf_i32(struct pyw_buf* b, int32_t v);
void pyw_buf_u64(struct pyw_buf* b, uint64_t v);
void pyw_buf_str(struct pyw_buf* b, const char* s); /* u32 length (0xFFFFFFFF: NULL), bytes */
void pyw_buf_free(struct pyw_buf* b);

/* A bounded reader over a received control body. */
struct pyw_rd {
  const uint8_t* p;
  size_t len, at;
  int bad;
};

uint32_t pyw_rd_u32(struct pyw_rd* r);
int32_t pyw_rd_i32(struct pyw_rd* r);
int64_t pyw_rd_i64(struct pyw_rd* r);
char* pyw_rd_str(struct pyw_rd* r); /* malloc'd, NULL for a NULL string or on error */

/* ---- Arrow IPC (ipc_codec.c) ---------------------------------------------- */

/* One field of a schema: a C Data format string, a name, nullability. */
struct pyw_field {
  const char* name;
  const char* format;
  int nullable;
};

/* Appends one encapsulated Schema message for `n` fields. Returns NULL, or
 * why a field cannot be written (a format this codec does not encode). */
const char* pyw_ipc_schema(struct pyw_buf* b, const struct pyw_field* f, int n);

/* Bytes per value of a fixed-width primitive format, or 0. */
int pyw_format_width(const char* format);

/* The encapsulated RecordBatch message of `n` primitive columns, each
 * `widths[i]` bytes per value, `length` rows from each column's own
 * offset: its size, then the message written into `dst` (64-byte aligned,
 * at least that size). Each column's values are copied once, and its
 * validity bitmap re-based to offset 0; the null count is the array's, or
 * counted when it is -1. Returns the bytes written. */
size_t pyw_ipc_batch_size(int64_t length, const struct ArrowArray* const* cols, const int* widths, int n);
size_t pyw_ipc_batch_write(uint8_t* dst, int64_t length, const struct ArrowArray* const* cols, const int* widths,
                           int n);

/* Decodes a RecordBatch message of one primitive column of `width` bytes
 * per value from `msg` (an engine-owned copy of `len` bytes), checking every
 * offset and size against the message and the batch length. On success
 * `out` is an array over `msg`'s bytes whose release calls free(msg);
 * returns NULL. Otherwise returns why, and `msg` is still the caller's. */
const char* pyw_ipc_decode_column(uint8_t* msg, size_t len, int width, struct ArrowArray* out);


/* ---- one worker process and its channels (proxy_channel.c) ---------------- */

struct pyw_slot {
  uint32_t off, len;
  int used;
};

struct pyw_chan {
  int fd;        /* the control socket, engine end; -1 once closed */
  pid_t pid;     /* the worker's */
  int our_child; /* the engine spawned it: its exit status is ours to reap */
  uint8_t* shm;  /* the shared region, NULL on the pipe transport */
  int memfd;
  uint64_t next_id;
  int dead; /* end of file, a protocol fault or a kill: no request is sent again */
  char why[256];
  struct pyw_slot slots[PYW_MAX_SLOTS];
  int heap_full; /* the last batch went inline because no slot fit */
  uint32_t clock_seen;
  int64_t slot_sends, inline_sends, heap_full_events;
  /* CALL_BATCH time, summed: in pyw_chan_call, from its request sent to its
   * reply read, and in the worker (its reply's `slot` field: ns from reading
   * the request to sending the reply, which an OK otherwise leaves 0). */
  int64_t calls, call_ns, wait_ns, worker_ns;
};

/* What the worker answered: OK or ERROR, with its payload copied into a
 * malloc block the caller frees. */
struct pyw_reply {
  uint32_t op;
  uint8_t* payload;
  size_t len;
};

/* The program a worker runs and how: <dir>/python/bin/python3.13 on
 * <dir>/pyworker/komira_udf_pyworker.py. */
struct pyw_launch {
  const char* dir;
  const char* role;  /* "control", "zygote" or "context" */
  const char* codec; /* "own" or "pyarrow" */
  int limit_threads; /* OPENBLAS/OMP/MKL thread pools of one thread */
};

/* Starts a worker with posix_spawn and says HELLO; 0, or -1 with `why`. */
int pyw_chan_spawn(struct pyw_chan* c, const struct pyw_launch* l, int use_shm, char* why, size_t n);

/* Adopts a worker the zygote forked on `fd` (the engine end) and says HELLO. */
int pyw_chan_adopt(struct pyw_chan* c, int fd, pid_t pid, int use_shm, char* why, size_t n);

/* One request with a control body sent inline, `fds` passed with it, and its
 * reply. Returns 0, or -1 with c->why set (the worker is gone or broke the
 * protocol). */
int pyw_chan_request(struct pyw_chan* c, uint32_t op, const struct pyw_buf* body, const int* fds, int nfds,
                     struct pyw_reply* rep);

/* A CALL_BATCH: `head` (the call's control block, written first) and the
 * IPC batch of `cols`, in a slot of the engine-to-worker heap or inline
 * when none fits. `args` is released as soon as it is written. While it
 * waits, the engine forwards the worker's clock reads to host->now_ns and
 * the host's cancel flag to the worker, and kills the worker once a
 * deadline is 2 s past. Returns 0 or -1 as pyw_chan_request; `killed` is set
 * when the deadline kill fired. */
int pyw_chan_call(struct pyw_chan* c, const uint8_t* head, size_t head_len, int64_t length,
                  const struct ArrowArray* const* cols, const int* widths, int ncols, struct ArrowArray* args,
                  const komira_udf_call* call, const komira_udf_host* host, struct pyw_reply* rep, int* killed);

/* SHUTDOWN, closes the socket and the region, and waits up to 2 s for the
 * process to end before killing it. */
void pyw_chan_close(struct pyw_chan* c);

void pyw_reply_free(struct pyw_reply* r);

#endif /* KOMIRA_UDF_PYW_H */
