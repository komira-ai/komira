# =============================================================================
# komira_async.ops.io_op — IoOp[T, S, ro] value-typed in-flight handle
# =============================================================================
#
#
# Value-typed in-flight I/O. Holds an op_id allocated by the reactor, a
# state sentinel (Pending / Ready / Err), an Optional[T] result that the
# reactor populates on completion, and an error string populated on Err.
#
# Bounds:
#   - T: Copyable & ImplicitlyCopyable & Movable & Deinitable
#     (the ImplicitlyCopyable bound is load-bearing — wait() returns by
#     COPY, never by move; a partial move out of the Optional is banned).
#   - S: WakerSink & Deinitable
#   - ro: Origin[mut=False]
#     (`never_origin` (= `StaticConstantOrigin`) is an `ImmutOrigin`, which
#     CANNOT bind to a `mut=True` parameter, so IoOp's `ro` slot is
#     `mut=False` — synthetic IoOps + ALL production IoOps work fine with
#     this since the only thing that needs to be MUT'd is the internal
#     Reactor[S] (via `UnsafePointer`, which is mut-agnostic), not the
#     caller-provided origin.)
#
# Self.T / Self.S / Self.ro qualifications are mandatory in field
# declarations AND method bodies.
#
# value-type plumbing complete:
#   - state machine (Pending / Ready / Err)
#   - Optional[Self.T] result + String _err
#   - poll() / is_ready() / is_pending() / has_err()
#   - wait() drains a worker-local poll loop returning by COPY
#   - synthetic ready/err static constructors for testing + ioop_ready
#
# wires _reactor: Pointer[Reactor[Self.S], Self.ro] and
# rewrites wait() to drive `self._reactor[].run_once(timeout_us)` between
# state checks. for_read/for_write/for_connect static constructors fire
# off a reactor.register_{read,write} and return the Pending IoOp.
#
# wait_with_token(token: CancellationToken) calls
# token.poll_or_raise() between reactor.run_once iterations.
# =============================================================================

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import WakerSink

# OpStatus sentinel encoding. UInt8 sentinels; a later step may promote to
# a named enum once Mojo's enum surface stabilizes.
comptime OP_PENDING: UInt8 = 0
comptime OP_READY: UInt8 = 1
comptime OP_ERR: UInt8 = 2


struct IoOp[
    T: Copyable & ImplicitlyCopyable & Movable & Deinitable,
    S: WakerSink & Movable & Deinitable,
    ro: Origin[mut=False],
](Copyable, Movable, Deinitable):
    """Value-typed in-flight I/O.

    2 field set:
      var _state: UInt8                  # OP_PENDING / OP_READY / OP_ERR
      var _op_id: Int64
      var _result: Optional[Self.T]      # populated when _state == OP_READY
      var _err: String                   # populated when _state == OP_ERR

    3 will add:
      var _reactor: Pointer[Reactor[Self.S], Self.ro]

    Notes for
      - When the reactor field lands, `wait()` drives
        `self._reactor[].run_once(timeout_us)` between state-checks.
      - Static `for_read/for_write/for_connect` allocate an op_id from the
        reactor and call `register_read/register_write` before returning.
      - Drop semantics: if _state == OP_PENDING at drop, must call
        `self._reactor[].deregister(self._op_id)`. The destructor needs
        Reactor[S] to exist. synthetic IoOps don't register
        with any reactor, so drop is a no-op.
    """

    var _state: UInt8
    var _op_id: Int64
    var _result: Optional[Self.T]
    var _err: String

    def __init__(out self, op_id: Int64, state: UInt8):
        """Default Pending construction. Used by tests + by the `ioop_ready`
        / `ioop_err` factories below (a reactor-backed form would also take
        a `Pointer[Reactor[Self.S], Self.ro]`).
        """
        self._state = state
        self._op_id = op_id
        self._result = Optional[Self.T]()
        self._err = String("")

    @staticmethod
    def synthetic_ready(value: Self.T, op_id: Int64) -> IoOp[Self.T, Self.S, Self.ro]:
        """Construct a synthetic IoOp pre-flagged Ready with the given value.
        Used for `ioop_ready`-style operations where the
        readiness is not driven by a real reactor — and for tests in 1.2
        that want to validate the value-flow without a reactor.

        3 will keep this static factory; the reactor pointer is set
        to a sentinel-null Pointer (synthetic ops never deregister).
        """
        var op = IoOp[Self.T, Self.S, Self.ro](op_id=op_id, state=OP_READY)
        op._result = Optional[Self.T](value)
        return op^

    @staticmethod
    def synthetic_err(err: String, op_id: Int64) -> IoOp[Self.T, Self.S, Self.ro]:
        """Construct a synthetic IoOp pre-flagged Err with the given error."""
        var op = IoOp[Self.T, Self.S, Self.ro](op_id=op_id, state=OP_ERR)
        op._err = err
        return op^

    @staticmethod
    def for_read() raises -> IoOp[Self.T, Self.S, Self.ro]:
        """3 signature:
        `for_read(reactor_ptr, fd, buf) -> Self`."""
        raise Error("not implemented (needs Reactor wiring)")

    @staticmethod
    def for_write() raises -> IoOp[Self.T, Self.S, Self.ro]:
        """3 stub."""
        raise Error("not implemented (needs Reactor wiring)")

    @staticmethod
    def for_connect() raises -> IoOp[Self.T, Self.S, Self.ro]:
        """3 stub."""
        raise Error("not implemented (needs Reactor wiring)")

    def poll(mut self) raises -> UInt8:
        """Returns OpStatus (Pending / Ready / Err).
        returns `_state` directly without driving any reactor.
        3 will optionally drain `self._reactor[].run_once(0)` first
        to surface readiness even when wait() hasn't been called yet.
        """
        return self._state

    def is_pending(self) -> Bool:
        """Predicate form of poll() == OP_PENDING."""
        return self._state == OP_PENDING

    def is_ready(self) -> Bool:
        """Predicate form of poll() == OP_READY."""
        return self._state == OP_READY

    def has_err(self) -> Bool:
        """Predicate form of poll() == OP_ERR."""
        return self._state == OP_ERR

    def op_id(self) -> Int64:
        """Reactor-allocated op_id. Useful for diagnostics + cross-referencing
        the reactor's WakerSlot table."""
        return self._op_id

    # Tier 1: implicit token from worker-local state.
    def wait(var self) raises -> Self.T:
        """Drains the in-flight op until ready.
        Returns by COPY (the T: ImplicitlyCopyable bound is load-bearing; a
        partial move out via take_pointee is banned).

        Body: if _state == OP_READY, return _result.value(). If
        OP_ERR, raise. If OP_PENDING, raise unconditionally — there is no
        Reactor pointer field to drive a reactor.run_once loop.

        A reactor-backed form would poll
        `self._reactor[].run_once(timeout_us=1000)` until
        `self._reactor[].is_ready(self._op_id)`, then mark ready + return,
        with `Runtime.shutdown_token()` as the out-of-task token.
        """
        if self._state == OP_READY:
            return self._result.value()
        if self._state == OP_ERR:
            raise Error(self._err)
        # OP_PENDING with no reactor.
        raise Error(
            "IoOp.wait() on Pending op without reactor (synthetic ops only)"
        )

    # Tier 2: explicit token (race / timeout / cross-thread escape).
    def wait_with_token(var self, token: CancellationToken) raises -> Self.T:
        """Wait for the IoOp to complete OR for the token to be cancelled.

        Returns by COPY (the T: ImplicitlyCopyable bound is load-bearing; a
        partial move out via take_pointee is banned).

        Cancellation semantics:
          - If the token is already cancelled at entry: raise
            Error("CancelledError: " + reason) WITHOUT touching the
            reactor (the underlying op may still complete out-of-band;
            the caller must drop the IoOp wrapper to deregister).
          - If the op completes first: return the value.
          - If the op errors first: raise.
          - This shape does NOT poll between iterations
            because the synthetic IoOp doesn't drive a
            reactor loop. The reactor-driven path (TcpStream read / write /
            accept) polls the token in its own park loop; this surface is
            the cancellation contract + the synthetic / pre-completed
            short-circuit.
        """
        # Pre-entry cancellation check (fast-path raise without
        # touching the reactor).
        if token.is_cancelled():
            raise Error("CancelledError: " + token.reason())
        if self._state == OP_READY:
            return self._result.value()
        if self._state == OP_ERR:
            raise Error(self._err)
        # Synthetic Pending IoOps without a
        # reactor — the caller must use the higher-level reactor-driven path
        # (TcpStream.read / write / accept), which polls the token in
        # _read_or_write_loop.
        raise Error(
            "IoOp.wait_with_token() on Pending op without reactor (use the"
            " reactor-driven TcpStream path, which polls the token per"
            " iteration)"
        )


# -----------------------------------------------------------------------------
# ioop_ready[T, S](value: T) -> IoOp[T, S, never_origin]
# Constructs a synthetic Ready IoOp at op_id 0. Module-level helper that
# instantiates IoOp's `synthetic_ready` factory; lives here next to IoOp so
# higher-level modules (channel / morsel / timer) can import it directly.
# -----------------------------------------------------------------------------

# NOTE: ioop_ready is intentionally a free fn (not a method). The `ro`
# parameter is `never_origin`
# — synthetic IoOps have no caller-borrow so the immutable static origin is
# the correct annotation. We DON'T hard-code never_origin here because doing
# so would force every consumer to import never_origin — instead we let the
# caller bind `ro` to whatever they need (typically never_origin). The
# canonical wrapper at komira_async.primitives is in 1 of the channel /
# stream / timer modules and binds `ro = never_origin` explicitly.
def ioop_ready[
    T: Copyable & ImplicitlyCopyable & Movable & Deinitable,
    S: WakerSink & Movable & Deinitable,
    ro: Origin[mut=False],
](value: T) -> IoOp[T, S, ro]:
    """Synthetic-ready IoOp constructor.

    Use this when an "operation" can be answered immediately by the host
    (e.g. `MorselPool.try_claim()` returning `OptionalT.None`, or a
    pre-cached value from a `Stream.next()`). The IoOp is in `OP_READY`
    state from construction; `wait()` returns the value without parking.
    """
    return IoOp[T, S, ro].synthetic_ready(value=value, op_id=Int64(0))
