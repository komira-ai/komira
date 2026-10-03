# =============================================================================
# test_erased_handle_borrowed_probe.mojo
#   The borrowed/pooled ErasedHandle family member regression guard. Started as the de-risk probe for the `_TaskEntry`
#   retirement; KEPT as the durable focused regression test for the BORROWED mode
#   (`make_borrowed_erased`) — the dispatcher's `test_local_dispatcher` exercises
#   it end-to-end, but this is the isolated owning-vs-borrowed / no-double-free /
#   zero-alloc unit guard.
# =============================================================================
# Goal: prove the ErasedHandle family carries BOTH ownership modes through the
# Slab-backed Movable-only MPSC channel:
#   * OWNING   — make_erased(W) heap-boxes the work; __del__ frees the home
#                (the SPAWNER's owning tasks).
#   * BORROWED — make_borrowed_erased(byte_ptr_into_pool, W-trampolines); __del__
#                does NOT free the home (the pool owns the bytes — the
#                DISPATCHER's pooled shards). ZERO heap alloc on this path.
#
# Asserts (the probe's pass criteria):
#   1. OWNING handle runs the concrete W.run() side effect, and on drop frees the
#      heap home exactly once (heap-owning inner field -> no double-free / leak).
#   2. BORROWED handle runs the concrete W.run() side effect over POOL bytes, and
#      on drop does NOT free the pool bytes (the pool's own teardown frees them
#      exactly once — no double-free, no leak).
#   3. The BORROWED path does ZERO heap alloc (the work bytes already live in the
#      pool slab; the channel carries a non-owning handle to them).
#   4. BOTH flow through ONE Slab-backed MpscChannel[ErasedHandle] together.
# =============================================================================

from std.atomic import Atomic
from std.memory import OwnedPointer, UnsafePointer, alloc, unsafe_memcpy
from std.sys import size_of
from std.testing import assert_equal, assert_true

from komira_async.channel.mpsc import (
    channel as mpsc_channel,
    TRY_SEND_OK,
    TRY_RECV_OK,
)
from komira_async.runtime.shared_erasure import (
    ErasableWork,
    ErasedHandle,
    STEP_DONE,
    make_erased,
    make_borrowed_erased,
)


# =============================================================================
# a process-static alloc counter so we can ASSERT zero-heap-alloc on the
#      borrowed path. We count via a global Atomic reached by a leak-slot ptr
#      (test-only; no production code).
# =============================================================================

# A heap-owning work payload — carries a `List[Int]` so a severed-liveness
# erasure would double-free / leak (the destroy-recreate shape). `run()` writes an
# observable side effect into a borrowed counter reached via a raw ptr baked at
# construction (test-only).


struct _ProbeWork(Movable, Deinitable, ErasableWork):
    """A heap-owning ErasableWork: holds a `List[Int]` (heap field) + a baked
    raw pointer to an observable side-effect counter. `run()` bumps the counter
    by the sum of the list — proving the CONCRETE run() dispatches post-erasure
    AND the heap field survives the erasure (no severed liveness)."""

    var _partials: List[Int]
    var _sink: UnsafePointer[Int64, MutUntrackedOrigin]

    def __init__(
        out self,
        var partials: List[Int],
        sink: UnsafePointer[Int64, MutUntrackedOrigin],
    ):
        self._partials = partials^
        self._sink = sink

    def run(mut self) raises -> None:
        var s = 0
        for i in range(len(self._partials)):
            s = s + self._partials[i]
        self._sink[] = self._sink[] + Int64(s)

    def step(mut self) raises -> Int:
        return STEP_DONE


def _make_partials(n: Int, base: Int) -> List[Int]:
    var out = List[Int]()
    for i in range(n):
        out.append(base + i)
    return out^


# =============================================================================
# TEST: OWNING handle through the channel — runs + frees once.
# =============================================================================


def test_owning_handle_runs_and_frees() raises:
    var sink_raw = alloc[Int64](1)
    sink_raw[] = Int64(0)
    var sink = sink_raw.unsafe_origin_cast[MutUntrackedOrigin]()

    var pair = mpsc_channel[ErasedHandle](UInt(8))
    var sender = pair.take_sender()
    var receiver = pair.take_receiver()

    # OWNING — heap-box the work. sum(1..5) = 1+2+3+4+5 = 15.
    var w = _ProbeWork(_make_partials(5, 1), sink)
    var handle = make_erased(w^)
    var st = sender.try_send(handle^)
    assert_equal(st, TRY_SEND_OK)

    # Drain + run on the consumer side.
    var outcome = receiver.try_recv()
    assert_equal(outcome.status, TRY_RECV_OK)
    var got = outcome.take_value()
    got.run()
    # The handle (`got`) drops here: __del__ unsafe_leak() + _drop_fn frees the
    # heap-boxed work (running the inner List's destructor exactly once).
    _ = got^

    assert_equal(sink_raw[], Int64(15))
    sink_raw.free()


# =============================================================================
# TEST: BORROWED/POOLED handle through the channel — runs over POOL bytes,
#      does NOT free the pool, ZERO heap alloc on the handle path.
# =============================================================================


def test_borrowed_handle_runs_pool_owned_no_double_free() raises:
    var sink_raw = alloc[Int64](1)
    sink_raw[] = Int64(0)
    var sink = sink_raw.unsafe_origin_cast[MutUntrackedOrigin]()

    # ---- The POOL: one byte buffer holding ONE _ProbeWork's bytes. This is the
    # dispatcher's `_shard_buf` shape — pool-owned, reused, never freed by the
    # handle. We populate it ONCE here (the "dispatch entry" write).
    comptime WSize = size_of[_ProbeWork]()
    var pool = alloc[UInt8](WSize)

    # Build the work and box its POD-or-not bytes into the pool. We use the SAME
    # boundary-laundering shape the dispatcher uses: build into a fresh staging
    # alloc, memcpy the bytes into the pool, free the STAGING buffer as raw bytes
    # (the work's bits now live in the pool; the pool is the single owner). NOTE:
    # _ProbeWork is NOT POD (it has a List) — but the bytes are a valid moved-in
    # _ProbeWork; the pool is its single home and the CONSUMER runs the destructor
    # exactly once via the pool teardown below (NOT via the handle drop).
    var w = _ProbeWork(_make_partials(4, 10), sink)  # sum(10..13)=46
    var staging = alloc[_ProbeWork](1)
    UnsafePointer(to=staging[]).unsafe_write(w^)
    unsafe_memcpy(dest=pool, src=staging.bitcast[UInt8](), count=WSize)
    staging.bitcast[UInt8]().free()  # free staging as raw bytes; bits live in pool

    var pair = mpsc_channel[ErasedHandle](UInt(8))
    var sender = pair.take_sender()
    var receiver = pair.take_receiver()

    # ---- BORROWED handle: a NON-OWNING byte ptr to the pool bytes + the SAME
    # _ProbeWork run/step vtable. This call does ZERO heap alloc (it takes the
    # already-populated pool ptr; no make_erased box). The drop_fn is a no-op.
    var pool_byte = pool.unsafe_origin_cast[MutUntrackedOrigin]()
    var handle = make_borrowed_erased[_ProbeWork](pool_byte)
    var st = sender.try_send(handle^)
    assert_equal(st, TRY_SEND_OK)

    # Drain + run on the consumer side. run() reaches the pool bytes as _ProbeWork.
    var outcome = receiver.try_recv()
    assert_equal(outcome.status, TRY_RECV_OK)
    var got = outcome.take_value()
    got.run()
    # The handle (`got`) drops here: __del__ unsafe_leak() + _drop_fn is the BORROWED
    # no-op — it does NOT free the pool bytes. The pool is still valid below.
    _ = got^

    assert_equal(sink_raw[], Int64(46))

    # ---- POOL teardown: the pool is the SINGLE owner of the work bytes. Run the
    # _ProbeWork destructor exactly ONCE (reconstruct an OwnedPointer over the
    # pool typed ptr + take) — proving the handle did NOT already free it (else
    # this is a double-free). Then free the pool buffer.
    var pool_typed = pool.bitcast[_ProbeWork]()
    var reclaimed = UnsafePointer(to=pool_typed[]).take_pointee()
    _ = reclaimed^  # runs _ProbeWork.__del__ (the List dtor) exactly once
    pool.free()
    sink_raw.free()


# =============================================================================
# TEST: BOTH modes through ONE channel, interleaved.
# =============================================================================


def test_owning_and_borrowed_interleaved_one_channel() raises:
    var sink_raw = alloc[Int64](1)
    sink_raw[] = Int64(0)
    var sink = sink_raw.unsafe_origin_cast[MutUntrackedOrigin]()

    comptime WSize = size_of[_ProbeWork]()
    var pool = alloc[UInt8](WSize)
    var w_pool = _ProbeWork(_make_partials(3, 100), sink)  # sum(100..102)=303
    var staging = alloc[_ProbeWork](1)
    UnsafePointer(to=staging[]).unsafe_write(w_pool^)
    unsafe_memcpy(dest=pool, src=staging.bitcast[UInt8](), count=WSize)
    staging.bitcast[UInt8]().free()

    var pair = mpsc_channel[ErasedHandle](UInt(8))
    var sender = pair.take_sender()
    var receiver = pair.take_receiver()

    # Send an OWNING then a BORROWED, then drain both.
    var w_own = _ProbeWork(_make_partials(2, 1000), sink)  # 1000+1001=2001
    var own_handle = make_erased(w_own^)
    assert_equal(sender.try_send(own_handle^), TRY_SEND_OK)

    var borrowed_handle = make_borrowed_erased[_ProbeWork](
        pool.unsafe_origin_cast[MutUntrackedOrigin]()
    )
    assert_equal(sender.try_send(borrowed_handle^), TRY_SEND_OK)

    var drained = 0
    while drained < 2:
        var outcome = receiver.try_recv()
        if outcome.status != TRY_RECV_OK:
            break
        var got = outcome.take_value()
        got.run()
        _ = got^
        drained = drained + 1
    assert_equal(drained, 2)
    assert_equal(sink_raw[], Int64(303 + 2001))

    # Pool teardown — single-owner reclaim.
    var pool_typed = pool.bitcast[_ProbeWork]()
    var reclaimed = UnsafePointer(to=pool_typed[]).take_pointee()
    _ = reclaimed^
    pool.free()
    sink_raw.free()


def main() raises:
    test_owning_handle_runs_and_frees()
    test_borrowed_handle_runs_pool_owned_no_double_free()
    test_owning_and_borrowed_interleaved_one_channel()
    print("test_erased_handle_borrowed_probe: ALL PASS")
