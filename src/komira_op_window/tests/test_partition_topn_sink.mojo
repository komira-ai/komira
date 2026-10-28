# =============================================================================
# test_partition_topn_sink -- PartitionTopNSink against the window operator
# =============================================================================
#
# The per-partition top-K is ROW_NUMBER() or RANK() OVER (PARTITION BY p
# ORDER BY o) filtered to at most k. Every case below runs the sink and the
# window operator of this package (`_execute_partition_by_sink`, whose
# partition and order semantics are tested on their own) over the same rows
# and compares the kept rows as a multiset, on the compact path (one INT32 /
# INT64 partition key, one numeric order key, no NULL) and the generic path.
# Cases: ties within and across k (ROW_NUMBER's rows among equal keys are
# the window's, in input order), a heap too small for its ties (the RANK
# fallback), NULL partition and order keys, NaN / +inf / -0.0 order keys, an
# `Int64.MIN` partition key, the rank column, k = 0, k past the partition
# size, an empty batch, and a float sort key's -0.0 coming back as 0.0.
# =============================================================================

from std.collections import Dict
from std.math import inf
from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_column_kernels.compiler_helpers import copy_batch, gather_batch
from komira_physical_plan.physical_plan import PartitionBySinkData, PartitionTopNSinkData
from komira_plan_expr.partition_expr import (
    PF_RANK,
    PF_ROW_NUMBER,
    PartitionExpr,
    partition_expr_output_field,
)

from komira_op_window.partition_scan_sink import _execute_partition_by_sink
from komira_op_window.partition_topn_sink import PartitionTopNSink


# =============================================================================
# Fixtures
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
    return Column.from_primitive[DType.float64](PrimitiveArray[DType.float64].from_list(l))


def _all(n: Int) -> List[Bool]:
    var v = List[Bool]()
    for _ in range(n):
        v.append(True)
    return v^


def _gov(var g: Column[HeapRegion], var o: Column[HeapRegion], n: Int) raises -> RecordBatch:
    """(g, o, v = row index)."""
    var v = List[Int64]()
    for i in range(n):
        v.append(Int64(i))
    var sb = SchemaBuilder()
    sb.add_field(Field("g", g.arrow_type, True))
    sb.add_field(Field("o", o.arrow_type, True))
    sb.add_field(Field("v", ArrowType.INT64, False))
    var bb = RecordBatchBuilder()
    bb.add_column(g^)
    bb.add_column(o^)
    bb.add_column(_i64(v, _all(n)))
    return bb.build(sb.build())


def _copy_schema(s: Schema) raises -> Schema:
    var sb = SchemaBuilder()
    for i in range(s.num_columns()):
        sb.add_field(s.field_at(i))
    return sb.build()


def _topn(
    batch: RecordBatch, k: Int, func: UInt8, desc: Bool,
    over_fetch: Int = -1, rk: Bool = False,
) raises -> RecordBatch:
    var pk: List[String] = ["g"]
    var ok: List[String] = ["o"]
    var dl: List[Bool] = [desc]
    var name: Optional[String] = None
    if rk:
        name = String("rk")
    var spec = PartitionTopNSinkData(
        pk^, ok^, dl^, k, _copy_schema(batch.schema), func, over_fetch, name^
    )
    var sink = PartitionTopNSink(spec^)
    sink.ingest_prebuilt(copy_batch(batch))
    sink.combine()
    return sink.take_output()


def _window_filtered(batch: RecordBatch, k: Int, func: UInt8, desc: Bool) raises -> RecordBatch:
    """ROW_NUMBER / RANK over (PARTITION BY g ORDER BY o) through the window
    operator, the rows with a number at most k."""
    var exprs = List[PartitionExpr]()
    if func == PF_RANK:
        exprs.append(PartitionExpr.rank())
    else:
        exprs.append(PartitionExpr.row_number())
    var sb = SchemaBuilder()
    for i in range(batch.schema.num_columns()):
        sb.add_field(batch.schema.field_at(i))
    sb.add_field(partition_expr_output_field(exprs[0], batch.schema, 0))
    var pk: List[String] = ["g"]
    var ok: List[String] = ["o"]
    var dl: List[Bool] = [desc]
    var out = _execute_partition_by_sink(
        copy_batch(batch), PartitionBySinkData(pk^, ok^, dl^, exprs^, sb.build())
    )
    var keep = List[Int]()
    ref rcol = out.column_at(3)
    for r in range(out.num_rows()):
        if rcol._data.get_typed[Scalar[DType.int64]](rcol._offset + r) <= Int64(k):
            keep.append(r)
    return gather_batch(out, keep)


def _cell(rb: RecordBatch, c: Int, r: Int) -> String:
    ref col = rb.column_at(c)
    if col.is_null_at(r):
        return String("N")
    if col.arrow_type == ArrowType.FLOAT64:
        var bits = bitcast[DType.uint64](col._data.get_typed[Scalar[DType.float64]](col._offset + r))
        return String(bits)
    if col.arrow_type == ArrowType.STRING:
        return String("s")
    return String(col._data.get_typed[Scalar[DType.int64]](col._offset + r))


def _row_key(rb: RecordBatch, r: Int) raises -> String:
    """(o, v): v is unique, o pins the order key's bits."""
    return _cell(rb, 1, r) + "|" + _cell(rb, 2, r)


def _assert_same_rows(got: RecordBatch, want: RecordBatch, label: String) raises:
    assert_equal(got.num_rows(), want.num_rows(), label + ": row count")
    var counts = Dict[String, Int]()
    for r in range(want.num_rows()):
        var key = _row_key(want, r)
        counts[key] = counts.get(key, 0) + 1
    for r in range(got.num_rows()):
        var key = _row_key(got, r)
        var c = counts.get(key, 0)
        assert_true(c > 0, label + ": unexpected row " + key)
        counts[key] = c - 1


def _check_both(batch: RecordBatch, k: Int, func: UInt8, desc: Bool, label: String, over_fetch: Int = -1) raises:
    _assert_same_rows(
        _topn(batch, k, func, desc, over_fetch), _window_filtered(batch, k, func, desc), label
    )


# =============================================================================
# Tests
# =============================================================================


def test_compact_and_generic_match_the_window() raises:
    # 600 rows, 12 partitions, scores with ties: (r * 37) % 50.
    var n = 600
    var g = List[Int64]()
    var o = List[Int64]()
    var gs = List[String]()
    for r in range(n):
        g.append(Int64((r * 7919) % 12))
        o.append(Int64((r * 37) % 50))
        gs.append(String("p") + String((r * 7919) % 12))
    var compact = _gov(_i64(g, _all(n)), _i64(o, _all(n)), n)
    var generic = _gov(Column.from_string(StringArray.from_strings(gs)), _i64(o, _all(n)), n)
    for k in [1, 3, 10, 60]:
        for d in range(2):
            _check_both(compact, k, PF_RANK, d == 1, "compact rank k=" + String(k))
            _check_both(generic, k, PF_RANK, d == 1, "generic rank k=" + String(k))
    # ROW_NUMBER compared on a tie-free order key (o2 = row index).
    var o2 = List[Int64]()
    for r in range(n):
        o2.append(Int64((r * 101) % n))
    var c2 = _gov(_i64(g, _all(n)), _i64(o2, _all(n)), n)
    for k in [1, 5, 100]:
        _check_both(c2, k, PF_ROW_NUMBER, False, "compact row_number")
        _check_both(c2, k, PF_ROW_NUMBER, True, "compact row_number desc")


def test_row_number_ties_keep_the_earliest_rows_like_the_window() raises:
    # Only 5 distinct order keys over 600 rows: every partition is ties, so
    # ROW_NUMBER <= k picks among equal keys. The window operator numbers
    # equal keys in input order, and the sink must keep exactly those rows
    # (the rows are compared with their unique `v`) on the heap path and on
    # the sort path, ascending and descending.
    var n = 600
    var g = List[Int64]()
    var o = List[Int64]()
    var gs = List[String]()
    for r in range(n):
        g.append(Int64((r * 7919) % 12))
        o.append(Int64((r * 37 + r // 7) % 5))
        gs.append(String("p") + String((r * 7919) % 12))
    var compact = _gov(_i64(g, _all(n)), _i64(o, _all(n)), n)
    var generic = _gov(Column.from_string(StringArray.from_strings(gs)), _i64(o, _all(n)), n)
    for k in [1, 3, 10, 60]:
        for d in range(2):
            _check_both(compact, k, PF_ROW_NUMBER, d == 1, "compact row k=" + String(k))
            _check_both(generic, k, PF_ROW_NUMBER, d == 1, "generic row k=" + String(k))


def test_row_number_keeps_the_earlier_of_two_tied_rows() raises:
    # One partition, k = 2. ASC o = 5 5 4: the stable order is r2, r0, r1, so
    # r0 stays and r1 goes (a heap that evicted by key alone could drop
    # either 5 when r2 arrives). DESC o = 4 4 5 is the mirror case.
    var g: List[Int64] = [1, 1, 1]
    var asc: List[Int64] = [5, 5, 4]
    var desc: List[Int64] = [4, 4, 5]
    _check_both(_gov(_i64(g, _all(3)), _i64(asc, _all(3)), 3), 2, PF_ROW_NUMBER, False, "asc")
    _check_both(_gov(_i64(g, _all(3)), _i64(desc, _all(3)), 3), 2, PF_ROW_NUMBER, True, "desc")
    # Pin the answer itself, not only the window's: the kept rows' v are 2, 0.
    var out = _topn(_gov(_i64(g, _all(3)), _i64(asc, _all(3)), 3), 2, PF_ROW_NUMBER, False)
    assert_equal(out.num_rows(), 2)
    var vs = List[String]()
    for r in range(2):
        vs.append(_cell(out, 2, r))
    assert_true((vs[0] == "2" and vs[1] == "0") or (vs[0] == "0" and vs[1] == "2"))
    assert_true(_cell(out, 2, 0) != "1" and _cell(out, 2, 1) != "1")


def test_rank_ties_past_the_heap() raises:
    # One partition, scores 1, 2 x 30, 3: RANK <= 2 keeps 31 rows. With an
    # over-fetch heap of 4 the ties overflow it and the partition is
    # recomputed from every row.
    var o: List[Int64] = [1]
    for _ in range(30):
        o.append(2)
    o.append(3)
    var n = len(o)
    var g = List[Int64]()
    for _ in range(n):
        g.append(Int64(5))
    var b = _gov(_i64(g, _all(n)), _i64(o, _all(n)), n)
    var out = _topn(b, 2, PF_RANK, False, 4)
    assert_equal(out.num_rows(), 31)
    _check_both(b, 2, PF_RANK, False, "rank overflow", 4)


def test_null_partition_and_order_keys() raises:
    # g holds NULLs whose slots collide with real keys; o holds NULLs. The
    # compact schema falls back to the generic path for this batch.
    var g: List[Int64] = [1, 1, 2, 1, 2, 2, 7, 1]
    var gv: List[Bool] = [True, False, True, True, False, True, True, False]
    var o: List[Int64] = [5, 4, 3, 9, 2, 8, 1, 6]
    var ov: List[Bool] = [True, True, False, True, True, True, True, False]
    var b = _gov(_i64(g, gv), _i64(o, ov), 8)
    for d in range(2):
        for k in [1, 2, 3]:
            _check_both(b, k, PF_RANK, d == 1, "nulls rank")
    # ROW_NUMBER k=2 ASC: g=1: o 5, 9; g=2: o 8, NULL (NULL last); g=7: o 1;
    # g=NULL: o 2, 4 (the NULL-o row is last).
    var out = _topn(b, 2, PF_ROW_NUMBER, False)
    assert_equal(out.num_rows(), 7)
    _check_both(b, 2, PF_ROW_NUMBER, False, "nulls row_number")


def test_nan_inf_and_signed_zero_order_keys() raises:
    # Two partitions of floats with NaN (two payloads), +inf, -0.0, +0.0.
    var nan_a = Float64(0.0) / Float64(0.0)
    var nan_b = bitcast[DType.float64](UInt64(0x7FF8000000000001))
    var o: List[Float64] = [nan_a, 1.0, inf[DType.float64](), -0.0, 0.0, nan_b, -1.0, 0.0]
    var g: List[Int64] = [1, 1, 1, 1, 1, 1, 2, 2]
    var b = _gov(_i64(g, _all(8)), _f64(o), 8)
    for d in range(2):
        for k in [1, 2, 3, 5]:
            _check_both(b, k, PF_RANK, d == 1, "float rank")
    # DESC top 1 of g=1: both NaNs (they tie, NaN above +inf).
    var out = _topn(b, 1, PF_RANK, True)
    var nans = 0
    for r in range(out.num_rows()):
        if _cell(out, 0, r) == "1":
            nans += 1
    assert_equal(nans, 2)
    # ASC RANK <= 1 of g=1: -0.0 and +0.0 tie, and both come back as 0.0.
    var asc = _topn(b, 1, PF_RANK, False)
    var zeros = 0
    for r in range(asc.num_rows()):
        if _cell(asc, 0, r) == "1":
            assert_equal(_cell(asc, 1, r), "0")
            zeros += 1
    assert_equal(zeros, 2)


def test_int64_min_partition_key_is_one_partition() raises:
    # Partition key Int64.MIN on three rows: ROW_NUMBER <= 1 keeps one of
    # them, not three.
    var g: List[Int64] = [Int64.MIN, 3, Int64.MIN, Int64.MIN, 3]
    var o: List[Int64] = [4, 2, 1, 9, 5]
    var b = _gov(_i64(g, _all(5)), _i64(o, _all(5)), 5)
    var out = _topn(b, 1, PF_ROW_NUMBER, False)
    assert_equal(out.num_rows(), 2)
    _check_both(b, 1, PF_ROW_NUMBER, False, "min key")


def test_rank_column_and_edges() raises:
    var g: List[Int64] = [1, 1, 1, 2]
    var o: List[Int64] = [3, 1, 1, 7]
    var b = _gov(_i64(g, _all(4)), _i64(o, _all(4)), 4)
    # RANK with the rank column: g=1 -> 1, 1, 3; g=2 -> 1.
    var out = _topn(b, 3, PF_RANK, False, -1, True)
    assert_equal(out.num_columns(), 4)
    var total = Int64(0)
    for r in range(out.num_rows()):
        ref rc = out.column_at(3)
        total += rc._data.get_typed[Scalar[DType.int64]](rc._offset + r)
    assert_equal(out.num_rows(), 4)
    assert_equal(total, 6)
    # k = 0 keeps nothing; k past every partition keeps everything; an empty
    # batch gives an empty result.
    assert_equal(_topn(b, 0, PF_ROW_NUMBER, False).num_rows(), 0)
    assert_equal(_topn(b, 10, PF_ROW_NUMBER, False).num_rows(), 4)
    var none: List[Int64] = []
    var empty = _gov(_i64(none, List[Bool]()), _i64(none, List[Bool]()), 0)
    assert_equal(_topn(empty, 3, PF_RANK, False).num_rows(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
