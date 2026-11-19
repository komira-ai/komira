// =============================================================================
// _proc_io_shim.c  --  the supervisor's pipe I/O: a write that never raises
// SIGPIPE, and a poll-based readiness wait. Both are fixed-arity, scalar and
// buffer-pointer entry points called from proc_ffi.mojo; nothing is retained
// after a call returns.
// =============================================================================

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <unistd.h>

// -----------------------------------------------------------------------------
// komira_proc_write  --  write() all of `len` bytes (EINTR retried, a short
//   write continued). Returns `len`, or -errno. It blocks while the pipe is
//   full. On an error after some bytes went out (-EPIPE: the reader closed
//   or died mid-write) the count already written is not reported.
//   A write to a pipe whose reader has gone returns -EPIPE and does not raise
//   SIGPIPE in the process: the signal is blocked for the calling thread
//   during the call, and a SIGPIPE this call raised is consumed before the
//   mask is restored (best effort: one raised for another thread's write in
//   the same window is indistinguishable and may be consumed too; one that
//   was already pending is left alone). If the signal cannot be blocked
//   nothing is written and the error is returned.
// -----------------------------------------------------------------------------
long komira_proc_write(int fd, const uint8_t *buf, long len) {
    sigset_t pipe_set, old_set, pending;
    sigemptyset(&pipe_set);
    sigaddset(&pipe_set, SIGPIPE);
    int rc = pthread_sigmask(SIG_BLOCK, &pipe_set, &old_set);
    if (rc != 0) return -rc;
    int was_pending = 0;
    if (sigpending(&pending) == 0) was_pending = sigismember(&pending, SIGPIPE);
    long done = 0;
    long result = 0;
    while (done < len) {
        ssize_t n = write(fd, buf + done, (size_t)(len - done));
        if (n < 0) {
            if (errno == EINTR) continue;
            result = -errno;
            break;
        }
        done += (long)n;
    }
    if (result == 0) result = done;
    if (result == -EPIPE && !was_pending && sigpending(&pending) == 0 &&
        sigismember(&pending, SIGPIPE)) {
        int sig = 0;
        sigwait(&pipe_set, &sig);
    }
    pthread_sigmask(SIG_SETMASK, &old_set, NULL);
    return result;
}

// -----------------------------------------------------------------------------
// komira_proc_wait_readable  --  wait up to `timeout_ms` (negative: without
//   limit) until `fd` has data to read, a hang-up (end of file) or an error.
//   Returns 1 when a read would not block, 0 on timeout, -errno on failure.
// -----------------------------------------------------------------------------
int komira_proc_wait_readable(int fd, int timeout_ms) {
    struct pollfd p;
    p.fd = fd;
    p.events = POLLIN;
    p.revents = 0;
    for (;;) {
        int r = poll(&p, 1, timeout_ms);
        if (r < 0) {
            if (errno == EINTR) continue;
            return -errno;
        }
        return r > 0 ? 1 : 0;
    }
}
