// The Arrow C stream import of the Node addon: an Arrow C stream drained in C
// and handed to JavaScript as descriptions over its own memory. apache-arrow
// has no importer for the C Data Interface, so the addon reads the C structs
// and the private TypeScript module (src/arrow_import.ts) builds apache-arrow
// data from the descriptions.
//
//   importArrowStream(capsule)   Promise of a result: the stream drained
//   (sql(session, text) in komira_addon.c resolves to a result of the same kind)
//   arrowSchema(result)          the stream's schema, described
//   arrowNextBatch(result)       the next batch, described, or null at the end
//   arrowClose(result)           release what the result still holds; again is a no-op
//
// The drain (arrow_drain). It calls get_schema once and get_next until the
// end of the stream, keeping every ArrowArray it is handed, then calls the
// stream's release. The arrays stay valid: each has its own release (the C
// Stream Interface). A non-zero callback status is an error with
// get_last_error's text, after the arrays taken so far, the schema and the
// stream are released. The stream is materialized by its producer, so the
// drain only moves structs. It needs no napi_env: importArrowStream runs it on
// the JavaScript thread over a stream it moves out of its capsule (arrow_c.h),
// and the addon's `sql` on the session's thread over the stream
// komira_sql_stream filled (komira_addon.c).
//
// The descriptions. A schema becomes { format, name, flags, metadata,
// children, dictionary }, metadata as [key, value] pairs or null. A batch
// becomes { length, nullCount, offset, buffers, children, dictionary }, where
// each buffer is an ArrayBuffer of the length the format and the array give
// (the C structs carry no buffer length), or null for an absent validity
// bitmap. A buffer at an 8-byte aligned address is an external ArrayBuffer
// over the array's memory; one at another address is copied into a new
// ArrayBuffer, since a typed array needs its element alignment.
//
// Ownership. A batch that arrowNextBatch takes is owned by the external
// ArrayBuffers over it: a count per batch, and the batch's release is called
// when the last of them is collected, or at once when it has none (every
// buffer copied or empty). The batches not taken and the schema are released
// by arrowClose or, if it is never called, by the result's finalizer. Every
// array and the schema are released exactly once.
//
// The formats it reads are the exporter's set (src/arrow_ipc/README.md):
// integers, floats, bool, dates, times, timestamps, durations, intervals,
// decimal128 and decimal256, utf8 and binary and their large forms,
// dictionaries with an integer index, list, struct, map, and sparse and dense
// unions. Another format is an error naming the column; the TypeScript
// module refuses it from the schema before it reads a batch.
#include "arrow_import.h"

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "arrow_c.h"

static const napi_type_tag g_stream_tag = {KOMIRA_ARROW_STREAM_TAG_LOWER, KOMIRA_ARROW_STREAM_TAG_UPPER};
// Marks the results this addon makes ("komira.arrow.result").
static const napi_type_tag g_result_tag = {0x6b6f6d6972612e61ULL, 0x72726f772e726573ULL};

// The largest length or offset JavaScript holds exactly (2^53).
#define MAX_EXACT (INT64_C(1) << 53)

struct ArrowResult {
  struct ArrowSchema schema;  // release is NULL once released
  struct ArrowArray *arrays;  // the batches get_next handed out, in order
  size_t n_arrays;
  size_t next;  // the batch arrowNextBatch takes next
  bool closed;
};
typedef struct ArrowResult Result;

// A batch JavaScript holds: one count for each external ArrayBuffer over its
// memory, and one for the description while it is being made.
typedef struct {
  struct ArrowArray array;
  atomic_int_fast64_t refs;
} Shared;

static napi_value throw_error(napi_env env, const char *code, const char *message) {
  napi_throw_error(env, code, message);
  return NULL;
}

static napi_value throw_type(napi_env env, const char *message) {
  napi_throw_type_error(env, "KOMIRA_ARG", message);
  return NULL;
}

// An Error with `code` and `message`, or NULL.
static napi_value make_error(napi_env env, const char *code, const char *message) {
  napi_value code_v, msg_v, err;
  if (napi_create_string_utf8(env, code, NAPI_AUTO_LENGTH, &code_v) != napi_ok ||
      napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &msg_v) != napi_ok ||
      napi_create_error(env, code_v, msg_v, &err) != napi_ok) {
    return NULL;
  }
  return err;
}

static void release_schema(struct ArrowSchema *s) {
  if (s->release != NULL) s->release(s);
}

static void release_array(struct ArrowArray *a) {
  if (a->release != NULL) a->release(a);
}

// Releases the schema and every batch the result still holds.
static void result_release(Result *r) {
  for (size_t i = r->next; i < r->n_arrays; i++) release_array(&r->arrays[i]);
  r->next = r->n_arrays;
  release_schema(&r->schema);
  free(r->arrays);
  r->arrays = NULL;
  r->n_arrays = 0;
  r->closed = true;
}

static void finalize_result(napi_env env, void *data, void *hint) {
  (void)env;
  (void)hint;
  Result *r = data;
  result_release(r);
  free(r);
}

// ---- the drain --------------------------------------------------------------

// A malloc'd copy of `text`, or NULL when there is no memory for it.
static char *copy_text(const char *text) {
  size_t n = strlen(text) + 1;
  char *out = malloc(n);
  if (out != NULL) memcpy(out, text, n);
  return out;
}

// Records a drain error that is not a callback's. Returns false.
static bool drain_failed(ArrowDrainError *err, const char *code, const char *message) {
  err->code = code;
  err->message = copy_text(message);
  return false;
}

// Records the failure of callback `op`: `<op> failed (status N): <text>`, with
// get_last_error's text, read before the stream is released (empty when it
// gives none). Returns false.
static bool stream_failed(ArrowDrainError *err, struct ArrowArrayStream *s, const char *op, int status) {
  const char *text = s->get_last_error != NULL ? s->get_last_error(s) : NULL;
  if (text == NULL) text = "";
  err->code = "KOMIRA_ARROW_STREAM";
  err->status = status;
  err->last = copy_text(text);
  size_t cap = strlen(op) + strlen(text) + 64;
  err->message = malloc(cap);
  if (err->message != NULL) {
    if (text[0] != '\0') {
      snprintf(err->message, cap, "%s failed (status %d): %s", op, status, text);
    } else {
      snprintf(err->message, cap, "%s failed (status %d)", op, status);
    }
  }
  return false;
}

// Drains `s` into `r`. Returns true on success; otherwise false with `*err`
// filled. The stream itself is released by the caller either way.
static bool drain(struct ArrowArrayStream *s, Result *r, ArrowDrainError *err) {
  int rc = s->get_schema(s, &r->schema);
  if (rc != 0) return stream_failed(err, s, "get_schema", rc);
  if (r->schema.release == NULL) {
    return drain_failed(err, "KOMIRA_ARROW_INVALID", "get_schema returned a released schema");
  }
  if (r->schema.format == NULL || strcmp(r->schema.format, "+s") != 0) {
    char msg[160];
    snprintf(msg, sizeof msg, "the stream's schema has format \"%.64s\", not a struct (\"+s\")",
             r->schema.format != NULL ? r->schema.format : "");
    return drain_failed(err, "KOMIRA_ARROW_INVALID", msg);
  }
  size_t cap = 0;
  for (;;) {
    struct ArrowArray a;
    memset(&a, 0, sizeof a);
    rc = s->get_next(s, &a);
    if (rc != 0) return stream_failed(err, s, "get_next", rc);
    if (a.release == NULL) return true;  // the end of the stream
    if (r->n_arrays == cap) {
      size_t grown = cap == 0 ? 4 : cap * 2;
      struct ArrowArray *more = realloc(r->arrays, grown * sizeof *more);
      if (more == NULL) {
        release_array(&a);
        return drain_failed(err, "KOMIRA_ERR_NOMEM", "out of memory");
      }
      r->arrays = more;
      cap = grown;
    }
    r->arrays[r->n_arrays++] = a;
  }
}

ArrowResult *arrow_drain(struct ArrowArrayStream *stream, ArrowDrainError *err) {
  memset(err, 0, sizeof *err);
  Result *r = calloc(1, sizeof *r);
  if (r == NULL) {
    stream->release(stream);
    drain_failed(err, "KOMIRA_ERR_NOMEM", "out of memory");
    return NULL;
  }
  bool ok = drain(stream, r, err);
  stream->release(stream);
  if (!ok) {
    result_release(r);
    free(r);
    return NULL;
  }
  return r;
}

void arrow_drain_error_free(ArrowDrainError *err) {
  free(err->message);
  free(err->last);
  err->message = NULL;
  err->last = NULL;
}

napi_value arrow_drain_error_value(napi_env env, const ArrowDrainError *err) {
  if (err->message == NULL) return make_error(env, "KOMIRA_ERR_NOMEM", "out of memory");
  napi_value e = make_error(env, err->code, err->message);
  if (e == NULL || strcmp(err->code, "KOMIRA_ARROW_STREAM") != 0) return e;
  napi_value status_v, text_v;
  if (napi_create_int32(env, err->status, &status_v) != napi_ok ||
      napi_create_string_utf8(env, err->last != NULL ? err->last : "", NAPI_AUTO_LENGTH, &text_v) != napi_ok ||
      napi_set_named_property(env, e, "status", status_v) != napi_ok ||
      napi_set_named_property(env, e, "lastError", text_v) != napi_ok) {
    return NULL;
  }
  return e;
}

void arrow_result_free(ArrowResult *r) {
  if (r == NULL) return;
  result_release(r);
  free(r);
}

napi_value arrow_result_value(napi_env env, ArrowResult *r) {
  napi_value ext = NULL;
  if (napi_create_external(env, r, finalize_result, NULL, &ext) != napi_ok) {
    arrow_result_free(r);
    return NULL;
  }
  // From here the external owns `r` through its finalizer.
  if (napi_type_tag_object(env, ext, &g_result_tag) != napi_ok) return NULL;
  return ext;
}

// ---- importArrowStream ------------------------------------------------------

// The exception pending in `env`, or a KOMIRA_NAPI error when there is none.
static napi_value pending_or_napi(napi_env env) {
  napi_value pending = NULL;
  if (napi_get_and_clear_last_exception(env, &pending) != napi_ok || pending == NULL) {
    pending = make_error(env, "KOMIRA_NAPI", "cannot make the result");
  }
  return pending;
}

static napi_value js_import_arrow_stream(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1];
  if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok) {
    return throw_error(env, "KOMIRA_NAPI", "cannot read the arguments");
  }
  napi_valuetype t = napi_undefined;
  bool tagged = false;
  void *data = NULL;
  if (argc < 1 || napi_typeof(env, argv[0], &t) != napi_ok || t != napi_external ||
      napi_check_object_type_tag(env, argv[0], &g_stream_tag, &tagged) != napi_ok || !tagged ||
      napi_get_value_external(env, argv[0], &data) != napi_ok || data == NULL) {
    return throw_type(env, "importArrowStream takes an Arrow C stream capsule");
  }
  struct ArrowArrayStream *src = data;
  if (src->release == NULL) {
    return throw_type(env, "the Arrow C stream was already imported or released");
  }
  // Move the stream out of the capsule: its maker's finalizer then leaves it alone.
  struct ArrowArrayStream stream = *src;
  src->release = NULL;

  napi_deferred deferred;
  napi_value promise;
  if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
    stream.release(&stream);
    return throw_error(env, "KOMIRA_NAPI", "cannot make the promise");
  }
  ArrowDrainError err;
  ArrowResult *r = arrow_drain(&stream, &err);
  napi_value v;
  if (r != NULL) {
    v = arrow_result_value(env, r);
    if (v != NULL) {
      napi_resolve_deferred(env, deferred, v);
      return promise;
    }
    v = pending_or_napi(env);
  } else {
    v = arrow_drain_error_value(env, &err);
    arrow_drain_error_free(&err);
    if (v == NULL) v = pending_or_napi(env);
  }
  if (v == NULL) napi_get_undefined(env, &v);
  napi_reject_deferred(env, deferred, v);
  return promise;
}

// ---- the result -------------------------------------------------------------

// The Result behind `v`, open, or NULL with an exception pending.
static Result *get_result(napi_env env, napi_callback_info info, bool allow_closed) {
  size_t argc = 1;
  napi_value argv[1];
  napi_valuetype t = napi_undefined;
  bool tagged = false;
  void *data = NULL;
  if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc < 1 ||
      napi_typeof(env, argv[0], &t) != napi_ok || t != napi_external ||
      napi_check_object_type_tag(env, argv[0], &g_result_tag, &tagged) != napi_ok || !tagged ||
      napi_get_value_external(env, argv[0], &data) != napi_ok || data == NULL) {
    throw_type(env, "the result must be a value importArrowStream or sql resolved to");
    return NULL;
  }
  Result *r = data;
  if (r->closed && !allow_closed) {
    throw_error(env, "KOMIRA_ARROW_CLOSED", "the Arrow result was closed");
    return NULL;
  }
  return r;
}

// Throws KOMIRA_ARROW_INVALID: `column "<path>": <what>`, or `the batch:
// <what>` for the batch itself (the empty path). Returns NULL.
static napi_value invalid(napi_env env, const char *path, const char *what) {
  size_t cap = strlen(path) + strlen(what) + 32;
  char *message = malloc(cap);
  if (message == NULL) return throw_error(env, "KOMIRA_ERR_NOMEM", "out of memory");
  if (path[0] == '\0') {
    snprintf(message, cap, "the batch: %s", what);
  } else {
    snprintf(message, cap, "column \"%s\": %s", path, what);
  }
  throw_error(env, "KOMIRA_ARROW_INVALID", message);
  free(message);
  return NULL;
}

// `parent.name` (or `name` at the top), malloc'd; NULL when out of memory.
static char *child_path(const char *parent, const char *name) {
  if (name == NULL) name = "";
  size_t cap = strlen(parent) + strlen(name) + 2;
  char *p = malloc(cap);
  if (p == NULL) return NULL;
  if (parent[0] == '\0') {
    snprintf(p, cap, "%s", name);
  } else {
    snprintf(p, cap, "%s.%s", parent, name);
  }
  return p;
}

static bool set_number(napi_env env, napi_value obj, const char *key, double v) {
  napi_value n;
  return napi_create_double(env, v, &n) == napi_ok && napi_set_named_property(env, obj, key, n) == napi_ok;
}

static bool set_string(napi_env env, napi_value obj, const char *key, const char *s) {
  napi_value v;
  if (s == NULL) {
    if (napi_get_null(env, &v) != napi_ok) return false;
  } else if (napi_create_string_utf8(env, s, NAPI_AUTO_LENGTH, &v) != napi_ok) {
    return false;
  }
  return napi_set_named_property(env, obj, key, v) == napi_ok;
}

// The schema's metadata as [key, value] pairs, or null: an int32 count, then
// for each pair an int32 length and the bytes of the key, then of the value,
// in native byte order (the C Data Interface).
static napi_value describe_metadata(napi_env env, const char *path, const char *m) {
  napi_value out;
  if (m == NULL) {
    if (napi_get_null(env, &out) != napi_ok) return NULL;
    return out;
  }
  int32_t n;
  memcpy(&n, m, 4);
  m += 4;
  if (n < 0) return invalid(env, path, "the metadata has a negative count");
  if (napi_create_array_with_length(env, (size_t)n, &out) != napi_ok) return NULL;
  for (int32_t i = 0; i < n; i++) {
    napi_value pair, part;
    if (napi_create_array_with_length(env, 2, &pair) != napi_ok) return NULL;
    for (uint32_t k = 0; k < 2; k++) {
      int32_t len;
      memcpy(&len, m, 4);
      m += 4;
      if (len < 0) return invalid(env, path, "the metadata has a negative length");
      if (napi_create_string_utf8(env, m, (size_t)len, &part) != napi_ok ||
          napi_set_element(env, pair, k, part) != napi_ok) {
        return NULL;
      }
      m += len;
    }
    if (napi_set_element(env, out, (uint32_t)i, pair) != napi_ok) return NULL;
  }
  return out;
}

static napi_value describe_schema(napi_env env, const struct ArrowSchema *s, const char *path) {
  if (s->format == NULL) return invalid(env, path, "the schema has no format");
  if (s->n_children < 0 || (s->n_children > 0 && s->children == NULL)) {
    return invalid(env, path, "the schema's children are missing");
  }
  napi_value obj, metadata, children, dictionary;
  if (napi_create_object(env, &obj) != napi_ok || !set_string(env, obj, "format", s->format) ||
      !set_string(env, obj, "name", s->name) || !set_number(env, obj, "flags", (double)s->flags)) {
    return NULL;
  }
  metadata = describe_metadata(env, path, s->metadata);
  if (metadata == NULL || napi_set_named_property(env, obj, "metadata", metadata) != napi_ok) return NULL;
  if (napi_create_array_with_length(env, (size_t)s->n_children, &children) != napi_ok) return NULL;
  for (int64_t i = 0; i < s->n_children; i++) {
    const struct ArrowSchema *c = s->children[i];
    if (c == NULL) return invalid(env, path, "the schema's children are missing");
    char *cp = child_path(path, c->name);
    if (cp == NULL) return throw_error(env, "KOMIRA_ERR_NOMEM", "out of memory");
    napi_value d = describe_schema(env, c, cp);
    free(cp);
    if (d == NULL || napi_set_element(env, children, (uint32_t)i, d) != napi_ok) return NULL;
  }
  if (napi_set_named_property(env, obj, "children", children) != napi_ok) return NULL;
  if (s->dictionary == NULL) {
    if (napi_get_null(env, &dictionary) != napi_ok) return NULL;
  } else {
    dictionary = describe_schema(env, s->dictionary, path);
    if (dictionary == NULL) return NULL;
  }
  if (napi_set_named_property(env, obj, "dictionary", dictionary) != napi_ok) return NULL;
  return obj;
}

static napi_value js_arrow_schema(napi_env env, napi_callback_info info) {
  Result *r = get_result(env, info, false);
  if (r == NULL) return NULL;
  return describe_schema(env, &r->schema, "");
}

// ---- batches ----------------------------------------------------------------

// What a buffer of an array holds, so its length can be computed.
typedef enum {
  K_VALIDITY,   // a bitmap, one bit per slot
  K_BITS,       // bool values, one bit per slot
  K_FIXED,      // `width` bytes per slot
  K_OFFSETS32,  // length + 1 int32 offsets
  K_OFFSETS64,  // length + 1 int64 offsets
  K_DATA32,     // the bytes the int32 offsets of the buffer before reach
  K_DATA64,     // the bytes the int64 offsets of the buffer before reach
  K_TYPE_IDS,   // one int8 per slot
  K_UNION_OFFSETS,  // one int32 per slot
} Kind;

typedef struct {
  int n_buffers;
  Kind kind[3];
  int64_t width;      // for K_FIXED
  int64_t children;   // -1: as many as the schema has
} Layout;

static bool fixed(Layout *l, int64_t width) {
  l->n_buffers = 2;
  l->kind[0] = K_VALIDITY;
  l->kind[1] = K_FIXED;
  l->width = width;
  l->children = 0;
  return true;
}

static bool var(Layout *l, Kind offsets, Kind data) {
  l->n_buffers = 3;
  l->kind[0] = K_VALIDITY;
  l->kind[1] = offsets;
  l->kind[2] = data;
  l->children = 0;
  return true;
}

// The byte width of an integer format, or 0.
static int64_t int_width(const char *f) {
  if (f[0] == '\0' || f[1] != '\0') return 0;
  switch (f[0]) {
    case 'c': case 'C': return 1;
    case 's': case 'S': return 2;
    case 'i': case 'I': return 4;
    case 'l': case 'L': return 8;
    default: return 0;
  }
}

// The buffers and children of format `f`; false for a format not read here.
static bool layout_of(const char *f, Layout *l) {
  static const struct {
    const char *format;
    int64_t width;
  } widths[] = {
      {"e", 2},   {"f", 4},   {"g", 8},   {"tdD", 4}, {"tdm", 8}, {"tts", 4}, {"ttm", 4},
      {"ttu", 8}, {"ttn", 8}, {"tDs", 8}, {"tDm", 8}, {"tDu", 8}, {"tDn", 8}, {"tiM", 4},
      {"tiD", 8}, {"tin", 16},
  };
  int64_t w = int_width(f);
  if (w > 0) return fixed(l, w);
  for (size_t i = 0; i < sizeof widths / sizeof widths[0]; i++) {
    if (strcmp(f, widths[i].format) == 0) return fixed(l, widths[i].width);
  }
  if (f[0] == 't' && f[1] == 's' && f[2] != '\0' && strchr("smun", f[2]) != NULL && f[3] == ':') {
    return fixed(l, 8);
  }
  if (f[0] == 'd' && f[1] == ':') {
    // d:precision,scale[,bitwidth]
    const char *comma = strchr(f + 2, ',');
    if (comma == NULL) return false;
    const char *width = strchr(comma + 1, ',');
    if (width == NULL || strcmp(width, ",128") == 0) return fixed(l, 16);
    if (strcmp(width, ",256") == 0) return fixed(l, 32);
    return false;
  }
  if (strcmp(f, "b") == 0) {
    fixed(l, 0);
    l->kind[1] = K_BITS;
    return true;
  }
  if (strcmp(f, "u") == 0 || strcmp(f, "z") == 0) return var(l, K_OFFSETS32, K_DATA32);
  if (strcmp(f, "U") == 0 || strcmp(f, "Z") == 0) return var(l, K_OFFSETS64, K_DATA64);
  if (strcmp(f, "+l") == 0 || strcmp(f, "+m") == 0) {
    l->n_buffers = 2;
    l->kind[0] = K_VALIDITY;
    l->kind[1] = K_OFFSETS32;
    l->children = 1;
    return true;
  }
  if (strcmp(f, "+s") == 0) {
    l->n_buffers = 1;
    l->kind[0] = K_VALIDITY;
    l->children = -1;
    return true;
  }
  if (strncmp(f, "+us:", 4) == 0 || strncmp(f, "+ud:", 4) == 0) {
    // A union has no validity bitmap.
    l->n_buffers = f[2] == 's' ? 1 : 2;
    l->kind[0] = K_TYPE_IDS;
    l->kind[1] = K_UNION_OFFSETS;
    l->children = -1;
    return true;
  }
  return false;
}

static void shared_unref(Shared *sh) {
  if (atomic_fetch_sub(&sh->refs, 1) == 1) {
    release_array(&sh->array);
    free(sh);
  }
}

static void finalize_buffer(napi_env env, void *data, void *hint) {
  (void)env;
  (void)data;
  shared_unref(hint);
}

// An ArrayBuffer of `size` bytes at `p`: external over the batch's memory when
// `p` is 8-byte aligned (one more count on `sh`), a copy otherwise, and a new
// empty one for no bytes.
static napi_value make_buffer(napi_env env, Shared *sh, const void *p, uint64_t size) {
  napi_value ab;
  void *copy = NULL;
  if (size == 0 || ((uintptr_t)p % 8) != 0) {
    if (napi_create_arraybuffer(env, (size_t)size, &copy, &ab) != napi_ok) return NULL;
    if (size > 0) memcpy(copy, p, (size_t)size);
    return ab;
  }
  atomic_fetch_add(&sh->refs, 1);
  if (napi_create_external_arraybuffer(env, (void *)p, (size_t)size, finalize_buffer, sh, &ab) != napi_ok) {
    atomic_fetch_sub(&sh->refs, 1);
    return NULL;
  }
  return ab;
}

// The offset at index `i` of an int32 or int64 offsets buffer.
static int64_t offset_at(const void *offsets, bool wide, int64_t i) {
  if (wide) {
    int64_t v;
    memcpy(&v, (const char *)offsets + i * 8, 8);
    return v;
  }
  int32_t v;
  memcpy(&v, (const char *)offsets + i * 4, 4);
  return v;
}

static napi_value describe_array(napi_env env, Shared *sh, const struct ArrowSchema *s,
                                 const struct ArrowArray *a, const char *path);

// The children (or, with `dictionary`, the dictionary) of `a`, described.
static napi_value describe_children(napi_env env, Shared *sh, const struct ArrowSchema *s,
                                    const struct ArrowArray *a, const char *path) {
  napi_value children;
  if (napi_create_array_with_length(env, (size_t)a->n_children, &children) != napi_ok) return NULL;
  for (int64_t i = 0; i < a->n_children; i++) {
    const struct ArrowSchema *cs = s->children[i];
    if (cs == NULL) return invalid(env, path, "the schema's children are missing");
    char *cp = child_path(path, cs->name);
    if (cp == NULL) return throw_error(env, "KOMIRA_ERR_NOMEM", "out of memory");
    napi_value d = describe_array(env, sh, cs, a->children[i], cp);
    free(cp);
    if (d == NULL || napi_set_element(env, children, (uint32_t)i, d) != napi_ok) return NULL;
  }
  return children;
}

static napi_value describe_array(napi_env env, Shared *sh, const struct ArrowSchema *s,
                                 const struct ArrowArray *a, const char *path) {
  char what[160];
  if (a == NULL) return invalid(env, path, "the array is missing");
  Layout l = {0};
  if (s->dictionary != NULL) {
    // A dictionary-encoded array holds the indices; the values are its dictionary.
    if (int_width(s->format) == 0) {
      snprintf(what, sizeof what, "dictionary index format \"%.32s\" is not an integer", s->format);
      return invalid(env, path, what);
    }
    fixed(&l, int_width(s->format));
  } else if (!layout_of(s->format, &l)) {
    snprintf(what, sizeof what, "format \"%.64s\" is not supported", s->format);
    return invalid(env, path, what);
  }
  int64_t want_children = l.children < 0 ? s->n_children : l.children;
  if (a->n_buffers != l.n_buffers || (a->n_buffers > 0 && a->buffers == NULL)) {
    snprintf(what, sizeof what, "format \"%.64s\" has %d buffers, the array has %lld", s->format, l.n_buffers,
             (long long)a->n_buffers);
    return invalid(env, path, what);
  }
  if (a->n_children != want_children || s->n_children != want_children ||
      (a->n_children > 0 && (a->children == NULL || s->children == NULL))) {
    snprintf(what, sizeof what, "the schema has %lld children, the array has %lld", (long long)s->n_children,
             (long long)a->n_children);
    return invalid(env, path, what);
  }
  if ((s->dictionary != NULL) != (a->dictionary != NULL)) {
    return invalid(env, path, s->dictionary != NULL ? "the array has no dictionary" : "the array has a dictionary the schema does not");
  }
  if (a->length < 0 || a->offset < 0 || a->length > MAX_EXACT || a->offset > MAX_EXACT - a->length ||
      a->null_count < -1 || a->null_count > a->length) {
    snprintf(what, sizeof what, "length %lld, offset %lld and null count %lld are out of range",
             (long long)a->length, (long long)a->offset, (long long)a->null_count);
    return invalid(env, path, what);
  }
  int64_t slots = a->offset + a->length;

  napi_value obj, buffers, children, dictionary;
  if (napi_create_object(env, &obj) != napi_ok || !set_number(env, obj, "length", (double)a->length) ||
      !set_number(env, obj, "nullCount", (double)a->null_count) ||
      !set_number(env, obj, "offset", (double)a->offset) ||
      napi_create_array_with_length(env, (size_t)l.n_buffers, &buffers) != napi_ok) {
    return NULL;
  }
  for (int i = 0; i < l.n_buffers; i++) {
    const void *p = a->buffers[i];
    uint64_t size = 0;
    switch (l.kind[i]) {
      case K_VALIDITY:
      case K_BITS: size = (uint64_t)(slots + 7) / 8; break;
      case K_FIXED: size = (uint64_t)slots * (uint64_t)l.width; break;
      // An array of no slots reads no offset: its offsets buffer may hold none.
      case K_OFFSETS32: size = slots == 0 ? 0 : (uint64_t)(slots + 1) * 4; break;
      case K_OFFSETS64: size = slots == 0 ? 0 : (uint64_t)(slots + 1) * 8; break;
      case K_TYPE_IDS: size = (uint64_t)slots; break;
      case K_UNION_OFFSETS: size = (uint64_t)slots * 4; break;
      case K_DATA32:
      case K_DATA64: {
        const void *offsets = a->buffers[i - 1];
        int64_t end = offsets == NULL || slots == 0 ? 0 : offset_at(offsets, l.kind[i] == K_DATA64, slots);
        if (end < 0) {
          snprintf(what, sizeof what, "the last offset is negative (%lld)", (long long)end);
          return invalid(env, path, what);
        }
        size = (uint64_t)end;
        break;
      }
    }
    napi_value b;
    if (p == NULL && (l.kind[i] == K_VALIDITY || size == 0)) {
      // No bitmap means no nulls, and a buffer of no bytes may be NULL.
      if (l.kind[i] == K_VALIDITY) {
        if (napi_get_null(env, &b) != napi_ok) return NULL;
      } else if ((b = make_buffer(env, sh, NULL, 0)) == NULL) {
        return NULL;
      }
    } else if (p == NULL) {
      snprintf(what, sizeof what, "buffer %d is NULL", i);
      return invalid(env, path, what);
    } else if ((b = make_buffer(env, sh, p, size)) == NULL) {
      return NULL;
    }
    if (napi_set_element(env, buffers, (uint32_t)i, b) != napi_ok) return NULL;
  }
  if (napi_set_named_property(env, obj, "buffers", buffers) != napi_ok) return NULL;
  children = describe_children(env, sh, s, a, path);
  if (children == NULL || napi_set_named_property(env, obj, "children", children) != napi_ok) return NULL;
  if (a->dictionary == NULL) {
    if (napi_get_null(env, &dictionary) != napi_ok) return NULL;
  } else {
    dictionary = describe_array(env, sh, s->dictionary, a->dictionary, path);
    if (dictionary == NULL) return NULL;
  }
  if (napi_set_named_property(env, obj, "dictionary", dictionary) != napi_ok) return NULL;
  return obj;
}

static napi_value js_arrow_next_batch(napi_env env, napi_callback_info info) {
  Result *r = get_result(env, info, false);
  if (r == NULL) return NULL;
  napi_value out;
  if (r->next == r->n_arrays) {
    if (napi_get_null(env, &out) != napi_ok) return NULL;
    return out;
  }
  Shared *sh = malloc(sizeof *sh);
  if (sh == NULL) return throw_error(env, "KOMIRA_ERR_NOMEM", "out of memory");
  // The batch is JavaScript's now: the result no longer releases it.
  sh->array = r->arrays[r->next];
  memset(&r->arrays[r->next], 0, sizeof r->arrays[r->next]);
  r->next++;
  atomic_init(&sh->refs, 1);
  out = describe_array(env, sh, &r->schema, &sh->array, "");
  // Drop the description's own count: with no external buffer, or when the
  // description failed and its buffers are garbage, this releases the batch
  // now or when they are collected.
  shared_unref(sh);
  return out;
}

static napi_value js_arrow_close(napi_env env, napi_callback_info info) {
  Result *r = get_result(env, info, true);
  if (r == NULL) return NULL;
  result_release(r);
  napi_value out;
  if (napi_get_undefined(env, &out) != napi_ok) return NULL;
  return out;
}

int arrow_import_export(napi_env env, napi_value exports) {
  static const struct {
    const char *name;
    napi_callback fn;
  } calls[] = {
      {"importArrowStream", js_import_arrow_stream},
      {"arrowSchema", js_arrow_schema},
      {"arrowNextBatch", js_arrow_next_batch},
      {"arrowClose", js_arrow_close},
  };
  for (size_t i = 0; i < sizeof calls / sizeof calls[0]; i++) {
    napi_value f;
    if (napi_create_function(env, calls[i].name, NAPI_AUTO_LENGTH, calls[i].fn, NULL, &f) != napi_ok ||
        napi_set_named_property(env, exports, calls[i].name, f) != napi_ok) {
      return 0;
    }
  }
  return 1;
}
