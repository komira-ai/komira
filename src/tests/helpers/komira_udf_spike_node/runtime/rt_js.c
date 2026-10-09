/*
 * The requests, on an environment's JavaScript thread (design section 5.3:
 * "In-process hands each batch to an isolate"). Test-only spike code.
 *
 * rt_dispatch is the threadsafe function's callback. For one request it
 * builds the JavaScript arguments (column descriptors over the engine's
 * buffers: rt_arrow.c), calls the matching method of the adapter (adapter.js)
 * and turns the answer into the request's status, error and output arrays.
 *
 * The adapter never throws across this boundary on purpose: it answers an
 * array whose first element is the komira_udf_status,
 *   [0, ...payload]                        on success
 *   [status, message, trace|null, row, group]  on failure
 * and an exception that does escape is reported as ERR_INTERNAL, never as
 * user code's.
 *
 * Order matters at the end of a request: the results are copied out of
 * JavaScript memory first (they may be views of the wrapped argument
 * buffers), and only then are the wrapped ArrayBuffers detached
 * (rt_unwrap_all). The engine thread releases the argument arrays after
 * rt_complete.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "rt_internal.h"

static const char* const FN_NAMES[] = {
    [OP_OPEN_CONTEXT] = "openContext", [OP_CLOSE_CONTEXT] = "closeContext", [OP_OPEN_INSTANCE] = "openInstance",
    [OP_CLOSE_INSTANCE] = "closeInstance", [OP_CALL_BATCH] = "callBatch", [OP_FRAME_OPEN] = "frameOpen",
    [OP_FRAME_NEXT] = "frameNext", [OP_FRAME_CLOSE] = "frameClose", [OP_AGG_OPEN] = "aggOpen",
    [OP_AGG_UPDATE] = "aggUpdate", [OP_AGG_MERGE] = "aggMerge", [OP_AGG_STATE] = "aggState",
    [OP_AGG_FINISH] = "aggFinish", [OP_AGG_CLOSE] = "aggClose", [OP_MEMORY] = "memory",
    [OP_SPAWN] = "spawnWorker", [OP_STOP] = "stopWorker",
};

static char* js_string(napi_env env, napi_value v) {
  size_t n = 0;
  if (napi_get_value_string_utf8(env, v, NULL, 0, &n) != napi_ok) return NULL;
  char* s = malloc(n + 1);
  if (s == NULL) return NULL;
  size_t got = 0;
  if (napi_get_value_string_utf8(env, v, s, n + 1, &got) != napi_ok) {
    free(s);
    return NULL;
  }
  s[got] = 0;
  return s;
}

static napi_value str(napi_env env, const char* s) {
  napi_value v;
  napi_create_string_utf8(env, s, NAPI_AUTO_LENGTH, &v);
  return v;
}

static napi_value num(napi_env env, int64_t n) {
  napi_value v;
  napi_create_int64(env, n, &v);
  return v;
}

/* The exception pending after a failed call, as ERR_INTERNAL. */
static int32_t take_exception(struct request* r, const char* what) {
  napi_env env = r->es->env;
  napi_value exc, msg;
  char text[400];
  snprintf(text, sizeof(text), "%s threw an exception the adapter should have caught", what);
  if (napi_get_and_clear_last_exception(env, &exc) == napi_ok) {
    if (napi_get_named_property(env, exc, "message", &msg) == napi_ok) {
      char* m = js_string(env, msg);
      if (m != NULL) {
        snprintf(text, sizeof(text), "%s threw: %s", what, m);
        free(m);
      }
    }
  }
  return rt_fail(r, KOMIRA_UDF_ERR_INTERNAL, text);
}

/* Call adapter.<op>(argv...) and read the answer's status. On success the
 * answer array is in *res and KOMIRA_UDF_OK returned. */
static int32_t call_adapter(struct request* r, napi_value* argv, size_t argc, napi_value* res) {
  struct env_state* es = r->es;
  napi_env env = es->env;
  napi_value adapter, fn;
  if (napi_get_reference_value(env, es->adapter, &adapter) != napi_ok || adapter == NULL)
    return rt_fail(r, KOMIRA_UDF_ERR_INTERNAL, "the adapter is gone");
  if (es->fn[r->op] == NULL) {
    if (napi_get_named_property(env, adapter, FN_NAMES[r->op], &fn) != napi_ok)
      return rt_fail(r, KOMIRA_UDF_ERR_INTERNAL, "the adapter lacks a method of this operation");
    napi_create_reference(env, fn, 1, &es->fn[r->op]);
  } else {
    napi_get_reference_value(env, es->fn[r->op], &fn);
  }
  napi_status s = napi_call_function(env, adapter, fn, argc, argv, res);
  if (s == napi_pending_exception) return take_exception(r, FN_NAMES[r->op]);
  if (s != napi_ok) return rt_fail(r, KOMIRA_UDF_ERR_INTERNAL, "napi_call_function failed");
  bool is_array = false;
  napi_is_array(env, *res, &is_array);
  if (!is_array) return rt_fail(r, KOMIRA_UDF_ERR_INTERNAL, "the adapter answered something that is not an array");
  napi_value v;
  napi_get_element(env, *res, 0, &v);
  int32_t status = 0;
  napi_get_value_int32(env, v, &status);
  if (status == KOMIRA_UDF_OK) return KOMIRA_UDF_OK;
  r->status = status;
  napi_get_element(env, *res, 1, &v);
  free(r->message);
  r->message = js_string(env, v);
  napi_get_element(env, *res, 2, &v);
  napi_valuetype vt;
  napi_typeof(env, v, &vt);
  free(r->trace);
  r->trace = vt == napi_string ? js_string(env, v) : NULL;
  napi_get_element(env, *res, 3, &v);
  int64_t n = -1;
  napi_get_value_int64(env, v, &n);
  r->row = n;
  napi_get_element(env, *res, 4, &v);
  n = -1;
  napi_get_value_int64(env, v, &n);
  r->group = n;
  return status;
}

/* ---- natives the adapter calls ------------------------------------------- */

static struct request* current_request(napi_env env) {
  void* d = NULL;
  napi_get_instance_data(env, &d);
  return d != NULL ? ((struct env_state*)d)->cur : NULL;
}

/* interrupted(): 0, or the status the call must end with: ERR_CANCELLED when
 * the cancel flag is set, ERR_DEADLINE when the deadline passed. It always
 * reads the host's clock once, as the echo runtime's checks do. */
napi_value rt_native_interrupted(napi_env env, napi_callback_info info) {
  (void)info;
  struct request* r = current_request(env);
  int32_t st = 0;
  int64_t now = g_host != NULL ? g_host->now_ns(g_host->host_data) : 0;
  if (r != NULL && r->call != NULL) {
    if (r->call->cancel != NULL && __atomic_load_n(r->call->cancel, __ATOMIC_ACQUIRE) != 0)
      st = KOMIRA_UDF_ERR_CANCELLED;
    else if (r->call->deadline_ns != 0 && now > r->call->deadline_ns)
      st = KOMIRA_UDF_ERR_DEADLINE;
  }
  napi_value out;
  napi_create_int32(env, st, &out);
  return out;
}

/* nowNs(): the host's monotonic clock, in nanoseconds (a double). */
napi_value rt_native_now_ns(napi_env env, napi_callback_info info) {
  (void)info;
  napi_value out;
  napi_create_double(env, g_host != NULL ? (double)g_host->now_ns(g_host->host_data) : 0.0, &out);
  return out;
}

/* ---- the operations ------------------------------------------------------- */

static napi_value ref_value(napi_env env, napi_ref ref) {
  napi_value v = NULL;
  napi_get_reference_value(env, ref, &v);
  return v;
}

/* [[fmt, name, nullable], ...] */
static napi_value cols_desc(napi_env env, const struct rt_col* c, int n) {
  napi_value arr;
  napi_create_array_with_length(env, (size_t)n, &arr);
  for (int i = 0; i < n; i++) {
    char f[2] = {c[i].fmt, 0};
    napi_value e, b;
    napi_create_array_with_length(env, 3, &e);
    napi_set_element(env, e, 0, str(env, f));
    napi_set_element(env, e, 1, str(env, c[i].name));
    napi_get_boolean(env, c[i].nullable != 0, &b);
    napi_set_element(env, e, 2, b);
    napi_set_element(env, arr, (uint32_t)i, e);
  }
  return arr;
}

static napi_value spec_object(napi_env env, const struct komira_udf_udf* u) {
  napi_value o, v;
  napi_create_object(env, &o);
  napi_set_named_property(env, o, "entry", str(env, u->entry));
  napi_set_named_property(env, o, "shape", num(env, u->shape));
  napi_set_named_property(env, o, "nullMode", num(env, u->null_mode));
  napi_set_named_property(env, o, "args", cols_desc(env, u->args, u->n_args));
  napi_set_named_property(env, o, "result", cols_desc(env, u->res, u->n_res));
  napi_get_boolean(env, u->res_is_table != 0, &v);
  napi_set_named_property(env, o, "isTable", v);
  if (u->state.fmt != 0) {
    napi_set_named_property(env, o, "state", cols_desc(env, &u->state, 1));
  } else {
    napi_get_null(env, &v);
    napi_set_named_property(env, o, "state", v);
  }
  return o;
}

/* A primitive array as the one child of a throwaway struct, so it takes the
 * same path as the argument columns. */
static int32_t primitive_to_js(struct request* r, const struct ArrowArray* a, char fmt, napi_value* out) {
  const struct ArrowArray* kid = a;
  struct ArrowArray st;
  memset(&st, 0, sizeof(st));
  st.length = a->length;
  st.n_children = 1;
  st.children = (struct ArrowArray**)&kid;
  struct rt_col c = {fmt, 1, (char*)""};
  napi_value cols, first;
  int32_t rc = rt_columns_to_js(r, &st, &c, 1, &cols);
  if (rc != KOMIRA_UDF_OK) return rc;
  napi_get_element(r->es->env, cols, 0, &first);
  *out = first;
  return KOMIRA_UDF_OK;
}

/* The JavaScript result of a column answer [0, [n, values, validity]] into out. */
static int32_t column_out(struct request* r, napi_value res, char fmt, struct ArrowDeviceArray* out) {
  napi_value col;
  napi_get_element(r->es->env, res, 1, &col);
  return rt_column_from_js(r, col, fmt, &out->array);
}

static void drop_ref(napi_env env, napi_ref* ref) {
  if (*ref != NULL) {
    napi_delete_reference(env, *ref);
    *ref = NULL;
  }
}

static int32_t op_call_batch(struct request* r) {
  napi_env env = r->es->env;
  const struct komira_udf_udf* u = r->udf;
  napi_value cols, res, argv[3];
  int32_t rc = rt_columns_to_js(r, &r->args->array, u->args, u->n_args, &cols);
  if (rc != KOMIRA_UDF_OK) return rc;
  argv[0] = ref_value(env, r->inst->obj);
  argv[1] = num(env, r->args->array.length);
  argv[2] = cols;
  rc = call_adapter(r, argv, 3, &res);
  if (rc != KOMIRA_UDF_OK) return rc;
  rc = column_out(r, res, u->res[0].fmt, r->out);
  return rc;
}

static int32_t op_frame_open(struct request* r) {
  napi_env env = r->es->env;
  napi_value pull, res, argv[2];
  if (napi_create_function(env, "pull", NAPI_AUTO_LENGTH, rt_pull, r->frame, &pull) != napi_ok)
    return rt_fail(r, KOMIRA_UDF_ERR_INTERNAL, "cannot create the pull function");
  argv[0] = ref_value(env, r->inst->obj);
  argv[1] = pull;
  int32_t rc = call_adapter(r, argv, 2, &res);
  if (rc != KOMIRA_UDF_OK) return rc;
  napi_value obj;
  napi_get_element(env, res, 1, &obj);
  napi_create_reference(env, obj, 1, &r->frame->obj);
  return KOMIRA_UDF_OK;
}

/* frameNext answers [0, 0] at the end and [0, 1, [length, [columns...]]] for a table. */
static int32_t op_frame_next(struct request* r) {
  napi_env env = r->es->env;
  const struct komira_udf_udf* u = r->udf;
  napi_value res, argv[1], v, table;
  argv[0] = ref_value(env, r->frame->obj);
  int32_t rc = call_adapter(r, argv, 1, &res);
  if (rc != KOMIRA_UDF_OK) return rc;
  napi_get_element(env, res, 1, &v);
  int32_t kind = 0;
  napi_get_value_int32(env, v, &kind);
  if (kind == 0) {
    r->out->array.release = NULL;
    return KOMIRA_UDF_OK;
  }
  napi_get_element(env, res, 2, &table);
  if (u->res_is_table) return rt_table_from_js(r, table, u->res, u->n_res, &r->out->array);
  /* A plain aggregate's result is one column, not a struct. */
  napi_value len, cols, col;
  napi_get_element(env, table, 0, &len);
  napi_get_element(env, table, 1, &cols);
  napi_get_element(env, cols, 0, &col);
  return rt_column_from_js(r, col, u->res[0].fmt, &r->out->array);
}

static int32_t op_agg_fold(struct request* r) {
  napi_env env = r->es->env;
  const struct komira_udf_udf* u = r->udf;
  napi_value cols, ids, res, argv[5];
  int32_t rc;
  if (r->op == OP_AGG_UPDATE) rc = rt_columns_to_js(r, &r->args->array, u->args, u->n_args, &cols);
  else rc = primitive_to_js(r, &r->args->array, u->state.fmt, &cols);
  if (rc != KOMIRA_UDF_OK) return rc;
  rc = primitive_to_js(r, &r->ids->array, 'i', &ids);
  if (rc != KOMIRA_UDF_OK) return rc;
  argv[0] = ref_value(env, r->groups->obj);
  argv[1] = num(env, r->args->array.length);
  argv[2] = cols;
  argv[3] = ids;
  argv[4] = num(env, r->n_groups);
  return call_adapter(r, argv, 5, &res);
}

static int32_t op_agg_emit(struct request* r) {
  napi_env env = r->es->env;
  napi_value res, argv[2];
  argv[0] = ref_value(env, r->groups->obj);
  argv[1] = num(env, r->n_groups);
  int32_t rc = call_adapter(r, argv, 2, &res);
  if (rc != KOMIRA_UDF_OK) return rc;
  char fmt = r->op == OP_AGG_STATE ? r->udf->state.fmt : r->udf->res[0].fmt;
  return column_out(r, res, fmt, r->out);
}

static int32_t run_op(struct request* r) {
  napi_env env = r->es->env;
  napi_value res, argv[2];
  switch (r->op) {
    case OP_OPEN_CONTEXT: {
      argv[0] = num(env, r->ctx->slot);
      int32_t rc = call_adapter(r, argv, 1, &res);
      if (rc != KOMIRA_UDF_OK) return rc;
      napi_value obj;
      napi_get_element(env, res, 1, &obj);
      napi_create_reference(env, obj, 1, &r->ctx->obj);
      return KOMIRA_UDF_OK;
    }
    case OP_CLOSE_CONTEXT:
      argv[0] = ref_value(env, r->ctx->obj);
      call_adapter(r, argv, 1, &res);
      drop_ref(env, &r->ctx->obj);
      return KOMIRA_UDF_OK;
    case OP_OPEN_INSTANCE: {
      argv[0] = ref_value(env, r->ctx->obj);
      argv[1] = spec_object(env, r->udf);
      int32_t rc = call_adapter(r, argv, 2, &res);
      if (rc != KOMIRA_UDF_OK) return rc;
      napi_value obj;
      napi_get_element(env, res, 1, &obj);
      napi_create_reference(env, obj, 1, &r->inst->obj);
      return KOMIRA_UDF_OK;
    }
    case OP_CLOSE_INSTANCE:
      argv[0] = ref_value(env, r->inst->obj);
      call_adapter(r, argv, 1, &res);
      drop_ref(env, &r->inst->obj);
      return KOMIRA_UDF_OK;
    case OP_CALL_BATCH:
      return op_call_batch(r);
    case OP_FRAME_OPEN:
      return op_frame_open(r);
    case OP_FRAME_NEXT:
      return op_frame_next(r);
    case OP_FRAME_CLOSE:
      argv[0] = ref_value(env, r->frame->obj);
      call_adapter(r, argv, 1, &res);
      drop_ref(env, &r->frame->obj);
      return KOMIRA_UDF_OK;
    case OP_AGG_OPEN: {
      argv[0] = ref_value(env, r->inst->obj);
      int32_t rc = call_adapter(r, argv, 1, &res);
      if (rc != KOMIRA_UDF_OK) return rc;
      napi_value obj;
      napi_get_element(env, res, 1, &obj);
      napi_create_reference(env, obj, 1, &r->groups->obj);
      return KOMIRA_UDF_OK;
    }
    case OP_AGG_UPDATE:
    case OP_AGG_MERGE:
      return op_agg_fold(r);
    case OP_AGG_STATE:
    case OP_AGG_FINISH:
      return op_agg_emit(r);
    case OP_AGG_CLOSE:
      argv[0] = ref_value(env, r->groups->obj);
      call_adapter(r, argv, 1, &res);
      drop_ref(env, &r->groups->obj);
      return KOMIRA_UDF_OK;
    case OP_MEMORY: {
      argv[0] = ref_value(env, r->ctx->obj);
      int32_t rc = call_adapter(r, argv, 1, &res);
      if (rc != KOMIRA_UDF_OK) return rc;
      napi_value v;
      double d = -1;
      napi_get_element(env, res, 1, &v);
      napi_get_value_double(env, v, &d);
      r->value = (int64_t)d;
      return KOMIRA_UDF_OK;
    }
    case OP_SPAWN: {
      napi_value av[3];
      av[0] = num(env, r->n_groups);
      av[1] = str(env, g_addon_path);
      av[2] = str(env, g_code_dir);
      return call_adapter(r, av, 3, &res);
    }
    case OP_STOP:
      argv[0] = num(env, r->n_groups);
      return call_adapter(r, argv, 1, &res);
    default:
      return rt_fail(r, KOMIRA_UDF_ERR_INTERNAL, "unknown operation");
  }
}

void rt_dispatch(napi_env env, napi_value js_cb, void* context, void* data) {
  (void)js_cb;
  struct env_state* es = context;
  struct request* r = data;
  if (env == NULL) { /* the environment is shutting down: nothing can run */
    rt_fail(r, KOMIRA_UDF_ERR_INSTANCE_LOST, "the Node environment is shutting down");
    rt_complete(r);
    return;
  }
  napi_handle_scope scope;
  napi_open_handle_scope(env, &scope);
  es->cur = r;
  int32_t rc = run_op(r);
  if (rc != KOMIRA_UDF_OK && r->status == KOMIRA_UDF_OK) r->status = rc;
  if (r->status != KOMIRA_UDF_OK && r->out != NULL) r->out->array.release = NULL;
  rt_unwrap_all(r);
  es->cur = NULL;
  napi_close_handle_scope(env, scope);
  rt_complete(r);
}
