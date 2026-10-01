# =============================================================================
# test_real_timer_park_lifecycle.mojo
# The REAL reactor timer + the full streaming lifecycle.
# =============================================================================
# test_stream_conn_lifecycle_poc.mojo proved the
# OWNERSHIP / destroy-recreate shape of a streaming frame's connection lifecycle, using a
# `MockIdleWakeOp` poll-counter standing in for the not-yet-built reactor timer.
# This suite lands the REAL primitive: `reactor.register_timer(deadline_ns)` ->
# a BIASED, parkable op_id that fires as an ordinary fd-readiness completion
# (Linux timerfd / macOS EVFILT_TIMER), routed through the SAME run_once demux
# as a register_read — so a parked frame keyed on the timer op_id resumes via
# the existing driver path with ZERO driver change.
#
# THE FULL PROVABLE LOOP (vs the MockIdleWakeOp unit POC):
#   own-during-burst -> release the conn to the pool -> register_timer + park
#   (holding only the POD StreamResumeToken) -> deadline FIRES (real kernel
#   wake) -> resume -> re-acquire -> re-burst.
#
# Guards (TDD — written FIRST; fail before register_timer exists, pass after):
#   1. REGISTER_TIMER op_id is BIASED (>= OP_ID_ALLOC_BASE) — routes through the
#      handler demux exactly like a PG read, not as an fd-cookie.
#   2. REAL DEADLINE FIRES — Linux/macOS: a short timer becomes is_ready() after
#      a run_once whose timeout exceeds the deadline; a run_once BEFORE the
#      deadline does NOT report it ready. (Linux primary gate; macOS via the
#      EVFILT_TIMER branch, compile-guarded.)
#   3. FULL LIFECYCLE — a frame parks on a real register_timer op, RELEASES its
#      connection to the pool BEFORE parking, the deadline fires, it resumes,
#      re-acquires, and re-bursts. pool.in_use_count() reflects the lease held;
#      the conn is in the pool (NOT pinned) while parked.
#   4. NO TIMERFD LEAK — register many timers + deregister them; the reactor
#      closes each reactor-owned timerfd (asserted structurally: deregister +
#      Reactor __del__ both close; we exercise both paths without fd exhaustion).
#   5. ABANDONED-FRAME TEARDOWN — drop a frame mid-park (timer still armed) and
#      mid-burst (conn owned); the conn returns to the pool both ways and the
#      timerfd is closed by deregister / Reactor __del__ — no leak, no
#      double-free.
#
# Backend: BACKEND_EPOLL on Linux (real timerfd), BACKEND_KQUEUE on macOS (real
# EVFILT_TIMER). The connection + pool are the SAME mock shapes as STREAM-
# FOUNDATION 2 (`_FakeConn` / `_CountingConnPool`) mirroring PgDatabase / PgPool
# cheap-vacate — so the lifecycle is proved end-to-end against the REAL reactor
# timer without docker / a live Postgres.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true
from std.sys.info import CompilationTarget

from komira_async.ops.waker_sink import NoopSink, WakerSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    BACKEND_MOCK,
    OP_ID_ALLOC_BASE,
    Reactor,
)
from komira_async.runtime.stream_conn_lifecycle import (
    IDLE_READY,
    RealTimerIdleWakeOp,
    StreamResumeToken,
)
from komira_async.runtime.suspendable_handler import (
    HandlerStepResult,
    SuspendableHandler,
)

from komira_core.collections.slab import Slab


# =============================================================================
# backend selection helper. Linux = EPOLL (timerfd); macOS = KQUEUE
#      (EVFILT_TIMER). Any other target falls back to MOCK (no real timer).
# =============================================================================


def _real_timer_backend() -> UInt8:
    comptime if CompilationTarget.is_linux():
        return BACKEND_EPOLL
    elif CompilationTarget.is_macos():
        return BACKEND_KQUEUE
    else:
        return BACKEND_MOCK


def _has_real_timer() -> Bool:
    comptime if CompilationTarget.is_linux():
        return True
    elif CompilationTarget.is_macos():
        return True
    else:
        return False


# =============================================================================
# _FakeConn / _CountingConnPool — the SAME cheap-vacate mock shapes as
#      2, mirroring PgDatabase / PgPool.
# =============================================================================


struct _FakeConn(Movable, Deinitable):
    """A mock single-owner connection over a "socket id". Movable, not Copyable.
    The `_label` heap String makes the round-trip a genuine destroy-recreate test."""

    var _socket_id: Int
    var _label: String

    def __init__(out self, socket_id: Int, var label: String):
        self._socket_id = socket_id
        self._label = label^

    @always_inline
    def socket_id(self) -> Int:
        return self._socket_id

    def read_burst(self, want_rows: Int) -> Int:
        return self._socket_id * 1000 + want_rows


struct _CountingConnPool(Movable, Deinitable):
    """A bounded mock pool over `Optional[_FakeConn]` slots, mirroring PgPool's
    cheap-vacate surface (checkout/return_conn/vacate/restore/connects_made/
    in_use_count). `_connects_made` counts ONLY genuine socket establishments."""

    var _slots: Slab[Optional[_FakeConn]]
    var _in_use: List[Bool]
    var _connects_made: Int

    def __init__(out self, size: Int):
        self._slots = Slab[Optional[_FakeConn]](size)
        self._in_use = List[Bool]()
        var connects = 0
        for i in range(size):
            self._slots.append(
                Optional[_FakeConn](_FakeConn(i + 1, String("conn-") + String(i)))
            )
            self._in_use.append(False)
            connects += 1
        self._connects_made = connects

    @always_inline
    def size(self) -> Int:
        return len(self._in_use)

    def in_use_count(self) -> Int:
        var n = 0
        for i in range(len(self._in_use)):
            if self._in_use[i]:
                n += 1
        return n

    @always_inline
    def connects_made(self) -> Int:
        return self._connects_made

    def checkout(mut self) raises -> Int:
        for i in range(len(self._in_use)):
            if not self._in_use[i]:
                self._in_use[i] = True
                return i
        raise Error("pool exhausted")

    def return_conn(mut self, lease: Int) raises:
        self._in_use[lease] = False

    def vacate(mut self, lease: Int) raises -> _FakeConn:
        var slot = self._slots.replace(lease, Optional[_FakeConn]())
        if not slot:
            raise Error("vacate: lease already vacated")
        return slot.take()

    def restore(mut self, lease: Int, var conn: _FakeConn) raises:
        _ = self._slots.replace(lease, Optional[_FakeConn](conn^))

    def is_vacated(self, lease: Int) raises -> Bool:
        return not self._slots[lease]


# =============================================================================
# _RealTimerStreamHandlerSM — the streaming handler on the REAL timer.
# =============================================================================
# Identical lifecycle to 2's `_StreamHandlerSM`, but the idle
# park uses `RealTimerIdleWakeOp` (a real reactor.register_timer deadline)
# instead of the `MockIdleWakeOp` poll-counter. The connection is OWNED only
# during the active burst; during the idle park `_conn` is None (the pool holds
# the connection) and the frame carries only the POD StreamResumeToken + the
# RealTimerIdleWakeOp (also all-POD). destroy-recreate/gap7-clean.


comptime SH_STEP_BURST: UInt8 = 0
comptime SH_STEP_IDLE: UInt8 = 1
comptime SH_STEP_DONE: UInt8 = 2

# A short but observable deadline: 2 ms. Long enough that a non-blocking
# run_once (timeout 0) before it elapses does NOT report it ready; short
# enough that a blocking run_once with a generous timeout fires promptly.
comptime _IDLE_DEADLINE_NS: Int64 = Int64(2_000_000)  # 2 ms


struct _RealTimerStreamHandlerSM(
    Movable, Deinitable, SuspendableHandler
):
    """A POC streaming handler proving the connection-ownership lifecycle on the
    REAL reactor timer. Owns the connection ONLY during the active burst; vacates
    it to the pool during the idle park (parked on a real register_timer op);
    re-acquires on the deadline wake. Resp = Int (the final last_seen_id)."""

    comptime Resp = Int

    var _step: UInt8
    var _pool: ArcPointer[_CountingConnPool]
    var _lease: Int
    var _conn: Optional[_FakeConn]
    var _token: StreamResumeToken
    var _idle: Optional[RealTimerIdleWakeOp]
    var _bursts_remaining: Int
    var _conn_in_pool: Bool

    def __init__(
        out self,
        var pool: ArcPointer[_CountingConnPool],
        lease: Int,
        var conn: _FakeConn,
        n_bursts: Int,
    ):
        self._step = SH_STEP_BURST
        self._pool = pool^
        self._lease = lease
        self._conn = Optional[_FakeConn](conn^)
        self._token = StreamResumeToken.initial()
        self._idle = Optional[RealTimerIdleWakeOp]()
        self._bursts_remaining = n_bursts
        self._conn_in_pool = False

    def step[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> HandlerStepResult[Int]:
        if self._step == SH_STEP_BURST:
            return self._do_burst[S](reactor)
        elif self._step == SH_STEP_IDLE:
            return self._resume_idle[S](reactor)
        else:
            return HandlerStepResult[Int].error(
                String("real-timer-poc: step() at unexpected step")
            )

    def _do_burst[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> HandlerStepResult[Int]:
        """ACTIVE BURST: OWN the connection, read, advance. If more bursts
        remain, RELEASE the connection to the pool BEFORE parking on a REAL
        deadline timer (holding only the POD token). Else DONE."""
        var conn = self._conn.take()
        var new_id = conn.read_burst(1)
        self._token.advance(Int64(new_id), Int64(new_id))
        self._bursts_remaining -= 1

        if self._bursts_remaining <= 0:
            self._pool[].restore(self._lease, conn^)
            self._pool[].return_conn(self._lease)
            self._conn_in_pool = True
            self._step = SH_STEP_DONE
            return HandlerStepResult[Int].done(Int(self._token.last_seen_id))

        # RELEASE the connection to the pool BEFORE parking (cheap-vacate, no
        # reconnect). The conn is back in the pool slot; the lease stays held.
        self._pool[].restore(self._lease, conn^)
        self._conn_in_pool = True

        # PARK on a REAL reactor deadline timer. register_timer returns a biased
        # op_id that fires when the deadline elapses, routed like a PG read.
        var idle = RealTimerIdleWakeOp(_IDLE_DEADLINE_NS)
        var op_id = idle.start[S](reactor)
        self._token.idle_wake_op_id = op_id
        self._idle = Optional[RealTimerIdleWakeOp](idle^)
        self._step = SH_STEP_IDLE
        return HandlerStepResult[Int].parked(op_id)

    def _resume_idle[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> HandlerStepResult[Int]:
        """WAKE: the deadline fired (the driver resumed us because our op_id's
        completion arrived). Mark the timer ready, deregister it (close the
        reactor-owned timerfd), RE-ACQUIRE the connection from the pool, and run
        the next burst."""
        # The driver resumes us only when our op_id's completion has fired; the
        # reactor's is_ready(op_id) confirms it. (poll_reactor records that.)
        var st = self._idle.value().poll_reactor[S](reactor)
        if st != IDLE_READY:
            # Spurious resume (deadline not yet fired) — re-park on the same op.
            return HandlerStepResult[Int].parked(self._idle.value().op_id())

        # Deadline fired. Deregister the one-shot timer (closes the timerfd on
        # Linux; tears down EVFILT_TIMER on macOS).
        var fired_op = self._idle.value().op_id()
        reactor.deregister(fired_op)
        _ = self._idle.take()

        # RE-ACQUIRE the connection (cheap-vacate out of the pool — same socket,
        # NO reconnect).
        var conn = self._pool[].vacate(self._lease)
        self._conn = Optional[_FakeConn](conn^)
        self._conn_in_pool = False
        self._step = SH_STEP_BURST
        return self._do_burst[S](reactor)

    @always_inline
    def holds_connection(self) -> Bool:
        return self._conn.__bool__()

    @always_inline
    def current_token(self) -> StreamResumeToken:
        return self._token.copy()

    def __deinit__(deinit self):
        """Safety net: if dropped mid-burst (conn owned), re-home the conn into
        its pool slot + free the lease. If dropped idle-parked (conn in pool),
        just free the lease. Either way no leak / no double-free. NOTE: the
        reactor owns the armed timerfd keyed on the op_id; the Reactor's __del__
        closes any remaining MODE_TIMER timerfds, so an abandoned idle-parked
        frame's timer is NOT leaked even without an explicit deregister."""
        if self._conn:
            var conn = self._conn.take()
            try:
                self._pool[].restore(self._lease, conn^)
                self._pool[].return_conn(self._lease)
            except:
                pass
        elif not self._conn_in_pool:
            pass
        else:
            try:
                self._pool[].return_conn(self._lease)
            except:
                pass


# =============================================================================
# register_timer returns a BIASED op_id (the demux-disjointness contract).
# =============================================================================


def test_register_timer_op_id_is_biased() raises:
    """The op_id from register_timer is >= OP_ID_ALLOC_BASE so it routes through
    the handler demux exactly like a register_read, never as an fd-cookie."""
    var r = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), _real_timer_backend())
    var op = r.register_timer(Int64(5_000_000))
    assert_true(op >= OP_ID_ALLOC_BASE)
    # Cleanup (closes the timerfd on Linux).
    r.deregister(op)


def test_register_timer_monotone_biased() raises:
    """Successive register_timer op_ids are monotone AND all biased — they share
    the alloc_op_id namespace with register_read (no collision)."""
    var r = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), _real_timer_backend())
    var a = r.register_timer(Int64(10_000_000))
    var b = r.register_timer(Int64(10_000_000))
    assert_true(a >= OP_ID_ALLOC_BASE)
    assert_true(b > a)
    r.deregister(a)
    r.deregister(b)


# =============================================================================
# the REAL deadline fires as an ordinary completion (Linux/macOS gate).
# =============================================================================


def test_real_timer_deadline_fires() raises:
    """A short real deadline becomes is_ready() after a blocking run_once whose
    timeout exceeds it; a non-blocking run_once BEFORE the deadline does NOT
    report it ready. Linux (timerfd) primary; macOS (EVFILT_TIMER) compile-
    guarded. On a non-timer backend the test is skipped (returns early)."""
    if not _has_real_timer():
        return
    var r = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), _real_timer_backend())
    # 5 ms deadline.
    var op = r.register_timer(Int64(5_000_000))
    assert_true(op >= OP_ID_ALLOC_BASE)

    # Non-blocking poll immediately: the deadline has NOT elapsed -> not ready.
    var n0 = r.run_once(timeout_us=Int32(0))
    assert_false(r.is_ready(op))
    _ = n0

    # Blocking run_once with a generous timeout (50 ms) — the 5 ms deadline
    # MUST fire within it. The completion routes through the SAME demux as a
    # read: marks the slot ready + fires the sink.
    var n1 = r.run_once(timeout_us=Int32(50_000))
    assert_true(n1 >= 1)
    assert_true(r.is_ready(op))

    r.deregister(op)


def test_real_timer_two_concurrent_deadlines() raises:
    """Two timers with different deadlines: the short one fires first; only the
    fired op reports ready until the longer deadline elapses."""
    if not _has_real_timer():
        return
    var r = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), _real_timer_backend())
    var short_op = r.register_timer(Int64(3_000_000))    # 3 ms
    var long_op = r.register_timer(Int64(100_000_000))   # 100 ms

    # Block up to 40 ms: the short timer fires, the long one does not.
    var n = r.run_once(timeout_us=Int32(40_000))
    assert_true(n >= 1)
    assert_true(r.is_ready(short_op))
    assert_false(r.is_ready(long_op))

    r.deregister(short_op)
    r.deregister(long_op)


# =============================================================================
# FULL LIFECYCLE on the real timer: own / release-to-pool / park-on-timer /
#      deadline-fires / resume / re-acquire / re-burst.
# =============================================================================


def test_full_lifecycle_real_timer() raises:
    """The streaming frame parks on a REAL register_timer op, RELEASES its
    connection to the pool BEFORE parking, the deadline fires, it resumes,
    re-acquires, re-bursts. Asserts: conn NOT held while parked (in_use lease
    held but conn in pool slot); NO reconnect; terminal last_seen_id correct."""
    if not _has_real_timer():
        return
    var pool = ArcPointer[_CountingConnPool](_CountingConnPool(2))
    var connects_before = pool[].connects_made()

    # Lease + move the connection into the frame (the eager dispatch shape).
    var lease = pool[].checkout()
    var conn = pool[].vacate(lease)
    var socket_id = conn.socket_id()
    var sm = _RealTimerStreamHandlerSM(
        ArcPointer[_CountingConnPool](copy=pool), lease, conn^, 3
    )

    var r = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), _real_timer_backend())

    # Burst 0: owns the conn, reads, releases to pool, parks on a real timer.
    var sr0 = sm.step[NoopSink](r)
    assert_true(sr0.is_parked())
    var parked_op = sr0.op_id()
    assert_true(parked_op >= OP_ID_ALLOC_BASE)
    # The frame does NOT hold the connection while idle-parked.
    assert_false(sm.holds_connection())
    # The conn is back in the pool slot (NOT pinned) but the lease stays held.
    assert_false(pool[].is_vacated(lease))
    assert_equal(pool[].in_use_count(), 1)

    # Drive the reactor until the deadline fires.
    var fired = False
    for _attempt in range(20):
        var n = r.run_once(timeout_us=Int32(20_000))
        _ = n
        if r.is_ready(parked_op):
            fired = True
            break
    assert_true(fired)

    # Resume: deadline fired -> re-acquire + next burst -> re-park (burst 1).
    var sr1 = sm.step[NoopSink](r)
    assert_true(sr1.is_parked())
    assert_false(sm.holds_connection())
    var parked_op1 = sr1.op_id()

    # Drive to the 2nd deadline.
    var fired1 = False
    for _attempt in range(20):
        _ = r.run_once(timeout_us=Int32(20_000))
        if r.is_ready(parked_op1):
            fired1 = True
            break
    assert_true(fired1)

    # Resume: burst 2 -> terminal (bursts_remaining hits 0).
    var sr2 = sm.step[NoopSink](r)
    assert_true(sr2.is_done())
    var terminal = sr2.take_response()
    # 3 bursts of read_burst(1) -> last_seen_id = socket_id*1000 + 1.
    assert_equal(terminal, socket_id * 1000 + 1)

    # NO reconnect across the whole lifecycle — the cheap-vacate path never
    # established a new socket.
    assert_equal(pool[].connects_made(), connects_before)
    # The terminal returned the conn + freed the lease.
    assert_equal(pool[].in_use_count(), 0)


# =============================================================================
# NO TIMERFD LEAK across many register/deregister cycles.
# =============================================================================


def test_no_timerfd_leak_register_deregister() raises:
    """Register + deregister many timers in a loop. Each deregister closes the
    reactor-owned timerfd (Linux) / tears down the EVFILT_TIMER (macOS); without
    that, the process would exhaust RLIMIT_NOFILE long before the loop ends.
    The loop completing without a register_timer failure IS the no-leak
    assertion (a leaked fd per iteration would EMFILE well under 4096)."""
    if not _has_real_timer():
        return
    var r = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), _real_timer_backend())
    for _i in range(4096):
        var op = r.register_timer(Int64(1_000_000_000))  # 1 s, never fires here
        assert_true(op >= OP_ID_ALLOC_BASE)
        r.deregister(op)
    # If we got here, no fd leak (a per-iteration leak EMFILEs under 4096).
    assert_true(True)


def test_no_timerfd_leak_reactor_del() raises:
    """Register many timers and DROP the reactor without deregistering — the
    Reactor's __del__ closes every remaining MODE_TIMER timerfd. Repeated in an
    outer loop: a leak in __del__ would EMFILE across the repeats."""
    if not _has_real_timer():
        return
    for _round in range(64):
        var r = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), _real_timer_backend())
        for _i in range(64):
            var op = r.register_timer(Int64(1_000_000_000))
            assert_true(op >= OP_ID_ALLOC_BASE)
        # Drop r WITHOUT deregistering — __del__ must close all 64 timerfds.
    assert_true(True)


# =============================================================================
# ABANDONED-FRAME TEARDOWN — drop mid-park (timer armed) + mid-burst.
# =============================================================================


def test_abandoned_frame_mid_park() raises:
    """Drop a frame while idle-parked on a real timer (conn in pool, timer
    armed). The conn must already be in the pool (not pinned); the frame's
    __del__ frees the lease; the Reactor's __del__ closes the armed timerfd.
    No leak / no double-free."""
    if not _has_real_timer():
        return
    var pool = ArcPointer[_CountingConnPool](_CountingConnPool(1))
    var lease = pool[].checkout()
    var conn = pool[].vacate(lease)
    var sm = _RealTimerStreamHandlerSM(
        ArcPointer[_CountingConnPool](copy=pool), lease, conn^, 5
    )
    var r = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), _real_timer_backend())
    # Burst 0 -> release conn to pool + park on a real timer.
    var sr = sm.step[NoopSink](r)
    assert_true(sr.is_parked())
    assert_false(sm.holds_connection())
    assert_false(pool[].is_vacated(lease))  # conn is in the pool while parked
    # Drop sm (idle-parked) — __del__ frees the lease; the conn is already in
    # the pool. Drop r — __del__ closes the armed timerfd.
    _ = sm^
    _ = r^
    # The conn is still in the pool slot (size-1 pool intact); lease freed.
    assert_false(pool[].is_vacated(lease))
    assert_equal(pool[].in_use_count(), 0)


def test_abandoned_frame_mid_burst() raises:
    """Drop a frame mid-burst (conn OWNED, not yet released). The frame's
    __del__ re-homes the owned conn into its pool slot + frees the lease — no
    leak / no double-free of the heap-String-bearing conn."""
    var pool = ArcPointer[_CountingConnPool](_CountingConnPool(1))
    var lease = pool[].checkout()
    var conn = pool[].vacate(lease)  # slot now None; frame owns the conn
    var sm = _RealTimerStreamHandlerSM(
        ArcPointer[_CountingConnPool](copy=pool), lease, conn^, 5
    )
    # Do NOT step — the frame still OWNS the conn (mid-burst shape).
    assert_true(sm.holds_connection())
    assert_true(pool[].is_vacated(lease))  # pool slot is None right now
    _ = sm^  # drop mid-burst: __del__ re-homes the conn + frees the lease
    assert_false(pool[].is_vacated(lease))  # conn restored to the slot
    assert_equal(pool[].in_use_count(), 0)


def main() raises:
    test_register_timer_op_id_is_biased()
    test_register_timer_monotone_biased()
    test_real_timer_deadline_fires()
    test_real_timer_two_concurrent_deadlines()
    test_full_lifecycle_real_timer()
    test_no_timerfd_leak_register_deregister()
    test_no_timerfd_leak_reactor_del()
    test_abandoned_frame_mid_park()
    test_abandoned_frame_mid_burst()
    print("PASS komira_async real-timer park lifecycle")
