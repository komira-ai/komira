/*
 * call_batch of the Python UDF runtime (python_runtime.c), for SCALAR and
 * MAP_BATCHES_COLUMN.
 *
 * FFI-BOUNDARY. `args` is moved in on entry, whatever the status (design
 * section 4.4): its struct is copied into an owner block and the host's
 * slot cleared. Its buffers reach Python without a copy, each through an
 * ArrowBuffer object (a buffer exporter holding one reference on the owner)
 * and a memoryview over it. The owner's references are atomic: one for the
 * call, one per ArrowBuffer. The last one to go releases the array, so the
 * array lives exactly as long as user code holds a view of any of its
 * buffers (a numpy array over it, kept in a global, keeps it) and is
 * released when the call returns otherwise. An ArrowBuffer goes when its
 * interpreter frees it (at the latest when the interpreter ends), on the
 * thread that holds that interpreter; the release it may run is the host's
 * and takes no lock of this runtime.
 *
 * `out` is moved to the host on success: one malloc block per column
 * (buffer list, validity, values), freed by its release, which takes no
 * interpreter lock and runs on any thread. A SCALAR result is written by
 * the adapter straight into that block through writable memoryviews; a
 * MAP_BATCHES_COLUMN result (a Python object holding its own values) is
 * copied into it once through the buffer protocol.
 */
#include "pyrt.h" /* first: Python.h sets the feature macros */

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

/* A primitive array of `n` rows of 8-byte values, all valid; the caller
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

/* The argument struct's layout, before any of it is read. */
static const char* args_layout_error(const struct ArrowArray* in, const struct komira_udf_udf* u) {
  if (in->n_children != u->n_args) return "args has a child count other than the bound signature's";
  if (in->length < 0) return "args has a negative length";
  if (in->offset != 0) return "args has a nonzero offset (the argument struct is at offset 0)";
  for (int64_t i = 0; i < in->n_children; i++) {
    const struct ArrowArray* c = in->children[i];
    if (c == NULL || c->n_buffers != 2) return "an argument is not a primitive array";
    if (c->offset < 0 || c->length < in->length) return "an argument is shorter than the batch";
    if (in->length > 0 && c->buffers[1] == NULL) return "an argument has no values buffer";
  }
  return NULL;
}

/* The moved argument array and its references (above). */
struct pyrt_owner {
  struct ArrowArray args;
  int64_t refs;
};

static void owner_unref(struct pyrt_owner* o) {
  if (__atomic_sub_fetch(&o->refs, 1, __ATOMIC_ACQ_REL) == 0) {
    if (o->args.release != NULL) o->args.release(&o->args);
    free(o);
  }
}

/* ArrowBuffer: one buffer of a moved argument array, read-only. */
struct pyrt_buffer {
  PyObject_HEAD
  struct pyrt_owner* owner;
  void* buf;
  Py_ssize_t len;
};

/* Set at init: the dealloc and getbuffer slots have no context. */
static const struct pyapi* g_api;

void pyrt_set_api(const struct pyapi* api) { g_api = api; }

static int buffer_getbuffer(PyObject* self, Py_buffer* view, int flags) {
  struct pyrt_buffer* b = (struct pyrt_buffer*)self;
  return g_api->PyBuffer_FillInfo(view, self, b->buf, b->len, 1, flags);
}

static void buffer_dealloc(PyObject* self) {
  struct pyrt_buffer* b = (struct pyrt_buffer*)self;
  struct pyrt_owner* o = b->owner;
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
    "komira_udf_pyrt.ArrowBuffer",
    sizeof(struct pyrt_buffer),
    0,
    Py_TPFLAGS_DEFAULT,
    BUFFER_SLOTS,
};

PyObject* pyrt_buffer_type_new(const struct pyapi* api) { return api->PyType_FromSpec(&BUFFER_SPEC); }

/* A memoryview over `bytes` bytes at `p` that holds `o` until it goes. */
static PyObject* owned_view(struct komira_udf_context* c, struct pyrt_owner* o, const void* p, int64_t bytes) {
  struct pyapi* a = &c->rt->api;
  PyTypeObject* tp = (PyTypeObject*)c->buffer_type;
  struct pyrt_buffer* b = (struct pyrt_buffer*)tp->tp_alloc(tp, 0);
  if (b == NULL) return NULL;
  __atomic_add_fetch(&o->refs, 1, __ATOMIC_ACQ_REL);
  b->owner = o;
  b->buf = (bytes <= 0 || p == NULL) ? (void*)EMPTY_BUF : (void*)p;
  b->len = bytes <= 0 || p == NULL ? 0 : (Py_ssize_t)bytes;
  PyObject* v = a->PyMemoryView_FromObject((PyObject*)b);
  a->Py_DecRef((PyObject*)b); /* the view holds it now */
  return v;
}

/* Releases each of our own views (output, cancel flag): the adapter never
 * hands them to user code, so none is held. */
static void release_own(struct komira_udf_context* c, PyObject** views, int n) {
  struct pyapi* a = &c->rt->api;
  for (int i = 0; i < n; i++) {
    PyObject* r = a->PyObject_CallMethodObjArgs(views[i], c->name_release, NULL);
    if (r != NULL)
      a->Py_DecRef(r);
    else
      a->PyErr_Clear();
    a->Py_DecRef(views[i]);
  }
}

/* A memoryview over `bytes` bytes at `p` (an empty buffer for 0). */
static PyObject* view(struct pyapi* a, const void* p, int64_t bytes, int writable) {
  if (bytes <= 0 || p == NULL) {
    p = EMPTY_BUF;
    bytes = 0;
  }
  return a->PyMemoryView_FromMemory((char*)p, (Py_ssize_t)bytes, writable ? PyBUF_WRITE : PyBUF_READ);
}

/* Copies a Python result column (values, optional validity) into `o`. */
static const char* copy_column(struct pyapi* a, PyObject* data, PyObject* valid, int64_t m, int64_t nulls,
                               struct ArrowArray* o) {
  uint8_t* v;
  void* d;
  if (m < 0) return "the adapter returned a negative length";
  if (!make_col(o, m, &v, &d)) return "out of memory";
  Py_buffer b;
  if (a->PyObject_GetBuffer(data, &b, PyBUF_SIMPLE) != 0) {
    a->PyErr_Clear();
    o->release(o);
    return "the result's values have no contiguous buffer";
  }
  int ok = b.len == m * 8;
  if (ok && m > 0) memcpy(d, b.buf, (size_t)m * 8);
  a->PyBuffer_Release(&b);
  if (!ok) {
    o->release(o);
    return "the result's values buffer is not 8 bytes per row";
  }
  if (valid != a->none) {
    if (a->PyObject_GetBuffer(valid, &b, PyBUF_SIMPLE) != 0) {
      a->PyErr_Clear();
      o->release(o);
      return "the result's validity has no contiguous buffer";
    }
    ok = b.len >= (m + 7) / 8;
    if (ok && m > 0) memcpy(v, b.buf, (size_t)((m + 7) / 8));
    a->PyBuffer_Release(&b);
    if (!ok) {
      o->release(o);
      return "the result's validity is shorter than its rows";
    }
  }
  o->null_count = nulls;
  return NULL;
}

int32_t pyrt_call_batch(komira_udf_instance* inst, const komira_udf_call* call, struct ArrowDeviceArray* args,
                        struct ArrowDeviceArray* out, komira_udf_error* e) {
  struct komira_udf_context* c = inst->ctx;
  const struct komira_udf_udf* u = inst->udf;
  struct pyapi* a = &c->rt->api;
  out->array.release = NULL;
  /* Moved in: from here on the array is this runtime's. */
  struct ArrowArray in = args->array;
  int on_cpu = args->device_type == ARROW_DEVICE_CPU;
  args->array.release = NULL;

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
  } else if ((bad = args_layout_error(&in, u)) != NULL) {
    code = KOMIRA_UDF_ERR_INTERNAL;
  } else if (cancelled(call)) {
    code = KOMIRA_UDF_ERR_CANCELLED;
    bad = "cancelled before the batch";
  } else if (call->deadline_ns != 0 && c->rt->host->now_ns(c->rt->host->host_data) > call->deadline_ns) {
    code = KOMIRA_UDF_ERR_DEADLINE;
    bad = "the deadline passed before the batch";
  }
  if (code != KOMIRA_UDF_OK) {
    if (in.release != NULL) in.release(&in);
    return pyrt_fail(e, code, bad, NULL, -1);
  }

  int64_t n = in.length;
  int scalar = u->shape == (int32_t)KOMIRA_UDF_SHAPE_SCALAR;
  uint8_t* ov = NULL;
  void* od = NULL;
  if (scalar && !make_col(&out->array, n, &ov, &od)) {
    if (in.release != NULL) in.release(&in);
    return pyrt_fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "call_batch: out of memory", NULL, -1);
  }

  struct pyrt_owner* owner = malloc(sizeof(*owner));
  if (owner == NULL) {
    if (in.release != NULL) in.release(&in);
    if (out->array.release != NULL) out->array.release(&out->array);
    return pyrt_fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "call_batch: out of memory", NULL, -1);
  }
  owner->args = in;
  owner->refs = 1; /* the call's */

  pyrt_enter(c);
  PyObject* own_views[3];
  int n_own = 0;
  PyObject* cols = a->PyList_New(u->n_args);
  for (int i = 0; cols != NULL && i < u->n_args; i++) {
    const struct ArrowArray* ch = in.children[i];
    char fmt[2] = {u->arg_fmt[i], 0};
    PyObject* d = owned_view(c, owner, ch->buffers[1], (ch->offset + n) * 8);
    PyObject* v = a->none;
    if (ch->buffers[0] != NULL && ch->null_count != 0) v = owned_view(c, owner, ch->buffers[0], (ch->offset + n + 7) / 8);
    else a->Py_IncRef(v);
    PyObject* t = a->PyTuple_New(4);
    if (t == NULL || d == NULL || v == NULL) {
      if (t) a->Py_DecRef(t);
      if (d) a->Py_DecRef(d);
      if (v) a->Py_DecRef(v);
      a->Py_DecRef(cols);
      cols = NULL;
      break;
    }
    a->PyTuple_SetItem(t, 0, a->PyUnicode_FromString(fmt));
    a->PyTuple_SetItem(t, 1, d); /* the tuple takes our references */
    a->PyTuple_SetItem(t, 2, v);
    a->PyTuple_SetItem(t, 3, a->PyLong_FromLongLong(ch->offset));
    a->PyList_SetItem(cols, i, t);
  }
  PyObject* cancel_view = call->cancel != NULL ? view(a, (const void*)call->cancel, 4, 0) : a->none;
  if (cancel_view != a->none && cancel_view != NULL) own_views[n_own++] = cancel_view;
  PyObject* out_d = a->none;
  PyObject* out_v = a->none;
  if (scalar) {
    out_d = view(a, od, n * 8, 1);
    out_v = view(a, ov, (n + 7) / 8, 1);
    if (out_d != NULL) own_views[n_own++] = out_d;
    if (out_v != NULL) own_views[n_own++] = out_v;
  }
  PyObject* r = NULL;
  PyObject* targs = a->PyTuple_New(7);
  if (targs != NULL && cols != NULL && cancel_view != NULL && out_d != NULL && out_v != NULL) {
    PyObject* items[7] = {a->PyLong_FromLongLong(n), cols, out_d, out_v, cancel_view, c->now_fn,
                          a->PyLong_FromLongLong(call->deadline_ns)};
    for (int i = 0; i < 7; i++) {
      if (i != 0 && i != 6) a->Py_IncRef(items[i]); /* SetItem steals */
      a->PyTuple_SetItem(targs, i, items[i]);
    }
    r = a->PyObject_CallObject(inst->call, targs);
  }
  char* internal = r == NULL ? pyrt_take_exception(a) : NULL;
  if (targs) a->Py_DecRef(targs);
  if (cols) a->Py_DecRef(cols);

  /* The verdict, copied out before the objects go. */
  int64_t row = -1;
  char* msg = NULL;
  char* trace = NULL;
  const char* copy_err = NULL;
  if (r != NULL) {
    code = (int32_t)a->PyLong_AsLongLong(a->PyTuple_GetItem(r, 0));
    if (code == KOMIRA_UDF_OK && scalar) {
      out->array.null_count = a->PyLong_AsLongLong(a->PyTuple_GetItem(r, 1));
    } else if (code == KOMIRA_UDF_OK) {
      copy_err = copy_column(a, a->PyTuple_GetItem(r, 1), a->PyTuple_GetItem(r, 2),
                             a->PyLong_AsLongLong(a->PyTuple_GetItem(r, 4)),
                             a->PyLong_AsLongLong(a->PyTuple_GetItem(r, 3)), &out->array);
      if (copy_err != NULL) code = KOMIRA_UDF_ERR_RETURN_TYPE;
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
  /* The call's reference: the array is released here unless user code
   * still holds a view of one of its buffers. */
  owner_unref(owner);
  pyrt_leave(c);

  if (code != KOMIRA_UDF_OK) {
    if (out->array.release != NULL) out->array.release(&out->array);
    int32_t rc;
    if (internal != NULL)
      rc = pyrt_fail(e, code, internal, NULL, -1);
    else if (copy_err != NULL)
      rc = pyrt_fail(e, code, copy_err, NULL, -1);
    else
      rc = pyrt_fail(e, code, msg, trace, row);
    free(internal);
    free(msg);
    free(trace);
    return rc;
  }
  set_cpu(out);
  return KOMIRA_UDF_OK;
}
