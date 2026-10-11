# =============================================================================
# komira_supervisor.supervisor — the safe Supervisor wrapper.
# =============================================================================
#
# The process supervisor: spawn a child, capture its output, observe its exit,
# and stop it.
#
# Public surface:
#   ChildSpec{path, argv, env?, cwd?, rlimits}  — what to run (defaults inherit)
#   RLimit{resource, soft, hard}                — opt-in resource limit (accepted, not applied yet)
#   ExitInfo{exit_code, signal, shell_code}     — decoded exit status
#   Supervisor:
#     spawn(spec) -> Int32           posix_spawn w/ TWO pipes; returns pid (>0)
#     stdout_fd() / stderr_fd()      read ends of the two capture pipes
#     pid()                          child pid
#     wait_exit() -> ExitInfo        block for exit (reactor-event in prod), reap once
#     drain_pipe(fd) -> String       drain one capture pipe to EOF (deadlock-free)
#     terminate(grace_ms) -> ExitInfo  SIGTERM -> grace -> SIGKILL, exactly-once
#     terminate_with(sig, grace_ms, reap_orphans) -> ExitInfo
#                                    the same ladder from `sig`; to the child's
#                                    process group when it leads one
#     reap_orphans() -> Int          collect exited children other than ours
#     signal(sig)                    raw kill(pid, sig)
#     close()                        close pipe fds, dereg
#
# Pointer discipline: NO UnsafePointer in any signature here. All FFI is behind
# proc_ffi.mojo's thunks. The public API returns typed scalars / String / value
# structs. No wildcard origins, no unsafe_from_address, no take_pointee.
#
# Reactor exit monitor (the one genuinely-new mechanism): child exit is a
# NORMAL reactor event — NO SIGCHLD handler.
#   darwin: kqueue_subsystem.kevent_register_proc_exit (EVFILT_PROC/NOTE_EXIT)
#           on the long-lived reactor kqueue.
#   linux:  proc_ffi.proc_pidfd_open + the existing epoll_subsystem.epoll_ctl_add.
# Both converge on the upper-layer `watch_process_exit(pid)` in exit_monitor.mojo.
# The package test proves the kernel mechanism via the standalone wait
# (proc_kqueue_exit_wait / proc_pidfd_wait); a long-lived caller awaits the
# reactor completion.
# =============================================================================

from std.ffi import external_call

from .proc_ffi import (
    ReapStatus,
    ReadAvail,
    SIGTERM,
    SIGKILL,
    build_cstr_blob,
    proc_environ_at,
    proc_environ_count,
    proc_spawn,
    proc_spawn_detached,
    proc_read,
    proc_read_avail,
    proc_set_nonblocking,
    proc_close,
    proc_kill,
    proc_kill_group,
    proc_reap,
    proc_reap_orphans,
    SPAWN_OWN_PGROUP,
    SPAWN_DEFAULT_SIGNALS,
)


# =============================================================================
# _BYTES_NOT_CODEPOINTS — the one rule every byte->String seam in this file obeys
# =============================================================================
#
# ⛔ NEVER `out += chr(Int(byte))`. `chr(n)` maps a UNICODE CODEPOINT to its
# UTF-8 encoding, so feeding it a raw byte of a multi-byte character re-encodes
# that byte as a codepoint in its own right. For example:
#
#     in   4d e2 80 94 45 e2 80 a6 4e         "M—E…N"      (9 bytes)
#     out  4d c3 a2 c2 80 c2 94 45 c3 a2 …    "MâE⦔  (15 bytes)
#
# Every non-ASCII character comes out as three mojibake characters, and the
# string gets LONGER — so a byte-exact transport became a lossy transcode.
#
# This file is where it matters most: every supervised subprocess has its
# stdout and stderr captured HERE. Protocol markers in those streams are usually
# ASCII, so a transcode bug stays invisible to marker checks; what it mangles is
# exactly the prose a human reads when a child fails.
#
# A borrow of the reused chunk buffer must not escape (it would dangle), but
# that does not mean the bytes must be decoded. The correct shape owns the bytes
# AND preserves them:
#
#     var acc = List[UInt8]()          # OUR storage, not the read buffer's
#     acc.extend(Span[UInt8](buf)[0:n])
#     return String(unsafe_from_utf8=Span(acc))   # copies; nothing borrowed
#
# The returned String is byte-identical to the input and survives the source
# list's death plus arbitrary further allocation.
#
# ⚠ A chunk boundary MAY split a multi-byte character. That is safe precisely
# BECAUSE nothing decodes: the fragments ride through as raw bytes and String
# `+=` (a byte concatenation) rejoins them exactly. A decoder at this seam would
# have to mangle the fragment or carry state across calls.
# =============================================================================


# -----------------------------------------------------------------------------
# _sleep_ms — usleep-backed millisecond pause.
#
# We use `usleep` (single-arg, returns Int32) instead of stdlib `time.sleep`
# (which declares `nanosleep`): an AOT binary that links this package ALONGSIDE
# komira_async (whose reactor declares its OWN `external_call["nanosleep", ...]`)
# fails legalization with a "conflicting nanosleep signature". `usleep` is a
# DISTINCT symbol
# from either nanosleep decl, so it sidesteps the conflict entirely. Resolution
# is ~10ms-tick-grade, which is exactly what the grace poll needs.
# -----------------------------------------------------------------------------
def _sleep_ms(ms: Int):
    """Sleep `ms` milliseconds via usleep (microsecond granularity)."""
    if ms <= 0:
        return
    _ = external_call["usleep", Int32](UInt32(ms * 1000))


# -----------------------------------------------------------------------------
# spawn_detached — spawn a LONG-LIVED child WITHOUT capture pipes.
#
# The two-pipe `Supervisor.spawn` is for a captured child whose stdout/stderr the
# caller drains. A LONG-LIVED detached child (for example a node agent started by
# a local pod manager) wants the SIMPLER shape: inherit the parent's fd 0/1/2, no
# pipe plumbing (such a child ships its own logs). This free function marshals
# argv/env INTO flat NUL-delimited blobs internally (the single-heap-buffer shape)
# and calls the posix_spawn FFI. The C envp[] array is built INSIDE the shim from
# the blob — no `char**` and no UnsafePointer crosses this module's boundary.
#
# `path`     : absolute binary path.
# `argv`     : argv[1:]; argv[0] is defaulted to `path`.
# `env`      : "KEY=VALUE" entries; empty => the child inherits `environ`.
# Returns the child pid (> 0) on success, or -errno (< 0) on spawn failure.
# -----------------------------------------------------------------------------
def spawn_detached(
    path: String, argv: List[String], env: List[String]
) -> Int32:
    # argv blob: argv[0] = path, then argv[1:].
    var argv_items = List[String]()
    argv_items.append(path)
    for ref a in argv:
        argv_items.append(a)
    var argv_blob = build_cstr_blob(argv_items)
    var argc = len(argv_items)

    # env blob: only when an explicit environment is supplied (else inherit).
    var env_blob: List[UInt8]
    var envc: Int
    if len(env) > 0:
        env_blob = build_cstr_blob(env)
        envc = len(env)
    else:
        env_blob = List[UInt8]()
        env_blob.append(UInt8(0))  # non-empty so unsafe_ptr() is valid
        envc = 0

    var pid = Int32(-1)
    var rc = proc_spawn_detached(path, argv_blob, argc, env_blob, envc, pid)
    if rc != Int32(0):
        return rc  # -errno
    return pid


# -----------------------------------------------------------------------------
# DetachedExit — the result of one DetachedChild.poll_exit() (WNOHANG reap).
# `running` True => the child is still alive (exit_code meaningless). Otherwise
# the child terminated: `exited` + `exit_code` (0..255) on a normal exit, or
# `signaled` + `signal` on a signal kill. `error` => waitpid failed (e.g. ECHILD
# already reaped); a caller treats this as "gone".
# -----------------------------------------------------------------------------
@fieldwise_init
struct DetachedExit(Copyable, ImplicitlyCopyable, Movable):
    var running: Bool
    var exited: Bool
    var exit_code: Int32
    var signaled: Bool
    var signal: Int32
    var error: Bool


# -----------------------------------------------------------------------------
# DetachedChild — a thin owner of one detached child pid. Encapsulates the
# WNOHANG reap + SIGKILL FFI so the caller never touches a raw pid syscall.
# Movable POD (just an Int32 pid + a cached-terminal flag).
# -----------------------------------------------------------------------------
struct DetachedChild(Copyable, ImplicitlyCopyable, Movable):
    var _pid: Int32

    def __init__(out self, pid: Int32):
        self._pid = pid

    def pid(self) -> Int32:
        return self._pid

    def poll_exit(self) -> DetachedExit:
        """Non-blocking WNOHANG reap. running=True if the child is still alive;
        otherwise the decoded terminal status. Reaps the zombie on terminal."""
        if self._pid <= Int32(0):
            return DetachedExit(
                running=False, exited=False, exit_code=Int32(-1),
                signaled=False, signal=Int32(-1), error=True,
            )
        var r = proc_reap(self._pid, nohang=True)
        if not r.collected and not r.error:
            return DetachedExit(
                running=True, exited=False, exit_code=Int32(-1),
                signaled=False, signal=Int32(-1), error=False,
            )
        if r.error:
            return DetachedExit(
                running=False, exited=False, exit_code=Int32(-1),
                signaled=False, signal=Int32(-1), error=True,
            )
        return DetachedExit(
            running=False, exited=r.exited, exit_code=r.exit_code,
            signaled=r.signaled, signal=r.signal, error=False,
        )

    def term(self) -> Int32:
        """SIGTERM the child (catchable — the polite graceful-stop request).
        Returns 0 / -errno. Idempotent at the caller level — a term on an
        already-exited pid returns -errno (ESRCH), which the caller swallows.
        Used by a SIGTERM -> grace -> SIGKILL termination ladder (for example a
        multi-child supervisor) so the kill FFI stays confined to this
        encapsulated child wrapper (no raw `kill` syscall crosses the caller's
        module boundary)."""
        if self._pid <= Int32(0):
            return Int32(-1)
        return proc_kill(self._pid, SIGTERM)

    def kill(self) -> Int32:
        """SIGKILL the child (uncatchable). Returns 0 / -errno. Idempotent at the
        caller level — a kill on an already-exited pid returns -errno (ESRCH),
        which the caller swallows."""
        if self._pid <= Int32(0):
            return Int32(-1)
        return proc_kill(self._pid, SIGKILL)


# -----------------------------------------------------------------------------
# RLimit — opt-in resource limit: accepted but NOT applied yet (container
# limits cover the current callers). Carried so the API is stable when a
# concrete need appears.
# -----------------------------------------------------------------------------
@fieldwise_init
struct RLimit(Copyable, Movable):
    var resource: Int32   # RLIMIT_* constant
    var soft: UInt64
    var hard: UInt64


# -----------------------------------------------------------------------------
# process_environ / merge_env_overlay — the two halves of "inherit AND override".
#
# `posix_spawn` has exactly two env arms: inherit `environ` wholesale, or hand it
# a complete replacement. A caller that needs the ambient environment PLUS its
# own values therefore has to build the union itself, and these are the pieces.
# -----------------------------------------------------------------------------
def process_environ() -> List[String]:
    """This process's own environment as `"KEY=VALUE"` entries, in `environ`
    order.

    Every entry is COPIED out of libc storage by the shim (see
    `_proc_shim.c:komira_proc_environ_at`) — no libc pointer reaches Mojo, so a
    later `setenv` cannot invalidate what this returned."""
    var out = List[String]()
    var n = proc_environ_count()
    comptime START_CAP = 4096
    for i in range(n):
        var cap = START_CAP
        var buf = List[UInt8]()
        for _ in range(cap):
            buf.append(UInt8(0))
        var r = proc_environ_at(i, buf, cap)
        if r.bytes < 0 and r.needed > 0:
            # An entry longer than the starting buffer. Grow ONCE to exactly the
            # size the shim asked for and re-read.
            cap = r.needed
            buf = List[UInt8]()
            for _ in range(cap):
                buf.append(UInt8(0))
            r = proc_environ_at(i, buf, cap)
        if r.bytes < 0:
            # Out of range: `environ` shrank between the count and this read.
            # Stop rather than emit a partial entry.
            break
        # ⛔ BYTE-PRESERVING (see `_BYTES_NOT_CODEPOINTS` above). An environment
        # VALUE is arbitrary bytes — a UTF-8 path, a display name, a locale
        # string — and these entries are handed straight back to
        # `build_cstr_blob` as the CHILD's environment, so a transcode here
        # hands the child a value its parent never had.
        out.append(String(unsafe_from_utf8=Span[UInt8](buf)[0 : r.bytes]))
    return out^


def _env_name_of(entry: String) -> String:
    """The NAME half of a `"KEY=VALUE"` entry — everything before the FIRST `=`.
    An entry with no `=` is its own name (defensive: `environ` entries always
    carry one, but a caller-supplied overlay might not).

    ⛔ BYTE-PRESERVING (see `_BYTES_NOT_CODEPOINTS` above). Its only caller
    (`merge_env_overlay`) compares two of these against each other, where a
    transcode would still keep equal names equal; but the no-`=` arm returns a
    whole entry, i.e. a VALUE, and a caller that prints or stores what this
    returns must get the original bytes. Byte-preserving is also cheaper."""
    var b = entry.as_bytes()
    for i in range(len(b)):
        if b[i] == UInt8(0x3D):  # '='
            return String(unsafe_from_utf8=b[0:i])
    return entry.copy()


def merge_env_overlay(
    var base: List[String], overlay: List[String]
) -> List[String]:
    """`base` with `overlay` applied BY NAME: an overlay entry whose name is
    already in `base` REPLACES it IN PLACE; a new name is APPENDED, in overlay
    order.

    ⛔ IT REPLACES RATHER THAN APPENDS, AND THAT IS THE WHOLE POINT. Two entries
    with the same name in one `envp` array is not an override — glibc's `getenv`
    returns the FIRST match, so appending `AWS_REGION=us-east-1` after an
    inherited `AWS_REGION=eu-west-1` silently keeps the inherited one. The
    resulting environment here has each name AT MOST ONCE, so it means the same
    thing to every libc.

    ⚠ WITHIN `overlay`, the LAST entry for a name wins — the usual order for an
    authored-then-forwarded concatenation."""
    var out = base^
    for ref e in overlay:
        var name = _env_name_of(e)
        var replaced = False
        for i in range(len(out)):
            if _env_name_of(out[i]) == name:
                out[i] = e.copy()
                replaced = True
                break
        if not replaced:
            out.append(e.copy())
    return out^


# -----------------------------------------------------------------------------
# ChildSpec — what to run. Defaults: one child, inherited env + cwd, no
# rlimits.
# -----------------------------------------------------------------------------
struct ChildSpec(Movable):
    var path: String          # absolute path to the binary
    var argv: List[String]    # argv[1:]; argv[0] is defaulted to `path`
    var has_env: Bool
    var env: List[String]     # "KEY=VALUE" entries; used only when has_env
    var has_cwd: Bool
    var cwd: String           # used only when has_cwd
    var rlimits: List[RLimit] # opt-in; accepted but not applied yet
    var own_process_group: Bool  # see set_own_process_group
    var default_signals: Bool    # see set_default_signals

    def __init__(out self, path: String):
        self.path = path
        self.argv = List[String]()
        self.has_env = False
        self.env = List[String]()
        self.has_cwd = False
        self.cwd = String("")
        self.rlimits = List[RLimit]()
        self.own_process_group = False
        self.default_signals = False

    @staticmethod
    def shell(cmd: String) -> ChildSpec:
        """Convenience: run `/bin/sh -c cmd`, the shape the scenario tests
        use. Production specs use an absolute binary path + argv."""
        var spec = ChildSpec(String("/bin/sh"))
        spec.argv.append(String("-c"))
        spec.argv.append(cmd)
        return spec^

    def with_arg(mut self, arg: String):
        self.argv.append(arg)

    def set_env(mut self, var entries: List[String]):
        self.has_env = True
        self.env = entries^

    def set_env_over_inherited(mut self, overlay: List[String]) raises:
        """Deliver `overlay` to the child ON TOP OF this process's OWN
        environment, name-keyed, instead of INSTEAD OF it.

        ⛔ WHY THIS IS NOT `set_env` WITH A LONGER LIST. `set_env` is
        ALL-OR-NOTHING by construction — `posix_spawn` takes envp as a complete
        environment, and the shim's `envc == 0` arm is the only "inherit" it has.
        So a caller that wants BOTH has to compose the union itself, and the
        union has to be composed by NAME: duplicate entries in an envp array are
        resolved by whichever direction the libc `getenv` scan happens to run
        (glibc returns the FIRST match), so appending an override does not
        reliably override anything. `merge_env_overlay` replaces IN PLACE.

        ⚠ USE `set_env` WHEN THE CHILD REALLY IS A CLOSED WORLD — a container's
        env spec is a closed set and modelling it exactly is correct there. Use
        THIS when the child is a process on the operator's own machine that must
        keep the ambient credential chain, the dynamic loader's search path and
        `$HOME` while still receiving what the caller authored."""
        self.has_env = True
        self.env = merge_env_overlay(process_environ(), overlay)

    def set_cwd(mut self, dir: String):
        self.has_cwd = True
        self.cwd = dir

    def set_own_process_group(mut self):
        """The child leads a new process group (its id is the child's pid), and
        `Supervisor.terminate` / `terminate_with` signal that GROUP: the child
        and every descendant that did not leave it. Without this the child
        shares this process's group and only its pid is signalled."""
        self.own_process_group = True

    def set_default_signals(mut self):
        """Every signal starts at its default action in the child, and none is
        blocked. exec resets caught signals by itself but keeps ignored ones
        and the mask, so without this a child inherits, for example, the
        SIGPIPE this process ignores once it has made a TLS connection."""
        self.default_signals = True

    def spawn_flags(self) -> Int32:
        """The shim's spawn flags for this spec."""
        var f = Int32(0)
        if self.own_process_group:
            f |= SPAWN_OWN_PGROUP
        if self.default_signals:
            f |= SPAWN_DEFAULT_SIGNALS
        return f


# -----------------------------------------------------------------------------
# ExitInfo — decoded exit status:
#   exited normally  -> exit_code in 0..255, signal == -1
#   killed by signal -> exit_code == -1, signal == WTERMSIG
# shell_code is the 128+signal shell convention (143 for SIGTERM, 137 for
# SIGKILL) the scenario tests assert on.
# -----------------------------------------------------------------------------
@fieldwise_init
struct ExitInfo(Copyable, ImplicitlyCopyable, Movable):
    var exit_code: Int32      # 0..255 when exited normally; -1 if signaled
    var signal: Int32         # WTERMSIG when signaled; -1 otherwise
    var shell_code: Int32     # 128+signal convention; == exit_code when exited

    @staticmethod
    def from_reap(r: ReapStatus) -> ExitInfo:
        if r.exited:
            return ExitInfo(
                exit_code=r.exit_code, signal=Int32(-1),
                shell_code=r.exit_code,
            )
        elif r.signaled:
            return ExitInfo(
                exit_code=Int32(-1), signal=r.signal,
                shell_code=Int32(128) + r.signal,
            )
        else:
            # error / not-collected — sentinel
            return ExitInfo(
                exit_code=Int32(-1), signal=Int32(-1), shell_code=Int32(-1),
            )


# -----------------------------------------------------------------------------
# ReadChunk — the result of one non-blocking read_available() call. Carries the
# bytes that were ready (as an OWNED String) plus the status a caller's loop
# branches on: would_block (nothing now, child alive), eof (writers closed,
# drain done), error (genuine read error). When `text` is non-empty the status
# flags are all False (data outcome). Movable-only (owns a String).
# -----------------------------------------------------------------------------
struct ReadChunk(Movable):
    var text: String
    var eof: Bool
    var would_block: Bool
    var error: Bool

    def __init__(
        out self,
        var text: String,
        eof: Bool,
        would_block: Bool,
        error: Bool,
    ):
        self.text = text^
        self.eof = eof
        self.would_block = would_block
        self.error = error


# -----------------------------------------------------------------------------
# Supervisor — owns spawn / capture / exit / kill for ONE child.
# -----------------------------------------------------------------------------
struct Supervisor(Movable):
    var _pid: Int32
    var _pgid: Int32           # the child's own process group, or -1
    var _stdout_fd: Int32
    var _stderr_fd: Int32
    var _exited: Bool          # cached terminal state (idempotency)
    var _cached_exit: ExitInfo # valid once _exited

    def __init__(out self):
        self._pid = Int32(-1)
        self._pgid = Int32(-1)
        self._stdout_fd = Int32(-1)
        self._stderr_fd = Int32(-1)
        self._exited = False
        self._cached_exit = ExitInfo(Int32(-1), Int32(-1), Int32(-1))

    # --- lifecycle -----------------------------------------------------------

    def spawn(mut self, spec: ChildSpec) -> Int32:
        """`posix_spawn` the child with TWO separate pipes (stdout, stderr).
        Returns pid (>0) or -errno (<0). Does NOT register the reactor exit
        monitor here — see exit_monitor.watch_process_exit for that; the
        package test drives the standalone wait."""
        # argv blob: argv[0] = path, then the spec's argv[1:].
        var argv_items = List[String]()
        argv_items.append(spec.path)
        for ref a in spec.argv:
            argv_items.append(a)
        var argv_blob = build_cstr_blob(argv_items)
        var argc = len(argv_items)

        # env blob: only when the spec carries an explicit environment.
        var env_blob: List[UInt8]
        var envc: Int
        if spec.has_env:
            env_blob = build_cstr_blob(spec.env)
            envc = len(spec.env)
        else:
            env_blob = List[UInt8]()
            env_blob.append(UInt8(0))  # non-empty so unsafe_ptr() is valid
            envc = 0

        var sout = Int32(-1)
        var serr = Int32(-1)
        var pid = Int32(-1)
        var rc = proc_spawn(
            spec.path,
            argv_blob, argc,
            env_blob, envc,
            spec.cwd, spec.has_cwd,
            spec.spawn_flags(),
            sout, serr, pid,
        )
        if rc != Int32(0):
            return rc  # -errno
        self._pid = pid
        # POSIX_SPAWN_SETPGROUP with pgroup 0: the group's id is the pid, set
        # in the child before exec, so it exists by the time spawn returns.
        self._pgid = pid if spec.own_process_group else Int32(-1)
        self._stdout_fd = sout
        self._stderr_fd = serr
        return pid

    def pid(self) -> Int32:
        return self._pid

    def process_group(self) -> Int32:
        """The child's own process group id (its pid) when the spec asked for
        one, else -1."""
        return self._pgid

    def stdout_fd(self) -> Int32:
        return self._stdout_fd

    def stderr_fd(self) -> Int32:
        return self._stderr_fd

    # --- capture -------------------------------------------------------------

    def drain_pipe(mut self, fd: Int32) -> String:
        """Drain one capture pipe to EOF, returning the captured text.

        Deadlock-avoidance core: we read in a loop until read() returns 0
        (EOF), which only happens once ALL writers (the child's dup'd fd) are
        closed — i.e. after the child exits. Because we drain continuously, the
        child can emit >> one pipe buffer (the >1MB scenario) without blocking.

        ⛔ BYTE-PRESERVING — see the `_BYTES_NOT_CODEPOINTS` block above. The
        captured stream is ARBITRARY BYTES; the ONLY correct thing to do with
        them is carry them through untouched, which is what accumulating into
        an owned `List[UInt8]` and building the String ONCE does.

        Use-after-free rule, stated precisely: what dangles is a
        *borrow of `buf`* — the chunk buffer this loop REUSES on every read.
        `String(unsafe_from_utf8=Span(acc))` borrows nothing: `acc` is owned
        here and the constructor COPIES its bytes into the String (the returned
        String is intact after `acc` dies and after arbitrary further
        allocation). Owning accumulation and byte preservation do not conflict.
        """
        comptime CHUNK = 65536
        var acc = List[UInt8]()
        var buf = List[UInt8]()
        for _ in range(CHUNK):
            buf.append(UInt8(0))
        while True:
            var n = proc_read(fd, buf, CHUNK)
            if n <= 0:
                break  # EOF (0) or error (<0)
            # Bulk byte copy out of the reused chunk buffer into OUR storage.
            # Also strictly less work than N String appends.
            acc.extend(Span[UInt8](buf)[0:n])
        return String(unsafe_from_utf8=Span(acc))

    def drain_both(
        mut self, stdout_fd: Int32, stderr_fd: Int32
    ) -> Tuple[String, String]:
        """Drain BOTH capture pipes to EOF CONCURRENTLY, returning
        (stdout_text, stderr_text).

        Deadlock-avoidance core (the general fix): a sequential
        `drain_pipe(stdout)` THEN `drain_pipe(stderr)` DEADLOCKS whenever the
        child floods the not-yet-drained pipe past the ~64KB kernel pipe buffer
        while we block reading the other. The classic shape: the child writes a
        terminal marker to stdout LAST (so stdout EOFs only on child exit) but
        floods stderr first — draining stdout-to-EOF first blocks forever
        because stderr's full buffer wedges the child's write(2), so the child
        never reaches the stdout marker and never exits. Draining BOTH fds
        interleaved (each non-blocking) means neither pipe's buffer can fill
        while the other is being read, so the child never blocks on write(2).

        Mechanism: set O_NONBLOCK on both read ends, then loop issuing ONE
        non-blocking `read_available` on each still-open fd per turn. An fd that
        reports EOF is retired; the loop ends once BOTH have hit EOF. When
        neither fd had data this turn (both would_block, both still open) we
        pause a short tick so the loop doesn't busy-spin the CPU while the child
        computes. A read error on an fd retires it (treated as drain-done for
        that stream) so a genuine failure can't hang the loop.

        Behavior preserved vs. two sequential drains: stdout is captured in
        FULL (a marker parser still sees every stdout byte) and
        stderr is captured in FULL (surfaced on failure, never silently
        dropped). The two streams stay separate (two pipes).

        ⛔ BYTE-PRESERVING (see `_BYTES_NOT_CODEPOINTS` above): `read_available`
        hands back the raw bytes of each turn's read and the `+=` below is a
        BYTE concatenation, so a multi-byte character split across two turns is
        rejoined exactly. Nothing on this path decodes, at any altitude.
        """
        var out = String("")
        var err = String("")
        # Make both read ends non-blocking so a single read can never park the
        # loop (idempotent; a no-op if already O_NONBLOCK). A negative fd
        # (unopened end) is treated as already-EOF below.
        if stdout_fd >= Int32(0):
            _ = self.set_nonblocking(stdout_fd)
        if stderr_fd >= Int32(0):
            _ = self.set_nonblocking(stderr_fd)
        var out_done = stdout_fd < Int32(0)
        var err_done = stderr_fd < Int32(0)
        while not out_done or not err_done:
            var progressed = False
            if not out_done:
                var c = self.read_available(stdout_fd)
                if c.text.byte_length() > 0:
                    out += c.text
                    progressed = True
                elif c.eof or c.error:
                    out_done = True
                    progressed = True
                # else would_block: nothing ready now, leave open.
            if not err_done:
                var c = self.read_available(stderr_fd)
                if c.text.byte_length() > 0:
                    err += c.text
                    progressed = True
                elif c.eof or c.error:
                    err_done = True
                    progressed = True
                # else would_block.
            if not progressed:
                # Both open fds would_block this turn — the child is computing
                # with no output ready. Pause a short tick to avoid a busy spin;
                # we'll be woken by the next data or by EOF-on-exit.
                _sleep_ms(2)
        return (out^, err^)

    def drain_pipe_bytes(mut self, fd: Int32) -> Int:
        """Drain one capture pipe to EOF, returning the byte count only (no
        String materialization) — used by the >1MB no-deadlock scenario to
        avoid building a megabyte String."""
        comptime CHUNK = 65536
        var total = 0
        var buf = List[UInt8]()
        for _ in range(CHUNK):
            buf.append(UInt8(0))
        while True:
            var n = proc_read(fd, buf, CHUNK)
            if n <= 0:
                break
            total += n
        return total

    # --- incremental (non-blocking) capture ----------------------------------

    def set_nonblocking(self, fd: Int32) -> Int32:
        """Set O_NONBLOCK on a capture-pipe read end so read_available never
        parks the caller. Returns 0 / -errno. Call once per fd after spawn
        (idempotent); a run loop that also heartbeats does this for stdout_fd +
        stderr_fd so a single incremental drain read can't block it."""
        if fd < Int32(0):
            return Int32(-1)
        return proc_set_nonblocking(fd)

    def read_available(mut self, fd: Int32) -> ReadChunk:
        """ONE non-blocking read: return whatever bytes are ready RIGHT NOW
        (does NOT loop to EOF — that's drain_pipe). The fd must be O_NONBLOCK
        (set_nonblocking) so the read can't block.

        Returns a ReadChunk whose status is exactly one of:
          * text non-empty + eof=False  -> these bytes are ready; more may be
            waiting — the caller may call again immediately (a hot child can be
            drained in a tight inner loop until would_block).
          * would_block=True            -> nothing ready now, child still alive;
            poll again next loop iteration.
          * eof=True                    -> all writers closed (child exited /
            closed the fd); the pipe is fully drained — no more data ever.
          * error=True                  -> a genuine read error; stop draining.

        ⛔ BYTE-PRESERVING — see the `_BYTES_NOT_CODEPOINTS` block above. This
        is the site the whole `drain_both` path runs through, so a transcode
        here corrupts EVERY incrementally-drained stream.

        ⚠ A CHUNK BOUNDARY MAY SPLIT A MULTI-BYTE CHARACTER, and that is fine
        *because* nothing here decodes: the split halves come back as two
        Strings holding the raw byte fragments, and `drain_both`'s `+=` is a
        BYTE concatenation that rejoins them exactly (`4d e2` then
        `80 94 45` concatenates to `4d e2 80 94 45`). A decoder at this seam
        could not do that — it would have to either mangle the fragment or
        carry decoder state across calls.
        """
        comptime CHUNK = 65536
        if fd < Int32(0):
            return ReadChunk(String(""), eof=True, would_block=False, error=False)
        var buf = List[UInt8]()
        for _ in range(CHUNK):
            buf.append(UInt8(0))
        var r = proc_read_avail(fd, buf, CHUNK)
        if r.bytes > 0:
            # ONE copy out of the read buffer. `buf` is dead after this call;
            # the constructor copies, so nothing borrows it (see drain_pipe).
            return ReadChunk(
                String(unsafe_from_utf8=Span[UInt8](buf)[0 : r.bytes]),
                eof=False, would_block=False, error=False,
            )
        return ReadChunk(
            String(""), eof=r.eof, would_block=r.would_block, error=r.error
        )

    # --- exit detection ------------------------------------------------------

    def wait_exit(mut self) -> ExitInfo:
        """Block until the child exits, then waitpid-reap exactly once.

        Production: awaits the reactor "child N exited" completion (posted by
        EVFILT_PROC / pidfd EPOLLIN) then reaps. This package-level form uses a
        blocking reap (waitpid without WNOHANG) — the child has been observed
        to exit (e.g. via the capture-pipe EOF or the standalone exit monitor)
        so the blocking reap returns promptly and clears the zombie.

        Idempotent: a second call after the child was already reaped returns
        the cached ExitInfo (no double-waitpid -> no ECHILD surprise).
        """
        if self._exited:
            return self._cached_exit
        var r = proc_reap(self._pid, nohang=False)
        var info = ExitInfo.from_reap(r)
        if r.collected:
            self._exited = True
            self._cached_exit = info
        return info

    def try_wait(mut self) -> ReapStatus:
        """Non-blocking WNOHANG reap. collected==True means the child
        terminated and was reaped (caches ExitInfo). Used by terminate()'s
        grace-period poll and by tests asserting no-zombie."""
        if self._exited:
            return ReapStatus(
                collected=True, error=False,
                exited=self._cached_exit.signal == Int32(-1),
                exit_code=self._cached_exit.exit_code,
                signaled=self._cached_exit.signal != Int32(-1),
                signal=self._cached_exit.signal,
            )
        var r = proc_reap(self._pid, nohang=True)
        if r.collected:
            self._exited = True
            self._cached_exit = ExitInfo.from_reap(r)
        return r

    # --- cancellation: SIGTERM -> grace -> SIGKILL ---------------------------

    def terminate(mut self, grace_ms: Int) -> ExitInfo:
        """The cancellation ladder: SIGTERM, wait up to
        grace_ms for the child to exit, escalate to SIGKILL (uncatchable) if it
        is still alive. Exactly-once / idempotent: a call after the child has
        already exited returns the cached ExitInfo without re-signaling.
        `terminate_with(SIGTERM, grace_ms, False)`; see there for a child that
        leads its own process group.

        Production drives the grace wait off the reactor exit completion with a
        deadline (no busy-poll). This package-level form polls try_wait at a
        10ms tick; the reactor variant is a drop-in for a caller that awaits
        watch_process_exit's completion with a deadline.
        """
        return self.terminate_with(SIGTERM, grace_ms, False)

    def terminate_with(
        mut self, sig: Int32, grace_ms: Int, reap_orphans: Bool
    ) -> ExitInfo:
        """The ladder from `sig` (SIGTERM, or a forwarded SIGINT): send it,
        wait up to `grace_ms`, then SIGKILL. Cached and not re-sent once the
        child has been reaped.

        For a child spawned with `set_own_process_group`, every signal goes to
        the GROUP, and the grace wait lasts until the child is reaped AND the
        group is empty (or the grace runs out), so a grandchild that is still
        shutting down is not cut short, and one that ignored `sig` is
        SIGKILLed with the rest. With `reap_orphans`, each tick also collects
        exited orphans (`reap_orphans()`): a descendant re-parented to this
        process stays in the group as a zombie until collected. Pass it only
        when this process owns every child it has (see `reap_orphans`).
        Without an own group: the child's pid only, as `terminate` always did."""
        if self._exited:
            return self._cached_exit

        _ = self._signal_child(sig)
        var waited = 0
        while waited < grace_ms:
            var r = self.try_wait()
            if reap_orphans:
                _ = self.reap_orphans()
            if r.collected and not self._group_alive():
                return self._cached_exit
            _sleep_ms(10)  # 10ms tick
            waited += 10

        # Still alive after grace -> escalate. SIGKILL cannot be trapped.
        _ = self._signal_child(SIGKILL)
        var info = self._cached_exit
        if not self._exited:
            # Blocking reap — SIGKILL is delivered promptly.
            var r2 = proc_reap(self._pid, nohang=False)
            info = ExitInfo.from_reap(r2)
            if r2.collected:
                self._exited = True
                self._cached_exit = info
        if reap_orphans:
            # The SIGKILLed rest of the group become zombies of this process
            # (the re-parented ones) a moment later; collect them, bounded.
            var settle = 0
            while settle < 1000:
                _ = self.reap_orphans()
                if not self._group_alive():
                    break
                _sleep_ms(10)
                settle += 10
        return info

    def _signal_child(self, sig: Int32) -> Int32:
        """`sig` to the child's own group when it leads one, else its pid."""
        if self._pgid > Int32(1):
            return proc_kill_group(self._pgid, sig)
        return proc_kill(self._pid, sig)

    def _group_alive(self) -> Bool:
        """Whether any process (a zombie included) is still in the child's own
        group. False without an own group."""
        if self._pgid <= Int32(1):
            return False
        return proc_kill_group(self._pgid, Int32(0)) == Int32(0)

    def reap_orphans(self) -> Int:
        """Collect, without blocking, every exited child of this process except
        this Supervisor's own (whose status `wait_exit` / `try_wait` keep).
        Returns how many (0 on failure). This is how a PID 1 or a child
        subreaper (komira_supervisor.pid1) clears the zombies of the orphans
        re-parented to it.

        ONLY for a process that owns every child it has: in a process running
        several Supervisors it would collect a sibling's child, whose
        `wait_exit` would then fail."""
        comptime MAX_PER_CALL = 256
        var n = proc_reap_orphans(self._pid, Int32(MAX_PER_CALL))
        if n < Int32(0):
            return 0
        return Int(n)

    def signal(self, sig: Int32) -> Int32:
        """Raw kill(pid, sig). Returns 0 / -errno."""
        return proc_kill(self._pid, sig)

    # --- teardown ------------------------------------------------------------

    def close(mut self):
        """Close any open capture-pipe fds (idempotent). Does NOT reap — call
        wait_exit / terminate for that. Production also deregisters the reactor
        exit-monitor fd (pidfd) here."""
        if self._stdout_fd >= Int32(0):
            proc_close(self._stdout_fd)
            self._stdout_fd = Int32(-1)
        if self._stderr_fd >= Int32(0):
            proc_close(self._stderr_fd)
            self._stderr_fd = Int32(-1)
