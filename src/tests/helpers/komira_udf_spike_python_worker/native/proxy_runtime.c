/*
 * komira-test/python-worker, engine side: the table of komira_udf_runtime.h
 * implemented as a proxy that sends every entry to Python worker processes
 * over the worker protocol (docs/design/udf_runtime_interface.md sections
 * 4.1 and 5). Test-only spike code. The engine, the harness and the
 * conformance suite drive it like any in-process runtime.
 *
 * Processes. init starts one control worker (posix_spawn) that answers
 * DESCRIBE, VALIDATE and LOAD. Each open_context starts one context worker,
 * so one worker process serves one engine thread (section 3.3,
 * SINGLE_THREAD). Two ways to start it:
 *   spawn   posix_spawn a fresh interpreter; LOAD is sent to it again,
 *           so each worker imports or deserializes the UDF itself.
 *   zygote  the control worker is a zygote: LOAD imports or
 *           deserializes the UDF there, once, and each context worker is
 *           os.fork()ed from it (private op FORK, pyw.h), sharing the loaded
 *           pages copy-on-write. A UDF loaded after a child was forked is
 *           sent to that child with LOAD.
 * The engine itself never forks (section 5.2): the zygote is a
 * single-threaded process it spawned.
 *
 * Builds (one init each; refrt/ forwards the ABI's export to one):
 *   komira_udf_pyworker_spawn_init_v1    spawn, shared memory
 *   komira_udf_pyworker_zygote_init_v1   zygote, shared memory
 *   komira_udf_pyworker_pipe_init_v1     spawn, every payload on the socket
 *   komira_udf_pyworker_pyarrow_init_v1  spawn, shared memory, the worker
 *                                        reading and writing IPC with pyarrow
 *   komira_udf_pyworker_zygote_threads_init_v1
 *                                        zygote, native thread pools not
 *                                        limited to one thread (so a fork
 *                                        may find threads running)
 *
 * The worker answers describe; the proxy reports it with thread_affine 0:
 * the proxy's handles may be called from any engine thread, one at a time
 * (the worker's own thread runs the UDF).
 *
 * FFI-BOUNDARY. Owners: the rt, udf, context and instance structs are this
 * file's, freed by shutdown, unload, close_context and close_instance; each
 * context owns its worker channel (proxy_channel.c). Arrays: `args` is moved
 * in on entry and released once serialized; `out` is an array over an
 * engine-owned copy of the worker's reply, released by the host. Error
 * strings are malloc'd here and freed by the error's release.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "pyw.h"

#define MAX_ARGS 8
#define MAX_LOADED 16

enum variant { V_SPAWN = 1, V_ZYGOTE = 2 };

struct komira_udf_rt {
  const komira_udf_host* host;
  enum variant variant;
  int use_shm;
  struct pyw_launch launch; /* role is set per start */
  char dir[1024];
  pthread_mutex_t lock; /* the control channel, the load counter */
  struct pyw_chan control;
  uint64_t loads; /* LOADs the control worker has answered */
  komira_udf_capabilities caps;
  char runtime_id[96], runtime_abi[32];
};

struct komira_udf_udf {
  struct komira_udf_rt* rt;
  uint64_t remote;  /* its id in the control worker */
  uint64_t seq;     /* rt->loads when it was loaded */
  struct pyw_buf body; /* the LOAD body, sent again to a worker that lacks it */
  int n_args;
  int arg_width[MAX_ARGS];
  int result_width;
};

struct komira_udf_context {
  struct komira_udf_rt* rt;
  struct pyw_chan ch;
  uint64_t remote;
  uint64_t forked_at; /* rt->loads at the fork; UINT64_MAX: not forked */
  int lost;
  struct {
    const komira_udf_udf* udf;
    uint64_t remote;
  } loaded[MAX_LOADED];
  int n_loaded;
};

struct komira_udf_instance {
  struct komira_udf_context* ctx;
  const komira_udf_udf* udf;
  uint64_t remote;
};

/* ---- errors -------------------------------------------------------------- */

static void free_error(komira_udf_error* e) {
  free((void*)e->message);
  free((void*)e->user_trace);
  e->message = e->user_trace = NULL;
  e->release = NULL;
}

static int32_t fail(komira_udf_error* e, int32_t code, const char* msg, const char* trace, int64_t row) {
  if (e == NULL || e->struct_size < sizeof(komira_udf_error)) return code;
  e->code = code;
  e->message = strdup(msg && msg[0] ? msg : "the Python worker runtime failed");
  e->user_trace = trace ? strdup(trace) : NULL;
  e->row = row;
  e->group = -1;
  e->release = free_error;
  return code;
}

/* An ERROR reply's body: i32 code, i64 row, i64 group, message, trace. */
static int32_t fail_reply(komira_udf_error* e, const struct pyw_reply* r) {
  struct pyw_rd d = {r->payload, r->len, 0, 0};
  int32_t code = pyw_rd_i32(&d);
  int64_t row = pyw_rd_i64(&d);
  (void)pyw_rd_i64(&d);
  char* msg = pyw_rd_str(&d);
  char* trace = pyw_rd_str(&d);
  if (d.bad || code == KOMIRA_UDF_OK) code = KOMIRA_UDF_ERR_INTERNAL;
  int32_t rc = fail(e, code, d.bad ? "UDF_RUNTIME_FAULT: a malformed ERROR reply" : msg, trace, row);
  free(msg);
  free(trace);
  return rc;
}

static int32_t fail_chan(komira_udf_error* e, const struct pyw_chan* c) {
  return fail(e, KOMIRA_UDF_ERR_INSTANCE_LOST, c->why, NULL, -1);
}

/* A request whose OK carries one u64 id. */
static int32_t request_id(struct pyw_chan* c, uint32_t op, const struct pyw_buf* body, uint64_t* id,
                          komira_udf_error* e) {
  struct pyw_reply r;
  if (pyw_chan_request(c, op, body, NULL, 0, &r) != 0) return fail_chan(e, c);
  int32_t rc = KOMIRA_UDF_OK;
  if (r.op == KOMIRA_UDF_OP_ERROR) {
    rc = fail_reply(e, &r);
  } else if (id != NULL) {
    struct pyw_rd d = {r.payload, r.len, 0, 0};
    *id = (uint64_t)pyw_rd_i64(&d);
    if (d.bad) rc = fail(e, KOMIRA_UDF_ERR_INTERNAL, "UDF_RUNTIME_FAULT: an OK without its id", NULL, -1);
  }
  pyw_reply_free(&r);
  return rc;
}

/* ---- the spec, as a control body ----------------------------------------- */

/* The fields of a struct schema, or the schema itself as one field. */
static int fields_of(const struct ArrowSchema* s, struct pyw_field* out, int max, int* is_struct) {
  *is_struct = s->format != NULL && strcmp(s->format, "+s") == 0;
  if (!*is_struct) {
    out[0] = (struct pyw_field){s->name, s->format, (s->flags & ARROW_FLAG_NULLABLE) != 0};
    return 1;
  }
  if (s->n_children > max) return -1;
  for (int64_t i = 0; i < s->n_children; i++) {
    const struct ArrowSchema* c = s->children[i];
    out[i] = (struct pyw_field){c->name, c->format, (c->flags & ARROW_FLAG_NULLABLE) != 0};
  }
  return (int)s->n_children;
}

/* The VALIDATE and LOAD body: the spec's scalar fields, its code objects,
 * then the argument and result schemas as IPC Schema messages. */
static int32_t encode_spec(const komira_udf_spec* s, struct pyw_buf* b, komira_udf_udf* u, komira_udf_error* e) {
  if (s == NULL || s->struct_size < sizeof(komira_udf_spec))
    return fail(e, KOMIRA_UDF_ERR_ABI, "spec struct_size is below this runtime's", NULL, -1);
  if (s->args == NULL || s->result == NULL)
    return fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "a spec without argument or result schema", NULL, -1);
  if (s->state != NULL) return fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "a state type is for aggregates", NULL, -1);
  struct pyw_field af[MAX_ARGS], rf[1];
  int a_struct, r_struct;
  int na = fields_of(s->args, af, MAX_ARGS, &a_struct);
  int nr = fields_of(s->result, rf, 1, &r_struct);
  if (na < 0 || !a_struct)
    return fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "args is not a struct of at most 8 fields", NULL, -1);
  if (nr != 1 || r_struct) return fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "the result is not one column", NULL, -1);
  pyw_buf_i32(b, s->shape);
  pyw_buf_i32(b, s->form);
  pyw_buf_i32(b, s->null_mode);
  pyw_buf_i32(b, s->stability);
  pyw_buf_u32(b, s->descriptor_version);
  pyw_buf_str(b, s->entry);
  pyw_buf_u32(b, (uint32_t)s->descriptor_len);
  pyw_buf_put(b, s->descriptor, s->descriptor_len);
  pyw_buf_str(b, s->code_root);
  pyw_buf_u32(b, (uint32_t)s->n_code);
  for (size_t i = 0; i < s->n_code; i++) {
    pyw_buf_str(b, s->code_roles ? s->code_roles[i] : NULL);
    pyw_buf_put(b, s->code_sha256[i], 32);
  }
  pyw_buf_align(b, 8);
  const char* bad = pyw_ipc_schema(b, af, na);
  if (bad == NULL) bad = pyw_ipc_schema(b, rf, 1);
  if (bad != NULL) {
    char m[160];
    snprintf(m, sizeof(m), "the worker transport carries no Arrow type '%s' (spike)", bad);
    return fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, m, NULL, -1);
  }
  if (b->oom) return fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "encoding the spec: out of memory", NULL, -1);
  if (u != NULL) {
    u->n_args = na;
    for (int i = 0; i < na; i++) u->arg_width[i] = pyw_format_width(af[i].format);
    u->result_width = pyw_format_width(rf[0].format);
  }
  return KOMIRA_UDF_OK;
}

/* ---- describe / validate / load ------------------------------------------ */

static int32_t pw_describe(komira_udf_rt* rt, komira_udf_capabilities* c) {
  if (c == NULL || c->struct_size < sizeof(komira_udf_capabilities)) return KOMIRA_UDF_ERR_ABI;
  size_t sz = c->struct_size;
  *c = rt->caps;
  c->struct_size = sz;
  return KOMIRA_UDF_OK;
}

static int32_t pw_validate(komira_udf_rt* rt, const komira_udf_spec* s, komira_udf_error* e) {
  struct pyw_buf b = {0};
  int32_t rc = encode_spec(s, &b, NULL, e);
  if (rc == KOMIRA_UDF_OK) {
    pthread_mutex_lock(&rt->lock);
    rc = request_id(&rt->control, KOMIRA_UDF_OP_VALIDATE, &b, NULL, e);
    pthread_mutex_unlock(&rt->lock);
  }
  pyw_buf_free(&b);
  return rc;
}

static int32_t pw_load(komira_udf_rt* rt, const komira_udf_spec* s, komira_udf_udf** out, komira_udf_error* e) {
  komira_udf_udf* u = calloc(1, sizeof(*u));
  if (u == NULL) return fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "load: out of memory", NULL, -1);
  u->rt = rt;
  int32_t rc = encode_spec(s, &u->body, u, e);
  if (rc == KOMIRA_UDF_OK) {
    pthread_mutex_lock(&rt->lock);
    rc = request_id(&rt->control, KOMIRA_UDF_OP_LOAD, &u->body, &u->remote, e);
    if (rc == KOMIRA_UDF_OK) u->seq = ++rt->loads;
    pthread_mutex_unlock(&rt->lock);
  }
  if (rc != KOMIRA_UDF_OK) {
    pyw_buf_free(&u->body);
    free(u);
    return rc;
  }
  *out = u;
  return KOMIRA_UDF_OK;
}

static void put_id(struct pyw_buf* b, uint64_t id) { pyw_buf_u64(b, id); }

static void pw_unload(komira_udf_udf* u) {
  struct komira_udf_rt* rt = u->rt;
  struct pyw_buf b = {0};
  put_id(&b, u->remote);
  komira_udf_error e = {sizeof(e), 0, NULL, NULL, -1, -1, NULL, NULL};
  pthread_mutex_lock(&rt->lock);
  (void)request_id(&rt->control, KOMIRA_UDF_OP_UNLOAD, &b, NULL, &e);
  pthread_mutex_unlock(&rt->lock);
  if (e.release) e.release(&e);
  pyw_buf_free(&b);
  pyw_buf_free(&u->body);
  free(u);
}

/* ---- contexts ------------------------------------------------------------ */

/* The zygote forks a context worker onto a new socket pair. */
static int32_t fork_worker(struct komira_udf_rt* rt, struct komira_udf_context* c, komira_udf_error* e) {
  int sv[2];
  if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sv) != 0)
    return fail(e, KOMIRA_UDF_ERR_INTERNAL, "open_context: socketpair failed", NULL, -1);
  struct pyw_reply r;
  pthread_mutex_lock(&rt->lock);
  int rc = pyw_chan_request(&rt->control, PYW_OP_FORK, NULL, &sv[1], 1, &r);
  c->forked_at = rt->loads;
  pthread_mutex_unlock(&rt->lock);
  close(sv[1]);
  if (rc != 0) {
    close(sv[0]);
    return fail(e, KOMIRA_UDF_ERR_INTERNAL, rt->control.why, NULL, -1);
  }
  if (r.op == KOMIRA_UDF_OP_ERROR) {
    close(sv[0]);
    int32_t x = fail_reply(e, &r);
    pyw_reply_free(&r);
    return x;
  }
  /* OK: i32 child pid, i32 the zygote's threads at the fork, the warning
   * os.fork raised ("" for none). */
  struct pyw_rd d = {r.payload, r.len, 0, 0};
  pid_t pid = (pid_t)pyw_rd_i32(&d);
  int32_t threads = pyw_rd_i32(&d);
  char* warning = pyw_rd_str(&d);
  pyw_reply_free(&r);
  if (rt->host->log != NULL) {
    char m[600];
    snprintf(m, sizeof(m), "komira-test/python-worker: forked worker %d; zygote threads at fork %d; warning: %s",
             (int)pid, (int)threads, warning && warning[0] ? warning : "none");
    rt->host->log(rt->host->host_data, 3, m);
  }
  free(warning);
  char why[300];
  if (d.bad || pyw_chan_adopt(&c->ch, sv[0], pid, rt->use_shm, why, sizeof(why)) != 0) {
    if (d.bad) close(sv[0]);
    return fail(e, KOMIRA_UDF_ERR_INTERNAL, d.bad ? "open_context: a malformed FORK reply" : why, NULL, -1);
  }
  return KOMIRA_UDF_OK;
}

static int32_t pw_open_context(komira_udf_rt* rt, uint32_t slot, komira_udf_context** out, komira_udf_error* e) {
  komira_udf_context* c = calloc(1, sizeof(*c));
  if (c == NULL) return fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "open_context: out of memory", NULL, -1);
  c->rt = rt;
  c->forked_at = UINT64_MAX;
  c->ch.fd = -1; /* no channel yet: closing it touches nothing */
  c->ch.memfd = -1;
  int32_t rc;
  if (rt->variant == V_ZYGOTE) {
    rc = fork_worker(rt, c, e);
  } else {
    struct pyw_launch l = rt->launch;
    l.role = "context";
    char why[300];
    rc = pyw_chan_spawn(&c->ch, &l, rt->use_shm, why, sizeof(why)) == 0
             ? KOMIRA_UDF_OK
             : fail(e, KOMIRA_UDF_ERR_INTERNAL, why, NULL, -1);
  }
  if (rc == KOMIRA_UDF_OK) {
    struct pyw_buf b = {0};
    pyw_buf_u32(&b, slot);
    rc = request_id(&c->ch, KOMIRA_UDF_OP_OPEN_CONTEXT, &b, &c->remote, e);
    pyw_buf_free(&b);
  }
  if (rc != KOMIRA_UDF_OK) {
    pyw_chan_close(&c->ch);
    free(c);
    return rc;
  }
  *out = c;
  return KOMIRA_UDF_OK;
}

static void pw_close_context(komira_udf_context* c) {
  const komira_udf_host* h = c->rt->host;
  if (h->log != NULL && c->ch.calls > 0) {
    char m[256];
    snprintf(m, sizeof(m),
             "komira-test/python-worker: worker %d: calls %lld, call ns %lld, wait ns %lld, worker ns %lld",
             (int)c->ch.pid, (long long)c->ch.calls, (long long)c->ch.call_ns, (long long)c->ch.wait_ns,
             (long long)c->ch.worker_ns);
    h->log(h->host_data, 3, m);
  }
  if (!c->ch.dead) {
    struct pyw_buf b = {0};
    put_id(&b, c->remote);
    komira_udf_error e = {sizeof(e), 0, NULL, NULL, -1, -1, NULL, NULL};
    (void)request_id(&c->ch, KOMIRA_UDF_OP_CLOSE_CONTEXT, &b, NULL, &e);
    if (e.release) e.release(&e);
    pyw_buf_free(&b);
  }
  pyw_chan_close(&c->ch);
  free(c);
}

/* ---- instances ----------------------------------------------------------- */

/* The UDF's id in the context's worker: inherited from the zygote when it
 * was loaded before the fork, else sent with LOAD now. */
static int32_t remote_udf(komira_udf_context* c, const komira_udf_udf* u, uint64_t* id, komira_udf_error* e) {
  if (c->forked_at != UINT64_MAX && u->seq <= c->forked_at) {
    *id = u->remote;
    return KOMIRA_UDF_OK;
  }
  for (int i = 0; i < c->n_loaded; i++)
    if (c->loaded[i].udf == u) {
      *id = c->loaded[i].remote;
      return KOMIRA_UDF_OK;
    }
  if (c->n_loaded == MAX_LOADED) return fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "open_instance: over 16 UDFs in one context (spike)", NULL, -1);
  int32_t rc = request_id(&c->ch, KOMIRA_UDF_OP_LOAD, &u->body, id, e);
  if (rc == KOMIRA_UDF_OK) {
    c->loaded[c->n_loaded].udf = u;
    c->loaded[c->n_loaded].remote = *id;
    c->n_loaded++;
  }
  return rc;
}

static int32_t pw_open_instance(komira_udf_context* c, komira_udf_udf* u, komira_udf_instance** out,
                                komira_udf_error* e) {
  if (c->lost || c->ch.dead) return fail_chan(e, &c->ch);
  uint64_t uid = 0;
  int32_t rc = remote_udf(c, u, &uid, e);
  if (rc != KOMIRA_UDF_OK) return rc;
  komira_udf_instance* i = calloc(1, sizeof(*i));
  if (i == NULL) return fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "open_instance: out of memory", NULL, -1);
  struct pyw_buf b = {0};
  put_id(&b, c->remote);
  put_id(&b, uid);
  rc = request_id(&c->ch, KOMIRA_UDF_OP_OPEN_INSTANCE, &b, &i->remote, e);
  pyw_buf_free(&b);
  if (rc != KOMIRA_UDF_OK) {
    free(i);
    return rc;
  }
  i->ctx = c;
  i->udf = u;
  *out = i;
  return KOMIRA_UDF_OK;
}

static void pw_close_instance(komira_udf_instance* i) {
  komira_udf_context* c = i->ctx;
  if (!c->ch.dead) {
    struct pyw_buf b = {0};
    put_id(&b, i->remote);
    komira_udf_error e = {sizeof(e), 0, NULL, NULL, -1, -1, NULL, NULL};
    (void)request_id(&c->ch, KOMIRA_UDF_OP_CLOSE_INSTANCE, &b, NULL, &e);
    if (e.release) e.release(&e);
    pyw_buf_free(&b);
  }
  free(i);
}

/* ---- call_batch ---------------------------------------------------------- */

static const char* args_layout_error(const struct ArrowArray* in, const komira_udf_udf* u) {
  if (in->n_children != u->n_args) return "args has a child count other than the bound signature's";
  if (in->length < 0) return "args has a negative length";
  if (in->offset != 0) return "args has a nonzero offset (the argument struct is at offset 0)";
  for (int64_t i = 0; i < in->n_children; i++) {
    const struct ArrowArray* c = in->children[i];
    if (c == NULL || c->n_buffers != 2 || u->arg_width[i] == 0) return "an argument is not a fixed-width primitive";
    if (c->offset < 0 || c->length < in->length) return "an argument is shorter than the batch";
    if (in->length > 0 && c->buffers[1] == NULL) return "an argument has no values buffer";
  }
  return NULL;
}

static int32_t pw_call_batch(komira_udf_instance* inst, const komira_udf_call* call, struct ArrowDeviceArray* args,
                             struct ArrowDeviceArray* out, komira_udf_error* e) {
  komira_udf_context* c = inst->ctx;
  const komira_udf_udf* u = inst->udf;
  const komira_udf_host* host = c->rt->host;
  out->array.release = NULL;
  struct ArrowArray in = args->array; /* moved in */
  int on_cpu = args->device_type == ARROW_DEVICE_CPU;
  args->array.release = NULL;
  const char* bad = NULL;
  int32_t code = KOMIRA_UDF_OK;
  if (call == NULL || call->struct_size < sizeof(komira_udf_call)) {
    code = KOMIRA_UDF_ERR_ABI;
    bad = "call struct_size is below this runtime's";
  } else if (c->lost || c->ch.dead) {
    code = KOMIRA_UDF_ERR_INSTANCE_LOST;
    bad = c->ch.why[0] ? c->ch.why : "the context's worker is gone";
  } else if (!on_cpu) {
    code = KOMIRA_UDF_ERR_UNSUPPORTED;
    bad = "args are not on the CPU";
  } else if ((bad = args_layout_error(&in, u)) != NULL) {
    code = KOMIRA_UDF_ERR_INTERNAL;
  } else if (call->cancel != NULL && __atomic_load_n(call->cancel, __ATOMIC_ACQUIRE) != 0) {
    code = KOMIRA_UDF_ERR_CANCELLED;
    bad = "cancelled before the batch";
  } else if (call->deadline_ns != 0 && host->now_ns(host->host_data) > call->deadline_ns) {
    code = KOMIRA_UDF_ERR_DEADLINE;
    bad = "the deadline passed before the batch";
  }
  if (code != KOMIRA_UDF_OK) {
    if (in.release != NULL) in.release(&in);
    return fail(e, code, bad, NULL, -1);
  }
  /* The call's control block: instance id, deadline, call id. */
  uint8_t head[64];
  memset(head, 0, sizeof(head));
  memcpy(head, &inst->remote, 8);
  memcpy(head + 8, &call->deadline_ns, 8);
  memcpy(head + 16, &call->call_id, 8);
  const struct ArrowArray* cols[MAX_ARGS];
  for (int i = 0; i < u->n_args; i++) cols[i] = in.children[i];
  struct pyw_reply r;
  int killed = 0;
  if (pyw_chan_call(&c->ch, head, sizeof(head), in.length, cols, u->arg_width, u->n_args, &in, call, host, &r,
                    &killed) != 0) {
    c->lost = 1;
    return fail(e, killed ? KOMIRA_UDF_ERR_DEADLINE : KOMIRA_UDF_ERR_INSTANCE_LOST, c->ch.why, NULL, -1);
  }
  if (r.op == KOMIRA_UDF_OP_ERROR) {
    int32_t rc = fail_reply(e, &r);
    pyw_reply_free(&r);
    return rc;
  }
  const char* why = pyw_ipc_decode_column(r.payload, r.len, u->result_width, &out->array);
  if (why != NULL) {
    pyw_reply_free(&r);
    char m[300];
    snprintf(m, sizeof(m), "UDF_RUNTIME_FAULT: komira-test/python-worker: %s", why);
    return fail(e, KOMIRA_UDF_ERR_INTERNAL, m, NULL, -1);
  }
  /* The array owns the payload now. */
  out->device_id = -1;
  out->device_type = ARROW_DEVICE_CPU;
  out->sync_event = NULL;
  memset(out->reserved, 0, sizeof(out->reserved));
  return KOMIRA_UDF_OK;
}

/* ---- the shapes the worker runtime does not declare ---------------------- */

static void release_device(struct ArrowDeviceArray* d) {
  if (d != NULL && d->array.release != NULL) d->array.release(&d->array);
}

static int32_t pw_frame_open(komira_udf_instance* i, const komira_udf_call* call, struct ArrowDeviceArrayStream* in,
                             komira_udf_frame** out, komira_udf_error* e) {
  (void)i, (void)call, (void)out;
  if (in != NULL && in->release != NULL) in->release(in);
  return fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "frames are not in this runtime's shapes", NULL, -1);
}

static int32_t pw_frame_next(komira_udf_frame* f, const komira_udf_call* call, struct ArrowDeviceArray* out,
                             komira_udf_error* e) {
  (void)f, (void)call;
  out->array.release = NULL;
  return fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "frames are not in this runtime's shapes", NULL, -1);
}

static void pw_frame_close(komira_udf_frame* f) { (void)f; }

static int32_t pw_agg_open(komira_udf_instance* i, komira_udf_groups** out, komira_udf_error* e) {
  (void)i, (void)out;
  return fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "aggregates are not in this runtime's shapes", NULL, -1);
}

static int32_t pw_agg_update(komira_udf_groups* g, const komira_udf_call* call, struct ArrowDeviceArray* args,
                             struct ArrowDeviceArray* ids, uint32_t n, komira_udf_error* e) {
  (void)g, (void)call, (void)n;
  release_device(args);
  release_device(ids);
  return fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "aggregates are not in this runtime's shapes", NULL, -1);
}

static int32_t pw_agg_emit(komira_udf_groups* g, uint32_t n, struct ArrowDeviceArray* out, komira_udf_error* e) {
  (void)g, (void)n;
  out->array.release = NULL;
  return fail(e, KOMIRA_UDF_ERR_UNSUPPORTED, "aggregates are not in this runtime's shapes", NULL, -1);
}

static void pw_agg_close(komira_udf_groups* g) { (void)g; }

/* ---- shutdown and init --------------------------------------------------- */

static void pw_shutdown(komira_udf_rt* rt) {
  pyw_chan_close(&rt->control);
  pthread_mutex_destroy(&rt->lock);
  free(rt);
}

static const komira_udf_runtime TABLE = {
    sizeof(komira_udf_runtime),
    KOMIRA_UDF_ABI_MAJOR,
    KOMIRA_UDF_ABI_MINOR,
    pw_describe,
    pw_validate,
    pw_load,
    pw_unload,
    pw_open_context,
    pw_close_context,
    pw_open_instance,
    pw_close_instance,
    pw_call_batch,
    pw_frame_open,
    pw_frame_next,
    pw_frame_close,
    pw_agg_open,
    pw_agg_update,
    pw_agg_update, /* agg_merge: the same refusal, the same moves */
    pw_agg_emit,   /* agg_state */
    pw_agg_emit,   /* agg_finish */
    pw_agg_close,
    pw_shutdown,
    NULL, /* memory_report: in a worker the process's memory is the number (section 4.8) */
};

/* The directory holding this library, from the path it was loaded by. */
static int own_dir(char* out, size_t n) {
  Dl_info info;
  if (dladdr((void*)&own_dir, &info) == 0 || info.dli_fname == NULL) return 0;
  const char* name = info.dli_fname;
  const char* slash = strrchr(name, '/');
  size_t len = slash == NULL ? 0 : (size_t)(slash - name);
  size_t at = 0;
  if (name[0] != '/') {
    if (getcwd(out, n) == NULL) return 0;
    at = strlen(out);
    if (len > 0 && at + 1 < n) out[at++] = '/';
  }
  if (at + len + 1 > n) return 0;
  memcpy(out + at, name, len);
  out[at + len] = 0;
  return 1;
}

/* DESCRIBE's body: runtime id, ABI tag, then ten u32 in the struct's order. */
static int32_t describe_remote(struct komira_udf_rt* rt, komira_udf_error* e) {
  struct pyw_reply r;
  if (pyw_chan_request(&rt->control, KOMIRA_UDF_OP_DESCRIBE, NULL, NULL, 0, &r) != 0)
    return fail(e, KOMIRA_UDF_ERR_LOAD, rt->control.why, NULL, -1);
  if (r.op == KOMIRA_UDF_OP_ERROR) {
    int32_t rc = fail_reply(e, &r);
    pyw_reply_free(&r);
    return rc;
  }
  struct pyw_rd d = {r.payload, r.len, 0, 0};
  char* id = pyw_rd_str(&d);
  char* abi = pyw_rd_str(&d);
  uint32_t v[10];
  for (int i = 0; i < 10; i++) v[i] = pyw_rd_u32(&d);
  pyw_reply_free(&r);
  int ok = !d.bad && id && abi && strlen(id) < sizeof(rt->runtime_id) && strlen(abi) < sizeof(rt->runtime_abi);
  if (ok) {
    snprintf(rt->runtime_id, sizeof(rt->runtime_id), "%s", id);
    snprintf(rt->runtime_abi, sizeof(rt->runtime_abi), "%s", abi);
  }
  free(id);
  free(abi);
  if (!ok) return fail(e, KOMIRA_UDF_ERR_LOAD, "UDF_RUNTIME_FAULT: a malformed DESCRIBE reply", NULL, -1);
  komira_udf_capabilities* c = &rt->caps;
  c->struct_size = sizeof(*c);
  c->runtime_id = rt->runtime_id;
  c->runtime_abi = rt->runtime_abi;
  c->max_descriptor_version = v[0];
  c->shapes = v[1];
  c->threading = v[2];
  c->thread_affine = 0; /* the proxy's handles: any engine thread, one at a time */
  c->transports = v[4];
  c->hosting = v[5];
  c->devices = v[6];
  c->features = 0; /* the proxy has no memory_report entry */
  c->udf_class = v[8];
  c->global_lock = v[9];
  return KOMIRA_UDF_OK;
}

static const komira_udf_runtime* init(const komira_udf_host* host, komira_udf_rt** out, komira_udf_error* e,
                                      enum variant variant, int use_shm, const char* codec, int limit_threads) {
  if (host == NULL || host->struct_size < sizeof(komira_udf_host) || host->abi_major != KOMIRA_UDF_ABI_MAJOR) {
    fail(e, KOMIRA_UDF_ERR_ABI, "this runtime speaks ABI major 1", NULL, -1);
    return NULL;
  }
  komira_udf_rt* rt = calloc(1, sizeof(*rt));
  if (rt == NULL) {
    fail(e, KOMIRA_UDF_ERR_OUT_OF_MEMORY, "init: out of memory", NULL, -1);
    return NULL;
  }
  rt->host = host;
  rt->variant = variant;
  rt->use_shm = use_shm;
  pthread_mutex_init(&rt->lock, NULL);
  if (!own_dir(rt->dir, sizeof(rt->dir))) {
    fail(e, KOMIRA_UDF_ERR_LOAD, "init: cannot find the runtime library's own directory", NULL, -1);
    pw_shutdown(rt);
    return NULL;
  }
  rt->launch = (struct pyw_launch){rt->dir, variant == V_ZYGOTE ? "zygote" : "control", codec, limit_threads};
  char why[300];
  if (pyw_chan_spawn(&rt->control, &rt->launch, use_shm, why, sizeof(why)) != 0) {
    char m[400];
    snprintf(m, sizeof(m), "init: the control worker: %s", why);
    fail(e, KOMIRA_UDF_ERR_LOAD, m, NULL, -1);
    pw_shutdown(rt);
    return NULL;
  }
  if (describe_remote(rt, e) != KOMIRA_UDF_OK) {
    pw_shutdown(rt);
    return NULL;
  }
  *out = rt;
  return &TABLE;
}

const komira_udf_runtime* komira_udf_pyworker_spawn_init_v1(const komira_udf_host* h, komira_udf_rt** rt,
                                                            komira_udf_error* e) {
  return init(h, rt, e, V_SPAWN, 1, "own", 1);
}

const komira_udf_runtime* komira_udf_pyworker_zygote_init_v1(const komira_udf_host* h, komira_udf_rt** rt,
                                                             komira_udf_error* e) {
  return init(h, rt, e, V_ZYGOTE, 1, "own", 1);
}

const komira_udf_runtime* komira_udf_pyworker_pipe_init_v1(const komira_udf_host* h, komira_udf_rt** rt,
                                                           komira_udf_error* e) {
  return init(h, rt, e, V_SPAWN, 0, "own", 1);
}

const komira_udf_runtime* komira_udf_pyworker_pyarrow_init_v1(const komira_udf_host* h, komira_udf_rt** rt,
                                                              komira_udf_error* e) {
  return init(h, rt, e, V_SPAWN, 1, "pyarrow", 1);
}

const komira_udf_runtime* komira_udf_pyworker_zygote_threads_init_v1(const komira_udf_host* h, komira_udf_rt** rt,
                                                                     komira_udf_error* e) {
  return init(h, rt, e, V_ZYGOTE, 1, "own", 0);
}
