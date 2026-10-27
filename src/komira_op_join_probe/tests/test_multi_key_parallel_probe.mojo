# The parallel composite INNER probe against the serial probe: the same pairs,
# the same pairs on every run, an empty probe, and a skewed build (one key on a
# 200-row chain) that drives each worker's output cursor through its growth
# path without desynchronising the paired lists.

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.arrow_types import ArrowType
from komira_collections.slab import Slab

from komira_async_api.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime

from komira_op_join_probe.join_multi_key import (
    MultiKeyColumns,
)
from komira_op_join_probe.join_key_extract import (
    extract_join_key_columns_serial,
)
from komira_op_join_probe.join_multi_key_builder import (
    MultiKeyHashJoinBuilder,
)
from komira_op_join_probe.join_multi_key_parallel import (
    parallel_multi_key_inner_probe_into,
)


def _test_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _test_runtime() raises -> PerCoreAsyncRuntime[NoopSink]:
    """Construct a small mock runtime for parallel-probe dispatch."""
    return PerCoreAsyncRuntime[NoopSink](
        num_workers=4,
        sink_factory=_test_sink,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )


def _make_2col_int64(
    c0_name: String, c1_name: String,
    c0_vals: List[Int64], c1_vals: List[Int64],
) raises -> RecordBatch:
    """Build a 2-col INT64 batch from raw Int64 lists."""
    var n = len(c0_vals)
    var a0 = PrimitiveArray[DType.int64].allocate(n)
    var p0 = a0._typed_ptr_mut()
    for i in range(n):
        p0.store[width=1](i, c0_vals[i])
    var a1 = PrimitiveArray[DType.int64].allocate(n)
    var p1 = a1._typed_ptr_mut()
    for i in range(n):
        p1.store[width=1](i, c1_vals[i])

    var sb = SchemaBuilder()
    sb.add_field(Field(c0_name, ArrowType.INT64, False))
    sb.add_field(Field(c1_name, ArrowType.INT64, False))
    var schema = sb.build()
    var bldr = RecordBatchBuilder()
    bldr.add_column(Column.from_primitive(a0^))
    bldr.add_column(Column.from_primitive(a1^))
    return bldr.build(schema^)


def _build_synthetic_build(n_build: Int) raises -> RecordBatch:
    """Build the synthetic build-side 2-key INT64 batch."""
    var b_a = List[Int64](capacity=n_build)
    var b_b = List[Int64](capacity=n_build)
    for i in range(n_build):
        b_a.append(Int64(i // 8))
        b_b.append(Int64(i % 8))
    return _make_2col_int64("b_a", "b_b", b_a, b_b)


def _build_synthetic_probe(
    n_probe: Int, n_build: Int,
) raises -> RecordBatch:
    """Build the synthetic probe-side 2-key INT64 batch."""
    var p_a = List[Int64](capacity=n_probe)
    var p_b = List[Int64](capacity=n_probe)
    for i in range(n_probe):
        if i < n_build:
            p_a.append(Int64(i // 8))
            p_b.append(Int64(i % 8))
        else:
            p_a.append(Int64(-(i + 1)))
            p_b.append(Int64(-(i + 1)))
    return _make_2col_int64("p_a", "p_b", p_a, p_b)


def _sorted_pairs(
    build_matches: List[Int],
    probe_matches: List[Int],
) -> List[Tuple[Int, Int]]:
    """Pack (build, probe) pairs and sort lexicographically."""
    var n = len(build_matches)
    var pairs = List[Tuple[Int, Int]](capacity=n)
    for i in range(n):
        pairs.append((build_matches[i], probe_matches[i]))
    for i in range(1, n):
        var key = pairs[i]
        var j = i - 1
        while j >= 0:
            var cur = pairs[j]
            if cur[0] < key[0] or (cur[0] == key[0] and cur[1] <= key[1]):
                break
            pairs[j + 1] = cur
            j -= 1
        pairs[j + 1] = key
    return pairs^


def _assert_pairs_equal(
    a_b: List[Int], a_p: List[Int],
    b_b: List[Int], b_p: List[Int],
) raises:
    """Assert two parallel-output (build_matches, probe_matches) lists agree."""
    assert_equal(len(a_b), len(b_b))
    assert_equal(len(a_p), len(b_p))
    var sa = _sorted_pairs(a_b, a_p)
    var sb = _sorted_pairs(b_b, b_p)
    for i in range(len(sa)):
        assert_equal(sa[i][0], sb[i][0])
        assert_equal(sa[i][1], sb[i][1])


def test_parallel_2key_same_pairs_as_sequential_100k() raises:
    """Parallel multi-key inner probe must produce same matches as sequential."""
    var n = 100_000

    var build_batch_seq = _build_synthetic_build(n)
    var probe_batch_seq = _build_synthetic_probe(n, n)
    var build_keys_seq = extract_join_key_columns_serial(
        build_batch_seq, ["b_a", "b_b"]
    )
    var probe_keys_seq = extract_join_key_columns_serial(
        probe_batch_seq, ["p_a", "p_b"]
    )
    var builder_seq = MultiKeyHashJoinBuilder.build(build_keys_seq^)
    var seq_b = List[Int]()
    var seq_p = List[Int]()
    builder_seq.probe_inner_into(probe_keys_seq, seq_b, seq_p)
    assert_equal(len(seq_b), n)
    assert_equal(len(seq_p), n)

    var build_batch_par = _build_synthetic_build(n)
    var probe_batch_par = _build_synthetic_probe(n, n)
    var build_keys_par = extract_join_key_columns_serial(
        build_batch_par, ["b_a", "b_b"]
    )
    var probe_keys_par = extract_join_key_columns_serial(
        probe_batch_par, ["p_a", "p_b"]
    )
    var builder_par = MultiKeyHashJoinBuilder.build(build_keys_par^)
    var rt = _test_runtime()
    ref dispatcher = rt.dispatcher()
    var par_b = List[Int]()
    var par_p = List[Int]()
    parallel_multi_key_inner_probe_into(
        dispatcher, CancellationToken.never(),
        builder_par, probe_keys_par,
        par_b, par_p,
    )
    assert_equal(len(par_b), n)
    assert_equal(len(par_p), n)

    _assert_pairs_equal(seq_b, seq_p, par_b, par_p)


def test_parallel_2key_determinism_3runs() raises:
    """Parallel multi-key inner probe must be deterministic across runs."""
    var n = 100_000

    var rt = _test_runtime()
    ref dispatcher = rt.dispatcher()

    var bb0 = _build_synthetic_build(n)
    var pb0 = _build_synthetic_probe(n, n)
    var bk0 = extract_join_key_columns_serial(bb0, ["b_a", "b_b"])
    var pk0 = extract_join_key_columns_serial(pb0, ["p_a", "p_b"])
    var b0 = MultiKeyHashJoinBuilder.build(bk0^)
    var run0_b = List[Int]()
    var run0_p = List[Int]()
    parallel_multi_key_inner_probe_into(
        dispatcher, CancellationToken.never(),
        b0, pk0, run0_b, run0_p,
    )

    var bb1 = _build_synthetic_build(n)
    var pb1 = _build_synthetic_probe(n, n)
    var bk1 = extract_join_key_columns_serial(bb1, ["b_a", "b_b"])
    var pk1 = extract_join_key_columns_serial(pb1, ["p_a", "p_b"])
    var b1 = MultiKeyHashJoinBuilder.build(bk1^)
    var run1_b = List[Int]()
    var run1_p = List[Int]()
    parallel_multi_key_inner_probe_into(
        dispatcher, CancellationToken.never(),
        b1, pk1, run1_b, run1_p,
    )

    var bb2 = _build_synthetic_build(n)
    var pb2 = _build_synthetic_probe(n, n)
    var bk2 = extract_join_key_columns_serial(bb2, ["b_a", "b_b"])
    var pk2 = extract_join_key_columns_serial(pb2, ["p_a", "p_b"])
    var b2 = MultiKeyHashJoinBuilder.build(bk2^)
    var run2_b = List[Int]()
    var run2_p = List[Int]()
    parallel_multi_key_inner_probe_into(
        dispatcher, CancellationToken.never(),
        b2, pk2, run2_b, run2_p,
    )

    _assert_pairs_equal(run0_b, run0_p, run1_b, run1_p)
    _assert_pairs_equal(run1_b, run1_p, run2_b, run2_p)


def test_parallel_empty_probe() raises:
    """Edge case: empty probe-side input -> zero matches (no crash)."""
    var b_a: List[Int64] = []
    b_a.append(Int64(1))
    b_a.append(Int64(2))
    b_a.append(Int64(3))
    var b_b: List[Int64] = []
    b_b.append(Int64(10))
    b_b.append(Int64(20))
    b_b.append(Int64(30))
    var build_batch = _make_2col_int64("b_a", "b_b", b_a, b_b)

    var p_a: List[Int64] = []
    var p_b: List[Int64] = []
    var probe_batch = _make_2col_int64("p_a", "p_b", p_a, p_b)

    var bk = extract_join_key_columns_serial(build_batch, ["b_a", "b_b"])
    var pk = extract_join_key_columns_serial(probe_batch, ["p_a", "p_b"])
    var builder = MultiKeyHashJoinBuilder.build(bk^)

    var rt = _test_runtime()
    ref dispatcher = rt.dispatcher()
    var bm = List[Int]()
    var pm = List[Int]()
    parallel_multi_key_inner_probe_into(
        dispatcher, CancellationToken.never(),
        builder, pk, bm, pm,
    )
    assert_equal(len(bm), 0)
    assert_equal(len(pm), 0)


comptime _SKEW_N_BUILD: Int = 12_000
comptime _SKEW_N_HOT_BUILD: Int = 200       # build rows sharing the hot key
comptime _SKEW_HOT_KEY: Int64 = 7
comptime _SKEW_COLD_BASE: Int64 = 1_000     # distinct-key base
comptime _SKEW_N_PROBE: Int = 70_000        # > 1 morsel => >= 2 workers
comptime _SKEW_HOT_STRIDE: Int = 50         # every 50th probe row is hot


def _skew_build_batch() raises -> RecordBatch:
    """Build side: 200 rows on ONE key, 11,800 rows on distinct keys."""
    var b_a = List[Int64](capacity=_SKEW_N_BUILD)
    var b_b = List[Int64](capacity=_SKEW_N_BUILD)
    for i in range(_SKEW_N_BUILD):
        if i < _SKEW_N_HOT_BUILD:
            b_a.append(_SKEW_HOT_KEY)
            b_b.append(_SKEW_HOT_KEY)
        else:
            b_a.append(_SKEW_COLD_BASE + Int64(i))
            b_b.append(_SKEW_COLD_BASE + Int64(i))
    return _make_2col_int64("b_a", "b_b", b_a, b_b)


def _skew_probe_batch() raises -> RecordBatch:
    """Probe side: every 50th row hits the 200-row chain, the rest match 1:1."""
    var n_cold_build = _SKEW_N_BUILD - _SKEW_N_HOT_BUILD
    var p_a = List[Int64](capacity=_SKEW_N_PROBE)
    var p_b = List[Int64](capacity=_SKEW_N_PROBE)
    for i in range(_SKEW_N_PROBE):
        if i % _SKEW_HOT_STRIDE == 0:
            p_a.append(_SKEW_HOT_KEY)
            p_b.append(_SKEW_HOT_KEY)
        else:
            var j = _SKEW_N_HOT_BUILD + (i % n_cold_build)
            p_a.append(_SKEW_COLD_BASE + Int64(j))
            p_b.append(_SKEW_COLD_BASE + Int64(j))
    return _make_2col_int64("p_a", "p_b", p_a, p_b)


def test_parallel_skew_overflows_presize_values_stay_paired() raises:
    """Forcing the cursor's growth path must not desync the paired index lists."""
    var n_cold_build = _SKEW_N_BUILD - _SKEW_N_HOT_BUILD
    var n_hot_probe = (_SKEW_N_PROBE + _SKEW_HOT_STRIDE - 1) // _SKEW_HOT_STRIDE
    var n_cold_probe = _SKEW_N_PROBE - n_hot_probe
    var expected_total = n_hot_probe * _SKEW_N_HOT_BUILD + n_cold_probe
    var hot_index_sum = (_SKEW_N_HOT_BUILD * (_SKEW_N_HOT_BUILD - 1)) // 2

    var build_batch = _skew_build_batch()
    var probe_batch = _skew_probe_batch()
    var bk = extract_join_key_columns_serial(build_batch, ["b_a", "b_b"])
    var pk = extract_join_key_columns_serial(probe_batch, ["p_a", "p_b"])
    var builder = MultiKeyHashJoinBuilder.build(bk^)

    var rt = _test_runtime()
    ref dispatcher = rt.dispatcher()
    var bm = List[Int]()
    var pm = List[Int]()
    parallel_multi_key_inner_probe_into(
        dispatcher, CancellationToken.never(),
        builder, pk, bm, pm,
    )

    assert_equal(len(bm), expected_total)
    assert_equal(len(pm), expected_total)

    var build_key = List[Int64](capacity=_SKEW_N_BUILD)
    for i in range(_SKEW_N_BUILD):
        if i < _SKEW_N_HOT_BUILD:
            build_key.append(_SKEW_HOT_KEY)
        else:
            build_key.append(_SKEW_COLD_BASE + Int64(i))
    var probe_key = List[Int64](capacity=_SKEW_N_PROBE)
    for i in range(_SKEW_N_PROBE):
        if i % _SKEW_HOT_STRIDE == 0:
            probe_key.append(_SKEW_HOT_KEY)
        else:
            probe_key.append(
                _SKEW_COLD_BASE + Int64(_SKEW_N_HOT_BUILD + (i % n_cold_build))
            )

    var cnt = List[Int](capacity=_SKEW_N_PROBE)
    var bsum = List[Int](capacity=_SKEW_N_PROBE)
    for _ in range(_SKEW_N_PROBE):
        cnt.append(0)
        bsum.append(0)

    var bad_key_pairs = 0
    var out_of_range = 0
    for i in range(len(bm)):
        var br = bm[i]
        var pr = pm[i]
        if br < 0 or br >= _SKEW_N_BUILD or pr < 0 or pr >= _SKEW_N_PROBE:
            out_of_range += 1
            continue
        if build_key[br] != probe_key[pr]:
            bad_key_pairs += 1
        cnt[pr] = cnt[pr] + 1
        bsum[pr] = bsum[pr] + br
    assert_equal(out_of_range, 0)
    assert_equal(bad_key_pairs, 0)

    for i in range(_SKEW_N_PROBE):
        if i % _SKEW_HOT_STRIDE == 0:
            assert_equal(cnt[i], _SKEW_N_HOT_BUILD)
            assert_equal(bsum[i], hot_index_sum)
        else:
            assert_equal(cnt[i], 1)
            assert_equal(bsum[i], _SKEW_N_HOT_BUILD + (i % n_cold_build))


def test_parallel_skew_growth_matches_sequential_kernel() raises:
    """Cross-check the grown parallel output against the sequential kernel."""
    var n = 20_000
    var n_cold_build = _SKEW_N_BUILD - _SKEW_N_HOT_BUILD

    var probe_a = List[Int64](capacity=n)
    var probe_b = List[Int64](capacity=n)
    for i in range(n):
        if i % _SKEW_HOT_STRIDE == 0:
            probe_a.append(_SKEW_HOT_KEY)
            probe_b.append(_SKEW_HOT_KEY)
        else:
            var j = _SKEW_N_HOT_BUILD + (i % n_cold_build)
            probe_a.append(_SKEW_COLD_BASE + Int64(j))
            probe_b.append(_SKEW_COLD_BASE + Int64(j))

    var seq_b = List[Int]()
    var seq_p = List[Int]()
    var build_seq = _skew_build_batch()
    var probe_seq = _make_2col_int64("p_a", "p_b", probe_a, probe_b)
    var bk_seq = extract_join_key_columns_serial(build_seq, ["b_a", "b_b"])
    var pk_seq = extract_join_key_columns_serial(probe_seq, ["p_a", "p_b"])
    var builder_seq = MultiKeyHashJoinBuilder.build(bk_seq^)
    builder_seq.probe_inner_into(pk_seq, seq_b, seq_p)

    var par_b = List[Int]()
    var par_p = List[Int]()
    var build_par = _skew_build_batch()
    var probe_par = _make_2col_int64("p_a", "p_b", probe_a, probe_b)
    var bk_par = extract_join_key_columns_serial(build_par, ["b_a", "b_b"])
    var pk_par = extract_join_key_columns_serial(probe_par, ["p_a", "p_b"])
    var builder_par = MultiKeyHashJoinBuilder.build(bk_par^)
    var rt = _test_runtime()
    ref dispatcher = rt.dispatcher()
    parallel_multi_key_inner_probe_into(
        dispatcher, CancellationToken.never(),
        builder_par, pk_par, par_b, par_p,
    )

    assert_equal(len(par_b), len(seq_b))
    assert_equal(len(par_p), len(seq_p))
    assert_true(len(par_b) > 0)

    var seq_cnt = List[Int](capacity=n)
    var seq_sum = List[Int](capacity=n)
    var seq_xor = List[Int](capacity=n)
    var par_cnt = List[Int](capacity=n)
    var par_sum = List[Int](capacity=n)
    var par_xor = List[Int](capacity=n)
    for _ in range(n):
        seq_cnt.append(0)
        seq_sum.append(0)
        seq_xor.append(0)
        par_cnt.append(0)
        par_sum.append(0)
        par_xor.append(0)
    for i in range(len(seq_b)):
        var pr = seq_p[i]
        seq_cnt[pr] = seq_cnt[pr] + 1
        seq_sum[pr] = seq_sum[pr] + seq_b[i]
        seq_xor[pr] = seq_xor[pr] ^ (seq_b[i] + 1)
    for i in range(len(par_b)):
        var pr = par_p[i]
        par_cnt[pr] = par_cnt[pr] + 1
        par_sum[pr] = par_sum[pr] + par_b[i]
        par_xor[pr] = par_xor[pr] ^ (par_b[i] + 1)
    for i in range(n):
        assert_equal(par_cnt[i], seq_cnt[i])
        assert_equal(par_sum[i], seq_sum[i])
        assert_equal(par_xor[i], seq_xor[i])


def main() raises:
    var suite = TestSuite()
    suite.test[test_parallel_2key_same_pairs_as_sequential_100k]()
    suite.test[test_parallel_2key_determinism_3runs]()
    suite.test[test_parallel_empty_probe]()
    suite.test[test_parallel_skew_overflows_presize_values_stay_paired]()
    suite.test[test_parallel_skew_growth_matches_sequential_kernel]()
    suite^.run()
