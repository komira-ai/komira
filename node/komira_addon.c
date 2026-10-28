// The Node-API addon over libkomira, komira's one shared library with a flat C
// ABI (src/komira_so). It is built by node_addon (BUCK, `komira_addon`) with
// every napi_* symbol left undefined for node to resolve, and it exposes the
// library to JavaScript:
//
//   load(libraryPath)                  open libkomira from `libraryPath`
//   abiVersion()                       the library's komira_abi_version()
//   newSession()                       a session handle (an external)
//   freeSession(session)               destroy it; calling it again is a no-op
//   registerParquet(session, name, path)
//   parquetSchema(session, path)       Buffer: the file's schema as komira.plan.v1 WireSchema bytes
//   planRender(session, bytes)         string: the text of a serialized plan; the plan is not run
//   sessionStats()                     { created, freed }: komira_ctx_new and komira_ctx_free calls made here
//
// Why the library is opened with dlopen at `load`, and is not a NEEDED
// dependency with a run path. libkomira is a Mojo shared library: it needs the
// Mojo runtime and its native owners beside it (lib/), and the build offers it
// as a directory (`libkomira[runnable]`), not as a link input to a C target.
// A NEEDED edge would fix the library's place at build time and make a missing
// or wrong library a loader error before any JavaScript runs. With dlopen the
// host gives the path, the addon checks `komira_abi_version` (major 1) and
// names a missing symbol, and every failure is a JavaScript Error. The library
// is never dlclose'd: the Mojo runtime does not support unloading, and a
// session finalizer may run late.
//
// Errors. A call that gets a non-zero status throws an Error with `status`
// (the number), `code` (the KOMIRA_ERR_* name) and `lastError` (the session's
// last error text, read with komira_last_error's two-call protocol). Misuse of
// the addon itself (wrong argument types, a freed session, a library not
// loaded, a path with a NUL byte) throws TypeError or Error with `code` and no
// `status`.
//
// Sessions. A session is an N-API external over a heap box that holds the
// context handle. The external's finalizer destroys the context if
// freeSession has not, so a context is freed exactly once.
#define NAPI_VERSION 8
#include <node_api.h>

#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define KOMIRA_OK 0
#define KOMIRA_ERR_NULL_CTX (-1)
#define KOMIRA_ERR_NULL_ARG (-2)
#define KOMIRA_ERR_ENGINE (-3)
#define KOMIRA_ERR_BUFFER_TOO_SMALL (-4)
#define KOMIRA_ERR_TOO_LARGE (-5)

#define ABI_MAJOR 1

// The library's functions, resolved by `load`. One library per process:
// dlopen of the same file again returns the same handle, so the table is
// process-wide (not per environment) and a worker thread shares it.
typedef struct {
  void *lib;
  char *path;
  int32_t (*abi_version)(void);
  void *(*ctx_new)(void);
  void (*ctx_free)(void *);
  int32_t (*last_error)(void *, uint8_t *, uint64_t, uint64_t *);
  int32_t (*register_parquet)(void *, const char *, const char *);
  int32_t (*parquet_schema)(void *, const char *, uint8_t *, uint64_t, uint64_t *);
  int32_t (*plan_render)(void *, const uint8_t *, uint64_t, uint8_t *, uint64_t, uint64_t *);
} Api;

static Api g_api;
static pthread_mutex_t g_load_lock = PTHREAD_MUTEX_INITIALIZER;
static atomic_bool g_loaded;
static atomic_uint_fast64_t g_created;
static atomic_uint_fast64_t g_freed;

typedef struct {
  void *ctx;  // NULL once freed
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

// The session's last error text, read with the two-call protocol. Returns a
// malloc'd NUL-terminated string (empty when there is none or it cannot be
// read); the caller frees it.
static char *read_last_error(void *ctx) {
  uint64_t n = 0;
  int32_t rc = g_api.last_error(ctx, NULL, 0, &n);
  if (rc == KOMIRA_OK || n == 0) return calloc(1, 1);
  if (rc != KOMIRA_ERR_BUFFER_TOO_SMALL) return calloc(1, 1);
  char *text = malloc((size_t)n + 1);
  if (text == NULL) return calloc(1, 1);
  uint64_t got = 0;
  if (g_api.last_error(ctx, (uint8_t *)text, n, &got) != KOMIRA_OK || got > n) {
    free(text);
    return calloc(1, 1);
  }
  text[got] = '\0';
  return text;
}

// Throws the Error for a failed call `op`: message, `code`, `status` and
// `lastError`. Always returns NULL.
static napi_value throw_status(napi_env env, const char *op, int32_t status, void *ctx) {
  char *last = read_last_error(ctx);
  size_t cap = strlen(op) + strlen(last) + 64;
  char *message = malloc(cap);
  if (message == NULL) {
    free(last);
    return fail(env, "KOMIRA_ERR_NOMEM", "out of memory");
  }
  if (last[0] != '\0') {
    snprintf(message, cap, "%s failed (status %d): %s", op, (int)status, last);
  } else {
    snprintf(message, cap, "%s failed (status %d)", op, (int)status);
  }
  napi_value code, msg, err, status_v, last_v;
  if (napi_create_string_utf8(env, status_code(status), NAPI_AUTO_LENGTH, &code) == napi_ok &&
      napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &msg) == napi_ok &&
      napi_create_error(env, code, msg, &err) == napi_ok &&
      napi_create_int32(env, status, &status_v) == napi_ok &&
      napi_create_string_utf8(env, last, NAPI_AUTO_LENGTH, &last_v) == napi_ok &&
      napi_set_named_property(env, err, "status", status_v) == napi_ok &&
      napi_set_named_property(env, err, "lastError", last_v) == napi_ok) {
    napi_throw(env, err);
  } else {
    fail(env, status_code(status), message);
  }
  free(message);
  free(last);
  return NULL;
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

// The live Session behind `v`, or NULL with an exception pending.
static Session *get_session(napi_env env, napi_value v) {
  Session *s = get_box(env, v);
  if (s == NULL) return NULL;
  if (s->ctx == NULL) {
    fail(env, "KOMIRA_SESSION_FREED", "the session was freed");
    return NULL;
  }
  return s;
}

// ---- load, abiVersion -------------------------------------------------------

static int resolve(napi_env env, void *lib, const char *name, void **out) {
  *out = dlsym(lib, name);
  if (*out == NULL) {
    char msg[160];
    snprintf(msg, sizeof msg, "libkomira has no symbol %s", name);
    fail(env, "KOMIRA_MISSING_SYMBOL", msg);
    return 0;
  }
  return 1;
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
  if (!resolve(env, lib, "komira_ctx_new", &fn)) goto closed;
  api.ctx_new = (void *(*)(void))fn;
  if (!resolve(env, lib, "komira_ctx_free", &fn)) goto closed;
  api.ctx_free = (void (*)(void *))fn;
  if (!resolve(env, lib, "komira_last_error", &fn)) goto closed;
  api.last_error = (int32_t(*)(void *, uint8_t *, uint64_t, uint64_t *))fn;
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

// ---- sessions ---------------------------------------------------------------

static void finalize_session(napi_env env, void *data, void *hint) {
  (void)env;
  (void)hint;
  Session *s = data;
  if (s->ctx != NULL) {
    g_api.ctx_free(s->ctx);
    s->ctx = NULL;
    atomic_fetch_add(&g_freed, 1);
  }
  free(s);
}

static napi_value js_new_session(napi_env env, napi_callback_info info) {
  (void)info;
  if (!require_loaded(env)) return NULL;
  Session *s = malloc(sizeof *s);
  if (s == NULL) return fail(env, "KOMIRA_ERR_NOMEM", "out of memory");
  s->ctx = g_api.ctx_new();
  if (s->ctx == NULL) {
    free(s);
    return fail(env, "KOMIRA_ERR_NOMEM", "komira_ctx_new returned NULL");
  }
  atomic_fetch_add(&g_created, 1);
  napi_value ext = NULL;
  if (napi_create_external(env, s, finalize_session, NULL, &ext) != napi_ok ||
      napi_type_tag_object(env, ext, &g_session_tag) != napi_ok) {
    // The external, if made, owns `s` through its finalizer.
    if (s->ctx != NULL && ext == NULL) {
      g_api.ctx_free(s->ctx);
      atomic_fetch_add(&g_freed, 1);
      free(s);
    }
    return fail(env, "KOMIRA_NAPI", "cannot make a session");
  }
  return ext;
}

static napi_value js_free_session(napi_env env, napi_callback_info info) {
  napi_value argv[1];
  if (!get_args(env, info, 1, argv)) return NULL;
  Session *s = get_box(env, argv[0]);
  if (s == NULL) return NULL;
  if (s->ctx != NULL) {
    g_api.ctx_free(s->ctx);
    s->ctx = NULL;
    atomic_fetch_add(&g_freed, 1);
  }
  napi_value out;
  if (napi_get_undefined(env, &out) != napi_ok) return NULL;
  return out;
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
  int32_t rc = g_api.register_parquet(s->ctx, name, path);
  free(name);
  free(path);
  if (rc != KOMIRA_OK) return throw_status(env, "komira_register_parquet", rc, s->ctx);
  napi_value out;
  if (napi_get_undefined(env, &out) != napi_ok) return NULL;
  return out;
}

// The bytes of a call that follows the two-call protocol, as a Buffer: the
// first call (capacity 0) learns the length, the second fills a Buffer of
// exactly that size. `plan` is NULL for the schema call.
static napi_value two_call(napi_env env, Session *s, const char *op, const char *path,
                           const uint8_t *plan, uint64_t plan_len, uint8_t **raw, uint64_t *raw_len) {
  uint64_t n = 0;
  int32_t rc = path != NULL ? g_api.parquet_schema(s->ctx, path, NULL, 0, &n)
                            : g_api.plan_render(s->ctx, plan, plan_len, NULL, 0, &n);
  if (rc != KOMIRA_OK && rc != KOMIRA_ERR_BUFFER_TOO_SMALL) return throw_status(env, op, rc, s->ctx);
  napi_value buf = NULL;
  void *data = NULL;
  if (napi_create_buffer(env, (size_t)n, &data, &buf) != napi_ok) {
    return fail(env, "KOMIRA_ERR_NOMEM", "cannot allocate the result");
  }
  if (n > 0) {
    uint64_t got = 0;
    rc = path != NULL ? g_api.parquet_schema(s->ctx, path, data, n, &got)
                      : g_api.plan_render(s->ctx, plan, plan_len, data, n, &got);
    if (rc != KOMIRA_OK) return throw_status(env, op, rc, s->ctx);
    if (got != n) return fail(env, "KOMIRA_ERR_LENGTH", "the result changed length between the two calls");
  }
  *raw = data;
  *raw_len = n;
  return buf;
}

static napi_value js_parquet_schema(napi_env env, napi_callback_info info) {
  napi_value argv[2];
  if (!get_args(env, info, 2, argv) || !require_loaded(env)) return NULL;
  Session *s = get_session(env, argv[0]);
  if (s == NULL) return NULL;
  char *path = get_cstring(env, argv[1], "path");
  if (path == NULL) return NULL;
  uint8_t *raw;
  uint64_t raw_len;
  napi_value out = two_call(env, s, "komira_parquet_schema", path, NULL, 0, &raw, &raw_len);
  free(path);
  return out;
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
  // An empty array has no data pointer; the library refuses a NULL plan as an
  // argument error, but an empty plan is bytes that are not a plan.
  static const uint8_t empty = 0;
  const uint8_t *plan = data != NULL ? data : &empty;
  uint8_t *raw;
  uint64_t raw_len;
  napi_value buf = two_call(env, s, "komira_plan_render", NULL, plan, (uint64_t)length, &raw, &raw_len);
  if (buf == NULL) return NULL;
  napi_value text;
  if (napi_create_string_utf8(env, raw_len > 0 ? (const char *)raw : "", (size_t)raw_len, &text) != napi_ok) {
    return fail(env, "KOMIRA_NAPI", "cannot make the text");
  }
  return text;
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
      !export_fn(env, exports, "sessionStats", js_session_stats)) {
    napi_throw_error(env, NULL, "komira_addon: cannot export its functions");
    return NULL;
  }
  return exports;
}
