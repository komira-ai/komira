/*
 * The engine's call loop over N engine threads, driving any UDF runtime
 * library through komira_udf_runtime.h alone
 * (docs/design/udf_runtime_interface.md section 4.3). Test-only spike code:
 * the threads test and the bench reach it through engine.mojo.
 *
 * Why C: the engine threads are pthreads started here, and no Mojo code runs
 * on them, so a thread Mojo did not start never enters Mojo. Each thread
 * does what an engine thread does with a UDF operator: open_context on
 * itself (the context is thread-affine), open_instance, then call_batch
 * once per batch, timing each call with CLOCK_MONOTONIC around the table
 * entry alone, checking every output and releasing it.
 *
 * Inputs are exported per call without a copy: a struct array of one
 * primitive child over the thread's own values buffer, whose release (called
 * by the runtime, from any thread, at any time) frees the call's small
 * block and counts. The values are base + step * row.
 *
 * FFI-BOUNDARY. The runtime library is dlopened once (RTLD_NOW |
 * RTLD_LOCAL) and never closed. The engine, run and per-thread structs,
 * their sample arrays and the values buffers are this file's, freed by
 * kudf_engine_close and kudf_run_free; the host struct lives in the engine
 * until close, after shutdown returns. Handles are the runtime's.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

#include "komira_udf_runtime.h"

#define MAX_THREADS 64
#define MSG 512

enum { CHECK_NONE = 0, CHECK_AFFINE = 1, CHECK_COUNTER = 2 };

/* Run-level fields (thread -1) and per-thread fields of kudf_run_get. */
enum {
  R_STATUS = 0, /* load's status, or the first thread's failure */
  R_LOAD_NS,
  R_WALL_NS, /* the measured phase: every thread's measured batches */
  R_CPU_USER_NS,
  R_CPU_SYS_NS,
  R_RSS_BEFORE, /* bytes, before any context of this run */
  R_RSS_OPEN,   /* bytes, every context open, every instance, one batch each */
  R_CPUS,       /* this process's CPU affinity count */
  R_COLD_NS,    /* engine open (before dlopen) to the end of the first batch; first run only, else -1 */
  R_THREADS,
  R_INVOLUNTARY_SWITCHES /* during the measured phase */
};
enum {
  T_STATUS = 0,
  T_OPEN_CONTEXT_NS,
  T_OPEN_INSTANCE_NS,
  T_FIRST_CALL_NS,
  T_CALLS,
  T_ROWS,
  T_BAD_VALUES,
  T_FIRST_VALUE,
  T_LAST_VALUE,
  T_INCREASING, /* 1 when every output value exceeded the one before it */
  T_EXPORTED,
  T_RELEASED,
  T_SAMPLES
};

struct engine {
  void* lib;
  const komira_udf_runtime* t;
  komira_udf_rt* rt;
  komira_udf_host host;
  int32_t status;
  char message[MSG];
  int64_t t_open;  /* before dlopen */
  int64_t open_ns; /* dlopen + init */
  int runs;
  komira_udf_capabilities caps;
};

struct thread_state {
  struct run* run;
  int index;
  pthread_t tid;
  int64_t f[T_SAMPLES + 1];
  char message[MSG];
  int64_t* samples;
  int64_t first_batch_end; /* monotonic ns */
};

struct run {
  struct engine* e;
  komira_udf_udf* udf;
  komira_udf_spec spec;
  int32_t shape;
  char arg_fmt;
  char result_fmt;
  int threads, warmup, batches;
  int64_t rows;
  int check;
  double a, b, base, step;
  pthread_barrier_t opened, warmed, measured;
  int64_t f[R_INVOLUNTARY_SWITCHES + 1];
  char message[MSG];
  struct thread_state th[MAX_THREADS];
};

static int64_t now_mono(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

/* ---- host callbacks ------------------------------------------------------ */

static int32_t host_reserve(void* hd, int64_t bytes) {
  (void)hd;
  (void)bytes;
  return KOMIRA_UDF_OK;
}
static void host_release(void* hd, int64_t bytes) {
  (void)hd;
  (void)bytes;
}
static int64_t host_now(void* hd) {
  (void)hd;
  return now_mono();
}
static void host_log(void* hd, int32_t level, const char* utf8) {
  (void)hd;
  fprintf(stderr, "runtime log %d: %s\n", level, utf8 ? utf8 : "");
}

static void take_error(komira_udf_error* err, char* into) {
  snprintf(into, MSG, "%s", err->message ? err->message : "(no message)");
  if (err->release != NULL) err->release(err);
}

/* ---- the engine: open, describe, close ----------------------------------- */

struct engine* kudf_engine_open(const char* path) {
  struct engine* e = calloc(1, sizeof(*e));
  if (e == NULL) return NULL;
  e->t_open = now_mono();
  e->lib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (e->lib == NULL) {
    e->status = KOMIRA_UDF_ERR_LOAD;
    snprintf(e->message, MSG, "dlopen %s: %s", path, dlerror());
    return e;
  }
  __typeof__(&komira_udf_runtime_init_v1) init =
      (__typeof__(&komira_udf_runtime_init_v1))dlsym(e->lib, "komira_udf_runtime_init_v1");
  if (init == NULL) {
    e->status = KOMIRA_UDF_ERR_LOAD;
    snprintf(e->message, MSG, "%s exports no komira_udf_runtime_init_v1", path);
    return e;
  }
  e->host.struct_size = sizeof(komira_udf_host);
  e->host.abi_major = KOMIRA_UDF_ABI_MAJOR;
  e->host.abi_minor = KOMIRA_UDF_ABI_MINOR;
  e->host.host_data = e;
  e->host.mem_reserve = host_reserve;
  e->host.mem_release = host_release;
  e->host.now_ns = host_now;
  e->host.log = host_log;
  komira_udf_error err = {sizeof(komira_udf_error), 0, NULL, NULL, -1, -1, NULL, NULL};
  e->t = init(&e->host, &e->rt, &err);
  e->open_ns = now_mono() - e->t_open;
  if (e->t == NULL) {
    e->status = err.code;
    take_error(&err, e->message);
    return e;
  }
  e->caps.struct_size = sizeof(e->caps);
  int32_t rc = e->t->describe(e->rt, &e->caps);
  if (rc != KOMIRA_UDF_OK) {
    e->status = rc;
    snprintf(e->message, MSG, "describe returned %d", rc);
  } else if (e->caps.threading == KOMIRA_UDF_THREAD_SAFE && e->caps.global_lock != 0) {
    /* design section 4.2: THREAD_SAFE requires no global lock */
    e->status = KOMIRA_UDF_ERR_INTERNAL;
    snprintf(e->message, MSG, "UDF_RUNTIME_FAULT: THREAD_SAFE with global_lock 1");
  }
  return e;
}

int32_t kudf_engine_status(const struct engine* e) { return e == NULL ? KOMIRA_UDF_ERR_OUT_OF_MEMORY : e->status; }
const char* kudf_engine_message(const struct engine* e) { return e == NULL ? "out of memory" : e->message; }
int64_t kudf_engine_open_ns(const struct engine* e) { return e->open_ns; }
const char* kudf_engine_runtime_id(const struct engine* e) { return e->caps.runtime_id ? e->caps.runtime_id : ""; }

/* threading, global_lock, thread_affine, udf_class, hosting, shapes */
int64_t kudf_engine_cap(const struct engine* e, int32_t which) {
  switch (which) {
    case 0: return e->caps.threading;
    case 1: return e->caps.global_lock;
    case 2: return e->caps.thread_affine;
    case 3: return e->caps.udf_class;
    case 4: return e->caps.hosting;
    default: return e->caps.shapes;
  }
}

void kudf_engine_close(struct engine* e) {
  if (e == NULL) return;
  if (e->t != NULL) e->t->shutdown(e->rt);
  free(e); /* the library stays loaded */
}

/* ---- exported inputs ----------------------------------------------------- */

struct export_block {
  struct ArrowArray parent;
  struct ArrowArray child;
  struct ArrowArray* kids[1];
  const void* pbufs[1];
  const void* cbufs[2];
  int64_t* released; /* the thread's counter */
};

static void release_child(struct ArrowArray* a) { a->release = NULL; }

static void release_parent(struct ArrowArray* a) {
  struct export_block* b = a->private_data;
  if (b->child.release != NULL) b->child.release(&b->child);
  __atomic_fetch_add(b->released, 1, __ATOMIC_ACQ_REL);
  a->release = NULL;
  free(b);
}

static int export_args(struct ArrowDeviceArray* d, const void* values, int64_t rows, int64_t* released) {
  struct export_block* b = calloc(1, sizeof(*b));
  if (b == NULL) return 0;
  b->released = released;
  b->cbufs[0] = NULL;
  b->cbufs[1] = values;
  b->child.length = rows;
  b->child.n_buffers = 2;
  b->child.buffers = b->cbufs;
  b->child.release = release_child;
  b->child.private_data = b;
  b->kids[0] = &b->child;
  b->pbufs[0] = NULL;
  b->parent.length = rows;
  b->parent.n_buffers = 1;
  b->parent.buffers = b->pbufs;
  b->parent.n_children = 1;
  b->parent.children = b->kids;
  b->parent.release = release_parent;
  b->parent.private_data = b;
  memset(d, 0, sizeof(*d));
  d->array = b->parent;
  /* The struct was copied into `d`: its children pointer still points into
   * the block, which the copy's release frees. */
  d->array.private_data = b;
  d->device_id = -1;
  d->device_type = ARROW_DEVICE_CPU;
  return 1;
}

/* ---- one engine thread --------------------------------------------------- */

static const char* check_output(struct thread_state* s, const struct ArrowArray* o, const void* in, int64_t rows,
                                int64_t* prev, int* have_prev) {
  struct run* r = s->run;
  if (o->length != rows) return "an output with another row count";
  if (o->n_buffers != 2 || o->buffers[1] == NULL || o->n_children != 0) return "an output that is not one column";
  const int64_t* vi = (const int64_t*)o->buffers[1] + o->offset;
  const double* vf = (const double*)o->buffers[1] + o->offset;
  for (int64_t i = 0; i < rows; i++) {
    if (r->check == CHECK_AFFINE) {
      double x = r->arg_fmt == 'g' ? ((const double*)in)[i] : (double)((const int64_t*)in)[i];
      double want = r->a * x + r->b;
      double got = r->result_fmt == 'g' ? vf[i] : (double)vi[i];
      double scale = want < 0 ? -want : want;
      if (scale < 1) scale = 1;
      double diff = got - want;
      if (diff < 0) diff = -diff;
      if (diff > 1e-9 * scale) s->f[T_BAD_VALUES]++;
    } else if (r->check == CHECK_COUNTER) {
      int64_t v = vi[i];
      if (!*have_prev) s->f[T_FIRST_VALUE] = v;
      if (*have_prev && v <= *prev) s->f[T_INCREASING] = 0;
      *prev = v;
      *have_prev = 1;
      s->f[T_LAST_VALUE] = v;
    }
  }
  return NULL;
}

static void fail_thread(struct thread_state* s, int32_t code, const char* msg) {
  if (s->f[T_STATUS] == 0) {
    s->f[T_STATUS] = code;
    snprintf(s->message, MSG, "%s", msg);
  }
}

/* One call: export, call_batch (timed), check, release. Returns the ns. */
static int64_t one_call(struct thread_state* s, komira_udf_instance* inst, const void* values, int64_t* prev,
                        int* have_prev) {
  struct run* r = s->run;
  const komira_udf_runtime* t = r->e->t;
  struct ArrowDeviceArray args, out;
  memset(&out, 0, sizeof(out));
  if (!export_args(&args, values, r->rows, &s->f[T_RELEASED])) {
    fail_thread(s, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "export: out of memory");
    return 0;
  }
  s->f[T_EXPORTED]++;
  int32_t cancel = 0;
  komira_udf_call call = {sizeof(komira_udf_call), 0, s->f[T_CALLS] + 1, &cancel};
  komira_udf_error err = {sizeof(komira_udf_error), 0, NULL, NULL, -1, -1, NULL, NULL};
  int64_t t0 = now_mono();
  int32_t rc = t->call_batch(inst, &call, &args, &out, &err);
  int64_t ns = now_mono() - t0;
  s->f[T_CALLS]++;
  if (args.array.release != NULL) {
    /* not moved: still ours */
    args.array.release(&args.array);
    fail_thread(s, KOMIRA_UDF_ERR_INTERNAL, "UDF_RUNTIME_FAULT: args not moved by call_batch");
  }
  if (rc != KOMIRA_UDF_OK) {
    char m[MSG];
    take_error(&err, m);
    fail_thread(s, rc, m);
    if (out.array.release != NULL) out.array.release(&out.array);
    return ns;
  }
  if (out.array.release == NULL) {
    fail_thread(s, KOMIRA_UDF_ERR_INTERNAL, "UDF_RUNTIME_FAULT: OK without an output");
    return ns;
  }
  const char* bad = out.device_type == ARROW_DEVICE_CPU ? check_output(s, &out.array, values, r->rows, prev, have_prev)
                                                         : "an output not on the CPU";
  if (bad != NULL) fail_thread(s, KOMIRA_UDF_ERR_INTERNAL, bad);
  s->f[T_ROWS] += r->rows;
  out.array.release(&out.array);
  return ns;
}

static void* engine_thread(void* p) {
  struct thread_state* s = p;
  struct run* r = s->run;
  const komira_udf_runtime* t = r->e->t;
  s->f[T_INCREASING] = 1;
  size_t w = 8;
  void* values = malloc((size_t)(r->rows > 0 ? r->rows : 1) * w);
  for (int64_t i = 0; values != NULL && i < r->rows; i++) {
    double x = r->base + r->step * (double)i;
    if (r->arg_fmt == 'g')
      ((double*)values)[i] = x;
    else
      ((int64_t*)values)[i] = (int64_t)x;
  }
  komira_udf_context* ctx = NULL;
  komira_udf_instance* inst = NULL;
  komira_udf_error err = {sizeof(komira_udf_error), 0, NULL, NULL, -1, -1, NULL, NULL};
  int64_t t0 = now_mono();
  int32_t rc = values == NULL ? KOMIRA_UDF_ERR_OUT_OF_MEMORY : t->open_context(r->e->rt, (uint32_t)s->index, &ctx, &err);
  s->f[T_OPEN_CONTEXT_NS] = now_mono() - t0;
  if (rc != KOMIRA_UDF_OK) {
    char m[MSG];
    take_error(&err, m);
    fail_thread(s, rc, m);
  } else {
    t0 = now_mono();
    rc = t->open_instance(ctx, r->udf, &inst, &err);
    s->f[T_OPEN_INSTANCE_NS] = now_mono() - t0;
    if (rc != KOMIRA_UDF_OK) {
      char m[MSG];
      take_error(&err, m);
      fail_thread(s, rc, m);
    }
  }
  int64_t prev = 0;
  int have_prev = 0;
  int ok = inst != NULL;
  if (ok) {
    s->f[T_FIRST_CALL_NS] = one_call(s, inst, values, &prev, &have_prev);
    s->first_batch_end = now_mono();
  }
  pthread_barrier_wait(&r->opened);
  for (int i = 1; ok && i < r->warmup && s->f[T_STATUS] == 0; i++) one_call(s, inst, values, &prev, &have_prev);
  pthread_barrier_wait(&r->warmed);
  for (int i = 0; ok && i < r->batches && s->f[T_STATUS] == 0; i++)
    s->samples[s->f[T_SAMPLES]++] = one_call(s, inst, values, &prev, &have_prev);
  pthread_barrier_wait(&r->measured);
  if (inst != NULL) t->close_instance(inst);
  if (ctx != NULL) t->close_context(ctx);
  free(values);
  return NULL;
}

/* ---- a run --------------------------------------------------------------- */

static int64_t rss_bytes(void) {
  FILE* f = fopen("/proc/self/statm", "r");
  long pages = 0, resident = 0;
  if (f == NULL) return -1;
  if (fscanf(f, "%ld %ld", &pages, &resident) != 2) resident = -1;
  fclose(f);
  return resident < 0 ? -1 : (int64_t)resident * sysconf(_SC_PAGESIZE);
}

static int64_t tv_ns(struct timeval tv) { return (int64_t)tv.tv_sec * 1000000000LL + (int64_t)tv.tv_usec * 1000; }

static void no_release(struct ArrowSchema* s) { (void)s; }

struct run* kudf_run(struct engine* e, const char* entry, int32_t shape, char arg_fmt, char result_fmt,
                     int32_t threads, int32_t warmup, int32_t batches, int64_t rows, int32_t check, double a,
                     double b, double base, double step) {
  struct run* r = calloc(1, sizeof(*r));
  if (r == NULL) return NULL;
  r->e = e;
  r->shape = shape;
  r->arg_fmt = arg_fmt;
  r->result_fmt = result_fmt;
  r->threads = threads < 1 ? 1 : threads > MAX_THREADS ? MAX_THREADS : threads;
  r->warmup = warmup < 1 ? 1 : warmup;
  r->batches = batches < 0 ? 0 : batches;
  r->rows = rows;
  r->check = check;
  r->a = a;
  r->b = b;
  r->base = base;
  r->step = step;
  r->f[R_THREADS] = r->threads;
  r->f[R_COLD_NS] = -1;
  cpu_set_t set;
  r->f[R_CPUS] = sched_getaffinity(0, sizeof(set), &set) == 0 ? CPU_COUNT(&set) : -1;
  if (e == NULL || e->status != KOMIRA_UDF_OK) {
    r->f[R_STATUS] = e == NULL ? KOMIRA_UDF_ERR_OUT_OF_MEMORY : e->status;
    snprintf(r->message, MSG, "%s", kudf_engine_message(e));
    return r;
  }
  /* The spec: one argument of arg_fmt, a result of result_fmt. */
  char arg_name[] = "x";
  char arg_format[2] = {arg_fmt, 0};
  char res_format[2] = {result_fmt, 0};
  struct ArrowSchema child = {arg_format, arg_name, NULL, ARROW_FLAG_NULLABLE, 0, NULL, NULL, no_release, NULL};
  struct ArrowSchema* kids[1] = {&child};
  struct ArrowSchema args = {"+s", "", NULL, 0, 1, kids, NULL, no_release, NULL};
  struct ArrowSchema result = {res_format, "", NULL, ARROW_FLAG_NULLABLE, 0, NULL, NULL, no_release, NULL};
  komira_udf_spec* s = &r->spec;
  s->struct_size = sizeof(*s);
  s->shape = shape;
  s->form = KOMIRA_UDF_FORM_BUNDLE;
  s->entry = entry;
  s->args = &args;
  s->result = &result;
  s->null_mode = KOMIRA_UDF_NULL_MANUAL;
  s->stability = KOMIRA_UDF_IMMUTABLE;
  s->code_root = "";
  komira_udf_error err = {sizeof(komira_udf_error), 0, NULL, NULL, -1, -1, NULL, NULL};
  int64_t t0 = now_mono();
  int32_t rc = e->t->load(e->rt, s, &r->udf, &err);
  r->f[R_LOAD_NS] = now_mono() - t0;
  s->args = s->result = NULL; /* borrowed for the call only */
  s->entry = NULL;
  if (rc != KOMIRA_UDF_OK) {
    r->f[R_STATUS] = rc;
    take_error(&err, r->message);
    return r;
  }
  r->f[R_RSS_BEFORE] = rss_bytes();
  pthread_barrier_init(&r->opened, NULL, (unsigned)r->threads + 1);
  pthread_barrier_init(&r->warmed, NULL, (unsigned)r->threads + 1);
  pthread_barrier_init(&r->measured, NULL, (unsigned)r->threads + 1);
  for (int i = 0; i < r->threads; i++) {
    struct thread_state* th = &r->th[i];
    th->run = r;
    th->index = i;
    th->samples = calloc((size_t)(r->batches > 0 ? r->batches : 1), sizeof(int64_t));
    pthread_create(&th->tid, NULL, engine_thread, th);
  }
  pthread_barrier_wait(&r->opened);
  r->f[R_RSS_OPEN] = rss_bytes();
  if (e->runs == 0 && r->th[0].first_batch_end != 0) r->f[R_COLD_NS] = r->th[0].first_batch_end - e->t_open;
  struct rusage u0, u1;
  pthread_barrier_wait(&r->warmed);
  getrusage(RUSAGE_SELF, &u0);
  int64_t w0 = now_mono();
  pthread_barrier_wait(&r->measured);
  r->f[R_WALL_NS] = now_mono() - w0;
  getrusage(RUSAGE_SELF, &u1);
  r->f[R_CPU_USER_NS] = tv_ns(u1.ru_utime) - tv_ns(u0.ru_utime);
  r->f[R_CPU_SYS_NS] = tv_ns(u1.ru_stime) - tv_ns(u0.ru_stime);
  r->f[R_INVOLUNTARY_SWITCHES] = u1.ru_nivcsw - u0.ru_nivcsw;
  for (int i = 0; i < r->threads; i++) pthread_join(r->th[i].tid, NULL);
  pthread_barrier_destroy(&r->opened);
  pthread_barrier_destroy(&r->warmed);
  pthread_barrier_destroy(&r->measured);
  e->t->unload(r->udf);
  r->udf = NULL;
  e->runs++;
  for (int i = 0; i < r->threads; i++)
    if (r->th[i].f[T_STATUS] != 0 && r->f[R_STATUS] == 0) {
      r->f[R_STATUS] = r->th[i].f[T_STATUS];
      snprintf(r->message, MSG, "thread %d: %s", i, r->th[i].message);
    }
  return r;
}

int64_t kudf_run_get(const struct run* r, int32_t thread, int32_t field) {
  if (thread < 0) return field >= 0 && field <= R_INVOLUNTARY_SWITCHES ? r->f[field] : 0;
  if (thread >= r->threads || field < 0 || field > T_SAMPLES) return 0;
  return r->th[thread].f[field];
}

const char* kudf_run_message(const struct run* r, int32_t thread) {
  return thread < 0 ? r->message : r->th[thread].message;
}

int64_t kudf_run_sample(const struct run* r, int32_t thread, int64_t i) {
  if (thread < 0 || thread >= r->threads || i < 0 || i >= r->th[thread].f[T_SAMPLES]) return 0;
  return r->th[thread].samples[i];
}

void kudf_run_free(struct run* r) {
  if (r == NULL) return;
  for (int i = 0; i < r->threads; i++) free(r->th[i].samples);
  free(r);
}
