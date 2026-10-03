# =============================================================================
# test_spill_prefetch_producer.mojo
# =============================================================================
# IO-lane prefetch-offload (compute/IO hyperthread split) —
# the PRODUCER side: `SpillPrefetcher` + `SpillPrefetchWork` +
# `LocalDispatcher.make_spill_prefetcher`.
#
# The prefetch offload steers BLOCKING spill-restore reads to a sibling-HT
# IO worker so they
# warm the OS page cache AHEAD of the compute fold. These tests pin the producer
# CONTRACT deterministically (no running worker — the post lands in a real MPSC
# the test drains, and the work is run synchronously):
#
#   * INACTIVE (no IO lane): `is_active()` False -> `prefetch_chunk` returns
#     False and posts NOTHING. This is the no-IO-lane / non-SMT default — the
#     guarantee that the producer is a no-op there.
#   * ACTIVE (1 IO sender): `prefetch_chunk` posts ONE `SpillPrefetchWork` to the
#     IO MPSC; the test drains it and runs it (page-cache prime of a temp file),
#     asserting the post + the work run without error.
#   * ROUND-ROBIN (2 IO senders): N posts spread across both queues.
#   * DISPATCHER FACTORY FIREWALL: `make_spill_prefetcher()` off a 4-compute +
#     2-IO runtime yields an ACTIVE prefetcher with io_lane_count()==2 while the
#     dispatcher's `worker_count()` stays 4 (compute-only) — the IO senders are
#     a SEPARATE slab, never the fork-join shard set.
#   * NO-IO-LANE FACTORY: `make_spill_prefetcher()` off a compute-only runtime
#     yields an INACTIVE prefetcher (the default-path guard).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_runtime_paths import test_tmpdir
from komira_async.channel.mpsc import channel as mpsc_channel
from komira_async.channel.spsc import TRY_RECV_OK
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import (
    PLACEMENT_FIXED,
    PerCoreAsyncRuntime,
)
from komira_async.runtime.shared_erasure import ErasedHandle
from komira_async.runtime.spill_prefetch import (
    SpillPrefetcher,
    SpillPrefetchWork,
)
from komira_async.runtime.wake_primitives import WorkerWakeHandle


# ---------------------------------------------------------------------------
# ⚠ $TEST_TMPDIR, NOT A HARD-CODED `/tmp` PATH.
#
# A fixed `/tmp` path is shared by every concurrent execution of this test on
# one worker; the runner's private `TEST_TMPDIR` (read through
# `komira_runtime_paths.test_tmpdir`) keeps them disjoint.
# ---------------------------------------------------------------------------
def _scratch_dir() raises -> String:
    """The directory THIS execution may write scratch files into."""
    return test_tmpdir()


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


comptime _Q_CAP: UInt = 16


# -----------------------------------------------------------------------------
# INACTIVE prefetcher — the flag-off / non-SMT default (posts nothing)
# -----------------------------------------------------------------------------


def test_inactive_prefetcher_posts_nothing() raises:
    """An EMPTY `SpillPrefetcher` (no IO lane) is the flag-off / non-SMT default:
    `is_active()` is False, `io_lane_count()` is 0, and `prefetch_chunk` returns
    False (posts nothing). This is the byte-identical-to-today guarantee — the
    spill restore's `_prefetch_run` no-ops on an inactive prefetcher."""
    var pf = SpillPrefetcher()
    assert_false(pf.is_active())
    assert_equal(pf.io_lane_count(), 0)
    # Posting on an inactive prefetcher returns False (nothing posted).
    assert_false(pf.prefetch_chunk((_scratch_dir() + String("/does_not_matter.bin")), 0))


# -----------------------------------------------------------------------------
# ACTIVE prefetcher — one IO sender; post + drain + run
# -----------------------------------------------------------------------------


def test_active_prefetcher_posts_one_to_io_queue() raises:
    """With ONE IO sender wired, `prefetch_chunk` posts exactly ONE
    `SpillPrefetchWork` handle into the IO MPSC. The test drains the receiver
    and runs the handle (a page-cache prime of a real temp file) to prove the
    posted work is the prefetch payload and runs without error."""
    # Write a small temp file the prefetch will warm.
    var path = (_scratch_dir() + String("/spill_prefetch_test_active.bin"))
    with open(path, "w") as f:
        f.write(String("hello-prefetch-payload"))

    var pair = mpsc_channel[ErasedHandle](_Q_CAP)
    var receiver = pair.take_receiver()
    var sender = pair.take_sender()

    var pf = SpillPrefetcher()
    # `add_io_sender` takes the sender AND its wake handle in ONE
    # call — that is what keeps the two slabs index-parallel by
    # construction. No worker exists here, so a disconnected handle (whose
    # dummy sleeping-arc always reads awake -> wake always elided) is the
    # correct stand-in.
    pf.add_io_sender(sender^, WorkerWakeHandle.make_disconnected(-1, 0))
    assert_true(pf.is_active())
    assert_equal(pf.io_lane_count(), 1)
    assert_equal(pf.wake_handle_count(), 1)

    # Post one prefetch — must be accepted by the (empty) IO queue.
    var posted = pf.prefetch_chunk(path, 22)
    assert_true(posted)

    # Drain the IO queue: exactly ONE handle landed. Run it (the page-cache
    # prime) — must not raise. The drained handle's __del__ frees its path copy.
    var outcome = receiver.try_recv()
    assert_equal(Int(outcome.status), Int(TRY_RECV_OK))
    var handle = outcome.take_value()
    handle.run()
    _ = handle^

    # Queue is now empty (only one was posted).
    var outcome2 = receiver.try_recv()
    assert_true(Int(outcome2.status) != Int(TRY_RECV_OK))


def test_spill_prefetch_work_runs_on_missing_file_is_benign() raises:
    """`SpillPrefetchWork.run()` on a NONEXISTENT path is benign — the page-cache
    prime swallows the open failure (the compute thread's own read covers
    correctness). This guards the fire-and-forget contract: a stale / released
    chunk path never raises out of the IO worker."""
    var work = SpillPrefetchWork(
        (_scratch_dir() + String("/no_such_spill_chunk_xyz.bin")), 4096
    )
    # Runs without raising even though the file does not exist.
    work.run()


# -----------------------------------------------------------------------------
# ROUND-ROBIN — two IO senders spread the posts
# -----------------------------------------------------------------------------


def test_round_robin_spreads_across_two_io_senders() raises:
    """With TWO IO senders, consecutive `prefetch_chunk` posts spread across the
    two queues (round-robin). Four posts -> two per queue. Drains both to prove
    the spread (no single queue gets all the load)."""
    var pair0 = mpsc_channel[ErasedHandle](_Q_CAP)
    var recv0 = pair0.take_receiver()
    var send0 = pair0.take_sender()
    var pair1 = mpsc_channel[ErasedHandle](_Q_CAP)
    var recv1 = pair1.take_receiver()
    var send1 = pair1.take_sender()

    var pf = SpillPrefetcher()
    pf.add_io_sender(send0^, WorkerWakeHandle.make_disconnected(-1, 0))
    pf.add_io_sender(send1^, WorkerWakeHandle.make_disconnected(-1, 1))
    assert_equal(pf.io_lane_count(), 2)
    assert_equal(pf.wake_handle_count(), 2)

    var path = (_scratch_dir() + String("/spill_prefetch_test_rr.bin"))
    var i = 0
    while i < 4:
        assert_true(pf.prefetch_chunk(path, 0))
        i += 1

    # Each queue got 2 (round-robin). Drain + count both.
    var n0 = 0
    while True:
        var o = recv0.try_recv()
        if Int(o.status) != Int(TRY_RECV_OK):
            break
        var h = o.take_value()
        _ = h^
        n0 += 1
    var n1 = 0
    while True:
        var o = recv1.try_recv()
        if Int(o.status) != Int(TRY_RECV_OK):
            break
        var h = o.take_value()
        _ = h^
        n1 += 1
    assert_equal(n0, 2)
    assert_equal(n1, 2)
    assert_equal(n0 + n1, 4)


# -----------------------------------------------------------------------------
# DISPATCHER FACTORY — make_spill_prefetcher + the firewall
# -----------------------------------------------------------------------------


def test_dispatcher_factory_active_with_io_lane_firewall() raises:
    """`make_spill_prefetcher()` off a 4-compute + 2-IO runtime yields an ACTIVE
    prefetcher with io_lane_count()==2, WHILE the dispatcher's `worker_count()`
    stays 4 (compute-only). This is the firewall: the IO senders the prefetcher
    clones come from the dispatcher's SEPARATE `_io_senders` slab, never the
    fork-join `_worker_senders` shard set."""
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(4, _noop_sink_factory, BACKEND_MOCK)
    rt.attach_io_workers(2, _noop_sink_factory, BACKEND_MOCK)
    # Compute shard count stays 4; IO lane is 2.
    assert_equal(rt.worker_count(), 4)
    assert_equal(rt.io_worker_count(), 2)
    ref disp = rt.dispatcher()
    # The dispatcher's fork-join shard count is compute-only (4); its IO lane
    # registration is separate (2).
    assert_equal(disp.worker_count(), 4)
    assert_equal(disp.io_lane_count(), 2)
    assert_true(disp.io_lane_active())
    var pf = disp.make_spill_prefetcher()
    assert_true(pf.is_active())
    assert_equal(pf.io_lane_count(), 2)
    _ = pf^


def test_dispatcher_factory_inactive_without_io_lane() raises:
    """`make_spill_prefetcher()` off a COMPUTE-ONLY runtime (no IO lane attached)
    yields an INACTIVE prefetcher. This is the default-path guard: with the flag
    off / on a non-SMT box, the engine attaches no IO lane, so the dispatcher's
    `_io_senders` is empty and the spill producer no-ops."""
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(4, _noop_sink_factory, BACKEND_MOCK)
    ref disp = rt.dispatcher()
    assert_equal(disp.worker_count(), 4)
    assert_equal(disp.io_lane_count(), 0)
    assert_false(disp.io_lane_active())
    var pf = disp.make_spill_prefetcher()
    assert_false(pf.is_active())
    assert_equal(pf.io_lane_count(), 0)
    _ = pf^


def main() raises:
    test_inactive_prefetcher_posts_nothing()
    test_active_prefetcher_posts_one_to_io_queue()
    test_spill_prefetch_work_runs_on_missing_file_is_benign()
    test_round_robin_spreads_across_two_io_senders()
    test_dispatcher_factory_active_with_io_lane_firewall()
    test_dispatcher_factory_inactive_without_io_lane()
    print("PASS komira_async.runtime spill-prefetch producer (IO lane)")
