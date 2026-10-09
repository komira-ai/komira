/*
 * engine_loop.c: an engine that drives any UDF runtime library through the
 * C ABI table alone, on N engine threads (pthreads started here, on which no
 * Mojo code runs), and measures what the spike reports (design section 9,
 * the prototype of per-thread contexts: the scaling curve from 1 to N,
 * memory per context, cold start). Test-only spike code; it names no runtime and no language.
 *
 * kudfw_engine_run loads one UDF of one float64 or int64 argument and runs
 * it on `threads` threads. Each thread opens its own context and instance
 * (for a worker runtime: its own worker process), times open_context,
 * open_instance and its first call (the cold start), then warms up until
 * three consecutive window medians of WINDOW batches agree within 2% (or
 * `warm_max` batches), waits for every thread, and times at least `samples`
 * calls, for at least `min_ms` milliseconds, with CLOCK_MONOTONIC around
 * call_batch alone. Each output is checked outside the timer. The result is one JSON object (README of the bench:
 * bench/bench_main.mojo).
 *
 * What a runtime logs through the host (komira_udf_host.log) is kept per
 * thread: a worker runtime names the worker it started (`pid=`) and, at
 * close_context, the worker's own counters; both go into the report. CPU is
 * the scheduler's ns (schedstat) of the engine thread and of every thread of
 * the worker process named by the log, memory from /proc/<pid>/smaps_rollup.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <dlfcn.h>
#include <pthread.h>
#include <sched.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h> /* RUSAGE_SELF: the engine process */
#include <time.h>
#include <unistd.h>

#include "komira_udf_runtime.h"

#define WINDOW 10
#define MAX_THREADS 64
#define MAX_SAMPLES 200000

/* ---- JSON text --------------------------------------------------------------- */

typedef struct jbuf {
  char* p;
  size_t n, cap;
} jbuf;

static void jput(jbuf* b, const char* fmt, ...) {
  va_list ap;
  for (;;) {
    va_start(ap, fmt);
    size_t room = b->cap - b->n;
    int k = vsnprintf(b->p ? b->p + b->n : NULL, b->p ? room : 0, fmt, ap);
    va_end(ap);
    if (k < 0) return;
    if (b->p != NULL && (size_t)k < room) {
      b->n += (size_t)k;
      return;
    }
    size_t cap = b->cap ? b->cap * 2 : 4096;
    while (cap < b->n + (size_t)k + 1) cap *= 2;
    char* q = (char*)realloc(b->p, cap);
    if (q == NULL) return;
    b->p = q;
    b->cap = cap;
  }
}

/* A JSON string of `s`: quotes, backslashes and control bytes escaped. */
static void jstr(jbuf* b, const char* s) {
  jput(b, "\"");
  for (; s != NULL && *s; s++) {
    unsigned char c = (unsigned char)*s;
    if (c == '"' || c == '\\')
      jput(b, "\\%c", c);
    else if (c < 0x20)
      jput(b, "\\u%04x", c);
    else
      jput(b, "%c", c);
  }
  jput(b, "\"");
}

/* ---- the host ------------------------------------------------------------------ */

static int64_t mono_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

static __thread char t_open_line[1024];
static __thread char t_close_line[1024];

static int32_t h_reserve(void* hd, int64_t bytes) {
  (void)hd;
  (void)bytes;
  return KOMIRA_UDF_OK;
}
static void h_release(void* hd, int64_t bytes) {
  (void)hd;
  (void)bytes;
}
static int64_t h_now(void* hd) {
  (void)hd;
  return mono_ns();
}
static void h_log(void* hd, int32_t level, const char* utf8) {
  (void)hd;
  (void)level;
  if (utf8 == NULL) return;
  if (strstr(utf8, " open slot=") != NULL) snprintf(t_open_line, sizeof(t_open_line), "%s", utf8);
  if (strstr(utf8, " close slot=") != NULL) snprintf(t_close_line, sizeof(t_close_line), "%s", utf8);
}

/* The integer after `key=` in `line`, or -1. */
static long long field_of(const char* line, const char* key) {
  char k[64];
  snprintf(k, sizeof(k), " %s=", key);
  const char* p = strstr(line, k);
  return p ? atoll(p + strlen(k)) : -1;
}

/* ---- arguments: exported arrays with counted releases ----------------------- */

static atomic_long exported, released;

typedef struct arg_hold {
  struct ArrowArray child;
  struct ArrowArray* kids[1];
  const void* root_bufs[1];
  const void* child_bufs[2];
} arg_hold;

static void release_child(struct ArrowArray* a) { a->release = NULL; }

static void release_root(struct ArrowArray* a) {
  arg_hold* h = (arg_hold*)a->private_data;
  if (h->child.release != NULL) h->child.release(&h->child);
  free(h);
  a->release = NULL;
  atomic_fetch_add(&released, 1);
}

/* A struct of one column of `rows` values at `values` (borrowed: it lives
 * as long as the thread). */
static void make_args(struct ArrowDeviceArray* d, const void* values, int64_t rows) {
  arg_hold* h = (arg_hold*)calloc(1, sizeof(*h));
  memset(d, 0, sizeof(*d));
  h->child_bufs[0] = NULL;
  h->child_bufs[1] = values;
  h->child.length = rows;
  h->child.n_buffers = 2;
  h->child.buffers = h->child_bufs;
  h->child.release = release_child;
  h->kids[0] = &h->child;
  h->root_bufs[0] = NULL;
  d->array.length = rows;
  d->array.n_buffers = 1;
  d->array.n_children = 1;
  d->array.buffers = h->root_bufs;
  d->array.children = h->kids;
  d->array.release = release_root;
  d->array.private_data = h;
  d->device_id = -1;
  d->device_type = ARROW_DEVICE_CPU;
  atomic_fetch_add(&exported, 1);
}

static void noop_schema_release(struct ArrowSchema* s) { s->release = NULL; }

static void leaf(struct ArrowSchema* s, const char* fmt, const char* name) {
  memset(s, 0, sizeof(*s));
  s->format = fmt;
  s->name = name;
  s->flags = ARROW_FLAG_NULLABLE;
  s->release = noop_schema_release;
}

/* ---- one run ------------------------------------------------------------------- */

typedef struct run run_t;

typedef struct thread_rep {
  run_t* run;
  int slot;
  int32_t status;
  char message[400];
  long long pid;
  int64_t open_context_ns, open_instance_ns, first_call_ns, cold_ns;
  int warm_batches;
  int64_t* samples;
  int n_samples, cap_samples;
  int64_t t_start, t_end;
  int64_t engine_cpu_ns, worker_cpu_ns;
  long long rss_kb, pss_kb, uss_kb;
  long long bad_values;
  char close_line[1024];
} thread_rep;

struct run {
  const komira_udf_runtime* t;
  komira_udf_rt* rt;
  komira_udf_udf* udf;
  char fmt;
  int64_t rows;
  int warm_max, samples, check;
  int64_t min_ns; /* the measured phase runs at least this long, and at least `samples` calls */
  double a, b;
  int threads;
  pthread_barrier_t warm, done;
  thread_rep rep[MAX_THREADS];
};

/* The first field of a schedstat file: ns this task has run on a CPU. */
static int64_t schedstat_ns(const char* path) {
  FILE* f = fopen(path, "r");
  if (f == NULL) return -1;
  long long v = -1;
  if (fscanf(f, "%lld", &v) != 1) v = -1;
  fclose(f);
  return v;
}

/* CPU time of the calling thread, in ns (scheduler accounting, not ticks). */
static int64_t thread_cpu_ns(void) { return schedstat_ns("/proc/thread-self/schedstat"); }

/* CPU time of every thread of process `pid` (its JIT and GC helpers
 * included), in ns, or -1. */
static int64_t proc_cpu_ns(long long pid) {
  if (pid <= 0) return -1;
  char dir[64];
  snprintf(dir, sizeof(dir), "/proc/%lld/task", pid);
  DIR* d = opendir(dir);
  if (d == NULL) return -1;
  int64_t total = 0;
  struct dirent* e;
  while ((e = readdir(d)) != NULL) {
    if (e->d_name[0] == '.') continue;
    char path[128];
    snprintf(path, sizeof(path), "%s/%s/schedstat", dir, e->d_name);
    int64_t v = schedstat_ns(path);
    if (v > 0) total += v;
  }
  closedir(d);
  return total;
}

static void smaps(long long pid, long long* rss, long long* pss, long long* uss) {
  *rss = *pss = *uss = -1;
  if (pid <= 0) return;
  char path[64], line[256];
  snprintf(path, sizeof(path), "/proc/%lld/smaps_rollup", pid);
  FILE* f = fopen(path, "r");
  if (f == NULL) return;
  long long pc = 0, pd = 0;
  while (fgets(line, sizeof(line), f) != NULL) {
    long long v;
    if (sscanf(line, "Rss: %lld", &v) == 1) *rss = v;
    if (sscanf(line, "Pss: %lld", &v) == 1) *pss = v;
    if (sscanf(line, "Private_Clean: %lld", &v) == 1) pc = v;
    if (sscanf(line, "Private_Dirty: %lld", &v) == 1) pd = v;
  }
  fclose(f);
  *uss = pc + pd;
}

static int cmp64(const void* x, const void* y) {
  int64_t a = *(const int64_t*)x, b = *(const int64_t*)y;
  return (a > b) - (a < b);
}

static int64_t median(const int64_t* v, int n) {
  int64_t tmp[WINDOW];
  memcpy(tmp, v, sizeof(int64_t) * (size_t)n);
  qsort(tmp, (size_t)n, sizeof(int64_t), cmp64);
  return tmp[n / 2];
}

/* Bad values in an output column: compared with a * x + b (CHECK 1) or x
 * (CHECK 2), CHECK 0 checks the row count only. */
static long long check_out(const run_t* r, const struct ArrowDeviceArray* out, const void* in) {
  const struct ArrowArray* a = &out->array;
  if (a->release == NULL || a->length != r->rows || a->n_buffers != 2) return r->rows ? r->rows : 1;
  if (r->check == 0) return 0;
  long long bad = 0;
  for (int64_t i = 0; i < r->rows; i++) {
    double x = r->fmt == 'g' ? ((const double*)in)[i] : (double)((const int64_t*)in)[i];
    double want = r->check == 1 ? r->a * x + r->b : x;
    double got = r->fmt == 'g' ? ((const double*)a->buffers[1])[a->offset + i]
                               : (double)((const int64_t*)a->buffers[1])[a->offset + i];
    double d = got > want ? got - want : want - got;
    if (d > 1e-9 * ((want < 0 ? -want : want) + 1)) bad++;
  }
  return bad;
}

static int32_t one_call(run_t* r, komira_udf_instance* inst, const void* values, int64_t* ns, long long* bad,
                        char* msg, size_t msg_len) {
  struct ArrowDeviceArray args, out;
  make_args(&args, values, r->rows);
  memset(&out, 0, sizeof(out));
  komira_udf_error e;
  memset(&e, 0, sizeof(e));
  e.struct_size = sizeof(e);
  volatile int32_t flag = 0;
  komira_udf_call call = {sizeof(call), 0, 1, &flag};
  int64_t t0 = mono_ns();
  int32_t st = r->t->call_batch(inst, &call, &args, &out, &e);
  *ns = mono_ns() - t0;
  if (args.array.release != NULL) args.array.release(&args.array);
  if (st == KOMIRA_UDF_OK)
    *bad += check_out(r, &out, values);
  else
    snprintf(msg, msg_len, "call_batch: status %d: %s", st, e.message ? e.message : "");
  if (out.array.release != NULL) out.array.release(&out.array);
  if (e.release != NULL) e.release(&e);
  return st;
}

static void* thread_main(void* arg) {
  thread_rep* tr = (thread_rep*)arg;
  run_t* r = tr->run;
  komira_udf_error e;
  memset(&e, 0, sizeof(e));
  e.struct_size = sizeof(e);
  void* values = malloc((size_t)(r->rows > 0 ? r->rows : 1) * 8);
  for (int64_t i = 0; i < r->rows; i++) {
    if (r->fmt == 'g')
      ((double*)values)[i] = 0.5 * (double)i - 40.0;
    else
      ((int64_t*)values)[i] = (int64_t)(r->a);
  }
  komira_udf_context* ctx = NULL;
  komira_udf_instance* inst = NULL;
  int64_t t0 = mono_ns();
  tr->status = r->t->open_context(r->rt, (uint32_t)tr->slot, &ctx, &e);
  tr->open_context_ns = mono_ns() - t0;
  tr->pid = field_of(t_open_line, "pid");
  if (tr->status == KOMIRA_UDF_OK) {
    int64_t t1 = mono_ns();
    tr->status = r->t->open_instance(ctx, r->udf, &inst, &e);
    tr->open_instance_ns = mono_ns() - t1;
  }
  if (tr->status != KOMIRA_UDF_OK) {
    snprintf(tr->message, sizeof(tr->message), "open: status %d: %s", tr->status, e.message ? e.message : "");
    if (e.release) e.release(&e);
  }
  if (tr->status == KOMIRA_UDF_OK) {
    tr->status = one_call(r, inst, values, &tr->first_call_ns, &tr->bad_values, tr->message, sizeof(tr->message));
    tr->cold_ns = mono_ns() - t0;
  }
  int64_t win[3] = {0, 0, 0};
  int64_t w[WINDOW];
  while (tr->status == KOMIRA_UDF_OK && tr->warm_batches < r->warm_max) {
    for (int k = 0; k < WINDOW && tr->status == KOMIRA_UDF_OK; k++)
      tr->status = one_call(r, inst, values, &w[k], &tr->bad_values, tr->message, sizeof(tr->message));
    tr->warm_batches += WINDOW;
    win[0] = win[1];
    win[1] = win[2];
    win[2] = median(w, WINDOW);
    if (win[0] > 0) {
      int64_t lo = win[0], hi = win[0];
      for (int k = 1; k < 3; k++) {
        lo = win[k] < lo ? win[k] : lo;
        hi = win[k] > hi ? win[k] : hi;
      }
      if ((double)hi <= 1.02 * (double)lo) break;
    }
  }
  pthread_barrier_wait(&r->warm);
  tr->t_start = mono_ns();
  int64_t c0 = thread_cpu_ns(), p0 = proc_cpu_ns(tr->pid);
  for (int k = 0; tr->status == KOMIRA_UDF_OK && k < tr->cap_samples; k++) {
    if (k >= r->samples && mono_ns() - tr->t_start >= r->min_ns) break;
    tr->status = one_call(r, inst, values, &tr->samples[k], &tr->bad_values, tr->message, sizeof(tr->message));
    if (tr->status == KOMIRA_UDF_OK) tr->n_samples++;
  }
  tr->t_end = mono_ns();
  tr->engine_cpu_ns = thread_cpu_ns() - c0;
  int64_t p1 = proc_cpu_ns(tr->pid);
  tr->worker_cpu_ns = p0 >= 0 && p1 >= 0 ? p1 - p0 : -1;
  smaps(tr->pid, &tr->rss_kb, &tr->pss_kb, &tr->uss_kb);
  pthread_barrier_wait(&r->done);
  if (inst != NULL) r->t->close_instance(inst);
  if (ctx != NULL) r->t->close_context(ctx);
  snprintf(tr->close_line, sizeof(tr->close_line), "%s", t_close_line);
  free(values);
  return NULL;
}

static void read_file(const char* path, char* out, size_t n) {
  out[0] = 0;
  FILE* f = fopen(path, "r");
  if (f == NULL) return;
  size_t k = fread(out, 1, n - 1, f);
  fclose(f);
  out[k] = 0;
  for (size_t i = 0; i < k; i++)
    if (out[i] == '\n') out[i] = ' ';
}

static void cpu_model(char* out, size_t n) {
  out[0] = 0;
  FILE* f = fopen("/proc/cpuinfo", "r");
  if (f == NULL) return;
  char line[512];
  while (fgets(line, sizeof(line), f) != NULL)
    if (strncmp(line, "model name", 10) == 0) {
      char* c = strchr(line, ':');
      if (c != NULL) snprintf(out, n, "%s", c + 2);
      break;
    }
  fclose(f);
  size_t k = strlen(out);
  if (k > 0 && out[k - 1] == '\n') out[k - 1] = 0;
}

static long long kv_space(const char* buf, const char* key) {
  const char* p = strstr(buf, key);
  return p ? atoll(p + strlen(key)) : -1;
}

/* cgroup v2 cpu.stat: `nr_throttled N` and `throttled_usec N`, or -1. */
static void cgroup_stat(long long* nr_throttled, long long* throttled_usec) {
  char buf[2048];
  read_file("/sys/fs/cgroup/cpu.stat", buf, sizeof(buf));
  *nr_throttled = kv_space(buf, "nr_throttled ");
  *throttled_usec = kv_space(buf, "throttled_usec ");
}

__attribute__((visibility("default"))) char* kudfw_engine_run(const char* lib_path, const char* entry, uint32_t shape,
                                                             const char* fmt, int64_t threads, int64_t rows,
                                                             int64_t warm_max, int64_t samples, int64_t min_ms,
                                                             int64_t check, double a, double b) {
  jbuf j = {0};
  static komira_udf_host host;
  host.struct_size = sizeof(host);
  host.abi_major = KOMIRA_UDF_ABI_MAJOR;
  host.abi_minor = KOMIRA_UDF_ABI_MINOR;
  host.mem_reserve = h_reserve;
  host.mem_release = h_release;
  host.now_ns = h_now;
  host.log = h_log;
  if (threads < 1 || threads > MAX_THREADS || samples < 1 || (fmt[0] != 'g' && fmt[0] != 'l')) {
    jput(&j, "{\"status\":-1,\"message\":\"bad arguments\"}");
    return j.p;
  }
  int64_t t0 = mono_ns();
  void* lib = dlopen(lib_path, RTLD_NOW | RTLD_LOCAL);
  if (lib == NULL) {
    jput(&j, "{\"status\":-1,\"message\":");
    jstr(&j, dlerror());
    jput(&j, "}");
    return j.p;
  }
  typedef const komira_udf_runtime* (*init_fn)(const komira_udf_host*, komira_udf_rt**, komira_udf_error*);
  init_fn init = (init_fn)dlsym(lib, "komira_udf_runtime_init_v1");
  komira_udf_error e;
  memset(&e, 0, sizeof(e));
  e.struct_size = sizeof(e);
  run_t* r = (run_t*)calloc(1, sizeof(*r));
  r->t = init != NULL ? init(&host, &r->rt, &e) : NULL;
  int64_t init_ns = mono_ns() - t0;
  if (r->t == NULL) {
    jput(&j, "{\"status\":-1,\"message\":");
    jstr(&j, e.message ? e.message : "no init");
    jput(&j, "}");
    if (e.release) e.release(&e);
    free(r);
    return j.p;
  }
  komira_udf_capabilities caps;
  memset(&caps, 0, sizeof(caps));
  caps.struct_size = sizeof(caps);
  r->t->describe(r->rt, &caps);
  struct ArrowSchema arg_leaf, args_s, res_s;
  struct ArrowSchema* kids[1] = {&arg_leaf};
  leaf(&arg_leaf, fmt, "x");
  memset(&args_s, 0, sizeof(args_s));
  args_s.format = "+s";
  args_s.name = "";
  args_s.n_children = 1;
  args_s.children = kids;
  args_s.release = noop_schema_release;
  leaf(&res_s, fmt, "");
  komira_udf_spec spec;
  memset(&spec, 0, sizeof(spec));
  spec.struct_size = sizeof(spec);
  spec.shape = (int32_t)shape;
  spec.form = KOMIRA_UDF_FORM_BUNDLE;
  spec.entry = entry;
  spec.args = &args_s;
  spec.result = &res_s;
  spec.null_mode = KOMIRA_UDF_NULL_MANUAL;
  spec.stability = KOMIRA_UDF_IMMUTABLE;
  spec.code_root = "";
  int64_t t1 = mono_ns();
  int32_t st = r->t->load(r->rt, &spec, &r->udf, &e);
  int64_t load_ns = mono_ns() - t1;
  if (st != KOMIRA_UDF_OK) {
    jput(&j, "{\"status\":%d,\"message\":", st);
    jstr(&j, e.message ? e.message : "");
    jput(&j, "}");
    if (e.release) e.release(&e);
    r->t->shutdown(r->rt);
    free(r);
    return j.p;
  }
  r->fmt = fmt[0];
  r->rows = rows;
  r->warm_max = (int)warm_max;
  r->samples = (int)samples;
  r->min_ns = min_ms * 1000000;
  r->check = (int)check;
  r->a = a;
  r->b = b;
  r->threads = (int)threads;
  pthread_barrier_init(&r->warm, NULL, (unsigned)threads);
  pthread_barrier_init(&r->done, NULL, (unsigned)threads);
  char cpu_max[128], load0[128], load1[128], model[256];
  read_file("/sys/fs/cgroup/cpu.max", cpu_max, sizeof(cpu_max));
  read_file("/proc/loadavg", load0, sizeof(load0));
  cpu_model(model, sizeof(model));
  long long thr0, thr_us0, thr1, thr_us1;
  cgroup_stat(&thr0, &thr_us0);
  cpu_set_t set;
  int cpus = sched_getaffinity(0, sizeof(set), &set) == 0 ? CPU_COUNT(&set) : -1;
  struct rusage pu0, pu1;
  getrusage(RUSAGE_SELF, &pu0);
  long exp0 = atomic_load(&exported), rel0 = atomic_load(&released);
  pthread_t th[MAX_THREADS];
  for (int i = 0; i < r->threads; i++) {
    r->rep[i].run = r;
    r->rep[i].slot = i;
    r->rep[i].cap_samples = (int)(samples > MAX_SAMPLES ? samples : MAX_SAMPLES);
    r->rep[i].samples = (int64_t*)calloc((size_t)r->rep[i].cap_samples, sizeof(int64_t));
    pthread_create(&th[i], NULL, thread_main, &r->rep[i]);
  }
  for (int i = 0; i < r->threads; i++) pthread_join(th[i], NULL);
  getrusage(RUSAGE_SELF, &pu1);
  cgroup_stat(&thr1, &thr_us1);
  read_file("/proc/loadavg", load1, sizeof(load1));
  int64_t wall0 = r->rep[0].t_start, wall1 = r->rep[0].t_end;
  for (int i = 0; i < r->threads; i++) {
    if (r->rep[i].t_start < wall0) wall0 = r->rep[i].t_start;
    if (r->rep[i].t_end > wall1) wall1 = r->rep[i].t_end;
  }
  r->t->unload(r->udf);
  int64_t s0 = mono_ns();
  r->t->shutdown(r->rt);
  int64_t shutdown_ns = mono_ns() - s0;
  int32_t status = 0;
  for (int i = 0; i < r->threads; i++)
    if (r->rep[i].status != 0 && status == 0) status = r->rep[i].status;
  jput(&j, "{\"status\":%d,\"runtime_id\":", status);
  jstr(&j, caps.runtime_id ? caps.runtime_id : "");
  jput(&j, ",\"runtime_abi\":");
  jstr(&j, caps.runtime_abi ? caps.runtime_abi : "");
  jput(&j, ",\"threading\":%u,\"transports\":%u,\"entry\":", caps.threading, caps.transports);
  jstr(&j, entry);
  jput(&j, ",\"shape\":%u,\"fmt\":", shape);
  jstr(&j, fmt);
  jput(&j, ",\"threads\":%lld,\"rows\":%lld,\"samples\":%lld,\"init_ns\":%lld,\"load_ns\":%lld,\"shutdown_ns\":%lld",
       (long long)threads, (long long)rows, (long long)samples, (long long)init_ns, (long long)load_ns,
       (long long)shutdown_ns);
  jput(&j, ",\"wall_ns\":%lld,\"engine_user_ns\":%lld,\"engine_sys_ns\":%lld,\"involuntary_switches\":%ld",
       (long long)(wall1 - wall0),
       (long long)((pu1.ru_utime.tv_sec - pu0.ru_utime.tv_sec) * 1000000000LL +
                   (pu1.ru_utime.tv_usec - pu0.ru_utime.tv_usec) * 1000LL),
       (long long)((pu1.ru_stime.tv_sec - pu0.ru_stime.tv_sec) * 1000000000LL +
                   (pu1.ru_stime.tv_usec - pu0.ru_stime.tv_usec) * 1000LL),
       pu1.ru_nivcsw - pu0.ru_nivcsw);
  jput(&j, ",\"exported\":%ld,\"released\":%ld", atomic_load(&exported) - exp0, atomic_load(&released) - rel0);
  jput(&j, ",\"cpus\":%d,\"cpu_model\":", cpus);
  jstr(&j, model);
  jput(&j, ",\"cgroup_cpu_max\":");
  jstr(&j, cpu_max);
  jput(&j, ",\"nr_throttled_delta\":%lld,\"throttled_usec_delta\":%lld,\"loadavg_before\":",
       thr0 >= 0 && thr1 >= 0 ? thr1 - thr0 : -1, thr_us0 >= 0 && thr_us1 >= 0 ? thr_us1 - thr_us0 : -1);
  jstr(&j, load0);
  jput(&j, ",\"loadavg_after\":");
  jstr(&j, load1);
  jput(&j, ",\"per_thread\":[");
  for (int i = 0; i < r->threads; i++) {
    thread_rep* tr = &r->rep[i];
    const char* cl = tr->close_line;
    jput(&j, "%s{\"status\":%d,\"message\":", i ? "," : "", tr->status);
    jstr(&j, tr->message);
    jput(&j,
         ",\"pid\":%lld,\"open_context_ns\":%lld,\"open_instance_ns\":%lld,\"first_call_ns\":%lld,\"cold_ns\":%lld,"
         "\"warm_batches\":%d,\"measured_ns\":%lld,\"engine_cpu_ns\":%lld,\"worker_cpu_ns\":%lld,\"rss_kb\":%lld,"
         "\"pss_kb\":%lld,\"uss_kb\":%lld,\"bad_values\":%lld",
         tr->pid, (long long)tr->open_context_ns, (long long)tr->open_instance_ns, (long long)tr->first_call_ns,
         (long long)tr->cold_ns, tr->warm_batches, (long long)(tr->t_end - tr->t_start),
         (long long)tr->engine_cpu_ns, (long long)tr->worker_cpu_ns, tr->rss_kb, tr->pss_kb, tr->uss_kb,
         tr->bad_values);
    jput(&j,
         ",\"worker_calls\":%lld,\"worker_rows\":%lld,\"worker_decode_ns\":%lld,\"worker_run_ns\":%lld,"
         "\"worker_encode_ns\":%lld,\"worker_idle_ns\":%lld,\"v8_heap_used\":%lld,\"v8_heap_total\":%lld,"
         "\"external\":%lld,\"array_buffers\":%lld,\"worker_rss\":%lld",
         field_of(cl, "calls"), field_of(cl, "rows"), field_of(cl, "decode_ns"), field_of(cl, "run_ns"),
         field_of(cl, "encode_ns"), field_of(cl, "idle_ns"), field_of(cl, "v8_heap_used"),
         field_of(cl, "v8_heap_total"), field_of(cl, "external"), field_of(cl, "array_buffers"), field_of(cl, "rss"));
    jput(&j, ",\"samples_ns\":[");
    for (int k = 0; k < tr->n_samples; k++) jput(&j, "%s%lld", k ? "," : "", (long long)tr->samples[k]);
    jput(&j, "]}");
    free(tr->samples);
  }
  jput(&j, "]}");
  pthread_barrier_destroy(&r->warm);
  pthread_barrier_destroy(&r->done);
  free(r);
  return j.p;
}

__attribute__((visibility("default"))) void kudfw_engine_free(char* p) { free(p); }
