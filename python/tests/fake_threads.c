// A stand-in for libkomira (ABI 1.3) for the tests of a session used from
// several threads (test_threads.py). Each context is its own, and every call
// on one is written to a journal, when it enters and when it leaves, with the
// context's number. A call can be held at a gate until the test opens it, so
// the tests see which calls run while another is held, with no clock.
//
// The calls take a command: the table name of komira_register_parquet, the
// credential name of komira_credential_add, the SQL text of
// komira_sql_stream.
//   gate:<k>           enter gate k (0 <= k < 64), wait until it is opened,
//                      then succeed
//   fail:<text>        fail with status -3 and last error <text>
//   failgate:<k>:<text> fail with status -3 and last error <text>; the next
//                      komira_last_error on the context enters gate k first
//   signal             raise SIGUSR1 in the calling thread, then succeed
//   anything else      succeed
// komira_credential_set and komira_credential_seal always succeed. The four
// output calls of ABI 1.1 (schema, bindings, plan render), which the loader
// requires of a 1.3 library and these tests never make, answer nothing.
// komira_sql_stream answers, on success, a stream of the schema
// `n: int64` and no batch.
//
// Built with -DFAKE_RUN it reports ABI 1.6 and has the run handle calls
// (komira_run_new, _free, _cancel, _progress) and komira_sql_stream_run, for
// the tests of a query cancelled and watched through one (test_sql_cancel.py).
// Each handle has a number, in the order made, and its making, cancel and
// free are journaled (`r<n> new`, `r<n> cancel`, `r<n> free`); a call on a
// freed handle is counted as an overlap. komira_sql_stream_run takes a command
// as its SQL text:
//   hold:<k>           enter gate k, wait until it is opened or the run is
//                      cancelled; cancelled is -6, opened succeeds
//   ignore:<k>         enter gate k, wait until it is opened, whatever a
//                      cancel says, then succeed (a cancel after the last check)
//   failhold:<k>:<text> as hold, then fail with -3 and last error <text>
//   steps:<g>:<n>      add n to the handle's total, then for each segment i
//                      in 0..n-1 enter gate g+i as hold does and, opened,
//                      add 1 to the handle's done
//   slowcancel:<k>:<j> as hold; cancelled, enter gate j and wait until it is
//                      opened before returning -6
//   cancelled          return -6 with no cancel
//   fail:<text>        fail with -3 and last error <text>
//   anything else      succeed
// -6 sets the last error QUERY_CANCELLED_TEXT. On success it answers the
// stream komira_sql_stream answers; fake_streams counts the streams made and
// released.
//
// A call that enters while another call is inside the same context is
// journaled as `overlap` and counted (fake_overlaps), and so is a call on a
// context after its komira_ctx_free (`after free`; the context's memory is
// kept so that such a call can be seen). Neither is refused: the test reads
// the counts.
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define EXPORT __attribute__((visibility("default")))
#define GATES 64

typedef struct {
  int id;
  int inside;  // calls inside the context now
  bool freed;
  int last_error_gate;  // -1, or the gate the next komira_last_error enters
  char last[256];
} Ctx;

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static int next_id = 1;
static int overlaps;
static bool entered[GATES], opened[GATES];
static char journal[1 << 16];
static size_t journal_len;

static void note_locked(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(journal + journal_len, sizeof journal - journal_len, fmt, ap);
  va_end(ap);
  if (n > 0 && journal_len + (size_t)n < sizeof journal) journal_len += (size_t)n;
}

static void hold_locked(int k) {
  if (k < 0 || k >= GATES) return;
  entered[k] = true;
  pthread_cond_broadcast(&changed);
  while (!opened[k]) pthread_cond_wait(&changed, &mu);
}

// Journals the entry of a call `op` with `cmd` on `c`, counting an overlap or
// a use after free.
static void enter_locked(Ctx *c, const char *op, const char *cmd) {
  if (c->freed) {
    overlaps++;
    note_locked("c%d %s %s after free\n", c->id, op, cmd);
  } else if (c->inside > 0) {
    overlaps++;
    note_locked("c%d %s %s overlap\n", c->id, op, cmd);
  }
  c->inside++;
  note_locked("c%d %s %s enter\n", c->id, op, cmd);
}

static void leave_locked(Ctx *c, const char *op, const char *cmd) {
  c->inside--;
  note_locked("c%d %s %s leave\n", c->id, op, cmd);
}

// Runs the command `cmd` of a call `op` on `c` and returns its status.
static int32_t run(Ctx *c, const char *op, const char *cmd) {
  pthread_mutex_lock(&mu);
  enter_locked(c, op, cmd);
  int32_t rc = 0;
  if (strncmp(cmd, "gate:", 5) == 0) {
    hold_locked(atoi(cmd + 5));
  } else if (strncmp(cmd, "fail:", 5) == 0) {
    snprintf(c->last, sizeof c->last, "%s", cmd + 5);
    rc = -3;
  } else if (strncmp(cmd, "failgate:", 9) == 0) {
    const char *text = strchr(cmd + 9, ':');
    snprintf(c->last, sizeof c->last, "%s", text == NULL ? "" : text + 1);
    c->last_error_gate = atoi(cmd + 9);
    rc = -3;
  }
  leave_locked(c, op, cmd);
  pthread_mutex_unlock(&mu);
  if (strcmp(cmd, "signal") == 0) raise(SIGUSR1);
  return rc;
}

#ifdef FAKE_RUN
EXPORT int32_t komira_abi_version(void) { return 1006; }
#else
EXPORT int32_t komira_abi_version(void) { return 1003; }
#endif

EXPORT void *komira_ctx_new(void) {
  Ctx *c = calloc(1, sizeof *c);
  if (c == NULL) return NULL;
  pthread_mutex_lock(&mu);
  c->id = next_id++;
  c->last_error_gate = -1;
  note_locked("c%d new\n", c->id);
  pthread_mutex_unlock(&mu);
  return c;
}

EXPORT void komira_ctx_free(void *ctx) {
  Ctx *c = ctx;
  if (c == NULL) return;
  pthread_mutex_lock(&mu);
  enter_locked(c, "free", "-");
  c->freed = true;
  leave_locked(c, "free", "-");
  pthread_mutex_unlock(&mu);
}

EXPORT int32_t komira_last_error(void *ctx, uint8_t *b, uint64_t cap, uint64_t *n) {
  Ctx *c = ctx;
  pthread_mutex_lock(&mu);
  enter_locked(c, "last_error", "-");
  if (c->last_error_gate >= 0) {
    int k = c->last_error_gate;
    c->last_error_gate = -1;
    hold_locked(k);
  }
  size_t len = strlen(c->last);
  int32_t rc = 0;
  *n = len;
  if (cap < len) {
    rc = -4;
  } else if (len > 0) {
    memcpy(b, c->last, len);
  }
  leave_locked(c, "last_error", "-");
  pthread_mutex_unlock(&mu);
  return rc;
}

EXPORT int32_t komira_register_parquet(void *ctx, const char *name, const char *path) {
  (void)path;
  return run(ctx, "register", name);
}

// The output calls of ABI 1.1: an empty answer through the two-call protocol.
static int32_t nothing(uint64_t *n) {
  *n = 0;
  return 0;
}

EXPORT int32_t komira_parquet_schema(void *ctx, const char *path, uint8_t *b, uint64_t cap, uint64_t *n) {
  (void)ctx, (void)path, (void)b, (void)cap;
  return nothing(n);
}

EXPORT int32_t komira_csv_binding(void *ctx, const char *path, uint8_t delimiter, int32_t has_header,
                                  int32_t all_varchar, uint8_t *b, uint64_t cap, uint64_t *n) {
  (void)ctx, (void)path, (void)delimiter, (void)has_header, (void)all_varchar, (void)b, (void)cap;
  return nothing(n);
}

EXPORT int32_t komira_json_binding(void *ctx, const char *path, uint8_t *b, uint64_t cap, uint64_t *n) {
  (void)ctx, (void)path, (void)b, (void)cap;
  return nothing(n);
}

EXPORT int32_t komira_plan_render(void *ctx, const char *plan, uint64_t len, uint8_t *b, uint64_t cap,
                                  uint64_t *n) {
  (void)ctx, (void)plan, (void)len, (void)b, (void)cap;
  return nothing(n);
}

EXPORT int32_t komira_credential_add(void *ctx, int32_t kind, const char *name, int32_t *out_id) {
  (void)kind;
  int32_t rc = run(ctx, "credential_add", name);
  if (rc == 0) *out_id = 1;
  return rc;
}

EXPORT int32_t komira_credential_set(void *ctx, int32_t id, int32_t field, const uint8_t *v, uint64_t len) {
  (void)id, (void)field, (void)v, (void)len;
  return run(ctx, "credential_set", "-");
}

EXPORT int32_t komira_credential_seal(void *ctx, int32_t id, int32_t scope) {
  (void)id, (void)scope;
  return run(ctx, "credential_seal", "-");
}

// ---- the answer of komira_sql_stream: `n: int64`, no batch --------------------

struct ArrowSchema {
  const char *format;
  const char *name;
  const char *metadata;
  int64_t flags;
  int64_t n_children;
  struct ArrowSchema **children;
  struct ArrowSchema *dictionary;
  void (*release)(struct ArrowSchema *);
  void *private_data;
};

struct ArrowArray;

struct ArrowArrayStream {
  int (*get_schema)(struct ArrowArrayStream *, struct ArrowSchema *);
  int (*get_next)(struct ArrowArrayStream *, struct ArrowArray *);
  const char *(*get_last_error)(struct ArrowArrayStream *);
  void (*release)(struct ArrowArrayStream *);
  void *private_data;
};

struct ArrowArray {
  int64_t length;
  int64_t null_count;
  int64_t offset;
  int64_t n_buffers;
  int64_t n_children;
  const void **buffers;
  struct ArrowArray **children;
  struct ArrowArray *dictionary;
  void (*release)(struct ArrowArray *);
  void *private_data;
};

static void release_child(struct ArrowSchema *s) { s->release = NULL; }

static void release_root(struct ArrowSchema *s) {
  struct ArrowSchema *child = s->children[0];
  if (child->release != NULL) child->release(child);
  free(child);
  free(s->children);
  s->release = NULL;
}

static int get_schema(struct ArrowArrayStream *st, struct ArrowSchema *out) {
  (void)st;
  struct ArrowSchema **children = malloc(sizeof *children);
  struct ArrowSchema *child = calloc(1, sizeof *child);
  if (children == NULL || child == NULL) {
    free(children);
    free(child);
    return 12;  // ENOMEM
  }
  *child = (struct ArrowSchema){.format = "l", .name = "n", .flags = 2, .release = release_child};
  children[0] = child;
  *out = (struct ArrowSchema){
      .format = "+s", .name = "", .n_children = 1, .children = children, .release = release_root};
  return 0;
}

static int get_next(struct ArrowArrayStream *st, struct ArrowArray *out) {
  (void)st;
  memset(out, 0, sizeof *out);  // release NULL: the end of the stream
  return 0;
}

static const char *get_last_error(struct ArrowArrayStream *st) {
  (void)st;
  return NULL;
}

static int64_t streams_made, streams_released;

static void release_stream(struct ArrowArrayStream *st) {
  pthread_mutex_lock(&mu);
  streams_released++;
  pthread_mutex_unlock(&mu);
  st->release = NULL;
}

static void fill_stream(struct ArrowArrayStream *out) {
  pthread_mutex_lock(&mu);
  streams_made++;
  pthread_mutex_unlock(&mu);
  *out = (struct ArrowArrayStream){
      .get_schema = get_schema, .get_next = get_next, .get_last_error = get_last_error, .release = release_stream};
}

EXPORT int32_t komira_sql_stream(void *ctx, const char *sql, struct ArrowArrayStream *out) {
  int32_t rc = run(ctx, "sql", sql);
  if (rc == 0) fill_stream(out);
  return rc;
}

#ifdef FAKE_RUN
// ---- the run handle of ABI 1.6 ---------------------------------------------------

#define QUERY_CANCELLED_TEXT "QUERY_CANCELLED: execute: the stand-in's run was cancelled"

typedef struct {
  int id;
  bool cancelled;
  bool freed;
  uint64_t done, total;
} Run;

static int next_run = 1;
static int cancels;

// Counts and journals a call `op` on a handle already freed.
static void check_run_locked(Run *r, const char *op) {
  if (r->freed) {
    overlaps++;
    note_locked("r%d %s after free\n", r->id, op);
  }
}

EXPORT void *komira_run_new(void) {
  Run *r = calloc(1, sizeof *r);
  if (r == NULL) return NULL;
  pthread_mutex_lock(&mu);
  r->id = next_run++;
  note_locked("r%d new\n", r->id);
  pthread_mutex_unlock(&mu);
  return r;
}

// The handle's memory is kept, so that a call after the free is seen.
EXPORT void komira_run_free(void *run) {
  Run *r = run;
  if (r == NULL) return;
  pthread_mutex_lock(&mu);
  check_run_locked(r, "free");
  r->freed = true;
  note_locked("r%d free\n", r->id);
  pthread_mutex_unlock(&mu);
}

EXPORT int32_t komira_run_cancel(void *run) {
  Run *r = run;
  if (r == NULL) return -2;
  pthread_mutex_lock(&mu);
  check_run_locked(r, "cancel");
  r->cancelled = true;
  cancels++;
  note_locked("r%d cancel\n", r->id);
  pthread_cond_broadcast(&changed);
  pthread_mutex_unlock(&mu);
  return 0;
}

EXPORT int32_t komira_run_progress(void *run, uint64_t *done, uint64_t *total) {
  Run *r = run;
  if (r == NULL || done == NULL || total == NULL) return -2;
  pthread_mutex_lock(&mu);
  check_run_locked(r, "progress");
  *done = r->done;
  *total = r->total;
  pthread_mutex_unlock(&mu);
  return 0;
}

// Enters gate k and waits until it is opened or `r` is cancelled; whether it
// was cancelled.
static bool hold_run_locked(int k, Run *r) {
  if (k < 0 || k >= GATES) return r->cancelled;
  entered[k] = true;
  pthread_cond_broadcast(&changed);
  while (!opened[k] && !r->cancelled) pthread_cond_wait(&changed, &mu);
  return !opened[k] && r->cancelled;
}

EXPORT int32_t komira_sql_stream_run(void *ctx, const char *sql, void *run, struct ArrowArrayStream *out) {
  Ctx *c = ctx;
  Run *r = run;
  if (c == NULL) return -1;
  if (sql == NULL || r == NULL || out == NULL) return -2;
  pthread_mutex_lock(&mu);
  enter_locked(c, "sql_run", sql);
  check_run_locked(r, "sql_run");
  int32_t rc = 0;
  const char *text = NULL;
  if (strncmp(sql, "hold:", 5) == 0) {
    if (hold_run_locked(atoi(sql + 5), r)) rc = -6;
  } else if (strncmp(sql, "ignore:", 7) == 0) {
    hold_locked(atoi(sql + 7));
  } else if (strncmp(sql, "failhold:", 9) == 0) {
    hold_run_locked(atoi(sql + 9), r);
    text = strchr(sql + 9, ':');
    rc = -3;
  } else if (strncmp(sql, "steps:", 6) == 0) {
    int g = atoi(sql + 6);
    const char *n_at = strchr(sql + 6, ':');
    int n = n_at == NULL ? 0 : atoi(n_at + 1);
    r->total += (uint64_t)n;
    for (int i = 0; i < n && rc == 0; i++) {
      if (hold_run_locked(g + i, r)) {
        rc = -6;
      } else {
        r->done++;
      }
    }
  } else if (strncmp(sql, "slowcancel:", 11) == 0) {
    if (hold_run_locked(atoi(sql + 11), r)) {
      const char *j = strchr(sql + 11, ':');
      hold_locked(j == NULL ? -1 : atoi(j + 1));
      rc = -6;
    }
  } else if (strcmp(sql, "cancelled") == 0) {
    rc = -6;
  } else if (strncmp(sql, "fail:", 5) == 0) {
    text = sql + 4;
    rc = -3;
  }
  if (rc == -6) {
    snprintf(c->last, sizeof c->last, "%s", QUERY_CANCELLED_TEXT);
  } else if (rc == -3) {
    snprintf(c->last, sizeof c->last, "%s", text == NULL ? "" : text + 1);
  }
  leave_locked(c, "sql_run", sql);
  pthread_mutex_unlock(&mu);
  if (rc == 0) fill_stream(out);
  return rc;
}

// Waits until komira_run_cancel has been called n times in all. No clock: the
// test made the call that cancels before it waits.
EXPORT void fake_wait_cancels(int n) {
  pthread_mutex_lock(&mu);
  while (cancels < n) pthread_cond_wait(&changed, &mu);
  pthread_mutex_unlock(&mu);
}
#endif

// ---- the tests' controls --------------------------------------------------------

EXPORT void fake_open(int k) {
  if (k < 0 || k >= GATES) return;
  pthread_mutex_lock(&mu);
  opened[k] = true;
  pthread_cond_broadcast(&changed);
  pthread_mutex_unlock(&mu);
}

// Waits until a call has entered gate k. No clock: the test started the
// thread whose call enters it before it waits.
EXPORT void fake_wait_entered(int k) {
  if (k < 0 || k >= GATES) return;
  pthread_mutex_lock(&mu);
  while (!entered[k]) pthread_cond_wait(&changed, &mu);
  pthread_mutex_unlock(&mu);
}

// The calls that entered a context another call was inside, or one already
// freed.
EXPORT int fake_overlaps(void) {
  pthread_mutex_lock(&mu);
  int n = overlaps;
  pthread_mutex_unlock(&mu);
  return n;
}

// The streams komira_sql_stream and komira_sql_stream_run made, and the
// streams released.
EXPORT void fake_streams(int64_t *made, int64_t *released) {
  pthread_mutex_lock(&mu);
  *made = streams_made;
  *released = streams_released;
  pthread_mutex_unlock(&mu);
}

// Copies up to `cap` bytes of the journal into `b` and returns its length.
EXPORT size_t fake_journal(char *b, size_t cap) {
  pthread_mutex_lock(&mu);
  size_t len = journal_len;
  if (b != NULL) memcpy(b, journal, len < cap ? len : cap);
  pthread_mutex_unlock(&mu);
  return len;
}
