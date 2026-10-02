# =============================================================================
# test_parked_frame_demux_scaling.mojo
# =============================================================================
# O(n)->hash demux for the parked-frame store + timer-deadline jitter +
# handled re-acquire-failure backpressure.
#
# At thousands of idle parked streams the reactor's demux was O(n) per wakeup ->
# O(n^2) under a storm: `ParkedMorselSlab.take`/`.contains` and
# `Reactor._find_slot_idx` were linear scans scoped in-comment to "<100
# in-flight/worker". This suite proves the data-structure swap (an `OpIdIndexMap`
# behind the SAME public API) makes the demux SUB-LINEAR, and that the jitter +
# handled re-acquire-failure arm prevent a timer-aligned herd from synchronizing
# or throwing uncaught.
#
# Guards (TDD — written FIRST; must fail before the impl, pass after):
#   1. MAP sub-linearity        — N inserts + N lookups; total probe steps O(N).
#   2. ParkedMorselSlab scaling — park N (1000+) frames, take all, demux O(N) +
#                                 correctness preserved (FIFO/arbitrary order).
#   3. Reactor demux scaling    — register N timers (BACKEND_MOCK), N demux
#                                 lookups stay O(N).
#   4. JITTER determinism       — op_id_jitter_ns deterministic, in-band, spreads.
#   5. HERD re-acquire-fail     — more frames than pool capacity wake in
#                                 lockstep; the losers' checkout RAISES; the
#                                 handled arm RE-PARKS WITH JITTER (BACKPRESSURE
#                                 outcome) rather than throwing through resume.
#
# Backend: BACKEND_MOCK — no kernel fds, cross-platform. register_timer under
# MOCK records a MODE_TIMER slot (fd=-1) without arming a kernel timer, which is
# exactly what we need to exercise the demux index at scale.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_true, assert_false

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_MOCK,
    OP_ID_ALLOC_BASE,
    Reactor,
)
from komira_async.runtime.op_id_index_map import OpIdIndexMap
from komira_async.runtime.parked_morsel_slab import ParkedMorselSlab
from komira_async.runtime.stream_conn_lifecycle import (
    DEFAULT_JITTER_BAND_NS,
    REACQUIRE_BACKPRESSURE,
    REACQUIRE_OK,
    ReacquireOutcome,
    backpressure_repark,
    jittered_deadline_ns,
    op_id_jitter_ns,
)


# A trivial Movable-not-Copyable parked-frame state with a heap-owning field
# (List[Int]) so the slab's drop / move paths are exercised against non-POD T
# (the destroy-recreate shape — a botched move/drop would corrupt the round-trip).
struct _FrameState(Movable, Deinitable):
    var tag: Int
    var bytes: List[Int]

    def __init__(out self, tag: Int):
        self.tag = tag
        self.bytes = List[Int]()
        self.bytes.append(tag)


# =============================================================================
# Guard 1 — OpIdIndexMap sub-linearity.
# =============================================================================
def test_map_lookup_is_sublinear() raises:
    """N inserts then N lookups: the cumulative probe step count must be O(N)
    (a small constant per lookup), NOT O(N^2). A regression to a linear scan
    would make N lookups cost ~N^2/2 probes."""
    comptime N = 2000
    var m = OpIdIndexMap(capacity_hint=N)
    # Insert N biased monotone op_ids (exactly what alloc_op_id hands out).
    for k in range(N):
        m.insert(OP_ID_ALLOC_BASE + Int64(k + 1), k)
    assert_equal(m.len(), N)

    # Every key resolves to its index (correctness).
    for k in range(N):
        assert_equal(m.lookup(OP_ID_ALLOC_BASE + Int64(k + 1)), k)
    # Absent keys return -1.
    assert_equal(m.lookup(Int64(-12345)), -1)
    assert_equal(m.lookup(OP_ID_ALLOC_BASE + Int64(N + 100)), -1)

    # Sub-linearity probe: N lookups; total probes must stay under a small
    # constant * N. For an open-addressed map at < 1/2 load (capacity_hint
    # doubles), the average probe length is ~1-2; we allow a generous 8*N bound.
    # A linear-scan regression would be ~N^2/2 = 2,000,000 probes for N=2000 —
    # two orders of magnitude over the bound.
    m.reset_probe_counter()
    for k in range(N):
        _ = m.probe_lookup(OP_ID_ALLOC_BASE + Int64(k + 1))
    var probes = m.probe_steps()
    assert_true(
        probes <= 8 * N,
        String("map demux not sub-linear: ") + String(probes)
        + " probes for " + String(N) + " lookups (bound " + String(8 * N) + ")",
    )


def test_map_remove_swap_patch() raises:
    """Removal (tombstone) + an update (the swap-remove relocation) keeps the
    map correct: removed key absent, relocated key resolves to its new index."""
    var m = OpIdIndexMap()
    for k in range(8):
        m.insert(OP_ID_ALLOC_BASE + Int64(k + 1), k)
    assert_equal(m.len(), 8)
    # Remove the key at index 3; simulate swap-remove moving the last (index 7)
    # element into slot 3.
    var removed = OP_ID_ALLOC_BASE + Int64(4)  # k=3
    var moved = OP_ID_ALLOC_BASE + Int64(8)    # k=7 (was last)
    assert_true(m.remove(removed))
    m.update(moved, 3)
    assert_equal(m.len(), 7)
    assert_equal(m.lookup(removed), -1)         # tombstoned
    assert_equal(m.lookup(moved), 3)            # relocated
    assert_equal(m.lookup(OP_ID_ALLOC_BASE + Int64(1)), 0)  # untouched


# =============================================================================
# Guard 2 — ParkedMorselSlab scaling + correctness.
# =============================================================================
def test_parked_morsel_slab_scaling() raises:
    """Park N (>1000) frames, then take them all in REVERSE order. Correctness:
    every state round-trips intact (heap field preserved). Scaling: the demux
    probe count across N membership checks is O(N)."""
    comptime N = 1500
    var slab = ParkedMorselSlab[_FrameState](capacity=N)
    for k in range(N):
        slab.park(
            op_id=OP_ID_ALLOC_BASE + Int64(k + 1), state=_FrameState(tag=k)
        )
    assert_equal(slab.len(), N)

    # Sub-linearity: N membership checks; probes O(N).
    slab.reset_probe_counter()
    for k in range(N):
        assert_true(slab.probe_contains(OP_ID_ALLOC_BASE + Int64(k + 1)))
    var probes = slab.probe_steps()
    assert_true(
        probes <= 8 * N,
        String("parked-slab demux not sub-linear: ") + String(probes)
        + " probes for " + String(N) + " contains (bound " + String(8 * N) + ")",
    )

    # Take all in reverse; each state must round-trip with its heap field.
    for kk in range(N):
        var k = N - 1 - kk
        var taken = slab.take(OP_ID_ALLOC_BASE + Int64(k + 1))
        assert_true(taken.__bool__())
        var v = taken.take()
        assert_equal(v.tag, k)
        assert_equal(len(v.bytes), 1)
        assert_equal(v.bytes[0], k)
    assert_true(slab.is_empty())
    # A taken op_id is no longer present.
    assert_false(slab.contains(OP_ID_ALLOC_BASE + Int64(1)))


def test_parked_morsel_slab_interleaved() raises:
    """Interleave park / take so the swap-remove repeatedly relocates keys; the
    map must stay consistent throughout."""
    var slab = ParkedMorselSlab[_FrameState]()
    # Park 0..99.
    for k in range(100):
        slab.park(op_id=Int64(k + 1), state=_FrameState(tag=k))
    # Take every even key (forces swap-remove relocations of odd keys).
    for k in range(0, 100, 2):
        var t = slab.take(Int64(k + 1))
        assert_true(t.__bool__())
        var v = t.take()
        assert_equal(v.tag, k)
    assert_equal(slab.len(), 50)
    # All odd keys still resolve correctly.
    for k in range(1, 100, 2):
        assert_true(slab.contains(Int64(k + 1)))
        var t = slab.take(Int64(k + 1))
        assert_true(t.__bool__())
        var v = t.take()
        assert_equal(v.tag, k)
    assert_true(slab.is_empty())


# =============================================================================
# Guard 3 — Reactor demux scaling (BACKEND_MOCK timers).
# =============================================================================
def test_reactor_demux_scaling() raises:
    """Register N (>1000) MODE_TIMER slots under BACKEND_MOCK; N demux lookups
    stay O(N). Mirrors thousands of idle timer-parked streams sharing one
    worker reactor."""
    comptime N = 1200
    var reactor = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    var op_ids = List[Int64]()
    for _ in range(N):
        # register_timer under MOCK records a MODE_TIMER slot without arming a
        # kernel timer; returns the biased op_id.
        op_ids.append(reactor.register_timer(Int64(1_000_000)))
    # Every registered op_id is found by the demux.
    reactor.reset_probe_counter()
    for i in range(N):
        assert_true(reactor.probe_find_slot_idx(op_ids[i]) >= 0)
    var probes = reactor.probe_steps()
    assert_true(
        probes <= 8 * N,
        String("reactor demux not sub-linear: ") + String(probes)
        + " probes for " + String(N) + " lookups (bound " + String(8 * N) + ")",
    )
    # Deregister half (forces swap-remove + map patch); the rest stay findable.
    for i in range(0, N, 2):
        reactor.deregister(op_ids[i])
    for i in range(1, N, 2):
        assert_true(reactor.is_ready(op_ids[i]) == False)  # not fired, but found
        assert_true(reactor.probe_find_slot_idx(op_ids[i]) >= 0)
    for i in range(0, N, 2):
        assert_equal(reactor.probe_find_slot_idx(op_ids[i]), -1)  # gone


# =============================================================================
# Guard 4 — deterministic timer jitter.
# =============================================================================
def test_jitter_deterministic_and_in_band() raises:
    """op_id_jitter_ns is deterministic (same op_id -> same offset), always in
    [0, band), and spreads distinct op_ids across the band."""
    var band = DEFAULT_JITTER_BAND_NS
    # Deterministic.
    var a = op_id_jitter_ns(OP_ID_ALLOC_BASE + Int64(7), band)
    var b = op_id_jitter_ns(OP_ID_ALLOC_BASE + Int64(7), band)
    assert_equal(a, b)
    # In band.
    for k in range(64):
        var j = op_id_jitter_ns(OP_ID_ALLOC_BASE + Int64(k + 1), band)
        assert_true(j >= Int64(0))
        assert_true(j < band)
    # band <= 0 disables jitter.
    assert_equal(op_id_jitter_ns(OP_ID_ALLOC_BASE + Int64(7), Int64(0)), Int64(0))
    # Jitter only ever pushes the deadline later (offset >= 0).
    var nominal = Int64(500_000_000)
    var jd = jittered_deadline_ns(nominal, OP_ID_ALLOC_BASE + Int64(3), band)
    assert_true(jd >= nominal)
    assert_true(jd < nominal + band)
    # Spread: adjacent biased-monotone op_ids do NOT all collide. Count distinct
    # offsets over a window of 32 adjacent op_ids; a non-mixing impl (raw % band)
    # would still spread, but we assert a meaningful spread to catch a constant.
    var distinct = 0
    var seen = List[Int64]()
    for k in range(32):
        var j = op_id_jitter_ns(OP_ID_ALLOC_BASE + Int64(k + 1), band)
        var found = False
        for s in range(len(seen)):
            if seen[s] == j:
                found = True
                break
        if not found:
            seen.append(j)
            distinct += 1
    # Expect near-32 distinct offsets across a 250ms band; allow a generous floor.
    assert_true(
        distinct >= 24,
        String("jitter does not spread: only ") + String(distinct)
        + " distinct offsets over 32 op_ids",
    )


# =============================================================================
# Guard 5 — herd re-acquire-failure -> handled re-park-with-jitter.
# =============================================================================
# A bounded mock pool whose checkout RAISES on exhaustion (mirrors Pool[T] /
# PgPool.checkout). The herd test: pool capacity C < herd size H; the first C
# frames win a lease, the remaining H-C frames hit exhaustion and MUST re-park
# with jitter via the handled arm rather than throwing.


struct _BoundedPool(Movable, Deinitable):
    var _capacity: Int
    var _in_use: Int

    def __init__(out self, capacity: Int):
        self._capacity = capacity
        self._in_use = 0

    def checkout(mut self) raises -> Int:
        if self._in_use >= self._capacity:
            raise Error("pool exhausted")
        var lease = self._in_use
        self._in_use += 1
        return lease


def test_herd_reacquire_failure_reparks_not_throws() raises:
    """A herd of H frames wakes in lockstep and re-acquires from a pool of
    capacity C < H. The first C succeed (OK); the rest hit exhaustion and the
    handled arm re-parks them with jitter (BACKPRESSURE) — NO uncaught throw
    propagates through the resume path."""
    comptime C = 4
    comptime H = 16
    var reactor = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    var pool = ArcPointer[_BoundedPool](_BoundedPool(C))

    var ok_count = 0
    var backpressure_count = 0
    var retry_op_ids = List[Int64]()

    for h in range(H):
        var frame_salt = OP_ID_ALLOC_BASE + Int64(h + 1)
        # The resume path: try to re-acquire; on exhaustion, the HANDLED arm
        # re-parks with jitter instead of letting the raise escape.
        var outcome: ReacquireOutcome
        try:
            var lease = pool[].checkout()
            outcome = ReacquireOutcome.ok(lease)
        except:
            # Pool exhausted — graceful backpressure: re-park with jitter.
            outcome = backpressure_repark[NoopSink](
                reactor,
                Int64(1_000_000),  # nominal idle deadline
                frame_salt,
                DEFAULT_JITTER_BAND_NS,
            )
        if outcome.is_ok():
            ok_count += 1
            assert_true(outcome.lease >= 0)
        else:
            assert_equal(outcome.status, REACQUIRE_BACKPRESSURE)
            assert_true(outcome.is_backpressure())
            # The frame is re-parked on a fresh biased op_id (a real reactor
            # timer registration). It is findable in the demux.
            assert_true(outcome.retry_op_id >= OP_ID_ALLOC_BASE)
            assert_true(reactor.probe_find_slot_idx(outcome.retry_op_id) >= 0)
            retry_op_ids.append(outcome.retry_op_id)
            backpressure_count += 1

    # Exactly C frames got a lease; the rest re-parked gracefully — none threw.
    assert_equal(ok_count, C)
    assert_equal(backpressure_count, H - C)
    # The backpressured frames' retry op_ids are distinct (each a fresh timer).
    assert_equal(len(retry_op_ids), H - C)
    for i in range(len(retry_op_ids)):
        for j in range(i + 1, len(retry_op_ids)):
            assert_true(retry_op_ids[i] != retry_op_ids[j])


def main() raises:
    test_map_lookup_is_sublinear()
    test_map_remove_swap_patch()
    test_parked_morsel_slab_scaling()
    test_parked_morsel_slab_interleaved()
    test_reactor_demux_scaling()
    test_jitter_deterministic_and_in_band()
    test_herd_reacquire_failure_reparks_not_throws()
    print("test_parked_frame_demux_scaling: ALL PASS")
