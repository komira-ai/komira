# =============================================================================
# komira_async.reactor.kqueue_subsystem — Darwin/BSD kqueue backend
# =============================================================================
# The full kqueue completion-queue implementation.
#
# kqueue's submit+poll model maps cleanly to the
# planned Reactor[S] API. ONE upper-layer abstraction; per-backend FFI thunks
# differ in syscall shape (epoll = two syscalls per op: epoll_ctl + epoll_wait;
# kqueue = one syscall does both via changelist+eventlist) but converge at
# the typed-scalar boundary. NO structural concessions to the Reactor[S]
# shape are required.
#
#
# Linux build: the wrong-OS FFI symbols are
# ELIDED at codegen on Linux (nm -D shows kqueue absent in the Linux ELF
# binary), so this file compiles cleanly on Linux but its bodies are
# functional only on Darwin.
#
# Pointer discipline (FFI carve-out):
#   - All public functions return Int32 / Int / void (typed scalars).
#   - UnsafePointer is INTERNAL TO THIS MODULE only — confined to the FFI
#     thunks below; each thunk carries a # SAFETY: comment.
#   - No wildcard origins on any public surface.
#   - Wrong-OS branches (Linux) raise an explicit "Darwin only" Error per
#     the per-platform comptime if discipline.
# =============================================================================

from std.sys.info import CompilationTarget
from std.ffi import external_call


@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin (replaces the b2-removed
    `_null_ptr[T, o]()` null ctor).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer (modular/mojo/proposals/non-null-pointer.md); `None` is the all-zero
    # (NULL) bit pattern. Used only for NULL syscall arguments below.
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]


# -----------------------------------------------------------------------------
# Constants — Darwin/BSD ABI (`<sys/event.h>`).
# -----------------------------------------------------------------------------

# Filter identifiers (negative int16):
comptime EVFILT_READ: Int16 = Int16(-1)
comptime EVFILT_WRITE: Int16 = Int16(-2)
comptime EVFILT_PROC: Int16 = Int16(-5)    # process exit/fork/exec monitor
comptime EVFILT_USER: Int16 = Int16(-10)   # cross-thread wake (eventfd analog)
comptime EVFILT_TIMER: Int16 = Int16(-7)   # for future timer integration

# Action flags (uint16). Combined via bitwise OR.
comptime EV_ADD: UInt16 = UInt16(0x0001)        # add event to kqueue
comptime EV_DELETE: UInt16 = UInt16(0x0002)     # remove event from kqueue
comptime EV_ENABLE: UInt16 = UInt16(0x0004)     # arm an EV_DISABLE'd event
comptime EV_DISABLE: UInt16 = UInt16(0x0008)    # quiesce without removing
comptime EV_ONESHOT: UInt16 = UInt16(0x0010)    # auto-deregister after firing
comptime EV_CLEAR: UInt16 = UInt16(0x0020)      # edge-triggered (epoll's EPOLLET)
comptime EV_RECEIPT: UInt16 = UInt16(0x0040)    # force per-change EV_ERROR reply
comptime EV_DISPATCH: UInt16 = UInt16(0x0080)   # auto-disable after firing
comptime EV_EOF: UInt16 = UInt16(0x8000)        # output: peer hung up
comptime EV_ERROR: UInt16 = UInt16(0x4000)      # output: error in this kevent

# fflags for EVFILT_USER (uint32).
comptime NOTE_TRIGGER: UInt32 = UInt32(0x01000000)  # fire the user event

# fflags for EVFILT_PROC (uint32). NOTE_EXIT fires when the watched process
# exits — the reactor-clean child-exit monitor
# for a process supervisor. Child exit becomes a normal kevent on
# the long-lived reactor kqueue; NO SIGCHLD handler.
comptime NOTE_EXIT: UInt32 = UInt32(0x80000000)     # process exited

# fflags for EVFILT_TIMER (uint32) — time-unit selectors for the `data` field.
# 3: the macOS analog of timerfd. A
# one-shot EVFILT_TIMER (EV_ONESHOT) fires once after `data` nanoseconds, then
# auto-deregisters — routing through the SAME kevent_wait_decode path as a
# socket read, with the parked-stream op_id echoed in udata.
comptime NOTE_SECONDS: UInt32 = UInt32(0x00000001)  # data is in seconds
comptime NOTE_USECONDS: UInt32 = UInt32(0x00000002) # data is in microseconds
comptime NOTE_NSECONDS: UInt32 = UInt32(0x00000004) # data is in nanoseconds

comptime MAX_EVENTS_PER_WAIT: Int = 64

# Mode sentinels (mirrors epoll_subsystem.mojo MODE_READ / MODE_WRITE).
comptime MODE_READ: UInt8 = 1
comptime MODE_WRITE: UInt8 = 2

# Sentinel udata for the per-reactor wake event (analogous to the
# OP_ID_WAKE_EVENTFD route in reactor.mojo). Mirrors epoll's data=cookie
# pattern; kqueue's udata field carries the same role.
comptime OP_ID_WAKE_USER: Int64 = Int64(-1)


# -----------------------------------------------------------------------------
# KEvent — packed 32-byte struct kevent (Darwin x86_64 / arm64).
#
# C declaration (xnu `bsd/sys/event.h`):
#     struct kevent {
#         uintptr_t  ident;    // 8 bytes — typically an fd or arbitrary id
#         int16_t    filter;   // 2 bytes — EVFILT_* (negative)
#         uint16_t   flags;    // 2 bytes — EV_* action flags
#         uint32_t   fflags;   // 4 bytes — filter-specific flags
#         intptr_t   data;     // 8 bytes — filter-specific output (e.g., bytes available)
#         void *     udata;    // 8 bytes — opaque cookie (we use as op_id)
#     };  // total 32 bytes, naturally aligned, no padding on LP64.
# -----------------------------------------------------------------------------

@fieldwise_init
struct KEvent(
    TrivialRegisterPassable,
    Copyable,
    ImplicitlyCopyable,
    Movable,
    Deinitable,
):
    """Decoded kevent. Field roles:
      `ident`: fd for EVFILT_READ/WRITE; arbitrary uint for EVFILT_USER.
      `filter`: which kernel filter produced (or will produce) this event.
      `flags`: EV_* on input; on output may carry EV_EOF / EV_ERROR.
      `fflags`: filter-specific. For EVFILT_USER on wake: NOTE_TRIGGER.
      `data`: bytes-available for read/write; error code if EV_ERROR.
      `udata`: 8-byte opaque cookie. We pack the op_id here.
    """

    var ident: UInt64
    var filter: Int16
    var flags: UInt16
    var fflags: UInt32
    var data: Int64
    var udata: UInt64


# -----------------------------------------------------------------------------
# Darwin-only FFI block. `@parameter if CompilationTarget.is_macos()` per
# the canonical 0.26.3 idiom (epoll_subsystem.mojo sets the precedent).
# -----------------------------------------------------------------------------


def kqueue_create() raises -> Int32:
    """Create a kqueue fd (Darwin only). Wraps `kqueue()`.

    Returns the kqueue fd (auto-CLOEXEC'd via fcntl). Raises on syscall
    error. Wrong-OS callers raise the explicit "Darwin only" diagnostic.

    NOTE: kqueue() does NOT take a flags arg (unlike epoll_create1 which
    accepts EPOLL_CLOEXEC). On Darwin/BSD we set FD_CLOEXEC via a follow-up
    fcntl, mirroring tokio/mio's selector::new shape.
    """
    comptime if CompilationTarget.is_macos():
        var fd = external_call["kqueue", Int32]()
        if fd < 0:
            raise Error("kqueue() failed")
        # set FD_CLOEXEC via the
        # non-variadic shim. The 3-arg `fcntl(fd, F_SETFD, FD_CLOEXEC)`
        # call previously here is variadic-fragile under Apple's ARM64
        # ABI; route through `komira_fcntl_set_cloexec` instead.
        # See `_posix_shim.c` and `socket_setup.mojo` for the full
        # rationale. Match mio's behavior.
        _ = external_call["komira_fcntl_set_cloexec", Int32](fd)
        return fd
    else:
        raise Error("KQueueSubsystem.kqueue_create: Darwin only")


def kqueue_close(kq_fd: Int32):
    """Close a kqueue fd. Idempotent if fd < 0 (sentinel)."""
    comptime if CompilationTarget.is_macos():
        if kq_fd >= 0:
            _ = external_call["close", Int32](kq_fd)


def _kevent_call(
    kq_fd: Int32,
    changelist_ptr: UnsafePointer[UInt8, MutUntrackedOrigin],
    nchanges: Int32,
    eventlist_ptr: UnsafePointer[UInt8, MutUntrackedOrigin],
    nevents: Int32,
    timeout_ptr: UnsafePointer[UInt8, MutUntrackedOrigin],
) -> Int32:
    """Single FFI thunk over kevent(2) — combined submit + retrieve.
    Internal-to-this-module helper; never escapes a typed boundary.

    SAFETY: caller passes pointers to stack-local InlineArray buffers OR
    a NULL sentinel for timeout / changelist / eventlist (constructed
    via `_null_ptr[T, MutExternalOrigin]()`). The kernel
    reads from changelist and writes up to `nevents` into eventlist;
    pointers are not retained past the syscall return.

    Note: an earlier attempt typed the
    null-permitting parameters as `Optional[UnsafePointer[...]]`,
    but the Mojo 1.0.0-b1 AOT compiler cannot lower
    `Optional[UnsafePointer]` arguments to `pop.external_call` (struct
    layout `kgen.struct<(struct<(struct<(struct<(pointer<none>) memoryOnly>)>)>)>`
    fails LowerToLLVMPipeline). Reverted to the raw `UnsafePointer` shape
    with `_unsafe_null=()` at NULL call sites — non-deprecated AND
    AOT-compatible.

    Returns the number of events placed in eventlist (>= 0), or -1 on error
    with errno set. We coerce errors to "0 events ready" + propagate via
    EV_ERROR per-change semantics (when EV_RECEIPT is set on the changelist).
    """
    comptime if CompilationTarget.is_macos():
        return external_call["kevent", Int32](
            kq_fd, changelist_ptr, nchanges,
            eventlist_ptr, nevents, timeout_ptr,
        )
    else:
        return Int32(-1)


# -----------------------------------------------------------------------------
# Encoding / decoding of struct kevent — confined to this module.
#
# We use InlineArray[UInt8, 32] for each kevent slot (struct kevent is exactly
# 32 bytes on Darwin LP64). This mirrors epoll_subsystem.mojo's pattern
# (InlineArray[UInt8, 12] for struct epoll_event); the kernel reads/writes
# bytes, we encode/decode at the boundary.
# -----------------------------------------------------------------------------


def _encode_kevent(
    mut buf: Array[UInt8, 32],
    ident: UInt64,
    filter: Int16,
    flags: UInt16,
    fflags: UInt32,
    data: Int64,
    udata: UInt64,
):
    """Pack a kevent into the 32-byte buffer. Field offsets per the C decl."""
    # ident: 8 bytes at offset 0
    for i in range(8):
        buf[i] = UInt8((ident >> UInt64(8 * i)) & UInt64(0xFF))
    # filter: 2 bytes at offset 8 (signed; 2's complement byte layout)
    var f_u = UInt16(filter.cast[DType.uint16]())  # bit-pattern reinterpret
    buf[8] = UInt8(f_u & UInt16(0xFF))
    buf[9] = UInt8((f_u >> UInt16(8)) & UInt16(0xFF))
    # flags: 2 bytes at offset 10
    buf[10] = UInt8(flags & UInt16(0xFF))
    buf[11] = UInt8((flags >> UInt16(8)) & UInt16(0xFF))
    # fflags: 4 bytes at offset 12
    for i in range(4):
        buf[12 + i] = UInt8((fflags >> UInt32(8 * i)) & UInt32(0xFF))
    # data: 8 bytes at offset 16
    var d_u = UInt64(data.cast[DType.uint64]())
    for i in range(8):
        buf[16 + i] = UInt8((d_u >> UInt64(8 * i)) & UInt64(0xFF))
    # udata: 8 bytes at offset 24
    for i in range(8):
        buf[24 + i] = UInt8((udata >> UInt64(8 * i)) & UInt64(0xFF))


def _decode_kevent(buf: Array[UInt8, 32]) -> KEvent:
    """Unpack a kevent from the 32-byte buffer."""
    var ident = UInt64(0)
    for i in range(8):
        ident = ident | (UInt64(buf[i]) << UInt64(8 * i))
    var f_u = UInt16(buf[8]) | (UInt16(buf[9]) << UInt16(8))
    var filter = Int16(f_u.cast[DType.int16]())  # bit-pattern reinterpret
    var flags = UInt16(buf[10]) | (UInt16(buf[11]) << UInt16(8))
    var fflags = UInt32(0)
    for i in range(4):
        fflags = fflags | (UInt32(buf[12 + i]) << UInt32(8 * i))
    var d_u = UInt64(0)
    for i in range(8):
        d_u = d_u | (UInt64(buf[16 + i]) << UInt64(8 * i))
    var data = Int64(d_u.cast[DType.int64]())
    var udata = UInt64(0)
    for i in range(8):
        udata = udata | (UInt64(buf[24 + i]) << UInt64(8 * i))
    return KEvent(
        ident=ident, filter=filter, flags=flags,
        fflags=fflags, data=data, udata=udata,
    )


# -----------------------------------------------------------------------------
# High-level FFI thunks — typed-scalar parameters, typed-scalar returns.
# Parallel to the epoll_ctl_add / epoll_ctl_del / epoll_wait_decode trio.
# -----------------------------------------------------------------------------


def kevent_register(
    kq_fd: Int32,
    fd: Int32,
    filter: Int16,        # EVFILT_READ or EVFILT_WRITE
    cookie: UInt64,       # op_id (echoed back in udata)
    edge_triggered: Bool, # True → set EV_CLEAR (EPOLLET analog)
) raises:
    """Register `fd` for the given filter under `cookie`.

    Equivalent to `epoll_ctl(EPOLL_CTL_ADD, fd, EPOLLIN | maybe EPOLLET,
    data=cookie)`. Edge-triggered when `edge_triggered=True` (matches the
 EPOLLET / EV_CLEAR pairing required by try_io).

    EV_RECEIPT is set so the kernel returns EV_ERROR per-change rather
    than failing the whole syscall — uniform error handling.
    """
    comptime if CompilationTarget.is_macos():
        var flags = EV_ADD | EV_RECEIPT
        if edge_triggered:
            flags = flags | EV_CLEAR
        var change = Array[UInt8, 32](fill=UInt8(0))
        # SAFETY: change is stack-local; kernel reads only; not retained.
        # anchor lifetime past the syscall.
        _encode_kevent(
            change, UInt64(fd), filter, flags,
            UInt32(0), Int64(0), cookie,
        )
        var ack_buf = Array[UInt8, 32](fill=UInt8(0))
        var n = _kevent_call(
            kq_fd, change.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](), Int32(1),
            ack_buf.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](), Int32(1),
            _null_ptr[UInt8, MutUntrackedOrigin](),
        )
        # Anchor lifetimes past the syscall (MutExternalOrigin defeats
        # the lifetime tracker; without these reads the InlineArrays
        # could be freed before the kernel reads/writes them).
        _ = change[0]
        _ = ack_buf[0]
        if n < 0:
            raise Error("kevent(ADD) syscall failed")
        if n > 0:
            var ack = _decode_kevent(ack_buf)
            if (ack.flags & EV_ERROR) != UInt16(0) and ack.data != Int64(0):
                raise Error("kevent(ADD) per-change error")
    else:
        raise Error("kevent_register: Darwin only")


def kevent_register_proc_exit(
    kq_fd: Int32, pid: Int32, cookie: UInt64,
) raises:
    """register process-exit monitoring for `pid`
    on the long-lived reactor kqueue.

    Equivalent to a fresh-kqueue EVFILT_PROC registration, but folded
    into the reactor's own kqueue alongside the existing READ/WRITE/USER/TIMER
    registrations. The kernel posts a NOTE_EXIT
    kevent (ident=pid, udata=cookie) when the child exits — child exit becomes
    a NORMAL reactor event with NO SIGCHLD handler.

    Uses EV_ONESHOT: the exit fires exactly once and auto-deregisters. The
    registration reuses the existing _encode_kevent thunk unchanged — only the
    filter (EVFILT_PROC) and fflags (NOTE_EXIT) differ from kevent_register.

    NOTE: NOTE_EXIT is a NOTIFICATION, not a reaper. The supervisor still
    waitpid-reaps after the completion to clear the zombie.
    """
    comptime if CompilationTarget.is_macos():
        var change = Array[UInt8, 32](fill=UInt8(0))
        # SAFETY: change is stack-local; kernel reads only; not retained.
        # ident = pid (not an fd); fflags = NOTE_EXIT; EV_ONESHOT auto-dereg.
        _encode_kevent(
            change, UInt64(pid), EVFILT_PROC,
            EV_ADD | EV_ONESHOT | EV_RECEIPT,
            NOTE_EXIT, Int64(0), cookie,
        )
        var ack_buf = Array[UInt8, 32](fill=UInt8(0))
        var n = _kevent_call(
            kq_fd, change.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](), Int32(1),
            ack_buf.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](), Int32(1),
            _null_ptr[UInt8, MutUntrackedOrigin](),
        )
        # Anchor lifetimes past the syscall (MutExternalOrigin defeats the
        # lifetime tracker; without these reads the InlineArrays could be
        # freed before the kernel reads/writes them).
        _ = change[0]
        _ = ack_buf[0]
        if n < 0:
            raise Error("kevent(EVFILT_PROC add) syscall failed")
        if n > 0:
            var ack = _decode_kevent(ack_buf)
            if (ack.flags & EV_ERROR) != UInt16(0) and ack.data != Int64(0):
                # ESRCH (no such process) can fire if the child exited between
                # spawn and registration — surface so the caller reaps directly.
                raise Error("kevent(EVFILT_PROC add) per-change error")
    else:
        raise Error("kevent_register_proc_exit: Darwin only")


def kevent_register_timer(
    kq_fd: Int32, timer_ident: UInt64, deadline_ns: Int64, cookie: UInt64,
) raises:
    """The macOS analog of timerfd.
    Register a ONE-SHOT EVFILT_TIMER that fires once after `deadline_ns`
    nanoseconds, echoing `cookie` (the parked-stream op_id) in udata, then
    auto-deregisters (EV_ONESHOT).

    `timer_ident` is an arbitrary uint identifying the timer (EVFILT_TIMER's
    `ident` is NOT an fd — kqueue uses it as a logical timer id). The Reactor
    passes the biased op_id itself so the (ident, filter) pair is unique per
    parked stream.

    Routes through kevent_wait_decode EXACTLY like a socket read — the parked
    frame keyed on `cookie` in the ParkedMorselSlab resumes via the existing
    path with zero driver change. The kqueue analog needs NO drain (EV_ONESHOT
    auto-deregisters; the timer fires once and is gone), unlike the Linux
    timerfd which must be drained + closed.

    `deadline_ns <= 0` arms a ~1ns timer (fires almost immediately).
    """
    comptime if CompilationTarget.is_macos():
        var ns = deadline_ns
        if ns <= Int64(0):
            ns = Int64(1)
        var change = Array[UInt8, 32](fill=UInt8(0))
        # SAFETY: change is stack-local; kernel reads only; not retained.
        # ident = timer_ident (a logical id, NOT an fd); filter = EVFILT_TIMER;
        # fflags = NOTE_NSECONDS (data interpreted as nanoseconds); data = ns;
        # EV_ONESHOT auto-deregisters after the single fire.
        _encode_kevent(
            change, timer_ident, EVFILT_TIMER,
            EV_ADD | EV_ONESHOT | EV_RECEIPT,
            NOTE_NSECONDS, ns, cookie,
        )
        var ack_buf = Array[UInt8, 32](fill=UInt8(0))
        var n = _kevent_call(
            kq_fd, change.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](), Int32(1),
            ack_buf.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](), Int32(1),
            _null_ptr[UInt8, MutUntrackedOrigin](),
        )
        # Anchor lifetimes past the syscall (MutExternalOrigin defeats the
        # lifetime tracker; without these reads the InlineArrays could be
        # freed before the kernel reads/writes them).
        _ = change[0]
        _ = ack_buf[0]
        if n < 0:
            raise Error("kevent(EVFILT_TIMER add) syscall failed")
        if n > 0:
            var ack = _decode_kevent(ack_buf)
            if (ack.flags & EV_ERROR) != UInt16(0) and ack.data != Int64(0):
                raise Error("kevent(EVFILT_TIMER add) per-change error")
    else:
        raise Error("kevent_register_timer: Darwin only")


def kevent_deregister_timer(kq_fd: Int32, timer_ident: UInt64):
    """Remove a one-shot EVFILT_TIMER before it fires (early teardown of a
    parked stream). Best-effort; ENOENT is benign (the EV_ONESHOT may already
    have fired and auto-deregistered)."""
    comptime if CompilationTarget.is_macos():
        if kq_fd < 0:
            return
        var change = Array[UInt8, 32](fill=UInt8(0))
        # SAFETY: stack-local; kernel reads only.
        _encode_kevent(
            change, timer_ident, EVFILT_TIMER, EV_DELETE | EV_RECEIPT,
            UInt32(0), Int64(0), UInt64(0),
        )
        var ack_buf = Array[UInt8, 32](fill=UInt8(0))
        _ = _kevent_call(
            kq_fd, change.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](), Int32(1),
            ack_buf.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](), Int32(1),
            _null_ptr[UInt8, MutUntrackedOrigin](),
        )
        _ = change[0]
        _ = ack_buf[0]


def kevent_deregister_proc_exit(kq_fd: Int32, pid: Int32):
    """Remove a process-exit watch. Best-effort; ENOENT is benign (the
    EV_ONESHOT may already have fired and auto-deregistered)."""
    comptime if CompilationTarget.is_macos():
        if kq_fd < 0 or pid < 0:
            return
        var change = Array[UInt8, 32](fill=UInt8(0))
        # SAFETY: stack-local; kernel reads only.
        _encode_kevent(
            change, UInt64(pid), EVFILT_PROC, EV_DELETE | EV_RECEIPT,
            UInt32(0), Int64(0), UInt64(0),
        )
        var ack_buf = Array[UInt8, 32](fill=UInt8(0))
        _ = _kevent_call(
            kq_fd, change.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](), Int32(1),
            ack_buf.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](), Int32(1),
            _null_ptr[UInt8, MutUntrackedOrigin](),
        )
        _ = change[0]
        _ = ack_buf[0]


def kevent_deregister(kq_fd: Int32, fd: Int32, filter: Int16):
    """Remove fd's filter from the kqueue. Best-effort; ENOENT is benign
    (matches epoll_ctl_del's swallow-ENOENT contract).

    Equivalent to `epoll_ctl(EPOLL_CTL_DEL, fd, NULL)` BUT kqueue requires
    one delete per (fd, filter) pair. If we registered both READ and WRITE,
    deregister must be called twice.
    """
    comptime if CompilationTarget.is_macos():
        if kq_fd < 0 or fd < 0:
            return
        var change = Array[UInt8, 32](fill=UInt8(0))
        # SAFETY: stack-local; kernel reads only. anchor.
        _encode_kevent(
            change, UInt64(fd), filter, EV_DELETE | EV_RECEIPT,
            UInt32(0), Int64(0), UInt64(0),
        )
        var ack_buf = Array[UInt8, 32](fill=UInt8(0))
        _ = _kevent_call(
            kq_fd, change.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](), Int32(1),
            ack_buf.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](), Int32(1),
            _null_ptr[UInt8, MutUntrackedOrigin](),
        )
        _ = change[0]
        _ = ack_buf[0]


def kevent_modify_enable(
    kq_fd: Int32, fd: Int32, filter: Int16,
) raises:
    """Re-arm a previously-EV_DISABLE'd kevent.

    Used by `Reactor.modify` to flip a long-lived kqueue registration
    between READ / WRITE / both (per — kqueue's analog of
    epoll's EPOLL_CTL_MOD).
    """
    comptime if CompilationTarget.is_macos():
        if kq_fd < 0 or fd < 0:
            return
        var change = Array[UInt8, 32](fill=UInt8(0))
        # SAFETY: stack-local; kernel reads only. anchor.
        _encode_kevent(
            change, UInt64(fd), filter, EV_ENABLE | EV_RECEIPT,
            UInt32(0), Int64(0), UInt64(0),
        )
        var ack_buf = Array[UInt8, 32](fill=UInt8(0))
        var n = _kevent_call(
            kq_fd, change.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](), Int32(1),
            ack_buf.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](), Int32(1),
            _null_ptr[UInt8, MutUntrackedOrigin](),
        )
        _ = change[0]
        _ = ack_buf[0]
        if n < 0:
            raise Error("kevent(ENABLE) failed")
        if n > 0:
            var ack = _decode_kevent(ack_buf)
            if (ack.flags & EV_ERROR) != UInt16(0) and ack.data != Int64(0):
                raise Error("kevent(ENABLE) per-change error")
    else:
        raise Error("kevent_modify_enable: Darwin only")


def kevent_modify_disable(
    kq_fd: Int32, fd: Int32, filter: Int16,
) raises:
    """Disable an active kevent without removing it.

    Used by `Reactor.modify` for the converse of `kevent_modify_enable`.
    """
    comptime if CompilationTarget.is_macos():
        if kq_fd < 0 or fd < 0:
            return
        var change = Array[UInt8, 32](fill=UInt8(0))
        # anchor lifetimes.
        _encode_kevent(
            change, UInt64(fd), filter, EV_DISABLE | EV_RECEIPT,
            UInt32(0), Int64(0), UInt64(0),
        )
        var ack_buf = Array[UInt8, 32](fill=UInt8(0))
        var n = _kevent_call(
            kq_fd, change.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](), Int32(1),
            ack_buf.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](), Int32(1),
            _null_ptr[UInt8, MutUntrackedOrigin](),
        )
        _ = change[0]
        _ = ack_buf[0]
        if n < 0:
            raise Error("kevent(DISABLE) failed")
        if n > 0:
            var ack = _decode_kevent(ack_buf)
            if (ack.flags & EV_ERROR) != UInt16(0) and ack.data != Int64(0):
                raise Error("kevent(DISABLE) per-change error")
    else:
        raise Error("kevent_modify_disable: Darwin only")


def kevent_wait_decode(
    kq_fd: Int32,
    mut events: List[KEvent],
    timeout_us: Int64,
) raises -> Int:
    """Block up to `timeout_us` microseconds for ready events; decode into
    `events` (cleared first). Returns the number of ready events.

    Equivalent to `epoll_wait(epoll_fd, &events, MAX, timeout_ms)`.
    `timeout_us = -1` means block indefinitely (NULL timespec); `timeout_us
    = 0` means non-blocking poll (zero timespec).

    SAFETY: raw is stack-local; kernel writes up to MAX_EVENTS_PER_WAIT *
    32 bytes. Pointers do not cross the module boundary.
    """
    comptime if CompilationTarget.is_macos():
        var raw = Array[UInt8, MAX_EVENTS_PER_WAIT * 32](
            fill=UInt8(0)
        )
        # struct timespec = {tv_sec: int64, tv_nsec: int64} = 16 bytes.
        # the previous implementation built
        # `ts_ptr` outside the syscall scope and let the InlineArray
        # `ts_buf` go out of scope while the pointer was still in use —
        # `MutExternalOrigin` defeats lifetime tracking, so the
        # InlineArray's storage was freed before the kernel read it,
        # producing EINVAL (errno 22) at every kevent_wait. The fix
        # makes the syscall in TWO branches (NULL vs zero/non-zero
        # timespec) so the InlineArray + the syscall live in the same
        # scope and the borrow checker keeps `ts_buf` alive through
        # the call.
        var n: Int32
        if timeout_us < Int64(0):
            # NULL timespec → block forever. No InlineArray needed.
            n = _kevent_call(
                kq_fd,
                _null_ptr[UInt8, MutUntrackedOrigin](),
                Int32(0),
                raw.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](),
                Int32(MAX_EVENTS_PER_WAIT),
                _null_ptr[UInt8, MutUntrackedOrigin](),
            )
        else:
            var ts_buf = Array[UInt8, 16](fill=UInt8(0))
            var ts_sec = timeout_us // Int64(1_000_000)
            var ts_nsec = (timeout_us % Int64(1_000_000)) * Int64(1_000)
            for i in range(8):
                ts_buf[i] = UInt8(
                    (UInt64(ts_sec) >> UInt64(8 * i)) & UInt64(0xFF)
                )
            for i in range(8):
                ts_buf[8 + i] = UInt8(
                    (UInt64(ts_nsec) >> UInt64(8 * i)) & UInt64(0xFF)
                )
            # SAFETY: ts_buf is stack-local; the syscall happens in
            # this same `else` block before ts_buf goes out of scope.
            # `unsafe_origin_cast` widens to MutExternalOrigin for the
            # FFI thunk; ts_buf must not move/free before the call
            # returns. Issuing the call IN-LINE (not via a hoisted
            # `ts_ptr` variable) keeps the borrow chain intact.
            n = _kevent_call(
                kq_fd,
                _null_ptr[UInt8, MutUntrackedOrigin](),
                Int32(0),
                raw.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](),
                Int32(MAX_EVENTS_PER_WAIT),
                ts_buf.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](),
            )
            # ts_buf could otherwise be freed before
            # this point; keep this access alive AFTER the syscall to
            # be safe — read one byte to anchor the lifetime.
            _ = ts_buf[0]
        if n < 0:
            raise Error("kevent(wait) failed")
        while len(events) > 0:
            _ = events.pop()
        for i in range(Int(n)):
            var slot_buf = Array[UInt8, 32](fill=UInt8(0))
            for k in range(32):
                slot_buf[k] = raw[i * 32 + k]
            events.append(_decode_kevent(slot_buf))
        return Int(n)
    else:
        raise Error("kevent_wait_decode: Darwin only")


# -----------------------------------------------------------------------------
# Cross-thread wake — EVFILT_USER (kqueue's eventfd analog).
#
# Setup pattern (libuv / mio convention):
#   1. At reactor construct time: register EVFILT_USER with EV_ADD |
#      EV_CLEAR under sentinel ident. EV_CLEAR makes the trigger
#      auto-rearm after each retrieval (no manual drain like eventfd).
#   2. To wake from another thread: call kevent() with a single change
#      whose filter=EVFILT_USER, flags=EV_ADD (idempotent), fflags=
#      NOTE_TRIGGER. The kernel marks the event ready; the worker's
#      kevent() wait returns with this event in the eventlist.
#
# CRITICAL (per libuv `src/unix/async.c` empirical note): the EVFILT_USER
# event MUST be registered BEFORE any wake call, or the wake errors with
# ENOENT. We satisfy this by doing the EV_ADD in Reactor.__init__ before
# the worker pthread is observable to producers.
# -----------------------------------------------------------------------------


def kevent_register_user_wake(
    kq_fd: Int32, ident: UInt64, cookie: UInt64,
) raises:
    """Register an EVFILT_USER event under `ident` with cookie `cookie` in
    udata. EV_CLEAR semantics: each wake fires once, kernel auto-resets.

    This is the macOS equivalent of:
      `epoll_ctl_add(epoll_fd, eventfd, EPOLLIN, OP_ID_WAKE_EVENTFD)`.
    """
    comptime if CompilationTarget.is_macos():
        var change = Array[UInt8, 32](fill=UInt8(0))
        # SAFETY: stack-local. keep buffers alive across
        # the syscall by keeping all uses in this scope and anchoring
        # the InlineArrays after the call (MutExternalOrigin defeats
        # the lifetime tracker).
        _encode_kevent(
            change, ident, EVFILT_USER, EV_ADD | EV_CLEAR | EV_RECEIPT,
            UInt32(0), Int64(0), cookie,
        )
        var ack_buf = Array[UInt8, 32](fill=UInt8(0))
        var n = _kevent_call(
            kq_fd, change.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](), Int32(1),
            ack_buf.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](), Int32(1),
            _null_ptr[UInt8, MutUntrackedOrigin](),
        )
        # Anchor lifetimes past the syscall.
        _ = change[0]
        _ = ack_buf[0]
        if n < 0:
            raise Error("kevent(EVFILT_USER setup) failed")
        # Check the per-change EV_ERROR ack: when EV_RECEIPT is set
        # the kernel always returns one event with EV_ERROR flag and
        # ev.data = errno (0 on success). errno != 0 => the
        # registration was rejected.
        if n > 0:
            var ack = _decode_kevent(ack_buf)
            if (ack.flags & EV_ERROR) != UInt16(0) and ack.data != Int64(0):
                raise Error("kevent(EVFILT_USER setup) per-change error")


def kevent_user_wake(kq_fd: Int32, ident: UInt64):
    """Cross-thread wake. Lock-free per the kqueue contract — kevent()
    is async-signal-safe and callable from any thread.

    Equivalent to `write_eventfd(eventfd_fd)` on Linux. Best-effort:
    EBADF on a closed reactor is benign (matches WorkerWakeHandle's
    EBADF-silent contract).

    trigger uses `flags=0` (NO action flag)
    + `fflags=NOTE_TRIGGER`. Pre-fix used `flags=EV_ADD` which the
    kernel treats as "modify event with these flags + fflags"; the
    NOTE_TRIGGER bit was set on the event-control word but the
    semantic distinction between "register a fresh event with
    NOTE_TRIGGER" and "fire an existing event" was muddled, and the
    Mojo + libxnu combination did not deliver the trigger. Empirical
    bisect: only `flags=0` produces a deliverable EVFILT_USER event
    (matches libuv's `src/unix/async.c` shape exactly).
    """
    comptime if CompilationTarget.is_macos():
        if kq_fd < 0:
            return
        var change = Array[UInt8, 32](fill=UInt8(0))
        # SAFETY: stack-local; kernel reads only. Same scope as the
        # syscall to keep the borrow chain intact under
        # MutExternalOrigin's lifetime erasure.
        # pass udata=OP_ID_WAKE_USER so the
        # delivered event preserves the wake-channel cookie on receive.
        # The kernel mirrors udata from the most-recent change record;
        # passing 0 here would cause Reactor.run_once's kqueue branch
        # to receive `udata=0` and miss the `op_id == OP_ID_WAKE_USER`
        # routing.
        _encode_kevent(
            change, ident, EVFILT_USER, UInt16(0),  # flags=0
            NOTE_TRIGGER, Int64(0), UInt64(OP_ID_WAKE_USER),
        )
        _ = _kevent_call(
            kq_fd,
            change.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](),
            Int32(1),
            _null_ptr[UInt8, MutUntrackedOrigin](),
            Int32(0),
            _null_ptr[UInt8, MutUntrackedOrigin](),
        )
        # Anchor lifetime past the syscall (same shape as
        # kevent_wait_decode's ts_buf workaround).
        _ = change[0]


# -----------------------------------------------------------------------------
# KqueueSubsystem — RAII handle (parallel to EpollSubsystem).
# -----------------------------------------------------------------------------
# Naming kept as `KqueueSubsystem` (lowercase q) for backward compatibility
# with the existing stub's import paths in tests / reactor.mojo.

struct KqueueSubsystem(Deinitable):
    """Darwin/BSD kqueue
    backend (RAII handle).

    Constructed via `KqueueSubsystem.create()` on macOS only. On Linux,
    `create()` raises an explicit "Darwin only" error per the wrong-OS
    branch discipline. The wrong-OS FFI symbols are ELIDED
    at codegen on Linux (nm -D shows kqueue absent in the Linux ELF
    binary), so this struct compiles cleanly on both platforms but is
    functional only on Darwin.

    Owned resources:
      - kqueue fd (closed by __del__).
      - One persistent EVFILT_USER registration (ident=0; serves as the
        cross-thread wake channel — eventfd analog).
    """

    var _kq_fd: Int32
    # The wake-channel ident is fixed at 0 — there's only one EVFILT_USER
    # per reactor.
    var _wake_ident: UInt64

    def __init__(out self, kq_fd: Int32, wake_ident: UInt64):
        self._kq_fd = kq_fd
        self._wake_ident = wake_ident

    def __deinit__(deinit self):
        # No explicit EVFILT_USER deregister — closing the kqueue fd
        # tears down all registrations in the kernel.
        kqueue_close(self._kq_fd)

    @staticmethod
    def create() raises -> KqueueSubsystem:
        """Darwin-only constructor. Allocates kqueue fd + registers the
        persistent EVFILT_USER wake channel under ident=0 with the
        sentinel OP_ID_WAKE_USER cookie."""
        comptime if CompilationTarget.is_macos():
            var fd = kqueue_create()
            kevent_register_user_wake(
                fd, UInt64(0), UInt64(OP_ID_WAKE_USER),
            )
            return KqueueSubsystem(kq_fd=fd, wake_ident=UInt64(0))
        else:
            raise Error("KqueueSubsystem available on macOS only")

    def fd(self) -> Int32:
        """Underlying kqueue fd. Used by Reactor[S] for the kevent_*
        free-fn calls. Typed-scalar return preserves the encapsulation
        rule (no UnsafePointer crosses)."""
        return self._kq_fd

    def wake_ident(self) -> UInt64:
        """The EVFILT_USER ident reserved for cross-thread wake. Cloned
        into WorkerWakeHandle._ident at attach time."""
        return self._wake_ident
