/*
 * The Node runtime's internal declarations (docs/design/udf_runtime_interface.md
 * section 5.3, "Node requirements"). Test-only spike code.
 *
 * Threads. Two kinds of thread meet in this addon.
 *   - Engine threads call the table (rt_table.c). They never touch V8: they
 *     fill a `struct request`, queue it on the target environment's
 *     threadsafe function and wait for the environment's JavaScript thread
 *     to finish it.
 *   - Each environment's JavaScript thread (the main thread, or one
 *     worker_threads thread) runs `rt_dispatch` (rt_js.c), the only code that
 *     calls Node-API for a request. A `struct env_state` belongs to one
 *     environment, is created by NAPI_MODULE_INIT and freed by the
 *     finalizer of napi_set_instance_data.
 *
 * Process-wide state is the `g_` globals of rt_table.c and rt_main.c: the
 * host table, the registry of attached environments, the counters.
 */
#ifndef KOMIRA_UDF_NODE_RT_INTERNAL_H
#define KOMIRA_UDF_NODE_RT_INTERNAL_H

#define NAPI_VERSION 8
#include <node_api.h>
#include <pthread.h>
#include <stdint.h>

#include "headers/komira_udf_runtime.h" /* the abi package's :headers, staged as headers/ */

#define RT_EXPORT __attribute__((visibility("default")))

/* The two builds of this source (BUCK): KOMIRA_NODE_WORKERS 0 runs every
 * context in the main isolate (the baseline), 1 runs each context in a
 * worker_threads isolate of its own. */
#ifndef KOMIRA_NODE_WORKERS
#define KOMIRA_NODE_WORKERS 0
#endif

/* ---- what the runtime binds a UDF to ------------------------------------ */

/* The Arrow formats this runtime maps: 'i' int32, 'l' int64, 'g' float64. */
struct rt_col {
  char fmt;
  char nullable;
  char* name; /* the field name (a ROW's read set); never NULL */
};

struct komira_udf_udf { /* load: the part of the spec the instances need */
  char* entry;          /* "bundle.js#export" */
  int32_t shape;
  int32_t null_mode;
  int32_t n_args;
  struct rt_col* args;
  int32_t n_res; /* columns of the result: 1 for a column, any number for a table */
  struct rt_col* res;
  int32_t res_is_table;
  struct rt_col state; /* state.fmt 0: none */
};

struct env_state;

struct komira_udf_rt {
  const komira_udf_host* host;
};

struct komira_udf_context {
  struct env_state* es; /* the environment that runs this context */
  uint32_t slot;
  napi_ref obj; /* the JS context object; touched on es's thread only */
  int lost;     /* its isolate was terminated (a cancel that did not stop): the engine thread's flag */
};

struct komira_udf_instance {
  struct komira_udf_context* ctx;
  const struct komira_udf_udf* udf;
  napi_ref obj;
};

struct komira_udf_frame {
  struct komira_udf_instance* inst;
  struct ArrowDeviceArrayStream in; /* moved in; released at frame_close */
  napi_ref obj;
  int64_t pulls; /* batches pulled so far */
};

struct komira_udf_groups {
  struct komira_udf_instance* inst;
  napi_ref obj;
};

/* ---- one request, from an engine thread to an environment ---------------- */

enum rt_op {
  OP_OPEN_CONTEXT = 1,
  OP_CLOSE_CONTEXT,
  OP_OPEN_INSTANCE,
  OP_CLOSE_INSTANCE,
  OP_CALL_BATCH,
  OP_FRAME_OPEN,
  OP_FRAME_NEXT,
  OP_FRAME_CLOSE,
  OP_AGG_OPEN,
  OP_AGG_UPDATE,
  OP_AGG_MERGE,
  OP_AGG_STATE,
  OP_AGG_FINISH,
  OP_AGG_CLOSE,
  OP_MEMORY,
  OP_SPAWN, /* main environment only: start the worker of a slot */
  OP_STOP   /* main environment only: stop the worker of a slot */
};

/* Buffers wrapped for one request (rt_arrow.c): each distinct address once. */
struct wrap_entry {
  const void* ptr;
  size_t bytes;
  napi_ref ab; /* a strong reference to the ArrayBuffer */
  int external; /* wrapped over the engine's memory (to detach), not copied */
};
struct wrap_set {
  struct wrap_entry* e;
  int n, cap;
};

struct request {
  int op;
  struct env_state* es;
  struct komira_udf_context* ctx;
  struct komira_udf_instance* inst;
  struct komira_udf_frame* frame;
  struct komira_udf_groups* groups;
  const struct komira_udf_udf* udf;
  const komira_udf_call* call;
  struct ArrowDeviceArray* args;    /* the struct array of arguments or states */
  struct ArrowDeviceArray* ids;     /* int32 group ids */
  struct ArrowDeviceArray* out;     /* the result, when the op has one */
  uint32_t n_groups;                /* n_groups, emit_first_n or the slot */
  /* Arrays pulled from a frame's input during this request: the engine
   * thread releases them once the request is done (they hold the engine's
   * buffers, which the detach of the wrapped ArrayBuffers has made
   * unreachable by then). */
  struct ArrowDeviceArray* pulled;
  int n_pulled, cap_pulled;
  struct wrap_set wraps;
  /* the answer */
  int32_t status;
  char* message;
  char* trace;
  int64_t row, group;
  int64_t value; /* OP_MEMORY: bytes */
  int output_rows_set;
  /* the handshake */
  pthread_mutex_t mu;
  pthread_cond_t cv;
  int done;
};

/* ---- one environment ----------------------------------------------------- */

struct env_state {
  napi_env env;
  pthread_t thread;
  int is_main;
  int attached;
  uint32_t slot; /* a worker's context slot */
  napi_threadsafe_function tsfn;
  napi_ref adapter; /* the JS adapter object (adapter.js) */
  napi_ref fn[24];  /* the adapter's functions by op, resolved on first use */
  struct request* cur; /* the request being dispatched */
  int64_t env_calls;   /* NAPI_MODULE_INIT's per-environment counter */
  struct env_state* next; /* the registry of attached environments */
};

/* ---- process-wide state (rt_main.c) -------------------------------------- */

struct rt_stats { /* atomic counters, read by stats() */
  int64_t external_wraps, copy_wraps, detaches, detach_failures;
  int64_t wrapped_bytes, calls, requests, outputs_copied_bytes, pulls;
};
extern struct rt_stats g_stats;
extern pthread_mutex_t g_mu; /* guards the registry and the settings below */
extern pthread_cond_t g_cv;  /* signalled when an environment attaches or leaves */
extern struct env_state* g_envs;   /* attached environments */
extern struct env_state* g_main;   /* the main one, or NULL */
extern int g_copy_mode;            /* arguments are copied into V8 memory, not wrapped */
extern int g_detach_ok;            /* probed at the first attach: external buffers detach */
extern char g_code_dir[1024];      /* where adapter.js, worker.js and the bundles live */
extern char g_addon_path[1024];    /* this addon's file, for the workers to load */
extern const komira_udf_host* g_host;
extern int64_t g_fail_slot;        /* a worker that could not start, or -1 */
extern char g_fail_msg[256];

#define STAT_ADD(field, n) __atomic_fetch_add(&g_stats.field, (int64_t)(n), __ATOMIC_RELAXED)

/* rt_main.c */
void rt_complete(struct request* r);
struct env_state* rt_find_slot(uint32_t slot);
int32_t rt_submit(struct env_state* es, struct request* r);
int32_t rt_fail(struct request* r, int32_t status, const char* message);

/* rt_js.c: the tsfn callback and the ops (JavaScript thread only) */
void rt_dispatch(napi_env env, napi_value js_cb, void* context, void* data);
napi_value rt_native_interrupted(napi_env env, napi_callback_info info);
napi_value rt_native_now_ns(napi_env env, napi_callback_info info);

/* rt_arrow.c: Arrow <-> JavaScript (JavaScript thread only) */
int32_t rt_columns_to_js(struct request* r, const struct ArrowArray* st, const struct rt_col* cols, int n_cols,
                         napi_value* out);
int32_t rt_wrap_buffer(struct request* r, const void* ptr, size_t bytes, napi_value* out);
void rt_unwrap_all(struct request* r);
int32_t rt_column_from_js(struct request* r, napi_value col, char fmt, struct ArrowArray* out);
int32_t rt_table_from_js(struct request* r, napi_value table, const struct rt_col* cols, int n_cols,
                         struct ArrowArray* out);
napi_value rt_pull(napi_env env, napi_callback_info info);
int rt_probe_detach(napi_env env);
napi_value rt_probe_wrap(napi_env env, napi_callback_info info);
napi_value rt_probe_wrap_many(napi_env env, napi_callback_info info);
napi_value rt_probe_finalized(napi_env env, napi_callback_info info);

/* rt_table.c */
const komira_udf_runtime* rt_table(void);

#endif
