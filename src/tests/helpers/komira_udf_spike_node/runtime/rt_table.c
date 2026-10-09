/*
 * The komira_udf_runtime table of the Node runtime, as engine threads see it
 * (docs/design/udf_runtime_interface.md section 4.3). Test-only spike code.
 *
 * Nothing here calls Node-API. validate and load read the spec and the
 * bundle's text; every other entry that reaches user code builds a
 * `struct request`, queues it on the environment that runs the context
 * (rt_submit) and waits. The environment's JavaScript thread runs it
 * (rt_js.c).
 *
 * Ownership, entry by entry (design section 4.4):
 *   - args, ids, states and the input stream are moved in before anything can
 *     fail: this file copies the struct, clears the caller's `release`, and
 *     releases its copy exactly once after the request is done, on the
 *     engine thread, whatever the status. By then the ArrayBuffers wrapped
 *     over them are detached (rt_arrow.c), so nothing in JavaScript reads
 *     them.
 *   - `out` is filled by the JavaScript thread with arrays this addon
 *     allocated, whose release only frees them; on any status but OK
 *     out->array.release is NULL.
 *   - error strings are malloc'd here and freed by the error's release.
 *   - handles belong to this file: created by open_*, freed by close_*.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

#include "rt_internal.h"

#define RUNTIME_ID_SHARED "komira-test/node-shared-isolate"
#define RUNTIME_ID_WORKERS "komira-test/node-workers"
#define SPAWN_TIMEOUT_S 120
/* A call whose cancel flag has been set for this long without ending has its
 * isolate terminated (the workers build): Node-API cannot stop JavaScript
 * running in an isolate, worker.terminate() can. */
#define HARD_CANCEL_GRACE_NS 1000000000LL

const komira_udf_host* g_host = NULL;

/* ---- strings and errors -------------------------------------------------- */

static char* dup_str(const char* s) {
  size_t n = strlen(s) + 1;
  char* d = malloc(n);
  if (d != NULL) memcpy(d, s, n);
  return d;
}

static void free_error(komira_udf_error* e) {
  free((void*)e->message);
  free((void*)e->user_trace);
  e->message = NULL;
  e->user_trace = NULL;
  e->release = NULL;
}

/* Fill the host's error with strings of ours (taken over: freed by release). */
static int32_t put_error(komira_udf_error* e, int32_t code, char* message, char* trace, int64_t row, int64_t group) {
  if (e == NULL || e->struct_size < sizeof(komira_udf_error)) {
    free(message);
    free(trace);
    return code;
  }
  e->code = code;
  e->message = message != NULL ? message : dup_str("(no message)");
  e->user_trace = trace;
  e->row = row;
  e->group = group;
  e->release = free_error;
  return code;
}

static int32_t fail(komira_udf_error* e, int32_t code, const char* msg) {
  return put_error(e, code, dup_str(msg), NULL, -1, -1);
}

/* The error a finished request carries, if it failed. */
static int32_t request_status(struct request* r, komira_udf_error* e) {
  if (r->status == KOMIRA_UDF_OK) return KOMIRA_UDF_OK; /* request_destroy frees any strings */
  int32_t code = r->status;
  put_error(e, code, r->message, r->trace, r->row, r->group);
  r->message = NULL;
  r->trace = NULL;
  return code;
}

/* ---- requests ------------------------------------------------------------ */

static void request_init(struct request* r, int op) {
  memset(r, 0, sizeof(*r));
  r->op = op;
  r->row = -1;
  r->group = -1;
  pthread_mutex_init(&r->mu, NULL);
  pthread_condattr_t attr;
  pthread_condattr_init(&attr);
  pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);
  pthread_cond_init(&r->cv, &attr);
  pthread_condattr_destroy(&attr);
}

static void request_destroy(struct request* r) {
  /* The arrays frame pulls left: released here, on the engine thread. */
  for (int i = 0; i < r->n_pulled; i++)
    if (r->pulled[i].array.release != NULL) r->pulled[i].array.release(&r->pulled[i].array);
  free(r->pulled);
  free(r->wraps.e);
  free(r->message);
  free(r->trace);
  pthread_mutex_destroy(&r->mu);
  pthread_cond_destroy(&r->cv);
}

int32_t rt_fail(struct request* r, int32_t status, const char* message) {
  r->status = status;
  free(r->message);
  r->message = dup_str(message);
  return status;
}

void rt_complete(struct request* r) {
  pthread_mutex_lock(&r->mu);
  r->done = 1;
  pthread_cond_signal(&r->cv);
  pthread_mutex_unlock(&r->mu);
}

/* Queue `r` on `es` and wait for its JavaScript thread to finish it. */
int32_t rt_submit(struct env_state* es, struct request* r) {
  r->es = es;
  STAT_ADD(requests, 1);
  if (pthread_equal(es->thread, pthread_self()))
    return rt_fail(r, KOMIRA_UDF_ERR_INTERNAL,
                   "the call was made on the JavaScript thread of the environment that runs it, and would wait on itself");
  if (napi_call_threadsafe_function(es->tsfn, r, napi_tsfn_blocking) != napi_ok)
    return rt_fail(r, KOMIRA_UDF_ERR_INSTANCE_LOST, "the environment no longer takes calls");
  pthread_mutex_lock(&r->mu);
  while (!r->done) pthread_cond_wait(&r->cv, &r->mu);
  pthread_mutex_unlock(&r->mu);
  return r->status;
}

static int64_t mono_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static void wait_done(struct request* r) {
  pthread_mutex_lock(&r->mu);
  while (!r->done) pthread_cond_wait(&r->cv, &r->mu);
  pthread_mutex_unlock(&r->mu);
}

/* Queue `r` on the environment of context `c`. In the workers build a call
 * that carries a cancel flag is watched: once the flag has been set for
 * HARD_CANCEL_GRACE_NS and the call has not ended (the user's function does
 * not return, so the cooperative checks between rows never run), the isolate
 * is terminated, the call ends ERR_INSTANCE_LOST and the context is lost: the
 * engine closes it and opens another (design section 4.7). */
static int32_t ctx_submit(struct komira_udf_context* c, struct request* r) {
  if (c->lost) return rt_fail(r, KOMIRA_UDF_ERR_INSTANCE_LOST, "the context was lost: its isolate was terminated by a cancel");
  struct env_state* es = c->es;
  if (!(KOMIRA_NODE_WORKERS && r->call != NULL && r->call->cancel != NULL)) return rt_submit(es, r);
  r->es = es;
  STAT_ADD(requests, 1);
  uint32_t slot = c->slot;
  if (pthread_equal(es->thread, pthread_self()))
    return rt_fail(r, KOMIRA_UDF_ERR_INTERNAL, "the call was made on the JavaScript thread of the environment that runs it, and would wait on itself");
  if (napi_call_threadsafe_function(es->tsfn, r, napi_tsfn_blocking) != napi_ok)
    return rt_fail(r, KOMIRA_UDF_ERR_INSTANCE_LOST, "the environment no longer takes calls");
  int64_t seen = 0;
  int terminate = 0;
  pthread_mutex_lock(&r->mu);
  while (!r->done) {
    struct timespec until;
    clock_gettime(CLOCK_MONOTONIC, &until);
    until.tv_nsec += 1000000;
    if (until.tv_nsec >= 1000000000L) {
      until.tv_sec += 1;
      until.tv_nsec -= 1000000000L;
    }
    pthread_cond_timedwait(&r->cv, &r->mu, &until);
    if (r->done) break;
    if (__atomic_load_n(r->call->cancel, __ATOMIC_ACQUIRE) != 0) {
      int64_t now = mono_ns();
      if (seen == 0) seen = now;
      else if (now - seen > HARD_CANCEL_GRACE_NS) {
        terminate = 1;
        break;
      }
    }
  }
  pthread_mutex_unlock(&r->mu);
  if (!terminate) return r->status;
  c->lost = 1;
  pthread_mutex_lock(&g_mu);
  es->attached = 0;
  for (struct env_state** p = &g_envs; *p != NULL; p = &(*p)->next)
    if (*p == es) {
      *p = es->next;
      break;
    }
  struct env_state* main_es = g_main;
  pthread_mutex_unlock(&g_mu);
  if (main_es != NULL) {
    struct request st;
    request_init(&st, OP_STOP);
    st.n_groups = slot;
    rt_submit(main_es, &st);
    request_destroy(&st);
  }
  wait_done(r); /* the terminated call ends in some error, or had just ended */
  if (r->out != NULL && r->out->array.release != NULL) {
    r->out->array.release(&r->out->array);
    r->out->array.release = NULL;
  }
  free(r->message);
  r->message = dup_str("cancelled: the function did not return within the grace period and its isolate was terminated");
  free(r->trace);
  r->trace = NULL;
  r->status = KOMIRA_UDF_ERR_INSTANCE_LOST;
  return r->status;
}

/* ---- the entry grammar and the bundle's export list ---------------------- */

static int ident_ok(const char* s, size_t n) {
  if (n == 0) return 0;
  for (size_t i = 0; i < n; i++) {
    char c = s[i];
    int alpha = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '$';
    int digit = c >= '0' && c <= '9';
    if (!(alpha || (digit && i > 0))) return 0;
  }
  return 1;
}

/* "dir/bundle.js#name": a relative .js path below the code directory and an
 * identifier. file and name are copied into the caller's buffers. */
static int split_entry(const char* entry, char* file, size_t file_cap, char* name, size_t name_cap) {
  if (entry == NULL) return 0;
  const char* hash = strchr(entry, '#');
  if (hash == NULL) return 0;
  size_t fn = (size_t)(hash - entry), nn = strlen(hash + 1);
  if (fn < 4 || fn >= file_cap || nn >= name_cap) return 0;
  if (entry[0] == '/' || strstr(entry, "..") != NULL) return 0;
  if (memcmp(entry + fn - 3, ".js", 3) != 0) return 0;
  if (!ident_ok(hash + 1, nn)) return 0;
  memcpy(file, entry, fn);
  file[fn] = 0;
  memcpy(name, hash + 1, nn + 1);
  return 1;
}

enum { EXPORTS_UNKNOWN = -1, EXPORTS_ABSENT = 0, EXPORTS_PRESENT = 1 };

/* Does the bundle export `name`? The text is read, never run: esbuild's CJS
 * output ends with `0 && (module.exports = { a, b });` (the names node reads
 * for named imports). A bundle without that annotation cannot be checked
 * without running it, which validate must not do: EXPORTS_UNKNOWN. */
static int bundle_exports(const char* path, const char* name) {
  FILE* f = fopen(path, "rb");
  if (f == NULL) return EXPORTS_UNKNOWN;
  fseek(f, 0, SEEK_END);
  long size = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (size <= 0 || size > (8L << 20)) {
    fclose(f);
    return EXPORTS_UNKNOWN;
  }
  char* text = malloc((size_t)size + 1);
  if (text == NULL || fread(text, 1, (size_t)size, f) != (size_t)size) {
    free(text);
    fclose(f);
    return EXPORTS_UNKNOWN;
  }
  fclose(f);
  text[size] = 0;
  int result = EXPORTS_UNKNOWN;
  const char* mark = "0 && (module.exports = {";
  char* at = strstr(text, mark);
  if (at != NULL) {
    char* p = at + strlen(mark);
    char* end = strchr(p, '}');
    result = EXPORTS_ABSENT;
    size_t nn = strlen(name);
    while (end != NULL && p < end) {
      while (p < end && (*p == ' ' || *p == '\n' || *p == '\t' || *p == ',' || *p == '\r')) p++;
      char* start = p;
      while (p < end && *p != ' ' && *p != '\n' && *p != '\t' && *p != ',' && *p != '\r') p++;
      if ((size_t)(p - start) == nn && memcmp(start, name, nn) == 0) result = EXPORTS_PRESENT;
    }
  }
  free(text);
  return result;
}

/* ---- validate and load --------------------------------------------------- */

#define SHAPES_ALL                                                                                           \
  (KOMIRA_UDF_SHAPE_SCALAR | KOMIRA_UDF_SHAPE_ROW | KOMIRA_UDF_SHAPE_MAP_BATCHES_COLUMN |                   \
   KOMIRA_UDF_SHAPE_MAP_BATCHES_FRAME | KOMIRA_UDF_SHAPE_AGG_PLAIN | KOMIRA_UDF_SHAPE_AGG_MERGEABLE |        \
   KOMIRA_UDF_SHAPE_STEP)

static int fmt_ok(const struct ArrowSchema* s) {
  if (s == NULL || s->format == NULL || s->format[0] == 0 || s->format[1] != 0 || s->n_children != 0) return 0;
  return s->format[0] == 'i' || s->format[0] == 'l' || s->format[0] == 'g';
}

static void free_cols(struct rt_col* c, int n) {
  if (c == NULL) return;
  for (int i = 0; i < n; i++) free(c[i].name);
  free(c);
}

static struct rt_col* copy_cols(const struct ArrowSchema* st, int* n_out) {
  int n = (int)st->n_children;
  struct rt_col* c = calloc((size_t)(n > 0 ? n : 1), sizeof(*c));
  if (c == NULL) return NULL;
  for (int i = 0; i < n; i++) {
    c[i].fmt = st->children[i]->format[0];
    c[i].nullable = (st->children[i]->flags & ARROW_FLAG_NULLABLE) != 0;
    c[i].name = dup_str(st->children[i]->name != NULL ? st->children[i]->name : "");
    if (c[i].name == NULL) {
      free_cols(c, i);
      return NULL;
    }
  }
  *n_out = n;
  return c;
}

static int32_t check_spec(const komira_udf_spec* s, komira_udf_error* e) {
  if (s == NULL || s->struct_size < sizeof(komira_udf_spec))
    return fail(e, KOMIRA_UDF_ERR_ABI, "spec struct_size is below this runtime's");
  if (s->form < KOMIRA_UDF_FORM_PACKAGE || s->form > KOMIRA_UDF_FORM_VALUE)
    return fail(e, KOMIRA_UDF_ERR_DESCRIPTOR, "code form is not PACKAGE, BUNDLE or VALUE");
  if (s->descriptor_version > 0)
    return fail(e, KOMIRA_UDF_ERR_DESCRIPTOR, "descriptor_version is newer than 0, the newest read here");
  if (s->descriptor_len != 0)
    return fail(e, KOMIRA_UDF_ERR_DESCRIPTOR, "descriptor version 0 is empty; these bytes are not canonical");
  if (s->n_code != 0)
    return fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "this runtime reads no code objects: the digests in the spec cannot be checked");
  uint32_t shape = (uint32_t)s->shape;
  if (shape == 0 || (shape & (shape - 1)) != 0 || (shape & SHAPES_ALL) == 0)
    return fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "the shape is not one this runtime declares");
  char file[512], name[256];
  if (!split_entry(s->entry, file, sizeof(file), name, sizeof(name)))
    return fail(e, KOMIRA_UDF_ERR_DESCRIPTOR, "the entry is not <relative bundle>.js#<export>");
  char path[1600];
  snprintf(path, sizeof(path), "%s/%s", g_code_dir, file);
  struct stat st;
  if (stat(path, &st) != 0 || !S_ISREG(st.st_mode))
    return fail(e, KOMIRA_UDF_ERR_DESCRIPTOR, "the entry's bundle does not exist in the code directory");
  if (bundle_exports(path, name) == EXPORTS_ABSENT)
    return fail(e, KOMIRA_UDF_ERR_DESCRIPTOR, "the bundle exports nothing of this name");
  if (s->args == NULL || s->args->format == NULL || strcmp(s->args->format, "+s") != 0)
    return fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "the argument schema is not a struct");
  for (int64_t i = 0; i < s->args->n_children; i++)
    if (!fmt_ok(s->args->children[i]))
      return fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "an argument type this runtime does not map (int32, int64, float64 only)");
  if (shape == KOMIRA_UDF_SHAPE_ROW) {
    if (s->args->n_children < 1) return fail(e, KOMIRA_UDF_ERR_DESCRIPTOR, "a ROW's read set is empty");
    for (int64_t i = 0; i < s->args->n_children; i++) {
      const char* nm = s->args->children[i]->name;
      if (nm == NULL || nm[0] == 0) return fail(e, KOMIRA_UDF_ERR_DESCRIPTOR, "a ROW's read-set field has no name");
      for (int64_t j = 0; j < i; j++)
        if (strcmp(s->args->children[j]->name, nm) == 0)
          return fail(e, KOMIRA_UDF_ERR_DESCRIPTOR, "a ROW's read set names a field twice");
    }
  }
  if (s->result == NULL || s->result->format == NULL) return fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "no result type");
  if (strcmp(s->result->format, "+s") == 0) {
    for (int64_t i = 0; i < s->result->n_children; i++)
      if (!fmt_ok(s->result->children[i])) return fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "a result column type this runtime does not map");
  } else if (!fmt_ok(s->result)) {
    return fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "the result type is not one this runtime maps");
  }
  if (s->state != NULL && !fmt_ok(s->state)) return fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "the state type is not one this runtime maps");
  return KOMIRA_UDF_OK;
}

static int32_t rt_validate(komira_udf_rt* rt, const komira_udf_spec* s, komira_udf_error* e) {
  (void)rt;
  return check_spec(s, e);
}

static void free_udf(struct komira_udf_udf* u) {
  if (u == NULL) return;
  free(u->entry);
  free_cols(u->args, u->n_args);
  free_cols(u->res, u->n_res);
  free(u->state.name);
  free(u);
}

static int32_t rt_load(komira_udf_rt* rt, const komira_udf_spec* s, komira_udf_udf** out, komira_udf_error* e) {
  (void)rt;
  int32_t rc = check_spec(s, e);
  if (rc != KOMIRA_UDF_OK) return rc;
  struct komira_udf_udf* u = calloc(1, sizeof(*u));
  if (u == NULL) return fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "load: out of memory");
  u->entry = dup_str(s->entry);
  u->shape = s->shape;
  u->null_mode = s->null_mode;
  u->args = copy_cols(s->args, &u->n_args);
  if (strcmp(s->result->format, "+s") == 0) {
    u->res_is_table = 1;
    u->res = copy_cols(s->result, &u->n_res);
  } else {
    u->n_res = 1;
    u->res = calloc(1, sizeof(*u->res));
    if (u->res != NULL) {
      u->res[0].fmt = s->result->format[0];
      u->res[0].nullable = (s->result->flags & ARROW_FLAG_NULLABLE) != 0;
      u->res[0].name = dup_str("");
    }
  }
  if (s->state != NULL) {
    u->state.fmt = s->state->format[0];
    u->state.nullable = 1;
    u->state.name = dup_str("");
  }
  if (u->entry == NULL || u->args == NULL || u->res == NULL || (s->state != NULL && u->state.name == NULL) ||
      (!u->res_is_table && u->res[0].name == NULL)) {
    free_udf(u);
    return fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "load: out of memory");
  }
  *out = u;
  return KOMIRA_UDF_OK;
}

static void rt_unload(komira_udf_udf* u) { free_udf(u); }

/* ---- contexts and instances ---------------------------------------------- */

static struct env_state* wait_for_slot(uint32_t slot) {
  struct timespec until;
  clock_gettime(CLOCK_REALTIME, &until);
  until.tv_sec += SPAWN_TIMEOUT_S;
  pthread_mutex_lock(&g_mu);
  struct env_state* es = rt_find_slot(slot);
  while (es == NULL && g_fail_slot != (int64_t)slot) {
    if (pthread_cond_timedwait(&g_cv, &g_mu, &until) != 0) break;
    es = rt_find_slot(slot);
  }
  pthread_mutex_unlock(&g_mu);
  return es;
}

static int32_t rt_open_context(komira_udf_rt* rt, uint32_t slot, komira_udf_context** out, komira_udf_error* e) {
  (void)rt;
  pthread_mutex_lock(&g_mu);
  struct env_state* main_es = g_main;
  pthread_mutex_unlock(&g_mu);
  if (main_es == NULL)
    return fail(e, KOMIRA_UDF_ERR_LOAD, "no Node environment is attached: the script that loaded this addon must call attachMain first");
  struct env_state* es = main_es;
  if (KOMIRA_NODE_WORKERS) {
    struct request sp;
    request_init(&sp, OP_SPAWN);
    sp.n_groups = slot;
    rt_submit(main_es, &sp);
    int32_t rc = request_status(&sp, e);
    request_destroy(&sp);
    if (rc != KOMIRA_UDF_OK) return rc;
    es = wait_for_slot(slot);
    if (es == NULL)
      return fail(e, KOMIRA_UDF_ERR_LOAD, g_fail_slot == (int64_t)slot ? g_fail_msg : "the worker of this slot did not attach in time");
  }
  struct komira_udf_context* c = calloc(1, sizeof(*c));
  if (c == NULL) return fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "open_context: out of memory");
  c->es = es;
  c->slot = slot;
  struct request r;
  request_init(&r, OP_OPEN_CONTEXT);
  r.ctx = c;
  rt_submit(es, &r);
  int32_t rc = request_status(&r, e);
  request_destroy(&r);
  if (rc != KOMIRA_UDF_OK) {
    free(c);
    return rc;
  }
  *out = c;
  return KOMIRA_UDF_OK;
}

static void rt_close_context(komira_udf_context* c) {
  struct request r;
  request_init(&r, OP_CLOSE_CONTEXT);
  r.ctx = c;
  if (!c->lost) rt_submit(c->es, &r);
  request_destroy(&r);
  if (KOMIRA_NODE_WORKERS && !c->lost) {
    /* The worker's only reason to stay alive is its threadsafe function:
     * releasing it lets its event loop drain and the thread exit, which
     * frees its environment's state. */
    pthread_mutex_lock(&g_mu);
    c->es->attached = 0;
    for (struct env_state** p = &g_envs; *p != NULL; p = &(*p)->next)
      if (*p == c->es) {
        *p = c->es->next;
        break;
      }
    pthread_mutex_unlock(&g_mu);
    napi_release_threadsafe_function(c->es->tsfn, napi_tsfn_release);
  }
  free(c);
}

static int32_t rt_open_instance(komira_udf_context* c, komira_udf_udf* u, komira_udf_instance** out,
                                komira_udf_error* e) {
  struct komira_udf_instance* i = calloc(1, sizeof(*i));
  if (i == NULL) return fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "open_instance: out of memory");
  i->ctx = c;
  i->udf = u;
  struct request r;
  request_init(&r, OP_OPEN_INSTANCE);
  r.ctx = c;
  r.inst = i;
  r.udf = u;
  ctx_submit(c, &r);
  int32_t rc = request_status(&r, e);
  request_destroy(&r);
  if (rc != KOMIRA_UDF_OK) {
    free(i);
    return rc;
  }
  *out = i;
  return KOMIRA_UDF_OK;
}

static void rt_close_instance(komira_udf_instance* i) {
  struct request r;
  request_init(&r, OP_CLOSE_INSTANCE);
  r.inst = i;
  ctx_submit(i->ctx, &r);
  request_destroy(&r);
  free(i);
}

/* ---- calls ---------------------------------------------------------------- */

static void release_dev(struct ArrowDeviceArray* a) {
  if (a != NULL && a->array.release != NULL) a->array.release(&a->array);
}

static int cancelled(const komira_udf_call* c) {
  return c != NULL && c->cancel != NULL && __atomic_load_n(c->cancel, __ATOMIC_ACQUIRE) != 0;
}

static int32_t start_call(const komira_udf_call* c, komira_udf_error* e) {
  if (c == NULL || c->struct_size < sizeof(komira_udf_call)) return fail(e, KOMIRA_UDF_ERR_ABI, "call struct_size is below this runtime's");
  if (cancelled(c)) return fail(e, KOMIRA_UDF_ERR_CANCELLED, "cancelled before the batch");
  if (c->deadline_ns != 0 && g_host->now_ns(g_host->host_data) > c->deadline_ns)
    return fail(e, KOMIRA_UDF_ERR_DEADLINE, "the deadline passed before the batch");
  return KOMIRA_UDF_OK;
}

static void set_cpu(struct ArrowDeviceArray* d) {
  d->device_id = -1;
  d->device_type = ARROW_DEVICE_CPU;
  d->sync_event = NULL;
  d->reserved[0] = d->reserved[1] = d->reserved[2] = 0;
}

/* Run `r` and finish: the status, the moved arrays released, the request
 * destroyed. `a` and `b` are the arrays moved in (either may be unset). */
static int32_t finish(struct request* r, komira_udf_error* e, struct ArrowDeviceArray* a, struct ArrowDeviceArray* b) {
  int32_t rc = request_status(r, e);
  release_dev(a);
  release_dev(b);
  request_destroy(r);
  return rc;
}

static int32_t rt_call_batch(komira_udf_instance* i, const komira_udf_call* call, struct ArrowDeviceArray* args,
                             struct ArrowDeviceArray* out, komira_udf_error* e) {
  struct ArrowDeviceArray mine = *args; /* moved in, whatever the status */
  args->array.release = NULL;
  out->array.release = NULL;
  int32_t rc = start_call(call, e);
  if (rc == KOMIRA_UDF_OK && mine.device_type != ARROW_DEVICE_CPU)
    rc = fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "only CPU arrays are read here");
  if (rc == KOMIRA_UDF_OK && (i->udf->shape & (KOMIRA_UDF_SHAPE_SCALAR | KOMIRA_UDF_SHAPE_ROW | KOMIRA_UDF_SHAPE_MAP_BATCHES_COLUMN)) == 0)
    rc = fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "call_batch on a UDF of another shape");
  if (rc != KOMIRA_UDF_OK) {
    release_dev(&mine);
    return rc;
  }
  STAT_ADD(calls, 1);
  struct request r;
  request_init(&r, OP_CALL_BATCH);
  r.inst = i;
  r.udf = i->udf;
  r.call = call;
  r.args = &mine;
  r.out = out;
  ctx_submit(i->ctx, &r);
  rc = finish(&r, e, &mine, NULL);
  if (rc == KOMIRA_UDF_OK) set_cpu(out);
  return rc;
}

static int32_t rt_frame_open(komira_udf_instance* i, const komira_udf_call* call, struct ArrowDeviceArrayStream* in,
                             komira_udf_frame** out, komira_udf_error* e) {
  struct ArrowDeviceArrayStream mine = *in; /* moved in, whatever the status */
  in->release = NULL;
  int32_t rc = KOMIRA_UDF_OK;
  if ((i->udf->shape & (KOMIRA_UDF_SHAPE_MAP_BATCHES_FRAME | KOMIRA_UDF_SHAPE_AGG_PLAIN | KOMIRA_UDF_SHAPE_STEP)) == 0)
    rc = fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "frame_open on a UDF of another shape");
  if (rc == KOMIRA_UDF_OK) rc = start_call(call, e);
  struct komira_udf_frame* f = NULL;
  if (rc == KOMIRA_UDF_OK && (f = calloc(1, sizeof(*f))) == NULL) rc = fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "frame_open: out of memory");
  if (rc != KOMIRA_UDF_OK) {
    if (mine.release != NULL) mine.release(&mine);
    return rc;
  }
  f->inst = i;
  f->in = mine;
  struct request r;
  request_init(&r, OP_FRAME_OPEN);
  r.inst = i;
  r.udf = i->udf;
  r.frame = f;
  r.call = call;
  ctx_submit(i->ctx, &r);
  rc = finish(&r, e, NULL, NULL);
  if (rc != KOMIRA_UDF_OK) {
    if (f->in.release != NULL) f->in.release(&f->in);
    free(f);
    return rc;
  }
  *out = f;
  return KOMIRA_UDF_OK;
}

static int32_t rt_frame_next(komira_udf_frame* f, const komira_udf_call* call, struct ArrowDeviceArray* out,
                             komira_udf_error* e) {
  out->array.release = NULL;
  if (cancelled(call)) return fail(e, KOMIRA_UDF_ERR_CANCELLED, "cancelled between batches");
  struct request r;
  request_init(&r, OP_FRAME_NEXT);
  r.inst = f->inst;
  r.udf = f->inst->udf;
  r.frame = f;
  r.call = call;
  r.out = out;
  ctx_submit(f->inst->ctx, &r);
  int32_t rc = finish(&r, e, NULL, NULL);
  if (rc == KOMIRA_UDF_OK && out->array.release != NULL) set_cpu(out);
  return rc;
}

static void rt_frame_close(komira_udf_frame* f) {
  struct request r;
  request_init(&r, OP_FRAME_CLOSE);
  r.inst = f->inst;
  r.frame = f;
  ctx_submit(f->inst->ctx, &r);
  request_destroy(&r);
  if (f->in.release != NULL) f->in.release(&f->in);
  free(f);
}

static int32_t rt_agg_open(komira_udf_instance* i, komira_udf_groups** out, komira_udf_error* e) {
  if (i->udf->shape != KOMIRA_UDF_SHAPE_AGG_MERGEABLE) return fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "agg_open on a UDF of another shape");
  struct komira_udf_groups* g = calloc(1, sizeof(*g));
  if (g == NULL) return fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "agg_open: out of memory");
  g->inst = i;
  struct request r;
  request_init(&r, OP_AGG_OPEN);
  r.inst = i;
  r.udf = i->udf;
  r.groups = g;
  ctx_submit(i->ctx, &r);
  int32_t rc = finish(&r, e, NULL, NULL);
  if (rc != KOMIRA_UDF_OK) {
    free(g);
    return rc;
  }
  *out = g;
  return KOMIRA_UDF_OK;
}

static int32_t agg_fold(int op, komira_udf_groups* g, const komira_udf_call* call, struct ArrowDeviceArray* values,
                        struct ArrowDeviceArray* ids, uint32_t n_groups, komira_udf_error* e) {
  struct ArrowDeviceArray v = *values; /* both moved in */
  values->array.release = NULL;
  struct ArrowDeviceArray gid = *ids;
  ids->array.release = NULL;
  int32_t rc = cancelled(call) ? fail(e, KOMIRA_UDF_ERR_CANCELLED, "cancelled before the batch") : KOMIRA_UDF_OK;
  if (rc != KOMIRA_UDF_OK) {
    release_dev(&v);
    release_dev(&gid);
    return rc;
  }
  struct request r;
  request_init(&r, op);
  r.inst = g->inst;
  r.udf = g->inst->udf;
  r.groups = g;
  r.call = call;
  r.args = &v;
  r.ids = &gid;
  r.n_groups = n_groups;
  ctx_submit(g->inst->ctx, &r);
  return finish(&r, e, &v, &gid);
}

static int32_t rt_agg_update(komira_udf_groups* g, const komira_udf_call* c, struct ArrowDeviceArray* args,
                             struct ArrowDeviceArray* ids, uint32_t n, komira_udf_error* e) {
  return agg_fold(OP_AGG_UPDATE, g, c, args, ids, n, e);
}

static int32_t rt_agg_merge(komira_udf_groups* g, const komira_udf_call* c, struct ArrowDeviceArray* states,
                            struct ArrowDeviceArray* ids, uint32_t n, komira_udf_error* e) {
  return agg_fold(OP_AGG_MERGE, g, c, states, ids, n, e);
}

static int32_t agg_emit(int op, komira_udf_groups* g, uint32_t n, struct ArrowDeviceArray* out, komira_udf_error* e) {
  out->array.release = NULL;
  struct request r;
  request_init(&r, op);
  r.inst = g->inst;
  r.udf = g->inst->udf;
  r.groups = g;
  r.n_groups = n;
  r.out = out;
  ctx_submit(g->inst->ctx, &r);
  int32_t rc = finish(&r, e, NULL, NULL);
  if (rc == KOMIRA_UDF_OK) set_cpu(out);
  return rc;
}

static int32_t rt_agg_state(komira_udf_groups* g, uint32_t n, struct ArrowDeviceArray* out, komira_udf_error* e) {
  return agg_emit(OP_AGG_STATE, g, n, out, e);
}

static int32_t rt_agg_finish(komira_udf_groups* g, uint32_t n, struct ArrowDeviceArray* out, komira_udf_error* e) {
  return agg_emit(OP_AGG_FINISH, g, n, out, e);
}

static void rt_agg_close(komira_udf_groups* g) {
  struct request r;
  request_init(&r, OP_AGG_CLOSE);
  r.inst = g->inst;
  r.groups = g;
  ctx_submit(g->inst->ctx, &r);
  request_destroy(&r);
  free(g);
}

static int64_t rt_memory_report(komira_udf_context* c) {
  struct request r;
  request_init(&r, OP_MEMORY);
  r.ctx = c;
  int32_t rc = ctx_submit(c, &r);
  int64_t v = rc == KOMIRA_UDF_OK ? r.value : -1;
  request_destroy(&r);
  return v;
}

/* ---- the runtime ---------------------------------------------------------- */

static int32_t rt_describe(komira_udf_rt* rt, komira_udf_capabilities* c) {
  (void)rt;
  if (c == NULL || c->struct_size < sizeof(komira_udf_capabilities)) return KOMIRA_UDF_ERR_ABI;
  c->runtime_id = KOMIRA_NODE_WORKERS ? RUNTIME_ID_WORKERS : RUNTIME_ID_SHARED;
  c->runtime_abi = "node24";
  c->max_descriptor_version = 0;
  c->shapes = SHAPES_ALL;
  c->threading = KOMIRA_UDF_CONTEXT_PER_THREAD;
  c->thread_affine = 0; /* the runtime hands every call to the right thread itself */
  c->transports = KOMIRA_UDF_TRANSPORT_IN_PROCESS;
  c->hosting = KOMIRA_UDF_HOSTING_HOST_INTERPRETER; /* node loaded the engine */
  c->devices = KOMIRA_UDF_DEVICE_CPU;
  c->features = KOMIRA_UDF_FEATURE_MEMORY_REPORT;
  c->udf_class = KOMIRA_UDF_CLASS_MANAGED;
  /* One isolate behind every context serializes user code: a global lock. */
  c->global_lock = KOMIRA_NODE_WORKERS ? 0 : 1;
  return KOMIRA_UDF_OK;
}

static void rt_shutdown(komira_udf_rt* rt) {
  if (g_host == rt->host) g_host = NULL;
  free(rt);
}

static const komira_udf_runtime TABLE = {
    sizeof(komira_udf_runtime),
    KOMIRA_UDF_ABI_MAJOR,
    KOMIRA_UDF_ABI_MINOR,
    rt_describe,
    rt_validate,
    rt_load,
    rt_unload,
    rt_open_context,
    rt_close_context,
    rt_open_instance,
    rt_close_instance,
    rt_call_batch,
    rt_frame_open,
    rt_frame_next,
    rt_frame_close,
    rt_agg_open,
    rt_agg_update,
    rt_agg_merge,
    rt_agg_state,
    rt_agg_finish,
    rt_agg_close,
    rt_shutdown,
    rt_memory_report,
};

const komira_udf_runtime* rt_table(void) { return &TABLE; }

RT_EXPORT const komira_udf_runtime* komira_udf_runtime_init_v1(const komira_udf_host* host, komira_udf_rt** rt,
                                                               komira_udf_error* e) {
  if (host == NULL || host->struct_size < sizeof(komira_udf_host) || host->abi_major != KOMIRA_UDF_ABI_MAJOR) {
    fail(e, KOMIRA_UDF_ERR_ABI, "this runtime speaks ABI major 1");
    return NULL;
  }
  struct komira_udf_rt* r = calloc(1, sizeof(*r));
  if (r == NULL) {
    fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "init: out of memory");
    return NULL;
  }
  r->host = host;
  g_host = host;
  *rt = r;
  return &TABLE;
}
