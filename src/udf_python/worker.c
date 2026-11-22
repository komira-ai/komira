/*
 * worker.c: a context's worker and the calls on it.
 *
 * open_context asks the current generation's zygote to fork one worker, and
 * hands it two descriptors in the FORK request: its end of a fresh socket
 * pair, and the memfd of the cancel word. The context keeps the other end
 * of the socket and its own mapping of the word. Every call on the context's
 * instances goes to that worker, which runs user code on its one thread.
 *
 * Cancel: the worker cannot read its socket during a call, so while the
 * library waits for a reply it polls in 10 ms ticks; a tick that finds the
 * host's cancel flag set or the deadline passed stores the call's id in the
 * cancel word (once), which the worker reads between rows. Nothing stops the
 * worker by force here.
 *
 * Ownership: `args` is moved in on every call whatever the status and
 * released once its bytes are encoded (or on early refusal). `out` is the
 * host's on OK only: arrays that borrow the reply's payload, whose bytes are
 * reserved through host->mem_reserve until the last array is released.
 *
 * A context is used by one engine thread at a time; only the registry and
 * the generation's counts, touched under rt->zy_mu, are shared.
 */
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <unistd.h>

#include "udfpy.h"

#define TICK_MS 10

/* ---- opening and closing a context --------------------------------------------------- */

static void ctx_free(komira_udf_context_t* c) {
  if (c->sock >= 0) close(c->sock);
  if (c->word != NULL) munmap((void*)c->word, 8);
  free(c);
}

int32_t udfpy_open_context(udfpy_rt* rt, uint32_t slot, komira_udf_context_t** out, komira_udf_error* err) {
  *out = NULL;
  pthread_mutex_lock(&rt->zy_mu);
  udfpy_gen* g = rt->cur;
  if (g == NULL || g->retired) {
    pthread_mutex_unlock(&rt->zy_mu);
    return udfpy_fail(err, KOMIRA_UDF_ERR_UNSUPPORTED, -1, "no UDF is loaded; open a context after a load");
  }
  komira_udf_context_t* c = (komira_udf_context_t*)calloc(1, sizeof(*c));
  if (c == NULL) {
    pthread_mutex_unlock(&rt->zy_mu);
    return udfpy_fail(err, KOMIRA_UDF_ERR_OUT_OF_MEMORY, -1, "no memory for a context");
  }
  c->sock = -1;
  int sv[2] = {-1, -1};
  int mfd = -1;
  int32_t rc = KOMIRA_UDF_OK;
  if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sv) != 0) {
    rc = udfpy_fail(err, KOMIRA_UDF_ERR_INTERNAL, -1, "socketpair: %s", strerror(errno));
  } else if ((mfd = memfd_create("komira-udf-cancel", MFD_CLOEXEC)) < 0 || ftruncate(mfd, 8) != 0) {
    rc = udfpy_fail(err, KOMIRA_UDF_ERR_INTERNAL, -1, "memfd_create: %s", strerror(errno));
  } else {
    void* m = mmap(NULL, 8, PROT_READ | PROT_WRITE, MAP_SHARED, mfd, 0);
    if (m == MAP_FAILED)
      rc = udfpy_fail(err, KOMIRA_UDF_ERR_INTERNAL, -1, "mmap of the cancel word: %s", strerror(errno));
    else
      c->word = (volatile int64_t*)m;
  }
  uint64_t id = rt->next_ctx + 1;
  uint32_t pid = 0;
  if (rc == KOMIRA_UDF_OK) {
    int fds[2] = {sv[1], mfd};
    udfpy_msg r;
    rc = udfpy_ctl_request(rt, g, UDFPY_OP_FORK, 0, id, (const uint8_t*)&slot, sizeof(slot), fds, 2, &r, err);
    if (rc == KOMIRA_UDF_OK) {
      rc = udfpy_reply_status(&r, err);
      if (rc == KOMIRA_UDF_OK && r.len >= 4)
        memcpy(&pid, r.payload, 4);
      else if (rc == KOMIRA_UDF_OK)
        rc = udfpy_fail(err, KOMIRA_UDF_ERR_INTERNAL, -1, "the zygote's FORK reply is malformed");
      udfpy_msg_free(&r);
    }
  }
  if (sv[1] >= 0) close(sv[1]); /* the worker has its copy, or none is wanted */
  if (mfd >= 0) close(mfd);
  if (rc == KOMIRA_UDF_OK && rt->n_ctxs == rt->cap_ctxs) {
    int cap = rt->cap_ctxs ? 2 * rt->cap_ctxs : 8;
    komira_udf_context_t** p = (komira_udf_context_t**)realloc(rt->ctxs, (size_t)cap * sizeof(*p));
    if (p == NULL)
      rc = udfpy_fail(err, KOMIRA_UDF_ERR_OUT_OF_MEMORY, -1, "no memory for a context");
    else {
      rt->ctxs = p;
      rt->cap_ctxs = cap;
    }
  }
  if (rc != KOMIRA_UDF_OK) {
    if (sv[0] >= 0) close(sv[0]);
    ctx_free(c);
    pthread_mutex_unlock(&rt->zy_mu);
    return rc;
  }
  rt->next_ctx = id;
  c->rt = rt;
  c->gen = g;
  c->id = id;
  c->slot = slot;
  c->fork_seq = g->loads;
  c->pid = (pid_t)pid;
  c->sock = sv[0];
  g->open_ctx++;
  rt->ctxs[rt->n_ctxs++] = c;
  udfpy_trace(rt, "fork gen=%d ctx=%llu slot=%u pid=%u", g->number, (unsigned long long)id, slot, pid);
  pthread_mutex_unlock(&rt->zy_mu);
  *out = c;
  return KOMIRA_UDF_OK;
}

void udfpy_close_context(komira_udf_context_t* c) {
  if (c == NULL) return;
  udfpy_rt* rt = c->rt;
  if (c->sock >= 0) close(c->sock); /* the worker exits at end of file */
  c->sock = -1;
  pthread_mutex_lock(&rt->zy_mu);
  for (int i = 0; i < rt->n_ctxs; i++)
    if (rt->ctxs[i] == c) {
      rt->ctxs[i] = rt->ctxs[--rt->n_ctxs];
      break;
    }
  udfpy_gen* g = c->gen;
  g->open_ctx--;
  if (g->retired && g->open_ctx == 0) udfpy_gen_shutdown(rt, g);
  pthread_mutex_unlock(&rt->zy_mu);
  ctx_free(c);
}

/* ---- one request on the worker's socket ------------------------------------------------- */

static void mark_lost(komira_udf_context_t* c, const char* why) {
  if (c->lost) return;
  c->lost = 1;
  snprintf(c->lost_why, sizeof(c->lost_why), "%s", why);
}

static int32_t lost_error(komira_udf_context_t* c, komira_udf_error* err) {
  return udfpy_fail(err, KOMIRA_UDF_ERR_INSTANCE_LOST, -1, "the worker (pid %d) is gone; no user code ran", (int)c->pid);
}

static int32_t crashed(komira_udf_context_t* c, komira_udf_error* err) {
  char why[64];
  snprintf(why, sizeof(why), "the worker (pid %d) ended during the call", (int)c->pid);
  mark_lost(c, why);
  return udfpy_fail(err, KOMIRA_UDF_ERR_WORKER_CRASHED, -1, "%s", why);
}

static int32_t broke(komira_udf_context_t* c, const char* why, komira_udf_error* err) {
  kill(c->pid, SIGKILL);
  mark_lost(c, "the worker's reply broke the framing");
  return udfpy_fail(err, KOMIRA_UDF_ERR_INTERNAL, -1, "the worker's reply broke the framing: %s", why);
}

typedef struct watch {
  int stored;
  int deadline; /* what stored the id: 1 the deadline, 0 the cancel flag */
} watch;

/* One request; with `call`, watch it. 0 with *reply (OK or ERROR), or a
 * status with `err` filled. */
static int32_t request(komira_udf_context_t* c, uint32_t op, uint64_t handle, const komira_udf_call* call,
                       const uint8_t* body, size_t body_len, udfpy_msg* reply, watch* w, komira_udf_error* err) {
  const komira_udf_host* host = c->rt->host;
  memset(reply, 0, sizeof(*reply));
  w->stored = w->deadline = 0;
  if (c->lost) return lost_error(c, err);
  int64_t remaining = 0;
  int64_t call_id = call != NULL ? call->call_id : 0;
  if (call != NULL && call->deadline_ns != 0) remaining = call->deadline_ns - host->now_ns(host->host_data);
  uint64_t id = ++c->next_request;
  /* The cancel word names a call by this request id, which is never 0 and
   * never repeats on a context, not by the host's call_id, which may be 0. */
  if (udfpy_send(c->sock, op, id, 0, handle, remaining, (int64_t)id, body, body_len, NULL, 0) != 0) {
    mark_lost(c, "the worker is gone");
    return lost_error(c, err);
  }
  while (call != NULL) { /* a request with no call waits in recv */
    struct pollfd p = {c->sock, POLLIN, 0};
    int r = poll(&p, 1, TICK_MS);
    if (r > 0) break;
    if (r < 0 && errno != EINTR) return crashed(c, err);
    if (w->stored) continue;
    int cancel = call->cancel != NULL && __atomic_load_n(call->cancel, __ATOMIC_ACQUIRE) != 0;
    int late = call->deadline_ns != 0 && host->now_ns(host->host_data) >= call->deadline_ns;
    if (cancel || late) {
      __atomic_store_n(c->word, (int64_t)id, __ATOMIC_RELEASE);
      w->stored = 1;
      w->deadline = !cancel;
      udfpy_trace(c->rt, "cancel_word ctx=%llu call=%lld why=%s", (unsigned long long)c->id, (long long)call_id,
                  cancel ? "cancel" : "deadline");
    }
  }
  const char* why = "";
  int rc = udfpy_recv(c->sock, reply, &why);
  if (rc == -1) return crashed(c, err);
  if (rc == -2) return broke(c, why, err);
  if ((reply->op != UDFPY_OP_OK && reply->op != UDFPY_OP_ERROR) || reply->request_id != id) {
    udfpy_msg_free(reply);
    return broke(c, "a reply that answers no request", err);
  }
  return KOMIRA_UDF_OK;
}

/* request(), then an ERROR reply mapped to its status; on OK *reply is the
 * reply, to free. */
static int32_t ask(komira_udf_context_t* c, uint32_t op, uint64_t handle, const komira_udf_call* call,
                   const uint8_t* body, size_t body_len, udfpy_msg* reply, komira_udf_error* err) {
  watch w;
  int32_t st = request(c, op, handle, call, body, body_len, reply, &w, err);
  if (st != KOMIRA_UDF_OK) return st;
  st = udfpy_reply_status(reply, err);
  if (st != KOMIRA_UDF_OK) udfpy_msg_free(reply);
  return st;
}

/* ---- instances ------------------------------------------------------------------------------- */

int32_t udfpy_open_instance(komira_udf_context_t* c, udfpy_udf* u, udfpy_inst** out, komira_udf_error* err) {
  *out = NULL;
  if (u->gen != c->gen || u->load_seq > c->fork_seq)
    return udfpy_fail(err, KOMIRA_UDF_ERR_UNSUPPORTED, -1, "UDF '%s' was loaded after this context was opened; open a new context",
                      u->entry);
  udfpy_msg r;
  int32_t st = ask(c, UDFPY_OP_OPEN_INSTANCE, u->id, NULL, NULL, 0, &r, err);
  if (st != KOMIRA_UDF_OK) return st;
  uint64_t iid = 0;
  if (r.len >= 8) memcpy(&iid, r.payload, 8);
  int ok = r.len >= 8;
  udfpy_msg_free(&r);
  if (!ok) return udfpy_fail(err, KOMIRA_UDF_ERR_INTERNAL, -1, "the worker's OPEN_INSTANCE reply is malformed");
  udfpy_inst* in = (udfpy_inst*)calloc(1, sizeof(*in));
  if (in == NULL) return udfpy_fail(err, KOMIRA_UDF_ERR_OUT_OF_MEMORY, -1, "no memory for an instance");
  in->ctx = c;
  in->udf = u;
  in->id = iid;
  *out = in;
  return KOMIRA_UDF_OK;
}

void udfpy_close_instance(udfpy_inst* in) {
  if (in == NULL) return;
  if (!in->ctx->lost) {
    udfpy_msg r;
    if (ask(in->ctx, UDFPY_OP_CLOSE_INSTANCE, in->id, NULL, NULL, 0, &r, NULL) == KOMIRA_UDF_OK) {
      uint32_t left = 0;
      if (r.len >= 4) { /* the instances the worker still holds */
        memcpy(&left, r.payload, 4);
        udfpy_trace(in->ctx->rt, "close_instance ctx=%llu inst=%llu left=%u", (unsigned long long)in->ctx->id,
                    (unsigned long long)in->id, left);
      }
      udfpy_msg_free(&r);
    }
  }
  free(in);
}

/* ---- calls --------------------------------------------------------------------------------------- */

static void take(struct ArrowDeviceArray* d, struct ArrowArray* mine) {
  memset(mine, 0, sizeof(*mine));
  if (d == NULL) return;
  *mine = d->array;
  d->array.release = NULL;
}

static void clear_out(struct ArrowDeviceArray* out) {
  if (out == NULL) return;
  memset(out, 0, sizeof(*out));
  out->device_id = -1;
  out->device_type = ARROW_DEVICE_CPU;
}

/* A struct array's children as one RecordBatch message. A struct that does
 * not match the bound schema is the host's breach (ERR_HOST_CONTRACT). */
static int32_t encode_struct(const struct ArrowArray* a, const udfpy_schema* s, udfpy_buf* b, komira_udf_error* err) {
  if (a->release == NULL) return udfpy_fail(err, KOMIRA_UDF_ERR_HOST_CONTRACT, -1, "the host passed a released argument struct");
  if (a->n_children != s->n || a->offset != 0 || (a->n_buffers > 0 && a->buffers != NULL && a->buffers[0] != NULL))
    return udfpy_fail(err, KOMIRA_UDF_ERR_HOST_CONTRACT, -1,
                      "the host passed a struct of %lld children at offset %lld%s; the bound schema has %d",
                      (long long)a->n_children, (long long)a->offset,
                      a->n_buffers > 0 && a->buffers != NULL && a->buffers[0] != NULL ? " with a bitmap" : "", s->n);
  char fmts[UDFPY_MAX_FIELDS];
  for (int i = 0; i < s->n; i++) fmts[i] = s->f[i].fmt;
  const char* why = NULL;
  if (udfpy_ipc_batch(b, a->length, s->n, (const struct ArrowArray* const*)a->children, fmts, &why) != 0)
    return udfpy_fail(err, b->oom ? KOMIRA_UDF_ERR_OUT_OF_MEMORY : KOMIRA_UDF_ERR_INTERNAL, -1, "%s", why);
  return KOMIRA_UDF_OK;
}

/* The worker's OK payload as the host's `out`: one column, checked against
 * the bound result field. */
static int32_t take_output(const komira_udf_host* host, udfpy_msg* r, const udfpy_field* want,
                           struct ArrowDeviceArray* out, komira_udf_error* err) {
  if (host->mem_reserve != NULL && host->mem_reserve(host->host_data, (int64_t)r->len) != KOMIRA_UDF_OK) {
    size_t n = r->len;
    udfpy_msg_free(r);
    return udfpy_fail(err, KOMIRA_UDF_ERR_OUT_OF_MEMORY, -1, "the host refused %zu bytes of output", n);
  }
  udfpy_hold* hold = udfpy_hold_new(r->payload, r->len, host);
  if (hold == NULL) {
    if (host->mem_release != NULL) host->mem_release(host->host_data, (int64_t)r->len);
    udfpy_msg_free(r);
    return udfpy_fail(err, KOMIRA_UDF_ERR_OUT_OF_MEMORY, -1, "no memory for an output");
  }
  r->payload = NULL;
  struct ArrowArray col;
  int64_t length = 0;
  const char* why = NULL;
  if (udfpy_ipc_decode(hold->payload, hold->bytes, want, 1, &length, hold, &col, &why) != 0) {
    udfpy_hold_drop(hold);
    return udfpy_fail(err, KOMIRA_UDF_ERR_INTERNAL, -1, "the worker's output failed validation: %s", why);
  }
  udfpy_out_column(out, &col);
  udfpy_hold_drop(hold);
  return KOMIRA_UDF_OK;
}

int32_t udfpy_call_batch(udfpy_inst* in, const komira_udf_call* call, struct ArrowDeviceArray* args,
                         struct ArrowDeviceArray* out, komira_udf_error* err) {
  komira_udf_context_t* c = in->ctx;
  const komira_udf_host* host = c->rt->host;
  struct ArrowArray mine;
  int32_t dev = args != NULL ? args->device_type : ARROW_DEVICE_CPU;
  take(args, &mine);
  clear_out(out);
  udfpy_buf b = {0};
  int32_t rc;
  if (call == NULL || call->struct_size < sizeof(*call)) {
    rc = udfpy_fail(err, KOMIRA_UDF_ERR_ABI, -1, "komira/python needs a komira_udf_call of ABI 1.0");
  } else if (dev != ARROW_DEVICE_CPU) {
    rc = udfpy_fail(err, KOMIRA_UDF_ERR_HOST_CONTRACT, -1, "arguments on device type %d, not the CPU", (int)dev);
  } else if (c->lost) {
    rc = lost_error(c, err);
  } else if (call->cancel != NULL && __atomic_load_n(call->cancel, __ATOMIC_ACQUIRE) != 0) {
    rc = udfpy_fail(err, KOMIRA_UDF_ERR_CANCELLED, -1, "cancelled before the batch was sent");
  } else if (call->deadline_ns != 0 && host->now_ns(host->host_data) >= call->deadline_ns) {
    rc = udfpy_fail(err, KOMIRA_UDF_ERR_DEADLINE, -1, "the deadline passed before the batch was sent");
  } else {
    rc = encode_struct(&mine, &in->udf->args, &b, err);
  }
  if (mine.release != NULL) mine.release(&mine);
  if (rc == KOMIRA_UDF_OK) {
    udfpy_msg rep;
    watch w;
    rc = request(c, UDFPY_OP_CALL_BATCH, in->id, call, b.p, b.n, &rep, &w, err);
    if (rc == KOMIRA_UDF_OK && rep.op == UDFPY_OP_OK) {
      rc = take_output(host, &rep, &in->udf->result.f[0], out, err);
    } else if (rc == KOMIRA_UDF_OK) {
      komira_udf_error e;
      memset(&e, 0, sizeof(e));
      e.struct_size = sizeof(e);
      rc = udfpy_reply_status(&rep, &e);
      udfpy_msg_free(&rep);
      if (rc == KOMIRA_UDF_ERR_CANCELLED && w.stored && w.deadline) {
        int64_t row = e.row;
        if (e.release != NULL) e.release(&e);
        rc = udfpy_fail(err, KOMIRA_UDF_ERR_DEADLINE, row, "the call passed its deadline at row %lld", (long long)row);
      } else {
        if (rc == KOMIRA_UDF_ERR_OUT_OF_MEMORY) mark_lost(c, "the worker ended after running out of memory");
        udfpy_error_move(err, &e);
      }
    }
  }
  udfpy_buf_free(&b);
  return rc;
}
