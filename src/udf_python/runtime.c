/*
 * runtime.c: the komira_udf_runtime table of komira/python
 * (docs/design/udf_python_worker.md): init and its options, describe,
 * validate, load and unload, and the entries of the shapes not built yet.
 *
 * Nothing starts at init: the zygote is spawned by the first load of a
 * generation (zygote.c). validate is pure (descriptor.c). Contexts and
 * calls are in worker.c.
 *
 * A fork of the engine's process (design section 2.3): init registers, once
 * per process, a pthread_atfork child handler. In the child it closes every
 * descriptor each runtime owns (control and worker sockets, pidfds, the
 * trace) and marks the runtime forked, so the zygote still sees end of file
 * when the engine's process ends, and in the child every load, open_context
 * and call returns ERR_INSTANCE_LOST; closing and shutdown there free memory
 * only. The prepare handler takes every runtime's zygote lock, so the child
 * never copies a runtime in the middle of a change; a fork waits for a load,
 * a FORK or the wait for an EXIT report in progress. The parent is
 * unaffected.
 *
 * The one exported symbol is komira_udf_runtime_init_v1.
 */
#include <ctype.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "udfpy.h"

#define EXPORT __attribute__((visibility("default")))

static const char RUNTIME_ID[] = "komira/python";

/* ---- options ------------------------------------------------------------------------ */

static int32_t bad_option(komira_udf_error* err, const char* fmt, ...) __attribute__((format(printf, 2, 3)));
static int32_t bad_option(komira_udf_error* err, const char* fmt, ...) {
  char buf[800];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  return udfpy_fail(err, KOMIRA_UDF_ERR_BAD_OPTION, -1, "UDF_RUNTIME_OPTION_INVALID: komira/python: %s", buf);
}

static void options_free(udfpy_options* o) {
  free((void*)o->interpreter);
  free((void*)o->zygote);
  free((void*)o->abi);
  free((void*)o->scratch);
  for (int i = 0; i < o->n_sys_path; i++) free((void*)o->sys_path[i]);
  free((void*)o->trace);
  memset(o, 0, sizeof(*o));
}

static const char* const KEYS[] = {"interpreter", "zygote", "abi", "scratch", "sys_path", "grace_ms", "trace"};

/* The reason `value` is not a value of `key`, or NULL. */
static const char* value_problem(const char* key, const char* value) {
  if (strcmp(key, "abi") == 0) {
    if (strncmp(value, "cp", 2) != 0 || value[2] == 0) return "not cp followed by digits";
    for (const char* p = value + 2; *p; p++)
      if (!isdigit((unsigned char)*p)) return "not cp followed by digits";
    return NULL;
  }
  if (strcmp(key, "grace_ms") == 0) {
    size_t n = strlen(value);
    long v = 0;
    if (n == 0 || n > 7) return "not a whole number of milliseconds up to 3600000";
    for (size_t i = 0; i < n; i++) {
      if (!isdigit((unsigned char)value[i])) return "not a whole number of milliseconds up to 3600000";
      v = v * 10 + (value[i] - '0');
    }
    return v <= 3600000 ? NULL : "not a whole number of milliseconds up to 3600000";
  }
  if (value[0] != '/') return "not an absolute path";
  if (strcmp(key, "scratch") == 0) {
    struct stat st;
    if (stat(value, &st) != 0 || !S_ISDIR(st.st_mode)) return "not a directory";
  }
  return NULL;
}

static int32_t parse_options(const komira_udf_host* host, udfpy_options* o, komira_udf_error* err) {
  memset(o, 0, sizeof(*o));
  o->grace_ms = 2000;
  size_t n = 0;
  const char* const* opts = NULL;
  if (host->struct_size >= offsetof(komira_udf_host, options) + sizeof(host->options)) {
    n = host->n_options;
    opts = host->options;
  }
  int seen_grace = 0;
  for (size_t i = 0; i < n; i++) {
    const char* text = opts[i] != NULL ? opts[i] : "";
    const char* eq = strchr(text, '=');
    int32_t rc = KOMIRA_UDF_OK;
    if (eq == NULL) {
      rc = bad_option(err, "option '%s' is not key=value", text);
      options_free(o);
      return rc;
    }
    size_t klen = (size_t)(eq - text);
    char key[64];
    int known = -1;
    for (int k = 0; k < (int)(sizeof(KEYS) / sizeof(KEYS[0])); k++)
      if (strlen(KEYS[k]) == klen && memcmp(KEYS[k], text, klen) == 0) known = k;
    if (known < 0) {
      rc = bad_option(err, "unknown option key '%.*s'", (int)klen, text);
      options_free(o);
      return rc;
    }
    snprintf(key, sizeof(key), "%s", KEYS[known]);
    const char* value = eq + 1;
    const char** slot = NULL;
    switch (known) {
      case 0: slot = &o->interpreter; break;
      case 1: slot = &o->zygote; break;
      case 2: slot = &o->abi; break;
      case 3: slot = &o->scratch; break;
      case 6: slot = &o->trace; break;
      default: break;
    }
    if ((slot != NULL && *slot != NULL) || (known == 5 && seen_grace)) {
      rc = bad_option(err, "option '%s' is given twice", key);
      options_free(o);
      return rc;
    }
    const char* why = value_problem(key, value);
    if (why != NULL) {
      rc = bad_option(err, "option '%s': %s", key, why);
      options_free(o);
      return rc;
    }
    if (known == 4 && o->n_sys_path == UDFPY_MAX_SYS_PATH) {
      rc = bad_option(err, "option 'sys_path': more than %d entries", UDFPY_MAX_SYS_PATH);
      options_free(o);
      return rc;
    }
    if (known == 5) {
      o->grace_ms = atol(value);
      seen_grace = 1;
      continue;
    }
    char* copy = strdup(value);
    if (copy == NULL) {
      options_free(o);
      return udfpy_fail(err, KOMIRA_UDF_ERR_OUT_OF_MEMORY, -1, "no memory for the options");
    }
    if (known == 4)
      o->sys_path[o->n_sys_path++] = copy;
    else
      *slot = copy;
  }
  static const char* const REQUIRED[] = {"interpreter", "zygote", "abi", "scratch"};
  const char* have[] = {o->interpreter, o->zygote, o->abi, o->scratch};
  for (int k = 0; k < 4; k++)
    if (have[k] == NULL) {
      int32_t rc = bad_option(err, "required option '%s' is missing", REQUIRED[k]);
      options_free(o);
      return rc;
    }
  return KOMIRA_UDF_OK;
}

/* ---- the table ------------------------------------------------------------------------- */

static int32_t t_describe(komira_udf_rt* rt, komira_udf_capabilities* out) {
  if (out == NULL || out->struct_size < sizeof(*out)) return KOMIRA_UDF_ERR_ABI;
  out->runtime_id = RUNTIME_ID;
  out->runtime_abi = rt->opt.abi;
  out->max_descriptor_version = 1;
  out->shapes = KOMIRA_UDF_SHAPE_SCALAR | KOMIRA_UDF_SHAPE_MAP_BATCHES_COLUMN;
  out->devices = KOMIRA_UDF_DEVICE_CPU;
  out->features = KOMIRA_UDF_FEATURE_CONTAINS_CRASHES | KOMIRA_UDF_FEATURE_FORCED_STOP;
  out->udf_class = KOMIRA_UDF_CLASS_MANAGED;
  return KOMIRA_UDF_OK;
}

static int32_t t_validate(komira_udf_rt* rt, const komira_udf_spec* s, komira_udf_error* err) {
  (void)rt;
  return udfpy_validate(s, NULL, err);
}

/* ---- load ------------------------------------------------------------------------------- */

static void put_blob(udfpy_buf* b, const udfpy_schema* s) {
  udfpy_buf sb = {0};
  udfpy_ipc_schema(&sb, s, 0, NULL, NULL);
  if (sb.oom) {
    b->oom = 1;
  } else {
    udfpy_buf_u32(b, (uint32_t)sb.n);
    udfpy_buf_put(b, sb.p, sb.n);
    udfpy_buf_pad(b, 8);
  }
  udfpy_buf_free(&sb);
}

/* The LOAD body (udfpy_wire.h, design section 4.2). */
static int32_t load_body(const komira_udf_spec* s, uint32_t batch_format, const udfpy_udf* u, udfpy_buf* b,
                         komira_udf_error* err) {
  udfpy_buf_u32(b, (uint32_t)s->form);
  udfpy_buf_u32(b, (uint32_t)s->shape);
  udfpy_buf_u32(b, batch_format);
  udfpy_buf_u32(b, (uint32_t)s->null_mode);
  udfpy_buf_str(b, s->entry);
  udfpy_buf_str(b, s->code_root != NULL ? s->code_root : "");
  udfpy_buf_u32(b, (uint32_t)s->n_code);
  for (size_t i = 0; i < s->n_code; i++) {
    udfpy_buf_str(b, s->code_roles[i]);
    udfpy_buf_put(b, s->code_sha256[i], 32);
  }
  put_blob(b, &u->args);
  put_blob(b, &u->result);
  if (b->oom) return udfpy_fail(err, KOMIRA_UDF_ERR_OUT_OF_MEMORY, -1, "no memory for the spec");
  return KOMIRA_UDF_OK;
}

static void udf_free(udfpy_udf* u) {
  if (u == NULL) return;
  free(u->entry);
  free(u);
}

void udfpy_udf_drop(udfpy_udf* u) {
  if (u != NULL && atomic_fetch_sub_explicit(&u->refs, 1, memory_order_acq_rel) == 1) udf_free(u);
}

/* Load in the current generation, spawning one when there is none; a reply
 * that retires the generation and asks for a retry is answered once in a new
 * generation. rt->zy_mu is held. */
static int32_t load_locked(udfpy_rt* rt, udfpy_udf* u, const udfpy_buf* body, komira_udf_error* err) {
  for (int attempt = 0; attempt < 2; attempt++) {
    if (rt->cur != NULL) udfpy_ctl_drain(rt, rt->cur); /* a zygote that ended retires its generation */
    udfpy_gen* g = rt->cur;
    if (g == NULL) {
      int32_t rc = udfpy_gen_spawn(rt, &g, err);
      if (rc != KOMIRA_UDF_OK) return rc;
    }
    udfpy_msg r;
    int32_t rc = udfpy_ctl_request(rt, g, UDFPY_OP_LOAD, 0, u->id, body->p, body->n, NULL, 0, &r, err);
    if (rc != KOMIRA_UDF_OK) {
      udfpy_trace(rt, "load gen=%d udf=%llu entry=%s status=%s threads=-1", g->number, (unsigned long long)u->id,
                  u->entry, udfpy_status_name(rc));
      return rc;
    }
    komira_udf_error e;
    memset(&e, 0, sizeof(e));
    e.struct_size = sizeof(e);
    int32_t st = udfpy_reply_status(&r, &e);
    int32_t threads = -1;
    if (st == KOMIRA_UDF_OK && r.len >= 4) memcpy(&threads, r.payload, 4);
    uint32_t flags = r.flags;
    udfpy_msg_free(&r);
    udfpy_trace(rt, "load gen=%d udf=%llu entry=%s status=%s threads=%d", g->number, (unsigned long long)u->id,
                u->entry, udfpy_status_name(st), (int)threads);
    if (st == KOMIRA_UDF_OK) {
      u->gen = g;
      u->load_seq = ++g->loads;
      return KOMIRA_UDF_OK;
    }
    if (flags & UDFPY_FLAG_RETIRE) udfpy_gen_retire(rt, g);
    if ((flags & UDFPY_FLAG_RETIRE) && (flags & UDFPY_FLAG_RETRY) && attempt == 0) {
      if (e.release != NULL) e.release(&e);
      continue;
    }
    udfpy_error_move(err, &e);
    return st;
  }
  return KOMIRA_UDF_ERR_INTERNAL; /* not reached: the second attempt returns */
}

static int32_t t_load(komira_udf_rt* rt, const komira_udf_spec* s, komira_udf_udf** out, komira_udf_error* err) {
  *out = NULL;
  uint32_t bf = 0;
  int32_t rc = udfpy_validate(s, &bf, err);
  if (rc != KOMIRA_UDF_OK) return rc;
  if (rt->forked) return udfpy_fail(err, KOMIRA_UDF_ERR_INSTANCE_LOST, -1, "komira/python: %s", UDFPY_FORKED_WHY);
  udfpy_udf* u = (udfpy_udf*)calloc(1, sizeof(*u));
  if (u == NULL) return udfpy_fail(err, KOMIRA_UDF_ERR_OUT_OF_MEMORY, -1, "no memory for a udf");
  atomic_init(&u->refs, 1);
  char why[1400];
  why[0] = 0;
  u->entry = strdup(s->entry);
  if (u->entry == NULL || udfpy_schema_read(s->args, 1, &u->args, why, sizeof(why)) != 0 ||
      udfpy_schema_read(s->result, 0, &u->result, why, sizeof(why)) != 0) {
    rc = u->entry == NULL ? udfpy_fail(err, KOMIRA_UDF_ERR_OUT_OF_MEMORY, -1, "no memory for a udf")
                          : udfpy_fail(err, KOMIRA_UDF_ERR_UNSUPPORTED, -1, "%s", why);
    udf_free(u);
    return rc;
  }
  u->rt = rt;
  u->shape = s->shape;
  u->batch_format = bf;
  udfpy_buf body = {0};
  rc = load_body(s, bf, u, &body, err);
  if (rc == KOMIRA_UDF_OK) {
    pthread_mutex_lock(&rt->zy_mu);
    u->id = ++rt->next_udf;
    rc = load_locked(rt, u, &body, err);
    pthread_mutex_unlock(&rt->zy_mu);
  }
  udfpy_buf_free(&body);
  if (rc != KOMIRA_UDF_OK) {
    udf_free(u);
    return rc;
  }
  *out = u;
  return KOMIRA_UDF_OK;
}

static void t_unload(komira_udf_udf* u) {
  if (u == NULL) return;
  udfpy_rt* rt = u->rt;
  pthread_mutex_lock(&rt->zy_mu);
  udfpy_gen* g = u->gen;
  if (g != NULL && !g->shut && !g->dead) {
    udfpy_msg r;
    if (udfpy_ctl_request(rt, g, UDFPY_OP_UNLOAD, 0, u->id, NULL, 0, NULL, 0, &r, NULL) == KOMIRA_UDF_OK) {
      if (r.op == UDFPY_OP_OK && r.len >= 4) { /* the UDFs the zygote still holds */
        uint32_t left = 0;
        memcpy(&left, r.payload, 4);
        udfpy_trace(rt, "unload gen=%d udf=%llu left=%u", g->number, (unsigned long long)u->id, left);
      }
      udfpy_msg_free(&r);
    }
  }
  pthread_mutex_unlock(&rt->zy_mu);
  udfpy_udf_drop(u);
}

/* ---- contexts, instances, calls ---------------------------------------------------------- */

static int32_t t_open_context(komira_udf_rt* rt, uint32_t slot, komira_udf_context** out, komira_udf_error* err) {
  return udfpy_open_context(rt, slot, out, err);
}

static void t_close_context(komira_udf_context* c) { udfpy_close_context(c); }

static int32_t t_open_instance(komira_udf_context* c, komira_udf_udf* u, komira_udf_instance** out,
                               komira_udf_error* err) {
  return udfpy_open_instance(c, u, out, err);
}

static void t_close_instance(komira_udf_instance* in) { udfpy_close_instance(in); }

static int32_t t_call_batch(komira_udf_instance* in, const komira_udf_call* call, struct ArrowDeviceArray* args,
                            struct ArrowDeviceArray* out, komira_udf_error* err) {
  return udfpy_call_batch(in, call, args, out, err);
}

/* ---- the shapes not built: every input is moved in, so it is released ------------------- */

static void drop_array(struct ArrowDeviceArray* a) {
  if (a != NULL && a->array.release != NULL) a->array.release(&a->array);
}

static void clear(struct ArrowDeviceArray* out) {
  if (out != NULL) memset(out, 0, sizeof(*out));
}

static int32_t not_built(komira_udf_error* err, const char* what) {
  return udfpy_fail(err, KOMIRA_UDF_ERR_UNSUPPORTED, -1, "%s is not built in komira/python yet", what);
}

static int32_t t_frame_open(komira_udf_instance* in, const komira_udf_call* call, struct ArrowDeviceArrayStream* s,
                            komira_udf_frame** out, komira_udf_error* err) {
  (void)in;
  (void)call;
  *out = NULL;
  if (s != NULL && s->release != NULL) s->release(s);
  return not_built(err, "a frame");
}

static int32_t t_frame_next(komira_udf_frame* f, const komira_udf_call* call, struct ArrowDeviceArray* out,
                            komira_udf_error* err) {
  (void)f;
  (void)call;
  clear(out);
  return not_built(err, "a frame");
}

static void t_frame_close(komira_udf_frame* f) { (void)f; }

static int32_t t_agg_open(komira_udf_instance* in, komira_udf_groups** out, komira_udf_error* err) {
  (void)in;
  *out = NULL;
  return not_built(err, "an aggregate");
}

static int32_t t_agg_update(komira_udf_groups* g, const komira_udf_call* call, struct ArrowDeviceArray* args,
                            struct ArrowDeviceArray* group_ids, uint32_t n_groups, komira_udf_error* err) {
  (void)g;
  (void)call;
  (void)n_groups;
  drop_array(args);
  drop_array(group_ids);
  return not_built(err, "an aggregate");
}

static int32_t t_agg_state(komira_udf_groups* g, uint32_t n, struct ArrowDeviceArray* out, komira_udf_error* err) {
  (void)g;
  (void)n;
  clear(out);
  return not_built(err, "an aggregate");
}

static void t_agg_close(komira_udf_groups* g) { (void)g; }

/* ---- forks of the engine's process ---------------------------------------------------------- */

static pthread_mutex_t g_rts_mu = PTHREAD_MUTEX_INITIALIZER;
static udfpy_rt* g_rts = NULL; /* every runtime between init and shutdown */
static pthread_once_t g_atfork_once = PTHREAD_ONCE_INIT;

static void fork_prepare(void) {
  pthread_mutex_lock(&g_rts_mu);
  for (udfpy_rt* r = g_rts; r != NULL; r = r->next_rt) pthread_mutex_lock(&r->zy_mu);
}

static void fork_parent(void) {
  for (udfpy_rt* r = g_rts; r != NULL; r = r->next_rt) pthread_mutex_unlock(&r->zy_mu);
  pthread_mutex_unlock(&g_rts_mu);
}

/* In the child: the processes are the parent's; let go of every descriptor
 * that reaches them, and signal none of them. */
static void forget_processes(udfpy_rt* r) {
  r->forked = 1;
  if (r->trace_fd >= 0) close(r->trace_fd);
  r->trace_fd = -1;
  for (int i = 0; i < r->n_gens; i++) {
    udfpy_gen* g = r->gens[i];
    if (g->sock >= 0) close(g->sock);
    g->sock = -1;
    g->pid = -1;
    g->reaped = g->dead = g->retired = g->shut = 1;
  }
  r->cur = NULL;
  for (int i = 0; i < r->n_ctxs; i++) {
    komira_udf_context_t* c = r->ctxs[i];
    if (c->sock >= 0) close(c->sock);
    if (c->pidfd >= 0) close(c->pidfd);
    c->sock = c->pidfd = -1;
    c->lost = 1;
    snprintf(c->lost_why, sizeof(c->lost_why), "%s", UDFPY_FORKED_WHY);
  }
}

static void fork_child(void) {
  for (udfpy_rt* r = g_rts; r != NULL; r = r->next_rt) {
    forget_processes(r);
    pthread_mutex_unlock(&r->zy_mu);
  }
  pthread_mutex_unlock(&g_rts_mu);
}

static void register_atfork(void) { pthread_atfork(fork_prepare, fork_parent, fork_child); }

static void rts_add(udfpy_rt* r) {
  pthread_once(&g_atfork_once, register_atfork);
  pthread_mutex_lock(&g_rts_mu);
  r->next_rt = g_rts;
  g_rts = r;
  pthread_mutex_unlock(&g_rts_mu);
}

static void rts_remove(udfpy_rt* r) {
  pthread_mutex_lock(&g_rts_mu);
  for (udfpy_rt** p = &g_rts; *p != NULL; p = &(*p)->next_rt)
    if (*p == r) {
      *p = r->next_rt;
      break;
    }
  pthread_mutex_unlock(&g_rts_mu);
}

static void t_shutdown(komira_udf_rt* rt) {
  rts_remove(rt);
  pthread_mutex_lock(&rt->zy_mu);
  for (int i = 0; i < rt->n_gens; i++) udfpy_gen_shutdown(rt, rt->gens[i]);
  pthread_mutex_unlock(&rt->zy_mu);
  udfpy_gens_free(rt);
  free(rt->ctxs);
  if (rt->trace_fd >= 0) close(rt->trace_fd);
  pthread_mutex_destroy(&rt->zy_mu);
  options_free(&rt->opt);
  free(rt);
}

static const komira_udf_runtime TABLE = {
    sizeof(komira_udf_runtime),
    KOMIRA_UDF_ABI_MAJOR,
    KOMIRA_UDF_ABI_MINOR,
    t_describe,
    t_validate,
    t_load,
    t_unload,
    t_open_context,
    t_close_context,
    t_open_instance,
    t_close_instance,
    t_call_batch,
    t_frame_open,
    t_frame_next,
    t_frame_close,
    t_agg_open,
    t_agg_update,
    t_agg_update, /* agg_merge: the same refusal */
    t_agg_state,
    t_agg_state, /* agg_finish */
    t_agg_close,
    t_shutdown,
    NULL, /* memory_report */
};

EXPORT const komira_udf_runtime* komira_udf_runtime_init_v1(const komira_udf_host* host, komira_udf_rt** rt,
                                                             komira_udf_error* err) {
  if (rt != NULL) *rt = NULL;
  if (host == NULL || rt == NULL) {
    udfpy_fail(err, KOMIRA_UDF_ERR_ABI, -1, "komira/python needs a host and a place for the runtime");
    return NULL;
  }
  if (host->struct_size < offsetof(komira_udf_host, n_options)) {
    udfpy_fail(err, KOMIRA_UDF_ERR_ABI, -1, "komira/python needs a komira_udf_host of ABI 1.0");
    return NULL;
  }
  if (host->abi_major != KOMIRA_UDF_ABI_MAJOR) {
    udfpy_fail(err, KOMIRA_UDF_ERR_ABI, -1, "komira/python speaks ABI major %d", KOMIRA_UDF_ABI_MAJOR);
    return NULL;
  }
  udfpy_rt* r = (udfpy_rt*)calloc(1, sizeof(*r));
  if (r == NULL) {
    udfpy_fail(err, KOMIRA_UDF_ERR_OUT_OF_MEMORY, -1, "no memory for the runtime");
    return NULL;
  }
  if (parse_options(host, &r->opt, err) != KOMIRA_UDF_OK) {
    free(r);
    return NULL;
  }
  r->trace_fd = -1;
  if (r->opt.trace != NULL) {
    r->trace_fd = open(r->opt.trace, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0600);
    if (r->trace_fd < 0) {
      bad_option(err, "option 'trace': cannot be opened for append");
      options_free(&r->opt);
      free(r);
      return NULL;
    }
  }
  r->host = host;
  pthread_mutex_init(&r->zy_mu, NULL);
  rts_add(r);
  *rt = r;
  return &TABLE;
}
