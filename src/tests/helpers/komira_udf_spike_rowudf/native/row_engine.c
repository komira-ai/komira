/*
 * The engine's call loop for a row-shaped UDF over N engine threads, driving
 * a UDF runtime library through komira_udf_runtime.h alone
 * (docs/design/udf_runtime_interface.md section 4.3). Test-only spike code:
 * the tests and the bench reach it through engine.mojo.
 *
 * An input is `width` float64 columns, named by the caller. A run declares
 * a read set (a list of those names): the spec's argument struct names them
 * (load binds it) and every call exports exactly those columns as the
 * struct's children, in read-set order, so only the read set crosses. The
 * rest of the input stays in the engine. Bytes crossed per call are counted
 * from what is exported. Column j holds ((i * (j + 3)) % 97) + 1 at row i.
 *
 * Why C: the engine threads are pthreads started here, and no Mojo code runs
 * on them. Each thread does what an engine thread does with a UDF operator:
 * open_context on itself (contexts are thread-affine), open_instance, then
 * call_batch once per batch, timing each call with CLOCK_MONOTONIC around
 * the table entry alone, checking every output and releasing it. A thread
 * warms up until the medians of three consecutive windows of calls agree
 * within 2% (or a cap), then all threads run their measured batches between
 * two barriers.
 *
 * row_probe.c makes single calls on the calling thread, broken in one known
 * way each, through the same engine (row_engine.h).
 *
 * FFI-BOUNDARY. The runtime library is dlopened once (RTLD_NOW |
 * RTLD_LOCAL) and never closed. The engine, run and per-thread structs,
 * their sample arrays and the input columns are this file's, freed by
 * rowe_close and rowe_run_free; the host struct lives in the engine until
 * close, after shutdown returns. Handles are the runtime's. An exported
 * argument struct's block is freed by its release, which the runtime calls
 * from any thread.
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

#include "row_engine.h"

#define MAX_THREADS 64

/* Run-level fields (thread -1) and per-thread fields of rowe_get. */
enum {
  R_STATUS = 0,
  R_LOAD_NS,
  R_WALL_NS, /* the measured phase */
  R_CPU_USER_NS,
  R_CPU_SYS_NS,
  R_RSS_BEFORE,
  R_RSS_OPEN, /* every context and instance open, one batch each */
  R_CPUS,
  R_COLD_NS, /* engine open (before dlopen) to the end of the first batch; first run only, else -1 */
  R_THREADS,
  R_INVOLUNTARY_SWITCHES,
  R_NR_THROTTLED,   /* cgroup cpu.stat delta over the measured phase; -1 unreadable */
  R_THROTTLED_USEC, /* likewise */
  R_LOADAVG_MILLI,  /* 1-minute load average x 1000 before the run; -1 unreadable */
  R_WIDTH,
  R_READ_FIELDS,
  R_LAST = R_READ_FIELDS
};
enum {
  T_STATUS = 0,
  T_OPEN_CONTEXT_NS,
  T_OPEN_INSTANCE_NS,
  T_FIRST_CALL_NS,
  T_CALLS,
  T_ROWS,
  T_BAD_VALUES,
  T_EXPORTED,
  T_RELEASED,
  T_BYTES,         /* argument bytes exported, every call */
  T_WARMUP_CALLS,  /* calls before the measured phase, the first included */
  T_WARM_STABLE,   /* 1 when three window medians agreed within 2% before the cap */
  T_SAMPLES,
  T_LAST = T_SAMPLES
};

struct thread_state {
  struct run* run;
  int index;
  pthread_t tid;
  int64_t f[T_LAST + 1];
  char message[MSG];
  int64_t* samples;
  double* cols[MAX_COLS]; /* this thread's input, `width` columns of `rows` */
  int64_t first_batch_end;
};

struct run {
  struct engine* e;
  komira_udf_udf* udf;
  int threads, batches, warm_window, warm_cap;
  int64_t rows;
  int width, k;         /* input columns; read-set fields */
  int read[MAX_COLS];   /* the read set, as input column indices */
  int check_p, check_q; /* outputs must equal col p * col q; -1: unchecked */
  pthread_barrier_t opened, warmed, measured;
  int64_t f[R_LAST + 1];
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
  struct engine* e = hd;
  if (!e->script) return now_mono();
  int64_t n = ++e->reads;
  if (e->cancel_at != 0 && n == e->cancel_at && e->cancel_flag != NULL)
    __atomic_store_n(e->cancel_flag, 1, __ATOMIC_RELEASE);
  return e->clock0 + n;
}
static void host_log(void* hd, int32_t level, const char* utf8) {
  __atomic_store_n(&((struct engine*)hd)->last_level, level, __ATOMIC_RELEASE);
  __atomic_add_fetch(&((struct engine*)hd)->logs, 1, __ATOMIC_ACQ_REL);
  fprintf(stderr, "runtime log %d: %s\n", level, utf8 ? utf8 : "");
}

void rowe_take_error(komira_udf_error* err, char* into) {
  snprintf(into, MSG, "%s", err->message ? err->message : "(no message)");
  if (err->release != NULL) err->release(err);
}

/* ---- host facts ---------------------------------------------------------- */

/* The first line of `path` starting with `key` (after it), or of the file
 * when key is "", into out; "" when unreadable. */
static void read_line(const char* path, const char* key, char* out, size_t n) {
  out[0] = 0;
  FILE* f = fopen(path, "r");
  if (f == NULL) return;
  char line[512];
  size_t kl = strlen(key);
  while (fgets(line, sizeof(line), f) != NULL) {
    if (strncmp(line, key, kl) == 0) {
      const char* v = line + kl;
      while (*v == ' ' || *v == '\t' || *v == ':') v++;
      snprintf(out, n, "%s", v);
      size_t l = strlen(out);
      while (l > 0 && (out[l - 1] == '\n' || out[l - 1] == ' ')) out[--l] = 0;
      break;
    }
  }
  fclose(f);
}

static int64_t cpu_stat(const char* key) {
  char v[64];
  read_line("/sys/fs/cgroup/cpu.stat", key, v, sizeof(v));
  return v[0] ? strtoll(v, NULL, 10) : -1;
}

static int64_t loadavg_milli(void) {
  char v[64];
  read_line("/proc/loadavg", "", v, sizeof(v));
  return v[0] ? (int64_t)(strtod(v, NULL) * 1000.0) : -1;
}

/* ---- the engine: open, describe, close ----------------------------------- */

struct engine* rowe_open(const char* path) {
  struct engine* e = calloc(1, sizeof(*e));
  if (e == NULL) return NULL;
  read_line("/proc/cpuinfo", "model name", e->cpu_model, sizeof(e->cpu_model));
  read_line("/sys/fs/cgroup/cpu.max", "", e->cpu_max, sizeof(e->cpu_max));
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
  const int sigs[3] = {SIGINT, SIGPIPE, SIGXFSZ};
  for (int i = 0; i < 3; i++) {
    struct sigaction sa;
    e->signals_before[i] = sigaction(sigs[i], NULL, &sa) == 0 ? sa.sa_handler : NULL;
  }
  komira_udf_error err = {sizeof(komira_udf_error), 0, NULL, NULL, -1, -1, NULL, NULL};
  e->t = init(&e->host, &e->rt, &err);
  e->open_ns = now_mono() - e->t_open;
  if (e->t == NULL) {
    e->status = err.code;
    e->init_row = err.row;
    rowe_take_error(&err, e->message);
    return e;
  }
  e->caps.struct_size = sizeof(e->caps);
  int32_t rc = e->t->describe(e->rt, &e->caps);
  if (rc != KOMIRA_UDF_OK) {
    e->status = rc;
    snprintf(e->message, MSG, "describe returned %d", rc);
  } else if ((e->caps.shapes & KOMIRA_UDF_SHAPE_ROW) == 0) {
    e->status = KOMIRA_UDF_ERR_UNSUPPORTED;
    snprintf(e->message, MSG, "the runtime does not declare the ROW shape");
  }
  return e;
}

int32_t rowe_status(const struct engine* e) { return e == NULL ? KOMIRA_UDF_ERR_OUT_OF_MEMORY : e->status; }
const char* rowe_message(const struct engine* e) { return e == NULL ? "out of memory" : e->message; }
int64_t rowe_open_ns(const struct engine* e) { return e->open_ns; }
int64_t rowe_init_row(const struct engine* e) { return e->init_row; }
const char* rowe_runtime_id(const struct engine* e) { return e->caps.runtime_id ? e->caps.runtime_id : ""; }
/* 0: the CPU model; 1: the cgroup's cpu.max ("" when unreadable). */
const char* rowe_host_fact(const struct engine* e, int32_t which) { return which == 0 ? e->cpu_model : e->cpu_max; }

void rowe_close(struct engine* e) {
  if (e == NULL) return;
  if (e->t != NULL) e->t->shutdown(e->rt);
  free(e); /* the library stays loaded */
}

/* ---- exported inputs ----------------------------------------------------- */

/* One exported argument struct: this header, then k child arrays, k child
 * pointers and k buffer pairs, in one block its release frees. */
struct export_block {
  struct ArrowArray parent;
  int64_t* released;
  const void* pbufs[1];
  struct ArrowArray* child;
  struct ArrowArray** kids;
  const void** cbufs;
};

void rowe_release_child(struct ArrowArray* a) { a->release = NULL; }

static void release_parent(struct ArrowArray* a) {
  struct export_block* b = a->private_data;
  for (int64_t i = 0; i < a->n_children; i++)
    if (b->child[i].release != NULL) b->child[i].release(&b->child[i]);
  __atomic_fetch_add(b->released, 1, __ATOMIC_ACQ_REL);
  a->release = NULL;
  free(b);
}

/* The read set's columns of thread `s`'s input as a struct array in `d`;
 * returns the bytes exported, or -1 when out of memory. */
static int64_t export_args(struct thread_state* s, struct ArrowDeviceArray* d) {
  struct run* r = s->run;
  size_t k = (size_t)r->k;
  struct export_block* b =
      malloc(sizeof(*b) + k * sizeof(struct ArrowArray) + k * sizeof(struct ArrowArray*) + 2 * k * sizeof(void*));
  if (b == NULL) return -1;
  memset(b, 0, sizeof(*b));
  b->child = (struct ArrowArray*)(b + 1);
  b->kids = (struct ArrowArray**)(b->child + k);
  b->cbufs = (const void**)(b->kids + k);
  b->released = &s->f[T_RELEASED];
  for (size_t i = 0; i < k; i++) {
    struct ArrowArray* c = &b->child[i];
    memset(c, 0, sizeof(*c));
    b->cbufs[2 * i] = NULL;
    b->cbufs[2 * i + 1] = s->cols[r->read[i]];
    c->length = r->rows;
    c->n_buffers = 2;
    c->buffers = &b->cbufs[2 * i];
    c->release = rowe_release_child;
    c->private_data = b;
    b->kids[i] = c;
  }
  b->pbufs[0] = NULL;
  b->parent.length = r->rows;
  b->parent.n_buffers = 1;
  b->parent.buffers = b->pbufs;
  b->parent.n_children = r->k;
  b->parent.children = b->kids;
  b->parent.release = release_parent;
  b->parent.private_data = b;
  memset(d, 0, sizeof(*d));
  d->array = b->parent;
  d->device_id = -1;
  d->device_type = ARROW_DEVICE_CPU;
  return (int64_t)r->k * r->rows * 8;
}

/* ---- one engine thread --------------------------------------------------- */

static void fail_thread(struct thread_state* s, int32_t code, const char* msg) {
  if (s->f[T_STATUS] == 0) {
    s->f[T_STATUS] = code;
    snprintf(s->message, MSG, "%s", msg);
  }
}

static const char* check_output(struct thread_state* s, const struct ArrowArray* o) {
  struct run* r = s->run;
  if (o->length != r->rows) return "an output with another row count";
  if (o->n_buffers != 2 || o->buffers[1] == NULL || o->n_children != 0) return "an output that is not one column";
  if (r->check_p < 0 || r->check_q < 0) return NULL;
  const double* v = (const double*)o->buffers[1] + o->offset;
  const double* p = s->cols[r->check_p];
  const double* q = s->cols[r->check_q];
  for (int64_t i = 0; i < r->rows; i++)
    if (v[i] != p[i] * q[i]) s->f[T_BAD_VALUES]++;
  return NULL;
}

/* One call: export, call_batch (timed), check, release. Returns the ns. */
static int64_t one_call(struct thread_state* s, komira_udf_instance* inst) {
  const komira_udf_runtime* t = s->run->e->t;
  struct ArrowDeviceArray args, out;
  memset(&out, 0, sizeof(out));
  int64_t bytes = export_args(s, &args);
  if (bytes < 0) {
    fail_thread(s, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "export: out of memory");
    return 0;
  }
  s->f[T_EXPORTED]++;
  s->f[T_BYTES] += bytes;
  int32_t cancel = 0;
  komira_udf_call call = {sizeof(komira_udf_call), 0, s->f[T_CALLS] + 1, &cancel};
  komira_udf_error err = {sizeof(komira_udf_error), 0, NULL, NULL, -1, -1, NULL, NULL};
  int64_t t0 = now_mono();
  int32_t rc = t->call_batch(inst, &call, &args, &out, &err);
  int64_t ns = now_mono() - t0;
  s->f[T_CALLS]++;
  if (args.array.release != NULL) {
    args.array.release(&args.array);
    fail_thread(s, KOMIRA_UDF_ERR_INTERNAL, "UDF_RUNTIME_FAULT: args not moved by call_batch");
  }
  if (rc != KOMIRA_UDF_OK) {
    char m[MSG];
    rowe_take_error(&err, m);
    fail_thread(s, rc, m);
    if (out.array.release != NULL) out.array.release(&out.array);
    return ns;
  }
  if (out.array.release == NULL) {
    fail_thread(s, KOMIRA_UDF_ERR_INTERNAL, "UDF_RUNTIME_FAULT: OK without an output");
    return ns;
  }
  const char* bad = out.device_type == ARROW_DEVICE_CPU ? check_output(s, &out.array) : "an output not on the CPU";
  if (bad != NULL) fail_thread(s, KOMIRA_UDF_ERR_INTERNAL, bad);
  s->f[T_ROWS] += s->run->rows;
  out.array.release(&out.array);
  return ns;
}

static int cmp_i64(const void* a, const void* b) {
  int64_t x = *(const int64_t*)a, y = *(const int64_t*)b;
  return x < y ? -1 : x > y;
}

/* Warm-up: windows of warm_window calls until the last three windows'
 * medians agree within 2%, or warm_cap windows. */
static void warm_up(struct thread_state* s, komira_udf_instance* inst) {
  struct run* r = s->run;
  int64_t win[64];
  int w = r->warm_window < 1 ? 1 : r->warm_window > 64 ? 64 : r->warm_window;
  int64_t med[3] = {0, 0, 0};
  for (int k = 0; k < r->warm_cap && s->f[T_STATUS] == 0; k++) {
    for (int i = 0; i < w; i++) win[i] = one_call(s, inst);
    qsort(win, (size_t)w, sizeof(int64_t), cmp_i64);
    med[0] = med[1];
    med[1] = med[2];
    med[2] = win[w / 2];
    if (k >= 2) {
      int64_t lo = med[0], hi = med[0];
      for (int j = 1; j < 3; j++) {
        if (med[j] < lo) lo = med[j];
        if (med[j] > hi) hi = med[j];
      }
      if (lo > 0 && (double)hi <= 1.02 * (double)lo) {
        s->f[T_WARM_STABLE] = 1;
        return;
      }
    }
  }
}

static void* engine_thread(void* p) {
  struct thread_state* s = p;
  struct run* r = s->run;
  const komira_udf_runtime* t = r->e->t;
  int ok = 1;
  for (int j = 0; j < r->width; j++) {
    s->cols[j] = malloc((size_t)(r->rows > 0 ? r->rows : 1) * sizeof(double));
    if (s->cols[j] == NULL) {
      ok = 0;
      continue;
    }
    for (int64_t i = 0; i < r->rows; i++) s->cols[j][i] = (double)((i * (j + 3)) % 97) + 1.0;
  }
  komira_udf_context* ctx = NULL;
  komira_udf_instance* inst = NULL;
  komira_udf_error err = {sizeof(komira_udf_error), 0, NULL, NULL, -1, -1, NULL, NULL};
  int64_t t0 = now_mono();
  int32_t rc = !ok ? KOMIRA_UDF_ERR_OUT_OF_MEMORY : t->open_context(r->e->rt, (uint32_t)s->index, &ctx, &err);
  s->f[T_OPEN_CONTEXT_NS] = now_mono() - t0;
  if (rc != KOMIRA_UDF_OK) {
    char m[MSG];
    if (ok) rowe_take_error(&err, m);
    fail_thread(s, rc, ok ? m : "input: out of memory");
  } else {
    t0 = now_mono();
    rc = t->open_instance(ctx, r->udf, &inst, &err);
    s->f[T_OPEN_INSTANCE_NS] = now_mono() - t0;
    if (rc != KOMIRA_UDF_OK) {
      char m[MSG];
      rowe_take_error(&err, m);
      fail_thread(s, rc, m);
    }
  }
  if (inst != NULL) {
    s->f[T_FIRST_CALL_NS] = one_call(s, inst);
    s->first_batch_end = now_mono();
  }
  pthread_barrier_wait(&r->opened);
  if (inst != NULL) warm_up(s, inst);
  s->f[T_WARMUP_CALLS] = s->f[T_CALLS];
  pthread_barrier_wait(&r->warmed);
  for (int i = 0; inst != NULL && i < r->batches && s->f[T_STATUS] == 0; i++)
    s->samples[s->f[T_SAMPLES]++] = one_call(s, inst);
  pthread_barrier_wait(&r->measured);
  if (inst != NULL) t->close_instance(inst);
  if (ctx != NULL) t->close_context(ctx);
  for (int j = 0; j < r->width; j++) free(s->cols[j]);
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

/* Splits a comma-separated list in place into at most `max` names. */
int rowe_split(char* s, char** out, int max) {
  int n = 0;
  if (s[0] == 0) return 0;
  for (char* p = s; n < max;) {
    out[n++] = p;
    char* c = strchr(p, ',');
    if (c == NULL) break;
    *c = 0;
    p = c + 1;
  }
  return n;
}

static int index_of(char** names, int n, const char* name) {
  for (int i = 0; i < n; i++)
    if (strcmp(names[i], name) == 0) return i;
  return -1;
}

/* Loads `entry` with the `k` names of `read` (float64 each) as its argument
 * struct; on failure fills `msg` and returns the status. */
int32_t rowe_load_read_set(struct engine* e, const char* entry, char** read, int k, komira_udf_udf** out,
                             char* msg) {
  struct ArrowSchema kids_s[MAX_COLS];
  struct ArrowSchema* kids[MAX_COLS];
  for (int i = 0; i < k; i++) {
    struct ArrowSchema c = {"g", read[i], NULL, ARROW_FLAG_NULLABLE, 0, NULL, NULL, no_release, NULL};
    kids_s[i] = c;
    kids[i] = &kids_s[i];
  }
  struct ArrowSchema args = {"+s", "", NULL, 0, k, kids, NULL, no_release, NULL};
  struct ArrowSchema result = {"g", "", NULL, ARROW_FLAG_NULLABLE, 0, NULL, NULL, no_release, NULL};
  komira_udf_spec s;
  memset(&s, 0, sizeof(s));
  s.struct_size = sizeof(s);
  s.shape = (int32_t)KOMIRA_UDF_SHAPE_ROW;
  s.form = KOMIRA_UDF_FORM_BUNDLE;
  s.entry = entry;
  s.args = &args;
  s.result = &result;
  s.null_mode = KOMIRA_UDF_NULL_MANUAL;
  s.stability = KOMIRA_UDF_IMMUTABLE;
  s.code_root = "";
  komira_udf_error err = {sizeof(komira_udf_error), 0, NULL, NULL, -1, -1, NULL, NULL};
  int32_t rc = e->t->load(e->rt, &s, out, &err);
  if (rc != KOMIRA_UDF_OK) {
    rowe_take_error(&err, msg);
    *out = NULL;
  }
  return rc;
}

/* Loads the run's UDF; on failure sets R_STATUS and the message. */
static void run_load(struct run* r, const char* entry, char** read) {
  int64_t t0 = now_mono();
  int32_t rc = rowe_load_read_set(r->e, entry, read, r->k, &r->udf, r->message);
  r->f[R_LOAD_NS] = now_mono() - t0;
  if (rc != KOMIRA_UDF_OK) r->f[R_STATUS] = rc;
}

/* One run: `input` (comma-separated, `width` names) and the read set
 * `read_set` (comma-separated names of the input). Outputs are checked
 * against input columns check_p * check_q when both are named. */
struct run* rowe_run(struct engine* e, const char* entry, const char* input_csv, const char* read_csv,
                     const char* check_p, const char* check_q, int32_t threads, int64_t rows, int32_t batches,
                     int32_t warm_window, int32_t warm_cap) {
  struct run* r = calloc(1, sizeof(*r));
  if (r == NULL) return NULL;
  r->e = e;
  r->threads = threads < 1 ? 1 : threads > MAX_THREADS ? MAX_THREADS : threads;
  r->batches = batches < 0 ? 0 : batches;
  r->warm_window = warm_window;
  r->warm_cap = warm_cap < 0 ? 0 : warm_cap;
  r->rows = rows;
  r->f[R_THREADS] = r->threads;
  r->f[R_COLD_NS] = -1;
  cpu_set_t set;
  r->f[R_CPUS] = sched_getaffinity(0, sizeof(set), &set) == 0 ? CPU_COUNT(&set) : -1;
  if (e == NULL || e->status != KOMIRA_UDF_OK) {
    r->f[R_STATUS] = e == NULL ? KOMIRA_UDF_ERR_OUT_OF_MEMORY : e->status;
    snprintf(r->message, MSG, "%s", rowe_message(e));
    return r;
  }
  char* in_copy = strdup(input_csv);
  char* rs_copy = strdup(read_csv);
  char* input[MAX_COLS];
  char* read[MAX_COLS];
  r->width = in_copy ? rowe_split(in_copy, input, MAX_COLS) : 0;
  r->k = rs_copy ? rowe_split(rs_copy, read, MAX_COLS) : 0;
  r->f[R_WIDTH] = r->width;
  r->f[R_READ_FIELDS] = r->k;
  for (int i = 0; i < r->k; i++) {
    r->read[i] = index_of(input, r->width, read[i]);
    if (r->read[i] < 0) {
      r->f[R_STATUS] = KOMIRA_UDF_ERR_INTERNAL;
      snprintf(r->message, MSG, "the read set names %s; the input has no such column", read[i]);
    }
  }
  r->check_p = index_of(input, r->width, check_p);
  r->check_q = index_of(input, r->width, check_q);
  if (r->f[R_STATUS] == 0) run_load(r, entry, read);
  free(in_copy);
  free(rs_copy);
  if (r->udf == NULL) return r;

  r->f[R_RSS_BEFORE] = rss_bytes();
  r->f[R_LOADAVG_MILLI] = loadavg_milli();
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
  int64_t thr0 = cpu_stat("nr_throttled"), tus0 = cpu_stat("throttled_usec");
  getrusage(RUSAGE_SELF, &u0);
  int64_t w0 = now_mono();
  pthread_barrier_wait(&r->measured);
  r->f[R_WALL_NS] = now_mono() - w0;
  getrusage(RUSAGE_SELF, &u1);
  int64_t thr1 = cpu_stat("nr_throttled"), tus1 = cpu_stat("throttled_usec");
  r->f[R_NR_THROTTLED] = thr0 < 0 || thr1 < 0 ? -1 : thr1 - thr0;
  r->f[R_THROTTLED_USEC] = tus0 < 0 || tus1 < 0 ? -1 : tus1 - tus0;
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

int64_t rowe_get(const struct run* r, int32_t thread, int32_t field) {
  if (thread < 0) return field >= 0 && field <= R_LAST ? r->f[field] : 0;
  if (thread >= r->threads || field < 0 || field > T_LAST) return 0;
  if (field == T_RELEASED) return __atomic_load_n(&r->th[thread].f[T_RELEASED], __ATOMIC_ACQUIRE);
  return r->th[thread].f[field];
}

const char* rowe_run_message(const struct run* r, int32_t thread) {
  return thread < 0 ? r->message : r->th[thread].message;
}

int64_t rowe_sample(const struct run* r, int32_t thread, int64_t i) {
  if (thread < 0 || thread >= r->threads || i < 0 || i >= r->th[thread].f[T_SAMPLES]) return 0;
  return r->th[thread].samples[i];
}

void rowe_run_free(struct run* r) {
  if (r == NULL) return;
  for (int i = 0; i < r->threads; i++) free(r->th[i].samples);
  free(r);
}

