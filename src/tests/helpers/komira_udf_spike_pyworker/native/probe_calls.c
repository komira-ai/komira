/*
 * Calls the engine loop (drive.c) does not make, through a UDF runtime
 * library's table alone (komira_udf_runtime.h). Test-only spike code
 * (tests/test_worker_calls.mojo).
 *
 *   two_args   a SCALAR of two int64 arguments whose children are slices at
 *              different offsets (13 and 3), each with nulls, one null count
 *              given and one left -1: every value and every null of the
 *              result (section 4.4: each child has its own offset).
 *   late_load  a UDF loaded after a context was opened: called in that
 *              context, then in a context opened after the load; then, in
 *              the first context, a UDF unloaded and another loaded (whose
 *              handle may reuse the first's address): the second is called.
 *   refusals   call_batch given args it must refuse before any message:
 *              each refusal's status and reason, `args` released exactly
 *              once by each, and the context still serving a good call after.
 *   kills      a call deaf to cancel and to the clock: cancelled 300 ms in,
 *              and, in a new context, past a deadline 300 ms away. Both are
 *              answered by killing the worker (section 5.2); the time each
 *              took, the worker gone, and the context lost.
 *   after_cancel  a call cancelled 150 ms in, then a second instance and the
 *              first again in the same context: both answer.
 *   two_udfs   two UDFs of different arity loaded before the context opened
 *              (zygote: before the fork), an instance of each in one context,
 *              called in turn: each runs its own UDF and schema.
 *   many_calls eight rounds of 40 calls that hold their input's slot and one
 *              that lets all go: every call answers and the heap never fills.
 *   nulls      a null in the last row of 9 (SCALAR) and in an 8-row column
 *              result: every value and bit.
 *   trace      a user error's trace is its Python traceback.
 *   big        a 9.6 MB result, over the reply heap: every value.
 *   clock_time 1000 rows with a deadline set: 1000 clock reads; the call's ms.
 *   leaks      the engine's heap around 200 refused validates, loads with
 *              unloads, and instances opened and closed: bytes grown.
 *   leaks_more the same around 200 validates taken, 200 calls whose user code
 *              raises, 50 contexts opened and closed, and 25 inits with
 *              shutdowns: bytes grown, a case each.
 *   abs_path   the library opened by its absolute path, then two_args.
 * Each case is one member of the JSON object kpw_probe_calls returns (as
 * probe_json.h); kpw_free (drive.c) frees it.
 *
 * FFI-BOUNDARY. The library is dlopened (RTLD_NOW | RTLD_LOCAL) and never
 * closed; its runtime is shut down before kpw_probe_calls returns. Handles
 * are the runtime's, closed here. Each argument array is this file's: its
 * release frees its buffers and counts itself; call_batch moves it.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <malloc.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "komira_udf_runtime.h"
#include "probe_json.h"

static int64_t mono(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static int32_t h_reserve(void* hd, int64_t b) {
  (void)hd, (void)b;
  return KOMIRA_UDF_OK;
}
static void h_release(void* hd, int64_t b) { (void)hd, (void)b; }
static int64_t h_now(void* hd) {
  (void)hd;
  return mono();
}
/* "heap full" warnings the proxy logged (many_calls) */
static int heap_full_logs;
static void h_log(void* hd, int32_t level, const char* m) {
  (void)hd, (void)level;
  if (strstr(m, "heap full") != NULL) heap_full_logs++;
}

struct eng {
  const komira_udf_runtime* t;
  komira_udf_rt* rt;
  komira_udf_host host;
  __typeof__(&komira_udf_runtime_init_v1) init; /* the library's init, for leaks_more */
};

static void take(komira_udf_error* e, char* into, size_t n) {
  snprintf(into, n, "%s", e->message ? e->message : "");
  if (e->release) e->release(e);
  e->release = NULL;
  e->message = NULL;
}

#define ERR_INIT {sizeof(komira_udf_error), 0, NULL, NULL, -1, -1, NULL, NULL}

/* ---- specs ---------------------------------------------------------------- */

static void no_release(struct ArrowSchema* s) { (void)s; }

struct spec_block {
  struct ArrowSchema kid[2], args, result;
  struct ArrowSchema* kids[2];
  komira_udf_spec spec;
};

/* A BUNDLE of `shape` over `nargs` arguments of format `fmt` to a result
 * of `fmt`. */
static void make_spec_as(struct spec_block* b, const char* entry, int nargs, int32_t shape, const char* fmt) {
  memset(b, 0, sizeof(*b));
  for (int i = 0; i < nargs; i++) {
    b->kid[i] = (struct ArrowSchema){fmt, i ? "y" : "x", NULL, ARROW_FLAG_NULLABLE, 0, NULL, NULL, no_release, NULL};
    b->kids[i] = &b->kid[i];
  }
  b->args = (struct ArrowSchema){"+s", "", NULL, 0, nargs, b->kids, NULL, no_release, NULL};
  b->result = (struct ArrowSchema){fmt, "", NULL, ARROW_FLAG_NULLABLE, 0, NULL, NULL, no_release, NULL};
  b->spec.struct_size = sizeof(b->spec);
  b->spec.shape = shape;
  b->spec.form = KOMIRA_UDF_FORM_BUNDLE;
  b->spec.entry = entry;
  b->spec.args = &b->args;
  b->spec.result = &b->result;
  b->spec.null_mode = KOMIRA_UDF_NULL_MANUAL;
  b->spec.stability = KOMIRA_UDF_IMMUTABLE;
}

/* A BUNDLE SCALAR over `nargs` int64 arguments to an int64 result. */
static void make_spec(struct spec_block* b, const char* entry, int nargs) {
  make_spec_as(b, entry, nargs, KOMIRA_UDF_SHAPE_SCALAR, "l");
}

/* ---- arguments ------------------------------------------------------------ */

struct col_spec {
  int64_t offset, length, null_count; /* null_count -1: not counted */
  int64_t base;                       /* value at physical position p: base + p */
  int64_t null_row;                   /* the logical row that is null, or -1 */
};

struct args_block {
  struct ArrowArray parent, child[2];
  struct ArrowArray* kids[2];
  const void* pbufs[1];
  const void* cbufs[2][2];
  int64_t* values[2];
  uint8_t* valid[2];
  int* released;
};

static void child_release(struct ArrowArray* a) { a->release = NULL; }

static void args_release(struct ArrowArray* a) {
  struct args_block* b = a->private_data;
  for (int i = 0; i < 2; i++) {
    if (b->child[i].release) b->child[i].release(&b->child[i]);
    free(b->values[i]);
    free(b->valid[i]);
  }
  (*b->released)++;
  a->release = NULL;
  free(b);
}

/* A struct of `n` children over `rows` rows, at offset 0. */
static void make_args(struct ArrowDeviceArray* d, int64_t rows, int n, const struct col_spec* cs, int* released) {
  struct args_block* b = calloc(1, sizeof(*b));
  b->released = released;
  for (int i = 0; i < n; i++) {
    int64_t phys = cs[i].offset + cs[i].length + 8;
    b->values[i] = calloc((size_t)phys, 8);
    for (int64_t p = 0; p < phys; p++) b->values[i][p] = cs[i].base + p;
    if (cs[i].null_row >= 0) {
      b->valid[i] = malloc((size_t)(phys + 7) / 8);
      memset(b->valid[i], 0xFF, (size_t)(phys + 7) / 8);
      int64_t p = cs[i].offset + cs[i].null_row;
      b->valid[i][p >> 3] &= (uint8_t)~(1u << (p & 7));
    }
    b->cbufs[i][0] = b->valid[i];
    b->cbufs[i][1] = b->values[i];
    b->child[i] = (struct ArrowArray){cs[i].length, cs[i].null_count, cs[i].offset, 2, 0, b->cbufs[i], NULL, NULL,
                                      child_release, b};
    b->kids[i] = &b->child[i];
  }
  b->parent = (struct ArrowArray){rows, 0, 0, 1, n, b->pbufs, b->kids, NULL, args_release, b};
  memset(d, 0, sizeof(*d));
  d->array = b->parent;
  d->device_id = -1;
  d->device_type = ARROW_DEVICE_CPU;
}

/* ---- a call --------------------------------------------------------------- */

struct canceller {
  volatile int32_t* flag;
  int64_t after_ns;
};

static void* cancel_later(void* p) {
  struct canceller* c = p;
  struct timespec ts = {c->after_ns / 1000000000LL, c->after_ns % 1000000000LL};
  nanosleep(&ts, NULL);
  __atomic_store_n(c->flag, 1, __ATOMIC_RELEASE);
  return NULL;
}

/* One call; the status, its reason, the output (released by the caller
 * when OK), and the ms it took. `cancel_ms` >= 0 sets the flag that long
 * into the call; `deadline_ms` > 0 sets a deadline that far away. */
static int32_t call(struct eng* e, komira_udf_instance* inst, struct ArrowDeviceArray* args,
                    struct ArrowDeviceArray* out, char* msg, size_t n, int64_t cancel_ms, int64_t deadline_ms,
                    int64_t* ms, size_t call_size) {
  volatile int32_t flag = 0;
  komira_udf_call c = {call_size, deadline_ms > 0 ? mono() + deadline_ms * 1000000LL : 0, 1, &flag};
  komira_udf_error err = ERR_INIT;
  pthread_t t;
  struct canceller cc = {&flag, cancel_ms * 1000000LL};
  int threaded = cancel_ms >= 0 && pthread_create(&t, NULL, cancel_later, &cc) == 0;
  memset(out, 0, sizeof(*out));
  int64_t t0 = mono();
  int32_t rc = e->t->call_batch(inst, &c, args, out, &err);
  *ms = (mono() - t0) / 1000000LL;
  if (threaded) pthread_join(t, NULL);
  msg[0] = 0;
  if (rc != KOMIRA_UDF_OK) take(&err, msg, n);
  return rc;
}

static int open_engine(struct eng* e, const char* lib, struct pj* j) {
  memset(e, 0, sizeof(*e));
  void* h = dlopen(lib, RTLD_NOW | RTLD_LOCAL);
  __typeof__(&komira_udf_runtime_init_v1) init =
      h ? (__typeof__(&komira_udf_runtime_init_v1))dlsym(h, "komira_udf_runtime_init_v1") : NULL;
  if (init == NULL) {
    pj_case(j, "open", -1, h ? "no komira_udf_runtime_init_v1" : dlerror(), 0);
    return 0;
  }
  e->host = (komira_udf_host){sizeof(komira_udf_host), KOMIRA_UDF_ABI_MAJOR, KOMIRA_UDF_ABI_MINOR, NULL,
                              h_reserve, h_release, h_now, h_log};
  komira_udf_error err = ERR_INIT;
  e->init = init;
  e->t = init(&e->host, &e->rt, &err);
  if (e->t == NULL) {
    char m[512];
    take(&err, m, sizeof(m));
    pj_case(j, "open", -1, m, 0);
    return 0;
  }
  return 1;
}

/* load + open_context + open_instance, or a failed case named `name`. */
static int setup_as(struct eng* e, struct pj* j, const char* name, const char* entry, int nargs, int32_t shape,
                    const char* fmt, komira_udf_udf** u, komira_udf_context** c, komira_udf_instance** i) {
  struct spec_block sb;
  make_spec_as(&sb, entry, nargs, shape, fmt);
  komira_udf_error err = ERR_INIT;
  char m[512];
  int32_t rc = KOMIRA_UDF_OK;
  if (u != NULL && *u == NULL) rc = e->t->load(e->rt, &sb.spec, u, &err);
  if (rc == KOMIRA_UDF_OK && c != NULL && *c == NULL) rc = e->t->open_context(e->rt, 0, c, &err);
  if (rc == KOMIRA_UDF_OK) rc = e->t->open_instance(*c, *u, i, &err);
  if (rc != KOMIRA_UDF_OK) {
    take(&err, m, sizeof(m));
    if (j != NULL) pj_case(j, name, rc, m, -1);
    return 0;
  }
  return 1;
}

static int setup(struct eng* e, struct pj* j, const char* name, const char* entry, int nargs, komira_udf_udf** u,
                 komira_udf_context** c, komira_udf_instance** i) {
  return setup_as(e, j, name, entry, nargs, KOMIRA_UDF_SHAPE_SCALAR, "l", u, c, i);
}

/* ---- the groups ------------------------------------------------------------ */

static int64_t pid_in(struct eng* e, komira_udf_context* c);

/* pair(x, y) = x * 1000 + y over 12 rows: x from offset 13 (null at row 2,
 * its null count given), y from offset 3 (null at row 5, null count -1). */
static void two_args_case(struct eng* e, struct pj* j, const char* name, komira_udf_instance* inst) {
  const struct col_spec cs[2] = {{13, 12, 1, 0, 2}, {3, 12, -1, 500, 5}};
  int released = 0;
  struct ArrowDeviceArray args, out;
  make_args(&args, 12, 2, cs, &released);
  char m[512];
  int64_t ms;
  int32_t rc = call(e, inst, &args, &out, m, sizeof(m), -1, 0, &ms, sizeof(komira_udf_call));
  int64_t bad = 0;
  if (rc == KOMIRA_UDF_OK) {
    const struct ArrowArray* o = &out.array;
    const int64_t* v = (const int64_t*)o->buffers[1];
    const uint8_t* b = o->buffers[0];
    bad += o->length != 12 || o->null_count != 2 || b == NULL;
    for (int64_t r = 0; b != NULL && r < 12 && o->length == 12; r++) {
      int64_t p = o->offset + r;
      int valid = (b[p >> 3] >> (p & 7)) & 1;
      int want_valid = r != 2 && r != 5;
      bad += valid != want_valid;
      if (valid && want_valid) bad += v[p] != (13 + r) * 1000 + (500 + 3 + r);
    }
    out.array.release(&out.array);
    snprintf(m, sizeof(m), "OK");
  }
  pj_case(j, name, rc, m, bad + (released != 1) * 1000);
}

static void group_two_args(struct eng* e, struct pj* j) {
  komira_udf_udf* u = NULL;
  komira_udf_context* c = NULL;
  komira_udf_instance* i = NULL;
  if (!setup(e, j, "two_args", "udf_worker_fixtures:pair", 2, &u, &c, &i)) return;
  two_args_case(e, j, "two_args", i);
  two_args_case(e, j, "two_args_again", i); /* a second batch: a slot reused or a new one */
  e->t->close_instance(i);
  e->t->close_context(c);
  e->t->unload(u);
}

static void group_late_load(struct eng* e, struct pj* j) {
  komira_udf_udf *first = NULL, *late = NULL;
  komira_udf_context *a = NULL, *b = NULL;
  komira_udf_instance *ia = NULL, *la = NULL, *lb = NULL;
  if (!setup(e, j, "before", "udf_fixtures:add_strict", 2, &first, &a, &ia)) return;
  const struct col_spec cs[2] = {{0, 4, 0, 10, -1}, {0, 4, 0, 20, -1}};
  struct ArrowDeviceArray args, out;
  char m[512];
  int64_t ms;
  int released = 0;
  make_args(&args, 4, 2, cs, &released);
  int32_t rc = call(e, ia, &args, &out, m, sizeof(m), -1, 0, &ms, sizeof(komira_udf_call));
  if (rc == KOMIRA_UDF_OK) out.array.release(&out.array);
  pj_case(j, "before", rc, rc ? m : "OK", 0);
  /* Loaded after `a` was opened (in the zygote build: after its fork). */
  const char* names[2] = {"late_in_open_context", "late_in_new_context"};
  if (setup(e, j, names[0], "udf_worker_fixtures:pair", 2, &late, &a, &la) &&
      setup(e, j, names[1], "udf_worker_fixtures:pair", 2, &late, &b, &lb)) {
    two_args_case(e, j, names[0], la);
    two_args_case(e, j, names[1], lb);
  }
  /* worker_pid loaded, called, closed and unloaded in `a`; then pair. */
  komira_udf_udf* again = NULL;
  komira_udf_instance* ag = NULL;
  int64_t pid = pid_in(e, a);
  if (pid <= 0) pj_case(j, "after_unload", -1, "worker_pid did not answer", 0);
  else if (setup(e, j, "after_unload", "udf_worker_fixtures:pair", 2, &again, &a, &ag))
    two_args_case(e, j, "after_unload", ag);
  if (ag) e->t->close_instance(ag);
  if (again) e->t->unload(again);
  if (lb) e->t->close_instance(lb);
  if (la) e->t->close_instance(la);
  e->t->close_instance(ia);
  if (b) e->t->close_context(b);
  e->t->close_context(a);
  if (late) e->t->unload(late);
  e->t->unload(first);
}

/* One refusal: what call_batch said, and how often it released `args`. */
static void refuse(struct eng* e, struct pj* j, komira_udf_instance* inst, const char* name, int64_t rows, int n,
                   const struct col_spec* cs, void (*bend)(struct ArrowDeviceArray*), size_t call_size) {
  int released = 0;
  struct ArrowDeviceArray args, out;
  make_args(&args, rows, n, cs, &released);
  if (bend) bend(&args);
  char m[512];
  int64_t ms;
  int32_t rc = call(e, inst, &args, &out, m, sizeof(m), -1, 0, &ms, call_size);
  if (rc == KOMIRA_UDF_OK && out.array.release) out.array.release(&out.array);
  int moved = args.array.release == NULL;
  if (!moved) args.array.release(&args.array);
  pj_case(j, name, rc, m, moved ? released : -1); /* moved and released once: 1 */
}

static void bend_struct_offset(struct ArrowDeviceArray* d) { d->array.offset = 1; }
static void bend_negative_length(struct ArrowDeviceArray* d) { d->array.length = -1; }
static void bend_three_buffers(struct ArrowDeviceArray* d) { d->array.children[1]->n_buffers = 3; }
static void bend_no_values(struct ArrowDeviceArray* d) { ((const void**)d->array.children[0]->buffers)[1] = NULL; }
static void bend_negative_offset(struct ArrowDeviceArray* d) { d->array.children[1]->offset = -1; }
static void bend_device(struct ArrowDeviceArray* d) { d->device_type = ARROW_DEVICE_CUDA; }

static void group_refusals(struct eng* e, struct pj* j) {
  komira_udf_udf* u = NULL;
  komira_udf_context* c = NULL;
  komira_udf_instance* i = NULL;
  if (!setup(e, j, "refusals", "udf_worker_fixtures:pair", 2, &u, &c, &i)) return;
  const struct col_spec ok2[2] = {{0, 8, 0, 0, -1}, {0, 8, 0, 0, -1}};
  const struct col_spec short_y[2] = {{0, 8, 0, 0, -1}, {2, 7, 0, 0, -1}};
  size_t cs = sizeof(komira_udf_call);
  refuse(e, j, i, "short_child", 8, 2, short_y, NULL, cs);
  refuse(e, j, i, "child_count", 8, 1, ok2, NULL, cs);
  refuse(e, j, i, "struct_offset", 8, 2, ok2, bend_struct_offset, cs);
  refuse(e, j, i, "negative_length", 8, 2, ok2, bend_negative_length, cs);
  refuse(e, j, i, "three_buffers", 8, 2, ok2, bend_three_buffers, cs);
  refuse(e, j, i, "no_values", 8, 2, ok2, bend_no_values, cs);
  refuse(e, j, i, "negative_offset", 8, 2, ok2, bend_negative_offset, cs);
  refuse(e, j, i, "not_cpu", 8, 2, ok2, bend_device, cs);
  refuse(e, j, i, "call_struct_size", 8, 2, ok2, NULL, sizeof(size_t));
  two_args_case(e, j, "after_refusals", i);
  e->t->close_instance(i);
  e->t->close_context(c);
  e->t->unload(u);
}

/* The worker's pid, from a call of worker_pid in the context. */
static int64_t pid_in(struct eng* e, komira_udf_context* c) {
  komira_udf_udf* u = NULL;
  komira_udf_instance* i = NULL;
  if (!setup(e, NULL, "", "udf_worker_fixtures:worker_pid", 1, &u, &c, &i)) return -1;
  const struct col_spec cs[1] = {{0, 1, 0, 0, -1}};
  int released = 0;
  struct ArrowDeviceArray args, out;
  make_args(&args, 1, 1, cs, &released);
  char m[512];
  int64_t ms, pid = -1;
  if (call(e, i, &args, &out, m, sizeof(m), -1, 0, &ms, sizeof(komira_udf_call)) == KOMIRA_UDF_OK) {
    pid = ((const int64_t*)out.array.buffers[1])[out.array.offset];
    out.array.release(&out.array);
  }
  e->t->close_instance(i);
  e->t->unload(u);
  return pid;
}

/* Whether `pid` has ended (a zombie not yet reaped counts: the engine reaps
 * its own children at close_context), polling for up to `ms`. */
static int ended_within(int64_t pid, int ms) {
  char path[64], st[512];
  snprintf(path, sizeof(path), "/proc/%lld/stat", (long long)pid);
  for (int i = 0; i <= ms; i++) {
    FILE* f = fopen(path, "r");
    if (f == NULL) return 1;
    size_t n = fread(st, 1, sizeof(st) - 1, f);
    fclose(f);
    st[n] = 0;
    const char* rp = strrchr(st, ')'); /* the state follows the command name */
    if (rp != NULL && (rp[2] == 'Z' || rp[2] == 'X')) return 1;
    usleep(1000);
  }
  return 0;
}

/* sleep_deaf(20), cancelled at 300 ms or past a deadline 300 ms away: the
 * status, the reason and the ms (value); then whether the context is lost
 * and whether its worker is gone after close_context. */
static void kill_case(struct eng* e, struct pj* j, const char* name, int by_cancel) {
  komira_udf_udf* u = NULL;
  komira_udf_context* c = NULL;
  komira_udf_instance* i = NULL;
  komira_udf_error err = ERR_INIT;
  char m[512];
  if (e->t->open_context(e->rt, 0, &c, &err) != KOMIRA_UDF_OK) {
    take(&err, m, sizeof(m));
    pj_case(j, name, -1, m, -1);
    return;
  }
  int64_t pid = pid_in(e, c);
  if (!setup(e, j, name, "udf_worker_fixtures:sleep_deaf", 1, &u, &c, &i)) {
    e->t->close_context(c);
    return;
  }
  const struct col_spec cs[1] = {{0, 1, 0, 20, -1}};
  int released = 0;
  struct ArrowDeviceArray args, out;
  make_args(&args, 1, 1, cs, &released);
  int64_t ms;
  int32_t rc = call(e, i, &args, &out, m, sizeof(m), by_cancel ? 300 : -1, by_cancel ? 0 : 300, &ms,
                    sizeof(komira_udf_call));
  if (rc == KOMIRA_UDF_OK) out.array.release(&out.array);
  pj_case(j, name, rc, m, ms);
  /* Killed by the time call_batch returned (a second or so for the signal
   * to land), not later by close_context. */
  char key0[64];
  snprintf(key0, sizeof(key0), "%s_ended_at_return", name);
  int ended = pid > 0 && ended_within(pid, 1000);
  pj_case(j, key0, pid > 0 ? 0 : -1, ended ? "ended" : "running", ended);
  /* The next call on the same instance. */
  char m2[512], key[64];
  make_args(&args, 1, 1, cs, &released);
  int32_t rc2 = call(e, i, &args, &out, m2, sizeof(m2), -1, 0, &ms, sizeof(komira_udf_call));
  if (rc2 == KOMIRA_UDF_OK) out.array.release(&out.array);
  snprintf(key, sizeof(key), "%s_next", name);
  pj_case(j, key, rc2, m2, released);
  e->t->close_instance(i);
  e->t->close_context(c);
  e->t->unload(u);
  snprintf(key, sizeof(key), "%s_worker_gone", name);
  int alive = pid > 0 && kill((pid_t)pid, 0) == 0;
  pj_case(j, key, pid > 0 ? 0 : -1, alive ? "alive" : "gone", alive);
}

static void group_kills(struct eng* e, struct pj* j) {
  kill_case(e, j, "cancel_kill", 1);
  kill_case(e, j, "deadline_kill", 0);
  /* The runtime still serves: a new context after both kills. */
  group_two_args(e, j);
}

/* ---- the groups the mutation sweep asked for ------------------------------ */

/* A SCALAR call of slow_loop (100 ms a row) over 20 rows, cancelled 150 ms
 * in; then, in the same context, pair on a second instance and slow_loop
 * again on one row: both answer (a cancelled call leaves the context and
 * its worker serving: the worker's cancel flag cleared, the CANCEL kept
 * for the record not taken as a request). */
static void group_after_cancel(struct eng* e, struct pj* j) {
  komira_udf_udf *slow = NULL, *pr = NULL;
  komira_udf_context* c = NULL;
  komira_udf_instance *is = NULL, *ip = NULL;
  if (!setup(e, j, "cancelled", "udf_fixtures:slow_loop", 1, &slow, &c, &is)) return;
  const struct col_spec cs[1] = {{0, 20, 0, 0, -1}};
  int released = 0;
  struct ArrowDeviceArray args, out;
  char m[512];
  int64_t ms;
  make_args(&args, 20, 1, cs, &released);
  int32_t rc = call(e, is, &args, &out, m, sizeof(m), 150, 0, &ms, sizeof(komira_udf_call));
  if (rc == KOMIRA_UDF_OK) out.array.release(&out.array);
  pj_case(j, "cancelled", rc, m, ms);
  if (setup(e, j, "after_cancel_pair", "udf_worker_fixtures:pair", 2, &pr, &c, &ip))
    two_args_case(e, j, "after_cancel_pair", ip);
  const struct col_spec one[1] = {{0, 1, 0, 5, -1}};
  make_args(&args, 1, 1, one, &released);
  rc = call(e, is, &args, &out, m, sizeof(m), -1, 0, &ms, sizeof(komira_udf_call));
  int64_t got = -1;
  if (rc == KOMIRA_UDF_OK) {
    got = ((const int64_t*)out.array.buffers[1])[out.array.offset];
    out.array.release(&out.array);
    snprintf(m, sizeof(m), "OK");
  }
  pj_case(j, "after_cancel_same", rc, m, got);
  if (ip) e->t->close_instance(ip);
  e->t->close_instance(is);
  e->t->close_context(c);
  if (pr) e->t->unload(pr);
  e->t->unload(slow);
}

/* 1 + 2x over 4 rows from `base` through `inst`: the number of wrong
 * values (0), or -1 when the call failed. */
static int64_t double_case(struct eng* e, komira_udf_instance* inst, int64_t base, char* m, size_t n) {
  const struct col_spec cs[1] = {{0, 4, 0, base, -1}};
  int released = 0;
  struct ArrowDeviceArray args, out;
  int64_t ms;
  make_args(&args, 4, 1, cs, &released);
  if (call(e, inst, &args, &out, m, n, -1, 0, &ms, sizeof(komira_udf_call)) != KOMIRA_UDF_OK) return -1;
  int64_t wrong = out.array.length != 4;
  for (int r = 0; r < 4 && !wrong; r++) wrong += ((const int64_t*)out.array.buffers[1])[out.array.offset + r] != 2 * (base + r);
  out.array.release(&out.array);
  return wrong;
}

/* Two UDFs of different arity loaded before the context is opened (in the
 * zygote build: both before the fork), each with an instance in the one
 * context, called in turn: each instance runs its own UDF with its own
 * schema. */
static void group_two_udfs(struct eng* e, struct pj* j) {
  komira_udf_udf *pa = NULL, *db = NULL;
  komira_udf_context* c = NULL;
  komira_udf_instance *ia = NULL, *ib = NULL;
  struct spec_block sb;
  komira_udf_error err = ERR_INIT;
  char m[512];
  make_spec(&sb, "udf_worker_fixtures:pair", 2);
  int32_t rc = e->t->load(e->rt, &sb.spec, &pa, &err);
  make_spec(&sb, "udf_fixtures:double", 1);
  if (rc == KOMIRA_UDF_OK) rc = e->t->load(e->rt, &sb.spec, &db, &err);
  if (rc != KOMIRA_UDF_OK) {
    take(&err, m, sizeof(m));
    pj_case(j, "two_udfs", rc, m, -1);
    return;
  }
  if (setup(e, j, "two_udfs", "", 2, &pa, &c, &ia) && setup(e, j, "two_udfs", "", 1, &db, &c, &ib)) {
    two_args_case(e, j, "two_udfs_pair", ia);
    int64_t w = double_case(e, ib, 40, m, sizeof(m));
    pj_case(j, "two_udfs_double", w < 0 ? -1 : 0, w < 0 ? m : "OK", w);
    two_args_case(e, j, "two_udfs_pair_again", ia);
  }
  if (ib) e->t->close_instance(ib);
  if (ia) e->t->close_instance(ia);
  if (c) e->t->close_context(c);
  e->t->unload(db);
  e->t->unload(pa);
}

/* Eight rounds of 40 calls of keep_view (each keeps a view of its input,
 * so the slot it came in stays held) and one of drop_views (all let go),
 * in one worker: every call answers and the heap never fills, since each
 * round's 40 slots come back through the release ring with their own ids
 * (a worker that released them under another id would leak 40 a round,
 * and the second round would find no slot). */
static void group_many_calls(struct eng* e, struct pj* j) {
  komira_udf_udf *uk = NULL, *ud = NULL;
  komira_udf_context* c = NULL;
  komira_udf_instance *ik = NULL, *id = NULL;
  if (!setup_as(e, j, "many_calls", "udf_np:keep_view", 1, KOMIRA_UDF_SHAPE_MAP_BATCHES_COLUMN, "g", &uk, &c, &ik) ||
      !setup_as(e, j, "many_calls", "udf_np:drop_views", 1, KOMIRA_UDF_SHAPE_MAP_BATCHES_COLUMN, "g", &ud, &c, &id))
    return;
  heap_full_logs = 0;
  int failed = 0;
  char m[512] = "OK";
  for (int k = 0; k < 8 * 41; k++) {
    const struct col_spec cs[1] = {{0, 16, 0, k, -1}};
    int released = 0;
    struct ArrowDeviceArray args, out;
    int64_t ms;
    make_args(&args, 16, 1, cs, &released);
    if (call(e, k % 41 == 40 ? id : ik, &args, &out, m, sizeof(m), -1, 0, &ms, sizeof(komira_udf_call)) ==
        KOMIRA_UDF_OK)
      out.array.release(&out.array);
    else
      failed++;
  }
  pj_case(j, "many_calls", failed, failed ? m : "OK", heap_full_logs);
  e->t->close_instance(id);
  e->t->close_instance(ik);
  e->t->close_context(c);
  e->t->unload(ud);
  e->t->unload(uk);
}

/* Nulls at the bitmap's edges: null_on_zero over 9 rows whose last is 0
 * (the output bitmap's second byte holds one bit), and none_on_zero_list,
 * a column result, over 8 rows with row 3 zero (a whole bitmap byte). The
 * value is wrong values or bits. */
static void nulls_case(struct eng* e, struct pj* j, const char* name, const char* entry, int32_t shape, int64_t rows,
                       int64_t zero_row) {
  komira_udf_udf* u = NULL;
  komira_udf_context* c = NULL;
  komira_udf_instance* i = NULL;
  if (!setup_as(e, j, name, entry, 1, shape, "l", &u, &c, &i)) return;
  const struct col_spec cs[1] = {{0, rows, 0, -zero_row, -1}};
  int released = 0;
  struct ArrowDeviceArray args, out;
  char m[512];
  int64_t ms;
  make_args(&args, rows, 1, cs, &released);
  int32_t rc = call(e, i, &args, &out, m, sizeof(m), -1, 0, &ms, sizeof(komira_udf_call));
  int64_t wrong = 0;
  if (rc == KOMIRA_UDF_OK) {
    const struct ArrowArray* o = &out.array;
    const uint8_t* b = o->buffers[0];
    const int64_t* v = o->buffers[1];
    wrong += o->length != rows || o->null_count != 1 || b == NULL;
    for (int64_t r = 0; b != NULL && r < rows && o->length == rows; r++) {
      int64_t p = o->offset + r;
      int valid = (b[p >> 3] >> (p & 7)) & 1;
      int64_t x = r - zero_row;
      wrong += valid != (r != zero_row);
      if (valid && r != zero_row) wrong += v[p] != (shape == KOMIRA_UDF_SHAPE_SCALAR ? 2 * x : x);
    }
    o->release(&out.array);
    snprintf(m, sizeof(m), "OK");
  }
  pj_case(j, name, rc, m, wrong);
  e->t->close_instance(i);
  e->t->close_context(c);
  e->t->unload(u);
}

/* A user error's trace: raise_type_error's ERR_RAISED carries the
 * Python traceback, apart from its message. */
static void group_trace(struct eng* e, struct pj* j) {
  komira_udf_udf* u = NULL;
  komira_udf_context* c = NULL;
  komira_udf_instance* i = NULL;
  if (!setup(e, j, "trace", "udf_fixtures:raise_type_error", 1, &u, &c, &i)) return;
  const struct col_spec cs[1] = {{0, 2, 0, 0, -1}};
  int released = 0;
  struct ArrowDeviceArray args, out;
  make_args(&args, 2, 1, cs, &released);
  volatile int32_t flag = 0;
  komira_udf_call call_ = {sizeof(call_), 0, 1, &flag};
  komira_udf_error err = ERR_INIT;
  memset(&out, 0, sizeof(out));
  int32_t rc = e->t->call_batch(i, &call_, &args, &out, &err);
  char m[600];
  const char* tr = err.user_trace ? err.user_trace : "";
  int has_tb = strstr(tr, "Traceback") != NULL && strstr(tr, "raise_type_error: always") != NULL;
  snprintf(m, sizeof(m), "%s", err.message ? err.message : "");
  if (err.release) err.release(&err);
  if (rc == KOMIRA_UDF_OK) out.array.release(&out.array);
  pj_case(j, "trace", rc, m, has_tb);
  e->t->close_instance(i);
  e->t->close_context(c);
  e->t->unload(u);
}

/* np_int_out (x * 2) over 1,200,000 rows: a 9.6 MB result, over the 8 MiB
 * worker-to-engine heap, so it comes back inline. */
static void group_big(struct eng* e, struct pj* j) {
  komira_udf_udf* u = NULL;
  komira_udf_context* c = NULL;
  komira_udf_instance* i = NULL;
  if (!setup_as(e, j, "big", "udf_np:np_int_out", 1, KOMIRA_UDF_SHAPE_MAP_BATCHES_COLUMN, "l", &u, &c, &i)) return;
  const int64_t N = 1200000;
  const struct col_spec cs[1] = {{0, N, 0, 0, -1}};
  int released = 0;
  struct ArrowDeviceArray args, out;
  char m[512];
  int64_t ms;
  make_args(&args, N, 1, cs, &released);
  int32_t rc = call(e, i, &args, &out, m, sizeof(m), -1, 0, &ms, sizeof(komira_udf_call));
  int64_t wrong = 0;
  if (rc == KOMIRA_UDF_OK) {
    const int64_t* v = out.array.buffers[1];
    wrong += out.array.length != N;
    for (int64_t r = 0; r < N && !wrong; r += 997) wrong += v[out.array.offset + r] != 2 * r;
    wrong += v[out.array.offset + N - 1] != 2 * (N - 1);
    out.array.release(&out.array);
    snprintf(m, sizeof(m), "OK");
  }
  pj_case(j, "big", rc, m, wrong);
  e->t->close_instance(i);
  e->t->close_context(c);
  e->t->unload(u);
}

/* double over 1000 rows with a deadline a minute away: the worker reads the
 * host clock after every row (1000 reads), each a CLOCK message the engine
 * answers at once. The value is the call's ms. An engine that answers a read
 * only when its poll times out spends at least 1 ms a read: over 1000 ms. */
static void group_clock_time(struct eng* e, struct pj* j) {
  komira_udf_udf* u = NULL;
  komira_udf_context* c = NULL;
  komira_udf_instance* i = NULL;
  if (!setup(e, j, "clock_time", "udf_fixtures:double", 1, &u, &c, &i)) return;
  const struct col_spec cs[1] = {{0, 1000, 0, 0, -1}};
  int released = 0;
  struct ArrowDeviceArray args, out;
  char m[512];
  int64_t ms;
  make_args(&args, 1000, 1, cs, &released);
  int32_t rc = call(e, i, &args, &out, m, sizeof(m), -1, 60000, &ms, sizeof(komira_udf_call));
  if (rc == KOMIRA_UDF_OK) {
    out.array.release(&out.array);
    snprintf(m, sizeof(m), "OK");
  }
  pj_case(j, "clock_time", rc, m, ms);
  e->t->close_instance(i);
  e->t->close_context(c);
  e->t->unload(u);
}

/* The engine's heap (glibc's main arena) around 200 rounds of: a refused
 * validate whose error is released; load and unload; open_instance and
 * close_instance. Each round frees what it made, so the arena's use stays
 * within a few blocks (the value: bytes grown per kind, as a * 1000000 +
 * b * 1000 + c, each capped at 999). */
static size_t heap_used(void) { return mallinfo2().uordblks; }

static void group_leaks(struct eng* e, struct pj* j) {
  komira_udf_udf* u = NULL;
  komira_udf_context* c = NULL;
  komira_udf_instance* i = NULL;
  if (!setup(e, j, "leaks", "udf_fixtures:double", 1, &u, &c, &i)) return;
  struct spec_block sb;
  make_spec(&sb, "udf_fixtures:double", 1);
  komira_udf_spec bad = sb.spec;
  bad.struct_size = 8;
  int64_t grown[3];
  for (int kind = 0; kind < 3; kind++) {
    size_t before = 0;
    for (int k = 0; k < 220; k++) {
      if (k == 20) before = heap_used(); /* after a warm-up */
      komira_udf_error err = ERR_INIT;
      if (kind == 0) {
        (void)e->t->validate(e->rt, &bad, &err);
      } else if (kind == 1) {
        komira_udf_udf* v = NULL;
        if (e->t->load(e->rt, &sb.spec, &v, &err) == KOMIRA_UDF_OK) e->t->unload(v);
      } else {
        komira_udf_instance* x = NULL;
        if (e->t->open_instance(c, u, &x, &err) == KOMIRA_UDF_OK) e->t->close_instance(x);
      }
      if (err.release) err.release(&err);
    }
    int64_t g = (int64_t)heap_used() - (int64_t)before;
    grown[kind] = g < 0 ? 0 : g > 999 ? 999 : g;
  }
  pj_case(j, "leaks", 0, "", grown[0] * 1000000 + grown[1] * 1000 + grown[2]);
  e->t->close_instance(i);
  e->t->close_context(c);
  e->t->unload(u);
}

/* The engine's heap around rounds the leaks group does not make, one case
 * each (the value: bytes grown after a warm-up, capped at 99999):
 *   leak_load_refused a load the zygote refuses (the module fails at import:
 *                     the udf and its LOAD body freed on the way out);
 *   leak_validate_ok  a validate the worker takes (the spec's body built and
 *                     freed);
 *   leak_raised_call  a call whose user code raises (an ERROR reply with a
 *                     message and a trace, the error released);
 *   leak_context      open_context and close_context (a fork, its reply and
 *                     warning, the context's channel and struct);
 *   leak_init         init and shutdown (DESCRIBE's reply and strings, the
 *                     zygote's channel, the rt struct). */
static void leak_case(struct pj* j, const char* name, size_t before) {
  int64_t g = (int64_t)heap_used() - (int64_t)before;
  pj_case(j, name, 0, "", g < 0 ? 0 : g > 99999 ? 99999 : g);
}

static void group_leaks_more(struct eng* e, struct pj* j) {
  struct spec_block sb;
  make_spec(&sb, "udf_fixtures:double", 1);
  size_t before = 0;
  for (int k = 0; k < 220; k++) {
    if (k == 20) before = heap_used();
    komira_udf_error err = ERR_INIT;
    (void)e->t->validate(e->rt, &sb.spec, &err);
    if (err.release) err.release(&err);
  }
  leak_case(j, "leak_validate_ok", before);
  struct spec_block bad_import;
  make_spec(&bad_import, "udf_worker_badimport:f", 1);
  for (int k = 0; k < 220; k++) {
    if (k == 20) before = heap_used();
    komira_udf_udf* v = NULL;
    komira_udf_error err = ERR_INIT;
    if (e->t->load(e->rt, &bad_import.spec, &v, &err) == KOMIRA_UDF_OK) e->t->unload(v);
    if (err.release) err.release(&err);
  }
  leak_case(j, "leak_load_refused", before);


  komira_udf_udf* u = NULL;
  komira_udf_context* c = NULL;
  komira_udf_instance* i = NULL;
  if (setup(e, j, "leak_raised_call", "udf_fixtures:raise_type_error", 1, &u, &c, &i)) {
    const struct col_spec cs[1] = {{0, 2, 0, 0, -1}};
    for (int k = 0; k < 220; k++) {
      if (k == 20) before = heap_used();
      int released = 0;
      struct ArrowDeviceArray args, out;
      make_args(&args, 2, 1, cs, &released);
      char m[300];
      int64_t ms;
      if (call(e, i, &args, &out, m, sizeof(m), -1, 0, &ms, sizeof(komira_udf_call)) == KOMIRA_UDF_OK)
        out.array.release(&out.array);
    }
    leak_case(j, "leak_raised_call", before);
    e->t->close_instance(i);
    e->t->unload(u);
  }

  for (int k = 0; k < 60; k++) {
    if (k == 10) before = heap_used();
    komira_udf_context* x = NULL;
    komira_udf_error err = ERR_INIT;
    if (e->t->open_context(e->rt, 0, &x, &err) == KOMIRA_UDF_OK) e->t->close_context(x);
    if (err.release) err.release(&err);
  }
  if (c) e->t->close_context(c);
  leak_case(j, "leak_context", before);

  for (int k = 0; k < 30; k++) {
    if (k == 5) before = heap_used();
    komira_udf_rt* rt = NULL;
    komira_udf_error err = ERR_INIT;
    const komira_udf_runtime* t = e->init(&e->host, &rt, &err);
    if (t != NULL) t->shutdown(rt);
    if (err.release) err.release(&err);
  }
  leak_case(j, "leak_init", before);
}

/* The library opened by its absolute path: init finds its own directory
 * from it (no working directory in front), and a call answers. */
static void group_abs_path(struct pj* j, const char* lib) {
  char real[4096];
  if (realpath(lib, real) == NULL) {
    pj_case(j, "abs_path", -1, "the library path does not resolve", 0);
    return;
  }
  struct eng e2;
  if (!open_engine(&e2, real, j)) return;
  group_two_args(&e2, j);
  e2.t->shutdown(e2.rt);
}

static int more_group(struct eng* e, struct pj* j, const char* group) {
  if (strcmp(group, "after_cancel") == 0) group_after_cancel(e, j);
  else if (strcmp(group, "two_udfs") == 0) group_two_udfs(e, j);
  else if (strcmp(group, "many_calls") == 0) group_many_calls(e, j);
  else if (strcmp(group, "nulls") == 0) {
    nulls_case(e, j, "rows_9_last_null", "udf_fixtures:null_on_zero", KOMIRA_UDF_SHAPE_SCALAR, 9, 8);
    nulls_case(e, j, "column_8_rows_null", "udf_fixtures:none_on_zero_list", KOMIRA_UDF_SHAPE_MAP_BATCHES_COLUMN, 8, 3);
  } else if (strcmp(group, "trace") == 0) group_trace(e, j);
  else if (strcmp(group, "big") == 0) group_big(e, j);
  else if (strcmp(group, "clock_time") == 0) group_clock_time(e, j);
  else if (strcmp(group, "leaks") == 0) group_leaks(e, j);
  else if (strcmp(group, "leaks_more") == 0) group_leaks_more(e, j);
  else return 0;
  return 1;
}

/* `lib`: a runtime library; `group`: two_args, late_load, refusals, kills,
 * after_cancel, two_udfs, many_calls, nulls, trace, big, clock_time, leaks,
 * leaks_more or
 * abs_path. */
char* kpw_probe_calls(const char* lib, const char* group) {
  struct pj j = {0};
  pj_open(&j);
  struct eng e;
  if (strcmp(group, "abs_path") == 0) {
    /* the first dlopen of this library in the process, by absolute path
     * (glibc keeps the name a library was first loaded by) */
    group_abs_path(&j, lib);
  } else if (open_engine(&e, lib, &j)) {
    if (strcmp(group, "two_args") == 0) group_two_args(&e, &j);
    else if (strcmp(group, "late_load") == 0) group_late_load(&e, &j);
    else if (strcmp(group, "refusals") == 0) group_refusals(&e, &j);
    else if (strcmp(group, "kills") == 0) group_kills(&e, &j);
    else if (!more_group(&e, &j, group)) pj_case(&j, "group", -1, "no such group", 0);
    e.t->shutdown(e.rt);
  }
  return pj_close(&j);
}
