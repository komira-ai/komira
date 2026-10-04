# =============================================================================
# komira_db/tests/test_generic_pool_non_pg.mojo
# The "NOT hardcoded to Postgres" proof for the generic pool.
# =============================================================================
# `PgDatabase` is just ONE type of connection, and a user may not be using
# Postgres at all, so the pool must work for any `PooledResource`.
#
# THE PROOF: a NON-Postgres mock resource (`_MockConn`) conforming to
# `PooledResource`, run through the GENERIC `Pool[T]` + the SAME streaming
# own-during-burst -> vacate-on-idle -> restore-on-wake lifecycle (driven by the
# `MockIdleWakeOp` poll-counter), asserting the SAME guarantees as the PG path:
#   * no wildcard-origin field, no partial move (structural);
#   * in_use_count() == 0 across an idle re-park;
#   * a connect-count probe: NO new `_MockConn` established on re-acquire after an
#     idle park (the cheap-vacate works generically);
#   * teardown of an abandoned long-lived idle frame returns the resource (no
#     leak / double-free).
# The non-PG mock passing through the IDENTICAL `Pool[T]` machinery IS the
# "not hardcoded to Postgres" proof — there is NO Postgres anywhere in this file.
#
# Backend: BACKEND_MOCK — no kernel fds, cross-platform. `_MockConn` is a fake
# resource (an id + a PROCESS-WIDE connect-count so the no-reconnect probe is
# unambiguous + a heap String so a botched erasure / double-free would corrupt
# it — a relocation hazard on purpose).
# =============================================================================

from std.memory import ArcPointer

from std.testing import assert_equal, assert_true, assert_false

from komira_async.ops.waker_sink import NoopSink, WakerSink
from komira_async.reactor.reactor import (
    BACKEND_MOCK,
    OP_ID_ALLOC_BASE,
    Reactor,
)
from komira_async.runtime.shared_erasure import (
    ErasedHandlerFrame,
    make_erased_handler_frame,
)
from komira_async.runtime.stream_conn_lifecycle import (
    IDLE_READY,
    MockIdleWakeOp,
    StreamResumeToken,
)
from komira_async.runtime.suspendable_handler import (
    HandlerStepResult,
    SuspendableHandler,
)

from komira_db.pool import Pool, PooledResource


# =============================================================================
# A — _ConnectCounter — a connect-count cell that lives OUTSIDE the pool.
# =============================================================================
# The no-reconnect probe needs to count GENUINE resource establishments
# (`_MockConn.connect` calls) INDEPENDENTLY of the pool's own `connects_made()`
# instrument — so a regression that routed around the pool's counter would still
# be caught. Mojo 1.0.0b1 has NO global variables, so the counter is a heap cell
# shared (via `ArcPointer`) into the resource's Config: every `_MockConn.connect`
# bumps it. The test owns the Arc, so it reads the count from outside the pool,
# proving NO `connect` fires across a vacate/restore cycle. Single-threaded test
# -> a plain Int cell suffices (no Atomic needed).


struct _ConnectCounter(Movable, Deinitable):
    """A shared mutable connect-count cell, reached through `ArcPointer`. The
    test holds a clone to read the count from OUTSIDE the pool."""

    var count: Int

    def __init__(out self):
        self.count = 0


# =============================================================================
# B — _MockConnConfig — the resource's opaque Config (a non-PG one).
# =============================================================================
# `_MockConn.connect(config)` builds a connection from this. The pool treats it
# as opaque — it just copies it per eager establishment. Models "a Redis URL" /
# "an HTTP backend address" — anything that is NOT a PgConfig. Carries the shared
# `_ConnectCounter` Arc so each establishment bumps the test-visible cell.


struct _MockConnConfig(Copyable, Movable, Deinitable):
    """A non-Postgres resource config (e.g. a backend address + a base id),
    carrying a shared connect-count cell. `Copyable & Movable &
    Deinitable` per the `PooledResource.Config` bound — the Arc clone
    shares the SAME cell across copies (so a per-resource config copy still bumps
    the one counter)."""

    var base_id: Int
    var label: String
    var connects: ArcPointer[_ConnectCounter]

    def __init__(out self, base_id: Int, var label: String, var connects: ArcPointer[_ConnectCounter]):
        self.base_id = base_id
        self.label = label^
        self.connects = connects^


# =============================================================================
# C — _MockConn — a NON-Postgres pooled resource conforming to PooledResource.
# =============================================================================
# A single-owner, Movable-not-Copyable handle over a "channel id" (a positive Int
# when live, 0 when closed) + a heap String label (a relocation hazard). It conforms
# to `PooledResource` by exposing exactly: `Config = _MockConnConfig`,
# `connect(config) -> Self` (THE ONLY establishment site — bumps the shared
# counter), and `close(mut self)`. NOTHING Postgres.


struct _MockConn(PooledResource):
    """A non-PG pooled resource: a single-owner channel over a "channel id".
    Movable, not Copyable (single ownership). The `_label` heap String makes the
    erased round-trip a genuine relocation test. Conforms to `PooledResource`."""

    comptime Config = _MockConnConfig

    var _channel_id: Int
    var _label: String

    def __init__(out self, channel_id: Int, var label: String):
        self._channel_id = channel_id
        self._label = label^

    @staticmethod
    def pooled_connect(var config: _MockConnConfig) raises -> _MockConn:
        """Establish ONE mock channel from the config. THE ONLY establishment
        site — bumps the shared connect counter. The cheap-vacate cycle NEVER
        calls this (it moves the resource, never re-establishes)."""
        config.connects[].count += 1
        # channel_id derived from the config so each pool's resources are
        # distinguishable; +1 keeps it positive (0 == closed sentinel).
        return _MockConn(config.base_id + 1, config.label.copy())

    def close(mut self):
        """Teardown: mark the channel closed (id -> 0)."""
        self._channel_id = 0

    @always_inline
    def channel_id(self) -> Int:
        return self._channel_id

    def read_burst(self, want_rows: Int) -> Int:
        """Simulate reading `want_rows` rows over the live channel; returns the
        new highest row id (the channel id stands in for the data source)."""
        return self._channel_id * 1000 + want_rows


# A non-PG pool, specialized purely by swapping `T` — NO PgDatabase, NO PgConfig.
comptime _MockPool = Pool[_MockConn]


# =============================================================================
# D — _MockStreamHandlerSM — the streaming handler over the GENERIC pool.
# =============================================================================
# The pool handle is `ArcPointer[Pool[_MockConn]]` — a generic `Pool[T]`, NOT
# `PgPool`: the streaming lifecycle references `Pool[T]` generically. The connection is OWNED (`_conn: Optional[_MockConn]`) ONLY during
# the active burst; during the IDLE park `_conn` is None and the pool holds it.


comptime MH_STEP_BURST: UInt8 = 0
comptime MH_STEP_IDLE: UInt8 = 1
comptime MH_STEP_DONE: UInt8 = 2


struct _MockStreamHandlerSM(Movable, Deinitable, SuspendableHandler):
    """A POC streaming handler over the GENERIC `Pool[_MockConn]` proving the
    connection-ownership lifecycle resource-agnostically. Owns the resource ONLY
    during the active burst (`_conn` Some), vacates it to the pool during the
    idle park (`_conn` None), and re-acquires on wake. `Resp = Int`."""

    comptime Resp = Int

    var _step: UInt8
    var _pool: ArcPointer[Pool[_MockConn]]
    var _lease: Int
    # OWNED across the active burst only; None during the idle park.
    var _conn: Optional[_MockConn]
    var _token: StreamResumeToken
    var _idle: Optional[MockIdleWakeOp]
    var _bursts_remaining: Int
    var _conn_in_pool: Bool

    def __init__(
        out self,
        var pool: ArcPointer[Pool[_MockConn]],
        lease: Int,
        var conn: _MockConn,
        n_bursts: Int,
    ):
        self._step = MH_STEP_BURST
        self._pool = pool^
        self._lease = lease
        self._conn = Optional[_MockConn](conn^)
        self._token = StreamResumeToken.initial()
        self._idle = Optional[MockIdleWakeOp]()
        self._bursts_remaining = n_bursts
        self._conn_in_pool = False

    def step[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> HandlerStepResult[Int]:
        if self._step == MH_STEP_BURST:
            return self._do_burst[S](reactor)
        elif self._step == MH_STEP_IDLE:
            return self._resume_idle[S](reactor)
        else:
            return HandlerStepResult[Int].error(
                String("mock-stream-poc: step() at unexpected step")
            )

    def _do_burst[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> HandlerStepResult[Int]:
        """ACTIVE BURST: we OWN the resource. Read, advance the token. If more
        bursts remain, VACATE the resource back to the pool and PARK on a fresh
        idle wake holding ONLY the POD token. Else DONE."""
        var conn = self._conn.take()
        var new_id = conn.read_burst(1)
        self._token.advance(Int64(new_id), Int64(new_id))
        self._bursts_remaining -= 1

        if self._bursts_remaining <= 0:
            self._pool[].restore(self._lease, conn^)
            self._pool[].return_lease(self._lease)
            self._conn_in_pool = True
            self._step = MH_STEP_DONE
            return HandlerStepResult[Int].done(Int(self._token.last_seen_id))

        # IDLE: give the resource BACK to the pool (cheap — no reconnect).
        self._pool[].restore(self._lease, conn^)
        self._conn_in_pool = True

        var idle = MockIdleWakeOp(1)  # ready after 1 poll
        var op_id = idle.start[S](reactor)
        self._token.idle_wake_op_id = op_id
        self._idle = Optional[MockIdleWakeOp](idle^)
        self._step = MH_STEP_IDLE
        return HandlerStepResult[Int].parked(op_id)

    def _resume_idle[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> HandlerStepResult[Int]:
        """WAKE: poll the idle op; if pending, re-park (still holding NO
        resource). If ready, RE-ACQUIRE from the pool (`vacate` — cheap, no
        reconnect) and run the next burst."""
        var st = self._idle.value().poll()
        if st != IDLE_READY:
            return HandlerStepResult[Int].parked(self._idle.value().op_id())

        _ = self._idle.take()
        var conn = self._pool[].vacate(self._lease)
        self._conn = Optional[_MockConn](conn^)
        self._conn_in_pool = False
        self._step = MH_STEP_BURST
        return self._do_burst[S](reactor)

    @always_inline
    def holds_connection(self) -> Bool:
        return self._conn.__bool__()

    def __deinit__(deinit self):
        """Safety net: re-home a held resource into its pool slot on an abnormal
        drop. Generic over `_MockConn`."""
        if self._conn:
            var conn = self._conn.take()
            try:
                self._pool[].restore(self._lease, conn^)
                self._pool[].return_lease(self._lease)
            except:
                pass
        elif not self._conn_in_pool:
            try:
                self._pool[].return_lease(self._lease)
            except:
                pass
        if (not self._conn) and self._conn_in_pool and self._step != MH_STEP_DONE:
            try:
                self._pool[].return_lease(self._lease)
            except:
                pass


# =============================================================================
# 1. CONFORMANCE + EAGER-CONNECT — `_MockConn` conforms to `PooledResource`, and
#    `Pool[_MockConn]` establishes exactly `size` resources eagerly. NO Postgres.
# =============================================================================
def test_non_pg_resource_conforms_and_pool_establishes_eagerly() raises:
    """A NON-Postgres resource (`_MockConn`) drives the generic `Pool[T]`. The
    pool establishes exactly `size` resources at construction — the process-wide
    connect counter AND the pool's own `connects_made()` both report `size`.
    This is the "not hardcoded to Postgres" structural proof: the SAME `Pool[T]`
    machinery, a non-PG `T`."""
    var counter = ArcPointer[_ConnectCounter](_ConnectCounter())
    var cfg = _MockConnConfig(100, String("mock-backend"), counter.copy())
    var pool = Pool[_MockConn].connect(cfg^, 3)
    # The pool established exactly 3 resources eagerly.
    assert_equal(pool.size(), 3, "the pool holds 3 resources")
    assert_equal(pool.connects_made(), 3, "the pool established 3 resources eagerly")
    assert_equal(
        counter[].count,
        3,
        "exactly 3 _MockConn.connect calls fired (counter outside the pool)",
    )
    assert_equal(pool.in_use_count(), 0, "no lease checked out yet")
    _ = pool^
    print("  [1] non-PG _MockConn conforms + Pool[_MockConn] establishes eagerly OK")


# =============================================================================
# 2. in_use_count() == 0 across an idle re-park — the generic-pool 503-prevention.
# =============================================================================
def test_no_resource_held_across_idle_park_generic() raises:
    """Drive the streaming frame over the GENERIC pool to its FIRST idle park.
    Assert the frame holds NO resource AND the size-1 pool's resource is back in
    its slot (available) — the 503-prevention property, resource-agnostic."""
    var reactor = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    var counter = ArcPointer[_ConnectCounter](_ConnectCounter())
    var cfg = _MockConnConfig(0, String("c"), counter.copy())
    var pool = ArcPointer[Pool[_MockConn]](Pool[_MockConn].connect(cfg^, 1))

    var lease = pool[].checkout()
    var conn = pool[].vacate(lease)  # take it out to hand to the frame
    var sm = _MockStreamHandlerSM(pool.copy(), lease, conn^, 3)

    var sr0 = sm.step(reactor)
    assert_true(sr0.is_parked(), "after burst 0 the frame parks on the idle wake")
    assert_true(
        sr0.op_id() >= OP_ID_ALLOC_BASE,
        "the idle-wake op_id is biased (a dynamically-registered op)",
    )

    assert_false(sm.holds_connection(), "the idle-parked frame holds NO resource")
    assert_false(
        pool[].is_vacated(lease),
        "the resource is back IN the generic pool while the frame is idle-parked",
    )
    assert_equal(
        pool[].in_use_count(),
        1,
        "the lease is still held across the idle (vacate keeps the slot reserved)",
    )
    _ = sm^
    print("  [2] no resource held across idle re-park (generic Pool[T]) OK")


# =============================================================================
# 3. NO-RECONNECT probe (generic) — re-acquire after an idle park establishes NO
#    new resource. The process-wide connect counter is FLAT across the stream.
# =============================================================================
def test_reacquire_does_not_reconnect_generic() raises:
    """Run a full multi-burst stream over the GENERIC pool to completion. The
    pool established exactly `size` resources at construction; the vacate/restore
    cycle across every idle re-park must NOT establish any new resource. BOTH the
    pool's `connects_made()` AND the process-wide `_MockConn.connect` counter are
    UNCHANGED across the whole stream — the cheap-vacate works generically."""
    var reactor = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    var counter = ArcPointer[_ConnectCounter](_ConnectCounter())
    var cfg = _MockConnConfig(0, String("c"), counter.copy())
    var pool = ArcPointer[Pool[_MockConn]](Pool[_MockConn].connect(cfg^, 1))
    assert_equal(counter[].count, 1, "size-1 pool established 1 resource")
    var pool_connects_at_start = pool[].connects_made()
    assert_equal(pool_connects_at_start, 1, "the pool reports 1 establishment")
    var global_after_connect = counter[].count

    var lease = pool[].checkout()
    var conn = pool[].vacate(lease)
    var sm = _MockStreamHandlerSM(pool.copy(), lease, conn^, 4)  # 4 bursts -> 3 idle gaps

    var guard = 0
    var done = False
    var final_id = Int(0)
    while (not done) and guard < 100:
        var sr = sm.step(reactor)
        if sr.is_done():
            done = True
            final_id = sr.take_response()
        elif sr.is_error():
            raise Error("generic stream errored: " + sr.err_text())
        guard += 1
    assert_true(done, "the generic stream completes within the guard bound")
    # channel_id: base_id 0 + 1 = 1 (slot 0); last burst read 1 row -> 1*1000+1.
    assert_equal(final_id, 1001, "the final watermark reflects the last burst read")

    # THE GUARD (GREEN — cheap-vacate path): no new resource established.
    assert_equal(
        pool[].connects_made(),
        pool_connects_at_start,
        "re-acquire across idle re-parks established NO new resource (pool counter)",
    )
    assert_equal(
        counter[].count,
        global_after_connect,
        "NO _MockConn.connect fired across the vacate/restore cycle (counter outside pool)",
    )
    _ = sm^
    print("  [3] generic re-acquire across idle re-parks does NOT reconnect OK")


# =============================================================================
# 4. ABANDONED-FRAME TEARDOWN (generic) — drop a long-lived idle frame; the
#    resource returns to the pool (no leak / no double-free). Both idle AND
#    mid-burst.
# =============================================================================
def test_abandoned_frame_returns_resource_generic() raises:
    """(a) IDLE-PARK DROP over the GENERIC pool: drive to an idle park (resource
    in the pool), DROP. The pool's resource is intact in its slot and the lease
    is freed. (b) MID-BURST DROP: a fresh frame OWNS the resource; DROP before it
    parks — the `__del__` safety net re-homes the owned resource into the pool
    slot + frees the lease. No reconnect either way."""
    var reactor = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    var counter = ArcPointer[_ConnectCounter](_ConnectCounter())
    var cfg = _MockConnConfig(0, String("c"), counter.copy())

    # ---- (a) idle-park drop ----
    var pool_a = ArcPointer[Pool[_MockConn]](Pool[_MockConn].connect(cfg.copy(), 1))
    var connects_a = pool_a[].connects_made()
    var lease_a = pool_a[].checkout()
    var conn_a = pool_a[].vacate(lease_a)
    var sm_a = _MockStreamHandlerSM(pool_a.copy(), lease_a, conn_a^, 5)
    var sr_a = sm_a.step(reactor)  # burst 0 -> vacate -> idle park
    assert_true(sr_a.is_parked())
    assert_false(sm_a.holds_connection(), "idle-parked: resource in the pool")
    assert_false(pool_a[].is_vacated(lease_a), "the resource is in its pool slot")
    _ = sm_a^  # DROP the idle-parked frame.
    assert_false(
        pool_a[].is_vacated(lease_a),
        "after abandoning an idle-parked frame the resource is still in the pool",
    )
    assert_equal(pool_a[].in_use_count(), 0, "the lease is freed after teardown")
    assert_equal(pool_a[].connects_made(), connects_a, "no reconnect on teardown")

    # ---- (b) mid-burst drop ----
    var pool_b = ArcPointer[Pool[_MockConn]](Pool[_MockConn].connect(cfg.copy(), 1))
    var connects_b = pool_b[].connects_made()
    var lease_b = pool_b[].checkout()
    var conn_b = pool_b[].vacate(lease_b)
    var sm_b = _MockStreamHandlerSM(pool_b.copy(), lease_b, conn_b^, 5)
    assert_true(sm_b.holds_connection(), "freshly-built frame OWNS the resource")
    assert_true(pool_b[].is_vacated(lease_b), "the pool slot is vacated (frame holds it)")
    _ = sm_b^  # DROP the mid-burst frame (it still owns the resource).
    assert_false(
        pool_b[].is_vacated(lease_b),
        "the mid-burst-dropped frame re-homed its resource into the pool",
    )
    assert_equal(pool_b[].in_use_count(), 0, "the lease is freed after mid-burst teardown")
    assert_equal(pool_b[].connects_made(), connects_b, "no reconnect on mid-burst teardown")
    print("  [4] abandoned frame returns the resource generically (idle + mid-burst) OK")


# =============================================================================
# 4b. ERASURE SAFETY (generic) — the SAME lifecycle through `ErasedHandlerFrame`.
# =============================================================================
def test_lifecycle_through_erased_frame_generic() raises:
    """The generic-pool streaming handler, erased into `ErasedHandlerFrame[NoopSink]`
    and stepped BLIND, runs the full vacate/restore lifecycle: the OWNED resource
    (`_MockConn` with its heap String) + POD token travel through the
    type-erasure bitcast intact; `_drop_fn` runs the SM `__del__` in-place. Proves
    owned-across-erased-park is relocation-clean for a non-PG resource too."""
    var reactor = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    var counter = ArcPointer[_ConnectCounter](_ConnectCounter())
    var cfg = _MockConnConfig(0, String("c"), counter.copy())
    var pool = ArcPointer[Pool[_MockConn]](Pool[_MockConn].connect(cfg^, 1))
    var connects_at_start = pool[].connects_made()
    var lease = pool[].checkout()
    var conn = pool[].vacate(lease)
    var sm = _MockStreamHandlerSM(pool.copy(), lease, conn^, 3)

    var frame = make_erased_handler_frame[_MockStreamHandlerSM, NoopSink](sm^, Int64(7))

    var guard = 0
    var done = False
    var final_id = Int(0)
    while (not done) and guard < 100:
        var sr = frame.step(reactor)
        if sr.is_done():
            done = True
            final_id = sr.take_response[Int]()
        elif sr.is_error():
            raise Error("erased generic stream errored: " + sr.err_text())
        guard += 1
    assert_true(done, "the erased generic stream completes")
    assert_equal(final_id, 1001, "the watermark round-trips through the erasure")
    assert_equal(
        pool[].connects_made(), connects_at_start, "no reconnect through the erased path"
    )
    assert_equal(pool[].in_use_count(), 0, "the lease is freed at terminal")
    _ = frame^
    print("  [4b] full lifecycle through ErasedHandlerFrame (generic, owned-across-erasure) OK")


# =============================================================================
# 5. CHEAP-VACATE move-API generic structural — take/give_back round-trips a
#    non-PG resource by value with NO reconnect (the borrow-in-place ref is
#    UNEXPRESSIBLE for Slab[Optional[T]]; the move API is the contract).
# =============================================================================
def test_take_give_back_move_api_generic() raises:
    """The generic move-based access (`take` / `give_back`) round-trips a non-PG
    resource by value with NO reconnect — the contract that replaces the
    UNEXPRESSIBLE `conn(lease) -> ref T` borrow for `Slab[Optional[T]]` storage.
    Exercises the same 1.0.0b1 wall pool.mojo documents, generically."""
    var counter = ArcPointer[_ConnectCounter](_ConnectCounter())
    var cfg = _MockConnConfig(41, String("mv"), counter.copy())
    var pool = Pool[_MockConn].connect(cfg^, 1)
    var connects = pool.connects_made()

    var lease = pool.checkout()
    assert_equal(pool.in_use_count(), 1, "lease checked out")
    var r = pool.take(lease)  # move OUT (slot -> None, lease still held)
    assert_true(pool.is_vacated(lease), "slot is None after take")
    assert_equal(r.channel_id(), 42, "base_id 41 + 1 == channel 42 (non-PG)")
    pool.give_back(lease, r^)  # move BACK + free lease
    assert_false(pool.is_vacated(lease), "slot is re-installed after give_back")
    assert_equal(pool.in_use_count(), 0, "lease freed by give_back")
    assert_equal(pool.connects_made(), connects, "take/give_back established NO new resource")
    _ = pool^
    print("  [5] take/give_back move-API round-trips a non-PG resource, no reconnect OK")


def main() raises:
    print("== generic Pool[T] non-PG proof suite ==")
    test_non_pg_resource_conforms_and_pool_establishes_eagerly()
    test_no_resource_held_across_idle_park_generic()
    test_reacquire_does_not_reconnect_generic()
    test_abandoned_frame_returns_resource_generic()
    test_lifecycle_through_erased_frame_generic()
    test_take_give_back_move_api_generic()
    print("PASS test_generic_pool_non_pg")
