/*
 * Arrow C Data <-> JavaScript, for the Node runtime (design section 5.3, "External
 * buffers, with a copy fallback"). Test-only spike code. Everything here
 * runs on an environment's JavaScript thread, inside rt_dispatch.
 *
 * Into JavaScript, no copy: each buffer of an argument array is wrapped as an
 * external ArrayBuffer over the engine's memory (napi_create_external_arraybuffer),
 * once per distinct address in a request (V8 aborts when one address is
 * wrapped twice while the first wrap lives: the wrap set is how a column used
 * twice, or two children sharing a buffer, stays safe). When the request
 * ends every wrapped ArrayBuffer is detached, so a view the user's code kept
 * is empty and the engine's array can be released at once; the finalizer
 * Node-API requires is a no-op. A Node built without external buffers
 * (napi_no_external_buffers_allowed), or g_copy_mode, takes the copy path:
 * the bytes are copied into V8's own memory (counted as copy_wraps).
 *
 * Out of JavaScript, one copy: a result column is a V8-owned typed array, so
 * its bytes are copied into a block this file allocates, whose release only
 * frees it (counted in outputs_copied_bytes).
 *
 * FFI-BOUNDARY. Arrays the engine exported are read, not owned: this file
 * never calls their release (the engine thread does, after the request).
 * Every block allocated here is freed by the release callback of the array
 * that points into it, which may run on any thread.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "rt_internal.h"

static int64_t g_probe_finalized = 0;
static char g_probe_mem[256] __attribute__((aligned(64)));

static size_t width_of(char fmt) { return fmt == 'i' ? 4 : 8; }

static void noop_finalize(napi_env env, void* data, void* hint) {
  (void)env;
  (void)data;
  (void)hint;
}

static void probe_finalize(napi_env env, void* data, void* hint) {
  (void)env;
  (void)data;
  (void)hint;
  __atomic_fetch_add(&g_probe_finalized, 1, __ATOMIC_RELAXED);
}

static int32_t fail_napi(struct request* r, const char* what, napi_status s) {
  char msg[256];
  const napi_extended_error_info* info = NULL;
  napi_get_last_error_info(r->es->env, &info);
  snprintf(msg, sizeof(msg), "%s failed (napi status %d%s%s)", what, (int)s, info != NULL && info->error_message != NULL ? ": " : "",
           info != NULL && info->error_message != NULL ? info->error_message : "");
  return rt_fail(r, KOMIRA_UDF_ERR_INTERNAL, msg);
}

/* ---- probing ---------------------------------------------------------------- */

/* Can an external ArrayBuffer be detached? Wraps 16 bytes of heap and tries. */
int rt_probe_detach(napi_env env) {
  void* mem = malloc(16);
  if (mem == NULL) return 0;
  napi_value ab;
  if (napi_create_external_arraybuffer(env, mem, 16, probe_finalize, NULL, &ab) != napi_ok) {
    free(mem);
    return 0;
  }
  /* The finalizer must not free `mem` while V8 may still reach it, so the
   * block is simply leaked: 16 bytes, once per process. */
  return napi_detach_arraybuffer(env, ab) == napi_ok;
}

napi_value rt_probe_finalized(napi_env env, napi_callback_info info) {
  (void)info;
  napi_value out;
  napi_create_int64(env, __atomic_load_n(&g_probe_finalized, __ATOMIC_RELAXED), &out);
  return out;
}

static void probe_free_finalize(napi_env env, void* data, void* hint) {
  (void)env;
  (void)hint;
  free(data);
  __atomic_fetch_add(&g_probe_finalized, 1, __ATOMIC_RELAXED);
}

/* probeWrapMany(count, bytes): wraps `count` distinct heap blocks as
 * external ArrayBuffers, never detaches them and drops the handles; each
 * block is freed by its ArrayBuffer's finalizer, which probeFinalized() counts.
 * Returns how many were wrapped. This is what releasing the engine's array
 * from the finalizer, not at return, would hold until a garbage collection. */
napi_value rt_probe_wrap_many(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  int64_t count = 0, bytes = 0;
  napi_value out;
  if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc < 2 ||
      napi_get_value_int64(env, argv[0], &count) != napi_ok || napi_get_value_int64(env, argv[1], &bytes) != napi_ok || bytes <= 0)
    return NULL;
  int64_t made = 0;
  for (int64_t i = 0; i < count; i++) {
    napi_handle_scope scope;
    napi_open_handle_scope(env, &scope);
    void* mem = malloc((size_t)bytes);
    napi_value ab;
    if (mem == NULL || napi_create_external_arraybuffer(env, mem, (size_t)bytes, probe_free_finalize, NULL, &ab) != napi_ok) {
      free(mem);
      napi_close_handle_scope(env, scope);
      break;
    }
    made++;
    napi_close_handle_scope(env, scope);
  }
  napi_create_int64(env, made, &out);
  return out;
}

static napi_value status_array(napi_env env, const int* st, int n) {
  napi_value arr;
  napi_create_array_with_length(env, (size_t)n, &arr);
  for (int i = 0; i < n; i++) {
    napi_value v;
    napi_create_int32(env, st[i], &v);
    napi_set_element(env, arr, (uint32_t)i, v);
  }
  return arr;
}

/* probeWrap(mode): wraps a static block as external ArrayBuffers in the ways
 * the V8 rule is about; returns the Node-API status of each step. If V8
 * aborts, the process dies: tests run each mode in a child process.
 *   0: the same address wrapped twice, both ArrayBuffers alive
 *   1: wrapped, detached, wrapped again, detached
 *   2: wrapped and the handle dropped (no detach), nothing else
 *   3: wrapped again after mode 2 (the caller ran a GC in between)
 *   4: an address inside the first wrap, wrapped while the first is alive */
napi_value rt_probe_wrap(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  int32_t mode = 0;
  if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) == napi_ok && argc >= 1) napi_get_value_int32(env, argv[0], &mode);
  int st[8] = {0};
  int n = 0;
  napi_value a, b;
  switch (mode) {
    case 0:
      st[n++] = napi_create_external_arraybuffer(env, g_probe_mem, 128, probe_finalize, NULL, &a);
      st[n++] = napi_create_external_arraybuffer(env, g_probe_mem, 128, probe_finalize, NULL, &b);
      break;
    case 1:
      st[n++] = napi_create_external_arraybuffer(env, g_probe_mem, 128, probe_finalize, NULL, &a);
      st[n++] = napi_detach_arraybuffer(env, a);
      st[n++] = napi_create_external_arraybuffer(env, g_probe_mem, 128, probe_finalize, NULL, &b);
      st[n++] = napi_detach_arraybuffer(env, b);
      break;
    case 2:
    case 3:
      st[n++] = napi_create_external_arraybuffer(env, g_probe_mem, 128, probe_finalize, NULL, &a);
      break;
    case 4:
      st[n++] = napi_create_external_arraybuffer(env, g_probe_mem, 128, probe_finalize, NULL, &a);
      st[n++] = napi_create_external_arraybuffer(env, g_probe_mem + 64, 64, probe_finalize, NULL, &b);
      break;
    default:
      break;
  }
  return status_array(env, st, n);
}

/* ---- wrapping --------------------------------------------------------------- */

int32_t rt_wrap_buffer(struct request* r, const void* ptr, size_t bytes, napi_value* out) {
  napi_env env = r->es->env;
  if (ptr != NULL && bytes != 0) {
    for (int i = 0; i < r->wraps.n; i++) {
      if (r->wraps.e[i].ptr != ptr) continue;
      if (bytes > r->wraps.e[i].bytes)
        return rt_fail(r, KOMIRA_UDF_ERR_UNSUPPORTED, "one engine buffer is used at two lengths in one call: it can be wrapped once");
      napi_status s = napi_get_reference_value(env, r->wraps.e[i].ab, out);
      return s == napi_ok ? KOMIRA_UDF_OK : fail_napi(r, "napi_get_reference_value", s);
    }
  }
  napi_value ab;
  void* copy = NULL;
  napi_status s;
  if (ptr == NULL || bytes == 0) {
    s = napi_create_arraybuffer(env, 0, &copy, &ab);
    if (s != napi_ok) return fail_napi(r, "napi_create_arraybuffer", s);
    *out = ab;
    return KOMIRA_UDF_OK;
  }
  int copied = g_copy_mode;
  if (!copied) {
    s = napi_create_external_arraybuffer(env, (void*)ptr, bytes, noop_finalize, NULL, &ab);
    if (s == napi_no_external_buffers_allowed) {
      g_copy_mode = 1;
      copied = 1;
    } else if (s != napi_ok) {
      return fail_napi(r, "napi_create_external_arraybuffer", s);
    }
  }
  if (copied) {
    s = napi_create_arraybuffer(env, bytes, &copy, &ab);
    if (s != napi_ok) return fail_napi(r, "napi_create_arraybuffer", s);
    memcpy(copy, ptr, bytes);
    STAT_ADD(copy_wraps, 1);
  } else {
    STAT_ADD(external_wraps, 1);
  }
  STAT_ADD(wrapped_bytes, bytes);
  if (r->wraps.n == r->wraps.cap) {
    int cap = r->wraps.cap != 0 ? r->wraps.cap * 2 : 16;
    struct wrap_entry* e = realloc(r->wraps.e, (size_t)cap * sizeof(*e));
    if (e == NULL) return rt_fail(r, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "wrap set: out of memory");
    r->wraps.e = e;
    r->wraps.cap = cap;
  }
  struct wrap_entry* w = &r->wraps.e[r->wraps.n];
  w->ptr = ptr;
  w->bytes = bytes;
  s = napi_create_reference(env, ab, 1, &w->ab);
  if (s != napi_ok) return fail_napi(r, "napi_create_reference", s);
  r->wraps.n++;
  *out = ab;
  return KOMIRA_UDF_OK;
}

/* End of a request: every external ArrayBuffer is detached (a view the user
 * kept is empty from here) and its reference dropped. Copied buffers belong
 * to V8 and need no detach. */
void rt_unwrap_all(struct request* r) {
  napi_env env = r->es->env;
  for (int i = 0; i < r->wraps.n; i++) {
    struct wrap_entry* w = &r->wraps.e[i];
    napi_value ab;
    if (!g_copy_mode && napi_get_reference_value(env, w->ab, &ab) == napi_ok && ab != NULL) {
      if (napi_detach_arraybuffer(env, ab) == napi_ok)
        STAT_ADD(detaches, 1);
      else
        STAT_ADD(detach_failures, 1);
    }
    napi_delete_reference(env, w->ab);
  }
  r->wraps.n = 0;
}

static int64_t count_nulls(const uint8_t* valid, int64_t off, int64_t len) {
  int64_t nulls = 0;
  for (int64_t i = 0; i < len; i++)
    if (!((valid[(off + i) >> 3] >> ((off + i) & 7)) & 1)) nulls++;
  return nulls;
}

/* The JavaScript descriptors of the children of struct array `st`, one per
 * entry of `cols`: [length, offset, nullCount, validity|null, values]. */
int32_t rt_columns_to_js(struct request* r, const struct ArrowArray* st, const struct rt_col* cols, int n_cols,
                         napi_value* out) {
  napi_env env = r->es->env;
  if (st->offset != 0) return rt_fail(r, KOMIRA_UDF_ERR_INTERNAL, "the host passed an argument struct at a non-zero offset");
  if (st->n_children != n_cols)
    return rt_fail(r, KOMIRA_UDF_ERR_INTERNAL, "the argument struct has a different number of children than the UDF has arguments");
  napi_value arr;
  napi_status s = napi_create_array_with_length(env, (size_t)n_cols, &arr);
  if (s != napi_ok) return fail_napi(r, "napi_create_array_with_length", s);
  for (int i = 0; i < n_cols; i++) {
    const struct ArrowArray* c = st->children[i];
    if (c == NULL || c->n_buffers != 2 || c->n_children != 0 || c->dictionary != NULL)
      return rt_fail(r, KOMIRA_UDF_ERR_INTERNAL, "an argument child is not a primitive array");
    if (c->length != st->length) return rt_fail(r, KOMIRA_UDF_ERR_INTERNAL, "an argument child differs in length from its struct");
    size_t w = width_of(cols[i].fmt);
    int64_t off = c->offset, len = c->length;
    const uint8_t* valid = c->buffers[0];
    int64_t nc = c->null_count;
    if (valid == NULL) nc = 0;
    else if (nc < 0) nc = count_nulls(valid, off, len);
    napi_value v_valid, v_vals, e, n;
    if (nc != 0) {
      int32_t rc = rt_wrap_buffer(r, valid, (size_t)((off + len + 7) >> 3), &v_valid);
      if (rc != KOMIRA_UDF_OK) return rc;
    } else {
      napi_get_null(env, &v_valid);
    }
    int32_t rc = rt_wrap_buffer(r, c->buffers[1], (size_t)(off + len) * w, &v_vals);
    if (rc != KOMIRA_UDF_OK) return rc;
    napi_create_array_with_length(env, 5, &e);
    napi_create_int64(env, len, &n);
    napi_set_element(env, e, 0, n);
    napi_create_int64(env, off, &n);
    napi_set_element(env, e, 1, n);
    napi_create_int64(env, nc, &n);
    napi_set_element(env, e, 2, n);
    napi_set_element(env, e, 3, v_valid);
    napi_set_element(env, e, 4, v_vals);
    s = napi_set_element(env, arr, (uint32_t)i, e);
    if (s != napi_ok) return fail_napi(r, "napi_set_element", s);
  }
  *out = arr;
  return KOMIRA_UDF_OK;
}

/* ---- frame input ------------------------------------------------------------ */

/* pull(): the next batch of a frame's input as [length, [columns...]], or
 * null at the end. Its data is the frame (set by the dispatcher). The batch
 * is released by the engine thread when the request ends. */
napi_value rt_pull(napi_env env, napi_callback_info info) {
  void* data = NULL;
  if (napi_get_cb_info(env, info, NULL, NULL, NULL, &data) != napi_ok || data == NULL) return NULL;
  struct komira_udf_frame* f = data;
  void* esd = NULL;
  napi_get_instance_data(env, &esd);
  struct env_state* es = esd;
  struct request* r = es != NULL ? es->cur : NULL;
  if (r == NULL) {
    napi_throw_error(env, NULL, "pull: called outside a request");
    return NULL;
  }
  const struct komira_udf_udf* u = f->inst->udf;
  struct ArrowDeviceArray dev;
  memset(&dev, 0, sizeof(dev));
  int rc = f->in.get_next(&f->in, &dev);
  if (rc != 0) {
    const char* m = f->in.get_last_error != NULL ? f->in.get_last_error(&f->in) : NULL;
    char msg[300];
    snprintf(msg, sizeof(msg), "the input stream failed (%d): %s", rc, m != NULL ? m : "no message");
    napi_throw_error(env, NULL, msg);
    return NULL;
  }
  napi_value result;
  if (dev.array.release == NULL) {
    napi_get_null(env, &result);
    return result;
  }
  /* Own it first: the engine thread releases it when the request ends, on
   * every path below. */
  if (r->n_pulled == r->cap_pulled) {
    int cap = r->cap_pulled != 0 ? r->cap_pulled * 2 : 4;
    struct ArrowDeviceArray* p = realloc(r->pulled, (size_t)cap * sizeof(*p));
    if (p == NULL) {
      dev.array.release(&dev.array);
      napi_throw_error(env, NULL, "pull: out of memory");
      return NULL;
    }
    r->pulled = p;
    r->cap_pulled = cap;
  }
  r->pulled[r->n_pulled++] = dev;
  struct ArrowDeviceArray* kept = &r->pulled[r->n_pulled - 1];
  STAT_ADD(pulls, 1);
  f->pulls++;
  if (kept->device_type != ARROW_DEVICE_CPU) {
    napi_throw_error(env, NULL, "pull: an input batch is not on the CPU");
    return NULL;
  }
  struct rt_col group = {'l', 0, (char*)""};
  struct rt_col all[65];
  int n = 0;
  if (u->shape == KOMIRA_UDF_SHAPE_AGG_PLAIN) all[n++] = group;
  for (int i = 0; i < u->n_args && n < 65; i++) all[n++] = u->args[i];
  napi_value cols;
  if (rt_columns_to_js(r, &kept->array, all, n, &cols) != KOMIRA_UDF_OK) {
    napi_throw_error(env, NULL, r->message != NULL ? r->message : "pull: the input batch cannot be read");
    return NULL;
  }
  napi_value len, pair;
  napi_create_int64(env, kept->array.length, &len);
  napi_create_array_with_length(env, 2, &pair);
  napi_set_element(env, pair, 0, len);
  napi_set_element(env, pair, 1, cols);
  return pair;
}

/* ---- results ---------------------------------------------------------------- */

struct col_block {
  const void* bufs[2];
};

static void release_col(struct ArrowArray* a) {
  free(a->private_data);
  a->release = NULL;
}

static void release_array(struct ArrowArray* a) {
  if (a->release != NULL) a->release(a);
}

static void release_struct(struct ArrowArray* a) {
  for (int64_t i = 0; i < a->n_children; i++) {
    release_array(a->children[i]);
    free(a->children[i]);
  }
  free(a->private_data);
  a->release = NULL;
}

static napi_typedarray_type ta_type_of(char fmt) {
  return fmt == 'i' ? napi_int32_array : fmt == 'l' ? napi_bigint64_array : napi_float64_array;
}

/* A column from [length, values(TypedArray), validity(Uint8Array)|null]. */
int32_t rt_column_from_js(struct request* r, napi_value col, char fmt, struct ArrowArray* out) {
  napi_env env = r->es->env;
  napi_value v_len, v_vals, v_valid;
  bool is_array = false;
  if (napi_is_array(env, col, &is_array) != napi_ok || !is_array)
    return rt_fail(r, KOMIRA_UDF_ERR_INTERNAL, "the adapter returned a column that is not an array");
  napi_get_element(env, col, 0, &v_len);
  napi_get_element(env, col, 1, &v_vals);
  napi_get_element(env, col, 2, &v_valid);
  int64_t n = 0;
  if (napi_get_value_int64(env, v_len, &n) != napi_ok || n < 0) return rt_fail(r, KOMIRA_UDF_ERR_INTERNAL, "a column has no length");
  bool is_ta = false;
  napi_is_typedarray(env, v_vals, &is_ta);
  if (!is_ta) return rt_fail(r, KOMIRA_UDF_ERR_INTERNAL, "a column has no typed array of values");
  napi_typedarray_type type;
  size_t tlen = 0, boff = 0;
  void* data = NULL;
  napi_value ab;
  if (napi_get_typedarray_info(env, v_vals, &type, &tlen, &data, &ab, &boff) != napi_ok)
    return fail_napi(r, "napi_get_typedarray_info", napi_generic_failure);
  if (type != ta_type_of(fmt)) return rt_fail(r, KOMIRA_UDF_ERR_RETURN_TYPE, "the result is a typed array of another element type than the declared type");
  if ((int64_t)tlen < n) return rt_fail(r, KOMIRA_UDF_ERR_INTERNAL, "a column's typed array is shorter than its length");
  const uint8_t* valid = NULL;
  napi_valuetype vt;
  napi_typeof(env, v_valid, &vt);
  if (vt != napi_null && vt != napi_undefined) {
    napi_typedarray_type vtype;
    size_t vlen = 0, voff = 0;
    void* vdata = NULL;
    napi_value vab;
    if (napi_get_typedarray_info(env, v_valid, &vtype, &vlen, &vdata, &vab, &voff) != napi_ok || vtype != napi_uint8_array ||
        (int64_t)vlen < ((n + 7) >> 3))
      return rt_fail(r, KOMIRA_UDF_ERR_INTERNAL, "a column's validity is not a long enough Uint8Array");
    valid = vdata;
  }
  int64_t nulls = valid != NULL ? count_nulls(valid, 0, n) : 0;
  size_t w = width_of(fmt);
  size_t vbytes = nulls != 0 ? (size_t)((n + 7) >> 3) : 0;
  struct col_block* b = malloc(sizeof(*b) + vbytes + (size_t)n * w + 16);
  if (b == NULL) return rt_fail(r, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "result: out of memory");
  uint8_t* vcopy = (uint8_t*)(b + 1);
  uint8_t* dcopy = (uint8_t*)(((uintptr_t)(vcopy + vbytes) + 7) & ~(uintptr_t)7);
  if (vbytes != 0) {
    memcpy(vcopy, valid, vbytes);
  }
  if (n != 0) memcpy(dcopy, data, (size_t)n * w);
  b->bufs[0] = vbytes != 0 ? vcopy : NULL;
  b->bufs[1] = dcopy;
  memset(out, 0, sizeof(*out));
  out->length = n;
  out->null_count = nulls;
  out->n_buffers = 2;
  out->buffers = b->bufs;
  out->release = release_col;
  out->private_data = b;
  STAT_ADD(outputs_copied_bytes, (size_t)n * w + vbytes);
  return KOMIRA_UDF_OK;
}

/* A table from [length, [column, ...]] into a struct array of `n_cols` children. */
int32_t rt_table_from_js(struct request* r, napi_value table, const struct rt_col* cols, int n_cols,
                         struct ArrowArray* out) {
  napi_env env = r->es->env;
  napi_value v_len, v_cols;
  napi_get_element(env, table, 0, &v_len);
  napi_get_element(env, table, 1, &v_cols);
  int64_t n = 0;
  uint32_t got = 0;
  if (napi_get_value_int64(env, v_len, &n) != napi_ok || napi_get_array_length(env, v_cols, &got) != napi_ok)
    return rt_fail(r, KOMIRA_UDF_ERR_INTERNAL, "the adapter returned a malformed table");
  if ((int)got != n_cols)
    return rt_fail(r, KOMIRA_UDF_ERR_RETURN_TYPE, "the table has a different number of columns than the declared result");
  size_t bytes = sizeof(void*) + (size_t)n_cols * sizeof(struct ArrowArray*);
  void** blk = calloc(1, bytes);
  if (blk == NULL) return rt_fail(r, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "result: out of memory");
  struct ArrowArray** kids = (struct ArrowArray**)(blk + 1);
  for (int i = 0; i < n_cols; i++) {
    kids[i] = calloc(1, sizeof(struct ArrowArray));
    if (kids[i] == NULL) {
      for (int k = 0; k < i; k++) {
        release_array(kids[k]);
        free(kids[k]);
      }
      free(blk);
      return rt_fail(r, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "result: out of memory");
    }
  }
  int32_t rc = KOMIRA_UDF_OK;
  for (int i = 0; i < n_cols && rc == KOMIRA_UDF_OK; i++) {
    napi_value c;
    napi_get_element(env, v_cols, (uint32_t)i, &c);
    rc = rt_column_from_js(r, c, cols[i].fmt, kids[i]);
    if (rc == KOMIRA_UDF_OK && kids[i]->length != n) rc = rt_fail(r, KOMIRA_UDF_ERR_RETURN_TYPE, "the columns of a table differ in length");
  }
  if (rc != KOMIRA_UDF_OK) {
    for (int i = 0; i < n_cols; i++) { /* a column not built has no release */
      release_array(kids[i]);
      free(kids[i]);
    }
    free(blk);
    return rc;
  }
  memset(out, 0, sizeof(*out));
  out->length = n;
  out->n_buffers = 1;
  out->n_children = n_cols;
  out->buffers = (const void**)blk; /* blk[0] == NULL: no validity */
  out->children = n_cols > 0 ? kids : NULL;
  out->release = release_struct;
  out->private_data = blk;
  return KOMIRA_UDF_OK;
}
