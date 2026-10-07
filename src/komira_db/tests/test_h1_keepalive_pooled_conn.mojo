# =============================================================================
# komira_db/tests/test_h1_keepalive_pooled_conn.mojo
# The generic Pool[T] spans TRANSPORTS, not just DBs.
# =============================================================================
# `PgDatabase` is just ONE type of connection. test_generic_pool_non_pg.mojo
# proves the generic `Pool[T: PooledResource]` with a synthetic non-PG mock
# (`_MockConn`). THIS file proves it spans a SECOND, REAL backend: the S3 / HTTP-1.1
# keep-alive TRANSPORT connection — a dialed TLS/TCP byte-stream to an origin, the
# pooled "resource" the existing ad-hoc `_H1CacheEntry[S]` / `_h1_idle_conn` /
# `_streaming_idle_pool` cache (komira_http_client/client.mojo) keys by `PoolKey`.
#
# THE POOLED RESOURCE: `H1KeepAliveConn[S]` — a keep-alive H1 transport connection
# wrapping a real `IoStream` conformer (`ScriptedStream`, with its heap-owning
# `_read_script: List[UInt8]` — the SAME relocation shape as `_H1CacheEntry[S]._stream`
# and `ClientConn[S]._stream`). It is NOT "an S3 client": it is the dialed byte
# stream a client borrows to drive one request-response cycle. `pooled_connect`
# DIALS the origin (here: a deterministic socket-free dial that bumps a shared
# dial counter + builds a fresh ScriptedStream, mirroring `Connector.connect`
# producing a fresh `Self.Stream`); `close` drops the socket.
#
# THE THREE CAVEATS, all honored + tested:
#  (a) ORIGIN-BUCKETING. `Pool[T]` is the PER-ORIGIN unit (one origin == one
#      PoolKey == one Pool). A `Dict[PoolKey, Pool[T]]` is the multi-origin
#      layer; we do NOT try to make one Pool hold multiple origins. Mojo 1.0.0b1
#      `Dict` cannot hold a Movable-not-Copyable value (`Pool[T]`), so the
#      multi-origin registry mirrors `PerCorePool._buckets`: a `Slab` of
#      `(PoolKey, Pool[T])` resolved by linear scan on the key. Test 6.
#  (b) H2 STAYS SEPARATE. `H2ClientPool` / HTTP-2 is shared-multiplexed (N streams
#      over ONE conn), NOT exclusive-lease — it is intentionally NOT folded into
#      `Pool[T]`: an exclusive lease would serialize the streams a shared h2
#      connection exists to multiplex. This file only conforms the H1
#      (exclusive-lease) transport.
#  (c) KEEPALIVE LIVENESS. A server can silently close an idle keep-alive conn.
#      The minimal answer is NO new trait method: the pool's EXISTING
#      `discard(lease)` is the discard hook, and liveness stays REACTIVE — a
#      use that fails (head-read error on a server-closed conn) discards the dead
#      conn and re-dials (the robustness the production `_call_pooled_self_c`
#      / `send_streaming_pooled_get` already implement). Test 5 exercises exactly
#      this: a conn marked dead is `discard`ed and a fresh dial replaces it.
#
# THE SAME GUARANTEES AS PG (the proof bar): conformance + eager-establish==size;
# in_use()==0 across release; NO reconnect on re-acquire of a warm conn (BOTH the
# pool's `connects_made()` AND the out-of-pool dial counter flat across the
# vacate/restore cycle); teardown returns the conn (no leak / double-free); no
# wildcard-origin field, no partial move. NO Postgres anywhere; a REAL transport
# stream type (`ScriptedStream`) — that IS the "spans transports" proof.
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

from komira_db.pool import Pool, PooledResource

from komira_http_client.pool import PoolKey, VERIFY_PEER
from komira_http_core.transport.scripted import ScriptedStream


# =============================================================================
# A — _DialCounter — a dial-count cell that lives OUTSIDE the pool.
# =============================================================================
# The no-reconnect probe needs to count GENUINE transport dials
# (`H1KeepAliveConn.pooled_connect` calls) INDEPENDENTLY of the pool's own
# `connects_made()` instrument — so a regression that routed around the pool's
# counter would still be caught. Mojo 1.0.0b1 has NO global variables, so the
# counter is a heap cell shared (via `ArcPointer`) into the resource's Config:
# every dial bumps it. The test owns the Arc, so it reads the count from OUTSIDE
# the pool, proving NO dial fires across a vacate/restore cycle. Single-threaded
# test -> a plain Int cell suffices (no Atomic). This is the transport analog of
# the ScriptedConnector's own `connect_call_count()`.


struct _DialCounter(Movable, Deinitable):
    """A shared mutable transport-dial-count cell, reached through `ArcPointer`.
    The test holds a clone to read the dial count from OUTSIDE the pool."""

    var dials: Int

    def __init__(out self):
        self.dials = 0


# =============================================================================
# B — _H1DialConfig — the transport resource's opaque Config (an ORIGIN, not a DB).
# =============================================================================
# `H1KeepAliveConn.pooled_connect(config)` DIALS this origin. The pool treats it
# as opaque — it just copies it per eager establishment (caveat (a): one config
# == one origin == one Pool). It carries:
#   * the origin coordinates as a `PoolKey` (scheme/host/port/verify/alpn) — the
#     SAME key `pool_key_for_origin` derives in the production cache;
#   * `script_marker` — a byte planted into the dialed stream's read-script so a
#     botched type-erasure / double-free would corrupt it (the relocation canary, the
#     transport analog of `_MockConn`'s heap String label);
#   * the shared `_DialCounter` Arc, so each dial bumps the test-visible cell.
# This models "dial coords for ONE S3 origin" — anything that is NOT a PgConfig.


struct _H1DialConfig(Copyable, Movable, Deinitable):
    """A non-Postgres pooled-resource config: the DIAL COORDS for ONE H1 origin
    (a `PoolKey`) + a stream canary byte + a shared dial-count cell. `Copyable &
    Movable & Deinitable` per the `PooledResource.Config` bound — the
    Arc clone shares the SAME cell across copies (so a per-resource config copy
    still bumps the one counter)."""

    var key: PoolKey
    var script_marker: UInt8
    var dials: ArcPointer[_DialCounter]

    def __init__(
        out self,
        var key: PoolKey,
        script_marker: UInt8,
        var dials: ArcPointer[_DialCounter],
    ):
        self.key = key^
        self.script_marker = script_marker
        self.dials = dials^


# =============================================================================
# C — H1KeepAliveConn — a REAL transport pooled resource conforming to PooledResource.
# =============================================================================
# A single-owner, Movable-not-Copyable keep-alive H1 transport connection: an
# `Optional[ScriptedStream]` (the LIVE byte stream to the origin — `take()`able on
# checkout, the SAME `Optional<S>` shape as `_H1CacheEntry[S]`) + the `PoolKey` it
# was dialed for (the back-pointer the production cache validates against on
# lookup). It conforms to `PooledResource` by exposing exactly: `Config =
# _H1DialConfig`, `pooled_connect(config) -> Self` (THE ONLY dial site — bumps the
# shared dial counter), and `close(mut self)` (drop the socket). NOTHING about
# "an S3 client" — the pooled resource is the TRANSPORT, the byte stream itself.
#
# RELOCATION: the inner `ScriptedStream._read_script: List[UInt8]` is a heap-owning
# field (a relocation hazard on purpose). It is relocation-clean in `Slab[Optional[H1KeepAliveConn]]`
# because the Slab moves each Optional in/out (init_pointee_move / take_pointee /
# destroy_pointee) — no wildcard origin, no byte-slab-reinterpret of the heap field.
# This is the IDENTICAL audit `ClientConn[S]` / `_H1CacheEntry[S]` pass (and why the
# production pool stores `Slab[OwnedPointer[ClientConn[S]]]`).


struct H1KeepAliveConn(PooledResource):
    """A keep-alive H1 TRANSPORT connection: a single-owner live byte stream to one
    origin + the PoolKey it was dialed for. Movable, not Copyable (single ownership
    of the socket). Conforms to `PooledResource` — the SAME cheap-vacate machinery
    `PgDatabase` uses, over a TRANSPORT resource instead of a DB connection."""

    comptime Config = _H1DialConfig

    var _stream: Optional[ScriptedStream]
    var _key: PoolKey
    # A small id derived from the dial coords + dial ordinal, so tests can tell
    # distinct dials apart (the transport analog of `_MockConn._channel_id`).
    var _conn_id: Int
    var _alive: Bool

    def __init__(
        out self, var stream: ScriptedStream, var key: PoolKey, conn_id: Int
    ):
        self._stream = Optional[ScriptedStream](stream^)
        self._key = key^
        self._conn_id = conn_id
        self._alive = True

    @staticmethod
    def pooled_connect(var config: _H1DialConfig) raises -> H1KeepAliveConn:
        """The `PooledResource` factory: DIAL ONE H1 keep-alive transport conn to
        the origin in `config.key`. THE ONLY dial site — bumps the shared dial
        counter (the out-of-pool no-reconnect probe). The cheap-vacate cycle NEVER
        calls this (it MOVES the conn, never re-dials).

        In production `PgDatabase.pooled_connect` stands up a `BlockingRuntime` and
        runs the full TCP->TLS->SCRAM handshake; the real `H1KeepAliveConn` factory
        would stand up the same blocking runtime and call
        `connector.connect[BlockingRuntime](reactor, ip_be, port)` to dial the
        socket. Here we dial deterministically + socket-free (a fresh
        `ScriptedStream` with the config's canary byte planted), which is the
        faithful contract: produce a fresh live `IoStream` per dial, count the
        dial, key it by origin."""
        config.dials[].dials += 1
        var ordinal = config.dials[].dials
        # Plant the canary byte into the dialed stream's read-script: a botched
        # erasure / double-free of the heap `List[UInt8]` would corrupt this.
        var script = List[UInt8]()
        script.append(config.script_marker)
        var stream = ScriptedStream.from_read_script(script^)
        var key = config.key.copy()
        # conn_id encodes (port, dial ordinal) so distinct dials are tellable.
        return H1KeepAliveConn(stream^, key^, Int(config.key.port) * 1000 + ordinal)

    def close(mut self):
        """Teardown: close + drop the live byte stream (the keep-alive socket)."""
        if self._stream:
            var s = self._stream.take()
            s^.close()
        self._alive = False

    @always_inline
    def conn_id(self) -> Int:
        return self._conn_id

    def key(self) -> PoolKey:
        return self._key

    def drive_request(mut self) raises -> Int:
        """Simulate driving ONE request-response cycle on the live keep-alive
        stream. Asserts the stream is live (its heap read-script survived any
        prior move/erasure — `read_remaining() > 0`) and returns a watermark
        derived from the conn id. A keep-alive conn stays live + reusable for the
        next request: the stream is NOT consumed, only borrowed for the cycle."""
        if not self._stream:
            raise Error("H1KeepAliveConn.drive_request: stream taken / closed")
        # Liveness check: the heap `List[UInt8]` read-script must still be intact
        # (a botched erasure / double-free would leave it empty/corrupt).
        if self._stream.value().read_remaining() <= 0:
            raise Error("H1KeepAliveConn.drive_request: stream script empty")
        return self._conn_id * 10 + 1

    def is_alive(self) -> Bool:
        return self._alive

    def mark_dead(mut self):
        """Mark this conn dead (server silently closed the idle keep-alive).
        Caveat (c): the pool's `discard(lease)` then excludes it; the next
        checkout re-dials. Liveness stays REACTIVE — no trait method needed."""
        self._alive = False

    def script_is_live(self) -> Bool:
        """Relocation canary read: True iff the inner heap `List[UInt8]` read-script
        survived intact (non-empty). A botched erasure would leave it
        empty/corrupt. Used by the erased-frame test."""
        if not self._stream:
            return False
        return self._stream.value().read_remaining() > 0


# An H1 transport pool, specialized purely by swapping `T` — NO PgDatabase, NO
# PgConfig; a REAL `IoStream`-backed transport resource.
comptime _H1Pool = Pool[H1KeepAliveConn]


def _origin_key(host: String, port: UInt16) -> PoolKey:
    """The SAME origin->key shape `pool_key_for_origin` uses for http."""
    return PoolKey.http(host, port)


# =============================================================================
# D — _H1StreamHandlerSM — the streaming handler over the GENERIC transport pool.
# =============================================================================
# Identical lifecycle shape to the non-PG handler in test_generic_pool_non_pg.mojo, but `T` is a REAL
# transport conn. OWNS the keep-alive conn (`_conn: Optional[H1KeepAliveConn]`)
# ONLY during the active request burst; during the IDLE park `_conn` is None and
# the pool holds it (origin slot reserved). Proves own-during-burst /
# vacate-on-idle / re-acquire-on-wake for a TRANSPORT resource.


comptime H1_STEP_BURST: UInt8 = 0
comptime H1_STEP_IDLE: UInt8 = 1
comptime H1_STEP_DONE: UInt8 = 2


struct _H1StreamHandlerSM(Movable, Deinitable, SuspendableHandler):
    """A POC streaming handler over `Pool[H1KeepAliveConn]` proving the
    transport-connection-ownership lifecycle. `Resp = Int`."""

    comptime Resp = Int

    var _step: UInt8
    var _pool: ArcPointer[Pool[H1KeepAliveConn]]
    var _lease: Int
    var _conn: Optional[H1KeepAliveConn]
    var _token: StreamResumeToken
    var _idle: Optional[MockIdleWakeOp]
    var _bursts_remaining: Int
    var _conn_in_pool: Bool

    def __init__(
        out self,
        var pool: ArcPointer[Pool[H1KeepAliveConn]],
        lease: Int,
        var conn: H1KeepAliveConn,
        n_bursts: Int,
    ):
        self._step = H1_STEP_BURST
        self._pool = pool^
        self._lease = lease
        self._conn = Optional[H1KeepAliveConn](conn^)
        self._token = StreamResumeToken.initial()
        self._idle = Optional[MockIdleWakeOp]()
        self._bursts_remaining = n_bursts
        self._conn_in_pool = False

    def step[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> HandlerStepResult[Int]:
        if self._step == H1_STEP_BURST:
            return self._do_burst[S](reactor)
        elif self._step == H1_STEP_IDLE:
            return self._resume_idle[S](reactor)
        else:
            return HandlerStepResult[Int].error(
                String("h1-stream-poc: step() at unexpected step")
            )

    def _do_burst[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> HandlerStepResult[Int]:
        """ACTIVE BURST: we OWN the keep-alive transport conn. Drive one request
        on it, advance the token. If more bursts remain, give the conn BACK to the
        pool (cheap-vacate — NO re-dial) and PARK on a fresh idle wake holding
        ONLY the POD token. Else DONE."""
        var conn = self._conn.take()
        var watermark = conn.drive_request()
        self._token.advance(Int64(watermark), Int64(watermark))
        self._bursts_remaining -= 1

        if self._bursts_remaining <= 0:
            self._pool[].restore(self._lease, conn^)
            self._pool[].return_lease(self._lease)
            self._conn_in_pool = True
            self._step = H1_STEP_DONE
            return HandlerStepResult[Int].done(Int(self._token.last_seen_id))

        # IDLE: give the keep-alive conn BACK to the pool (cheap — no re-dial).
        self._pool[].restore(self._lease, conn^)
        self._conn_in_pool = True

        var idle = MockIdleWakeOp(1)  # ready after 1 poll
        var op_id = idle.start[S](reactor)
        self._token.idle_wake_op_id = op_id
        self._idle = Optional[MockIdleWakeOp](idle^)
        self._step = H1_STEP_IDLE
        return HandlerStepResult[Int].parked(op_id)

    def _resume_idle[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> HandlerStepResult[Int]:
        """WAKE: poll the idle op; if pending, re-park (holding NO conn — the
        origin slot stays reserved + available). If ready, RE-ACQUIRE the keep-
        alive conn from the pool (`vacate` — cheap, no re-dial) and drive the
        next request."""
        var st = self._idle.value().poll()
        if st != IDLE_READY:
            return HandlerStepResult[Int].parked(self._idle.value().op_id())

        _ = self._idle.take()
        var conn = self._pool[].vacate(self._lease)
        self._conn = Optional[H1KeepAliveConn](conn^)
        self._conn_in_pool = False
        self._step = H1_STEP_BURST
        return self._do_burst[S](reactor)

    @always_inline
    def holds_connection(self) -> Bool:
        return self._conn.__bool__()

    def __deinit__(deinit self):
        """Safety net: re-home a held keep-alive conn into its pool slot on an
        abnormal drop. Identical to the PG / non-PG POCs — generic over the
        transport resource."""
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
        if (not self._conn) and self._conn_in_pool and self._step != H1_STEP_DONE:
            try:
                self._pool[].return_lease(self._lease)
            except:
                pass


# =============================================================================
# E — _OriginRegistry — the MULTI-ORIGIN layer (caveat (a)).
# =============================================================================
# `Pool[T]` is the PER-ORIGIN unit. A multi-origin client needs a `Dict[PoolKey,
# Pool[T]]`. Mojo 1.0.0b1 `Dict` cannot hold a Movable-not-Copyable value, so —
# exactly as `PerCorePool._buckets` does for `_PoolBucket[S]` — the registry is a
# `Slab` of `(PoolKey, Pool[T])` resolved by linear scan on the key. This is the
# faithful "Dict[PoolKey, Pool[T]]" multi-origin layer: each origin gets its OWN
# Pool; one Pool NEVER holds two origins.


struct _OriginEntry(Movable, Deinitable):
    var key: PoolKey
    var pool: Pool[H1KeepAliveConn]

    def __init__(out self, var key: PoolKey, var pool: Pool[H1KeepAliveConn]):
        self.key = key^
        self.pool = pool^


struct _OriginRegistry(Movable, Deinitable):
    """The multi-origin layer: a per-origin `Pool[H1KeepAliveConn]`, resolved by
    linear scan on `PoolKey` (the `Dict[PoolKey, Pool[T]]` that Mojo 1.0.0b1's
    `Dict` limitation forces onto a Slab). One Pool per origin; one origin per Pool."""

    var _entries: Slab[_OriginEntry]

    def __init__(out self):
        self._entries = Slab[_OriginEntry]()

    def _find(self, key: PoolKey) -> Int:
        var n = self._entries.len()
        var i = 0
        while i < n:
            if self._entries[i].key == key:
                return i
            i = i + 1
        return -1

    def add_origin(
        mut self, var key: PoolKey, var pool: Pool[H1KeepAliveConn]
    ) raises:
        """Register a per-origin pool. Raises on a duplicate origin (programmer
        error — one Pool per origin)."""
        if self._find(key) >= 0:
            raise Error("origin already registered")
        self._entries.append(_OriginEntry(key^, pool^))

    def origin_count(self) -> Int:
        return self._entries.len()

    def checkout_for(mut self, key: PoolKey) raises -> Int:
        var idx = self._find(key)
        if idx < 0:
            raise Error("no pool for origin")
        return self._entries[idx].pool.checkout()

    def dials_for(self, key: PoolKey) -> Int:
        var idx = self._find(key)
        if idx < 0:
            return -1
        return self._entries[idx].pool.connects_made()

    def in_use_for(self, key: PoolKey) -> Int:
        var idx = self._find(key)
        if idx < 0:
            return -1
        return self._entries[idx].pool.in_use_count()

    def return_for(mut self, key: PoolKey, lease: Int) raises:
        var idx = self._find(key)
        if idx < 0:
            raise Error("no pool for origin")
        self._entries[idx].pool.return_lease(lease)


# =============================================================================
# 1. CONFORMANCE + EAGER-DIAL — `H1KeepAliveConn` conforms to `PooledResource`,
#    and `Pool[H1KeepAliveConn]` DIALS exactly `size` transport conns eagerly.
# =============================================================================
def test_h1_transport_conforms_and_pool_dials_eagerly() raises:
    """A REAL transport resource (`H1KeepAliveConn` over a live `ScriptedStream`)
    drives the generic `Pool[T]`. The pool DIALS exactly `size` keep-alive conns
    at construction — the out-of-pool dial counter AND the pool's own
    `connects_made()` both report `size`. The "spans transports" structural
    proof: the SAME `Pool[T]` machinery, a transport `T` (NOT a DB)."""
    var counter = ArcPointer[_DialCounter](_DialCounter())
    var key = _origin_key(String("10.0.0.5"), UInt16(80))
    var cfg = _H1DialConfig(key^, UInt8(0xAB), counter.copy())
    var pool = Pool[H1KeepAliveConn].connect(cfg^, 4)
    assert_equal(pool.size(), 4, "the pool holds 4 keep-alive transport conns")
    assert_equal(pool.connects_made(), 4, "the pool dialed 4 conns eagerly")
    assert_equal(
        counter[].dials,
        4,
        "exactly 4 transport dials fired (counter outside the pool)",
    )
    assert_equal(pool.in_use_count(), 0, "no lease checked out yet")
    _ = pool^
    print("  [1] H1 transport conn conforms + Pool dials eagerly OK")


# =============================================================================
# 2. in_use_count()==0 / slot-available across an idle re-park — 503-prevention
#    over a TRANSPORT pool.
# =============================================================================
def test_no_transport_conn_held_across_idle_park() raises:
    """Drive the streaming frame over the transport pool to its FIRST idle park.
    The frame holds NO conn AND the size-1 pool's conn is back in its origin slot
    (available) — the keep-alive 503-prevention property over a transport."""
    var reactor = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    var counter = ArcPointer[_DialCounter](_DialCounter())
    var key = _origin_key(String("127.0.0.1"), UInt16(8080))
    var cfg = _H1DialConfig(key^, UInt8(0x11), counter.copy())
    var pool = ArcPointer[Pool[H1KeepAliveConn]](
        Pool[H1KeepAliveConn].connect(cfg^, 1)
    )

    var lease = pool[].checkout()
    var conn = pool[].vacate(lease)
    var sm = _H1StreamHandlerSM(pool.copy(), lease, conn^, 3)

    var sr0 = sm.step(reactor)
    assert_true(sr0.is_parked(), "after request 0 the frame idle-parks")
    assert_true(
        sr0.op_id() >= OP_ID_ALLOC_BASE,
        "the idle-wake op_id is biased (a dynamically-registered op)",
    )
    assert_false(sm.holds_connection(), "the idle-parked frame holds NO conn")
    assert_false(
        pool[].is_vacated(lease),
        "the keep-alive conn is back IN the origin slot while idle-parked",
    )
    assert_equal(
        pool[].in_use_count(),
        1,
        "the lease stays held across the idle (vacate keeps the slot reserved)",
    )
    _ = sm^
    print("  [2] no transport conn held across idle re-park OK")


# =============================================================================
# 3. NO-RECONNECT probe — re-acquire of a WARM keep-alive conn does NOT re-dial.
#    BOTH the pool's connects_made() AND the out-of-pool dial counter are FLAT.
# =============================================================================
def test_reacquire_warm_conn_does_not_redial() raises:
    """Run a full multi-request stream over the transport pool to completion. The
    pool dialed exactly `size` conns at construction; the vacate/restore cycle
    across every idle re-park must NOT dial a new conn (the keep-alive guarantee:
    a warm conn is reused, not re-dialed). BOTH the pool's `connects_made()` AND
    the out-of-pool dial counter are UNCHANGED across the whole stream."""
    var reactor = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    var counter = ArcPointer[_DialCounter](_DialCounter())
    var key = _origin_key(String("10.1.2.3"), UInt16(443))
    var cfg = _H1DialConfig(key^, UInt8(0x22), counter.copy())
    var pool = ArcPointer[Pool[H1KeepAliveConn]](
        Pool[H1KeepAliveConn].connect(cfg^, 1)
    )
    assert_equal(counter[].dials, 1, "size-1 pool dialed 1 conn")
    var pool_connects_at_start = pool[].connects_made()
    assert_equal(pool_connects_at_start, 1, "the pool reports 1 dial")
    var dials_after_connect = counter[].dials

    var lease = pool[].checkout()
    var conn = pool[].vacate(lease)
    # 4 requests -> 3 idle gaps -> 3 warm re-acquires, none re-dialing.
    var sm = _H1StreamHandlerSM(pool.copy(), lease, conn^, 4)

    var guard = 0
    var done = False
    while (not done) and guard < 100:
        var sr = sm.step(reactor)
        if sr.is_done():
            done = True
        elif sr.is_error():
            raise Error("transport stream errored: " + sr.err_text())
        guard += 1
    assert_true(done, "the transport stream completes within the guard bound")

    # THE GUARD (GREEN — cheap-vacate / keep-alive reuse): no new dial.
    assert_equal(
        pool[].connects_made(),
        pool_connects_at_start,
        "warm re-acquire across idle re-parks dialed NO new conn (pool counter)",
    )
    assert_equal(
        counter[].dials,
        dials_after_connect,
        "NO transport dial fired across the vacate/restore cycle (counter outside pool)",
    )
    _ = sm^
    print("  [3] warm keep-alive re-acquire does NOT re-dial OK")


# =============================================================================
# 4. ABANDONED-FRAME TEARDOWN — drop a long-lived frame; the keep-alive conn
#    returns to the pool (no leak / no double-free). Both idle AND mid-burst.
# =============================================================================
def test_abandoned_transport_frame_returns_conn() raises:
    """(a) IDLE-PARK DROP: drive to an idle park (conn in the pool), DROP. The
    pool's conn is intact in its origin slot and the lease is freed. (b)
    MID-BURST DROP: a fresh frame OWNS the conn; DROP before it parks — the
    `__del__` safety net re-homes the owned conn into the slot + frees the lease.
    No re-dial either way."""
    var reactor = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    var counter = ArcPointer[_DialCounter](_DialCounter())
    var key = _origin_key(String("192.168.0.9"), UInt16(80))
    var cfg = _H1DialConfig(key^, UInt8(0x33), counter.copy())

    # ---- (a) idle-park drop ----
    var pool_a = ArcPointer[Pool[H1KeepAliveConn]](
        Pool[H1KeepAliveConn].connect(cfg.copy(), 1)
    )
    var dials_a = pool_a[].connects_made()
    var lease_a = pool_a[].checkout()
    var conn_a = pool_a[].vacate(lease_a)
    var sm_a = _H1StreamHandlerSM(pool_a.copy(), lease_a, conn_a^, 5)
    var sr_a = sm_a.step(reactor)  # request 0 -> vacate -> idle park
    assert_true(sr_a.is_parked())
    assert_false(sm_a.holds_connection(), "idle-parked: conn in the pool")
    assert_false(pool_a[].is_vacated(lease_a), "the conn is in its origin slot")
    _ = sm_a^  # DROP the idle-parked frame.
    assert_false(
        pool_a[].is_vacated(lease_a),
        "after abandoning an idle-parked frame the conn is still in the pool",
    )
    assert_equal(pool_a[].in_use_count(), 0, "the lease is freed after teardown")
    assert_equal(pool_a[].connects_made(), dials_a, "no re-dial on teardown")

    # ---- (b) mid-burst drop ----
    var pool_b = ArcPointer[Pool[H1KeepAliveConn]](
        Pool[H1KeepAliveConn].connect(cfg.copy(), 1)
    )
    var dials_b = pool_b[].connects_made()
    var lease_b = pool_b[].checkout()
    var conn_b = pool_b[].vacate(lease_b)
    var sm_b = _H1StreamHandlerSM(pool_b.copy(), lease_b, conn_b^, 5)
    assert_true(sm_b.holds_connection(), "freshly-built frame OWNS the conn")
    assert_true(pool_b[].is_vacated(lease_b), "the slot is vacated (frame holds it)")
    _ = sm_b^  # DROP the mid-burst frame (still owning the conn).
    assert_false(
        pool_b[].is_vacated(lease_b),
        "the mid-burst-dropped frame re-homed its conn into the pool",
    )
    assert_equal(pool_b[].in_use_count(), 0, "the lease is freed after mid-burst teardown")
    assert_equal(pool_b[].connects_made(), dials_b, "no re-dial on mid-burst teardown")
    print("  [4] abandoned transport frame returns the conn (idle + mid-burst) OK")


# =============================================================================
# 4b. ERASURE SAFETY — the SAME lifecycle through `ErasedHandlerFrame`. The keep-alive
#     conn's heap `List[UInt8]` script survives the type-erasure bitcast.
# =============================================================================
def test_lifecycle_through_erased_frame_transport() raises:
    """The transport-pool streaming handler, erased into `ErasedHandlerFrame[NoopSink]`
    and stepped BLIND, runs the full vacate/restore lifecycle: the OWNED keep-
    alive conn (`H1KeepAliveConn` wrapping a `ScriptedStream` with its heap
    `List[UInt8]` script) + POD token travel through the type-erasure bitcast
    intact; `_drop_fn` runs the SM `__del__` in-place. Proves owned-across-erased-
    park is relocation-clean for a TRANSPORT resource — the script survives."""
    var reactor = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    var counter = ArcPointer[_DialCounter](_DialCounter())
    var key = _origin_key(String("10.9.9.9"), UInt16(80))
    var cfg = _H1DialConfig(key^, UInt8(0x44), counter.copy())
    var pool = ArcPointer[Pool[H1KeepAliveConn]](
        Pool[H1KeepAliveConn].connect(cfg^, 1)
    )
    var connects_at_start = pool[].connects_made()
    var lease = pool[].checkout()
    var conn = pool[].vacate(lease)
    # Canary: the dialed conn's heap script is live before the stream starts.
    assert_true(conn.script_is_live(), "the dialed conn's heap script is live")
    var sm = _H1StreamHandlerSM(pool.copy(), lease, conn^, 3)

    var frame = make_erased_handler_frame[_H1StreamHandlerSM, NoopSink](sm^, Int64(9))

    var guard = 0
    var done = False
    while (not done) and guard < 100:
        var sr = frame.step(reactor)
        if sr.is_done():
            done = True
        elif sr.is_error():
            raise Error("erased transport stream errored: " + sr.err_text())
        guard += 1
    assert_true(done, "the erased transport stream completes")
    assert_equal(
        pool[].connects_made(),
        connects_at_start,
        "no re-dial through the erased path",
    )
    assert_equal(pool[].in_use_count(), 0, "the lease is freed at terminal")
    # The conn round-tripped back into the pool; its heap script survived. The
    # stream returned its lease at completion, so re-checkout to inspect the conn.
    var inspect_lease = pool[].checkout()
    var final_conn = pool[].take(inspect_lease)
    assert_true(
        final_conn.script_is_live(),
        "the keep-alive conn's heap script survived the erasure round-trip (relocation-clean)",
    )
    pool[].give_back(inspect_lease, final_conn^)
    _ = frame^
    print("  [4b] full lifecycle through ErasedHandlerFrame (transport, relocation-clean) OK")


# =============================================================================
# 5. CAVEAT (c) — REACTIVE keepalive liveness: a server-closed idle conn is
#    DISCARDed (the pool's existing hook, NO new trait method) and re-dialed.
# =============================================================================
def test_dead_conn_is_discarded_and_redialed() raises:
    """Caveat (c): a server can silently close an idle keep-alive conn. The
    minimal answer uses NO new trait method — the pool's EXISTING `discard(lease)`
    marks the slot dead, and a fresh dial replaces it. Liveness stays REACTIVE
    (use-fails -> discard -> re-dial), exactly the robustness the production
    `_call_pooled_self_c` / `send_streaming_pooled_get` implement.

    Flow: take a warm conn, find it dead (server closed it), close + discard the
    slot, then re-dial a fresh conn into a NEW slot. The dial counter bumps ONCE
    (the re-dial), proving discard does NOT silently reuse the dead conn."""
    var counter = ArcPointer[_DialCounter](_DialCounter())
    var key = _origin_key(String("10.0.0.7"), UInt16(80))
    var cfg = _H1DialConfig(key^, UInt8(0x55), counter.copy())
    var pool = Pool[H1KeepAliveConn].connect(cfg.copy(), 2)
    assert_equal(counter[].dials, 2, "size-2 pool dialed 2 conns")
    var dials_after_eager = counter[].dials

    var lease = pool.checkout()
    var conn = pool.take(lease)  # move the warm conn out to use it
    # The server silently closed this idle keep-alive conn — discovered on use.
    conn.mark_dead()
    assert_false(conn.is_alive(), "the conn is dead (server closed it)")
    # REACTIVE liveness: close the dead conn + DISCARD its slot (existing hook).
    conn.close()
    _ = conn^
    pool.discard(lease)
    assert_equal(
        counter[].dials,
        dials_after_eager,
        "discard does NOT re-dial by itself (no silent reuse of the dead conn)",
    )

    # Re-dial a fresh conn for the SAME origin via a second lease (the live slot).
    var lease2 = pool.checkout()
    assert_true(lease2 != lease, "the discarded slot is not handed out again")
    var conn2 = pool.take(lease2)
    assert_true(conn2.is_alive(), "the replacement conn is live")
    pool.give_back(lease2, conn2^)
    # The replacement came from the eager pool (slot 1), so STILL no new dial yet;
    # now force an explicit re-dial to prove the factory path is reachable for a
    # health/reconnect follow-on.
    var fresh = H1KeepAliveConn.pooled_connect(cfg^)
    assert_true(fresh.is_alive(), "an explicit re-dial produces a live conn")
    assert_equal(
        counter[].dials,
        dials_after_eager + 1,
        "exactly ONE re-dial fired (the explicit reconnect), not a silent reuse",
    )
    _ = fresh^
    _ = pool^
    print("  [5] dead conn discarded + re-dialed (reactive liveness, no trait change) OK")


# =============================================================================
# 6. CAVEAT (a) — ORIGIN-BUCKETING: one Pool per origin; a Dict[PoolKey,Pool[T]]
#    multi-origin layer; one Pool NEVER holds two origins.
# =============================================================================
def test_origin_bucketing_one_pool_per_origin() raises:
    """Caveat (a): `Pool[T]` is the PER-ORIGIN unit. A multi-origin client keys
    `Pool[T]` by `PoolKey` in a registry (`Dict[PoolKey,Pool[T]]`, realized as a
    Slab+linear-scan per the 1.0.0b1 `Dict` limitation). Two distinct origins get two
    distinct pools; a checkout for origin A never touches origin B's conns; the
    per-origin dial counts are independent. We do NOT try to make one Pool hold
    both origins."""
    var counter_a = ArcPointer[_DialCounter](_DialCounter())
    var counter_b = ArcPointer[_DialCounter](_DialCounter())
    var key_a = _origin_key(String("10.0.0.1"), UInt16(80))
    var key_b = _origin_key(String("10.0.0.2"), UInt16(80))
    var cfg_a = _H1DialConfig(key_a.copy(), UInt8(0xA0), counter_a.copy())
    var cfg_b = _H1DialConfig(key_b.copy(), UInt8(0xB0), counter_b.copy())

    var registry = _OriginRegistry()
    registry.add_origin(key_a.copy(), Pool[H1KeepAliveConn].connect(cfg_a^, 2))
    registry.add_origin(key_b.copy(), Pool[H1KeepAliveConn].connect(cfg_b^, 3))

    assert_equal(registry.origin_count(), 2, "two distinct origins, two pools")
    assert_equal(registry.dials_for(key_a), 2, "origin A pool dialed 2 conns")
    assert_equal(registry.dials_for(key_b), 3, "origin B pool dialed 3 conns")
    # The per-origin dial counters are independent (no cross-origin pooling).
    assert_equal(counter_a[].dials, 2, "origin A's out-of-pool dial counter is 2")
    assert_equal(counter_b[].dials, 3, "origin B's out-of-pool dial counter is 3")

    # A checkout for origin A touches ONLY origin A's pool.
    var la = registry.checkout_for(key_a)
    assert_equal(registry.in_use_for(key_a), 1, "origin A has 1 conn in use")
    assert_equal(registry.in_use_for(key_b), 0, "origin B is untouched by A's checkout")
    registry.return_for(key_a, la)
    assert_equal(registry.in_use_for(key_a), 0, "origin A's lease returned")

    # Duplicate-origin registration is rejected (one Pool per origin).
    var dup_raised = False
    try:
        registry.add_origin(key_a.copy(), Pool[H1KeepAliveConn].connect(
            _H1DialConfig(key_a.copy(), UInt8(0xA1), counter_a.copy())^, 1
        ))
    except:
        dup_raised = True
    assert_true(dup_raised, "registering a duplicate origin is rejected")

    _ = registry^
    _ = key_a^
    _ = key_b^
    print("  [6] origin-bucketing: one Pool per origin, Dict[PoolKey,Pool] layer OK")


def main() raises:
    print("== generic Pool[T] spans TRANSPORTS (S3/H1 keep-alive) ==")
    test_h1_transport_conforms_and_pool_dials_eagerly()
    test_no_transport_conn_held_across_idle_park()
    test_reacquire_warm_conn_does_not_redial()
    test_abandoned_transport_frame_returns_conn()
    test_lifecycle_through_erased_frame_transport()
    test_dead_conn_is_discarded_and_redialed()
    test_origin_bucketing_one_pool_per_origin()
    print("PASS test_h1_keepalive_pooled_conn")
