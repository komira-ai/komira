/*
 * udfpy.h: the private structures of the komira/python runtime library,
 * shared by its files (docs/design/udf_python_worker.md).
 *
 * The library implements the komira_udf_runtime table. Python code runs in
 * worker processes forked from a zygote: the zygote (python/komira/_udf/
 * zygote.py) is started with posix_spawn at the first load of a generation
 * and answers on a control socket; each context asks it, with FORK, for one
 * worker and gets that worker's socket and cancel word.
 *
 * Files: runtime.c (the table, init, options, load and contexts),
 * descriptor.c (the descriptor decoder and validate), zygote.c (generations
 * and the control channel), worker.c (a context's channel and calls),
 * wire.c (framing, errors, trace), ipc.c (Arrow IPC).
 *
 * Locking: one mutex, rt->zy_mu, guards the generations, the control
 * channel, the counters and the registry of contexts. A context is used by
 * one engine thread at a time and holds no lock during a call. Two flags are
 * written under zy_mu and read without it, with atomic loads, by the check a
 * context makes before each request: a generation's `dead` and a context's
 * `exit_known`.
 *
 * Supervision (design section 5): the library learns of a worker's end from
 * end of file on its socket and names the end from the zygote's EXIT report,
 * which it waits for under zy_mu (udfpy_await_exit). It stops a worker by
 * force only through the worker's pidfd, grace_ms after it stored the call's
 * id in the cancel word.
 */
#ifndef UDFPY_H
#define UDFPY_H

#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#include "komira_udf_runtime.h"
#include "udfpy_wire.h"

#define UDFPY_ALIGN 64u /* Arrow IPC body buffers, library to worker */
#define UDFPY_MAX_FIELDS 64
#define UDFPY_MAX_NAME 64

/* ---- growable byte buffer (ipc.c) ---------------------------------------- */

typedef struct udfpy_buf {
  uint8_t* p;
  size_t n, cap;
  int oom;
} udfpy_buf;

void udfpy_buf_free(udfpy_buf* b);
size_t udfpy_buf_put(udfpy_buf* b, const void* src, size_t n); /* position written at */
size_t udfpy_buf_zero(udfpy_buf* b, size_t n);
size_t udfpy_buf_pad(udfpy_buf* b, size_t align); /* zero-pad to `align`; the new length */
void udfpy_buf_u32(udfpy_buf* b, uint32_t v);
void udfpy_buf_u64(udfpy_buf* b, uint64_t v);
void udfpy_buf_str(udfpy_buf* b, const char* s);

/* ---- Arrow IPC (ipc.c) ---------------------------------------------------- */

typedef struct udfpy_field {
  char fmt; /* the C Data format: 'l', 'g' or 'i' */
  int nullable;
  char name[UDFPY_MAX_NAME];
} udfpy_field;

typedef struct udfpy_schema {
  int n;
  int is_struct;
  udfpy_field f[UDFPY_MAX_FIELDS];
} udfpy_schema;

/* Read a bound ArrowSchema: a struct's children, or one leaf. 0, or -1 with
 * `why` set for a type this runtime does not carry. */
int udfpy_schema_read(const struct ArrowSchema* s, udfpy_schema* out, const char** why);

/* Append one IPC Schema message holding `s`'s fields, with `n_kv` pairs of
 * custom metadata (none here). */
void udfpy_ipc_schema(udfpy_buf* b, const udfpy_schema* s, int n_kv, const char* const* keys,
                      const char* const* values);

/* Append one IPC RecordBatch message of `n` primitive columns of `length`
 * rows (`fmts[i]`); each column's validity bitmap and values are re-based to
 * offset 0. -1 with `why` set for a column this encoder cannot read. */
int udfpy_ipc_batch(udfpy_buf* b, int64_t length, int n, const struct ArrowArray* const* cols,
                    const char* fmts, const char** why);

typedef struct udfpy_hold udfpy_hold;

/* A RecordBatch message a worker sent, decoded against `fields` into arrays
 * that borrow the payload: layout and every buffer are checked against the
 * bound types and the body's bounds before a pointer is formed. Each
 * array's release drops a reference on `hold`. -1 with `why` set otherwise. */
int udfpy_ipc_decode(const uint8_t* msg, size_t len, const udfpy_field* fields, int n, int64_t* length,
                     udfpy_hold* hold, struct ArrowArray* cols, const char** why);

/* The payload block decoded arrays borrow, reference-counted; the last drop
 * releases the reserved bytes to the host and frees the payload. */
struct udfpy_hold {
  _Atomic int refs;
  uint8_t* payload;
  size_t bytes;
  const komira_udf_host* host;
};
udfpy_hold* udfpy_hold_new(uint8_t* payload, size_t bytes, const komira_udf_host* host);
void udfpy_hold_drop(udfpy_hold* h);

void udfpy_out_column(struct ArrowDeviceArray* out, struct ArrowArray* col);

/* ---- wire.c: framing, errors, trace --------------------------------------- */

#define UDFPY_MSG_FDS 4

typedef struct udfpy_msg {
  uint32_t op, flags;
  uint64_t request_id;
  uint8_t* payload; /* malloc'd, UDFPY_ALIGN-aligned; NULL when len is 0 */
  size_t len;
  int fds[UDFPY_MSG_FDS]; /* descriptors that came with it (close-on-exec), owned */
  int nfds;
} udfpy_msg;

/* One request: header, 64-byte head, body, in one sendmsg, with `nfds`
 * descriptors as SCM_RIGHTS on it. 0, or -1 with errno set. */
int udfpy_send(int sock, uint32_t op, uint64_t request_id, uint32_t flags, uint64_t handle, int64_t deadline_left,
               int64_t call_id, const uint8_t* body, size_t body_len, const int* fds, int nfds);

/* One message, with up to UDFPY_MSG_FDS descriptors sent with it (more are
 * closed). 0; -1 at end of file or on an error; -2 when the header breaks the
 * framing (`why` set). On -1 and -2 nothing is left to free. */
int udfpy_recv(int sock, udfpy_msg* m, const char** why);
/* Free the payload and close the descriptors the message still owns. */
void udfpy_msg_free(udfpy_msg* m);

/* The status of an ERROR message, its strings moved into `err`; 0 for OK. */
int32_t udfpy_reply_status(const udfpy_msg* m, komira_udf_error* err);

int32_t udfpy_fail(komira_udf_error* e, int32_t code, int64_t row, const char* fmt, ...)
    __attribute__((format(printf, 4, 5)));
/* Move `from`'s strings and fields into `to` (the host's struct). */
void udfpy_error_move(komira_udf_error* to, komira_udf_error* from);
const char* udfpy_status_name(int32_t code);
int64_t udfpy_mono_ns(void);
/* How a process ended, as text: "signal 6 (SIGABRT)", "exit status 3", or
 * "an unknown status" (how 0 with a negative value). `how` is 0 for an
 * exit, 1 for a signal, as in the zygote's EXIT report. */
void udfpy_how_text(int how, int value, char* out, size_t n);

/* ---- the runtime ------------------------------------------------------------ */

#define UDFPY_MAX_SYS_PATH 32

/* The strings are malloc'd copies, freed with the runtime. */
typedef struct udfpy_options {
  const char* interpreter;
  const char* zygote;
  const char* abi;
  const char* scratch;
  const char* sys_path[UDFPY_MAX_SYS_PATH];
  int n_sys_path;
  int64_t grace_ms; /* the forced stop's grace period; default 2000 */
  const char* trace;
} udfpy_options;

typedef struct udfpy_gen {
  int number;
  pid_t pid;       /* -1 once reaped */
  pid_t spawn_pid; /* the pid it was started with */
  int sock;
  uint64_t next_request;
  uint32_t loads; /* LOADs the zygote answered OK */
  int open_ctx;
  int helloed, retired, shut;
  int dead; /* the control socket ended; atomic loads outside zy_mu */
  int exit_how; /* 0 exited, 1 signalled; valid once reaped */
  int exit_value;
  int reaped;
} udfpy_gen;

typedef struct komira_udf_context komira_udf_context_t;

typedef struct komira_udf_rt {
  const komira_udf_host* host;
  udfpy_options opt;
  int trace_fd;
  pthread_mutex_t zy_mu;
  udfpy_gen** gens; /* every generation, running or not, until shutdown */
  int n_gens, cap_gens;
  udfpy_gen* cur; /* the current generation, or NULL */
  int next_gen;
  uint64_t next_udf, next_ctx;
  komira_udf_context_t** ctxs; /* open contexts, for EXIT messages */
  int n_ctxs, cap_ctxs;
  int forked;                    /* set in a fork of the engine's process: every entry is refused */
  struct komira_udf_rt* next_rt; /* the list the fork handler walks (runtime.c) */
} udfpy_rt;

/* Why every context of a runtime is lost in a fork of the engine's process. */
#define UDFPY_FORKED_WHY "this process is a fork of the process that owns the runtime's zygote and workers"

typedef struct komira_udf_udf {
  udfpy_rt* rt;
  uint64_t id;
  udfpy_gen* gen;
  uint32_t load_seq;
  int32_t shape;
  uint32_t batch_format;
  char* entry;
  udfpy_schema args, result;
} udfpy_udf;

struct komira_udf_context {
  udfpy_rt* rt;
  udfpy_gen* gen;
  uint64_t id;
  uint32_t slot;
  uint32_t fork_seq;
  pid_t pid;
  int pidfd; /* the worker's, from the FORK reply: the only way the library signals it */
  int sock;
  volatile int64_t* word; /* the cancel word, shared with the worker */
  uint64_t next_request;
  int lost;
  char lost_why[200]; /* why, after "the worker (pid N) is gone: " */
  int killing;        /* the library sent SIGKILL during the current call */
  int kill_deadline;  /* what that stop answered: 1 the deadline, 0 the cancel flag */
  int exit_how, exit_value; /* from EXIT, under zy_mu, before exit_known */
  int exit_known;           /* atomic loads outside zy_mu */
};

typedef struct komira_udf_instance {
  struct komira_udf_context* ctx;
  udfpy_udf* udf;
  uint64_t id;
} udfpy_inst;

/* ---- descriptor.c --------------------------------------------------------- */

int32_t udfpy_validate(const komira_udf_spec* s, uint32_t* batch_format, komira_udf_error* err);

/* ---- zygote.c (callers hold rt->zy_mu) ----------------------------------- */

void udfpy_trace(udfpy_rt* rt, const char* fmt, ...) __attribute__((format(printf, 2, 3)));

/* Spawn a zygote, exchange HELLO and check its interpreter; make it current. */
int32_t udfpy_gen_spawn(udfpy_rt* rt, udfpy_gen** out, komira_udf_error* err);
/* One request on the control channel. 0 with *reply an OK or ERROR message
 * (EXIT messages met on the way are recorded); a status with `err` filled
 * when the zygote ended or broke the framing (the generation is then
 * retired). */
int32_t udfpy_ctl_request(udfpy_rt* rt, udfpy_gen* g, uint32_t op, uint32_t flags, uint64_t handle,
                          const uint8_t* body, size_t body_len, const int* fds, int nfds, udfpy_msg* reply,
                          komira_udf_error* err);
void udfpy_gen_retire(udfpy_rt* rt, udfpy_gen* g);
void udfpy_gen_shutdown(udfpy_rt* rt, udfpy_gen* g);
void udfpy_gens_free(udfpy_rt* rt);
/* Read what the zygote sent while no request was pending (EXIT reports, or
 * the end of its socket, which retires the generation). */
void udfpy_ctl_drain(udfpy_rt* rt, udfpy_gen* g);
/* Read the control channel until `c`'s EXIT report is recorded or the
 * zygote's socket ends. Called once `c`'s worker is known to have ended. */
void udfpy_await_exit(udfpy_rt* rt, komira_udf_context_t* c);

/* ---- worker.c --------------------------------------------------------------- */

int32_t udfpy_open_context(udfpy_rt* rt, uint32_t slot, komira_udf_context_t** out, komira_udf_error* err);
void udfpy_close_context(komira_udf_context_t* c);
int32_t udfpy_open_instance(komira_udf_context_t* c, udfpy_udf* u, udfpy_inst** out, komira_udf_error* err);
void udfpy_close_instance(udfpy_inst* in);
int32_t udfpy_call_batch(udfpy_inst* in, const komira_udf_call* call, struct ArrowDeviceArray* args,
                         struct ArrowDeviceArray* out, komira_udf_error* err);

#endif /* UDFPY_H */
