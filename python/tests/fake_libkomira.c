// A stand-in for libkomira with the calls of ABI 1.1 that the Python loader
// binds, and, when FAKE_VERSION is 1.2 or later, the three credential calls of
// ABI 1.2 over a fake store, when it is 1.3 or later, komira_sql_stream
// answering a stand-in Arrow C stream, and when it is 1.7 or later,
// komira_last_error_code and komira_last_error_step (all below). The tests load it to reach what the real
// library never does:
//
// - FAKE_VERSION sets the ABI version it reports (default 1001, which is 1.1):
//   a library of another major version must be refused, any minor accepted.
// - FAKE_ABI_1_0 leaves out the five calls ABI 1.1 added, as a 1.0 library
//   would: it must load, and those calls must raise when used.
// - FAKE_OMIT_REGISTER leaves out komira_register_parquet, and
//   FAKE_OMIT_ABI_VERSION leaves out komira_abi_version: the loader must
//   refuse each by the symbol's name.
// - Otherwise komira_register_parquet takes its `name` as the mode of every
//   later call and answers by it, so one library drives each case of the
//   two-call protocol and of the error path (see komira_last_error below):
//   "ok", "empty_out" and "null_ctx" succeed; "null_arg" fails with -2; every
//   other name fails with -3. After "null_ctx", komira_ctx_new returns NULL.
//   The four output calls fail with the same status; when they succeed they
//   answer with text naming the arguments they were given, and with nothing
//   in "empty_out".
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#ifndef FAKE_VERSION
#define FAKE_VERSION 1001
#endif

#define EXPORT __attribute__((visibility("default")))

static char mode[32];
static int the_ctx;

static int is(const char *m) { return strcmp(mode, m) == 0; }

#ifndef FAKE_OMIT_ABI_VERSION
EXPORT int32_t komira_abi_version(void) { return FAKE_VERSION; }
#endif

EXPORT void *komira_ctx_new(void) { return is("null_ctx") ? NULL : &the_ctx; }

EXPORT void komira_ctx_free(void *ctx) { (void)ctx; }

// The two-call protocol of the real library: the length first, and nothing
// written unless the capacity holds it all.
static int32_t copy_out(const char *text, uint64_t len, uint8_t *b, uint64_t cap, uint64_t *n) {
  *n = len;
  if (cap < len) return -4;
  if (len > 0) memcpy(b, text, len);
  return 0;
}

// The last error of a credential call or of komira_sql_stream (below);
// empty when the last one had none.
static char cred_error[256];

// The code and step of that error, which komira_last_error_code and
// komira_last_error_step (ABI 1.7, below) answer: empty and 0 when it has
// none. Every call that sets or clears cred_error sets or clears them too.
static char err_code[64];
static int32_t err_step;

__attribute__((unused)) static void clear_error(void) {
  cred_error[0] = 0;
  err_code[0] = 0;
  err_step = 0;
}

// The last error, by mode:
//   "capacity"    29 bytes of text naming the capacity the call was given
//                 ("capacity " and 20 digits): the second call's capacity;
//   "null_arg"    "name is NULL";
//   "utf8"        "caf\xc3\xa9 bad\xff": UTF-8, then a byte that is not;
//   "grow"        4 bytes on the first call, 8 on the second, never written;
//   "shrink"      8 bytes on the first call; the second succeeds with 4;
//   "fail_second" 8 bytes on the first call; the second fails with -1;
//   "unreadable"  the call itself fails with -2;
//   otherwise     no text (length 0, success).
EXPORT int32_t komira_last_error(void *ctx, uint8_t *b, uint64_t cap, uint64_t *n) {
  (void)ctx;
  if (cred_error[0]) return copy_out(cred_error, strlen(cred_error), b, cap, n);
  if (is("capacity")) {
    char text[30];
    snprintf(text, sizeof text, "capacity %020llu", (unsigned long long)cap);
    return copy_out(text, 29, b, cap, n);
  }
  if (is("null_arg")) return copy_out("name is NULL", 12, b, cap, n);
  if (is("utf8")) return copy_out("caf\xc3\xa9 bad\xff", 10, b, cap, n);
  if (is("grow")) {
    *n = cap == 0 ? 4 : 8;
    return -4;
  }
  if (is("shrink")) {
    if (cap == 0) {
      *n = 8;
      return -4;
    }
    memcpy(b, "abcd", 4);
    *n = 4;
    return 0;
  }
  if (is("fail_second")) {
    if (cap == 0) {
      *n = 8;
      return -4;
    }
    return -1;
  }
  if (is("unreadable")) return -2;
  *n = 0;
  return 0;
}

#ifndef FAKE_ABI_1_0

// The status every call of a 1.1 library answers with in this mode.
static int32_t mode_status(void) {
  if (is("ok") || is("empty_out") || is("null_ctx")) return 0;
  if (is("null_arg")) return -2;
  return -3;
}

#ifndef FAKE_OMIT_REGISTER
EXPORT int32_t komira_register_parquet(void *ctx, const char *name, const char *path) {
  (void)ctx;
  (void)path;
  snprintf(mode, sizeof mode, "%s", name);
  return mode_status();
}
#endif

// An output call's answer: `text` in "ok", nothing in "empty_out", else the
// mode's failure.
static int32_t answer(const char *text, uint8_t *b, uint64_t cap, uint64_t *n) {
  int32_t status = mode_status();
  if (status != 0) return status;
  if (is("empty_out")) return copy_out("", 0, b, cap, n);
  return copy_out(text, strlen(text), b, cap, n);
}

static char out[512];

EXPORT int32_t komira_parquet_schema(void *ctx, const char *path, uint8_t *b, uint64_t cap, uint64_t *n) {
  (void)ctx;
  snprintf(out, sizeof out, "parquet:%s", path);
  return answer(out, b, cap, n);
}

EXPORT int32_t komira_csv_binding(void *ctx, const char *path, uint8_t delimiter, int32_t has_header,
                                  int32_t all_varchar, uint8_t *b, uint64_t cap, uint64_t *n) {
  (void)ctx;
  snprintf(out, sizeof out, "csv:%s:%u:%d:%d", path, (unsigned)delimiter, (int)has_header, (int)all_varchar);
  return answer(out, b, cap, n);
}

EXPORT int32_t komira_json_binding(void *ctx, const char *path, uint8_t *b, uint64_t cap, uint64_t *n) {
  (void)ctx;
  snprintf(out, sizeof out, "json:%s", path);
  return answer(out, b, cap, n);
}

// The plan's length and its bytes in hex, so a NUL byte inside it shows.
EXPORT int32_t komira_plan_render(void *ctx, const uint8_t *plan, uint64_t plan_len, uint8_t *b, uint64_t cap,
                                  uint64_t *n) {
  (void)ctx;
  int k = snprintf(out, sizeof out, "plan:%llu:", (unsigned long long)plan_len);
  for (uint64_t i = 0; i < plan_len && k + 3 < (int)sizeof out; i++) k += snprintf(out + k, sizeof out - k, "%02x", plan[i]);
  return answer(out, b, cap, n);
}

#endif

#if !defined(FAKE_ABI_1_0) && FAKE_VERSION % 1000 >= 2

// The fake store: each credential call appends one line saying what it was
// given, and komira_fake_store hands the lines back, so a test sees exactly
// the calls, their order and the bytes of every value:
//
//   add <kind> <name> <id>          (the id written to *out_id)
//   set <id> <field> <hex of value> (the value's bytes in hex, so a NUL shows)
//   seal <id> <scope>
//
// A call refused below appends nothing. How a call is refused, by the name
// of its credential or by its value:
//   name "refuse_add"     add fails with -3 and a CREDENTIALS_INVALID error;
//   name "silent"         add fails with -3 and no last error;
//   name "null_arg"       add fails with -2 and a last error;
//   value "refuse"        set fails with -3 and a CREDENTIALS_INVALID error
//                         naming the credential and the field;
//   name "refuse_seal"    seal fails with -3 and a CREDENTIALS_INVALID error.
// Every credential call clears the last error when it starts, as the real
// library does.
static char store[65536];
static size_t store_len;
static char names[64][129];
static int32_t next_id;

static void append(const char *line) {
  size_t k = strlen(line);
  if (store_len + k < sizeof store) {
    memcpy(store + store_len, line, k);
    store_len += k;
    store[store_len] = 0;
  }
}

static const char *name_of(int32_t id) { return id >= 1 && id <= next_id ? names[id - 1] : ""; }

EXPORT int32_t komira_credential_add(void *ctx, int32_t kind, const char *name, int32_t *out_id) {
  (void)ctx;
  clear_error();
  if (strcmp(name, "refuse_add") == 0) {
    snprintf(cred_error, sizeof cred_error, "CREDENTIALS_INVALID: add: the stand-in refuses kind %d", (int)kind);
    snprintf(err_code, sizeof err_code, "CREDENTIALS_INVALID");
    err_step = 2;
    return -3;
  }
  if (strcmp(name, "silent") == 0) return -3;
  if (strcmp(name, "null_arg") == 0) {
    snprintf(cred_error, sizeof cred_error, "out_id is NULL");
    return -2;
  }
  if (next_id >= 64) return -3;
  snprintf(names[next_id], sizeof names[next_id], "%s", name);
  *out_id = ++next_id;
  char line[200];
  snprintf(line, sizeof line, "add %d %s %d\n", (int)kind, name, (int)*out_id);
  append(line);
  return 0;
}

EXPORT int32_t komira_credential_set(void *ctx, int32_t id, int32_t field, const uint8_t *value, uint64_t value_len) {
  (void)ctx;
  clear_error();
  if (value_len == 6 && memcmp(value, "refuse", 6) == 0) {
    snprintf(cred_error, sizeof cred_error, "CREDENTIALS_INVALID: set credential=%s: the stand-in refuses field %d",
             name_of(id), (int)field);
    snprintf(err_code, sizeof err_code, "CREDENTIALS_INVALID");
    err_step = 2;
    return -3;
  }
  char line[64];
  snprintf(line, sizeof line, "set %d %d ", (int)id, (int)field);
  append(line);
  for (uint64_t i = 0; i < value_len; i++) {
    char hex[3];
    snprintf(hex, sizeof hex, "%02x", value[i]);
    append(hex);
  }
  append("\n");
  return 0;
}

EXPORT int32_t komira_credential_seal(void *ctx, int32_t id, int32_t scope) {
  (void)ctx;
  clear_error();
  if (strcmp(name_of(id), "refuse_seal") == 0) {
    snprintf(cred_error, sizeof cred_error, "CREDENTIALS_INVALID: seal credential=refuse_seal: the stand-in refuses it");
    snprintf(err_code, sizeof err_code, "CREDENTIALS_INVALID");
    err_step = 2;
    return -3;
  }
  char line[64];
  snprintf(line, sizeof line, "seal %d %d\n", (int)id, (int)scope);
  append(line);
  return 0;
}

// Not part of the ABI: the store's lines since the last call, by the two-call
// protocol; the store is emptied once they are written.
EXPORT int32_t komira_fake_store(uint8_t *b, uint64_t cap, uint64_t *n) {
  int32_t status = copy_out(store, store_len, b, cap, n);
  if (status == 0) {
    store_len = 0;
    store[0] = 0;
  }
  return status;
}

#endif

#if !defined(FAKE_ABI_1_0) && FAKE_VERSION % 1000 >= 3

// komira_sql_stream of ABI 1.3, answering by its SQL text (the whole text):
//   "rows"          a stream of the struct schema {n: int32, nullable} with
//                   two batches, [1, 2] and [3];
//   "no_rows"       that schema and no batch;
//   "schema_fails"  get_schema fails with EINVAL and the error
//                   "lower: the stand-in has no schema";
//   "next_fails"    the batch [1, 2], then get_next fails with EIO and the
//                   error "execute: the stand-in fails at batch 2";
//   "too_large"     -5 and the last error "komira_sql_stream: the stand-in
//                   takes no text this long";
//   "refuse <status> <step> [<code>]"
//                   <status> (a number) and the last error "stand-in refusal
//                   status <status> step <step> code <code>"; with ABI 1.7 the
//                   last error's step is the number <step> and its code the
//                   word <code>, empty when it is left out;
//   anything else   -3 and the last error "bind: the stand-in runs no query
//                   <text>", so a test sees the bytes that arrived.
// A text that starts "interrupted:" first raises SIGINT in the calling thread,
// as a Ctrl-C during a query does, and then answers as the rest of the text.
// A refusal leaves *out as it was given. komira_fake_stream_counts (not part
// of the ABI) writes the streams made and released, the schemas made and
// released and the batches made and released since the library was loaded,
// so a test sees that each is released exactly once.
#include <errno.h>
#include <signal.h>
#include <stdlib.h>

struct ArrowSchema {
  const char *format;
  const char *name;
  const char *metadata;
  int64_t flags;
  int64_t n_children;
  struct ArrowSchema **children;
  struct ArrowSchema *dictionary;
  void (*release)(struct ArrowSchema *);
  void *private_data;
};

struct ArrowArray {
  int64_t length;
  int64_t null_count;
  int64_t offset;
  int64_t n_buffers;
  int64_t n_children;
  const void **buffers;
  struct ArrowArray **children;
  struct ArrowArray *dictionary;
  void (*release)(struct ArrowArray *);
  void *private_data;
};

struct ArrowArrayStream {
  int (*get_schema)(struct ArrowArrayStream *, struct ArrowSchema *);
  int (*get_next)(struct ArrowArrayStream *, struct ArrowArray *);
  const char *(*get_last_error)(struct ArrowArrayStream *);
  void (*release)(struct ArrowArrayStream *);
  void *private_data;
};

enum { ROWS, NO_ROWS, SCHEMA_FAILS, NEXT_FAILS };

static int64_t counts[6];  // streams made, released; schemas made, released; batches made, released

// A child's memory belongs to its parent; releasing it only marks it.
static void release_child_schema(struct ArrowSchema *s) { s->release = NULL; }

static void release_child_array(struct ArrowArray *a) { a->release = NULL; }

typedef struct {
  struct ArrowSchema child;
  struct ArrowSchema *children[1];
} SchemaData;

static void release_schema(struct ArrowSchema *s) {
  SchemaData *d = s->private_data;
  if (d->child.release) d->child.release(&d->child);
  free(d);
  s->release = NULL;
  counts[3]++;
}

typedef struct {
  int32_t values[2];  // first, so 16-byte aligned like calloc's block
  struct ArrowArray child;
  struct ArrowArray *children[1];
  const void *top_buffers[1];
  const void *child_buffers[2];
} BatchData;

static void release_batch(struct ArrowArray *a) {
  BatchData *d = a->private_data;
  if (d->child.release) d->child.release(&d->child);
  free(d);
  a->release = NULL;
  counts[5]++;
}

typedef struct {
  int mode;
  int next;
  char error[96];
} StreamData;

static int stream_get_schema(struct ArrowArrayStream *s, struct ArrowSchema *out) {
  StreamData *p = s->private_data;
  if (p->mode == SCHEMA_FAILS) {
    snprintf(p->error, sizeof p->error, "lower: the stand-in has no schema");
    return EINVAL;
  }
  SchemaData *d = calloc(1, sizeof *d);
  if (!d) return ENOMEM;
  d->child = (struct ArrowSchema){.format = "i", .name = "n", .flags = 2, .release = release_child_schema};
  d->children[0] = &d->child;
  *out = (struct ArrowSchema){
      .format = "+s", .name = "", .n_children = 1, .children = d->children, .release = release_schema, .private_data = d};
  counts[2]++;
  return 0;
}

static int stream_get_next(struct ArrowArrayStream *s, struct ArrowArray *out) {
  StreamData *p = s->private_data;
  if (p->mode == NO_ROWS || p->next >= 2) {
    out->release = NULL;  // the end of the stream
    return 0;
  }
  if (p->mode == NEXT_FAILS && p->next == 1) {
    snprintf(p->error, sizeof p->error, "execute: the stand-in fails at batch 2");
    return EIO;
  }
  BatchData *d = calloc(1, sizeof *d);
  if (!d) return ENOMEM;
  int64_t n = p->next == 0 ? 2 : 1;
  if (p->next == 0) {
    d->values[0] = 1;
    d->values[1] = 2;
  } else {
    d->values[0] = 3;
  }
  d->child_buffers[1] = d->values;
  d->child = (struct ArrowArray){.length = n, .n_buffers = 2, .buffers = d->child_buffers, .release = release_child_array};
  d->children[0] = &d->child;
  *out = (struct ArrowArray){.length = n,
                             .n_buffers = 1,
                             .n_children = 1,
                             .buffers = d->top_buffers,
                             .children = d->children,
                             .release = release_batch,
                             .private_data = d};
  p->next++;
  counts[4]++;
  return 0;
}

static const char *stream_last_error(struct ArrowArrayStream *s) {
  StreamData *p = s->private_data;
  return p->error[0] ? p->error : NULL;
}

static void stream_release(struct ArrowArrayStream *s) {
  free(s->private_data);
  s->release = NULL;
  counts[1]++;
}

EXPORT int32_t komira_sql_stream(void *ctx, const char *sql, struct ArrowArrayStream *out) {
  (void)ctx;
  clear_error();
  if (!sql || !out) return -2;
  static const char interrupted[] = "interrupted:";
  if (strncmp(sql, interrupted, sizeof interrupted - 1) == 0) {
    raise(SIGINT);
    sql += sizeof interrupted - 1;
  }
  int m;
  if (strcmp(sql, "rows") == 0) {
    m = ROWS;
  } else if (strcmp(sql, "no_rows") == 0) {
    m = NO_ROWS;
  } else if (strcmp(sql, "schema_fails") == 0) {
    m = SCHEMA_FAILS;
  } else if (strcmp(sql, "next_fails") == 0) {
    m = NEXT_FAILS;
  } else if (strncmp(sql, "refuse ", 7) == 0) {
    int status = 0, step = 0;
    char code[64] = "";
    if (sscanf(sql + 7, "%d %d %63s", &status, &step, code) < 2) return -3;
    snprintf(cred_error, sizeof cred_error, "stand-in refusal status %d step %d code %s", status, step, code);
    snprintf(err_code, sizeof err_code, "%s", code);
    err_step = step;
    return status;
  } else if (strcmp(sql, "too_large") == 0) {
    snprintf(cred_error, sizeof cred_error, "komira_sql_stream: the stand-in takes no text this long");
    return -5;
  } else {
    snprintf(cred_error, sizeof cred_error, "bind: the stand-in runs no query %s", sql);
    snprintf(err_code, sizeof err_code, "SQL_BIND_ERROR");
    err_step = 2;
    return -3;
  }
  StreamData *p = calloc(1, sizeof *p);
  if (!p) return -3;
  p->mode = m;
  *out = (struct ArrowArrayStream){.get_schema = stream_get_schema,
                                   .get_next = stream_get_next,
                                   .get_last_error = stream_last_error,
                                   .release = stream_release,
                                   .private_data = p};
  counts[0]++;
  return 0;
}

EXPORT void komira_fake_stream_counts(int64_t *out) { memcpy(out, counts, sizeof counts); }

#endif

#if !defined(FAKE_ABI_1_0) && FAKE_VERSION % 1000 >= 7

// ABI 1.7: the last error's code, by the two-call protocol (empty when there
// is none), and its step number. A mode of komira_last_error's own (set by
// komira_register_parquet) has no code and no step.
EXPORT int32_t komira_last_error_code(void *ctx, uint8_t *b, uint64_t cap, uint64_t *n) {
  (void)ctx;
  return copy_out(err_code, strlen(err_code), b, cap, n);
}

EXPORT int32_t komira_last_error_step(void *ctx) {
  (void)ctx;
  return err_step;
}

#endif
