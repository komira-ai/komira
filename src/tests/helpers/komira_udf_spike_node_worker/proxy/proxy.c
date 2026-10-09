/*
 * proxy.c: the komira_udf_runtime table of the worker transport (design
 * section 4.1, "On the engine side, a proxy implements the table and talks
 * to the worker"). Test-only spike code.
 *
 * One worker process per context: open_context starts a worker (one per
 * engine thread, the design's mode 2 on the worker transport), and every
 * call on that context's instances goes to it. describe, validate, load and
 * unload, which come before any context, go to one admission worker the
 * runtime starts at init and guards with a lock (they are rare; no call on
 * a context ever takes it). A UDF loaded once at the admission worker is
 * loaded again in each context's worker on its first open_instance, from
 * the LOAD body the proxy kept.
 *
 * Ownership (section 4.4): `args`, `states` and `group_ids` are moved in on
 * entry, whatever the status, and released once their bytes are in the
 * request (the one copy, engine to worker, is the serialization); a frame's
 * input stream is moved in at frame_open and released at frame_close or on
 * failure. `out` is the host's on OK only: arrays that borrow the reply's
 * payload, whose bytes are reserved through host->mem_reserve until the last
 * array goes. Error strings are the proxy's, freed by the error's release.
 */
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "kudfw.h"

typedef struct komira_udf_rt {
  const komira_udf_host* host;
  kudfw_launcher launcher;
  pthread_mutex_t admin_mu;
  kudfw_worker admin;
  int have_caps;
  komira_udf_capabilities caps;
  char runtime_id[128];
  char runtime_abi[64];
} rt_t;

typedef struct komira_udf_udf {
  rt_t* rt;
  uint64_t serial;
  uint64_t admin_id;
  int32_t shape;
  kudfw_buf load_body;
  kudfw_schema args, result, state;
} udf_t;

#define MAX_LOADED 32

typedef struct komira_udf_context {
  rt_t* rt;
  uint32_t slot;
  kudfw_worker w;
  uint64_t id;
  int n_loaded;
  uint64_t loaded_serial[MAX_LOADED];
  uint64_t loaded_id[MAX_LOADED];
} ctx_t;

typedef struct komira_udf_instance {
  ctx_t* ctx;
  udf_t* udf;
  uint64_t id;
} inst_t;

typedef struct komira_udf_frame {
  inst_t* inst;
  uint64_t id;
  struct ArrowDeviceArrayStream in;
  int in_done;
} frame_t;

typedef struct komira_udf_groups {
  inst_t* inst;
  uint64_t id;
} groups_t;

static _Atomic uint64_t udf_serials = 1;

static const char* SHAPE_KEYS[] = {"shape", "form", "entry", "null_mode", "stability", "descriptor_version",
                                   "descriptor", "result", "state"};

/* ---- helpers --------------------------------------------------------------- */

static uint64_t reply_u64(const kudfw_reply* r) {
  uint64_t v = 0;
  if (r->len >= 8) memcpy(&v, r->payload, 8);
  return v;
}

/* One request on worker `w`; the reply's ERROR mapped to its status. On OK,
 * *r holds the reply (free it). */
static int32_t ask(kudfw_worker* w, const komira_udf_host* host, uint32_t op, uint32_t flags, uint64_t handle,
                   const komira_udf_call* call, uint32_t n_groups, uint32_t emit, const kudfw_buf* body,
                   kudfw_reply* r, komira_udf_error* err) {
  int32_t st = kudfw_request(w, host, op, flags, handle, call, n_groups, emit, body ? body->p : NULL,
                             body ? body->n : 0, r, err);
  if (st != KOMIRA_UDF_OK) return st;
  st = kudfw_reply_status(r, err);
  if (st != KOMIRA_UDF_OK) kudfw_reply_free(r);
  return st;
}

static int cancelled(const komira_udf_call* c) {
  return c != NULL && c->cancel != NULL && __atomic_load_n(c->cancel, __ATOMIC_ACQUIRE) != 0;
}

/* Move `d` out of the host's struct into `mine` (design section 4.4). */
static void take(struct ArrowDeviceArray* d, struct ArrowArray* mine) {
  memset(mine, 0, sizeof(*mine));
  if (d == NULL) return;
  *mine = d->array;
  d->array.release = NULL;
}

static void drop(struct ArrowArray* a) {
  if (a->release != NULL) a->release(a);
}

/* An output array the worker sent, checked against `want` and handed to
 * the host as a struct (a table) or a column. */
static int32_t take_output(const komira_udf_host* host, kudfw_reply* r, const kudfw_schema* want, int as_struct,
                           struct ArrowDeviceArray* out, komira_udf_error* err) {
  if (host->mem_reserve != NULL && host->mem_reserve(host->host_data, (int64_t)r->len) != KOMIRA_UDF_OK) {
    kudfw_reply_free(r);
    return kudfw_fail(err, KOMIRA_UDF_ERR_OUT_OF_MEMORY, -1, "the host refused %zu bytes of output", r->len);
  }
  kudfw_hold* hold = kudfw_hold_new(r->payload, r->len, host);
  if (hold == NULL) {
    if (host->mem_release != NULL) host->mem_release(host->host_data, (int64_t)r->len);
    kudfw_reply_free(r);
    return kudfw_fail(err, KOMIRA_UDF_ERR_OUT_OF_MEMORY, -1, "no memory for an output");
  }
  r->payload = NULL;
  struct ArrowArray cols[KUDFW_MAX_FIELDS];
  int64_t length = 0;
  const char* why = NULL;
  if (kudfw_ipc_decode(hold->payload, hold->bytes, want->f, want->n, &length, hold, cols, &why) != 0) {
    kudfw_hold_drop(hold);
    return kudfw_fail(err, KOMIRA_UDF_ERR_INTERNAL, -1, "the worker's output failed validation: %s", why);
  }
  if (as_struct)
    kudfw_out_struct(out, length, want->n, cols, hold);
  else
    kudfw_out_column(out, &cols[0]);
  kudfw_hold_drop(hold);
  if (out->array.release == NULL)
    return kudfw_fail(err, KOMIRA_UDF_ERR_OUT_OF_MEMORY, -1, "no memory for an output");
  return KOMIRA_UDF_OK;
}

static void clear_out(struct ArrowDeviceArray* out) {
  if (out == NULL) return;
  memset(out, 0, sizeof(*out));
  out->device_id = -1;
  out->device_type = ARROW_DEVICE_CPU;
}

/* ---- runtime level: the admission worker ------------------------------------ */

static int32_t t_describe(komira_udf_rt* rt, komira_udf_capabilities* out) {
  pthread_mutex_lock(&rt->admin_mu);
  int32_t st = KOMIRA_UDF_OK;
  if (!rt->have_caps) {
    kudfw_reply r;
    komira_udf_error e;
    memset(&e, 0, sizeof(e));
    st = ask(&rt->admin, rt->host, KOMIRA_UDF_OP_DESCRIBE, 0, 0, NULL, 0, 0, NULL, &r, &e);
    if (st == KOMIRA_UDF_OK) {
      uint32_t w[10];
      size_t at = 40;
      uint32_t n1 = 0, n2 = 0;
      int ok = r.len >= at + 4;
      if (ok) {
        memcpy(w, r.payload, 40);
        memcpy(&n1, r.payload + at, 4);
        ok = n1 < sizeof(rt->runtime_id) && r.len >= at + 4 + n1 + 4;
      }
      if (ok) {
        memcpy(rt->runtime_id, r.payload + at + 4, n1);
        rt->runtime_id[n1] = 0;
        at += 4 + n1;
        memcpy(&n2, r.payload + at, 4);
        ok = n2 < sizeof(rt->runtime_abi) && r.len >= at + 4 + n2;
      }
      if (ok) {
        memcpy(rt->runtime_abi, r.payload + at + 4, n2);
        rt->runtime_abi[n2] = 0;
        komira_udf_capabilities* c = &rt->caps;
        c->struct_size = sizeof(*c);
        c->runtime_id = rt->runtime_id;
        c->runtime_abi = rt->runtime_abi;
        c->max_descriptor_version = w[0];
        c->shapes = w[1];
        c->threading = w[2];
        c->thread_affine = w[3];
        c->transports = w[4];
        c->hosting = w[5];
        c->devices = w[6];
        c->features = w[7];
        c->udf_class = w[8];
        c->global_lock = w[9];
        rt->have_caps = 1;
      } else {
        st = KOMIRA_UDF_ERR_INTERNAL;
      }
      kudfw_reply_free(&r);
    } else {
      kudfw_log(rt->host, 2, "komira udf worker: describe failed: %s", e.message ? e.message : "");
    }
    if (e.release) e.release(&e);
  }
  if (st == KOMIRA_UDF_OK) {
    size_t n = out->struct_size && out->struct_size < sizeof(*out) ? out->struct_size : sizeof(*out);
    memcpy(out, &rt->caps, n);
    out->struct_size = n;
  }
  pthread_mutex_unlock(&rt->admin_mu);
  return st;
}

static char hexd(int v) { return (char)(v < 10 ? '0' + v : 'a' + v - 10); }

/* The VALIDATE and LOAD body: the argument, result and state schemas as IPC
 * Schema messages, the spec's scalar fields as the first one's metadata. */
static int32_t spec_body(const komira_udf_spec* s, kudfw_buf* b, kudfw_schema* args, kudfw_schema* result,
                         kudfw_schema* state, komira_udf_error* err) {
  const char* why = NULL;
  if (kudfw_schema_read(s->args, args, &why) != 0 || kudfw_schema_read(s->result, result, &why) != 0 ||
      kudfw_schema_read(s->state, state, &why) != 0)
    return kudfw_fail(err, KOMIRA_UDF_ERR_UNSUPPORTED, -1, "%s", why);
  if (s->args != NULL && !args->is_struct)
    return kudfw_fail(err, KOMIRA_UDF_ERR_UNSUPPORTED, -1, "the argument schema is not a struct");
  if (s->descriptor_len > 1024)
    return kudfw_fail(err, KOMIRA_UDF_ERR_DESCRIPTOR, -1, "a descriptor longer than 1024 bytes");
  char num[6][24];
  snprintf(num[0], 24, "%d", (int)s->shape);
  snprintf(num[1], 24, "%d", (int)s->form);
  snprintf(num[2], 24, "%d", (int)s->null_mode);
  snprintf(num[3], 24, "%d", (int)s->stability);
  snprintf(num[4], 24, "%u", s->descriptor_version);
  char hex[2049];
  for (size_t i = 0; i < s->descriptor_len; i++) {
    hex[2 * i] = hexd(s->descriptor[i] >> 4);
    hex[2 * i + 1] = hexd(s->descriptor[i] & 15);
  }
  hex[2 * s->descriptor_len] = 0;
  const char* vals[9] = {num[0], num[1], s->entry ? s->entry : "", num[2], num[3], num[4], hex,
                         result->is_struct ? "table" : "column", s->state != NULL ? "1" : "0"};
  kudfw_ipc_schema(b, args, 9, SHAPE_KEYS, vals);
  kudfw_ipc_schema(b, result, 0, NULL, NULL);
  if (s->state != NULL) kudfw_ipc_schema(b, state, 0, NULL, NULL);
  if (b->oom) return kudfw_fail(err, KOMIRA_UDF_ERR_OUT_OF_MEMORY, -1, "no memory for the spec");
  return KOMIRA_UDF_OK;
}

static int32_t t_validate(komira_udf_rt* rt, const komira_udf_spec* s, komira_udf_error* err) {
  kudfw_buf b = {0};
  kudfw_schema a, r, st;
  int32_t rc = spec_body(s, &b, &a, &r, &st, err);
  if (rc == KOMIRA_UDF_OK) {
    kudfw_reply rep;
    pthread_mutex_lock(&rt->admin_mu);
    rc = ask(&rt->admin, rt->host, KOMIRA_UDF_OP_VALIDATE, 0, 0, NULL, 0, 0, &b, &rep, err);
    pthread_mutex_unlock(&rt->admin_mu);
    if (rc == KOMIRA_UDF_OK) kudfw_reply_free(&rep);
  }
  kudfw_buf_free(&b);
  return rc;
}

static int32_t t_load(komira_udf_rt* rt, const komira_udf_spec* s, komira_udf_udf** out, komira_udf_error* err) {
  *out = NULL;
  udf_t* u = (udf_t*)calloc(1, sizeof(*u));
  if (u == NULL) return kudfw_fail(err, KOMIRA_UDF_ERR_OUT_OF_MEMORY, -1, "no memory for a udf");
  int32_t rc = spec_body(s, &u->load_body, &u->args, &u->result, &u->state, err);
  if (rc == KOMIRA_UDF_OK) {
    kudfw_reply rep;
    pthread_mutex_lock(&rt->admin_mu);
    rc = ask(&rt->admin, rt->host, KOMIRA_UDF_OP_LOAD, 0, 0, NULL, 0, 0, &u->load_body, &rep, err);
    pthread_mutex_unlock(&rt->admin_mu);
    if (rc == KOMIRA_UDF_OK) {
      u->admin_id = reply_u64(&rep);
      kudfw_reply_free(&rep);
    }
  }
  if (rc != KOMIRA_UDF_OK) {
    kudfw_buf_free(&u->load_body);
    free(u);
    return rc;
  }
  u->rt = rt;
  u->shape = s->shape;
  u->serial = atomic_fetch_add(&udf_serials, 1);
  *out = u;
  return KOMIRA_UDF_OK;
}

static void t_unload(komira_udf_udf* u) {
  if (u == NULL) return;
  rt_t* rt = u->rt;
  kudfw_reply rep;
  pthread_mutex_lock(&rt->admin_mu);
  if (ask(&rt->admin, rt->host, KOMIRA_UDF_OP_UNLOAD, 0, u->admin_id, NULL, 0, 0, NULL, &rep, NULL) == KOMIRA_UDF_OK)
    kudfw_reply_free(&rep);
  pthread_mutex_unlock(&rt->admin_mu);
  kudfw_buf_free(&u->load_body);
  free(u);
}

/* ---- contexts: one worker each ---------------------------------------------- */

static int32_t t_open_context(komira_udf_rt* rt, uint32_t slot, komira_udf_context** out, komira_udf_error* err) {
  *out = NULL;
  ctx_t* c = (ctx_t*)calloc(1, sizeof(*c));
  if (c == NULL) return kudfw_fail(err, KOMIRA_UDF_ERR_OUT_OF_MEMORY, -1, "no memory for a context");
  int64_t t0 = kudfw_mono_ns();
  int32_t rc = kudfw_spawn(&rt->launcher, rt->host, &c->w, err);
  if (rc != KOMIRA_UDF_OK) {
    free(c);
    return rc;
  }
  kudfw_buf b = {0};
  kudfw_buf_u32(&b, slot);
  kudfw_reply rep;
  rc = ask(&c->w, rt->host, KOMIRA_UDF_OP_OPEN_CONTEXT, 0, 0, NULL, 0, 0, &b, &rep, err);
  kudfw_buf_free(&b);
  if (rc != KOMIRA_UDF_OK) {
    kudfw_stop(&c->w);
    free(c);
    return rc;
  }
  c->id = reply_u64(&rep);
  kudfw_reply_free(&rep);
  c->rt = rt;
  c->slot = slot;
  kudfw_log(rt->host, 1, "komira udf worker: open slot=%u pid=%d spawn_hello_ns=%lld open_context_ns=%lld", slot,
            (int)c->w.pid, (long long)c->w.spawn_ns, (long long)(kudfw_mono_ns() - t0));
  *out = c;
  return KOMIRA_UDF_OK;
}

static void t_close_context(komira_udf_context* c) {
  if (c == NULL) return;
  kudfw_reply rep;
  int pid = (int)c->w.pid;
  if (!c->w.lost &&
      ask(&c->w, c->rt->host, KOMIRA_UDF_OP_CLOSE_CONTEXT, 0, c->id, NULL, 0, 0, NULL, &rep, NULL) == KOMIRA_UDF_OK) {
    char text[900];
    size_t n = rep.len < sizeof(text) - 1 ? rep.len : sizeof(text) - 1;
    memcpy(text, rep.payload, n);
    text[n] = 0;
    for (size_t i = 0; i < n; i++)
      if (text[i] == '\n') text[i] = ' ';
    kudfw_log(c->rt->host, 1, "komira udf worker: close slot=%u pid=%d %s", c->slot, pid, text);
    kudfw_reply_free(&rep);
  }
  kudfw_stop(&c->w);
  free(c);
}

static int32_t t_open_instance(komira_udf_context* c, komira_udf_udf* u, komira_udf_instance** out,
                               komira_udf_error* err) {
  *out = NULL;
  uint64_t udf_id = 0;
  int found = 0;
  for (int i = 0; i < c->n_loaded; i++)
    if (c->loaded_serial[i] == u->serial) {
      udf_id = c->loaded_id[i];
      found = 1;
    }
  kudfw_reply rep;
  int32_t rc;
  if (!found) {
    if (c->n_loaded == MAX_LOADED)
      return kudfw_fail(err, KOMIRA_UDF_ERR_UNSUPPORTED, -1, "more than %d UDFs in one context", MAX_LOADED);
    rc = ask(&c->w, c->rt->host, KOMIRA_UDF_OP_LOAD, 0, 0, NULL, 0, 0, &u->load_body, &rep, err);
    if (rc != KOMIRA_UDF_OK) return rc;
    udf_id = reply_u64(&rep);
    kudfw_reply_free(&rep);
    c->loaded_serial[c->n_loaded] = u->serial;
    c->loaded_id[c->n_loaded] = udf_id;
    c->n_loaded++;
  }
  kudfw_buf b = {0};
  kudfw_buf_u64(&b, c->id);
  rc = ask(&c->w, c->rt->host, KOMIRA_UDF_OP_OPEN_INSTANCE, 0, udf_id, NULL, 0, 0, &b, &rep, err);
  kudfw_buf_free(&b);
  if (rc != KOMIRA_UDF_OK) return rc;
  inst_t* in = (inst_t*)calloc(1, sizeof(*in));
  if (in == NULL) {
    kudfw_reply_free(&rep);
    return kudfw_fail(err, KOMIRA_UDF_ERR_OUT_OF_MEMORY, -1, "no memory for an instance");
  }
  in->ctx = c;
  in->udf = u;
  in->id = reply_u64(&rep);
  kudfw_reply_free(&rep);
  *out = in;
  return KOMIRA_UDF_OK;
}

static void t_close_instance(komira_udf_instance* in) {
  if (in == NULL) return;
  kudfw_reply rep;
  if (ask(&in->ctx->w, in->ctx->rt->host, KOMIRA_UDF_OP_CLOSE_INSTANCE, 0, in->id, NULL, 0, 0, NULL, &rep, NULL) ==
      KOMIRA_UDF_OK)
    kudfw_reply_free(&rep);
  free(in);
}

/* ---- calls -------------------------------------------------------------------- */

static void fmts_of(const kudfw_schema* s, char* fmts, int at) {
  for (int i = 0; i < s->n; i++) fmts[at + i] = s->f[i].fmt;
}

/* Encode a struct array's children as one RecordBatch body. */
static int32_t encode_struct(const struct ArrowArray* a, const char* fmts, int n, kudfw_buf* b, komira_udf_error* err) {
  if (a->release == NULL || a->n_children != n || a->offset != 0)
    return kudfw_fail(err, KOMIRA_UDF_ERR_INTERNAL, -1,
                      "the host passed a struct of %lld children at offset %lld; the bound schema has %d",
                      (long long)a->n_children, (long long)a->offset, n);
  const char* why = NULL;
  if (kudfw_ipc_batch(b, a->length, n, (const struct ArrowArray* const*)a->children, fmts, &why) != 0)
    return kudfw_fail(err, b->oom ? KOMIRA_UDF_ERR_OUT_OF_MEMORY : KOMIRA_UDF_ERR_INTERNAL, -1, "%s", why);
  return KOMIRA_UDF_OK;
}

static int32_t t_call_batch(komira_udf_instance* in, const komira_udf_call* call, struct ArrowDeviceArray* args,
                            struct ArrowDeviceArray* out, komira_udf_error* err) {
  struct ArrowArray mine;
  int32_t dev = args != NULL ? args->device_type : ARROW_DEVICE_CPU;
  take(args, &mine);
  clear_out(out);
  int32_t rc;
  kudfw_buf b = {0};
  char fmts[KUDFW_MAX_FIELDS];
  udf_t* u = in->udf;
  if (dev != ARROW_DEVICE_CPU) {
    rc = kudfw_fail(err, KOMIRA_UDF_ERR_UNSUPPORTED, -1, "arguments on device type %d", (int)dev);
  } else if (cancelled(call)) {
    rc = kudfw_fail(err, KOMIRA_UDF_ERR_CANCELLED, 0, "cancelled before the batch was sent");
  } else {
    fmts_of(&u->args, fmts, 0);
    rc = encode_struct(&mine, fmts, u->args.n, &b, err);
  }
  drop(&mine);
  if (rc == KOMIRA_UDF_OK) {
    kudfw_reply rep;
    rc = ask(&in->ctx->w, in->ctx->rt->host, KOMIRA_UDF_OP_CALL_BATCH, 0, in->id, call, 0, 0, &b, &rep, err);
    if (rc == KOMIRA_UDF_OK) {
      kudfw_schema one = u->result;
      one.n = 1;
      rc = take_output(in->ctx->rt->host, &rep, &one, 0, out, err);
    }
  }
  kudfw_buf_free(&b);
  return rc;
}

static int32_t t_frame_open(komira_udf_instance* in, const komira_udf_call* call, struct ArrowDeviceArrayStream* s,
                            komira_udf_frame** out, komira_udf_error* err) {
  *out = NULL;
  frame_t* f = (frame_t*)calloc(1, sizeof(*f));
  if (f == NULL) {
    if (s != NULL && s->release != NULL) s->release(s);
    return kudfw_fail(err, KOMIRA_UDF_ERR_OUT_OF_MEMORY, -1, "no memory for a frame");
  }
  if (s != NULL) {
    f->in = *s;
    s->release = NULL;
  } else {
    f->in_done = 1;
  }
  int32_t rc;
  kudfw_reply rep;
  if (cancelled(call)) {
    rc = kudfw_fail(err, KOMIRA_UDF_ERR_CANCELLED, -1, "cancelled before the frame opened");
  } else {
    rc = ask(&in->ctx->w, in->ctx->rt->host, KOMIRA_UDF_OP_FRAME_OPEN, 0, in->id, call, 0, 0, NULL, &rep, err);
    if (rc == KOMIRA_UDF_OK) {
      f->id = reply_u64(&rep);
      kudfw_reply_free(&rep);
    }
  }
  if (rc != KOMIRA_UDF_OK) {
    if (f->in.release != NULL) f->in.release(&f->in);
    free(f);
    return rc;
  }
  f->inst = in;
  *out = f;
  return KOMIRA_UDF_OK;
}

/* The next input batch of a frame as a FRAME_IN body; END when the stream
 * has ended. */
static int32_t next_input(frame_t* f, kudfw_buf* b, uint32_t* flags, komira_udf_error* err) {
  *flags = 0;
  if (f->in_done) {
    *flags = KOMIRA_UDF_WIRE_END;
    return KOMIRA_UDF_OK;
  }
  struct ArrowDeviceArray d;
  memset(&d, 0, sizeof(d));
  if (f->in.get_next(&f->in, &d) != 0)
    return kudfw_fail(err, KOMIRA_UDF_ERR_INTERNAL, -1, "the host's input stream failed");
  if (d.array.release == NULL) {
    f->in_done = 1;
    *flags = KOMIRA_UDF_WIRE_END;
    return KOMIRA_UDF_OK;
  }
  udf_t* u = f->inst->udf;
  char fmts[KUDFW_MAX_FIELDS + 1];
  int grouped = u->shape == KOMIRA_UDF_SHAPE_AGG_PLAIN || u->shape == KOMIRA_UDF_SHAPE_MAP_BATCHES_FRAME_GROUPED;
  if (grouped) fmts[0] = 'l';
  fmts_of(&u->args, fmts, grouped);
  int32_t rc = encode_struct(&d.array, fmts, u->args.n + grouped, b, err);
  drop(&d.array);
  return rc;
}

static int32_t t_frame_next(komira_udf_frame* f, const komira_udf_call* call, struct ArrowDeviceArray* out,
                            komira_udf_error* err) {
  clear_out(out);
  ctx_t* c = f->inst->ctx;
  udf_t* u = f->inst->udf;
  uint32_t op = KOMIRA_UDF_OP_FRAME_OUT, flags = 0;
  kudfw_buf b = {0};
  for (;;) {
    kudfw_reply rep;
    int32_t rc = ask(&c->w, c->rt->host, op, flags, f->id, call, 0, 0, &b, &rep, err);
    kudfw_buf_free(&b);
    if (rc != KOMIRA_UDF_OK) return rc;
    if (rep.len > 0) return take_output(c->rt->host, &rep, &u->result, u->result.is_struct, out, err);
    int ended = (rep.flags & KOMIRA_UDF_WIRE_END) != 0;
    kudfw_reply_free(&rep);
    if (ended) return KOMIRA_UDF_OK; /* out->array.release stays NULL: the end */
    /* The frame needs input before it can yield. */
    if (op == KOMIRA_UDF_OP_FRAME_IN && flags == KOMIRA_UDF_WIRE_END)
      return kudfw_fail(err, KOMIRA_UDF_ERR_INTERNAL, -1, "the worker asked for input after the end of input");
    if (cancelled(call)) return kudfw_fail(err, KOMIRA_UDF_ERR_CANCELLED, -1, "cancelled between frame batches");
    op = KOMIRA_UDF_OP_FRAME_IN;
    rc = next_input(f, &b, &flags, err);
    if (rc != KOMIRA_UDF_OK) {
      kudfw_buf_free(&b);
      return rc;
    }
  }
}

static void t_frame_close(komira_udf_frame* f) {
  if (f == NULL) return;
  ctx_t* c = f->inst->ctx;
  kudfw_reply rep;
  if (ask(&c->w, c->rt->host, KOMIRA_UDF_OP_FRAME_CLOSE, 0, f->id, NULL, 0, 0, NULL, &rep, NULL) == KOMIRA_UDF_OK)
    kudfw_reply_free(&rep);
  if (f->in.release != NULL) f->in.release(&f->in);
  free(f);
}

static int32_t t_agg_open(komira_udf_instance* in, komira_udf_groups** out, komira_udf_error* err) {
  *out = NULL;
  kudfw_reply rep;
  int32_t rc = ask(&in->ctx->w, in->ctx->rt->host, KOMIRA_UDF_OP_AGG_OPEN, 0, in->id, NULL, 0, 0, NULL, &rep, err);
  if (rc != KOMIRA_UDF_OK) return rc;
  groups_t* g = (groups_t*)calloc(1, sizeof(*g));
  if (g == NULL) {
    kudfw_reply_free(&rep);
    return kudfw_fail(err, KOMIRA_UDF_ERR_OUT_OF_MEMORY, -1, "no memory for groups");
  }
  g->inst = in;
  g->id = reply_u64(&rep);
  kudfw_reply_free(&rep);
  *out = g;
  return KOMIRA_UDF_OK;
}

/* agg_update (`a` a struct of the arguments) and agg_merge (`a` the state
 * column): `a`'s columns and the group ids as one RecordBatch. */
static int32_t agg_send(komira_udf_groups* g, uint32_t op, const komira_udf_call* call, struct ArrowDeviceArray* a,
                        struct ArrowDeviceArray* ids, uint32_t n_groups, komira_udf_error* err) {
  struct ArrowArray ma, mi;
  take(a, &ma);
  take(ids, &mi);
  udf_t* u = g->inst->udf;
  int32_t rc = KOMIRA_UDF_OK;
  kudfw_buf b = {0};
  if (cancelled(call)) rc = kudfw_fail(err, KOMIRA_UDF_ERR_CANCELLED, -1, "cancelled before the batch was sent");
  if (rc == KOMIRA_UDF_OK && (ma.release == NULL || mi.release == NULL))
    rc = kudfw_fail(err, KOMIRA_UDF_ERR_INTERNAL, -1, "a NULL input array");
  if (rc == KOMIRA_UDF_OK) {
    const struct ArrowArray* cols[KUDFW_MAX_FIELDS + 1];
    char fmts[KUDFW_MAX_FIELDS + 1];
    int n;
    if (op == KOMIRA_UDF_OP_AGG_UPDATE) {
      n = u->args.n;
      if (ma.n_children != n || ma.offset != 0)
        rc = kudfw_fail(err, KOMIRA_UDF_ERR_INTERNAL, -1, "the argument struct does not match the bound schema");
      for (int i = 0; rc == KOMIRA_UDF_OK && i < n; i++) cols[i] = ma.children[i];
      fmts_of(&u->args, fmts, 0);
    } else {
      n = 1;
      cols[0] = &ma;
      fmts[0] = u->state.n > 0 ? u->state.f[0].fmt : 'l';
    }
    cols[n] = &mi;
    fmts[n] = 'i';
    const char* why = NULL;
    if (rc == KOMIRA_UDF_OK && kudfw_ipc_batch(&b, mi.length, n + 1, cols, fmts, &why) != 0)
      rc = kudfw_fail(err, KOMIRA_UDF_ERR_INTERNAL, -1, "%s", why);
  }
  drop(&ma);
  drop(&mi);
  if (rc == KOMIRA_UDF_OK) {
    kudfw_reply rep;
    rc = ask(&g->inst->ctx->w, g->inst->ctx->rt->host, op, 0, g->id, call, n_groups, 0, &b, &rep, err);
    if (rc == KOMIRA_UDF_OK) kudfw_reply_free(&rep);
  }
  kudfw_buf_free(&b);
  return rc;
}

static int32_t t_agg_update(komira_udf_groups* g, const komira_udf_call* call, struct ArrowDeviceArray* args,
                            struct ArrowDeviceArray* ids, uint32_t n_groups, komira_udf_error* err) {
  return agg_send(g, KOMIRA_UDF_OP_AGG_UPDATE, call, args, ids, n_groups, err);
}

static int32_t t_agg_merge(komira_udf_groups* g, const komira_udf_call* call, struct ArrowDeviceArray* states,
                           struct ArrowDeviceArray* ids, uint32_t n_groups, komira_udf_error* err) {
  return agg_send(g, KOMIRA_UDF_OP_AGG_MERGE, call, states, ids, n_groups, err);
}

static int32_t agg_emit(komira_udf_groups* g, uint32_t op, uint32_t emit, const kudfw_schema* want,
                        struct ArrowDeviceArray* out, komira_udf_error* err) {
  clear_out(out);
  kudfw_reply rep;
  ctx_t* c = g->inst->ctx;
  int32_t rc = ask(&c->w, c->rt->host, op, 0, g->id, NULL, 0, emit, NULL, &rep, err);
  if (rc != KOMIRA_UDF_OK) return rc;
  kudfw_schema one = *want;
  one.n = 1;
  return take_output(c->rt->host, &rep, &one, 0, out, err);
}

static int32_t t_agg_state(komira_udf_groups* g, uint32_t emit, struct ArrowDeviceArray* out, komira_udf_error* err) {
  return agg_emit(g, KOMIRA_UDF_OP_AGG_STATE, emit, &g->inst->udf->state, out, err);
}

static int32_t t_agg_finish(komira_udf_groups* g, uint32_t emit, struct ArrowDeviceArray* out, komira_udf_error* err) {
  return agg_emit(g, KOMIRA_UDF_OP_AGG_FINISH, emit, &g->inst->udf->result, out, err);
}

static void t_agg_close(komira_udf_groups* g) {
  if (g == NULL) return;
  kudfw_reply rep;
  ctx_t* c = g->inst->ctx;
  if (ask(&c->w, c->rt->host, KOMIRA_UDF_OP_AGG_CLOSE, 0, g->id, NULL, 0, 0, NULL, &rep, NULL) == KOMIRA_UDF_OK)
    kudfw_reply_free(&rep);
  free(g);
}

static void t_shutdown(komira_udf_rt* rt) {
  if (rt == NULL) return;
  kudfw_stop(&rt->admin);
  pthread_mutex_destroy(&rt->admin_mu);
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
    t_agg_merge,
    t_agg_state,
    t_agg_finish,
    t_agg_close,
    t_shutdown,
    NULL, /* memory_report: no op on the worker transport (komira_udf_wire.h) */
};

const komira_udf_runtime* kudfw_proxy_init(const komira_udf_host* host, komira_udf_rt** rt_out,
                                           komira_udf_error* err, const kudfw_launcher* launcher) {
  *rt_out = NULL;
  if (host == NULL || host->abi_major != KOMIRA_UDF_ABI_MAJOR) {
    kudfw_fail(err, KOMIRA_UDF_ERR_ABI, -1, "the host speaks ABI %u; this runtime speaks %d",
               host != NULL ? host->abi_major : 0, KOMIRA_UDF_ABI_MAJOR);
    return NULL;
  }
  rt_t* rt = (rt_t*)calloc(1, sizeof(*rt));
  if (rt == NULL) {
    kudfw_fail(err, KOMIRA_UDF_ERR_OUT_OF_MEMORY, -1, "no memory for the runtime");
    return NULL;
  }
  rt->host = host;
  rt->launcher = *launcher;
  pthread_mutex_init(&rt->admin_mu, NULL);
  if (kudfw_spawn(&rt->launcher, host, &rt->admin, err) != KOMIRA_UDF_OK) {
    pthread_mutex_destroy(&rt->admin_mu);
    free(rt);
    return NULL;
  }
  kudfw_log(host, 1, "komira udf worker: admission pid=%d spawn_hello_ns=%lld", (int)rt->admin.pid,
            (long long)rt->admin.spawn_ns);
  *rt_out = rt;
  return &TABLE;
}
