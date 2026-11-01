# The row-indexed entry space: NULL-keyed build rows take an entry but are
# linked from no chain, so every probe kind (serial INNER, parallel INNER,
# LEFT, SEMI, ANTI, RIGHT, FULL) matches the real build rows that follow them
# by their own row index, and RIGHT / FULL still emit the NULL-keyed rows.
# Every leg asserts the exact (build, probe) pair multiset, not a count.

from std.sys import size_of
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.arrow_types import ArrowType
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.bitmap import Bitmap
from komira_buffer.byte_view import ByteView
from komira_buffer.heap_region import HeapRegion

from komira_async_api.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime

from komira_op_join_probe.join_key_extract import (
    extract_join_key_columns_serial,
)
from komira_op_join_probe.join_multi_key_builder import (
    MultiKeyHashJoinBuilder,
)
from komira_op_join_probe.join_multi_key_filter import (
    multi_key_probe_semi, multi_key_probe_anti,
)
from komira_op_join_probe.join_multi_key_outer import (
    multi_key_probe_right_into, multi_key_probe_full_into,
)
from komira_op_join_probe.join_multi_key_parallel import (
    parallel_multi_key_inner_probe_into,
)


def _make_int64_col(values: List[Int]) raises -> Column[HeapRegion]:
    var n = len(values)
    var arr = PrimitiveArray[DType.int64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, Scalar[DType.int64](values[i]))
    return Column.from_primitive(arr^)


def _make_string_col(values: List[String]) raises -> Column[HeapRegion]:
    var sa = StringArray.from_strings(values)
    return Column.from_string(sa^)


def _make_nullable_string_col(
    values: List[String], null_mask: List[Bool]
) raises -> Column[HeapRegion]:
    """Nullable StringArray -> Column. `null_mask[i] == True` -> row i is null."""
    var n = len(values)
    var total_bytes = 0
    for i in range(n):
        if not null_mask[i]:
            total_bytes += values[i].byte_length()
    comptime int32_size = size_of[Int32]()
    var offsets_buf = OwnedAlignedBuffer((n + 1) * int32_size)
    offsets_buf.set_typed[Int32](0, Int32(0))
    var data_buf = OwnedAlignedBuffer(max(total_bytes, 1))
    var offset = 0
    var null_count = 0
    var bm = Bitmap.create(n)
    for i in range(n):
        if null_mask[i]:
            bm.clear(i)
            null_count += 1
        else:
            bm.set(i)
            var s = values[i]
            var s_len = s.byte_length()
            if s_len > 0:
                var src_view = ByteView(s.unsafe_ptr().bitcast[UInt8](), s_len)
                data_buf.view_range_mut(offset, s_len).copy_from_view_at(
                    0, src_view
                )
            offset += s_len
        offsets_buf.set_typed[Int32](i + 1, Int32(offset))
    offsets_buf.set_length(Int64((n + 1) * int32_size))
    data_buf.set_length(Int64(total_bytes))
    var sa = StringArray[HeapRegion](
        offsets=offsets_buf^,
        data=data_buf^,
        validity=bm^,
        length=n,
        data_length=total_bytes,
        null_count=null_count,
    )
    return Column.from_string(sa^)


def _build_side() raises -> RecordBatch:
    """Build side [s(STRING nullable), v(INT64)] with rows 0,1 NULL-keyed (never
    inserted into any hash bucket by the composite build), rows 2,3 real.
    """
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRING, True))
    sb.add_field(Field("v", ArrowType.INT64, False))
    var schema = sb.build()
    var bldr = RecordBatchBuilder()
    var svals: List[String] = ["", "", "A", "B"]
    var smask: List[Bool] = [True, True, False, False]
    bldr.add_column(_make_nullable_string_col(svals, smask))
    var vvals: List[Int] = [100, 110, 200, 300]
    bldr.add_column(_make_int64_col(vvals))
    return bldr.build(schema^)


def _probe_side() raises -> RecordBatch:
    """Probe side [ps(STRING), pv(INT64)] = [(A,200),(B,300)] -> match build
    rows 2,3 respectively.
    """
    var sb = SchemaBuilder()
    sb.add_field(Field("ps", ArrowType.STRING, False))
    sb.add_field(Field("pv", ArrowType.INT64, False))
    var schema = sb.build()
    var bldr = RecordBatchBuilder()
    var psvals: List[String] = ["A", "B"]
    bldr.add_column(_make_string_col(psvals))
    var pvvals: List[Int] = [200, 300]
    bldr.add_column(_make_int64_col(pvvals))
    return bldr.build(schema^)


def _build_keys_bundle() raises -> MultiKeyHashJoinBuilder:
    var build_batch = _build_side()
    var bk: List[String] = ["s", "v"]
    var build_keys = extract_join_key_columns_serial(build_batch, bk)
    return MultiKeyHashJoinBuilder.build(build_keys^)


def _has_pair(
    build_matches: List[Int], probe_matches: List[Int],
    build_row: Int, probe_row: Int,
) -> Bool:
    for i in range(len(build_matches)):
        if build_matches[i] == build_row and probe_matches[i] == probe_row:
            return True
    return False


def _build_side_trailing_skip() raises -> RecordBatch:
    """Build side [s(STRING nullable), v(INT64)] = [(A,200),(B,300),(NULL,999)]."""
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRING, True))
    sb.add_field(Field("v", ArrowType.INT64, False))
    var schema = sb.build()
    var bldr = RecordBatchBuilder()
    var svals: List[String] = ["A", "B", ""]
    var smask: List[Bool] = [False, False, True]
    bldr.add_column(_make_nullable_string_col(svals, smask))
    var vvals: List[Int] = [200, 300, 999]
    bldr.add_column(_make_int64_col(vvals))
    return bldr.build(schema^)


def _builder_trailing_skip() raises -> MultiKeyHashJoinBuilder:
    var build_batch = _build_side_trailing_skip()
    var bk: List[String] = ["s", "v"]
    var build_keys = extract_join_key_columns_serial(build_batch, bk)
    return MultiKeyHashJoinBuilder.build(build_keys^)


def _count_pair(
    bm: List[Int], pm: List[Int], build_row: Int, probe_row: Int
) -> Int:
    var c = 0
    for i in range(len(bm)):
        if bm[i] == build_row and pm[i] == probe_row:
            c += 1
    return c


def _fmt_pairs(bm: List[Int], pm: List[Int]) -> String:
    var s = String("{")
    for i in range(len(bm)):
        if i > 0:
            s += ","
        s += "(" + String(bm[i]) + "," + String(pm[i]) + ")"
    return s + "}"


def _assert_pairs_exact(
    bm: List[Int], pm: List[Int],
    exp_b: List[Int], exp_p: List[Int],
    label: String,
) raises:
    """Exact MULTISET equality of the emitted (build_idx, probe_idx) pairs."""
    var got = _fmt_pairs(bm, pm)
    var want = _fmt_pairs(exp_b, exp_p)
    var ctx = String(" got=") + got + " want=" + want
    assert_equal(
        len(bm), len(pm), label + ": build/probe index lists differ in length"
        + ctx,
    )
    for i in range(len(exp_b)):
        assert_equal(
            _count_pair(bm, pm, exp_b[i], exp_p[i]),
            _count_pair(exp_b, exp_p, exp_b[i], exp_p[i]),
            label + ": wrong multiplicity for expected pair ("
            + String(exp_b[i]) + "," + String(exp_p[i]) + ")" + ctx,
        )
    for i in range(len(bm)):
        assert_equal(
            _count_pair(exp_b, exp_p, bm[i], pm[i]),
            _count_pair(bm, pm, bm[i], pm[i]),
            label + ": unexpected pair (" + String(bm[i]) + ","
            + String(pm[i]) + ")" + ctx,
        )
    assert_equal(len(bm), len(exp_b), label + ": wrong pair count" + ctx)


def _test_runtime() raises -> PerCoreAsyncRuntime[NoopSink]:
    return PerCoreAsyncRuntime[NoopSink](
        num_workers=4,
        sink_factory=_runtime_sink,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )


def _runtime_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def test_inner_serial_reads_correct_build_row() raises:
    """probe_inner_into MUST match the real rows past the compaction skew.
    Pre-fix: reads build key at the compacted chain_idx (rows 0/1, both NULL) ->
    0 matches. Post-fix: 2 matches at build rows 2,3.
    """
    var builder = _build_keys_bundle()
    var probe_batch = _probe_side()
    var pk: List[String] = ["ps", "pv"]
    var probe_keys = extract_join_key_columns_serial(probe_batch, pk)
    var build_matches = List[Int]()
    var probe_matches = List[Int]()
    builder.probe_inner_into(probe_keys, build_matches, probe_matches)
    assert_equal(
        len(build_matches), 2,
        "INNER (serial): 2 real matches past the 2-row compaction skew.",
    )
    assert_true(
        _has_pair(build_matches, probe_matches, 2, 0),
        "probe (A,200) MUST match build row 2 (not the skipped row 0).",
    )
    assert_true(
        _has_pair(build_matches, probe_matches, 3, 1),
        "probe (B,300) MUST match build row 3 (not the skipped row 1).",
    )


def test_inner_parallel_reads_correct_build_row() raises:
    """parallel_multi_key_inner_probe_into (the large-probe path) MUST
    read the correct build row past the compaction skew.
    """
    var builder = _build_keys_bundle()
    var probe_batch = _probe_side()
    var pk: List[String] = ["ps", "pv"]
    var probe_keys = extract_join_key_columns_serial(probe_batch, pk)
    var build_matches = List[Int]()
    var probe_matches = List[Int]()
    var rt = _test_runtime()
    ref dispatcher = rt.dispatcher()
    parallel_multi_key_inner_probe_into(
        dispatcher, CancellationToken.never(), builder, probe_keys,
        build_matches, probe_matches,
    )
    assert_equal(
        len(build_matches), 2,
        "INNER (parallel): 2 real matches past the compaction skew.",
    )
    assert_true(_has_pair(build_matches, probe_matches, 2, 0))
    assert_true(_has_pair(build_matches, probe_matches, 3, 1))


def test_left_reads_correct_build_row() raises:
    """probe_left_into MUST bind matched probe rows to the real build rows (2,3),
    NOT emit build=-1. Pre-fix: both probe rows appear with build=-1 (no match).
    """
    var builder = _build_keys_bundle()
    var probe_batch = _probe_side()
    var pk: List[String] = ["ps", "pv"]
    var probe_keys = extract_join_key_columns_serial(probe_batch, pk)
    var build_indices = List[Int]()
    var probe_indices = List[Int]()
    builder.probe_left_into(probe_keys, build_indices, probe_indices)
    assert_equal(len(probe_indices), 2, "LEFT emits every probe row once.")
    assert_true(
        _has_pair(build_indices, probe_indices, 2, 0),
        "LEFT probe (A,200) MUST bind build row 2 (not -1).",
    )
    assert_true(
        _has_pair(build_indices, probe_indices, 3, 1),
        "LEFT probe (B,300) MUST bind build row 3 (not -1).",
    )


def test_semi_finds_matches() raises:
    """multi_key_probe_semi MUST return BOTH probe rows (both match past the
    skew). 
    """
    var builder = _build_keys_bundle()
    var probe_batch = _probe_side()
    var pk: List[String] = ["ps", "pv"]
    var probe_keys = extract_join_key_columns_serial(probe_batch, pk)
    var semi = multi_key_probe_semi(builder, probe_keys)
    assert_equal(len(semi), 2, "SEMI: both probe rows have a real match.")


def test_anti_excludes_matches() raises:
    """multi_key_probe_anti MUST return NO probe rows (both match past the skew).
    Pre-fix: BOTH probe rows (bug drops the matches -> they look unmatched).
    """
    var builder = _build_keys_bundle()
    var probe_batch = _probe_side()
    var pk: List[String] = ["ps", "pv"]
    var probe_keys = extract_join_key_columns_serial(probe_batch, pk)
    var anti = multi_key_probe_anti(builder, probe_keys)
    assert_equal(len(anti), 0, "ANTI: both probe rows match -> none excluded.")


def test_right_pair_multiset() raises:
    """`multi_key_probe_right_into` on the skew-2 fixture."""
    var builder = _build_keys_bundle()
    var probe_batch = _probe_side()
    var pk: List[String] = ["ps", "pv"]
    var probe_keys = extract_join_key_columns_serial(probe_batch, pk)
    var build_matches = List[Int]()
    var probe_matches = List[Int]()
    multi_key_probe_right_into(
        builder, probe_keys, build_matches, probe_matches
    )
    var exp_b: List[Int] = [2, 3, 0, 1]
    var exp_p: List[Int] = [0, 1, -1, -1]
    _assert_pairs_exact(
        build_matches, probe_matches, exp_b, exp_p, "RIGHT (skew 2)"
    )


def test_full_pair_multiset() raises:
    """`multi_key_probe_full_into` on the skew-2 fixture."""
    var builder = _build_keys_bundle()
    var probe_batch = _probe_side()
    var pk: List[String] = ["ps", "pv"]
    var probe_keys = extract_join_key_columns_serial(probe_batch, pk)
    var build_matches = List[Int]()
    var probe_matches = List[Int]()
    multi_key_probe_full_into(
        builder, probe_keys, build_matches, probe_matches
    )
    var exp_b: List[Int] = [2, 3, 0, 1]
    var exp_p: List[Int] = [0, 1, -1, -1]
    _assert_pairs_exact(
        build_matches, probe_matches, exp_b, exp_p, "FULL (skew 2)"
    )


def test_right_preserves_trailing_sentinel_build_row() raises:
    """RIGHT keeps a trailing NULL-keyed build row: the sweep covers every
    build row, not only the inserted ones."""
    var builder = _builder_trailing_skip()
    var probe_batch = _probe_side()
    var pk: List[String] = ["ps", "pv"]
    var probe_keys = extract_join_key_columns_serial(probe_batch, pk)
    var build_matches = List[Int]()
    var probe_matches = List[Int]()
    multi_key_probe_right_into(
        builder, probe_keys, build_matches, probe_matches
    )
    var exp_b: List[Int] = [0, 1, 2]
    var exp_p: List[Int] = [0, 1, -1]
    _assert_pairs_exact(
        build_matches, probe_matches, exp_b, exp_p,
        "RIGHT (trailing sentinel, NULL-keyed tail)",
    )


def test_full_preserves_trailing_sentinel_build_row() raises:
    """FULL keeps a trailing NULL-keyed build row."""
    var builder = _builder_trailing_skip()
    var probe_batch = _probe_side()
    var pk: List[String] = ["ps", "pv"]
    var probe_keys = extract_join_key_columns_serial(probe_batch, pk)
    var build_matches = List[Int]()
    var probe_matches = List[Int]()
    multi_key_probe_full_into(
        builder, probe_keys, build_matches, probe_matches
    )
    var exp_b: List[Int] = [0, 1, 2]
    var exp_p: List[Int] = [0, 1, -1]
    _assert_pairs_exact(
        build_matches, probe_matches, exp_b, exp_p,
        "FULL (trailing sentinel, NULL-keyed tail)",
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_inner_serial_reads_correct_build_row]()
    suite.test[test_inner_parallel_reads_correct_build_row]()
    suite.test[test_left_reads_correct_build_row]()
    suite.test[test_semi_finds_matches]()
    suite.test[test_anti_excludes_matches]()
    suite.test[test_right_pair_multiset]()
    suite.test[test_full_pair_multiset]()
    suite.test[test_right_preserves_trailing_sentinel_build_row]()
    suite.test[test_full_preserves_trailing_sentinel_build_row]()
    suite^.run()
