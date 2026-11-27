/*
 * channel_probe.c: what the proxy's tests read about the channel a worker
 * is given (kudfw_channel_open, channel.c), with no worker process: the
 * probe holds the worker's end itself. Test-only; linked into the welded
 * tests of the library (test_channel, test_proxy_edges), never into a
 * runtime library.
 *
 * Each channel probe opens its own channel and closes every descriptor it
 * opened before it returns. A probe whose channel could not be opened
 * returns -1. kudfw_probe_open_fds, kudfw_probe_children and kudfw_probe_cwd
 * read the process, not a channel.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <limits.h>
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include "kudfw.h"

typedef struct chan {
  int sv[2];
  int cancel;
} chan;

static int open_chan(chan* c) {
  const char* what = NULL;
  return kudfw_channel_open(c->sv, &c->cancel, &what);
}

static void close_chan(chan* c) {
  for (int i = 0; i < 2; i++)
    if (c->sv[i] >= 0) close(c->sv[i]);
  if (c->cancel >= 0) close(c->cancel);
}

static int cloexec(int fd) {
  int f = fcntl(fd, F_GETFD);
  return f >= 0 && (f & FD_CLOEXEC) != 0;
}

/* How many of the channel's three descriptors (the two ends and the cancel
 * file) are close-on-exec. */
int64_t kudfw_probe_channel_cloexec(void) {
  chan c;
  if (open_chan(&c) != 0) return -1;
  int64_t n = cloexec(c.sv[0]) + cloexec(c.sv[1]) + cloexec(c.cancel);
  close_chan(&c);
  return n;
}

/* The cancel file's size in bytes (`which` 0) or its count of names in the
 * file system (`which` 1). */
int64_t kudfw_probe_cancel_stat(int64_t which) {
  chan c;
  if (open_chan(&c) != 0) return -1;
  struct stat st;
  int64_t v = -1;
  if (fstat(c.cancel, &st) == 0) v = which == 0 ? (int64_t)st.st_size : (int64_t)st.st_nlink;
  close_chan(&c);
  return v;
}

/* The cancel word as the worker reads it (8 bytes at offset 0 of its own
 * descriptor of the file, worker/wire.mjs) before the engine writes it
 * (`write` 0), or after the engine wrote `word` there as kudfw_request does
 * (`write` 1). The worker's descriptor is a copy, as posix_spawn's dup2
 * gives it. */
int64_t kudfw_probe_cancel_word(int64_t write, int64_t word) {
  chan c;
  if (open_chan(&c) != 0) return -1;
  int64_t got = -1;
  int worker = dup(c.cancel);
  uint64_t w = (uint64_t)word;
  if (worker >= 0 && (!write || pwrite(c.cancel, &w, 8, 0) == 8)) {
    uint64_t r = 0;
    if (pread(worker, &r, 8, 0) == 8) got = (int64_t)r;
  }
  if (worker >= 0) close(worker);
  close_chan(&c);
  return got;
}

/* One request over the channel, answered by the probe as the worker would
 * (an OK reply with no payload, written before the request is sent).
 * 0 when kudfw_request returned OK with an OK reply and the worker's end
 * read a request header with the wire's magic, the op sent, request id 1 and
 * the head plus the 4-byte body as its payload; else a positive code naming
 * the first thing that differed. */
int64_t kudfw_probe_round_trip(void) {
  chan c;
  if (open_chan(&c) != 0) return -1;
  kudfw_worker w;
  memset(&w, 0, sizeof(w));
  w.pid = -1;
  w.sock = c.sv[0];
  w.cancel_fd = c.cancel;
  komira_udf_wire_header rh;
  memset(&rh, 0, sizeof(rh));
  rh.magic = KOMIRA_UDF_WIRE_MAGIC;
  rh.op = KOMIRA_UDF_OP_OK;
  rh.request_id = 1;
  rh.flags = KOMIRA_UDF_WIRE_INLINE;
  int64_t code = 0;
  if (write(c.sv[1], &rh, sizeof(rh)) != (ssize_t)sizeof(rh)) code = 1;
  uint8_t body[4] = {1, 2, 3, 4};
  kudfw_reply r;
  komira_udf_error e;
  memset(&e, 0, sizeof(e));
  e.struct_size = sizeof(e);
  if (code == 0 && kudfw_request(&w, NULL, KOMIRA_UDF_OP_DESCRIBE, 0, 0, NULL, 0, 0, body, sizeof(body), &r, &e) !=
                       KOMIRA_UDF_OK)
    code = 2;
  if (code == 0) {
    if (r.op != KOMIRA_UDF_OP_OK || r.len != 0) code = 3;
    kudfw_reply_free(&r);
  }
  komira_udf_wire_header h;
  if (code == 0 && recv(c.sv[1], &h, sizeof(h), MSG_WAITALL) != (ssize_t)sizeof(h)) code = 4;
  if (code == 0 && h.magic != KOMIRA_UDF_WIRE_MAGIC) code = 5;
  if (code == 0 && h.op != KOMIRA_UDF_OP_DESCRIBE) code = 6;
  if (code == 0 && h.request_id != 1) code = 7;
  if (code == 0 && h.payload_len != KUDFW_HEAD_BYTES + sizeof(body)) code = 8;
  if (e.release != NULL) e.release(&e);
  close_chan(&c);
  return code;
}

/* A request after the worker's end of the channel was closed: the status
 * kudfw_request returns, the send failing as an error (never a SIGPIPE that
 * ends this process). The message is compared whole: on a status of
 * ERR_INSTANCE_LOST with any other message the probe returns 0. */
int64_t kudfw_probe_peer_closed(void) {
  chan c;
  if (open_chan(&c) != 0) return -1;
  close(c.sv[1]);
  c.sv[1] = -1;
  kudfw_worker w;
  memset(&w, 0, sizeof(w));
  w.pid = -1;
  w.sock = c.sv[0];
  w.cancel_fd = c.cancel;
  kudfw_reply r;
  komira_udf_error e;
  memset(&e, 0, sizeof(e));
  e.struct_size = sizeof(e);
  int32_t st = kudfw_request(&w, NULL, KOMIRA_UDF_OP_DESCRIBE, 0, 0, NULL, 0, 0, NULL, 0, &r, &e);
  if (st == KOMIRA_UDF_ERR_INSTANCE_LOST &&
      (e.message == NULL || strcmp(e.message, "komira udf worker lost: the worker was already reaped") != 0))
    st = 0;
  if (e.release != NULL) e.release(&e);
  close_chan(&c);
  return st;
}

/* kudfw_spawn of a program that does not exist (./komira-udf-no-such-worker,
 * relative to the test's directory): its status. */
int64_t kudfw_probe_spawn_missing(void) {
  kudfw_launcher l;
  memset(&l, 0, sizeof(l));
  l.argv[0] = "./komira-udf-no-such-worker";
  l.argv[1] = NULL;
  l.envp[0] = NULL;
  kudfw_worker w;
  komira_udf_error e;
  memset(&e, 0, sizeof(e));
  e.struct_size = sizeof(e);
  int32_t st = kudfw_spawn(&l, NULL, &w, &e);
  if (e.release != NULL) e.release(&e);
  return st;
}

/* The descriptors open in this process among 0 to 4095. */
int64_t kudfw_probe_open_fds(void) {
  int64_t n = 0;
  for (int fd = 0; fd < 4096; fd++)
    if (fcntl(fd, F_GETFD) != -1) n++;
  return n;
}

/* How many child processes this process has left: it reaps every child that
 * already ended and counts it, and counts a child still running once (a
 * running child cannot be reaped, so the count stops there). 0 means no
 * child is left, none ended unreaped and none is running (waitpid(-1)
 * failing with ECHILD); -1 when waitpid fails with anything else. It reaps
 * with waitpid(-1, WNOHANG), so a caller that wants its own children to be
 * waited for by others must not call it. */
int64_t kudfw_probe_children(void) {
  int64_t n = 0;
  for (;;) {
    int status = 0;
    pid_t r = waitpid(-1, &status, WNOHANG);
    if (r > 0) {
      n++;
      continue;
    }
    if (r == 0) return n + 1;
    if (errno == EINTR) continue;
    return errno == ECHILD ? n : -1;
  }
}

/* The absolute path of the working directory, written into buf with its
 * terminator; returns its length, or -1 when it cannot be read or does not
 * fit in cap bytes. macOS reads it from a descriptor of "." (F_GETPATH):
 * realpath(3) and getcwd(3) look up each parent directory, which the farm's
 * macOS workers refuse with EPERM. Linux asks getcwd(3). */
int64_t kudfw_probe_cwd(char* buf, int64_t cap) {
  char path[PATH_MAX];
#ifdef __APPLE__
  int fd = open(".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (fd == -1) return -1;
  int r = fcntl(fd, F_GETPATH, path);
  close(fd);
  if (r == -1) return -1;
#else
  if (getcwd(path, sizeof(path)) == NULL) return -1;
#endif
  size_t n = strlen(path);
  if (cap <= 0 || n + 1 > (size_t)cap) return -1;
  memcpy(buf, path, n + 1);
  return (int64_t)n;
}
