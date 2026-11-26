// The Node-API addon over libkomira, komira's one shared library with a flat C
// ABI (src/so). It is built by node_addon (BUCK, `komira_addon`) with
// every napi_* symbol left undefined for node to resolve, and it exposes the
// library to JavaScript:
//
//   load(libraryPath)                  open libkomira from `libraryPath`
//   abiVersion()                       the library's komira_abi_version()
//   newSession(threads?, memoryLimit?) a session handle (an external): komira_ctx_new, or
//                                      komira_ctx_new_with_options when either is not 0
//   freeSession(session)               Promise<undefined>: destroy it once the calls made before it finish
//   registerParquet(session, name, path)  Promise<undefined>
//   parquetSchema(session, path)       Promise<Buffer>: the file's schema as komira.plan.v1 WireSchema bytes
//   planRender(session, bytes)         Promise<string>: the text of a serialized plan; the plan is not run
//   sessionStats()                     { created, freed }: contexts made and freed here
//   importArrowStream(capsule), arrowSchema(result), arrowNextBatch(result), arrowClose(result)
//                                      an Arrow C stream drained and described (arrow_import.c)
//
// Why the library is opened with dlopen at `load`, and is not a NEEDED
// dependency with a run path. libkomira is a Mojo shared library: it needs the
// Mojo runtime and its native owners beside it (lib/), and the build offers it
// as a directory (`libkomira[runnable]`), not as a link input to a C target.
// A NEEDED edge would fix the library's place at build time and make a missing
// or wrong library a loader error before any JavaScript runs. With dlopen the
// host gives the path, the addon checks `komira_abi_version` (major 1) and
// names a missing symbol, and every failure is a JavaScript Error. A call a
// later minor of ABI 1 added (komira_ctx_new_with_options in 1.4,
// komira_last_error_code and komira_last_error_step in 1.7) must be there when
// the library's minor includes it, and may be missing from an older library:
// newSession with options then throws, naming both versions. The library
// is never dlclose'd: the Mojo runtime does not support unloading, and a
// session finalizer may run late.
//
// The session thread. Every call on a session's context runs on one native
// thread that the session owns, started by its first call: the JavaScript
// thread queues the call and gets a Promise, the session thread runs the
// queued calls one at a time in the order they were made, and a thread-safe
// function settles each Promise on the JavaScript thread. So a context is used
// by one thread at a time (the ABI's rule), the event loop never waits on the
// library, and two sessions run at once. The thread-safe function is
// referenced only while a call is pending, so a pending call keeps the event
// loop alive and an idle session does not.
//
// Errors. A call whose status is not zero rejects with an Error with `status`
// (the number), `code` (the KOMIRA_ERR_* name), and, read on the session
// thread right after the call, `lastError` (the last error text, by the
// two-call protocol), `lastErrorCode` (its named code, empty for none) and
// `lastErrorStep` (its KOMIRA_STEP_* number, 0 for none; a library older than
// ABI 1.7 has neither call, so the code is empty and the step 0). Misuse of the addon itself (wrong
// argument types, a freed session, a library not loaded, a path with a NUL
// byte) throws TypeError or Error with `code` and no `status`, synchronously,
// before anything is queued.
//
// Sessions. A session is an N-API external over a heap box that holds the
// context handle and the session thread's queue. `freeSession` refuses new
// calls at once and queues the destruction of the context behind the calls
// already made, so a context is never destroyed under a running call; its
// Promise settles once the context is destroyed. Each pending call holds a
// strong reference to the external, so a session is finalized only when no
// call is pending. The external's finalizer destroys the context if
// freeSession has not, after the session thread is stopped and joined, so a
// context is freed exactly once.
#define NAPI_VERSION 8
#include <node_api.h>

#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "arrow_import.h"

#define KOMIRA_OK 0
#define KOMIRA_ERR_NULL_CTX (-1)
#define KOMIRA_ERR_NULL_ARG (-2)
#define KOMIRA_ERR_ENGINE (-3)
#define KOMIRA_ERR_BUFFER_TOO_SMALL (-4)
#define KOMIRA_ERR_TOO_LARGE (-5)

#define ABI_MAJOR 1

// The session thread's stack: the size of a main thread's under the usual
// 8 MiB stack limit, where the calls ran before they moved to this thread.
#define SESSION_STACK_BYTES (8u << 20)

// The library's functions, resolved by `load`. One library per process:
// dlopen of the same file again returns the same handle, so the table is
// process-wide (not per environment) and a worker thread shares it.
typedef struct {
  void *lib;
  char *path;
  int32_t version;  // komira_abi_version(): major * 1000 + minor
  int32_t (*abi_version)(void);
  void *(*ctx_new)(void);
  void *(*ctx_new_with_options)(int64_t, int64_t);  // ABI 1.4; NULL from an older library
  void (*ctx_free)(void *);
  int32_t (*last_error)(void *, uint8_t *, uint64_t, uint64_t *);
  int32_t (*last_error_code)(void *, uint8_t *, uint64_t, uint64_t *);  // ABI 1.7; NULL from an older library
  int32_t (*last_error_step)(void *);  // ABI 1.7; NULL from an older library
  int32_t (*register_parquet)(void *, const char *, const char *);
  int32_t (*parquet_schema)(void *, const char *, uint8_t *, uint64_t, uint64_t *);
  int32_t (*plan_render)(void *, const uint8_t *, uint64_t, uint8_t *, uint64_t, uint64_t *);
} Api;

static Api g_api;
static pthread_mutex_t g_load_lock = PTHREAD_MUTEX_INITIALIZER;
static atomic_bool g_loaded;
static atomic_uint_fast64_t g_created;
static atomic_uint_fast64_t g_freed;

typedef enum { OP_REGISTER, OP_SCHEMA, OP_RENDER, OP_FREE } Op;

// A further freeSession call made while the free was queued: its Promise
// settles with the free's.
typedef struct Waiter {
  struct Waiter *next;
  napi_deferred deferred;
} Waiter;

// One queued call. The JavaScript thread fills the arguments and owns the
// napi_* fields; the session thread fills the outcome; ownership passes with
// the queue and with the thread-safe function's call.
typedef struct Job {
  struct Job *next;
  Op op;
  char *name;  // OP_REGISTER
  char *path;  // OP_REGISTER, OP_SCHEMA
  uint8_t *plan;  // OP_RENDER: a copy of the caller's bytes, never NULL
  uint64_t plan_len;
  // The outcome. `code` set: the addon failed (no status), with `message`.
  // Otherwise `status` is the library's; when it is not zero, `last` is the
  // last error's text, `last_code` its named code and `last_step` its step.
  int32_t status;
  const char *code;
  const char *message;
  char *last;
  char *last_code;
  int32_t last_step;
  uint8_t *out;  // OP_SCHEMA, OP_RENDER: the result bytes
  uint64_t out_len;
  // JavaScript thread only.
  napi_deferred deferred;
  napi_ref keep;     // the session's external, kept alive while the call is pending
  Waiter *waiters;   // OP_FREE
} Job;

typedef struct {
  // Shared with the session thread, under `lock`.
  pthread_mutex_t lock;
  pthread_cond_t wake;
  Job *head, *tail;
  bool stop;
  // The context: the session thread's while it runs, the JavaScript thread's
  // before it starts and after it is joined. NULL once freed.
  void *ctx;
  // JavaScript thread only.
  bool closed;    // freeSession was called: new calls are refused
  bool freed;     // komira_ctx_free ran and its Promise settled
  Job *free_job;  // the queued free, until it settles
  bool started;   // the session thread exists (and `tsfn`)
  pthread_t thread;
  napi_threadsafe_function tsfn;  // NULL before the first call and after its finalizer
  uint32_t pending;  // calls queued and not settled
  int owners;  // the external, and the thread-safe function while it exists
} Session;

// Marks the externals this addon makes, so another addon's external is refused.
static const napi_type_tag g_session_tag = {0x6b6f6d6972612e6eULL, 0x6f64652e73657373ULL};

static const char *status_code(int32_t status) {
  switch (status) {
    case KOMIRA_ERR_NULL_CTX: return "KOMIRA_ERR_NULL_CTX";
    case KOMIRA_ERR_NULL_ARG: return "KOMIRA_ERR_NULL_ARG";
    case KOMIRA_ERR_ENGINE: return "KOMIRA_ERR_ENGINE";
    case KOMIRA_ERR_BUFFER_TOO_SMALL: return "KOMIRA_ERR_BUFFER_TOO_SMALL";
    case KOMIRA_ERR_TOO_LARGE: return "KOMIRA_ERR_TOO_LARGE";
    default: return "KOMIRA_ERR_UNKNOWN";
  }
}

static napi_value fail(napi_env env, const char *code, const char *message) {
  napi_throw_error(env, code, message);
  return NULL;
}

static napi_value fail_type(napi_env env, const char *code, const char *message) {
  napi_throw_type_error(env, code, message);
  return NULL;
}

typedef int32_t (*TextCall)(void *, uint8_t *, uint64_t, uint64_t *);

// The session's last error text (`read` is komira_last_error) or its code
// (komira_last_error_code), read with the two-call protocol. Returns a
// malloc'd NUL-terminated string (empty when there is none, `read` is NULL
// because the library is older than the call, or it cannot be read), or NULL
// when there is no memory for it; the caller frees it.
static char *read_last_text(TextCall read, void *ctx) {
  if (read == NULL) return calloc(1, 1);
  uint64_t n = 0;
  int32_t rc = read(ctx, NULL, 0, &n);
  if (rc == KOMIRA_OK || n == 0) return calloc(1, 1);
  if (rc != KOMIRA_ERR_BUFFER_TOO_SMALL) return calloc(1, 1);
  char *text = malloc((size_t)n + 1);
  if (text == NULL) return calloc(1, 1);
  uint64_t got = 0;
  if (read(ctx, (uint8_t *)text, n, &got) != KOMIRA_OK || got > n) {
    free(text);
    return calloc(1, 1);
  }
  text[got] = '\0';
  return text;
}

// The Error of a failed call `op`: message, `code`, `status`, `lastError`,
// `lastErrorCode` and `lastErrorStep`. NULL if it cannot be made.
static napi_value status_error(napi_env env, const char *op, int32_t status, const char *last,
                               const char *last_code, int32_t last_step) {
  if (last == NULL) last = "";
  if (last_code == NULL) last_code = "";
  size_t cap = strlen(op) + strlen(last) + 64;
  char *message = malloc(cap);
  if (message == NULL) return NULL;
  if (last[0] != '\0') {
    snprintf(message, cap, "%s failed (status %d): %s", op, (int)status, last);
  } else {
    snprintf(message, cap, "%s failed (status %d)", op, (int)status);
  }
  napi_value code, msg, err, status_v, last_v, last_code_v, last_step_v;
  napi_value out = NULL;
  if (napi_create_string_utf8(env, status_code(status), NAPI_AUTO_LENGTH, &code) == napi_ok &&
      napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &msg) == napi_ok &&
      napi_create_error(env, code, msg, &err) == napi_ok &&
      napi_create_int32(env, status, &status_v) == napi_ok &&
      napi_create_string_utf8(env, last, NAPI_AUTO_LENGTH, &last_v) == napi_ok &&
      napi_create_string_utf8(env, last_code, NAPI_AUTO_LENGTH, &last_code_v) == napi_ok &&
      napi_create_int32(env, last_step, &last_step_v) == napi_ok &&
      napi_set_named_property(env, err, "status", status_v) == napi_ok &&
      napi_set_named_property(env, err, "lastError", last_v) == napi_ok &&
      napi_set_named_property(env, err, "lastErrorCode", last_code_v) == napi_ok &&
      napi_set_named_property(env, err, "lastErrorStep", last_step_v) == napi_ok) {
    out = err;
  }
  free(message);
  return out;
}

// An Error with `code` and no `status`. NULL if it cannot be made.
static napi_value code_error(napi_env env, const char *code, const char *message) {
  napi_value code_v, msg, err;
  if (napi_create_string_utf8(env, code, NAPI_AUTO_LENGTH, &code_v) != napi_ok ||
      napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &msg) != napi_ok ||
      napi_create_error(env, code_v, msg, &err) != napi_ok) {
    return NULL;
  }
  return err;
}

static int require_loaded(napi_env env) {
  if (!atomic_load(&g_loaded)) {
    fail(env, "KOMIRA_NOT_LOADED", "libkomira is not loaded: call load(path) first");
    return 0;
  }
  return 1;
}

// The arguments of a call, at most `want` of them; throws if fewer are given.
static int get_args(napi_env env, napi_callback_info info, size_t want, napi_value *argv) {
  size_t argc = want;
  if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok) {
    fail(env, "KOMIRA_NAPI", "cannot read the arguments");
    return 0;
  }
  if (argc < want) {
    fail_type(env, "KOMIRA_ARG", "too few arguments");
    return 0;
  }
  return 1;
}

// A malloc'd NUL-terminated copy of the JavaScript string `v`, or NULL with an
// exception pending. A string with a NUL byte is refused: the C side would
// read a shorter path than the caller wrote.
static char *get_cstring(napi_env env, napi_value v, const char *what) {
  napi_valuetype t;
  if (napi_typeof(env, v, &t) != napi_ok || t != napi_string) {
    char msg[96];
    snprintf(msg, sizeof msg, "%s must be a string", what);
    fail_type(env, "KOMIRA_ARG", msg);
    return NULL;
  }
  size_t len = 0;
  if (napi_get_value_string_utf8(env, v, NULL, 0, &len) != napi_ok) {
    fail(env, "KOMIRA_NAPI", "cannot read a string");
    return NULL;
  }
  char *s = malloc(len + 1);
  if (s == NULL) {
    fail(env, "KOMIRA_ERR_NOMEM", "out of memory");
    return NULL;
  }
  size_t got = 0;
  if (napi_get_value_string_utf8(env, v, s, len + 1, &got) != napi_ok || got != len) {
    free(s);
    fail(env, "KOMIRA_NAPI", "cannot read a string");
    return NULL;
  }
  if (strlen(s) != len) {
    free(s);
    char msg[96];
    snprintf(msg, sizeof msg, "%s must not contain a NUL byte", what);
    fail_type(env, "KOMIRA_ARG", msg);
    return NULL;
  }
  return s;
}

// The Session behind `v` (freed or not), or NULL with an exception pending.
static Session *get_box(napi_env env, napi_value v) {
  napi_valuetype t;
  bool tagged = false;
  if (napi_typeof(env, v, &t) != napi_ok || t != napi_external ||
      napi_check_object_type_tag(env, v, &g_session_tag, &tagged) != napi_ok || !tagged) {
    fail_type(env, "KOMIRA_ARG", "session must be a value returned by newSession()");
    return NULL;
  }
  void *p = NULL;
  if (napi_get_value_external(env, v, &p) != napi_ok || p == NULL) {
    fail(env, "KOMIRA_NAPI", "cannot read a session");
    return NULL;
  }
  return p;
}

// The Session behind `v` that takes calls (freeSession not called on it), or
// NULL with an exception pending.
static Session *get_session(napi_env env, napi_value v) {
  Session *s = get_box(env, v);
  if (s == NULL) return NULL;
  if (s->closed) {
    fail(env, "KOMIRA_SESSION_FREED", "the session was freed");
    return NULL;
  }
  return s;
}

// ---- load, abiVersion -------------------------------------------------------

// The symbol `name`, which ABI 1.`minor` added, of a library of `version`:
// required when the library's minor includes it, else NULL when it is missing.
static int resolve_since(napi_env env, void *lib, int32_t version, int32_t minor, const char *name, void **out) {
  *out = dlsym(lib, name);
  if (*out == NULL && version % 1000 >= minor) {
    char msg[160];
    snprintf(msg, sizeof msg, "libkomira has no symbol %s", name);
    fail(env, "KOMIRA_MISSING_SYMBOL", msg);
    return 0;
  }
  return 1;
}

static int resolve(napi_env env, void *lib, const char *name, void **out) {
  return resolve_since(env, lib, 0, 0, name, out);
}

static napi_value js_load(napi_env env, napi_callback_info info) {
  napi_value argv[1];
  if (!get_args(env, info, 1, argv)) return NULL;
  char *path = get_cstring(env, argv[0], "the library path");
  if (path == NULL) return NULL;
  pthread_mutex_lock(&g_load_lock);
  napi_value result = NULL;
  if (atomic_load(&g_loaded)) {
    // One library per process: a second load of the same path is a no-op, and
    // of another path is refused rather than ignored.
    if (strcmp(path, g_api.path) != 0) {
      fail(env, "KOMIRA_LOADED", "libkomira is already loaded from another path");
    } else if (napi_get_undefined(env, &result) != napi_ok) {
      result = NULL;
    }
    goto done;
  }
  void *lib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (lib == NULL) {
    const char *why = dlerror();
    char msg[512];
    snprintf(msg, sizeof msg, "cannot load libkomira: %s", why != NULL ? why : "unknown error");
    fail(env, "KOMIRA_LOAD_FAILED", msg);
    goto done;
  }
  Api api;
  memset(&api, 0, sizeof api);
  api.lib = lib;
  void *fn;
  if (!resolve(env, lib, "komira_abi_version", &fn)) goto closed;
  api.abi_version = (int32_t(*)(void))fn;
  int32_t version = api.abi_version();
  if (version / 1000 != ABI_MAJOR) {
    char msg[160];
    snprintf(msg, sizeof msg, "libkomira has ABI version %d.%d; this addon needs major %d",
             (int)(version / 1000), (int)(version % 1000), ABI_MAJOR);
    fail(env, "KOMIRA_ABI_MISMATCH", msg);
    goto closed;
  }
  api.version = version;
  if (!resolve(env, lib, "komira_ctx_new", &fn)) goto closed;
  api.ctx_new = (void *(*)(void))fn;
  if (!resolve_since(env, lib, version, 4, "komira_ctx_new_with_options", &fn)) goto closed;
  api.ctx_new_with_options = (void *(*)(int64_t, int64_t))fn;
  if (!resolve(env, lib, "komira_ctx_free", &fn)) goto closed;
  api.ctx_free = (void (*)(void *))fn;
  if (!resolve(env, lib, "komira_last_error", &fn)) goto closed;
  api.last_error = (int32_t(*)(void *, uint8_t *, uint64_t, uint64_t *))fn;
  if (!resolve_since(env, lib, version, 7, "komira_last_error_code", &fn)) goto closed;
  api.last_error_code = (int32_t(*)(void *, uint8_t *, uint64_t, uint64_t *))fn;
  if (!resolve_since(env, lib, version, 7, "komira_last_error_step", &fn)) goto closed;
  api.last_error_step = (int32_t(*)(void *))fn;
  if (!resolve(env, lib, "komira_register_parquet", &fn)) goto closed;
  api.register_parquet = (int32_t(*)(void *, const char *, const char *))fn;
  if (!resolve(env, lib, "komira_parquet_schema", &fn)) goto closed;
  api.parquet_schema = (int32_t(*)(void *, const char *, uint8_t *, uint64_t, uint64_t *))fn;
  if (!resolve(env, lib, "komira_plan_render", &fn)) goto closed;
  api.plan_render =
      (int32_t(*)(void *, const uint8_t *, uint64_t, uint8_t *, uint64_t, uint64_t *))fn;
  api.path = path;
  path = NULL;
  g_api = api;
  atomic_store(&g_loaded, true);
  if (napi_get_undefined(env, &result) != napi_ok) result = NULL;
  goto done;
closed:
  // A refused library stays mapped, like an accepted one: komira_abi_version
  // is Mojo code and may have started the runtime, which cannot be unloaded.
done:
  pthread_mutex_unlock(&g_load_lock);
  free(path);
  return result;
}

static napi_value js_abi_version(napi_env env, napi_callback_info info) {
  (void)info;
  if (!require_loaded(env)) return NULL;
  napi_value out;
  if (napi_create_int32(env, g_api.abi_version(), &out) != napi_ok) return NULL;
  return out;
}

// ---- the session thread -----------------------------------------------------

static void free_job(Job *j) {
  free(j->name);
  free(j->path);
  free(j->plan);
  free(j->last);
  free(j->last_code);
  free(j->out);
  for (Waiter *w = j->waiters; w != NULL;) {
    Waiter *next = w->next;
    free(w);
    w = next;
  }
  free(j);
}

static void free_ctx(Session *s) {
  if (s->ctx != NULL) {
    g_api.ctx_free(s->ctx);
    s->ctx = NULL;
    atomic_fetch_add(&g_freed, 1);
  }
}

static int32_t two_call_step(Session *s, Job *j, uint8_t *buf, uint64_t cap, uint64_t *n) {
  return j->op == OP_SCHEMA ? g_api.parquet_schema(s->ctx, j->path, buf, cap, n)
                            : g_api.plan_render(s->ctx, j->plan, j->plan_len, buf, cap, n);
}

// The bytes of a call that follows the two-call protocol: the first call
// (capacity 0) learns the length, the second fills a buffer of exactly that
// size.
static void run_two_call(Session *s, Job *j) {
  uint64_t n = 0;
  int32_t rc = two_call_step(s, j, NULL, 0, &n);
  if (rc != KOMIRA_OK && rc != KOMIRA_ERR_BUFFER_TOO_SMALL) {
    j->status = rc;
    return;
  }
  if (n > 0) {
    j->out = malloc((size_t)n);
    if (j->out == NULL) {
      j->code = "KOMIRA_ERR_NOMEM";
      j->message = "cannot allocate the result";
      return;
    }
    uint64_t got = 0;
    rc = two_call_step(s, j, j->out, n, &got);
    if (rc != KOMIRA_OK) {
      j->status = rc;
      return;
    }
    if (got != n) {
      j->code = "KOMIRA_ERR_LENGTH";
      j->message = "the result changed length between the two calls";
      return;
    }
  }
  j->out_len = n;
}

// Runs one call on the session thread and records its outcome in `j`.
static void run_job(Session *s, Job *j) {
  switch (j->op) {
    case OP_REGISTER:
      j->status = g_api.register_parquet(s->ctx, j->name, j->path);
      break;
    case OP_SCHEMA:
    case OP_RENDER:
      run_two_call(s, j);
      break;
    case OP_FREE:
      free_ctx(s);
      return;
  }
  if (j->code == NULL && j->status != KOMIRA_OK) {
    j->last = read_last_text(g_api.last_error, s->ctx);
    j->last_code = read_last_text(g_api.last_error_code, s->ctx);
    j->last_step = g_api.last_error_step != NULL ? g_api.last_error_step(s->ctx) : 0;
  }
}

// The session thread: runs the queued calls in order until it is stopped or
// has destroyed the context (nothing is queued after the free).
static void *session_main(void *arg) {
  Session *s = arg;
  pthread_mutex_lock(&s->lock);
  for (;;) {
    while (!s->stop && s->head == NULL) pthread_cond_wait(&s->wake, &s->lock);
    if (s->stop) break;
    Job *j = s->head;
    s->head = j->next;
    if (s->head == NULL) s->tail = NULL;
    j->next = NULL;
    pthread_mutex_unlock(&s->lock);
    run_job(s, j);
    bool last = j->op == OP_FREE;
    // The call fails only while the environment is torn down, when nothing
    // can settle the Promise any more; the job is then this thread's to free.
    if (napi_call_threadsafe_function(s->tsfn, j, napi_tsfn_nonblocking) != napi_ok) free_job(j);
    if (last) return NULL;
    pthread_mutex_lock(&s->lock);
  }
  pthread_mutex_unlock(&s->lock);
  return NULL;
}

static void drop_owner(Session *s) {
  if (--s->owners > 0) return;
  pthread_cond_destroy(&s->wake);
  pthread_mutex_destroy(&s->lock);
  free(s);
}

// Stops the session thread and waits for it: it finishes the call it is
// running, if any, and runs nothing more. Jobs still queued (only when the
// environment is torn down) are freed unrun.
static void stop_thread(Session *s) {
  pthread_mutex_lock(&s->lock);
  s->stop = true;
  pthread_cond_signal(&s->wake);
  pthread_mutex_unlock(&s->lock);
  pthread_join(s->thread, NULL);
  // Joined: no other thread reads `stop`, and a later first call starts afresh.
  s->stop = false;
  s->started = false;
  for (Job *j = s->head; j != NULL;) {
    Job *next = j->next;
    free_job(j);
    j = next;
  }
  s->head = s->tail = NULL;
}

// The thread-safe function's finalizer, on the JavaScript thread: after the
// external's finalizer released it, or when the environment is torn down
// (then possibly while a call runs, which it waits for).
static void finalize_tsfn(napi_env env, void *data, void *hint) {
  (void)env;
  (void)hint;
  Session *s = data;
  if (s->started) stop_thread(s);
  free_ctx(s);
  s->tsfn = NULL;
  drop_owner(s);
}

// The Value a settled job resolves with, or the Error it rejects with
// (`*reject`). NULL if neither can be made.
static napi_value outcome(napi_env env, Job *j, bool *reject) {
  static const char *const ops[] = {"komira_register_parquet", "komira_parquet_schema",
                                    "komira_plan_render", "komira_ctx_free"};
  napi_value v = NULL;
  *reject = true;
  if (j->code != NULL) return code_error(env, j->code, j->message);
  if (j->status != KOMIRA_OK) return status_error(env, ops[j->op], j->status, j->last, j->last_code, j->last_step);
  *reject = false;
  switch (j->op) {
    case OP_REGISTER:
    case OP_FREE:
      if (napi_get_undefined(env, &v) != napi_ok) v = NULL;
      break;
    case OP_SCHEMA: {
      void *copy = NULL;
      if (napi_create_buffer_copy(env, (size_t)j->out_len, j->out != NULL ? j->out : (void *)"", &copy, &v) !=
          napi_ok) {
        v = NULL;
      }
      break;
    }
    case OP_RENDER:
      if (napi_create_string_utf8(env, j->out != NULL ? (const char *)j->out : "", (size_t)j->out_len, &v) !=
          napi_ok) {
        v = NULL;
      }
      break;
  }
  return v;
}

static void resolve_undefined(napi_env env, napi_deferred d) {
  napi_value u;
  if (napi_get_undefined(env, &u) == napi_ok) napi_resolve_deferred(env, d, u);
}

// The thread-safe function's call, on the JavaScript thread: settles the
// Promise of a job the session thread ran. `env` is NULL while the
// environment is torn down: the job is then only freed.
static void settle(napi_env env, napi_value js_cb, void *context, void *data) {
  (void)js_cb;
  Job *j = data;
  if (env == NULL) {
    free_job(j);
    return;
  }
  Session *s = context;
  bool reject = false;
  napi_value v = outcome(env, j, &reject);
  if (v == NULL) {
    reject = true;
    v = code_error(env, "KOMIRA_NAPI", "cannot make the result");
  }
  if (v != NULL) {
    if (reject) {
      napi_reject_deferred(env, j->deferred, v);
    } else {
      napi_resolve_deferred(env, j->deferred, v);
    }
  }
  if (j->op == OP_FREE) {
    s->freed = true;
    s->free_job = NULL;
    for (Waiter *w = j->waiters; w != NULL; w = w->next) resolve_undefined(env, w->deferred);
  }
  if (--s->pending == 0) napi_unref_threadsafe_function(env, s->tsfn);
  napi_delete_reference(env, j->keep);
  free_job(j);
}

// Starts the session thread and its thread-safe function at the session's
// first call. Returns 0 with an exception pending if either cannot be made.
static int ensure_thread(napi_env env, Session *s) {
  if (s->started) return 1;
  pthread_attr_t attr;
  int rc = pthread_attr_init(&attr);
  if (rc == 0) {
    rc = pthread_attr_setstacksize(&attr, SESSION_STACK_BYTES);
    if (rc == 0) rc = pthread_create(&s->thread, &attr, session_main, s);
    pthread_attr_destroy(&attr);
  }
  if (rc != 0) {
    fail(env, "KOMIRA_ERR_THREAD", "cannot start the session thread");
    return 0;
  }
  s->started = true;
  napi_value name;
  napi_threadsafe_function tsfn = NULL;
  if (napi_create_string_utf8(env, "komira session", NAPI_AUTO_LENGTH, &name) != napi_ok ||
      napi_create_threadsafe_function(env, NULL, NULL, name, 0, 1, s, finalize_tsfn, s, settle, &tsfn) !=
          napi_ok) {
    stop_thread(s);
    fail(env, "KOMIRA_NAPI", "cannot make the session's thread-safe function");
    return 0;
  }
  // The thread reads `tsfn` only after it takes a job from the queue, under
  // the lock the job was queued under.
  pthread_mutex_lock(&s->lock);
  s->tsfn = tsfn;
  pthread_mutex_unlock(&s->lock);
  s->owners++;
  // Referenced again while a call is pending (enqueue).
  napi_unref_threadsafe_function(env, tsfn);
  return 1;
}

// Queues `j` on the session behind `ext` and returns its Promise, or NULL with
// an exception pending (`j` is freed either way on failure).
static napi_value enqueue(napi_env env, napi_value ext, Session *s, Job *j) {
  if (!ensure_thread(env, s)) {
    free_job(j);
    return NULL;
  }
  napi_value promise;
  if (napi_create_reference(env, ext, 1, &j->keep) != napi_ok) {
    free_job(j);
    return fail(env, "KOMIRA_NAPI", "cannot hold the session");
  }
  if (napi_create_promise(env, &j->deferred, &promise) != napi_ok) {
    napi_delete_reference(env, j->keep);
    free_job(j);
    return fail(env, "KOMIRA_NAPI", "cannot make a promise");
  }
  if (s->pending++ == 0) napi_ref_threadsafe_function(env, s->tsfn);
  pthread_mutex_lock(&s->lock);
  if (s->tail != NULL) {
    s->tail->next = j;
  } else {
    s->head = j;
  }
  s->tail = j;
  pthread_cond_signal(&s->wake);
  pthread_mutex_unlock(&s->lock);
  return promise;
}

static Job *new_job(napi_env env, Op op) {
  Job *j = calloc(1, sizeof *j);
  if (j == NULL) fail(env, "KOMIRA_ERR_NOMEM", "out of memory");
  if (j != NULL) j->op = op;
  return j;
}

static napi_value resolved(napi_env env) {
  napi_deferred d;
  napi_value promise;
  if (napi_create_promise(env, &d, &promise) != napi_ok) return fail(env, "KOMIRA_NAPI", "cannot make a promise");
  resolve_undefined(env, d);
  return promise;
}

// ---- sessions ---------------------------------------------------------------

// The external's finalizer. No call is pending (each holds the external), so
// the session thread is idle: releasing the thread-safe function lets its
// finalizer stop and join the thread and destroy the context. A session that
// made no call destroys its context here.
static void finalize_session(napi_env env, void *data, void *hint) {
  (void)env;
  (void)hint;
  Session *s = data;
  if (s->tsfn != NULL) {
    napi_release_threadsafe_function(s->tsfn, napi_tsfn_release);
  } else {
    free_ctx(s);
  }
  drop_owner(s);
}

// An engine option argument of newSession: undefined is 0 (the engine's own
// value), else an integer number from 0 to 2**53 - 1, the largest a number
// holds exactly. Returns 0 with an exception pending for anything else.
static int get_option(napi_env env, napi_value v, const char *what, int64_t *out) {
  napi_valuetype t = napi_undefined;
  double d = 0;
  if (napi_typeof(env, v, &t) == napi_ok && t == napi_undefined) {
    *out = 0;
    return 1;
  }
  if (t != napi_number || napi_get_value_double(env, v, &d) != napi_ok || !(d >= 0 && d <= 9007199254740991.0) ||
      d != (double)(int64_t)d) {
    char msg[128];
    snprintf(msg, sizeof msg, "%s must be an integer from 0 to 2**53 - 1", what);
    fail_type(env, "KOMIRA_ARG", msg);
    return 0;
  }
  *out = (int64_t)d;
  return 1;
}

// A new context: komira_ctx_new when both options are 0, else
// komira_ctx_new_with_options. NULL with an exception pending on failure.
static void *new_ctx(napi_env env, int64_t workers, int64_t budget) {
  if (workers == 0 && budget == 0) {
    void *ctx = g_api.ctx_new();
    if (ctx == NULL) fail(env, "KOMIRA_ERR_NOMEM", "komira_ctx_new returned NULL");
    return ctx;
  }
  char msg[4096 + 160];  // the library's path and the numbers
  if (g_api.ctx_new_with_options == NULL) {
    snprintf(msg, sizeof msg, "komira_ctx_new_with_options needs libkomira ABI version %d.4; the library at %s is %d.%d",
             ABI_MAJOR, g_api.path, (int)(g_api.version / 1000), (int)(g_api.version % 1000));
    fail(env, "KOMIRA_ABI_TOO_OLD", msg);
    return NULL;
  }
  void *ctx = g_api.ctx_new_with_options(workers, budget);
  if (ctx == NULL) {
    snprintf(msg, sizeof msg, "komira_ctx_new_with_options returned NULL for %lld workers and a budget of %lld bytes",
             (long long)workers, (long long)budget);
    fail(env, "KOMIRA_CTX_REFUSED", msg);
  }
  return ctx;
}

static napi_value js_new_session(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];  // threads and memoryLimit, each optional
  int64_t workers = 0, budget = 0;
  if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok) return fail(env, "KOMIRA_NAPI", "cannot read the arguments");
  if (!require_loaded(env) || (argc > 0 && !get_option(env, argv[0], "threads", &workers)) ||
      (argc > 1 && !get_option(env, argv[1], "memoryLimit", &budget))) {
    return NULL;
  }
  Session *s = calloc(1, sizeof *s);
  if (s == NULL) return fail(env, "KOMIRA_ERR_NOMEM", "out of memory");
  if (pthread_mutex_init(&s->lock, NULL) != 0) {
    free(s);
    return fail(env, "KOMIRA_ERR_NOMEM", "cannot make the session's lock");
  }
  if (pthread_cond_init(&s->wake, NULL) != 0) {
    pthread_mutex_destroy(&s->lock);
    free(s);
    return fail(env, "KOMIRA_ERR_NOMEM", "cannot make the session's condition");
  }
  s->owners = 1;
  s->ctx = new_ctx(env, workers, budget);
  if (s->ctx == NULL) {
    drop_owner(s);
    return NULL;
  }
  atomic_fetch_add(&g_created, 1);
  napi_value ext = NULL;
  if (napi_create_external(env, s, finalize_session, NULL, &ext) != napi_ok) {
    free_ctx(s);
    drop_owner(s);
    return fail(env, "KOMIRA_NAPI", "cannot make a session");
  }
  // From here the external owns `s` through its finalizer.
  if (napi_type_tag_object(env, ext, &g_session_tag) != napi_ok) {
    return fail(env, "KOMIRA_NAPI", "cannot make a session");
  }
  return ext;
}

// Refuses new calls on the session at once, and returns a Promise that
// settles once the context is destroyed: at once if the session made no call,
// else after every call made before this one.
static napi_value js_free_session(napi_env env, napi_callback_info info) {
  napi_value argv[1];
  if (!get_args(env, info, 1, argv)) return NULL;
  Session *s = get_box(env, argv[0]);
  if (s == NULL) return NULL;
  if (s->freed) return resolved(env);
  if (s->closed) {
    // The free is queued: this Promise settles with it.
    Waiter *w = calloc(1, sizeof *w);
    if (w == NULL) return fail(env, "KOMIRA_ERR_NOMEM", "out of memory");
    napi_value promise;
    if (napi_create_promise(env, &w->deferred, &promise) != napi_ok) {
      free(w);
      return fail(env, "KOMIRA_NAPI", "cannot make a promise");
    }
    w->next = s->free_job->waiters;
    s->free_job->waiters = w;
    return promise;
  }
  if (!s->started) {
    // No call was made: no thread uses the context.
    s->closed = true;
    free_ctx(s);
    s->freed = true;
    return resolved(env);
  }
  Job *j = new_job(env, OP_FREE);
  if (j == NULL) return NULL;
  napi_value promise = enqueue(env, argv[0], s, j);
  if (promise == NULL) return NULL;
  s->closed = true;
  s->free_job = j;
  return promise;
}

static napi_value js_session_stats(napi_env env, napi_callback_info info) {
  (void)info;
  napi_value obj, created, freed;
  if (napi_create_object(env, &obj) != napi_ok ||
      napi_create_double(env, (double)atomic_load(&g_created), &created) != napi_ok ||
      napi_create_double(env, (double)atomic_load(&g_freed), &freed) != napi_ok ||
      napi_set_named_property(env, obj, "created", created) != napi_ok ||
      napi_set_named_property(env, obj, "freed", freed) != napi_ok) {
    return fail(env, "KOMIRA_NAPI", "cannot make the stats");
  }
  return obj;
}

// ---- the operations ---------------------------------------------------------

static napi_value js_register_parquet(napi_env env, napi_callback_info info) {
  napi_value argv[3];
  if (!get_args(env, info, 3, argv) || !require_loaded(env)) return NULL;
  Session *s = get_session(env, argv[0]);
  if (s == NULL) return NULL;
  char *name = get_cstring(env, argv[1], "name");
  if (name == NULL) return NULL;
  char *path = get_cstring(env, argv[2], "path");
  if (path == NULL) {
    free(name);
    return NULL;
  }
  Job *j = new_job(env, OP_REGISTER);
  if (j == NULL) {
    free(name);
    free(path);
    return NULL;
  }
  j->name = name;
  j->path = path;
  return enqueue(env, argv[0], s, j);
}

static napi_value js_parquet_schema(napi_env env, napi_callback_info info) {
  napi_value argv[2];
  if (!get_args(env, info, 2, argv) || !require_loaded(env)) return NULL;
  Session *s = get_session(env, argv[0]);
  if (s == NULL) return NULL;
  char *path = get_cstring(env, argv[1], "path");
  if (path == NULL) return NULL;
  Job *j = new_job(env, OP_SCHEMA);
  if (j == NULL) {
    free(path);
    return NULL;
  }
  j->path = path;
  return enqueue(env, argv[0], s, j);
}

static napi_value js_plan_render(napi_env env, napi_callback_info info) {
  napi_value argv[2];
  if (!get_args(env, info, 2, argv) || !require_loaded(env)) return NULL;
  Session *s = get_session(env, argv[0]);
  if (s == NULL) return NULL;
  bool is_ta = false;
  napi_typedarray_type type;
  size_t length = 0;
  void *data = NULL;
  if (napi_is_typedarray(env, argv[1], &is_ta) != napi_ok || !is_ta ||
      napi_get_typedarray_info(env, argv[1], &type, &length, &data, NULL, NULL) != napi_ok ||
      type != napi_uint8_array) {
    return fail_type(env, "KOMIRA_ARG", "the plan must be a Uint8Array");
  }
  Job *j = new_job(env, OP_RENDER);
  if (j == NULL) return NULL;
  // A copy: the caller may change or drop its array while the call is queued.
  // An empty plan is a one-byte allocation, not NULL: the library refuses a
  // NULL plan as an argument error, but an empty plan is bytes that are not a
  // plan.
  j->plan = malloc(length > 0 ? length : 1);
  if (j->plan == NULL) {
    free_job(j);
    return fail(env, "KOMIRA_ERR_NOMEM", "out of memory");
  }
  if (length > 0) memcpy(j->plan, data, length);
  j->plan_len = (uint64_t)length;
  return enqueue(env, argv[0], s, j);
}

// ---- the module -------------------------------------------------------------

static int export_fn(napi_env env, napi_value exports, const char *name, napi_callback fn) {
  napi_value f;
  return napi_create_function(env, name, NAPI_AUTO_LENGTH, fn, NULL, &f) == napi_ok &&
         napi_set_named_property(env, exports, name, f) == napi_ok;
}

NAPI_MODULE_INIT() {
  if (!export_fn(env, exports, "load", js_load) ||
      !export_fn(env, exports, "abiVersion", js_abi_version) ||
      !export_fn(env, exports, "newSession", js_new_session) ||
      !export_fn(env, exports, "freeSession", js_free_session) ||
      !export_fn(env, exports, "registerParquet", js_register_parquet) ||
      !export_fn(env, exports, "parquetSchema", js_parquet_schema) ||
      !export_fn(env, exports, "planRender", js_plan_render) ||
      !export_fn(env, exports, "sessionStats", js_session_stats) ||
      !arrow_import_export(env, exports)) {
    napi_throw_error(env, NULL, "komira_addon: cannot export its functions");
    return NULL;
  }
  return exports;
}
