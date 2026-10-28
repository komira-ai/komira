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
#
# The retile is driven through the pool size and the settings, not the host's
# core count; a probe whose key count or key lengths disagree with the build
# is refused with a named error, and so is a negative setting.

from std.ffi import external_call
from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_collections.slab import Slab

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async.runtime.sched_trace import SITE_JOIN_MULTIKEY
from komira_async_api.token import CancellationToken
from komira_engine_runtime.fan_out_grain import parallel_fork_grain
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
from komira_op_join_probe.join_multi_key import MultiKeyColumns
from komira_op_join_probe.join_multi_key_builder import (
    MultiKeyHashJoinBuilder,
)
from komira_op_join_probe.join_multi_key_parallel import (
    parallel_multi_key_inner_probe_into,
)
from komira_op_join_probe.join_probe_settings import (
    mk_probe_batch_width,
    mk_probe_configure,
    mk_probe_morsel_rows,
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


def _sorted_pairs(b: List[Int], p: List[Int]) -> List[Int]:
    """Each pair as `build * 1_000_000 + probe` (rows are below a million),
    sorted."""
    var out = List[Int](capacity=len(b))
    for i in range(len(b)):
        out.append(b[i] * 1_000_000 + p[i])
    sort(out)
    return out^


def _assert_same_pairs(
    a_b: List[Int], a_p: List[Int], b_b: List[Int], b_p: List[Int]
) raises:
    assert_equal(len(a_b), len(a_p))
    assert_equal(len(b_b), len(b_p))
    assert_equal(len(a_b), len(b_b), "the pair counts differ")
    var sa = _sorted_pairs(a_b, a_p)
    var sb = _sorted_pairs(b_b, b_p)
    for i in range(len(sa)):
        assert_equal(sa[i], sb[i], "a pair differs")


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
    reset_join_probe_settings()
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
    reset_join_probe_settings()
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
    reset_join_probe_settings()
    var build = _int_batch(0, 9, 1, 0)
    var probe = _int_batch(200, 9, 3, 0)
    assert_equal(_check(build, probe, 4, 50), 0)


def test_empty_probe_returns_no_pairs() raises:
    reset_join_probe_settings()
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
    reset_join_probe_settings()
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


def _record(field: Int) raises -> Int:
    return grain_geometry_field(SITE_JOIN_MULTIKEY, field)


def _run_unconfigured_morsel(
    build: RecordBatch, probe: RecordBatch, workers: Int, retile: Bool
) raises:
    """Probe with the fork grain (no morsel given) and check the pairs."""
    var bk = extract_join_key_columns_serial(build, _names())
    var pk = extract_join_key_columns_serial(probe, _names())
    var builder = MultiKeyHashJoinBuilder.build(bk^)
    var seq_b = List[Int]()
    var seq_p = List[Int]()
    builder.probe_inner_into(pk, seq_b, seq_p)
    mk_probe_configure(retile=retile)
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
    assert_true(len(seq_b) > 0, "the data produced no pairs")
    _assert_same_pairs(seq_b, seq_p, par_b, par_p)


def test_retile_cuts_the_morsels_when_every_pool_worker_has_one() raises:
    """With the retile on, a pool of 4 workers and fewer than 16 morsels, the
    morsel shrinks to a sixteenth of the probe (never under 4,096 rows) and the
    split is recorded as run; with it off the split is the fork grain's.
    """
    reset_join_probe_settings()
    var workers = 4
    var rows = 100_000
    var grain = parallel_fork_grain(rows, workers)
    var grain_morsels = (rows + grain - 1) // grain
    var cut = (rows + 4 * workers - 1) // (4 * workers)
    # The case is only a retile case when the fork grain gives every worker a
    # morsel but fewer than four, and the cut is a real cut.
    assert_true(grain_morsels >= workers and grain_morsels < 4 * workers)
    assert_true(cut >= 4_096 and cut < grain)
    var build = _int_batch(45, 9, 1, 0)
    var probe = _int_batch(rows, 9, 3, 17)

    _run_unconfigured_morsel(build, probe, workers, False)
    assert_equal(_record(GRAIN_F_GRAIN), grain)
    assert_equal(_record(GRAIN_F_MORSELS), grain_morsels)

    _run_unconfigured_morsel(build, probe, workers, True)
    assert_equal(_record(GRAIN_F_ROWS), rows)
    assert_equal(_record(GRAIN_F_GRAIN), cut)
    assert_equal(_record(GRAIN_F_MORSELS), (rows + cut - 1) // cut)
    assert_equal(_record(GRAIN_F_WORKERS), workers)


def test_retile_leaves_a_given_morsel_alone() raises:
    """A morsel given in the settings is never cut, retile or not."""
    reset_join_probe_settings()
    var build = _int_batch(45, 9, 1, 0)
    var probe = _int_batch(100_000, 9, 3, 17)
    var bk = extract_join_key_columns_serial(build, _names())
    var pk = extract_join_key_columns_serial(probe, _names())
    var builder = MultiKeyHashJoinBuilder.build(bk^)
    mk_probe_configure(morsel_rows=30_000, retile=True)
    grain_geometry_reset()
    var rt = _runtime(4)
    ref dispatcher = rt.dispatcher()
    var par_b = List[Int]()
    var par_p = List[Int]()
    parallel_multi_key_inner_probe_into(
        dispatcher, CancellationToken.never(), builder, pk, par_b, par_p
    )
    rt.shutdown()
    reset_join_probe_settings()
    assert_equal(_record(GRAIN_F_GRAIN), 30_000)
    assert_equal(_record(GRAIN_F_MORSELS), 4)


def test_retile_does_not_run_when_a_pool_worker_has_no_morsel() raises:
    """8 workers and a 20,000-row probe: the fork grain gives fewer morsels
    than workers, so some worker has none and the retile leaves the split as
    the fork grain made it."""
    reset_join_probe_settings()
    var rows = 20_000
    var grain = parallel_fork_grain(rows, 8)
    var grain_morsels = (rows + grain - 1) // grain
    assert_true(grain_morsels < 8, "the case needs fewer morsels than workers")
    _run_unconfigured_morsel(
        _int_batch(45, 9, 1, 0), _int_batch(rows, 9, 3, 17), 8, True
    )
    assert_equal(_record(GRAIN_F_GRAIN), grain)
    assert_equal(_record(GRAIN_F_MORSELS), grain_morsels)
    assert_equal(_record(GRAIN_F_WORKERS), grain_morsels)


def _i64_arr(imm values: List[Int64]) -> PrimitiveArray[I64]:
    var arr = PrimitiveArray[I64].allocate(len(values))
    var p = arr._typed_ptr_mut()
    for i in range(len(values)):
        p.store[width=1](i, values[i])
    return arr^


def _slots(imm cols: List[List[Int64]]) raises -> MultiKeyColumns:
    """Key slots with one Int64 column per entry; the lengths may differ."""
    var n_keys = len(cols)
    var ik = Slab[PrimitiveArray[I64]].create(n_keys)
    var sk = Slab[Optional[StringArray[HeapRegion]]].create(n_keys)
    var dk = Slab[Optional[StringDictionaryArray]].create(n_keys)
    var fps = List[UInt64]()
    for k in range(n_keys):
        ik.append(_i64_arr(cols[k]))
        sk.append(Optional[StringArray[HeapRegion]](None))
        dk.append(Optional[StringDictionaryArray](None))
        fps.append(UInt64(0))
    return MultiKeyColumns(ik^, sk^, dk^, fps^, n_keys)


def _expect_refusal(
    probe_keys: MultiKeyColumns, reason: String
) raises:
    """The probe against a two-key build refuses `probe_keys` with `reason` in
    its message and leaves the caller's lists as they were."""
    var build = _int_batch(50, 9, 1, 0)
    var bk = extract_join_key_columns_serial(build, _names())
    var builder = MultiKeyHashJoinBuilder.build(bk^)
    var rt = _runtime(2)
    ref dispatcher = rt.dispatcher()
    var par_b: List[Int] = [11, 12]
    var par_p: List[Int] = [21, 22, 23]
    var message = String("")
    var raised = False
    try:
        parallel_multi_key_inner_probe_into(
            dispatcher, CancellationToken.never(), builder, probe_keys,
            par_b, par_p,
        )
    except e:
        raised = True
        message = String(e)
    rt.shutdown()
    assert_true(raised, "the probe returned instead of raising")
    assert_true(
        reason in message,
        "the error does not say '" + reason + "': " + message,
    )
    assert_equal(len(par_b), 2)
    assert_equal(len(par_p), 3)


def test_probe_with_the_wrong_key_count_is_refused() raises:
    """A one-key probe against a two-key build raises a key-count error."""
    reset_join_probe_settings()
    var one_key = List[String]()
    one_key.append(String("k0"))
    var pk = extract_join_key_columns_serial(_int_batch(20, 9, 3, 0), one_key)
    _expect_refusal(pk, "probe key count 1 != build key count 2")


def test_probe_keys_of_different_lengths_are_refused() raises:
    """Two probe key columns of 5 and 3 rows raise a key-length error."""
    reset_join_probe_settings()
    var cols = List[List[Int64]]()
    cols.append([Int64(1), Int64(2), Int64(3), Int64(4), Int64(5)])
    cols.append([Int64(1), Int64(2), Int64(3)])
    _expect_refusal(_slots(cols), "probe key 1 length 3 != probe key 0 length 5")


def test_negative_settings_are_refused_and_change_nothing() raises:
    """A negative morsel or width raises naming the setting, and the settings
    keep their earlier values."""
    reset_join_probe_settings()
    mk_probe_configure(batch_width=7, morsel_rows=9)
    var morsel_msg = String("")
    try:
        mk_probe_configure(batch_width=3, morsel_rows=-1)
    except e:
        morsel_msg = String(e)
    assert_true("negative morsel_rows" in morsel_msg, morsel_msg)
    var width_msg = String("")
    try:
        mk_probe_configure(batch_width=-1, morsel_rows=3)
    except e:
        width_msg = String(e)
    assert_true("negative batch_width" in width_msg, width_msg)
    assert_equal(mk_probe_batch_width(), 7)
    assert_equal(mk_probe_morsel_rows(), 9)
    reset_join_probe_settings()


def main() raises:
    # A lost wake-up must fail the build, not hold a worker: exit 142.
    _ = external_call["alarm", UInt32](UInt32(300))
    var suite = TestSuite()
    suite.test[test_int_keys_match_serial_across_workers_and_morsels]()
    suite.test[test_float_keys_nan_and_signed_zero_match_serial]()
    suite.test[test_empty_build_returns_no_pairs]()
    suite.test[test_empty_probe_returns_no_pairs]()
    suite.test[test_cancelled_probe_raises_and_leaves_the_lists_untouched]()
    suite.test[test_retile_cuts_the_morsels_when_every_pool_worker_has_one]()
    suite.test[test_retile_leaves_a_given_morsel_alone]()
    suite.test[test_retile_does_not_run_when_a_pool_worker_has_no_morsel]()
    suite.test[test_probe_with_the_wrong_key_count_is_refused]()
    suite.test[test_probe_keys_of_different_lengths_are_refused]()
    suite.test[test_negative_settings_are_refused_and_change_nothing]()
    suite^.run()
