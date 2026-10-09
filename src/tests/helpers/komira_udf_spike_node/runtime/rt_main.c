/*
 * The Node runtime as a Node-API addon (docs/design/udf_runtime_interface.md
 * section 5.3). Test-only spike code. The same file is the module a script
 * loads with require() and the library an engine dlopens for the symbol
 * komira_udf_runtime_init_v1 (rt_table.c): node loads the library first, so
 * the engine's dlopen finds it already mapped and the two share this
 * file's globals.
 *
 * The addon is context-aware (NAPI_MODULE_INIT runs once per environment: the
 * main thread and each worker_threads thread that loads it). Each
 * environment's state is `struct env_state`, kept as instance data
 * (napi_set_instance_data), never in a global, so two environments never
 * share it and its finalizer frees it with the environment.
 *
 * What a script does:
 *   const addon = require('./runtime_shared.node');
 *   const adapter = require('./adapter.js').create(addon, ...);
 *   addon.attachMain(adapter, codeDir, addonPath);   // main thread
 * and, in the workers build, worker.js does the same with attachWorker for
 * the slot it was started for.
 *
 * FFI-BOUNDARY. Node owns the napi_env, napi_value and napi_ref values this
 * file touches, and only on the environment's own thread. The env_state is
 * calloc'd here and freed by its instance-data finalizer. The threadsafe
 * function belongs to Node and is released by close_context (workers) or by
 * detach (main).
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "rt_internal.h"

struct rt_stats g_stats;
pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
pthread_cond_t g_cv = PTHREAD_COND_INITIALIZER;
struct env_state* g_envs = NULL;
struct env_state* g_main = NULL;
int g_copy_mode = 0;
int g_detach_ok = 0;
char g_code_dir[1024] = "";
char g_addon_path[1024] = "";
int64_t g_fail_slot = -1;
char g_fail_msg[256] = "";
static int64_t g_finalized = 0; /* env_states freed by their finalizer */

/* The attached worker environment of `slot`; g_mu held. */
struct env_state* rt_find_slot(uint32_t slot) {
  for (struct env_state* e = g_envs; e != NULL; e = e->next)
    if (!e->is_main && e->attached && e->slot == slot) return e;
  return NULL;
}

static struct env_state* get_es(napi_env env) {
  void* data = NULL;
  if (napi_get_instance_data(env, &data) != napi_ok) return NULL;
  return data;
}

static napi_value throw_msg(napi_env env, const char* msg) {
  napi_throw_error(env, NULL, msg);
  return NULL;
}

/* ---- instance data -------------------------------------------------------- */

static void free_es(napi_env env, void* data, void* hint) {
  (void)hint;
  struct env_state* es = data;
  pthread_mutex_lock(&g_mu);
  for (struct env_state** p = &g_envs; *p != NULL; p = &(*p)->next)
    if (*p == es) {
      *p = es->next;
      break;
    }
  if (g_main == es) g_main = NULL;
  pthread_cond_broadcast(&g_cv);
  pthread_mutex_unlock(&g_mu);
  if (es->adapter != NULL) napi_delete_reference(env, es->adapter);
  for (size_t i = 0; i < sizeof(es->fn) / sizeof(es->fn[0]); i++)
    if (es->fn[i] != NULL) napi_delete_reference(env, es->fn[i]);
  free(es);
  __atomic_fetch_add(&g_finalized, 1, __ATOMIC_RELAXED);
}

/* ---- attaching ------------------------------------------------------------ */

static int string_arg(napi_env env, napi_value v, char* into, size_t cap) {
  size_t n = 0;
  if (napi_get_value_string_utf8(env, v, into, cap, &n) != napi_ok) return 0;
  return n < cap - 1 || into[n] == 0;
}

/* attachMain(adapter, codeDir, addonPath) and attachWorker(adapter, slot,
 * codeDir, addonPath) */
static napi_value attach(napi_env env, napi_callback_info info, int is_main) {
  size_t argc = 4;
  napi_value argv[4];
  if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok) return throw_msg(env, "attach: bad call");
  size_t want = is_main ? 3 : 4;
  if (argc < want) return throw_msg(env, "attach: too few arguments");
  struct env_state* es = get_es(env);
  if (es == NULL) return throw_msg(env, "attach: this environment has no instance data");
  if (es->attached) return throw_msg(env, "attach: this environment is attached already");
  uint32_t slot = 0;
  size_t k = 1;
  if (!is_main) {
    if (napi_get_value_uint32(env, argv[k++], &slot) != napi_ok) return throw_msg(env, "attach: slot is not a number");
  }
  char code_dir[sizeof(g_code_dir)], addon_path[sizeof(g_addon_path)];
  if (!string_arg(env, argv[k], code_dir, sizeof(code_dir)) || !string_arg(env, argv[k + 1], addon_path, sizeof(addon_path)))
    return throw_msg(env, "attach: codeDir and addonPath must be strings that fit");
  if (napi_create_reference(env, argv[0], 1, &es->adapter) != napi_ok) return throw_msg(env, "attach: cannot hold the adapter");
  napi_value name;
  napi_create_string_utf8(env, "komira_udf_node", NAPI_AUTO_LENGTH, &name);
  if (napi_create_threadsafe_function(env, NULL, NULL, name, 0, 1, NULL, NULL, es, rt_dispatch, &es->tsfn) != napi_ok)
    return throw_msg(env, "attach: cannot create the threadsafe function");
  /* The main environment must not stay alive just for this function. A
   * worker lives exactly as long as its function is referenced. */
  if (is_main) napi_unref_threadsafe_function(env, es->tsfn);
  es->thread = pthread_self();
  es->is_main = is_main;
  es->slot = slot;
  pthread_mutex_lock(&g_mu);
  int first = g_envs == NULL && g_main == NULL;
  snprintf(g_code_dir, sizeof(g_code_dir), "%s", code_dir);
  snprintf(g_addon_path, sizeof(g_addon_path), "%s", addon_path);
  es->attached = 1;
  es->next = g_envs;
  g_envs = es;
  if (is_main) g_main = es;
  if (g_fail_slot == (int64_t)slot && !is_main) g_fail_slot = -1;
  pthread_cond_broadcast(&g_cv);
  pthread_mutex_unlock(&g_mu);
  if (first) {
    /* Decided once, before the first call: whether an external ArrayBuffer
     * can be detached. Detaching is how the runtime makes a view the user
     * kept harmless when it releases the engine's array at return. */
    g_detach_ok = rt_probe_detach(env);
    if (!g_detach_ok) g_copy_mode = 1;
  }
  return NULL;
}

static napi_value attach_main(napi_env env, napi_callback_info info) { return attach(env, info, 1); }
static napi_value attach_worker(napi_env env, napi_callback_info info) { return attach(env, info, 0); }

/* detach(): the main environment stops taking calls. */
static napi_value detach(napi_env env, napi_callback_info info) {
  (void)info;
  struct env_state* es = get_es(env);
  if (es == NULL || !es->attached) return NULL;
  pthread_mutex_lock(&g_mu);
  es->attached = 0;
  if (g_main == es) g_main = NULL;
  pthread_mutex_unlock(&g_mu);
  napi_release_threadsafe_function(es->tsfn, napi_tsfn_release);
  return NULL;
}

/* workerFailed(slot, message): the main environment could not start a worker. */
static napi_value worker_failed(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  uint32_t slot = 0;
  if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc < 2) return NULL;
  napi_get_value_uint32(env, argv[0], &slot);
  pthread_mutex_lock(&g_mu);
  g_fail_slot = slot;
  if (!string_arg(env, argv[1], g_fail_msg, sizeof(g_fail_msg))) snprintf(g_fail_msg, sizeof(g_fail_msg), "the worker failed");
  pthread_cond_broadcast(&g_cv);
  pthread_mutex_unlock(&g_mu);
  return NULL;
}

/* ---- small observers ------------------------------------------------------ */

static napi_value int_value(napi_env env, int64_t v) {
  napi_value out;
  napi_create_int64(env, v, &out);
  return out;
}

static void set_int(napi_env env, napi_value obj, const char* key, int64_t v) {
  napi_set_named_property(env, obj, key, int_value(env, v));
}

/* stats(): the counters of this process. */
static napi_value stats(napi_env env, napi_callback_info info) {
  (void)info;
  napi_value o;
  napi_create_object(env, &o);
  set_int(env, o, "externalWraps", __atomic_load_n(&g_stats.external_wraps, __ATOMIC_RELAXED));
  set_int(env, o, "copyWraps", __atomic_load_n(&g_stats.copy_wraps, __ATOMIC_RELAXED));
  set_int(env, o, "detaches", __atomic_load_n(&g_stats.detaches, __ATOMIC_RELAXED));
  set_int(env, o, "detachFailures", __atomic_load_n(&g_stats.detach_failures, __ATOMIC_RELAXED));
  set_int(env, o, "wrappedBytes", __atomic_load_n(&g_stats.wrapped_bytes, __ATOMIC_RELAXED));
  set_int(env, o, "calls", __atomic_load_n(&g_stats.calls, __ATOMIC_RELAXED));
  set_int(env, o, "requests", __atomic_load_n(&g_stats.requests, __ATOMIC_RELAXED));
  set_int(env, o, "outputCopiedBytes", __atomic_load_n(&g_stats.outputs_copied_bytes, __ATOMIC_RELAXED));
  set_int(env, o, "pulls", __atomic_load_n(&g_stats.pulls, __ATOMIC_RELAXED));
  set_int(env, o, "copyMode", g_copy_mode);
  set_int(env, o, "detachOk", g_detach_ok);
  set_int(env, o, "envsFinalized", __atomic_load_n(&g_finalized, __ATOMIC_RELAXED));
  return o;
}

/* setCopyMode(bool): arguments are copied into V8 memory instead of wrapped
 * (the path a Node built with the V8 sandbox takes); tests force it. */
static napi_value set_copy_mode(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  bool on = false;
  if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc < 1) return NULL;
  napi_get_value_bool(env, argv[0], &on);
  g_copy_mode = on ? 1 : !g_detach_ok;
  return NULL;
}

/* envCalls(): how many times this environment has called it, from the
 * environment's own instance data (the context-aware test). */
static napi_value env_calls(napi_env env, napi_callback_info info) {
  (void)info;
  struct env_state* es = get_es(env);
  if (es == NULL) return throw_msg(env, "envCalls: this environment has no instance data");
  es->env_calls += 1;
  return int_value(env, es->env_calls);
}

static napi_value is_attached(napi_env env, napi_callback_info info) {
  (void)info;
  struct env_state* es = get_es(env);
  napi_value out;
  napi_get_boolean(env, es != NULL && es->attached, &out);
  return out;
}

static int export_fn(napi_env env, napi_value exports, const char* name, napi_callback cb) {
  napi_value fn;
  if (napi_create_function(env, name, NAPI_AUTO_LENGTH, cb, NULL, &fn) != napi_ok) return 0;
  return napi_set_named_property(env, exports, name, fn) == napi_ok;
}

NAPI_MODULE_INIT() {
  struct env_state* es = calloc(1, sizeof(*es));
  if (es == NULL) return throw_msg(env, "komira_udf_node: out of memory");
  es->env = env;
  es->thread = pthread_self();
  if (napi_set_instance_data(env, es, free_es, NULL) != napi_ok) {
    free(es);
    return throw_msg(env, "komira_udf_node: napi_set_instance_data failed");
  }
  if (!export_fn(env, exports, "attachMain", attach_main) || !export_fn(env, exports, "attachWorker", attach_worker) ||
      !export_fn(env, exports, "detach", detach) || !export_fn(env, exports, "workerFailed", worker_failed) ||
      !export_fn(env, exports, "stats", stats) || !export_fn(env, exports, "setCopyMode", set_copy_mode) ||
      !export_fn(env, exports, "envCalls", env_calls) || !export_fn(env, exports, "isAttached", is_attached) ||
      !export_fn(env, exports, "interrupted", rt_native_interrupted) || !export_fn(env, exports, "nowNs", rt_native_now_ns) ||
      !export_fn(env, exports, "probeWrap", rt_probe_wrap) || !export_fn(env, exports, "probeFinalized", rt_probe_finalized) ||
      !export_fn(env, exports, "probeWrapMany", rt_probe_wrap_many))
    return throw_msg(env, "komira_udf_node: cannot export its functions");
  return exports;
}
