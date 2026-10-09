// =============================================================================
// _proc_shim.c  --  process-supervisor C shim.
// =============================================================================
//
// The C half of komira_supervisor: spawn with two capture pipes, optional
// env/cwd, waitpid decode, the non-reaping waitid child probe, and the
// per-platform exit-monitor primitives.
//
// Why a C shim (the same pattern as komira_async's reactor shim):
//   - posix_spawn() / posix_spawn_file_actions_* take POINTER-ARRAY args
//     (argv[], envp[], file_actions*, attr*) and OUT pid_t* / fd* slots --
//     an ABI-hostile shape for Mojo's external_call (struct-by-value
//     file_actions, NULL-terminated char* arrays). Encapsulating the whole
//     spawn-with-two-pipes dance behind ONE fixed-arity entry point is the
//     clean pattern the production reactor already uses for variadic-fragile
//     fcntl/openat.
//   - waitpid()'s exit-status decoding uses WIFEXITED/WEXITSTATUS/
//     WIFSIGNALED/WTERMSIG -- #defines over bit layout that differs subtly
//     across libc -- decode in C, hand Mojo typed scalars.
//   - pidfd_open(2) (Linux exit-monitor) is a raw syscall on glibc < 2.36;
//     wrap it so the Mojo side sees one stable symbol on every platform.
//
// Pointer discipline:
//   - All entry points are fixed-arity. argv/envp are passed as a flat
//     `const char *const *` NULL-terminated array marshalled by the Mojo
//     thunk; the kernel (posix_spawn) copies the strings synchronously.
//   - OUT params are caller-owned stack int slots; no heap crosses the
//     boundary; no allocations are retained.
//   - Process-resident static-linked code; no Mojo origin interaction.
//
// Design points:
//   - TWO pipes (stdout fd1, stderr fd2). A caller may stream stdout and only
//     tail-capture stderr, so they MUST be separable.
//   - env/cwd: optional envp + cwd (addchdir), both defaulted to inherit.
//   - rlimits: accepted by the Mojo API but not applied yet.
//   - The Linux pidfd_open exit monitor is fully implemented; Linux container
//     pods are the primary target.
// =============================================================================

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

// -----------------------------------------------------------------------------
// Build a NULL-terminated char*[] from a flat NUL-delimited byte blob.
//
// The Mojo side never marshals a `char**` (which would require keeping every
// inner String's heap bytes alive across the FFI call -- a stale-pointer-prone
// shape).
// Instead it hands us ONE contiguous byte blob where each entry is a
// NUL-terminated C string laid end-to-end, plus the entry count. We split it
// here into a heap `char*[count+1]` (NULL-terminated) pointing INTO the blob.
//
// Returns a malloc'd argv array (caller frees with free()) or NULL on OOM.
// `blob` must contain exactly `count` NUL-terminated strings back-to-back.
// -----------------------------------------------------------------------------
static char **_split_blob(const char *blob, int count) {
    char **vec = (char **)malloc((size_t)(count + 1) * sizeof(char *));
    if (vec == NULL) return NULL;
    const char *p = blob;
    for (int i = 0; i < count; i++) {
        vec[i] = (char *)p;
        p += strlen(p) + 1;  // advance past this entry's NUL
    }
    vec[count] = NULL;
    return vec;
}

// =============================================================================
// WHY posix_spawnp (the `p` variant) AND NOT posix_spawn.
// =============================================================================
//
// Both spawn entry points here use `posix_spawnp`, which PATH-searches a bare
// executable name. Callers rely on that: a daemon runner may default to a bare
// binary name and expect it to resolve on PATH, and a build driver may spawn a
// bare tool name such as `crane`. With the non-`p` variant every bare name
// fails with ENOENT, because posix_spawn requires a path.
//
// posix_spawnp is a strict SUPERSET of posix_spawn for every input that works
// with posix_spawn. For a `path` containing a `/` the two are identical -- no
// search is performed (POSIX; execvp(3) semantics). Only bare names behave
// differently, and with posix_spawn those always fail with ENOENT. A caller
// that wants to pin an exact binary passes an absolute path (for example
// ChildSpec.shell -> "/bin/sh"), which the `p` variant honours verbatim.
//
// PATH is read from the CALLER's environment (POSIX: "the PATH environment
// variable of the calling process"), NOT from a caller-supplied `envp` -- so
// handing the child a custom env does not redirect the search.
// =============================================================================

// -----------------------------------------------------------------------------
// komira_proc_spawn
//   Spawn `path` with argv built from `argv_blob` (`argc` NUL-terminated
//   strings back-to-back) and envp built from `env_blob` (`envc` entries) --
//   or inherit `environ` when `env_blob` is NULL / `envc <= 0`. stdout(fd1)
//   and stderr(fd2) are redirected onto the write ends of TWO SEPARATE pipes.
//
//   PATH SEARCH: see the "WHY posix_spawnp" block above. `path` containing a
//   `/` is used verbatim; a BARE NAME is resolved against the caller's
//   inherited PATH, exactly like execvp(3).
//   If `cwd` is non-NULL, the child chdir()s to it before exec (via
//   posix_spawn_file_actions_addchdir_np where available; see the cwd note).
//
//   argv_blob MUST contain argv[0] as its first entry (the Mojo marshaller
//   defaults argv[0] to `path` when the caller supplies none).
//
//   On success returns 0 and writes:
//     *out_stdout_fd  = READ end of the stdout pipe (parent drains)
//     *out_stderr_fd  = READ end of the stderr pipe (parent drains)
//     *out_pid        = child pid
//   On failure returns -errno and leaves no fds open (best-effort cleanup).
//
//   `flags` is a bitmask of the KOMIRA_SPAWN_* values below (0 = neither, the
//   behaviour every caller had before the flags existed):
//     KOMIRA_SPAWN_OWN_PGROUP     the child leads a new process group whose id
//                                 is its pid (POSIX_SPAWN_SETPGROUP, pgroup 0),
//                                 so komira_proc_kill_group(pid, sig) reaches
//                                 it and every descendant that stays in it.
//     KOMIRA_SPAWN_DEFAULT_SIGNALS every signal starts at SIG_DFL in the child
//                                 and none is blocked (POSIX_SPAWN_SETSIGDEF
//                                 over a full set, POSIX_SPAWN_SETSIGMASK with
//                                 an empty one). exec(2) resets CAUGHT signals
//                                 by itself but keeps IGNORED ones and the
//                                 mask; without this flag a child inherits,
//                                 for example, the SIGPIPE=SIG_IGN that the
//                                 TLS layer sets process-wide.
//   The two values are this file's ABI with proc_ffi.mojo (SPAWN_OWN_PGROUP,
//   SPAWN_DEFAULT_SIGNALS there), not platform constants.
//
//   Fixed arity, all scalar / pointer-to-bytes -> Mojo-FFI friendly.
// -----------------------------------------------------------------------------
#define KOMIRA_SPAWN_OWN_PGROUP 1
#define KOMIRA_SPAWN_DEFAULT_SIGNALS 2

// Fill `attr` for `flags`. Returns 0 or an errno value (posix_spawnattr_*
// return the error number, they do not set errno). On failure `attr` has been
// destroyed already.
static int _spawn_attr_for(posix_spawnattr_t *attr, int flags) {
    int rc = posix_spawnattr_init(attr);
    if (rc != 0) return rc;
    short sflags = 0;
    if (flags & KOMIRA_SPAWN_OWN_PGROUP) {
        sflags |= POSIX_SPAWN_SETPGROUP;
        rc = posix_spawnattr_setpgroup(attr, 0);  // 0: a new group, id = pid
        if (rc != 0) goto fail;
    }
    if (flags & KOMIRA_SPAWN_DEFAULT_SIGNALS) {
        sigset_t all;
        sigset_t none;
        sigfillset(&all);
        sigemptyset(&none);
        sflags |= POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK;
        rc = posix_spawnattr_setsigdefault(attr, &all);
        if (rc != 0) goto fail;
        rc = posix_spawnattr_setsigmask(attr, &none);
        if (rc != 0) goto fail;
    }
    rc = posix_spawnattr_setflags(attr, sflags);
    if (rc != 0) goto fail;
    return 0;
fail:
    posix_spawnattr_destroy(attr);
    return rc;
}

int komira_proc_spawn(const char *path,
                       const char *argv_blob, int argc,
                       const char *env_blob, int envc,
                       const char *cwd, int has_cwd,
                       int flags,
                       int *out_stdout_fd,
                       int *out_stderr_fd,
                       int *out_pid) {
    char **argv = _split_blob(argv_blob, argc);
    if (argv == NULL) return -ENOMEM;
    char **envp = NULL;
    if (env_blob != NULL && envc > 0) {
        envp = _split_blob(env_blob, envc);
        if (envp == NULL) {
            free(argv);
            return -ENOMEM;
        }
    }
    int out_pipe[2];
    int err_pipe[2];
    if (pipe(out_pipe) != 0) {
        int e = errno;
        free(argv); free(envp);
        return -e;
    }
    if (pipe(err_pipe) != 0) {
        int e = errno;
        close(out_pipe[0]);
        close(out_pipe[1]);
        free(argv); free(envp);
        return -e;
    }

    posix_spawn_file_actions_t fa;
    if (posix_spawn_file_actions_init(&fa) != 0) {
        int e = errno;
        close(out_pipe[0]); close(out_pipe[1]);
        close(err_pipe[0]); close(err_pipe[1]);
        free(argv); free(envp);
        return -e;
    }

    // cwd: posix_spawn has no portable POSIX cwd attr. The non-POSIX
    // `addchdir_np` exists on modern glibc (>= 2.29) and darwin. Guard it
    // behind a feature probe; if absent and a cwd is requested, fail loudly
    // rather than silently running in the wrong directory. Only callers that
    // set a cwd reach this path.
    if (has_cwd && cwd != NULL) {
        // POSIX standardized `posix_spawn_file_actions_addchdir` (no _np) in
        // POSIX.1-2024; macOS 26 deprecated the long-standing `_np` form in
        // its favor, while older macOS / glibc only ship the `_np` form. Pick
        // the standardized name where the platform advertises it, else the _np
        // fallback; fail loudly if neither exists. _CHDIR_RC captures
        // the call so the error handling stays single-sourced.
        int _chdir_rc;
#if defined(__APPLE__)
#  if defined(__MAC_OS_X_VERSION_MAX_ALLOWED) && (__MAC_OS_X_VERSION_MAX_ALLOWED >= 260000)
        _chdir_rc = posix_spawn_file_actions_addchdir(&fa, cwd);
#  else
        _chdir_rc = posix_spawn_file_actions_addchdir_np(&fa, cwd);
#  endif
#elif defined(__GLIBC__) && (__GLIBC__ > 2 || (__GLIBC__ == 2 && __GLIBC_MINOR__ >= 29))
        _chdir_rc = posix_spawn_file_actions_addchdir_np(&fa, cwd);
#else
        _chdir_rc = ENOSYS;  // cwd requested but addchdir unavailable
#endif
        if (_chdir_rc != 0) {
            int e = (_chdir_rc == ENOSYS) ? ENOSYS : errno;
            posix_spawn_file_actions_destroy(&fa);
            close(out_pipe[0]); close(out_pipe[1]);
            close(err_pipe[0]); close(err_pipe[1]);
            free(argv); free(envp);
            return -e;
        }
    }

    // Child fd wiring:
    //   fd 1 (stdout) -> out_pipe write end
    //   fd 2 (stderr) -> err_pipe write end
    //   close all four inherited pipe ends in the child after the dup2s, so
    //   the child holds NEITHER read end open (else the parent's read() never
    //   sees EOF after the child exits) and the write ends survive only as
    //   the dup'd fd1/fd2.
    posix_spawn_file_actions_adddup2(&fa, out_pipe[1], 1);
    posix_spawn_file_actions_adddup2(&fa, err_pipe[1], 2);
    posix_spawn_file_actions_addclose(&fa, out_pipe[0]);
    posix_spawn_file_actions_addclose(&fa, out_pipe[1]);
    posix_spawn_file_actions_addclose(&fa, err_pipe[0]);
    posix_spawn_file_actions_addclose(&fa, err_pipe[1]);

    // argv is required (argv[0] defaulted to `path` by the Mojo marshaller).
    char *const *argv_c = (char *const *)argv;
    char *const *envp_c = (envp != NULL) ? (char *const *)envp : environ;

    posix_spawnattr_t attr;
    posix_spawnattr_t *attrp = NULL;
    if (flags != 0) {
        int arc = _spawn_attr_for(&attr, flags);
        if (arc != 0) {
            posix_spawn_file_actions_destroy(&fa);
            close(out_pipe[0]); close(out_pipe[1]);
            close(err_pipe[0]); close(err_pipe[1]);
            free(argv); free(envp);
            return -arc;
        }
        attrp = &attr;
    }

    pid_t pid = 0;
    // posix_spawnp, NOT posix_spawn -- see the "WHY posix_spawnp" block above.
    int rc = posix_spawnp(&pid, path, &fa, attrp, argv_c, envp_c);
    posix_spawn_file_actions_destroy(&fa);
    if (attrp != NULL) posix_spawnattr_destroy(attrp);

    // posix_spawn copies argv/envp string bytes into the child synchronously
    // before returning, so the split vectors (which only point INTO the
    // caller-owned blobs) are safe to free now on every path.
    free(argv);
    free(envp);

    // Parent never writes to either pipe; close BOTH write ends so the only
    // remaining writer per pipe is the child's dup'd fd. Classic deadlock
    // avoidance: a lingering parent-held write end would keep read() blocked
    // forever after the child exits.
    close(out_pipe[1]);
    close(err_pipe[1]);

    if (rc != 0) {
        close(out_pipe[0]);
        close(err_pipe[0]);
        return -rc;  // posix_spawn returns the errno value directly
    }

    *out_stdout_fd = out_pipe[0];
    *out_stderr_fd = err_pipe[0];
    *out_pid = (int)pid;
    return 0;
}

// -----------------------------------------------------------------------------
// komira_proc_spawn_detached
//   Spawn `path` with argv from `argv_blob` (`argc` NUL-terminated strings) and
//   envp from `env_blob` (`envc` entries) -- or inherit `environ` when env_blob
//   is NULL / envc <= 0. UNLIKE komira_proc_spawn this does NOT create pipes or
//   redirect stdout/stderr: the child INHERITS the parent's fd 0/1/2. Intended
//   for a long-lived DETACHED child (for example a node agent started by a
//   local pod manager) whose stdout/stderr we do not capture -- such a child
//   ships its own logs.
//
//   On success returns 0 and writes *out_pid = child pid.
//   On failure returns -errno and writes no pid.
//
//   Fixed arity, all scalar / pointer-to-bytes -> Mojo-FFI friendly. The kernel
//   (posix_spawn) copies argv/envp string bytes synchronously before returning,
//   so the split vectors (which only point INTO the caller-owned blobs) are
//   freed on every path.
// -----------------------------------------------------------------------------
int komira_proc_spawn_detached(const char *path,
                                const char *argv_blob, int argc,
                                const char *env_blob, int envc,
                                int *out_pid) {
    char **argv = _split_blob(argv_blob, argc);
    if (argv == NULL) return -ENOMEM;
    char **envp = NULL;
    if (env_blob != NULL && envc > 0) {
        envp = _split_blob(env_blob, envc);
        if (envp == NULL) {
            free(argv);
            return -ENOMEM;
        }
    }

    char *const *argv_c = (char *const *)argv;
    char *const *envp_c = (envp != NULL) ? (char *const *)envp : environ;

    pid_t pid = 0;
    // No file_actions / no attr: the child inherits the parent's fds + signal
    // mask. The detached child sets up its own supervision.
    // posix_spawnp, NOT posix_spawn -- see the "WHY posix_spawnp" block above.
    int rc = posix_spawnp(&pid, path, NULL, NULL, argv_c, envp_c);

    free(argv);
    free(envp);

    if (rc != 0) {
        return -rc;  // posix_spawn returns the errno value directly
    }
    *out_pid = (int)pid;
    return 0;
}

// -----------------------------------------------------------------------------
// komira_proc_environ_count / komira_proc_environ_at  --  READ the CALLING
//   process's own environment, one entry at a time.
//
// ★ WHY THIS EXISTS. `komira_proc_spawn` takes envp as ALL-OR-NOTHING: envc==0
// inherits `environ` wholesale, envc>0 REPLACES it with exactly the entries
// given. There is no third arm, and there must not be one here -- posix_spawn
// itself has none, and faking "extend" inside the spawn would hide which
// environment the child actually ran with from the caller that has to reason
// about it.
//
// So the OVERLAY is composed by the CALLER, which needs to read `environ`. That
// read is the whole of these two functions. `environ` is a `char**` global, not
// a function, so Mojo's `external_call` cannot reach it at all; a shim entry
// point is the only way, and this is the file that already declares it.
//
// ⛔ NO POINTER IS RETURNED. `komira_proc_environ_at` COPIES into a
// caller-owned buffer, because an `environ` entry's storage is libc-owned and
// may be freed or moved by any `setenv`/`putenv` -- exactly the dangling shape
// `drain_pipe`'s use-after-free note describes one seam over.
//
// PROTOCOL for `_at`:
//     idx out of range           -> -1
//     entry needs more than cap  -> -(len + 1), i.e. the required capacity,
//                                   NEGATED. The caller resizes and retries.
//     otherwise                  -> len (bytes written, NUL-terminated)
// A required capacity is always <= -2, so it can never be confused with the
// out-of-range -1: an entry needing capacity 1 is the empty string, and that
// takes the success arm (len 0) whenever cap >= 1.
// -----------------------------------------------------------------------------
int komira_proc_environ_count(void) {
    if (environ == NULL) return 0;
    int n = 0;
    while (environ[n] != NULL) n++;
    return n;
}

long komira_proc_environ_at(int idx, char *buf, long cap) {
    if (environ == NULL || idx < 0) return -1;
    int n = 0;
    while (environ[n] != NULL) n++;
    if (idx >= n) return -1;
    const char *e = environ[idx];
    size_t len = strlen(e);
    if (cap <= 0 || (size_t)cap < len + 1) return -(long)(len + 1);
    memcpy(buf, e, len + 1);
    return (long)len;
}

// -----------------------------------------------------------------------------
// komira_proc_read  --  thin read() wrapper (typed-scalar boundary).
//   Returns bytes read (>=0), 0 on EOF, or -errno (<0) on error. EINTR is
//   retried internally. EAGAIN/EWOULDBLOCK (non-blocking fd, no data) is
//   surfaced as -EAGAIN so the reactor-driven caller can re-await readiness.
// -----------------------------------------------------------------------------
long komira_proc_read(int fd, uint8_t *buf, long cap) {
    for (;;) {
        ssize_t n = read(fd, buf, (size_t)cap);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -errno;
        }
        return (long)n;
    }
}

// -----------------------------------------------------------------------------
// komira_proc_set_nonblocking  --  set O_NONBLOCK on `fd` (F_GETFL|F_SETFL).
//   Returns 0 on success or -errno on failure. Used by a caller's run loop to
//   make the capture-pipe READ ends non-blocking so an incremental drain read
//   never blocks the loop (EWOULDBLOCK is surfaced as "nothing now" rather
//   than parking the thread). Idempotent.
// -----------------------------------------------------------------------------
int komira_proc_set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) return -errno;
    if (flags & O_NONBLOCK) return 0;  // already non-blocking
    if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) return -errno;
    return 0;
}

// -----------------------------------------------------------------------------
// komira_proc_read_avail  --  ONE non-blocking read for the incremental drain.
//   Reads whatever bytes are ready RIGHT NOW (a single read(); does NOT loop to
//   EOF). The fd is expected to be O_NONBLOCK (via komira_proc_set_nonblocking)
//   so read() returns EAGAIN/EWOULDBLOCK when the pipe is momentarily empty but
//   the child is still alive (writers still open).
//   Returns:
//      > 0  -> that many bytes were written into `buf` (more may be ready).
//        0  -> EOF: all writers closed (the child has closed its stdout/stderr
//              -- i.e. it has exited or dup'd the fd shut). No more data ever.
//       -1  -> EWOULDBLOCK / EAGAIN: nothing ready now, but the child is still
//              running (writers still open). The caller should poll again later.
//       -2  -> a genuine read error (other errno). Treat as "drain done".
//   EINTR is retried internally. This is the kernel primitive a caller's loop
//   calls each iteration to keep the pipe from filling (the deadlock fix).
// -----------------------------------------------------------------------------
long komira_proc_read_avail(int fd, uint8_t *buf, long cap) {
    for (;;) {
        ssize_t n = read(fd, buf, (size_t)cap);
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) return -1;
            return -2;  // genuine error
        }
        return (long)n;  // n>0 bytes, or 0 == EOF
    }
}

// There is no close wrapper here: proc_ffi.proc_close is a bare libc `close`
// external_call (no errno/EINTR/macro logic, and `["close", Int32]` is an
// already-shared, conflict-free link signature). The wrappers below are in C
// deliberately — each carries EINTR retries, -errno returns, EAGAIN/EWOULDBLOCK
// classification, fcntl's broken-on-Apple-ARM64 varargs ABI, or waitpid's WIF*
// macro decode (see proc_ffi.mojo for the per-wrapper rationale).

// -----------------------------------------------------------------------------
// komira_proc_kill  --  send `sig` to `pid`. Returns 0 / -errno.
// -----------------------------------------------------------------------------
int komira_proc_kill(int pid, int sig) {
    if (kill((pid_t)pid, sig) != 0) return -errno;
    return 0;
}

// -----------------------------------------------------------------------------
// komira_proc_kill_group  --  send `sig` to the process group `pgid`
//   (kill(-pgid, sig)). Returns 0 / -errno.
//
//   REFUSES pgid <= 1 with -EINVAL and sends nothing: kill(-1, sig) signals
//   every process this one may signal, and kill(0, sig) signals the CALLER's
//   own group. Neither is ever "the job's group", and a pid of 0 or 1 here is
//   a caller bug (an unset pid, or PID 1 itself).
// -----------------------------------------------------------------------------
int komira_proc_kill_group(int pgid, int sig) {
    if (pgid <= 1) return -EINVAL;
    if (kill(-(pid_t)pgid, sig) != 0) return -errno;
    return 0;
}

// -----------------------------------------------------------------------------
// The stop-signal latch: SIGTERM and SIGINT, as a platform sends them to a
// container's PID 1 to stop it.
//
// The handler does one async-signal-safe thing: it records the signal number
// in a lock-free atomic int, if none is recorded yet (the first stop signal wins).
// The run loop takes it with komira_proc_take_stop_signal, which reads and
// clears it in one atomic exchange, so a signal that lands between a read and
// a clear cannot be lost. No pointer crosses; the latch is a TU-internal
// process-wide scalar.
//
// Installing a handler is what makes these signals reach PID 1 at all: the
// kernel drops a signal sent to a namespace's init whose disposition is
// SIG_DFL. A caught signal is reset to SIG_DFL in a child by execve(2), so
// the job never inherits the handler.
//
// No SA_RESTART: a blocking usleep/poll in the run loop returns early on the
// signal, so the loop sees it within one pass instead of after its sleep.
// The loop's syscalls retry EINTR themselves (the reap and read wrappers here
// do).
// -----------------------------------------------------------------------------
// Touched only through __atomic builtins, which are lock-free on an int on
// every target this builds for, and so async-signal-safe.
static int _stop_signal = 0;

static void _stop_signal_handler(int signo) {
    int none = 0;
    (void)__atomic_compare_exchange_n(&_stop_signal, &none, signo, 0,
                                      __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
}

// Install the latch handler for SIGTERM and SIGINT. Idempotent. Returns 0, or
// -errno of the first sigaction that failed.
int komira_proc_install_stop_handler(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = _stop_signal_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    if (sigaction(SIGTERM, &sa, NULL) != 0) return -errno;
    if (sigaction(SIGINT, &sa, NULL) != 0) return -errno;
    return 0;
}

// The recorded stop signal (SIGTERM or SIGINT), cleared by the read; 0 when
// none arrived since the last take.
int komira_proc_take_stop_signal(void) {
    return __atomic_exchange_n(&_stop_signal, 0, __ATOMIC_SEQ_CST);
}

// -----------------------------------------------------------------------------
// komira_proc_adopt_orphans  --  make this process the reaper of its orphaned
//   descendants.
//
//   A process orphaned by its parent's exit is re-parented to the nearest
//   ancestor that is a "child subreaper", else to its namespace's init. So:
//     PID 1                       -> nothing to set; orphans come here already.
//                                    Returns 1.
//     Linux, not PID 1            -> prctl(PR_SET_CHILD_SUBREAPER, 1).
//                                    Returns 0, or -errno.
//     no subreaper on this OS     -> -ENOSYS (orphans go to init, which reaps
//                                    them; this process just does not see them).
//   Either way a re-parented orphan becomes a zombie of THIS process when it
//   exits, and komira_proc_reap_orphans collects it.
// -----------------------------------------------------------------------------
#if defined(__linux__)
#include <sys/prctl.h>
#endif

int komira_proc_adopt_orphans(void) {
    if (getpid() == 1) return 1;
#if defined(__linux__) && defined(PR_SET_CHILD_SUBREAPER)
    if (prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) != 0) return -errno;
    return 0;
#else
    return -ENOSYS;
#endif
}

// -----------------------------------------------------------------------------
// komira_proc_reap_orphans  --  collect every EXITED child of this process
//   except `keep_pid`, without blocking. Returns how many were collected
//   (>= 0), or -errno on a waitid failure other than ECHILD.
//
//   `keep_pid` is the job's own child: its status belongs to the Supervisor
//   that spawned it (Supervisor.wait_exit / try_wait waitpid it by pid), so
//   it is never collected here. waitid(WNOWAIT) names one exited child
//   without collecting it; anything but `keep_pid` is then collected by pid.
//   When waitid names `keep_pid` the pass stops (waitid cannot be asked for
//   "the next one"); the zombies behind it are collected on a later pass,
//   once the Supervisor has reaped its child.
//
//   At most `max` are collected per call, so a fork storm cannot hold the
//   caller's loop here.
//
//   ONLY a process that owns every child it has may call this: in a process
//   running several Supervisors it would collect a sibling Supervisor's
//   child and that Supervisor's waitpid would then fail with ECHILD.
// -----------------------------------------------------------------------------
int komira_proc_reap_orphans(int keep_pid, int max) {
    int n = 0;
    while (n < max) {
        siginfo_t info;
        int r;
        for (;;) {
            memset(&info, 0, sizeof(info));
            r = waitid(P_ALL, 0, &info, WEXITED | WNOHANG | WNOWAIT);
            if (r < 0 && errno == EINTR) continue;
            break;
        }
        if (r < 0) {
            if (errno == ECHILD) break;
            return -errno;
        }
        pid_t pid = info.si_pid;
        if (pid == 0 || pid == (pid_t)keep_pid) break;
        int status = 0;
        pid_t w;
        for (;;) {
            w = waitpid(pid, &status, WNOHANG);
            if (w < 0 && errno == EINTR) continue;
            break;
        }
        if (w != pid) break;
        n++;
    }
    return n;
}

// -----------------------------------------------------------------------------
// komira_proc_reap
//   waitpid with optional WNOHANG. Decodes the status into the OUT slots so
//   Mojo never touches the WIF* bit-layout macros:
//     *out_exited   = 1 if the child exited normally, else 0
//     *out_exitcode = WEXITSTATUS (0..255) when exited normally, else -1
//     *out_signaled = 1 if the child was killed by a signal, else 0
//     *out_signal   = WTERMSIG when signaled, else -1
//   Return value:
//      1  -> child state collected (exited or signaled); OUT slots valid.
//      0  -> WNOHANG and child still running; OUT slots untouched.
//     -1  -> error (e.g. ECHILD already reaped, EINVAL).
// -----------------------------------------------------------------------------
int komira_proc_reap(int pid, int nohang,
                      int *out_exited, int *out_exitcode,
                      int *out_signaled, int *out_signal) {
    int status = 0;
    int flags = nohang ? WNOHANG : 0;
    pid_t r;
    for (;;) {
        r = waitpid((pid_t)pid, &status, flags);
        if (r < 0 && errno == EINTR) continue;
        break;
    }
    if (r == 0) return 0;   // WNOHANG: still running
    if (r < 0) return -1;   // ECHILD / EINVAL

    if (WIFEXITED(status)) {
        *out_exited = 1;
        *out_exitcode = WEXITSTATUS(status);
        *out_signaled = 0;
        *out_signal = -1;
    } else if (WIFSIGNALED(status)) {
        *out_exited = 0;
        *out_exitcode = -1;
        *out_signaled = 1;
        *out_signal = WTERMSIG(status);
    } else {
        // Stopped/continued -- treat as "not terminal" for our supervision
        // model (we never WUNTRACED). Report as not-collected.
        return 0;
    }
    return 1;
}

// -----------------------------------------------------------------------------
// komira_proc_probe_children
//   "Does this process have any child?", asked WITHOUT reaping one:
//     waitid(P_ALL, 0, &info, WEXITED | WNOHANG | WNOWAIT)
//   WNOWAIT leaves an exited child a zombie, so whoever owns it still collects
//   its status with waitpid(pid). (waitpid(-1, WNOHANG) would reap it.) The
//   constants stay here; the Mojo side sees only scalars.
//   Return value:
//   "Child" means one that reports its exit with SIGCHLD (every posix_spawn
//   child does): without __WALL, Linux waitid skips __WCLONE children.
//      1 -> at least one child exists. *out_exited_pid is the pid of a child
//           that has exited and is still unreaped (left as it was), or 0 when
//           no child has exited (all running or stopped).
//      0 -> no child at all (ECHILD).
//     -1 -> any other failure; *out_errno = errno.
//   POSIX says a WNOHANG waitid with nothing waitable zeroes si_pid; `info`
//   is zeroed first anyway so a libc that leaves it untouched still reads 0.
// -----------------------------------------------------------------------------
int komira_proc_probe_children(int *out_exited_pid, int *out_errno) {
    siginfo_t info;
    int r;
    for (;;) {
        memset(&info, 0, sizeof(info));
        r = waitid(P_ALL, 0, &info, WEXITED | WNOHANG | WNOWAIT);
        if (r < 0 && errno == EINTR) continue;
        break;
    }
    if (r < 0) {
        if (errno == ECHILD) return 0;
        *out_errno = errno;
        return -1;
    }
    *out_exited_pid = (int)info.si_pid;
    return 1;
}

// =============================================================================
// REACTOR-CLEAN EXIT MONITOR primitives (per-backend)
// =============================================================================
//
// The design folds child-exit detection into the LONG-LIVED reactor:
//   - darwin: EVFILT_PROC / NOTE_EXIT, registered via the Mojo-side
//     `_encode_kevent` thunk on the reactor's own kqueue (NOT a fresh one).
//     The darwin registration is therefore NOT in this shim -- it reuses the
//     existing kevent encode in kqueue_subsystem.mojo. We KEEP a self-contained
//     fresh-kqueue wait here ONLY as a fallback for the standalone package test
//     that does not stand up a full reactor (the test asserts the kernel posts
//     NOTE_EXIT; the production path uses register_proc_exit on the reactor kq).
//   - linux: pidfd_open(pid, 0) returns an fd that becomes EPOLLIN-readable
//     when the child exits. It is registered identically to a socket fd via
//     the existing epoll_ctl_add. The shim only needs to surface pidfd_open.
// -----------------------------------------------------------------------------

#if defined(__linux__)
#include <sys/syscall.h>

// pidfd_open(2). glibc gained a wrapper in 2.36; for portability across the
// kernels and libcs we issue the raw syscall. Returns the pidfd (>= 0) or -errno.
// The returned fd becomes readable (EPOLLIN) when the target process exits;
// it binds to the EXACT process (immune to pid reuse). Kernel >= 5.3 for the
// syscall, >= 5.4 for pollability.
int komira_proc_pidfd_open(int pid) {
#ifdef SYS_pidfd_open
    long fd = syscall(SYS_pidfd_open, (pid_t)pid, 0u);
    if (fd < 0) return -errno;
    return (int)fd;
#else
    (void)pid;
    return -ENOSYS;
#endif
}

// Self-contained Linux exit wait used ONLY by the standalone package test's
// scenario (f) when no reactor epoll is stood up: poll() the pidfd for
// POLLIN up to timeout_ms. Returns 1 (exit observed), 0 (timeout), -1 (error).
// Production code does NOT call this -- it registers the pidfd with the
// reactor's epoll via epoll_ctl_add and awaits the completion.
#include <poll.h>
int komira_proc_pidfd_wait(int pidfd, int timeout_ms) {
    struct pollfd pfd;
    pfd.fd = pidfd;
    pfd.events = POLLIN;
    pfd.revents = 0;
    for (;;) {
        int n = poll(&pfd, 1, timeout_ms);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return 0;  // timeout
        return 1;              // readable -> child exited
    }
}

// darwin-only symbol stubbed on Linux so the symbol set resolves uniformly.
int komira_proc_kqueue_exit_wait(int pid, int timeout_ms) {
    (void)pid; (void)timeout_ms;
    return -2;  // not the Linux path; use pidfd_open + epoll
}

#else  /* !__linux__  (darwin / other BSD) */

// pidfd_open does not exist off Linux. Stubbed so the symbol resolves.
int komira_proc_pidfd_open(int pid) {
    (void)pid;
    return -2;  // darwin uses EVFILT_PROC, not pidfd
}

int komira_proc_pidfd_wait(int pidfd, int timeout_ms) {
    (void)pidfd; (void)timeout_ms;
    return -2;
}

#if defined(__APPLE__)
#include <sys/event.h>
#include <sys/time.h>

// Self-contained darwin exit wait used ONLY by the standalone package test's
// scenario (f) when no reactor kqueue is stood up: register EVFILT_PROC /
// NOTE_EXIT on a FRESH kqueue and block up to timeout_ms for the child-exit
// event. Returns 1 (NOTE_EXIT fired), 0 (timeout), -1 (error).
//
// Production code does NOT call this -- it registers EVFILT_PROC on the
// LONG-LIVED reactor kqueue via kqueue_subsystem.kevent_register_proc_exit
// and awaits the completion. This fresh-kqueue
// form mirrors the kernel contract the reactor path relies on, so the package
// test can prove "child exit is a normal kernel event, no SIGCHLD handler"
// without spinning up a full reactor in-process.
int komira_proc_kqueue_exit_wait(int pid, int timeout_ms) {
    int kq = kqueue();
    if (kq < 0) return -1;

    struct kevent change;
    EV_SET(&change, (uintptr_t)pid, EVFILT_PROC, EV_ADD | EV_ONESHOT,
           NOTE_EXIT, 0, NULL);

    struct kevent evlist[1];
    struct timespec ts;
    ts.tv_sec = timeout_ms / 1000;
    ts.tv_nsec = (long)(timeout_ms % 1000) * 1000000L;

    int n = kevent(kq, &change, 1, evlist, 1, &ts);
    close(kq);
    if (n < 0) return -1;
    if (n == 0) return 0;  // timeout
    return 1;              // any EVFILT_PROC event on this pid => state change
}
#else
int komira_proc_kqueue_exit_wait(int pid, int timeout_ms) {
    (void)pid; (void)timeout_ms;
    return -2;
}
#endif  /* __APPLE__ */

#endif  /* __linux__ */
