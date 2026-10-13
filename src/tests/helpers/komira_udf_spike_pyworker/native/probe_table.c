/*
 * The runtime library's table entries the other probes do not reach, and
 * what each build of the proxy starts. Test-only spike code
 * (tests/test_runtime_table.mojo).
 *
 *   specs    validate and load refusing a spec before any message (NULL or
 *            short struct, no argument or result schema, a state type, args
 *            not a struct or over 8 fields, a result that is not one
 *            column, a type the transport does not carry); 8 arguments
 *            taken; refusals with a NULL error and with an error struct too
 *            short to write (nothing written);
 *   entries  describe (NULL, short, and a longer struct whose size is kept;
 *            every field); the frame and aggregate entries refusing, each
 *            releasing what it was given once and leaving outputs released;
 *   builds   per build: the worker's thread-pool limit, whether it maps
 *            the shared region, which IPC codec it imported; a worker that
 *            exits with status 3; open_instance on the lost context; the
 *            proxy's call accounting logged at close_context (level 3)
 *            only when calls were made; a call of 4.4 s (its worker time is
 *            over 2^32 ns);
 *   deadline the proxy's checks before a batch against the host's clock (a
 *            deadline equal to now passes, one ns before refuses, a cancel
 *            set refuses), the deadline reaching the worker, an empty batch
 *            without values, one row without values refused; the clock
 *            read after every row while a deadline is set (ERR_DEADLINE
 *            at row 2 after a slow row 1), and a deadline passing during
 *            the last row ending nothing;
 *   many     17 UDFs in one context: the 17th refused; one UDF opened twice
 *            in a context;
 *   init     init refusing a NULL, short or other-major host; a copy of the
 *            library loaded by absolute path from another directory finds
 *            that directory (its zygote's interpreter is looked for
 *            there).
 * Each case is one member of the JSON object (probe_json.h): status, the
 * error's message, and a value the case names (for refusals: 1 when the
 * row is not -1, 10 when the group is not -1).
 *
 * FFI-BOUNDARY. The library is dlopened (RTLD_NOW | RTLD_LOCAL) and never
 * closed; its runtime is shut down before kpw_probe_table returns. Handles
 * are the runtime's, closed here. Arrays and streams passed in are this
 * file's; each release counts itself. The library copy in TMPDIR is this
 * file's.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "komira_udf_runtime.h"
#include "pyw_descriptor.h"
#include "probe_json.h"

static int64_t mono(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

struct hostdata {
  int64_t fixed_now; /* 0: the real clock */
  int stats_logs, stats_level, fork_logs, fork_level;
};

static int32_t t_reserve(void* hd, int64_t b) {
  (void)hd, (void)b;
  return KOMIRA_UDF_OK;
}
static void t_release(void* hd, int64_t b) { (void)hd, (void)b; }
static int64_t t_now(void* hd) {
  struct hostdata* h = hd;
  return h->fixed_now ? h->fixed_now : mono();
}
static void t_log(void* hd, int32_t level, const char* m) {
  struct hostdata* h = hd;
  if (strstr(m, "calls ") != NULL && strstr(m, "wait ns") != NULL) h->stats_logs++, h->stats_level = level;
  if (strstr(m, "forked worker") != NULL) h->fork_logs++, h->fork_level = level;
}

struct eng {
  const komira_udf_runtime* t;
  komira_udf_rt* rt;
  komira_udf_host host;
  struct hostdata hd;
  __typeof__(&komira_udf_runtime_init_v1) init;
};

#define ERR_INIT {sizeof(komira_udf_error), 0, NULL, NULL, -1, -1, NULL, NULL}

/* Records a call's status and its error (then released). */
static void rec(struct pj* j, const char* name, int32_t rc, komira_udf_error* e, int64_t extra) {
  int64_t v = extra;
  if (rc != KOMIRA_UDF_OK) v += (e->row != -1) + (e->group != -1) * 10;
  pj_case(j, name, rc, rc != KOMIRA_UDF_OK && e->message ? e->message : "OK", v);
  if (e->release) e->release(e);
  e->release = NULL;
  e->message = NULL;
}

static int open_engine(struct eng* e, const char* lib, struct pj* j) {
  memset(e, 0, sizeof(*e));
  void* h = dlopen(lib, RTLD_NOW | RTLD_LOCAL);
  e->init = h ? (__typeof__(&komira_udf_runtime_init_v1))dlsym(h, "komira_udf_runtime_init_v1") : NULL;
  if (e->init == NULL) {
    pj_case(j, "open", -1, h ? "no komira_udf_runtime_init_v1" : dlerror(), 0);
    return 0;
  }
  e->host = (komira_udf_host){sizeof(komira_udf_host), KOMIRA_UDF_ABI_MAJOR, KOMIRA_UDF_ABI_MINOR, &e->hd,
                              t_reserve, t_release, t_now, t_log};
  komira_udf_error err = ERR_INIT;
  e->t = e->init(&e->host, &e->rt, &err);
  if (e->t == NULL) {
    rec(j, "open", -1, &err, 0);
    return 0;
  }
  return 1;
}

/* ---- specs ------------------------------------------------------------------ */

static void no_release_schema(struct ArrowSchema* s) { (void)s; }

struct specb {
  struct ArrowSchema kid[65], args, result, rkid[2];
  struct ArrowSchema* kids[65];
  struct ArrowSchema* rkids[2];
  komira_udf_spec spec;
  uint8_t desc[PYW_DESCRIPTOR_MAX];
};

/* A BUNDLE SCALAR of `nargs` arguments of `fmt` to an int64 result. */
static void mk(struct specb* b, const char* entry, int nargs, const char* fmt) {
  memset(b, 0, sizeof(*b));
  for (int i = 0; i < nargs; i++) {
    b->kid[i] = (struct ArrowSchema){fmt, "a", NULL, ARROW_FLAG_NULLABLE, 0, NULL, NULL, no_release_schema, NULL};
    b->kids[i] = &b->kid[i];
  }
  b->args = (struct ArrowSchema){"+s", "", NULL, 0, nargs, b->kids, NULL, no_release_schema, NULL};
  b->result = (struct ArrowSchema){"l", "", NULL, ARROW_FLAG_NULLABLE, 0, NULL, NULL, no_release_schema, NULL};
  b->spec.struct_size = sizeof(b->spec);
  b->spec.shape = KOMIRA_UDF_SHAPE_SCALAR;
  b->spec.form = KOMIRA_UDF_FORM_BUNDLE;
  b->spec.entry = entry;
  b->spec.args = &b->args;
  b->spec.result = &b->result;
  b->spec.null_mode = KOMIRA_UDF_NULL_MANUAL;
  b->spec.stability = KOMIRA_UDF_IMMUTABLE;
  b->spec.descriptor_version = 1;
  b->spec.descriptor = b->desc;
  b->spec.descriptor_len = pyw_descriptor_encode(b->desc, entry, (uint32_t)b->spec.shape, &b->args, &b->result);
}

static void spec_cases(struct eng* e, struct pj* j) {
  struct specb b;
  komira_udf_error err = ERR_INIT;
  int32_t rc;
  rc = e->t->validate(e->rt, NULL, &err);
  rec(j, "spec_null", rc, &err, 0);
  mk(&b, "udf_worker_fixtures:pair", 2, "l");
  b.spec.struct_size = 8;
  rc = e->t->validate(e->rt, &b.spec, &err);
  rec(j, "spec_short", rc, &err, 0);
  mk(&b, "udf_worker_fixtures:pair", 2, "l");
  b.spec.args = NULL;
  rc = e->t->validate(e->rt, &b.spec, &err);
  rec(j, "spec_no_args", rc, &err, 0);
  mk(&b, "udf_worker_fixtures:pair", 2, "l");
  b.spec.result = NULL;
  rc = e->t->validate(e->rt, &b.spec, &err);
  rec(j, "spec_no_result", rc, &err, 0);
  mk(&b, "udf_worker_fixtures:pair", 2, "l");
  b.spec.state = &b.result;
  rc = e->t->validate(e->rt, &b.spec, &err);
  rec(j, "spec_state", rc, &err, 0);
  mk(&b, "udf_worker_fixtures:pair", 2, "l");
  b.spec.args = &b.kid[0]; /* one field, not a struct */
  rc = e->t->validate(e->rt, &b.spec, &err);
  rec(j, "spec_args_not_struct", rc, &err, 0);
  mk(&b, "udf_fixtures:sum64", 65, "l");
  rc = e->t->validate(e->rt, &b.spec, &err);
  rec(j, "spec_65_args", rc, &err, 0);
  mk(&b, "udf_fixtures:sum64", 64, "l");
  rc = e->t->validate(e->rt, &b.spec, &err);
  rec(j, "spec_64_args", rc, &err, 0);
  mk(&b, "udf_worker_fixtures:pair", 2, "l");
  b.rkid[0] = b.result;
  b.rkids[0] = &b.rkid[0];
  b.result = (struct ArrowSchema){"+s", "", NULL, 0, 1, b.rkids, NULL, no_release_schema, NULL};
  rc = e->t->validate(e->rt, &b.spec, &err);
  rec(j, "spec_result_struct", rc, &err, 0);
  mk(&b, "udf_worker_fixtures:pair", 2, "tdD");
  rc = e->t->validate(e->rt, &b.spec, &err);
  rec(j, "spec_type_not_carried", rc, &err, 0);
  mk(&b, "udf_worker_fixtures:pair", 2, "l");
  b.result.format = "tdD";
  komira_udf_udf* u = NULL;
  rc = e->t->load(e->rt, &b.spec, &u, &err);
  rec(j, "load_result_type_not_carried", rc, &err, u != NULL);
  /* a NULL error, and one too short to write: the status only */
  rc = e->t->validate(e->rt, NULL, NULL);
  pj_case(j, "error_null", rc, "", 0);
  komira_udf_error small = {8, 0, NULL, NULL, 7, 7, NULL, NULL};
  rc = e->t->validate(e->rt, NULL, &small);
  pj_case(j, "error_short", rc, "", (small.message != NULL) + (small.release != NULL) * 10 + (small.code != 0) * 100 +
                                       (small.row != 7) * 1000);
}

/* ---- entries ---------------------------------------------------------------- */

static int released;
static void count_array(struct ArrowArray* a) {
  released++;
  a->release = NULL;
}
static void count_stream(struct ArrowDeviceArrayStream* s) {
  released++;
  s->release = NULL;
}

static void entry_cases(struct eng* e, struct pj* j) {
  komira_udf_capabilities c;
  memset(&c, 0, sizeof(c));
  pj_case(j, "describe_null", e->t->describe(e->rt, NULL), "", 0);
  c.struct_size = 8;
  pj_case(j, "describe_short", e->t->describe(e->rt, &c), "", 0);
  struct {
    komira_udf_capabilities c;
    char more[16];
  } big;
  memset(&big, 0, sizeof(big));
  big.c.struct_size = sizeof(big);
  int32_t rc = e->t->describe(e->rt, &big.c);
  char m[256];
  snprintf(m, sizeof(m), "%s %s %u %u %u %u %u", big.c.runtime_id ? big.c.runtime_id : "?",
           big.c.runtime_abi ? big.c.runtime_abi : "?", big.c.max_descriptor_version, big.c.shapes, big.c.devices,
           big.c.features, big.c.udf_class);
  pj_case(j, "describe", rc, m, (int64_t)big.c.struct_size);

  komira_udf_error err = ERR_INIT;
  komira_udf_call call = {sizeof(call), 0, 1, NULL};
  struct ArrowDeviceArrayStream st;
  memset(&st, 0, sizeof(st));
  st.release = count_stream;
  komira_udf_frame* fr = NULL;
  released = 0;
  rc = e->t->frame_open(NULL, &call, &st, &fr, &err);
  rec(j, "frame_open", rc, &err, released * 100);
  rc = e->t->frame_open(NULL, &call, NULL, &fr, &err);
  rec(j, "frame_open_no_stream", rc, &err, 0);
  st.release = NULL;
  rc = e->t->frame_open(NULL, &call, &st, &fr, &err);
  rec(j, "frame_open_released_stream", rc, &err, 0);
  struct ArrowDeviceArray out;
  memset(&out, 0, sizeof(out));
  out.array.release = count_array;
  rc = e->t->frame_next(NULL, &call, &out, &err);
  rec(j, "frame_next", rc, &err, (out.array.release != NULL) * 100);
  e->t->frame_close(NULL);
  komira_udf_groups* g = NULL;
  rc = e->t->agg_open(NULL, &g, &err);
  rec(j, "agg_open", rc, &err, 0);
  struct ArrowDeviceArray args, ids;
  memset(&args, 0, sizeof(args));
  memset(&ids, 0, sizeof(ids));
  args.array.release = count_array;
  ids.array.release = count_array;
  released = 0;
  rc = e->t->agg_update(NULL, &call, &args, &ids, 1, &err);
  rec(j, "agg_update", rc, &err, released * 100);
  args.array.release = count_array;
  released = 0;
  rc = e->t->agg_merge(NULL, &call, &args, NULL, 1, &err);
  rec(j, "agg_merge_no_ids", rc, &err, released * 100);
  out.array.release = count_array;
  rc = e->t->agg_state(NULL, 1, &out, &err);
  rec(j, "agg_state", rc, &err, (out.array.release != NULL) * 100);
  out.array.release = count_array;
  rc = e->t->agg_finish(NULL, 1, &out, &err);
  rec(j, "agg_finish", rc, &err, (out.array.release != NULL) * 100);
  e->t->agg_close(NULL);
  pj_case(j, "memory_report", 0, "", e->t->memory_report != NULL);
}

/* ---- calls ------------------------------------------------------------------ */

struct argsb {
  struct ArrowArray parent, child;
  struct ArrowArray* kids[1];
  const void* pbufs[1];
  const void* cbufs[2];
  int64_t vals[8];
};

static void child_rel(struct ArrowArray* a) { a->release = NULL; }
static void parent_rel(struct ArrowArray* a) {
  released++;
  a->release = NULL;
}

/* One int64 argument column of `n` rows (values x0, x0+1, ...); `values`
 * 0: no values buffer. */
static void mkargs(struct argsb* b, struct ArrowDeviceArray* d, int64_t n, int64_t x0, int values) {
  memset(b, 0, sizeof(*b));
  for (int i = 0; i < 8; i++) b->vals[i] = x0 + i;
  b->cbufs[0] = NULL;
  b->cbufs[1] = values ? b->vals : NULL;
  b->child = (struct ArrowArray){n, 0, 0, 2, 0, b->cbufs, NULL, NULL, child_rel, NULL};
  b->kids[0] = &b->child;
  b->parent = (struct ArrowArray){n, 0, 0, 1, 1, b->pbufs, b->kids, NULL, parent_rel, NULL};
  memset(d, 0, sizeof(*d));
  d->array = b->parent;
  d->device_id = -1;
  d->device_type = ARROW_DEVICE_CPU;
}

struct one {
  komira_udf_udf* u;
  komira_udf_context* c;
  komira_udf_instance* i;
};

static int32_t setup(struct eng* e, const char* entry, struct one* o, komira_udf_error* err) {
  struct specb b;
  mk(&b, entry, 1, "l");
  int32_t rc = KOMIRA_UDF_OK;
  if (o->u == NULL) rc = e->t->load(e->rt, &b.spec, &o->u, err);
  if (rc == KOMIRA_UDF_OK && o->c == NULL) rc = e->t->open_context(e->rt, 0, &o->c, err);
  if (rc == KOMIRA_UDF_OK) rc = e->t->open_instance(o->c, o->u, &o->i, err);
  return rc;
}

static void teardown(struct eng* e, struct one* o) {
  if (o->i) e->t->close_instance(o->i);
  if (o->c) e->t->close_context(o->c);
  if (o->u) e->t->unload(o->u);
  memset(o, 0, sizeof(*o));
}

/* call_batch of `n` rows; the first value of the result, or -1. */
static int32_t call1(struct eng* e, komira_udf_instance* i, int64_t n, int64_t x0, int values, int64_t deadline,
                     const volatile int32_t* cancel, komira_udf_error* err, int64_t* first) {
  struct argsb ab;
  struct ArrowDeviceArray args, out;
  mkargs(&ab, &args, n, x0, values);
  memset(&out, 0xAB, sizeof(out));
  komira_udf_call call = {sizeof(call), deadline, 1, cancel};
  int32_t rc = e->t->call_batch(i, &call, &args, &out, err);
  *first = -1;
  if (rc == KOMIRA_UDF_OK) {
    if (out.array.length > 0) *first = ((const int64_t*)out.array.buffers[1])[out.array.offset];
    else *first = 0;
    int reserved_zero = 1;
    for (size_t k = 0; k < sizeof(out.reserved) / sizeof(out.reserved[0]); k++) reserved_zero &= out.reserved[k] == 0;
    if (!reserved_zero || out.device_type != ARROW_DEVICE_CPU || out.device_id != -1 || out.sync_event != NULL)
      *first = -2;
    out.array.release(&out.array);
  }
  return rc;
}

static void build_cases(struct eng* e, struct pj* j, int long_call) {
  komira_udf_error err = ERR_INIT;
  const char* fx[3] = {"udf_worker_fixtures:blas_threads", "udf_worker_fixtures:shares_memory",
                       "udf_worker_fixtures:uses_pyarrow"};
  const char* names[3] = {"blas_threads", "shares_memory", "uses_pyarrow"};
  for (int k = 0; k < 3; k++) {
    struct one o = {0};
    int64_t v = -1;
    int32_t rc = setup(e, fx[k], &o, &err);
    if (rc == KOMIRA_UDF_OK) rc = call1(e, o.i, 1, 0, 1, 0, NULL, &err, &v);
    rec(j, names[k], rc, &err, v);
    teardown(e, &o);
  }
  /* a context with no calls logs no accounting; one with calls logs it */
  struct one o = {0};
  e->hd.stats_logs = 0;
  setup(e, "udf_worker_fixtures:worker_pid", &o, &err);
  teardown(e, &o);
  pj_case(j, "no_calls_no_stats", 0, "", e->hd.stats_logs);
  int64_t v;
  setup(e, "udf_worker_fixtures:worker_pid", &o, &err);
  call1(e, o.i, 1, 0, 1, 0, NULL, &err, &v);
  teardown(e, &o);
  pj_case(j, "calls_stats", e->hd.stats_level, "", e->hd.stats_logs);
  pj_case(j, "fork_log", e->hd.fork_level, "", e->hd.fork_logs > 0);
  /* a worker that exits with status 3; the context is lost */
  int32_t rc = setup(e, "udf_worker_fixtures:exit_3", &o, &err);
  if (rc == KOMIRA_UDF_OK) rc = call1(e, o.i, 1, 0, 1, 0, NULL, &err, &v);
  rec(j, "exit_3", rc, &err, 0);
  komira_udf_instance* again = NULL;
  rc = e->t->open_instance(o.c, o.u, &again, &err);
  rec(j, "open_instance_lost", rc, &err, again != NULL);
  teardown(e, &o);
  if (long_call) {
    rc = setup(e, "udf_worker_fixtures:sleep_ms", &o, &err);
    if (rc == KOMIRA_UDF_OK) rc = call1(e, o.i, 1, 4400, 1, 0, NULL, &err, &v);
    rec(j, "call_over_2e32_ns", rc, &err, v);
    teardown(e, &o);
  }
}

static void deadline_cases(struct eng* e, struct pj* j) {
  komira_udf_error err = ERR_INIT;
  struct one o = {0};
  int64_t v;
  int32_t rc = setup(e, "udf_worker_fixtures:worker_pid", &o, &err);
  if (rc != KOMIRA_UDF_OK) {
    rec(j, "deadline_setup", rc, &err, 0);
    return;
  }
  int64_t later = mono() + 60LL * 1000000000LL;
  e->hd.fixed_now = later;
  rc = call1(e, o.i, 1, 0, 1, later, NULL, &err, &v);
  rec(j, "deadline_equal_now", rc, &err, 0);
  rc = call1(e, o.i, 1, 0, 1, later - 1, NULL, &err, &v);
  rec(j, "deadline_one_ns_past", rc, &err, 0);
  /* the library's clock says early; the worker's, that the deadline passed:
   * seen after row 0 of 2, with a row left */
  e->hd.fixed_now = 1;
  rc = call1(e, o.i, 2, 0, 1, mono() - 1000000000LL, NULL, &err, &v);
  rec(j, "deadline_in_worker", rc, &err, 0);
  e->hd.fixed_now = 0;
  volatile int32_t flag = 1;
  rc = call1(e, o.i, 1, 0, 1, 0, &flag, &err, &v);
  rec(j, "cancelled_before", rc, &err, 0);
  rc = call1(e, o.i, 0, 0, 0, 0, NULL, &err, &v);
  rec(j, "empty_no_values", rc, &err, v);
  rc = call1(e, o.i, 1, 0, 0, 0, NULL, &err, &v);
  rec(j, "one_row_no_values", rc, &err, 0);
  teardown(e, &o);
  /* The worker reads the clock after every row while a deadline is set:
   * slow_on_1 over the values 0, 1, 2 returns at once on rows 0 and 2 and
   * takes 2 s on row 1, and the deadline is 1 s ahead (on the real clock;
   * the library kills a worker only 2 s past it). Read after row 1 only, it
   * has passed: ERR_DEADLINE at row 2. Over the values 0, 1 the deadline
   * passes during the last row, and the batch is complete: OK, never row 2
   * (a row past the batch). */
  rc = setup(e, "udf_worker_fixtures:slow_on_1", &o, &err);
  if (rc != KOMIRA_UDF_OK) {
    rec(j, "row_deadline_setup", rc, &err, 0);
    return;
  }
  rc = call1(e, o.i, 3, 0, 1, mono() + 1000000000LL, NULL, &err, &v);
  rec(j, "deadline_after_row_1", rc, &err, 0);
  rc = call1(e, o.i, 2, 0, 1, mono() + 1000000000LL, NULL, &err, &v);
  rec(j, "deadline_in_last_row", rc, &err, 0);
  teardown(e, &o);
}

static void many_cases(struct eng* e, struct pj* j) {
  komira_udf_error err = ERR_INIT;
  komira_udf_udf* u[17] = {0};
  komira_udf_instance* in[17] = {0};
  komira_udf_context* c = NULL;
  struct specb b;
  mk(&b, "udf_worker_fixtures:worker_pid", 1, "l");
  int32_t rc = e->t->open_context(e->rt, 0, &c, &err);
  int opened = 0;
  for (int i = 0; i < 17 && rc == KOMIRA_UDF_OK; i++) {
    rc = e->t->load(e->rt, &b.spec, &u[i], &err);
    if (rc == KOMIRA_UDF_OK) rc = e->t->open_instance(c, u[i], &in[i], &err);
    if (rc == KOMIRA_UDF_OK) opened++;
  }
  rec(j, "seventeen_udfs", rc, &err, opened);
  komira_udf_instance* twice = NULL;
  rc = e->t->open_instance(c, u[0], &twice, &err);
  int64_t v = -1;
  if (rc == KOMIRA_UDF_OK) rc = call1(e, twice, 1, 0, 1, 0, NULL, &err, &v);
  rec(j, "same_udf_twice", rc, &err, v > 0);
  if (twice) e->t->close_instance(twice);
  for (int i = 0; i < 17; i++)
    if (in[i]) e->t->close_instance(in[i]);
  if (c) e->t->close_context(c);
  for (int i = 0; i < 17; i++)
    if (u[i]) e->t->unload(u[i]);
}

static void init_cases(struct eng* e, struct pj* j, const char* lib) {
  komira_udf_error err = ERR_INIT;
  komira_udf_rt* rt = NULL;
  komira_udf_host h = e->host;
  const komira_udf_runtime* t = e->init(NULL, &rt, &err);
  rec(j, "init_host_null", t == NULL ? (int32_t)err.code : 0, &err, 0);
  h.struct_size = 8;
  t = e->init(&h, &rt, &err);
  rec(j, "init_host_short", t == NULL ? (int32_t)err.code : 0, &err, 0);
  h = e->host;
  h.abi_major = KOMIRA_UDF_ABI_MAJOR + 1;
  t = e->init(&h, &rt, &err);
  rec(j, "init_host_major", t == NULL ? (int32_t)err.code : 0, &err, 0);
  /* a copy of the library in $TMPDIR/rtcopy, loaded by absolute path */
  const char* tmp = getenv("TMPDIR");
  char dir[512], path[600];
  snprintf(dir, sizeof(dir), "%s/rtcopy", tmp ? tmp : "/tmp");
  mkdir(dir, 0700);
  snprintf(path, sizeof(path), "%s/copy_of_runtime.so", dir);
  FILE* in = fopen(lib, "rb");
  FILE* out = fopen(path, "wb");
  if (in == NULL || out == NULL) {
    if (in) fclose(in);
    if (out) fclose(out);
    pj_case(j, "init_copy", -1, "copy failed", 0);
    return;
  }
  char buf[65536];
  size_t r;
  while ((r = fread(buf, 1, sizeof(buf), in)) > 0) fwrite(buf, 1, r, out);
  fclose(in);
  fclose(out);
  void* hh = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  __typeof__(&komira_udf_runtime_init_v1) init2 =
      hh ? (__typeof__(&komira_udf_runtime_init_v1))dlsym(hh, "komira_udf_runtime_init_v1") : NULL;
  if (init2 == NULL) {
    pj_case(j, "init_copy", -1, dlerror(), 0);
    return;
  }
  t = init2(&e->host, &rt, &err);
  char want[700];
  snprintf(want, sizeof(want), "%s/python/bin/python3.13", dir);
  int names_dir = err.message != NULL && strstr(err.message, want) != NULL;
  rec(j, "init_copy", t == NULL ? (int32_t)err.code : 0, &err, names_dir * 100);
}

/* A context worker killed while idle (SIGKILL from here, after a call told
 * its pid): the next open_instance on the context runs no user code, so the
 * loss is ERR_INSTANCE_LOST (section 4.5), and a call on the old instance
 * is refused the same way. */
static void lost_idle_cases(struct eng* e, struct pj* j) {
  komira_udf_error err = ERR_INIT;
  struct one o = {0};
  int64_t pid = -1;
  int32_t rc = setup(e, "udf_worker_fixtures:worker_pid", &o, &err);
  if (rc == KOMIRA_UDF_OK) rc = call1(e, o.i, 1, 0, 1, 0, NULL, &err, &pid);
  rec(j, "lost_idle_call", rc, &err, 0);
  if (rc == KOMIRA_UDF_OK && pid > 0) {
    kill((pid_t)pid, SIGKILL);
    for (int k = 0; k < 2000 && kill((pid_t)pid, 0) == 0; k++) usleep(1000);
    komira_udf_instance* again = NULL;
    rc = e->t->open_instance(o.c, o.u, &again, &err);
    rec(j, "lost_idle_open_instance", rc, &err, again != NULL);
    int64_t v = 0;
    rc = call1(e, o.i, 1, 0, 1, 0, NULL, &err, &v);
    rec(j, "lost_idle_call_after", rc, &err, 0);
  }
  teardown(e, &o);
}

/* A normal shutdown, timed: a context opened, a call made and the context
 * closed, then shutdown. The zygote exits on SHUTDOWN and the engine, its
 * parent, reaps it at once; one that waits for a process it does not reap
 * (a zombie stays "alive" to kill(pid, 0)) runs into its 2 s fallback kill.
 * The value is shutdown's ms. */
static void shutdown_cases(struct eng* e, struct pj* j) {
  komira_udf_error err = ERR_INIT;
  struct one o = {0};
  int64_t v = 0;
  int32_t rc = setup(e, "udf_worker_fixtures:worker_pid", &o, &err);
  if (rc == KOMIRA_UDF_OK) rc = call1(e, o.i, 1, 0, 1, 0, NULL, &err, &v);
  rec(j, "shutdown_call", rc, &err, 0);
  teardown(e, &o);
  int64_t t0 = mono();
  e->t->shutdown(e->rt);
  pj_case(j, "shutdown_ms", 0, "", (mono() - t0) / 1000000);
}

/* The zygote ends during a LOAD (the module exits the process that imports
 * it, status 3): load returns the zygote's end as the engine's child, by its
 * status; a later validate is refused at once (the channel is dead); and
 * shutdown returns within a second (the zygote is already reaped). */
static void zygote_exit_cases(struct eng* e, struct pj* j) {
  komira_udf_error err = ERR_INIT;
  struct specb b;
  mk(&b, "udf_worker_exit_on_import:f", 1, "l");
  komira_udf_udf* u = NULL;
  int32_t rc = e->t->load(e->rt, &b.spec, &u, &err);
  rec(j, "zygote_exit_load", rc, &err, u != NULL);
  rc = e->t->load(e->rt, &b.spec, &u, &err);
  rec(j, "zygote_exit_load_again", rc, &err, u != NULL);
  mk(&b, "udf_worker_fixtures:worker_pid", 1, "l");
  rc = e->t->validate(e->rt, &b.spec, &err);
  rec(j, "zygote_exit_validate", rc, &err, 0);
  int64_t t0 = mono();
  e->t->shutdown(e->rt);
  pj_case(j, "zygote_exit_shutdown", 0, "", (mono() - t0) / 1000000);
}

/* `lib`: a runtime library; `group`: specs, entries, builds, builds_long,
 * deadline, many, init, shutdown or zygote_exit (the last two shut the runtime down
 * themselves). */
char* kpw_probe_table(const char* lib, const char* group) {
  struct pj j = {0};
  pj_open(&j);
  struct eng e;
  if (open_engine(&e, lib, &j) && strcmp(group, "shutdown") == 0) {
    shutdown_cases(&e, &j);
  } else if (e.t != NULL && strcmp(group, "zygote_exit") == 0) {
    zygote_exit_cases(&e, &j);
  } else if (e.t != NULL) {
    if (strcmp(group, "specs") == 0) spec_cases(&e, &j);
    else if (strcmp(group, "entries") == 0) entry_cases(&e, &j);
    else if (strcmp(group, "builds") == 0) build_cases(&e, &j, 0);
    else if (strcmp(group, "builds_long") == 0) build_cases(&e, &j, 1);
    else if (strcmp(group, "deadline") == 0) deadline_cases(&e, &j);
    else if (strcmp(group, "many") == 0) many_cases(&e, &j);
    else if (strcmp(group, "init") == 0) init_cases(&e, &j, lib);
    else if (strcmp(group, "lost_idle") == 0) lost_idle_cases(&e, &j);
    else pj_case(&j, "group", -1, "no such group", 0);
    e.t->shutdown(e.rt);
  }
  return pj_close(&j);
}
