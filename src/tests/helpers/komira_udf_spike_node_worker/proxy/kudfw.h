/*
 * kudfw.h: the engine side of the UDF worker transport
 * (docs/design/udf_runtime_interface.md sections 4.1 and 5.2), shared by the
 * files of the proxy runtime. Test-only spike code.
 *
 * The proxy is a komira_udf_runtime table whose entries send one request per
 * call to a worker process and wait for its reply (komira_udf_wire.h). It
 * knows no language: a launcher (an argv and an environment) says how to
 * start a worker, and describe answers what the worker says it is.
 *
 * Messages, as this spike frames them (every payload INLINE, after the
 * 40-byte header on a Unix socket pair):
 *   request payload  = a 64-byte request head, then the op's body (so the
 *                      body, and the 64-aligned buffers in it, start
 *                      64-aligned in the payload)
 *   request head     = u64 handle (the worker's id of the udf, context,
 *                      instance, frame or groups object the op is for),
 *                      i64 deadline (ns left when sent; 0 = none),
 *                      i64 call_id, u32 n_groups, u32 emit_first_n,
 *                      32 zero bytes
 *   reply payload    = the op's body (OK) or an error (ERROR):
 *                      i32 code, i64 row, i64 group, str message, str trace
 *   str              = u32 length, UTF-8 bytes
 * Bodies: HELLO u32 wire version, u32 ABI major, u32 ABI minor (both ways);
 * DESCRIBE reply: ten u32 capability fields in komira_udf_capabilities
 * order, then str runtime_id, str runtime_abi; VALIDATE and LOAD: Arrow IPC
 * Schema messages (arguments, result, and the state when there is one), the
 * spec's scalar fields as the first one's custom metadata; LOAD, OPEN_CONTEXT,
 * OPEN_INSTANCE, FRAME_OPEN, AGG_OPEN reply: u64 id; OPEN_CONTEXT: u32 slot;
 * OPEN_INSTANCE: u64 context id; CALL_BATCH, FRAME_IN, AGG_UPDATE, AGG_MERGE:
 * one Arrow IPC RecordBatch message (AGG_*: the group ids as its last
 * column); replies with data: one RecordBatch message. A reply to FRAME_OUT
 * or FRAME_IN is OK with a batch (an output), OK with KOMIRA_UDF_WIRE_END
 * (the frame ended), or OK with neither (the frame needs an input batch
 * first). CLOSE_CONTEXT reply: UTF-8 `key=value` lines, the worker's own
 * counters, which the proxy logs through the host.
 *
 * Cancel: the worker runs user code on its only thread, so it cannot read
 * the control channel during a call. Each worker gets a shared memory file
 * (fd 4) whose first 8 bytes the proxy sets to the request id of a call
 * the host cancelled; the worker reads it between rows.
 */
#ifndef KUDFW_H
#define KUDFW_H

#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#include "komira_udf_runtime.h"
#include "komira_udf_wire.h"

#define KUDFW_HEAD_BYTES 64u
#define KUDFW_MAX_FIELDS 64
#define KUDFW_ALIGN 64u /* Arrow IPC body buffers, engine to worker */

/* ---- growable byte buffer ------------------------------------------------ */

typedef struct kudfw_buf {
  uint8_t* p;
  size_t n, cap;
  int oom;
} kudfw_buf;

void kudfw_buf_free(kudfw_buf* b);
size_t kudfw_buf_put(kudfw_buf* b, const void* src, size_t n); /* position written at */
size_t kudfw_buf_zero(kudfw_buf* b, size_t n);
size_t kudfw_buf_pad(kudfw_buf* b, size_t align); /* zero-pad to `align`; the new length */
void kudfw_buf_u32(kudfw_buf* b, uint32_t v);
void kudfw_buf_u64(kudfw_buf* b, uint64_t v);
void kudfw_buf_str(kudfw_buf* b, const char* s);

/* ---- Arrow IPC (ipc.c) ------------------------------------------------------ */

/* One field of a bound schema: its C Data format ('l', 'g', 'i') and flags. */
typedef struct kudfw_field {
  char fmt;
  int nullable;
  char name[64];
} kudfw_field;

typedef struct kudfw_schema {
  int n;
  int is_struct; /* a table (struct) result, or a single column */
  kudfw_field f[KUDFW_MAX_FIELDS];
} kudfw_schema;

/* Read a bound ArrowSchema: a struct's children, or one leaf. 0, or -1 with
 * `why` set for a type this transport does not carry. */
int kudfw_schema_read(const struct ArrowSchema* s, kudfw_schema* out, const char** why);

/* Append one IPC Schema message (continuation, length, flatbuffer, no body)
 * holding `s`'s fields, with `n_kv` key/value pairs of custom metadata. */
void kudfw_ipc_schema(kudfw_buf* b, const kudfw_schema* s, int n_kv, const char* const* keys,
                      const char* const* values);

/* Append one IPC RecordBatch message of `n` primitive columns of `length`
 * rows (`fmts[i]`). A column's validity bitmap and values are re-based to
 * offset 0. -1 with `why` set for a column this encoder cannot read. */
int kudfw_ipc_batch(kudfw_buf* b, int64_t length, int n, const struct ArrowArray* const* cols,
                    const char* fmts, const char** why);

/* An IPC RecordBatch message the worker sent, decoded against `fields` into
 * arrays that borrow `payload` (`len` bytes at `msg`): the layout is checked
 * against the bound types and every buffer against the body's bounds before
 * any pointer is formed. On success, *arrays holds `n` columns; each one's
 * release drops a reference on `hold`, which frees the payload with its last
 * reference. -1 with `why` set otherwise. */
typedef struct kudfw_hold kudfw_hold;
int kudfw_ipc_decode(const uint8_t* msg, size_t len, const kudfw_field* fields, int n, int64_t* length,
                     kudfw_hold* hold, struct ArrowArray* cols, const char** why);

/* The payload block the decoded arrays borrow, reference-counted. */
struct kudfw_hold {
  _Atomic int refs;
  uint8_t* payload;
  size_t bytes;
  const komira_udf_host* host; /* its mem_release, for the reserved bytes */
};
kudfw_hold* kudfw_hold_new(uint8_t* payload, size_t bytes, const komira_udf_host* host);
void kudfw_hold_drop(kudfw_hold* h);

/* Wrap decoded columns as the host's `out`: a struct of all of them (a
 * table) or the one column. Moves the columns. */
void kudfw_out_struct(struct ArrowDeviceArray* out, int64_t length, int n, struct ArrowArray* cols,
                      kudfw_hold* hold);
void kudfw_out_column(struct ArrowDeviceArray* out, struct ArrowArray* col);

/* ---- one worker process and its channel (channel.c) ------------------------ */

typedef struct kudfw_launcher {
  const char* argv[12]; /* argv[0] is the program */
  const char* envp[8];
} kudfw_launcher;

typedef struct kudfw_worker {
  pid_t pid;
  int sock;
  int cancel_fd; /* the shared memory file of the cancel word */
  uint64_t next_request;
  int lost;         /* 1 once the worker crashed, was killed, or broke the protocol */
  char lost_why[200];
  int64_t spawn_ns; /* posix_spawn to the end of HELLO */
} kudfw_worker;

/* A reply: its op, flags and payload (malloc'd, KUDFW_ALIGN-aligned). */
typedef struct kudfw_reply {
  uint32_t op, flags;
  uint8_t* payload;
  size_t len;
} kudfw_reply;

/* Start a worker and exchange HELLO. 0, or a status with `err` filled. */
int32_t kudfw_spawn(const kudfw_launcher* l, const komira_udf_host* host, kudfw_worker* w,
                    komira_udf_error* err);

/* Send one request and wait for its reply, watching the call: the host's
 * cancel flag (forwarded to the cancel word) and deadline. A worker that
 * does not answer KUDFW_GRACE_MS after a cancel or a passed deadline is
 * killed. 0 with *reply filled (an OK or ERROR reply), or a status with
 * `err` filled (the worker is then lost: crashed, killed, or a protocol
 * fault). `body` follows the head. */
#define KUDFW_GRACE_MS 500
int32_t kudfw_request(kudfw_worker* w, const komira_udf_host* host, uint32_t op, uint32_t flags,
                      uint64_t handle, const komira_udf_call* call, uint32_t n_groups, uint32_t emit_first_n,
                      const uint8_t* body, size_t body_len, kudfw_reply* reply, komira_udf_error* err);

/* The status of an ERROR reply, its strings moved into `err`; or 0 for OK. */
int32_t kudfw_reply_status(const kudfw_reply* r, komira_udf_error* err);
void kudfw_reply_free(kudfw_reply* r);

/* SHUTDOWN, close the channel, reap the process (killed if it lingers). */
void kudfw_stop(kudfw_worker* w);

/* ---- errors (channel.c) ----------------------------------------------------- */

int32_t kudfw_fail(komira_udf_error* e, int32_t code, int64_t row, const char* fmt, ...)
    __attribute__((format(printf, 4, 5)));

int64_t kudfw_mono_ns(void);
void kudfw_log(const komira_udf_host* host, int32_t level, const char* fmt, ...)
    __attribute__((format(printf, 3, 4)));

/* ---- the table (proxy.c) ---------------------------------------------------- */

const komira_udf_runtime* kudfw_proxy_init(const komira_udf_host* host, komira_udf_rt** rt,
                                           komira_udf_error* err, const kudfw_launcher* launcher);

#endif /* KUDFW_H */
