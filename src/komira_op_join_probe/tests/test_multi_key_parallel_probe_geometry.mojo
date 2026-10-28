# The parallel composite INNER probe against the serial probe across the split
# geometry: the worker count and the probe morsel size. Every run must return
# the serial probe's pair multiset (sorted, element for element, so a lost or a
# duplicated pair shows), and the recorded split (rows, morsel, morsels,
# workers) must be the one the settings ask for, whatever the schedule did.
#
# The data repeats build keys (a chain holds several true matches), puts NULLs
# on both sides, and covers FLOAT64 keys with NaN, -0.0 and +0.0. An empty
# build, an empty probe, and a probe whose token is already cancelled complete
# the set: the cancelled probe raises and leaves the caller's lists exactly as
# they were.

from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_buffer.heap_region import HeapRegion

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async.runtime.sched_trace import SITE_JOIN_MULTIKEY
from komira_async_api.token import CancellationToken
from komira_engine_runtime.grain_geometry import (
    GRAIN_F_GRAIN,
    GRAIN_F_MORSELS,
    GRAIN_F_ROWS,
    GRAIN_F_WORKERS,
    grain_geometry_field,
    grain_geometry_reset,
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
from komira_op_join_probe.join_probe_settings import (
    mk_probe_configure,
    reset_join_probe_settings,
)


comptime I64 = DType.int64
comptime F64 = DType.float64


def _test_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _runtime(workers: Int) raises -> PerCoreAsyncRuntime[NoopSink]:
    return PerCoreAsyncRuntime[NoopSink](
        num_workers=workers,
        sink_factory=_test_sink,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )


def _names() -> List[String]:
    var l = List[String]()
    l.append(String("k0"))
    l.append(String("k1"))
    return l^


def _sorted_pairs(b: List[Int], p: List[Int]) -> List[Tuple[Int, Int]]:
    var n = len(b)
    var pairs = List[Tuple[Int, Int]](capacity=n)
    for i in range(n):
        pairs.append((b[i], p[i]))
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


def _assert_same_pairs(
    a_b: List[Int], a_p: List[Int], b_b: List[Int], b_p: List[Int]
) raises:
    assert_equal(len(a_b), len(a_p))
    assert_equal(len(b_b), len(b_p))
    assert_equal(len(a_b), len(b_b), "the pair counts differ")
    var sa = _sorted_pairs(a_b, a_p)
    var sb = _sorted_pairs(b_b, b_p)
    for i in range(len(sa)):
        assert_equal(sa[i][0], sb[i][0], "a pair's build row differs")
        assert_equal(sa[i][1], sb[i][1], "a pair's probe row differs")


def _int_batch(n: Int, k0_mod: Int, k1_mul: Int, null_every: Int) raises -> RecordBatch:
    var a = PrimitiveArray[I64].allocate_nullable(n)
    var c = PrimitiveArray[I64].allocate(n)
    for i in range(n):
        a.set(i, Int64(i % k0_mod))
        if null_every > 0 and i % null_every == 0:
            a._set_null(i)
        c.set(i, Int64((i * k1_mul) % 5))
    var sb = SchemaBuilder()
    sb.add_field(Field("k0", ArrowType.INT64, True))
    sb.add_field(Field("k1", ArrowType.INT64, False))
    var b = RecordBatchBuilder()
    b.add_column(Column.from_primitive[I64](a^))
    b.add_column(Column.from_primitive[I64](c^))
    return b.build(sb.build())


def _f64(bits: UInt64) -> Float64:
    return bitcast[F64](bits)


def _float_batch(n: Int, null_every: Int) raises -> RecordBatch:
    var pool = List[Float64]()
    pool.append(_f64(UInt64(0x7FF8000000000000)))
    pool.append(_f64(UInt64(0xFFF8000000000000)))
    pool.append(_f64(UInt64(0x8000000000000000)))
    pool.append(Float64(0.0))
    pool.append(Float64(1.5))
    var a = PrimitiveArray[F64].allocate_nullable(n)
    var c = PrimitiveArray[I64].allocate(n)
    for i in range(n):
        a.set(i, pool[i % len(pool)])
        if null_every > 0 and i % null_every == 0:
            a._set_null(i)
        c.set(i, Int64(7))
    var sb = SchemaBuilder()
    sb.add_field(Field("k0", ArrowType.FLOAT64, True))
    sb.add_field(Field("k1", ArrowType.INT64, False))
    var b = RecordBatchBuilder()
    b.add_column(Column.from_primitive[F64](a^))
    b.add_column(Column.from_primitive[I64](c^))
    return b.build(sb.build())


def _check(
    build: RecordBatch, probe: RecordBatch, workers: Int, morsel: Int
) raises -> Int:
    """Parallel against serial for one geometry; returns the pair count."""
    var bk = extract_join_key_columns_serial(build, _names())
    var pk = extract_join_key_columns_serial(probe, _names())
    var builder = MultiKeyHashJoinBuilder.build(bk^)
    var seq_b = List[Int]()
    var seq_p = List[Int]()
    builder.probe_inner_into(pk, seq_b, seq_p)

    mk_probe_configure(morsel_rows=morsel)
    grain_geometry_reset()
    var rt = _runtime(workers)
    ref dispatcher = rt.dispatcher()
    var par_b = List[Int]()
    var par_p = List[Int]()
    parallel_multi_key_inner_probe_into(
        dispatcher, CancellationToken.never(), builder, pk, par_b, par_p
    )
    rt.shutdown()
    reset_join_probe_settings()
    _assert_same_pairs(seq_b, seq_p, par_b, par_p)

    var rows = probe.num_rows()
    var morsels = (rows + morsel - 1) // morsel
    assert_equal(grain_geometry_field(SITE_JOIN_MULTIKEY, GRAIN_F_ROWS), rows)
    assert_equal(grain_geometry_field(SITE_JOIN_MULTIKEY, GRAIN_F_GRAIN), morsel)
    assert_equal(
        grain_geometry_field(SITE_JOIN_MULTIKEY, GRAIN_F_MORSELS), morsels
    )
    assert_equal(
        grain_geometry_field(SITE_JOIN_MULTIKEY, GRAIN_F_WORKERS),
        min(morsels, workers),
    )
    return len(seq_b)


def test_int_keys_match_serial_across_workers_and_morsels() raises:
    var build = _int_batch(600, 9, 1, 23)
    var probe = _int_batch(1_000, 9, 3, 17)
    var workers: List[Int] = [1, 2, 3, 8]
    var morsels: List[Int] = [1, 7, 64, 333, 5_000]
    var total = 0
    for w in range(len(workers)):
        for m in range(len(morsels)):
            total += _check(build, probe, workers[w], morsels[m])
    assert_true(total > 0, "the data produced no pairs, so nothing was checked")


def test_float_keys_nan_and_signed_zero_match_serial() raises:
    var build = _float_batch(300, 11)
    var probe = _float_batch(500, 13)
    var workers: List[Int] = [1, 4]
    var morsels: List[Int] = [3, 100, 4_000]
    var total = 0
    for w in range(len(workers)):
        for m in range(len(morsels)):
            total += _check(build, probe, workers[w], morsels[m])
    assert_true(total > 0, "the data produced no pairs, so nothing was checked")


def test_empty_build_returns_no_pairs() raises:
    var build = _int_batch(0, 9, 1, 0)
    var probe = _int_batch(200, 9, 3, 0)
    assert_equal(_check(build, probe, 4, 50), 0)


def test_empty_probe_returns_no_pairs() raises:
    var build = _int_batch(200, 9, 1, 0)
    var probe = _int_batch(0, 9, 3, 0)
    var bk = extract_join_key_columns_serial(build, _names())
    var pk = extract_join_key_columns_serial(probe, _names())
    var builder = MultiKeyHashJoinBuilder.build(bk^)
    var rt = _runtime(4)
    ref dispatcher = rt.dispatcher()
    var par_b = List[Int]()
    var par_p = List[Int]()
    parallel_multi_key_inner_probe_into(
        dispatcher, CancellationToken.never(), builder, pk, par_b, par_p
    )
    rt.shutdown()
    assert_equal(len(par_b), 0)
    assert_equal(len(par_p), 0)


def test_cancelled_probe_raises_and_leaves_the_lists_untouched() raises:
    var build = _int_batch(600, 9, 1, 0)
    var probe = _int_batch(1_000, 9, 3, 0)
    var bk = extract_join_key_columns_serial(build, _names())
    var pk = extract_join_key_columns_serial(probe, _names())
    var builder = MultiKeyHashJoinBuilder.build(bk^)
    var rt = _runtime(4)
    ref dispatcher = rt.dispatcher()
    var par_b: List[Int] = [11, 12]
    var par_p: List[Int] = [21, 22, 23]
    var token = CancellationToken.new()
    token.cancel("test")
    var raised = False
    try:
        parallel_multi_key_inner_probe_into(
            dispatcher, token^, builder, pk, par_b, par_p
        )
    except e:
        raised = True
        assert_true(
            "Cancel" in String(e),
            "the error does not say the probe was cancelled: " + String(e),
        )
    rt.shutdown()
    assert_true(raised, "a cancelled probe returned instead of raising")
    assert_equal(len(par_b), 2)
    assert_equal(len(par_p), 3)
    assert_equal(par_b[1], 12)
    assert_equal(par_p[2], 23)


def main() raises:
    var suite = TestSuite()
    suite.test[test_int_keys_match_serial_across_workers_and_morsels]()
    suite.test[test_float_keys_nan_and_signed_zero_match_serial]()
    suite.test[test_empty_build_returns_no_pairs]()
    suite.test[test_empty_probe_returns_no_pairs]()
    suite.test[test_cancelled_probe_raises_and_leaves_the_lists_untouched]()
    suite^.run()
