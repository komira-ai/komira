// A stand-in for libkomira (ABI 1.2) for the tests of the session thread
// (thread.test.mjs). Each context is its own, and every library call is
// written to a journal with the context's number and the thread that made it.
// A call can be held at a gate until the test opens it, so the tests see
// which calls run while another is held, with no clock.
//
// The calls take a command: the table name of komira_register_parquet, the
// path of komira_parquet_schema, the plan bytes of komira_plan_render.
//   gate:<k>       enter gate k (0 <= k < 64) and wait until it is opened
//   fail:<text>    fail with status -3 and last error <text>
//   anything else  succeed
// komira_parquet_schema returns the command's bytes, komira_plan_render the
// text `plan:<command>`, each through the two-call protocol; only the first
// of the two calls is journaled or held.
//
// The stand-in refuses (status -3, with a last error saying which) a call
// made on the thread that made the context (the JavaScript thread: the call
// was not moved off it), a call while another runs on the same context, and
// a call from another thread than the context's earlier calls.
//
// The tests reach the journal and the gates through fake_control.c, which
// opens this same library with RTLD_NOLOAD and calls the fake_* functions.
#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define EXPORT __attribute__((visibility("default")))
#define GATES 64
#define THREADS 64

typedef struct {
  int id;
  int maker;  // the thread index of komira_ctx_new
  int user;   // the thread index of its first call, -1 before
  bool inside;
  char last[256];
} Ctx;

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static int next_id = 1;
static bool entered[GATES], opened[GATES];
static char journal[1 << 16];
static size_t journal_len;
static pthread_t threads[THREADS];
static int thread_count;

// The index of the calling thread, by first appearance; THREADS once full.
static int thread_index_locked(void) {
  pthread_t self = pthread_self();
  for (int i = 0; i < thread_count; i++) {
    if (pthread_equal(threads[i], self)) return i;
  }
  if (thread_count == THREADS) return THREADS;
  threads[thread_count] = self;
  return thread_count++;
}

static void note_locked(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(journal + journal_len, sizeof journal - journal_len, fmt, ap);
  va_end(ap);
  if (n > 0 && journal_len + (size_t)n < sizeof journal) journal_len += (size_t)n;
}

static int32_t refuse_locked(Ctx *c, const char *why) {
  snprintf(c->last, sizeof c->last, "%s", why);
  return -3;
}

// Checks and journals a call `op` with `cmd` on `c`, holds it at its gate, and
// returns its status. `first` is false for the second of two calls.
static int32_t enter(Ctx *c, const char *op, const char *cmd, bool first) {
  pthread_mutex_lock(&mu);
  int t = thread_index_locked();
  int32_t rc = 0;
  if (t == c->maker) {
    rc = refuse_locked(c, "called on the thread that made the context");
  } else if (c->inside) {
    rc = refuse_locked(c, "two calls at once on one context");
  } else if (c->user >= 0 && c->user != t) {
    rc = refuse_locked(c, "a second thread used the context");
  }
  if (rc != 0) {
    note_locked("c%d %s %s t%d refused\n", c->id, op, cmd, t);
    pthread_mutex_unlock(&mu);
    return rc;
  }
  c->user = t;
  c->inside = true;
  if (first) note_locked("c%d %s %s t%d\n", c->id, op, cmd, t);
  int k = -1;
  if (first && strncmp(cmd, "gate:", 5) == 0) k = atoi(cmd + 5);
  if (k >= 0 && k < GATES) {
    entered[k] = true;
    pthread_cond_broadcast(&changed);
    while (!opened[k]) pthread_cond_wait(&changed, &mu);
  }
  if (strncmp(cmd, "fail:", 5) == 0) rc = refuse_locked(c, cmd + 5);
  c->inside = false;
  pthread_mutex_unlock(&mu);
  return rc;
}

// The two-call protocol over `bytes`.
static int32_t give(const char *bytes, size_t len, uint8_t *b, uint64_t cap, uint64_t *n) {
  *n = len;
  if (cap < len) return -4;
  memcpy(b, bytes, len);
  return 0;
}

EXPORT int32_t komira_abi_version(void) { return 1002; }

EXPORT void *komira_ctx_new(void) {
  Ctx *c = calloc(1, sizeof *c);
  if (c == NULL) return NULL;
  pthread_mutex_lock(&mu);
  c->id = next_id++;
  c->maker = thread_index_locked();
  c->user = -1;
  note_locked("c%d new t%d\n", c->id, c->maker);
  pthread_mutex_unlock(&mu);
  return c;
}

EXPORT void komira_ctx_free(void *ctx) {
  Ctx *c = ctx;
  pthread_mutex_lock(&mu);
  note_locked("c%d free t%d\n", c->id, thread_index_locked());
  pthread_mutex_unlock(&mu);
  free(c);
}

EXPORT int32_t komira_last_error(void *ctx, uint8_t *b, uint64_t cap, uint64_t *n) {
  Ctx *c = ctx;
  size_t len = strlen(c->last);
  if (len == 0) {
    *n = 0;
    return 0;
  }
  return give(c->last, len, b, cap, n);
}

EXPORT int32_t komira_register_parquet(void *ctx, const char *name, const char *path) {
  (void)path;
  return enter(ctx, "register", name, true);
}

EXPORT int32_t komira_parquet_schema(void *ctx, const char *path, uint8_t *b, uint64_t cap, uint64_t *n) {
  int32_t rc = enter(ctx, "schema", path, b == NULL);
  if (rc != 0) return rc;
  return give(path, strlen(path), b, cap, n);
}

EXPORT int32_t komira_plan_render(void *ctx, const uint8_t *p, uint64_t len, uint8_t *b, uint64_t cap,
                                  uint64_t *n) {
  char cmd[200];
  size_t m = len < sizeof cmd - 1 ? (size_t)len : sizeof cmd - 1;
  memcpy(cmd, p, m);
  cmd[m] = '\0';
  int32_t rc = enter(ctx, "render", cmd, b == NULL);
  if (rc != 0) return rc;
  char text[208];
  int k = snprintf(text, sizeof text, "plan:%s", cmd);
  return give(text, (size_t)k, b, cap, n);
}

// ---- the tests' controls (fake_control.c) -------------------------------------

EXPORT void fake_open(int k) {
  if (k < 0 || k >= GATES) return;
  pthread_mutex_lock(&mu);
  opened[k] = true;
  pthread_cond_broadcast(&changed);
  pthread_mutex_unlock(&mu);
}

// Waits until a call has entered gate k. No clock: the call that enters it is
// already queued when a test waits.
EXPORT void fake_wait_entered(int k) {
  if (k < 0 || k >= GATES) return;
  pthread_mutex_lock(&mu);
  while (!entered[k]) pthread_cond_wait(&changed, &mu);
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
