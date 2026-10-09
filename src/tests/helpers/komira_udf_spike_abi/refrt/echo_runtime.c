/*
 * komira-test/echo: the reference UDF runtime of the conformance suite,
 * written against komira_udf_runtime.h alone (design section 6.3). It
 * implements every entry of the table with fixed fixtures, chosen by the
 * spec's entry string, so the harness and the cases are proven without any
 * language behind them. It is also the template a new runtime copies: the
 * move of every input on entry, the release of what it moved, the error
 * strings it owns, the cancel flag and deadline it polls.
 *
 * It reports udf_class MANAGED: it stands where a managed runtime's
 * interpreter would, and has none, so of the two hosting values it reports
 * EMBEDDED (it needs nothing from the process that loads it).
 *
 * Built twice (BUCK). With KOMIRA_UDF_ECHO_BROKEN defined it is
 * komira-test/echo-broken, the same code with seven planted defects the
 * suite must catch (each marked BROKEN below):
 *   1. it does not release `args` when a fixture raises (a leak);
 *   2. `fahrenheit` writes int64 values into its float64 result;
 *   3. it never reads the cancel flag;
 *   4. agg_merge overwrites a group's state instead of adding to it;
 *   5. it ignores every input array's offset;
 *   6. `double` adds an instance-local call counter to every value;
 *   7. a ROW read outside the read set that the fixture catches is not
 *      reported: call_batch returns OK.
 *
 * Every symbol but ECHO_INIT is static, so both builds link into one
 * process (the one-definition gate links every C library whole).
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "komira_udf_runtime.h"

#ifndef ECHO_INIT
#error "ECHO_INIT names the init function this build defines"
#endif

#ifdef KOMIRA_UDF_ECHO_BROKEN
#define BROKEN 1
#define ECHO_ID "komira-test/echo-broken"
#else
#define BROKEN 0
#define ECHO_ID "komira-test/echo"
#endif

#define FMT_I64 'l'
#define SLOW_ROW_NS 10000000 /* slow_loop: 10 ms of the host's clock per row */
#define FMT_F64 'g'

/* ---- fixtures ------------------------------------------------------------ */

enum fixture_id {
  F_DOUBLE = 1,
  F_DOUBLE_STRICT,
  F_FAHRENHEIT,
  F_IDENTITY,
  F_SHORT_BY_ONE,
  F_BAD_LAYOUT,
  F_NULL_OUT,
  F_CONST7,
  F_RAISE_ON_ROW_3,
  F_SLOW_LOOP,
  F_SUM,
  F_RUNNING_SUM,
  F_GROUP_MAX,
  F_EMPTY_TABLE,
  F_PICK,
  F_PICK_CAUGHT,
  F_OUT_SET_ON_ERROR,
  F_OK_WITHOUT_OUTPUT,
  F_DEVICE_NOT_CPU,
  F_NULL_COUNT_LIES,
  F_ARGS_KEPT,
  F_YIELD_TWO_THEN_RAISE
};

/* args: one format per argument ('*' for ROW: any number of int64 fields,
 * bound by name at load). result: one format for a column; a table is 't'
 * then one format per column. state: "" when none. */
struct fixture {
  const char* entry;
  enum fixture_id id;
  uint32_t shape;
  const char* args;
  const char* result;
  const char* state;
};

static const struct fixture FIXTURES[] = {
    {"double", F_DOUBLE, KOMIRA_UDF_SHAPE_SCALAR, "l", "l", ""},
    {"double_strict", F_DOUBLE_STRICT, KOMIRA_UDF_SHAPE_SCALAR, "l", "l", ""},
    {"fahrenheit", F_FAHRENHEIT, KOMIRA_UDF_SHAPE_MAP_BATCHES_COLUMN, "g", "g", ""},
    {"identity", F_IDENTITY, KOMIRA_UDF_SHAPE_MAP_BATCHES_COLUMN, "l", "l", ""},
    {"short_by_one", F_SHORT_BY_ONE, KOMIRA_UDF_SHAPE_MAP_BATCHES_COLUMN, "l", "l", ""},
    {"bad_layout", F_BAD_LAYOUT, KOMIRA_UDF_SHAPE_SCALAR, "l", "l", ""},
    {"null_out", F_NULL_OUT, KOMIRA_UDF_SHAPE_SCALAR, "l", "l", ""},
    {"const7", F_CONST7, KOMIRA_UDF_SHAPE_SCALAR, "", "l", ""},
    {"raise_on_row_3", F_RAISE_ON_ROW_3, KOMIRA_UDF_SHAPE_SCALAR, "l", "l", ""},
    {"slow_loop", F_SLOW_LOOP, KOMIRA_UDF_SHAPE_SCALAR, "l", "l", ""},
    {"sum", F_SUM, KOMIRA_UDF_SHAPE_AGG_MERGEABLE, "l", "l", "l"},
    {"running_sum", F_RUNNING_SUM, KOMIRA_UDF_SHAPE_MAP_BATCHES_FRAME, "l", "tl", ""},
    {"group_max", F_GROUP_MAX, KOMIRA_UDF_SHAPE_AGG_PLAIN, "l", "l", ""},
    {"empty_table", F_EMPTY_TABLE, KOMIRA_UDF_SHAPE_STEP, "l", "t", ""},
    /* ROW: f(r) = r.a if r.flag else r.b, reading fields by name. */
    {"pick", F_PICK, KOMIRA_UDF_SHAPE_ROW, "*", "l", ""},
    /* The same, where user code catches the undeclared-field error and
     * returns 0 for the row. */
    {"pick_caught", F_PICK_CAUGHT, KOMIRA_UDF_SHAPE_ROW, "*", "l", ""},
    /* Runtime bugs the host must catch, each with the identity's values:
     * an error with `out` left set; OK with no output; an output on another
     * device; a null_count the validity bitmap contradicts; `args` read in
     * place and never moved or released. */
    {"out_set_on_error", F_OUT_SET_ON_ERROR, KOMIRA_UDF_SHAPE_SCALAR, "l", "l", ""},
    {"ok_without_output", F_OK_WITHOUT_OUTPUT, KOMIRA_UDF_SHAPE_SCALAR, "l", "l", ""},
    {"device_not_cpu", F_DEVICE_NOT_CPU, KOMIRA_UDF_SHAPE_SCALAR, "l", "l", ""},
    {"null_count_lies", F_NULL_COUNT_LIES, KOMIRA_UDF_SHAPE_SCALAR, "l", "l", ""},
    {"args_kept", F_ARGS_KEPT, KOMIRA_UDF_SHAPE_SCALAR, "l", "l", ""},
    /* A frame that yields its first two input batches unchanged, then
     * raises, leaving the rest of its input unread. */
    {"yield_two_then_raise", F_YIELD_TWO_THEN_RAISE, KOMIRA_UDF_SHAPE_MAP_BATCHES_FRAME, "l", "tl", ""},
};

#define N_FIXTURES (sizeof(FIXTURES) / sizeof(FIXTURES[0]))

/* ---- handles ------------------------------------------------------------- */

struct komira_udf_rt {
  const komira_udf_host* host;
};
#define ROW_FIELDS_MAX 8

/* A loaded UDF. For ROW, the read set's field names, copied at load from
 * spec->args: the only names a row view resolves. */
struct komira_udf_udf {
  const struct fixture* fx;
  int64_t n_fields;
  char* fields[ROW_FIELDS_MAX];
};
struct komira_udf_context {
  struct komira_udf_rt* rt;
  uint32_t slot;
};
struct komira_udf_instance {
  struct komira_udf_context* ctx;
  const struct komira_udf_udf* udf;
  const struct fixture* fx;
  int64_t calls; /* BROKEN (6) reads it */
};
struct komira_udf_groups {
  int64_t* st;
  uint32_t n;
  uint32_t cap;
};
struct komira_udf_frame {
  struct komira_udf_instance* inst;
  struct ArrowDeviceArrayStream in;
  int done;
  int64_t running; /* running_sum */
  int64_t group;   /* group_max: current ordinal, -1 before the first row */
  int64_t max;
};

/* ---- errors -------------------------------------------------------------- */

static void free_error(komira_udf_error* e) {
  free((void*)e->message);
  free((void*)e->user_trace);
  e->message = NULL;
  e->user_trace = NULL;
  e->release = NULL;
}

static char* dup(const char* s) {
  size_t n = strlen(s) + 1;
  char* d = malloc(n);
  if (d) memcpy(d, s, n);
  return d;
}

static int32_t fail(komira_udf_error* e, int32_t code, const char* msg, int64_t row) {
  if (e == NULL || e->struct_size < sizeof(komira_udf_error)) return code;
  e->code = code;
  e->message = dup(msg);
  e->user_trace = code == KOMIRA_UDF_ERR_RAISED ? dup("echo_runtime.c: the fixture raised") : NULL;
  e->row = row;
  e->group = -1;
  e->release = free_error;
  return code;
}

/* ---- reading inputs ------------------------------------------------------ */

static int64_t off_of(const struct ArrowArray* a) { return BROKEN ? 0 : a->offset; } /* BROKEN (5) */

static int is_valid(const struct ArrowArray* a, int64_t r) {
  const uint8_t* v = (const uint8_t*)a->buffers[0];
  int64_t at = off_of(a) + r;
  return v == NULL || ((v[at >> 3] >> (at & 7)) & 1);
}

static int64_t i64_at(const struct ArrowArray* a, int64_t r) {
  return ((const int64_t*)a->buffers[1])[off_of(a) + r];
}

static double f64_at(const struct ArrowArray* a, int64_t r) {
  return ((const double*)a->buffers[1])[off_of(a) + r];
}

static int32_t i32_at(const struct ArrowArray* a, int64_t r) {
  return ((const int32_t*)a->buffers[1])[off_of(a) + r];
}

static void release_array(struct ArrowArray* a) {
  if (a->release != NULL) a->release(a);
}

static int cancelled(const komira_udf_call* c) {
  if (BROKEN) return 0; /* BROKEN (3) */
  return c != NULL && c->cancel != NULL && __atomic_load_n(c->cancel, __ATOMIC_ACQUIRE) != 0;
}

static int past_deadline(const komira_udf_rt* rt, const komira_udf_call* c) {
  return c != NULL && c->deadline_ns != 0 && rt->host->now_ns(rt->host->host_data) > c->deadline_ns;
}

/* ---- building outputs ---------------------------------------------------- */

/* One malloc block per primitive array: its two-entry buffer list, the
 * validity bitmap, the values. The release frees the block. */
struct col_block {
  const void* bufs[2];
};

static void release_col(struct ArrowArray* a) {
  free(a->private_data);
  a->release = NULL;
}

static void set_cpu(struct ArrowDeviceArray* d) {
  d->device_id = -1;
  d->device_type = ARROW_DEVICE_CPU;
  d->sync_event = NULL;
  d->reserved[0] = d->reserved[1] = d->reserved[2] = 0;
}

/* A primitive array of `n` rows of 8-byte values, every row valid; the
 * caller writes *data and clears validity bits for nulls. */
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

static void set_null(struct ArrowArray* a, uint8_t* v, int64_t r) {
  v[r >> 3] &= (uint8_t)~(1u << (r & 7));
  a->null_count++;
}

static void release_struct(struct ArrowArray* a) {
  for (int64_t i = 0; i < a->n_children; i++) {
    release_array(a->children[i]);
    free(a->children[i]);
  }
  free(a->private_data);
  a->release = NULL;
}

/* A struct array of `n` rows whose `k` children the caller fills. */
static int make_struct(struct ArrowArray* a, int64_t n, int64_t k) {
  size_t bytes = sizeof(void*) + (size_t)k * sizeof(struct ArrowArray*);
  void** b = calloc(1, bytes);
  if (b == NULL) return 0;
  struct ArrowArray** kids = (struct ArrowArray**)(b + 1);
  for (int64_t i = 0; i < k; i++) {
    kids[i] = calloc(1, sizeof(struct ArrowArray));
  }
  a->length = n;
  a->null_count = 0;
  a->offset = 0;
  a->n_buffers = 1;
  a->n_children = k;
  a->buffers = (const void**)b; /* b[0] == NULL: no validity */
  a->children = k > 0 ? kids : NULL;
  a->dictionary = NULL;
  a->release = release_struct;
  a->private_data = b;
  return 1;
}

/* ---- validate / load ----------------------------------------------------- */

static const struct fixture* find(const char* entry) {
  if (entry == NULL) return NULL;
  for (size_t i = 0; i < N_FIXTURES; i++)
    if (strcmp(FIXTURES[i].entry, entry) == 0) return &FIXTURES[i];
  return NULL;
}

static int leaf_is(const struct ArrowSchema* s, char f) {
  return s != NULL && s->format != NULL && s->format[0] == f && s->format[1] == 0 && s->n_children == 0;
}

static int struct_is(const struct ArrowSchema* s, const char* fmts) {
  if (s == NULL || s->format == NULL || strcmp(s->format, "+s") != 0) return 0;
  if (s->n_children != (int64_t)strlen(fmts)) return 0;
  for (int64_t i = 0; i < s->n_children; i++)
    if (!leaf_is(s->children[i], fmts[i])) return 0;
  return 1;
}

/* A ROW read set: one to ROW_FIELDS_MAX int64 fields, each named, no name
 * twice. */
static int row_args_ok(const struct ArrowSchema* s) {
  if (s == NULL || s->format == NULL || strcmp(s->format, "+s") != 0) return 0;
  if (s->n_children < 1 || s->n_children > ROW_FIELDS_MAX) return 0;
  for (int64_t i = 0; i < s->n_children; i++) {
    const struct ArrowSchema* c = s->children[i];
    if (!leaf_is(c, FMT_I64) || c->name == NULL || c->name[0] == 0) return 0;
    for (int64_t j = 0; j < i; j++)
      if (strcmp(s->children[j]->name, c->name) == 0) return 0;
  }
  return 1;
}

static int32_t check_spec(const komira_udf_spec* s, komira_udf_error* e, const struct fixture** out) {
  if (s == NULL || s->struct_size < sizeof(komira_udf_spec))
    return fail(e, KOMIRA_UDF_ERR_ABI, "spec struct_size is below this runtime's", -1);
  const struct fixture* fx = find(s->entry);
  if (fx == NULL) return fail(e, KOMIRA_UDF_ERR_DESCRIPTOR, "no fixture has this entry", -1);
  if (s->form < KOMIRA_UDF_FORM_PACKAGE || s->form > KOMIRA_UDF_FORM_VALUE)
    return fail(e, KOMIRA_UDF_ERR_DESCRIPTOR, "code form is not PACKAGE, BUNDLE or VALUE", -1);
  if (s->descriptor_version > 0)
    return fail(e, KOMIRA_UDF_ERR_DESCRIPTOR, "descriptor_version is newer than 0, the newest read here", -1);
  if (s->descriptor_len != 0)
    return fail(e, KOMIRA_UDF_ERR_DESCRIPTOR, "descriptor version 0 is empty; these bytes are not canonical", -1);
  if ((uint32_t)s->shape != fx->shape)
    return fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "the fixture does not have this shape", -1);
  int result_ok = fx->result[0] == 't' ? struct_is(s->result, fx->result + 1) : leaf_is(s->result, fx->result[0]);
  int state_ok = fx->state[0] == 0 ? s->state == NULL : leaf_is(s->state, fx->state[0]);
  int args_ok = fx->args[0] == '*' ? row_args_ok(s->args) : struct_is(s->args, fx->args);
  if (!args_ok || !result_ok || !state_ok)
    return fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "the declared types are not the fixture's signature", -1);
  *out = fx;
  return KOMIRA_UDF_OK;
}

static int32_t echo_describe(komira_udf_rt* rt, komira_udf_capabilities* c) {
  (void)rt;
  if (c == NULL || c->struct_size < sizeof(komira_udf_capabilities)) return KOMIRA_UDF_ERR_ABI;
  c->runtime_id = ECHO_ID;
  c->runtime_abi = "";
  c->max_descriptor_version = 0;
  c->shapes = KOMIRA_UDF_SHAPE_SCALAR | KOMIRA_UDF_SHAPE_ROW | KOMIRA_UDF_SHAPE_MAP_BATCHES_COLUMN |
              KOMIRA_UDF_SHAPE_MAP_BATCHES_FRAME | KOMIRA_UDF_SHAPE_AGG_PLAIN | KOMIRA_UDF_SHAPE_AGG_MERGEABLE |
              KOMIRA_UDF_SHAPE_STEP;
  c->threading = KOMIRA_UDF_THREAD_SAFE;
  c->thread_affine = 0;
  c->transports = KOMIRA_UDF_TRANSPORT_IN_PROCESS;
  c->hosting = KOMIRA_UDF_HOSTING_EMBEDDED;
  c->devices = KOMIRA_UDF_DEVICE_CPU;
  c->features = KOMIRA_UDF_FEATURE_MEMORY_REPORT;
  c->udf_class = KOMIRA_UDF_CLASS_MANAGED;
  return KOMIRA_UDF_OK;
}

static int32_t echo_validate(komira_udf_rt* rt, const komira_udf_spec* s, komira_udf_error* e) {
  (void)rt;
  const struct fixture* fx = NULL;
  return check_spec(s, e, &fx);
}

static int32_t echo_load(komira_udf_rt* rt, const komira_udf_spec* s, komira_udf_udf** out,
                         komira_udf_error* e) {
  (void)rt;
  const struct fixture* fx = NULL;
  int32_t rc = check_spec(s, e, &fx);
  if (rc != KOMIRA_UDF_OK) return rc;
  komira_udf_udf* u = calloc(1, sizeof(*u));
  if (u == NULL) return fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "load: out of memory", -1);
  u->fx = fx;
  if (fx->shape == KOMIRA_UDF_SHAPE_ROW) {
    for (int64_t i = 0; i < s->args->n_children; i++) {
      u->fields[i] = dup(s->args->children[i]->name);
      u->n_fields = i + 1;
      if (u->fields[i] == NULL) break;
    }
  }
  *out = u;
  return KOMIRA_UDF_OK;
}

static void echo_unload(komira_udf_udf* u) {
  for (int64_t i = 0; i < u->n_fields; i++) free(u->fields[i]);
  free(u);
}

static int32_t echo_open_context(komira_udf_rt* rt, uint32_t slot, komira_udf_context** out,
                                 komira_udf_error* e) {
  komira_udf_context* c = malloc(sizeof(*c));
  if (c == NULL) return fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "open_context: out of memory", -1);
  c->rt = rt;
  c->slot = slot;
  *out = c;
  return KOMIRA_UDF_OK;
}

static void echo_close_context(komira_udf_context* c) { free(c); }

static int32_t echo_open_instance(komira_udf_context* c, komira_udf_udf* u, komira_udf_instance** out,
                                  komira_udf_error* e) {
  komira_udf_instance* i = malloc(sizeof(*i));
  if (i == NULL) return fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "open_instance: out of memory", -1);
  i->ctx = c;
  i->udf = u;
  i->fx = u->fx;
  i->calls = 0;
  *out = i;
  return KOMIRA_UDF_OK;
}

static void echo_close_instance(komira_udf_instance* i) { free(i); }

static int64_t echo_memory_report(komira_udf_context* c) {
  (void)c;
  return 0;
}

static void echo_shutdown(komira_udf_rt* rt) { free(rt); }

/* ---- call_batch ---------------------------------------------------------- */

static int32_t start_call(const komira_udf_rt* rt, const komira_udf_call* c, komira_udf_error* e) {
  if (c == NULL || c->struct_size < sizeof(komira_udf_call))
    return fail(e, KOMIRA_UDF_ERR_ABI, "call struct_size is below this runtime's", -1);
  if (cancelled(c)) return fail(e, KOMIRA_UDF_ERR_CANCELLED, "cancelled before the batch", -1);
  if (past_deadline(rt, c)) return fail(e, KOMIRA_UDF_ERR_DEADLINE, "the deadline passed before the batch", -1);
  return KOMIRA_UDF_OK;
}

/* ---- ROW: a row view over the read set ---------------------------------- */

/* One row's view: reads a field by name from the argument struct's children,
 * which are the read set in order. A name outside the read set records the
 * violation (the first one) and reads as 0; call_batch checks the record
 * before it returns, so user code that catches the error still fails the
 * batch. */
struct row_view {
  const struct komira_udf_udf* udf;
  const struct ArrowArray* args;
  int64_t row;
  const char* violation; /* the first undeclared name read, or NULL */
  int64_t violation_row;
};

static int64_t row_get(struct row_view* v, const char* name) {
  for (int64_t i = 0; i < v->udf->n_fields; i++)
    if (strcmp(v->udf->fields[i], name) == 0) return i64_at(v->args->children[i], v->row);
  if (v->violation == NULL) {
    v->violation = name;
    v->violation_row = v->row;
  }
  return 0;
}

static int32_t row_violation(const struct row_view* v, komira_udf_error* e) {
  char msg[256];
  size_t at = (size_t)snprintf(msg, sizeof(msg), "field '%s' is not in the read set {", v->violation);
  for (int64_t i = 0; i < v->udf->n_fields && at < sizeof(msg); i++)
    at += (size_t)snprintf(msg + at, sizeof(msg) - at, "%s%s", i ? ", " : "", v->udf->fields[i]);
  if (at < sizeof(msg)) snprintf(msg + at, sizeof(msg) - at, "}; add it to columns=[...]");
  return fail(e, KOMIRA_UDF_ERR_FIELD_NOT_DECLARED, msg, v->violation_row);
}

/* pick and pick_caught over every row: `o` gets one int64 per row. */
static int32_t row_call(komira_udf_instance* inst, const struct ArrowArray* in, struct ArrowArray* o,
                        komira_udf_error* e) {
  uint8_t* valid;
  void* d;
  if (!make_col(o, in->length, &valid, &d))
    return fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "call_batch: out of memory", -1);
  struct row_view v = {inst->udf, in, 0, NULL, -1};
  for (int64_t r = 0; r < in->length; r++) {
    v.row = r;
    const char* violation_before = v.violation;
    int64_t y = row_get(&v, "flag") ? row_get(&v, "a") : row_get(&v, "b");
    if (v.violation != violation_before && inst->fx->id == F_PICK) {
      /* The fixture lets the error propagate: the batch fails here. */
      release_array(o);
      return row_violation(&v, e);
    }
    ((int64_t*)d)[r] = y; /* pick_caught: the caught error leaves 0 */
  }
  if (v.violation != NULL && !BROKEN) { /* BROKEN (7) */
    release_array(o);
    return row_violation(&v, e);
  }
  return KOMIRA_UDF_OK;
}

/* The column fixtures. `in` is the argument struct; `o` the result. */
static int32_t scalar(komira_udf_instance* inst, const komira_udf_call* call, const struct ArrowArray* in,
                      struct ArrowArray* o, komira_udf_error* e) {
  const struct fixture* fx = inst->fx;
  const komira_udf_rt* rt = inst->ctx->rt;
  int64_t n = in->length;
  const struct ArrowArray* x = in->n_children > 0 ? in->children[0] : NULL;
  int64_t rows = (fx->id == F_SHORT_BY_ONE && n > 0) ? n - 1 : n;
  if (fx->id == F_DOUBLE_STRICT)
    for (int64_t r = 0; r < n; r++)
      if (!is_valid(x, r)) return fail(e, KOMIRA_UDF_ERR_RAISED, "double_strict: a null argument", r);
  if (fx->id == F_RAISE_ON_ROW_3 && n > 3) return fail(e, KOMIRA_UDF_ERR_RAISED, "raise_on_row_3: row 3", 3);
  uint8_t* v;
  void* d;
  if (!make_col(o, rows, &v, &d)) return fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "call_batch: out of memory", -1);
  int64_t* di = (int64_t*)d;
  for (int64_t r = 0; r < rows; r++) {
    if (fx->id == F_SLOW_LOOP) {
      if (cancelled(call)) {
        release_array(o);
        return fail(e, KOMIRA_UDF_ERR_CANCELLED, "slow_loop: cancelled", r);
      }
      if (past_deadline(rt, call)) {
        release_array(o);
        return fail(e, KOMIRA_UDF_ERR_DEADLINE, "slow_loop: deadline passed", r);
      }
      /* Each row takes SLOW_ROW_NS of the host's clock, so a cancel the
       * host sets during the call lands between rows. */
      int64_t until = rt->host->now_ns(rt->host->host_data) + SLOW_ROW_NS;
      while (rt->host->now_ns(rt->host->host_data) < until) {
      }
    }
    di[r] = 0;
    if (fx->id == F_CONST7) {
      di[r] = 7;
      continue;
    }
    if (fx->id == F_NULL_OUT || !is_valid(x, r)) {
      set_null(o, v, r);
      continue;
    }
    switch (fx->id) {
      case F_FAHRENHEIT: {
        double y = f64_at(x, r) * 1.8 + 32.0;
        if (BROKEN)
          di[r] = (int64_t)y; /* BROKEN (2) */
        else
          ((double*)d)[r] = y;
        break;
      }
      case F_DOUBLE:
        di[r] = 2 * i64_at(x, r) + (BROKEN ? inst->calls : 0); /* BROKEN (6) */
        break;
      case F_DOUBLE_STRICT:
        di[r] = 2 * i64_at(x, r);
        break;
      default: /* identity, short_by_one, bad_layout, raise_on_row_3 below row 4, slow_loop */
        di[r] = i64_at(x, r);
    }
  }
  if (fx->id == F_BAD_LAYOUT) o->n_buffers = 1;
  inst->calls++;
  return KOMIRA_UDF_OK;
}

static int32_t echo_call_batch(komira_udf_instance* inst, const komira_udf_call* call, struct ArrowDeviceArray* args,
                               struct ArrowDeviceArray* out, komira_udf_error* e) {
  if (inst->fx->id == F_ARGS_KEPT) { /* the bug: args read in place, never moved */
    out->array.release = NULL;
    int32_t kept = scalar(inst, call, &args->array, &out->array, e);
    if (kept == KOMIRA_UDF_OK) set_cpu(out);
    return kept;
  }
  struct ArrowDeviceArray mine = *args; /* moved in, whatever the status */
  args->array.release = NULL;
  out->array.release = NULL;
  int32_t rc = start_call(inst->ctx->rt, call, e);
  if (rc == KOMIRA_UDF_OK && mine.device_type != ARROW_DEVICE_CPU)
    rc = fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "only CPU arrays are read here", -1);
  if (rc == KOMIRA_UDF_OK &&
      (inst->fx->shape & (KOMIRA_UDF_SHAPE_SCALAR | KOMIRA_UDF_SHAPE_ROW | KOMIRA_UDF_SHAPE_MAP_BATCHES_COLUMN)) == 0)
    rc = fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "call_batch on a fixture of another shape", -1);
  if (rc == KOMIRA_UDF_OK && inst->fx->shape == KOMIRA_UDF_SHAPE_ROW)
    rc = row_call(inst, &mine.array, &out->array, e);
  else if (rc == KOMIRA_UDF_OK)
    rc = scalar(inst, call, &mine.array, &out->array, e);
  if (rc == KOMIRA_UDF_OK) set_cpu(out);
  if (rc == KOMIRA_UDF_OK) {
    switch (inst->fx->id) { /* the runtime bugs of the fixtures above */
      case F_OUT_SET_ON_ERROR:
        rc = fail(e, KOMIRA_UDF_ERR_RAISED, "out_set_on_error: raised with out still set", -1);
        break;
      case F_OK_WITHOUT_OUTPUT:
        release_array(&out->array);
        break;
      case F_DEVICE_NOT_CPU:
        out->device_type = ARROW_DEVICE_CUDA;
        break;
      case F_NULL_COUNT_LIES:
        out->array.null_count += 1;
        break;
      default:
        break;
    }
  }
  if (!(BROKEN && rc == KOMIRA_UDF_ERR_RAISED)) release_array(&mine.array); /* BROKEN (1) */
  return rc;
}

/* ---- mergeable aggregate: sum ------------------------------------------ */

static int32_t echo_agg_open(komira_udf_instance* inst, komira_udf_groups** out, komira_udf_error* e) {
  if (inst->fx->id != F_SUM) return fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "agg_open on a fixture of another shape", -1);
  komira_udf_groups* g = calloc(1, sizeof(*g));
  if (g == NULL) return fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "agg_open: out of memory", -1);
  *out = g;
  return KOMIRA_UDF_OK;
}

static int grow(komira_udf_groups* g, uint32_t n) {
  if (n > g->cap) {
    uint32_t cap = g->cap ? g->cap : 16;
    while (cap < n) cap *= 2;
    int64_t* st = realloc(g->st, (size_t)cap * sizeof(int64_t));
    if (st == NULL) return 0;
    memset(st + g->cap, 0, (size_t)(cap - g->cap) * sizeof(int64_t));
    g->st = st;
    g->cap = cap;
  }
  if (n > g->n) g->n = n;
  return 1;
}

/* agg_update (`merge` 0: values are the argument struct's first child) and
 * agg_merge (`merge` 1: values are the state column). */
static int32_t fold(komira_udf_groups* g, const komira_udf_call* call, struct ArrowDeviceArray* values,
                    struct ArrowDeviceArray* gids, uint32_t n_groups, komira_udf_error* e, int merge) {
  struct ArrowDeviceArray v = *values; /* both moved in */
  values->array.release = NULL;
  struct ArrowDeviceArray ids = *gids;
  gids->array.release = NULL;
  int32_t rc = KOMIRA_UDF_OK;
  const struct ArrowArray* x = merge ? &v.array : (v.array.n_children > 0 ? v.array.children[0] : NULL);
  if (cancelled(call))
    rc = fail(e, KOMIRA_UDF_ERR_CANCELLED, "cancelled before the batch", -1);
  else if (x == NULL || ids.array.length != v.array.length)
    rc = fail(e, KOMIRA_UDF_ERR_INTERNAL, "group ids and values differ in length", -1);
  else if (!grow(g, n_groups))
    rc = fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "agg: out of memory", -1);
  for (int64_t r = 0; rc == KOMIRA_UDF_OK && r < v.array.length; r++) {
    int32_t gid = i32_at(&ids.array, r);
    if (gid < 0 || (uint32_t)gid >= n_groups) {
      rc = fail(e, KOMIRA_UDF_ERR_INTERNAL, "a group id is not below n_groups", r);
      break;
    }
    if (!is_valid(x, r)) continue;
    if (merge && BROKEN)
      g->st[gid] = i64_at(x, r); /* BROKEN (4) */
    else
      g->st[gid] += i64_at(x, r);
  }
  release_array(&v.array);
  release_array(&ids.array);
  return rc;
}

static int32_t echo_agg_update(komira_udf_groups* g, const komira_udf_call* c, struct ArrowDeviceArray* args,
                               struct ArrowDeviceArray* gids, uint32_t n, komira_udf_error* e) {
  return fold(g, c, args, gids, n, e, 0);
}

static int32_t echo_agg_merge(komira_udf_groups* g, const komira_udf_call* c, struct ArrowDeviceArray* states,
                              struct ArrowDeviceArray* gids, uint32_t n, komira_udf_error* e) {
  return fold(g, c, states, gids, n, e, 1);
}

/* Emit the first `n` groups' sums and forget them: the groups after them
 * move down by `n` (the design does not say whether ids shift; here they do). */
static int32_t emit(komira_udf_groups* g, uint32_t n, struct ArrowDeviceArray* out, komira_udf_error* e) {
  out->array.release = NULL;
  if (n > g->n) return fail(e, KOMIRA_UDF_ERR_INTERNAL, "emit_first_n is above the group count", -1);
  uint8_t* v;
  void* d;
  if (!make_col(&out->array, n, &v, &d)) return fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "agg: out of memory", -1);
  if (n > 0) memcpy(d, g->st, (size_t)n * sizeof(int64_t));
  memmove(g->st, g->st + n, (size_t)(g->n - n) * sizeof(int64_t));
  g->n -= n;
  set_cpu(out);
  return KOMIRA_UDF_OK;
}

static int32_t echo_agg_state(komira_udf_groups* g, uint32_t n, struct ArrowDeviceArray* out, komira_udf_error* e) {
  return emit(g, n, out, e);
}

static int32_t echo_agg_finish(komira_udf_groups* g, uint32_t n, struct ArrowDeviceArray* out, komira_udf_error* e) {
  return emit(g, n, out, e);
}

static void echo_agg_close(komira_udf_groups* g) {
  free(g->st);
  free(g);
}

/* ---- frames: running_sum, group_max (plain aggregate), empty_table (step) */

static int32_t echo_frame_open(komira_udf_instance* inst, const komira_udf_call* call,
                               struct ArrowDeviceArrayStream* in, komira_udf_frame** out, komira_udf_error* e) {
  struct ArrowDeviceArrayStream mine = *in; /* moved in, whatever the status */
  in->release = NULL;
  int32_t rc = KOMIRA_UDF_OK;
  if ((inst->fx->shape & (KOMIRA_UDF_SHAPE_MAP_BATCHES_FRAME | KOMIRA_UDF_SHAPE_AGG_PLAIN | KOMIRA_UDF_SHAPE_STEP)) == 0)
    rc = fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "frame_open on a fixture of another shape", -1);
  if (rc == KOMIRA_UDF_OK) rc = start_call(inst->ctx->rt, call, e);
  komira_udf_frame* fr = NULL;
  if (rc == KOMIRA_UDF_OK && (fr = calloc(1, sizeof(*fr))) == NULL)
    rc = fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "frame_open: out of memory", -1);
  if (rc != KOMIRA_UDF_OK) {
    if (mine.release != NULL) mine.release(&mine);
    return rc;
  }
  fr->inst = inst;
  fr->in = mine;
  fr->group = -1;
  *out = fr;
  return KOMIRA_UDF_OK;
}

/* The next input batch into *b; 0 with b->array.release == NULL at the end. */
static int pull(komira_udf_frame* fr, struct ArrowDeviceArray* b) {
  memset(b, 0, sizeof(*b));
  return fr->in.get_next(&fr->in, b);
}

static int32_t next_running_sum(komira_udf_frame* fr, struct ArrowDeviceArray* out, komira_udf_error* e) {
  struct ArrowDeviceArray b;
  if (pull(fr, &b) != 0) return fail(e, KOMIRA_UDF_ERR_INTERNAL, "the input stream failed", -1);
  if (b.array.release == NULL) {
    fr->done = 1;
    return KOMIRA_UDF_OK;
  }
  int64_t n = b.array.length;
  const struct ArrowArray* x = b.array.n_children > 0 ? b.array.children[0] : NULL;
  uint8_t* v;
  void* d;
  if (x == NULL || !make_struct(&out->array, n, 1) || !make_col(out->array.children[0], n, &v, &d)) {
    release_array(&out->array);
    release_array(&b.array);
    return fail(e, KOMIRA_UDF_ERR_INTERNAL, "running_sum: no input column, or out of memory", -1);
  }
  for (int64_t r = 0; r < n; r++) {
    if (!is_valid(x, r)) {
      ((int64_t*)d)[r] = 0;
      set_null(out->array.children[0], v, r);
      continue;
    }
    fr->running += i64_at(x, r);
    ((int64_t*)d)[r] = fr->running;
  }
  release_array(&b.array);
  set_cpu(out);
  return KOMIRA_UDF_OK;
}

/* Pulls until at least one group is complete (or the input ends), and
 * returns the completed groups' maxima, one row each, in ordinal order. */
static int32_t next_group_max(komira_udf_frame* fr, struct ArrowDeviceArray* out, komira_udf_error* e) {
  int64_t* done = NULL;
  int64_t k = 0, cap = 0;
  while (k == 0 && !fr->done) {
    struct ArrowDeviceArray b;
    if (pull(fr, &b) != 0) {
      free(done);
      return fail(e, KOMIRA_UDF_ERR_INTERNAL, "the input stream failed", -1);
    }
    int64_t n = b.array.release == NULL ? 0 : b.array.length;
    if (b.array.release == NULL) fr->done = 1;
    if (n > 0 && b.array.n_children < 2) {
      release_array(&b.array);
      free(done);
      return fail(e, KOMIRA_UDF_ERR_INTERNAL, "group_max: a batch without its group and value columns", -1);
    }
    for (int64_t r = 0; r <= n; r++) {
      int at_end = r == n;
      if (at_end && !fr->done) break;
      int64_t gid = at_end ? -1 : i64_at(b.array.children[0], r);
      if (!at_end && gid == fr->group) {
        int64_t val = i64_at(b.array.children[1], r);
        if (val > fr->max) fr->max = val;
        continue;
      }
      if (fr->group >= 0) {
        if (k == cap) {
          cap = cap ? cap * 2 : 16;
          int64_t* grown = realloc(done, (size_t)cap * sizeof(int64_t));
          if (grown == NULL) {
            free(done);
            release_array(&b.array);
            return fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "group_max: out of memory", -1);
          }
          done = grown;
        }
        done[k++] = fr->max;
      }
      fr->group = gid;
      if (!at_end) fr->max = i64_at(b.array.children[1], r);
    }
    release_array(&b.array);
  }
  if (k == 0) {
    free(done);
    return KOMIRA_UDF_OK; /* the end */
  }
  uint8_t* v;
  void* d;
  if (!make_col(&out->array, k, &v, &d)) {
    free(done);
    return fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "group_max: out of memory", -1);
  }
  memcpy(d, done, (size_t)k * sizeof(int64_t));
  free(done);
  set_cpu(out);
  return KOMIRA_UDF_OK;
}

/* A step: one length-1 batch of literal arguments in; a table with no
 * columns and as many rows as the first literal says, out. */
static int32_t next_step(komira_udf_frame* fr, struct ArrowDeviceArray* out, komira_udf_error* e) {
  struct ArrowDeviceArray b;
  if (pull(fr, &b) != 0) return fail(e, KOMIRA_UDF_ERR_INTERNAL, "the input stream failed", -1);
  fr->done = 1;
  if (b.array.release == NULL) return fail(e, KOMIRA_UDF_ERR_INTERNAL, "a step got no literal batch", -1);
  int64_t rows = b.array.length == 1 && b.array.n_children == 1 ? i64_at(b.array.children[0], 0) : -1;
  release_array(&b.array);
  if (rows < 0) return fail(e, KOMIRA_UDF_ERR_INTERNAL, "a step's literal batch is not one int64 row", -1);
  if (!make_struct(&out->array, rows, 0)) return fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "step: out of memory", -1);
  set_cpu(out);
  return KOMIRA_UDF_OK;
}

/* yield_two_then_raise: the input batch is the output (a runtime may return
 * its input buffers), twice; then an error, with the rest unread. */
static int32_t next_yield_two(komira_udf_frame* fr, struct ArrowDeviceArray* out, komira_udf_error* e) {
  if (fr->running == 2) {
    fr->done = 1;
    return fail(e, KOMIRA_UDF_ERR_RAISED, "yield_two_then_raise: raised after two outputs", -1);
  }
  if (pull(fr, out) != 0) return fail(e, KOMIRA_UDF_ERR_INTERNAL, "the input stream failed", -1);
  if (out->array.release == NULL) fr->done = 1;
  fr->running++;
  set_cpu(out);
  return KOMIRA_UDF_OK;
}

static int32_t echo_frame_next(komira_udf_frame* fr, const komira_udf_call* call, struct ArrowDeviceArray* out,
                               komira_udf_error* e) {
  out->array.release = NULL;
  if (cancelled(call)) return fail(e, KOMIRA_UDF_ERR_CANCELLED, "cancelled between batches", -1);
  if (fr->done) return KOMIRA_UDF_OK; /* the end: out->array.release stays NULL */
  switch (fr->inst->fx->id) {
    case F_RUNNING_SUM:
      return next_running_sum(fr, out, e);
    case F_GROUP_MAX:
      return next_group_max(fr, out, e);
    case F_YIELD_TWO_THEN_RAISE:
      return next_yield_two(fr, out, e);
    default:
      return next_step(fr, out, e);
  }
}

static void echo_frame_close(komira_udf_frame* fr) {
  if (fr->in.release != NULL) fr->in.release(&fr->in);
  free(fr);
}

static const komira_udf_runtime TABLE = {
    sizeof(komira_udf_runtime),
    KOMIRA_UDF_ABI_MAJOR,
    KOMIRA_UDF_ABI_MINOR,
    echo_describe,
    echo_validate,
    echo_load,
    echo_unload,
    echo_open_context,
    echo_close_context,
    echo_open_instance,
    echo_close_instance,
    echo_call_batch,
    echo_frame_open,
    echo_frame_next,
    echo_frame_close,
    echo_agg_open,
    echo_agg_update,
    echo_agg_merge,
    echo_agg_state,
    echo_agg_finish,
    echo_agg_close,
    echo_shutdown,
    echo_memory_report,
};

const komira_udf_runtime* ECHO_INIT(const komira_udf_host* host, komira_udf_rt** rt, komira_udf_error* e) {
  if (host == NULL || host->struct_size < sizeof(komira_udf_host) || host->abi_major != KOMIRA_UDF_ABI_MAJOR) {
    fail(e, KOMIRA_UDF_ERR_ABI, "this runtime speaks ABI major 1", -1);
    return NULL;
  }
  komira_udf_rt* r = malloc(sizeof(*r));
  if (r == NULL) {
    fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "init: out of memory", -1);
    return NULL;
  }
  r->host = host;
  *rt = r;
  return &TABLE;
}
