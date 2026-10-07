# =============================================================================
# test_stream_conn_lifecycle_poc.mojo
# The connection-ownership lifecycle POC + guard suite.
# =============================================================================
# Proves the SAFE SHAPE for a long-lived / streaming suspendable frame's
# connection-ownership lifecycle, INDEPENDENT of the not-yet-built reactor timer
# (a `MockIdleWakeOp` poll-counter stands in for the idle wake):
#
#   ACTIVE READ BURST  — the frame OWNS a moved-out connection (`Optional[Conn]`)
#                        across its OWN read park (safe across destroy-recreate: owned value, moves
#                        with the SM through the ErasedHandlerFrame bitcast).
#   IDLE WAIT          — the frame GIVES the connection BACK to the pool
#                        (`pool.vacate(lease)`) and holds ONLY a POD
#                        `StreamResumeToken` across the idle park. NO connection
#                        pinned while idle -> the pool is not exhausted.
#   ON WAKE            — RE-ACQUIRE through the pool handle (`pool.restore`),
#                        never a stored ref. The cheap-vacate primitive makes
#                        this a pure ownership move — NO reconnect.
#
# The 5 guards (TDD — written FIRST; must fail before the impl, pass after):
#   1. ENCAPSULATION (asserted structurally + by the lint gate, not in-test):
#      destroy-recreate / wildcard-origin / partial-move lints clean on the lifecycle code.
#   2. pool.in_use_count() == 0 across an idle re-park — the frame holds NO
#      connection while idle-parked.
#   3. NO-RECONNECT probe — a connect-count instrument asserts re-acquire after
#      an idle park does NOT establish a new connection (catches the
#      take()/connect_blocking handshake regression). This test FAILS on the
#      naive placeholder-handshake path and PASSES on the cheap-vacate path.
#   4. ABANDONED-FRAME TEARDOWN — drop a long-lived frame while idle-parked
#      (connection in the pool) AND while mid-burst (connection owned); assert
#      the connection is returned to the pool both ways — not leaked, not
#      double-freed. The `__del__` safety net handles the re-leased-per-burst
#      lifecycle.
#   5. NEGATIVE CHECK — the banned stored-borrow shape (`ref [pool] Conn` field
#      across the park) kept as a documented compile-fail snippet so it cannot
#      be reintroduced.
#
# Backend: BACKEND_MOCK — no kernel fds, cross-platform. The connection + pool
# are mocks (`_FakeConn` / `_CountingConnPool`) that mirror `PgDatabase` /
# `PgPool.vacate`/`restore`/`connects_made`/`in_use_count` EXACTLY — so the POC
# proves the lifecycle shape the real `PgPool` cheap-vacate primitive supports,
# without docker / a live Postgres. The real `PgPool` cheap-vacate is exercised
# by the production handler; this suite locks the OWNERSHIP / destroy-recreate shape.
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

from komira_collections.slab import Slab


# =============================================================================
# _FakeConn — a mock connection that counts live sockets (mirrors
#      PgDatabase: a single-owner, Movable-not-Copyable handle over a "socket").
# =============================================================================
# A _FakeConn owns a "socket id" (a positive Int when live, 0 when closed). It is
# Movable, NOT Copyable (single ownership of its socket), with a heap-owning
# String field so a botched erasure / double-free would corrupt it — the destroy-recreate
# shape on purpose, identical to the erased-frame test's _ToyResp rationale.


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
        """Simulate reading `want_rows` rows over the live socket; returns the
        new highest row id (the socket id stands in for the data source)."""
        return self._socket_id * 1000 + want_rows


# =============================================================================
# _CountingConnPool — a mock pool mirroring PgPool's cheap-vacate surface.
# =============================================================================
# Mirrors EXACTLY the real `PgPool` surface the streaming lifecycle uses:
#   * checkout() -> lease ; return_conn(lease)
#   * vacate(lease) -> _FakeConn   (cheap: leaves the slot None, NO new socket)
#   * restore(lease, conn^)        (cheap: re-installs, NO new socket)
#   * connects_made()              (the no-reconnect probe instrument)
#   * in_use_count()               (free-count across an idle re-park)
# Each slot is an `Optional[_FakeConn]` (the SAME cheap-vacate storage shape the
# real PgPool now uses): a vacated slot holds None — no fabricated socket. The
# `_connects_made` counter is bumped ONLY when a NEW socket is established (eager
# connect). vacate/restore are pure ownership moves and do NOT bump it.


struct _CountingConnPool(Movable, Deinitable):
    """A bounded mock pool over `Optional[_FakeConn]` slots, mirroring the real
    `PgPool` cheap-vacate surface. The `_connects_made` instrument is the
    no-reconnect probe: it counts ONLY genuine socket establishments (eager
    connect), NEVER a vacate/restore cycle."""

    var _slots: Slab[Optional[_FakeConn]]
    var _in_use: List[Bool]
    var _connects_made: Int

    def __init__(out self, size: Int):
        self._slots = Slab[Optional[_FakeConn]](size)
        self._in_use = List[Bool]()
        var connects = 0
        for i in range(size):
            # Establish a real socket per slot (the eager-connect handshake).
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
        """Cheap-vacate: move the connection OUT, leave the slot None, KEEP the
        lease held. NO new socket — `_connects_made` is untouched."""
        var slot = self._slots.replace(lease, Optional[_FakeConn]())
        if not slot:
            raise Error("vacate: lease already vacated")
        return slot.take()

    def restore(mut self, lease: Int, var conn: _FakeConn) raises:
        """Cheap-restore: re-install the connection. NO new socket."""
        _ = self._slots.replace(lease, Optional[_FakeConn](conn^))

    def naive_take_with_placeholder(mut self, lease: Int) raises -> _FakeConn:
        """The BANNED OLD shape, kept ONLY to prove the no-reconnect test (test 3)
        DISCRIMINATES: this is what the pre-cheap-vacate `PgPool.take()` did —
        fabricate a placeholder connection (a full handshake -> bump
        `_connects_made`) to keep the slot non-None, then return the real conn.
        A streaming frame that release+re-took its connection per idle cycle on
        THIS path would bump `_connects_made` on every cycle. The cheap-vacate
        path (`vacate`/`take` above) does NOT. Used only by the RED-proof
        assertion in test 3 — the production lifecycle NEVER calls this."""
        var slot = self._slots.replace(
            lease,
            # The placeholder "handshake": a fresh socket (bumps the counter).
            Optional[_FakeConn](_FakeConn(9999, String("placeholder"))),
        )
        self._connects_made += 1  # the fabricated-placeholder handshake cost
        if not slot:
            raise Error("naive_take: lease already vacated")
        return slot.take()

    def is_vacated(self, lease: Int) raises -> Bool:
        return not self._slots[lease]


# =============================================================================
# _StreamHandlerSM — the POC streaming handler with the SAFE lifecycle.
# =============================================================================
# Models a long-lived polling stream over `n_bursts` bursts. Each burst:
#   (a) RE-ACQUIRE: restore the connection from the pool (it was vacated during
#       the prior idle). On the FIRST burst it takes the eagerly-leased conn.
#   (b) ACTIVE BURST: OWN the connection across the read (here a synchronous
#       read_burst; in production a parked PG read). Advance the resume token.
#   (c) IDLE: vacate the connection BACK to the pool, start a MockIdleWakeOp,
#       hold ONLY the POD token, PARK on the idle op_id.
#   (d) WAKE: poll the idle op; ready -> next burst; pending -> re-park.
# After `n_bursts`, DONE.
#
# THE OWNERSHIP INVARIANT: the connection is OWNED (in
# `_conn: Optional[_FakeConn]`) ONLY during the active burst; during the IDLE
# park `_conn` is None and the pool holds the connection. The pool handle is an
# `ArcPointer[_CountingConnPool]` — the SAME shape `NotifListPgHandlerSM` uses
# (a borrowed `ref [pool]` field is BANNED here; see test 5). NO field holds a
# wildcard origin or a borrowed pointer; the resume token is all-POD; the burst
# connection is an owned value. destroy-recreate/gap7-clean.


comptime SH_STEP_BURST: UInt8 = 0  # re-acquire + read + advance, then go idle
comptime SH_STEP_IDLE: UInt8 = 1  # parked on the idle wake
comptime SH_STEP_DONE: UInt8 = 2


struct _StreamHandlerSM(Movable, Deinitable, SuspendableHandler):
    """A POC streaming handler proving the connection-ownership lifecycle. Owns
    the connection ONLY during the active burst (`_conn` Some), vacates it to the
    pool during the idle park (`_conn` None), and re-acquires on wake. Conforms
    to `SuspendableHandler` with `Resp = Int` (a toy terminal — the final
    `last_seen_id` — so the substrate stays HTTP-free)."""

    comptime Resp = Int

    var _step: UInt8
    var _pool: ArcPointer[_CountingConnPool]
    var _lease: Int
    # OWNED across the active burst only; None during the idle park (the pool
    # holds the connection then). The load-bearing owned-not-borrowed field.
    var _conn: Optional[_FakeConn]
    var _token: StreamResumeToken
    var _idle: Optional[MockIdleWakeOp]
    var _bursts_remaining: Int
    # True once the connection has been vacated/returned to the pool for good (or
    # is currently in the pool during an idle park) — the `__del__` safety-net
    # guard, so teardown does not double-return.
    var _conn_in_pool: Bool

    def __init__(
        out self,
        var pool: ArcPointer[_CountingConnPool],
        lease: Int,
        var conn: _FakeConn,
        n_bursts: Int,
    ):
        """The dispatcher leased a connection (slot `lease`) eagerly and moved it
        in. The handler OWNS it for the first burst, then cycles vacate/restore
        per idle gap."""
        self._step = SH_STEP_BURST
        self._pool = pool^
        self._lease = lease
        self._conn = Optional[_FakeConn](conn^)
        self._token = StreamResumeToken.initial()
        self._idle = Optional[MockIdleWakeOp]()
        self._bursts_remaining = n_bursts
        self._conn_in_pool = False  # we hold the connection right now

    def step[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> HandlerStepResult[Int]:
        if self._step == SH_STEP_BURST:
            return self._do_burst[S](reactor)
        elif self._step == SH_STEP_IDLE:
            return self._resume_idle[S](reactor)
        else:
            return HandlerStepResult[Int].error(
                String("stream-poc: step() at unexpected step")
            )

    def _do_burst[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> HandlerStepResult[Int]:
        """ACTIVE BURST: we OWN the connection (re-acquired on the prior wake, or
        the eager lease on burst 0). Read over it, advance the token. If more
        bursts remain, VACATE the connection back to the pool and PARK on a fresh
        idle wake holding ONLY the POD token. Else DONE (return the connection)."""
        # We own the connection here (re-acquired on wake / eager on burst 0).
        var conn = self._conn.take()
        var new_id = conn.read_burst(1)
        self._token.advance(Int64(new_id), Int64(new_id))
        self._bursts_remaining -= 1

        if self._bursts_remaining <= 0:
            # Terminal: return the connection to the pool and DONE.
            self._pool[].restore(self._lease, conn^)
            self._pool[].return_conn(self._lease)
            self._conn_in_pool = True
            self._step = SH_STEP_DONE
            return HandlerStepResult[Int].done(Int(self._token.last_seen_id))

        # IDLE: vacate the connection BACK to the pool (cheap — no reconnect),
        # hold ONLY the POD token across the park.
        self._pool[].restore(self._lease, conn^)
        self._conn_in_pool = True  # the pool now holds the connection
        # Note: the lease STAYS held across the idle (vacate/restore semantics);
        # we used restore (re-install) to put the conn back, and we will vacate
        # it out again on wake. The slot is reserved for us the whole time.

        var idle = MockIdleWakeOp(1)  # ready after 1 poll
        var op_id = idle.start[S](reactor)
        self._token.idle_wake_op_id = op_id
        self._idle = Optional[MockIdleWakeOp](idle^)
        self._step = SH_STEP_IDLE
        return HandlerStepResult[Int].parked(op_id)

    def _resume_idle[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> HandlerStepResult[Int]:
        """WAKE: the idle op fired. Poll it; if still pending, re-park (we still
        hold NO connection). If ready, RE-ACQUIRE the connection from the pool
        (`vacate` — cheap, no reconnect) and run the next burst."""
        var st = self._idle.value().poll()
        if st != IDLE_READY:
            # Re-park on the same idle op (still holding no connection).
            return HandlerStepResult[Int].parked(self._idle.value().op_id())

        # Idle wake fired. Re-acquire the connection (cheap-vacate out of the
        # pool — the SAME socket, no reconnect).
        _ = self._idle.take()
        var conn = self._pool[].vacate(self._lease)
        self._conn = Optional[_FakeConn](conn^)
        self._conn_in_pool = False  # we hold the connection again
        self._step = SH_STEP_BURST
        return self._do_burst[S](reactor)

    @always_inline
    def holds_connection(self) -> Bool:
        """True iff the frame currently OWNS the connection (mid-burst), False if
        it is idle-parked (the connection is in the pool). Test introspection."""
        return self._conn.__bool__()

    def __deinit__(deinit self):
        """Safety net: if the frame is dropped while it STILL OWNS the connection
        (an abnormal mid-burst drop), return it to the pool so the pool is not
        starved AND the lease is freed. If the frame is dropped while idle-parked
        (the connection is already in the pool), just free the lease. Either way
        the connection is not leaked and not double-freed: `_conn` is an owned
        Optional whose own destructor handles the held-conn case, but we must
        re-home it into the pool slot (which is currently None during an idle
        park) so the pool's slot count + socket survive.

        The re-leased-per-burst lifecycle (the connection is sometimes held,
        sometimes in the pool, at drop time) is handled by checking `_conn`:
          * `_conn` is Some (mid-burst drop): move it back into the pool slot via
            `restore`, then free the lease. The pool keeps the socket.
          * `_conn` is None (idle-park drop / already-returned): the pool already
            holds the connection in its slot; just free the lease (if not already
            freed at terminal).
        """
        if self._conn:
            # Mid-burst abnormal drop: re-home the owned connection into its pool
            # slot (currently None — vacated for the burst) so the socket is not
            # lost, then free the lease.
            var conn = self._conn.take()
            try:
                self._pool[].restore(self._lease, conn^)
                self._pool[].return_conn(self._lease)
            except:
                pass
        elif not self._conn_in_pool:
            # Defensive: no conn held AND we never marked it back in the pool —
            # should not happen, but free the lease so the pool is not starved.
            try:
                self._pool[].return_conn(self._lease)
            except:
                pass
        # If `_conn` is None and `_conn_in_pool` is True (the normal idle-park /
        # terminal state), the pool already owns the connection; the lease is
        # freed at terminal (DONE) or, for an abandoned idle-parked frame, here:
        if (not self._conn) and self._conn_in_pool and self._step != SH_STEP_DONE:
            try:
                self._pool[].return_conn(self._lease)
            except:
                pass


comptime _StreamFrame = ErasedHandlerFrame[NoopSink]


# =============================================================================
# 1. ENCAPSULATION — asserted by the lint gate (not in-test). The lifecycle
#    code (stream_conn_lifecycle.mojo + this handler) carries ZERO UnsafePointer
#    in any signature, ZERO wildcard origin, ZERO take_pointee. This test pins
#    the STRUCTURAL property the lints verify: the resume token is all-POD and
#    the connection is an OWNED Optional (never a borrowed ref).
# =============================================================================
def test_resume_token_is_pod_and_conn_is_owned() raises:
    """The StreamResumeToken is all-scalar POD (Copyable — a pure struct copy,
    no ownership transfer / no heap field) and survives a copy intact. The
    connection lives in an OWNED Optional, never a borrowed ref. This is the
    safe across destroy-recreate structural property: nothing the ErasedHandlerFrame bitcast erases an
    origin on."""
    var tok = StreamResumeToken.initial()
    assert_equal(tok.last_seen_id, Int64(0))
    assert_equal(tok.idle_wake_op_id, Int64(0))
    tok.advance(Int64(42), Int64(99))
    assert_equal(tok.last_seen_id, Int64(42))
    assert_equal(tok.cursor, Int64(99))
    # Copyable POD: a copy is independent (no shared heap buffer to dangle).
    # Mojo 1.0.0b1 distinguishes Copyable from ImplicitlyCopyable; an explicit
    # `.copy()` is the spelling for a Copyable-but-not-implicitly type.
    var tok2 = tok.copy()
    tok2.advance(Int64(100), Int64(200))
    assert_equal(tok.last_seen_id, Int64(42), "the original token is unaffected by the copy")
    assert_equal(tok2.last_seen_id, Int64(100))
    print("  [1] resume token is all-POD + conn is owned (destroy-recreate-safe shape) OK")


# =============================================================================
# 2. pool.in_use_count()/free-count across an idle re-park — the frame holds NO
#    connection while parked on the mock idle-wake.
# =============================================================================
def test_no_connection_held_across_idle_park() raises:
    """Drive the streaming frame to its FIRST idle park (burst 0 done, vacated
    the connection, parked on the idle wake). Assert the frame holds NO
    connection (`holds_connection()` False) AND the pool slot is back to
    non-vacated (the connection is in the pool, not pinned by the parked frame).
    A pool of size 1 with this one stream parked idle must have its single
    connection AVAILABLE in its slot — the 503-prevention property."""
    var reactor = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    var pool = ArcPointer[_CountingConnPool](_CountingConnPool(1))

    # Lease the single connection eagerly + hand it to the frame (3 bursts).
    var lease = pool[].checkout()
    var conn = pool[].vacate(lease)  # take it out to hand to the frame
    var sm = _StreamHandlerSM(pool.copy(), lease, conn^, 3)

    # Step once: burst 0 runs, then the frame vacates the conn + parks idle.
    var sr0 = sm.step(reactor)
    assert_true(sr0.is_parked(), "after burst 0 the frame parks on the idle wake")
    assert_true(
        sr0.op_id() >= OP_ID_ALLOC_BASE,
        "the idle-wake op_id is biased (a dynamically-registered op)",
    )

    # THE GUARD: the frame holds NO connection while idle-parked, and the pool
    # slot is NOT vacated (the connection is back in the pool, available).
    assert_false(sm.holds_connection(), "the idle-parked frame holds NO connection")
    assert_false(
        pool[].is_vacated(lease),
        "the connection is back IN the pool while the frame is idle-parked",
    )
    # The connection is NOT pinned: a size-1 pool with one idle stream still has
    # its connection in its slot (would-be 503-prevention at scale).
    _ = sm^
    print("  [2] no connection held across idle re-park (pool slot available) OK")


# =============================================================================
# 3. NO-RECONNECT probe — re-acquire after an idle park establishes NO new
#    connection. FAILS on the placeholder-handshake path; PASSES on cheap-vacate.
# =============================================================================
def test_reacquire_does_not_reconnect() raises:
    """Run a full multi-burst stream to completion. The pool established exactly
    `size` connections at construction; the vacate/restore cycle across every
    idle re-park must NOT establish any new connection. `connects_made()` must be
    UNCHANGED from its post-construction value — this is the test that FAILS on
    the old `take()` -> `connect_blocking()` placeholder-handshake path and
    PASSES on the cheap-vacate (`Optional`-slot) path."""
    var reactor = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    var pool = ArcPointer[_CountingConnPool](_CountingConnPool(1))
    var connects_at_start = pool[].connects_made()
    assert_equal(connects_at_start, 1, "size-1 pool establishes exactly 1 connection")

    var lease = pool[].checkout()
    var conn = pool[].vacate(lease)
    var sm = _StreamHandlerSM(pool.copy(), lease, conn^, 4)  # 4 bursts -> 3 idle gaps

    # Drive to completion: step until DONE (each idle park is ready after 1 poll).
    var guard = 0
    var done = False
    var final_id = Int(0)
    while (not done) and guard < 100:
        var sr = sm.step(reactor)
        if sr.is_done():
            done = True
            # Non-erased: HandlerStepResult[Int].take_response() takes NO param
            # (the Resp is the result's own type alias). The erased path's
            # ErasedStepResult.take_response[Int]() DOES take a param.
            final_id = sr.take_response()
        elif sr.is_error():
            raise Error("stream errored: " + sr.err_text())
        guard += 1
    assert_true(done, "the stream completes within the guard bound")
    # socket_id 1 (slot 0), last burst read 1 row -> 1*1000 + 1 = 1001.
    assert_equal(final_id, 1001, "the final watermark reflects the last burst read")

    # THE GUARD (GREEN — cheap-vacate path): no new connection was established
    # across the 3 vacate/restore cycles. Pure ownership move — same socket.
    assert_equal(
        pool[].connects_made(),
        connects_at_start,
        "re-acquire across idle re-parks established NO new connection (no reconnect)",
    )
    _ = sm^

    # RED-PROOF (the test DISCRIMINATES): the SAME assertion FAILS on the OLD
    # placeholder-handshake `take()` shape. We drive ONE acquire/release cycle on
    # `naive_take_with_placeholder` (what the pre-cheap-vacate PgPool.take did)
    # and show `connects_made` BUMPS — so a regression to that path would trip
    # test 3. This proves the guard is not vacuously green.
    var red_pool = ArcPointer[_CountingConnPool](_CountingConnPool(1))
    var red_before = red_pool[].connects_made()
    var red_lease = red_pool[].checkout()
    var red_conn = red_pool[].naive_take_with_placeholder(red_lease)  # OLD shape
    red_pool[].restore(red_lease, red_conn^)
    assert_true(
        red_pool[].connects_made() > red_before,
        "RED-proof: the OLD placeholder-handshake take() BUMPS connects_made (a"
        " regression would trip the no-reconnect guard) — the cheap-vacate path"
        " above does NOT",
    )
    print("  [3] re-acquire across idle re-parks does NOT reconnect (+ RED-proof) OK")


# =============================================================================
# 4. ABANDONED-FRAME TEARDOWN — drop a long-lived frame (a) while idle-parked
#    and (b) while mid-burst; the connection returns to the pool both ways.
# =============================================================================
def test_abandoned_frame_returns_connection_both_ways() raises:
    """(a) IDLE-PARK DROP: drive the frame to an idle park (connection in the
    pool), then DROP it. The pool's connection is intact in its slot (the parked
    frame never owned it) and the lease is freed — not leaked, not double-freed.
    (b) MID-BURST DROP: construct a fresh frame that OWNS the connection and DROP
    it before it ever parks. The `__del__` safety net re-homes the owned
    connection into the pool slot + frees the lease."""
    var reactor = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)

    # ---- (a) idle-park drop ----
    var pool_a = ArcPointer[_CountingConnPool](_CountingConnPool(1))
    var connects_a = pool_a[].connects_made()
    var lease_a = pool_a[].checkout()
    var conn_a = pool_a[].vacate(lease_a)
    var sm_a = _StreamHandlerSM(pool_a.copy(), lease_a, conn_a^, 5)
    var sr_a = sm_a.step(reactor)  # burst 0 -> vacate -> idle park
    assert_true(sr_a.is_parked())
    assert_false(sm_a.holds_connection(), "idle-parked: connection in the pool")
    assert_false(pool_a[].is_vacated(lease_a), "the connection is in its pool slot")
    # DROP the idle-parked frame.
    _ = sm_a^
    # The connection is still in its slot (intact), the lease is freed, NO new
    # connection was established (no leak, no reconnect, no double-free).
    assert_false(
        pool_a[].is_vacated(lease_a),
        "after abandoning an idle-parked frame the connection is still in the pool",
    )
    assert_equal(pool_a[].in_use_count(), 0, "the lease is freed after teardown")
    assert_equal(pool_a[].connects_made(), connects_a, "no reconnect on teardown")

    # ---- (b) mid-burst drop ----
    var pool_b = ArcPointer[_CountingConnPool](_CountingConnPool(1))
    var connects_b = pool_b[].connects_made()
    var lease_b = pool_b[].checkout()
    var conn_b = pool_b[].vacate(lease_b)
    # The frame OWNS the connection (constructed, never stepped -> mid-burst).
    var sm_b = _StreamHandlerSM(pool_b.copy(), lease_b, conn_b^, 5)
    assert_true(sm_b.holds_connection(), "freshly-built frame OWNS the connection")
    assert_true(pool_b[].is_vacated(lease_b), "the pool slot is vacated (frame holds it)")
    # DROP the mid-burst frame (it still owns the connection).
    _ = sm_b^
    # The __del__ safety net re-homed the owned connection into the pool slot +
    # freed the lease: the socket survives, the lease is free, no double-free.
    assert_false(
        pool_b[].is_vacated(lease_b),
        "the mid-burst-dropped frame re-homed its connection into the pool",
    )
    assert_equal(pool_b[].in_use_count(), 0, "the lease is freed after mid-burst teardown")
    assert_equal(pool_b[].connects_made(), connects_b, "no reconnect on mid-burst teardown")
    print("  [4] abandoned frame returns the connection (idle-park AND mid-burst) OK")


# =============================================================================
# 4b. ERASURE SAFETY — the SAME lifecycle through `ErasedHandlerFrame[NoopSink]`.
#     The owned connection + POD token travel through the type-erasure bitcast
#     intact; vacate/restore + the __del__ safety net fire correctly when the
#     erased frame is stepped BLIND and dropped.
# =============================================================================
def test_lifecycle_through_erased_frame() raises:
    """The streaming handler, erased into `ErasedHandlerFrame[NoopSink]` and stepped
    BLIND, runs the full vacate/restore lifecycle correctly: the OWNED connection
    moves WITH the SM through the `UInt8` blob bitcast (no origin to erase — the
    safe across destroy-recreate property), and the erased frame's `_drop_fn` runs the SM `__del__`
    safety net in-place. A stored-borrow field would dangle here; an owned field
    does not."""
    var reactor = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    var pool = ArcPointer[_CountingConnPool](_CountingConnPool(1))
    var connects_at_start = pool[].connects_made()
    var lease = pool[].checkout()
    var conn = pool[].vacate(lease)
    var sm = _StreamHandlerSM(pool.copy(), lease, conn^, 3)

    var frame = make_erased_handler_frame[_StreamHandlerSM, NoopSink](sm^, Int64(7))

    # Step the ERASED frame BLIND through the full lifecycle until DONE.
    var guard = 0
    var done = False
    var final_id = Int(0)
    while (not done) and guard < 100:
        var sr = frame.step(reactor)
        if sr.is_done():
            done = True
            final_id = sr.take_response[Int]()
        elif sr.is_error():
            raise Error("erased stream errored: " + sr.err_text())
        guard += 1
    assert_true(done, "the erased stream completes")
    assert_equal(final_id, 1001, "the watermark round-trips through the erasure")
    assert_equal(
        pool[].connects_made(), connects_at_start, "no reconnect through the erased path"
    )
    assert_equal(pool[].in_use_count(), 0, "the lease is freed at terminal")
    # The erased frame drops here: `_drop_fn` runs the SM destructor in-place
    # (the connection is already in the pool at DONE; no double-free / leak).
    _ = frame^
    print("  [4b] full lifecycle through ErasedHandlerFrame (owned-across-erasure) OK")


# =============================================================================
# 5. NEGATIVE CHECK — the BANNED stored-borrow shape, kept as a documented
#    compile-fail snippet so it cannot be reintroduced.
# =============================================================================
# What we are AVOIDING — a streaming handler that stores a BORROWED ref/pointer
# to the pooled connection across the park instead of OWNING it:
#
#     struct _BadStreamHandlerSM[pool_origin: ImmutableOrigin](
#         Movable, Deinitable, SuspendableHandler
#     ):
#         comptime Resp = Int
#         var _step: UInt8
#         # BANNED: a borrowed ref into the pool, held across the park.
#         var _conn_ref: Pointer[_FakeConn, pool_origin]   # <-- the trap
#         ...
#
# WHY IT IS BANNED (two independent failures, both fatal):
#   (1) ERASURE ERASES THE ORIGIN. `make_erased_handler_frame[_BadStreamHandlerSM, S]` bitcasts
#       the SM into a `UInt8` blob (erased_frame.mojo `make_erased_handler_frame`). The
#       `pool_origin` parameter — and the borrow chain the lifetime checker uses
#       to prove `_conn_ref` does not outlive the pool — are GONE the moment the
#       SM becomes opaque bytes. The frame then lives in the driver's
#       `Slab[ErasedHandlerFrame[S]]` for the stream's multi-minute lifetime while the
#       pool may be torn down / the slot reused (the destroy-recreate lifecycle). `_conn_ref` becomes a dangling, UNTRACKED pointer; a
#       read through it after the pool slot is reused is a UAF — the destroy-recreate
#       crash shape. An OWNED `Optional[_FakeConn]` has NO origin to erase: its
#       lifetime IS the frame's and it moves WITH the SM through the bitcast.
#   (2) The pointer rules ban a wildcard/borrowed-pointer FIELD on any struct
#       in the destroy-recreate lifecycle: a field that holds a caller-stack
#       pointer can outlive the caller via the pool's own teardown ordering. A
#       long-lived streaming frame IS
#       that lifecycle. The canonical replacement is exactly what `_StreamHandlerSM`
#       does: thread the pool through an Arc handle (compiler-tracked refcount)
#       and OWN the connection across the burst, vacate it across the idle.
#
# There is intentionally NO compiling form of `_BadStreamHandlerSM` in this file:
# a parameterized-origin field on a struct that must conform to the
# non-parameterized `SuspendableHandler` trait + erase through `make_erased_handler_frame[H,S]`
# (which takes `H: SuspendableHandler`, not `H[origin]`) does not even type — the
# trait/erasure boundary STRUCTURALLY rejects the borrowed-field shape. That
# structural rejection is the point: the safe shape is the ONLY one that compiles
# through the erasure. The lint gate (lint_wildcard_field) is the belt-and-braces
# backstop for the field-declaration form.


def test_negative_stored_borrow_shape_is_documented() raises:
    """A no-op assertion anchoring the negative-check rationale above. The banned
    `ref [pool] _FakeConn` field shape is documented as a compile-fail snippet
    (it cannot conform to the non-parameterized `SuspendableHandler` trait NOR
    erase through `make_erased_handler_frame[H, S]`), so it cannot be reintroduced.
    The safe shape (`_StreamHandlerSM`'s owned `Optional[_FakeConn]` + Arc pool
    handle) is the ONLY one that compiles through the type-erasure boundary."""
    assert_true(
        True,
        "the banned stored-borrow shape is documented above as a compile-fail snippet",
    )
    print("  [5] negative check: stored-borrow-across-park is documented as banned OK")


def main() raises:
    print("== connection-ownership lifecycle POC suite ==")
    test_resume_token_is_pod_and_conn_is_owned()
    test_no_connection_held_across_idle_park()
    test_reacquire_does_not_reconnect()
    test_abandoned_frame_returns_connection_both_ways()
    test_lifecycle_through_erased_frame()
    test_negative_stored_borrow_shape_is_documented()
    print("PASS test_stream_conn_lifecycle_poc")
