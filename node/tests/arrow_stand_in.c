// A stand-in Arrow C stream producer: a Node-API addon, built only for the
// tests, that turns a description of a stream into a real Arrow C stream (the
// C Data and C Stream Interfaces, arrow_c.h) and hands it out as a capsule
// that komira_addon's importArrowStream takes. It counts every release, so a
// test sees that the importer releases each struct exactly once.
//
//   stream(spec)       a capsule over the stream `spec` describes
//   counts(capsule)    { arrays, streamReleases, schemaReleases, arrayReleases,
//                        badReleases } of that capsule's stream: the batches it
//                        built and the releases of the stream, of its schema
//                        and of its batches (each top-level struct counts, its
//                        children and dictionary are released with it)
//
// spec = {
//   schema:  { format, name?, flags?, metadata?: [[key, value], ...],
//              children?: [schema...], dictionary?: schema },
//   batches: [array...],  array = { length, nullCount?, offset?,
//              buffers: (TypedArray | number | null)[], children?: [array...],
//              dictionary?: array, misalign?: true },
//   pool?: [TypedArray...],  buffers that batches share: a buffer given as
//              the number k is pool[k], the same memory in every batch
//   schemaError?: { status, message? },  get_schema fails with `status`
//   nextError?:   { at, status, message? },  call `at` of get_next fails
//   releasedSchema?: true,  get_schema succeeds with a released schema
// }
//
// Every struct is built when stream() is called; get_schema and get_next move
// them out. A buffer is a copy of the typed array's bytes in memory aligned to
// 16 bytes, or at one byte past such an address with `misalign`. The number of
// buffers and children of each struct is the length of its list, so a test can
// describe an array that does not match its format. get_last_error gives the
// message of the failing call (NULL when the spec has none). An ArrowArray's
// release frees its memory but keeps a record of the release, so a second
// release through a stale copy is counted in `badReleases` instead of freeing
// twice; those records, the pool and the stream's state are never freed.
#define NAPI_VERSION 8
#include <node_api.h>

#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "arrow_c.h"

static const napi_type_tag g_stream_tag = {KOMIRA_ARROW_STREAM_TAG_LOWER, KOMIRA_ARROW_STREAM_TAG_UPPER};

// The releases of one stream's structs.
typedef struct {
  int64_t arrays, stream_releases, schema_releases, array_releases, bad;
} Counts;

typedef struct {
  Counts *counts;
  bool top;
  bool released;
  void **owned;  // the buffer blocks this array frees
  int64_t n_owned;
} ArrayRecord;

typedef struct {
  Counts *counts;
  bool top;
  bool released;
} SchemaRecord;

typedef struct {
  Counts counts;
  struct ArrowSchema schema;  // moved out by get_schema
  struct ArrowArray *arrays;  // moved out by get_next, in order
  size_t n_arrays, next;
  void **pool;
  size_t n_pool;
  bool schema_fails, next_fails, released_schema, released;
  int schema_status, next_status;
  int64_t next_at, calls;
  char *schema_message, *next_message;
  const char *last_error;
} Stand;

// ---- reading the spec -------------------------------------------------------

static bool fail(napi_env env, const char *message) {
  napi_throw_error(env, "STAND_IN_SPEC", message);
  return false;
}

// The property `key` of `obj`, or NULL when it is undefined.
static napi_value prop(napi_env env, napi_value obj, const char *key) {
  napi_value v;
  napi_valuetype t;
  if (napi_get_named_property(env, obj, key, &v) != napi_ok || napi_typeof(env, v, &t) != napi_ok) return NULL;
  return t == napi_undefined ? NULL : v;
}

static bool is_null(napi_env env, napi_value v) {
  napi_valuetype t;
  return napi_typeof(env, v, &t) == napi_ok && t == napi_null;
}

static bool get_int(napi_env env, napi_value obj, const char *key, int64_t dflt, int64_t *out) {
  napi_value v = prop(env, obj, key);
  if (v == NULL) {
    *out = dflt;
    return true;
  }
  return napi_get_value_int64(env, v, out) == napi_ok || fail(env, "a number is expected");
}

// A malloc'd copy of the string `v`, or NULL with an exception pending.
static char *get_string(napi_env env, napi_value v, size_t *len_out) {
  size_t len = 0;
  if (napi_get_value_string_utf8(env, v, NULL, 0, &len) != napi_ok) {
    fail(env, "a string is expected");
    return NULL;
  }
  char *s = malloc(len + 1);
  if (s == NULL || napi_get_value_string_utf8(env, v, s, len + 1, &len) != napi_ok) {
    free(s);
    fail(env, "cannot read a string");
    return NULL;
  }
  if (len_out != NULL) *len_out = len;
  return s;
}

static bool get_length(napi_env env, napi_value list, uint32_t *n) {
  bool is_array = false;
  if (napi_is_array(env, list, &is_array) != napi_ok || !is_array) return fail(env, "a list is expected");
  return napi_get_array_length(env, list, n) == napi_ok || fail(env, "cannot read a list");
}

// The bytes of the typed array `v`.
static bool get_bytes(napi_env env, napi_value v, const void **data, size_t *size) {
  bool is_ta = false;
  napi_typedarray_type type;
  size_t length = 0;
  void *p = NULL;
  if (napi_is_typedarray(env, v, &is_ta) != napi_ok || !is_ta ||
      napi_get_typedarray_info(env, v, &type, &length, &p, NULL, NULL) != napi_ok) {
    return fail(env, "a buffer is a typed array, a pool index or null");
  }
  size_t width = 1;
  switch (type) {
    case napi_int16_array: case napi_uint16_array: width = 2; break;
    case napi_int32_array: case napi_uint32_array: case napi_float32_array: width = 4; break;
    case napi_float64_array: case napi_bigint64_array: case napi_biguint64_array: width = 8; break;
    default: width = 1; break;
  }
  *data = p;
  *size = length * width;
  return true;
}

// A copy of `size` bytes in a block aligned to 16, at `+ 1` when `misalign`.
static void *copy_bytes(const void *data, size_t size, bool misalign, void **block) {
  void *b = NULL;
  if (posix_memalign(&b, 16, size + 16) != 0) return NULL;
  char *p = (char *)b + (misalign ? 1 : 0);
  if (size > 0) memcpy(p, data, size);
  *block = b;
  return p;
}

// ---- schemas ----------------------------------------------------------------

static void release_schema(struct ArrowSchema *s) {
  SchemaRecord *rec = s->private_data;
  if (rec->released) {
    rec->counts->bad++;
    return;
  }
  rec->released = true;
  for (int64_t i = 0; i < s->n_children; i++) {
    s->children[i]->release(s->children[i]);
    free(s->children[i]);
  }
  if (s->dictionary != NULL) {
    s->dictionary->release(s->dictionary);
    free(s->dictionary);
  }
  free(s->children);
  free((void *)s->format);
  free((void *)s->name);
  free((void *)s->metadata);
  if (rec->top) rec->counts->schema_releases++;
  s->release = NULL;
}

// The C Data Interface encoding of [[key, value], ...]: an int32 count, then
// an int32 length and the bytes of each key and value.
static bool build_metadata(napi_env env, napi_value pairs, const char **out) {
  uint32_t n;
  if (!get_length(env, pairs, &n)) return false;
  size_t cap = 4, used = 4;
  char *m = malloc(cap);
  if (m == NULL) return fail(env, "out of memory");
  int32_t count = (int32_t)n;
  memcpy(m, &count, 4);
  for (uint32_t i = 0; i < n; i++) {
    napi_value pair, part;
    if (napi_get_element(env, pairs, i, &pair) != napi_ok) {
      free(m);
      return fail(env, "cannot read a pair");
    }
    for (uint32_t k = 0; k < 2; k++) {
      size_t len = 0;
      char *text = napi_get_element(env, pair, k, &part) == napi_ok ? get_string(env, part, &len) : NULL;
      if (text == NULL) {
        free(m);
        return false;
      }
      char *grown = realloc(m, used + 4 + len);
      if (grown == NULL) {
        free(text);
        free(m);
        return fail(env, "out of memory");
      }
      m = grown;
      int32_t l32 = (int32_t)len;
      memcpy(m + used, &l32, 4);
      memcpy(m + used + 4, text, len);
      used += 4 + len;
      free(text);
    }
  }
  *out = m;
  return true;
}

static bool build_schema(napi_env env, napi_value spec, Counts *counts, struct ArrowSchema *s, bool top) {
  memset(s, 0, sizeof *s);
  SchemaRecord *rec = calloc(1, sizeof *rec);
  if (rec == NULL) return fail(env, "out of memory");
  rec->counts = counts;
  rec->top = top;
  s->private_data = rec;
  s->release = release_schema;
  napi_value v;
  int64_t flags;
  if ((v = prop(env, spec, "format")) == NULL) return fail(env, "a schema needs a format");
  if ((s->format = get_string(env, v, NULL)) == NULL) return false;
  if ((v = prop(env, spec, "name")) != NULL && (s->name = get_string(env, v, NULL)) == NULL) return false;
  if (!get_int(env, spec, "flags", 0, &flags)) return false;
  s->flags = flags;
  if ((v = prop(env, spec, "metadata")) != NULL && !build_metadata(env, v, &s->metadata)) return false;
  if ((v = prop(env, spec, "children")) != NULL) {
    uint32_t n;
    if (!get_length(env, v, &n)) return false;
    s->children = calloc(n > 0 ? n : 1, sizeof *s->children);
    if (s->children == NULL) return fail(env, "out of memory");
    for (uint32_t i = 0; i < n; i++) {
      napi_value c;
      s->children[i] = malloc(sizeof **s->children);
      if (s->children[i] == NULL || napi_get_element(env, v, i, &c) != napi_ok) return fail(env, "out of memory");
      s->n_children = i + 1;
      if (!build_schema(env, c, counts, s->children[i], false)) return false;
    }
  }
  if ((v = prop(env, spec, "dictionary")) != NULL) {
    s->dictionary = malloc(sizeof *s->dictionary);
    if (s->dictionary == NULL) return fail(env, "out of memory");
    if (!build_schema(env, v, counts, s->dictionary, false)) return false;
  }
  return true;
}

// ---- arrays -----------------------------------------------------------------

static void release_array(struct ArrowArray *a) {
  ArrayRecord *rec = a->private_data;
  if (rec->released) {
    rec->counts->bad++;
    return;
  }
  rec->released = true;
  for (int64_t i = 0; i < a->n_children; i++) {
    a->children[i]->release(a->children[i]);
    free(a->children[i]);
  }
  if (a->dictionary != NULL) {
    a->dictionary->release(a->dictionary);
    free(a->dictionary);
  }
  for (int64_t i = 0; i < rec->n_owned; i++) free(rec->owned[i]);
  free(rec->owned);
  rec->owned = NULL;
  free((void *)a->buffers);
  free(a->children);
  if (rec->top) rec->counts->array_releases++;
  a->release = NULL;
}

static bool build_array(napi_env env, napi_value spec, Stand *st, struct ArrowArray *a, bool top) {
  memset(a, 0, sizeof *a);
  ArrayRecord *rec = calloc(1, sizeof *rec);
  if (rec == NULL) return fail(env, "out of memory");
  rec->counts = &st->counts;
  rec->top = top;
  a->private_data = rec;
  a->release = release_array;
  int64_t length, null_count, offset;
  if (!get_int(env, spec, "length", 0, &length) || !get_int(env, spec, "nullCount", 0, &null_count) ||
      !get_int(env, spec, "offset", 0, &offset)) {
    return false;
  }
  a->length = length;
  a->null_count = null_count;
  a->offset = offset;
  napi_value v = prop(env, spec, "misalign");
  bool misalign = false;
  if (v != NULL && napi_get_value_bool(env, v, &misalign) != napi_ok) return fail(env, "misalign is a boolean");
  if ((v = prop(env, spec, "buffers")) == NULL) return fail(env, "an array needs its buffers");
  uint32_t n;
  if (!get_length(env, v, &n)) return false;
  a->buffers = calloc(n > 0 ? n : 1, sizeof *a->buffers);
  rec->owned = calloc(n > 0 ? n : 1, sizeof *rec->owned);
  if (a->buffers == NULL || rec->owned == NULL) return fail(env, "out of memory");
  a->n_buffers = n;
  for (uint32_t i = 0; i < n; i++) {
    napi_value b;
    napi_valuetype t;
    if (napi_get_element(env, v, i, &b) != napi_ok || napi_typeof(env, b, &t) != napi_ok) {
      return fail(env, "cannot read a buffer");
    }
    if (is_null(env, b)) continue;
    if (t == napi_number) {
      int64_t k;
      if (napi_get_value_int64(env, b, &k) != napi_ok || k < 0 || (size_t)k >= st->n_pool) {
        return fail(env, "a pool index is out of range");
      }
      a->buffers[i] = st->pool[k];
      continue;
    }
    const void *data;
    size_t size;
    if (!get_bytes(env, b, &data, &size)) return false;
    void *block;
    a->buffers[i] = copy_bytes(data, size, misalign, &block);
    if (a->buffers[i] == NULL) return fail(env, "out of memory");
    rec->owned[rec->n_owned++] = block;
  }
  if ((v = prop(env, spec, "children")) != NULL) {
    if (!get_length(env, v, &n)) return false;
    a->children = calloc(n > 0 ? n : 1, sizeof *a->children);
    if (a->children == NULL) return fail(env, "out of memory");
    for (uint32_t i = 0; i < n; i++) {
      napi_value c;
      a->children[i] = malloc(sizeof **a->children);
      if (a->children[i] == NULL || napi_get_element(env, v, i, &c) != napi_ok) return fail(env, "out of memory");
      a->n_children = i + 1;
      if (!build_array(env, c, st, a->children[i], false)) return false;
    }
  }
  if ((v = prop(env, spec, "dictionary")) != NULL) {
    a->dictionary = malloc(sizeof *a->dictionary);
    if (a->dictionary == NULL) return fail(env, "out of memory");
    if (!build_array(env, v, st, a->dictionary, false)) return false;
  }
  return true;
}

// ---- the stream -------------------------------------------------------------

static int stand_get_schema(struct ArrowArrayStream *s, struct ArrowSchema *out) {
  Stand *st = s->private_data;
  if (st->schema_fails) {
    st->last_error = st->schema_message;
    return st->schema_status;
  }
  if (st->released_schema) {
    memset(out, 0, sizeof *out);
    return 0;
  }
  if (st->schema.release == NULL) return EINVAL;
  *out = st->schema;
  st->schema.release = NULL;
  return 0;
}

static int stand_get_next(struct ArrowArrayStream *s, struct ArrowArray *out) {
  Stand *st = s->private_data;
  int64_t call = st->calls++;
  if (st->next_fails && call == st->next_at) {
    st->last_error = st->next_message;
    return st->next_status;
  }
  if (st->next == st->n_arrays) {
    memset(out, 0, sizeof *out);
    return 0;
  }
  *out = st->arrays[st->next];
  st->arrays[st->next].release = NULL;
  st->next++;
  return 0;
}

static const char *stand_get_last_error(struct ArrowArrayStream *s) {
  Stand *st = s->private_data;
  return st->last_error;
}

static void stand_release(struct ArrowArrayStream *s) {
  Stand *st = s->private_data;
  if (st->released) {
    st->counts.bad++;
    return;
  }
  st->released = true;
  if (st->schema.release != NULL) st->schema.release(&st->schema);
  for (size_t i = 0; i < st->n_arrays; i++) {
    if (st->arrays[i].release != NULL) st->arrays[i].release(&st->arrays[i]);
  }
  st->counts.stream_releases++;
  s->release = NULL;
}

static void finalize_capsule(napi_env env, void *data, void *hint) {
  (void)env;
  (void)hint;
  struct ArrowArrayStream *s = data;
  if (s->release != NULL) s->release(s);
  free(s);
}

static bool get_failure(napi_env env, napi_value spec, const char *key, bool *fails, int *status,
                        char **message, int64_t *at) {
  napi_value f = prop(env, spec, key);
  if (f == NULL) return true;
  *fails = true;
  int64_t st;
  if (!get_int(env, f, "status", 0, &st) || (at != NULL && !get_int(env, f, "at", 0, at))) return false;
  *status = (int)st;
  napi_value m = prop(env, f, "message");
  return m == NULL || (*message = get_string(env, m, NULL)) != NULL;
}

static napi_value js_stream(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value spec;
  if (napi_get_cb_info(env, info, &argc, &spec, NULL, NULL) != napi_ok || argc < 1) {
    fail(env, "stream(spec)");
    return NULL;
  }
  Stand *st = calloc(1, sizeof *st);
  if (st == NULL) {
    fail(env, "out of memory");
    return NULL;
  }
  napi_value v;
  uint32_t n;
  if ((v = prop(env, spec, "pool")) != NULL) {
    if (!get_length(env, v, &n)) return NULL;
    st->pool = calloc(n > 0 ? n : 1, sizeof *st->pool);
    if (st->pool == NULL) {
      fail(env, "out of memory");
      return NULL;
    }
    for (uint32_t i = 0; i < n; i++) {
      napi_value b;
      const void *data;
      size_t size;
      void *block;
      if (napi_get_element(env, v, i, &b) != napi_ok || !get_bytes(env, b, &data, &size)) return NULL;
      if ((st->pool[i] = copy_bytes(data, size, false, &block)) == NULL) {
        fail(env, "out of memory");
        return NULL;
      }
      st->n_pool = i + 1;
    }
  }
  if ((v = prop(env, spec, "schema")) == NULL) {
    fail(env, "a stream needs a schema");
    return NULL;
  }
  if (!build_schema(env, v, &st->counts, &st->schema, true)) return NULL;
  if ((v = prop(env, spec, "batches")) == NULL || !get_length(env, v, &n)) {
    if (v == NULL) fail(env, "a stream needs its batches");
    return NULL;
  }
  st->arrays = calloc(n > 0 ? n : 1, sizeof *st->arrays);
  if (st->arrays == NULL) {
    fail(env, "out of memory");
    return NULL;
  }
  for (uint32_t i = 0; i < n; i++) {
    napi_value b;
    if (napi_get_element(env, v, i, &b) != napi_ok) return NULL;
    st->n_arrays = i + 1;
    if (!build_array(env, b, st, &st->arrays[i], true)) return NULL;
    st->counts.arrays++;
  }
  if (!get_failure(env, spec, "schemaError", &st->schema_fails, &st->schema_status, &st->schema_message, NULL) ||
      !get_failure(env, spec, "nextError", &st->next_fails, &st->next_status, &st->next_message, &st->next_at)) {
    return NULL;
  }
  if ((v = prop(env, spec, "releasedSchema")) != NULL && napi_get_value_bool(env, v, &st->released_schema) != napi_ok) {
    fail(env, "releasedSchema is a boolean");
    return NULL;
  }
  struct ArrowArrayStream *s = calloc(1, sizeof *s);
  if (s == NULL) {
    fail(env, "out of memory");
    return NULL;
  }
  s->get_schema = stand_get_schema;
  s->get_next = stand_get_next;
  s->get_last_error = stand_get_last_error;
  s->release = stand_release;
  s->private_data = st;
  napi_value ext;
  if (napi_create_external(env, s, finalize_capsule, NULL, &ext) != napi_ok ||
      napi_type_tag_object(env, ext, &g_stream_tag) != napi_ok) {
    fail(env, "cannot make the capsule");
    return NULL;
  }
  return ext;
}

// The counts of the stream of `capsule`. The importer copies the stream out
// and leaves the capsule's private_data, so it still names the stream's state,
// which is never freed.
static napi_value js_counts(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value arg;
  bool tagged = false;
  void *data = NULL;
  if (napi_get_cb_info(env, info, &argc, &arg, NULL, NULL) != napi_ok || argc < 1 ||
      napi_check_object_type_tag(env, arg, &g_stream_tag, &tagged) != napi_ok || !tagged ||
      napi_get_value_external(env, arg, &data) != napi_ok) {
    fail(env, "counts(capsule)");
    return NULL;
  }
  const Counts *c = &((Stand *)((struct ArrowArrayStream *)data)->private_data)->counts;
  const struct {
    const char *key;
    int64_t value;
  } rows[] = {
      {"arrays", c->arrays},
      {"streamReleases", c->stream_releases},
      {"schemaReleases", c->schema_releases},
      {"arrayReleases", c->array_releases},
      {"badReleases", c->bad},
  };
  napi_value obj;
  if (napi_create_object(env, &obj) != napi_ok) return NULL;
  for (size_t i = 0; i < sizeof rows / sizeof rows[0]; i++) {
    napi_value n;
    if (napi_create_int64(env, rows[i].value, &n) != napi_ok ||
        napi_set_named_property(env, obj, rows[i].key, n) != napi_ok) {
      return NULL;
    }
  }
  return obj;
}

NAPI_MODULE_INIT() {
  napi_value f;
  if (napi_create_function(env, "stream", NAPI_AUTO_LENGTH, js_stream, NULL, &f) != napi_ok ||
      napi_set_named_property(env, exports, "stream", f) != napi_ok ||
      napi_create_function(env, "counts", NAPI_AUTO_LENGTH, js_counts, NULL, &f) != napi_ok ||
      napi_set_named_property(env, exports, "counts", f) != napi_ok) {
    napi_throw_error(env, NULL, "arrow_stand_in: cannot export its functions");
    return NULL;
  }
  return exports;
}
