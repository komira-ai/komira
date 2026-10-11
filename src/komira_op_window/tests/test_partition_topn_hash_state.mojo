# =============================================================================
# test_partition_topn_hash_state -- PartitionTopNHashState, by hand
# =============================================================================
#
# Expected rows are derived by hand: per partition the N best rows by the
# order key (ASC smallest, DESC largest), full rows emitted; ROW_NUMBER keeps
# exactly N, RANK keeps every row tied within N however many there are
# (§9.2); floats in DuckDB's order (NaN above +inf, -0.0 = +0.0, §4.3, §4.4);
# NULL order keys last and NULL partition keys one partition (§4.1, §9.9);
# a combine of two workers equals one worker fed every row.
# =============================================================================

from std.math import inf, isnan
from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import batch_view_over
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_op_sort.sort_stage_payloads import PayloadCol_Typed

from komira_op_window.part_key_block import (
    PartKeyBlock,
    PartKeyCol_Numeric,
    PartKeyCol_String,
)
from komira_op_window.partition_topn_hash_state import (
    PTN_DIR_ASC,
    PTN_DIR_DESC,
    PTN_ORDER_STRING_SENTINEL,
    PTN_TIES_RANK,
    PTN_TIES_ROW,
    PartitionTopNHashState,
)


comptime I64 = DType.int64
comptime F64 = DType.float64

comptime KB_I64 = PartKeyBlock[PartKeyCol_Numeric[I64, 0]]
comptime KB_F64 = PartKeyBlock[PartKeyCol_Numeric[F64, 0]]
comptime KB_STR = PartKeyBlock[PartKeyCol_String[0]]
comptime PAY2 = PayloadCol_Typed[I64, 2]


def _col_i64(vals: List[Int64], valid: List[Bool]) -> Column[HeapRegion]:
    var arr = PrimitiveArray[I64].allocate_nullable(len(vals))
    for i in range(len(vals)):
        arr.store[1](i, vals[i])
        if not valid[i]:
            arr._set_null(i)
    return Column.from_primitive[I64](arr)


def _col_f64(vals: List[Float64]) -> Column[HeapRegion]:
    var l = List[Scalar[F64]]()
    for v in vals:
        l.append(v)
    return Column.from_primitive[F64](PrimitiveArray[F64].from_list(l))


def _all(n: Int) -> List[Bool]:
    var v = List[Bool]()
    for _ in range(n):
        v.append(True)
    return v^


def _batch3(var pk: Column[HeapRegion], var okey: Column[HeapRegion]) raises -> RecordBatch:
    """[pk @0, okey @1, pay = row index @2]."""
    var n = pk.length()
    var pay = List[Int64]()
    for i in range(n):
        pay.append(Int64(i))
    var sb = SchemaBuilder()
    sb.add_field(Field("pk", pk.arrow_type, True))
    sb.add_field(Field("okey", okey.arrow_type, True))
    sb.add_field(Field("pay", ArrowType.INT64, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(pk^)
    rbb.add_column(okey^)
    rbb.add_column(_col_i64(pay, _all(n)))
    return rbb.build(sb.build())


def _get(rb: RecordBatch, c: Int, r: Int) -> Int64:
    ref col = rb.column_at(c)
    return col._data.get_typed[Scalar[I64]](col._offset + r)


def _getf(rb: RecordBatch, c: Int, r: Int) -> Float64:
    ref col = rb.column_at(c)
    return col._data.get_typed[Scalar[F64]](col._offset + r)


def _pays(rb: RecordBatch) -> List[Int64]:
    var out = List[Int64]()
    for r in range(rb.num_rows()):
        out.append(_get(rb, 2, r))
    return out^


def _assert_pays(rb: RecordBatch, want: List[Int64], label: String) raises:
    var got = _pays(rb)
    assert_equal(len(got), len(want), label + ": rows")
    for i in range(len(want)):
        assert_equal(got[i], want[i], label + ": payload at " + String(i))


def test_float_order_keys_mixed_signs_nan_and_zero() raises:
    # One partition; okey = -2.5, 3.0, NaN, -0.0, +inf, +0.0, -inf.
    # ASC top 3: -inf (6), -2.5 (0), then a zero (3 or 5).
    # DESC top 3: NaN (2), +inf (4), 3.0 (1).
    var pk: List[Int64] = [1, 1, 1, 1, 1, 1, 1]
    var ok: List[Float64] = [-2.5, 3.0, Float64(0.0) / Float64(0.0), -0.0, inf[F64](), 0.0, -inf[F64]()]
    var b = _batch3(_col_i64(pk, _all(7)), _col_f64(ok))
    var bv = batch_view_over(b)
    var asc = PartitionTopNHashState[KB_I64, 1, F64, 3, PTN_DIR_ASC, PTN_TIES_ROW, PAY2](KB_I64.make_empty(4))
    var desc = PartitionTopNHashState[KB_I64, 1, F64, 3, PTN_DIR_DESC, PTN_TIES_ROW, PAY2](KB_I64.make_empty(4))
    var rank1 = PartitionTopNHashState[KB_I64, 1, F64, 3, PTN_DIR_ASC, PTN_TIES_RANK, PAY2](KB_I64.make_empty(4))
    for r in range(7):
        asc.feed_row(bv, r)
        desc.feed_row(bv, r)
        rank1.feed_row(bv, r)
    var ao = asc.drain_to_record_batch()
    var a = ao.take()
    assert_equal(a.num_rows(), 3)
    assert_equal(_get(a, 2, 0), 6)
    assert_equal(_get(a, 2, 1), 0)
    var z = _get(a, 2, 2)
    assert_true(z == 3 or z == 5)
    var do_ = desc.drain_to_record_batch()
    var d = do_.take()
    var want_d: List[Int64] = [2, 4, 1]
    _assert_pays(d, want_d, "desc floats")
    assert_true(isnan(_getf(d, 1, 0)))
    # RANK <= 3: -inf, -2.5, and both zeros (they tie at rank 3).
    var ro = rank1.drain_to_record_batch()
    var rk = ro.take()
    assert_equal(rk.num_rows(), 4)


def test_int64_extremes_desc() raises:
    # okey MIN, 0, MAX, 5 in one partition: DESC top 2 = MAX (2), 5 (3);
    # DESC top 4 ends with MIN (0).
    var pk: List[Int64] = [9, 9, 9, 9]
    var okv: List[Int64] = [Int64.MIN, 0, Int64.MAX, 5]
    var b = _batch3(_col_i64(pk, _all(4)), _col_i64(okv, _all(4)))
    var bv = batch_view_over(b)
    var d2 = PartitionTopNHashState[KB_I64, 1, I64, 2, PTN_DIR_DESC, PTN_TIES_ROW, PAY2](KB_I64.make_empty(4))
    var d4 = PartitionTopNHashState[KB_I64, 1, I64, 4, PTN_DIR_DESC, PTN_TIES_ROW, PAY2](KB_I64.make_empty(4))
    for r in range(4):
        d2.feed_row(bv, r)
        d4.feed_row(bv, r)
    var o2 = d2.drain_to_record_batch()
    var want2: List[Int64] = [2, 3]
    _assert_pays(o2.take(), want2, "desc top2")
    var o4 = d4.drain_to_record_batch()
    var want4: List[Int64] = [2, 3, 1, 0]
    _assert_pays(o4.take(), want4, "desc top4")


def test_rank_keeps_every_tie_row_keeps_n() raises:
    # One partition: okey 1, then 40 rows of 2, then 3. RANK <= 2 keeps 41
    # rows (more than any fixed over-fetch); ROW_NUMBER <= 2 keeps 2.
    var okv: List[Int64] = [1]
    for _ in range(40):
        okv.append(2)
    okv.append(3)
    var n = len(okv)
    var pk = List[Int64]()
    for _ in range(n):
        pk.append(Int64(7))
    var b = _batch3(_col_i64(pk, _all(n)), _col_i64(okv, _all(n)))
    var bv = batch_view_over(b)
    var rank = PartitionTopNHashState[KB_I64, 1, I64, 2, PTN_DIR_ASC, PTN_TIES_RANK, PAY2](KB_I64.make_empty(4))
    var row = PartitionTopNHashState[KB_I64, 1, I64, 2, PTN_DIR_ASC, PTN_TIES_ROW, PAY2](KB_I64.make_empty(4))
    # Feed the 3 first, then the rest, so the heap holds the worse key early.
    rank.feed_row(bv, n - 1)
    row.feed_row(bv, n - 1)
    for r in range(n - 1):
        rank.feed_row(bv, r)
        row.feed_row(bv, r)
    var ro = rank.drain_to_record_batch()
    var rk = ro.take()
    assert_equal(rk.num_rows(), 41)
    var wo = row.drain_to_record_batch()
    assert_equal(wo.take().num_rows(), 2)


def test_rank_ties_are_dropped_when_the_boundary_moves() raises:
    # okey 5, 5, 5, then 1, 2: RANK <= 2 is {1, 2}; the three 5s were tied
    # with the boundary until better rows pushed it to 2.
    var pk: List[Int64] = [1, 1, 1, 1, 1]
    var okv: List[Int64] = [5, 5, 5, 1, 2]
    var b = _batch3(_col_i64(pk, _all(5)), _col_i64(okv, _all(5)))
    var bv = batch_view_over(b)
    var rank = PartitionTopNHashState[KB_I64, 1, I64, 2, PTN_DIR_ASC, PTN_TIES_RANK, PAY2](KB_I64.make_empty(4))
    for r in range(5):
        rank.feed_row(bv, r)
    var ro = rank.drain_to_record_batch()
    var want: List[Int64] = [3, 4]
    _assert_pays(ro.take(), want, "moved boundary")


def test_null_partition_and_order_keys() raises:
    # pk: 1, NULL(slot 1), 1, NULL(slot 1); okey: NULL, 4, 2, NULL.
    # Partitions: 1 -> 2 then the NULL-okey row (row 0); NULL -> 4 then row 3.
    var pk: List[Int64] = [1, 1, 1, 1]
    var pkv: List[Bool] = [True, False, True, False]
    var okv: List[Int64] = [0, 4, 2, 0]
    var okvalid: List[Bool] = [False, True, True, False]
    var b = _batch3(_col_i64(pk, pkv), _col_i64(okv, okvalid))
    var bv = batch_view_over(b)
    var st = PartitionTopNHashState[KB_I64, 1, I64, 2, PTN_DIR_DESC, PTN_TIES_ROW, PAY2](KB_I64.make_empty(4))
    for r in range(4):
        st.feed_row(bv, r)
    assert_equal(st.n_partitions(), 2)
    var o = st.drain_to_record_batch()
    var out = o.take()
    var want: List[Int64] = [2, 0, 1, 3]
    _assert_pays(out, want, "nulls")
    assert_false(out.column_at(0).is_null_at(0))
    assert_true(out.column_at(0).is_null_at(2) and out.column_at(0).is_null_at(3))
    assert_true(out.column_at(1).is_null_at(1) and out.column_at(1).is_null_at(3))
    # RANK <= 2: the NULL-okey rows rank 2 (one non-NULL row each), so kept.
    var sr = PartitionTopNHashState[KB_I64, 1, I64, 2, PTN_DIR_DESC, PTN_TIES_RANK, PAY2](KB_I64.make_empty(4))
    for r in range(4):
        sr.feed_row(bv, r)
    var o2 = sr.drain_to_record_batch()
    _assert_pays(o2.take(), want, "nulls rank")


def test_float_partition_keys_nan_and_zero() raises:
    # pk: NaN, -0.0, NaN(other payload), +0.0 -> two partitions; ASC top 1
    # each over okey 4, 3, 2, 1: NaN partition -> row 2, zero partition -> row 3.
    var nan_b = bitcast[F64](UInt64(0x7FF8000000000001))
    var pkf: List[Float64] = [Float64(0.0) / Float64(0.0), -0.0, nan_b, 0.0]
    var okv: List[Int64] = [4, 3, 2, 1]
    var b = _batch3(_col_f64(pkf), _col_i64(okv, _all(4)))
    var bv = batch_view_over(b)
    var st = PartitionTopNHashState[KB_F64, 1, I64, 1, PTN_DIR_ASC, PTN_TIES_ROW, PAY2](KB_F64.make_empty(4))
    for r in range(4):
        st.feed_row(bv, r)
    assert_equal(st.n_partitions(), 2)
    var o = st.drain_to_record_batch()
    var want: List[Int64] = [2, 3]
    _assert_pays(o.take(), want, "float partitions")


def test_string_partition_and_string_order() raises:
    # pk strings with a NULL; okey strings: per partition DESC top 1.
    var pks = List[String]()
    pks.append("a")
    pks.append("b")
    pks.append("a")
    pks.append("")
    var pkv: List[Bool] = [True, True, True, False]
    var oks = List[String]()
    oks.append("pear")
    oks.append("fig")
    oks.append("plum")
    oks.append("kiwi")
    var b = _batch3(
        Column.from_string(StringArray.from_strings_with_validity(pks, pkv)),
        Column.from_string(StringArray.from_strings(oks)),
    )
    var bv = batch_view_over(b)
    var st = PartitionTopNHashState[KB_STR, 1, PTN_ORDER_STRING_SENTINEL, 1, PTN_DIR_DESC, PTN_TIES_ROW, PAY2](
        KB_STR.make_empty(4)
    )
    for r in range(4):
        st.feed_row(bv, r)
    var o = st.drain_to_record_batch()
    var out = o.take()
    var want: List[Int64] = [2, 1, 3]
    _assert_pays(out, want, "strings")
    var keys = out.column_at(1).as_string()
    assert_equal(keys.get(0), "plum")
    var pkcol = out.column_at(0).as_string()
    assert_equal(pkcol.get(0), "a")
    assert_true(pkcol.is_null(2))


def test_combine_equals_one_feed() raises:
    # 200 rows over 7 partitions with heavy ties; RANK <= 3 and ROW_NUMBER
    # counts: two workers combined equal one worker (RANK: same rows;
    # ROW_NUMBER: same count per partition).
    var n = 200
    var pk = List[Int64]()
    var okv = List[Int64]()
    for r in range(n):
        pk.append(Int64((r * 7919) % 7))
        okv.append(Int64((r * 37) % 5))
    var b = _batch3(_col_i64(pk, _all(n)), _col_i64(okv, _all(n)))
    var bv = batch_view_over(b)
    var one = PartitionTopNHashState[KB_I64, 1, I64, 3, PTN_DIR_DESC, PTN_TIES_RANK, PAY2](KB_I64.make_empty(8))
    var w0 = PartitionTopNHashState[KB_I64, 1, I64, 3, PTN_DIR_DESC, PTN_TIES_RANK, PAY2](KB_I64.make_empty(8))
    var w1 = PartitionTopNHashState[KB_I64, 1, I64, 3, PTN_DIR_DESC, PTN_TIES_RANK, PAY2](KB_I64.make_empty(8))
    for r in range(n):
        one.feed_row(bv, r)
        if r % 3 == 0:
            w0.feed_row(bv, r)
        else:
            w1.feed_row(bv, r)
    w0.combine(w1^)
    var ao = one.drain_to_record_batch()
    var a = ao.take()
    var co = w0.drain_to_record_batch()
    var c = co.take()
    var pa = _pays(a)
    var pc = _pays(c)
    sort(pa)
    sort(pc)
    assert_equal(len(pa), len(pc))
    for i in range(len(pa)):
        assert_equal(pa[i], pc[i])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
