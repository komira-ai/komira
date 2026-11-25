# =============================================================================
# test_window_frame_index -- ROWS and RANGE frames with offsets, as row indices
# =============================================================================
#
# `frame_index` over batches already in window order (NULLs last in both
# directions unless a test passes NULLS FIRST, floats in DuckDB's order). Every expected `[lo, hi)` is derived
# by hand from docs/design/query_semantics.md §9.8 and agrees with what DuckDB
# v1.5.6 answers for the same rows (the sum or count each frame gives is in
# the comment above each case):
#
#   test_rows_offsets_past_the_partition_frame_the_whole_partition
#                     9223372036854775807 PRECEDING .. FOLLOWING is the whole
#                     partition; offsets are clamped, so the lowest one cannot
#                     overflow either.
#   test_range_offsets_over_a_bigint_key_with_null_keys
#                     a NULL key frames over the NULL group, an UNBOUNDED bound
#                     stays the partition's edge, offset bounds of a non-NULL
#                     key never reach a NULL key, ascending and descending,
#                     two partitions.
#   test_range_offsets_over_a_bigint_key_with_leading_null_keys
#                     the same rules with the NULL group at the start of the
#                     partition (NULLS FIRST), ascending and descending.
#   test_range_offsets_over_a_double_key_with_nan_and_infinities
#                     NaN rows frame over the NaN group, an infinity plus or
#                     minus an offset is itself, ascending and descending.
#   test_range_offset_zero_makes_negative_and_positive_zero_peers
#   test_range_offsets_over_an_int32_key_widen_a_wide_offset
#                     an offset past 32 bits is measured in 64 bits.
#   test_range_bounds_that_leave_the_keys_type_raise_duckdbs_overflow_error
#                     INT64 subtraction and addition, INT32 for an offset that
#                     fits in 32 bits, INT64 for an INT32 key and a wide one;
#                     every start bound is checked before any end bound, so
#                     the row named is the one DuckDB names.
#   test_range_offsets_over_an_unmeasurable_key_or_key_count_raise
#   test_nth_value_past_int64s_top_is_null
#                     NTH_VALUE with n = 9223372036854775807 over frames that
#                     start past row 1 answers NULL rather than a row.
# =============================================================================

from std.math import inf, nan
from std.testing import TestSuite, assert_equal, assert_true

from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.record_batch import RecordBatch, RecordBatchBuilder
from arrow.schema import Field, SchemaBuilder
from arrow.string_array import StringArray
from byte_buffer.heap_region import HeapRegion
from physical_plan.physical_plan import PartitionBySinkData
from plan_expr.partition_expr import (
    FRAME_BOUND_CURRENT_ROW,
    FRAME_BOUND_FOLLOWING,
    FRAME_BOUND_PRECEDING,
    FRAME_BOUND_UNBOUNDED_FOLLOWING,
    FRAME_BOUND_UNBOUNDED_PRECEDING,
    FRAME_UNITS_RANGE,
    FRAME_UNITS_ROWS,
    PartitionExpr,
    PartitionFrame,
    partition_expr_output_field,
)

from op_window.partition_frame_index import frame_index
from op_window.partition_scan_sink import _execute_partition_by_sink


def _i64(vals: List[Int64], valid: List[Bool]) -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int64].allocate_nullable(len(vals))
    for i in range(len(vals)):
        arr.store[1](i, vals[i])
        if not valid[i]:
            arr._set_null(i)
    return Column.from_primitive[DType.int64](arr)


def _i32(vals: List[Int32]) -> Column[HeapRegion]:
    var l = List[Scalar[DType.int32]]()
    for v in vals:
        l.append(v)
    return Column.from_primitive[DType.int32](
        PrimitiveArray[DType.int32].from_list(l)
    )


def _f64(vals: List[Float64], valid: List[Bool]) -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.float64].allocate_nullable(len(vals))
    for i in range(len(vals)):
        arr.store[1](i, vals[i])
        if not valid[i]:
            arr._set_null(i)
    return Column.from_primitive[DType.float64](arr)


def _all_valid(n: Int) -> List[Bool]:
    var out = List[Bool]()
    for _ in range(n):
        out.append(True)
    return out^


def _one_column(name: String, var col: Column[HeapRegion]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(name, col.arrow_type, True))
    var bb = RecordBatchBuilder()
    bb.add_column(col^)
    return bb.build(sb.build())


def _range(start_tag: UInt8, start: Int64, end_tag: UInt8, end: Int64) -> PartitionFrame:
    return PartitionFrame(FRAME_UNITS_RANGE, start_tag, start, end_tag, end)


def _rows(start_tag: UInt8, start: Int64, end_tag: UInt8, end: Int64) -> PartitionFrame:
    return PartitionFrame(FRAME_UNITS_ROWS, start_tag, start, end_tag, end)


def _keys(name: String) -> List[String]:
    var out = List[String]()
    out.append(name)
    return out^


def _dirs(desc: Bool) -> List[Bool]:
    var out = List[Bool]()
    out.append(desc)
    return out^


def _expect(
    batch: RecordBatch,
    bounds: List[Int],
    desc: Bool,
    frame: PartitionFrame,
    lo: List[Int],
    hi: List[Int],
    label: String,
    nulls_first: List[Bool] = List[Bool](),
) raises:
    var fi = frame_index(
        batch, bounds, _keys("k"), _dirs(desc), frame, nulls_first
    )
    assert_equal(len(fi.lo), len(lo), label + ": rows")
    for r in range(len(lo)):
        assert_equal(fi.lo[r], lo[r], label + ": lo at row " + String(r))
        assert_equal(fi.hi[r], hi[r], label + ": hi at row " + String(r))


def _raises(
    batch: RecordBatch,
    keys: List[String],
    desc: Bool,
    frame: PartitionFrame,
    message: String,
) raises:
    var raised = False
    try:
        _ = frame_index(batch, [0], keys, _dirs(desc), frame)
    except e:
        raised = True
        assert_equal(String(e), message)
    assert_true(raised, "expected the error: " + message)


def test_rows_offsets_past_the_partition_frame_the_whole_partition() raises:
    var batch = _one_column("k", _i64([1, 2, 3, 4, 5], _all_valid(5)))
    var top = Int64.MAX
    # DuckDB: sum(x) over ROWS BETWEEN 9223372036854775807 PRECEDING AND
    # 9223372036854775807 FOLLOWING is every row's partition total.
    _expect(
        batch, [0], False,
        _rows(FRAME_BOUND_PRECEDING, top, FRAME_BOUND_FOLLOWING, top),
        [0, 0, 0, 0, 0], [5, 5, 5, 5, 5], "rows, widest offsets",
    )
    # The kernel takes a negative offset the other way round (lowering
    # refuses one, so no SQL frame brings it here): `-1 PRECEDING` is the row
    # after, a frame that starts past its end and is empty.
    _expect(
        batch, [0], False,
        _rows(FRAME_BOUND_PRECEDING, -1, FRAME_BOUND_CURRENT_ROW, 0),
        [1, 2, 3, 4, 5], [1, 2, 3, 4, 5], "rows, -1 PRECEDING",
    )
    # The lowest offset is clamped too, so nothing overflows.
    _expect(
        batch, [0], False,
        _rows(FRAME_BOUND_PRECEDING, Int64.MIN, FRAME_BOUND_UNBOUNDED_FOLLOWING, 0),
        [5, 5, 5, 5, 5], [5, 5, 5, 5, 5], "rows, the lowest offset",
    )


def test_range_offsets_over_a_bigint_key_with_null_keys() raises:
    # Partition 0 sorted ascending: k = 1, 2, 4, 5, NULL, NULL with
    # x = 10, 20, 50, NULL, 30, 40; partition 1: k = 3, NULL.
    var v = _all_valid(8)
    v[4] = False
    v[5] = False
    v[7] = False
    var batch = _one_column("k", _i64([1, 2, 4, 5, 0, 0, 3, 0], v))
    var bounds: List[Int] = [0, 6]
    # 1 PRECEDING AND 1 FOLLOWING: DuckDB sums 30, 30, 50, 50, 70, 70.
    _expect(
        batch, bounds, False,
        _range(FRAME_BOUND_PRECEDING, 1, FRAME_BOUND_FOLLOWING, 1),
        [0, 0, 2, 2, 4, 4, 6, 7], [2, 2, 4, 4, 6, 6, 7, 8], "1 P .. 1 F",
    )
    # 3 FOLLOWING AND 5 FOLLOWING: 50, NULL, NULL, NULL, 70, 70.
    _expect(
        batch, bounds, False,
        _range(FRAME_BOUND_FOLLOWING, 3, FRAME_BOUND_FOLLOWING, 5),
        [2, 3, 4, 4, 4, 4, 7, 7], [4, 4, 4, 4, 6, 6, 7, 8], "3 F .. 5 F",
    )
    # UNBOUNDED PRECEDING AND 1 PRECEDING: NULL, 10, 30, 80, 150, 150 (the
    # NULL rows reach back to the partition's start).
    _expect(
        batch, bounds, False,
        _range(FRAME_BOUND_UNBOUNDED_PRECEDING, 0, FRAME_BOUND_PRECEDING, 1),
        [0, 0, 0, 0, 0, 0, 6, 6], [0, 1, 2, 3, 6, 6, 6, 8], "U P .. 1 P",
    )
    # 1 FOLLOWING AND UNBOUNDED FOLLOWING reaches the NULL rows.
    _expect(
        batch, bounds, False,
        _range(FRAME_BOUND_FOLLOWING, 1, FRAME_BOUND_UNBOUNDED_FOLLOWING, 0),
        [1, 2, 3, 4, 4, 4, 7, 7], [6, 6, 6, 6, 6, 6, 8, 8], "1 F .. U F",
    )
    # Descending: k = 5, 4, 2, 1, NULL, NULL with x = NULL, 50, 20, 10, 30, 40.
    var dv = _all_valid(6)
    dv[4] = False
    dv[5] = False
    var desc = _one_column("k", _i64([5, 4, 2, 1, 0, 0], dv))
    # 2 PRECEDING AND UNBOUNDED FOLLOWING: 150, 150, 150, 100, 70, 70.
    _expect(
        desc, [0], True,
        _range(FRAME_BOUND_PRECEDING, 2, FRAME_BOUND_UNBOUNDED_FOLLOWING, 0),
        [0, 0, 1, 2, 4, 4], [6, 6, 6, 6, 6, 6], "desc 2 P .. U F",
    )
    # 1 PRECEDING AND CURRENT ROW: NULL, 50, 20, 30, 70, 70.
    _expect(
        desc, [0], True,
        _range(FRAME_BOUND_PRECEDING, 1, FRAME_BOUND_CURRENT_ROW, 0),
        [0, 0, 2, 2, 4, 4], [1, 2, 3, 4, 6, 6], "desc 1 P .. CR",
    )


def test_range_offsets_over_a_bigint_key_with_leading_null_keys() raises:
    # NULLS FIRST ascending. Partition 0: k = NULL, NULL, 1, 2, 4, 5;
    # partition 1: k = NULL, 3. The NULL group leads each partition.
    var nf = _dirs(True)
    var v = _all_valid(8)
    v[0] = False
    v[1] = False
    v[6] = False
    var batch = _one_column("k", _i64([0, 0, 1, 2, 4, 5, 0, 3], v))
    var bounds: List[Int] = [0, 6]
    # 1 PRECEDING AND 1 FOLLOWING: a NULL row frames the NULL group; a key
    # frames the non-NULL keys within one of it.
    _expect(
        batch, bounds, False,
        _range(FRAME_BOUND_PRECEDING, 1, FRAME_BOUND_FOLLOWING, 1),
        [0, 0, 2, 2, 4, 4, 6, 7], [2, 2, 4, 4, 6, 6, 7, 8],
        "nulls first 1 P .. 1 F", nf,
    )
    # 3 FOLLOWING AND 5 FOLLOWING: keys 1 and 2 see keys 4 and 5, key 4 and 5
    # and the other partition's key 3 see no row; the NULL rows keep the NULL
    # group.
    _expect(
        batch, bounds, False,
        _range(FRAME_BOUND_FOLLOWING, 3, FRAME_BOUND_FOLLOWING, 5),
        [0, 0, 4, 5, 6, 6, 6, 8], [2, 2, 6, 6, 6, 6, 7, 8],
        "nulls first 3 F .. 5 F", nf,
    )
    # UNBOUNDED PRECEDING AND 1 PRECEDING: the start reaches the partition's
    # start, NULL rows included; the end of the smallest key is the end of
    # the NULL group, since no non-NULL key lies below it.
    _expect(
        batch, bounds, False,
        _range(FRAME_BOUND_UNBOUNDED_PRECEDING, 0, FRAME_BOUND_PRECEDING, 1),
        [0, 0, 0, 0, 0, 0, 6, 6], [2, 2, 2, 3, 4, 5, 7, 7],
        "nulls first U P .. 1 P", nf,
    )
    # 1 FOLLOWING AND UNBOUNDED FOLLOWING: a NULL row starts at the NULL
    # group and ends at the partition's end.
    _expect(
        batch, bounds, False,
        _range(FRAME_BOUND_FOLLOWING, 1, FRAME_BOUND_UNBOUNDED_FOLLOWING, 0),
        [0, 0, 3, 4, 5, 6, 6, 8], [6, 6, 6, 6, 6, 6, 8, 8],
        "nulls first 1 F .. U F", nf,
    )
    # 0 PRECEDING AND 0 FOLLOWING is each row's peer group, the NULLs
    # included.
    var pv = _all_valid(5)
    pv[0] = False
    pv[1] = False
    var peers = _one_column("k", _i64([0, 0, 1, 1, 3], pv))
    _expect(
        peers, [0], False,
        _range(FRAME_BOUND_PRECEDING, 0, FRAME_BOUND_FOLLOWING, 0),
        [0, 0, 2, 2, 4], [2, 2, 4, 4, 5], "nulls first 0 P .. 0 F", nf,
    )
    # Descending NULLS FIRST: k = NULL, NULL, 5, 4, 2, 1.
    var dv = _all_valid(6)
    dv[0] = False
    dv[1] = False
    var desc = _one_column("k", _i64([0, 0, 5, 4, 2, 1], dv))
    _expect(
        desc, [0], True,
        _range(FRAME_BOUND_PRECEDING, 2, FRAME_BOUND_UNBOUNDED_FOLLOWING, 0),
        [0, 0, 2, 2, 3, 4], [6, 6, 6, 6, 6, 6],
        "nulls first desc 2 P .. U F", nf,
    )
    _expect(
        desc, [0], True,
        _range(FRAME_BOUND_PRECEDING, 1, FRAME_BOUND_CURRENT_ROW, 0),
        [0, 0, 2, 2, 4, 4], [2, 2, 3, 4, 5, 6],
        "nulls first desc 1 P .. CR", nf,
    )
    # An explicit NULLS LAST on a descending key is the derived placement.
    var last = _one_column("k", _i64([5, 4, 0], [True, True, False]))
    _expect(
        last, [0], True,
        _range(FRAME_BOUND_PRECEDING, 1, FRAME_BOUND_CURRENT_ROW, 0),
        [0, 0, 2], [1, 2, 3], "nulls last desc 1 P .. CR", _dirs(False),
    )


def test_range_offsets_over_a_double_key_with_nan_and_infinities() raises:
    # Ascending: k = -inf, 1.0, 2.5, inf, NaN, NaN, NULL with
    # x = 70, 10, 50, 60, 20, 30, 40.
    var v = _all_valid(7)
    v[6] = False
    var asc = _one_column(
        "k",
        _f64([-inf[DType.float64](), 1.0, 2.5, inf[DType.float64](),
              nan[DType.float64](), nan[DType.float64](), 0.0], v),
    )
    # 1 PRECEDING AND 1 FOLLOWING: 70, 10, 50, 60, 50, 50, 40.
    _expect(
        asc, [0], False,
        _range(FRAME_BOUND_PRECEDING, 1, FRAME_BOUND_FOLLOWING, 1),
        [0, 1, 2, 3, 4, 4, 6], [1, 2, 3, 4, 6, 6, 7], "1 P .. 1 F",
    )
    # UNBOUNDED PRECEDING AND 1 PRECEDING: 70, 70, 80, 190, 240, 240, 280.
    _expect(
        asc, [0], False,
        _range(FRAME_BOUND_UNBOUNDED_PRECEDING, 0, FRAME_BOUND_PRECEDING, 1),
        [0, 0, 0, 0, 0, 0, 0], [1, 1, 2, 4, 6, 6, 7], "U P .. 1 P",
    )
    # 1 FOLLOWING AND UNBOUNDED FOLLOWING: 280, 200, 150, 150, 90, 90, 40.
    _expect(
        asc, [0], False,
        _range(FRAME_BOUND_FOLLOWING, 1, FRAME_BOUND_UNBOUNDED_FOLLOWING, 0),
        [0, 2, 3, 3, 4, 4, 6], [7, 7, 7, 7, 7, 7, 7], "1 F .. U F",
    )
    # Descending: k = NaN, NaN, inf, 2.5, 1.0, -inf, NULL.
    var desc = _one_column(
        "k",
        _f64([nan[DType.float64](), nan[DType.float64](), inf[DType.float64](),
              2.5, 1.0, -inf[DType.float64](), 0.0], v),
    )
    # 1 PRECEDING AND 1 FOLLOWING: 50, 50, 60, 50, 10, 70, 40.
    _expect(
        desc, [0], True,
        _range(FRAME_BOUND_PRECEDING, 1, FRAME_BOUND_FOLLOWING, 1),
        [0, 0, 2, 3, 4, 5, 6], [2, 2, 3, 4, 5, 6, 7], "desc 1 P .. 1 F",
    )


def test_range_offset_zero_makes_negative_and_positive_zero_peers() raises:
    # DuckDB: count(*) over RANGE BETWEEN CURRENT ROW AND CURRENT ROW is 2 on
    # -0.0 and on 0.0; 0 PRECEDING AND 0 FOLLOWING is the same frame.
    var batch = _one_column("k", _f64([-0.0, 0.0, 0.5], _all_valid(3)))
    _expect(
        batch, [0], False,
        _range(FRAME_BOUND_PRECEDING, 0, FRAME_BOUND_FOLLOWING, 0),
        [0, 0, 2], [2, 2, 3], "0 P .. 0 F",
    )


def test_range_offsets_over_an_int32_key_widen_a_wide_offset() raises:
    # k = -2147483648, 0, 2147483646, 2147483647 with x = 20, 30, 40, 10.
    var batch = _one_column(
        "k", _i32([Int32.MIN, 0, Int32.MAX - 1, Int32.MAX])
    )
    # 3000000000 PRECEDING AND CURRENT ROW: DuckDB sums 20, 50, 70, 80; the
    # bound is measured in BIGINT, so no row overflows INT32.
    _expect(
        batch, [0], False,
        _range(FRAME_BOUND_PRECEDING, 3000000000, FRAME_BOUND_CURRENT_ROW, 0),
        [0, 0, 1, 1], [1, 2, 3, 4], "3000000000 P .. CR",
    )
    # 2147483648 PRECEDING is the first offset past 32 bits: the same frames.
    _expect(
        batch, [0], False,
        _range(FRAME_BOUND_PRECEDING, 2147483648, FRAME_BOUND_CURRENT_ROW, 0),
        [0, 0, 1, 1], [1, 2, 3, 4], "2147483648 P .. CR",
    )
    # Descending, 2 PRECEDING AND CURRENT ROW adds 2: 2147483644 + 2 stays
    # inside INT32.
    var desc = _one_column("k", _i32([Int32.MAX - 3, Int32.MAX - 4, 0]))
    _expect(
        desc, [0], True,
        _range(FRAME_BOUND_PRECEDING, 2, FRAME_BOUND_CURRENT_ROW, 0),
        [0, 0, 2], [1, 2, 3], "desc 2 P .. CR",
    )


def test_range_bounds_that_leave_the_keys_type_raise_duckdbs_overflow_error() raises:
    var tail = ")! (the RANGE frame bound of the ORDER BY key 'k')"
    var head = String("partition_frame_index: Out of Range Error: Overflow in ")
    var low = _one_column("k", _i64([Int64.MIN, 1], _all_valid(2)))
    _raises(
        low, _keys("k"), False,
        _range(FRAME_BOUND_PRECEDING, 1, FRAME_BOUND_CURRENT_ROW, 0),
        head + "subtraction of INT64 (-9223372036854775808 - 1" + tail,
    )
    var high = _one_column("k", _i64([1, Int64.MAX], _all_valid(2)))
    _raises(
        high, _keys("k"), False,
        _range(FRAME_BOUND_CURRENT_ROW, 0, FRAME_BOUND_FOLLOWING, 1),
        head + "addition of INT64 (9223372036854775807 + 1" + tail,
    )
    # Descending, PRECEDING adds: the largest key overflows.
    var high_desc = _one_column("k", _i64([Int64.MAX, 1], _all_valid(2)))
    _raises(
        high_desc, _keys("k"), True,
        _range(FRAME_BOUND_PRECEDING, 1, FRAME_BOUND_CURRENT_ROW, 0),
        head + "addition of INT64 (9223372036854775807 + 1" + tail,
    )
    # A NULL key computes no bound: the same frame over a NULL and a key far
    # from the edge answers.
    var nulls = _all_valid(2)
    nulls[1] = False
    var safe = _one_column("k", _i64([5, Int64.MIN], nulls))
    _expect(
        safe, [0], False,
        _range(FRAME_BOUND_PRECEDING, 1, FRAME_BOUND_CURRENT_ROW, 0),
        [0, 1], [1, 2], "a NULL beside the edge value",
    )
    var i32 = _one_column("k", _i32([Int32.MIN, 0, Int32.MAX - 1, Int32.MAX]))
    _raises(
        i32, _keys("k"), False,
        _range(FRAME_BOUND_PRECEDING, 1, FRAME_BOUND_CURRENT_ROW, 0),
        head + "subtraction of INT32 (-2147483648 - 1" + tail,
    )
    _raises(
        i32, _keys("k"), False,
        _range(FRAME_BOUND_PRECEDING, 2147483647, FRAME_BOUND_CURRENT_ROW, 0),
        head + "subtraction of INT32 (-2147483648 - 2147483647" + tail,
    )
    _raises(
        i32, _keys("k"), False,
        _range(FRAME_BOUND_CURRENT_ROW, 0, FRAME_BOUND_FOLLOWING, 1),
        head + "addition of INT32 (2147483647 + 1" + tail,
    )
    # Start bounds first: 2147483642 + 10 would overflow as an end bound, but
    # DuckDB names the start bound 2147483647 + 1 of the row after it.
    var late = _one_column("k", _i32([Int32.MAX - 5, Int32.MAX]))
    _raises(
        late, _keys("k"), False,
        _range(FRAME_BOUND_FOLLOWING, 1, FRAME_BOUND_FOLLOWING, 10),
        head + "addition of INT32 (2147483647 + 1" + tail,
    )
    var late64 = _one_column("k", _i64([Int64.MAX - 10, Int64.MAX], _all_valid(2)))
    _raises(
        late64, _keys("k"), False,
        _range(FRAME_BOUND_FOLLOWING, 1, FRAME_BOUND_FOLLOWING, 20),
        head + "addition of INT64 (9223372036854775807 + 1" + tail,
    )
    _raises(
        i32, _keys("k"), False,
        _range(FRAME_BOUND_PRECEDING, Int64.MAX, FRAME_BOUND_CURRENT_ROW, 0),
        head + "subtraction of INT64 (-2147483648 - 9223372036854775807" + tail,
    )
    _raises(
        i32, _keys("k"), False,
        _range(FRAME_BOUND_CURRENT_ROW, 0, FRAME_BOUND_FOLLOWING, Int64.MAX),
        head + "addition of INT64 (2147483646 + 9223372036854775807" + tail,
    )
    # A negative offset moves a bound the other way, and DuckDB names the
    # operation the bound's direction asks for (lowering refuses negative
    # offsets; this is the kernel's arithmetic).
    _raises(
        high, _keys("k"), False,
        _range(FRAME_BOUND_PRECEDING, -1, FRAME_BOUND_UNBOUNDED_FOLLOWING, 0),
        head + "subtraction of INT64 (9223372036854775807 - -1" + tail,
    )
    _raises(
        low, _keys("k"), False,
        _range(FRAME_BOUND_UNBOUNDED_PRECEDING, 0, FRAME_BOUND_FOLLOWING, -1),
        head + "addition of INT64 (-9223372036854775808 + -1" + tail,
    )


def test_range_offsets_over_an_unmeasurable_key_or_key_count_raise() raises:
    var frame = _range(FRAME_BOUND_PRECEDING, 1, FRAME_BOUND_CURRENT_ROW, 0)
    var words: List[String] = ["a", "b"]
    var strings = _one_column("k", Column.from_string(StringArray.from_strings(words)))
    _raises(
        strings, _keys("k"), False, frame.copy(),
        "partition_frame_index: a RANGE frame with an offset needs an INT64,"
        " INT32 or FLOAT64 ORDER BY key; got " + String(strings.column_at(0).arrow_type),
    )
    var ints = _one_column("k", _i64([1, 2], _all_valid(2)))
    _raises(
        ints, List[String](), False, frame.copy(),
        "partition_frame_index: `RANGE BETWEEN <n> PRECEDING/FOLLOWING`"
        " measures its bound against the ORDER BY key, and this window has no"
        " ORDER BY; add one, or write the frame in ROWS",
    )
    var two: List[String] = ["k", "k"]
    _raises(
        ints, two, False, frame.copy(),
        "partition_frame_index: a RANGE frame with an offset needs exactly one"
        " ORDER BY key; this window has 2",
    )


def test_nth_value_past_int64s_top_is_null() raises:
    # DuckDB: nth_value(k, 9223372036854775807) OVER (ORDER BY k ROWS BETWEEN
    # CURRENT ROW AND UNBOUNDED FOLLOWING) is NULL on every row. The frames
    # start at rows 0 to 3, so `start + n - 1` leaves INT64 from row 2 on.
    var batch = _one_column("k", _i64([1, 2, 3, 4], _all_valid(4)))
    var exprs = List[PartitionExpr]()
    exprs.append(
        PartitionExpr.nth_value("k", Int(Int64.MAX)).with_frame(
            _rows(FRAME_BOUND_CURRENT_ROW, 0, FRAME_BOUND_UNBOUNDED_FOLLOWING, 0)
        )
    )
    var out_sb = SchemaBuilder()
    out_sb.add_field(batch.schema.field_at(0))
    out_sb.add_field(partition_expr_output_field(exprs[0], batch.schema, 0))
    var spec = PartitionBySinkData(
        List[String](), _keys("k"), _dirs(False), exprs^, out_sb.build()
    )
    var out = _execute_partition_by_sink(batch^, spec)
    for r in range(4):
        assert_true(out.column_at(1).is_null_at(r), "row " + String(r))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
