// =============================================================================
// _posix_shim.c -- non-variadic C shims for variadic-fragile libc calls.
// =============================================================================
//
// Why this file exists
// --------------------
// Mojo's `external_call["fcntl", Int32](fd, cmd, arg)` passes all three
// arguments in registers under the standard ARM64 calling convention. On
// Apple platforms (darwin-arm64), Apple diverges from the standard ARM64 ABI
// for variadic functions: variadic arguments must be passed on the STACK, not
// in registers (Apple ARM64 Calling Convention, "Arguments and parameters"
// section).
//
// The C declaration is `int fcntl(int fildes, int cmd, ...)` -- variadic
// from the third argument onward. Mojo's FFI machinery treats every arg
// as fixed and passes them in x0/x1/x2; the kernel's libsystem fcntl
// stub, expecting the third arg on the stack, reads garbage:
// `fcntl(fd, F_SETFL, flags | O_NONBLOCK)` returns rc=0 (success) but the
// kernel reads a stale stack slot and sets a different flag bit. Result:
// O_NONBLOCK is never actually set, a listener fd is born blocking, and an
// HTTP server hangs after the first accepted connection.
//
// The shim functions below are non-variadic at the C level, so Mojo's
// external_call machinery passes their arguments correctly on every
// platform. The same file also holds the other small C helpers the runtime
// needs (signal handling, process-global serialization gates, directory
// walks and the scheduler-trace counters), because C is where platform
// constants and struct layouts are resolved correctly.
//
// Cross-platform note
// -------------------
// The Linux ABI passes variadic args in registers (System V), so Mojo's
// `external_call["fcntl", ...]` works correctly on Linux. Linux callers still
// go through this shim to keep the call site uniform; the cost is one extra
// function call. The source compiles on both Linux and Darwin; `<fcntl.h>`
// defines O_NONBLOCK and FD_CLOEXEC on both.
//
// Pointer discipline
// ------------------
// Arguments are typed POSIX scalars wherever possible. Where a pointer does
// cross (a path, an output buffer), it is passed through verbatim for the
// duration of the call and never retained.
//
// Lifetime / origin
// -----------------
// The shim is process-resident static-linked code; no Mojo origin tracking
// interaction.
// =============================================================================

// Feature-test macros — MUST precede every system header so glibc exposes the
// POSIX.1-2001 surface this shim uses (posix_fadvise + POSIX_FADV_WILLNEED for
// the spill prefetch, pread/pwrite, etc.). Without _DEFAULT_SOURCE the
// fadvise declaration is hidden under a strict-ANSI default and the
// `-Werror=implicit-function-declaration` build would fail. Harmless on macOS
// (these declarations are unconditionally visible there).
//
// macOS BSD-type surface. Setting _POSIX_C_SOURCE
// above puts the Apple SDK headers into a strict-POSIX mode that HIDES the BSD
// legacy types (u_int / u_short / u_long / u_char), the BSD macro
// SOCK_MAXADDRLEN, and rusage_info_t. The Mach/Darwin probe block below
// (#if defined(__APPLE__)) pulls in <libproc.h>, which transitively includes
// <sys/ucred.h>, <sys/attr.h>, <net/route.h>, and <sys/proc_info.h> — all of
// <sys/ucred.h>, <sys/attr.h>, <net/route.h>, and <sys/proc_info.h> — all of
// which reference exactly those hidden symbols, so a `cc -Werror` compile
// fails with "unknown type name" errors. _DARWIN_C_SOURCE is the canonical
// macOS feature-test macro that re-exposes the full BSD surface ON TOP OF the
// POSIX surface; it MUST be defined before any system header. Guarded on
// __APPLE__ so the Linux / non-Apple build is a strict no-op (glibc ignores
// the macro regardless, and here it is never even defined off-Apple).
#if defined(__APPLE__)
#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE 1
#endif
#endif
#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE 1
#endif
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#include <fcntl.h>
#include <stdint.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>    // scheduler-trace dump (fprintf/stderr)
#include <stdlib.h>   // atexit for the scheduler-trace dump; also used by the dir-walk below

// =============================================================================
// Process-global graceful-shutdown flag — SIGTERM handler for serve loops
// =============================================================================
//
// Why this exists
// ---------------
// A server built on this runtime is an infinite non-blocking serve loop. For a
// zero-downtime replacement (for example an SO_REUSEPORT blue-green swap), the
// old process is sent SIGTERM once the new one is healthy; it must STOP
// ACCEPTING new connections, let its in-flight sessions DRAIN to completion
// (drive the existing per-connection CLOSING phase machine), then exit cleanly
// — rather than being SIGKILLed at the grace deadline. Mojo has no native
// signal API, so the SIGTERM handler is installed here in the statically-linked
// posix shim (the sibling of the socket FFI).
//
// Concurrency / async-signal-safety
// ---------------------------------
// The handler does the ONE async-signal-safe thing: a store to a
// `volatile sig_atomic_t` flag (POSIX guarantees sig_atomic_t stores are atomic
// w.r.t. signal delivery). It calls NOTHING else — no malloc, no printf, no
// libc that isn't async-signal-safe. The serve loop POLLS the flag once per
// outer iteration on its own thread; the volatile read sees the handler's store.
// This is the canonical "signal sets a flag, the main loop reacts" pattern.
//
// Pointer discipline: no pointers cross the FFI boundary; the
// `&_shutdown_requested` taken by sigaction is TU-internal. Lifetime:
// process-resident static; no heap; no Mojo origin interaction (a plain
// process-global scalar, NOT a Mojo struct field). The Mojo callers
// (`komira_install_sigterm_handler` / `komira_shutdown_requested`) exchange
// only `int` scalars, so the external_call ABI is correct on Darwin + Linux.
// ---------------------------------------------------------------------------
static volatile sig_atomic_t _shutdown_requested = 0;

// The SIGTERM (and SIGINT) handler: set the flag and return. Async-signal-safe
// (a single sig_atomic_t store; no other libc calls).
static void _shutdown_signal_handler(int signo) {
    (void)signo;
    _shutdown_requested = 1;
}

// Install the graceful-shutdown handler for SIGTERM + SIGINT. Idempotent (a
// second install just re-points to the same handler). Uses sigaction (NOT
// signal()) for portable, well-defined semantics. SA_RESTART so the handler
// does not turn an in-progress blocking syscall into an EINTR error (the serve
// loops are non-blocking, but SA_RESTART is the safe default). Returns 0 on
// success, -1 if either sigaction call failed. Called ONCE at server boot.
int komira_install_sigterm_handler(void) {
    struct sigaction sa;
    sa.sa_handler = _shutdown_signal_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESTART;
    if (sigaction(SIGTERM, &sa, 0) != 0) {
        return -1;
    }
    // Also catch SIGINT (Ctrl-C / `docker stop` of a tty-attached run) so a
    // local operator gets the same graceful drain as a compose SIGTERM.
    if (sigaction(SIGINT, &sa, 0) != 0) {
        return -1;
    }
    return 0;
}

// Read the graceful-shutdown flag (0 = keep serving, 1 = drain + exit). The
// serve loop polls this once per outer iteration. Reading a volatile
// sig_atomic_t is atomic w.r.t. signal delivery (POSIX), so the loop reliably
// observes the handler's store.
int komira_shutdown_requested(void) {
    return (int)_shutdown_requested;
}

// ---------------------------------------------------------------------------
// komira_ignore_sigpipe — set SIGPIPE to SIG_IGN so a write to a peer that has
// gone away returns EPIPE instead of KILLING THE PROCESS.
//
// ★ WHY THIS IS A CORRECTNESS FIX AND NOT HARDENING. `try_send` (socket_io)
// calls send() with MSG_DONTWAIT and NOT MSG_NOSIGNAL, and nothing else in the
// process alters SIGPIPE's disposition. The default disposition is TERMINATE.
// So a socket server built on this reactor dies — whole process, every
// connection it was serving — the first time it writes to a socket whose peer
// disconnected a moment earlier.
//
// The error path for that already exists and is already documented:
// `try_io_write`'s docstring names "EPIPE on closed peer" as a return it
// produces, and a serve loop maps a hard write error to "drop that ONE
// connection and keep serving". Without this disposition that code is
// unreachable: a server that multiplexes many sessions in one process would
// lose EVERY session the moment one departing peer is written to.
//
// Idempotent and process-wide by construction (signal dispositions are
// per-process). Returns 0 on success, -1 if the sigaction install failed.
int komira_ignore_sigpipe(void) {
    struct sigaction sa;
    sa.sa_handler = SIG_IGN;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    if (sigaction(SIGPIPE, &sa, 0) != 0) {
        return -1;
    }
    return 0;
}

// =============================================================================
// Process-global CAS-manifest serialization gate
// =============================================================================
//
// Why this exists
// ---------------
// The object-store CAS manifest (`komira_objectstore.cas_manifest`) can be
// driven by several bare-pthread writers in one process. Its maintenance and
// lifecycle verbs mutate shared manifest state through composite
// read-modify-write sequences; this gate serializes those composite
// operations across the WHOLE process (every store instance and clone), which
// is the correct layer: a lock inside one store conformer would leave request
// construction outside it.
//
// Implementation: a static `pthread_rwlock_t`. READ verbs take the shared
// lock, so concurrent readers proceed in parallel; WRITE (maintenance) verbs
// take the exclusive lock, which excludes all readers while one is in flight.
// rd/wr/unlock are non-variadic, so the Mojo `external_call` ABI is correct on
// Darwin + Linux.
//
// The rwlock MUST be writer-preferring — a sustained read-heavy load would
// otherwise STARVE a waiting writer (loss of liveness). On Linux this is set
// via `pthread_rwlockattr_setkind_np(PTHREAD_RWLOCK_PREFER_WRITER_NONRECURSIVE_NP)`.
// `PTHREAD_RWLOCK_INITIALIZER` CANNOT carry the kind attr, so the rwlock is
// initialized at runtime via `pthread_rwlock_init` + attr behind a
// `pthread_once` (zero init-race; Mojo has no module-level globals). macOS
// provides no `_np` kind attr — there it falls back to the
// implementation-defined default priority. Writes are rare vs reads, so on
// either platform writer-starvation is not a practical concern; the explicit
// writer-preference on Linux removes even the theoretical hazard.
//
// Pointer discipline: no pointers cross the FFI boundary; the
// `&_cas_gate` taken here is TU-internal. Lifetime: process-resident static;
// no heap; no Mojo origin interaction.
// ---------------------------------------------------------------------------
static pthread_rwlock_t _cas_gate;
static pthread_once_t _cas_gate_once = PTHREAD_ONCE_INIT;

static void _cas_gate_init(void) {
    pthread_rwlockattr_t attr;
    pthread_rwlockattr_init(&attr);
#if defined(__linux__) && defined(PTHREAD_RWLOCK_PREFER_WRITER_NONRECURSIVE_NP)
    // Writer-preferring on Linux/glibc to avoid writer starvation under
    // sustained read-heavy load. NONRECURSIVE because no thread takes the
    // gate recursively.
    pthread_rwlockattr_setkind_np(
        &attr, PTHREAD_RWLOCK_PREFER_WRITER_NONRECURSIVE_NP);
#endif
    // macOS: no `_np` kind attr — default (impl-defined) priority. Acceptable
    // for the dev target; publishes are rare so starvation is not a concern.
    pthread_rwlock_init(&_cas_gate, &attr);
    pthread_rwlockattr_destroy(&attr);
}

// Test toggle. Default 0 = gate ON (production behavior). A test that needs
// the un-gated path calls `komira_cas_gate_set_disabled(1)` ONCE in main
// before spawning. Set-once-before-threads / read-many-after means no data
// race on this plain int (happens-before via pthread_create). Production never
// calls the setter, so the gate is unconditionally taken.
static int _cas_gate_disabled = 0;

void komira_cas_gate_set_disabled(int v) {
    _cas_gate_disabled = v;
}

// Acquisition counters. They make "is the gate actually engaged on this
// path?" answerable by measurement instead of by reading prose. Plain
// non-atomic longs: they are incremented under the lock they count (so the
// values are exact), and read after the threads join.
static unsigned long _cas_gate_rd_acquires = 0;
static unsigned long _cas_gate_wr_acquires = 0;

// which: 0 = read acquisitions, 1 = write acquisitions. Any other value = 0.
unsigned long komira_cas_gate_acquires(int which) {
    if (which == 0) return _cas_gate_rd_acquires;
    if (which == 1) return _cas_gate_wr_acquires;
    return 0UL;
}

// READ verbs take the shared lock — concurrent readers proceed in parallel.
// Callers: read_head,
// read_head_fresh, read_head_authoritative, read_durable_head,
// read_dedup_sentinel, read_chunk, tombstone_seqs, tombstone_schedule_ts,
// read_log_start, read_catalog_sidecar.
// The `_cas_gate_disabled` test short-circuit is preserved on every entry
// point (production never sets it).
void komira_cas_gate_rdlock(void) {
    if (_cas_gate_disabled) return;
    pthread_once(&_cas_gate_once, _cas_gate_init);
    pthread_rwlock_rdlock(&_cas_gate);
    _cas_gate_rd_acquires++;
}

// WRITE verbs take the exclusive lock.
//
// `append` is NOT one of them: the append path runs lock-free, and the
// `If-None-Match` create-CAS is its sole correctness arbiter. The write-lock
// callers are the MAINTENANCE / lifecycle verbs: rewrite_chunk_body,
// schedule_for_delete_at, reap, purge_all, advance_log_start,
// cas_catalog_sidecar.
void komira_cas_gate_wrlock(void) {
    if (_cas_gate_disabled) return;
    pthread_once(&_cas_gate_once, _cas_gate_init);
    pthread_rwlock_wrlock(&_cas_gate);
    _cas_gate_wr_acquires++;
}

// One unlock entry point for both lock kinds (pthread_rwlock_unlock releases
// whichever — read or write — this thread holds).
void komira_cas_gate_unlock(void) {
    if (_cas_gate_disabled) return;
    pthread_rwlock_unlock(&_cas_gate);
}

// =============================================================================
// Process-global LOCAL-MODEL STATE-MACHINE serialization gate
// =============================================================================
//
// Why this exists
// ---------------
// A local-model server (`komira_localmodel`) forwards requests to an inference
// engine from N pthread workers, so N admitted requests reach the engine at
// once and its own continuous batching serves them in parallel.
//
// The N workers SHARE one BackendSupervisor state machine (the SM owns the
// model lifecycle + the per-model admission counters). The whole POINT of
// admission control is bounding the TOTAL in-flight requests against ONE shared
// loaded model -- so the SM CANNOT be per-worker (per-worker SMs would each
// spawn a duplicate engine child + each carry an independent, N-times-too-loose
// cap). One shared SM mutated by N threads is the only correct shape.
//
// The SM is plain (non-atomic) mutable state: parallel List[Int] for
// _inflight / _queued / _states, mutated by admit() / release() / request_load()
// / tick_idle_unload(). Those mutations MUST be serialized across the worker
// threads or the counters race (lost updates -> the cap leaks past N).
//
// This gate serializes the SM critical section across the WHOLE process. It is a
// plain mutual-exclusion mutex (NOT a rwlock) because every SM verb on the
// request path MUTATES (admit bumps in-flight, release decrements, request_load
// may LRU-evict + spawn) -- there is no read-only fast path worth a rwlock, and
// the critical section is short (counter arithmetic + the occasional launch()).
// The forward to the engine happens OUTSIDE this gate (the worker releases the
// gate before the blocking HTTP round-trip), so N workers forward concurrently;
// the gate only serializes the brief admit / release / load bookkeeping.
//
// pthread_mutex_t initialized at runtime behind a pthread_once (zero init-race;
// Mojo has no module-level globals). Mirrors the CAS gate above.
//
// Pointer discipline: no pointers cross the FFI boundary; the
// &_lm_sm_gate taken here is TU-internal. Lifetime: process-resident static;
// no heap; no Mojo origin interaction.
// ---------------------------------------------------------------------------
static pthread_mutex_t _lm_sm_gate;
static pthread_once_t _lm_sm_gate_once = PTHREAD_ONCE_INIT;

static void _lm_sm_gate_init(void) {
    pthread_mutex_init(&_lm_sm_gate, 0);
}

void komira_localmodel_sm_lock(void) {
    pthread_once(&_lm_sm_gate_once, _lm_sm_gate_init);
    pthread_mutex_lock(&_lm_sm_gate);
}

void komira_localmodel_sm_unlock(void) {
    pthread_mutex_unlock(&_lm_sm_gate);
}


// ---------------------------------------------------------------------------
// Read the file status flags (F_GETFL).
//
// Equivalent to `fcntl(fd, F_GETFL)` but with a fixed (non-variadic)
// signature. On error returns -1; caller should consult errno.
// ---------------------------------------------------------------------------
int komira_fcntl_get_flags(int fd) {
    return fcntl(fd, F_GETFL);
}

// ---------------------------------------------------------------------------
// Set the file status flags (F_SETFL).
//
// Equivalent to `fcntl(fd, F_SETFL, flags)` but with a fixed (non-variadic)
// signature. Caller is responsible for OR-ing in any new flag bits;
// this function passes `flags` verbatim.
// ---------------------------------------------------------------------------
int komira_fcntl_set_flags(int fd, int flags) {
    return fcntl(fd, F_SETFL, flags);
}

// ---------------------------------------------------------------------------
// Set FD_CLOEXEC (close-on-exec) on a file descriptor (F_SETFD).
//
// Used by `kqueue_subsystem.mojo`'s `kqueue_create()` to mirror tokio/mio's
// post-kqueue close-on-exec convention. Equivalent C:
// `fcntl(fd, F_SETFD, FD_CLOEXEC)`. Fixed-arity. Returns the rc from
// fcntl (0 on success, -1 on error).
// ---------------------------------------------------------------------------
int komira_fcntl_set_cloexec(int fd) {
    return fcntl(fd, F_SETFD, FD_CLOEXEC);
}

// =============================================================================
// Mach / Darwin probes for leak-detection tests.
// =============================================================================
//
// The Linux leak-detection helpers parse `/proc/self/task` (thread count),
// `/proc/self/fd` (fd count), and `getrusage().ru_maxrss` (peak RSS).
// Mach-O / Darwin has no /proc; the equivalents are:
//   - thread count: `task_threads(mach_task_self(), &thread_list, &count)`
//   - peak/current RSS: `task_info(mach_task_self(), MACH_TASK_BASIC_INFO, ...)`
//   - fd count: `proc_pidinfo(getpid(), PROC_PIDLISTFDS, ...)` in its
//     TWO-CALL form — a size query for the buffer, then a REAL FILL;
//     #fds = the SECOND call's return / sizeof(struct proc_fdinfo). The size
//     query ALONE answers the fd TABLE CAPACITY, which does not move when a
//     descriptor is opened or closed; see `komira_mac_fd_count` below.
//
// All three are exposed as fixed-arity, scalar-returning shims so the
// Mojo test code can use a single `external_call` per metric and remain
// cross-platform (Linux callers return -1 from these and route through
// the existing `/proc`-based helpers).
//
// Pointer discipline: zero pointers cross the FFI boundary.
// The functions allocate / free internal Mach resources locally; the
// returned scalars are raw POSIX integer types.
// =============================================================================

#if defined(__APPLE__)

#include <mach/mach.h>
#include <mach/mach_init.h>
#include <mach/task.h>
#include <libproc.h>
#include <unistd.h>
#include <stdlib.h>  /* malloc/free — komira_mac_fd_count's real-fill buffer */

// Returns the number of threads in the current process, or -1 on error.
// Mach-side resources (the thread_act_array and per-thread mach_port_t)
// are released before return; no caller cleanup needed.
long long komira_mac_thread_count(void) {
    thread_act_array_t thread_list;
    mach_msg_type_number_t thread_count = 0;
    kern_return_t kr = task_threads(mach_task_self(), &thread_list, &thread_count);
    if (kr != KERN_SUCCESS) {
        return -1;
    }
    long long n = (long long)thread_count;
    // Drop the per-thread send rights granted by task_threads.
    for (mach_msg_type_number_t i = 0; i < thread_count; i++) {
        mach_port_deallocate(mach_task_self(), thread_list[i]);
    }
    // Free the array itself.
    vm_deallocate(mach_task_self(),
                  (vm_address_t)thread_list,
                  thread_count * sizeof(thread_act_t));
    return n;
}

// Returns the current resident-set size in bytes, or -1 on error.
// Equivalent of /proc/self/status VmRSS (current, not peak).
long long komira_mac_resident_bytes(void) {
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t info_count = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(),
                                 MACH_TASK_BASIC_INFO,
                                 (task_info_t)&info,
                                 &info_count);
    if (kr != KERN_SUCCESS) {
        return -1;
    }
    return (long long)info.resident_size;
}

// Returns the peak resident-set size in bytes, or -1 on error.
// Equivalent of /proc/self/status VmHWM. NOTE: unlike Linux's
// getrusage().ru_maxrss (KB on Linux, bytes on Darwin), this returns
// bytes uniformly so callers don't need to special-case units.
long long komira_mac_peak_resident_bytes(void) {
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t info_count = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(),
                                 MACH_TASK_BASIC_INFO,
                                 (task_info_t)&info,
                                 &info_count);
    if (kr != KERN_SUCCESS) {
        return -1;
    }
    return (long long)info.resident_size_max;
}

// Returns the number of open file descriptors in the current process, or -1
// on error. Equivalent of `ls /proc/self/fd | wc -l` on Linux.
//
// ⛔ THE ZERO-BUFFER "SIZE QUERY" IS THE TABLE CAPACITY, NOT THE OPEN COUNT.
// `proc_pidinfo(pid, PROC_PIDLISTFDS, 0, 0, 0) / sizeof(struct proc_fdinfo)` —
// the documented size-query idiom — answers `fd_nfiles * sizeof(...)`: how many
// slots the kernel has ALLOCATED for this process's descriptor table. It does
// not move when a descriptor is opened or closed, so a leak test built on it
// subtracts one constant from another and always passes. On one process:
//
//     baseline      size_query=320   real_fill=3
//     +1 fd         size_query=320   real_fill=4
//     +3 fds        size_query=320   real_fill=6
//     after close   size_query=320   real_fill=3
//
// `real_fill` is exact to a single fd, and its baseline of 3 is
// stdin/stdout/stderr. So this uses the two-call form: size-query for the
// buffer, then a real fill, and divide the SECOND call's return — the bytes
// actually WRITTEN, i.e. only the open descriptors — rather than the first's.
long long komira_mac_fd_count(void) {
    pid_t pid = getpid();
    // (1) Size query: how many slots the table HAS. Upper bound for the buffer;
    //     NOT the answer. See above.
    int cap_bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, 0, 0);
    if (cap_bytes <= 0) {
        return -1;
    }
    struct proc_fdinfo *buf = (struct proc_fdinfo *)malloc((size_t)cap_bytes);
    if (buf == NULL) {
        return -1;
    }
    // (2) Real fill: the kernel writes one entry per OPEN descriptor and returns
    //     the bytes it wrote. That count is the answer, and it is exact to one fd.
    int used_bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buf, cap_bytes);
    free(buf);
    if (used_bytes <= 0) {
        return -1;
    }
    return (long long)(used_bytes / (int)sizeof(struct proc_fdinfo));
}

#else  /* !__APPLE__ */

// On non-Darwin platforms the Mojo callers should not invoke these.
// They are still defined so the symbol resolves identically on every
// build; returning -1 is the documented "platform unsupported" sentinel
// and is what the Mojo helpers fall back to today.
long long komira_mac_thread_count(void) { return -1; }
long long komira_mac_resident_bytes(void) { return -1; }
long long komira_mac_peak_resident_bytes(void) { return -1; }
long long komira_mac_fd_count(void) { return -1; }

#endif

// =============================================================================
// mkdir(2) shim
// =============================================================================

#include <sys/uio.h>
#include <sys/stat.h>
#include <unistd.h>

// `komira_mkdir(path, mode)`:
//   mkdir(2) renamed to sidestep the stdlib's own reserved `mkdir` FFI
//   declaration. A bare `external_call["mkdir", ...]` legalizes fine in a
//   SMALL closure, but in a LARGE binary whose transitive closure also pulls
//   in std.os's `mkdir` declaration (with a `mode_t`-typed second arg
//   differing from Mojo's Int32), the two conflicting declarations fail Mojo's
//   external-call legalization ("existing function with conflicting
//   signature"). Returns 0 on success, -1 on error (EEXIST included; a caller
//   probes directory-existence to tolerate an already-created directory).
//   mode is taken as int (fixed-arity, register-safe) and cast to mode_t
//   internally.
int komira_mkdir(const char *path, int mode) {
    return mkdir(path, (mode_t)mode);
}


// =============================================================================
// Recursive directory walk shim
// =============================================================================
//
// Encapsulates the platform-fragile `dirent` / `stat` struct layouts and the
// recursive crawl ENTIRELY in C, so the Mojo side (`LocalFs.list`) never does
// raw struct-offset arithmetic or pointer walking (no UnsafePointer arithmetic
// across module boundaries; the Mojo caller gets
// a flat NUL-separated buffer + a free()).
//
// `komira_walk_dir_recursive(root, out_buf, out_len)`:
//   Recursively walks `root`, collecting the absolute path of every REGULAR
//   FILE under it (at any depth). Writes a single heap buffer of the paths
//   joined by '\0' (one trailing '\0' per path, including the last) into
//   `*out_buf`, and the total byte length (including all separators) into
//   `*out_len`. Returns 0 on success, -1 on error.
//
//   On success with zero files found, `*out_buf` is a valid 1-byte heap
//   allocation (so the caller can always `free` it) and `*out_len` is 0.
//
//   OWNERSHIP: the caller (Mojo `LocalFs.list`) MUST `free(*out_buf)` via
//   `komira_free` after copying the paths out. The buffer is malloc'd here.
//
// SYMLINK SAFETY (matches DuckDB — do not follow symlinks into cycles):
//   We classify each entry with `lstat(2)` (NOT `stat(2)`), which does NOT
//   dereference symlinks. A symlink is neither a regular file nor a directory
//   under lstat's S_IFMT, so it is SKIPPED entirely — we never emit it as a
//   file and never recurse through it. This makes the walk acyclic by
//   construction (the only way to form a directory cycle on a POSIX fs is via
//   a symlink, and we never traverse one). No visited-inode set is needed.
//
// `d_name` is read as a NUL-terminated C string (robust — no dependence on
// the platform `d_reclen` / `d_namlen` fields or the `d_name` struct offset;
// `readdir` guarantees `d_name` is NUL-terminated on every POSIX platform).
// "." and ".." are skipped.
//
// Pointer discipline: the only pointers crossing the FFI boundary are the
// out-params (`char **out_buf`, `unsigned long *out_len`) the Mojo caller
// owns on its stack frame, plus the malloc'd buffer whose ownership transfers
// to the caller (freed via komira_free). No Mojo origin interaction; the
// recursion + struct parsing is fully TU-internal.
// =============================================================================

#include <dirent.h>
#include <stdlib.h>
#include <string.h>

// Grow a heap buffer to hold `needed` more bytes beyond `*used`. Returns 0 on
// success, -1 on allocation failure (leaving the existing buffer intact).
static int _walk_buf_ensure(char **buf, size_t *cap, size_t used,
                            size_t needed) {
    size_t want = used + needed;
    if (want <= *cap) {
        return 0;
    }
    size_t new_cap = (*cap == 0) ? 4096 : *cap;
    while (new_cap < want) {
        new_cap *= 2;
    }
    char *grown = (char *)realloc(*buf, new_cap);
    if (grown == NULL) {
        return -1;
    }
    *buf = grown;
    *cap = new_cap;
    return 0;
}

// Recursive helper. Appends NUL-terminated absolute file paths under `dir`
// into the growable (`*buf`, `*cap`, `*used`). Returns 0 on success, -1 on a
// hard error (allocation failure). A directory that cannot be opened (e.g.
// EACCES) is SKIPPED (best-effort walk), not treated as a hard error.
static int _walk_dir_into(const char *dir, char **buf, size_t *cap,
                          size_t *used) {
    DIR *dp = opendir(dir);
    if (dp == NULL) {
        // Unreadable directory: skip it rather than failing the whole walk.
        return 0;
    }
    size_t dir_len = strlen(dir);
    struct dirent *ent;
    int rc = 0;
    while ((ent = readdir(dp)) != NULL) {
        const char *name = ent->d_name;
        // Skip "." and "..".
        if (name[0] == '.' &&
            (name[1] == '\0' || (name[1] == '.' && name[2] == '\0'))) {
            continue;
        }
        // Build the child path: dir + '/' + name (collapse a trailing '/').
        size_t name_len = strlen(name);
        int need_sep = (dir_len > 0 && dir[dir_len - 1] != '/') ? 1 : 0;
        size_t child_len = dir_len + (size_t)need_sep + name_len;
        char *child = (char *)malloc(child_len + 1);
        if (child == NULL) {
            rc = -1;
            break;
        }
        memcpy(child, dir, dir_len);
        size_t off = dir_len;
        if (need_sep) {
            child[off++] = '/';
        }
        memcpy(child + off, name, name_len);
        child[off + name_len] = '\0';

        // Classify WITHOUT following symlinks (lstat). Symlinks fall through
        // both branches -> skipped (cycle-safe).
        struct stat st;
        if (lstat(child, &st) == 0) {
            if (S_ISDIR(st.st_mode)) {
                rc = _walk_dir_into(child, buf, cap, used);
                if (rc != 0) {
                    free(child);
                    break;
                }
            } else if (S_ISREG(st.st_mode)) {
                if (_walk_buf_ensure(buf, cap, *used, child_len + 1) != 0) {
                    rc = -1;
                    free(child);
                    break;
                }
                memcpy(*buf + *used, child, child_len);
                (*buf)[*used + child_len] = '\0';
                *used += child_len + 1;
            }
            // else: symlink / fifo / socket / device -> skip.
        }
        // lstat failure (race: entry removed mid-walk) -> skip.
        free(child);
    }
    closedir(dp);
    return rc;
}

int komira_walk_dir_recursive(const char *root, char **out_buf,
                               unsigned long *out_len) {
    char *buf = NULL;
    size_t cap = 0;
    size_t used = 0;
    int rc = _walk_dir_into(root, &buf, &cap, &used);
    if (rc != 0) {
        free(buf);
        *out_buf = NULL;
        *out_len = 0;
        return -1;
    }
    // Always hand back a freeable buffer, even for the zero-file case.
    if (buf == NULL) {
        buf = (char *)malloc(1);
        if (buf == NULL) {
            *out_buf = NULL;
            *out_len = 0;
            return -1;
        }
    }
    *out_buf = buf;
    *out_len = (unsigned long)used;
    return 0;
}

// =============================================================================
// `komira_list_dir_shallow(dir, out_buf, out_len)`:
//   SHALLOW one-level directory listing — the partition-schema probe
//   primitive for lazy Hive discovery. Lists the IMMEDIATE children of
//   `dir` (NOT recursive — this is the whole point: we never enumerate the
//   leaf data files). Each immediate child is emitted as a single
//   NUL-terminated record whose FIRST byte is a TYPE TAG:
//       'D' <name>'\0'   -> the child is a subdirectory
//       'F' <name>'\0'   -> the child is a regular file
//   `<name>` is the bare entry name (NOT the full path — the Mojo caller
//   joins it to `dir`). `*out_len` is the total byte length (tags + names +
//   separators). Returns 0 on success, -1 on error.
//
//   The level-by-level Mojo walk (`LocalFs.list_dir_shallow` ->
//   `_try_build_hive_partitioned_plan`) descends partition_depth levels,
//   reading ONE shallow listing per level to learn the `key=value` partition
//   column name + the distinct values at that level for the type probe, and
//   ONE representative leaf path for the data-schema footer read. The pruned
//   leaf-file enumeration is deferred to the reader that opens the pruned set.
//
//   On success with zero children, `*out_buf` is a valid 1-byte heap
//   allocation and `*out_len` is 0. OWNERSHIP: caller MUST `komira_free`.
//
//   SYMLINK SAFETY: lstat classification (no symlink deref). A symlink is
//   neither 'D' nor 'F' under S_IFMT -> SKIPPED (consistent with the
//   recursive walk's no-follow contract).
// =============================================================================
int komira_list_dir_shallow(const char *dir, char **out_buf,
                             unsigned long *out_len) {
    char *buf = NULL;
    size_t cap = 0;
    size_t used = 0;
    int rc = 0;

    DIR *dp = opendir(dir);
    if (dp != NULL) {
        size_t dir_len = strlen(dir);
        struct dirent *ent;
        while ((ent = readdir(dp)) != NULL) {
            const char *name = ent->d_name;
            // Skip "." and "..".
            if (name[0] == '.' &&
                (name[1] == '\0' ||
                 (name[1] == '.' && name[2] == '\0'))) {
                continue;
            }
            size_t name_len = strlen(name);
            // Build the full child path for the lstat classification.
            int need_sep = (dir_len > 0 && dir[dir_len - 1] != '/') ? 1 : 0;
            size_t child_len = dir_len + (size_t)need_sep + name_len;
            char *child = (char *)malloc(child_len + 1);
            if (child == NULL) {
                rc = -1;
                break;
            }
            memcpy(child, dir, dir_len);
            size_t off = dir_len;
            if (need_sep) {
                child[off++] = '/';
            }
            memcpy(child + off, name, name_len);
            child[off + name_len] = '\0';

            char tag = 0;
            struct stat st;
            if (lstat(child, &st) == 0) {
                if (S_ISDIR(st.st_mode)) {
                    tag = 'D';
                } else if (S_ISREG(st.st_mode)) {
                    tag = 'F';
                }
                // else: symlink / fifo / socket / device -> tag stays 0 (skip).
            }
            free(child);
            if (tag == 0) {
                continue;  // not a dir or regular file -> skip.
            }
            // Emit: <tag> <name> '\0'.
            size_t rec_len = 1 + name_len;
            if (_walk_buf_ensure(&buf, &cap, used, rec_len + 1) != 0) {
                rc = -1;
                break;
            }
            buf[used] = tag;
            memcpy(buf + used + 1, name, name_len);
            buf[used + rec_len] = '\0';
            used += rec_len + 1;
        }
        closedir(dp);
    }
    // (opendir failure -> treated as an empty listing, like the recursive walk.)

    if (rc != 0) {
        free(buf);
        *out_buf = NULL;
        *out_len = 0;
        return -1;
    }
    if (buf == NULL) {
        buf = (char *)malloc(1);
        if (buf == NULL) {
            *out_buf = NULL;
            *out_len = 0;
            return -1;
        }
    }
    *out_buf = buf;
    *out_len = (unsigned long)used;
    return 0;
}

// Free a buffer returned by komira_walk_dir_recursive. Renamed (not bare
// `free`) to sidestep any stdlib FFI name reservation, matching the
// the other renamed wrappers in this file. Returns 0
// (an `int` return keeps the Mojo external_call site uniform with the other
// shims; the value is ignored by the caller).
int komira_free(void *p) {
    free(p);
    return 0;
}

#include <sys/mman.h>
#include <stdatomic.h>

// =============================================================================
// RLIMIT_NOFILE soft-limit shim
// =============================================================================

#include <time.h>
#include <sys/resource.h>

// `komira_set_nofile_soft_limit(long long soft) -> long long`
//   Set RLIMIT_NOFILE's SOFT limit to `soft` and return the PREVIOUS soft
//   limit, or -1 on failure. The hard limit is left alone, so the previous
//   value can always be restored (raising the soft limit up to the hard limit
//   needs no privilege).
//
//   WHY THIS EXISTS. The mapping pin must DECLINE — not propagate — when
//   `mmap(2)` fails for a reason that has nothing to do with the file's
//   contents, because a cache optimisation that can turn a resource squeeze
//   into a failed query is worse than no cache. On POSIX there is exactly one
//   portable way to make `open(2)` of a perfectly good regular file fail while
//   `stat(2)` of the same path still succeeds: run the process out of file
//   descriptors. (Permission denial is not portable here: a process running
//   as uid 0 bypasses it.) Lowering the soft
//   limit BELOW the highest fd already open makes the next `open` return EMFILE
//   immediately, with no descriptor-exhaustion loop and no memory cost, and the
//   caller restores the limit on the next line.
//
//   `RLIMIT_NOFILE` is 7 on Linux and 8 on Darwin — a platform-constant
//   divergence of exactly the kind (`AT_FDCWD` = -2 vs -100) that this shim
//   file exists to keep off the Mojo side.
long long komira_set_nofile_soft_limit(long long soft) {
    struct rlimit rl;
    if (getrlimit(RLIMIT_NOFILE, &rl) != 0) {
        return -1;
    }
    long long prev = (long long)rl.rlim_cur;
    rl.rlim_cur = (rlim_t)soft;
    if (setrlimit(RLIMIT_NOFILE, &rl) != 0) {
        return -1;
    }
    return prev;
}

// =============================================================================
// Process-global SCHEDULER-TRACE counter block
// The a/b/c/d wall-attribution split.
// =============================================================================
//
// Why this exists
// ---------------
// This instrumentation splits the runtime's "dispatch + idle" flat-self-time
// bucket into FOUR attributed-wall buckets, because the
// mechanism that recovers each is different:
//   (a) inter-segment barrier  — a worker parks while NO run_with_state dispatch
//       is live (between breaker segments; the driver-serial combine/finalize
//       window). Discriminator: komira_on_pool_depth() == 0 at park entry
//       (the pool-dispatch depth counter lives in komira_core).
//   (b) intra-segment straggler — a worker parks while a dispatch IS live
//       (finished its shard, waits for the slowest). Discriminator: depth > 0.
//   (c) dispatch CPU           — the enqueue-loop wall (make_borrowed_erased +
//       shard build + try_send) + the worker MPSC drain-pop overhead. Real
//       on-CPU work, not idle; cross-barrier overlap can INCREASE it.
//   (d) spin-poll CPU burn     — the empty spin-window CPU-burn before a worker
//       parks (Plan-C adaptive spin).
// The remainder (useful join/agg/decode/materialize work) is derived by
// subtraction so the five buckets partition the attributed worker wall exactly.
//
// This is a process-global-scalar mechanism: a
// TU-static counter block, relaxed atomics for the thread-agnostic globals,
// plain per-wid stores for the single-writer per-worker slots. No pointers cross
// the FFI boundary; no heap; no Mojo origin interaction. The
// enabled flag is set ONCE at startup (`komira_sched_trace_configure`); every
// Mojo hot path caches it in a struct FIELD (LocalDispatcher._sched_on /
// Worker._sched_accum.enabled) so the OFF path is a single cold Bool branch with
// ZERO external_call — the <1%-overhead-when-off HARD REQUIREMENT.
//
// Output: an atexit handler prints ONE machine-parseable summary block to stderr
// (SCHED_TRACE_SUMMARY_BEGIN .. _END). For a benchmark binary a process run
// IS one query (warm-looped), so cumulative totals give the correct a/b/c/d
// FRACTIONS. komira_sched_reset() / the getters exist for precise per-window use
// + the unit test.
//
// PER-SITE CALL-SITE ATTRIBUTION
// ---------------------------------------------------------------------------
// When bucket (a), the inter-segment barrier, dominates, it is made of
// same-segment driver-serial windows between many fine-grained fork-joins.
// sites emit those forks. Each `run_with_state` fork now carries a small runtime
// `site_id` (a POD UInt32 — NO comptime axis; the method is already monomorphized
// per [State,T]). add_segment additionally bins fork wall / count / task-count by
// site, and attributes each driver-serial inter-gap to the site of the fork that
// PRECEDED it (the combine/finalize window that follows a site's fork). Sites the
// runtime cannot label at the call site (peer-owned join/concat fork sites) fall
// to SITE_OTHER (id 0), or to whatever a `SchedSiteScope` ambient guard pushed on
// an enclosing owned frame. Per-site sums partition the global fork/inter/count
// totals exactly (unit-test invariant).
// ---------------------------------------------------------------------------
#define KOMIRA_SCHED_MAXW 512
// CAPACITY. The cost of the site capacity is the transition matrix, which is
// the only N^2 structure here: 2 * N^2 * 8 B = 64 KiB at 64, 256 KiB at 128.
// That is BSS, untouched when tracing is off.
#define KOMIRA_SCHED_MAXSITE 128

static int      _sched_enabled = 0;           // 0 = off until configured
static int      _sched_atexit_armed = 0;
// Ambient call-site (SchedSiteScope). Single driver thread pushes/pops around a
// fork region in an owned enclosing frame; run_with_state reads it when its own
// site_id arg is 0 (unlabeled). Relaxed atomic — set on the driver, read on the
// driver (the fork is non-reentrant), but keep it atomic for a clean dump read.
static uint32_t _sched_cur_site = 0;
// thread-agnostic flat globals (relaxed atomics — multi-thread writers)
static uint64_t _sched_dispatch_ns = 0;       // enqueue-loop wall (bucket c)
static uint64_t _sched_erasure_count = 0;     // make_borrowed_erased volume
static uint64_t _sched_seg_count = 0;         // run_with_state fork count
static uint64_t _sched_fork_ns = 0;           // sum of fork->barrier spans
static uint64_t _sched_inter_ns = 0;          // sum of driver-serial inter-fork gaps (a, driver view)
static uint64_t _sched_last_barrier_ns = 0;   // driver bookkeeping for the inter-gap
// per-worker absolute accumulators (single-writer per wid — plain stores)
static uint64_t _sched_w_run_ns[KOMIRA_SCHED_MAXW];
static uint64_t _sched_w_pop_ns[KOMIRA_SCHED_MAXW];
static uint64_t _sched_w_park_inter_ns[KOMIRA_SCHED_MAXW];
static uint64_t _sched_w_park_intra_ns[KOMIRA_SCHED_MAXW];
static uint64_t _sched_w_spin_ns[KOMIRA_SCHED_MAXW];
static uint64_t _sched_w_empty_windows[KOMIRA_SCHED_MAXW];
static uint64_t _sched_w_tasks[KOMIRA_SCHED_MAXW];
// PRODUCTIVE-SPIN BLIND SPOT. The spin window that RUNS and THEN catches work
// would otherwise accumulate into NO bucket: the worker loop `continue`s out of
// the found-work arm without touching any accumulator, so the pre-catch spin
// burn would be invisible (bucket (d) counts only the EMPTY windows). These two
// slots close it. `spin_found_ns` is the BUSY-EXCLUDED residue: (window wall) -
// (pop_ns + run_ns advanced inside the window), so the drain-pop + handle.run
// wall the window also covers is NOT double-counted against buckets
// (c)/(useful). It is reported as its OWN bucket (e) rather than folded into
// (d), so (d) keeps meaning "empty windows" only.
static uint64_t _sched_w_spin_found_ns[KOMIRA_SCHED_MAXW];
static uint64_t _sched_w_found_windows[KOMIRA_SCHED_MAXW];
// EMPTY-WINDOW CAUSALITY. `_sched_w_empty_windows` is one
// undifferentiated count, so it cannot say WHY a window came up empty. These two
// slots partition it by the SAME (a)/(b) discriminator the park wall already
// uses — the on-pool dispatch depth sampled at window close:
//   depth==0 -> INTER: no run_with_state is live anywhere. The pool is idle
//               because the single-threaded DRIVER is in a serial region. The
//               worker is correctly starved; the fix is upstream (delete
//               driver-serial work).
//   depth>0  -> INTRA: a dispatch IS live, so work exists SOMEWHERE in the
//               system, but this worker's own queue is empty. Note the spin loop
//               drains only `self.drain_task_queue` and never steals, so this is
//               "my shard is done, the fork is not" — load imbalance / no-steal,
//               a DIFFERENT cause from driver-serial.
// Together: empty_inter + empty_intra == empty_windows (asserted by the test).
static uint64_t _sched_w_empty_inter_w[KOMIRA_SCHED_MAXW];
static uint64_t _sched_w_empty_intra_w[KOMIRA_SCHED_MAXW];
static int      _sched_w_seen[KOMIRA_SCHED_MAXW];
// per-site driver-view accumulators (single-writer: the one non-reentrant driver)
static uint64_t _sched_last_site = 0;         // site of the previous fork (inter attribution)
static uint64_t _sched_s_fork_ns[KOMIRA_SCHED_MAXSITE];   // sum fork->barrier spans per site
static uint64_t _sched_s_inter_ns[KOMIRA_SCHED_MAXSITE];  // driver-serial gap FOLLOWING a site's fork
static uint64_t _sched_s_count[KOMIRA_SCHED_MAXSITE];     // fork count per site
static uint64_t _sched_s_task_sum[KOMIRA_SCHED_MAXSITE];  // sum of per-fork task counts
static uint64_t _sched_s_task_min[KOMIRA_SCHED_MAXSITE];  // min per-fork task count (0 = unseen sentinel)
static uint64_t _sched_s_task_max[KOMIRA_SCHED_MAXSITE];  // max per-fork task count

// -----------------------------------------------------------------------------
// IN-BAND OCCUPANCY
// -----------------------------------------------------------------------------
// `tasks/fork` says how many shards were POSTED. It does not say how many did
// WORK. A site that posts 22 shards of which 2 claim a morsel reads
// n_tasks=22 — "fully fanned" — about a wave that is 9% occupied, and deriving
// the real figure by hand would need a per-query counter module for every
// query decomposed.
//
// It does not need per-cell code, because the runtime ALREADY knows it. Every
// worker keeps an absolute `run_ns` (sum of handle.run() wall) in
// `_sched_w_run_ns[]`. Snapshot the SUM across workers at fork_start and again
// at the barrier; the delta is the total worker-busy ns burned inside this
// fork's window. Then, for a fork of wall `span`:
//
//     span_avg  = busy_ns / span          # average workers concurrently busy
//     occupancy = span_avg / n_tasks      # fraction of the posted fan actually used
//
// A wave where all 22 shards work the whole span reads span_avg ~= 22,
// occupancy ~= 1.00. A wave where 2 shards work and 20 return immediately reads
// span_avg ~= 2, occupancy ~= 0.09 — on every site, on every run, for zero
// per-query edits.
//
// ⚠ THE SAMPLE LAGS BY UP TO ONE WORKER ITERATION. Read out of the code, not
// assumed: `_SchedWorkerAccum.store()` runs at the TOP of each worker loop
// iteration (`Worker.run_until_shutdown`), i.e. AFTER the handle it just ran — and the
// driver's barrier can return before that worker loops around. So a fork's
// busy delta may MISS the tail of its own last shard and pick it up in the
// NEXT fork's window. Two bounded consequences, both stated rather than
// smoothed away:
//   * a SHORT fork following a long one can read occupancy > 1.0, being
//     credited with the previous fork's tail. That row is flagged `occ_lag=1`
//     rather than CLAMPED — clamping would delete the one signal that says
//     "this number is an artifact", which is the same mistake as printing a
//     percentage over 100 and labelling it.
//   * a fork's own occupancy is slightly UNDER-stated.
// Neither threatens the discriminating case: what this makes routine is a ~10x
// read (2 of 22 vs 22 of 22), not a 5% one.
//
// ⚠ WHY THIS IS AN AVERAGE AND NOT A MAX. A process-wide MAX of
// "shards that claimed >= 1 morsel" over-reports a
// wave whose shards are briefly busy and then idle for the rest of the span:
// 22 shards that each work 5% of the window score MAX=22 but recover nothing
// from a re-grain. The time-weighted average is the quantity a fan-out lever
// actually moves, and it is the one that answers "is this fork's fan wasted".
//
// ⚠ AND WHY IT IS AN UPPER BOUND, NOT CPU. `run_ns` is WALL inside handle.run()
// (the same caveat `useful_work_ns` carries), so a
// shard PARKED on a page fault still accrues. Occupancy therefore bounds the
// useful fan from ABOVE: a LOW occupancy is firm (the fan is genuinely unused),
// a HIGH one may still be parked. The report labels it accordingly.
//
// Single-writer (the one non-reentrant driver), same discipline as above.
static uint64_t _sched_s_busy_ns[KOMIRA_SCHED_MAXSITE];   // sum worker-busy ns inside this site's fork spans
static uint64_t _sched_s_occ_span_ns[KOMIRA_SCHED_MAXSITE]; // sum of fork spans that carried an occupancy sample
static uint64_t _sched_s_occ_ct[KOMIRA_SCHED_MAXSITE];    // # forks with an occupancy sample

// =============================================================================
// ★ PER-FORK OCCUPANCY ROWS
// =============================================================================
// WHY PER-SITE IS NOT ENOUGH. The three accumulators above bin busy/span PER
// SITE, SUMMED OVER EVERY FORK. A site that several `run_with_state` call sites
// stamp — one big fork and several tiny ones per query, say — reports one
// averaged occupancy, which is consistent with BOTH "the big fork really is
// that packed" and "the big fork is nearly full and the average is DRAGGED DOWN
// by the small ones" (in which case there is no prize at that site at all). A
// per-site row cannot separate those, and attributing the average to the big
// fork would be an inference dressed as a measurement. This ring is the
// separation.
//
// WHAT A ROW IS. ONE `run_with_state` fork -> barrier span: its site, its
// CALL-SITE TAG, the shards posted, the worker-busy delta, the span, and the
// driver-serial gap that PRECEDED it. Everything but the tag is already computed
// by `komira_sched_add_segment_occ`; this emits it before the accumulate
// instead of only after.
//
// ⚠ PER FORK, NEVER PER MORSEL. A query records a handful of rows per rep; a
// per-morsel row would
// be orders of magnitude more on the scan alone and would perturb what it measures. There is no
// per-task and no per-morsel path here, deliberately, and adding one is a
// separate decision with its own cost argument.
//
// FIRST-N, NOT A WRAP — the same reasoning `_sched_msink_run_*` states: the
// per-rep pattern repeats, so the HEAD of the sequence contains it, whereas a
// wrapping buffer splices two reps' orderings together and a last-N buffer starts
// mid-rep. 512 rows covers dozens of reps of a typical fork sequence. `_sched_fork_n` keeps
// counting past the cap so the dump reports how many it did NOT keep.
//
// COST WHEN TRACING IS OFF: zero. `komira_sched_add_segment_occ` is only reached
// from inside `local_dispatcher.mojo`'s `if sched_on:` block, and the notes below
// are only set inside a caller's already-resolved cold trace Bool.
#define KOMIRA_SCHED_FORKS 512
static uint64_t _sched_fk_site[KOMIRA_SCHED_FORKS];
static uint64_t _sched_fk_tag[KOMIRA_SCHED_FORKS];
static uint64_t _sched_fk_tasks[KOMIRA_SCHED_FORKS];
static uint64_t _sched_fk_span_ns[KOMIRA_SCHED_FORKS];
static uint64_t _sched_fk_busy_ns[KOMIRA_SCHED_FORKS];
static uint64_t _sched_fk_inter_ns[KOMIRA_SCHED_FORKS];  // driver-serial gap BEFORE this fork
static uint64_t _sched_fk_t0_ns[KOMIRA_SCHED_FORKS];     // fork_start, relative to the first fork
static uint64_t _sched_fk_units[KOMIRA_SCHED_FORKS];     // the note's work-unit count (0 = none given)
static uint64_t _sched_fk_rows[KOMIRA_SCHED_FORKS];      // the note's row count (0 = none given)
static uint64_t _sched_fk_flags[KOMIRA_SCHED_FORKS];     // bit0 = no occupancy sample, bit1 = note site mismatch
static uint64_t _sched_fk_n = 0;          // forks SEEN (may exceed the cap)
static uint64_t _sched_fk_first_ns = 0;   // fork_start of row 0

// THE PENDING CALL-SITE NOTE, and why it names its own site.
//
// The shim knows `site`; it does not know WHICH of a site's call sites forked.
// A caller therefore stamps a note immediately before its fork and the recorder
// CONSUMES-AND-CLEARS it. That is a stateful protocol, so it is built to make
// mis-attribution DETECTABLE rather than silent: the note carries the site the
// caller expects, and a fork whose own site disagrees is recorded `tag=0` with
// `note_mismatch=1` and counted in `_sched_fk_note_mismatch`. A fork that simply
// has no note reads `tag=0` — "unlabeled", which is true, never a wrong label.
// `_sched_fk_note_set` vs `_sched_fk_note_used` is the attribution-health pair a
// reader checks before quoting a tag.
static uint64_t _sched_fk_note_tag = 0;
static uint64_t _sched_fk_note_site = 0;
static uint64_t _sched_fk_note_units = 0;
static uint64_t _sched_fk_note_rows = 0;
static int      _sched_fk_note_live = 0;
static uint64_t _sched_fk_note_set = 0;
static uint64_t _sched_fk_note_used = 0;
static uint64_t _sched_fk_note_mismatch = 0;
static uint64_t _sched_fk_note_dropped = 0;  // set, then overwritten by another set

// =============================================================================
// POST-BARRIER ATTRIBUTION
// =============================================================================
// `_sched_s_inter_ns[]` above charges a driver-serial window to the site of the
// fork that PRECEDED it (`fork_start(N+1) - barrier(N)` -> site(N)). That names
// the fork BEFORE the window, not the code running IN it. A serial window
// between barrier(N) and fork_start(N+1) generically contains TWO things:
//
//     [ barrier(N) ....... tail of driver N ....... head of driver N+1 ....... fork_start(N+1) ]
//                          ^ PREV attribution                ^ NEXT attribution
//
// Neither endpoint attribution is correct on its own; together they BRACKET the
// truth, and the two agree exactly when prev-site == next-site (the window is
// bounded by two forks of the SAME driver, so that driver owns it -- FIRM).
//
//   * `_sched_s_inter_next_ns[s]`  — the same gap charged to the site of the
//     FOLLOWING fork ("post-barrier attribution"). Sums to the same total as
//     `_sched_s_inter_ns`, redistributed.
//   * `_sched_s_inter_same_ns[s]`  — the sub-part where prev==next==s. This is
//     the CONFIRMED-own-window share: a gap fenced by two forks of site s.
//   * `_sched_t_ns[prev][next]` / `_sched_t_ct[prev][next]` — the full transition
//     matrix. A cross-site row says the window straddles a driver handoff and
//     needs an explicit bracket to split; the matrix says WHICH handoff, which is
//     exactly what a "the residual did not close" number was missing.
//
// Single-writer (the one non-reentrant driver), same discipline as the block
// above. 64x64x8x2 = 64 KiB of BSS, zero cost when tracing is off.
static uint64_t _sched_s_inter_next_ns[KOMIRA_SCHED_MAXSITE];
static uint64_t _sched_s_inter_same_ns[KOMIRA_SCHED_MAXSITE];
static uint64_t _sched_s_inter_next_ct[KOMIRA_SCHED_MAXSITE];
static uint64_t _sched_t_ns[KOMIRA_SCHED_MAXSITE][KOMIRA_SCHED_MAXSITE];
static uint64_t _sched_t_ct[KOMIRA_SCHED_MAXSITE][KOMIRA_SCHED_MAXSITE];

// -----------------------------------------------------------------------------
// GENERIC SERIAL-PHASE BRACKET
// -----------------------------------------------------------------------------
// The endpoint-bracket above narrows attribution but cannot, on its own, prove
// WHICH code inside a window burned the time. This is the generic form of the
// msink SETUP/PREPARE/TEARDOWN wave: a driver brackets a named serial region and
// reports (wall, fork) for it; SERIAL = wall - fork is the fork-excluded
// driver-serial residue (a region that already forks internally has near-zero
// SERIAL and nothing to recover by parallelizing).
//
// Unlike the msink block these slots are NOT per-site-8 specific — any driver can
// claim a phase id, and the dump prints the table plus the two bridge totals a
// decision needs: total named serial vs the whole-process inter-gap.
// CAPACITY. Was 32, with ids 1-24 used —
// 7 free, i.e. ONE six-phase cell decomposition away from full. Four uint64
// arrays: 1 KiB at 32, 8 KiB at 256. BSS noise.
#define KOMIRA_SCHED_MAXPHASE 256
static uint64_t _sched_ph_wall_ns[KOMIRA_SCHED_MAXPHASE];
static uint64_t _sched_ph_fork_ns[KOMIRA_SCHED_MAXPHASE];
static uint64_t _sched_ph_count[KOMIRA_SCHED_MAXPHASE];
// TAIL-WINDOW WORK-UNIT COUNTER. A phase's ns are noisy (run-to-run wall
// noise can exceed a small lever's effect), so a small lever is not
// decidable from wall in one sweep. `_sched_ph_n` carries the phase's own
// WORK UNIT — rows copied / rows evaluated / keys materialized — which is
// EXACT, reproducible run-to-run, and moves the instant a lever removes work.
// Same argument as the `copy_bytes` counter on the join key extract: a byte or
// a fork count is reportable when a timing is not. 0 for a phase that does not
// report one.
static uint64_t _sched_ph_n[KOMIRA_SCHED_MAXPHASE];

// ★ OCCUPANCY. A bracket's `serial_ns`
// is labelled `bound=upper` everywhere in this file for ONE reason: the wall
// cannot distinguish a driver BURNING CPU inside the window from a driver
// PARKED (page faults, a blocking read, a futex). Dispatching a parked window
// across 20 workers recovers NOTHING, so a lever sized off `serial_ns` alone
// can be over-stated without limit: a window that looks large in wall can
// shrink several-fold the moment occupancy is applied.
//
// `_sched_ph_cpu_ns` closes that: the delta of CLOCK_THREAD_CPUTIME_ID across
// the SAME bracket, on the SAME thread. `cpu_ns / wall_ns` is the fraction of
// the window the bracketing thread was actually on a CPU, so
// `serial_ns * occ` is the ceiling a perfect fan-out could recover and
// `serial_ns` alone is the ceiling only when occ == 1.
//
// ⚠ CLOCK_THREAD_CPUTIME_ID COUNTS KERNEL TIME ON THIS THREAD, which is the
// behaviour we want and not a flaw: a MINOR fault's zeroing/copy is real work
// that 20 threads can do 20-ways in parallel, so it belongs in the recoverable
// half. A MAJOR fault or any blocking syscall descheduled the thread and does
// NOT advance this clock, so it correctly lands in the un-recoverable half.
// 0 for a bracket whose site does not record CPU (most of them) — the printer
// omits the field entirely rather than printing occ=0.00, which would read as
// "the driver was parked" instead of "nobody measured".
static uint64_t _sched_ph_cpu_ns[KOMIRA_SCHED_MAXPHASE];

// =============================================================================
// SCHED OPWAVE — the SCAN / OPERATOR split INSIDE one fused fork
// =============================================================================
// THE QUESTION NO OTHER TABLE CAN ANSWER. `SITE_SINK_EXECUTOR` (8) is one fork
// in which each worker pulls a morsel from the SOURCE (parquet decode) and then
// runs the OPERATOR on it (the join probe). A region measures that fork's WALL,
// the site row measures its fork span and its worker-busy total — and none of
// them can say which half of the fused body the busy time went to. When that
// one fork is the majority of a query, "decode or probe" is otherwise
// unanswerable from a run and has to be inferred from symbol profiles.
//
// The split is a SUBTRACTION over two things the process already maintains:
//
//     busy_ns  = sum over workers of `handle.run()` wall inside this fork
//                (the same `komira_sched_worker_busy_total()` delta the
//                occupancy sample uses)
//     op_ns    = sum over per-worker operators of the `elapsed_compute` Time
//                metric, which `MorselOperatorImpl` requires every operator to
//                maintain and which `JoinProbeOp._record_metrics` writes on
//                EVERY return path, including `_execute_inner_deferred`'s four
//     scan_ns  = busy_ns - op_ns   <- decode + sink accumulate + morsel plumbing
//
// ⚠ A ZERO MUST BE FALSIFIABLE, WHICH IS WHY `present`/`absent` ARE RECORDED.
// `metrics_snapshot()` has a DEFAULT implementation returning an EMPTY snapshot,
// so an operator that never adopted MetricsSet contributes 0 ns and is
// indistinguishable from one that did no work. `present` counts the per-worker
// operators that actually carried an `elapsed_compute` entry and `absent` counts
// those that did not, so:
//
//     no SCHED_OPWAVE row at all  -> the wave never ran
//     present=0 absent=N          -> NOBODY WIRED THE COUNTER for this operator
//     present=N op_ns=0           -> the counter is wired and the operator was free
//
// The row is printed for every site that recorded a wave, INCLUDING one whose
// `op_ns` is zero, because withholding it is what makes the first two cases
// look alike.
//
// ⚠ THE BUSY DELTA LAGS BY UP TO ONE WORKER ITERATION, exactly as the occupancy
// sample does (`_SchedWorkerAccum.store()` runs at the TOP of the worker loop,
// after the handle it just ran). For a wave of thousands of morsels this is
// noise; for a wave of one it is not, and `count`/`workers` are printed so a
// reader can see which they have. It is NOT clamped — `scan_ns` is printed as a
// SIGNED residual so a negative reads as "the lag ate this sample", never as a
// decode that took negative time.
static uint64_t _sched_ow_count[KOMIRA_SCHED_MAXSITE];
static uint64_t _sched_ow_busy_ns[KOMIRA_SCHED_MAXSITE];
static uint64_t _sched_ow_op_ns[KOMIRA_SCHED_MAXSITE];
static uint64_t _sched_ow_rows_in[KOMIRA_SCHED_MAXSITE];
static uint64_t _sched_ow_rows_out[KOMIRA_SCHED_MAXSITE];
static uint64_t _sched_ow_workers[KOMIRA_SCHED_MAXSITE];
static uint64_t _sched_ow_present[KOMIRA_SCHED_MAXSITE];
static uint64_t _sched_ow_absent[KOMIRA_SCHED_MAXSITE];

// Record one op-bearing wave. Driver-side, once per fork — never per morsel.
int komira_sched_add_op_wave(uint32_t site, uint64_t busy_ns, uint64_t op_ns,
                              uint64_t rows_in, uint64_t rows_out,
                              uint64_t workers, uint64_t present,
                              uint64_t absent) {
    if (site >= (uint32_t)KOMIRA_SCHED_MAXSITE) site = 0;  // clamp into OTHER
    _sched_ow_count[site] += 1;
    _sched_ow_busy_ns[site] += busy_ns;
    _sched_ow_op_ns[site] += op_ns;
    _sched_ow_rows_in[site] += rows_in;
    _sched_ow_rows_out[site] += rows_out;
    _sched_ow_workers[site] += workers;
    _sched_ow_present[site] += present;
    _sched_ow_absent[site] += absent;
    return 0;
}

// Op-wave getters (the driver's own `set_n`, and the unit test).
// 0=count 1=busy 2=op 3=rows_in 4=rows_out 5=workers 6=present 7=absent.
uint64_t komira_sched_get_op_wave(uint32_t site, int field) {
    if (site >= (uint32_t)KOMIRA_SCHED_MAXSITE) return 0;
    switch (field) {
    case 0: return _sched_ow_count[site];
    case 1: return _sched_ow_busy_ns[site];
    case 2: return _sched_ow_op_ns[site];
    case 3: return _sched_ow_rows_in[site];
    case 4: return _sched_ow_rows_out[site];
    case 5: return _sched_ow_workers[site];
    case 6: return _sched_ow_present[site];
    case 7: return _sched_ow_absent[site];
    default: return 0;
    }
}

// =============================================================================
// SCHED REGION — OBSERVED nesting, self_ns, TID partition
// =============================================================================
// The legacy `add_serial_phase` block above cannot produce a DISJOINT TOTAL, for
// two independent reasons, and both are structural:
//
//   1. Nesting is DECLARED, not observed. `_sched_phase_is_nested` is literally
//      `return id == 11 || id == 12 || id == 19 || id == 22;` — a hand-edited
//      boolean that a new bracket has to remember to join. Nothing checks it.
//   2. There is no residue term. The coverage bridge is WITHHELD entirely when
//      `named_serial > inter`, so "how much of this cell's driver time is
//      unnamed" has no computable answer.
//
// A REGION fixes both by measuring what the legacy form assumed. Enter pushes
// onto a THREAD-LOCAL stack; exit pops, and charges its own inclusive wall to
// the parent's child accumulator. Each region then carries
//
//     self_ns = wall_ns - sum(children wall_ns)
//
// the ordinary self/inclusive split, so self_ns over a properly-rooted tree is a
// PARTITION by construction — no nested list to maintain, and no way for a new
// bracket to silently double-count. A root region (the query driver) makes
//
//     UNATTRIBUTED = root.self_ns
//
// an ordinary row rather than a withheld ratio.
//
// ⚠ MOJO ASAP DESTRUCTION IS THE HAZARD, and it is real — `SchedSiteScope`
// already documents it (a guard destroyed before the fork it was meant to label
// restores the ambient site early). A region destroyed out of order would
// silently misattribute, which is worse than not measuring. So exit is
// DEFENSIVE: if top-of-stack is not the region being closed, we do NOT guess —
// bump `_sched_rg_misnest` and drop the sample. The report then REFUSES to
// print the partition for that run rather than printing a wrong one. Same shape
// as `check_no_remote_hostreq.py` refusing a zero-target query: an
// unverifiable answer is reported as unverifiable, never as an answer.
//
// ⚠ TID PARTITION. There is NO thread guard anywhere in the legacy block:
// `komira_sched_add_serial_phase` is a plain non-atomic `+=` under a comment
// reading "Driver-thread-only". That is a convention, not a mechanism, AND a
// latent data race if a worker ever brackets. Regions cache thread identity in
// TLS and keep two never-summed partitions. A driver share computed from zero
// driver samples is refused in-band, where the operator cannot forget it —
// promoting `driver_profile_parse.py`'s existing rc=3 refusal into the
// trace itself.
// =============================================================================
// SCHED REGION EVENT LOG — PHASE MARKERS for `perf record`
// =============================================================================
// THE QUESTION THE WALL BUDGET CANNOT ANSWER. A phase budget in WALL says WHERE
// the time goes; it cannot say whether a phase is expensive because it does more
// WORK or because it WAITS. When a top-down profile says the engine retires
// more uops than a reference engine at the same parallel efficiency, the gap is
// WORK, and the question is which phase carries it.
//
// ⛔ A PER-PHASE HARDWARE COUNTER IS NOT THE CHEAP ROUTE, AND THE REASON IS
// STRUCTURAL. Four of the seven phases are FORKS: their work runs on 20 worker
// threads, not on the driver that brackets them, and `perf_event_open` counts
// the CALLING thread. Reading instructions per phase would mean one fd per
// worker, opened in the worker loop, accumulated the way `run_ns` already is,
// plus a driver fd for the serial phases — a real mechanism, linux-only, gated
// on `perf_event_paranoid`, and no help on darwin.
//
// THE CHEAP ROUTE IS TIME. `perf record -k mono` timestamps every sample on
// CLOCK_MONOTONIC and the phases are contiguous windows on that same clock, so
// binning samples by TIME gives instructions per phase ACROSS EVERY THREAD with
// no new counter at all. The only missing piece was the boundaries, and that is
// what this log is: one line per region enter/exit carrying the id and the raw
// CLOCK_MONOTONIC nanosecond.
//
// ⚠ AND BINNING BY A 100 ms WINDOW IS NOT THE SKID PROBLEM. Sample skid moves a
// sample by a handful of instructions — enough to blame the wrong INSTRUCTION
// (which is how a `lock cmpxchg` was once credited with 72% of a phase), and
// nowhere near enough to move it into a different phase. Attributing to a
// window is exactly the altitude at which skid stops mattering.
//
// DEFAULT OFF, and separate from the trace switch itself: the aggregate tables
// cost nothing per event, this costs one vDSO clock read and one `fprintf` per
// region boundary. Enabled by `komira_sched_trace_configure(on, region_log=1)`
// (which also needs `on`, since a region that never opens emits nothing).
static int _sched_rgn_log = 0;    // 0 = off, 1 = on (set by komira_sched_trace_configure)

// FORWARD DECLARATION. `_sched_labels.inc` (which defines this) is #included
// far below, next to the dump that consumes the rest of its tables; the region
// enter/exit above it needs the name for its markers. Declared `static` to
// match the generated definition — an implicit declaration would compile on
// some toolchains and hard-error on this one.
static const char *_sched_phase_name(uint32_t id);

static inline int _sched_rgn_log_on(void) {
    return __atomic_load_n(&_sched_rgn_log, __ATOMIC_RELAXED);
}

// CLOCK_MONOTONIC, deliberately — it is the clock `perf record -k mono` stamps
// its samples with, and a marker on any other clock cannot be joined to them.
static inline uint64_t _sched_mono_ns(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

#define KOMIRA_SCHED_REGION_DEPTH 64

// DRIVER partition (thread identity == the captured driver thread).
static uint64_t _sched_rg_wall_ns[KOMIRA_SCHED_MAXPHASE];  // inclusive
static uint64_t _sched_rg_self_ns[KOMIRA_SCHED_MAXPHASE];  // inclusive - children
static uint64_t _sched_rg_fork_ns[KOMIRA_SCHED_MAXPHASE];
static uint64_t _sched_rg_count[KOMIRA_SCHED_MAXPHASE];
static uint64_t _sched_rg_n[KOMIRA_SCHED_MAXPHASE];
static uint64_t _sched_rg_depth_max[KOMIRA_SCHED_MAXPHASE];
// WORKER partition. Never summed with the driver arrays, and printed on its own
// rows — a worker-opened bracket measures concurrent wall across N threads and
// adding it to a single-threaded driver total is meaningless.
static uint64_t _sched_rg_wall_ns_w[KOMIRA_SCHED_MAXPHASE];
static uint64_t _sched_rg_self_ns_w[KOMIRA_SCHED_MAXPHASE];
static uint64_t _sched_rg_count_w[KOMIRA_SCHED_MAXPHASE];

// Thread-local bracket stack. `child_ns` accumulates the inclusive wall of the
// children closed while this frame is open.
static __thread uint32_t _sched_rg_stk_id[KOMIRA_SCHED_REGION_DEPTH];
static __thread uint64_t _sched_rg_stk_child[KOMIRA_SCHED_REGION_DEPTH];
static __thread int      _sched_rg_stk_depth = 0;
static __thread uintptr_t _sched_rg_self_tid = 0;   // cached pthread identity

static uint64_t _sched_rg_misnest = 0;        // out-of-order exits (partition invalid)
static uint64_t _sched_rg_overflow = 0;       // depth > REGION_DEPTH
static uint64_t _sched_rg_orphan = 0;         // exit with an empty stack
static uintptr_t _sched_driver_tid = 0;       // captured at reset (the driver calls it)
static uint64_t _sched_rg_driver_samples = 0;
static uint64_t _sched_rg_worker_samples = 0;
static uint32_t _sched_rg_root_id = 0;        // id declared as the query root

// Thread identity. `pthread_self()` is identity-only (never dereferenced, never
// printed as a number that must mean anything across runs), which is all the
// driver/worker partition needs and is portable across linux + darwin without a
// syscall on the hot path. Cached in TLS so a region enter costs one predicted
// load, not a libc call.
static inline uintptr_t _sched_tid_self(void) {
    if (_sched_rg_self_tid == 0) {
        _sched_rg_self_tid = (uintptr_t)pthread_self();
        // A pthread_t that casts to 0 would re-derive on every call. Nothing
        // breaks (identity comparison still holds), but pin it off zero so the
        // cache is a cache.
        if (_sched_rg_self_tid == 0) _sched_rg_self_tid = (uintptr_t)1;
    }
    return _sched_rg_self_tid;
}

// Open a region. Returns the depth AFTER the push (>=1) as an opaque token the
// caller hands back to exit; 0 means "not recorded" (overflow) and exit will
// ignore it. Cheap: one TLS load + two stores.
int komira_sched_region_enter(uint32_t phase) {
    if (phase == 0 || phase >= (uint32_t)KOMIRA_SCHED_MAXPHASE) return 0;
    int d = _sched_rg_stk_depth;
    if (d >= KOMIRA_SCHED_REGION_DEPTH) {
        __atomic_add_fetch(&_sched_rg_overflow, 1, __ATOMIC_RELAXED);
        return 0;
    }
    _sched_rg_stk_id[d] = phase;
    _sched_rg_stk_child[d] = 0;
    _sched_rg_stk_depth = d + 1;
    if (_sched_rgn_log_on()) {
        fprintf(stderr, "SCHED_RGN ev=ENTER id=%u name=%s depth=%d "
                        "mono_ns=%llu tid=%llu\n",
                phase, _sched_phase_name(phase), d + 1,
                (unsigned long long)_sched_mono_ns(),
                (unsigned long long)(uintptr_t)_sched_tid_self());
    }
    return d + 1;
}

// Close a region opened by `komira_sched_region_enter`. `wall_ns` is the
// bracket's own wall, `fork_ns` the fork->barrier span completed inside it, `n`
// the region's work unit (0 if none).
//
// DEFENSIVE POP: the region being closed must be on top. If it is not, the
// stack has been unwound out of order (ASAP destruction, or an exception path)
// and every attribution below this point is suspect, so we record the fact and
// attribute NOTHING. `token` is the depth the matching enter returned, which
// catches the case where the ids happen to match but the frames do not.
int komira_sched_region_exit(uint32_t phase, int token, uint64_t wall_ns,
                              uint64_t fork_ns, uint64_t n) {
    if (token == 0) return 0;  // enter declined (overflow) — nothing to close
    int d = _sched_rg_stk_depth;
    if (d <= 0) {
        __atomic_add_fetch(&_sched_rg_orphan, 1, __ATOMIC_RELAXED);
        return 0;
    }
    if (d != token || _sched_rg_stk_id[d - 1] != phase) {
        __atomic_add_fetch(&_sched_rg_misnest, 1, __ATOMIC_RELAXED);
        // Unwind to the frame that DOES match, if one is open, so a single
        // misnest does not corrupt every subsequent sample. The partition is
        // already marked invalid for this run either way.
        int k = d - 1;
        while (k >= 0 && _sched_rg_stk_id[k] != phase) k--;
        _sched_rg_stk_depth = (k >= 0) ? k : (d - 1);
        return 0;
    }
    _sched_rg_stk_depth = d - 1;
    uint64_t child = _sched_rg_stk_child[d - 1];
    uint64_t self_ns = (wall_ns > child) ? (wall_ns - child) : 0;
    // Charge our INCLUSIVE wall to the parent's child accumulator, so the
    // parent's self_ns excludes us. This is what makes self_ns a partition.
    if (d - 2 >= 0) _sched_rg_stk_child[d - 2] += wall_ns;

    if (_sched_tid_self() == __atomic_load_n(&_sched_driver_tid, __ATOMIC_RELAXED)) {
        _sched_rg_wall_ns[phase] += wall_ns;
        _sched_rg_self_ns[phase] += self_ns;
        _sched_rg_fork_ns[phase] += fork_ns;
        _sched_rg_count[phase] += 1;
        _sched_rg_n[phase] += n;
        if ((uint64_t)d > _sched_rg_depth_max[phase]) _sched_rg_depth_max[phase] = (uint64_t)d;
        __atomic_add_fetch(&_sched_rg_driver_samples, 1, __ATOMIC_RELAXED);
    } else {
        // Worker partition — concurrent across threads, so these MUST be atomic
        // (the legacy block's plain `+=` under a "driver-only" comment is the
        // race this avoids).
        __atomic_add_fetch(&_sched_rg_wall_ns_w[phase], wall_ns, __ATOMIC_RELAXED);
        __atomic_add_fetch(&_sched_rg_self_ns_w[phase], self_ns, __ATOMIC_RELAXED);
        __atomic_add_fetch(&_sched_rg_count_w[phase], 1, __ATOMIC_RELAXED);
        __atomic_add_fetch(&_sched_rg_worker_samples, 1, __ATOMIC_RELAXED);
    }
    if (_sched_rgn_log_on()) {
        // `wall_ns` travels with the EXIT so a binner can cross-check its own
        // (enter, exit) span against the number the region recorded. They must
        // agree to within the two clock reads; if they do not, the marker pair
        // is not the window the partition priced and the bin is not comparable.
        fprintf(stderr, "SCHED_RGN ev=EXIT id=%u name=%s depth=%d "
                        "mono_ns=%llu tid=%llu wall_ns=%llu fork_ns=%llu\n",
                phase, _sched_phase_name(phase), d,
                (unsigned long long)_sched_mono_ns(),
                (unsigned long long)(uintptr_t)_sched_tid_self(),
                (unsigned long long)wall_ns, (unsigned long long)fork_ns);
    }
    return 0;
}

// Declare which phase id is the query ROOT. The report reads the root's self_ns
// as UNATTRIBUTED and its wall_ns as the partition denominator.
int komira_sched_region_set_root(uint32_t phase) {
    if (phase >= (uint32_t)KOMIRA_SCHED_MAXPHASE) return 0;
    __atomic_store_n(&_sched_rg_root_id, phase, __ATOMIC_RELAXED);
    return 0;
}

// Adopt the CALLING thread as the driver. `komira_sched_reset` also does this
// (reset is a driver-side call), but a process that never resets still needs a
// driver, and a test needs to be able to say "this thread is the driver" without
// clearing the counters it is about to read.
int komira_sched_region_adopt_driver(void) {
    __atomic_store_n(&_sched_driver_tid, _sched_tid_self(), __ATOMIC_RELAXED);
    return 0;
}

// Region getters (unit test + report). 0=wall 1=self 2=fork 3=count 4=n
// 5=depth_max; worker partition: 6=wall_w 7=self_w 8=count_w.
uint64_t komira_sched_get_region(uint32_t phase, int field) {
    if (phase >= (uint32_t)KOMIRA_SCHED_MAXPHASE) return 0;
    if (field == 0) return _sched_rg_wall_ns[phase];
    if (field == 1) return _sched_rg_self_ns[phase];
    if (field == 2) return _sched_rg_fork_ns[phase];
    if (field == 3) return _sched_rg_count[phase];
    if (field == 4) return _sched_rg_n[phase];
    if (field == 5) return _sched_rg_depth_max[phase];
    if (field == 6) return __atomic_load_n(&_sched_rg_wall_ns_w[phase], __ATOMIC_RELAXED);
    if (field == 7) return __atomic_load_n(&_sched_rg_self_ns_w[phase], __ATOMIC_RELAXED);
    if (field == 8) return __atomic_load_n(&_sched_rg_count_w[phase], __ATOMIC_RELAXED);
    return 0;
}

// Region health (unit test + report refusals). 0=misnest 1=overflow 2=orphan
// 3=driver_samples 4=worker_samples 5=root_id 6=open_depth(this thread).
uint64_t komira_sched_get_region_health(int field) {
    if (field == 0) return __atomic_load_n(&_sched_rg_misnest, __ATOMIC_RELAXED);
    if (field == 1) return __atomic_load_n(&_sched_rg_overflow, __ATOMIC_RELAXED);
    if (field == 2) return __atomic_load_n(&_sched_rg_orphan, __ATOMIC_RELAXED);
    if (field == 3) return __atomic_load_n(&_sched_rg_driver_samples, __ATOMIC_RELAXED);
    if (field == 4) return __atomic_load_n(&_sched_rg_worker_samples, __ATOMIC_RELAXED);
    if (field == 5) return (uint64_t)__atomic_load_n(&_sched_rg_root_id, __ATOMIC_RELAXED);
    if (field == 6) return (uint64_t)_sched_rg_stk_depth;
    return 0;
}

// -----------------------------------------------------------------------------
// LABEL TABLES — GENERATED from the Mojo `comptime SITE_*` / `PHASE_*`
// declarations (`runtime/sched_trace.mojo`), so the C labels and the Mojo
// constants cannot drift apart.
//
// Generating these from the Mojo declarations (rather than hand-writing a
// second copy here) makes a mislabelled site structural rather than something
// a comparison of two hand-written copies could miss.
//
// Defines: _sched_site_name, _sched_phase_name, _sched_phase_unit.
// `_sched_phase_is_nested` below is NOT generated -- it belongs to the LEGACY
// declared-nesting bracket table only. Regions observe their nesting at
// runtime and have no such list.
// -----------------------------------------------------------------------------
#include "_sched_labels.inc"




// TRUE for a phase whose bracketed region is CONTAINED IN another phase's
// region. Such a phase is a legitimate sub-split (11/12 cut the extract that
// 6/7 already bracket, separating the `as_string` copy from the FNV loop), but
// its serial residue must NOT accrue to `SCHED_PHASE_COVERAGE` — that bridge is
// "how much of the driver-serial wall is now NAMED", and a nested id counts the
// same nanoseconds twice. See the comment at the coverage loop.
static int _sched_phase_is_nested(uint32_t id) {
    // TAIL-WINDOW adds two CONTAINER brackets, and a container is
    // the same double-count hazard as a sub-split, just from the other side:
    //   19 `hbs_payload_concat` WRAPS the concat, whose own 3/4 brackets are
    //      recorded inside it.
    //   22 `hbs_ht_build` WRAPS the build AND the 21 dynamic-filter copy that
    //      shares the region on both arms.
    // Both are excluded so the coverage bridge stays a partition; their rows
    // still print, which is the whole point (19's and 22's `wall - fork` is how
    // you see how much of each fork-bearing region was NOT dispatched).
    return id == 11 || id == 12 || id == 19 || id == 22;
}

// Sub-split the msink site's
// driver-serial inter-gap into (i) the RECOVERABLE driver-serial combine phases
// vs (ii) the residual handoff/sequencing wait a parallel combine cannot touch.
// The morsel-sink collect driver (unified/executor_msink.mojo) brackets the
// exact serial calls that run BETWEEN a SITE_SINK_EXECUTOR(id 8) fork's barrier
// and the next fork — the per-worker-locals DRAIN, the whole-segment
// sink.combine() (the parallelize target), and finalize() — and sums
// their wall here. Because these phases execute INSIDE the site-8 inter-gap, the
// ratio (drain+combine+finalize) / _sched_s_inter_ns[8] is exactly the fraction
// of the msink inter-gap that parallelizing the combine could recover.
// Single-writer (the non-reentrant driver), but kept relaxed-atomic like the
// rest of the block for a clean concurrent dump read.
// WALL sums: total wall of each phase (INCLUDES any internal run_with_state
// forks the phase dispatches). FORK sums: the fork->barrier span that completed
// INSIDE the phase bracket (the already-parallel portion). SERIAL = WALL - FORK
// is the fork-excluded driver-serial residue — the part actually recoverable by
// parallelizing (a phase that already forks internally has near-zero SERIAL and
// nothing to recover). The combine/finalize SERIAL residues are what sit in the
// SITE_SINK_EXECUTOR inter-gap; drain never forks so drain WALL == drain SERIAL.
static uint64_t _sched_msink_drain_ns = 0;         // per-worker locals drain loop (serial)
static uint64_t _sched_msink_combine_wall_ns = 0;  // sink.combine() total wall
static uint64_t _sched_msink_combine_fork_ns = 0;  // fork span completed inside combine (already parallel)
static uint64_t _sched_msink_finalize_wall_ns = 0; // sink.finalize() total wall
static uint64_t _sched_msink_finalize_fork_ns = 0; // fork span completed inside finalize (already parallel)
static uint64_t _sched_msink_phase_count = 0;      // # of msink driver invocations bracketed
// ★ OCCUPANCY — see `_sched_ph_cpu_ns`.
// CLOCK_THREAD_CPUTIME_ID delta of the DRIVER thread across the finalize /
// combine brackets. A large `finalize` serial residue stays `bound=upper` until
// this says the driver was on-CPU for it.
static uint64_t _sched_msink_finalize_cpu_ns = 0;
static uint64_t _sched_msink_combine_cpu_ns = 0;

// ★ PER-INVOCATION MSINK RECORDS.
//
// THE PROBLEM THIS SOLVES. `SCHED_MSINK finalize` is a SUM over every
// morsel-sink breaker in the run, and on the join-cluster cells that sum hides
// the only question worth asking: WHICH sink. A total cannot say whether
// 65 ms/rep of finalize is one 65 ms window or three 22 ms ones, nor which
// operator owns it. A lever aimed at a sum is aimed at nothing.
//
// It matters because the sinks ALREADY DISAGREE. `CountDistinctAggSink` forks
// through the `disp_ptr` seam and the SAME bracket can read almost entirely
// FORKED; `HashAggUntypedSink`'s
// collect sink's concat has a column-parallel path that is default-ON and a
// single-batch fast path that is a pure move. So "finalize is serial" is a
// statement about a SUBSET of sinks, and the subset has never been named.
//
// Deliberately the FIRST N invocations — not the last N, and not a wrap. The
// per-rep pattern repeats, so the head of the sequence contains it, whereas a
// wrapping buffer splices two reps' orderings together and a last-N buffer
// starts mid-rep. N=48 covers several reps of a wide query (one with ~30
// invocations per rep). `_sched_msink_run_n` keeps counting past the cap so the dump
// can say how many it did NOT keep rather than silently truncating.
//
// The label is the sink's own `combine_trace_label()`. Most sinks inherit the
// base's honest `"unlabeled"`, and a census of `unlabeled` rows here is a
// to-do list, not a false claim of coverage.
#define KOMIRA_SCHED_MSINK_RUNS 48
static uint64_t _sched_msink_run_fin_wall[KOMIRA_SCHED_MSINK_RUNS];
static uint64_t _sched_msink_run_fin_fork[KOMIRA_SCHED_MSINK_RUNS];
static uint64_t _sched_msink_run_fin_cpu[KOMIRA_SCHED_MSINK_RUNS];
static uint64_t _sched_msink_run_comb_wall[KOMIRA_SCHED_MSINK_RUNS];
static uint64_t _sched_msink_run_comb_fork[KOMIRA_SCHED_MSINK_RUNS];
static uint64_t _sched_msink_run_driver_wall[KOMIRA_SCHED_MSINK_RUNS];
static char _sched_msink_run_label[KOMIRA_SCHED_MSINK_RUNS][40];
static uint64_t _sched_msink_run_n = 0;

// SCHED_MSINK per-run WALL attribution.
// The block above reports each phase as a % of the SITE_SINK_EXECUTOR
// *inter-gap* (_sched_s_inter_ns[8]) — a driver-serial window that is itself only
// a small fraction of the breaker's WALL (the wall is dominated by the parallel
// scan/agg fork span, which is NOT in the inter-gap). Reading "finalize_serial =
// 73% of inter-gap" as a WALL share OVERSTATES the lever ~10x. So the
// msink driver now brackets its WHOLE wall (entry->return, incl. the scan/agg
// fork) and passes it here, so the dump reports each phase as a % of the RUN's
// wall. Two views: a cumulative sum (-> avg over runs) and a LAST-RUN OVERWRITE
// snapshot. The last msink invocation is a steady-state MEASURE iteration, so the
// snapshot is a clean single-run wall share — free of warmup contamination AND of
// the cross-iteration aggregation that inflated the inter-gap %.
static uint64_t _sched_msink_driver_wall_ns = 0;   // cumulative whole-driver wall (sum over runs)
// LAST-RUN overwrite slots (one measured run; NOT summed across iterations).
static uint64_t _sched_msink_last_driver_wall_ns = 0;
static uint64_t _sched_msink_last_drain_ns = 0;
static uint64_t _sched_msink_last_combine_wall_ns = 0;
static uint64_t _sched_msink_last_combine_fork_ns = 0;
static uint64_t _sched_msink_last_finalize_wall_ns = 0;
static uint64_t _sched_msink_last_finalize_fork_ns = 0;

// MSINK HANDOFF-RESIDUAL BRACKET. Without these, most of the
// SITE_SINK_EXECUTOR(8) inter-gap would sit in an anonymous "handoff residual"
// INSIDE an otherwise-instrumented window. These three brackets name the rest
// of the msink driver's serial spine:
//   * SETUP    — driver entry -> the streaming fork. Source hooks, the fan-out cap,
//                the per-worker locals slab (eff_workers x `sink.init_local()`, one
//                heap hash-table/accumulator allocation EACH), `sink.init_global()`,
//                and the State build. NB: this window lands in the PREVIOUS fork's
//                inter-gap (it precedes site 8's own fork), so it explains part of
//                the residual attributed to whatever site ran before -- it is
//                summed separately and reported as its own line.
//   * PREPARE  — post-combine `num_partitions()` + `prepare_finalize()` (and the
//                `_drive_combine_partition` dispatch decision), i.e. the window
//                between the combine bracket and the finalize bracket.
//   * TEARDOWN — post-finalize: the Finished-arm guard, `take_slot_unchecked(0)` on
//                the output slab, and the FinalizeOutput drop, i.e. the window
//                between the finalize bracket and the driver's return.
// Same cumulative + LAST-RUN-overwrite shape as the phases above.
// PREPARE is NOT pure driver-serial. It brackets
// `_drive_combine_partition`, which calls `dispatcher.run_with_state(...,
// site_id=SITE_SINK_EXECUTOR)` — a real fork — whenever `num_partitions() > 1`.
// Reporting its WALL under a `(serial)` label attributed parallel time to the
// driver, and could read many times the entire inter-gap it claimed to be a
// part of. PREPARE therefore carries
// a fork counter and is reported wall/fork/serial exactly like COMBINE and
// FINALIZE. SETUP and TEARDOWN contain no dispatch and remain pure-serial.
static uint64_t _sched_msink_setup_ns = 0;
static uint64_t _sched_msink_prepare_ns = 0;       // WALL (fork-inclusive)
static uint64_t _sched_msink_prepare_fork_ns = 0;  // fork span completed inside
static uint64_t _sched_msink_teardown_ns = 0;
static uint64_t _sched_msink_last_setup_ns = 0;
static uint64_t _sched_msink_last_prepare_ns = 0;
static uint64_t _sched_msink_last_prepare_fork_ns = 0;
static uint64_t _sched_msink_last_teardown_ns = 0;

// AGG-IN-PASS admission-pin fire counter. A test-observable
// fire signal, INDEPENDENT of the sched-trace block (same TU-static relaxed-
// atomic mechanism, but always on and NOT reset by komira_sched_reset).
// The fused CASE-B agg-over-join resolver arm bumps this exactly once per
// admission-SUCCESS (both the column-reference and the mapped fires). It exists
// to close the vacuous-green trap: if a future change silently kills
// admission, `ON` takes the SAME resident path as `OFF`, so the byte-equiv
// oracle passes trivially and the dead route is NOT caught. The admission-pin
// test resets this, runs a join-then-aggregate shape with the feature ON, and asserts count>0
// (fired) + count==0 on a wrong-way / non-INNER shape (clean decline). One
// relaxed add per fire — negligible on the ON path, ZERO on the OFF path (the
// resolver never reaches the increment when it declines).
static uint64_t _agg_in_pass_fire_count = 0;

// ORDER-ADVISORY fire counter. A
// test-observable fire signal for the join-order advisory checker, mirroring the
// agg-in-pass admission pin above (same TU-static relaxed-atomic mechanism,
// always on, NOT reset by komira_sched_reset). The checker
// (komira_sdk's order advisory) bumps this exactly once per DIVERGENCE
// (author join order estimated worse than the optimizer's reordered order). It
// closes the same vacuous-green trap the agg-in-pass pin closes: the advisory is
// read-only (never changes bytes), so a byte-equiv oracle can NEVER catch a
// silently-dead checker — a falsifier resets this, feeds an author join order
// known to blow up, and asserts count>0 (FIRED); a second feeds an
// already-optimal order and asserts count==0 (SILENT). One relaxed add per
// fire; ZERO on the silent path.
static uint64_t _order_advisory_fire_count = 0;

// PROJECTION SEAM — the last DECODED intermediate column count in a
// projected leaf-scan collect (sort / partition_topn / window). The seam
// narrows the parquet decode to {projection ∪ the breaker's
// keys} so dead columns are NEVER materialized; the post-materialize output is
// byte-identical to the post-materialize narrow either way, so a byte-equiv oracle can
// NEVER catch a silently-dead pre-materialize narrow. This SET-observable records
// `batch.num_columns()` right after the decode: each projection falsifier resets it,
// materializes a wide-row `<breaker>(...).select([subset])`, and asserts it equals
// the NARROW keep-width, NOT the full width. When the seam DECLINES (a frame
// with no projection) it records the FULL width — the RED→GREEN separation
// the byte-equiv oracle cannot see.
static uint64_t _seam1_decode_ncols = 0;

// JOIN-REORDER fire counter. A
// test-observable fire signal for the dpccp/greedy join reorderer.
// `reorder_joins_with_dp` bumps this once per maximal INNER-join chain it emits a
// reordered order for. It is the decision pin: an untyped
// multi-join fluent chain routed through the flatten-EXECUTE path asserts
// count>0 (the reorderer FIRED under the flattened plan); the kill-switched
// (author-order) path never reaches the reorderer, so count==0. One relaxed add
// per emitted chain; ZERO on the author path.
static uint64_t _join_reorder_fire_count = 0;

// GENERIC-EXECUTOR fire counter. The
// test-observable fire signal for the SHAPE-FREE generic wave-fold Runtime-A
// consumer (`run_generic_wave_fold`) — the DEFAULT-ON executor
// for the agg-over-INNER-join star. Bumped once per SUCCESSFUL
// generic cascade (right before the agg terminal). The generic path is
// DECLINE-not-corrupt (falls back to the byte-identical walker on any non-drivable
// shape), so the e2e ON leg resets + asserts count>0 to prove the generic path
// ACTUALLY drove the query (never a vacuous green). One relaxed add per fire; ZERO
// on the decline/fallback path.
static uint64_t _exec_generic_fire_count = 0;

// FUSED-DIM-WAVE. The test-observable fire
// signal for the FUSED multi-dim BUILD wave in `run_generic_wave_fold` — the ONE
// `run_subrg_scan_multi` fork whose task space is the UNION of every eligible dim
// leaf's row groups, replacing N sequential blocking fork-joins. The counter
// records the NUMBER OF DIMS the fused wave carried (not the number of waves), so
// a test can assert "the antichain actually fused >= 2 leaves" rather than the
// weaker "a wave ran". A future edit that reverts to the per-dim sequential loop
// drops this to 0 and the reachability guard goes RED: code that silently runs
// inline instead is caught here.
static uint64_t _fused_dim_wave_dims = 0;

// Partial-bind falsifier's
// seg-state alloc/free BALANCE counters. The grouped-agg
// registration leaf bumps `_seg_state_alloc` when its init_thunk allocates a
// state box, and a free-guard inside the boxed state bumps `_seg_state_free` on
// teardown. The test binds N grouped-agg segments where seg-3's init RAISES
// after segs 1,2 are bound, then asserts alloc == free (== 2) — proving the
// already-bound state boxes tear down EXACTLY ONCE on the raise (no leak, no
// double-free). Test-only signal.
static uint64_t _seg_state_alloc_count = 0;
static uint64_t _seg_state_free_count = 0;



// Aggregate + print the summary block. Registered via atexit on first enable.
static void _komira_sched_dump(void) {
    uint64_t run = 0, pop = 0, pi = 0, pa = 0, spin = 0, ew = 0, tasks = 0;
    uint64_t spinf = 0, fw = 0;
    uint64_t ewi = 0, ewa = 0;
    int nworkers = 0;
    for (int w = 0; w < KOMIRA_SCHED_MAXW; w++) {
        if (!_sched_w_seen[w]) continue;
        nworkers++;
        run   += _sched_w_run_ns[w];
        pop   += _sched_w_pop_ns[w];
        pi    += _sched_w_park_inter_ns[w];
        pa    += _sched_w_park_intra_ns[w];
        spin  += _sched_w_spin_ns[w];
        ew    += _sched_w_empty_windows[w];
        ewi   += _sched_w_empty_inter_w[w];
        ewa   += _sched_w_empty_intra_w[w];
        spinf += _sched_w_spin_found_ns[w];
        fw    += _sched_w_found_windows[w];
        tasks += _sched_w_tasks[w];
    }
    uint64_t disp = __atomic_load_n(&_sched_dispatch_ns, __ATOMIC_RELAXED);
    uint64_t er_ct = __atomic_load_n(&_sched_erasure_count, __ATOMIC_RELAXED);
    uint64_t segs  = __atomic_load_n(&_sched_seg_count, __ATOMIC_RELAXED);
    uint64_t fork  = __atomic_load_n(&_sched_fork_ns, __ATOMIC_RELAXED);
    uint64_t inter = __atomic_load_n(&_sched_inter_ns, __ATOMIC_RELAXED);
    // Buckets. (c) = driver/nested enqueue-loop wall + worker drain-pop overhead.
    // remainder (useful work) = worker run wall MINUS the enqueue-loop wall that
    // nests inside handle.run (avoids double-counting dispatch inside run).
    uint64_t a = pi;
    uint64_t b = pa;
    uint64_t c = disp + pop;
    uint64_t d = spin;
    // Bucket (e): the PRODUCTIVE-spin burn (a window that spun and THEN
    // caught work). Busy-excluded at the worker, so it does NOT overlap (c) or
    // the useful remainder. Kept OUT of (d) so (d) keeps meaning "empty windows".
    uint64_t e = spinf;
    uint64_t remainder = (run > disp) ? (run - disp) : 0;
    uint64_t total = a + b + c + d + e + remainder;
    double td = (total > 0) ? (double)total : 1.0;
    fprintf(stderr, "SCHED_TRACE_SUMMARY_BEGIN\n");
    fprintf(stderr,
        "SCHED workers=%d segments=%llu erasures=%llu tasks=%llu\n",
        nworkers, (unsigned long long)segs, (unsigned long long)er_ct,
        (unsigned long long)tasks);
    fprintf(stderr, "SCHED attributed_worker_wall_ns=%llu\n",
        (unsigned long long)total);
    fprintf(stderr, "SCHED a_inter_barrier_ns=%llu pct=%.2f\n",
        (unsigned long long)a, 100.0 * (double)a / td);
    fprintf(stderr, "SCHED b_intra_straggler_ns=%llu pct=%.2f\n",
        (unsigned long long)b, 100.0 * (double)b / td);
    fprintf(stderr, "SCHED c_dispatch_cpu_ns=%llu pct=%.2f\n",
        (unsigned long long)c, 100.0 * (double)c / td);
    fprintf(stderr, "SCHED d_spin_poll_ns=%llu pct=%.2f\n",
        (unsigned long long)d, 100.0 * (double)d / td);
    fprintf(stderr, "SCHED e_spin_found_ns=%llu pct=%.2f\n",
        (unsigned long long)e, 100.0 * (double)e / td);
    fprintf(stderr, "SCHED useful_work_ns=%llu pct=%.2f\n",
        (unsigned long long)remainder, 100.0 * (double)remainder / td);
    fprintf(stderr,
        "SCHED c_detail dispatch_enqueue_ns=%llu drain_pop_ns=%llu\n",
        (unsigned long long)disp, (unsigned long long)pop);
    fprintf(stderr, "SCHED d_detail empty_windows=%llu\n",
        (unsigned long long)ew);
    // The causality split of d_detail. `pct_inter` is THE headline —
    // the share of empty spin windows that opened while NO dispatch was live,
    // i.e. while the single-threaded driver held the critical path.
    fprintf(stderr,
        "SCHED d_cause empty_inter=%llu empty_intra=%llu pct_inter=%.2f\n",
        (unsigned long long)ewi, (unsigned long long)ewa,
        (ew > 0) ? (100.0 * (double)ewi / (double)ew) : 0.0);
    fprintf(stderr,
        "SCHED e_detail found_windows=%llu avg_ns_per_found_window=%llu\n",
        (unsigned long long)fw,
        (unsigned long long)((fw > 0) ? (e / fw) : 0));
    fprintf(stderr,
        "SCHED driver_view fork_ns=%llu inter_gap_ns=%llu seg_count=%llu\n",
        (unsigned long long)fork, (unsigned long long)inter,
        (unsigned long long)segs);
    // PER-THREAD WALL — THE ONLY DENOMINATOR THAT CONTAINS A DRIVER-SERIAL
    // NUMERATOR.
    //
    // `total` is attributed wall summed over `nworkers` threads, so the wall of
    // the RUN is `total / nworkers`. A driver-serial window is single-threaded
    // and is a sub-interval of the run, so it is bounded by that quantity — the
    // containment relation a percentage requires. `inter` is NOT such a bound:
    // see the SCHED_SITE comment below for why, and the 132 committed
    // `pct_of_inter` readings above 100% (max 1.5e10%) for what happens when a
    // ratio is printed whose denominator does not contain its numerator.
    double wwd = (nworkers > 0 && total > 0)
        ? ((double)total / (double)nworkers) : 1.0;
    // Per-site call-site histogram. Only sites with a non-zero fork count are
    // printed; the rows partition the driver_view fork_ns + inter_gap_ns above.
    //
    // CLASS=SITE. Every row in this table is an INFERRED
    // attribution: the runtime knows only which forks FENCE a serial window, not
    // which code ran in it. `confirmed_frac` is now emitted in-band so a reader
    // cannot quote `inter_ns` as "site X's cost" without seeing how much of it
    // is actually confirmed. confirmed_frac == 1.00 -> the window is fenced by
    // two forks of THIS site and the attribution needs no further proof;
    // confirmed_frac == 0.00 -> EVERY gap straddles a handoff between two
    // DIFFERENT sites, and the honest report is the pre..post RANGE, not either
    // endpoint: the pre and post sums can differ several-fold while the
    // confirmed core is zero, and quoting either endpoint alone overstates it.
    fprintf(stderr, "SCHED_SITE_TABLE_BEGIN\n");
    for (uint32_t s = 0; s < KOMIRA_SCHED_MAXSITE; s++) {
        uint64_t sc = _sched_s_count[s];
        if (sc == 0) continue;
        uint64_t sf = _sched_s_fork_ns[s];
        uint64_t si = _sched_s_inter_ns[s];
        uint64_t tmn = _sched_s_task_min[s];
        uint64_t tmx = _sched_s_task_max[s];
        uint64_t tavg = _sched_s_task_sum[s] / sc;
        // `inter_ns` is the PRE-barrier (previous-fork) attribution kept
        // verbatim for series comparability; `inter_next_ns` is the POST-barrier
        // attribution of the same wall; `inter_same_ns` is the sub-part on which
        // the two AGREE (prev==next==s -> the window is fenced by two forks of
        // THIS site, so this driver owns it — no bracket needed to believe it).
        uint64_t sin = _sched_s_inter_next_ns[s];
        uint64_t ssm = _sched_s_inter_same_ns[s];
        // confirmed_frac = same / max(pre, post). Emitted IN-BAND so the
        // ambiguity travels with the number instead of living in a separate
        // diagnostic a quoter can skip.
        uint64_t sden = (si > sin) ? si : sin;
        double scf = (sden > 0) ? ((double)ssm / (double)sden) : 0.0;
        // IN-BAND OCCUPANCY. span_avg = the time-weighted average
        // number of workers concurrently busy inside this site's forks;
        // occupancy = span_avg / task_avg, i.e. the fraction of the fan the fork
        // actually used. A site with no occupancy sample prints span_avg=-1
        // occupancy=-1 (NOT 0.00 — "unmeasured" and "idle" are different
        // findings, and a 0 that meant "no sample" would be misread).
        uint64_t sbz = _sched_s_busy_ns[s];
        uint64_t sos = _sched_s_occ_span_ns[s];
        uint64_t soc = _sched_s_occ_ct[s];
        double span_avg = -1.0, occ = -1.0;
        if (soc > 0 && sos > 0) {
            span_avg = (double)sbz / (double)sos;
            occ = (tavg > 0) ? (span_avg / (double)tavg) : -1.0;
        }
        fprintf(stderr,
            "SCHED_SITE class=SITE id=%u name=%s count=%llu fork_ns=%llu "
            "inter_ns=%llu task_min=%llu task_max=%llu task_avg=%llu "
            "inter_next_ns=%llu inter_same_ns=%llu confirmed_frac=%.2f "
            "pre_pct_of_worker_wall=%.2f post_pct_of_worker_wall=%.2f "
            "same_pct_of_worker_wall=%.2f "
            "busy_ns=%llu occ_span_ns=%llu occ_count=%llu "
            "span_avg=%.3f occupancy=%.4f%s\n",
            s, _sched_site_name(s), (unsigned long long)sc,
            (unsigned long long)sf, (unsigned long long)si,
            (unsigned long long)tmn, (unsigned long long)tmx,
            (unsigned long long)tavg,
            (unsigned long long)sin, (unsigned long long)ssm, scf,
            100.0 * (double)si / wwd, 100.0 * (double)sin / wwd,
            100.0 * (double)ssm / wwd,
            (unsigned long long)sbz, (unsigned long long)sos,
            (unsigned long long)soc, span_avg, occ,
            // The store-lag artifact, NAMED rather than clamped. See the
            // occupancy block's third warning: a short fork after a long one
            // can be credited with the previous fork's tail.
            (occ > 1.05) ? " occ_lag=1" : "");
    }
    fprintf(stderr, "SCHED_SITE_TABLE_END\n");
    // =========================================================================
    // ★ PER-FORK ROWS — the de-conflation the table above structurally cannot do
    // =========================================================================
    // The SITE table sums busy/span over every fork at a site. Where one site id
    // is stamped by several call sites (one site can fire several times per rep)
    // its occupancy is an average over forks of different sizes and different
    // jobs, and NO reading of it can say which fork owns the idle. These rows can.
    //
    // `span_avg` = busy_ns / span_ns  (average workers concurrently busy)
    // `occupancy` = span_avg / tasks  (fraction of the posted fan actually used)
    // -1 for both means the fork carried NO occupancy sample — "unmeasured", not
    // "idle"; the two are different findings, and a 0 there would read as the
    // second.
    //
    // `tag` is the CALL SITE, stamped by the caller
    // (`komira_sched_set_fork_note`); `tag=0 name=unlabeled` means no caller
    // stamped this fork, which is true of every fork whose site has only one
    // dispatch and needs no tag. `note_mismatch=1` on a row means a note was
    // consumed by a fork of a different site than the note named — the row is
    // reported UNLABELLED and the header's counts say how often that happened.
    {
        uint64_t fn = _sched_fk_n;
        uint64_t fkept = (fn < (uint64_t)KOMIRA_SCHED_FORKS)
                             ? fn : (uint64_t)KOMIRA_SCHED_FORKS;
        fprintf(stderr,
            "SCHED_FORKS_BEGIN forks=%llu kept=%llu dropped=%llu cap=%d"
            " notes_set=%llu notes_used=%llu notes_mismatched=%llu"
            " notes_overwritten=%llu"
            " (FIRST-N, not a wrap: the per-rep fork sequence repeats and the"
            " head contains it. PER FORK, never per morsel.)\n",
            (unsigned long long)fn, (unsigned long long)fkept,
            (unsigned long long)(fn - fkept), KOMIRA_SCHED_FORKS,
            (unsigned long long)_sched_fk_note_set,
            (unsigned long long)_sched_fk_note_used,
            (unsigned long long)_sched_fk_note_mismatch,
            (unsigned long long)_sched_fk_note_dropped);
        for (uint64_t i = 0; i < fkept; i++) {
            uint64_t fsp = _sched_fk_span_ns[i];
            uint64_t fbz = _sched_fk_busy_ns[i];
            uint64_t ftk = _sched_fk_tasks[i];
            uint64_t ffl = _sched_fk_flags[i];
            double fsa = -1.0, foc = -1.0;
            if (!(ffl & 1u) && fsp > 0) {
                fsa = (double)fbz / (double)fsp;
                foc = (ftk > 0) ? (fsa / (double)ftk) : -1.0;
            }
            fprintf(stderr,
                "SCHED_FORK i=%llu site=%llu name=%s tag=%llu tag_name=%s"
                " tasks=%llu span_ns=%llu busy_ns=%llu inter_ns=%llu"
                " t0_rel_ns=%llu units=%llu rows=%llu"
                " span_avg=%.3f occupancy=%.4f%s%s\n",
                (unsigned long long)i,
                (unsigned long long)_sched_fk_site[i],
                _sched_site_name((uint32_t)_sched_fk_site[i]),
                (unsigned long long)_sched_fk_tag[i],
                _sched_fork_tag_name((uint32_t)_sched_fk_tag[i]),
                (unsigned long long)ftk, (unsigned long long)fsp,
                (unsigned long long)fbz,
                (unsigned long long)_sched_fk_inter_ns[i],
                (unsigned long long)_sched_fk_t0_ns[i],
                (unsigned long long)_sched_fk_units[i],
                (unsigned long long)_sched_fk_rows[i],
                fsa, foc,
                (ffl & 2u) ? " note_mismatch=1" : "",
                (foc > 1.05) ? " occ_lag=1" : "");
        }
        fprintf(stderr, "SCHED_FORKS_END\n");
    }
    // TRANSITION MATRIX. One row per (prev_site -> next_site) pair that
    // carried driver-serial wall. `prev == next` rows are CONFIRMED-own windows;
    // `prev != next` rows straddle a driver handoff (tail of prev + head of next)
    // and are the ONLY rows that need an explicit bracket to split. This is the
    // instrument that says WHICH handoff a "did not close" residual lives in.
    fprintf(stderr, "SCHED_TRANS_TABLE_BEGIN\n");
    for (uint32_t p = 0; p < KOMIRA_SCHED_MAXSITE; p++) {
        for (uint32_t n = 0; n < KOMIRA_SCHED_MAXSITE; n++) {
            if (_sched_t_ct[p][n] == 0) continue;
            fprintf(stderr,
                "SCHED_TRANS prev=%u prev_name=%s next=%u next_name=%s "
                "gap_ns=%llu count=%llu same=%d\n",
                p, _sched_site_name(p), n, _sched_site_name(n),
                (unsigned long long)_sched_t_ns[p][n],
                (unsigned long long)_sched_t_ct[p][n], (p == n) ? 1 : 0);
        }
    }
    fprintf(stderr, "SCHED_TRANS_TABLE_END\n");
    // NAMED SERIAL-PHASE TABLE. Explicit driver brackets around named
    // serial regions. serial_ns = wall_ns - fork_ns is the fork-excluded residue.
    // `named_serial_ns` vs `inter_gap_ns` is the coverage bridge: how much of the
    // corpus's whole driver-serial wall is now attributed to NAMED code.
    {
        uint64_t named_serial = 0;
        fprintf(stderr, "SCHED_PHASE_TABLE_BEGIN\n");
        for (uint32_t p = 1; p < KOMIRA_SCHED_MAXPHASE; p++) {
            uint64_t pc = _sched_ph_count[p];
            if (pc == 0) continue;
            uint64_t pw = _sched_ph_wall_ns[p];
            uint64_t pf = _sched_ph_fork_ns[p];
            uint64_t ps = (pw > pf) ? (pw - pf) : 0;
            // NESTED SUB-PHASES ARE EXCLUDED FROM THE COVERAGE SUM.
            // Every phase up to id 10 brackets a DISJOINT region, so summing
            // their serial residues is a partition. Ids 11/12 are different:
            // they are recorded INSIDE `extract_join_key_columns_typed`, i.e.
            // inside the regions ids 6 and 7 already bracket, and adding them
            // double-counts: coverage could print well over 100% of the
            // inter-gap, which is not a coverage number at all. A metric that
            // can exceed 100% of its own denominator misleads whoever reads
            // it; the rows still print (they are the whole point of the
            // split), they just do not accrue to the bridge.
            // A new id belongs in this list IFF it brackets a region already
            // covered by another id.
            if (!_sched_phase_is_nested(p)) named_serial += ps;
            // There is deliberately NO `serial_pct_of_inter` on this row. It
            // would divide a bracket's serial residue by the GLOBAL
            // driver-serial gap, and a bracket that nests forks of a DIFFERENT
            // site has its serial wall charged to THAT site's inter-gap, so
            // numerator and denominator would describe disjoint sets of wall
            // and the ratio would be unbounded (thousands of percent). A label
            // saying "not a wall share" does not stop such a number being
            // quoted; removing it does, the same way the coverage bridge
            // directly below keeps itself under 100% by EXCLUDING nested
            // phases from the sum.
            // bracket the scheduler was told about that ran with zero
            // parallelism (see the SCHED_UNDISPATCHED block).
            const char *unit = _sched_phase_unit(p);
            char nbuf[96];
            nbuf[0] = '\0';
            if (unit != NULL) {
                snprintf(nbuf, sizeof(nbuf), " n=%llu unit=%s",
                         (unsigned long long)_sched_ph_n[p], unit);
            }
            // ★ OCCUPANCY. Printed ONLY for a bracket whose site recorded a
            // CPU-time delta; a bracket that recorded none prints no field at
            // all, because `occ=0.00` would read as "the driver was parked"
            // when it means "nobody measured". `recoverable_ns` is the whole
            // point: `serial_ns * occ` is the ceiling a perfect fan-out could
            // take, and it is what a lever must be sized against — NOT
            // `serial_ns`, which assumes occ == 1.
            char obuf[128];
            obuf[0] = '\0';
            if (_sched_ph_cpu_ns[p] > 0 && pw > 0) {
                double occ = (double)_sched_ph_cpu_ns[p] / (double)pw;
                snprintf(obuf, sizeof(obuf),
                         " cpu_ns=%llu occ=%.4f recoverable_ns=%llu",
                         (unsigned long long)_sched_ph_cpu_ns[p], occ,
                         (unsigned long long)((double)ps * (occ > 1.0 ? 1.0
                                                                     : occ)));
            }
            fprintf(stderr,
                "SCHED_PHASE class=BRACKET id=%u name=%s count=%llu "
                "wall_ns=%llu fork_ns=%llu serial_ns=%llu "
                "serial_pct_of_worker_wall=%.2f%s%s%s%s\n",
                p, _sched_phase_name(p), (unsigned long long)pc,
                (unsigned long long)pw, (unsigned long long)pf,
                (unsigned long long)ps,
                100.0 * (double)ps / wwd,
                (pf == 0 && pw > 0) ? " undispatched=1" : "",
                _sched_phase_is_nested(p) ? " nested=1" : "",
                nbuf, obuf);
        }
        // COVERAGE — how much of the process's driver-serial wall is now
        // attributed to NAMED code. This looks like the one legitimate
        // inter-relative ratio (both sides are whole-process driver-serial
        // totals), but it is NOT: a bracket that runs
        // BEFORE the first fork or AFTER the last is driver-serial wall that sits
        // in NO inter-gap, so `named_serial` is not a subset of `inter`, and the
        // ratio can exceed 100%.
        //
        // So the number is WITHHELD rather than labelled, which is the same rule
        // the retired `serial_pct_of_inter` is being held to: `named > inter` is
        // a STRUCTURAL finding (brackets cover time outside every fork gap), and
        // the honest report of a structural finding is the finding, not a
        // percentage with a caveat beside it. Both absolutes always print, so
        // nothing is hidden — only the misleading ratio is.
        if (named_serial <= inter) {
            fprintf(stderr,
                "SCHED_PHASE_COVERAGE named_serial_ns=%llu inter_gap_ns=%llu "
                "pct=%.2f valid=1\n",
                (unsigned long long)named_serial, (unsigned long long)inter,
                (inter > 0)
                    ? (100.0 * (double)named_serial / (double)inter) : 0.0);
        } else {
            fprintf(stderr,
                "SCHED_PHASE_COVERAGE named_serial_ns=%llu inter_gap_ns=%llu "
                "pct_withheld=1 valid=0 reason=named_serial_exceeds_inter_gap"
                "(brackets cover driver-serial wall outside every fork gap)\n",
                (unsigned long long)named_serial, (unsigned long long)inter);
        }
        fprintf(stderr, "SCHED_PHASE_TABLE_END\n");
    }
    // =========================================================================
    // SCHED REGION TABLE — the DISJOINT partition
    // =========================================================================
    // Unlike SCHED_PHASE above, these rows carry `self_ns` measured from an
    // OBSERVED nest stack, so summing self_ns over the driver partition is a
    // partition of the root's wall — no `_sched_phase_is_nested` list, and no
    // way for a new bracket to double-count. The header line carries everything
    // the report needs to REFUSE rather than print a wrong number.
    {
        fprintf(stderr, "SCHED_REGION_TABLE_BEGIN\n");
        uint32_t root = __atomic_load_n(&_sched_rg_root_id, __ATOMIC_RELAXED);
        uint64_t misnest = __atomic_load_n(&_sched_rg_misnest, __ATOMIC_RELAXED);
        uint64_t overflow = __atomic_load_n(&_sched_rg_overflow, __ATOMIC_RELAXED);
        uint64_t orphan = __atomic_load_n(&_sched_rg_orphan, __ATOMIC_RELAXED);
        uint64_t dsamp = __atomic_load_n(&_sched_rg_driver_samples, __ATOMIC_RELAXED);
        uint64_t wsamp = __atomic_load_n(&_sched_rg_worker_samples, __ATOMIC_RELAXED);
        uint64_t root_wall = (root != 0) ? _sched_rg_wall_ns[root] : 0;
        uint64_t root_self = (root != 0) ? _sched_rg_self_ns[root] : 0;
        // The partition is VALID only when the stack unwound cleanly and a root
        // was declared. `misnest` is the ASAP-destruction detector; without a
        // root there is no denominator and no UNATTRIBUTED term, so the rows are
        // individually true but do not add up to anything.
        int valid = (misnest == 0 && orphan == 0 && overflow == 0 && root != 0
                     && root_wall > 0);
        fprintf(stderr,
            "SCHED_REGION_HEADER root_id=%u root_name=%s root_wall_ns=%llu "
            "unattributed_ns=%llu misnest=%llu overflow=%llu orphan=%llu "
            "driver_tid_samples=%llu worker_tid_samples=%llu "
            "maxphase=%d partition_valid=%d\n",
            root, (root != 0) ? _sched_phase_name(root) : "none",
            (unsigned long long)root_wall, (unsigned long long)root_self,
            (unsigned long long)misnest, (unsigned long long)overflow,
            (unsigned long long)orphan,
            (unsigned long long)dsamp, (unsigned long long)wsamp,
            KOMIRA_SCHED_MAXPHASE, valid);
        uint64_t self_sum = 0;
        for (uint32_t p = 1; p < KOMIRA_SCHED_MAXPHASE; p++) {
            uint64_t rc = _sched_rg_count[p];
            uint64_t rcw = _sched_rg_count_w[p];
            if (rc == 0 && rcw == 0) continue;
            if (rc > 0) {
                uint64_t rw = _sched_rg_wall_ns[p];
                uint64_t rs = _sched_rg_self_ns[p];
                self_sum += rs;
                const char *unit = _sched_phase_unit(p);
                char nbuf[96];
                nbuf[0] = '\0';
                if (unit != NULL) {
                    snprintf(nbuf, sizeof(nbuf), " n=%llu unit=%s",
                             (unsigned long long)_sched_rg_n[p], unit);
                }
                fprintf(stderr,
                    "SCHED_REGION class=REGION part=DRIVER id=%u name=%s "
                    "count=%llu wall_ns=%llu self_ns=%llu fork_ns=%llu "
                    "depth_max=%llu self_pct_of_root=%.2f%s%s\n",
                    p, _sched_phase_name(p), (unsigned long long)rc,
                    (unsigned long long)rw, (unsigned long long)rs,
                    (unsigned long long)_sched_rg_fork_ns[p],
                    (unsigned long long)_sched_rg_depth_max[p],
                    (root_wall > 0) ? (100.0 * (double)rs / (double)root_wall) : 0.0,
                    (p == root) ? " is_root=1" : "", nbuf);
            }
            if (rcw > 0) {
                // WORKER partition — printed, never summed into the driver
                // total. Concurrent wall across N threads is not comparable to
                // a single-threaded driver's, and adding them is how a
                // "share of runtime" exceeds 100%.
                fprintf(stderr,
                    "SCHED_REGION class=REGION part=WORKER id=%u name=%s "
                    "count=%llu wall_ns=%llu self_ns=%llu\n",
                    p, _sched_phase_name(p), (unsigned long long)rcw,
                    (unsigned long long)__atomic_load_n(&_sched_rg_wall_ns_w[p], __ATOMIC_RELAXED),
                    (unsigned long long)__atomic_load_n(&_sched_rg_self_ns_w[p], __ATOMIC_RELAXED));
            }
        }
        // CLOSURE CHECK. Over the driver partition, sum(self_ns) must equal the
        // root's wall exactly — every nanosecond inside the root is charged to
        // exactly one region, and the root's own self_ns is the UNATTRIBUTED
        // residue. Printing the residual makes the invariant falsifiable from
        // the dump text alone; the report asserts it and exits 1 if it fails.
        long long closure = (long long)root_wall - (long long)self_sum;
        fprintf(stderr,
            "SCHED_REGION_CLOSURE root_wall_ns=%llu self_sum_ns=%llu "
            "residual_ns=%lld exact=%d\n",
            (unsigned long long)root_wall, (unsigned long long)self_sum,
            closure, (root_wall > 0 && closure == 0) ? 1 : 0);
        fprintf(stderr, "SCHED_REGION_TABLE_END\n");
    }
    // =========================================================================
    // SCHED REGION DECLARED — every declared phase, INCLUDING the ones that
    // never fired
    // =========================================================================
    // The region table above prints a row only when `count > 0`, so a phase that
    // never ran is INVISIBLE and a phase nobody ever wired is invisible in
    // exactly the same way — a counter whose only caller sits on a route the
    // query never takes, or a field name no emitter ever writes — so the phase
    // list is printed UNCONDITIONALLY here, with the three states separated:
    //
    //     wired=0                  no non-test call site opens this phase. The
    //                              counter DOES NOT EXIST yet; a zero from it is
    //                              not a measurement. (Derived at GENERATION
    //                              time and recorded in the label table.)
    //     wired=1 count=0          the phase exists and this run never entered
    //                              it. Correct for a cell whose plan has no such
    //                              operator; a DEFECT for one that should.
    //     wired=1 count>0 self=0   it ran and cost nothing. A real measurement.
    //
    // Cost: one pass over MAXPHASE at process exit, on the trace-on path only.
    {
        fprintf(stderr, "SCHED_REGION_DECLARED_BEGIN\n");
        uint64_t n_decl = 0, n_wired = 0, n_fired = 0, n_dark = 0;
        for (uint32_t p = 1; p < KOMIRA_SCHED_MAXPHASE; p++) {
            if (!_sched_phase_declared(p)) continue;
            n_decl++;
            int wired = _sched_phase_wired(p);
            uint64_t rc = _sched_rg_count[p];
            uint64_t rcw = _sched_rg_count_w[p];
            uint64_t bc = _sched_ph_count[p];   /* legacy bracket, not a region */
            if (wired) n_wired++;
            if (rc + rcw + bc > 0) n_fired++;
            if (wired && (rc + rcw + bc) == 0) n_dark++;
            fprintf(stderr,
                "SCHED_REGION_DECLARED id=%u name=%s wired=%d region_count=%llu "
                "region_count_worker=%llu bracket_count=%llu\n",
                p, _sched_phase_name(p), wired,
                (unsigned long long)rc, (unsigned long long)rcw,
                (unsigned long long)bc);
        }
        fprintf(stderr,
            "SCHED_REGION_DECLARED_SUMMARY declared=%llu wired=%llu fired=%llu "
            "wired_but_dark=%llu\n",
            (unsigned long long)n_decl, (unsigned long long)n_wired,
            (unsigned long long)n_fired, (unsigned long long)n_dark);
        fprintf(stderr, "SCHED_REGION_DECLARED_END\n");
    }
    // =========================================================================
    // SCHED OPWAVE — the SCAN / OPERATOR split inside one fused fork
    // =========================================================================
    // See the storage block's header for the subtraction and for why `present`
    // and `absent` are recorded. `scan_ns` is SIGNED and never clamped.
    {
        fprintf(stderr, "SCHED_OPWAVE_TABLE_BEGIN\n");
        uint64_t rows_any = 0;
        for (uint32_t s = 0; s < KOMIRA_SCHED_MAXSITE; s++) {
            uint64_t c = _sched_ow_count[s];
            if (c == 0) continue;
            rows_any++;
            uint64_t busy = _sched_ow_busy_ns[s];
            uint64_t opns = _sched_ow_op_ns[s];
            long long scan = (long long)busy - (long long)opns;
            double op_pct = (busy > 0) ? (100.0 * (double)opns / (double)busy) : -1.0;
            uint64_t pres = _sched_ow_present[s];
            uint64_t abst = _sched_ow_absent[s];
            fprintf(stderr,
                "SCHED_OPWAVE class=WAVE id=%u name=%s count=%llu "
                "busy_ns=%llu op_ns=%llu scan_ns=%lld op_pct_of_busy=%.2f "
                "rows_in=%llu rows_out=%llu workers=%llu "
                "metric_present=%llu metric_absent=%llu\n",
                s, _sched_site_name(s), (unsigned long long)c,
                (unsigned long long)busy, (unsigned long long)opns, scan,
                op_pct, (unsigned long long)_sched_ow_rows_in[s],
                (unsigned long long)_sched_ow_rows_out[s],
                (unsigned long long)_sched_ow_workers[s],
                (unsigned long long)pres, (unsigned long long)abst);
        }
        // An EMPTY table is a finding, not an absence of one: it means no
        // op-bearing wave ran (or the driver that runs them was not rebuilt).
        // Said in band so a grep for the row does not come back silent.
        fprintf(stderr, "SCHED_OPWAVE_SUMMARY sites_with_waves=%llu\n",
                (unsigned long long)rows_any);
        fprintf(stderr, "SCHED_OPWAVE_TABLE_END\n");
    }
    // The msink DRIVER-SERIAL combine-phase
    // split of the SITE_SINK_EXECUTOR(id 8) inter-gap. drain+combine+finalize is
    // the recoverable-by-parallelizing share; the residual is handoff/sequencing
    // (prepare_finalize, num_partitions, states_for_combine alloc, return-up-stack,
    // next-breaker setup) that a parallel combine cannot touch. combine_ns alone
    // is the specific target (parallelize sink.combine via combine_lib);
    // finalize_ns is a SEPARATE potential lever surfaced for the decision.
    {
        uint64_t md   = __atomic_load_n(&_sched_msink_drain_ns, __ATOMIC_RELAXED);
        uint64_t mcw  = __atomic_load_n(&_sched_msink_combine_wall_ns, __ATOMIC_RELAXED);
        uint64_t mcf  = __atomic_load_n(&_sched_msink_combine_fork_ns, __ATOMIC_RELAXED);
        uint64_t mfw  = __atomic_load_n(&_sched_msink_finalize_wall_ns, __ATOMIC_RELAXED);
        uint64_t mff  = __atomic_load_n(&_sched_msink_finalize_fork_ns, __ATOMIC_RELAXED);
        uint64_t mpc  = __atomic_load_n(&_sched_msink_phase_count, __ATOMIC_RELAXED);
        uint64_t mst  = __atomic_load_n(&_sched_msink_setup_ns, __ATOMIC_RELAXED);
        uint64_t mpr  = __atomic_load_n(&_sched_msink_prepare_ns, __ATOMIC_RELAXED);
        uint64_t mprf = __atomic_load_n(&_sched_msink_prepare_fork_ns, __ATOMIC_RELAXED);
        uint64_t mtd  = __atomic_load_n(&_sched_msink_teardown_ns, __ATOMIC_RELAXED);
        // The containing set for every phase row below.
        uint64_t cum_driver_wall =
            __atomic_load_n(&_sched_msink_driver_wall_ns, __ATOMIC_RELAXED);
        uint64_t msink_inter = _sched_s_inter_ns[8];  // SITE_SINK_EXECUTOR
        // SERIAL = fork-excluded driver-serial residue (the recoverable part).
        uint64_t mcs = (mcw > mcf) ? (mcw - mcf) : 0;  // combine serial residue
        uint64_t mfs = (mfw > mff) ? (mfw - mff) : 0;  // finalize serial residue
        uint64_t mps = (mpr > mprf) ? (mpr - mprf) : 0; // prepare serial residue
        uint64_t serial = md + mcs + mfs;              // total recoverable driver-serial
        // The NAMED span of the site-8 inter-gap is
        // drain + combine_serial + finalize_serial + prepare + teardown. SETUP is
        // deliberately EXCLUDED here -- it precedes site 8's own fork, so it lands
        // in the PREVIOUS site's inter-gap, not this one (it is reported on its own
        // line below). What is left after subtracting the named span is the TRUE
        // unattributed residual: the walker/plan return-up-stack + the next
        // breaker's pre-setup, i.e. work that does NOT belong to this driver.
        // PREPARE contributes its fork-EXCLUDED residue (mps), not its wall. Using
        // the wall here is what let `named` exceed the inter-gap it partitions,
        // silently clamping `handoff` to 0 and reporting "0 unattributed" on a
        // query whose gap was in fact mostly unattributed.
        uint64_t named = serial + mps + mtd;
        uint64_t handoff = (msink_inter > named) ? (msink_inter - named) : 0;
        // `gd` (= site-8 inter_ns) is NOT a denominator for these phase rows,
        // because it does not contain them: a finalize bracket that NESTS
        // another site's forks has the serial wall interleaved with those forks
        // charged to THAT site's inter-gap, never to site 8's, so dividing by
        // site 8's gap can print hundreds of percent.
        //
        // Charging the gap FORWARD instead (post-barrier attribution) does not
        // fix it either: direction and containment are independent defects.
        //
        // The msink DRIVER WALL is a true containing set: setup/drain/combine/
        // prepare/finalize/teardown are disjoint sequential sub-intervals of it
        // (the `phases_le_wall` invariant below). It is already measured, and
        // already printed in SCHED_MSINK_WALL_ATTR.
        double gd = (cum_driver_wall > 0) ? (double)cum_driver_wall : 1.0;
        fprintf(stderr, "SCHED_MSINK_PHASE_BEGIN\n");
        fprintf(stderr,
            "SCHED_MSINK phase_count=%llu msink_inter_gap_ns=%llu "
            "driver_wall_ns=%llu\n",
            (unsigned long long)mpc, (unsigned long long)msink_inter,
            (unsigned long long)cum_driver_wall);
        // WALL vs FORK vs SERIAL(recoverable) for the two forking phases.
        // `undispatched=1` == fork_ns 0 with wall > 0 (see SCHED_UNDISPATCHED).
        fprintf(stderr,
            "SCHED_MSINK class=BRACKET combine wall_ns=%llu fork_ns=%llu "
            "serial_ns=%llu serial_pct_of_driver_wall=%.2f%s\n",
            (unsigned long long)mcw, (unsigned long long)mcf,
            (unsigned long long)mcs, 100.0 * (double)mcs / gd,
            (mcf == 0 && mcw > 0) ? " undispatched=1" : "");
        // ★ OCCUPANCY on finalize — see the SCHED_PHASE printer above. The
        // finalize serial residue is the largest named item in 8 of the 9
        // join-cluster cells and is `bound=upper` without this field.
        {
            uint64_t mfc =
                __atomic_load_n(&_sched_msink_finalize_cpu_ns, __ATOMIC_RELAXED);
            char obuf[128];
            obuf[0] = '\0';
            if (mfc > 0 && mfw > 0) {
                double occ = (double)mfc / (double)mfw;
                snprintf(obuf, sizeof(obuf),
                         " cpu_ns=%llu occ=%.4f recoverable_ns=%llu",
                         (unsigned long long)mfc, occ,
                         (unsigned long long)((double)mfs * (occ > 1.0 ? 1.0
                                                                      : occ)));
            }
            fprintf(stderr,
                "SCHED_MSINK class=BRACKET finalize wall_ns=%llu fork_ns=%llu "
                "serial_ns=%llu serial_pct_of_driver_wall=%.2f%s%s\n",
                (unsigned long long)mfw, (unsigned long long)mff,
                (unsigned long long)mfs, 100.0 * (double)mfs / gd,
                (mff == 0 && mfw > 0) ? " undispatched=1" : "", obuf);
        }
        fprintf(stderr,
            "SCHED_MSINK class=BRACKET drain_ns=%llu (serial) "
            "pct_of_driver_wall=%.2f\n",
            (unsigned long long)md, 100.0 * (double)md / gd);
        // ★ PER-INVOCATION ROWS — the answer to "which sink", which the sums
        // above structurally cannot give. See `_sched_msink_run_*`.
        {
            uint64_t rn = __atomic_load_n(&_sched_msink_run_n, __ATOMIC_RELAXED);
            uint64_t kept = (rn < (uint64_t)KOMIRA_SCHED_MSINK_RUNS)
                                ? rn
                                : (uint64_t)KOMIRA_SCHED_MSINK_RUNS;
            fprintf(stderr,
                "SCHED_MSINK_RUNS_BEGIN invocations=%llu kept=%llu dropped=%llu"
                " (FIRST-N, not a wrap: the per-rep pattern repeats and the"
                " head of the sequence contains it)\n",
                (unsigned long long)rn, (unsigned long long)kept,
                (unsigned long long)(rn - kept));
            for (uint64_t i = 0; i < kept; i++) {
                uint64_t fw = _sched_msink_run_fin_wall[i];
                uint64_t ff = _sched_msink_run_fin_fork[i];
                uint64_t fc = _sched_msink_run_fin_cpu[i];
                uint64_t fs = (fw > ff) ? (fw - ff) : 0;
                char obuf[64];
                obuf[0] = '\0';
                if (fc > 0 && fw > 0) {
                    snprintf(obuf, sizeof(obuf), " fin_occ=%.4f",
                             (double)fc / (double)fw);
                }
                fprintf(stderr,
                    "SCHED_MSINK_RUN i=%llu label=%s fin_wall_ns=%llu"
                    " fin_fork_ns=%llu fin_serial_ns=%llu fin_cpu_ns=%llu"
                    " comb_wall_ns=%llu comb_fork_ns=%llu driver_wall_ns=%llu"
                    "%s%s\n",
                    (unsigned long long)i, _sched_msink_run_label[i],
                    (unsigned long long)fw, (unsigned long long)ff,
                    (unsigned long long)fs, (unsigned long long)fc,
                    (unsigned long long)_sched_msink_run_comb_wall[i],
                    (unsigned long long)_sched_msink_run_comb_fork[i],
                    (unsigned long long)_sched_msink_run_driver_wall[i],
                    (ff == 0 && fw > 0) ? " undispatched=1" : "", obuf);
            }
            fprintf(stderr, "SCHED_MSINK_RUNS_END\n");
        }
        // PREPARE = num_partitions + the `_drive_combine_partition` FORK +
        // prepare_finalize. It forks (site_id=SITE_SINK_EXECUTOR) whenever
        // num_partitions() > 1, so it is reported wall/fork/serial like the two
        // phases above — NOT under a `(serial)` label. TEARDOWN (Finished-arm
        // guard + output take + FinalizeOutput drop) contains no dispatch and IS
        // pure driver-serial, so wall == serial there.
        fprintf(stderr,
            "SCHED_MSINK class=BRACKET prepare wall_ns=%llu fork_ns=%llu "
            "serial_ns=%llu serial_pct_of_driver_wall=%.2f%s\n",
            (unsigned long long)mpr, (unsigned long long)mprf,
            (unsigned long long)mps, 100.0 * (double)mps / gd,
            (mprf == 0 && mpr > 0) ? " undispatched=1" : "");
        fprintf(stderr,
            "SCHED_MSINK class=BRACKET teardown_ns=%llu (serial) "
            "pct_of_driver_wall=%.2f\n",
            (unsigned long long)mtd, 100.0 * (double)mtd / gd);
        // SETUP sits in the PREVIOUS site's inter-gap (it runs before site 8 forks),
        // so it is NOT part of gd — reported as an absolute + a share of the msink
        // driver wall in the WALL_ATTR block below.
        fprintf(stderr,
            "SCHED_MSINK setup_ns=%llu (serial, lands in PREVIOUS site inter-gap)\n",
            (unsigned long long)mst);
        // The decision partition of the msink DRIVER WALL:
        //   combine_serial | finalize_serial | drain | prepare | teardown.
        // The denominator is the containing set (the driver wall), so the
        // number on this line is quotable as printed. `unattributed` is not
        // part of the partition — it is a residual of the inter-gap, a
        // different window; the site-8 inter-gap accounting stays available on
        // the line below for anyone reconciling coverage.
        fprintf(stderr,
            "SCHED_MSINK PARTITION_OF_DRIVER_WALL combine_serial_pct=%.2f "
            "finalize_serial_pct=%.2f drain_pct=%.2f prepare_pct=%.2f "
            "teardown_pct=%.2f setup_pct=%.2f\n",
            100.0 * (double)mcs / gd, 100.0 * (double)mfs / gd,
            100.0 * (double)md / gd, 100.0 * (double)mps / gd,
            100.0 * (double)mtd / gd, 100.0 * (double)mst / gd);
        // `named_le_inter` is the honesty flag. A partition of the inter-gap whose
        // parts sum to MORE than the gap is not a partition — it means some phase
        // is charging parallel (or out-of-window) time to the driver. Read it
        // before reading any pct on the lines above; a 0 invalidates all of them.
        fprintf(stderr,
            "SCHED_MSINK recoverable_driver_serial_ns=%llu "
            "pct_of_driver_wall=%.2f named_inter_ns=%llu "
            "unattributed_residual_ns=%llu named_le_inter=%d\n",
            (unsigned long long)serial, 100.0 * (double)serial / gd,
            (unsigned long long)named, (unsigned long long)handoff,
            (named <= msink_inter) ? 1 : 0);
        fprintf(stderr, "SCHED_MSINK_PHASE_END\n");
    }
    // SCHED_MSINK per-run WALL attribution. The
    // PHASE block above reports phase shares of the driver-serial INTER-GAP; this
    // block reports each phase's share of the msink-driver WALL — the number a perf
    // decision MUST read (finalize's true wall lever, not the ~10x-inflated
    // inter-gap %). Two views: (1) `aggregate` = cumulative phase wall / cumulative
    // driver wall over ALL runs AND breakers — the iteration/breaker-count-invariant
    // headline (robust for multi-breaker queries, whose largest finalize can sit
    // in an earlier breaker, not the last); (2) `last_run` = a single-breaker
    // snapshot from the last invocation (exact when a query has ONE msink breaker).
    {
        uint64_t lw   = __atomic_load_n(&_sched_msink_last_driver_wall_ns, __ATOMIC_RELAXED);
        uint64_t ld   = __atomic_load_n(&_sched_msink_last_drain_ns, __ATOMIC_RELAXED);
        uint64_t lcw  = __atomic_load_n(&_sched_msink_last_combine_wall_ns, __ATOMIC_RELAXED);
        uint64_t lcf  = __atomic_load_n(&_sched_msink_last_combine_fork_ns, __ATOMIC_RELAXED);
        uint64_t lfw  = __atomic_load_n(&_sched_msink_last_finalize_wall_ns, __ATOMIC_RELAXED);
        uint64_t lff  = __atomic_load_n(&_sched_msink_last_finalize_fork_ns, __ATOMIC_RELAXED);
        uint64_t cum_w = __atomic_load_n(&_sched_msink_driver_wall_ns, __ATOMIC_RELAXED);
        uint64_t mpc2 = __atomic_load_n(&_sched_msink_phase_count, __ATOMIC_RELAXED);
        // Fork-excluded serial residues (the recoverable-by-parallelizing part),
        // for the last run.
        uint64_t lst  = __atomic_load_n(&_sched_msink_last_setup_ns, __ATOMIC_RELAXED);
        uint64_t lpr  = __atomic_load_n(&_sched_msink_last_prepare_ns, __ATOMIC_RELAXED);
        uint64_t lprf = __atomic_load_n(&_sched_msink_last_prepare_fork_ns, __ATOMIC_RELAXED);
        uint64_t ltd  = __atomic_load_n(&_sched_msink_last_teardown_ns, __ATOMIC_RELAXED);
        uint64_t lcs = (lcw > lcf) ? (lcw - lcf) : 0;   // combine serial residue
        uint64_t lfs = (lfw > lff) ? (lfw - lff) : 0;   // finalize serial residue
        uint64_t lps = (lpr > lprf) ? (lpr - lprf) : 0; // prepare serial residue
        // Recoverable driver-serial includes the three named
        // handoff sub-phases (setup is the biggest of the three on wide fan-outs —
        // it is eff_workers x sink.init_local() heap allocations, strictly serial).
        // PREPARE contributes its fork-EXCLUDED residue (lps). Using its WALL here
        // would report a partition-combine FORK as recoverable serial time.
        uint64_t lserial = lst + ld + lcs + lfs + lps + ltd;
        // setup, drain, combine, prepare, finalize, teardown are DISJOINT sequential
        // sub-intervals of the driver, so their walls sum to <= the driver wall (the
        // remainder is the streaming scan/agg fork span the driver waits on).
        // phases_le_wall is the sanity invariant.
        uint64_t lphase_wall = lst + ld + lcw + lpr + lfw + ltd;
        double wd = (lw > 0) ? (double)lw : 1.0;
        uint64_t avg_w = (mpc2 > 0) ? (cum_w / mpc2) : 0;
        // AGGREGATE wall share (cumulative phase wall over ALL runs AND ALL msink
        // breakers / cumulative driver wall). This is the PRIMARY number:
        // iteration- AND breaker-count-INVARIANT, so it is robust when a query has
        // multiple heterogeneous msink breakers (e.g. a sub-agg + a final
        // grouping) where the LAST invocation is NOT the dominant one.
        // The last_run snapshot below is exact only for a single-breaker query.
        uint64_t cd  = __atomic_load_n(&_sched_msink_drain_ns, __ATOMIC_RELAXED);
        uint64_t ccw = __atomic_load_n(&_sched_msink_combine_wall_ns, __ATOMIC_RELAXED);
        uint64_t ccf = __atomic_load_n(&_sched_msink_combine_fork_ns, __ATOMIC_RELAXED);
        uint64_t cfw = __atomic_load_n(&_sched_msink_finalize_wall_ns, __ATOMIC_RELAXED);
        uint64_t cff = __atomic_load_n(&_sched_msink_finalize_fork_ns, __ATOMIC_RELAXED);
        uint64_t cst = __atomic_load_n(&_sched_msink_setup_ns, __ATOMIC_RELAXED);
        uint64_t cpr = __atomic_load_n(&_sched_msink_prepare_ns, __ATOMIC_RELAXED);
        uint64_t cprf = __atomic_load_n(&_sched_msink_prepare_fork_ns, __ATOMIC_RELAXED);
        uint64_t cps = (cpr > cprf) ? (cpr - cprf) : 0;  // prepare serial (cumulative)
        uint64_t ctd = __atomic_load_n(&_sched_msink_teardown_ns, __ATOMIC_RELAXED);
        uint64_t ccs = (ccw > ccf) ? (ccw - ccf) : 0;  // combine serial (cumulative)
        uint64_t cfs = (cfw > cff) ? (cfw - cff) : 0;  // finalize serial (cumulative)
        double cwd = (cum_w > 0) ? (double)cum_w : 1.0;
        fprintf(stderr, "SCHED_MSINK_WALL_ATTR_BEGIN\n");
        fprintf(stderr,
            "SCHED_MSINK_WALL aggregate total_driver_wall_ns=%llu runs=%llu "
            "drain_pct_of_wall=%.2f combine_serial_pct_of_wall=%.2f "
            "finalize_serial_pct_of_wall=%.2f\n",
            (unsigned long long)cum_w, (unsigned long long)mpc2,
            100.0 * (double)cd / cwd, 100.0 * (double)ccs / cwd,
            100.0 * (double)cfs / cwd);
        // The three named handoff sub-phases, as WALL shares.
        // `prepare_pct_of_wall` is a WALL share and INCLUDES the partition-combine
        // fork; `prepare_serial_pct_of_wall` is the driver-serial part and is the
        // only one of the two a "parallelize this" decision may be funded on.
        fprintf(stderr,
            "SCHED_MSINK_WALL aggregate setup_pct_of_wall=%.2f "
            "prepare_pct_of_wall=%.2f prepare_serial_pct_of_wall=%.2f "
            "teardown_pct_of_wall=%.2f "
            "setup_ns=%llu prepare_ns=%llu prepare_fork_ns=%llu teardown_ns=%llu\n",
            100.0 * (double)cst / cwd, 100.0 * (double)cpr / cwd,
            100.0 * (double)cps / cwd,
            100.0 * (double)ctd / cwd,
            (unsigned long long)cst, (unsigned long long)cpr,
            (unsigned long long)cprf, (unsigned long long)ctd);
        fprintf(stderr,
            "SCHED_MSINK_WALL last_run driver_wall_ns=%llu phases_wall_ns=%llu "
            "phases_le_wall=%d\n",
            (unsigned long long)lw, (unsigned long long)lphase_wall,
            (lphase_wall <= lw) ? 1 : 0);
        fprintf(stderr,
            "SCHED_MSINK_WALL last_run drain_ns=%llu pct_of_wall=%.2f\n",
            (unsigned long long)ld, 100.0 * (double)ld / wd);
        fprintf(stderr,
            "SCHED_MSINK_WALL last_run combine_ns=%llu pct_of_wall=%.2f "
            "combine_serial_ns=%llu serial_pct_of_wall=%.2f\n",
            (unsigned long long)lcw, 100.0 * (double)lcw / wd,
            (unsigned long long)lcs, 100.0 * (double)lcs / wd);
        fprintf(stderr,
            "SCHED_MSINK_WALL last_run finalize_ns=%llu pct_of_wall=%.2f "
            "finalize_serial_ns=%llu serial_pct_of_wall=%.2f\n",
            (unsigned long long)lfw, 100.0 * (double)lfw / wd,
            (unsigned long long)lfs, 100.0 * (double)lfs / wd);
        fprintf(stderr,
            "SCHED_MSINK_WALL last_run setup_ns=%llu pct_of_wall=%.2f "
            "prepare_ns=%llu pct_of_wall=%.2f prepare_serial_ns=%llu "
            "serial_pct_of_wall=%.2f teardown_ns=%llu pct_of_wall=%.2f\n",
            (unsigned long long)lst, 100.0 * (double)lst / wd,
            (unsigned long long)lpr, 100.0 * (double)lpr / wd,
            (unsigned long long)lps, 100.0 * (double)lps / wd,
            (unsigned long long)ltd, 100.0 * (double)ltd / wd);
        fprintf(stderr,
            "SCHED_MSINK_WALL last_run recoverable_driver_serial_ns=%llu "
            "pct_of_wall=%.2f\n",
            (unsigned long long)lserial, 100.0 * (double)lserial / wd);
        fprintf(stderr,
            "SCHED_MSINK_WALL avg_over_runs driver_wall_ns=%llu runs=%llu\n",
            (unsigned long long)avg_w, (unsigned long long)mpc2);
        fprintf(stderr, "SCHED_MSINK_WALL_ATTR_END\n");
    }
    // =====================================================================
    // SCHED_UNDISPATCHED — THE STANDING fork_ns == 0 SIGNAL.
    //
    // A bracket with wall_ns > 0 and fork_ns == 0 ran with ZERO parallelism
    // inside a region the driver had already told the scheduler about. That is
    // the cheap discriminator between "serial by NECESSITY" and "serial because
    // NOBODY DISPATCHED IT". The same bracket can be almost entirely forked on
    // one query and entirely serial on another, so the serial is a property of
    // the query's routing, not of the code. Emitting it on every run makes it
    // non-optional to notice.
    //
    // LIMIT OF THIS SIGNAL — READ BEFORE ACTING ON IT. fork_ns == 0 says
    // the region was not parallelized; it does NOT say the driver was BUSY. A
    // window where the driver is PARKED (page faults, I/O, an untraced parallel
    // region) recovers nothing when dispatched, and the trace cannot currently
    // tell the two apart: a driver-serial window that is mostly off-CPU costs a
    // fraction of what its wall suggests. That occupancy factor is NOT yet
    // for every bracket — until it is, every row here is an UPPER BOUND, which
    // is why the block prints `occupancy=unknown` rather than omitting it.
    {
        uint64_t mcw = __atomic_load_n(&_sched_msink_combine_wall_ns, __ATOMIC_RELAXED);
        uint64_t mcf = __atomic_load_n(&_sched_msink_combine_fork_ns, __ATOMIC_RELAXED);
        uint64_t mfw = __atomic_load_n(&_sched_msink_finalize_wall_ns, __ATOMIC_RELAXED);
        uint64_t mff = __atomic_load_n(&_sched_msink_finalize_fork_ns, __ATOMIC_RELAXED);
        uint64_t mpr = __atomic_load_n(&_sched_msink_prepare_ns, __ATOMIC_RELAXED);
        uint64_t mprf = __atomic_load_n(&_sched_msink_prepare_fork_ns, __ATOMIC_RELAXED);
        uint64_t mst = __atomic_load_n(&_sched_msink_setup_ns, __ATOMIC_RELAXED);
        int n_und = 0;
        uint64_t und_ns = 0;
        fprintf(stderr, "SCHED_UNDISPATCHED_BEGIN occupancy=unknown\n");
        for (uint32_t p = 1; p < KOMIRA_SCHED_MAXPHASE; p++) {
            if (_sched_ph_count[p] == 0) continue;
            uint64_t pw = _sched_ph_wall_ns[p];
            if (pw == 0 || _sched_ph_fork_ns[p] != 0) continue;
            if (_sched_phase_is_nested(p)) continue;  /* would double-count */
            n_und++;
            und_ns += pw;
            fprintf(stderr,
                "SCHED_UNDISPATCHED phase name=%s count=%llu serial_ns=%llu "
                "pct_of_worker_wall=%.2f upper_bound=1\n",
                _sched_phase_name(p), (unsigned long long)_sched_ph_count[p],
                (unsigned long long)pw, 100.0 * (double)pw / wwd);
        }
        /* The msink brackets are not in the phase table; check them by hand. */
        #define KOMIRA_UND_MSINK(nm, w, f)                                   \
            if ((w) > 0 && (f) == 0) {                                        \
                n_und++; und_ns += (w);                                       \
                fprintf(stderr,                                               \
                    "SCHED_UNDISPATCHED msink name=%s serial_ns=%llu "        \
                    "pct_of_worker_wall=%.2f upper_bound=1\n",                \
                    (nm), (unsigned long long)(w), 100.0 * (double)(w) / wwd); \
            }
        KOMIRA_UND_MSINK("combine", mcw, mcf)
        KOMIRA_UND_MSINK("finalize", mfw, mff)
        KOMIRA_UND_MSINK("prepare", mpr, mprf)
        KOMIRA_UND_MSINK("setup", mst, (uint64_t)0)
        #undef KOMIRA_UND_MSINK
        fprintf(stderr,
            "SCHED_UNDISPATCHED total brackets=%d serial_ns=%llu "
            "pct_of_worker_wall=%.2f\n",
            n_und, (unsigned long long)und_ns, 100.0 * (double)und_ns / wwd);
        fprintf(stderr, "SCHED_UNDISPATCHED_END\n");
    }
    fprintf(stderr, "SCHED_TRACE_SUMMARY_END\n");
    fflush(stderr);
}

// TEST-ONLY deterministic enable. A test asserts through the getters, so this
// deliberately does NOT arm the atexit dump: a test binary that dumped the whole
// sched summary to stderr on exit would pollute every suite run that links it.
int komira_sched_force_enable(int on) {
    __atomic_store_n(&_sched_enabled, on ? 1 : 0, __ATOMIC_RELAXED);
    return 0;
}

// Production configuration, called ONCE at process start (before any
// LocalDispatcher / Worker is constructed, since those cache the flag) with
// the values of the binary's own flags. `on` enables the counters and arms the
// atexit summary dump; `region_log` additionally emits the per-region markers
// (it has no effect while `on` is 0, since a region that never opens emits
// nothing). Tracing is OFF until this is called.
int komira_sched_trace_configure(int on, int region_log) {
    __atomic_store_n(&_sched_enabled, on ? 1 : 0, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_rgn_log, region_log ? 1 : 0, __ATOMIC_RELAXED);
    if (on) {
        int expected = 0;
        if (__atomic_compare_exchange_n(&_sched_atexit_armed, &expected, 1,
                                        0, __ATOMIC_RELAXED,
                                        __ATOMIC_RELAXED)) {
            atexit(_komira_sched_dump);
        }
    }
    return 0;
}

// The cached enable flag. Called at LocalDispatcher / Worker construction so
// the hot paths cache the result in a field (never call this per-iteration).
int komira_sched_trace_enabled(void) {
    return __atomic_load_n(&_sched_enabled, __ATOMIC_RELAXED);
}

// Record one run_with_state fork span (fork_start -> barrier) + the driver-serial
// inter-fork gap since the previous fork returned. Called once per dispatch on
// the SUCCESS path. `site` bins the fork wall/count/task-count; the inter-gap is
// attributed to the PREVIOUS fork's site (the combine/finalize window that
// follows that fork). `n_tasks` is n_workers (parallel shards) for this fork.
// Single-writer (the one non-reentrant driver) so per-site slots use plain
// stores; the globals stay atomic to match the existing block.
// IN-BAND OCCUPANCY. Total worker-busy ns across all workers — the
// sum of `handle.run()` wall each worker has accrued so far. The DELTA of this
// across a fork span is how much worker time the fork actually consumed;
// delta / span is the average number of workers concurrently busy. Trace-only
// path, so a 512-slot sum is free relative to the fork it is measuring.
uint64_t komira_sched_worker_busy_total(void) {
    uint64_t t = 0;
    for (uint32_t w = 0; w < KOMIRA_SCHED_MAXW; w++) t += _sched_w_run_ns[w];
    return t;
}

int komira_sched_add_segment_occ(uint32_t site, uint64_t fork_start_ns,
                                  uint64_t barrier_ns, uint64_t n_tasks,
                                  uint64_t busy_at_fork_ns,
                                  uint64_t busy_at_barrier_ns);

int komira_sched_add_segment(uint32_t site, uint64_t fork_start_ns,
                              uint64_t barrier_ns, uint64_t n_tasks) {
    return komira_sched_add_segment_occ(site, fork_start_ns, barrier_ns,
                                         n_tasks, 0, 0);
}

// `busy_at_fork_ns` is `komira_sched_worker_busy_total()` sampled at
// fork_start; `busy_at_barrier_ns` the same sampled after the barrier returned.
// Pass 0/0 for "no occupancy sample" (the legacy entry point above), which is
// distinguishable from a genuine zero because `_sched_s_occ_ct` does not
// advance — a site with no samples prints occupancy=- rather than 0.00.
int komira_sched_add_segment_occ(uint32_t site, uint64_t fork_start_ns,
                                  uint64_t barrier_ns, uint64_t n_tasks,
                                  uint64_t busy_at_fork_ns,
                                  uint64_t busy_at_barrier_ns) {
    if (site >= (uint32_t)KOMIRA_SCHED_MAXSITE) site = 0;  // clamp into OTHER
    // ★ PER-FORK ROW. Captured from THIS fork's own arguments,
    // BEFORE any of them are folded into a per-site accumulator, so the row and
    // the site total are the same nanoseconds seen at two granularities. The
    // preceding driver-serial gap is filled in below, where it is computed.
    uint64_t fk_span = (barrier_ns > fork_start_ns)
                           ? (barrier_ns - fork_start_ns) : 0;
    int fk_have_occ = (busy_at_barrier_ns >= busy_at_fork_ns
                       && busy_at_barrier_ns != 0);
    uint64_t fk_busy = fk_have_occ ? (busy_at_barrier_ns - busy_at_fork_ns) : 0;
    uint64_t fk_i = _sched_fk_n;
    _sched_fk_n = fk_i + 1;
    if (fk_i == 0) _sched_fk_first_ns = fork_start_ns;
    uint64_t fk_flags = fk_have_occ ? 0u : 1u;
    uint64_t fk_tag = 0, fk_units = 0, fk_rows = 0;
    if (_sched_fk_note_live) {
        _sched_fk_note_live = 0;
        if (_sched_fk_note_site == (uint64_t)site) {
            fk_tag = _sched_fk_note_tag;
            fk_units = _sched_fk_note_units;
            fk_rows = _sched_fk_note_rows;
            _sched_fk_note_used += 1;
        } else {
            // The note named a DIFFERENT site than the fork that consumed it, so
            // some other dispatch ran between the stamp and the fork it was for.
            // Recorded as UNLABELLED + flagged, never as the wrong label.
            fk_flags |= 2u;
            _sched_fk_note_mismatch += 1;
        }
    }
    if (fk_i < (uint64_t)KOMIRA_SCHED_FORKS) {
        _sched_fk_site[fk_i] = (uint64_t)site;
        _sched_fk_tag[fk_i] = fk_tag;
        _sched_fk_tasks[fk_i] = n_tasks;
        _sched_fk_span_ns[fk_i] = fk_span;
        _sched_fk_busy_ns[fk_i] = fk_busy;
        _sched_fk_inter_ns[fk_i] = 0;
        _sched_fk_t0_ns[fk_i] = (fork_start_ns > _sched_fk_first_ns)
                                    ? (fork_start_ns - _sched_fk_first_ns) : 0;
        _sched_fk_units[fk_i] = fk_units;
        _sched_fk_rows[fk_i] = fk_rows;
        _sched_fk_flags[fk_i] = fk_flags;
    }
    if (barrier_ns > fork_start_ns) {
        uint64_t span = barrier_ns - fork_start_ns;
        __atomic_add_fetch(&_sched_fork_ns, span, __ATOMIC_RELAXED);
        _sched_s_fork_ns[site] += span;
        if (busy_at_barrier_ns >= busy_at_fork_ns && busy_at_barrier_ns != 0) {
            _sched_s_busy_ns[site] += busy_at_barrier_ns - busy_at_fork_ns;
            _sched_s_occ_span_ns[site] += span;
            _sched_s_occ_ct[site] += 1;
        }
    }
    uint64_t last = __atomic_load_n(&_sched_last_barrier_ns, __ATOMIC_RELAXED);
    if (last != 0 && fork_start_ns > last) {
        uint64_t gap = fork_start_ns - last;
        if (fk_i < (uint64_t)KOMIRA_SCHED_FORKS) _sched_fk_inter_ns[fk_i] = gap;
        __atomic_add_fetch(&_sched_inter_ns, gap, __ATOMIC_RELAXED);
        uint32_t ls = (uint32_t)_sched_last_site;
        if (ls >= (uint32_t)KOMIRA_SCHED_MAXSITE) ls = 0;
        _sched_s_inter_ns[ls] += gap;
        // POST-BARRIER ATTRIBUTION. The SAME gap, charged to the site of
        // the fork that FOLLOWS it (`site`), plus the prev->next transition cell.
        // `_sched_s_inter_next_ns` totals identically to `_sched_s_inter_ns`; the
        // two differ only in where each gap lands, and the diagonal (ls == site)
        // is the share on which they AGREE — the window is fenced by two forks of
        // one driver, so that driver owns it (CONFIRMED, no bracket needed).
        _sched_s_inter_next_ns[site] += gap;
        _sched_s_inter_next_ct[site] += 1;
        if (ls == site) _sched_s_inter_same_ns[site] += gap;
        _sched_t_ns[ls][site] += gap;
        _sched_t_ct[ls][site] += 1;
    }
    __atomic_store_n(&_sched_last_barrier_ns, barrier_ns, __ATOMIC_RELAXED);
    _sched_last_site = site;
    _sched_s_count[site] += 1;
    _sched_s_task_sum[site] += n_tasks;
    if (n_tasks > _sched_s_task_max[site]) _sched_s_task_max[site] = n_tasks;
    if (_sched_s_task_min[site] == 0 || n_tasks < _sched_s_task_min[site])
        _sched_s_task_min[site] = n_tasks;
    __atomic_add_fetch(&_sched_seg_count, 1, __ATOMIC_RELAXED);
    return 0;
}

// GENERIC SERIAL-PHASE BRACKET. Record one
// named driver-serial region: `wall_ns` = the bracket's wall, `fork_ns` = the
// fork->barrier span that COMPLETED inside it (delta of `_sched_fork_ns` across
// the bracket). SERIAL = wall - fork is the fork-excluded residue — the part a
// parallelization could actually recover. Driver-thread-only; call on the
// trace-on path only (the caller gates on cached `sched_trace_enabled()`).
int komira_sched_add_serial_phase(uint32_t phase, uint64_t wall_ns,
                                   uint64_t fork_ns) {
    if (phase == 0 || phase >= (uint32_t)KOMIRA_SCHED_MAXPHASE) return 0;
    _sched_ph_wall_ns[phase] += wall_ns;
    _sched_ph_fork_ns[phase] += fork_ns;
    _sched_ph_count[phase] += 1;
    return 0;
}

// TAIL-WINDOW variant: same, plus the phase's own WORK UNIT `n`
// (rows / keys / morsels — see `_sched_phase_unit`). Run-to-run wall noise
// can exceed a small lever's effect, so such a lever cannot be decided from
// `wall_ns` in one sweep; `n` is exact and moves the instant a
// lever removes work, which makes a bracket falsifiable at any size.
int komira_sched_add_serial_phase_n(uint32_t phase, uint64_t wall_ns,
                                     uint64_t fork_ns, uint64_t n) {
    if (phase == 0 || phase >= (uint32_t)KOMIRA_SCHED_MAXPHASE) return 0;
    _sched_ph_wall_ns[phase] += wall_ns;
    _sched_ph_fork_ns[phase] += fork_ns;
    _sched_ph_count[phase] += 1;
    _sched_ph_n[phase] += n;
    return 0;
}

// ★ OCCUPANCY FALSIFIER. CLOCK_THREAD_CPUTIME_ID
// for the CALLING thread, in ns. Bracket a window with two of these and the
// delta is the time that thread was ON a CPU inside it — the discriminator
// between a driver-serial window a fan-out can recover and one it cannot.
// See `_sched_ph_cpu_ns` for why this is the right clock and what it counts.
uint64_t komira_sched_thread_cpu_ns(void) {
#if defined(CLOCK_THREAD_CPUTIME_ID)
    struct timespec ts;
    if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts) != 0) return 0;
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
#else
    return 0;  // no per-thread CPU clock: the printer omits `occ` entirely.
#endif
}

// Accumulate a CPU-time delta against an EXISTING phase id. Deliberately a
// SEPARATE call rather than a wider `add_serial_phase_n`: 49 bracket sites
// across 9 files call that one, and only the handful under active
// investigation should pay two extra clock_gettime calls. A phase with no
// cpu_ns prints no `occ` field at all.
int komira_sched_add_phase_cpu(uint32_t phase, uint64_t cpu_ns) {
    if (phase == 0 || phase >= (uint32_t)KOMIRA_SCHED_MAXPHASE) return 0;
    _sched_ph_cpu_ns[phase] += cpu_ns;
    return 0;
}

// Same falsifier for the msink driver's two forking brackets, which live in
// their own storage rather than the phase table.
int komira_sched_add_msink_cpu(uint64_t finalize_cpu_ns,
                                uint64_t combine_cpu_ns) {
    __atomic_add_fetch(&_sched_msink_finalize_cpu_ns, finalize_cpu_ns,
                       __ATOMIC_RELAXED);
    __atomic_add_fetch(&_sched_msink_combine_cpu_ns, combine_cpu_ns,
                       __ATOMIC_RELAXED);
    return 0;
}

// ★ PER-INVOCATION record — see `_sched_msink_run_*`. `label_ptr`/`label_len`
// are the sink's own `combine_trace_label()`; a NULL or empty label records
// `"(none)"` rather than an empty column, so a missing label is visible.
// The driver thread is the only caller (the msink driver is single-threaded at
// this point by construction — every worker has joined at the barrier), so the
// counter is a plain increment and not an atomic.
int komira_sched_add_msink_run(uint64_t fin_wall_ns, uint64_t fin_fork_ns,
                                uint64_t fin_cpu_ns, uint64_t comb_wall_ns,
                                uint64_t comb_fork_ns, uint64_t driver_wall_ns,
                                const char *label_ptr, uint64_t label_len) {
    uint64_t i = _sched_msink_run_n++;
    if (i >= (uint64_t)KOMIRA_SCHED_MSINK_RUNS) return 0;
    _sched_msink_run_fin_wall[i] = fin_wall_ns;
    _sched_msink_run_fin_fork[i] = fin_fork_ns;
    _sched_msink_run_fin_cpu[i] = fin_cpu_ns;
    _sched_msink_run_comb_wall[i] = comb_wall_ns;
    _sched_msink_run_comb_fork[i] = comb_fork_ns;
    _sched_msink_run_driver_wall[i] = driver_wall_ns;
    size_t cap = sizeof(_sched_msink_run_label[0]) - 1;
    size_t n = (label_ptr == NULL) ? 0 : (size_t)label_len;
    if (n > cap) n = cap;
    if (n == 0) {
        memcpy(_sched_msink_run_label[i], "(none)", 7);
    } else {
        memcpy(_sched_msink_run_label[i], label_ptr, n);
        _sched_msink_run_label[i][n] = '\0';
    }
    return 0;
}

// ★ PER-FORK CALL-SITE NOTE.
//
// Stamp the call site of the fork ABOUT TO HAPPEN, plus whatever work-unit and
// row counts that call site already has in hand. `komira_sched_add_segment_occ`
// consumes-and-clears it into the fork row.
//
// `expect_site` is NOT redundant with `tag`: it is what makes a stolen note
// detectable. If any other dispatch forks between this stamp and the fork it was
// written for, the consuming fork's own site will not match and the row is
// recorded UNLABELLED with `note_mismatch=1` — never with the wrong tag. Callers
// must stamp immediately before the fork, with no dispatch in between; this is
// the check on that, and `SCHED_FORKS_BEGIN` reports the counts.
//
// Driver-thread-only, trace-on path only (the caller gates on its already-cached
// `sched_trace_enabled()` Bool), and once per FORK — never per morsel.
int komira_sched_set_fork_note(uint32_t tag, uint32_t expect_site,
                                uint64_t units, uint64_t rows) {
    if (_sched_fk_note_live) _sched_fk_note_dropped += 1;
    _sched_fk_note_tag = (uint64_t)tag;
    _sched_fk_note_site = (uint64_t)expect_site;
    _sched_fk_note_units = units;
    _sched_fk_note_rows = rows;
    _sched_fk_note_live = 1;
    _sched_fk_note_set += 1;
    return 0;
}

// Per-fork row getter (unit test + Mojo introspection).
// 0=site 1=tag 2=tasks 3=span_ns 4=busy_ns 5=inter_ns 6=t0_rel_ns 7=units
// 8=rows 9=flags (bit0 = no occupancy sample, bit1 = note site mismatch).
// An index past the KEPT rows returns 0; use `komira_sched_fork_count(field)`
// to bound the loop. Deliberately no derived occupancy here — the caller divides,
// so a reader can never mistake a rounded double for the recorded integers.
uint64_t komira_sched_get_fork(uint64_t i, int field) {
    if (i >= (uint64_t)KOMIRA_SCHED_FORKS) return 0;
    if (i >= _sched_fk_n) return 0;
    if (field == 0) return _sched_fk_site[i];
    if (field == 1) return _sched_fk_tag[i];
    if (field == 2) return _sched_fk_tasks[i];
    if (field == 3) return _sched_fk_span_ns[i];
    if (field == 4) return _sched_fk_busy_ns[i];
    if (field == 5) return _sched_fk_inter_ns[i];
    if (field == 6) return _sched_fk_t0_ns[i];
    if (field == 7) return _sched_fk_units[i];
    if (field == 8) return _sched_fk_rows[i];
    if (field == 9) return _sched_fk_flags[i];
    return 0;
}

// Fork-ring census. 0=forks SEEN (may exceed the cap) 1=rows KEPT
// 2=notes set 3=notes consumed 4=notes site-mismatched 5=notes overwritten
// before use 6=the ring capacity. (0) and (1) differing is truncation, not loss
// of the head; (4)+(5) non-zero is an attribution-health finding and the dump
// says so in band.
uint64_t komira_sched_fork_count(int field) {
    if (field == 0) return _sched_fk_n;
    if (field == 1) return (_sched_fk_n < (uint64_t)KOMIRA_SCHED_FORKS)
                               ? _sched_fk_n : (uint64_t)KOMIRA_SCHED_FORKS;
    if (field == 2) return _sched_fk_note_set;
    if (field == 3) return _sched_fk_note_used;
    if (field == 4) return _sched_fk_note_mismatch;
    if (field == 5) return _sched_fk_note_dropped;
    if (field == 6) return (uint64_t)KOMIRA_SCHED_FORKS;
    return 0;
}

// Ambient call-site push/pop for a SchedSiteScope guard on an owned enclosing
// frame (labels forks in a callee the runtime cannot edit). swap returns the
// previous site so the guard can restore it on drop.
uint32_t komira_sched_swap_site(uint32_t site) {
    return __atomic_exchange_n(&_sched_cur_site, site, __ATOMIC_RELAXED);
}
void komira_sched_set_site(uint32_t site) {
    __atomic_store_n(&_sched_cur_site, site, __ATOMIC_RELAXED);
}
uint32_t komira_sched_get_site(void) {
    return __atomic_load_n(&_sched_cur_site, __ATOMIC_RELAXED);
}

// Record the enqueue-loop dispatch wall (make_borrowed_erased + shard build +
// try_send) + the number of erasures produced (= n_workers per dispatch).
int komira_sched_add_dispatch(uint64_t ns, uint64_t erasures) {
    __atomic_add_fetch(&_sched_dispatch_ns, ns, __ATOMIC_RELAXED);
    __atomic_add_fetch(&_sched_erasure_count, erasures, __ATOMIC_RELAXED);
    return 0;
}

// Record one morsel-sink collect driver's driver-serial combine-phase walls
// (per-worker-locals drain, whole-segment sink.combine(), finalize()) AND the
// whole-driver WALL (entry->return, incl. the parallel scan/agg fork). Called
// once per execute_collect_morsel_sink[_op] invocation ON THE TRACE-ON PATH ONLY.
// The drain/combine/finalize walls sum inside the SITE_SINK_EXECUTOR inter-gap
// (the PHASE block reports each as a fraction of it); driver_wall_ns is the RUN
// wall the WALL_ATTR block divides by so the read is a true wall share.
// The phase walls accumulate (avg over runs) AND overwrite the LAST-RUN snapshot
// slots (a clean single-run measurement, uncontaminated by warmup/aggregation).
// Single-writer (the non-reentrant driver); relaxed-atomic to match the block.
int komira_sched_add_msink_phase(uint64_t drain_ns,
                                  uint64_t combine_wall_ns,
                                  uint64_t combine_fork_ns,
                                  uint64_t finalize_wall_ns,
                                  uint64_t finalize_fork_ns,
                                  uint64_t driver_wall_ns,
                                  uint64_t setup_ns,
                                  uint64_t prepare_ns,
                                  uint64_t teardown_ns,
                                  uint64_t prepare_fork_ns) {
    __atomic_add_fetch(&_sched_msink_setup_ns, setup_ns, __ATOMIC_RELAXED);
    __atomic_add_fetch(&_sched_msink_prepare_ns, prepare_ns, __ATOMIC_RELAXED);
    __atomic_add_fetch(&_sched_msink_prepare_fork_ns, prepare_fork_ns, __ATOMIC_RELAXED);
    __atomic_add_fetch(&_sched_msink_teardown_ns, teardown_ns, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_msink_last_setup_ns, setup_ns, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_msink_last_prepare_ns, prepare_ns, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_msink_last_prepare_fork_ns, prepare_fork_ns, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_msink_last_teardown_ns, teardown_ns, __ATOMIC_RELAXED);
    __atomic_add_fetch(&_sched_msink_drain_ns, drain_ns, __ATOMIC_RELAXED);
    __atomic_add_fetch(&_sched_msink_combine_wall_ns, combine_wall_ns, __ATOMIC_RELAXED);
    __atomic_add_fetch(&_sched_msink_combine_fork_ns, combine_fork_ns, __ATOMIC_RELAXED);
    __atomic_add_fetch(&_sched_msink_finalize_wall_ns, finalize_wall_ns, __ATOMIC_RELAXED);
    __atomic_add_fetch(&_sched_msink_finalize_fork_ns, finalize_fork_ns, __ATOMIC_RELAXED);
    __atomic_add_fetch(&_sched_msink_driver_wall_ns, driver_wall_ns, __ATOMIC_RELAXED);
    __atomic_add_fetch(&_sched_msink_phase_count, 1, __ATOMIC_RELAXED);
    // LAST-RUN overwrite snapshot (single measured run; not summed across iters).
    __atomic_store_n(&_sched_msink_last_driver_wall_ns, driver_wall_ns, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_msink_last_drain_ns, drain_ns, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_msink_last_combine_wall_ns, combine_wall_ns, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_msink_last_combine_fork_ns, combine_fork_ns, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_msink_last_finalize_wall_ns, finalize_wall_ns, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_msink_last_finalize_fork_ns, finalize_fork_ns, __ATOMIC_RELAXED);
    return 0;
}

// Overwrite the per-worker absolute accumulators for `wid`. Single-writer per
// wid (the worker owns its slot), so plain stores are correct; a concurrent
// dump read sees a self-consistent-enough snapshot for a diagnostic.
int komira_sched_worker_store(uint64_t wid, uint64_t run_ns, uint64_t pop_ns,
                               uint64_t park_inter_ns, uint64_t park_intra_ns,
                               uint64_t spin_ns, uint64_t empty_windows,
                               uint64_t tasks,
                               uint64_t spin_found_ns,
                               uint64_t found_windows,
                               uint64_t empty_inter_w,
                               uint64_t empty_intra_w) {
    if (wid >= (uint64_t)KOMIRA_SCHED_MAXW) return -1;
    _sched_w_run_ns[wid] = run_ns;
    _sched_w_pop_ns[wid] = pop_ns;
    _sched_w_park_inter_ns[wid] = park_inter_ns;
    _sched_w_park_intra_ns[wid] = park_intra_ns;
    _sched_w_spin_ns[wid] = spin_ns;
    _sched_w_empty_windows[wid] = empty_windows;
    _sched_w_tasks[wid] = tasks;
    _sched_w_spin_found_ns[wid] = spin_found_ns;
    _sched_w_found_windows[wid] = found_windows;
    _sched_w_empty_inter_w[wid] = empty_inter_w;
    _sched_w_empty_intra_w[wid] = empty_intra_w;
    _sched_w_seen[wid] = 1;
    return 0;
}

// Zero all counters (precise per-window measurement + the unit test).
int komira_sched_reset(void) {
    __atomic_store_n(&_sched_dispatch_ns, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_erasure_count, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_seg_count, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_fork_ns, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_inter_ns, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_last_barrier_ns, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_cur_site, 0, __ATOMIC_RELAXED);
    _sched_last_site = 0;
    memset(_sched_w_run_ns, 0, sizeof(_sched_w_run_ns));
    memset(_sched_w_pop_ns, 0, sizeof(_sched_w_pop_ns));
    memset(_sched_w_park_inter_ns, 0, sizeof(_sched_w_park_inter_ns));
    memset(_sched_w_park_intra_ns, 0, sizeof(_sched_w_park_intra_ns));
    memset(_sched_w_spin_ns, 0, sizeof(_sched_w_spin_ns));
    memset(_sched_w_empty_windows, 0, sizeof(_sched_w_empty_windows));
    memset(_sched_w_tasks, 0, sizeof(_sched_w_tasks));
    memset(_sched_w_spin_found_ns, 0, sizeof(_sched_w_spin_found_ns));
    memset(_sched_w_found_windows, 0, sizeof(_sched_w_found_windows));
    memset(_sched_w_empty_inter_w, 0, sizeof(_sched_w_empty_inter_w));
    memset(_sched_w_empty_intra_w, 0, sizeof(_sched_w_empty_intra_w));
    memset(_sched_w_seen, 0, sizeof(_sched_w_seen));
    memset(_sched_s_fork_ns, 0, sizeof(_sched_s_fork_ns));
    memset(_sched_s_inter_ns, 0, sizeof(_sched_s_inter_ns));
    // post-barrier attribution + generic serial-phase brackets.
    memset(_sched_s_inter_next_ns, 0, sizeof(_sched_s_inter_next_ns));
    memset(_sched_s_inter_same_ns, 0, sizeof(_sched_s_inter_same_ns));
    memset(_sched_s_inter_next_ct, 0, sizeof(_sched_s_inter_next_ct));
    memset(_sched_t_ns, 0, sizeof(_sched_t_ns));
    memset(_sched_t_ct, 0, sizeof(_sched_t_ct));
    memset(_sched_ph_wall_ns, 0, sizeof(_sched_ph_wall_ns));
    memset(_sched_ph_fork_ns, 0, sizeof(_sched_ph_fork_ns));
    memset(_sched_ph_count, 0, sizeof(_sched_ph_count));
    memset(_sched_ph_n, 0, sizeof(_sched_ph_n));
    memset(_sched_ph_cpu_ns, 0, sizeof(_sched_ph_cpu_ns));
    // SCHED OPWAVE — the fused fork's SCAN/OPERATOR split.
    memset(_sched_ow_count, 0, sizeof(_sched_ow_count));
    memset(_sched_ow_busy_ns, 0, sizeof(_sched_ow_busy_ns));
    memset(_sched_ow_op_ns, 0, sizeof(_sched_ow_op_ns));
    memset(_sched_ow_rows_in, 0, sizeof(_sched_ow_rows_in));
    memset(_sched_ow_rows_out, 0, sizeof(_sched_ow_rows_out));
    memset(_sched_ow_workers, 0, sizeof(_sched_ow_workers));
    memset(_sched_ow_present, 0, sizeof(_sched_ow_present));
    memset(_sched_ow_absent, 0, sizeof(_sched_ow_absent));
    // IN-BAND OCCUPANCY.
    memset(_sched_s_busy_ns, 0, sizeof(_sched_s_busy_ns));
    memset(_sched_s_occ_span_ns, 0, sizeof(_sched_s_occ_span_ns));
    memset(_sched_s_occ_ct, 0, sizeof(_sched_s_occ_ct));
    // ★ PER-FORK ROWS. The ring AND the pending note:
    // a note left live across a reset would attach to the first fork of the next
    // window and label it with the previous window's call site.
    memset(_sched_fk_site, 0, sizeof(_sched_fk_site));
    memset(_sched_fk_tag, 0, sizeof(_sched_fk_tag));
    memset(_sched_fk_tasks, 0, sizeof(_sched_fk_tasks));
    memset(_sched_fk_span_ns, 0, sizeof(_sched_fk_span_ns));
    memset(_sched_fk_busy_ns, 0, sizeof(_sched_fk_busy_ns));
    memset(_sched_fk_inter_ns, 0, sizeof(_sched_fk_inter_ns));
    memset(_sched_fk_t0_ns, 0, sizeof(_sched_fk_t0_ns));
    memset(_sched_fk_units, 0, sizeof(_sched_fk_units));
    memset(_sched_fk_rows, 0, sizeof(_sched_fk_rows));
    memset(_sched_fk_flags, 0, sizeof(_sched_fk_flags));
    _sched_fk_n = 0;
    _sched_fk_first_ns = 0;
    _sched_fk_note_live = 0;
    _sched_fk_note_tag = 0;
    _sched_fk_note_site = 0;
    _sched_fk_note_units = 0;
    _sched_fk_note_rows = 0;
    _sched_fk_note_set = 0;
    _sched_fk_note_used = 0;
    _sched_fk_note_mismatch = 0;
    _sched_fk_note_dropped = 0;
    // SCHED REGION. The caller of reset IS the driver — this is
    // where the driver/worker partition gets its reference thread. A region
    // opened by any other thread from here on lands in the worker partition.
    memset(_sched_rg_wall_ns, 0, sizeof(_sched_rg_wall_ns));
    memset(_sched_rg_self_ns, 0, sizeof(_sched_rg_self_ns));
    memset(_sched_rg_fork_ns, 0, sizeof(_sched_rg_fork_ns));
    memset(_sched_rg_count, 0, sizeof(_sched_rg_count));
    memset(_sched_rg_n, 0, sizeof(_sched_rg_n));
    memset(_sched_rg_depth_max, 0, sizeof(_sched_rg_depth_max));
    memset(_sched_rg_wall_ns_w, 0, sizeof(_sched_rg_wall_ns_w));
    memset(_sched_rg_self_ns_w, 0, sizeof(_sched_rg_self_ns_w));
    memset(_sched_rg_count_w, 0, sizeof(_sched_rg_count_w));
    __atomic_store_n(&_sched_rg_misnest, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_rg_overflow, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_rg_orphan, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_rg_driver_samples, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_rg_worker_samples, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_driver_tid, _sched_tid_self(), __ATOMIC_RELAXED);
    _sched_rg_stk_depth = 0;
    memset(_sched_s_count, 0, sizeof(_sched_s_count));
    memset(_sched_s_task_sum, 0, sizeof(_sched_s_task_sum));
    memset(_sched_s_task_min, 0, sizeof(_sched_s_task_min));
    memset(_sched_s_task_max, 0, sizeof(_sched_s_task_max));
    // msink combine-phase counters.
    __atomic_store_n(&_sched_msink_drain_ns, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_msink_combine_wall_ns, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_msink_combine_fork_ns, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_msink_finalize_wall_ns, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_msink_finalize_fork_ns, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_msink_phase_count, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_msink_finalize_cpu_ns, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_msink_combine_cpu_ns, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_msink_run_n, 0, __ATOMIC_RELAXED);
    memset(_sched_msink_run_fin_wall, 0, sizeof(_sched_msink_run_fin_wall));
    memset(_sched_msink_run_fin_fork, 0, sizeof(_sched_msink_run_fin_fork));
    memset(_sched_msink_run_fin_cpu, 0, sizeof(_sched_msink_run_fin_cpu));
    memset(_sched_msink_run_comb_wall, 0, sizeof(_sched_msink_run_comb_wall));
    memset(_sched_msink_run_comb_fork, 0, sizeof(_sched_msink_run_comb_fork));
    memset(_sched_msink_run_driver_wall, 0,
           sizeof(_sched_msink_run_driver_wall));
    memset(_sched_msink_run_label, 0, sizeof(_sched_msink_run_label));
    // SCHED_MSINK per-run WALL attribution counters.
    __atomic_store_n(&_sched_msink_driver_wall_ns, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_msink_last_driver_wall_ns, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_msink_last_drain_ns, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_msink_last_combine_wall_ns, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_msink_last_combine_fork_ns, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_msink_last_finalize_wall_ns, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_msink_last_finalize_fork_ns, 0, __ATOMIC_RELAXED);
    // msink handoff-residual brackets.
    __atomic_store_n(&_sched_msink_setup_ns, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_msink_prepare_ns, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_msink_prepare_fork_ns, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_msink_last_prepare_fork_ns, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_msink_teardown_ns, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_msink_last_setup_ns, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_msink_last_prepare_ns, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&_sched_msink_last_teardown_ns, 0, __ATOMIC_RELAXED);
    return 0;
}

// Print the summary block on demand (in addition to the atexit dump).
int komira_sched_dump(void) {
    _komira_sched_dump();
    return 0;
}

// AGG-IN-PASS admission-pin fire counter (see the _agg_in_pass_fire_count
// declaration above). inc/read/reset are the test-observable fire signal so a
// silently-dead admission is caught — the fused agg-over-join arm calls inc()
// once per admission-SUCCESS, the admission-pin test resets + reads.
int komira_agg_in_pass_fire_inc(void) {
    __atomic_add_fetch(&_agg_in_pass_fire_count, 1, __ATOMIC_RELAXED);
    return 0;
}
uint64_t komira_agg_in_pass_fire_count(void) {
    return __atomic_load_n(&_agg_in_pass_fire_count, __ATOMIC_RELAXED);
}
int komira_agg_in_pass_fire_reset(void) {
    __atomic_store_n(&_agg_in_pass_fire_count, 0, __ATOMIC_RELAXED);
    return 0;
}

// ORDER-ADVISORY fire counter (see the
// _order_advisory_fire_count declaration above). inc/read/reset are the
// test-observable fire signal so a silently-dead join-order checker is caught —
// the checker calls inc() once per DIVERGENCE, the falsifiers reset + read.
int komira_order_advisory_fire_inc(void) {
    __atomic_add_fetch(&_order_advisory_fire_count, 1, __ATOMIC_RELAXED);
    return 0;
}
uint64_t komira_order_advisory_fire_count(void) {
    return __atomic_load_n(&_order_advisory_fire_count, __ATOMIC_RELAXED);
}
int komira_order_advisory_fire_reset(void) {
    __atomic_store_n(&_order_advisory_fire_count, 0, __ATOMIC_RELAXED);
    return 0;
}

// Projection-seam leaf-scan decode intermediate width
// observable (see the _seam1_decode_ncols declaration above). set() records the
// decoded intermediate column count; get()/reset() are the falsifier's
// pre-materialize-narrow proof (NARROW width when the seam fired, FULL width when
// killed) — byte-equiv either way, so this is the ONLY signal that catches a
// silently-dead pre-materialize narrow. Shared across the projection-seam breakers
// (sort / partition_topn / window).
int komira_seam1_decode_ncols_set(uint64_t n) {
    __atomic_store_n(&_seam1_decode_ncols, n, __ATOMIC_RELAXED);
    return 0;
}
uint64_t komira_seam1_decode_ncols_get(void) {
    return __atomic_load_n(&_seam1_decode_ncols, __ATOMIC_RELAXED);
}
int komira_seam1_decode_ncols_reset(void) {
    __atomic_store_n(&_seam1_decode_ncols, 0, __ATOMIC_RELAXED);
    return 0;
}

// JOIN-REORDER fire counter (see the
// _join_reorder_fire_count declaration above). inc/read/reset are the
// test-observable fire signal so a silently-dead reorder route is caught — the
// reorderer calls inc() once per emitted INNER-join chain; the falsifier
// resets + reads.
int komira_join_reorder_fire_inc(void) {
    __atomic_add_fetch(&_join_reorder_fire_count, 1, __ATOMIC_RELAXED);
    return 0;
}
uint64_t komira_join_reorder_fire_count(void) {
    return __atomic_load_n(&_join_reorder_fire_count, __ATOMIC_RELAXED);
}
int komira_join_reorder_fire_reset(void) {
    __atomic_store_n(&_join_reorder_fire_count, 0, __ATOMIC_RELAXED);
    return 0;
}

// GENERIC-EXECUTOR fire counter (see the
// _exec_generic_fire_count declaration above). inc/read/reset are the
// test-observable fire signal so a silently-declining generic wave-fold is
// caught — the consumer calls inc() once per successful generic cascade; the
// flag-ON e2e leg resets + reads (asserts count>0 = the generic path DROVE the
// query, never a vacuous green from a fallback to the matcher).
int komira_exec_generic_fire_inc(void) {
    __atomic_add_fetch(&_exec_generic_fire_count, 1, __ATOMIC_RELAXED);
    return 0;
}
uint64_t komira_exec_generic_fire_count(void) {
    return __atomic_load_n(&_exec_generic_fire_count, __ATOMIC_RELAXED);
}
int komira_exec_generic_fire_reset(void) {
    __atomic_store_n(&_exec_generic_fire_count, 0, __ATOMIC_RELAXED);
    return 0;
}

// FUSED-DIM-WAVE reachability counter (see the _fused_dim_wave_dims declaration
// above). `add` takes the DIM COUNT the fused wave carried so a test can assert
// the antichain really fused N leaves into one fork.
int komira_fused_dim_wave_add(uint64_t n_dims) {
    __atomic_add_fetch(&_fused_dim_wave_dims, n_dims, __ATOMIC_RELAXED);
    return 0;
}
uint64_t komira_fused_dim_wave_dims(void) {
    return __atomic_load_n(&_fused_dim_wave_dims, __ATOMIC_RELAXED);
}
int komira_fused_dim_wave_reset(void) {
    __atomic_store_n(&_fused_dim_wave_dims, 0, __ATOMIC_RELAXED);
    return 0;
}

// Partial-bind seg-state alloc/free BALANCE (see the
// _seg_state_{alloc,free}_count declarations above). alloc bumps on a state-box
// allocation in the grouped-agg init_thunk; free bumps on the boxed state's
// teardown guard. The partial-bind test resets, drives a partial-bind that raises, and
// asserts alloc == free (exactly-once teardown of the already-bound boxes).
int komira_seg_state_alloc_inc(void) {
    __atomic_add_fetch(&_seg_state_alloc_count, 1, __ATOMIC_RELAXED);
    return 0;
}
int komira_seg_state_free_inc(void) {
    __atomic_add_fetch(&_seg_state_free_count, 1, __ATOMIC_RELAXED);
    return 0;
}
uint64_t komira_seg_state_alloc_count(void) {
    return __atomic_load_n(&_seg_state_alloc_count, __ATOMIC_RELAXED);
}
uint64_t komira_seg_state_free_count(void) {
    return __atomic_load_n(&_seg_state_free_count, __ATOMIC_RELAXED);
}
int komira_seg_state_balance_reset(void) {
    __atomic_store_n(&_seg_state_alloc_count, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&_seg_state_free_count, 0, __ATOMIC_RELAXED);
    return 0;
}

// Getters (field selectors) for the unit test + a Mojo-side dump. Globals:
// 0=dispatch_ns 1=erasure_count 2=seg_count 3=fork_ns 4=inter_ns
// 5=msink_drain_ns 6=msink_combine_wall_ns 7=msink_combine_fork_ns
// 8=msink_finalize_wall_ns 9=msink_finalize_fork_ns 10=msink_phase_count
// (5-10 = the msink combine-phase split).
// 11=msink_driver_wall_ns (cumulative)
// 12=msink_last_driver_wall_ns 13=msink_last_drain_ns 14=msink_last_combine_wall_ns
// 15=msink_last_combine_fork_ns 16=msink_last_finalize_wall_ns
// 17=msink_last_finalize_fork_ns.
// 18=msink_setup_ns 19=msink_prepare_ns 20=msink_teardown_ns
// 21=msink_last_setup_ns 22=msink_last_prepare_ns 23=msink_last_teardown_ns
//.
// 24=msink_prepare_fork_ns 25=msink_last_prepare_fork_ns (19/22 are
// prepare WALLs; serial = wall - fork).
uint64_t komira_sched_get_global(int field) {
    if (field == 0) return __atomic_load_n(&_sched_dispatch_ns, __ATOMIC_RELAXED);
    if (field == 1) return __atomic_load_n(&_sched_erasure_count, __ATOMIC_RELAXED);
    if (field == 2) return __atomic_load_n(&_sched_seg_count, __ATOMIC_RELAXED);
    if (field == 3) return __atomic_load_n(&_sched_fork_ns, __ATOMIC_RELAXED);
    if (field == 4) return __atomic_load_n(&_sched_inter_ns, __ATOMIC_RELAXED);
    if (field == 5) return __atomic_load_n(&_sched_msink_drain_ns, __ATOMIC_RELAXED);
    if (field == 6) return __atomic_load_n(&_sched_msink_combine_wall_ns, __ATOMIC_RELAXED);
    if (field == 7) return __atomic_load_n(&_sched_msink_combine_fork_ns, __ATOMIC_RELAXED);
    if (field == 8) return __atomic_load_n(&_sched_msink_finalize_wall_ns, __ATOMIC_RELAXED);
    if (field == 9) return __atomic_load_n(&_sched_msink_finalize_fork_ns, __ATOMIC_RELAXED);
    if (field == 10) return __atomic_load_n(&_sched_msink_phase_count, __ATOMIC_RELAXED);
    if (field == 11) return __atomic_load_n(&_sched_msink_driver_wall_ns, __ATOMIC_RELAXED);
    if (field == 12) return __atomic_load_n(&_sched_msink_last_driver_wall_ns, __ATOMIC_RELAXED);
    if (field == 13) return __atomic_load_n(&_sched_msink_last_drain_ns, __ATOMIC_RELAXED);
    if (field == 14) return __atomic_load_n(&_sched_msink_last_combine_wall_ns, __ATOMIC_RELAXED);
    if (field == 15) return __atomic_load_n(&_sched_msink_last_combine_fork_ns, __ATOMIC_RELAXED);
    if (field == 16) return __atomic_load_n(&_sched_msink_last_finalize_wall_ns, __ATOMIC_RELAXED);
    if (field == 17) return __atomic_load_n(&_sched_msink_last_finalize_fork_ns, __ATOMIC_RELAXED);
    if (field == 18) return __atomic_load_n(&_sched_msink_setup_ns, __ATOMIC_RELAXED);
    if (field == 19) return __atomic_load_n(&_sched_msink_prepare_ns, __ATOMIC_RELAXED);
    if (field == 20) return __atomic_load_n(&_sched_msink_teardown_ns, __ATOMIC_RELAXED);
    if (field == 21) return __atomic_load_n(&_sched_msink_last_setup_ns, __ATOMIC_RELAXED);
    if (field == 22) return __atomic_load_n(&_sched_msink_last_prepare_ns, __ATOMIC_RELAXED);
    if (field == 23) return __atomic_load_n(&_sched_msink_last_teardown_ns, __ATOMIC_RELAXED);
    if (field == 24) return __atomic_load_n(&_sched_msink_prepare_fork_ns, __ATOMIC_RELAXED);
    if (field == 25) return __atomic_load_n(&_sched_msink_last_prepare_fork_ns, __ATOMIC_RELAXED);
    return 0;
}

// Per-worker getter. 0=run 1=pop 2=park_inter 3=park_intra 4=spin
// 5=empty_windows 6=tasks 7=seen 8=spin_found_ns 9=found_windows
//.
// 10=empty_inter_w 11=empty_intra_w (empty-window causality split;
// 10+11 == 5 by construction).
uint64_t komira_sched_get_worker(uint64_t wid, int field) {
    if (wid >= (uint64_t)KOMIRA_SCHED_MAXW) return 0;
    if (field == 0) return _sched_w_run_ns[wid];
    if (field == 1) return _sched_w_pop_ns[wid];
    if (field == 2) return _sched_w_park_inter_ns[wid];
    if (field == 3) return _sched_w_park_intra_ns[wid];
    if (field == 4) return _sched_w_spin_ns[wid];
    if (field == 5) return _sched_w_empty_windows[wid];
    if (field == 6) return _sched_w_tasks[wid];
    if (field == 7) return (uint64_t)_sched_w_seen[wid];
    if (field == 8) return _sched_w_spin_found_ns[wid];
    if (field == 9) return _sched_w_found_windows[wid];
    if (field == 10) return _sched_w_empty_inter_w[wid];
    if (field == 11) return _sched_w_empty_intra_w[wid];
    return 0;
}

// Per-site getter (unit test + Mojo introspection). 0=fork_ns 1=inter_ns
// 2=count 3=task_sum 4=task_min 5=task_max; post-barrier attribution
//: 6=inter_next_ns 7=inter_same_ns 8=inter_next_count.
uint64_t komira_sched_get_site_field(uint32_t site, int field) {
    if (site >= (uint32_t)KOMIRA_SCHED_MAXSITE) return 0;
    if (field == 0) return _sched_s_fork_ns[site];
    if (field == 1) return _sched_s_inter_ns[site];
    if (field == 2) return _sched_s_count[site];
    if (field == 3) return _sched_s_task_sum[site];
    if (field == 4) return _sched_s_task_min[site];
    if (field == 5) return _sched_s_task_max[site];
    if (field == 6) return _sched_s_inter_next_ns[site];
    if (field == 7) return _sched_s_inter_same_ns[site];
    if (field == 8) return _sched_s_inter_next_ct[site];
    // IN-BAND OCCUPANCY: 9=busy_ns 10=occ_span_ns 11=occ_count.
    // span_avg = busy_ns / occ_span_ns; occupancy = span_avg / (task_sum/count).
    if (field == 9) return _sched_s_busy_ns[site];
    if (field == 10) return _sched_s_occ_span_ns[site];
    if (field == 11) return _sched_s_occ_ct[site];
    return 0;
}

// transition-matrix getter (unit test + Mojo introspection).
// 0=gap_ns 1=count for the (prev_site -> next_site) cell.
uint64_t komira_sched_get_transition(uint32_t prev, uint32_t next, int field) {
    if (prev >= (uint32_t)KOMIRA_SCHED_MAXSITE) return 0;
    if (next >= (uint32_t)KOMIRA_SCHED_MAXSITE) return 0;
    if (field == 0) return _sched_t_ns[prev][next];
    if (field == 1) return _sched_t_ct[prev][next];
    return 0;
}

// named serial-phase getter. 0=wall_ns 1=fork_ns 2=count
// 3=serial_ns (== wall - fork, saturating).
uint64_t komira_sched_get_serial_phase(uint32_t phase, int field) {
    if (phase >= (uint32_t)KOMIRA_SCHED_MAXPHASE) return 0;
    if (field == 0) return _sched_ph_wall_ns[phase];
    if (field == 1) return _sched_ph_fork_ns[phase];
    if (field == 2) return _sched_ph_count[phase];
    if (field == 3) {
        uint64_t w = _sched_ph_wall_ns[phase], f = _sched_ph_fork_ns[phase];
        return (w > f) ? (w - f) : 0;
    }
    if (field == 4) return _sched_ph_n[phase];  // TAIL-WINDOW work unit
    return 0;
}
