# =============================================================================
# test_window_partition_keys -- partition and order keys as DuckDB reads them
# =============================================================================
#
# Through `_execute_partition_by_sink`, the window over one batch. Expected
# rows are derived by hand from docs/design/query_semantics.md: §4.1 (NULLs
# last in both directions), §4.3 (NaN above +inf, every NaN equal), §4.4
# (-0.0 equals +0.0), §4.9 (a float ORDER BY key comes back with -0.0 as 0.0),
# §9.7 (NULL order keys are peers), §9.9 (NULL partition keys form one
# partition).
#
# Every NULL slot below holds a value that collides with a real key, so a
# kernel that reads the slot instead of the validity bit puts the row in the
# wrong partition or peer group.
# =============================================================================

from std.math import inf, isnan
from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_physical_plan.physical_plan import PartitionBySinkData
from komira_plan_expr.partition_expr import (
    FRAME_BOUND_UNBOUNDED_FOLLOWING,
    FRAME_BOUND_UNBOUNDED_PRECEDING,
    FRAME_UNITS_ROWS,
    PF_COUNT,
    PartitionExpr,
    PartitionFrame,
    partition_expr_output_field,
)

from komira_op_window.partition_scan_sink import _execute_partition_by_sink


# =============================================================================
# Fixture helpers
# =============================================================================


def _i64(vals: List[Int64], valid: List[Bool]) -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int64].allocate_nullable(len(vals))
    for i in range(len(vals)):
        arr.store[1](i, vals[i])
        if not valid[i]:
            arr._set_null(i)
    return Column.from_primitive[DType.int64](arr)


def _f64(vals: List[Float64]) -> Column[HeapRegion]:
    var l = List[Scalar[DType.float64]]()
    for v in vals:
        l.append(v)
    return Column.from_primitive[DType.float64](
        PrimitiveArray[DType.float64].from_list(l)
    )


def _all_valid(n: Int) -> List[Bool]:
    var v = List[Bool]()
    for _ in range(n):
        v.append(True)
    return v^


def _batch(names: List[String], var cols: List[Column[HeapRegion]]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    var bb = RecordBatchBuilder()
    for i in range(len(names)):
        sb.add_field(Field(names[i], cols[i].arrow_type, True))
    for i in range(len(cols)):
        bb.add_column(cols[i].share())
    return bb.build(sb.build())


def _sink(
    batch: RecordBatch,
    pkeys: List[String],
    okeys: List[String],
    desc: List[Bool],
    var exprs: List[PartitionExpr],
) raises -> PartitionBySinkData:
    var sb = SchemaBuilder()
    for i in range(batch.schema.num_columns()):
        sb.add_field(batch.schema.field_at(i))
    for i in range(len(exprs)):
        sb.add_field(partition_expr_output_field(exprs[i], batch.schema, i))
    return PartitionBySinkData(pkeys.copy(), okeys.copy(), desc.copy(), exprs^, sb.build())


def _run(
    var batch: RecordBatch,
    pkeys: List[String],
    okeys: List[String],
    desc: List[Bool],
    var exprs: List[PartitionExpr],
) raises -> RecordBatch:
    var spec = _sink(batch, pkeys, okeys, desc, exprs^)
    return _execute_partition_by_sink(batch^, spec)


def _get_i64(rb: RecordBatch, col: Int, row: Int) -> Int64:
    ref c = rb.column_at(col)
    return c._data.get_typed[Scalar[DType.int64]](c._offset + row)


def _get_f64(rb: RecordBatch, col: Int, row: Int) -> Float64:
    ref c = rb.column_at(col)
    return c._data.get_typed[Scalar[DType.float64]](c._offset + row)


def _null(rb: RecordBatch, col: Int, row: Int) -> Bool:
    return rb.column_at(col).is_null_at(row)


def _keys(*names: String) -> List[String]:
    var out = List[String]()
    for n in names:
        out.append(n)
    return out^


def _whole_partition_count_star() -> PartitionExpr:
    return PartitionExpr.agg_with_frame(
        PF_COUNT,
        String(""),
        PartitionFrame(
            FRAME_UNITS_ROWS,
            FRAME_BOUND_UNBOUNDED_PRECEDING, 0,
            FRAME_BOUND_UNBOUNDED_FOLLOWING, 0,
        ),
    )


# =============================================================================
# NULL partition keys: one partition, placed last (§9.9, §4.1)
# =============================================================================


def test_null_partition_key_is_one_partition_last() raises:
    # g: 1, NULL(slot 1), 1, NULL(slot 2), 2 ; o: 1..5
    # PARTITION BY g ORDER BY o, ROW_NUMBER:
    #   g=1: o=1 -> 1, o=3 -> 2; g=2: o=5 -> 1; g=NULL: o=2 -> 1, o=4 -> 2.
    var gv: List[Int64] = [1, 1, 1, 2, 2]
    var gvalid: List[Bool] = [True, False, True, False, True]
    var ov: List[Int64] = [1, 2, 3, 4, 5]
    var cols = List[Column[HeapRegion]]()
    cols.append(_i64(gv, gvalid))
    cols.append(_i64(ov, _all_valid(5)))
    var exprs = List[PartitionExpr]()
    exprs.append(PartitionExpr.row_number())
    var out = _run(
        _batch(_keys("g", "o"), cols^), _keys("g"), _keys("o"), [False], exprs^
    )
    assert_equal(out.num_rows(), 5)
    var want_o: List[Int64] = [1, 3, 5, 2, 4]
    var want_rn: List[Int64] = [1, 2, 1, 1, 2]
    var want_g_null: List[Bool] = [False, False, False, True, True]
    for r in range(5):
        assert_equal(_get_i64(out, 1, r), want_o[r])
        assert_equal(_get_i64(out, 2, r), want_rn[r])
        assert_equal(_null(out, 0, r), want_g_null[r])


# =============================================================================
# NULL order keys: last in both directions, and peers of each other (§4.1, §9.7)
# =============================================================================


def _rank_over_nullable_o(desc: Bool) raises -> RecordBatch:
    # o: 3, NULL(slot 0), 1, NULL(slot 5)
    var ov: List[Int64] = [3, 0, 1, 5]
    var ovalid: List[Bool] = [True, False, True, False]
    var cols = List[Column[HeapRegion]]()
    cols.append(_i64(ov, ovalid))
    var exprs = List[PartitionExpr]()
    exprs.append(PartitionExpr.rank())
    exprs.append(PartitionExpr.dense_rank())
    return _run(
        _batch(_keys("o"), cols^), List[String](), _keys("o"), [desc], exprs^
    )


def test_null_order_key_last_ascending_and_peers() raises:
    # ASC: 1 (rank 1), 3 (rank 2), NULL, NULL (both rank 3, dense 3).
    var out = _rank_over_nullable_o(False)
    assert_equal(_get_i64(out, 0, 0), 1)
    assert_equal(_get_i64(out, 0, 1), 3)
    assert_true(_null(out, 0, 2) and _null(out, 0, 3))
    var want_rank: List[Int64] = [1, 2, 3, 3]
    var want_dense: List[Int64] = [1, 2, 3, 3]
    for r in range(4):
        assert_equal(_get_i64(out, 1, r), want_rank[r])
        assert_equal(_get_i64(out, 2, r), want_dense[r])


def test_null_order_key_last_descending() raises:
    # DESC: 3 (rank 1), 1 (rank 2), then the NULLs (rank 3): NULLS LAST holds
    # for DESC too.
    var out = _rank_over_nullable_o(True)
    assert_equal(_get_i64(out, 0, 0), 3)
    assert_equal(_get_i64(out, 0, 1), 1)
    assert_true(_null(out, 0, 2) and _null(out, 0, 3))
    assert_equal(_get_i64(out, 1, 2), 3)
    assert_equal(_get_i64(out, 1, 3), 3)


def test_null_first_key_keeps_second_key_order() raises:
    # ORDER BY a DESC, b ASC with a NULL in `a`: the NULL-a rows come last
    # and, among themselves, in `b` order (their NULL slots hold 9 and 1, the
    # reverse of `b`).
    #   a: 5, NULL(9), 7, NULL(1) ; b: 1, 2, 3, 1
    #   -> (7,3) (5,1) (NULL,1) (NULL,2)
    var av: List[Int64] = [5, 9, 7, 1]
    var avalid: List[Bool] = [True, False, True, False]
    var bv: List[Int64] = [1, 2, 3, 1]
    var cols = List[Column[HeapRegion]]()
    cols.append(_i64(av, avalid))
    cols.append(_i64(bv, _all_valid(4)))
    var exprs = List[PartitionExpr]()
    exprs.append(PartitionExpr.row_number())
    var out = _run(
        _batch(_keys("a", "b"), cols^), List[String](), _keys("a", "b"),
        [True, False], exprs^,
    )
    assert_equal(_get_i64(out, 0, 0), 7)
    assert_equal(_get_i64(out, 0, 1), 5)
    assert_true(_null(out, 0, 2) and _null(out, 0, 3))
    assert_equal(_get_i64(out, 1, 2), 1)
    assert_equal(_get_i64(out, 1, 3), 2)


# =============================================================================
# Float keys: NaN is one value above +inf, -0.0 equals +0.0 (§2.6, §4.3, §4.4)
# =============================================================================


def test_nan_and_signed_zero_partition_keys() raises:
    # g: NaN (0/0, sign bit set on x86), 1.0, NaN (other payload), 0.0, -0.0
    # Partitions: {0.0, -0.0} (2 rows), {1.0} (1 row), {NaN, NaN} (2 rows),
    # in that order. COUNT(*) over the whole partition.
    var nan_a = Float64(0.0) / Float64(0.0)
    var nan_b = bitcast[DType.float64](UInt64(0x7FF8000000000001))
    var gl: List[Float64] = [nan_a, 1.0, nan_b, 0.0, -0.0]
    var ol: List[Int64] = [1, 2, 3, 4, 5]
    var cols = List[Column[HeapRegion]]()
    cols.append(_f64(gl))
    cols.append(_i64(ol, _all_valid(5)))
    var exprs = List[PartitionExpr]()
    exprs.append(_whole_partition_count_star())
    var out = _run(
        _batch(_keys("g", "o"), cols^), _keys("g"), _keys("o"), [False], exprs^
    )
    var want_cnt: List[Int64] = [2, 2, 1, 2, 2]
    var want_o: List[Int64] = [4, 5, 2, 1, 3]
    for r in range(5):
        assert_equal(_get_i64(out, 2, r), want_cnt[r])
        assert_equal(_get_i64(out, 1, r), want_o[r])
    assert_true(isnan(_get_f64(out, 0, 3)) and isnan(_get_f64(out, 0, 4)))


def test_nan_order_key_above_inf_and_peers() raises:
    # o: NaN, +inf, 1.0, NaN(other payload). RANK ASC: 1.0 -> 1, +inf -> 2,
    # NaN, NaN -> 3, 3. RANK DESC: NaN, NaN -> 1, 1, +inf -> 3, 1.0 -> 4.
    var nan_b = bitcast[DType.float64](UInt64(0x7FF8000000000001))
    for d in range(2):
        var cols = List[Column[HeapRegion]]()
        var ol4: List[Float64] = [Float64(0.0) / Float64(0.0), inf[DType.float64](), 1.0, nan_b]
        cols.append(_f64(ol4))
        var exprs = List[PartitionExpr]()
        exprs.append(PartitionExpr.rank())
        var out = _run(
            _batch(_keys("o"), cols^), List[String](), _keys("o"), [d == 1], exprs^
        )
        if d == 0:
            assert_equal(_get_f64(out, 0, 0), 1.0)
            assert_equal(_get_f64(out, 0, 1), inf[DType.float64]())
            var want: List[Int64] = [1, 2, 3, 3]
            for r in range(4):
                assert_equal(_get_i64(out, 1, r), want[r])
        else:
            assert_true(isnan(_get_f64(out, 0, 0)) and isnan(_get_f64(out, 0, 1)))
            var want_d: List[Int64] = [1, 1, 3, 4]
            for r in range(4):
                assert_equal(_get_i64(out, 1, r), want_d[r])


def test_signed_zero_order_key_ties_and_comes_back_positive() raises:
    # o: 0.0, -0.0, 1.0 ; RANK ASC: 1, 1, 3. The sorted ORDER BY key column
    # comes back with -0.0 written as 0.0 (§4.9); a carried float column
    # keeps its -0.0.
    var cols = List[Column[HeapRegion]]()
    cols.append(_f64([0.0, -0.0, 1.0]))
    cols.append(_f64([-0.0, -0.0, -0.0]))
    var exprs = List[PartitionExpr]()
    exprs.append(PartitionExpr.rank())
    var out = _run(
        _batch(_keys("o", "carried"), cols^), List[String](), _keys("o"),
        [False], exprs^,
    )
    var want: List[Int64] = [1, 1, 3]
    for r in range(3):
        assert_equal(_get_i64(out, 2, r), want[r])
        assert_equal(
            bitcast[DType.uint64](_get_f64(out, 1, r)), UInt64(0x8000000000000000)
        )
    for r in range(2):
        assert_equal(bitcast[DType.uint64](_get_f64(out, 0, r)), UInt64(0))


# =============================================================================
# A dictionary ORDER BY key sorts by value, not by code
# =============================================================================


def test_dictionary_order_key_sorts_by_value() raises:
    # Dictionary ["pear", "apple", "fig"], codes [0, 1, 2, 1] = pear, apple,
    # fig, apple. ORDER BY s: apple, apple, fig, pear; RANK 1, 1, 3, 4. By
    # code the order would be pear first.
    var codes: List[Scalar[DType.int32]] = [0, 1, 2, 1]
    var entries = List[String]()
    entries.append("pear")
    entries.append("apple")
    entries.append("fig")
    var dict_col = Column.from_dictionary(
        StringDictionaryArray.from_parts(
            PrimitiveArray[DType.int32].from_list(codes),
            StringArray.from_strings(entries),
        )
    )
    var cols = List[Column[HeapRegion]]()
    cols.append(dict_col^)
    var vv: List[Int64] = [10, 20, 30, 40]
    cols.append(_i64(vv, _all_valid(4)))
    var exprs = List[PartitionExpr]()
    exprs.append(PartitionExpr.rank())
    var out = _run(
        _batch(_keys("s", "v"), cols^), List[String](), _keys("s"),
        [False], exprs^,
    )
    var want_v: List[Int64] = [20, 40, 30, 10]
    var want_rank: List[Int64] = [1, 1, 3, 4]
    for r in range(4):
        assert_equal(_get_i64(out, 1, r), want_v[r])
        assert_equal(_get_i64(out, 2, r), want_rank[r])


def test_empty_input_keeps_output_schema() raises:
    # A window over zero rows answers zero rows with the output schema's
    # columns (the input columns and one per function), not an error.
    var cols = List[Column[HeapRegion]]()
    var none: List[Int64] = []
    var none_valid: List[Bool] = []
    cols.append(_i64(none, none_valid))
    var exprs = List[PartitionExpr]()
    exprs.append(PartitionExpr.row_number())
    exprs.append(PartitionExpr.lag("o"))
    var out = _run(
        _batch(_keys("o"), cols^), List[String](), _keys("o"), [False], exprs^
    )
    assert_equal(out.num_rows(), 0)
    assert_equal(out.num_columns(), 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
