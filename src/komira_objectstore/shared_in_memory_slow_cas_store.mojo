# =============================================================================
# komira_objectstore/shared_in_memory_slow_cas_store.mojo
#   A CONTROLLABLE-SLOW in-memory AsyncCasStore conformer.
# =============================================================================
#
# The TEST substrate for the broker coordinator's parkable-S3-CAS serve. It is
# a thin wrapper around `SharedInMemoryConditionalStore` (the linearizable
# Arc-shared in-process store) that ALSO conforms to `AsyncCasStore` by making
# the read + CAS-write POLL-SHAPED: each op yields `CAS_OP_PENDING` exactly
# `slow_ticks` times (scheduling a near-immediate reactor timer to re-poll)
# before performing the underlying SYNC map operation and returning
# `CAS_OP_READY`.
#
# WHY THIS EXISTS: the coordinator serve-responsiveness unit test asserts that
# a 2nd connection admitted DURING a parked reassign is accepted+served the
# same serve cycle. To make a reassign actually PARK (instead of completing
# instantly the way the pure in-mem store does), its CAS round-trip must yield
# to the reactor a controllable number of times. `slow_ticks > 0` makes the
# op park on a biased timer op_id N times — the same demux a real S3 socket
# read would drive — so the test exercises the bucket-1 (accept) / bucket-2
# (parked reassign) multiplexing structurally, with no real socket.
#
# THE PARK MECHANISM: `reactor.register_timer(deadline_ns)` returns a BIASED
# op_id (>= OP_ID_ALLOC_BASE) that the suspendable serve loop's bucket-2 demux
# routes to `driver.resume()` exactly like a socket-read completion. On the MOCK
# reactor backend the timer slot is recorded but never self-fires; the test
# drives readiness through the serve loop's poll. On a real (epoll/kqueue)
# backend a near-immediate timer fires on the next poll cycle.
#
# THE IN-FLIGHT OP STAYS INSIDE THE CONFORMER (the heap-reuse contract, mirrored from
# the S3 conformer): the parkable op's working state is held on a CONFORMER
# FIELD (`_op`), reached directly (not through a byte-slab + wildcard). For the
# in-mem store there is no transport-pool buffer to launder — the op holds only
# POD + owned-value state — so heap-reuse is N/A here; the field shape is identical to
# the S3 conformer's so the trait surface is exercised the same way.
#
# Encapsulation: ZERO UnsafePointer in any signature; the reactor is a per-call
# `mut reactor: Reactor[S]` borrow (never stored); AT MOST ONE poll-shaped op
# in flight at a time (enforced by the single `_op` Optional).
# =============================================================================

from komira_async.ops.waker_sink import WakerSink
from komira_async.reactor.reactor import Reactor

from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.store import (
    AsyncCasStore,
    CasOpProgress,
    CasReadResult,
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
)
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)


# The op kind currently in flight (so `*_poll` knows which sync verb to run on
# the final tick). NONE means no op is parked.
comptime _SLOW_OP_NONE: UInt8 = 0
comptime _SLOW_OP_READ: UInt8 = 1
comptime _SLOW_OP_CAS_PUT: UInt8 = 2


struct _SlowCasOp(Movable, Deinitable):
    """The single in-flight poll-shaped op's working state, held on the
    conformer. POD + owned-value fields only (no transport, no pointer) —
    the in-mem analog of the S3 conformer's in-flight `PendingStreamingGet`.

    Field layout:
      var kind: UInt8           — _SLOW_OP_READ / _SLOW_OP_CAS_PUT.
      var remaining_ticks: Int  — parks left before the sync verb runs.
      var path: String          — the object key (raw).
      var put_bytes: List[UInt8] — the CAS body (CAS PUT only).
      var put_etag: String      — the If-Match etag (empty => create).
      var read_result: Optional[CasReadResult] — the READY read result.
      var put_result: Optional[ObjectMeta]      — the READY CAS-put result.
    """

    var kind: UInt8
    var remaining_ticks: Int
    var path: String
    var put_bytes: List[UInt8]
    var put_etag: String
    var read_result: Optional[CasReadResult]
    var put_result: Optional[ObjectMeta]

    def __init__(out self):
        self.kind = _SLOW_OP_NONE
        self.remaining_ticks = 0
        self.path = String("")
        self.put_bytes = List[UInt8]()
        self.put_etag = String("")
        self.read_result = Optional[CasReadResult]()
        self.put_result = Optional[ObjectMeta]()


struct SharedInMemorySlowCasStore(
    AsyncCasStore,
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    """A controllable-slow in-memory `AsyncCasStore` (test substrate).
    Delegates every SYNC verb to an inner
    `SharedInMemoryConditionalStore`; the POLL-SHAPED read + CAS-write yield
    `CAS_OP_PENDING` `_slow_ticks` times (parking on a biased reactor timer
    op_id) before running the underlying sync verb.

    `clone()` shares the inner Arc-backed map (so K coordinators contend on one
    assignment) AND carries the same `_slow_ticks` — but a FRESH (empty) in-flight
    op slot (an in-flight op is never shared across clones, exactly as the S3
    conformer mints a fresh empty transport Arc per clone)."""

    var _inner: SharedInMemoryConditionalStore
    var _slow_ticks: Int
    var _op: _SlowCasOp
    # TEST KNOB: when True, `read_start` RAISES immediately —
    # the in-mem analog of a real S3 `TcpStream.connect: connect failed
    # (errno=61)` raised from the conformer's parkable verb BEFORE it can record
    # a step-result error. The coordinator-crash regression: a verb that RAISES
    # (vs. returns CasOpProgress.error) must NOT escape the suspendable serve loop
    # and kill the process — `serve_read_round_suspendable` must catch the
    # `driver.admit` raise and drop the conn defensively. See the regression test.
    var _raise_on_read_start: Bool
    # TEST KNOB: when True, `cas_put_start` RAISES
    # immediately — the in-mem analog of a real S3 connect/transport failure
    # raised from the CREATE-CAS parkable verb BEFORE it can record a step-result
    # error. The pgwire async-commit path's defense: a verb that RAISES out of
    # `cas_put_start` must NOT escape the suspendable serve loop and kill the
    # process — the async serve path must catch it and surface it as a clean
    # connection drop / ErrorResponse. Distinct from `_raise_on_read_start` (the
    # READ verb) so a test can fault the create-CAS specifically.
    var _raise_on_cas_put: Bool
    # TEST KNOB: when True, `cas_put_poll` RAISES on its
    # FINAL tick (when remaining_ticks reaches 0 and the sync put would run) —
    # the in-mem analog of a real S3 transport failure surfacing DURING the
    # parked round-trip (after the conn already parked, on the resume edge). This
    # is the harder case: the op is already in flight on PgConnState when the
    # fault fires. The async serve path must drop the conn cleanly and free the
    # carried AsyncCommitOp exactly once.
    var _raise_on_poll: Bool

    def __init__(
        out self,
        slow_ticks: Int = 0,
        raise_on_read_start: Bool = False,
        raise_on_cas_put: Bool = False,
        raise_on_poll: Bool = False,
    ):
        self._inner = SharedInMemoryConditionalStore()
        self._slow_ticks = slow_ticks
        self._op = _SlowCasOp()
        self._raise_on_read_start = raise_on_read_start
        self._raise_on_cas_put = raise_on_cas_put
        self._raise_on_poll = raise_on_poll

    def __init__(
        out self,
        var inner: SharedInMemoryConditionalStore,
        slow_ticks: Int,
        raise_on_read_start: Bool = False,
        raise_on_cas_put: Bool = False,
        raise_on_poll: Bool = False,
    ):
        self._inner = inner^
        self._slow_ticks = slow_ticks
        self._op = _SlowCasOp()
        self._raise_on_read_start = raise_on_read_start
        self._raise_on_cas_put = raise_on_cas_put
        self._raise_on_poll = raise_on_poll

    def clone(self) -> Self:
        """Share the inner Arc-backed map + the slow-tick count; FRESH empty op
        slot (an in-flight op is per-handle, never shared)."""
        return Self(
            inner=self._inner.clone(),
            slow_ticks=self._slow_ticks,
            raise_on_read_start=self._raise_on_read_start,
            raise_on_cas_put=self._raise_on_cas_put,
            raise_on_poll=self._raise_on_poll,
        )

    @always_inline
    def inner_ref(ref self) -> ref [self._inner] SharedInMemoryConditionalStore:
        """Borrow the inner store (test inspection — op counts / direct reads)."""
        return self._inner

    def set_slow_ticks(mut self, ticks: Int):
        """TEST KNOB — RETUNE the park depth mid-test.
        Setting `ticks == 0` makes the NEXT `cas_put_start` finish INLINE (no
        park) on this handle — used to drive a QUEUED-then-KICKED commit to
        finish inside `_pg_kick_next_queued_commit`'s loop body (so its terminal-
        reply write — to a closed fd — faults IN the kick loop). Affects only this
        handle's FUTURE ops; an op already parked keeps its `remaining_ticks`."""
        self._slow_ticks = ticks

    def set_raise_on_poll(mut self, on: Bool):
        """TEST KNOB — ARM/disarm the `raise_on_poll` fault
        MID-TEST (the create-CAS RAISES on its final-tick poll). Lets a test SEED
        without the fault (so the seed-phase autocommit INSERTs — which also
        park — complete cleanly) then ARM the fault only for the COMMIT it
        wants to fault. Affects only this handle's FUTURE poll final-ticks."""
        self._raise_on_poll = on

    # =========================================================================
    # ObjectStore + ConditionalWriteStore — delegate every SYNC verb.
    # =========================================================================

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        return self._inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self._inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        return self._inner.get(path)

    def delete(self, path: Path) raises -> None:
        self._inner.delete(path)

    # =========================================================================
    # AsyncCasStore — the POLL-SHAPED read + CAS-write.
    # =========================================================================

    def _arm_tick[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> Int64:
        """Register a near-immediate reactor timer and return its BIASED op_id
        (the frame parks on it; the serve loop's bucket-2 demux resumes the
        frame when it fires). `deadline_ns=0` arms a near-immediate fire."""
        return reactor.register_timer(Int64(0))

    def read_start[
        S: WakerSink & Movable & Deinitable,
    ](mut self, path: Path, mut reactor: Reactor[S]) raises -> CasOpProgress:
        """Begin a poll-shaped READ of `path`. With `_slow_ticks == 0` the read
        runs SYNC immediately (READY, no park); otherwise it parks `_slow_ticks`
        times on a biased timer op_id before running the sync read.

        TEST KNOB: `_raise_on_read_start` RAISES here — the in-mem analog of a
        real S3 `TcpStream.connect: connect failed (errno=61)` raised from inside
        the parkable verb."""
        if self._raise_on_read_start:
            raise Error(
                "SharedInMemorySlowCasStore: simulated TcpStream.connect:"
                " connect failed (errno=61)"
            )
        self._op = _SlowCasOp()
        self._op.kind = _SLOW_OP_READ
        self._op.remaining_ticks = self._slow_ticks
        self._op.path = path.raw()
        if self._op.remaining_ticks <= 0:
            self._run_read_now()
            return CasOpProgress.ready()
        self._op.remaining_ticks -= 1
        return CasOpProgress.pending(self._arm_tick[S](reactor))

    def read_poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        """Advance the parked READ one tick. On the final tick run the sync read
        and return READY; otherwise re-park on a fresh biased timer op_id."""
        if self._op.kind != _SLOW_OP_READ:
            return CasOpProgress.error(
                String("SharedInMemorySlowCasStore.read_poll: no read in flight")
            )
        if self._op.remaining_ticks <= 0:
            self._run_read_now()
            return CasOpProgress.ready()
        self._op.remaining_ticks -= 1
        return CasOpProgress.pending(self._arm_tick[S](reactor))

    def _run_read_now(mut self) raises:
        """Run the underlying SYNC head+get, stashing the typed result (or the
        `absent` flag on a 404) into the op for `read_take`."""
        var path = Path.parse(self._op.path)
        try:
            var meta = self._inner.head(path)
            var body = self._inner.get(path)
            self._op.read_result = Optional[CasReadResult](
                CasReadResult(absent=False, body=body^, etag=meta.etag.copy())
            )
        except e:
            var msg = String(e)
            if msg.find("not_found") >= 0 or msg.find("404") >= 0:
                self._op.read_result = Optional[CasReadResult](
                    CasReadResult(
                        absent=True, body=List[UInt8](), etag=String("")
                    )
                )
            else:
                raise Error(msg)  # cov: unreachable the inner shared store's head/get raise only not_found

    def read_take(mut self) raises -> CasReadResult:
        """Move the completed read result out (caller checks READY first)."""
        if not self._op.read_result:
            raise Error(
                "SharedInMemorySlowCasStore.read_take: read not ready"
            )
        var out = self._op.read_result.take()
        self._op = _SlowCasOp()
        return out^

    def cas_put_start[
        S: WakerSink & Movable & Deinitable,
    ](
        mut self,
        path: Path,
        var bytes: List[UInt8],
        expected_etag: String,
        mut reactor: Reactor[S],
    ) raises -> CasOpProgress:
        """Begin a poll-shaped CAS PUT (empty `expected_etag` => If-None-Match
        create, else If-Match update). Parks `_slow_ticks` times before the sync
        write.

        TEST KNOB (S-6): `_raise_on_cas_put` RAISES here — the in-mem analog of a
        real S3 connect/transport failure raised from inside the create-CAS
        parkable verb."""
        if self._raise_on_cas_put:
            raise Error(
                "SharedInMemorySlowCasStore: simulated create-CAS transport"
                " failure (cas_put_start, errno=61)"
            )
        self._op = _SlowCasOp()
        self._op.kind = _SLOW_OP_CAS_PUT
        self._op.remaining_ticks = self._slow_ticks
        self._op.path = path.raw()
        self._op.put_bytes = bytes^
        self._op.put_etag = expected_etag
        if self._op.remaining_ticks <= 0:
            # ABI: *_start returns READY/PENDING/ERR — it MUST NOT raise a
            # precondition. On the immediate-completion fast path (slow_ticks==0,
            # the loopback-MinIO / S3-Express deployment shape) a lost-slot 412
            # raises from `_run_cas_put_now`; catch it into ERR exactly as
            # `cas_put_poll` does on the final-tick path (BLOCKER-2 fix). A raised
            # 412 here would escape the driver's lost-slot classification.
            try:
                self._run_cas_put_now()
            except e:
                return CasOpProgress.error(String(e))
            return CasOpProgress.ready()
        self._op.remaining_ticks -= 1
        return CasOpProgress.pending(self._arm_tick[S](reactor))

    def cas_put_poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        """Advance the parked CAS PUT one tick. On the final tick run the sync
        write and return READY (or propagate a 412 as ERR); else re-park.

        TEST KNOB (S-6): `_raise_on_poll` RAISES on the FINAL tick — the in-mem
        analog of a real S3 transport failure surfacing DURING the parked
        round-trip, AFTER the conn already parked. The harder
        case: the carried AsyncCommitOp is already in flight on PgConnState."""
        if self._op.kind != _SLOW_OP_CAS_PUT:
            return CasOpProgress.error(
                String(
                    "SharedInMemorySlowCasStore.cas_put_poll: no put in flight"
                )
            )
        if self._op.remaining_ticks <= 0:
            if self._raise_on_poll:
                raise Error(
                    "SharedInMemorySlowCasStore: simulated create-CAS transport"
                    " failure (cas_put_poll final tick, errno=61)"
                )
            try:
                self._run_cas_put_now()
            except e:
                return CasOpProgress.error(String(e))
            return CasOpProgress.ready()
        self._op.remaining_ticks -= 1
        return CasOpProgress.pending(self._arm_tick[S](reactor))

    def _run_cas_put_now(mut self) raises:
        """Run the underlying SYNC conditional_put (create or If-Match), stashing
        the committed ObjectMeta for `cas_put_take`. A 412 propagates (the
        coordinator's retry loop catches it)."""
        var path = Path.parse(self._op.path)
        var meta: ObjectMeta
        if self._op.put_etag.byte_length() == 0:
            meta = self._inner.conditional_put(
                path, self._op.put_bytes, WritePrecondition.if_none_match_star()
            )
        else:
            meta = self._inner.compare_and_swap(
                path, self._op.put_bytes, self._op.put_etag
            )
        self._op.put_result = Optional[ObjectMeta](meta^)

    def cas_put_take(mut self) raises -> ObjectMeta:
        """Move the committed ObjectMeta out (caller checks READY first)."""
        if not self._op.put_result:
            raise Error(
                "SharedInMemorySlowCasStore.cas_put_take: put not ready"
            )
        var out = self._op.put_result.take()
        self._op = _SlowCasOp()
        return out^
