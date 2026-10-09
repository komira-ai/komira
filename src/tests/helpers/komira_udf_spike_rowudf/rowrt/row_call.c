/*
 * call_batch of the row runtime (row_runtime.c), for the ROW shape.
 *
 * The argument struct is the read set: one child per declared field, in the
 * order load bound them (design section 3.4, rule 5: for a ROW, the
 * children are exactly the read set). A struct with another child count is
 * refused before any of it is read, so a host that passes columns outside
 * the read set fails here rather than handing user code a field it did not
 * declare.
 *
 * FFI-BOUNDARY. `args` is moved in on entry, whatever the status (design
 * section 4.4): its struct is copied into an owner block and the host's
 * slot cleared. Its buffers reach Python without a copy, each through an
 * ArrowBuffer object (a buffer exporter holding one reference on the owner)
 * and a memoryview over it. The owner's references are atomic: one for the
 * call, one per ArrowBuffer. The last one to go releases the array, so the
 * array lives exactly as long as Python holds a view of any of its buffers
 * and is released when the call returns otherwise. The adapter drops its
 * row objects' access to the views when the call returns, and a row carries
 * the number of the batch that made it, so a row kept past its batch raises
 * when read, also in a later batch of the same instance. An ArrowBuffer
 * goes when its interpreter frees it, on the thread that holds that
 * interpreter; the release it may run is the host's and takes no lock of
 * this runtime.
 *
 * The adapter checks the cancel flag before each row and reads the host's
 * clock (c->now_fn) after row 0 and every CLOCK_EVERY rows, failing the
 * batch with ERR_DEADLINE once the deadline (0: none) has passed.
 *
 * `out` is moved to the host on success: one malloc block (buffer list,
 * validity, values), freed by its release, which takes no interpreter lock
 * and runs on any thread. The adapter writes each row's result straight
 * into that block through writable memoryviews, released before return.
 */
#include "rowrt.h" /* first: Python.h sets the feature macros */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* A non-NULL address for the view of an empty buffer. */
static const uint64_t EMPTY_BUF[1];

struct col_block {
  const void* bufs[2];
};

static void release_col(struct ArrowArray* a) {
  free(a->private_data);
  a->release = NULL;
}

/* A primitive array of `n` rows of 8-byte values, all valid; the adapter
 * writes the values and clears validity bits for nulls. */
static int make_col(struct ArrowArray* a, int64_t n, uint8_t** validity, void** data) {
  size_t vbytes = (size_t)((n + 7) / 8);
  struct col_block* b = malloc(sizeof(struct col_block) + vbytes + (size_t)n * 8 + 8);
  if (b == NULL) return 0;
  uint8_t* v = (uint8_t*)(b + 1);
  memset(v, 0xFF, vbytes);
  void* d = (void*)(((uintptr_t)(v + vbytes) + 7) & ~(uintptr_t)7);
  b->bufs[0] = v;
  b->bufs[1] = d;
  a->length = n;
  a->null_count = 0;
  a->offset = 0;
  a->n_buffers = 2;
  a->n_children = 0;
  a->buffers = b->bufs;
  a->children = NULL;
  a->dictionary = NULL;
  a->release = release_col;
  a->private_data = b;
  *validity = v;
  *data = d;
  return 1;
}

static void set_cpu(struct ArrowDeviceArray* d) {
  d->device_id = -1;
  d->device_type = ARROW_DEVICE_CPU;
  d->sync_event = NULL;
  d->reserved[0] = d->reserved[1] = d->reserved[2] = 0;
}

static int cancelled(const komira_udf_call* c) {
  return c->cancel != NULL && __atomic_load_n(c->cancel, __ATOMIC_ACQUIRE) != 0;
}

/* The argument struct's layout against the read set, before any of it is
 * read. Writes the reason into `why`; returns 0 when it does not fit. */
static int args_fit(const struct ArrowArray* in, const struct komira_udf_udf* u, char* why, size_t len) {
  if (in->n_children != u->n) {
    snprintf(why, len, "args has %lld children; the read set has %d fields (only the read set crosses)",
             (long long)in->n_children, u->n);
    return 0;
  }
  const char* what = NULL;
  const char* field = "";
  if (in->length < 0) what = "args has a negative length";
  if (what == NULL && in->offset != 0) what = "args has a nonzero offset (the argument struct is at offset 0)";
  for (int64_t i = 0; what == NULL && i < in->n_children; i++) {
    const struct ArrowArray* c = in->children[i];
    field = u->fields[i].name;
    if (c == NULL || c->n_buffers != 2)
      what = "is not a primitive array";
    else if (c->offset < 0)
      what = "has a negative offset";
    else if (c->length < in->length)
      what = "is shorter than the batch";
    else if (in->length > 0 && c->buffers[1] == NULL)
      what = "has no values buffer";
  }
  if (what == NULL) return 1;
  if (field[0] != 0)
    snprintf(why, len, "read-set field %s %s", field, what);
  else
    snprintf(why, len, "%s", what);
  return 0;
}

/* The moved argument array and its references (above). */
struct row_owner {
  struct ArrowArray args;
  int64_t refs;
};

static void owner_unref(struct row_owner* o) {
  if (__atomic_sub_fetch(&o->refs, 1, __ATOMIC_ACQ_REL) == 0) {
    if (o->args.release != NULL) o->args.release(&o->args);
    free(o);
  }
}

/* ArrowBuffer: one buffer of a moved argument array, read-only. */
struct row_buffer {
  PyObject_HEAD
  struct row_owner* owner;
  void* buf;
  Py_ssize_t len;
};

/* Set at init: the dealloc and getbuffer slots have no context. */
static const struct rowpy* g_api;

void rowrt_set_api(const struct rowpy* api) { g_api = api; }

static int buffer_getbuffer(PyObject* self, Py_buffer* view, int flags) {
  struct row_buffer* b = (struct row_buffer*)self;
  return g_api->PyBuffer_FillInfo(view, self, b->buf, b->len, 1, flags);
}

static void buffer_dealloc(PyObject* self) {
  struct row_buffer* b = (struct row_buffer*)self;
  struct row_owner* o = b->owner;
  PyTypeObject* tp = Py_TYPE(self);
  tp->tp_free(self);
  g_api->Py_DecRef((PyObject*)tp); /* a heap type: each instance holds it */
  if (o != NULL) owner_unref(o);
}

static PyType_Slot BUFFER_SLOTS[] = {
    {Py_bf_getbuffer, (void*)buffer_getbuffer},
    {Py_tp_dealloc, (void*)buffer_dealloc},
    {0, NULL},
};

static PyType_Spec BUFFER_SPEC = {
    "komira_udf_rowrt.ArrowBuffer",
    sizeof(struct row_buffer),
    0,
    Py_TPFLAGS_DEFAULT,
    BUFFER_SLOTS,
};

PyObject* rowrt_buffer_type_new(const struct rowpy* api) { return api->PyType_FromSpec(&BUFFER_SPEC); }

/* A memoryview over `bytes` bytes at `p` that holds `o` until it goes. */
static PyObject* owned_view(struct komira_udf_context* c, struct row_owner* o, const void* p, int64_t bytes) {
  struct rowpy* a = &c->rt->api;
  PyTypeObject* tp = (PyTypeObject*)c->buffer_type;
  struct row_buffer* b = (struct row_buffer*)tp->tp_alloc(tp, 0);
  if (b == NULL) return NULL;
  __atomic_add_fetch(&o->refs, 1, __ATOMIC_ACQ_REL);
  b->owner = o;
  b->buf = (bytes <= 0 || p == NULL) ? (void*)EMPTY_BUF : (void*)p;
  b->len = bytes <= 0 || p == NULL ? 0 : (Py_ssize_t)bytes;
  PyObject* v = a->PyMemoryView_FromObject((PyObject*)b);
  a->Py_DecRef((PyObject*)b); /* the view holds it now */
  return v;
}

/* A memoryview over `bytes` bytes at `p` (an empty buffer for 0). */
static PyObject* view(struct rowpy* a, const void* p, int64_t bytes, int writable) {
  if (bytes <= 0 || p == NULL) {
    p = EMPTY_BUF;
    bytes = 0;
  }
  return a->PyMemoryView_FromMemory((char*)p, (Py_ssize_t)bytes, writable ? PyBUF_WRITE : PyBUF_READ);
}

/* Releases each of our own views (output, cancel flag): the adapter never
 * hands them to user code. */
static void release_own(struct komira_udf_context* c, PyObject** views, int n) {
  struct rowpy* a = &c->rt->api;
  for (int i = 0; i < n; i++) {
    PyObject* r = a->PyObject_CallMethodObjArgs(views[i], c->name_release, NULL);
    if (r != NULL)
      a->Py_DecRef(r);
    else
      a->PyErr_Clear();
    a->Py_DecRef(views[i]);
  }
}

/* The read set's columns for the adapter: one (fmt, values view, validity
 * view or None, offset) per field. A new reference, or NULL. */
static PyObject* field_columns(struct komira_udf_context* c, struct row_owner* owner, const struct komira_udf_udf* u,
                               int64_t n) {
  struct rowpy* a = &c->rt->api;
  PyObject* cols = a->PyList_New(u->n);
  for (int i = 0; cols != NULL && i < u->n; i++) {
    const struct ArrowArray* ch = owner->args.children[i];
    char fmt[2] = {u->fields[i].fmt, 0};
    PyObject* d = owned_view(c, owner, ch->buffers[1], (ch->offset + n) * 8);
    PyObject* v = a->none;
    if (ch->buffers[0] != NULL && ch->null_count != 0)
      v = owned_view(c, owner, ch->buffers[0], (ch->offset + n + 7) / 8);
    else
      a->Py_IncRef(v);
    PyObject* t = a->PyTuple_New(4);
    PyObject* f = a->PyUnicode_FromString(fmt);
    PyObject* off = a->PyLong_FromLongLong(ch->offset);
    if (t == NULL || d == NULL || v == NULL || f == NULL || off == NULL) {
      PyObject* drop[] = {t, d, v, f, off};
      for (int k = 0; k < 5; k++)
        if (drop[k]) a->Py_DecRef(drop[k]);
      a->Py_DecRef(cols);
      return NULL;
    }
    a->PyTuple_SetItem(t, 0, f); /* the tuple takes our references */
    a->PyTuple_SetItem(t, 1, d);
    a->PyTuple_SetItem(t, 2, v);
    a->PyTuple_SetItem(t, 3, off);
    a->PyList_SetItem(cols, i, t);
  }
  return cols;
}

int32_t rowrt_call_batch(komira_udf_instance* inst, const komira_udf_call* call, struct ArrowDeviceArray* args,
                         struct ArrowDeviceArray* out, komira_udf_error* e) {
  struct komira_udf_context* c = inst->ctx;
  const struct komira_udf_udf* u = inst->udf;
  struct rowpy* a = &c->rt->api;
  out->array.release = NULL;
  /* Moved in: from here on the array is this runtime's. */
  struct ArrowArray in = args->array;
  int on_cpu = args->device_type == ARROW_DEVICE_CPU;
  args->array.release = NULL;

  char why[256];
  const char* bad = NULL;
  int32_t code = KOMIRA_UDF_OK;
  if (call == NULL || call->struct_size < sizeof(komira_udf_call)) {
    code = KOMIRA_UDF_ERR_ABI;
    bad = "call struct_size is below this runtime's";
  } else if (!pthread_equal(c->owner, pthread_self())) {
    code = KOMIRA_UDF_ERR_INTERNAL;
    bad = "call_batch: the context belongs to another thread (thread_affine)";
  } else if (!on_cpu) {
    code = KOMIRA_UDF_ERR_UNSUPPORTED;
    bad = "args are not on the CPU";
  } else if (!args_fit(&in, u, why, sizeof(why))) {
    code = KOMIRA_UDF_ERR_INTERNAL;
    bad = why;
  } else if (cancelled(call)) {
    code = KOMIRA_UDF_ERR_CANCELLED;
    bad = "cancelled before the batch";
  } else if (call->deadline_ns != 0 && c->rt->host->now_ns(c->rt->host->host_data) > call->deadline_ns) {
    code = KOMIRA_UDF_ERR_DEADLINE;
    bad = "the deadline passed before the batch";
  }
  if (code != KOMIRA_UDF_OK) {
    if (in.release != NULL) in.release(&in);
    return rowrt_fail(e, code, bad, NULL, -1);
  }

  int64_t n = in.length;
  uint8_t* ov = NULL;
  void* od = NULL;
  if (!make_col(&out->array, n, &ov, &od)) {
    if (in.release != NULL) in.release(&in);
    return rowrt_fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "call_batch: out of memory", NULL, -1);
  }
  struct row_owner* owner = malloc(sizeof(*owner));
  if (owner == NULL) {
    if (in.release != NULL) in.release(&in);
    out->array.release(&out->array);
    return rowrt_fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "call_batch: out of memory", NULL, -1);
  }
  owner->args = in;
  owner->refs = 1; /* the call's */

  rowrt_enter(c);
  PyObject* own_views[3];
  int n_own = 0;
  PyObject* cols = field_columns(c, owner, u, n);
  PyObject* cancel_view = call->cancel != NULL ? view(a, (const void*)call->cancel, 4, 0) : a->none;
  if (cancel_view != a->none && cancel_view != NULL) own_views[n_own++] = cancel_view;
  PyObject* out_d = view(a, od, n * 8, 1);
  PyObject* out_v = view(a, ov, (n + 7) / 8, 1);
  if (out_d != NULL) own_views[n_own++] = out_d;
  if (out_v != NULL) own_views[n_own++] = out_v;
  PyObject* r = NULL;
  PyObject* targs = a->PyTuple_New(7);
  PyObject* pn = a->PyLong_FromLongLong(n);
  PyObject* pd = a->PyLong_FromLongLong(call->deadline_ns);
  if (targs != NULL && pn != NULL && pd != NULL && cols != NULL && cancel_view != NULL && out_d != NULL &&
      out_v != NULL) {
    PyObject* items[7] = {pn, cols, out_d, out_v, cancel_view, c->now_fn, pd};
    for (int i = 0; i < 7; i++) {
      a->Py_IncRef(items[i]); /* SetItem steals */
      a->PyTuple_SetItem(targs, i, items[i]);
    }
    r = a->PyObject_CallObject(inst->call, targs);
  }
  char* internal = r == NULL ? rowrt_take_exception(a) : NULL;
  if (targs) a->Py_DecRef(targs);
  if (pn) a->Py_DecRef(pn);
  if (pd) a->Py_DecRef(pd);
  if (cols) a->Py_DecRef(cols);

  /* The verdict, copied out before the objects go: (OK, null_count) or
   * (status, message, trace or None, row). */
  int64_t row = -1;
  char* msg = NULL;
  char* trace = NULL;
  if (r != NULL) {
    code = (int32_t)a->PyLong_AsLongLong(a->PyTuple_GetItem(r, 0));
    if (code == KOMIRA_UDF_OK) {
      out->array.null_count = a->PyLong_AsLongLong(a->PyTuple_GetItem(r, 1));
    } else {
      PyObject* m = a->PyTuple_GetItem(r, 1);
      PyObject* t = a->PyTuple_GetItem(r, 2);
      const char* ms = m != NULL ? a->PyUnicode_AsUTF8(m) : NULL;
      const char* ts = (t != NULL && t != a->none) ? a->PyUnicode_AsUTF8(t) : NULL;
      msg = ms ? strdup(ms) : NULL;
      trace = ts ? strdup(ts) : NULL;
      row = a->PyLong_AsLongLong(a->PyTuple_GetItem(r, 3));
    }
    if (a->PyErr_Occurred()) a->PyErr_Clear();
    a->Py_DecRef(r);
  } else {
    code = KOMIRA_UDF_ERR_INTERNAL;
  }

  release_own(c, own_views, n_own);
  /* The call's reference: the array is released here unless Python still
   * holds a view of one of its buffers. */
  owner_unref(owner);
  rowrt_leave(c);

  if (code != KOMIRA_UDF_OK) {
    out->array.release(&out->array);
    int32_t rc = rowrt_fail(e, code, internal != NULL ? internal : msg, internal != NULL ? NULL : trace,
                            internal != NULL ? -1 : row);
    free(internal);
    free(msg);
    free(trace);
    return rc;
  }
  set_cpu(out);
  return KOMIRA_UDF_OK;
}
