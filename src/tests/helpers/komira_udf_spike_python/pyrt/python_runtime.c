/*
 * komira-test/python: a UDF runtime that embeds CPython and implements the
 * table of komira_udf_runtime.h (docs/design/udf_runtime_interface.md
 * section 4.3) around it. Test-only spike code: it measures the design's
 * mode 2 (one interpreter per engine thread, section 1.2) in-process.
 *
 * Two builds of this file's init, one table:
 *   komira_udf_python_subinterp_init_v1   one sub-interpreter with its own
 *       GIL per context (Py_NewInterpreterFromConfig, PyInterpreterConfig
 *       OWN_GIL, check_multi_interp_extensions 1): no lock shared between
 *       engine threads. Reports CONTEXT_PER_THREAD, global_lock 0.
 *   komira_udf_python_shared_gil_init_v1  every context a thread state of
 *       the main interpreter: one GIL for every engine thread. The baseline
 *       the design rejects; reports CONTEXT_PER_THREAD with global_lock 1.
 *
 * Both report thread_affine 1: a context's PyThreadState belongs to the
 * engine thread that opened it, which enters it with PyEval_RestoreThread
 * and leaves it with PyEval_SaveThread on every call. PyGILState_* is never
 * used: it always targets the main interpreter.
 *
 * Where things are. The runtime finds everything beside its own library
 * file (dladdr), because init carries no configuration:
 *   <dir>/python/   a CPython 3.13 install (home); libpython in lib/
 *   <dir>/pyrt/     the adapter komira_udf_pyrt.py and the fixture modules
 *   <dir>/site/<w>  one directory per installed wheel, added to sys.path
 * User code is `module:qualname`, imported from that path in each context's
 * interpreter by open_instance (design section 4.3, step 4: for a runtime
 * whose objects belong to a context, open_instance loads).
 *
 * FFI-BOUNDARY. Owners: the rt, udf, context and instance structs are this
 * runtime's, freed by shutdown, unload, close_context and close_instance.
 * Every PyObject* field holds one strong reference, dropped (Py_DecRef) with
 * its interpreter entered, before the interpreter ends. libpython is loaded
 * once and never closed. Arrow arrays: python_call.c.
 */
#include "pyrt.h" /* first: Python.h sets the feature macros */

#include <dirent.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define RT_ID_SUBINTERP "komira-test/python"
#define RT_ID_SHARED_GIL "komira-test/python-shared-gil"

/* init runs once per process (design section 4.3, step 1): CPython is not
 * re-initialized after finalization here. */
static int g_initialized;
/* The one runtime of the process, for the clock callable (now_ns_fn). */
static struct komira_udf_rt* g_rt;

/* ---- errors -------------------------------------------------------------- */

static void free_error(komira_udf_error* e) {
  free((void*)e->message);
  free((void*)e->user_trace);
  e->message = NULL;
  e->user_trace = NULL;
  e->release = NULL;
}

static char* dup_str(const char* s) {
  if (s == NULL) return NULL;
  size_t n = strlen(s) + 1;
  char* d = malloc(n);
  if (d) memcpy(d, s, n);
  return d;
}

/* `s` on one line (the ABI's message is one line): each run of whitespace,
 * newlines included, becomes one space; leading and trailing ones go. */
static char* one_line(const char* s) {
  char* d = malloc(strlen(s) + 1);
  if (d == NULL) return NULL;
  size_t n = 0;
  int space = 0;
  for (const char* p = s; *p; p++) {
    if (*p == ' ' || *p == '\n' || *p == '\r' || *p == '\t') {
      space = n > 0;
    } else {
      if (space) d[n++] = ' ';
      space = 0;
      d[n++] = *p;
    }
  }
  d[n] = 0;
  return d;
}

int32_t pyrt_fail(komira_udf_error* e, int32_t code, const char* msg, const char* trace, int64_t row) {
  if (e == NULL || e->struct_size < sizeof(komira_udf_error)) return code;
  e->code = code;
  e->message = one_line(msg != NULL && msg[0] ? msg : "the Python runtime failed");
  e->user_trace = dup_str(trace);
  e->row = row;
  e->group = -1;
  e->release = free_error;
  return code;
}

char* pyrt_take_exception(const struct pyapi* api) {
  PyObject* exc = api->PyErr_GetRaisedException();
  if (exc == NULL) return dup_str("");
  char* out = NULL;
  PyObject* s = api->PyObject_Str(exc);
  PyObject* t = api->PyObject_GetAttrString(exc, "__class__");
  PyObject* tn = t ? api->PyObject_GetAttrString(t, "__name__") : NULL;
  const char* name = tn ? api->PyUnicode_AsUTF8(tn) : NULL;
  const char* text = s ? api->PyUnicode_AsUTF8(s) : NULL;
  size_t n = strlen(name ? name : "?") + strlen(text ? text : "") + 3;
  out = malloc(n);
  if (out) snprintf(out, n, "%s: %s", name ? name : "?", text ? text : "");
  api->PyErr_Clear();
  if (s) api->Py_DecRef(s);
  if (tn) api->Py_DecRef(tn);
  if (t) api->Py_DecRef(t);
  api->Py_DecRef(exc);
  return out ? out : dup_str("");
}

static int32_t fail_exception(struct pyapi* api, komira_udf_error* e, int32_t code, const char* what) {
  char* x = pyrt_take_exception(api);
  char msg[1024];
  snprintf(msg, sizeof(msg), "%s: %s", what, x);
  free(x);
  return pyrt_fail(e, code, msg, NULL, -1);
}

/* ---- interpreter entry --------------------------------------------------- */

void pyrt_enter(struct komira_udf_context* c) { c->rt->api.PyEval_RestoreThread(c->ts); }

void pyrt_leave(struct komira_udf_context* c) {
  PyThreadState* ts = c->rt->api.PyEval_SaveThread();
  (void)ts; /* == c->ts */
}

/* A thread state of the main interpreter for this thread, entered: for
 * work on the main interpreter from any engine thread (validate, creating a
 * sub-interpreter). main_leave clears and deletes it. */
static PyThreadState* main_enter(struct komira_udf_rt* rt) {
  PyThreadState* ts = rt->api.PyThreadState_New(rt->main_interp);
  if (ts != NULL) rt->api.PyEval_RestoreThread(ts);
  return ts;
}

static void main_leave(struct komira_udf_rt* rt, PyThreadState* ts) {
  rt->api.PyThreadState_Clear(ts);
  rt->api.PyThreadState_DeleteCurrent();
}

/* sys.path gets <dir>/pyrt, then <dir>/site/<each, sorted>; then the adapter
 * is imported. Returns a new reference, or NULL with the exception set. */
static PyObject* bootstrap(struct komira_udf_rt* rt) {
  struct pyapi* a = &rt->api;
  PyObject* mod = a->PyImport_ImportModule("sys");
  if (mod == NULL) return NULL;
  PyObject* path = a->PyObject_GetAttrString(mod, "path");
  a->Py_DecRef(mod);
  if (path == NULL) return NULL;
  char p[1200];
  snprintf(p, sizeof(p), "%s/pyrt", rt->dir);
  PyObject* name = a->PyUnicode_FromString("insert");
  PyObject* at = a->PyLong_FromLongLong(0);
  PyObject* dir = a->PyUnicode_DecodeFSDefault(p);
  PyObject* r = (name && at && dir) ? a->PyObject_CallMethodObjArgs(path, name, at, dir, NULL) : NULL;
  if (r) a->Py_DecRef(r);
  if (name) a->Py_DecRef(name);
  if (at) a->Py_DecRef(at);
  if (dir) a->Py_DecRef(dir);
  a->Py_DecRef(path);
  if (r == NULL) return NULL;
  PyObject* adapter = a->PyImport_ImportModule("komira_udf_pyrt");
  if (adapter == NULL) return NULL;
  snprintf(p, sizeof(p), "%s/site", rt->dir);
  PyObject* site = a->PyUnicode_DecodeFSDefault(p);
  PyObject* fn = a->PyUnicode_FromString("add_site_dirs");
  r = (site && fn) ? a->PyObject_CallMethodObjArgs(adapter, fn, site, NULL) : NULL;
  if (site) a->Py_DecRef(site);
  if (fn) a->Py_DecRef(fn);
  if (r == NULL) {
    a->Py_DecRef(adapter);
    return NULL;
  }
  a->Py_DecRef(r);
  return adapter;
}

/* ---- the host clock, as a Python callable -------------------------------- */

static PyObject* now_ns_fn(PyObject* self, PyObject* unused) {
  (void)self;
  (void)unused;
  /* The interpreter is entered; g_rt is set before any context exists. */
  return g_rt->api.PyLong_FromLongLong(g_rt->host->now_ns(g_rt->host->host_data));
}

static PyMethodDef NOW_NS_DEF = {"now_ns", now_ns_fn, METH_NOARGS, "The host's monotonic clock, in ns."};

/* ---- describe / validate / load ------------------------------------------ */

static int32_t py_describe(komira_udf_rt* rt, komira_udf_capabilities* c) {
  if (c == NULL || c->struct_size < sizeof(komira_udf_capabilities)) return KOMIRA_UDF_ERR_ABI;
  c->runtime_id = rt->variant == PYRT_SUBINTERP ? RT_ID_SUBINTERP : RT_ID_SHARED_GIL;
  c->runtime_abi = "cp313";
  c->max_descriptor_version = 0;
  c->shapes = KOMIRA_UDF_SHAPE_SCALAR | KOMIRA_UDF_SHAPE_MAP_BATCHES_COLUMN;
  c->threading = KOMIRA_UDF_CONTEXT_PER_THREAD;
  c->thread_affine = 1;
  c->transports = KOMIRA_UDF_TRANSPORT_IN_PROCESS;
  c->hosting = KOMIRA_UDF_HOSTING_EMBEDDED;
  c->devices = KOMIRA_UDF_DEVICE_CPU;
  c->features = 0;
  c->udf_class = KOMIRA_UDF_CLASS_MANAGED;
  c->global_lock = rt->variant == PYRT_SHARED_GIL ? 1u : 0u;
  return KOMIRA_UDF_OK;
}

static int leaf_fmt(const struct ArrowSchema* s, char* fmt) {
  if (s == NULL || s->format == NULL || s->n_children != 0 || s->format[1] != 0) return 0;
  if (s->format[0] != 'l' && s->format[0] != 'g') return 0;
  *fmt = s->format[0];
  return 1;
}

/* The checks that need no interpreter: sizes, form, entry grammar,
 * descriptor, shape and the types this runtime maps. Fills `u`. */
static int32_t check_spec(const komira_udf_spec* s, komira_udf_error* e, struct komira_udf_udf* u) {
  if (s == NULL || s->struct_size < sizeof(komira_udf_spec))
    return pyrt_fail(e, KOMIRA_UDF_ERR_ABI, "spec struct_size is below this runtime's", NULL, -1);
  if (s->form != KOMIRA_UDF_FORM_PACKAGE && s->form != KOMIRA_UDF_FORM_BUNDLE) {
    if (s->form == KOMIRA_UDF_FORM_VALUE)
      return pyrt_fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "code form VALUE (a serialized function) is not read by this runtime",
                       NULL, -1);
    return pyrt_fail(e, KOMIRA_UDF_ERR_DESCRIPTOR, "code form is not PACKAGE, BUNDLE or VALUE", NULL, -1);
  }
  const char* colon = s->entry ? strchr(s->entry, ':') : NULL;
  if (colon == NULL || colon == s->entry || colon[1] == 0 || strchr(colon + 1, ':') != NULL)
    return pyrt_fail(e, KOMIRA_UDF_ERR_DESCRIPTOR, "entry is not <module>:<function>", NULL, -1);
  if (s->descriptor_version > 0)
    return pyrt_fail(e, KOMIRA_UDF_ERR_DESCRIPTOR, "descriptor_version is newer than 0, the newest read here", NULL,
                     -1);
  if (s->descriptor_len != 0)
    return pyrt_fail(e, KOMIRA_UDF_ERR_DESCRIPTOR, "descriptor version 0 is empty; these bytes are not canonical",
                     NULL, -1);
  if (s->n_code != 0)
    return pyrt_fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "code objects are not read by this runtime (spike)", NULL, -1);
  if (s->shape != (int32_t)KOMIRA_UDF_SHAPE_SCALAR && s->shape != (int32_t)KOMIRA_UDF_SHAPE_MAP_BATCHES_COLUMN)
    return pyrt_fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "shape is not SCALAR or MAP_BATCHES_COLUMN", NULL, -1);
  if (s->args == NULL || s->args->format == NULL || strcmp(s->args->format, "+s") != 0 ||
      s->args->n_children > PYRT_MAX_ARGS)
    return pyrt_fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "args is not a struct of at most 8 fields", NULL, -1);
  u->n_args = (int)s->args->n_children;
  for (int i = 0; i < u->n_args; i++)
    if (!leaf_fmt(s->args->children[i], &u->arg_fmt[i]))
      return pyrt_fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "an argument type is not int64 or float64", NULL, -1);
  if (!leaf_fmt(s->result, &u->result_fmt))
    return pyrt_fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "the result type is not int64 or float64", NULL, -1);
  if (s->state != NULL) return pyrt_fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "a state type is for aggregates", NULL, -1);
  u->result_nullable = (s->result->flags & ARROW_FLAG_NULLABLE) != 0;
  u->shape = s->shape;
  u->null_mode = s->null_mode;
  return KOMIRA_UDF_OK;
}

/* The adapter's static check (komira_udf_pyrt.validate: the module's
 * source, parsed, never run), in the main interpreter. */
static int32_t check_source(struct komira_udf_rt* rt, const char* entry, const struct komira_udf_udf* u,
                            komira_udf_error* e) {
  struct pyapi* a = &rt->api;
  PyThreadState* ts = main_enter(rt);
  if (ts == NULL) return pyrt_fail(e, KOMIRA_UDF_ERR_INTERNAL, "validate: no thread state", NULL, -1);
  char args[PYRT_MAX_ARGS + 1];
  memcpy(args, u->arg_fmt, (size_t)u->n_args);
  args[u->n_args] = 0;
  char res[2] = {u->result_fmt, 0};
  PyObject* fn = a->PyUnicode_FromString("validate");
  PyObject* pe = a->PyUnicode_FromString(entry);
  PyObject* ps = a->PyLong_FromLongLong(u->shape);
  PyObject* pa = a->PyUnicode_FromString(args);
  PyObject* pr = a->PyUnicode_FromString(res);
  PyObject* r = (fn && pe && ps && pa && pr) ? a->PyObject_CallMethodObjArgs(rt->main_adapter, fn, pe, ps, pa, pr, NULL)
                                             : NULL;
  int32_t rc;
  if (r == NULL) {
    rc = fail_exception(a, e, KOMIRA_UDF_ERR_INTERNAL, "validate");
  } else {
    rc = (int32_t)a->PyLong_AsLongLong(a->PyTuple_GetItem(r, 0));
    if (rc != KOMIRA_UDF_OK) pyrt_fail(e, rc, a->PyUnicode_AsUTF8(a->PyTuple_GetItem(r, 1)), NULL, -1);
    a->Py_DecRef(r);
  }
  PyObject* objs[] = {fn, pe, ps, pa, pr};
  for (size_t i = 0; i < sizeof(objs) / sizeof(objs[0]); i++)
    if (objs[i]) a->Py_DecRef(objs[i]);
  main_leave(rt, ts);
  return rc;
}

static int32_t py_validate(komira_udf_rt* rt, const komira_udf_spec* s, komira_udf_error* e) {
  struct komira_udf_udf u = {0};
  int32_t rc = check_spec(s, e, &u);
  return rc != KOMIRA_UDF_OK ? rc : check_source(rt, s->entry, &u, e);
}

static int32_t py_load(komira_udf_rt* rt, const komira_udf_spec* s, komira_udf_udf** out, komira_udf_error* e) {
  struct komira_udf_udf u = {0};
  int32_t rc = check_spec(s, e, &u);
  if (rc == KOMIRA_UDF_OK) rc = check_source(rt, s->entry, &u, e);
  if (rc != KOMIRA_UDF_OK) return rc;
  komira_udf_udf* p = malloc(sizeof(*p));
  if (p == NULL) return pyrt_fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "load: out of memory", NULL, -1);
  *p = u;
  p->entry = dup_str(s->entry);
  *out = p;
  return KOMIRA_UDF_OK;
}

static void py_unload(komira_udf_udf* u) {
  free(u->entry);
  free(u);
}

/* ---- contexts ------------------------------------------------------------ */

/* Imports the adapter in the entered interpreter and makes the clock
 * callable. */
static int32_t context_setup(struct komira_udf_context* c, komira_udf_error* e) {
  struct pyapi* a = &c->rt->api;
  c->adapter = bootstrap(c->rt);
  if (c->adapter == NULL) return fail_exception(a, e, KOMIRA_UDF_ERR_INTERNAL, "open_context: the adapter");
  c->now_fn = a->PyCMethod_New(&NOW_NS_DEF, NULL, NULL, NULL);
  if (c->now_fn == NULL) return fail_exception(a, e, KOMIRA_UDF_ERR_INTERNAL, "open_context: the clock");
  c->name_release = a->PyUnicode_FromString("release");
  if (c->name_release == NULL) return fail_exception(a, e, KOMIRA_UDF_ERR_INTERNAL, "open_context: a name");
  c->buffer_type = pyrt_buffer_type_new(a);
  if (c->buffer_type == NULL) return fail_exception(a, e, KOMIRA_UDF_ERR_INTERNAL, "open_context: ArrowBuffer");
  return KOMIRA_UDF_OK;
}

static void context_drop_objects(struct komira_udf_context* c) {
  struct pyapi* a = &c->rt->api;
  if (c->now_fn) a->Py_DecRef(c->now_fn);
  if (c->adapter) a->Py_DecRef(c->adapter);
  if (c->name_release) a->Py_DecRef(c->name_release);
  if (c->buffer_type) a->Py_DecRef(c->buffer_type);
  c->now_fn = c->adapter = c->name_release = c->buffer_type = NULL;
}

/* A sub-interpreter with its own GIL. The calling thread first takes a
 * thread state of the main interpreter (Py_NewInterpreterFromConfig needs a
 * current thread state); creating the sub-interpreter releases the main
 * GIL and leaves the new one held. */
static int32_t open_subinterp(struct komira_udf_context* c, komira_udf_error* e) {
  struct komira_udf_rt* rt = c->rt;
  struct pyapi* a = &rt->api;
  PyThreadState* tmp = main_enter(rt);
  if (tmp == NULL) return pyrt_fail(e, KOMIRA_UDF_ERR_INTERNAL, "open_context: no thread state", NULL, -1);
  PyInterpreterConfig cfg;
  memset(&cfg, 0, sizeof(cfg));
  cfg.use_main_obmalloc = 0;
  cfg.allow_fork = 0;
  cfg.allow_exec = 0;
  cfg.allow_threads = 1;
  cfg.allow_daemon_threads = 0;
  cfg.check_multi_interp_extensions = 1;
  cfg.gil = PyInterpreterConfig_OWN_GIL;
  PyThreadState* sub = NULL;
  PyStatus st = a->Py_NewInterpreterFromConfig(&sub, &cfg);
  if (a->PyStatus_Exception(st) || sub == NULL) {
    /* The caller's thread state (tmp) is current again. */
    char msg[512];
    snprintf(msg, sizeof(msg), "open_context: Py_NewInterpreterFromConfig failed: %s",
             st.err_msg ? st.err_msg : "no message");
    main_leave(rt, tmp);
    return pyrt_fail(e, KOMIRA_UDF_ERR_INTERNAL, msg, NULL, -1);
  }
  c->ts = sub;
  int32_t rc = context_setup(c, e);
  if (rc != KOMIRA_UDF_OK) {
    context_drop_objects(c);
    a->Py_EndInterpreter(sub);
  } else {
    pyrt_leave(c);
  }
  /* Back to the temporary main thread state, to delete it. */
  a->PyEval_RestoreThread(tmp);
  main_leave(rt, tmp);
  return rc;
}

static int32_t open_shared(struct komira_udf_context* c, komira_udf_error* e) {
  struct pyapi* a = &c->rt->api;
  c->ts = a->PyThreadState_New(c->rt->main_interp);
  if (c->ts == NULL) return pyrt_fail(e, KOMIRA_UDF_ERR_INTERNAL, "open_context: no thread state", NULL, -1);
  pyrt_enter(c);
  int32_t rc = context_setup(c, e);
  if (rc != KOMIRA_UDF_OK) {
    context_drop_objects(c);
    a->PyThreadState_Clear(c->ts);
    a->PyThreadState_DeleteCurrent();
    return rc;
  }
  pyrt_leave(c);
  return KOMIRA_UDF_OK;
}

static int32_t py_open_context(komira_udf_rt* rt, uint32_t slot, komira_udf_context** out, komira_udf_error* e) {
  komira_udf_context* c = calloc(1, sizeof(*c));
  if (c == NULL) return pyrt_fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "open_context: out of memory", NULL, -1);
  c->rt = rt;
  c->slot = slot;
  c->owner = pthread_self();
  int32_t rc = rt->variant == PYRT_SUBINTERP ? open_subinterp(c, e) : open_shared(c, e);
  if (rc != KOMIRA_UDF_OK) {
    free(c);
    return rc;
  }
  *out = c;
  return KOMIRA_UDF_OK;
}

/* Arrays user code still views when its context closes are released when
 * the interpreter frees the views: for a sub-interpreter, when it ends here;
 * for the shared interpreter, when the objects go, at the latest at
 * finalization (python_call.c, ArrowBuffer). */
/* close_context and close_instance return nothing, so a call from a thread
 * other than the context's (a host that broke thread_affine) cannot be
 * refused with a status: it is logged and the handle is left untouched,
 * still the owner thread's to close. Entering the thread state here would
 * run the interpreter on a thread it does not belong to. */
static int off_owner_thread(komira_udf_context* c, const char* what) {
  if (pthread_equal(c->owner, pthread_self())) return 0;
  const komira_udf_host* h = c->rt->host;
  if (h->log != NULL) {
    char m[160];
    snprintf(m, sizeof(m), "komira-test/python: %s from a thread other than the context's (thread_affine); ignored",
             what);
    h->log(h->host_data, 2, m);
  }
  return 1;
}

static void py_close_context(komira_udf_context* c) {
  if (off_owner_thread(c, "close_context")) return;
  struct komira_udf_rt* rt = c->rt;
  struct pyapi* a = &rt->api;
  pyrt_enter(c);
  context_drop_objects(c);
  if (rt->variant == PYRT_SUBINTERP) {
    a->Py_EndInterpreter(c->ts);
  } else {
    a->PyThreadState_Clear(c->ts);
    a->PyThreadState_DeleteCurrent();
  }
  free(c);
}

/* ---- instances ----------------------------------------------------------- */

static int32_t py_open_instance(komira_udf_context* c, komira_udf_udf* u, komira_udf_instance** out,
                                komira_udf_error* e) {
  if (!pthread_equal(c->owner, pthread_self()))
    return pyrt_fail(e, KOMIRA_UDF_ERR_INTERNAL, "open_instance: the context belongs to another thread", NULL, -1);
  struct pyapi* a = &c->rt->api;
  komira_udf_instance* i = calloc(1, sizeof(*i));
  if (i == NULL) return pyrt_fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "open_instance: out of memory", NULL, -1);
  char args[PYRT_MAX_ARGS + 1];
  memcpy(args, u->arg_fmt, (size_t)u->n_args);
  args[u->n_args] = 0;
  char res[2] = {u->result_fmt, 0};
  pyrt_enter(c);
  PyObject* fn = a->PyUnicode_FromString("open_instance");
  PyObject* pe = a->PyUnicode_FromString(u->entry);
  PyObject* ps = a->PyLong_FromLongLong(u->shape);
  PyObject* pa = a->PyUnicode_FromString(args);
  PyObject* pr = a->PyUnicode_FromString(res);
  PyObject* pn = a->PyLong_FromLongLong(u->null_mode);
  PyObject* r = (fn && pe && ps && pa && pr && pn)
                    ? a->PyObject_CallMethodObjArgs(c->adapter, fn, pe, ps, pa, pr, pn, NULL)
                    : NULL;
  int32_t rc = KOMIRA_UDF_OK;
  if (r == NULL) {
    rc = fail_exception(a, e, KOMIRA_UDF_ERR_INTERNAL, "open_instance");
  } else {
    /* (0, Instance) or (status, message) */
    rc = (int32_t)a->PyLong_AsLongLong(a->PyTuple_GetItem(r, 0));
    PyObject* second = a->PyTuple_GetItem(r, 1);
    if (rc == KOMIRA_UDF_OK) {
      a->Py_IncRef(second);
      i->inst = second;
      i->call = a->PyObject_GetAttrString(second, "call");
      if (i->call == NULL) {
        rc = fail_exception(a, e, KOMIRA_UDF_ERR_INTERNAL, "open_instance: Instance.call");
        a->Py_DecRef(second);
      }
    } else {
      pyrt_fail(e, rc, a->PyUnicode_AsUTF8(second), NULL, -1);
    }
    a->Py_DecRef(r);
  }
  PyObject* objs[] = {fn, pe, ps, pa, pr, pn};
  for (size_t k = 0; k < sizeof(objs) / sizeof(objs[0]); k++)
    if (objs[k]) a->Py_DecRef(objs[k]);
  pyrt_leave(c);
  if (rc != KOMIRA_UDF_OK) {
    free(i);
    return rc;
  }
  i->ctx = c;
  i->udf = u;
  *out = i;
  return KOMIRA_UDF_OK;
}

static void py_close_instance(komira_udf_instance* i) {
  struct komira_udf_context* c = i->ctx;
  if (off_owner_thread(c, "close_instance")) return;
  pyrt_enter(c);
  c->rt->api.Py_DecRef(i->call);
  c->rt->api.Py_DecRef(i->inst);
  pyrt_leave(c);
  free(i);
}

/* ---- the shapes this runtime does not declare ---------------------------- */
/* The host never calls these for a spec validate refused; each still moves
 * and releases what the ABI moves into it. */

static void release_device(struct ArrowDeviceArray* d) {
  if (d != NULL && d->array.release != NULL) d->array.release(&d->array);
}

static int32_t py_frame_open(komira_udf_instance* i, const komira_udf_call* call, struct ArrowDeviceArrayStream* in,
                             komira_udf_frame** out, komira_udf_error* e) {
  (void)i;
  (void)call;
  (void)out;
  if (in != NULL && in->release != NULL) in->release(in);
  return pyrt_fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "frames are not in this runtime's shapes", NULL, -1);
}

static int32_t py_frame_next(komira_udf_frame* f, const komira_udf_call* call, struct ArrowDeviceArray* out,
                             komira_udf_error* e) {
  (void)f;
  (void)call;
  out->array.release = NULL;
  return pyrt_fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "frames are not in this runtime's shapes", NULL, -1);
}

static void py_frame_close(komira_udf_frame* f) { (void)f; }

static int32_t py_agg_open(komira_udf_instance* i, komira_udf_groups** out, komira_udf_error* e) {
  (void)i;
  (void)out;
  return pyrt_fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "aggregates are not in this runtime's shapes", NULL, -1);
}

static int32_t py_agg_update(komira_udf_groups* g, const komira_udf_call* call, struct ArrowDeviceArray* args,
                             struct ArrowDeviceArray* ids, uint32_t n, komira_udf_error* e) {
  (void)g;
  (void)call;
  (void)n;
  release_device(args);
  release_device(ids);
  return pyrt_fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "aggregates are not in this runtime's shapes", NULL, -1);
}

static int32_t py_agg_emit(komira_udf_groups* g, uint32_t n, struct ArrowDeviceArray* out, komira_udf_error* e) {
  (void)g;
  (void)n;
  out->array.release = NULL;
  return pyrt_fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "aggregates are not in this runtime's shapes", NULL, -1);
}

static void py_agg_close(komira_udf_groups* g) { (void)g; }

/* ---- shutdown and init --------------------------------------------------- */

static void py_shutdown(komira_udf_rt* rt) {
  struct pyapi* a = &rt->api;
  if (pthread_equal(rt->init_thread, pthread_self())) {
    a->PyEval_RestoreThread(rt->main_ts);
    a->Py_DecRef(rt->main_adapter);
    a->Py_FinalizeEx();
  } else if (rt->host->log != NULL) {
    /* CPython finalizes on the thread that initialized it; the interpreter
     * is left as it is (and any array user code still views with it). */
    rt->host->log(rt->host->host_data, 2, "komira-test/python: shutdown off the init thread; not finalized");
  }
  g_rt = NULL;
  free(rt);
}

static const komira_udf_runtime TABLE = {
    sizeof(komira_udf_runtime),
    KOMIRA_UDF_ABI_MAJOR,
    KOMIRA_UDF_ABI_MINOR,
    py_describe,
    py_validate,
    py_load,
    py_unload,
    py_open_context,
    py_close_context,
    py_open_instance,
    py_close_instance,
    pyrt_call_batch,
    py_frame_open,
    py_frame_next,
    py_frame_close,
    py_agg_open,
    py_agg_update,
    py_agg_update, /* agg_merge: the same refusal, the same moves */
    py_agg_emit,   /* agg_state */
    py_agg_emit,   /* agg_finish */
    py_agg_close,
    py_shutdown,
    NULL, /* memory_report: the MEMORY_REPORT feature is clear */
};

/* The directory holding this library, from its loaded path (the path the
 * host opened it by, not resolved through symbolic links), made absolute. */
static int own_dir(char* out, size_t n) {
  Dl_info info;
  if (dladdr((void*)&own_dir, &info) == 0 || info.dli_fname == NULL) return 0;
  const char* name = info.dli_fname;
  const char* slash = strrchr(name, '/');
  size_t len = slash == NULL ? 0 : (size_t)(slash - name);
  size_t at = 0;
  if (name[0] != '/') {
    if (getcwd(out, n) == NULL) return 0;
    at = strlen(out);
    if (len > 0 && at + 1 < n) out[at++] = '/';
  }
  if (at + len + 1 > n) return 0;
  memcpy(out + at, name, len);
  out[at + len] = 0;
  return 1;
}

static const komira_udf_runtime* init(const komira_udf_host* host, komira_udf_rt** out, komira_udf_error* e,
                                      enum pyrt_variant variant) {
  if (host == NULL || host->struct_size < sizeof(komira_udf_host) || host->abi_major != KOMIRA_UDF_ABI_MAJOR) {
    pyrt_fail(e, KOMIRA_UDF_ERR_ABI, "this runtime speaks ABI major 1", NULL, -1);
    return NULL;
  }
  if (__atomic_exchange_n(&g_initialized, 1, __ATOMIC_ACQ_REL)) {
    pyrt_fail(e, KOMIRA_UDF_ERR_INTERNAL, "init runs once per process; CPython is not initialized twice here", NULL,
              -1);
    return NULL;
  }
  komira_udf_rt* rt = calloc(1, sizeof(*rt));
  if (rt == NULL) {
    pyrt_fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "init: out of memory", NULL, -1);
    return NULL;
  }
  rt->host = host;
  rt->variant = variant;
  rt->init_thread = pthread_self();
  char why[1400];
  char lib[1200];
  if (!own_dir(rt->dir, sizeof(rt->dir))) {
    pyrt_fail(e, KOMIRA_UDF_ERR_LOAD, "init: cannot find the runtime library's own directory", NULL, -1);
    free(rt);
    return NULL;
  }
  snprintf(lib, sizeof(lib), "%s/python/lib/libpython3.13.so.1.0", rt->dir);
  if (!pyapi_load(&rt->api, lib, why, sizeof(why))) {
    pyrt_fail(e, KOMIRA_UDF_ERR_LOAD, why, NULL, -1);
    free(rt);
    return NULL;
  }
  struct pyapi* a = &rt->api;
  if (strncmp(a->Py_GetVersion(), "3.13.", 5) != 0) {
    snprintf(why, sizeof(why), "init: libpython is %s; this runtime is built for 3.13", a->Py_GetVersion());
    pyrt_fail(e, KOMIRA_UDF_ERR_LOAD, why, NULL, -1);
    free(rt);
    return NULL;
  }
  PyConfig cfg;
  a->PyConfig_InitIsolatedConfig(&cfg);
  cfg.install_signal_handlers = 0;
  cfg.site_import = 0;
  cfg.parse_argv = 0;
  snprintf(lib, sizeof(lib), "%s/python", rt->dir);
  PyStatus st = a->PyConfig_SetBytesString(&cfg, &cfg.home, lib);
  if (!a->PyStatus_Exception(st)) st = a->Py_InitializeFromConfig(&cfg);
  a->PyConfig_Clear(&cfg);
  if (a->PyStatus_Exception(st)) {
    snprintf(why, sizeof(why), "init: Py_InitializeFromConfig: %s", st.err_msg ? st.err_msg : "failed");
    pyrt_fail(e, KOMIRA_UDF_ERR_LOAD, why, NULL, -1);
    free(rt);
    return NULL;
  }
  rt->main_interp = a->PyInterpreterState_Main();
  g_rt = rt;
  pyrt_set_api(&rt->api);
  rt->main_adapter = bootstrap(rt);
  if (rt->main_adapter == NULL) {
    char* x = pyrt_take_exception(a);
    snprintf(why, sizeof(why), "init: the adapter: %s", x);
    free(x);
    pyrt_fail(e, KOMIRA_UDF_ERR_LOAD, why, NULL, -1);
    a->Py_FinalizeEx();
    free(rt);
    return NULL;
  }
  rt->main_ts = a->PyEval_SaveThread();
  *out = rt;
  return &TABLE;
}

const komira_udf_runtime* komira_udf_python_subinterp_init_v1(const komira_udf_host* host, komira_udf_rt** rt,
                                                              komira_udf_error* e) {
  return init(host, rt, e, PYRT_SUBINTERP);
}

const komira_udf_runtime* komira_udf_python_shared_gil_init_v1(const komira_udf_host* host, komira_udf_rt** rt,
                                                               komira_udf_error* e) {
  return init(host, rt, e, PYRT_SHARED_GIL);
}
