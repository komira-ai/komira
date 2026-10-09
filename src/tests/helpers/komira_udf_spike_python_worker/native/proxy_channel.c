/*
 * One Python worker process and its two channels, engine side
 * (docs/design/udf_runtime_interface.md section 5.2). Test-only spike code.
 *
 *   - The control channel: a Unix stream socket pair created at spawn. Every
 *     message starts with the 40-byte header of komira_udf_wire.h; a
 *     payload flagged KOMIRA_UDF_WIRE_INLINE follows it on the socket.
 *   - The shared region: one anonymous memory file per worker (memfd),
 *     passed with HELLO (SCM_RIGHTS): a control page, the engine-to-worker
 *     heap and the worker-to-engine heap (pyw.h). Without it (the pipe
 *     transport) every payload is inline.
 *
 * Engine to worker: a batch is serialized straight into a slot of the
 * engine-to-worker heap (the one copy, section 5.2), and the worker decodes
 * it in place. The worker frees a slot when nothing it handed user code
 * still views it, by pushing the slot's id onto the release ring in the
 * control page; the engine drains the ring before it allocates. When no
 * slot fits (user code keeps views of every input), the batch goes inline,
 * so a full heap never blocks either side.
 *
 * Worker to engine: the worker writes each reply's payload at the start of
 * its heap (one call is in flight per worker), and the engine copies it out
 * before it decodes it, so the worker cannot change bytes the engine has
 * checked (section 5.2). The next request frees that space.
 *
 * Control bodies (HELLO, LOAD, OPEN_*, ERROR, ...) are small and always go
 * inline.
 *
 * FFI-BOUNDARY. Owners: the socket, the memfd and the mapping are the
 * pyw_chan's, closed by pyw_chan_close. A reply's payload is a malloc block
 * the caller frees (pyw_reply_free). `args` given to pyw_chan_call is the
 * caller's moved-in array, released here once it is serialized. The worker
 * process is reaped here when the engine spawned it; a zygote's child is
 * the zygote's to reap, and is only waited for here.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "pyw.h"

#define DEADLINE_GRACE_NS 2000000000LL
#define CANCEL_GRACE_NS 2000000000LL
#define REAP_WAIT_MS 2000

static int64_t mono_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static void die(struct pyw_chan* c, const char* why) {
  if (!c->dead) snprintf(c->why, sizeof(c->why), "%s", why);
  c->dead = 1;
}

/* After end of file: how the worker ended, when it is ours to ask. */
static void died_eof(struct pyw_chan* c) {
  char m[256];
  int st = 0;
  pid_t r = -1;
  if (c->our_child) {
    for (int i = 0; i < 200 && (r = waitpid(c->pid, &st, WNOHANG)) == 0; i++) usleep(1000);
  }
  if (r == c->pid && WIFSIGNALED(st))
    snprintf(m, sizeof(m), "UDF_WORKER_CRASHED: worker %d ended by signal %d", (int)c->pid, WTERMSIG(st));
  else if (r == c->pid && WIFEXITED(st))
    snprintf(m, sizeof(m), "UDF_WORKER_CRASHED: worker %d exited with status %d", (int)c->pid, WEXITSTATUS(st));
  else
    snprintf(m, sizeof(m), "UDF_WORKER_CRASHED: worker %d closed its control channel", (int)c->pid);
  if (r == c->pid) c->our_child = 0; /* reaped */
  die(c, m);
}

/* ---- the socket ---------------------------------------------------------- */

static int send_all(struct pyw_chan* c, const struct iovec* iov0, int n, const int* fds, int nfds) {
  struct iovec iov[4];
  memcpy(iov, iov0, sizeof(struct iovec) * (size_t)n);
  union {
    char buf[CMSG_SPACE(sizeof(int) * 4)];
    struct cmsghdr align;
  } u;
  int first = 1;
  int at = 0;
  while (at < n) {
    struct msghdr mh;
    memset(&mh, 0, sizeof(mh));
    mh.msg_iov = iov + at;
    mh.msg_iovlen = (size_t)(n - at);
    if (first && nfds > 0) {
      memset(&u, 0, sizeof(u));
      mh.msg_control = u.buf;
      mh.msg_controllen = CMSG_SPACE(sizeof(int) * (size_t)nfds);
      struct cmsghdr* cm = CMSG_FIRSTHDR(&mh);
      cm->cmsg_level = SOL_SOCKET;
      cm->cmsg_type = SCM_RIGHTS;
      cm->cmsg_len = CMSG_LEN(sizeof(int) * (size_t)nfds);
      memcpy(CMSG_DATA(cm), fds, sizeof(int) * (size_t)nfds);
    }
    ssize_t w = sendmsg(c->fd, &mh, MSG_NOSIGNAL);
    if (w < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    first = 0;
    size_t left = (size_t)w;
    while (at < n && left >= iov[at].iov_len) left -= iov[at++].iov_len;
    if (at < n) {
      iov[at].iov_base = (char*)iov[at].iov_base + left;
      iov[at].iov_len -= left;
    }
  }
  return 0;
}

/* Reads exactly n bytes; 0, or -1 at end of file or on an error. */
static int recv_all(struct pyw_chan* c, void* p, size_t n) {
  size_t at = 0;
  while (at < n) {
    ssize_t r = recv(c->fd, (char*)p + at, n - at, 0);
    if (r == 0) return -1;
    if (r < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    at += (size_t)r;
  }
  return 0;
}

static int send_header(struct pyw_chan* c, uint32_t op, uint64_t id, uint32_t flags, uint32_t slot, uint64_t off,
                       uint64_t len, const void* inline_body, const int* fds, int nfds) {
  komira_udf_wire_header h = {KOMIRA_UDF_WIRE_MAGIC, op, id, flags, slot, off, len};
  struct iovec iov[2] = {{&h, sizeof(h)}, {(void*)inline_body, inline_body ? (size_t)len : 0}};
  if (send_all(c, iov, inline_body && len ? 2 : 1, fds, nfds) != 0) {
    die(c, "UDF_WORKER_CRASHED: the control channel refused a write (the worker is gone)");
    return -1;
  }
  return 0;
}

/* One message from the worker: its header, and its payload copied into a
 * malloc block (from the socket, or out of the worker-to-engine heap). */
static int read_message(struct pyw_chan* c, komira_udf_wire_header* h, struct pyw_reply* rep) {
  if (recv_all(c, h, sizeof(*h)) != 0) {
    died_eof(c);
    return -1;
  }
  if (h->magic != KOMIRA_UDF_WIRE_MAGIC) {
    die(c, "UDF_RUNTIME_FAULT: a reply without the protocol's magic");
    return -1;
  }
  rep->op = h->op;
  rep->payload = NULL;
  rep->len = 0;
  if (h->payload_len == 0) return 0;
  if (h->payload_len > (1ull << 31)) {
    die(c, "UDF_RUNTIME_FAULT: a reply payload over 2 GiB");
    return -1;
  }
  rep->payload = malloc(h->payload_len);
  if (rep->payload == NULL) {
    die(c, "UDF_RUNTIME_FAULT: out of memory for a reply");
    return -1;
  }
  rep->len = h->payload_len;
  if (h->flags & KOMIRA_UDF_WIRE_INLINE) {
    if (recv_all(c, rep->payload, rep->len) != 0) {
      pyw_reply_free(rep);
      died_eof(c);
      return -1;
    }
    return 0;
  }
  if (c->shm == NULL || h->payload_offset > PYW_HEAP_BYTES || h->payload_len > PYW_HEAP_BYTES - h->payload_offset) {
    pyw_reply_free(rep);
    die(c, "UDF_RUNTIME_FAULT: a reply payload outside the worker-to-engine heap");
    return -1;
  }
  /* The one copy of the worker-to-engine direction. */
  memcpy(rep->payload, c->shm + PYW_CTRL_BYTES + PYW_HEAP_BYTES + h->payload_offset, rep->len);
  return 0;
}

void pyw_reply_free(struct pyw_reply* r) {
  free(r->payload);
  r->payload = NULL;
  r->len = 0;
}

int pyw_chan_request(struct pyw_chan* c, uint32_t op, const struct pyw_buf* body, const int* fds, int nfds,
                     struct pyw_reply* rep) {
  memset(rep, 0, sizeof(*rep));
  if (c->dead) return -1;
  uint64_t id = ++c->next_id;
  size_t len = body ? body->len : 0;
  if (send_header(c, op, id, len ? KOMIRA_UDF_WIRE_INLINE : 0, 0, 0, len, len ? body->p : NULL, fds, nfds) != 0)
    return -1;
  komira_udf_wire_header h;
  if (read_message(c, &h, rep) != 0) return -1;
  if (h.request_id != id || (h.op != KOMIRA_UDF_OP_OK && h.op != KOMIRA_UDF_OP_ERROR)) {
    pyw_reply_free(rep);
    die(c, "UDF_RUNTIME_FAULT: a reply that answers no request");
    return -1;
  }
  return 0;
}

/* ---- the shared region --------------------------------------------------- */

static volatile uint32_t* ctrl_u32(struct pyw_chan* c, uint32_t at) { return (volatile uint32_t*)(c->shm + at); }

/* Frees every slot whose id the worker pushed onto the release ring. */
static void drain_ring(struct pyw_chan* c) {
  uint32_t head = __atomic_load_n(ctrl_u32(c, PYW_CTRL_RING_HEAD), __ATOMIC_ACQUIRE);
  uint32_t tail = *ctrl_u32(c, PYW_CTRL_RING_TAIL);
  while (tail != head) {
    uint32_t id = *ctrl_u32(c, PYW_CTRL_RING + 4 * (tail % PYW_RING_SLOTS));
    if (id < PYW_MAX_SLOTS) c->slots[id].used = 0;
    tail++;
  }
  __atomic_store_n(ctrl_u32(c, PYW_CTRL_RING_TAIL), tail, __ATOMIC_RELEASE);
}

/* A slot of `need` bytes: the lowest offset (0, or the end of a held slot)
 * where it overlaps no held slot. Returns the slot id, or -1. */
static int slot_alloc(struct pyw_chan* c, size_t need, uint32_t* off) {
  drain_ring(c);
  need = (need + PYW_ALIGN - 1) & ~(size_t)(PYW_ALIGN - 1);
  if (need > PYW_HEAP_BYTES) return -1;
  int free_id = -1;
  for (int i = 0; i < PYW_MAX_SLOTS && free_id < 0; i++)
    if (!c->slots[i].used) free_id = i;
  if (free_id < 0) return -1;
  int64_t best = -1;
  for (int k = -1; k < PYW_MAX_SLOTS; k++) {
    if (k >= 0 && !c->slots[k].used) continue;
    size_t at = k < 0 ? 0 : (size_t)c->slots[k].off + c->slots[k].len;
    if (at + need > PYW_HEAP_BYTES) continue;
    int clash = 0;
    for (int j = 0; j < PYW_MAX_SLOTS && !clash; j++)
      if (c->slots[j].used && at < (size_t)c->slots[j].off + c->slots[j].len && (size_t)c->slots[j].off < at + need)
        clash = 1;
    if (!clash && (best < 0 || (int64_t)at < best)) best = (int64_t)at;
  }
  if (best < 0) return -1;
  c->slots[free_id] = (struct pyw_slot){(uint32_t)best, (uint32_t)need, 1};
  *off = (uint32_t)best;
  return free_id;
}

/* ---- starting a worker --------------------------------------------------- */

static int hello(struct pyw_chan* c, int use_shm, char* why, size_t n) {
  c->memfd = -1;
  c->shm = NULL;
  if (use_shm) {
    c->memfd = memfd_create("komira-udf-worker", MFD_CLOEXEC);
    if (c->memfd < 0 || ftruncate(c->memfd, PYW_SHM_BYTES) != 0) {
      snprintf(why, n, "memfd for the shared region: %s", strerror(errno));
      return -1;
    }
    void* m = mmap(NULL, PYW_SHM_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED, c->memfd, 0);
    if (m == MAP_FAILED) {
      snprintf(why, n, "mapping the shared region: %s", strerror(errno));
      return -1;
    }
    c->shm = m;
    *ctrl_u32(c, PYW_CTRL_MAGIC) = PYW_SHM_MAGIC;
  }
  struct pyw_buf b = {0};
  pyw_buf_u32(&b, KOMIRA_UDF_WIRE_VERSION);
  pyw_buf_u32(&b, KOMIRA_UDF_ABI_MAJOR);
  pyw_buf_u32(&b, KOMIRA_UDF_ABI_MINOR);
  pyw_buf_u32(&b, use_shm ? 1u : 0u);
  pyw_buf_u64(&b, PYW_SHM_BYTES);
  pyw_buf_u64(&b, PYW_HEAP_BYTES);
  struct pyw_reply r;
  int rc = pyw_chan_request(c, KOMIRA_UDF_OP_HELLO, &b, use_shm ? &c->memfd : NULL, use_shm ? 1 : 0, &r);
  pyw_buf_free(&b);
  if (rc != 0) {
    snprintf(why, n, "HELLO: %s", c->why);
    return -1;
  }
  /* OK: the worker's wire version, ABI major and ABI minor, then its pid.
   * ERROR: its refusal. Both sides come from one image, so any difference
   * is refused (section 5.2), on either side. */
  struct pyw_rd d = {r.payload, r.len, 0, 0};
  int ok = 0;
  if (r.op == KOMIRA_UDF_OP_OK) {
    uint32_t wire = pyw_rd_u32(&d), major = pyw_rd_u32(&d), minor = pyw_rd_u32(&d);
    (void)pyw_rd_i32(&d);
    ok = !d.bad && wire == KOMIRA_UDF_WIRE_VERSION && major == KOMIRA_UDF_ABI_MAJOR && minor == KOMIRA_UDF_ABI_MINOR;
    if (d.bad)
      snprintf(why, n, "HELLO: a malformed OK from the worker");
    else if (!ok)
      snprintf(why, n, "HELLO: the worker speaks wire %u ABI %u.%u, this engine wire %u ABI %u.%u; any difference is refused",
               wire, major, minor, KOMIRA_UDF_WIRE_VERSION, KOMIRA_UDF_ABI_MAJOR, KOMIRA_UDF_ABI_MINOR);
  } else {
    (void)pyw_rd_i32(&d);
    (void)pyw_rd_i64(&d);
    (void)pyw_rd_i64(&d);
    char* m = pyw_rd_str(&d);
    snprintf(why, n, "HELLO refused by the worker: %s", m ? m : "(a malformed ERROR)");
    free(m);
  }
  pyw_reply_free(&r);
  if (!ok) die(c, why);
  return ok ? 0 : -1;
}

static void chan_init(struct pyw_chan* c) {
  memset(c, 0, sizeof(*c));
  c->fd = -1;
  c->memfd = -1;
}

int pyw_chan_start(struct pyw_chan* c, const struct pyw_launch* l, char* why, size_t n) {
  chan_init(c);
  int sv[2];
  if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sv) != 0) {
    snprintf(why, n, "socketpair: %s", strerror(errno));
    return -1;
  }
  /* The worker's end at fd 3. Moved above 9 first, so dup2 onto 3 is never
   * a no-op that would keep FD_CLOEXEC. */
  int wfd = fcntl(sv[1], F_DUPFD_CLOEXEC, 10);
  close(sv[1]);
  char exe[1200], script[1200];
  snprintf(exe, sizeof(exe), "%s/python/bin/python3.13", l->dir);
  snprintf(script, sizeof(script), "%s/pyworker/komira_udf_pyworker.py", l->dir);
  char* argv[] = {exe, "-I", "-S", "-B", script, "--role", (char*)l->role, "--dir", (char*)l->dir,
                  "--codec", (char*)l->codec, NULL};
  char* env_limited[] = {"LC_ALL=C", "TZ=UTC0", "OPENBLAS_NUM_THREADS=1", "OMP_NUM_THREADS=1",
                         "MKL_NUM_THREADS=1", NULL};
  char* env_free[] = {"LC_ALL=C", "TZ=UTC0", NULL};
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_adddup2(&fa, wfd, 3);
  pid_t pid = -1;
  int err = wfd < 0 ? EBADF : posix_spawn(&pid, exe, &fa, NULL, argv, l->limit_threads ? env_limited : env_free);
  posix_spawn_file_actions_destroy(&fa);
  if (wfd >= 0) close(wfd);
  if (err != 0) {
    close(sv[0]);
    snprintf(why, n, "posix_spawn %s: %s", exe, strerror(err));
    return -1;
  }
  c->fd = sv[0];
  c->pid = pid;
  c->our_child = 1;
  return 0;
}

int pyw_chan_spawn(struct pyw_chan* c, const struct pyw_launch* l, int use_shm, char* why, size_t n) {
  if (pyw_chan_start(c, l, why, n) != 0) return -1;
  return hello(c, use_shm, why, n);
}

int pyw_chan_adopt(struct pyw_chan* c, int fd, pid_t pid, int use_shm, char* why, size_t n) {
  chan_init(c);
  c->fd = fd;
  c->pid = pid;
  c->our_child = 0;
  return hello(c, use_shm, why, n);
}

/* ---- a call -------------------------------------------------------------- */

static int call_once(struct pyw_chan* c, const uint8_t* head, size_t head_len, int64_t length,
                     const struct ArrowArray* const* cols, const int* widths, int ncols, struct ArrowArray* args,
                     const komira_udf_call* call, const komira_udf_host* host, struct pyw_reply* rep, int* killed);

/* Waits for the call's reply, forwarding clock reads and the cancel flag.
 * A worker that has not answered CANCEL_GRACE_NS after the cancel reached
 * it, or DEADLINE_GRACE_NS past the call's deadline, is killed (section
 * 5.2): user code in a long C loop or a blocking call never reads the
 * flag. */
static int await_reply(struct pyw_chan* c, uint64_t id, const komira_udf_call* call, const komira_udf_host* host,
                       struct pyw_reply* rep, int* killed) {
  int cancel_sent = 0;
  int64_t cancel_at = 0;
  for (;;) {
    struct pollfd p = {c->fd, POLLIN, 0};
    int pr = poll(&p, 1, 1);
    if (pr < 0 && errno != EINTR) {
      die(c, "UDF_RUNTIME_FAULT: poll on the control channel failed");
      return -1;
    }
    if (c->shm != NULL) {
      uint32_t reads = __atomic_load_n(ctrl_u32(c, PYW_CTRL_CLOCK_READS), __ATOMIC_ACQUIRE);
      while (c->clock_seen != reads) {
        c->clock_seen++;
        (void)host->now_ns(host->host_data);
      }
    }
    if (!cancel_sent && call->cancel != NULL && __atomic_load_n(call->cancel, __ATOMIC_ACQUIRE) != 0) {
      /* The worker runs user code on its one thread and reads no message
       * meanwhile: the flag in the control page, or (pipe) SIGUSR1, whose
       * handler sets its local flag. CANCEL follows for the record. */
      if (c->shm != NULL)
        __atomic_store_n((volatile int32_t*)(c->shm + PYW_CTRL_CANCEL), 1, __ATOMIC_RELEASE);
      else
        kill(c->pid, SIGUSR1);
      if (send_header(c, KOMIRA_UDF_OP_CANCEL, id, 0, 0, 0, 0, NULL, NULL, 0) != 0) return -1;
      cancel_sent = 1;
      cancel_at = mono_ns();
    }
    if (cancel_sent && mono_ns() - cancel_at > CANCEL_GRACE_NS) {
      kill(c->pid, SIGKILL);
      *killed = PYW_KILLED_CANCEL;
      die(c, "cancelled: the worker did not answer within 2 s of CANCEL and was killed");
      return -1;
    }
    if (call->deadline_ns != 0 && host->now_ns(host->host_data) > call->deadline_ns + DEADLINE_GRACE_NS) {
      kill(c->pid, SIGKILL);
      *killed = PYW_KILLED_DEADLINE;
      die(c, "UDF_DEADLINE_EXCEEDED: the worker was killed 2 s past the call's deadline");
      return -1;
    }
    if (pr <= 0 || !(p.revents & (POLLIN | POLLHUP | POLLERR))) continue;
    komira_udf_wire_header h;
    if (read_message(c, &h, rep) != 0) return -1;
    if (h.op == PYW_OP_CLOCK) {
      pyw_reply_free(rep);
      (void)host->now_ns(host->host_data);
      continue;
    }
    if (h.request_id != id || (h.op != KOMIRA_UDF_OP_OK && h.op != KOMIRA_UDF_OP_ERROR)) {
      pyw_reply_free(rep);
      die(c, "UDF_RUNTIME_FAULT: a reply that answers no request");
      return -1;
    }
    c->worker_ns += h.slot;
    return 0;
  }
}

int pyw_chan_call(struct pyw_chan* c, const uint8_t* head, size_t head_len, int64_t length,
                  const struct ArrowArray* const* cols, const int* widths, int ncols, struct ArrowArray* args,
                  const komira_udf_call* call, const komira_udf_host* host, struct pyw_reply* rep, int* killed) {
  int64_t t0 = mono_ns();
  int rc = call_once(c, head, head_len, length, cols, widths, ncols, args, call, host, rep, killed);
  c->call_ns += mono_ns() - t0;
  c->calls++;
  return rc;
}

static int call_once(struct pyw_chan* c, const uint8_t* head, size_t head_len, int64_t length,
                     const struct ArrowArray* const* cols, const int* widths, int ncols, struct ArrowArray* args,
                     const komira_udf_call* call, const komira_udf_host* host, struct pyw_reply* rep, int* killed) {
  memset(rep, 0, sizeof(*rep));
  *killed = 0;
  if (c->dead) {
    if (args->release) args->release(args);
    return -1;
  }
  size_t msg = pyw_ipc_batch_size(length, cols, widths, ncols);
  size_t total = head_len + msg;
  uint64_t id = ++c->next_id;
  uint32_t off = 0;
  int slot = (c->shm != NULL && msg != 0) ? slot_alloc(c, total, &off) : -1;
  int rc;
  if (c->shm != NULL) __atomic_store_n((volatile int32_t*)(c->shm + PYW_CTRL_CANCEL), 0, __ATOMIC_RELEASE);
  if (slot >= 0) {
    uint8_t* dst = c->shm + PYW_CTRL_BYTES + off;
    memcpy(dst, head, head_len);
    pyw_ipc_batch_write(dst + head_len, length, cols, widths, ncols);
    if (args->release) args->release(args);
    if (c->heap_full) {
      c->heap_full = 0;
      if (host->log) host->log(host->host_data, 3, "komira-test/python-worker: engine-to-worker heap has room again");
    }
    c->slot_sends++;
    rc = send_header(c, KOMIRA_UDF_OP_CALL_BATCH, id, 0, (uint32_t)slot, off, total, NULL, NULL, 0);
  } else {
    uint8_t* buf = msg ? aligned_alloc(PYW_ALIGN, (total + PYW_ALIGN - 1) & ~(size_t)(PYW_ALIGN - 1)) : NULL;
    if (buf == NULL) {
      if (args->release) args->release(args);
      die(c, "UDF_RUNTIME_FAULT: out of memory serializing a batch");
      return -1;
    }
    memcpy(buf, head, head_len);
    pyw_ipc_batch_write(buf + head_len, length, cols, widths, ncols);
    if (args->release) args->release(args);
    if (c->shm != NULL && !c->heap_full) {
      c->heap_full = 1;
      c->heap_full_events++;
      if (host->log)
        host->log(host->host_data, 2, "komira-test/python-worker: engine-to-worker heap full: batches go inline");
    }
    c->inline_sends++;
    rc = send_header(c, KOMIRA_UDF_OP_CALL_BATCH, id, KOMIRA_UDF_WIRE_INLINE, 0, 0, total, buf, NULL, 0);
    free(buf);
  }
  if (rc != 0) return -1;
  int64_t sent = mono_ns();
  rc = await_reply(c, id, call, host, rep, killed);
  c->wait_ns += mono_ns() - sent;
  return rc;
}

/* ---- closing ------------------------------------------------------------- */

void pyw_chan_close(struct pyw_chan* c) {
  if (c->fd >= 0) {
    if (!c->dead) send_header(c, KOMIRA_UDF_OP_SHUTDOWN, ++c->next_id, 0, 0, 0, 0, NULL, NULL, 0);
    close(c->fd);
    c->fd = -1;
  }
  if (c->shm != NULL) munmap(c->shm, PYW_SHM_BYTES);
  c->shm = NULL;
  if (c->memfd >= 0) close(c->memfd);
  c->memfd = -1;
  if (c->pid <= 0) return;
  int64_t end = mono_ns() + (int64_t)REAP_WAIT_MS * 1000000LL;
  for (;;) {
    int gone;
    if (c->our_child) {
      int st;
      gone = waitpid(c->pid, &st, WNOHANG) == c->pid;
    } else {
      gone = kill(c->pid, 0) != 0 && errno == ESRCH;
    }
    if (gone) break;
    if (mono_ns() > end) {
      kill(c->pid, SIGKILL);
      if (c->our_child) waitpid(c->pid, NULL, 0);
      break;
    }
    usleep(1000);
  }
  c->pid = 0;
}
