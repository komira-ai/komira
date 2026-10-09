/*
 * komira-test/python-row: a UDF runtime that embeds CPython and runs
 * row-shaped UDFs (shape ROW, docs/design/udf_runtime_interface.md sections
 * 3.1 and 4.3) behind the table of komira_udf_runtime.h. Test-only spike
 * code: it measures what a declared read set saves.
 *
 * A ROW UDF is a plain Python function of one row (`def f(row) -> float`).
 * The spec's argument struct is its read set: one named field each, the
 * names user code reads. load binds the names; per batch the adapter
 * (komira_udf_rowrt.py) builds one row object per row over the struct's
 * children only, and a read of any other name fails the batch with
 * ERR_FIELD_NOT_DECLARED naming the field, even when user code catches the
 * language's exception.
 *
 * Contexts are sub-interpreters with their own GIL, one per engine thread
 * (the design's mode 2): CONTEXT_PER_THREAD, global_lock 0, thread_affine 1.
 * A context's PyThreadState belongs to the engine thread that opened it,
 * which enters it with PyEval_RestoreThread and leaves it with
 * PyEval_SaveThread on every call; PyGILState_* is never used.
 *
 * Where things are. The runtime finds everything beside its own library file
 * (dladdr), because init carries no configuration:
 *   <dir>/python/   a CPython 3.13 install (home); libpython in lib/
 *   <dir>/pyrt/     the adapter komira_udf_rowrt.py and the user modules
 * User code is `module:qualname`, imported from that path in each context's
 * interpreter by open_instance; validate reads its source only.
 *
 * FFI-BOUNDARY. Owners: the rt, udf, context and instance structs are this
 * runtime's, freed by shutdown, unload, close_context and close_instance.
 * Every PyObject* field holds one strong reference, dropped (Py_DecRef) with
 * its interpreter entered, before the interpreter ends. libpython is loaded
 * once and never closed. Arrow arrays: row_call.c.
 */
#include "rowrt.h" /* first: Python.h sets the feature macros */

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define RT_ID "komira-test/python-row"

/* init runs once per process: CPython is not re-initialized here. */
static int g_initialized;

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

/* `s` on one line (the ABI's message is one line). */
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

int32_t rowrt_fail(komira_udf_error* e, int32_t code, const char* msg, const char* trace, int64_t row) {
  if (e == NULL || e->struct_size < sizeof(komira_udf_error)) return code;
  e->code = code;
  e->message = one_line(msg != NULL && msg[0] ? msg : "the Python row runtime failed");
  e->user_trace = dup_str(trace);
  e->row = row;
  e->group = -1;
  e->release = free_error;
  return code;
}

char* rowrt_take_exception(const struct rowpy* api) {
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

static int32_t fail_exception(struct rowpy* api, komira_udf_error* e, int32_t code, const char* what) {
  char* x = rowrt_take_exception(api);
  char msg[1024];
  snprintf(msg, sizeof(msg), "%s: %s", what, x);
  free(x);
  return rowrt_fail(e, code, msg, NULL, -1);
}

/* ---- interpreter entry --------------------------------------------------- */

void rowrt_enter(struct komira_udf_context* c) { c->rt->api.PyEval_RestoreThread(c->ts); }

void rowrt_leave(struct komira_udf_context* c) { (void)c->rt->api.PyEval_SaveThread(); }

/* A thread state of the main interpreter for this thread, entered, for
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

/* sys.path gets <dir>/pyrt first; then the adapter is imported. Returns a
 * new reference, or NULL with the exception set. */
static PyObject* bootstrap(struct komira_udf_rt* rt) {
  struct rowpy* a = &rt->api;
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
  return a->PyImport_ImportModule("komira_udf_rowrt");
}

/* ---- describe / validate / load ------------------------------------------ */

static int32_t row_describe(komira_udf_rt* rt, komira_udf_capabilities* c) {
  (void)rt;
  if (c == NULL || c->struct_size < sizeof(komira_udf_capabilities)) return KOMIRA_UDF_ERR_ABI;
  c->runtime_id = RT_ID;
  c->runtime_abi = "cp313";
  c->max_descriptor_version = 0;
  c->shapes = KOMIRA_UDF_SHAPE_ROW;
  c->threading = KOMIRA_UDF_CONTEXT_PER_THREAD;
  c->thread_affine = 1;
  c->transports = KOMIRA_UDF_TRANSPORT_IN_PROCESS;
  c->hosting = KOMIRA_UDF_HOSTING_EMBEDDED;
  c->devices = KOMIRA_UDF_DEVICE_CPU;
  c->features = 0;
  c->udf_class = KOMIRA_UDF_CLASS_MANAGED;
  c->global_lock = 0;
  return KOMIRA_UDF_OK;
}

static int leaf_fmt(const struct ArrowSchema* s, char* fmt) {
  if (s == NULL || s->format == NULL || s->n_children != 0 || s->format[0] == 0 || s->format[1] != 0) return 0;
  if (s->format[0] != 'l' && s->format[0] != 'g') return 0;
  *fmt = s->format[0];
  return 1;
}

static void free_udf(struct komira_udf_udf* u) {
  if (u == NULL) return;
  for (int i = 0; u->names != NULL && i < u->n; i++) free(u->names[i]);
  free(u->names);
  free(u->fmts);
  free(u->entry);
  free(u);
}

/* The checks that need no interpreter: sizes, form, entry grammar,
 * descriptor, shape, null mode, and the read set (named fields, each name
 * non-empty and unique, of a type this runtime maps). Returns a filled udf,
 * or NULL with `e` filled and *rc set. */
static struct komira_udf_udf* check_spec(const komira_udf_spec* s, komira_udf_error* e, int32_t* rc) {
#define REFUSE(code, msg)                         \
  do {                                            \
    *rc = rowrt_fail(e, (code), (msg), NULL, -1); \
    free_udf(u);                                  \
    return NULL;                                  \
  } while (0)
  struct komira_udf_udf* u = NULL;
  if (s == NULL || s->struct_size < sizeof(komira_udf_spec))
    REFUSE(KOMIRA_UDF_ERR_ABI, "spec struct_size is below this runtime's");
  if (s->form == KOMIRA_UDF_FORM_VALUE)
    REFUSE(KOMIRA_UDF_ERR_UNSUPPORTED, "code form VALUE (a serialized function) is not read by this runtime");
  if (s->form != KOMIRA_UDF_FORM_PACKAGE && s->form != KOMIRA_UDF_FORM_BUNDLE)
    REFUSE(KOMIRA_UDF_ERR_DESCRIPTOR, "code form is not PACKAGE, BUNDLE or VALUE");
  const char* colon = s->entry ? strchr(s->entry, ':') : NULL;
  if (colon == NULL || colon == s->entry || colon[1] == 0 || strchr(colon + 1, ':') != NULL)
    REFUSE(KOMIRA_UDF_ERR_DESCRIPTOR, "entry is not <module>:<function>");
  if (s->descriptor_version > 0)
    REFUSE(KOMIRA_UDF_ERR_DESCRIPTOR, "descriptor_version is newer than 0, the newest read here");
  if (s->descriptor_len != 0)
    REFUSE(KOMIRA_UDF_ERR_DESCRIPTOR, "descriptor version 0 is empty; these bytes are not canonical");
  if (s->n_code != 0) REFUSE(KOMIRA_UDF_ERR_UNSUPPORTED, "code objects are not read by this runtime (spike)");
  if (s->shape != (int32_t)KOMIRA_UDF_SHAPE_ROW) REFUSE(KOMIRA_UDF_ERR_UNSUPPORTED, "this runtime runs ROW UDFs only");
  if (s->null_mode != KOMIRA_UDF_NULL_MANUAL)
    REFUSE(KOMIRA_UDF_ERR_UNSUPPORTED, "a ROW UDF is MANUAL: the row sees its nulls (OPTIMIZED_UDF_ROW_NULL_MODE)");
  if (s->args == NULL || s->args->format == NULL || strcmp(s->args->format, "+s") != 0 || s->args->n_children < 0)
    REFUSE(KOMIRA_UDF_ERR_UNSUPPORTED, "args is not a struct");
  if (s->state != NULL) REFUSE(KOMIRA_UDF_ERR_UNSUPPORTED, "a state type is for aggregates");
  u = calloc(1, sizeof(*u));
  if (u == NULL) REFUSE(KOMIRA_UDF_ERR_OUT_OF_MEMORY, "load: out of memory");
  u->n = (int)s->args->n_children;
  u->names = calloc((size_t)(u->n > 0 ? u->n : 1), sizeof(char*));
  u->fmts = calloc((size_t)u->n + 1, 1);
  u->entry = dup_str(s->entry);
  if (u->names == NULL || u->fmts == NULL || u->entry == NULL) REFUSE(KOMIRA_UDF_ERR_OUT_OF_MEMORY, "load: out of memory");
  for (int i = 0; i < u->n; i++) {
    const struct ArrowSchema* f = s->args->children[i];
    if (!leaf_fmt(f, &u->fmts[i])) REFUSE(KOMIRA_UDF_ERR_UNSUPPORTED, "a read-set field's type is not int64 or float64");
    if (f->name == NULL || f->name[0] == 0)
      REFUSE(KOMIRA_UDF_ERR_UNSUPPORTED, "the read set has a field with no name (OPTIMIZED_UDF_ROW_READ_SET_INVALID)");
    for (int j = 0; j < i; j++)
      if (strcmp(u->names[j], f->name) == 0)
        REFUSE(KOMIRA_UDF_ERR_UNSUPPORTED, "the read set names a field twice (OPTIMIZED_UDF_ROW_READ_SET_INVALID)");
    u->names[i] = dup_str(f->name);
    if (u->names[i] == NULL) REFUSE(KOMIRA_UDF_ERR_OUT_OF_MEMORY, "load: out of memory");
  }
  if (!leaf_fmt(s->result, &u->result_fmt))
    REFUSE(KOMIRA_UDF_ERR_UNSUPPORTED, "the result type is not int64 or float64");
  *rc = KOMIRA_UDF_OK;
  return u;
#undef REFUSE
}

/* The adapter's arguments for `u`: (entry, [names], fmts, result_fmt), as
 * new references in `o`; 0 when one could not be made. */
static int udf_args(struct rowpy* a, const struct komira_udf_udf* u, PyObject* o[4]) {
  char res[2] = {u->result_fmt, 0};
  o[0] = a->PyUnicode_FromString(u->entry);
  o[1] = a->PyList_New(u->n);
  o[2] = a->PyUnicode_FromString(u->fmts);
  o[3] = a->PyUnicode_FromString(res);
  for (int i = 0; o[1] != NULL && i < u->n; i++) {
    PyObject* n = a->PyUnicode_FromString(u->names[i]);
    if (n == NULL) return 0;
    a->PyList_SetItem(o[1], i, n); /* steals */
  }
  return o[0] && o[1] && o[2] && o[3];
}

static void drop_all(struct rowpy* a, PyObject** o, int n) {
  for (int i = 0; i < n; i++)
    if (o[i]) a->Py_DecRef(o[i]);
}

/* The adapter's static check (komira_udf_rowrt.validate: the module's
 * source, parsed, never run), in the main interpreter. */
static int32_t check_source(struct komira_udf_rt* rt, const struct komira_udf_udf* u, komira_udf_error* e) {
  struct rowpy* a = &rt->api;
  PyThreadState* ts = main_enter(rt);
  if (ts == NULL) return rowrt_fail(e, KOMIRA_UDF_ERR_INTERNAL, "validate: no thread state", NULL, -1);
  PyObject* o[5] = {NULL, NULL, NULL, NULL, NULL};
  int ok = udf_args(a, u, o);
  o[4] = a->PyUnicode_FromString("validate");
  PyObject* r = ok && o[4] ? a->PyObject_CallMethodObjArgs(rt->main_adapter, o[4], o[0], o[1], o[2], o[3], NULL) : NULL;
  int32_t rc;
  if (r == NULL) {
    rc = fail_exception(a, e, KOMIRA_UDF_ERR_INTERNAL, "validate");
  } else {
    rc = (int32_t)a->PyLong_AsLongLong(a->PyTuple_GetItem(r, 0));
    if (rc != KOMIRA_UDF_OK) rowrt_fail(e, rc, a->PyUnicode_AsUTF8(a->PyTuple_GetItem(r, 1)), NULL, -1);
    a->Py_DecRef(r);
  }
  drop_all(a, o, 5);
  main_leave(rt, ts);
  return rc;
}

static int32_t row_validate(komira_udf_rt* rt, const komira_udf_spec* s, komira_udf_error* e) {
  int32_t rc;
  struct komira_udf_udf* u = check_spec(s, e, &rc);
  if (u == NULL) return rc;
  rc = check_source(rt, u, e);
  free_udf(u);
  return rc;
}

static int32_t row_load(komira_udf_rt* rt, const komira_udf_spec* s, komira_udf_udf** out, komira_udf_error* e) {
  int32_t rc;
  struct komira_udf_udf* u = check_spec(s, e, &rc);
  if (u == NULL) return rc;
  rc = check_source(rt, u, e);
  if (rc != KOMIRA_UDF_OK) {
    free_udf(u);
    return rc;
  }
  *out = u;
  return KOMIRA_UDF_OK;
}

static void row_unload(komira_udf_udf* u) { free_udf(u); }

/* ---- contexts ------------------------------------------------------------ */

static void context_drop_objects(struct komira_udf_context* c) {
  struct rowpy* a = &c->rt->api;
  if (c->adapter) a->Py_DecRef(c->adapter);
  if (c->name_release) a->Py_DecRef(c->name_release);
  if (c->buffer_type) a->Py_DecRef(c->buffer_type);
  c->adapter = c->name_release = c->buffer_type = NULL;
}

/* Imports the adapter in the entered interpreter and makes its objects. */
static int32_t context_setup(struct komira_udf_context* c, komira_udf_error* e) {
  struct rowpy* a = &c->rt->api;
  c->adapter = bootstrap(c->rt);
  if (c->adapter == NULL) return fail_exception(a, e, KOMIRA_UDF_ERR_INTERNAL, "open_context: the adapter");
  c->name_release = a->PyUnicode_FromString("release");
  if (c->name_release == NULL) return fail_exception(a, e, KOMIRA_UDF_ERR_INTERNAL, "open_context: a name");
  c->buffer_type = rowrt_buffer_type_new(a);
  if (c->buffer_type == NULL) return fail_exception(a, e, KOMIRA_UDF_ERR_INTERNAL, "open_context: ArrowBuffer");
  return KOMIRA_UDF_OK;
}

/* A sub-interpreter with its own GIL. The calling thread first takes a
 * thread state of the main interpreter (Py_NewInterpreterFromConfig needs a
 * current thread state); creating the sub-interpreter releases the main
 * GIL and leaves the new one held. */
static int32_t row_open_context(komira_udf_rt* rt, uint32_t slot, komira_udf_context** out, komira_udf_error* e) {
  struct rowpy* a = &rt->api;
  komira_udf_context* c = calloc(1, sizeof(*c));
  if (c == NULL) return rowrt_fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "open_context: out of memory", NULL, -1);
  c->rt = rt;
  c->slot = slot;
  c->owner = pthread_self();
  PyThreadState* tmp = main_enter(rt);
  if (tmp == NULL) {
    free(c);
    return rowrt_fail(e, KOMIRA_UDF_ERR_INTERNAL, "open_context: no thread state", NULL, -1);
  }
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
    char msg[512];
    snprintf(msg, sizeof(msg), "open_context: Py_NewInterpreterFromConfig failed: %s",
             st.err_msg ? st.err_msg : "no message");
    main_leave(rt, tmp);
    free(c);
    return rowrt_fail(e, KOMIRA_UDF_ERR_INTERNAL, msg, NULL, -1);
  }
  c->ts = sub;
  int32_t rc = context_setup(c, e);
  if (rc != KOMIRA_UDF_OK) {
    context_drop_objects(c);
    a->Py_EndInterpreter(sub);
  } else {
    rowrt_leave(c);
  }
  a->PyEval_RestoreThread(tmp);
  main_leave(rt, tmp);
  if (rc != KOMIRA_UDF_OK) {
    free(c);
    return rc;
  }
  *out = c;
  return KOMIRA_UDF_OK;
}

/* close_context and close_instance return nothing, so a call from a thread
 * other than the context's cannot be refused with a status: it is logged
 * and the handle is left to the owner thread. */
static int off_owner_thread(komira_udf_context* c, const char* what) {
  if (pthread_equal(c->owner, pthread_self())) return 0;
  const komira_udf_host* h = c->rt->host;
  if (h->log != NULL) {
    char m[160];
    snprintf(m, sizeof(m), RT_ID ": %s from a thread other than the context's (thread_affine); ignored", what);
    h->log(h->host_data, 2, m);
  }
  return 1;
}

/* Arrays user code still views when its context closes are released when
 * the interpreter frees the views, at the latest when it ends here. */
static void row_close_context(komira_udf_context* c) {
  if (off_owner_thread(c, "close_context")) return;
  rowrt_enter(c);
  context_drop_objects(c);
  c->rt->api.Py_EndInterpreter(c->ts);
  free(c);
}

/* ---- instances ----------------------------------------------------------- */

static int32_t row_open_instance(komira_udf_context* c, komira_udf_udf* u, komira_udf_instance** out,
                                 komira_udf_error* e) {
  if (!pthread_equal(c->owner, pthread_self()))
    return rowrt_fail(e, KOMIRA_UDF_ERR_INTERNAL, "open_instance: the context belongs to another thread", NULL, -1);
  struct rowpy* a = &c->rt->api;
  komira_udf_instance* i = calloc(1, sizeof(*i));
  if (i == NULL) return rowrt_fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "open_instance: out of memory", NULL, -1);
  rowrt_enter(c);
  PyObject* o[5] = {NULL, NULL, NULL, NULL, NULL};
  int ok = udf_args(a, u, o);
  o[4] = a->PyUnicode_FromString("open_instance");
  PyObject* r = ok && o[4] ? a->PyObject_CallMethodObjArgs(c->adapter, o[4], o[0], o[1], o[2], o[3], NULL) : NULL;
  int32_t rc = KOMIRA_UDF_OK;
  if (r == NULL) {
    rc = fail_exception(a, e, KOMIRA_UDF_ERR_INTERNAL, "open_instance");
  } else {
    /* (0, RowInstance) or (status, message) */
    rc = (int32_t)a->PyLong_AsLongLong(a->PyTuple_GetItem(r, 0));
    PyObject* second = a->PyTuple_GetItem(r, 1);
    if (rc == KOMIRA_UDF_OK) {
      a->Py_IncRef(second);
      i->inst = second;
      i->call = a->PyObject_GetAttrString(second, "call");
      if (i->call == NULL) {
        rc = fail_exception(a, e, KOMIRA_UDF_ERR_INTERNAL, "open_instance: RowInstance.call");
        a->Py_DecRef(second);
      }
    } else {
      rowrt_fail(e, rc, a->PyUnicode_AsUTF8(second), NULL, -1);
    }
    a->Py_DecRef(r);
  }
  drop_all(a, o, 5);
  rowrt_leave(c);
  if (rc != KOMIRA_UDF_OK) {
    free(i);
    return rc;
  }
  i->ctx = c;
  i->udf = u;
  *out = i;
  return KOMIRA_UDF_OK;
}

static void row_close_instance(komira_udf_instance* i) {
  struct komira_udf_context* c = i->ctx;
  if (off_owner_thread(c, "close_instance")) return;
  rowrt_enter(c);
  c->rt->api.Py_DecRef(i->call);
  c->rt->api.Py_DecRef(i->inst);
  rowrt_leave(c);
  free(i);
}

/* ---- the shapes this runtime does not declare ---------------------------- */
/* The host never calls these for a spec validate refused; each still moves
 * and releases what the ABI moves into it. */

static void release_device(struct ArrowDeviceArray* d) {
  if (d != NULL && d->array.release != NULL) d->array.release(&d->array);
}

static int32_t row_frame_open(komira_udf_instance* i, const komira_udf_call* call, struct ArrowDeviceArrayStream* in,
                              komira_udf_frame** out, komira_udf_error* e) {
  (void)i;
  (void)call;
  (void)out;
  if (in != NULL && in->release != NULL) in->release(in);
  return rowrt_fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "frames are not in this runtime's shapes", NULL, -1);
}

static int32_t row_frame_next(komira_udf_frame* f, const komira_udf_call* call, struct ArrowDeviceArray* out,
                              komira_udf_error* e) {
  (void)f;
  (void)call;
  out->array.release = NULL;
  return rowrt_fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "frames are not in this runtime's shapes", NULL, -1);
}

static void row_frame_close(komira_udf_frame* f) { (void)f; }

static int32_t row_agg_open(komira_udf_instance* i, komira_udf_groups** out, komira_udf_error* e) {
  (void)i;
  (void)out;
  return rowrt_fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "aggregates are not in this runtime's shapes", NULL, -1);
}

static int32_t row_agg_update(komira_udf_groups* g, const komira_udf_call* call, struct ArrowDeviceArray* args,
                              struct ArrowDeviceArray* ids, uint32_t n, komira_udf_error* e) {
  (void)g;
  (void)call;
  (void)n;
  release_device(args);
  release_device(ids);
  return rowrt_fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "aggregates are not in this runtime's shapes", NULL, -1);
}

static int32_t row_agg_emit(komira_udf_groups* g, uint32_t n, struct ArrowDeviceArray* out, komira_udf_error* e) {
  (void)g;
  (void)n;
  out->array.release = NULL;
  return rowrt_fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "aggregates are not in this runtime's shapes", NULL, -1);
}

static void row_agg_close(komira_udf_groups* g) { (void)g; }

/* ---- shutdown and init --------------------------------------------------- */

static void row_shutdown(komira_udf_rt* rt) {
  struct rowpy* a = &rt->api;
  if (pthread_equal(rt->init_thread, pthread_self())) {
    a->PyEval_RestoreThread(rt->main_ts);
    a->Py_DecRef(rt->main_adapter);
    a->Py_FinalizeEx();
  } else if (rt->host->log != NULL) {
    /* CPython finalizes on the thread that initialized it. */
    rt->host->log(rt->host->host_data, 2, RT_ID ": shutdown off the init thread; not finalized");
  }
  free(rt);
}

static const komira_udf_runtime TABLE = {
    sizeof(komira_udf_runtime),
    KOMIRA_UDF_ABI_MAJOR,
    KOMIRA_UDF_ABI_MINOR,
    row_describe,
    row_validate,
    row_load,
    row_unload,
    row_open_context,
    row_close_context,
    row_open_instance,
    row_close_instance,
    rowrt_call_batch,
    row_frame_open,
    row_frame_next,
    row_frame_close,
    row_agg_open,
    row_agg_update,
    row_agg_update, /* agg_merge: the same refusal, the same moves */
    row_agg_emit,   /* agg_state */
    row_agg_emit,   /* agg_finish */
    row_agg_close,
    row_shutdown,
    NULL, /* memory_report: the MEMORY_REPORT feature is clear */
};

/* The directory holding this library, from its loaded path, made absolute. */
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

static const komira_udf_runtime* init_fail(komira_udf_rt* rt, komira_udf_error* e, int32_t code, const char* why) {
  rowrt_fail(e, code, why, NULL, -1);
  free(rt);
  return NULL;
}

const komira_udf_runtime* komira_udf_python_row_init_v1(const komira_udf_host* host, komira_udf_rt** out,
                                                        komira_udf_error* e) {
  if (host == NULL || host->struct_size < sizeof(komira_udf_host) || host->abi_major != KOMIRA_UDF_ABI_MAJOR) {
    rowrt_fail(e, KOMIRA_UDF_ERR_ABI, "this runtime speaks ABI major 1", NULL, -1);
    return NULL;
  }
  if (__atomic_exchange_n(&g_initialized, 1, __ATOMIC_ACQ_REL)) {
    rowrt_fail(e, KOMIRA_UDF_ERR_INTERNAL, "init runs once per process; CPython is not initialized twice here", NULL,
               -1);
    return NULL;
  }
  komira_udf_rt* rt = calloc(1, sizeof(*rt));
  if (rt == NULL) return init_fail(rt, e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "init: out of memory");
  rt->host = host;
  rt->init_thread = pthread_self();
  char why[1400];
  char lib[1200];
  if (!own_dir(rt->dir, sizeof(rt->dir)))
    return init_fail(rt, e, KOMIRA_UDF_ERR_LOAD, "init: cannot find the runtime library's own directory");
  snprintf(lib, sizeof(lib), "%s/python/lib/libpython3.13.so.1.0", rt->dir);
  if (!rowpy_load(&rt->api, lib, why, sizeof(why))) return init_fail(rt, e, KOMIRA_UDF_ERR_LOAD, why);
  struct rowpy* a = &rt->api;
  if (strncmp(a->Py_GetVersion(), "3.13.", 5) != 0) {
    snprintf(why, sizeof(why), "init: libpython is %s; this runtime is built for 3.13", a->Py_GetVersion());
    return init_fail(rt, e, KOMIRA_UDF_ERR_LOAD, why);
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
    return init_fail(rt, e, KOMIRA_UDF_ERR_LOAD, why);
  }
  rt->main_interp = a->PyInterpreterState_Main();
  rowrt_set_api(&rt->api);
  rt->main_adapter = bootstrap(rt);
  if (rt->main_adapter == NULL) {
    char* x = rowrt_take_exception(a);
    snprintf(why, sizeof(why), "init: the adapter: %s", x);
    free(x);
    a->Py_FinalizeEx();
    return init_fail(rt, e, KOMIRA_UDF_ERR_LOAD, why);
  }
  rt->main_ts = a->PyEval_SaveThread();
  *out = rt;
  return &TABLE;
}
