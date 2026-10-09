/*
 * The engine loop the worker runtime's tests and bench drive it with: any
 * UDF runtime library, through komira_udf_runtime.h alone, on N engine
 * threads (pthreads started here; no Mojo code runs on them). Test-only
 * spike code.
 *
 * Unlike the in-process runtime's loop it binds specs of any code form
 * (VALUE with a code object by digest), and it measures what a worker
 * transport costs (docs/design/udf_runtime_interface.md section 9):
 *   - each call_batch timed with CLOCK_MONOTONIC around the table entry
 *     alone; warm-up until three consecutive window medians agree within 2%
 *     (capped), then the measured batches;
 *   - CPU time: this process (getrusage) and every process below it (the
 *     workers, from /proc/<pid>/stat), over the measured phase;
 *   - memory of every process below this one at the moment every context
 *     is open with its instance and one batch done: PSS, USS
 *     (Private_Clean + Private_Dirty) and RSS from /proc/<pid>/smaps_rollup,
 *     with the worker's role from its command line;
 *   - co-tenancy: the cgroup's cpu.max and cpu.stat throttling counters
 *     before and after, the load average, the affinity mask's size and the
 *     CPU model;
 *   - cold start: per context, open_context to the end of its first batch;
 *     for the engine, open (before dlopen) to the end of the first run's
 *     first batch.
 * A run is configured by `key=value` lines and reported as one JSON object.
 *
 * FFI-BOUNDARY. The runtime library is dlopened once (RTLD_NOW |
 * RTLD_LOCAL) and never closed. The engine and run structs, the report
 * strings and the input buffers are this file's: kpw_close frees the engine
 * (after shutdown returns), kpw_free frees a report. Handles are the
 * runtime's.
 */
#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <dlfcn.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdarg.h>
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
#define MAX_LOGS 64

static int64_t now_mono(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

/* ---- a JSON writer ------------------------------------------------------- */

struct js {
  char* p;
  size_t len, cap;
};

static void js_add(struct js* j, const char* fmt, ...) {
  va_list ap;
  for (;;) {
    size_t room = j->cap - j->len;
    va_start(ap, fmt);
    int n = vsnprintf(j->p ? j->p + j->len : NULL, j->p ? room : 0, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if (j->p && (size_t)n < room) {
      j->len += (size_t)n;
      return;
    }
    size_t c = j->cap ? j->cap * 2 : 4096;
    while (c < j->len + (size_t)n + 1) c *= 2;
    char* q = realloc(j->p, c);
    if (q == NULL) return;
    j->p = q;
    j->cap = c;
  }
}

static void js_str(struct js* j, const char* s) {
  js_add(j, "\"");
  for (; s && *s; s++) {
    unsigned char c = (unsigned char)*s;
    if (c == '"' || c == '\\') js_add(j, "\\%c", c);
    else if (c < 0x20) js_add(j, " ");
    else js_add(j, "%c", c);
  }
  js_add(j, "\"");
}

/* ---- the engine ---------------------------------------------------------- */

struct engine {
  void* lib;
  const komira_udf_runtime* t;
  komira_udf_rt* rt;
  komira_udf_host host;
  int32_t status;
  char message[MSG];
  int64_t t_open, open_ns;
  int runs;
  komira_udf_capabilities caps;
  pthread_mutex_t log_lock;
  char* logs[MAX_LOGS];
  int n_logs;
  int64_t log_total;
};

static int32_t host_reserve(void* hd, int64_t b) {
  (void)hd, (void)b;
  return KOMIRA_UDF_OK;
}
static void host_release(void* hd, int64_t b) { (void)hd, (void)b; }
static int64_t host_now(void* hd) {
  (void)hd;
  return now_mono();
}
static void host_log(void* hd, int32_t level, const char* utf8) {
  struct engine* e = hd;
  (void)level;
  pthread_mutex_lock(&e->log_lock);
  e->log_total++;
  if (e->n_logs < MAX_LOGS) e->logs[e->n_logs++] = strdup(utf8 ? utf8 : "");
  pthread_mutex_unlock(&e->log_lock);
}

static void take_error(komira_udf_error* err, char* into) {
  snprintf(into, MSG, "%s", err->message ? err->message : "(no message)");
  if (err->release != NULL) err->release(err);
}

struct engine* kpw_open(const char* path) {
  struct engine* e = calloc(1, sizeof(*e));
  if (e == NULL) return NULL;
  pthread_mutex_init(&e->log_lock, NULL);
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
  e->host = (komira_udf_host){sizeof(komira_udf_host), KOMIRA_UDF_ABI_MAJOR, KOMIRA_UDF_ABI_MINOR, e,
                              host_reserve, host_release, host_now, host_log};
  komira_udf_error err = {sizeof(err), 0, NULL, NULL, -1, -1, NULL, NULL};
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
  }
  return e;
}

int32_t kpw_status(const struct engine* e) { return e == NULL ? KOMIRA_UDF_ERR_OUT_OF_MEMORY : e->status; }
const char* kpw_message(const struct engine* e) { return e == NULL ? "out of memory" : e->message; }

void kpw_close(struct engine* e) {
  if (e == NULL) return;
  if (e->t != NULL) e->t->shutdown(e->rt);
  for (int i = 0; i < e->n_logs; i++) free(e->logs[i]);
  free(e); /* the library stays loaded */
}

int32_t kpw_pid_alive(int32_t pid) { return pid > 0 && kill(pid, 0) == 0; }
int32_t kpw_self_pid(void) { return (int32_t)getpid(); }

/* ---- /proc --------------------------------------------------------------- */

static int read_file(const char* path, char* buf, size_t n) {
  FILE* f = fopen(path, "r");
  if (f == NULL) return -1;
  size_t r = fread(buf, 1, n - 1, f);
  fclose(f);
  buf[r] = 0;
  return (int)r;
}

/* (ppid, utime + stime in ns) of a process, from /proc/<pid>/stat. */
static int proc_stat(int pid, int* ppid, int64_t* cpu_ns) {
  char path[64], buf[2048];
  snprintf(path, sizeof(path), "/proc/%d/stat", pid);
  if (read_file(path, buf, sizeof(buf)) <= 0) return 0;
  char* p = strrchr(buf, ')');
  if (p == NULL) return 0;
  long long f[20];
  char st;
  /* fields after the comm: state ppid pgrp session tty tpgid flags minflt
   * cminflt majflt cmajflt utime stime */
  if (sscanf(p + 2, "%c %lld %lld %lld %lld %lld %lld %lld %lld %lld %lld %lld %lld", &st, &f[0], &f[1], &f[2],
             &f[3], &f[4], &f[5], &f[6], &f[7], &f[8], &f[9], &f[10], &f[11]) != 13)
    return 0;
  *ppid = (int)f[0];
  *cpu_ns = (f[10] + f[11]) * (1000000000LL / sysconf(_SC_CLK_TCK));
  return 1;
}

/* Every process below this one (any depth), at most `max`. */
static int descendants(int* out, int max) {
  int n = 0;
  int me = getpid();
  int parents[256];
  int np = 0;
  parents[np++] = me;
  for (int round = 0; round < 4 && n < max; round++) {
    DIR* d = opendir("/proc");
    if (d == NULL) return n;
    struct dirent* de;
    int added = 0;
    while ((de = readdir(d)) != NULL && n < max) {
      if (!isdigit((unsigned char)de->d_name[0])) continue;
      int pid = atoi(de->d_name), ppid;
      int64_t cpu;
      if (!proc_stat(pid, &ppid, &cpu)) continue;
      int below = 0, known = 0;
      for (int i = 0; i < np; i++) below |= parents[i] == ppid;
      for (int i = 0; i < n; i++) known |= out[i] == pid;
      if (below && !known) {
        out[n++] = pid;
        if (np < 256) parents[np++] = pid;
        added = 1;
      }
    }
    closedir(d);
    if (!added) break;
  }
  return n;
}

/* CPU time of the processes below this one: a snapshot, then the sum of
 * each one's growth since it (processes in both only). */
struct cpu_snap {
  int n;
  int pids[256];
  int64_t ns[256];
};

static void workers_cpu_snap(struct cpu_snap* s) {
  s->n = descendants(s->pids, 256);
  for (int i = 0; i < s->n; i++) {
    int ppid;
    if (!proc_stat(s->pids[i], &ppid, &s->ns[i])) s->ns[i] = -1;
  }
}

static int64_t workers_cpu_since(const struct cpu_snap* s) {
  int64_t sum = 0;
  for (int i = 0; i < s->n; i++) {
    int ppid;
    int64_t c;
    if (s->ns[i] >= 0 && proc_stat(s->pids[i], &ppid, &c) && c >= s->ns[i]) sum += c - s->ns[i];
  }
  return sum;
}

static int64_t smaps_kb(const char* text, const char* key) {
  const char* p = strstr(text, key);
  return p ? atoll(p + strlen(key)) : -1;
}

static void role_of(int pid, char* out, size_t n) {
  char path[64], buf[4096];
  snprintf(path, sizeof(path), "/proc/%d/cmdline", pid);
  int r = read_file(path, buf, sizeof(buf));
  snprintf(out, n, "?");
  for (int i = 0; r > 0 && i < r; i += (int)strlen(buf + i) + 1)
    if (strcmp(buf + i, "--role") == 0 && i + 7 < r) snprintf(out, n, "%s", buf + i + 7);
}

static void memory_json(struct js* j) {
  int pids[256], ppids[256];
  char roles[256][32];
  int n = descendants(pids, 256);
  for (int i = 0; i < n; i++) {
    int64_t cpu;
    ppids[i] = 0;
    proc_stat(pids[i], &ppids[i], &cpu);
    role_of(pids[i], roles[i], sizeof(roles[i]));
  }
  /* A forked worker keeps its zygote's command line: a "zygote" whose
   * parent is a zygote is a context worker. */
  for (int i = 0; i < n; i++)
    for (int k = 0; k < n; k++)
      if (ppids[i] == pids[k] && strcmp(roles[i], "zygote") == 0 && strcmp(roles[k], "zygote") == 0)
        snprintf(roles[i], sizeof(roles[i]), "context");
  js_add(j, "[");
  for (int i = 0; i < n; i++) {
    char path[64], buf[4096];
    snprintf(path, sizeof(path), "/proc/%d/smaps_rollup", pids[i]);
    if (read_file(path, buf, sizeof(buf)) <= 0) buf[0] = 0;
    const char* role = roles[i];
    int ppid = ppids[i];
    int64_t uss = smaps_kb(buf, "Private_Clean:") + smaps_kb(buf, "Private_Dirty:");
    js_add(j, "%s{\"pid\": %d, \"ppid\": %d, \"role\": ", i ? ", " : "", pids[i], ppid);
    js_str(j, role);
    js_add(j, ", \"pss_kb\": %lld, \"uss_kb\": %lld, \"rss_kb\": %lld}", (long long)smaps_kb(buf, "Pss:"),
           (long long)uss, (long long)smaps_kb(buf, "Rss:"));
  }
  js_add(j, "]");
}

/* The cgroup's cpu.max and its throttling counters. */
static void cgroup_read(char* max, size_t n, int64_t* nr_throttled, int64_t* throttled_us) {
  char buf[4096], path[1200], stat[2048];
  snprintf(max, n, "unknown");
  *nr_throttled = *throttled_us = -1;
  if (read_file("/proc/self/cgroup", buf, sizeof(buf)) <= 0) return;
  char* p = strstr(buf, "0::");
  if (p == NULL) return;
  p += 3;
  char* nl = strchr(p, '\n');
  if (nl) *nl = 0;
  snprintf(path, sizeof(path), "/sys/fs/cgroup%s/cpu.max", p);
  if (read_file(path, max, n) > 0) {
    char* q = strchr(max, '\n');
    if (q) *q = 0;
  }
  snprintf(path, sizeof(path), "/sys/fs/cgroup%s/cpu.stat", p);
  if (read_file(path, stat, sizeof(stat)) > 0) {
    *nr_throttled = smaps_kb(stat, "nr_throttled ");
    *throttled_us = smaps_kb(stat, "throttled_usec ");
  }
}

static void cpu_model(char* out, size_t n) {
  char buf[8192];
  snprintf(out, n, "unknown");
  if (read_file("/proc/cpuinfo", buf, sizeof(buf)) <= 0) return;
  char* p = strstr(buf, "model name");
  if (p == NULL) return;
  p = strchr(p, ':');
  if (p == NULL) return;
  p += 2;
  char* nl = strchr(p, '\n');
  if (nl) *nl = 0;
  snprintf(out, n, "%s", p);
}

/* ---- a run's configuration ----------------------------------------------- */

enum { CHECK_NONE = 0, CHECK_AFFINE = 1, CHECK_COUNTER = 2 };

struct config {
  char entry[256];
  char code_root[1024];
  uint8_t sha[32];
  int has_code;
  int form, shape, threads, warmup_fixed, warmup_cap, window, batches, check;
  char arg_fmt, result_fmt;
  int64_t rows;
  double a, b, base, step;
};

static int hexval(char c) {
  return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;
}

static void parse_config(const char* text, struct config* c) {
  memset(c, 0, sizeof(*c));
  c->form = KOMIRA_UDF_FORM_BUNDLE;
  c->shape = KOMIRA_UDF_SHAPE_SCALAR;
  c->threads = 1;
  c->warmup_cap = 200;
  c->window = 10;
  c->batches = 30;
  c->arg_fmt = c->result_fmt = 'g';
  c->rows = 1;
  c->a = 1;
  const char* p = text;
  while (*p) {
    const char* nl = strchr(p, '\n');
    size_t len = nl ? (size_t)(nl - p) : strlen(p);
    char line[1200];
    snprintf(line, sizeof(line), "%.*s", (int)(len < sizeof(line) - 1 ? len : sizeof(line) - 1), p);
    char* eq = strchr(line, '=');
    if (eq) {
      *eq = 0;
      const char* k = line;
      const char* v = eq + 1;
      if (!strcmp(k, "entry")) snprintf(c->entry, sizeof(c->entry), "%s", v);
      else if (!strcmp(k, "code_root")) snprintf(c->code_root, sizeof(c->code_root), "%s", v);
      else if (!strcmp(k, "code_sha256") && strlen(v) == 64) {
        c->has_code = 1;
        for (int i = 0; i < 32; i++) c->sha[i] = (uint8_t)(hexval(v[2 * i]) * 16 + hexval(v[2 * i + 1]));
      } else if (!strcmp(k, "form")) c->form = atoi(v);
      else if (!strcmp(k, "shape")) c->shape = atoi(v);
      else if (!strcmp(k, "threads")) c->threads = atoi(v);
      else if (!strcmp(k, "warmup_fixed")) c->warmup_fixed = atoi(v);
      else if (!strcmp(k, "warmup_cap")) c->warmup_cap = atoi(v);
      else if (!strcmp(k, "window")) c->window = atoi(v);
      else if (!strcmp(k, "batches")) c->batches = atoi(v);
      else if (!strcmp(k, "check")) c->check = atoi(v);
      else if (!strcmp(k, "arg_fmt")) c->arg_fmt = v[0];
      else if (!strcmp(k, "result_fmt")) c->result_fmt = v[0];
      else if (!strcmp(k, "rows")) c->rows = atoll(v);
      else if (!strcmp(k, "a")) c->a = atof(v);
      else if (!strcmp(k, "b")) c->b = atof(v);
      else if (!strcmp(k, "base")) c->base = atof(v);
      else if (!strcmp(k, "step")) c->step = atof(v);
    }
    p += len + (nl ? 1 : 0);
  }
  if (c->threads < 1) c->threads = 1;
  if (c->threads > MAX_THREADS) c->threads = MAX_THREADS;
  if (c->window < 1) c->window = 1;
}

/* ---- one engine thread --------------------------------------------------- */

struct thread_state {
  struct run* run;
  int index;
  pthread_t tid;
  int32_t status;
  char message[MSG];
  int64_t open_context_ns, open_instance_ns, first_call_ns, cold_ns, first_batch_end;
  int64_t calls, rows, bad_values, first_value, last_value, exported, released;
  int increasing, warmup_calls, warm;
  int64_t* samples;
  int n_samples;
};

struct run {
  struct engine* e;
  struct config cfg;
  komira_udf_udf* udf;
  pthread_barrier_t opened, warmed, measured;
  struct thread_state th[MAX_THREADS];
};

struct export_block {
  struct ArrowArray parent, child;
  struct ArrowArray* kids[1];
  const void* pbufs[1];
  const void* cbufs[2];
  int64_t* released;
};

static void release_child(struct ArrowArray* a) { a->release = NULL; }

static void release_parent(struct ArrowArray* a) {
  struct export_block* b = a->private_data;
  if (b->child.release != NULL) b->child.release(&b->child);
  __atomic_fetch_add(b->released, 1, __ATOMIC_ACQ_REL);
  a->release = NULL;
  free(b);
}

/* The argument struct: one primitive child over the thread's values. */
static int export_args(struct ArrowDeviceArray* d, const void* values, int64_t rows, int64_t* released) {
  struct export_block* b = calloc(1, sizeof(*b));
  if (b == NULL) return 0;
  b->released = released;
  b->cbufs[1] = values;
  b->child = (struct ArrowArray){rows, 0, 0, 2, 0, b->cbufs, NULL, NULL, release_child, b};
  b->kids[0] = &b->child;
  b->parent = (struct ArrowArray){rows, 0, 0, 1, 1, b->pbufs, b->kids, NULL, release_parent, b};
  memset(d, 0, sizeof(*d));
  d->array = b->parent;
  d->device_id = -1;
  d->device_type = ARROW_DEVICE_CPU;
  return 1;
}

static void fail_thread(struct thread_state* s, int32_t code, const char* msg) {
  if (s->status == 0) {
    s->status = code;
    snprintf(s->message, MSG, "%s", msg);
  }
}

static void check_output(struct thread_state* s, const struct ArrowArray* o, const void* in, int* have_prev) {
  const struct config* c = &s->run->cfg;
  if (o->length != c->rows || o->n_buffers != 2 || o->buffers[1] == NULL || o->n_children != 0) {
    fail_thread(s, KOMIRA_UDF_ERR_INTERNAL, "an output that is not one column of the input's rows");
    return;
  }
  const int64_t* vi = (const int64_t*)o->buffers[1] + o->offset;
  const double* vf = (const double*)o->buffers[1] + o->offset;
  for (int64_t i = 0; i < c->rows; i++) {
    if (c->check == CHECK_AFFINE) {
      double x = c->arg_fmt == 'g' ? ((const double*)in)[i] : (double)((const int64_t*)in)[i];
      double want = c->a * x + c->b;
      double got = c->result_fmt == 'g' ? vf[i] : (double)vi[i];
      double scale = want < 0 ? -want : want;
      if (scale < 1) scale = 1;
      double diff = got - want;
      if ((diff < 0 ? -diff : diff) > 1e-9 * scale) s->bad_values++;
    } else if (c->check == CHECK_COUNTER) {
      int64_t v = vi[i];
      if (!*have_prev) s->first_value = v;
      if (*have_prev && v <= s->last_value) s->increasing = 0;
      s->last_value = v;
      *have_prev = 1;
    }
  }
}

static int64_t one_call(struct thread_state* s, komira_udf_instance* inst, const void* values, int* have_prev) {
  struct run* r = s->run;
  const komira_udf_runtime* t = r->e->t;
  struct ArrowDeviceArray args, out;
  memset(&out, 0, sizeof(out));
  if (!export_args(&args, values, r->cfg.rows, &s->released)) {
    fail_thread(s, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "export: out of memory");
    return 0;
  }
  s->exported++;
  int32_t cancel = 0;
  komira_udf_call call = {sizeof(call), 0, s->calls + 1, &cancel};
  komira_udf_error err = {sizeof(err), 0, NULL, NULL, -1, -1, NULL, NULL};
  int64_t t0 = now_mono();
  int32_t rc = t->call_batch(inst, &call, &args, &out, &err);
  int64_t ns = now_mono() - t0;
  s->calls++;
  if (args.array.release != NULL) {
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
  check_output(s, &out.array, values, have_prev);
  s->rows += r->cfg.rows;
  out.array.release(&out.array);
  return ns;
}

static int cmp64(const void* a, const void* b) {
  int64_t x = *(const int64_t*)a, y = *(const int64_t*)b;
  return x < y ? -1 : x > y;
}

static int64_t median_of(int64_t* xs, int n) {
  qsort(xs, (size_t)n, sizeof(int64_t), cmp64);
  return xs[n / 2];
}

/* Warm-up: fixed, or windows until three consecutive window medians agree
 * within 2% (max <= 1.02 x min), at most warmup_cap calls. */
static void warm_up(struct thread_state* s, komira_udf_instance* inst, const void* values, int* have_prev) {
  const struct config* c = &s->run->cfg;
  if (c->warmup_fixed > 0) {
    for (int i = 0; i < c->warmup_fixed && s->status == 0; i++) one_call(s, inst, values, have_prev);
    s->warmup_calls = c->warmup_fixed;
    s->warm = 1;
    return;
  }
  int64_t win[256], med[3];
  int w = c->window > 256 ? 256 : c->window;
  int k = 0;
  while (s->warmup_calls + w <= c->warmup_cap && s->status == 0) {
    for (int i = 0; i < w; i++) win[i] = one_call(s, inst, values, have_prev);
    s->warmup_calls += w;
    med[k % 3] = median_of(win, w);
    k++;
    if (k >= 3) {
      int64_t lo = med[0], hi = med[0];
      for (int i = 1; i < 3; i++) {
        if (med[i] < lo) lo = med[i];
        if (med[i] > hi) hi = med[i];
      }
      if ((double)hi <= 1.02 * (double)lo) {
        s->warm = 1;
        return;
      }
    }
  }
}

static void* engine_thread(void* p) {
  struct thread_state* s = p;
  struct run* r = s->run;
  const struct config* c = &r->cfg;
  const komira_udf_runtime* t = r->e->t;
  s->increasing = 1;
  void* values = malloc((size_t)(c->rows > 0 ? c->rows : 1) * 8);
  for (int64_t i = 0; values != NULL && i < c->rows; i++) {
    double x = c->base + c->step * (double)i;
    if (c->arg_fmt == 'g') ((double*)values)[i] = x;
    else ((int64_t*)values)[i] = (int64_t)x;
  }
  komira_udf_context* ctx = NULL;
  komira_udf_instance* inst = NULL;
  komira_udf_error err = {sizeof(err), 0, NULL, NULL, -1, -1, NULL, NULL};
  int64_t t0 = now_mono();
  int32_t rc = values == NULL ? KOMIRA_UDF_ERR_OUT_OF_MEMORY : t->open_context(r->e->rt, (uint32_t)s->index, &ctx, &err);
  s->open_context_ns = now_mono() - t0;
  if (rc != KOMIRA_UDF_OK) {
    char m[MSG];
    take_error(&err, m);
    fail_thread(s, rc, m);
  } else {
    int64_t t1 = now_mono();
    rc = t->open_instance(ctx, r->udf, &inst, &err);
    s->open_instance_ns = now_mono() - t1;
    if (rc != KOMIRA_UDF_OK) {
      char m[MSG];
      take_error(&err, m);
      fail_thread(s, rc, m);
    }
  }
  int have_prev = 0;
  if (inst != NULL) {
    s->first_call_ns = one_call(s, inst, values, &have_prev);
    s->first_batch_end = now_mono();
    s->cold_ns = s->first_batch_end - t0;
  }
  pthread_barrier_wait(&r->opened);
  if (inst != NULL && s->status == 0) warm_up(s, inst, values, &have_prev);
  pthread_barrier_wait(&r->warmed);
  for (int i = 0; inst != NULL && i < c->batches && s->status == 0; i++)
    s->samples[s->n_samples++] = one_call(s, inst, values, &have_prev);
  pthread_barrier_wait(&r->measured);
  if (inst != NULL) t->close_instance(inst);
  if (ctx != NULL) t->close_context(ctx);
  free(values);
  return NULL;
}

/* ---- a run --------------------------------------------------------------- */

static int64_t tv_ns(struct timeval tv) { return (int64_t)tv.tv_sec * 1000000000LL + (int64_t)tv.tv_usec * 1000; }

static void no_release(struct ArrowSchema* s) { (void)s; }

static void drain_logs(struct engine* e, struct js* j) {
  pthread_mutex_lock(&e->log_lock);
  js_add(j, "\"logs_total\": %lld, \"logs\": [", (long long)e->log_total);
  for (int i = 0; i < e->n_logs; i++) {
    js_add(j, i ? ", " : "");
    js_str(j, e->logs[i]);
    free(e->logs[i]);
  }
  js_add(j, "]");
  e->n_logs = 0;
  e->log_total = 0;
  pthread_mutex_unlock(&e->log_lock);
}

static void thread_json(struct js* j, const struct thread_state* s) {
  js_add(j, "{\"status\": %d, \"message\": ", s->status);
  js_str(j, s->message);
  js_add(j,
         ", \"open_context_ns\": %lld, \"open_instance_ns\": %lld, \"first_call_ns\": %lld, \"cold_ns\": %lld"
         ", \"calls\": %lld, \"rows\": %lld, \"bad_values\": %lld, \"first_value\": %lld, \"last_value\": %lld"
         ", \"increasing\": %s, \"exported\": %lld, \"released\": %lld, \"warmup_calls\": %d, \"warm\": %s"
         ", \"samples\": [",
         (long long)s->open_context_ns, (long long)s->open_instance_ns, (long long)s->first_call_ns,
         (long long)s->cold_ns, (long long)s->calls, (long long)s->rows, (long long)s->bad_values,
         (long long)s->first_value, (long long)s->last_value, s->increasing ? "true" : "false",
         (long long)s->exported, (long long)__atomic_load_n(&s->released, __ATOMIC_ACQUIRE), s->warmup_calls,
         s->warm ? "true" : "false");
  for (int i = 0; i < s->n_samples; i++) js_add(j, "%s%lld", i ? ", " : "", (long long)s->samples[i]);
  js_add(j, "]}");
}

/* Runs one configured workload; returns its JSON report (kpw_free). */
char* kpw_run(struct engine* e, const char* config) {
  struct js j = {0};
  struct run* r = calloc(1, sizeof(*r));
  if (r == NULL) return NULL;
  parse_config(config, &r->cfg);
  struct config* c = &r->cfg;
  r->e = e;
  cpu_set_t set;
  int cpus = sched_getaffinity(0, sizeof(set), &set) == 0 ? CPU_COUNT(&set) : -1;
  js_add(&j, "{\"threads\": %d, \"rows_per_batch\": %lld, \"cpus\": %d", c->threads, (long long)c->rows, cpus);
  if (e == NULL || e->status != KOMIRA_UDF_OK) {
    js_add(&j, ", \"status\": %d, \"message\": ", kpw_status(e));
    js_str(&j, kpw_message(e));
    js_add(&j, "}");
    free(r);
    return j.p;
  }
  char af[2] = {c->arg_fmt, 0}, rf[2] = {c->result_fmt, 0};
  struct ArrowSchema child = {af, "x", NULL, ARROW_FLAG_NULLABLE, 0, NULL, NULL, no_release, NULL};
  struct ArrowSchema* kids[1] = {&child};
  struct ArrowSchema args = {"+s", "", NULL, 0, 1, kids, NULL, no_release, NULL};
  struct ArrowSchema result = {rf, "", NULL, ARROW_FLAG_NULLABLE, 0, NULL, NULL, no_release, NULL};
  const char* roles[1] = {"payload"};
  const uint8_t(*shas)[32] = (const uint8_t(*)[32])c->sha;
  komira_udf_spec spec = {sizeof(spec), c->shape, c->form, c->entry, 0, NULL, 0, &args, &result, NULL,
                          KOMIRA_UDF_NULL_MANUAL, KOMIRA_UDF_IMMUTABLE, c->code_root, c->has_code ? 1u : 0u,
                          roles, shas};
  komira_udf_error err = {sizeof(err), 0, NULL, NULL, -1, -1, NULL, NULL};
  int64_t t0 = now_mono();
  int32_t rc = e->t->load(e->rt, &spec, &r->udf, &err);
  int64_t load_ns = now_mono() - t0;
  js_add(&j, ", \"load_ns\": %lld, \"open_ns\": %lld, \"runtime_id\": ", (long long)load_ns, (long long)e->open_ns);
  js_str(&j, e->caps.runtime_id ? e->caps.runtime_id : "");
  js_add(&j,
         ", \"threading\": %u, \"global_lock\": %u, \"thread_affine\": %u, \"transports\": %u, \"hosting\": %u"
         ", \"udf_class\": %u",
         e->caps.threading, e->caps.global_lock, e->caps.thread_affine, e->caps.transports, e->caps.hosting,
         e->caps.udf_class);
  if (rc != KOMIRA_UDF_OK) {
    char m[MSG];
    take_error(&err, m);
    js_add(&j, ", \"status\": %d, \"message\": ", rc);
    js_str(&j, m);
    js_add(&j, ", ");
    drain_logs(e, &j);
    js_add(&j, "}");
    free(r);
    return j.p;
  }
  pthread_barrier_init(&r->opened, NULL, (unsigned)c->threads + 1);
  pthread_barrier_init(&r->warmed, NULL, (unsigned)c->threads + 1);
  pthread_barrier_init(&r->measured, NULL, (unsigned)c->threads + 1);
  for (int i = 0; i < c->threads; i++) {
    struct thread_state* s = &r->th[i];
    s->run = r;
    s->index = i;
    s->samples = calloc((size_t)(c->batches > 0 ? c->batches : 1), sizeof(int64_t));
    pthread_create(&s->tid, NULL, engine_thread, s);
  }
  pthread_barrier_wait(&r->opened);
  struct js mem = {0};
  memory_json(&mem);
  int64_t cold = (e->runs == 0 && r->th[0].first_batch_end != 0) ? r->th[0].first_batch_end - e->t_open : -1;
  pthread_barrier_wait(&r->warmed);
  char cmax[64];
  int64_t thr0, thu0, thr1, thu1;
  cgroup_read(cmax, sizeof(cmax), &thr0, &thu0);
  struct rusage u0, u1;
  getrusage(RUSAGE_SELF, &u0);
  struct cpu_snap snap;
  workers_cpu_snap(&snap);
  int64_t w0 = now_mono();
  pthread_barrier_wait(&r->measured);
  int64_t wall = now_mono() - w0;
  getrusage(RUSAGE_SELF, &u1);
  int64_t wcpu = workers_cpu_since(&snap);
  cgroup_read(cmax, sizeof(cmax), &thr1, &thu1);
  for (int i = 0; i < c->threads; i++) pthread_join(r->th[i].tid, NULL);
  pthread_barrier_destroy(&r->opened);
  pthread_barrier_destroy(&r->warmed);
  pthread_barrier_destroy(&r->measured);
  e->t->unload(r->udf);
  e->runs++;
  int32_t status = 0;
  const char* message = "";
  for (int i = 0; i < c->threads && status == 0; i++)
    if (r->th[i].status != 0) {
      status = r->th[i].status;
      message = r->th[i].message;
    }
  char loadavg[128] = "", model[160];
  if (read_file("/proc/loadavg", loadavg, sizeof(loadavg)) > 0) {
    char* q = strchr(loadavg, '\n');
    if (q) *q = 0;
  }
  cpu_model(model, sizeof(model));
  js_add(&j, ", \"status\": %d, \"message\": ", status);
  js_str(&j, message);
  js_add(&j,
         ", \"engine_cold_ns\": %lld, \"wall_ns\": %lld, \"engine_cpu_user_ns\": %lld, \"engine_cpu_sys_ns\": %lld"
         ", \"workers_cpu_ns\": %lld, \"involuntary_switches\": %ld, \"cgroup_cpu_max\": ",
         (long long)cold, (long long)wall, (long long)(tv_ns(u1.ru_utime) - tv_ns(u0.ru_utime)),
         (long long)(tv_ns(u1.ru_stime) - tv_ns(u0.ru_stime)), (long long)wcpu,
         u1.ru_nivcsw - u0.ru_nivcsw);
  js_str(&j, cmax);
  js_add(&j, ", \"nr_throttled_delta\": %lld, \"throttled_us_delta\": %lld, \"loadavg\": ",
         (long long)(thr1 >= 0 && thr0 >= 0 ? thr1 - thr0 : -1), (long long)(thu1 >= 0 && thu0 >= 0 ? thu1 - thu0 : -1));
  js_str(&j, loadavg);
  js_add(&j, ", \"cpu_model\": ");
  js_str(&j, model);
  js_add(&j, ", \"processes\": %s, ", mem.p ? mem.p : "[]");
  free(mem.p);
  drain_logs(e, &j);
  js_add(&j, ", \"per_thread\": [");
  for (int i = 0; i < c->threads; i++) {
    js_add(&j, i ? ", " : "");
    thread_json(&j, &r->th[i]);
    free(r->th[i].samples);
  }
  js_add(&j, "]}");
  free(r);
  return j.p;
}

void kpw_free(char* s) { free(s); }
