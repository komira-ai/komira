/*
 * worker.c: a context's worker, the calls on it, and its supervision
 * (docs/design/udf_python_worker.md section 5).
 *
 * open_context asks the current generation's zygote to fork one worker, and
 * hands it two descriptors in the FORK request: its end of a fresh socket
 * pair, and the memfd of the cancel word. The FORK reply carries the
 * worker's pid and a pidfd the zygote opened on it before answering, so the
 * pidfd names that process and no other. The context keeps the other end of
 * the socket, the pidfd and its own mapping of the word. On macOS, which has
 * neither memfd nor pidfd (design sections 5.2 and 5.3), the word is a file
 * under the `scratch` option, unlinked at once, and the reply carries the
 * pid alone. Every call on the
 * context's instances goes to that worker, which runs user code on its one
 * thread.
 *
 * Cancel: the worker cannot read its socket during a call, so while the
 * library waits for a reply it polls in 10 ms ticks; a tick that finds the
 * host's cancel flag set or the deadline passed (by host->now_ns) stores the
 * call's id in the cancel word, once, which the worker reads between rows.
 * A worker that has not answered grace_ms (by host->now_ns) after the store
 * is stopped by force: the context records that it is sending the signal,
 * then sends SIGKILL through the pidfd. On macOS it sends kill(pid), and
 * only while the worker's socket has not ended and no EXIT report names the
 * worker; a pid freed and handed out again between that check and the kill
 * is the race the design accepts.
 *
 * Ends: end of file on the worker's socket means the worker ended. Before a
 * status is returned the context waits, under rt->zy_mu, for the zygote's
 * EXIT report of that worker, or for the zygote's own end, and names it:
 *   - during a call: ERR_KILLED when the library's SIGKILL ended it, else
 *     ERR_WORKER_CRASHED naming the signal or exit status, or the zygote's
 *     end;
 *   - before a request (the context polls the socket for a hang-up first, and
 *     checks the generation's `dead` and its own `exit_known`), or in a
 *     request that runs no user code: ERR_INSTANCE_LOST naming the same.
 * Either way the context is lost: every later request returns
 * ERR_INSTANCE_LOST without reaching a worker, and closing it succeeds.
 * Nothing is retried.
 *
 * Ownership: `args` is moved in on every call whatever the status and
 * released once its bytes are encoded (or on early refusal). `out` is the
 * host's on OK only: arrays that borrow the reply's payload, whose bytes are
 * reserved through host->mem_reserve until the last array is released.
 *
 * A context is used by one engine thread at a time; only the registry, the
 * generation's counts and the EXIT fields, touched under rt->zy_mu, are
 * shared.
 */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#ifndef __APPLE__
#include <sys/syscall.h>
#endif
#include <unistd.h>

#include "udfpy.h"

#define TICK_MS 10

#ifdef __APPLE__
/* The cancel word's descriptor (design section 5.2): a file of its own under
 * the `scratch` option (mkostemp, mode 0600, close-on-exec), unlinked at
 * once, so only the descriptors name it, then sized to 8 bytes. Not
 * shm_open, which a sandboxed process is refused. -1 with errno. */
static int file_word(const char* scratch) {
  char path[4200];
  int n = snprintf(path, sizeof(path), "%s/cancel-XXXXXX", scratch);
  if (n < 0 || (size_t)n >= sizeof(path)) {
    errno = ENAMETOOLONG;
    return -1;
  }
  int fd = mkostemp(path, O_CLOEXEC);
  if (fd < 0) return -1;
  unlink(path);
  if (ftruncate(fd, 8) != 0) {
    int e = errno;
    close(fd);
    errno = e;
    return -1;
  }
  return fd;
}

/* recv with MSG_PEEK: 1 once the peer's end has closed and nothing is left to read. */
static int sock_ended(int sock) {
  char b;
  ssize_t k;
  do {
    k = recv(sock, &b, 1, MSG_PEEK | MSG_DONTWAIT);
  } while (k < 0 && errno == EINTR);
  return k == 0;
}
#endif

/* ---- opening and closing a context --------------------------------------------------- */

static void ctx_free(komira_udf_context_t* c) {
  if (c->sock >= 0) close(c->sock);
  if (c->pidfd >= 0) close(c->pidfd);
  if (c->word != NULL) munmap((void*)c->word, 8);
  free(c);
}

/* The current generation in *out, after reading what its zygote sent
 * unasked; a status with `err` filled when there is none to fork from. */
static int32_t fork_gen(udfpy_rt* rt, udfpy_gen** out, komira_udf_error* err) {
  udfpy_gen* g = rt->cur;
  *out = NULL;
  if (g != NULL) udfpy_ctl_drain(rt, g);
  if (g == NULL && rt->n_gens > 0) g = rt->gens[rt->n_gens - 1]; /* the last one, to name its end */
  if (g != NULL && g->dead && g->helloed) {
    char how[48];
    udfpy_how_text(g->exit_how, g->exit_value, how, sizeof(how));
    return udfpy_fail(err, KOMIRA_UDF_ERR_INSTANCE_LOST, -1,
                      "the zygote (pid %d) ended with %s; load the UDFs again to open a context", (int)g->spawn_pid,
                      how);
  }
  if (g == NULL || g->retired)
    return udfpy_fail(err, KOMIRA_UDF_ERR_UNSUPPORTED, -1, "no UDF is loaded; open a context after a load");
  *out = g;
  return KOMIRA_UDF_OK;
}

int32_t udfpy_open_context(udfpy_rt* rt, uint32_t slot, komira_udf_context_t** out, komira_udf_error* err) {
  *out = NULL;
  if (rt->forked)
    return udfpy_fail(err, KOMIRA_UDF_ERR_INSTANCE_LOST, -1, "komira/python: %s", UDFPY_FORKED_WHY);
  pthread_mutex_lock(&rt->zy_mu);
  udfpy_gen* g = NULL;
  int32_t gst = fork_gen(rt, &g, err);
  if (gst != KOMIRA_UDF_OK) {
    pthread_mutex_unlock(&rt->zy_mu);
    return gst;
  }
  komira_udf_context_t* c = (komira_udf_context_t*)calloc(1, sizeof(*c));
  if (c == NULL) {
    pthread_mutex_unlock(&rt->zy_mu);
    return udfpy_fail(err, KOMIRA_UDF_ERR_OUT_OF_MEMORY, -1, "no memory for a context");
  }
  c->sock = -1;
  c->pidfd = -1;
  int sv[2] = {-1, -1};
  int mfd = -1;
  int32_t rc = KOMIRA_UDF_OK;
  if (udfpy_socketpair(sv) != 0) {
    rc = udfpy_fail(err, KOMIRA_UDF_ERR_INTERNAL, -1, "socketpair: %s", strerror(errno));
#ifdef __APPLE__
  } else if ((mfd = file_word(rt->opt.scratch)) < 0) {
    rc = udfpy_fail(err, KOMIRA_UDF_ERR_INTERNAL, -1, "the cancel word's file under '%s': %s", rt->opt.scratch,
                    strerror(errno));
#else
  } else if ((mfd = memfd_create("komira-udf-cancel", MFD_CLOEXEC)) < 0 || ftruncate(mfd, 8) != 0) {
    rc = udfpy_fail(err, KOMIRA_UDF_ERR_INTERNAL, -1, "memfd_create: %s", strerror(errno));
#endif
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
#ifdef __APPLE__
      if (rc == KOMIRA_UDF_OK && r.len >= 4 && r.nfds == 0) {
        memcpy(&pid, r.payload, 4); /* no pidfd on macOS: the pid alone */
      } else if (rc == KOMIRA_UDF_OK) {
#else
      if (rc == KOMIRA_UDF_OK && r.len >= 4 && r.nfds == 1) {
        memcpy(&pid, r.payload, 4);
        c->pidfd = r.fds[0]; /* the context owns it now */
        r.nfds = 0;
      } else if (rc == KOMIRA_UDF_OK) {
#endif
        rc = udfpy_fail(err, KOMIRA_UDF_ERR_INTERNAL, -1, "the zygote's FORK reply is malformed");
      }
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

/* ---- the ends of a worker --------------------------------------------------------------- */

static void mark_lost(komira_udf_context_t* c, const char* fmt, ...) __attribute__((format(printf, 2, 3)));
static void mark_lost(komira_udf_context_t* c, const char* fmt, ...) {
  if (c->lost) return;
  c->lost = 1;
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(c->lost_why, sizeof(c->lost_why), fmt, ap);
  va_end(ap);
}

static int32_t lost_error(komira_udf_context_t* c, komira_udf_error* err) {
  return udfpy_fail(err, KOMIRA_UDF_ERR_INSTANCE_LOST, -1, "the worker (pid %d) is gone: %s; no user code ran",
                    (int)c->pid, c->lost_why);
}

static void send_kill(komira_udf_context_t* c) {
#ifdef __APPLE__
  if (c->pid > 0 && c->sock >= 0 && !__atomic_load_n(&c->exit_known, __ATOMIC_ACQUIRE) && !sock_ended(c->sock))
    kill(c->pid, SIGKILL);
#else
  if (c->pidfd >= 0) syscall(SYS_pidfd_send_signal, c->pidfd, SIGKILL, NULL, 0);
#endif
}

/* How the context's worker ended, once it has: wait for its EXIT report (or
 * the zygote's end) under the zygote lock. *known is 1 when the report came;
 * else `zhow` names the zygote's end. */
typedef struct ending {
  int known, how, value;
  pid_t zygote;
  char text[64]; /* the worker's end, or the zygote's */
} ending;

static void await_end(komira_udf_context_t* c, ending* e) {
  udfpy_rt* rt = c->rt;
  pthread_mutex_lock(&rt->zy_mu);
  udfpy_await_exit(rt, c);
  e->known = c->exit_known;
  e->how = c->exit_how;
  e->value = c->exit_value;
  e->zygote = c->gen->spawn_pid;
  if (e->known)
    udfpy_how_text(e->how, e->value, e->text, sizeof(e->text));
  else
    udfpy_how_text(c->gen->exit_how, c->gen->exit_value, e->text, sizeof(e->text));
  pthread_mutex_unlock(&rt->zy_mu);
}

/* The worker ended while no call of user code was in progress. */
static int32_t ended_idle(komira_udf_context_t* c, komira_udf_error* err) {
  ending e;
  await_end(c, &e);
  if (e.known)
    mark_lost(c, "it ended with %s while no call was running", e.text);
  else
    mark_lost(c, "its zygote (pid %d) ended with %s", (int)e.zygote, e.text);
  return lost_error(c, err);
}

/* The worker's socket ended during a call. */
static int32_t ended_in_call(komira_udf_context_t* c, komira_udf_error* err) {
  ending e;
  await_end(c, &e);
  int pid = (int)c->pid;
  if (e.known && c->killing && e.how == 1 && e.value == SIGKILL) {
    mark_lost(c, "it was stopped with SIGKILL during an earlier call");
    return udfpy_fail(err, KOMIRA_UDF_ERR_KILLED, -1,
                      "the worker (pid %d) did not stop within grace_ms=%lld after %s and was stopped with SIGKILL", pid,
                      (long long)c->rt->opt.grace_ms, c->kill_deadline ? "its deadline passed" : "the cancel");
  }
  if (e.known) {
    mark_lost(c, "it ended during an earlier call with %s", e.text);
    return udfpy_fail(err, KOMIRA_UDF_ERR_WORKER_CRASHED, -1, "the worker (pid %d) ended during the call with %s", pid,
                      e.text);
  }
  mark_lost(c, "its zygote (pid %d) ended with %s", (int)e.zygote, e.text);
  return udfpy_fail(err, KOMIRA_UDF_ERR_WORKER_CRASHED, -1,
                    "the worker (pid %d) ended during the call when its zygote (pid %d) ended with %s", pid,
                    (int)e.zygote, e.text);
}

/* The worker broke the protocol: it is stopped, and the context lost. */
static int32_t broke(komira_udf_context_t* c, const char* why, komira_udf_error* err) {
  send_kill(c);
  mark_lost(c, "its reply broke the framing");
  return udfpy_fail(err, KOMIRA_UDF_ERR_INTERNAL, -1, "the worker's reply broke the framing: %s", why);
}

/* Before a request: refuse it without reaching the worker when the context
 * is lost, or when its worker or zygote has ended since the last request. */
static int32_t check_alive(komira_udf_context_t* c, komira_udf_error* err) {
  if (c->rt->forked) {
    mark_lost(c, "%s", UDFPY_FORKED_WHY);
    return lost_error(c, err);
  }
  if (c->lost) return lost_error(c, err);
  struct pollfd p = {c->sock, POLLIN, 0}; /* an idle worker sends nothing: anything is its end */
  if (poll(&p, 1, 0) > 0 || __atomic_load_n(&c->exit_known, __ATOMIC_ACQUIRE) ||
      __atomic_load_n(&c->gen->dead, __ATOMIC_ACQUIRE))
    return ended_idle(c, err);
  return KOMIRA_UDF_OK;
}

/* ---- one request on the worker's socket ------------------------------------------------- */

typedef struct watch {
  int stored;
  int deadline; /* what stored the id: 1 the deadline, 0 the cancel flag */
  int64_t stored_at; /* host->now_ns when it was stored */
} watch;

/* grace_ms after the store, the library stops the worker by force. */
static void force_stop(komira_udf_context_t* c, const watch* w, int64_t call_id, int64_t now) {
  c->killing = 1;
  c->kill_deadline = w->deadline;
  udfpy_trace(c->rt, "sigkill ctx=%llu pid=%d call=%lld why=%s now=%lld", (unsigned long long)c->id, (int)c->pid,
              (long long)call_id, w->deadline ? "deadline" : "cancel", (long long)now);
  send_kill(c);
}

/* One request; with `call`, watch it. 0 with *reply (OK or ERROR), or a
 * status with `err` filled. */
static int32_t request(komira_udf_context_t* c, uint32_t op, uint64_t handle, const komira_udf_call* call,
                       const uint8_t* body, size_t body_len, udfpy_msg* reply, watch* w, komira_udf_error* err) {
  const komira_udf_host* host = c->rt->host;
  memset(reply, 0, sizeof(*reply));
  memset(w, 0, sizeof(*w));
  int32_t st = check_alive(c, err);
  if (st != KOMIRA_UDF_OK) return st;
  int64_t remaining = 0;
  int64_t call_id = call != NULL ? call->call_id : 0;
  if (call != NULL && call->deadline_ns != 0) remaining = call->deadline_ns - host->now_ns(host->host_data);
  uint64_t id = ++c->next_request;
  c->killing = 0;
  /* The cancel word names a call by this request id, which is never 0 and
   * never repeats on a context, not by the host's call_id, which may be 0. */
  if (udfpy_send(c->sock, op, id, 0, handle, remaining, (int64_t)id, body, body_len, NULL, 0) != 0)
    return ended_idle(c, err);
  int64_t grace_ns = c->rt->opt.grace_ms * 1000000;
  while (call != NULL) { /* a request with no call waits in recv */
    struct pollfd p = {c->sock, POLLIN, 0};
    int r = poll(&p, 1, TICK_MS);
    if (r > 0) break;
    if (r < 0 && errno == EINTR) continue;
    if (r < 0) return broke(c, "poll of its socket failed", err);
    int64_t now = host->now_ns(host->host_data);
    if (w->stored) {
      if (!c->killing && now - w->stored_at >= grace_ns) force_stop(c, w, call_id, now);
      continue;
    }
    int cancel = call->cancel != NULL && __atomic_load_n(call->cancel, __ATOMIC_ACQUIRE) != 0;
    int late = call->deadline_ns != 0 && now >= call->deadline_ns;
    if (cancel || late) {
      __atomic_store_n(c->word, (int64_t)id, __ATOMIC_RELEASE);
      w->stored = 1;
      w->deadline = !cancel;
      w->stored_at = now;
      udfpy_trace(c->rt, "cancel_word ctx=%llu call=%lld why=%s now=%lld", (unsigned long long)c->id,
                  (long long)call_id, cancel ? "cancel" : "deadline", (long long)now);
    }
  }
  const char* why = "";
  int rc = udfpy_recv(c->sock, reply, &why);
  if (rc == -1) return op == UDFPY_OP_CALL_BATCH ? ended_in_call(c, err) : ended_idle(c, err);
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
  atomic_fetch_add_explicit(&u->refs, 1, memory_order_relaxed);
  in->udf = u;
  in->id = iid;
  *out = in;
  return KOMIRA_UDF_OK;
}

void udfpy_close_instance(udfpy_inst* in) {
  if (in == NULL) return;
  if (!in->ctx->lost) {
    udfpy_msg r;
    /* ask() returns OK only for an OK reply; an ERROR reply is freed there. */
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
  udfpy_udf_drop(in->udf);
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
  const char* why = NULL;
  if (udfpy_ipc_batch(b, a->length, s, (const struct ArrowArray* const*)a->children, &why) != 0)
    return udfpy_fail(err, b->oom ? KOMIRA_UDF_ERR_OUT_OF_MEMORY : KOMIRA_UDF_ERR_INTERNAL, -1, "%s", why);
  return KOMIRA_UDF_OK;
}

/* The worker's OK payload as the host's `out`: one column, checked against
 * the bound result type. */
static int32_t take_output(const komira_udf_host* host, udfpy_msg* r, const udfpy_schema* want,
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
  if (udfpy_ipc_decode(hold->payload, hold->bytes, want, &length, hold, &col, &why) != 0) {
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
  } else if (c->lost || c->rt->forked) {
    rc = check_alive(c, err);
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
      rc = take_output(host, &rep, &in->udf->result, out, err);
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
        if (rc == KOMIRA_UDF_ERR_OUT_OF_MEMORY) { /* the worker exits after it answers */
          ending end;
          await_end(c, &end);
          mark_lost(c, "it ended with %s after it ran out of memory in an earlier call", end.text);
        }
        udfpy_error_move(err, &e);
      }
    }
  }
  udfpy_buf_free(&b);
  return rc;
}
