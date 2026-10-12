# =============================================================================
# The parallel INNER probes against the serial ones they fork.
#
# Each test runs a probe big enough for several morsels on a 4-worker pool
# (the grain is at most 16,384 rows) and checks the pairs exactly: every pair
# joins equal keys, each probe row gets exactly the build rows the serial
# probe gives it, and the fork really happened (the grain recorder saw more
# than one morsel). A pair dropped, duplicated or mismatched by a worker, a
# merge that loses a worker's list, or a layout arm that reads the wrong
# array turns one of these red.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.primitive_array import PrimitiveArray
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async.runtime.sched_trace import SITE_JOIN_PROBE
from komira_async_api.token import CancellationToken
from komira_engine_runtime.grain_geometry import (
    GRAIN_F_MORSELS,
    grain_geometry_calls,
    grain_geometry_field,
    grain_geometry_reset,
)
from komira_op_join_build.join import HashJoinBuilder
from komira_op_join_build.join_layout_counter import (
    join_layout_probe_fused_count,
    join_layout_probe_nobi_count,
)
from komira_op_join_build.join_perfect_hash import PerfectHashJoin
from komira_op_join_build.join_probe_null_mask import ProbeNullMask

from komira_op_fused_kernels.parallel_gate import (
    PARALLEL_THRESHOLD_ROWS,
    should_parallelize,
)
from komira_op_fused_kernels.parallel_inner_probe import (
    parallel_inner_join_probe_into,
    parallel_perfect_inner_probe_into,
)


comptime _POOL_WORKERS = 4


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _runtime() raises -> PerCoreAsyncRuntime[NoopSink]:
    return PerCoreAsyncRuntime[NoopSink](
        num_workers=_POOL_WORKERS,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )


def _keys_mod(n: Int, modulus: Int) -> PrimitiveArray[DType.int64]:
    """Keys `i % modulus` for `i` in `[0, n)`."""
    var arr = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        arr.store[1](i, SIMD[DType.int64, 1](Int64(i % modulus)))
    return arr^


def _expected_per_probe_row(
    build: PrimitiveArray[DType.int64], probe: PrimitiveArray[DType.int64]
) raises -> Tuple[List[Int], List[Int]]:
    """Per probe row: the number of build rows with an equal key, and the sum
    of those build rows' indices (NULL probe keys match nothing)."""
    var key_cnt = Dict[Int, Int]()
    var key_sum = Dict[Int, Int]()
    for b in range(build.length):
        var k = Int(build.get(b))
        key_cnt[k] = key_cnt.get(k, 0) + 1
        key_sum[k] = key_sum.get(k, 0) + b
    var cnt = List[Int](length=probe.length, fill=0)
    var sum = List[Int](length=probe.length, fill=0)
    for p in range(probe.length):
        if probe.is_null(p):
            continue
        var k = Int(probe.get(p))
        cnt[p] = key_cnt.get(k, 0)
        sum[p] = key_sum.get(k, 0)
    return (cnt^, sum^)


def _assert_pairs(
    build: PrimitiveArray[DType.int64],
    probe: PrimitiveArray[DType.int64],
    build_rows: List[Int],
    probe_rows: List[Int],
) raises:
    assert_equal(len(build_rows), len(probe_rows))
    var exp = _expected_per_probe_row(build, probe)
    var cnt = List[Int](length=probe.length, fill=0)
    var sum = List[Int](length=probe.length, fill=0)
    var total = 0
    for i in range(len(build_rows)):
        var b = build_rows[i]
        var p = probe_rows[i]
        assert_false(probe.is_null(p), "a NULL probe key matched")
        assert_equal(build.get(b), probe.get(p), "pair joins unequal keys")
        cnt[p] += 1
        sum[p] += b
    for p in range(probe.length):
        assert_equal(cnt[p], exp[0][p], "match count of probe row " + String(p))
        assert_equal(sum[p], exp[1][p], "build rows of probe row " + String(p))
        total += exp[0][p]
    assert_equal(len(build_rows), total)


def _assert_forked(calls_before: Int) raises:
    assert_equal(grain_geometry_calls(SITE_JOIN_PROBE), calls_before + 1)
    assert_true(
        grain_geometry_field(SITE_JOIN_PROBE, GRAIN_F_MORSELS) > 1,
        "the probe did not fork into more than one morsel",
    )


def _run_chained(nobi: Bool, fused: Bool, build_bloom: Bool) raises:
    # 40 build rows over 8 keys (5 rows per key), 60,000 probe rows over 10
    # keys: keys 8 and 9 match nothing, the rest match 5 build rows each.
    var build = _keys_mod(40, 8)
    var probe = _keys_mod(60_000, 10)
    var jb = HashJoinBuilder.build(
        build, build_bloom=build_bloom, nobi=nobi, fused=fused
    )
    assert_equal(jb._bi_elided, nobi)
    assert_equal(jb._fused, fused)
    var nobi_before = join_layout_probe_nobi_count()
    var fused_before = join_layout_probe_fused_count()
    var calls = grain_geometry_calls(SITE_JOIN_PROBE)
    var rt = _runtime()
    ref disp = rt.dispatcher()
    var bm = List[Int]()
    var pm = List[Int]()
    parallel_inner_join_probe_into(
        disp, CancellationToken.new(), jb, probe, probe.length, bm, pm,
        ProbeNullMask(probe, probe.length),
    )
    _assert_forked(calls)
    _assert_pairs(build, probe, bm, pm)
    # The arm taken is the builder's layout.
    assert_equal(join_layout_probe_nobi_count() - nobi_before, Int(nobi))
    assert_equal(join_layout_probe_fused_count() - fused_before, Int(fused))


def test_chained_probe_split_layout() raises:
    _run_chained(False, False, True)


def test_chained_probe_nobi_layout() raises:
    _run_chained(True, False, True)


def test_chained_probe_fused_layout() raises:
    _run_chained(False, True, True)


def test_chained_probe_fused_nobi_layout() raises:
    _run_chained(True, True, True)


def test_chained_probe_builder_without_bloom() raises:
    """A builder built without a bloom filter carries a placeholder over a
    NULL buffer; the probe must not consult it."""
    _run_chained(True, True, False)


def test_chained_probe_appends_after_existing_pairs() raises:
    """The pairs are appended: what the caller's lists held stays first."""
    var build = _keys_mod(16, 16)
    var probe = _keys_mod(40_000, 16)
    var jb = HashJoinBuilder.build(build)
    var rt = _runtime()
    ref disp = rt.dispatcher()
    var bm: List[Int] = [-7]
    var pm: List[Int] = [-9]
    parallel_inner_join_probe_into(
        disp, CancellationToken.new(), jb, probe, probe.length, bm, pm,
        ProbeNullMask(probe, probe.length),
    )
    assert_equal(len(bm), 40_001)
    assert_equal(bm[0], -7)
    assert_equal(pm[0], -9)
    var tail_b = List[Int]()
    var tail_p = List[Int]()
    for i in range(1, len(bm)):
        tail_b.append(bm[i])
        tail_p.append(pm[i])
    _assert_pairs(build, probe, tail_b, tail_p)


def _nullable_probe(n: Int, modulus: Int, null_every: Int) -> PrimitiveArray[DType.int64]:
    """Keys `i % modulus`, with every `null_every`-th row NULL. A NULL row's
    value is 0, which is a real build key: matching it would be visible."""
    var arr = PrimitiveArray[DType.int64].allocate_nullable(n)
    for i in range(n):
        if i % null_every == 0:
            arr.store[1](i, SIMD[DType.int64, 1](0))
            arr._set_null(i)
        else:
            arr.store[1](i, SIMD[DType.int64, 1](Int64(i % modulus)))
    return arr^


def test_chained_probe_null_keys_match_nothing() raises:
    var build = _keys_mod(8, 8)  # keys 0..7, one row each
    var probe = _nullable_probe(50_000, 8, 3)
    assert_true(probe.null_count > 0)
    var jb = HashJoinBuilder.build(build)
    var calls = grain_geometry_calls(SITE_JOIN_PROBE)
    var rt = _runtime()
    ref disp = rt.dispatcher()
    var bm = List[Int]()
    var pm = List[Int]()
    parallel_inner_join_probe_into(
        disp, CancellationToken.new(), jb, probe, probe.length, bm, pm,
        ProbeNullMask(probe, probe.length),
    )
    _assert_forked(calls)
    _assert_pairs(build, probe, bm, pm)


def test_perfect_probe_matches_serial() raises:
    # Dense unique build keys 0..999; probe keys 0..1199, so 200 of every
    # 1200 probe rows fall outside the table's range.
    var build = _keys_mod(1000, 1000)
    var probe = _keys_mod(60_000, 1200)
    var opt = PerfectHashJoin.try_build(build)
    assert_true(Bool(opt))
    var perfect = opt.take()
    var calls = grain_geometry_calls(SITE_JOIN_PROBE)
    var rt = _runtime()
    ref disp = rt.dispatcher()
    var bm = List[Int]()
    var pm = List[Int]()
    parallel_perfect_inner_probe_into(
        disp, CancellationToken.new(), perfect, probe, probe.length, bm, pm,
        ProbeNullMask(probe, probe.length),
    )
    _assert_forked(calls)
    _assert_pairs(build, probe, bm, pm)


def test_perfect_probe_null_keys_match_nothing() raises:
    var build = _keys_mod(8, 8)
    var probe = _nullable_probe(50_000, 8, 4)
    var opt = PerfectHashJoin.try_build(build)
    assert_true(Bool(opt))
    var perfect = opt.take()
    var calls = grain_geometry_calls(SITE_JOIN_PROBE)
    var rt = _runtime()
    ref disp = rt.dispatcher()
    var bm = List[Int]()
    var pm = List[Int]()
    parallel_perfect_inner_probe_into(
        disp, CancellationToken.new(), perfect, probe, probe.length, bm, pm,
        ProbeNullMask(probe, probe.length),
    )
    _assert_forked(calls)
    _assert_pairs(build, probe, bm, pm)


def test_one_morsel_takes_the_serial_probe() raises:
    """At or below one grain the probes do not fork: the recorder sees one
    morsel and the pairs are the serial probe's, NULL keys excluded by the
    column's own validity."""
    var build = _keys_mod(8, 8)
    var probe = _nullable_probe(5_000, 8, 5)
    var jb = HashJoinBuilder.build(build)
    var rt = _runtime()
    ref disp = rt.dispatcher()
    var bm = List[Int]()
    var pm = List[Int]()
    var calls = grain_geometry_calls(SITE_JOIN_PROBE)
    parallel_inner_join_probe_into(
        disp, CancellationToken.new(), jb, probe, probe.length, bm, pm,
        ProbeNullMask(probe, probe.length),
    )
    assert_equal(grain_geometry_calls(SITE_JOIN_PROBE), calls + 1)
    assert_equal(grain_geometry_field(SITE_JOIN_PROBE, GRAIN_F_MORSELS), 1)
    _assert_pairs(build, probe, bm, pm)

    var opt = PerfectHashJoin.try_build(build)
    var perfect = opt.take()
    var bm2 = List[Int]()
    var pm2 = List[Int]()
    parallel_perfect_inner_probe_into(
        disp, CancellationToken.new(), perfect, probe, probe.length, bm2, pm2,
        ProbeNullMask(probe, probe.length),
    )
    assert_equal(grain_geometry_field(SITE_JOIN_PROBE, GRAIN_F_MORSELS), 1)
    _assert_pairs(build, probe, bm2, pm2)


def test_should_parallelize_threshold() raises:
    from std.sys import num_physical_cores

    assert_false(should_parallelize(0))
    assert_false(should_parallelize(PARALLEL_THRESHOLD_ROWS - 1))
    var multi = num_physical_cores() > 1
    assert_equal(should_parallelize(PARALLEL_THRESHOLD_ROWS), multi)
    assert_equal(should_parallelize(10 * PARALLEL_THRESHOLD_ROWS), multi)


def main() raises:
    grain_geometry_reset()
    TestSuite.discover_tests[__functions_in_module()]().run()
