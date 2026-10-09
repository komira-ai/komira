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
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
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
static void h_log(void* hd, int32_t level, const char* m) { (void)hd, (void)level, (void)m; }

struct eng {
  const komira_udf_runtime* t;
  komira_udf_rt* rt;
  komira_udf_host host;
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

/* A BUNDLE SCALAR over `nargs` int64 arguments to an int64 result. */
static void make_spec(struct spec_block* b, const char* entry, int nargs) {
  memset(b, 0, sizeof(*b));
  for (int i = 0; i < nargs; i++) {
    b->kid[i] = (struct ArrowSchema){"l", i ? "y" : "x", NULL, ARROW_FLAG_NULLABLE, 0, NULL, NULL, no_release, NULL};
    b->kids[i] = &b->kid[i];
  }
  b->args = (struct ArrowSchema){"+s", "", NULL, 0, nargs, b->kids, NULL, no_release, NULL};
  b->result = (struct ArrowSchema){"l", "", NULL, ARROW_FLAG_NULLABLE, 0, NULL, NULL, no_release, NULL};
  b->spec.struct_size = sizeof(b->spec);
  b->spec.shape = KOMIRA_UDF_SHAPE_SCALAR;
  b->spec.form = KOMIRA_UDF_FORM_BUNDLE;
  b->spec.entry = entry;
  b->spec.args = &b->args;
  b->spec.result = &b->result;
  b->spec.null_mode = KOMIRA_UDF_NULL_MANUAL;
  b->spec.stability = KOMIRA_UDF_IMMUTABLE;
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
static int setup(struct eng* e, struct pj* j, const char* name, const char* entry, int nargs, komira_udf_udf** u,
                 komira_udf_context** c, komira_udf_instance** i) {
  struct spec_block sb;
  make_spec(&sb, entry, nargs);
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

/* `lib`: a runtime library; `group`: two_args, late_load, refusals or kills. */
char* kpw_probe_calls(const char* lib, const char* group) {
  struct pj j = {0};
  pj_open(&j);
  struct eng e;
  if (open_engine(&e, lib, &j)) {
    if (strcmp(group, "two_args") == 0) group_two_args(&e, &j);
    else if (strcmp(group, "late_load") == 0) group_late_load(&e, &j);
    else if (strcmp(group, "refusals") == 0) group_refusals(&e, &j);
    else if (strcmp(group, "kills") == 0) group_kills(&e, &j);
    else pj_case(&j, "group", -1, "no such group", 0);
    e.t->shutdown(e.rt);
  }
  return pj_close(&j);
}
