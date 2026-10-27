# =============================================================================
# test_hash_chain_parallel_build_settings -- the settings of the parallel
# chained-hash build decide which build serves a join and who fills the
# chain-head table, and every combination gives the serial build's answer
# =============================================================================
#
# What each test catches:
#   * `test_build_mode_eligibility`: AUTO takes the parallel build exactly at
#     `JOIN_BUILD_PARALLEL_THRESHOLD` rows; OFF never takes it; FORCE takes it
#     at one row; an empty build never does. (Making `chain_build_parallel_
#     eligible` that ignored OFF would fail it.)
#   * `test_fill_fan_eligibility`: the fanned fill needs the setting on, two
#     workers and a 4 MiB table (FORCE bypasses only the size floor).
#   * `test_forced_parallel_build_matches_serial`: under FORCE, with a 16-slot
#     fill grain so the fill wave tiles a fixture-sized table into many
#     morsels, the parallel build FIRES, spans between one worker and the pool, and
#     answers every probe exactly as the serial build does, for the fanned
#     fill and for the driver's fill alike.
#   * `test_off_takes_the_serial_build`: OFF leaves the fire counter at zero.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.primitive_array import PrimitiveArray
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async_api.token import CancellationToken

from komira_op_join_build.hash_chain_build_settings import (
    JOIN_BUILD_PARALLEL_THRESHOLD,
    JOIN_PARALLEL_BUILD_AUTO,
    JOIN_PARALLEL_BUILD_FORCE,
    JOIN_PARALLEL_BUILD_OFF,
    ht_fill_morsel_slots,
    join_ht_fill_configure,
    join_parallel_build_configure,
    reset_hash_chain_build_settings,
)
from komira_op_join_build.hash_chain_parallel_build import (
    chain_build_parallel_eligible,
    hash_join_build_parallel,
    ht_fill_fan_eligible,
)
from komira_op_join_build.join import HashJoinBuilder
from komira_op_join_build.join_parallel_build_counter import (
    join_parallel_build_fire_count,
    join_parallel_build_worker_span,
    reset_join_parallel_build,
)


comptime _POOL_WORKERS = 4


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _keys(n: Int, stride: Int) -> PrimitiveArray[DType.int64]:
    var arr = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        arr.store[1](i, SIMD[DType.int64, 1](Int64(i * stride)))
    return arr^


def _parallel(n: Int) raises -> HashJoinBuilder:
    var ct = CancellationToken.new()
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=_POOL_WORKERS,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = runtime.dispatcher()
    return hash_join_build_parallel(disp, ct^, _keys(n, 3))


def _assert_same_answer(
    ser: HashJoinBuilder, par: HashJoinBuilder, what: String
) raises:
    # Probe keys 0..3n-1 hit every third value: unique build keys, so each
    # probe row has at most one match and the order is fixed by probe order.
    var probe = _keys(3 * ser.num_build + 7, 1)
    var s = ser.probe_inner(probe)
    var p = par.probe_inner(probe)
    assert_equal(len(s[0]), len(p[0]), what + ": INNER pair count")
    assert_equal(len(s[0]), ser.num_build, what + ": every build row matches")
    for i in range(len(s[0])):
        assert_equal(s[0][i], p[0][i], what + ": build row " + String(i))
        assert_equal(s[1][i], p[1][i], what + ": probe row " + String(i))
    assert_equal(
        ser.probe_anti_count(probe), par.probe_anti_count(probe), what + ": ANTI"
    )


def test_build_mode_eligibility() raises:
    reset_hash_chain_build_settings()
    assert_false(chain_build_parallel_eligible(0))
    assert_false(chain_build_parallel_eligible(JOIN_BUILD_PARALLEL_THRESHOLD - 1))
    assert_true(chain_build_parallel_eligible(JOIN_BUILD_PARALLEL_THRESHOLD))
    join_parallel_build_configure(JOIN_PARALLEL_BUILD_OFF)
    assert_false(
        chain_build_parallel_eligible(10 * JOIN_BUILD_PARALLEL_THRESHOLD),
        "OFF never takes the parallel build",
    )
    join_parallel_build_configure(JOIN_PARALLEL_BUILD_FORCE)
    assert_true(chain_build_parallel_eligible(1), "FORCE at one row")
    assert_false(chain_build_parallel_eligible(0), "never for an empty build")
    join_parallel_build_configure(JOIN_PARALLEL_BUILD_AUTO)
    assert_false(chain_build_parallel_eligible(1))
    var raised = False
    try:
        join_parallel_build_configure(7)
    except:
        raised = True
    assert_true(raised, "an unknown mode is refused")
    reset_hash_chain_build_settings()


def test_fill_fan_eligibility() raises:
    reset_hash_chain_build_settings()
    comptime FOUR_MIB_SLOTS = 4 * 1024 * 1024 // 8
    assert_true(ht_fill_fan_eligible(FOUR_MIB_SLOTS, 4, False))
    assert_false(ht_fill_fan_eligible(FOUR_MIB_SLOTS - 1, 4, False), "the floor")
    assert_true(ht_fill_fan_eligible(16, 4, True), "FORCE bypasses the floor")
    assert_false(ht_fill_fan_eligible(FOUR_MIB_SLOTS, 1, True), "one worker")
    join_ht_fill_configure(False)
    assert_false(ht_fill_fan_eligible(FOUR_MIB_SLOTS, 4, True), "the driver fill")
    join_ht_fill_configure(True, 16)
    assert_equal(ht_fill_morsel_slots(), 16)
    reset_hash_chain_build_settings()
    assert_equal(ht_fill_morsel_slots(), 16_384)


def test_forced_parallel_build_matches_serial() raises:
    var n = 3000  # cap 8192: 512 fill morsels at a 16-slot grain
    var ser = HashJoinBuilder.build(_keys(n, 3), build_bloom=False)
    for fanned in range(2):
        reset_hash_chain_build_settings()
        join_parallel_build_configure(JOIN_PARALLEL_BUILD_FORCE)
        join_ht_fill_configure(fanned == 1, 16)
        reset_join_parallel_build()
        var par = _parallel(n)
        var what = String("forced, fanned fill=") + String(fanned)
        assert_equal(join_parallel_build_fire_count(), 1, what + ": fired")
        # How many workers claim a morsel is the scheduler's choice (one
        # worker may drain a shared counter before another starts), so only
        # the bounds are fixed: at least one, at most the pool.
        assert_true(
            join_parallel_build_worker_span() >= 1, what + ": a worker ran"
        )
        assert_true(
            join_parallel_build_worker_span() <= _POOL_WORKERS,
            what + ": no more workers than the pool",
        )
        assert_false(par.uses_bloom(), what + ": the parallel build has no bloom")
        _assert_same_answer(ser, par, what)
    reset_hash_chain_build_settings()
    reset_join_parallel_build()


def test_off_takes_the_serial_build() raises:
    reset_hash_chain_build_settings()
    join_parallel_build_configure(JOIN_PARALLEL_BUILD_OFF)
    reset_join_parallel_build()
    var n = 3000
    var par = _parallel(n)
    assert_equal(join_parallel_build_fire_count(), 0, "OFF: the serial build")
    var ser = HashJoinBuilder.build(_keys(n, 3), build_bloom=False)
    _assert_same_answer(ser, par, String("off"))
    reset_hash_chain_build_settings()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
