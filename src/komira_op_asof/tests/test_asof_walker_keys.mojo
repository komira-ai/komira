# =============================================================================
# test_asof_walker_keys -- the ASOF merge walker's equi keys: STRING and
# DICTIONARY keys, and the DuckDB matching rules on NULL and float keys
# (komira_op_asof.asof_walker)
# =============================================================================
#
# The sort that prepares both sides places a NULL INT64 key by the value its
# slot holds (here 0), so a NULL-keyed row can sit inside the run of 0 keys.
# DuckDB: that row matches nothing, and it must not hide the 0-keyed rows
# around it. Float keys compare in `sort_key_lt` order: NaN equals NaN and no
# number, -0.0 equals +0.0.
# =============================================================================

from std.math import nan
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_collections.slab import Slab
from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_arrow.dictionary_array import StringDictionaryArray

from komira_plan_ir.logical_plan import (
    AsofTolerance,
    ASOF_BACKWARD,
    ASOF_FORWARD,
    ASOF_NEAREST,
)
from komira_op_asof.asof_walker import (
    compare_keys,
    compare_equi_keys,
    asof_merge_into,
    asof_merge_dispatch,
)


# =============================================================================
# Helpers -- build typed PrimitiveArrays
# =============================================================================


def _arr_i32(vs: List[Int]) raises -> PrimitiveArray[DType.int32]:
    var a = PrimitiveArray[DType.int32].allocate(len(vs))
    var p = a._typed_ptr_mut()
    for i in range(len(vs)):
        p.store[width=1](i, Scalar[DType.int32](vs[i]))
    return a^


def _arr_i64(vs: List[Int]) raises -> PrimitiveArray[DType.int64]:
    var a = PrimitiveArray[DType.int64].allocate(len(vs))
    var p = a._typed_ptr_mut()
    for i in range(len(vs)):
        p.store[width=1](i, Scalar[DType.int64](vs[i]))
    return a^


def _arr_f64(vs: List[Float64]) raises -> PrimitiveArray[DType.float64]:
    var a = PrimitiveArray[DType.float64].allocate(len(vs))
    var p = a._typed_ptr_mut()
    for i in range(len(vs)):
        p.store[width=1](i, vs[i])
    return a^


def _batch_i64_2(
    c0: String, v0: List[Int], c1: String, v1: List[Int]
) raises -> RecordBatch:
    """Two-column non-null Int64 batch."""
    var a0 = _arr_i64(v0)
    var a1 = _arr_i64(v1)
    var sb = SchemaBuilder()
    sb.add_field(Field(c0, ArrowType.INT64, False))
    sb.add_field(Field(c1, ArrowType.INT64, False))
    return RecordBatch.from_columns_2(sb.build()^, a0^, a1^)


def _batch_i64_1(c0: String, v0: List[Int]) raises -> RecordBatch:
    var a0 = _arr_i64(v0)
    var sb = SchemaBuilder()
    sb.add_field(Field(c0, ArrowType.INT64, False))
    return RecordBatch.from_columns_1(sb.build()^, a0^)


def _nullable_i64_array(
    v0: List[Int], nulls: List[Int]
) raises -> PrimitiveArray[DType.int64]:
    """Build a nullable PrimitiveArray[int64]. `nulls` are row indices
    to mark NULL."""
    var n = len(v0)
    var arr = PrimitiveArray[DType.int64].allocate_nullable(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, Scalar[DType.int64](v0[i]))
    for i in range(len(nulls)):
        arr.validity.value().clear(nulls[i])
    arr.null_count = len(nulls)
    return arr^


def _batch_i64_1_nullable(
    c0: String, v0: List[Int], nulls: List[Int]
) raises -> RecordBatch:
    """Single-column Int64 batch with explicit NULL rows."""
    var arr = _nullable_i64_array(v0, nulls)
    var col = Column.from_primitive[DType.int64](arr^)
    var sb = SchemaBuilder()
    sb.add_field(Field(c0, ArrowType.INT64, True))
    return RecordBatch.from_typed_columns_1(sb.build()^, col^)


def _batch_i64_2_nullable_key(
    c0: String, v0: List[Int], nulls: List[Int], c1: String, v1: List[Int]
) raises -> RecordBatch:
    """`[<c0> (NULLABLE key), <c1> (non-null asof)]`.

    ⚠ THE NULL ROW'S DATA SLOT KEEPS ITS `v0[i]` VALUE. Writing a real value
    under a cleared validity bit is what makes a NULL-vs-NULL case
    non-vacuous -- a comparator that reads the value instead of the bit sees
    two equal numbers, which is precisely the wrong answer under test."""
    var a0 = _nullable_i64_array(v0, nulls)
    var a1 = _arr_i64(v1)
    var col0 = Column.from_primitive[DType.int64](a0^)
    var col1 = Column.from_primitive[DType.int64](a1^)
    var sb = SchemaBuilder()
    sb.add_field(Field(c0, ArrowType.INT64, True))
    sb.add_field(Field(c1, ArrowType.INT64, False))
    return RecordBatch.from_typed_columns_2(sb.build()^, col0^, col1^)


def _batch_i32_2(
    c0: String, v0: List[Int], c1: String, v1: List[Int]
) raises -> RecordBatch:
    """Two-column non-null Int32 batch."""
    var a0 = _arr_i32(v0)
    var a1 = _arr_i32(v1)
    var col0 = Column.from_primitive[DType.int32](a0^)
    var col1 = Column.from_primitive[DType.int32](a1^)
    var sb = SchemaBuilder()
    sb.add_field(Field(c0, ArrowType.INT32, False))
    sb.add_field(Field(c1, ArrowType.INT32, False))
    return RecordBatch.from_typed_columns_2(sb.build()^, col0^, col1^)


def _batch_f64_2(
    c0: String, v0: List[Float64], c1: String, v1: List[Float64]
) raises -> RecordBatch:
    var a0 = _arr_f64(v0)
    var a1 = _arr_f64(v1)
    var col0 = Column.from_primitive[DType.float64](a0^)
    var col1 = Column.from_primitive[DType.float64](a1^)
    var sb = SchemaBuilder()
    sb.add_field(Field(c0, ArrowType.FLOAT64, False))
    sb.add_field(Field(c1, ArrowType.FLOAT64, False))
    return RecordBatch.from_typed_columns_2(sb.build()^, col0^, col1^)


# =============================================================================
# STRING / DICTIONARY equi keys
# =============================================================================
#
# `_cmp_one_column` reads a STRING or DICTIONARY cell as its UTF-8 bytes
# and compares them byte-wise. Mixed
# STRING <-> DICTIONARY equi-keys are supported (the two encodings share
# the same UTF-8 contract on the wire).


def _batch_str_key_i64_ts(
    key_vals: List[String], ts_vals: List[Int]
) raises -> RecordBatch:
    """Two-column batch: STRING "k" equi-key + INT64 "ts" asof."""
    var n = len(key_vals)
    var str_arr = StringArray.from_strings(key_vals)
    var col_k = Column.from_string(str_arr^)
    var ts = PrimitiveArray[DType.int64].allocate(n)
    var tp = ts._typed_ptr_mut()
    for i in range(n):
        tp.store[width=1](i, Scalar[DType.int64](ts_vals[i]))
    var col_t = Column.from_primitive[DType.int64](ts^)
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.STRING, False))
    sb.add_field(Field("ts", ArrowType.INT64, False))
    var builder = RecordBatchBuilder()
    builder.add_column(col_k^)
    builder.add_column(col_t^)
    return builder.build(sb.build())


def _batch_dict_key_i64_ts(
    dict_unique: List[String], dict_idx: List[Int], ts_vals: List[Int]
) raises -> RecordBatch:
    """Two-column batch: DICTIONARY "k" equi-key + INT64 "ts" asof."""
    var n = len(dict_idx)
    var idx_arr = PrimitiveArray[DType.int32].allocate(n)
    var ip = idx_arr._typed_ptr_mut()
    for i in range(n):
        ip.store[width=1](i, Scalar[DType.int32](dict_idx[i]))
    var dict_sa = StringArray.from_strings(dict_unique)
    var col_k = Column.from_dictionary(
        StringDictionaryArray.from_parts(idx_arr^, dict_sa^)
    )
    var ts = PrimitiveArray[DType.int64].allocate(n)
    var tp = ts._typed_ptr_mut()
    for i in range(n):
        tp.store[width=1](i, Scalar[DType.int64](ts_vals[i]))
    var col_t = Column.from_primitive[DType.int64](ts^)
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.DICTIONARY, False))
    sb.add_field(Field("ts", ArrowType.INT64, False))
    var builder = RecordBatchBuilder()
    builder.add_column(col_k^)
    builder.add_column(col_t^)
    return builder.build(sb.build())


def test_walker_string_equi_key_backward() raises:
    """STRING equi-key "symbol" over BACKWARD / INT64 asof.

    left:  (AAPL, 10) (AAPL, 20) (MSFT, 15)
    right: (AAPL, 5)  (AAPL, 18) (MSFT, 12)
    BACKWARD expects:
      row 0: (AAPL, 10) -> (AAPL, 5)
      row 1: (AAPL, 20) -> (AAPL, 18)
      row 2: (MSFT, 15) -> (MSFT, 12)
    """
    var lk: List[String] = ["AAPL", "AAPL", "MSFT"]
    var lt: List[Int] = [10, 20, 15]
    var rk: List[String] = ["AAPL", "AAPL", "MSFT"]
    var rt: List[Int] = [5, 18, 12]
    var left = _batch_str_key_i64_ts(lk, lt)
    var right = _batch_str_key_i64_ts(rk, rt)
    var left_b = Slab[RecordBatch]()
    left_b.append(left^)
    var right_b = Slab[RecordBatch]()
    right_b.append(right^)

    var lkc: List[Int] = [0]
    var rkc: List[Int] = [0]
    var lb = List[Int]()
    var lr = List[Int]()
    var rb = List[Int]()
    var rr = List[Int]()
    asof_merge_into[ASOF_BACKWARD, DType.int64](
        left_b, right_b, lkc, rkc, 1, 1,
        AsofTolerance.none(), lb, lr, rb, rr,
    )
    assert_equal(len(lb), 3, "3 outputs for 3 left rows")
    # Left input order: AAPL/10 AAPL/20 MSFT/15
    assert_equal(lr[0], 0)
    assert_equal(rr[0], 0, "AAPL/10 -> right row 0 (AAPL/5)")
    assert_equal(lr[1], 1)
    assert_equal(rr[1], 1, "AAPL/20 -> right row 1 (AAPL/18)")
    assert_equal(lr[2], 2)
    assert_equal(rr[2], 2, "MSFT/15 -> right row 2 (MSFT/12)")


def test_walker_string_equi_key_unmatched_group() raises:
    """STRING equi-key with a left group absent from right -> NULL."""
    var lk: List[String] = ["GOOG"]
    var lt: List[Int] = [30]
    var rk: List[String] = ["AAPL", "MSFT"]
    var rt: List[Int] = [10, 20]
    var left = _batch_str_key_i64_ts(lk, lt)
    var right = _batch_str_key_i64_ts(rk, rt)
    var left_b = Slab[RecordBatch]()
    left_b.append(left^)
    var right_b = Slab[RecordBatch]()
    right_b.append(right^)

    var lkc: List[Int] = [0]
    var rkc: List[Int] = [0]
    var lb = List[Int]()
    var lr = List[Int]()
    var rb = List[Int]()
    var rr = List[Int]()
    asof_merge_into[ASOF_BACKWARD, DType.int64](
        left_b, right_b, lkc, rkc, 1, 1,
        AsofTolerance.none(), lb, lr, rb, rr,
    )
    assert_equal(len(lb), 1)
    assert_equal(rb[0], -1, "GOOG has no right group -> NULL")


def test_walker_dict_equi_key_backward() raises:
    """DICTIONARY equi-key. Walker must resolve dict indices to bytes.

    left  dict = ["AAPL", "MSFT"], indices = [0, 0, 1]
    right dict = ["AAPL", "MSFT"], indices = [0, 0, 1]
    ts same as STRING test. Identical dict content -> same compare result.
    """
    var uniq: List[String] = ["AAPL", "MSFT"]
    var l_idx: List[Int] = [0, 0, 1]
    var l_ts: List[Int] = [10, 20, 15]
    var r_idx: List[Int] = [0, 0, 1]
    var r_ts: List[Int] = [5, 18, 12]
    var left = _batch_dict_key_i64_ts(uniq.copy(), l_idx, l_ts)
    var right = _batch_dict_key_i64_ts(uniq.copy(), r_idx, r_ts)
    var left_b = Slab[RecordBatch]()
    left_b.append(left^)
    var right_b = Slab[RecordBatch]()
    right_b.append(right^)

    var lkc: List[Int] = [0]
    var rkc: List[Int] = [0]
    var lb = List[Int]()
    var lr = List[Int]()
    var rb = List[Int]()
    var rr = List[Int]()
    asof_merge_into[ASOF_BACKWARD, DType.int64](
        left_b, right_b, lkc, rkc, 1, 1,
        AsofTolerance.none(), lb, lr, rb, rr,
    )
    assert_equal(len(lb), 3)
    assert_equal(rr[0], 0)
    assert_equal(rr[1], 1)
    assert_equal(rr[2], 2)


def test_walker_mixed_string_dict_equi_key() raises:
    """Mixed STRING (left) <-> DICTIONARY (right) equi-key.

    Both sides resolve to UTF-8 bytes; compare should succeed. Uses
    BACKWARD over INT64 asof. Dict with different underlying encoding
    but identical byte contents must match.
    """
    var lk: List[String] = ["AAPL", "MSFT"]
    var lt: List[Int] = [10, 15]
    var left = _batch_str_key_i64_ts(lk, lt)
    var r_uniq: List[String] = ["AAPL", "MSFT"]
    var r_idx: List[Int] = [0, 1]
    var r_ts: List[Int] = [5, 12]
    var right = _batch_dict_key_i64_ts(r_uniq, r_idx, r_ts)
    var left_b = Slab[RecordBatch]()
    left_b.append(left^)
    var right_b = Slab[RecordBatch]()
    right_b.append(right^)

    var lkc: List[Int] = [0]
    var rkc: List[Int] = [0]
    var lb = List[Int]()
    var lr = List[Int]()
    var rb = List[Int]()
    var rr = List[Int]()
    asof_merge_into[ASOF_BACKWARD, DType.int64](
        left_b, right_b, lkc, rkc, 1, 1,
        AsofTolerance.none(), lb, lr, rb, rr,
    )
    assert_equal(len(lb), 2)
    # AAPL/10 -> dict[0]=AAPL / ts=5
    assert_equal(rr[0], 0)
    # MSFT/15 -> dict[1]=MSFT / ts=12
    assert_equal(rr[1], 1)



# =============================================================================
# A NULL key inside a run of equal keys (DuckDB: it matches nothing and hides
# nothing)
# =============================================================================


def _merge_backward(
    var left: RecordBatch, var right: RecordBatch, mut rr: List[Int]
) raises -> List[Int]:
    """BACKWARD over key column 0 and INT64 asof column 1; returns the right
    batch per left row and fills `rr` with the right row."""
    var left_b = Slab[RecordBatch]()
    left_b.append(left^)
    var right_b = Slab[RecordBatch]()
    right_b.append(right^)
    var lkc: List[Int] = [0]
    var rkc: List[Int] = [0]
    var lb = List[Int]()
    var lr = List[Int]()
    var rb = List[Int]()
    asof_merge_into[ASOF_BACKWARD, DType.int64](
        left_b, right_b, lkc, rkc, 1, 1,
        AsofTolerance.none(), lb, lr, rb, rr,
    )
    assert_equal(len(lb), len(rb), "one output per left row")
    return rb^


def test_walker_right_null_key_inside_run_is_stepped_over() raises:
    """Right, as the sort leaves it: k=[0, NULL(slot 0), 0], ts=[1, 2, 3].
    Left: k=0, ts=10. BACKWARD: the last 0-keyed row at or before 10 is
    ts=3 (right row 2).
    """
    var right = _batch_i64_2_nullable_key("k", [0, 0, 0], [1], "ts", [1, 2, 3])
    var left = _batch_i64_2("k", [0], "ts", [10])
    var rr = List[Int]()
    var rb = _merge_backward(left^, right^, rr)
    assert_equal(rb[0], 0, "matched")
    assert_equal(rr[0], 2, "the ts=3 row, past the NULL-keyed row")


def test_walker_left_null_key_inside_run_keeps_the_group() raises:
    """Left, as the sort leaves it: k=[0, NULL(slot 0), 0], ts=[10, 15, 20].
    Right: k=0, ts=5. The two 0-keyed left rows both match right row 0; the
    NULL-keyed one matches nothing.
    """
    var left = _batch_i64_2_nullable_key("k", [0, 0, 0], [1], "ts", [10, 15, 20])
    var right = _batch_i64_2("k", [0], "ts", [5])
    var rr = List[Int]()
    var rb = _merge_backward(left^, right^, rr)
    assert_equal(rb[0], 0, "left row 0 matches")
    assert_equal(rr[0], 0)
    assert_equal(rb[1], -1, "the NULL-keyed left row matches nothing")
    assert_equal(rb[2], 0, "left row 2 still matches")
    assert_equal(rr[2], 0)


def test_walker_null_keys_on_both_sides_inside_runs() raises:
    """Both sides carry a NULL (slot 0) among their 0 keys, and a 7 key.
    Left k=[0, NULL, 0, 7] ts=[10, 10, 30, 10]; right k=[0, NULL, 0, 7]
    ts=[5, 6, 25, 1]. Expected rows: [0, -1, 2, 3]."""
    var left = _batch_i64_2_nullable_key(
        "k", [0, 0, 0, 7], [1], "ts", [10, 10, 30, 10]
    )
    var right = _batch_i64_2_nullable_key(
        "k", [0, 0, 0, 7], [1], "ts", [5, 6, 25, 1]
    )
    var rr = List[Int]()
    var rb = _merge_backward(left^, right^, rr)
    assert_equal(rr[0], 0, "0/10 -> 0/5")
    assert_equal(rb[1], -1, "NULL -> nothing")
    assert_equal(rr[2], 2, "0/30 -> 0/25, past the NULL row")
    assert_equal(rr[3], 3, "7/10 -> 7/1")


# =============================================================================
# Float equi keys
# =============================================================================


def test_walker_float_key_nan_matches_only_nan() raises:
    """Left k=[1.0, NaN] ts=[10, 10]; right (sorted, NaN last) k=[1.0, NaN]
    ts=[5, 6]. 1.0 matches only the 1.0 row; NaN only the NaN row.
    """
    var left = _batch_f64_2("k", [1.0, nan[DType.float64]()], "ts", [10.0, 10.0])
    var right = _batch_f64_2("k", [1.0, nan[DType.float64]()], "ts", [5.0, 6.0])
    var left_b = Slab[RecordBatch]()
    left_b.append(left^)
    var right_b = Slab[RecordBatch]()
    right_b.append(right^)
    var lkc: List[Int] = [0]
    var rkc: List[Int] = [0]
    var lb = List[Int]()
    var lr = List[Int]()
    var rb = List[Int]()
    var rr = List[Int]()
    asof_merge_into[ASOF_BACKWARD, DType.float64](
        left_b, right_b, lkc, rkc, 1, 1,
        AsofTolerance.none(), lb, lr, rb, rr,
    )
    assert_equal(rr[0], 0, "1.0 -> the 1.0 row only")
    assert_equal(rr[1], 1, "NaN -> the NaN row")


def test_walker_float_key_nan_does_not_match_a_number() raises:
    """Left k=NaN; right k=5.0 only: no match."""
    var left = _batch_f64_2("k", [nan[DType.float64]()], "ts", [10.0])
    var right = _batch_f64_2("k", [5.0], "ts", [1.0])
    var left_b = Slab[RecordBatch]()
    left_b.append(left^)
    var right_b = Slab[RecordBatch]()
    right_b.append(right^)
    var lkc: List[Int] = [0]
    var rkc: List[Int] = [0]
    var lb = List[Int]()
    var lr = List[Int]()
    var rb = List[Int]()
    var rr = List[Int]()
    asof_merge_into[ASOF_BACKWARD, DType.float64](
        left_b, right_b, lkc, rkc, 1, 1,
        AsofTolerance.none(), lb, lr, rb, rr,
    )
    assert_equal(rb[0], -1, "NaN != 5.0")


def test_compare_equi_keys_float_model() raises:
    """NaN = NaN, -0.0 = +0.0, NaN sorts after +inf."""
    var b = _batch_f64_2(
        "k", [nan[DType.float64](), -0.0, Float64.MAX], "t", [0.0, 0.0, 0.0]
    )
    var c = _batch_f64_2(
        "k", [nan[DType.float64](), 0.0, nan[DType.float64]()], "t", [0.0, 0.0, 0.0]
    )
    var cols: List[Int] = [0]
    assert_true(compare_equi_keys(b, 0, c, 0, cols, cols).matched, "NaN = NaN")
    assert_true(compare_equi_keys(b, 1, c, 1, cols, cols).matched, "-0.0 = +0.0")
    var big_vs_nan = compare_equi_keys(b, 2, c, 2, cols, cols)
    assert_equal(big_vs_nan.order, -1, "MAX sorts before NaN")
    assert_false(big_vs_nan.matched)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
