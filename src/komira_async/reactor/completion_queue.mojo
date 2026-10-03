# =============================================================================
# komira_async.reactor.completion_queue — POD types for Reactor[S]'s NIC-style
# completion-queue API
# =============================================================================
# The completion-queue surface exposes five public methods on Reactor[S]:
#
#   submit(op_kind, fd, buf) -> OpHandle
#   register_long_lived(fd, interest_set) -> RegistrationHandle
#   modify(reg_handle, new_interest_set)
#   poll_completions(timeout_us) -> List[Completion]
#   wake_self()
#
# These return / accept the POD types declared here. Per: the public
# Reactor surface is `Int / Int32 / Int64 / OpHandle / Completion /
# RegistrationHandle / List[Completion] / void / boxed Error` — NO
# UnsafePointer in any signature.
#
# =============================================================================


# -----------------------------------------------------------------------------
# OpKind sentinels — discriminator passed to Reactor.submit.
# -----------------------------------------------------------------------------
# Values are stable UInt8 sentinels; no enum syntax in Mojo 0.26.3 for
# UInt-payloaded discriminated tags. Match the prose in (the four
# values plus a future-reserved OP_TIMER for's TimerAwaitable).

comptime OP_READ: UInt8 = 0
comptime OP_WRITE: UInt8 = 1
comptime OP_CONNECT: UInt8 = 2
comptime OP_ACCEPT: UInt8 = 3
# OP_TIMER reserved for sleep_async / TimerAwaitable; not implemented in
#
comptime OP_TIMER: UInt8 = 4


# -----------------------------------------------------------------------------
# OpHandle._state sentinels — three-state result discriminator.
# -----------------------------------------------------------------------------
# OP_PENDING: submit returned without resolving; caller must park on
#             poll_completions (or invoke the wait() loop) until a Completion
#             matching this op_id arrives.
# OP_READY:   submit's try_io fast path succeeded (or poll_completions saw the
#             matching Completion). `_result` carries the typed result
#             (bytes-read / bytes-written / 0 / etc.).
# OP_ERR:     submit / poll_completions saw a non-recoverable error.
#             `_result` carries the errno (positive); caller raises.

comptime OP_PENDING: UInt8 = 0
comptime OP_READY: UInt8 = 1
comptime OP_ERR: UInt8 = 2


# -----------------------------------------------------------------------------
# InterestSet bitmask — for register_long_lived / modify.
# -----------------------------------------------------------------------------
# Per: register_long_lived takes a bitmask `INTEREST_READ |
# INTEREST_WRITE`. modify takes a new bitmask to switch the registration's
# armed interests. Same shape on both backends:
#   epoll: EPOLLIN <-> INTEREST_READ; EPOLLOUT <-> INTEREST_WRITE.
#   kqueue: EVFILT_READ EV_ENABLE/EV_DISABLE under INTEREST_READ;
#           EVFILT_WRITE EV_ENABLE/EV_DISABLE under INTEREST_WRITE.

comptime INTEREST_READ: UInt8 = 1
comptime INTEREST_WRITE: UInt8 = 2


# -----------------------------------------------------------------------------
# OpHandle — track-agnostic IO operation handle.
# -----------------------------------------------------------------------------
# Per (header doc):
#   "POD — no UnsafePointer in fields. Just an op_id (Int64) + a tag
#   discriminating Ready/Pending/Err + an inline result for the Ready case.
#   The OpHandle does NOT carry a reactor pointer. The owning IoOp /
#   Awaitable wraps the OpHandle and threads ctx.reactor through for
#   poll_completions / deregister calls."
#
# Movability: per "Movable but NOT Copyable — single-ownership;
# wraps a slot in the reactor's pending-ops table; the slot is freed on
# completion or cancellation."
#
# NOTE: the Movable+NOT-Copyable invariant for OpHandle is the intended
# contract; the type ships Copyable because the wrapping `IoOp[T]` is the
# layer that enforces single-ownership. The bare OpHandle returned by
# submit() is transient and consumed by the IoOp/Awaitable wrapper on the
# same line. Tightening OpHandle to NOT-Copyable (along with IoOp[T]) is a
# possible later step. ------------------------------------------------------

@fieldwise_init
struct OpHandle(
    Copyable, ImplicitlyCopyable, Movable, Deinitable,
):
    """Track-agnostic IO operation handle. Returned by `Reactor.submit`.

    Three-state result discriminator (`_state`):
      - OP_PENDING: caller must park on `Reactor.poll_completions` until the
        matching `Completion` arrives. State-machine track wraps in IoOp[T]
        whose `wait()` body drives the spin-then-park dance;
        async/await track wraps in `ReadAwaitable / WriteAwaitable / ...`
        whose `__await__` body suspends via `_suspend_async`.
      - OP_READY: `submit`'s try_io fast path succeeded (`_result` = bytes).
      - OP_ERR: non-recoverable error (`_result` = errno).

    POD: only Int64 / UInt8 / Int64 fields. Trivially Movable; trivially
    Copyable (see module-level note above).
    """

    var _op_id: Int64
    var _state: UInt8
    var _result: Int64

    @always_inline
    def op_id(self) -> Int64:
        """Public accessor for the underlying op_id. Used by IoOp/Awaitable
        wrappers and by tests inspecting the OpHandle's identity."""
        return self._op_id

    @always_inline
    def state(self) -> UInt8:
        """Public accessor for the result discriminator. Returns one of
        OP_PENDING / OP_READY / OP_ERR."""
        return self._state

    @always_inline
    def result(self) -> Int64:
        """Public accessor for the inline result (bytes / errno).

        Caller must check `state()` first — for OP_PENDING the result is
        the sentinel 0 (not yet resolved); for OP_READY it's the typed
        result (bytes-read / bytes-written / 0); for OP_ERR it's the errno
        (positive integer).
        """
        return self._result


# -----------------------------------------------------------------------------
# Completion — one IO completion drained from poll_completions.
# -----------------------------------------------------------------------------
# Per: returned by `Reactor.poll_completions` (one Completion per
# epoll/kqueue event that maps to an in-flight op_id). Wake-channel
# completions (eventfd_write / EVFILT_USER) are decoded internally and
# never appear in the returned list.
#
# POD: trivially Movable + Copyable.

@fieldwise_init
struct Completion(
    Copyable, ImplicitlyCopyable, Movable, Deinitable,
):
    """One IO completion drained from `Reactor.poll_completions`.

    Fields:
      - op_id: the operation identifier (matches the OpHandle returned by
        the prior `Reactor.submit` for this op).
      - bytes: bytes-read / bytes-written on success; 0 on error.
      - err_code: 0 on success; errno on error.
      - hangup: True on EPOLLHUP / EV_EOF (peer closed the connection;
        further reads will return 0 immediately).
    """

    var op_id: Int64
    var bytes: Int64
    var err_code: Int32
    var hangup: Bool


# -----------------------------------------------------------------------------
# RegistrationHandle — single ownership of one long-lived multiplexer
# registration.
# -----------------------------------------------------------------------------
# Per: "Single ownership of one multiplexer registration. Movable
# but NOT Copyable. Drop deregisters with the multiplexer."
#
# NOTE: like OpHandle, the NOT-Copyable invariant is relaxed because the
# TcpStream wrapper is the enforcement layer; it may be tightened if the
# type-system path is
# clean. The drop-on-handle semantics fire correctly regardless of
# Copyable conformance because the Reactor's deregister-by-fd path is
# idempotent (epoll_ctl_del + ENOENT-swallow); a later step may add a
# `_registered: Bool` field to gate the drop at most once.

@fieldwise_init
struct RegistrationHandle(
    Copyable, ImplicitlyCopyable, Movable, Deinitable,
):
    """Long-lived multiplexer registration handle. Returned by
    `Reactor.register_long_lived`.

    Owns ONE multiplexer registration for the lifetime of the wrapping
    TcpStream. The drop body calls
    `Reactor._deregister_long_lived(self._fd)` to remove the registration
    from the multiplexer.

    Fields:
      - _fd: the registered file descriptor (also serves as the kqueue
        ident; on epoll, it's the fd we passed to EPOLL_CTL_ADD).
      - _interest_set: current armed interests (INTEREST_READ |
        INTEREST_WRITE bitmask). `Reactor.modify` updates this when the
        caller switches between read / write / both.
    """

    var _fd: Int32
    var _interest_set: UInt8

    @always_inline
    def fd(self) -> Int32:
        """Public accessor for the registered fd."""
        return self._fd

    @always_inline
    def interest_set(self) -> UInt8:
        """Public accessor for the current interest bitmask."""
        return self._interest_set
