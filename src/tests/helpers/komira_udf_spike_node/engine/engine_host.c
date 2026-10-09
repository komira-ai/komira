/*
 * The engine side of the Node runtime's tests, as a Node-API addon (BUCK,
 * engine_host). Test-only spike code. node hosts the process, so the engine
 * is a library node's script drives: this addon starts the engine's threads
 * and hands the results back, while the JavaScript threads stay free to run
 * the UDFs (the runtime posts every call to them).
 *
 *   engineOpen(runtimeLibrary) -> handle, engineInfo(handle), engineClose(handle)
 *   run(handle, options)            -> Promise: engine_loop.c on N engine threads
 *   cancelProbe(handle, options, ms) -> Promise: one call cancelled while it runs
 *   conform(engine.so, runtimeLibrary, casesDir) -> Promise<string>: the Mojo
 *                                      harness's conformance suite on a thread of its own
 *   gateSync(engine.so, symbol, n)  -> number: a Mojo library's int64 function
 *                                      called on the calling thread
 *   gateAsync(engine.so, symbol, n) -> Promise<number>: the same on a thread node made
 *   openContextHere(handle)         -> { status, message }: open_context on this thread
 *
 * FFI-BOUNDARY. An engine handle is an external value over the struct
 * engine_loop.c allocated; it is freed only by engineClose. Libraries are
 * dlopened and never closed. Strings and options are copied out of
 * JavaScript before any worker thread starts; a job's buffers belong to the
 * job and are freed in its completion callback on the JavaScript thread.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define NAPI_VERSION 8
#include <node_api.h>

#include "engine_loop.h"
#include "headers/komira_udf_runtime.h" /* the abi package's :headers, staged as headers/ */

#define REPORT_CAP (256 * 1024)
#define PATH_CAP 1024

enum { JOB_RUN = 1, JOB_CANCEL, JOB_CONFORM, JOB_GATE };

struct job {
  napi_async_work work;
  napi_deferred deferred;
  int kind;
  struct engine* e;
  struct run_opts opts;
  char entry[256];
  char arg_names[256];
  int32_t cancel_after_ms;
  struct run* run;
  int64_t probe[P_FIELDS];
  char message[ENGINE_MSG];
  char engine_path[PATH_CAP], runtime_path[PATH_CAP], cases_dir[PATH_CAP], symbol[128];
  char* report;
  int32_t rc;
  int64_t gate_n, gate_result;
};

static napi_value throw_msg(napi_env env, const char* msg) {
  napi_throw_error(env, NULL, msg);
  return NULL;
}

static int get_prop(napi_env env, napi_value obj, const char* key, napi_value* out) {
  bool has = false;
  if (napi_has_named_property(env, obj, key, &has) != napi_ok || !has) return 0;
  return napi_get_named_property(env, obj, key, out) == napi_ok;
}

static double num_opt(napi_env env, napi_value obj, const char* key, double dflt) {
  napi_value v;
  double d = dflt;
  if (get_prop(env, obj, key, &v)) napi_get_value_double(env, v, &d);
  return d;
}

static void str_opt(napi_env env, napi_value obj, const char* key, char* into, size_t cap, const char* dflt) {
  napi_value v;
  size_t n = 0;
  snprintf(into, cap, "%s", dflt);
  if (get_prop(env, obj, key, &v)) napi_get_value_string_utf8(env, v, into, cap, &n);
}

static napi_value set_num(napi_env env, napi_value obj, const char* key, double v) {
  napi_value n;
  napi_create_double(env, v, &n);
  napi_set_named_property(env, obj, key, n);
  return n;
}

static napi_value str_value(napi_env env, const char* s) {
  napi_value v;
  napi_create_string_utf8(env, s, NAPI_AUTO_LENGTH, &v);
  return v;
}

static void read_opts(napi_env env, napi_value o, struct job* j) {
  struct run_opts* r = &j->opts;
  memset(r, 0, sizeof(*r));
  str_opt(env, o, "entry", j->entry, sizeof(j->entry), "");
  r->entry = j->entry;
  r->shape = (int32_t)num_opt(env, o, "shape", 1);
  r->n_args = (int32_t)num_opt(env, o, "nArgs", 1);
  char f[8];
  str_opt(env, o, "argFmt", f, sizeof(f), "l");
  r->arg_fmt = f[0];
  str_opt(env, o, "resultFmt", f, sizeof(f), "l");
  r->result_fmt = f[0];
  r->threads = (int32_t)num_opt(env, o, "threads", 1);
  r->warmup_min = (int32_t)num_opt(env, o, "warmupMin", 8);
  r->warmup_cap = (int32_t)num_opt(env, o, "warmupCap", 8);
  r->batches = (int32_t)num_opt(env, o, "batches", 8);
  r->rows = (int64_t)num_opt(env, o, "rows", 1024);
  r->check = (int32_t)num_opt(env, o, "check", CHECK_NONE);
  r->a = num_opt(env, o, "a", 1);
  r->b = num_opt(env, o, "b", 0);
  r->base = num_opt(env, o, "base", 0);
  r->step = num_opt(env, o, "step", 1);
  r->dup_cols = (int32_t)num_opt(env, o, "dupCols", 0);
  r->offset = (int64_t)num_opt(env, o, "offset", 0);
  r->null_every = (int32_t)num_opt(env, o, "nullEvery", 0);
  r->form = (int32_t)num_opt(env, o, "form", 2);
  r->descriptor_version = (int32_t)num_opt(env, o, "descriptorVersion", 0);
  r->descriptor_len = (int32_t)num_opt(env, o, "descriptorLen", 0);
  r->n_code = (int32_t)num_opt(env, o, "nCode", 0);
  r->hold = (int32_t)num_opt(env, o, "hold", 0);
  str_opt(env, o, "argNames", j->arg_names, sizeof(j->arg_names), "");
  r->arg_names = j->arg_names;
}

/* ---- the engine handle -------------------------------------------------------- */

static struct engine* engine_arg(napi_env env, napi_value v) {
  void* p = NULL;
  if (napi_get_value_external(env, v, &p) != napi_ok) return NULL;
  return p;
}

static napi_value engine_open(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  char path[PATH_CAP];
  size_t n = 0;
  if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc < 1 ||
      napi_get_value_string_utf8(env, argv[0], path, sizeof(path), &n) != napi_ok)
    return throw_msg(env, "engineOpen(path)");
  struct engine* e = kudf_engine_open(path);
  if (e == NULL) return throw_msg(env, "engineOpen: out of memory");
  napi_value ext;
  napi_create_external(env, e, NULL, NULL, &ext);
  return ext;
}

static napi_value engine_info(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc < 1) return throw_msg(env, "engineInfo(handle)");
  struct engine* e = engine_arg(env, argv[0]);
  if (e == NULL) return throw_msg(env, "engineInfo: not an engine handle");
  napi_value o;
  napi_create_object(env, &o);
  set_num(env, o, "status", kudf_engine_status(e));
  napi_set_named_property(env, o, "message", str_value(env, kudf_engine_message(e)));
  if (kudf_engine_status(e) != 0) return o;
  napi_set_named_property(env, o, "runtimeId", str_value(env, kudf_engine_runtime_id(e)));
  set_num(env, o, "openNs", (double)kudf_engine_open_ns(e));
  set_num(env, o, "threading", (double)kudf_engine_cap(e, 0));
  set_num(env, o, "globalLock", (double)kudf_engine_cap(e, 1));
  set_num(env, o, "threadAffine", (double)kudf_engine_cap(e, 2));
  set_num(env, o, "udfClass", (double)kudf_engine_cap(e, 3));
  set_num(env, o, "hosting", (double)kudf_engine_cap(e, 4));
  set_num(env, o, "shapes", (double)kudf_engine_cap(e, 5));
  set_num(env, o, "features", (double)kudf_engine_cap(e, 6));
  return o;
}

static napi_value engine_close(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc < 1) return NULL;
  kudf_engine_close(engine_arg(env, argv[0]));
  return NULL;
}

static napi_value validate_spec(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc < 2) return throw_msg(env, "validateSpec(handle, options)");
  struct engine* e = engine_arg(env, argv[0]);
  if (e == NULL) return throw_msg(env, "validateSpec: not an engine handle");
  struct job j;
  memset(&j, 0, sizeof(j));
  read_opts(env, argv[1], &j);
  char message[ENGINE_MSG];
  int32_t rc = kudf_validate(e, &j.opts, message);
  napi_value o;
  napi_create_object(env, &o);
  set_num(env, o, "status", rc);
  napi_set_named_property(env, o, "message", str_value(env, message));
  return o;
}

static napi_value open_context_here(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc < 1) return throw_msg(env, "openContextHere(handle)");
  struct engine* e = engine_arg(env, argv[0]);
  if (e == NULL) return throw_msg(env, "openContextHere: not an engine handle");
  char message[ENGINE_MSG];
  int32_t rc = kudf_open_context_here(e, message);
  napi_value o;
  napi_create_object(env, &o);
  set_num(env, o, "status", rc);
  napi_set_named_property(env, o, "message", str_value(env, message));
  return o;
}

/* ---- jobs: work on a thread node owns, a Promise for the result ---------------- */

static void run_job(napi_env env, void* data) {
  (void)env;
  struct job* j = data;
  switch (j->kind) {
    case JOB_RUN:
      j->run = kudf_run(j->e, &j->opts);
      break;
    case JOB_CANCEL:
      kudf_cancel_probe(j->e, &j->opts, j->cancel_after_ms, j->probe, j->message);
      break;
    case JOB_CONFORM: {
      void* lib = dlopen(j->engine_path, RTLD_NOW | RTLD_LOCAL);
      if (lib == NULL) {
        snprintf(j->report, REPORT_CAP, "dlopen %s: %s", j->engine_path, dlerror());
        j->rc = -1;
        break;
      }
      typedef int32_t (*conform_fn)(const char*, const char*, char*, int64_t);
      conform_fn f = (conform_fn)dlsym(lib, "komira_udf_spike_node_conform");
      if (f == NULL) {
        snprintf(j->report, REPORT_CAP, "%s exports no komira_udf_spike_node_conform", j->engine_path);
        j->rc = -1;
        break;
      }
      j->rc = f(j->runtime_path, j->cases_dir, j->report, REPORT_CAP);
      break;
    }
    case JOB_GATE: {
      void* lib = dlopen(j->engine_path, RTLD_NOW | RTLD_LOCAL);
      typedef int64_t (*gate_fn)(int64_t);
      gate_fn f = lib != NULL ? (gate_fn)dlsym(lib, j->symbol) : NULL;
      j->gate_result = f != NULL ? f(j->gate_n) : -1;
      j->rc = f != NULL ? 0 : -1;
      break;
    }
    default:
      break;
  }
}

static napi_value run_result(napi_env env, struct run* r) {
  napi_value o, runs, threads, samples, msgs;
  napi_create_object(env, &o);
  napi_create_array_with_length(env, R_FIELDS, &runs);
  for (int k = 0; k < R_FIELDS; k++) {
    napi_value n;
    napi_create_double(env, (double)kudf_run_get(r, -1, k), &n);
    napi_set_element(env, runs, (uint32_t)k, n);
  }
  napi_set_named_property(env, o, "run", runs);
  napi_set_named_property(env, o, "message", str_value(env, kudf_run_message(r, -1)));
  int n_threads = (int)kudf_run_get(r, -1, R_THREADS);
  napi_create_array_with_length(env, (size_t)n_threads, &threads);
  napi_create_array_with_length(env, (size_t)n_threads, &samples);
  napi_create_array_with_length(env, (size_t)n_threads, &msgs);
  for (int t = 0; t < n_threads; t++) {
    napi_value fields;
    napi_create_array_with_length(env, T_FIELDS, &fields);
    for (int k = 0; k < T_FIELDS; k++) {
      napi_value n;
      napi_create_double(env, (double)kudf_run_get(r, t, k), &n);
      napi_set_element(env, fields, (uint32_t)k, n);
    }
    napi_set_element(env, threads, (uint32_t)t, fields);
    int64_t count = kudf_run_get(r, t, T_SAMPLES);
    napi_value ab, ta;
    double* data = NULL;
    napi_create_arraybuffer(env, (size_t)count * sizeof(double), (void**)&data, &ab);
    for (int64_t i = 0; i < count; i++) data[i] = (double)kudf_run_sample(r, t, i);
    napi_create_typedarray(env, napi_float64_array, (size_t)count, ab, 0, &ta);
    napi_set_element(env, samples, (uint32_t)t, ta);
    napi_set_element(env, msgs, (uint32_t)t, str_value(env, kudf_run_message(r, t)));
  }
  napi_set_named_property(env, o, "threads", threads);
  napi_set_named_property(env, o, "samples", samples);
  napi_set_named_property(env, o, "threadMessages", msgs);
  return o;
}

static void job_done(napi_env env, napi_status status, void* data) {
  struct job* j = data;
  napi_value v;
  if (status != napi_ok) {
    napi_reject_deferred(env, j->deferred, str_value(env, "the job was cancelled"));
  } else if (j->kind == JOB_RUN) {
    napi_resolve_deferred(env, j->deferred, run_result(env, j->run));
  } else if (j->kind == JOB_CANCEL) {
    napi_create_object(env, &v);
    set_num(env, v, "status", (double)j->probe[P_STATUS]);
    set_num(env, v, "elapsedNs", (double)j->probe[P_ELAPSED_NS]);
    set_num(env, v, "row", (double)j->probe[P_ROW]);
    napi_set_named_property(env, v, "message", str_value(env, j->message));
    napi_resolve_deferred(env, j->deferred, v);
  } else if (j->kind == JOB_CONFORM) {
    napi_create_object(env, &v);
    set_num(env, v, "rc", j->rc);
    napi_set_named_property(env, v, "report", str_value(env, j->report));
    napi_resolve_deferred(env, j->deferred, v);
  } else {
    napi_create_double(env, (double)j->gate_result, &v);
    napi_resolve_deferred(env, j->deferred, v);
  }
  napi_delete_async_work(env, j->work);
  if (j->run != NULL) kudf_run_free(j->run);
  free(j->report);
  free(j);
}

static napi_value start_job(napi_env env, struct job* j) {
  napi_value promise, name;
  napi_create_promise(env, &j->deferred, &promise);
  napi_create_string_utf8(env, "komira_udf_node_job", NAPI_AUTO_LENGTH, &name);
  if (napi_create_async_work(env, NULL, name, run_job, job_done, j, &j->work) != napi_ok ||
      napi_queue_async_work(env, j->work) != napi_ok) {
    free(j->report);
    free(j);
    return throw_msg(env, "cannot start the job");
  }
  return promise;
}

static napi_value job_run(napi_env env, napi_callback_info info, int kind) {
  size_t argc = 3;
  napi_value argv[3];
  if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc < 2) return throw_msg(env, "run(handle, options)");
  struct job* j = calloc(1, sizeof(*j));
  if (j == NULL) return throw_msg(env, "out of memory");
  j->kind = kind;
  j->e = engine_arg(env, argv[0]);
  if (j->e == NULL) {
    free(j);
    return throw_msg(env, "not an engine handle");
  }
  read_opts(env, argv[1], j);
  if (kind == JOB_CANCEL) {
    double ms = 0;
    if (argc >= 3) napi_get_value_double(env, argv[2], &ms);
    j->cancel_after_ms = (int32_t)ms;
  }
  return start_job(env, j);
}

static napi_value run_fn(napi_env env, napi_callback_info info) { return job_run(env, info, JOB_RUN); }
static napi_value cancel_probe(napi_env env, napi_callback_info info) { return job_run(env, info, JOB_CANCEL); }

static napi_value conform(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value argv[3];
  size_t n = 0;
  if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc < 3) return throw_msg(env, "conform(engine, runtime, casesDir)");
  struct job* j = calloc(1, sizeof(*j));
  if (j == NULL) return throw_msg(env, "out of memory");
  j->kind = JOB_CONFORM;
  j->report = calloc(1, REPORT_CAP);
  if (j->report == NULL ||
      napi_get_value_string_utf8(env, argv[0], j->engine_path, PATH_CAP, &n) != napi_ok ||
      napi_get_value_string_utf8(env, argv[1], j->runtime_path, PATH_CAP, &n) != napi_ok ||
      napi_get_value_string_utf8(env, argv[2], j->cases_dir, PATH_CAP, &n) != napi_ok) {
    free(j->report);
    free(j);
    return throw_msg(env, "conform: bad arguments");
  }
  return start_job(env, j);
}

static int gate_args(napi_env env, napi_callback_info info, struct job* j) {
  size_t argc = 3;
  napi_value argv[3];
  size_t n = 0;
  double d = 0;
  if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc < 3 ||
      napi_get_value_string_utf8(env, argv[0], j->engine_path, PATH_CAP, &n) != napi_ok ||
      napi_get_value_string_utf8(env, argv[1], j->symbol, sizeof(j->symbol), &n) != napi_ok ||
      napi_get_value_double(env, argv[2], &d) != napi_ok) {
    throw_msg(env, "gate(engine, symbol, n)");
    return 0;
  }
  j->gate_n = (int64_t)d;
  return 1;
}

static napi_value gate_sync(napi_env env, napi_callback_info info) {
  struct job j;
  memset(&j, 0, sizeof(j));
  if (!gate_args(env, info, &j)) return NULL;
  j.kind = JOB_GATE;
  run_job(env, &j);
  napi_value v;
  napi_create_double(env, (double)j.gate_result, &v);
  return v;
}

static napi_value gate_async(napi_env env, napi_callback_info info) {
  struct job* j = calloc(1, sizeof(*j));
  if (j == NULL) return throw_msg(env, "out of memory");
  j->kind = JOB_GATE;
  if (!gate_args(env, info, j)) {
    free(j);
    return NULL;
  }
  return start_job(env, j);
}

static int export_fn(napi_env env, napi_value exports, const char* name, napi_callback cb) {
  napi_value fn;
  if (napi_create_function(env, name, NAPI_AUTO_LENGTH, cb, NULL, &fn) != napi_ok) return 0;
  return napi_set_named_property(env, exports, name, fn) == napi_ok;
}

NAPI_MODULE_INIT() {
  if (!export_fn(env, exports, "engineOpen", engine_open) || !export_fn(env, exports, "engineInfo", engine_info) ||
      !export_fn(env, exports, "engineClose", engine_close) || !export_fn(env, exports, "run", run_fn) ||
      !export_fn(env, exports, "cancelProbe", cancel_probe) || !export_fn(env, exports, "conform", conform) ||
      !export_fn(env, exports, "gateSync", gate_sync) || !export_fn(env, exports, "gateAsync", gate_async) ||
      !export_fn(env, exports, "openContextHere", open_context_here) || !export_fn(env, exports, "validateSpec", validate_spec))
    return throw_msg(env, "engine_host: cannot export its functions");
  return exports;
}
