/*
 * The harness's timed call loops: call_batch of a runtime's instance, over
 * and over, timed with CLOCK_MONOTONIC around each call only (the timer sits
 * inside the engine loop, around the crossing and the runtime's work), on
 * one thread or on several at once. Written in C so that no Mojo code of the
 * harness runs on the loop threads: every array exported here and its
 * release are C; only the runtime's own code runs there.
 *
 * Each call gets a fresh struct array of `rows` rows with one non-null
 * column, int64 values i or float64 values i / 2, whose buffers all calls
 * share (the export costs one malloc). With `verify` set, every output is
 * read back: its length must be `rows`, and row i must equal a * x_i + b
 * (exactly for int64; within 1e-9 relative for float64), or the call counts
 * as a mismatch. A failed call counts as a failure. The shared values are
 * freed only when every exported array was released.
 *
 * Several threads: each thread loops on its own instance, each instance in
 * its own context (the caller opens them), after a common start; the wall
 * time runs from the start to the last thread's end, and the CPU time of the
 * process (getrusage, user and system) is read around the same span.
 */
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>

#include "komira_udf_runtime.h"

struct loop {
  const komira_udf_runtime* t;
  komira_udf_instance* inst;
  int64_t rows;
  int32_t is_float;
  double a, b;
  int32_t verify;
  int64_t iters;
  const void* values;
  int64_t* samples; /* iters entries, or NULL */
  int64_t failures, mismatches, released;
  int64_t thread_cpu_ns;
  int64_t call_ns; /* the calls alone, summed */
  const int32_t* go;
  pthread_t thread;
};

struct batch_block {
  struct ArrowArray child;
  struct ArrowArray* kids[1];
  const void* root_bufs[1];
  const void* child_bufs[2];
  int64_t* released;
};

static int64_t now_ns(clockid_t clock) {
  struct timespec ts;
  clock_gettime(clock, &ts);
  return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

static void release_child(struct ArrowArray* a) { a->release = NULL; }

static void release_root(struct ArrowArray* a) {
  struct batch_block* b = (struct batch_block*)a->private_data;
  if (b->child.release != NULL) b->child.release(&b->child);
  __atomic_add_fetch(b->released, 1, __ATOMIC_RELAXED);
  free(b);
  a->release = NULL;
}

static int export_batch(struct ArrowDeviceArray* d, struct loop* l) {
  struct batch_block* b = malloc(sizeof(*b));
  if (b == NULL) return 0;
  memset(d, 0, sizeof(*d));
  b->child_bufs[0] = NULL;
  b->child_bufs[1] = l->values;
  b->child = (struct ArrowArray){l->rows, 0, 0, 2, 0, b->child_bufs, NULL, NULL, release_child, NULL};
  b->kids[0] = &b->child;
  b->root_bufs[0] = NULL;
  b->released = &l->released;
  d->array = (struct ArrowArray){l->rows, 0, 0, 1, 1, b->root_bufs, b->kids, NULL, release_root, b};
  d->device_id = -1;
  d->device_type = ARROW_DEVICE_CPU;
  return 1;
}

/* 1 when `out` is `rows` rows of a * x_i + b. */
static int output_ok(const struct ArrowArray* o, const struct loop* l) {
  if (o->length != l->rows || o->n_buffers != 2 || o->null_count != 0) return 0;
  for (int64_t i = 0; i < l->rows; i++) {
    if (l->is_float) {
      double want = l->a * ((double)i / 2) + l->b;
      double got = ((const double*)o->buffers[1])[o->offset + i];
      double scale = want > 1 || want < -1 ? (want < 0 ? -want : want) : 1;
      double diff = got - want;
      if (diff > 1e-9 * scale || diff < -1e-9 * scale) return 0;
    } else if (((const int64_t*)o->buffers[1])[o->offset + i] != (int64_t)(l->a * (double)i + l->b)) {
      return 0;
    }
  }
  return 1;
}

static void* run(void* arg) {
  struct loop* l = (struct loop*)arg;
  int32_t cancel = 0;
  komira_udf_call call = {sizeof(komira_udf_call), 0, 0, &cancel};
  while (l->go != NULL && !__atomic_load_n(l->go, __ATOMIC_ACQUIRE)) {
  }
  int64_t cpu0 = now_ns(CLOCK_THREAD_CPUTIME_ID);
  for (int64_t k = 0; k < l->iters; k++) {
    struct ArrowDeviceArray args, out;
    komira_udf_error e;
    memset(&out, 0, sizeof(out));
    memset(&e, 0, sizeof(e));
    e.struct_size = sizeof(e);
    if (!export_batch(&args, l)) {
      l->failures++;
      continue;
    }
    call.call_id = k + 1;
    int64_t t0 = now_ns(CLOCK_MONOTONIC);
    int32_t rc = l->t->call_batch(l->inst, &call, &args, &out, &e);
    int64_t t1 = now_ns(CLOCK_MONOTONIC);
    if (l->samples != NULL) l->samples[k] = t1 - t0;
    l->call_ns += t1 - t0;
    if (args.array.release != NULL) args.array.release(&args.array); /* not moved: released here */
    if (rc != KOMIRA_UDF_OK || out.array.release == NULL) {
      l->failures++;
    } else if (l->verify && !output_ok(&out.array, l)) {
      l->mismatches++;
    }
    if (out.array.release != NULL) out.array.release(&out.array);
    if (e.release != NULL) e.release(&e);
  }
  l->thread_cpu_ns = now_ns(CLOCK_THREAD_CPUTIME_ID) - cpu0;
  return NULL;
}

static void* make_values(int64_t rows, int32_t is_float) {
  void* v = malloc((size_t)(rows > 0 ? rows : 1) * 8);
  if (v == NULL) return NULL;
  for (int64_t i = 0; i < rows; i++) {
    if (is_float)
      ((double*)v)[i] = (double)i / 2;
    else
      ((int64_t*)v)[i] = i;
  }
  return v;
}

static void fill(struct loop* l, const void* table, void* inst, int64_t rows, int32_t is_float, double a, double b,
                 int32_t verify, int64_t iters, const void* values) {
  memset(l, 0, sizeof(*l));
  l->t = (const komira_udf_runtime*)table;
  l->inst = (komira_udf_instance*)inst;
  l->rows = rows;
  l->is_float = is_float;
  l->a = a;
  l->b = b;
  l->verify = verify;
  l->iters = iters;
  l->values = values;
}

/* One thread: samples[k] is call k's time in ns. stats: failures,
 * mismatches, arrays released (of `iters` exported). Returns 0, or -1 when
 * nothing could be allocated. */
int64_t komira_udf_spike_time_calls(const void* table, void* inst, int64_t rows, int32_t is_float, double a, double b,
                                    int32_t verify, int64_t iters, int64_t* samples, int64_t* stats) {
  void* values = make_values(rows, is_float);
  if (values == NULL) return -1;
  struct loop l;
  fill(&l, table, inst, rows, is_float, a, b, verify, iters, values);
  l.samples = samples;
  run(&l);
  stats[0] = l.failures;
  stats[1] = l.mismatches;
  stats[2] = l.released;
  if (l.released == iters) free(values);
  return 0;
}

static int64_t rusage_cpu_ns(int64_t* invol) {
  struct rusage u;
  getrusage(RUSAGE_SELF, &u);
  *invol = u.ru_nivcsw;
  return ((int64_t)u.ru_utime.tv_sec + u.ru_stime.tv_sec) * 1000000000 +
         ((int64_t)u.ru_utime.tv_usec + u.ru_stime.tv_usec) * 1000;
}

/* `n` threads, thread i on insts[i], `iters` calls each. out: wall ns,
 * process CPU ns, the threads' CPU ns summed, failures, mismatches, arrays
 * released (of n * iters), involuntary context switches of the process, the
 * calls' own ns summed over every thread, and the largest one thread's sum.
 * Returns 0, or -1 when a thread or buffer could not be made. */
int64_t komira_udf_spike_time_calls_mt(const void* table, void* const* insts, int32_t n, int64_t rows,
                                       int32_t is_float, double a, double b, int32_t verify, int64_t iters,
                                       int64_t* out) {
  void* values = make_values(rows, is_float);
  struct loop* ls = calloc((size_t)n, sizeof(struct loop));
  if (values == NULL || ls == NULL) {
    free(values);
    free(ls);
    return -1;
  }
  int32_t go = 0;
  int32_t started = 0;
  for (int32_t i = 0; i < n; i++) {
    fill(&ls[i], table, insts[i], rows, is_float, a, b, verify, iters, values);
    ls[i].go = &go;
    if (pthread_create(&ls[i].thread, NULL, run, &ls[i]) != 0) break;
    started++;
  }
  int64_t invol0, invol1;
  int64_t cpu0 = rusage_cpu_ns(&invol0);
  int64_t t0 = now_ns(CLOCK_MONOTONIC);
  __atomic_store_n(&go, 1, __ATOMIC_RELEASE);
  for (int32_t i = 0; i < started; i++) pthread_join(ls[i].thread, NULL);
  int64_t t1 = now_ns(CLOCK_MONOTONIC);
  int64_t cpu1 = rusage_cpu_ns(&invol1);
  memset(out, 0, 9 * sizeof(int64_t));
  out[0] = t1 - t0;
  out[1] = cpu1 - cpu0;
  for (int32_t i = 0; i < started; i++) {
    out[2] += ls[i].thread_cpu_ns;
    out[3] += ls[i].failures;
    out[4] += ls[i].mismatches;
    out[5] += ls[i].released;
    out[7] += ls[i].call_ns;
    if (ls[i].call_ns > out[8]) out[8] = ls[i].call_ns;
  }
  out[6] = invol1 - invol0;
  if (out[5] == (int64_t)started * iters) free(values);
  free(ls);
  return started == n ? 0 : -1;
}
