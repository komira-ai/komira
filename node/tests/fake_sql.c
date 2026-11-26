// A stand-in for libkomira of ABI 1.9 whose komira_sql_stream answers a few
// fixed queries, so the package's tests reach what the real engine never
// hands back: a stream of two batches, one of none, a batch that breaks the C
// Data Interface, a column of a format the package does not map, a get_next
// that fails, and refusals whose code and step the test chooses. Every other
// call the addon resolves does nothing, except komira_register_parquet, which
// refuses with the bind step and no code.
//
// The queries (exact text):
//   "SELECT rows"          a column n (int32, nullable): batches [1, 2] and [3]
//   "SELECT nothing"       the column n and no batch
//   "SELECT bad batch"     one batch whose column n has 1 buffer, not 2
//   "SELECT fixed list"    a column n of format "+w:2", one empty batch
//   "SELECT next fails"    get_next returns 5 with FAKE_NEXT_ERROR
//   "refuse <code> <step>" status -3, the query as the last error, `code`
//                          (`-` for none) and `step` as its code and step
//   anything else          status -3, FAKE_UNKNOWN_QUERY, no code, no step
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "arrow_c.h"

#define EXPORT __attribute__((visibility("default")))

#define FAKE_NEXT_ERROR "stand-in: the batch cannot be read"
#define FAKE_UNKNOWN_QUERY "parse: the stand-in answers no such query"

static int the_ctx;
static char last_error[512];
static char last_code[128];
static int32_t last_step;

static void set_error(const char *text, const char *code, int32_t step) {
  snprintf(last_error, sizeof last_error, "%s", text);
  snprintf(last_code, sizeof last_code, "%s", code);
  last_step = step;
}

// The two-call protocol over `text`.
static int32_t two_call(const char *text, uint8_t *b, uint64_t cap, uint64_t *n) {
  const uint64_t len = strlen(text);
  *n = len;
  if (len == 0) return 0;
  if (cap < len) return -4;
  memcpy(b, text, len);
  return 0;
}

EXPORT int32_t komira_abi_version(void) { return 1009; }
EXPORT void *komira_ctx_new(void) { return &the_ctx; }
EXPORT void komira_ctx_free(void *ctx) { (void)ctx; }
EXPORT int32_t komira_last_error(void *ctx, uint8_t *b, uint64_t cap, uint64_t *n) {
  (void)ctx;
  return two_call(last_error, b, cap, n);
}
EXPORT int32_t komira_last_error_code(void *ctx, uint8_t *b, uint64_t cap, uint64_t *n) {
  (void)ctx;
  return two_call(last_code, b, cap, n);
}
EXPORT int32_t komira_last_error_step(void *ctx) {
  (void)ctx;
  return last_step;
}
EXPORT int32_t komira_register_parquet(void *ctx, const char *name, const char *path) {
  (void)ctx; (void)name; (void)path;
  set_error("IO Error: the stand-in has no file", "", 2);
  return -3;
}
EXPORT int32_t komira_parquet_schema(void *ctx, const char *path, uint8_t *b, uint64_t cap, uint64_t *n) {
  (void)ctx; (void)path; (void)b; (void)cap;
  *n = 0;
  return 0;
}
EXPORT int32_t komira_plan_render(void *ctx, const uint8_t *p, uint64_t len, uint8_t *b, uint64_t cap, uint64_t *n) {
  (void)ctx; (void)p; (void)len; (void)b; (void)cap;
  *n = 0;
  return 0;
}

// ---- the streams --------------------------------------------------------------

typedef enum { ROWS, NOTHING, BAD_BATCH, FIXED_LIST, NEXT_FAILS } Kind;

// The stream's schema: a struct of the one column n.
typedef struct {
  struct ArrowSchema child;
  struct ArrowSchema *children[1];
} SchemaBox;

static void release_schema(struct ArrowSchema *s) {
  free(s->private_data);
  s->release = NULL;
}

static void release_child_schema(struct ArrowSchema *s) { s->release = NULL; }

// One batch: the column n of int32 values with no validity bitmap.
typedef struct {
  struct ArrowArray child;
  struct ArrowArray *children[1];
  const void *buffers[1];
  const void *child_buffers[2];
  int32_t values[2];
} BatchBox;

static void release_child_array(struct ArrowArray *a) { a->release = NULL; }

static void release_batch(struct ArrowArray *a) {
  BatchBox *b = a->private_data;
  if (b->child.release != NULL) b->child.release(&b->child);
  free(b);
  a->release = NULL;
}

// Fills `out` with a batch of `n` values (at most 2); its column has
// `child_buffers` buffers. Returns 12 (ENOMEM) when there is no memory.
static int batch(struct ArrowArray *out, const int32_t *values, int64_t n, int64_t child_buffers) {
  BatchBox *b = calloc(1, sizeof *b);
  if (b == NULL) return 12;
  if (n > 0) memcpy(b->values, values, (size_t)n * sizeof values[0]);
  b->child_buffers[1] = b->values;
  b->child.length = n;
  b->child.n_buffers = child_buffers;
  b->child.buffers = b->child_buffers;
  b->child.release = release_child_array;
  b->children[0] = &b->child;
  memset(out, 0, sizeof *out);
  out->length = n;
  out->n_buffers = 1;
  out->n_children = 1;
  out->buffers = b->buffers;
  out->children = b->children;
  out->release = release_batch;
  out->private_data = b;
  return 0;
}

typedef struct {
  Kind kind;
  int next;  // the batches handed out so far
} Producer;

static int get_schema(struct ArrowArrayStream *s, struct ArrowSchema *out) {
  const Producer *p = s->private_data;
  SchemaBox *box = calloc(1, sizeof *box);
  if (box == NULL) return 12;
  box->child.format = p->kind == FIXED_LIST ? "+w:2" : "i";
  box->child.name = "n";
  box->child.flags = ARROW_FLAG_NULLABLE;
  box->child.release = release_child_schema;
  box->children[0] = &box->child;
  memset(out, 0, sizeof *out);
  out->format = "+s";
  out->name = "";
  out->n_children = 1;
  out->children = box->children;
  out->release = release_schema;
  out->private_data = box;
  return 0;
}

static int get_next(struct ArrowArrayStream *s, struct ArrowArray *out) {
  Producer *p = s->private_data;
  static const int32_t first[] = {1, 2};
  static const int32_t second[] = {3};
  int at = p->next++;
  memset(out, 0, sizeof *out);
  switch (p->kind) {
    case ROWS:
      if (at == 0) return batch(out, first, 2, 2);
      if (at == 1) return batch(out, second, 1, 2);
      return 0;
    case BAD_BATCH:
      return at == 0 ? batch(out, first, 2, 1) : 0;
    case FIXED_LIST:
      return at == 0 ? batch(out, first, 0, 2) : 0;
    case NEXT_FAILS:
      return 5;
    case NOTHING:
      return 0;
  }
  return 0;
}

static const char *get_last_error(struct ArrowArrayStream *s) {
  const Producer *p = s->private_data;
  return p->kind == NEXT_FAILS ? FAKE_NEXT_ERROR : NULL;
}

static void release_stream(struct ArrowArrayStream *s) {
  free(s->private_data);
  s->release = NULL;
}

EXPORT int32_t komira_sql_stream(void *ctx, const char *sql, struct ArrowArrayStream *out) {
  (void)ctx;
  static const struct {
    const char *query;
    Kind kind;
  } answers[] = {
      {"SELECT rows", ROWS},           {"SELECT nothing", NOTHING},       {"SELECT bad batch", BAD_BATCH},
      {"SELECT fixed list", FIXED_LIST}, {"SELECT next fails", NEXT_FAILS},
  };
  set_error("", "", 0);
  for (size_t i = 0; i < sizeof answers / sizeof answers[0]; i++) {
    if (strcmp(sql, answers[i].query) != 0) continue;
    Producer *p = calloc(1, sizeof *p);
    if (p == NULL) return -3;
    p->kind = answers[i].kind;
    out->get_schema = get_schema;
    out->get_next = get_next;
    out->get_last_error = get_last_error;
    out->release = release_stream;
    out->private_data = p;
    return 0;
  }
  char code[64];
  int step = 0;
  if (sscanf(sql, "refuse %63s %d", code, &step) == 2) {
    set_error(sql, strcmp(code, "-") == 0 ? "" : code, step);
  } else {
    set_error(FAKE_UNKNOWN_QUERY, "", 0);
  }
  return -3;
}
