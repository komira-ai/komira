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
 * Memory accounting (design section 4.8): every output array, every
 * error's strings and every handle (runtime, UDF, context, instance, groups,
 * frame) are reserved through host->mem_reserve when built and returned
 * through host->mem_release when released or closed. So a host that never
 * releases an output or an error, or never closes a handle, leaves its
 * reservation count above zero, which the conformance runner's ledger
 * reports. A host that breaks a rule echo can see only after the call
 * returns (a release that leaves its slot set) is charged one byte that is
 * never returned, which the ledger reports too.
 *
 * One translation unit in four files: this one (fixtures, handles, errors,
 * inputs and outputs, validate and load, the table and the inits) includes
 * echo_calls.inc (call_batch), echo_frames.inc (aggregates and frames) and,
 * when ECHO_INIT_VARIANT is defined, echo_variants.inc. Every symbol but the
 * inits is static, so the builds link into one process (the one-definition
 * gate links every C library whole).
 *
 * Built four ways (BUCK). With KOMIRA_UDF_ECHO_BROKEN defined it is
 * komira-test/echo-broken, the same code with seven planted defects the
 * suite must catch (each marked BROKEN):
 *   1. it does not release `args` when a fixture raises (a leak);
 *   2. `fahrenheit` writes int64 values into its float64 result;
 *   3. it never reads the cancel flag;
 *   4. agg_merge overwrites a group's state instead of adding to it;
 *   5. it ignores every input array's offset;
 *   6. `double` adds an instance-local call counter to every value;
 *   7. a ROW read outside the read set that the fixture catches is not
 *      reported: call_batch returns OK.
 *
 * With ECHO_INIT_GLOBAL_LOCK defined, the build also defines that init:
 * the same runtime reporting global_lock 1 beside THREAD_SAFE, the test
 * setting of design section 6.3, which a host must refuse at init. With
 * ECHO_INIT_VARIANT defined, it defines one more init whose table and
 * describe answer break one rule of the contract, chosen when it runs
 * (echo_variants.inc).
 *
 * With ECHO_NATIVE defined it is a native UDF library (design section 1.2),
 * the C fixture library the native runtime loads: the same fixtures, with
 * describe reporting runtime_id "komira/native", udf_class NATIVE, hosting 0
 * and CONTEXT_PER_THREAD. With ECHO_INIT_AFFINE also defined, that init is
 * the same library reporting thread_affine 1, which the native runtime must
 * refuse to load.
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
#elif defined(ECHO_NATIVE)
#define BROKEN 0
#define ECHO_ID "komira/native"
#else
#define BROKEN 0
#define ECHO_ID "komira-test/echo"
#endif

#define FMT_I64 'l'
#define SLOW_ROW_NS 100000000 /* slow_loop: at most 100 ms of the host's clock per row */
#define PAD_VALUE 0x5EAD5EAD  /* the rows before a sliced output's offset */

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
  F_YIELD_TWO_THEN_RAISE,
  F_ADD_STRICT,
  F_LONG_BY_ONE,
  F_SUM_ARGS_KEPT,
  F_ENDLESS,
  F_NULL_ON_ZERO,
  F_NARROW,
  F_LEAF,         /* identity, then the output reshaped by `variant` (enum leaf_shape) */
  F_TABLE,        /* a frame of identity tables, reshaped by `variant` (enum table_shape) */
  F_SUM_STATE_LONG,
  F_SUM_FINISH_SHORT,
  F_SUM_GIDS_KEPT,
  F_SUM_MERGE_KEPT,
  F_FRAME_IN_KEPT,
  F_STREAM_KEPT,
  F_RELEASE_ARGS_TWICE,
  F_RELEASE_SCHEMA,
  F_LEAK_RESERVATION,
  F_RAISE_NO_MESSAGE,
  F_ERROR_ON_OK,
  F_RAISE_ROW, /* raises with the error row `variant` names (enum raise_row) */
  F_ADD_MIXED,
  F_RAISE_ROW_UNSET,
  F_RAISE_AGAIN,
  F_RAISE_ON_SECOND_CALL,
  F_TWO_TYPES
};

/* The variant of a fixture that keeps an input (F_ARGS_KEPT, F_FRAME_IN_KEPT,
 * F_SUM_*_KEPT): the entry then fails. Design 4.4 moves inputs "whatever
 * status it returns", so the host's check must not depend on an OK. */
#define KEPT_THEN_RAISE 1

/* The variant of running_sum whose frame_next fills the error on every call
 * that returns OK (an output or the end): the host still releases it. */
#define FILL_ERROR_ON_OK 2

/* The variant of sum_gids_kept that moves group_ids and never releases them. */
#define GIDS_LEAKED 3

/* F_RAISE_ROW: the row its ERR_RAISED names, for an n-row batch. -1 is
 * legal ("not known"); n and -2 are outside the batch, a runtime bug. */
enum raise_row {
  RR_NONE = 1, /* -1 */
  RR_PAST,     /* n */
  RR_BELOW     /* -2 */
};

/* F_LEAF: what is done to the identity's output column. The first three are
 * legal Arrow the host must read; the rest break one rule each. */
enum leaf_shape {
  LS_SLICED = 1,          /* offset 11, the rows before it padding with null bits */
  LS_NULL_COUNT_UNKNOWN,  /* null_count -1: "not computed", legal */
  LS_EMPTY_DATA_NULL,     /* zero rows, no data buffer: legal */
  LS_N_BUFFERS_3,
  LS_N_CHILDREN_1,
  LS_DICTIONARY,
  LS_NEGATIVE_LENGTH,
  LS_NEGATIVE_OFFSET,
  LS_NULL_COUNT_BELOW,    /* null_count -2 */
  LS_BUFFERS_NULL,
  LS_DATA_NULL,
  LS_RELEASE_KEEPS_SLOT,  /* its release frees the column but leaves `release` set */
  LS_DEVICE_ID,           /* device CPU with device_id 0 */
  LS_SYNC_EVENT,          /* device CPU with a sync event */
  LS_NULL_COUNT_ZERO      /* null_count 0 over a bitmap with a null */
};

/* F_TABLE: what is done to each output table. */
enum table_shape {
  TS_SLICED = 1,  /* struct offset 2 over a child at offset 3: legal */
  TS_N_BUFFERS_0,
  TS_N_BUFFERS_2,
  TS_N_CHILDREN_0,
  TS_N_CHILDREN_2,
  TS_NEGATIVE_LENGTH,
  TS_NEGATIVE_OFFSET,
  TS_BUFFERS_NULL,
  TS_NULL_ROWS,       /* a validity bitmap with row 9 null, null_count 1 */
  TS_NULL_COUNT_LIES, /* null_count 1 with no validity bitmap */
  TS_CHILD_NULL,
  TS_CHILD_RELEASED,
  TS_CHILD_SHORT,  /* the child has one row fewer than the struct */
  TS_DEVICE,
  TS_OUT_ON_ERROR, /* frame_next returns ERR_RAISED with the table still in `out` */
  TS_DICTIONARY,   /* a dictionary on the struct, whose type has none */
  TS_NULL_COUNT_ZERO,   /* rows 1 and 10 null in the bitmap, null_count 0 */
  TS_NULL_COUNT_UNKNOWN /* a bitmap with no null row, null_count -1: legal */
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
  int variant;
};

#define SC KOMIRA_UDF_SHAPE_SCALAR
#define MC KOMIRA_UDF_SHAPE_MAP_BATCHES_COLUMN
#define MF KOMIRA_UDF_SHAPE_MAP_BATCHES_FRAME
#define AM KOMIRA_UDF_SHAPE_AGG_MERGEABLE

static const struct fixture FIXTURES[] = {
    {"double", F_DOUBLE, SC, "l", "l", "", 0},
    {"double_strict", F_DOUBLE_STRICT, SC, "l", "l", "", 0},
    {"fahrenheit", F_FAHRENHEIT, MC, "g", "g", "", 0},
    {"identity", F_IDENTITY, MC, "l", "l", "", 0},
    {"short_by_one", F_SHORT_BY_ONE, MC, "l", "l", "", 0},
    {"bad_layout", F_BAD_LAYOUT, SC, "l", "l", "", 0},
    {"null_out", F_NULL_OUT, SC, "l", "l", "", 0},
    {"const7", F_CONST7, SC, "", "l", "", 0},
    {"raise_on_row_3", F_RAISE_ON_ROW_3, SC, "l", "l", "", 0},
    {"slow_loop", F_SLOW_LOOP, SC, "l", "l", "", 0},
    {"sum", F_SUM, AM, "l", "l", "l", 0},
    {"running_sum", F_RUNNING_SUM, MF, "l", "tl", "", 0},
    {"group_max", F_GROUP_MAX, KOMIRA_UDF_SHAPE_AGG_PLAIN, "l", "l", "", 0},
    {"empty_table", F_EMPTY_TABLE, KOMIRA_UDF_SHAPE_STEP, "l", "t", "", 0},
    /* ROW: f(r) = r.a if r.flag else r.b, reading fields by name. */
    {"pick", F_PICK, KOMIRA_UDF_SHAPE_ROW, "*", "l", "", 0},
    /* The same, where user code catches the undeclared-field error and
     * returns 0 for the row. */
    {"pick_caught", F_PICK_CAUGHT, KOMIRA_UDF_SHAPE_ROW, "*", "l", "", 0},
    /* Runtime bugs the host must catch, each with the identity's values:
     * an error with `out` left set; OK with no output; an output on another
     * device; a null_count the validity bitmap contradicts; `args` read in
     * place and never moved or released. */
    {"out_set_on_error", F_OUT_SET_ON_ERROR, SC, "l", "l", "", 0},
    {"ok_without_output", F_OK_WITHOUT_OUTPUT, SC, "l", "l", "", 0},
    {"device_not_cpu", F_DEVICE_NOT_CPU, SC, "l", "l", "", 0},
    {"null_count_lies", F_NULL_COUNT_LIES, SC, "l", "l", "", 0},
    {"args_kept", F_ARGS_KEPT, SC, "l", "l", "", 0},
    /* A frame that yields its first two input batches unchanged, then
     * raises, leaving the rest of its input unread. */
    {"yield_two_then_raise", F_YIELD_TWO_THEN_RAISE, MF, "l", "tl", "", 0},
    /* a + b, raising on a null in either argument. */
    {"add_strict", F_ADD_STRICT, SC, "ll", "l", "", 0},
    /* More runtime bugs: one row too many; sum whose agg_update reads `args`
     * in place and never moves it; a frame that never ends. */
    {"long_by_one", F_LONG_BY_ONE, MC, "l", "l", "", 0},
    {"sum_args_kept", F_SUM_ARGS_KEPT, AM, "l", "l", "l", 0},
    {"endless", F_ENDLESS, MF, "l", "tl", "", 0},
    /* 2x, and a null for 0: a null the runtime returns for valid inputs. */
    {"null_on_zero", F_NULL_ON_ZERO, SC, "l", "l", "", 0},
    /* int64 in, the same values as int32 out. */
    {"narrow", F_NARROW, MC, "l", "i", "", 0},
    {"leaf_sliced", F_LEAF, MC, "l", "l", "", LS_SLICED},
    {"leaf_null_count_unknown", F_LEAF, MC, "l", "l", "", LS_NULL_COUNT_UNKNOWN},
    {"leaf_empty_data_null", F_LEAF, MC, "l", "l", "", LS_EMPTY_DATA_NULL},
    {"leaf_n_buffers_3", F_LEAF, MC, "l", "l", "", LS_N_BUFFERS_3},
    {"leaf_n_children_1", F_LEAF, MC, "l", "l", "", LS_N_CHILDREN_1},
    {"leaf_dictionary", F_LEAF, MC, "l", "l", "", LS_DICTIONARY},
    {"leaf_negative_length", F_LEAF, MC, "l", "l", "", LS_NEGATIVE_LENGTH},
    {"leaf_negative_offset", F_LEAF, MC, "l", "l", "", LS_NEGATIVE_OFFSET},
    {"leaf_null_count_below", F_LEAF, MC, "l", "l", "", LS_NULL_COUNT_BELOW},
    {"leaf_buffers_null", F_LEAF, MC, "l", "l", "", LS_BUFFERS_NULL},
    {"leaf_data_null", F_LEAF, MC, "l", "l", "", LS_DATA_NULL},
    {"leaf_release_keeps_slot", F_LEAF, MC, "l", "l", "", LS_RELEASE_KEEPS_SLOT},
    {"leaf_device_id", F_LEAF, MC, "l", "l", "", LS_DEVICE_ID},
    {"leaf_sync_event", F_LEAF, MC, "l", "l", "", LS_SYNC_EVENT},
    {"leaf_null_count_zero", F_LEAF, MC, "l", "l", "", LS_NULL_COUNT_ZERO},
    {"table_sliced", F_TABLE, MF, "l", "tl", "", TS_SLICED},
    {"table_n_buffers_0", F_TABLE, MF, "l", "tl", "", TS_N_BUFFERS_0},
    {"table_n_buffers_2", F_TABLE, MF, "l", "tl", "", TS_N_BUFFERS_2},
    {"table_n_children_0", F_TABLE, MF, "l", "tl", "", TS_N_CHILDREN_0},
    {"table_n_children_2", F_TABLE, MF, "l", "tl", "", TS_N_CHILDREN_2},
    {"table_negative_length", F_TABLE, MF, "l", "tl", "", TS_NEGATIVE_LENGTH},
    {"table_negative_offset", F_TABLE, MF, "l", "tl", "", TS_NEGATIVE_OFFSET},
    {"table_buffers_null", F_TABLE, MF, "l", "tl", "", TS_BUFFERS_NULL},
    {"table_null_rows", F_TABLE, MF, "l", "tl", "", TS_NULL_ROWS},
    {"table_null_count_lies", F_TABLE, MF, "l", "tl", "", TS_NULL_COUNT_LIES},
    {"table_child_null", F_TABLE, MF, "l", "tl", "", TS_CHILD_NULL},
    {"table_child_released", F_TABLE, MF, "l", "tl", "", TS_CHILD_RELEASED},
    {"table_child_short", F_TABLE, MF, "l", "tl", "", TS_CHILD_SHORT},
    {"table_device", F_TABLE, MF, "l", "tl", "", TS_DEVICE},
    {"table_out_on_error", F_TABLE, MF, "l", "tl", "", TS_OUT_ON_ERROR},
    {"table_dictionary", F_TABLE, MF, "l", "tl", "", TS_DICTIONARY},
    {"table_null_count_zero", F_TABLE, MF, "l", "tl", "", TS_NULL_COUNT_ZERO},
    {"table_null_count_unknown", F_TABLE, MF, "l", "tl", "", TS_NULL_COUNT_UNKNOWN},
    /* each input batch's column as an int64 column and, times ten, an int32
     * column */
    {"table_two_types", F_TWO_TYPES, MF, "l", "tli", "", 0},
    /* sum, with a state column one row too long; with a result one row
     * short; with agg_update not moving group_ids; with agg_merge not moving
     * the states. */
    {"sum_state_long", F_SUM_STATE_LONG, AM, "l", "l", "l", 0},
    {"sum_finish_short", F_SUM_FINISH_SHORT, AM, "l", "l", "l", 0},
    {"sum_gids_kept", F_SUM_GIDS_KEPT, AM, "l", "l", "l", 0},
    {"sum_merge_kept", F_SUM_MERGE_KEPT, AM, "l", "l", "l", 0},
    {"sum_args_kept_raise", F_SUM_ARGS_KEPT, AM, "l", "l", "l", KEPT_THEN_RAISE},
    {"sum_gids_kept_raise", F_SUM_GIDS_KEPT, AM, "l", "l", "l", KEPT_THEN_RAISE},
    {"sum_merge_kept_raise", F_SUM_MERGE_KEPT, AM, "l", "l", "l", KEPT_THEN_RAISE},
    {"args_kept_raise", F_ARGS_KEPT, SC, "l", "l", "", KEPT_THEN_RAISE},
    /* running_sum whose frame_open reads `in` in place and never moves it;
     * running_sum whose frame_close never releases `in`. */
    {"frame_in_kept", F_FRAME_IN_KEPT, MF, "l", "tl", "", 0},
    {"frame_in_kept_raise", F_FRAME_IN_KEPT, MF, "l", "tl", "", KEPT_THEN_RAISE},
    {"stream_kept", F_STREAM_KEPT, MF, "l", "tl", "", 0},
    /* identity, with one more ownership bug each: the moved `args` released
     * twice; the borrowed argument schema released at load; 64 bytes
     * reserved and never returned; an error with no message. */
    {"release_args_twice", F_RELEASE_ARGS_TWICE, MC, "l", "l", "", 0},
    {"release_schema", F_RELEASE_SCHEMA, MC, "l", "l", "", 0},
    {"leak_reservation", F_LEAK_RESERVATION, MC, "l", "l", "", 0},
    {"raise_no_message", F_RAISE_NO_MESSAGE, MC, "l", "l", "", 0},
    {"error_on_ok", F_ERROR_ON_OK, MC, "l", "l", "", 0},
    /* running_sum, filling the error on every frame_next that returns OK. */
    {"running_sum_error_on_ok", F_RUNNING_SUM, MF, "l", "tl", "", FILL_ERROR_ON_OK},
    /* A batch function that raises naming no row (legal), then two runtime
     * bugs: a row one past the batch, and a row below -1. */
    {"raise_no_row", F_RAISE_ROW, MC, "l", "l", "", RR_NONE},
    {"raise_row_past_batch", F_RAISE_ROW, MC, "l", "l", "", RR_PAST},
    {"raise_row_below_minus_one", F_RAISE_ROW, MC, "l", "l", "", RR_BELOW},
    /* a (int64) + b (int32), null where either is null */
    {"add_mixed", F_ADD_MIXED, SC, "li", "l", "", 0},
    /* an error with its code and message set and its row left as the host
     * set it */
    {"raise_row_unset", F_RAISE_ROW_UNSET, MC, "l", "l", "", 0},
    /* a frame whose frame_next raises, then answers ERR_INTERNAL to every
     * later frame_next (the host must not pull after an error) */
    {"raise_again", F_RAISE_AGAIN, MF, "l", "tl", "", 0},
    /* identity on an instance's first call, ERR_RAISED on its second (a
     * runtime bug: a result that depends on earlier calls, design 3.4 rule 3) */
    {"raise_on_second_call", F_RAISE_ON_SECOND_CALL, MC, "l", "l", "", 0},
    /* sum whose agg_update moves group_ids and never releases them */
    {"sum_gids_leaked", F_SUM_GIDS_KEPT, AM, "l", "l", "l", GIDS_LEAKED},
};

#define N_FIXTURES (sizeof(FIXTURES) / sizeof(FIXTURES[0]))

/* ---- handles ------------------------------------------------------------- */

struct komira_udf_rt {
  const komira_udf_host* host;
  uint32_t global_lock;
  uint32_t thread_affine; /* 1 only from ECHO_INIT_AFFINE */
  int variant;            /* echo_variants.inc; 0 in every other init */
};
#define ROW_FIELDS_MAX 8

/* A loaded UDF. For ROW, the read set's field names, copied at load from
 * spec->args: the only names a row view resolves. */
struct komira_udf_udf {
  const struct fixture* fx;
  const komira_udf_host* host;
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
  const struct fixture* fx;
  const komira_udf_host* host;
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

static const komira_udf_host* host_of(const komira_udf_instance* i) { return i->ctx->rt->host; }

/* ---- the host's ledger ---------------------------------------------------- */

/* A handle's struct, reserved while it is open. */
static void hold(const komira_udf_host* h, size_t n) { h->mem_reserve(h->host_data, (int64_t)n); }
static void drop(const komira_udf_host* h, size_t n) { h->mem_release(h->host_data, (int64_t)n); }

/* A rule the host broke that echo can only see after the fact: one byte
 * reserved and never returned, so the case's ledger fails. */
static void charge_host(const komira_udf_host* h) { h->mem_reserve(h->host_data, 1); }

/* Release an array the host moved in. The C Data rule: release sets the
 * slot to NULL; a host release that does not is charged. */
static void release_host(const komira_udf_host* h, struct ArrowArray* a) {
  if (a->release == NULL) return;
  a->release(a);
  if (a->release != NULL) charge_host(h);
}

/* ---- errors -------------------------------------------------------------- */

/* The bytes an error's strings hold, as reserved with the host. */
static int64_t error_bytes(const komira_udf_error* e) {
  int64_t n = 0;
  if (e->message) n += (int64_t)strlen(e->message) + 1;
  if (e->user_trace) n += (int64_t)strlen(e->user_trace) + 1;
  return n;
}

static void free_error(komira_udf_error* e) {
  const komira_udf_host* h = (const komira_udf_host*)e->private_data;
  if (h != NULL) h->mem_release(h->host_data, error_bytes(e));
  free((void*)e->message);
  free((void*)e->user_trace);
  e->message = NULL;
  e->user_trace = NULL;
  e->private_data = NULL;
  e->release = NULL;
}

static char* dup(const char* s) {
  size_t n = strlen(s) + 1;
  char* d = malloc(n);
  if (d) memcpy(d, s, n);
  return d;
}

/* Fill the host's error; its strings are reserved with host `h` (NULL: a
 * host too old to account to) until the host releases the error. */
static int32_t fail(const komira_udf_host* h, komira_udf_error* e, int32_t code, const char* msg, int64_t row) {
  if (e == NULL || e->struct_size < sizeof(komira_udf_error)) return code;
  e->code = code;
  e->message = dup(msg);
  e->user_trace = code == KOMIRA_UDF_ERR_RAISED ? dup("echo_runtime.c: the fixture raised") : NULL;
  e->row = row;
  e->group = -1;
  e->private_data = (void*)h;
  e->release = free_error;
  if (h != NULL) h->mem_reserve(h->host_data, error_bytes(e));
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

/* The host's half of the C Data rules and of design 3.4 rule 5, checked on
 * every input: an argument struct at offset 0 with one buffer and no
 * validity bitmap; each column's null_count, when known, what its bitmap
 * says over its rows from its own offset. A host that breaks one gets
 * ERR_INTERNAL (the true offset here, BROKEN or not). */
static int64_t count_nulls(const struct ArrowArray* a) {
  const uint8_t* v = (const uint8_t*)a->buffers[0];
  int64_t n = 0;
  for (int64_t r = 0; v != NULL && r < a->length; r++) {
    int64_t at = a->offset + r;
    if (!((v[at >> 3] >> (at & 7)) & 1)) n++;
  }
  return n;
}

static int column_ok(const struct ArrowArray* a) { return a->null_count < 0 || a->null_count == count_nulls(a); }

static int args_ok(const struct ArrowArray* s) {
  if (s->offset != 0 || s->n_buffers != 1 || s->buffers[0] != NULL) return 0;
  for (int64_t i = 0; i < s->n_children; i++)
    if (!column_ok(s->children[i])) return 0;
  return 1;
}

static int32_t check_args(const komira_udf_host* h, const struct ArrowArray* s, komira_udf_error* e) {
  if (args_ok(s)) return KOMIRA_UDF_OK;
  return fail(h, e, KOMIRA_UDF_ERR_INTERNAL,
              "the argument struct is not at offset 0 without a bitmap, or a null_count contradicts its bitmap", -1);
}

static void release_array(struct ArrowArray* a) {
  if (a->release != NULL) a->release(a);
}

static int cancelled(const komira_udf_call* c) {
  if (BROKEN) return 0; /* BROKEN (3) */
  return c != NULL && c->cancel != NULL && __atomic_load_n(c->cancel, __ATOMIC_ACQUIRE) != 0;
}

/* An input on the device of design 4.4: CPU, device_id -1, no sync event. */
static int on_cpu(const struct ArrowDeviceArray* d) {
  return d->device_type == ARROW_DEVICE_CPU && d->device_id == -1 && d->sync_event == NULL;
}

static int past_deadline(const komira_udf_rt* rt, const komira_udf_call* c) {
  return c != NULL && c->deadline_ns != 0 && rt->host->now_ns(rt->host->host_data) > c->deadline_ns;
}

/* ---- building outputs ---------------------------------------------------- */

/* One malloc block per primitive array: its two-entry buffer list, the host
 * its bytes are reserved with, then the validity bitmap and the values. */
struct col_block {
  const void* bufs[2];
  const komira_udf_host* host;
  int64_t bytes;
};

/* Free a column's block and return its reservation, once: NULLs
 * private_data, whatever the array's other fields say. */
static void free_col(struct ArrowArray* a) {
  struct col_block* b = (struct col_block*)a->private_data;
  if (b == NULL) return;
  b->host->mem_release(b->host->host_data, b->bytes);
  free(b);
  a->private_data = NULL;
}

static void release_col(struct ArrowArray* a) {
  free_col(a);
  a->release = NULL;
}

static void set_cpu(struct ArrowDeviceArray* d) {
  d->device_id = -1;
  d->device_type = ARROW_DEVICE_CPU;
  d->sync_event = NULL;
  d->reserved[0] = d->reserved[1] = d->reserved[2] = 0;
}

/* A primitive array of `n` rows of 8-byte values (room for 8 bytes each
 * whatever the type), every row valid; the caller writes *data and clears
 * validity bits for nulls. */
static int make_col(const komira_udf_host* h, struct ArrowArray* a, int64_t n, uint8_t** validity, void** data) {
  size_t vbytes = (size_t)((n + 7) / 8);
  size_t bytes = sizeof(struct col_block) + vbytes + (size_t)n * 8 + 8;
  if (h->mem_reserve(h->host_data, (int64_t)bytes) != KOMIRA_UDF_OK) return 0;
  struct col_block* b = malloc(bytes);
  if (b == NULL) {
    h->mem_release(h->host_data, (int64_t)bytes);
    return 0;
  }
  b->host = h;
  b->bytes = (int64_t)bytes;
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

/* A struct array's block: its buffer list, the children it owns (`kids`,
 * which its release frees whatever `children` and the kids' own release
 * slots were changed to), and `view`, what `children` points at. */
struct table_block {
  const void* bufs[2];
  uint8_t validity[8]; /* a bitmap for table_null_rows and table_sliced */
  int64_t k;
  struct ArrowArray** view;
  struct ArrowArray* kids[];
};

static void release_struct(struct ArrowArray* a) {
  struct table_block* b = (struct table_block*)a->private_data;
  for (int64_t i = 0; i < b->k; i++) {
    free_col(b->kids[i]);
    free(b->kids[i]);
  }
  free(b);
  a->release = NULL;
}

/* A struct array of `n` rows whose `k` children the caller fills with
 * make_col (one spare view slot, for a reshaped table). */
static int make_struct(struct ArrowArray* a, int64_t n, int64_t k) {
  struct table_block* b = calloc(1, sizeof(struct table_block) + (size_t)(2 * k + 1) * sizeof(void*));
  if (b == NULL) return 0;
  b->k = k;
  b->view = b->kids + k;
  for (int64_t i = 0; i < k; i++) {
    b->kids[i] = calloc(1, sizeof(struct ArrowArray));
    b->view[i] = b->kids[i];
  }
  a->length = n;
  a->null_count = 0;
  a->offset = 0;
  a->n_buffers = 1;
  a->n_children = k;
  a->buffers = b->bufs; /* bufs[0] == NULL: no validity */
  a->children = k > 0 ? b->view : NULL;
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
  return s != NULL && s->release != NULL && s->format != NULL && s->format[0] == f && s->format[1] == 0 &&
         s->n_children == 0;
}

static int struct_is(const struct ArrowSchema* s, const char* fmts) {
  if (s == NULL || s->release == NULL || s->format == NULL || strcmp(s->format, "+s") != 0) return 0;
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

static int32_t check_spec(const komira_udf_host* h, const komira_udf_spec* s, komira_udf_error* e,
                          const struct fixture** out) {
  if (s == NULL || s->struct_size < sizeof(komira_udf_spec))
    return fail(h, e, KOMIRA_UDF_ERR_ABI, "spec struct_size is below this runtime's", -1);
  const struct fixture* fx = find(s->entry);
  if (fx == NULL) return fail(h, e, KOMIRA_UDF_ERR_DESCRIPTOR, "no fixture has this entry", -1);
  if (s->form < KOMIRA_UDF_FORM_PACKAGE || s->form > KOMIRA_UDF_FORM_VALUE)
    return fail(h, e, KOMIRA_UDF_ERR_DESCRIPTOR, "code form is not PACKAGE, BUNDLE or VALUE", -1);
  if (s->descriptor_version > 0)
    return fail(h, e, KOMIRA_UDF_ERR_DESCRIPTOR, "descriptor_version is newer than 0, the newest read here", -1);
  if (s->descriptor_len != 0)
    return fail(h, e, KOMIRA_UDF_ERR_DESCRIPTOR, "descriptor version 0 is empty; these bytes are not canonical", -1);
  if ((uint32_t)s->shape != fx->shape)
    return fail(h, e, KOMIRA_UDF_ERR_UNSUPPORTED, "the fixture does not have this shape", -1);
  int result_ok = fx->result[0] == 't' ? struct_is(s->result, fx->result + 1) : leaf_is(s->result, fx->result[0]);
  int state_ok = fx->state[0] == 0 ? s->state == NULL : leaf_is(s->state, fx->state[0]);
  int args_ok = fx->args[0] == '*' ? row_args_ok(s->args) : struct_is(s->args, fx->args);
  if (!args_ok || !result_ok || !state_ok)
    return fail(h, e, KOMIRA_UDF_ERR_UNSUPPORTED, "the declared types are not the fixture's signature", -1);
  *out = fx;
  return KOMIRA_UDF_OK;
}

static int32_t describe_variant(const komira_udf_rt* rt, komira_udf_capabilities* c);

static int32_t echo_describe(komira_udf_rt* rt, komira_udf_capabilities* c) {
  if (c == NULL || c->struct_size < sizeof(komira_udf_capabilities)) return KOMIRA_UDF_ERR_ABI;
  c->runtime_id = ECHO_ID;
  c->runtime_abi = "";
  c->max_descriptor_version = 0;
  c->shapes = KOMIRA_UDF_SHAPE_SCALAR | KOMIRA_UDF_SHAPE_ROW | KOMIRA_UDF_SHAPE_MAP_BATCHES_COLUMN |
              KOMIRA_UDF_SHAPE_MAP_BATCHES_FRAME | KOMIRA_UDF_SHAPE_AGG_PLAIN | KOMIRA_UDF_SHAPE_AGG_MERGEABLE |
              KOMIRA_UDF_SHAPE_STEP;
#ifdef ECHO_NATIVE
  c->threading = KOMIRA_UDF_CONTEXT_PER_THREAD;
  c->hosting = KOMIRA_UDF_HOSTING_NONE;
  c->udf_class = KOMIRA_UDF_CLASS_NATIVE;
#else
  c->threading = KOMIRA_UDF_THREAD_SAFE;
  c->hosting = KOMIRA_UDF_HOSTING_EMBEDDED;
  c->udf_class = KOMIRA_UDF_CLASS_MANAGED;
#endif
  c->thread_affine = rt->thread_affine;
  c->transports = KOMIRA_UDF_TRANSPORT_IN_PROCESS;
  c->devices = KOMIRA_UDF_DEVICE_CPU;
  c->features = KOMIRA_UDF_FEATURE_MEMORY_REPORT;
  c->global_lock = rt->global_lock;
  if (rt->variant != 0) return describe_variant(rt, c);
  return KOMIRA_UDF_OK;
}

static int32_t echo_validate(komira_udf_rt* rt, const komira_udf_spec* s, komira_udf_error* e) {
  const struct fixture* fx = NULL;
  return check_spec(rt->host, s, e, &fx);
}

static int32_t echo_load(komira_udf_rt* rt, const komira_udf_spec* s, komira_udf_udf** out,
                         komira_udf_error* e) {
  const struct fixture* fx = NULL;
  int32_t rc = check_spec(rt->host, s, e, &fx);
  if (rc != KOMIRA_UDF_OK) return rc;
  /* the bug: a schema the host only lends, released (and a host release
   * that leaves its slot set refused) */
  if (fx->id == F_RELEASE_SCHEMA && s->args->release != NULL) {
    s->args->release((struct ArrowSchema*)s->args);
    if (s->args->release != NULL)
      return fail(rt->host, e, KOMIRA_UDF_ERR_INTERNAL, "release_schema: the schema's release left its slot set", -1);
  }
  komira_udf_udf* u = calloc(1, sizeof(*u));
  if (u == NULL) return fail(rt->host, e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "load: out of memory", -1);
  u->fx = fx;
  u->host = rt->host;
  if (fx->shape == KOMIRA_UDF_SHAPE_ROW) {
    for (int64_t i = 0; i < s->args->n_children; i++) {
      u->fields[i] = dup(s->args->children[i]->name);
      u->n_fields = i + 1;
      if (u->fields[i] == NULL) break;
    }
  }
  hold(u->host, sizeof(*u));
  *out = u;
  return KOMIRA_UDF_OK;
}

static void echo_unload(komira_udf_udf* u) {
  for (int64_t i = 0; i < u->n_fields; i++) free(u->fields[i]);
  drop(u->host, sizeof(*u));
  free(u);
}

static int32_t echo_open_context(komira_udf_rt* rt, uint32_t slot, komira_udf_context** out,
                                 komira_udf_error* e) {
  komira_udf_context* c = malloc(sizeof(*c));
  if (c == NULL) return fail(rt->host, e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "open_context: out of memory", -1);
  c->rt = rt;
  c->slot = slot;
  hold(rt->host, sizeof(*c));
  *out = c;
  return KOMIRA_UDF_OK;
}

static void echo_close_context(komira_udf_context* c) {
  drop(c->rt->host, sizeof(*c));
  free(c);
}

static int32_t echo_open_instance(komira_udf_context* c, komira_udf_udf* u, komira_udf_instance** out,
                                  komira_udf_error* e) {
  komira_udf_instance* i = malloc(sizeof(*i));
  if (i == NULL) return fail(c->rt->host, e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "open_instance: out of memory", -1);
  i->ctx = c;
  i->udf = u;
  i->fx = u->fx;
  i->calls = 0;
  hold(c->rt->host, sizeof(*i));
  *out = i;
  return KOMIRA_UDF_OK;
}

static void echo_close_instance(komira_udf_instance* i) {
  drop(host_of(i), sizeof(*i));
  free(i);
}

static int64_t echo_memory_report(komira_udf_context* c) {
  (void)c;
  return 0;
}

static void echo_shutdown(komira_udf_rt* rt) {
  drop(rt->host, sizeof(*rt));
  free(rt);
}

static int32_t start_call(const komira_udf_rt* rt, const komira_udf_call* c, komira_udf_error* e) {
  if (c == NULL || c->struct_size < sizeof(komira_udf_call))
    return fail(rt->host, e, KOMIRA_UDF_ERR_ABI, "call struct_size is below this runtime's", -1);
  if (cancelled(c)) return fail(rt->host, e, KOMIRA_UDF_ERR_CANCELLED, "cancelled before the batch", -1);
  if (past_deadline(rt, c))
    return fail(rt->host, e, KOMIRA_UDF_ERR_DEADLINE, "the deadline passed before the batch", -1);
  return KOMIRA_UDF_OK;
}

#include "echo_calls.inc"
#include "echo_frames.inc"

/* Every entry after abi_minor, in the header's order, but memory_report. */
#define ECHO_ENTRIES                                                                                     \
  echo_describe, echo_validate, echo_load, echo_unload, echo_open_context, echo_close_context,         \
      echo_open_instance, echo_close_instance, echo_call_batch, echo_frame_open, echo_frame_next,      \
      echo_frame_close, echo_agg_open, echo_agg_update, echo_agg_merge, echo_agg_state, echo_agg_finish, \
      echo_agg_close, echo_shutdown

static const komira_udf_runtime TABLE = {
    sizeof(komira_udf_runtime), KOMIRA_UDF_ABI_MAJOR, KOMIRA_UDF_ABI_MINOR, ECHO_ENTRIES, echo_memory_report,
};

/* A runtime on `host`, or NULL with *e filled. `any_major`: accept a host of
 * any ABI major (a variant's bug). */
static komira_udf_rt* new_rt(const komira_udf_host* host, komira_udf_error* e, uint32_t global_lock,
                             int any_major) {
  if (host == NULL || host->struct_size < sizeof(komira_udf_host)) {
    fail(NULL, e, KOMIRA_UDF_ERR_ABI, "this runtime needs a komira_udf_host of ABI 1.0", -1);
    return NULL;
  }
  if (host->abi_major != KOMIRA_UDF_ABI_MAJOR && !any_major) {
    fail(host, e, KOMIRA_UDF_ERR_ABI, "this runtime speaks ABI major 1", -1);
    return NULL;
  }
  komira_udf_rt* r = calloc(1, sizeof(*r));
  if (r == NULL) {
    fail(host, e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "init: out of memory", -1);
    return NULL;
  }
  r->host = host;
  r->global_lock = global_lock;
  hold(host, sizeof(*r));
  host->log(host->host_data, 0, "komira-test: a runtime is up");
  return r;
}

const komira_udf_runtime* ECHO_INIT(const komira_udf_host* host, komira_udf_rt** rt, komira_udf_error* e) {
  komira_udf_rt* r = new_rt(host, e, 0, 0);
  if (r == NULL) return NULL;
  *rt = r;
  return &TABLE;
}

#ifdef ECHO_INIT_GLOBAL_LOCK
const komira_udf_runtime* ECHO_INIT_GLOBAL_LOCK(const komira_udf_host* host, komira_udf_rt** rt,
                                                komira_udf_error* e) {
  komira_udf_rt* r = new_rt(host, e, 1, 0);
  if (r == NULL) return NULL;
  *rt = r;
  return &TABLE;
}
#endif

#ifdef ECHO_INIT_AFFINE
const komira_udf_runtime* ECHO_INIT_AFFINE(const komira_udf_host* host, komira_udf_rt** rt, komira_udf_error* e) {
  komira_udf_rt* r = new_rt(host, e, 0, 0);
  if (r == NULL) return NULL;
  r->thread_affine = 1;
  *rt = r;
  return &TABLE;
}
#endif

#ifdef ECHO_INIT_VARIANT
#include "echo_variants.inc"
#else
static int32_t describe_variant(const komira_udf_rt* rt, komira_udf_capabilities* c) {
  (void)rt;
  (void)c;
  return KOMIRA_UDF_OK;
}
#endif
