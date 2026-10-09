/*
 * The engine's call loop over N engine threads, driving any UDF runtime
 * library through komira_udf_runtime.h alone
 * (docs/design/udf_runtime_interface.md section 4.3). Test-only spike code:
 * the Node tests and the bench reach it through engine_host.c.
 *
 * Why C: the engine threads are pthreads started here, and no Mojo code runs
 * on them. Each thread does what an engine thread does with a UDF operator:
 * open_context on itself, open_instance, then call_batch once per batch,
 * timing each call with CLOCK_MONOTONIC around the table entry alone,
 * checking every output and releasing it.
 *
 * Inputs are exported per call without a copy: a struct array of primitive
 * children over the thread's own values buffer, whose release (called by the
 * runtime, from any thread, at any time) frees the call's small block and
 * counts. The values are base + step * row.
 *
 * FFI-BOUNDARY. The runtime library is dlopened once (RTLD_NOW | RTLD_LOCAL)
 * and never closed; in a Node process it is the library node loaded as an
 * addon, so dlopen returns the handle node holds. The engine, run and
 * per-thread structs, their sample arrays and the values buffers are this
 * file's, freed by kudf_engine_close and kudf_run_free; the host struct
 * lives in the engine until close, after shutdown returns. Handles are the
 * runtime's.
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

#include "engine_loop.h"
#include "headers/komira_udf_runtime.h" /* the abi package's :headers, staged as headers/ */

#define MAX_CHILDREN 4
#define WINDOW 8 /* warm-up: calls per window */

struct engine {
  void* lib;
  const komira_udf_runtime* t;
  komira_udf_rt* rt;
  komira_udf_host host;
  int32_t status;
  char message[ENGINE_MSG];
  int64_t t_open;  /* before dlopen */
  int64_t open_ns; /* dlopen + init */
  int runs;
  komira_udf_capabilities caps;
};

struct thread_state {
  struct run* run;
  int index;
  pthread_t tid;
  int64_t f[T_FIELDS];
  char message[ENGINE_MSG];
  int64_t* samples;
  int64_t first_batch_end; /* monotonic ns */
  struct ArrowDeviceArray* held; /* outputs kept past close (run_opts.hold) */
  int n_held;
};

struct run {
  struct engine* e;
  komira_udf_udf* udf;
  komira_udf_spec spec;
  struct run_opts o;
  char entry[256];
  char arg_names[256];
  int threads;
  pthread_barrier_t opened, warmed, measured;
  int64_t f[R_FIELDS];
  char message[ENGINE_MSG];
  struct thread_state th[ENGINE_MAX_THREADS];
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
  snprintf(into, ENGINE_MSG, "%s", err->message ? err->message : "(no message)");
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
    snprintf(e->message, ENGINE_MSG, "dlopen %s: %s", path, dlerror());
    return e;
  }
  __typeof__(&komira_udf_runtime_init_v1) init =
      (__typeof__(&komira_udf_runtime_init_v1))dlsym(e->lib, "komira_udf_runtime_init_v1");
  if (init == NULL) {
    e->status = KOMIRA_UDF_ERR_LOAD;
    snprintf(e->message, ENGINE_MSG, "%s exports no komira_udf_runtime_init_v1", path);
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
    snprintf(e->message, ENGINE_MSG, "describe returned %d", rc);
  } else if (e->caps.threading == KOMIRA_UDF_THREAD_SAFE && e->caps.global_lock != 0) {
    /* design section 4.2: THREAD_SAFE requires no global lock */
    e->status = KOMIRA_UDF_ERR_INTERNAL;
    snprintf(e->message, ENGINE_MSG, "UDF_RUNTIME_FAULT: THREAD_SAFE with global_lock 1");
  }
  return e;
}

int32_t kudf_engine_status(const struct engine* e) { return e == NULL ? KOMIRA_UDF_ERR_OUT_OF_MEMORY : e->status; }
const char* kudf_engine_message(const struct engine* e) { return e == NULL ? "out of memory" : e->message; }
int64_t kudf_engine_open_ns(const struct engine* e) { return e->open_ns; }
const char* kudf_engine_runtime_id(const struct engine* e) { return e->caps.runtime_id ? e->caps.runtime_id : ""; }

/* threading, global_lock, thread_affine, udf_class, hosting, shapes, features */
int64_t kudf_engine_cap(const struct engine* e, int32_t which) {
  switch (which) {
    case 0: return e->caps.threading;
    case 1: return e->caps.global_lock;
    case 2: return e->caps.thread_affine;
    case 3: return e->caps.udf_class;
    case 4: return e->caps.hosting;
    case 5: return e->caps.shapes;
    default: return e->caps.features;
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
  struct ArrowArray child[MAX_CHILDREN];
  struct ArrowArray* kids[MAX_CHILDREN];
  const void* pbufs[1];
  const void* cbufs[MAX_CHILDREN][2];
  int64_t* released; /* the thread's counter */
};

static void release_child(struct ArrowArray* a) { a->release = NULL; }

static void release_parent(struct ArrowArray* a) {
  struct export_block* b = a->private_data;
  __atomic_fetch_add(b->released, 1, __ATOMIC_ACQ_REL);
  a->release = NULL;
  free(b);
}

/* What one thread's arguments are made of. */
struct inputs {
  void* values[MAX_CHILDREN];
  uint8_t* valid; /* NULL: no nulls */
  int64_t nulls;
};

static int export_args(const struct run_opts* o, struct ArrowDeviceArray* d, const struct inputs* in, int64_t* released) {
  struct export_block* b = calloc(1, sizeof(*b));
  if (b == NULL) return 0;
  b->released = released;
  for (int k = 0; k < o->n_args; k++) {
    b->cbufs[k][0] = in->valid;
    b->cbufs[k][1] = in->values[o->dup_cols ? 0 : k];
    b->child[k].length = o->rows;
    b->child[k].null_count = in->nulls;
    b->child[k].offset = o->offset;
    b->child[k].n_buffers = 2;
    b->child[k].buffers = b->cbufs[k];
    b->child[k].release = release_child;
    b->kids[k] = &b->child[k];
  }
  b->pbufs[0] = NULL;
  b->parent.length = o->rows;
  b->parent.n_buffers = 1;
  b->parent.buffers = b->pbufs;
  b->parent.n_children = o->n_args;
  b->parent.children = o->n_args > 0 ? b->kids : NULL;
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

static void fill_values(const struct run_opts* o, void* values, int k) {
  int64_t total = o->offset + o->rows;
  for (int64_t i = 0; i < total; i++) {
    double x = i < o->offset ? -777.0 : o->base + o->step * (double)(i - o->offset) + (double)k;
    if (o->arg_fmt == 'g')
      ((double*)values)[i] = x;
    else if (o->arg_fmt == 'i')
      ((int32_t*)values)[i] = (int32_t)x;
    else
      ((int64_t*)values)[i] = (int64_t)x;
  }
}

static int make_inputs(const struct run_opts* o, struct inputs* in) {
  memset(in, 0, sizeof(*in));
  size_t w = o->arg_fmt == 'i' ? 4 : 8;
  size_t bytes = (size_t)(o->offset + (o->rows > 0 ? o->rows : 1)) * w + 8;
  int n = o->dup_cols ? 1 : o->n_args;
  for (int k = 0; k < n; k++) {
    in->values[k] = calloc(1, bytes);
    if (in->values[k] == NULL) return 0;
    fill_values(o, in->values[k], k);
  }
  if (o->null_every > 0) {
    size_t vb = (size_t)((o->offset + o->rows + 7) >> 3) + 1;
    in->valid = malloc(vb);
    if (in->valid == NULL) return 0;
    memset(in->valid, 0xFF, vb);
    for (int64_t r = 0; r < o->rows; r += o->null_every) {
      int64_t at = o->offset + r;
      in->valid[at >> 3] &= (uint8_t)~(1u << (at & 7));
      in->nulls++;
    }
  }
  return 1;
}

static void free_inputs(struct inputs* in) {
  for (int k = 0; k < MAX_CHILDREN; k++) free(in->values[k]);
  free(in->valid);
}

/* ---- one engine thread --------------------------------------------------- */

static void fail_thread(struct thread_state* s, int32_t code, const char* msg) {
  if (s->f[T_STATUS] == 0) {
    s->f[T_STATUS] = code;
    snprintf(s->message, ENGINE_MSG, "%s", msg);
  }
}

static const char* check_output(struct thread_state* s, const struct ArrowArray* o, int64_t* prev, int* have_prev,
                                int first_call) {
  const struct run_opts* opt = &s->run->o;
  int64_t rows = opt->rows;
  if (o->length != rows) return "an output with another row count";
  if (o->n_buffers != 2 || o->n_children != 0) return "an output that is not one column";
  if (rows > 0 && o->buffers[1] == NULL) return "an output without values";
  const int64_t* vi = (const int64_t*)o->buffers[1] + o->offset;
  const double* vf = (const double*)o->buffers[1] + o->offset;
  if (opt->check == CHECK_RECORD && rows > 0) {
    int64_t v = opt->result_fmt == 'g' ? (int64_t)vf[0] : vi[0];
    if (first_call) s->f[T_FIRST_VALUE] = v;
    s->f[T_LAST_VALUE] = v;
  }
  for (int64_t i = 0; i < rows; i++) {
    if (opt->check == CHECK_AFFINE) {
      double x = opt->base + opt->step * (double)i;
      double want = opt->a * x + opt->b;
      double got = opt->result_fmt == 'g' ? vf[i] : (double)vi[i];
      double scale = want < 0 ? -want : want;
      if (scale < 1) scale = 1;
      double diff = got - want;
      if (diff < 0) diff = -diff;
      if (diff > 1e-9 * scale) s->f[T_BAD_VALUES]++;
    } else if (opt->check == CHECK_NULLS) {
      int want_null = opt->null_every > 0 && (i % opt->null_every) == 0;
      const uint8_t* v = o->buffers[0];
      int64_t at = o->offset + i;
      int valid = v == NULL || ((v[at >> 3] >> (at & 7)) & 1);
      if (want_null == valid) {
        s->f[T_BAD_VALUES]++;
      } else if (!want_null) {
        double x = opt->base + opt->step * (double)i;
        double want = opt->a * x + opt->b;
        double got = opt->result_fmt == 'g' ? vf[i] : (double)vi[i];
        if (got != want) s->f[T_BAD_VALUES]++;
      }
    } else if (opt->check == CHECK_COUNTER) {
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

/* One call: export, call_batch (timed), check, release. Returns the ns. */
static int64_t one_call(struct thread_state* s, komira_udf_instance* inst, const struct inputs* in, int64_t* prev,
                        int* have_prev, int hold) {
  struct run* r = s->run;
  const komira_udf_runtime* t = r->e->t;
  struct ArrowDeviceArray args, out;
  memset(&out, 0, sizeof(out));
  if (!export_args(&r->o, &args, in, &s->f[T_RELEASED])) {
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
  int first_call = s->f[T_CALLS] == 0;
  s->f[T_CALLS]++;
  if (args.array.release != NULL) {
    /* not moved: still ours */
    args.array.release(&args.array);
    fail_thread(s, KOMIRA_UDF_ERR_INTERNAL, "UDF_RUNTIME_FAULT: args not moved by call_batch");
  }
  if (rc != KOMIRA_UDF_OK) {
    char m[ENGINE_MSG];
    take_error(&err, m);
    fail_thread(s, rc, m);
    if (out.array.release != NULL) out.array.release(&out.array);
    return ns;
  }
  if (out.array.release == NULL) {
    fail_thread(s, KOMIRA_UDF_ERR_INTERNAL, "UDF_RUNTIME_FAULT: OK without an output");
    return ns;
  }
  const char* bad = out.device_type == ARROW_DEVICE_CPU ? check_output(s, &out.array, prev, have_prev, first_call)
                                                         : "an output not on the CPU";
  if (bad != NULL) fail_thread(s, KOMIRA_UDF_ERR_INTERNAL, bad);
  s->f[T_ROWS] += r->o.rows;
  if (hold && s->held != NULL && s->n_held < r->o.batches) s->held[s->n_held++] = out;
  else out.array.release(&out.array);
  return ns;
}

static int cmp_i64(const void* a, const void* b) {
  int64_t x = *(const int64_t*)a, y = *(const int64_t*)b;
  return x < y ? -1 : x > y;
}

/* Warm up until three consecutive windows of WINDOW calls have medians
 * within 2% of each other (V8 tiers a hot function up in steps), or the
 * cap; at least `warmup_min` calls in all. */
static void warm_up(struct thread_state* s, komira_udf_instance* inst, const struct inputs* in, int64_t* prev,
                    int* have_prev) {
  const struct run_opts* o = &s->run->o;
  int64_t med[3] = {0, 0, 0};
  int windows = 0;
  while (s->f[T_STATUS] == 0 && s->f[T_CALLS] < o->warmup_cap) {
    int64_t w[WINDOW];
    int n = 0;
    while (n < WINDOW && s->f[T_CALLS] < o->warmup_cap && s->f[T_STATUS] == 0) w[n++] = one_call(s, inst, in, prev, have_prev, 0);
    if (n < WINDOW) break;
    qsort(w, WINDOW, sizeof(w[0]), cmp_i64);
    med[windows % 3] = w[WINDOW / 2];
    windows++;
    if (windows >= 3 && s->f[T_CALLS] >= o->warmup_min) {
      int64_t lo = med[0], hi = med[0];
      for (int k = 1; k < 3; k++) {
        if (med[k] < lo) lo = med[k];
        if (med[k] > hi) hi = med[k];
      }
      if ((double)(hi - lo) <= 0.02 * (double)hi) break;
    }
  }
  s->f[T_WARMUP_CALLS] = s->f[T_CALLS];
}

static int64_t memory_of(const struct engine* e, komira_udf_context* ctx) {
  if (e->t->struct_size < sizeof(komira_udf_runtime) || e->t->memory_report == NULL) return -1;
  return e->t->memory_report(ctx);
}

static void* engine_thread(void* p) {
  struct thread_state* s = p;
  struct run* r = s->run;
  const komira_udf_runtime* t = r->e->t;
  s->f[T_INCREASING] = 1;
  struct inputs in;
  int have_inputs = make_inputs(&r->o, &in);
  komira_udf_context* ctx = NULL;
  komira_udf_instance* inst = NULL;
  komira_udf_error err = {sizeof(komira_udf_error), 0, NULL, NULL, -1, -1, NULL, NULL};
  int64_t t0 = now_mono();
  int32_t rc = !have_inputs ? KOMIRA_UDF_ERR_OUT_OF_MEMORY : t->open_context(r->e->rt, (uint32_t)s->index, &ctx, &err);
  s->f[T_OPEN_CONTEXT_NS] = now_mono() - t0;
  if (rc != KOMIRA_UDF_OK) {
    char m[ENGINE_MSG];
    take_error(&err, m);
    fail_thread(s, rc, m);
  } else {
    t0 = now_mono();
    rc = t->open_instance(ctx, r->udf, &inst, &err);
    s->f[T_OPEN_INSTANCE_NS] = now_mono() - t0;
    if (rc != KOMIRA_UDF_OK) {
      char m[ENGINE_MSG];
      take_error(&err, m);
      fail_thread(s, rc, m);
    }
  }
  int64_t prev = 0;
  int have_prev = 0;
  int ok = inst != NULL;
  if (ok) {
    s->f[T_FIRST_CALL_NS] = one_call(s, inst, &in, &prev, &have_prev, 0);
    s->first_batch_end = now_mono();
    s->f[T_MEMORY_REPORT] = memory_of(r->e, ctx);
  }
  pthread_barrier_wait(&r->opened);
  if (ok) warm_up(s, inst, &in, &prev, &have_prev);
  pthread_barrier_wait(&r->warmed);
  for (int i = 0; ok && i < r->o.batches && s->f[T_STATUS] == 0; i++)
    s->samples[s->f[T_SAMPLES]++] = one_call(s, inst, &in, &prev, &have_prev, r->o.hold);
  pthread_barrier_wait(&r->measured);
  if (inst != NULL) t->close_instance(inst);
  if (ctx != NULL) t->close_context(ctx);
  free_inputs(&in);
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

/* The process's PSS in KiB, from smaps_rollup; -1 when unreadable. */
static int64_t pss_kib(void) {
  FILE* f = fopen("/proc/self/smaps_rollup", "r");
  char line[256];
  long kb = -1;
  if (f == NULL) return -1;
  while (fgets(line, sizeof(line), f) != NULL)
    if (sscanf(line, "Pss: %ld kB", &kb) == 1) break;
  fclose(f);
  return kb;
}

static int64_t tv_ns(struct timeval tv) { return (int64_t)tv.tv_sec * 1000000000LL + (int64_t)tv.tv_usec * 1000; }

static void no_release(struct ArrowSchema* s) { (void)s; }

/* Build the spec of `o` (n_args arguments, one result) and validate it or
 * load it. */
static int32_t call_spec(struct engine* e, const struct run_opts* o, int validate_only, komira_udf_spec* s,
                         komira_udf_udf** udf, char* message) {
  char names[MAX_CHILDREN][64] = {"x0", "x1", "x2", "x3"};
  if (o->arg_names != NULL && o->arg_names[0] != 0) {
    const char* p = o->arg_names;
    for (int k = 0; k < MAX_CHILDREN && *p != 0; k++) {
      const char* comma = strchr(p, ',');
      size_t n = comma != NULL ? (size_t)(comma - p) : strlen(p);
      if (n > 63) n = 63;
      memcpy(names[k], p, n);
      names[k][n] = 0;
      p = comma != NULL ? comma + 1 : p + strlen(p);
    }
  }
  char arg_format[2] = {o->arg_fmt, 0};
  char res_format[2] = {o->result_fmt, 0};
  struct ArrowSchema child[MAX_CHILDREN];
  struct ArrowSchema* kids[MAX_CHILDREN];
  for (int k = 0; k < o->n_args && k < MAX_CHILDREN; k++) {
    memset(&child[k], 0, sizeof(child[k]));
    child[k].format = arg_format;
    child[k].name = names[k];
    child[k].flags = ARROW_FLAG_NULLABLE;
    child[k].release = no_release;
    kids[k] = &child[k];
  }
  struct ArrowSchema args;
  memset(&args, 0, sizeof(args));
  args.format = "+s";
  args.name = "";
  args.n_children = o->n_args;
  args.children = kids;
  args.release = no_release;
  struct ArrowSchema result;
  memset(&result, 0, sizeof(result));
  result.format = res_format;
  result.name = "";
  result.flags = ARROW_FLAG_NULLABLE;
  result.release = no_release;
  static const char* const roles[1] = {"bundle"};
  static const uint8_t digest[1][32] = {{0}};
  static const uint8_t descriptor[8] = {0};
  memset(s, 0, sizeof(*s));
  s->struct_size = sizeof(*s);
  s->shape = o->shape;
  s->form = o->form;
  s->entry = o->entry;
  s->descriptor_version = (uint32_t)o->descriptor_version;
  s->descriptor = descriptor;
  s->descriptor_len = o->descriptor_len > 8 ? 8 : (size_t)o->descriptor_len;
  s->args = &args;
  s->result = &result;
  s->null_mode = KOMIRA_UDF_NULL_MANUAL;
  s->stability = KOMIRA_UDF_IMMUTABLE;
  s->code_root = "";
  s->n_code = o->n_code > 0 ? 1 : 0;
  s->code_roles = roles;
  s->code_sha256 = digest;
  komira_udf_error err = {sizeof(komira_udf_error), 0, NULL, NULL, -1, -1, NULL, NULL};
  int32_t rc = validate_only ? e->t->validate(e->rt, s, &err) : e->t->load(e->rt, s, udf, &err);
  s->args = s->result = NULL; /* borrowed for the call only */
  s->entry = NULL;
  if (rc != KOMIRA_UDF_OK) take_error(&err, message);
  return rc;
}

static int32_t load_udf(struct engine* e, const struct run_opts* o, komira_udf_spec* s, komira_udf_udf** udf,
                        char* message) {
  return call_spec(e, o, 0, s, udf, message);
}

int32_t kudf_validate(struct engine* e, const struct run_opts* o, char* message) {
  komira_udf_spec spec;
  message[0] = 0;
  if (e == NULL || e->status != KOMIRA_UDF_OK) return KOMIRA_UDF_ERR_INTERNAL;
  return call_spec(e, o, 1, &spec, NULL, message);
}

struct run* kudf_run(struct engine* e, const struct run_opts* o) {
  struct run* r = calloc(1, sizeof(*r));
  if (r == NULL) return NULL;
  r->e = e;
  r->o = *o;
  snprintf(r->entry, sizeof(r->entry), "%s", o->entry);
  r->o.entry = r->entry;
  snprintf(r->arg_names, sizeof(r->arg_names), "%s", o->arg_names != NULL ? o->arg_names : "");
  r->o.arg_names = r->arg_names;
  if (r->o.n_args < 0) r->o.n_args = 0;
  if (r->o.n_args > MAX_CHILDREN) r->o.n_args = MAX_CHILDREN;
  r->threads = o->threads < 1 ? 1 : o->threads > ENGINE_MAX_THREADS ? ENGINE_MAX_THREADS : o->threads;
  if (r->o.warmup_min < 1) r->o.warmup_min = 1;
  if (r->o.warmup_cap < r->o.warmup_min) r->o.warmup_cap = r->o.warmup_min;
  if (r->o.batches < 0) r->o.batches = 0;
  r->f[R_THREADS] = r->threads;
  r->f[R_COLD_NS] = -1;
  r->f[R_MEMORY_REPORT] = -1;
  cpu_set_t set;
  r->f[R_CPUS] = sched_getaffinity(0, sizeof(set), &set) == 0 ? CPU_COUNT(&set) : -1;
  if (e == NULL || e->status != KOMIRA_UDF_OK) {
    r->f[R_STATUS] = e == NULL ? KOMIRA_UDF_ERR_OUT_OF_MEMORY : e->status;
    snprintf(r->message, ENGINE_MSG, "%s", kudf_engine_message(e));
    return r;
  }
  int64_t t0 = now_mono();
  int32_t rc = load_udf(e, &r->o, &r->spec, &r->udf, r->message);
  r->f[R_LOAD_NS] = now_mono() - t0;
  if (rc != KOMIRA_UDF_OK) {
    r->f[R_STATUS] = rc;
    return r;
  }
  r->f[R_RSS_BEFORE] = rss_bytes();
  r->f[R_PSS_BEFORE] = pss_kib();
  pthread_barrier_init(&r->opened, NULL, (unsigned)r->threads + 1);
  pthread_barrier_init(&r->warmed, NULL, (unsigned)r->threads + 1);
  pthread_barrier_init(&r->measured, NULL, (unsigned)r->threads + 1);
  int64_t open0 = now_mono();
  for (int i = 0; i < r->threads; i++) {
    struct thread_state* th = &r->th[i];
    th->run = r;
    th->index = i;
    th->samples = calloc((size_t)(r->o.batches > 0 ? r->o.batches : 1), sizeof(int64_t));
    if (r->o.hold) th->held = calloc((size_t)(r->o.batches > 0 ? r->o.batches : 1), sizeof(*th->held));
    pthread_create(&th->tid, NULL, engine_thread, th);
  }
  pthread_barrier_wait(&r->opened);
  r->f[R_OPEN_WALL_NS] = now_mono() - open0;
  r->f[R_RSS_OPEN] = rss_bytes();
  r->f[R_PSS_OPEN] = pss_kib();
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
  /* Outputs kept past the close of their context and the unload of their UDF:
   * still readable, and released now (design section 4.4: release runs on
   * any thread, at any time, until shutdown begins). */
  for (int i = 0; i < r->threads; i++) {
    struct thread_state* th = &r->th[i];
    int64_t prev = 0;
    int have_prev = 0;
    for (int k = 0; k < th->n_held; k++) {
      const char* bad = check_output(th, &th->held[k].array, &prev, &have_prev, 0);
      if (bad != NULL) fail_thread(th, KOMIRA_UDF_ERR_INTERNAL, bad);
      th->held[k].array.release(&th->held[k].array);
    }
    free(th->held);
    th->held = NULL;
  }
  int64_t mem = 0;
  int have_mem = 0;
  for (int i = 0; i < r->threads; i++) {
    if (r->th[i].f[T_MEMORY_REPORT] >= 0) {
      mem += r->th[i].f[T_MEMORY_REPORT];
      have_mem = 1;
    }
    if (r->th[i].f[T_STATUS] != 0 && r->f[R_STATUS] == 0) {
      r->f[R_STATUS] = r->th[i].f[T_STATUS];
      snprintf(r->message, ENGINE_MSG, "thread %d: %s", i, r->th[i].message);
    }
  }
  r->f[R_MEMORY_REPORT] = have_mem ? mem : -1;
  return r;
}

int64_t kudf_run_get(const struct run* r, int32_t thread, int32_t field) {
  if (thread < 0) return field >= 0 && field < R_FIELDS ? r->f[field] : 0;
  if (thread >= r->threads || field < 0 || field >= T_FIELDS) return 0;
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

/* ---- a call that is cancelled while it runs ------------------------------- */

struct timer {
  int32_t* flag;
  int32_t after_ms;
};

static void* cancel_timer(void* p) {
  struct timer* t = p;
  struct timespec ts = {t->after_ms / 1000, (long)(t->after_ms % 1000) * 1000000L};
  nanosleep(&ts, NULL);
  __atomic_store_n(t->flag, 1, __ATOMIC_RELEASE);
  return NULL;
}

void kudf_cancel_probe(struct engine* e, const struct run_opts* o, int32_t cancel_after_ms, int64_t* out,
                       char* message) {
  struct run_opts opt = *o;
  komira_udf_spec spec;
  komira_udf_udf* udf = NULL;
  komira_udf_context* ctx = NULL;
  komira_udf_instance* inst = NULL;
  komira_udf_error err = {sizeof(komira_udf_error), 0, NULL, NULL, -1, -1, NULL, NULL};
  out[P_STATUS] = KOMIRA_UDF_ERR_INTERNAL;
  out[P_ELAPSED_NS] = 0;
  out[P_ROW] = -1;
  message[0] = 0;
  if (e == NULL || e->status != KOMIRA_UDF_OK) return;
  int32_t rc = load_udf(e, &opt, &spec, &udf, message);
  if (rc != KOMIRA_UDF_OK) {
    out[P_STATUS] = rc;
    return;
  }
  rc = e->t->open_context(e->rt, 0, &ctx, &err);
  if (rc == KOMIRA_UDF_OK) rc = e->t->open_instance(ctx, udf, &inst, &err);
  if (rc != KOMIRA_UDF_OK) {
    take_error(&err, message);
    out[P_STATUS] = rc;
  } else {
    struct inputs in;
    int64_t released = 0;
    struct ArrowDeviceArray args, res;
    memset(&res, 0, sizeof(res));
    if (make_inputs(&opt, &in) && export_args(&opt, &args, &in, &released)) {
      int32_t flag = 0;
      struct timer tm = {&flag, cancel_after_ms};
      pthread_t tid;
      int armed = pthread_create(&tid, NULL, cancel_timer, &tm) == 0;
      komira_udf_call call = {sizeof(komira_udf_call), 0, 1, &flag};
      int64_t t0 = now_mono();
      rc = e->t->call_batch(inst, &call, &args, &res, &err);
      out[P_ELAPSED_NS] = now_mono() - t0;
      out[P_STATUS] = rc;
      if (rc != KOMIRA_UDF_OK) {
        out[P_ROW] = err.row;
        take_error(&err, message);
      }
      if (res.array.release != NULL) res.array.release(&res.array);
      if (armed) pthread_join(tid, NULL);
    }
    free_inputs(&in);
  }
  if (inst != NULL) e->t->close_instance(inst);
  if (ctx != NULL) e->t->close_context(ctx);
  if (udf != NULL) e->t->unload(udf);
}

int32_t kudf_open_context_here(struct engine* e, char* message) {
  komira_udf_context* ctx = NULL;
  komira_udf_error err = {sizeof(komira_udf_error), 0, NULL, NULL, -1, -1, NULL, NULL};
  message[0] = 0;
  int32_t rc = e->t->open_context(e->rt, 0, &ctx, &err);
  if (rc != KOMIRA_UDF_OK) take_error(&err, message);
  else e->t->close_context(ctx);
  return rc;
}
