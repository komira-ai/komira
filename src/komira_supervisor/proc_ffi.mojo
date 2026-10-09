# =============================================================================
# komira_supervisor.proc_ffi — FFI thunks over _proc_shim.c.
# =============================================================================
#
# Typed-scalar in/out only. Every UnsafePointer here is
# INTERNAL to a thunk, confined to:
#   * out-param scalar slots the shim writes into (UnsafePointer(to=local)),
#   * the byte-blob marshal for argv/envp (a function-LOCAL List[UInt8] kept
#     alive across the syscall via an explicit anchor read),
#   * the pipe-drain buffer (a caller-owned mut List[UInt8]).
# None escape their thunk; the public Supervisor API (supervisor.mojo) returns
# only typed scalars / String / value structs.
#
# FFI-BOUNDARY: this module is the sanctioned FFI carve-out for the supervisor.
#   No wildcard origins on any signature; no unsafe_from_address=Int; no
#   take_pointee. The C shim owns all ABI-hostile syscalls (posix_spawn's
#   pointer-array argv/envp/file_actions, waitpid's WIF* macro decode,
#   waitid's P_ALL/WNOWAIT probe, pidfd_open).
# =============================================================================

from std.ffi import external_call


# -----------------------------------------------------------------------------
# Signal numbers — darwin and Linux share these.
# -----------------------------------------------------------------------------
comptime SIGTERM: Int32 = Int32(15)
comptime SIGKILL: Int32 = Int32(9)
comptime SIGINT: Int32 = Int32(2)


# -----------------------------------------------------------------------------
# komira_proc_spawn `flags` bits: this file's ABI with _proc_shim.c
# (KOMIRA_SPAWN_* there), not platform constants.
# -----------------------------------------------------------------------------
comptime SPAWN_OWN_PGROUP: Int32 = Int32(1)
comptime SPAWN_DEFAULT_SIGNALS: Int32 = Int32(2)


# -----------------------------------------------------------------------------
# Decoded waitpid status — the typed result the shim hands back.
# -----------------------------------------------------------------------------
@fieldwise_init
struct ReapStatus(Copyable, ImplicitlyCopyable, Movable):
    """Result of one komira_proc_reap call.

    `collected` is True when the child terminated (exited OR signaled) and the
    remaining fields are valid; False means WNOHANG and the child is still
    running (the other fields are meaningless). `error` is True on ECHILD /
    EINVAL (e.g. already reaped). `exited` / `signaled` are mutually exclusive
    when `collected`.
    """

    var collected: Bool
    var error: Bool
    var exited: Bool
    var exit_code: Int32   # WEXITSTATUS (0..255) when exited; -1 otherwise
    var signaled: Bool
    var signal: Int32      # WTERMSIG when signaled; -1 otherwise


# -----------------------------------------------------------------------------
# Build a flat NUL-delimited byte blob from a list of strings: each string's
# UTF-8 bytes followed by a NUL terminator, laid back-to-back. This is the
# shape `_split_blob` in the C shim expects (it splits on the embedded NULs).
#
# We marshal argv/envp this way SPECIFICALLY to avoid building a Mojo `char**`,
# which would require keeping every inner String's heap buffer alive across the
# FFI call (a stale-pointer-prone shape — the lifetime of N inner heap buffers under a
# pointer-array cast). One contiguous blob has ONE heap buffer whose liveness
# the caller anchors explicitly.
# -----------------------------------------------------------------------------
def build_cstr_blob(items: List[String]) -> List[UInt8]:
    var blob = List[UInt8]()
    for ref s in items:
        var b = s.as_bytes()
        for i in range(len(b)):
            # Guard against an embedded NUL in the source string (would
            # truncate the entry on the C side); skip NUL bytes defensively.
            var byte = b[i]
            if byte != UInt8(0):
                blob.append(byte)
        blob.append(UInt8(0))  # entry terminator
    if len(blob) == 0:
        # An empty blob still needs one byte so unsafe_ptr() is non-null.
        blob.append(UInt8(0))
    return blob^


# -----------------------------------------------------------------------------
# komira_proc_spawn thunk.
#   path        : absolute binary path (NUL-terminated C string)
#   argv_blob   : flat NUL-delimited argv (argc entries) — MUST include argv[0]
#   argc        : number of argv entries
#   env_blob    : flat NUL-delimited envp (envc entries); pass an empty blob +
#                 envc=0 to inherit `environ`
#   envc        : number of envp entries (0 => inherit)
#   cwd         : working directory (NUL-terminated) or empty => inherit
#   has_cwd     : True => apply cwd; False => pass NULL (inherit)
#   flags       : SPAWN_OWN_PGROUP | SPAWN_DEFAULT_SIGNALS, or 0
# Returns (rc, stdout_fd, stderr_fd, pid). rc==0 success; rc<0 is -errno.
# -----------------------------------------------------------------------------
def proc_spawn(
    path: String,
    mut argv_blob: List[UInt8],
    argc: Int,
    mut env_blob: List[UInt8],
    envc: Int,
    cwd: String,
    has_cwd: Bool,
    flags: Int32,
    mut out_stdout_fd: Int32,
    mut out_stderr_fd: Int32,
    mut out_pid: Int32,
) -> Int32:
    # SAFETY: path_local / cwd_local are rebound to `var` so as_c_string_slice()
    # (a mutating method) can be called — the same constraint s2n_shim.mojo
    # documents. Each `.unsafe_ptr()` yields a NUL-terminated Int8* the shim
    # reads synchronously (posix_spawn copies argv/env strings before return).
    # The argv/env blobs are function-LOCAL Lists; the shim reads bytes INTO
    # them during the call only. out_* are stack slots the shim writes. Nothing
    # escapes this function; all sources are anchored past the call below.
    var path_local = path
    var path_ptr = path_local.as_c_string_slice().unsafe_ptr()

    # Always pass a VALID cwd pointer (an empty String still yields a
    # NUL-terminated C string); the C shim applies it only when has_cwd!=0.
    # This sidesteps building a null UnsafePointer[Int8] (no default null ctor)
    # and keeps the FFI surface pointer-typed-uniform.
    var cwd_local = cwd
    var cwd_ptr = cwd_local.as_c_string_slice().unsafe_ptr()

    var argv_ptr = argv_blob.unsafe_ptr()
    var env_ptr = env_blob.unsafe_ptr()

    var sout_ptr = UnsafePointer(to=out_stdout_fd)
    var serr_ptr = UnsafePointer(to=out_stderr_fd)
    var pid_ptr = UnsafePointer(to=out_pid)

    var rc = external_call["komira_proc_spawn", Int32](
        path_ptr,
        argv_ptr,
        Int32(argc),
        env_ptr,
        Int32(envc),
        cwd_ptr,
        Int32(1) if has_cwd else Int32(0),
        flags,
        sout_ptr,
        serr_ptr,
        pid_ptr,
    )
    # Anchor every source's heap buffer past the syscall (the bytes/strings
    # must outlive posix_spawn's synchronous copy).
    _ = path_local
    _ = cwd_local
    _ = argv_blob[0]
    _ = env_blob[0]
    _ = out_stdout_fd
    _ = out_stderr_fd
    _ = out_pid
    return rc


# -----------------------------------------------------------------------------
# komira_proc_spawn_detached thunk — DETACHED spawn, NO capture pipes.
#   path       : absolute binary path (NUL-terminated C string)
#   argv_blob  : flat NUL-delimited argv (argc entries) — MUST include argv[0]
#   argc       : number of argv entries
#   env_blob   : flat NUL-delimited envp (envc entries); pass an empty blob +
#                envc=0 to inherit `environ`
#   envc       : number of envp entries (0 => inherit)
# Returns (rc, pid). rc==0 success; rc<0 is -errno. The child inherits the
# parent's fd 0/1/2 (no pipe plumbing — for a long-lived detached child).
# -----------------------------------------------------------------------------
def proc_spawn_detached(
    path: String,
    mut argv_blob: List[UInt8],
    argc: Int,
    mut env_blob: List[UInt8],
    envc: Int,
    mut out_pid: Int32,
) -> Int32:
    # SAFETY: path_local is rebound to `var` so as_c_string_slice() (a mutating
    # method) can be called; its `.unsafe_ptr()` yields a NUL-terminated Int8*
    # the shim reads synchronously (posix_spawn copies argv/env strings before
    # return). argv/env blobs are function-LOCAL Lists the shim reads bytes from
    # during the call only. out_pid is a stack slot the shim writes. Nothing
    # escapes this function; all sources are anchored past the call below.
    var path_local = path
    var path_ptr = path_local.as_c_string_slice().unsafe_ptr()
    var argv_ptr = argv_blob.unsafe_ptr()
    var env_ptr = env_blob.unsafe_ptr()
    var pid_ptr = UnsafePointer(to=out_pid)

    var rc = external_call["komira_proc_spawn_detached", Int32](
        path_ptr,
        argv_ptr,
        Int32(argc),
        env_ptr,
        Int32(envc),
        pid_ptr,
    )
    _ = path_local
    _ = argv_blob[0]
    _ = env_blob[0]
    _ = out_pid
    return rc


# -----------------------------------------------------------------------------
# proc_environ_count / proc_environ_at — READ the CALLING process's own
# environment. The shim COPIES each entry into a caller-owned buffer; no libc
# pointer crosses this boundary (an `environ` entry's storage is owned by libc
# and any setenv/putenv may free or move it).
#
# `proc_environ_at` returns `(bytes_written, needed)`:
#   bytes >= 0            -> `bytes` were written into buf (NUL-terminated).
#   bytes == -1, needed 0 -> `idx` is out of range.
#   bytes == -1, needed n -> buf is too small; retry with cap >= n.
# -----------------------------------------------------------------------------
@fieldwise_init
struct EnvironEntryRead(Copyable, ImplicitlyCopyable, Movable):
    var bytes: Int    # bytes written into buf, or -1
    var needed: Int   # required capacity when bytes == -1 and this is > 0


def proc_environ_count() -> Int:
    """The number of entries in this process's `environ`."""
    # SAFETY: a fixed-arity scalar call; no pointer crosses.
    return Int(external_call["komira_proc_environ_count", Int32]())


def proc_environ_at(idx: Int, mut buf: List[UInt8], cap: Int) -> EnvironEntryRead:
    # SAFETY: buf is pre-reserved to >= cap; the shim writes at most `cap` bytes
    # into buf's storage and NUL-terminates. The ptr does not escape; buf
    # outlives the call and is anchored past it.
    var n = external_call["komira_proc_environ_at", Int](
        Int32(idx), buf.unsafe_ptr(), Int64(cap)
    )
    _ = buf[0]  # anchor
    var r = Int(n)
    if r >= 0:
        return EnvironEntryRead(bytes=r, needed=0)
    if r == -1:
        return EnvironEntryRead(bytes=-1, needed=0)
    return EnvironEntryRead(bytes=-1, needed=-r)


def proc_read(fd: Int32, mut buf: List[UInt8], cap: Int) -> Int:
    # SAFETY: buf is pre-reserved to >= cap; the shim writes up to `cap` bytes
    # into buf's storage. The ptr does not escape; buf outlives the call.
    var n = external_call["komira_proc_read", Int](
        fd, buf.unsafe_ptr(), Int64(cap)
    )
    _ = buf[0]  # anchor
    return Int(n)


def proc_set_nonblocking(fd: Int32) -> Int32:
    """Set O_NONBLOCK on `fd` (fcntl F_GETFL|F_SETFL). Returns 0 / -errno. The
    caller makes the capture-pipe read ends non-blocking so the incremental drain
    read never parks the run loop."""
    # SAFETY: a fixed-arity scalar fcntl wrapper in the shim; no pointer crosses.
    return external_call["komira_proc_set_nonblocking", Int32](fd)


# -----------------------------------------------------------------------------
# proc_read_avail — ONE non-blocking read for the incremental drain. The result
# distinguishes the three outcomes a caller's loop must act on differently:
#   bytes > 0      -> `bytes` were written into buf (more may be ready now).
#   eof == True    -> all writers closed (the child exited / closed the fd) —
#                     the drain is finished, no more data will ever arrive.
#   would_block    -> nothing ready RIGHT NOW but the child is still running
#                     (writers still open) — poll again next loop iteration.
#   error          -> a genuine read error — treat as "drain done".
# Exactly ONE of {bytes>0, eof, would_block, error} is the meaningful outcome.
# -----------------------------------------------------------------------------
@fieldwise_init
struct ReadAvail(Copyable, ImplicitlyCopyable, Movable):
    var bytes: Int       # bytes read into buf (0 when not a data outcome)
    var eof: Bool        # all writers closed — drain complete
    var would_block: Bool  # nothing ready now; child still running
    var error: Bool      # genuine read error


def proc_read_avail(fd: Int32, mut buf: List[UInt8], cap: Int) -> ReadAvail:
    # SAFETY: buf is pre-reserved to >= cap; the shim writes up to `cap` bytes
    # into buf's storage in ONE non-blocking read(). The ptr does not escape;
    # buf outlives the call.
    var n = external_call["komira_proc_read_avail", Int](
        fd, buf.unsafe_ptr(), Int64(cap)
    )
    _ = buf[0]  # anchor
    var r = Int(n)
    if r > 0:
        return ReadAvail(bytes=r, eof=False, would_block=False, error=False)
    elif r == 0:
        return ReadAvail(bytes=0, eof=True, would_block=False, error=False)
    elif r == -1:
        return ReadAvail(bytes=0, eof=False, would_block=True, error=False)
    else:  # -2
        return ReadAvail(bytes=0, eof=False, would_block=False, error=True)


def proc_close(fd: Int32):
    # A bare libc `close` external_call: the work is a one-line
    # `if (fd >= 0) close(fd)` with no errno/EINTR/macro logic. The signature
    # `external_call["close", Int32](Int32)` is the one komira_async and the
    # other libraries the supervisor links with already declare; matching it
    # exactly avoids a "conflicting signature" link failure. The fd>=0 guard
    # keeps the no-op-on-negative-fd contract (callers pass -1 sentinels for
    # unopened pipe ends).
    if fd >= 0:
        _ = external_call["close", Int32](fd)


def proc_kill(pid: Int32, sig: Int32) -> Int32:
    return external_call["komira_proc_kill", Int32](pid, sig)


def proc_kill_group(pgid: Int32, sig: Int32) -> Int32:
    """kill(-pgid, sig): signal every process in group `pgid`. Returns 0 /
    -errno. The shim refuses pgid <= 1 with -EINVAL (kill(-1) would signal
    every process the caller may signal, kill(0) the caller's own group)."""
    return external_call["komira_proc_kill_group", Int32](pgid, sig)


# -----------------------------------------------------------------------------
# The stop-signal latch and orphan adoption (_proc_shim.c has the full notes).
#
# FFI-BOUNDARY: scalars only. The latch is a process-wide int inside the shim,
# written by its own SIGTERM/SIGINT handler and read-and-cleared by
# proc_take_stop_signal; no pointer crosses and nothing is allocated.
# -----------------------------------------------------------------------------
def proc_install_stop_handler() -> Int32:
    """Catch SIGTERM and SIGINT into the latch. 0, or -errno."""
    return external_call["komira_proc_install_stop_handler", Int32]()


def proc_take_stop_signal() -> Int32:
    """The first stop signal caught since the last take (SIGTERM or SIGINT),
    cleared by this read; 0 when none."""
    return external_call["komira_proc_take_stop_signal", Int32]()


def proc_adopt_orphans() -> Int32:
    """1 when this process is PID 1 (orphans come to it already); 0 once it
    is a Linux child subreaper; -errno on failure, -ENOSYS where the OS has no
    subreaper."""
    return external_call["komira_proc_adopt_orphans", Int32]()


def proc_reap_orphans(keep_pid: Int32, max: Int32) -> Int32:
    """Collect up to `max` exited children other than `keep_pid`, without
    blocking. Returns how many, or -errno."""
    return external_call["komira_proc_reap_orphans", Int32](keep_pid, max)


def proc_reap(pid: Int32, nohang: Bool) -> ReapStatus:
    # SAFETY: the four out_* are stack slots the shim writes the decoded
    # WIF* status into. Pointers do not escape; locals outlive the call.
    var out_exited = Int32(0)
    var out_exitcode = Int32(-1)
    var out_signaled = Int32(0)
    var out_signal = Int32(-1)
    var r = external_call["komira_proc_reap", Int32](
        pid,
        Int32(1) if nohang else Int32(0),
        UnsafePointer(to=out_exited),
        UnsafePointer(to=out_exitcode),
        UnsafePointer(to=out_signaled),
        UnsafePointer(to=out_signal),
    )
    _ = out_exited
    _ = out_exitcode
    _ = out_signaled
    _ = out_signal
    if r == Int32(1):
        return ReapStatus(
            collected=True,
            error=False,
            exited=out_exited == Int32(1),
            exit_code=out_exitcode,
            signaled=out_signaled == Int32(1),
            signal=out_signal,
        )
    elif r == Int32(0):
        return ReapStatus(
            collected=False, error=False, exited=False,
            exit_code=Int32(-1), signaled=False, signal=Int32(-1),
        )
    else:
        return ReapStatus(
            collected=False, error=True, exited=False,
            exit_code=Int32(-1), signaled=False, signal=Int32(-1),
        )


# -----------------------------------------------------------------------------
# proc_probe_children -- does this process have any child, asked WITHOUT
# reaping one: waitid(P_ALL, 0, WEXITED | WNOHANG | WNOWAIT) in the shim.
#
# "A child exists" means any child of this process that reports its exit with
# SIGCHLD (every posix_spawn child does; without __WALL, Linux waitid skips
# __WCLONE children), in any state: running, stopped, or exited and not yet
# reaped. An exited child stays a zombie (its
# owner still collects it with waitpid(pid)); `exited_pid` names one such
# child, or is 0 when none has exited. Only ECHILD means "no child"; any other
# waitid failure raises with its errno.
#
# FFI-BOUNDARY: the shim writes two caller-owned stack Int32 slots during the
# call and retains nothing; no pointer leaves this function.
# -----------------------------------------------------------------------------
@fieldwise_init
struct ChildProbe(Copyable, ImplicitlyCopyable, Movable):
    """What proc_probe_children saw (see its header)."""

    var any_child: Bool
    var exited_pid: Int32  # an exited, still-unreaped child; 0 when none


def proc_probe_children() raises -> ChildProbe:
    """Whether this process has any child, without reaping one. Raises on any
    waitid failure but ECHILD (the message carries the errno)."""
    var out_exited_pid = Int32(0)
    var out_errno = Int32(0)
    # SAFETY: both pointers are to the two locals above, which outlive the
    # call; the shim writes them synchronously and keeps neither.
    var r = external_call["komira_proc_probe_children", Int32](
        UnsafePointer(to=out_exited_pid),
        UnsafePointer(to=out_errno),
    )
    _ = out_exited_pid
    _ = out_errno
    if r == Int32(1):
        return ChildProbe(any_child=True, exited_pid=out_exited_pid)
    if r == Int32(0):
        return ChildProbe(any_child=False, exited_pid=Int32(0))
    raise Error(
        String("waitid(P_ALL, WEXITED|WNOHANG|WNOWAIT) failed: errno ")
        + String(out_errno)
    )


# -----------------------------------------------------------------------------
# Exit-monitor primitives (standalone forms used by the package test's
# scenario f; the PRODUCTION path registers on the long-lived reactor).
# -----------------------------------------------------------------------------
def proc_pidfd_open(pid: Int32) -> Int32:
    """Linux: pidfd_open(pid, 0). Returns the pidfd (>=0) or -errno / -2 off
    Linux. The fd becomes EPOLLIN-readable on child exit; register it with the
    reactor's epoll via epoll_subsystem.epoll_ctl_add (no new epoll code)."""
    return external_call["komira_proc_pidfd_open", Int32](pid)


def proc_pidfd_wait(pidfd: Int32, timeout_ms: Int32) -> Int32:
    """Linux standalone: poll() the pidfd for POLLIN up to timeout_ms.
    1=exit observed, 0=timeout, -1=error, -2=not Linux. Production uses the
    reactor epoll completion, not this."""
    return external_call["komira_proc_pidfd_wait", Int32](pidfd, timeout_ms)


def proc_kqueue_exit_wait(pid: Int32, timeout_ms: Int32) -> Int32:
    """Darwin standalone: fresh-kqueue EVFILT_PROC/NOTE_EXIT wait up to
    timeout_ms. 1=NOTE_EXIT fired, 0=timeout, -1=error, -2=not darwin.
    Production registers EVFILT_PROC on the long-lived reactor kqueue via
    kqueue_subsystem.kevent_register_proc_exit instead."""
    return external_call["komira_proc_kqueue_exit_wait", Int32](
        pid, timeout_ms
    )
