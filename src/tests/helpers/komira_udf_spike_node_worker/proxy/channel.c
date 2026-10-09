/*
 * channel.c: one worker process and its control channel (design section
 * 5.2), engine side. Test-only spike code.
 *
 * A worker is started with posix_spawn (never fork: the engine is
 * multi-threaded) and gets two descriptors: fd 3, its end of a Unix socket
 * pair (the control channel), and fd 4, a shared memory file whose first
 * 8 bytes are the cancel word (kudfw.h). Every descriptor the proxy opens is
 * close-on-exec, so a worker started by one engine thread never inherits
 * another worker's channel, and a worker's end of file is its own.
 *
 * kudfw_request sends one message and waits for the reply in 1 ms poll
 * ticks. Each tick reads the host's clock (the deadline is against it) and
 * the call's cancel flag; a flag seen set is written to the cancel word; a
 * worker that has not answered KUDFW_GRACE_MS after a cancel or a passed
 * deadline is killed (section 4.7: hard limits only in workers). End of
 * file, a reset, or a reply that breaks the framing marks the worker lost:
 * ERR_INSTANCE_LOST, with the exit status or signal in the message.
 *
 * Writes use MSG_NOSIGNAL: a worker that died must be an error here, never a
 * SIGPIPE in the engine.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "kudfw.h"

#define MAX_PAYLOAD ((uint64_t)1 << 31)

int64_t kudfw_mono_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

static void free_error(komira_udf_error* e) {
  free((void*)e->message);
  free((void*)e->user_trace);
  e->message = NULL;
  e->user_trace = NULL;
  e->release = NULL;
}

static void set_error(komira_udf_error* e, int32_t code, int64_t row, int64_t group, char* msg, char* trace) {
  if (e == NULL) {
    free(msg);
    free(trace);
    return;
  }
  e->code = code;
  e->message = msg;
  e->user_trace = trace;
  e->row = row;
  e->group = group;
  e->release = free_error;
}

int32_t kudfw_fail(komira_udf_error* e, int32_t code, int64_t row, const char* fmt, ...) {
  char buf[512];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  set_error(e, code, row, -1, strdup(buf), NULL);
  return code;
}

void kudfw_log(const komira_udf_host* host, int32_t level, const char* fmt, ...) {
  if (host == NULL || host->log == NULL) return;
  char buf[1024];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  host->log(host->host_data, level, buf);
}

/* A close-on-exec descriptor numbered above 4, so dup2 to 3 or 4 in the
 * child always clears close-on-exec on the copy. */
static int high_fd(int fd) {
  if (fd > 4) return fd;
  int h = fcntl(fd, F_DUPFD_CLOEXEC, 10);
  close(fd);
  return h;
}

static void mark_lost(kudfw_worker* w, const char* why) {
  if (!w->lost) {
    w->lost = 1;
    snprintf(w->lost_why, sizeof(w->lost_why), "%s", why);
  }
}

/* Reap the worker, killing it after `wait_ms`; describe how it ended. */
static void reap(kudfw_worker* w, int wait_ms, char* how, size_t how_len) {
  if (w->pid <= 0) {
    snprintf(how, how_len, "the worker was already reaped");
    return;
  }
  int st = 0;
  pid_t got = 0;
  for (int i = 0; i <= wait_ms; i++) {
    got = waitpid(w->pid, &st, WNOHANG);
    if (got != 0) break;
    struct timespec ts = {0, 1000000};
    nanosleep(&ts, NULL);
  }
  if (got == 0) {
    kill(w->pid, SIGKILL);
    got = waitpid(w->pid, &st, 0);
  }
  if (got == w->pid && WIFEXITED(st))
    snprintf(how, how_len, "the worker (pid %d) exited with status %d", (int)w->pid, WEXITSTATUS(st));
  else if (got == w->pid && WIFSIGNALED(st))
    snprintf(how, how_len, "the worker (pid %d) was killed by signal %d", (int)w->pid, WTERMSIG(st));
  else
    snprintf(how, how_len, "the worker (pid %d) could not be reaped", (int)w->pid);
  w->pid = -1;
}

static int send_all(int fd, struct iovec* iov, int n) {
  while (n > 0) {
    struct msghdr m;
    memset(&m, 0, sizeof(m));
    m.msg_iov = iov;
    m.msg_iovlen = (size_t)n;
    ssize_t k = sendmsg(fd, &m, MSG_NOSIGNAL);
    if (k < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    while (n > 0 && (size_t)k >= iov->iov_len) {
      k -= (ssize_t)iov->iov_len;
      iov++;
      n--;
    }
    if (n > 0) {
      iov->iov_base = (uint8_t*)iov->iov_base + k;
      iov->iov_len -= (size_t)k;
    }
  }
  return 0;
}

/* 0, or -1 at end of file or on an error. */
static int recv_all(int fd, void* dst, size_t n) {
  uint8_t* p = (uint8_t*)dst;
  while (n > 0) {
    ssize_t k = recv(fd, p, n, 0);
    if (k == 0) return -1;
    if (k < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    p += k;
    n -= (size_t)k;
  }
  return 0;
}

static int32_t lost_error(kudfw_worker* w, komira_udf_error* err) {
  return kudfw_fail(err, KOMIRA_UDF_ERR_INSTANCE_LOST, -1, "komira udf worker lost: %s", w->lost_why);
}

int32_t kudfw_request(kudfw_worker* w, const komira_udf_host* host, uint32_t op, uint32_t flags,
                      uint64_t handle, const komira_udf_call* call, uint32_t n_groups, uint32_t emit_first_n,
                      const uint8_t* body, size_t body_len, kudfw_reply* reply, komira_udf_error* err) {
  memset(reply, 0, sizeof(*reply));
  if (w->lost) return lost_error(w, err);
  int64_t remaining = 0;
  if (call != NULL && call->deadline_ns != 0) {
    remaining = call->deadline_ns - host->now_ns(host->host_data);
    if (remaining <= 0) return kudfw_fail(err, KOMIRA_UDF_ERR_DEADLINE, -1, "the call's deadline passed before it was sent");
  }
  uint64_t id = ++w->next_request;
  komira_udf_wire_header h;
  memset(&h, 0, sizeof(h));
  h.magic = KOMIRA_UDF_WIRE_MAGIC;
  h.op = op;
  h.request_id = id;
  h.flags = flags | KOMIRA_UDF_WIRE_INLINE;
  h.payload_len = KUDFW_HEAD_BYTES + body_len;
  uint8_t head[KUDFW_HEAD_BYTES];
  memset(head, 0, sizeof(head));
  int64_t call_id = call != NULL ? call->call_id : 0;
  memcpy(head, &handle, 8);
  memcpy(head + 8, &remaining, 8);
  memcpy(head + 16, &call_id, 8);
  memcpy(head + 24, &n_groups, 4);
  memcpy(head + 28, &emit_first_n, 4);
  struct iovec iov[3] = {{&h, sizeof(h)}, {head, sizeof(head)}, {(void*)body, body_len}};
  if (send_all(w->sock, iov, body_len ? 3 : 2) != 0) {
    char how[160];
    reap(w, 1000, how, sizeof(how));
    mark_lost(w, how);
    return lost_error(w, err);
  }
  /* Watch the call until the reply's header is readable. */
  int cancel_sent = 0;
  int64_t kill_at = 0;
  const char* kill_why = NULL;
  for (;;) {
    struct pollfd p = {w->sock, POLLIN, 0};
    int r = poll(&p, 1, 1);
    if (r > 0) break;
    if (r < 0 && errno != EINTR) {
      mark_lost(w, "poll on the control channel failed");
      return lost_error(w, err);
    }
    if (call == NULL) continue;
    int64_t now = host->now_ns(host->host_data);
    if (!cancel_sent && call->cancel != NULL && __atomic_load_n(call->cancel, __ATOMIC_ACQUIRE) != 0) {
      if (pwrite(w->cancel_fd, &id, 8, 0) != 8) {
        mark_lost(w, "the cancel word could not be written");
        return lost_error(w, err);
      }
      cancel_sent = 1;
      if (kill_at == 0) {
        kill_at = kudfw_mono_ns() + (int64_t)KUDFW_GRACE_MS * 1000000;
        kill_why = "cancelled";
      }
    }
    if (call->deadline_ns != 0 && now > call->deadline_ns && kill_at == 0) {
      kill_at = kudfw_mono_ns() + (int64_t)KUDFW_GRACE_MS * 1000000;
      kill_why = "past its deadline";
    }
    if (kill_at != 0 && kudfw_mono_ns() >= kill_at) {
      kill(w->pid, SIGKILL);
      char how[160];
      reap(w, 0, how, sizeof(how));
      char why[200];
      snprintf(why, sizeof(why), "the call was %s and the worker did not answer within %d ms; %s", kill_why,
               KUDFW_GRACE_MS, how);
      mark_lost(w, why);
      int32_t code = cancel_sent ? KOMIRA_UDF_ERR_INSTANCE_LOST : KOMIRA_UDF_ERR_DEADLINE;
      return kudfw_fail(err, code, -1, "komira udf worker killed: %s", why);
    }
  }
  komira_udf_wire_header rh;
  if (recv_all(w->sock, &rh, sizeof(rh)) != 0) {
    char how[160];
    reap(w, 1000, how, sizeof(how));
    mark_lost(w, how);
    return lost_error(w, err);
  }
  if (rh.magic != KOMIRA_UDF_WIRE_MAGIC || rh.request_id != id ||
      (rh.op != KOMIRA_UDF_OP_OK && rh.op != KOMIRA_UDF_OP_ERROR) || (rh.flags & KOMIRA_UDF_WIRE_INLINE) == 0 ||
      rh.payload_len > MAX_PAYLOAD) {
    kill(w->pid, SIGKILL);
    char how[160];
    reap(w, 0, how, sizeof(how));
    char why[200];
    snprintf(why, sizeof(why), "a reply broke the framing (op %u, request %llu for %llu); %s", rh.op,
             (unsigned long long)rh.request_id, (unsigned long long)id, how);
    mark_lost(w, why);
    return lost_error(w, err);
  }
  uint8_t* payload = NULL;
  if (rh.payload_len > 0) {
    void* p = NULL;
    if (posix_memalign(&p, KUDFW_ALIGN, (size_t)rh.payload_len) != 0)
      return kudfw_fail(err, KOMIRA_UDF_ERR_OUT_OF_MEMORY, -1, "no memory for a %llu-byte reply",
                        (unsigned long long)rh.payload_len);
    payload = (uint8_t*)p;
    if (recv_all(w->sock, payload, (size_t)rh.payload_len) != 0) {
      free(payload);
      char how[160];
      reap(w, 1000, how, sizeof(how));
      mark_lost(w, how);
      return lost_error(w, err);
    }
  }
  reply->op = rh.op;
  reply->flags = rh.flags;
  reply->payload = payload;
  reply->len = (size_t)rh.payload_len;
  return KOMIRA_UDF_OK;
}

void kudfw_reply_free(kudfw_reply* r) {
  free(r->payload);
  r->payload = NULL;
  r->len = 0;
}

static char* take_str(const uint8_t* p, size_t len, size_t* at, int* bad) {
  uint32_t n = 0;
  if (*at + 4 > len) {
    *bad = 1;
    return NULL;
  }
  memcpy(&n, p + *at, 4);
  *at += 4;
  if ((size_t)n > len - *at) {
    *bad = 1;
    return NULL;
  }
  char* s = (char*)malloc((size_t)n + 1);
  if (s == NULL) {
    *bad = 1;
    return NULL;
  }
  memcpy(s, p + *at, n);
  s[n] = 0;
  *at += n;
  return s;
}

int32_t kudfw_reply_status(const kudfw_reply* r, komira_udf_error* err) {
  if (r->op == KOMIRA_UDF_OP_OK) return KOMIRA_UDF_OK;
  int32_t code = 0;
  int64_t row = -1, group = -1;
  if (r->len < 20) return kudfw_fail(err, KOMIRA_UDF_ERR_INTERNAL, -1, "a malformed ERROR reply (%zu bytes)", r->len);
  memcpy(&code, r->payload, 4);
  memcpy(&row, r->payload + 4, 8);
  memcpy(&group, r->payload + 12, 8);
  size_t at = 20;
  int bad = 0;
  char* msg = take_str(r->payload, r->len, &at, &bad);
  char* trace = bad ? NULL : take_str(r->payload, r->len, &at, &bad);
  if (bad) {
    free(msg);
    free(trace);
    return kudfw_fail(err, KOMIRA_UDF_ERR_INTERNAL, -1, "a malformed ERROR reply");
  }
  if (code <= 0) code = KOMIRA_UDF_ERR_INTERNAL; /* ERROR with OK, or a negative code */
  if (trace != NULL && trace[0] == 0) {
    free(trace);
    trace = NULL;
  }
  set_error(err, code, row, group, msg, trace);
  return code;
}

int32_t kudfw_spawn(const kudfw_launcher* l, const komira_udf_host* host, kudfw_worker* w,
                    komira_udf_error* err) {
  memset(w, 0, sizeof(*w));
  w->pid = -1;
  w->sock = -1;
  w->cancel_fd = -1;
  int64_t t0 = kudfw_mono_ns();
  int sv[2];
  if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sv) != 0)
    return kudfw_fail(err, KOMIRA_UDF_ERR_INTERNAL, -1, "socketpair: %s", strerror(errno));
  int mfd = memfd_create("komira-udf-cancel", MFD_CLOEXEC);
  if (mfd < 0 || ftruncate(mfd, 4096) != 0) {
    int e = errno;
    close(sv[0]);
    close(sv[1]);
    if (mfd >= 0) close(mfd);
    return kudfw_fail(err, KOMIRA_UDF_ERR_INTERNAL, -1, "memfd_create: %s", strerror(e));
  }
  int child = high_fd(sv[1]);
  mfd = high_fd(mfd);
  posix_spawn_file_actions_t fa;
  posix_spawnattr_t attr;
  posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_adddup2(&fa, child, 3);
  posix_spawn_file_actions_adddup2(&fa, mfd, 4);
  posix_spawnattr_init(&attr);
  sigset_t none, all;
  sigemptyset(&none);
  sigfillset(&all);
  posix_spawnattr_setsigmask(&attr, &none);
  posix_spawnattr_setsigdefault(&attr, &all);
  posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);
  pid_t pid = -1;
  int rc = posix_spawn(&pid, l->argv[0], &fa, &attr, (char* const*)l->argv, (char* const*)l->envp);
  posix_spawn_file_actions_destroy(&fa);
  posix_spawnattr_destroy(&attr);
  close(child);
  if (rc != 0) {
    close(sv[0]);
    close(mfd);
    return kudfw_fail(err, KOMIRA_UDF_ERR_INTERNAL, -1, "posix_spawn %s: %s", l->argv[0], strerror(rc));
  }
  w->pid = pid;
  w->sock = sv[0];
  w->cancel_fd = mfd;
  uint32_t hello[3] = {KOMIRA_UDF_WIRE_VERSION, KOMIRA_UDF_ABI_MAJOR, KOMIRA_UDF_ABI_MINOR};
  kudfw_reply r;
  int32_t st = kudfw_request(w, host, KOMIRA_UDF_OP_HELLO, 0, 0, NULL, 0, 0, (const uint8_t*)hello, sizeof(hello),
                             &r, err);
  if (st != KOMIRA_UDF_OK) {
    kudfw_stop(w);
    return st;
  }
  st = kudfw_reply_status(&r, err);
  uint32_t got[3] = {0, 0, 0};
  if (st == KOMIRA_UDF_OK && r.len == sizeof(got)) memcpy(got, r.payload, sizeof(got));
  kudfw_reply_free(&r);
  if (st == KOMIRA_UDF_OK && memcmp(got, hello, sizeof(got)) != 0)
    st = kudfw_fail(err, KOMIRA_UDF_ERR_ABI, -1, "HELLO: the worker speaks wire %u, ABI %u.%u; the engine %u, %u.%u", got[0],
                    got[1], got[2], hello[0], hello[1], hello[2]);
  if (st != KOMIRA_UDF_OK) {
    kudfw_stop(w);
    return st;
  }
  w->spawn_ns = kudfw_mono_ns() - t0;
  return KOMIRA_UDF_OK;
}

void kudfw_stop(kudfw_worker* w) {
  if (w->sock >= 0 && !w->lost) {
    kudfw_reply r;
    if (kudfw_request(w, NULL, KOMIRA_UDF_OP_SHUTDOWN, 0, 0, NULL, 0, 0, NULL, 0, &r, NULL) == KOMIRA_UDF_OK)
      kudfw_reply_free(&r);
  }
  if (w->sock >= 0) close(w->sock);
  if (w->cancel_fd >= 0) close(w->cancel_fd);
  w->sock = -1;
  w->cancel_fd = -1;
  if (w->pid > 0) {
    char how[160];
    reap(w, 2000, how, sizeof(how));
  }
  w->lost = 1;
  snprintf(w->lost_why, sizeof(w->lost_why), "the worker was stopped");
}
