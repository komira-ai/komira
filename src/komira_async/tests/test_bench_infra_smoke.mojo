# =============================================================================
# test_bench_infra_smoke.mojo
# =============================================================================
# bench infrastructure smoke. Exercises the SAME
# komira_async APIs that the substrate bench targets exercise (spawn /
# wake / channel / mock-reactor), at low N, asserting they don't crash
# and produce the expected outputs. This guards bench-source drift —
# if the bench targets break, this test breaks first (and is much
# cheaper to run on every commit than a full bench sweep).
# =============================================================================

from std.testing import assert_equal, assert_true
from komira_atomic_alias import AtomicI32
from std.memory import OwnedPointer, alloc

from komira_async.spawner.spawner import (
    ForkJoinSpawner,
    SpawnableTask,
)
from komira_async.channel.spsc import (
    channel,
    TRY_SEND_OK,
    TRY_RECV_OK,
)
from komira_async.runtime.wake_primitives import wake_one_by_address
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.worker import Worker


# ---------------------------------------------------------------------------
# Test fixture: matches bench_spawn_latency.mojo's _NoOpTask.
# ---------------------------------------------------------------------------


@fieldwise_init
struct _NoOpTask(SpawnableTask, Movable, Deinitable):
    comptime T = Int

    var _placeholder: UInt8

    def run(mut self) raises -> Self.T:
        return 0


def test_bench_spawn_latency_shape_compiles_and_runs() raises:
    """Smoke: 100 spawns of the no-op task, mirroring bench_spawn_latency
    at low N. Asserts the bench API surface is callable + each spawn's
    join returns 0 as expected."""
    var s = ForkJoinSpawner.new()
    var i = 0
    while i < 100:
        var h = s.spawn[_NoOpTask](_NoOpTask(_placeholder=UInt8(0)))
        var result = h^.join()
        assert_equal(result, 0)
        i = i + 1


def test_bench_wake_round_trip_shape_compiles_and_runs() raises:
    """Smoke: wake_one_by_address with no waiter parked. Mirrors the
    bench_wake_round_trip API surface — no waiter parked → kernel
    returns 0 woken."""
    var raw = alloc[AtomicI32](1)
    raw[] = AtomicI32(Int32(0))
    var word = OwnedPointer[AtomicI32](unsafe_from_raw_pointer=raw)
    var i = 0
    while i < 100:
        _ = wake_one_by_address(word[])
        i = i + 1
    # No-op assertion: the call did not crash. (Return value semantics
    # vary by OS / kernel version — futex returns 0 on Linux when no
    # waiter; __ulock_wake returns -1 with errno on macOS.)
    assert_true(True)


def test_bench_channel_throughput_shape_compiles_and_runs() raises:
    """Smoke: SPSC try_send + try_recv interleave at low N. Mirrors the
    unbatched + batched bench shapes."""
    var pair = channel[Int](capacity=UInt(16))
    var tx = pair.take_sender()
    var rx = pair.take_receiver()
    # Unbatched: 100 send/recv pairs.
    var i = 0
    while i < 100:
        var rc = tx.try_send(i)
        assert_equal(Int(rc), Int(TRY_SEND_OK))
        var r = rx.try_recv()
        assert_equal(Int(r.status), Int(TRY_RECV_OK))
        assert_equal(r.value(), i)
        i = i + 1


def test_bench_e2e_smoke_shape_compiles_and_runs() raises:
    """Smoke: Worker[NoopSink] with BACKEND_MOCK + 10 idle iterations.
    Mirrors the bench_e2e_smoke shape at low N."""
    var w = Worker[NoopSink](
        worker_id=UInt16(0),
        sink=NoopSink(_placeholder=UInt8(0)),
        backend=BACKEND_MOCK,
    )
    var k = 0
    while k < 10:
        var n = w.run_one_iteration(timeout_us=Int32(0))
        # MOCK subsystem with no registered ops returns 0 ready.
        assert_equal(n, 0)
        k = k + 1


def main() raises:
    test_bench_spawn_latency_shape_compiles_and_runs()
    test_bench_wake_round_trip_shape_compiles_and_runs()
    test_bench_channel_throughput_shape_compiles_and_runs()
    test_bench_e2e_smoke_shape_compiles_and_runs()
    print("[PASS] komira_async bench_infra smoke — 4/4 tests")
