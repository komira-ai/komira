# =============================================================================
# test_in_list_null_contract — `x IN (...)` is THREE-VALUED at the ONE dispatcher
# =============================================================================
#
# REGRESSION GUARD for a
# SILENT-WRONG-ANSWER family in `compiler_eval_in_list._eval_in_list`, which the
# FILTER and the PROJECTION evaluators both call.
#
# THE DEFECT. The typed kernels build their answer with `BooleanArray.from_bitmap`
# from the column's RAW PAYLOAD and never read its validity. Two consequences,
# both MEASURED at the SQL door against DuckDB 1.5.3 over a 4-row parquet file
# `k = [1, 2, NULL, 4]` (the parquet decode stores 0 under the NULL):
#
#   WHERE k IN (0, 1)          DuckDB 1    komira 2   the NULL row's payload 0
#                                                     MATCHED the member 0
#   WHERE NOT (k IN (1, 2))    DuckDB 1    komira 2   a NULL row answered FALSE,
#                                                     and NOT turned it into TRUE
#   (and the same for `f IN (0.0, 1.0)`, `s IN ('', 'a')`, `NOT (s IN (...))`,
#   `NOT (f IN (...))`, and polars `filter(~pl.col('s').is_in([...]))`)
#
# The PROJECTION arm (`compiler_eval_column`) had re-imposed the child's validity
# on its own copy of the answer on the argument that "in a
# FILTER that is right — NULL IN (...) is UNKNOWN, which does not select". Both
# rows above refute it: a FALSE is not an UNKNOWN once a NOT reads it, and a raw
# payload is not a FALSE at all.
#
# AND A NULL **MEMBER**. `x IN (1, NULL)` is `x = 1 OR x = NULL`, i.e. TRUE where
# `x = 1` and NULL everywhere else (DuckDB: `2 IN (1, NULL)` is NULL, and
# `WHERE k NOT IN (1, NULL)` selects NOTHING). The kernels read a NULL member's
# unpopulated field as a well-formed ZERO / "" and probed it — so it MATCHED a
# 0 / "" row and every miss answered FALSE.
#
# The assertions below are against an INDEPENDENT oracle written per row (value
# AND validity), never against what a kernel happens to emit.
# =============================================================================

from std.sys import size_of
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.boolean_array import BooleanArray
from komira_core.arrow.bitmap import Bitmap
from komira_core.io.heap_region import HeapRegion
from komira_core.arrow.column import Column
from komira_core.arrow.string_array import StringArray
from komira_core.arrow.schema import SchemaBuilder, Field, RecordBatch, RecordBatchBuilder
from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.owned_aligned_buffer import OwnedAlignedBuffer
from komira_core.plan.expr import Expr, UN_NOT
from komira_core.plan.scalar_value import ScalarValue

from komira_compiler.compiler_eval_in_list import _eval_in_list
from komira_compiler.compiler_eval_predicate import _eval_predicate


# ---------------------------------------------------------------------------
# Fixtures: the NULL slot's payload is CHOSEN to equal a list member, which is
# the deterministic pre-fix failure shape (the parquet decode stores 0 there).
# ---------------------------------------------------------------------------


def _i64_batch(raw: List[Int64], nulls: List[Bool]) raises -> RecordBatch:
    var n = len(raw)
    comptime elem = size_of[Scalar[DType.int64]]()
    var buf = OwnedAlignedBuffer(max(n, 1) * elem)
    for i in range(n):
        buf.set_typed[Scalar[DType.int64]](i, Scalar[DType.int64](raw[i]))
    buf.set_length(Int64(n * elem))
    var bm = Bitmap.create_all_valid(n)
    var nc = 0
    for i in range(n):
        if nulls[i]:
            bm.clear(i)
            nc += 1
    var arr = PrimitiveArray[DType.int64](
        buf^, n, Optional[Bitmap[HeapRegion]](bm^), nc, 0
    )
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    return RecordBatch.from_columns_1(sb.build(), arr^)


def _i64_batch_no_validity(raw: List[Int64]) raises -> RecordBatch:
    var n = len(raw)
    comptime elem = size_of[Scalar[DType.int64]]()
    var buf = OwnedAlignedBuffer(max(n, 1) * elem)
    for i in range(n):
        buf.set_typed[Scalar[DType.int64]](i, Scalar[DType.int64](raw[i]))
    buf.set_length(Int64(n * elem))
    var arr = PrimitiveArray[DType.int64](
        buf^, n, Optional[Bitmap[HeapRegion]](None), 0, 0
    )
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    return RecordBatch.from_columns_1(sb.build(), arr^)


def _f64_batch(raw: List[Float64], nulls: List[Bool]) raises -> RecordBatch:
    var n = len(raw)
    comptime elem = size_of[Scalar[DType.float64]]()
    var buf = OwnedAlignedBuffer(max(n, 1) * elem)
    for i in range(n):
        buf.set_typed[Scalar[DType.float64]](i, Scalar[DType.float64](raw[i]))
    buf.set_length(Int64(n * elem))
    var bm = Bitmap.create_all_valid(n)
    var nc = 0
    for i in range(n):
        if nulls[i]:
            bm.clear(i)
            nc += 1
    var arr = PrimitiveArray[DType.float64](
        buf^, n, Optional[Bitmap[HeapRegion]](bm^), nc, 0
    )
    var c = Column.from_primitive[DType.float64](arr^)
    c.arrow_type = ArrowType.FLOAT64
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.FLOAT64, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(c^)
    return rbb.build(sb.build())


def _str_batch(vals: List[String], nulls: List[Bool]) raises -> RecordBatch:
    var n = len(vals)
    var sa = StringArray.from_strings(vals)
    var bm = Bitmap.create_all_valid(n)
    var nc = 0
    for i in range(n):
        if nulls[i]:
            bm.clear(i)
            nc += 1
    sa.validity = bm^
    sa.null_count = nc
    var c = Column.from_string(sa^)
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.STRING, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(c^)
    return rbb.build(sb.build())


# The oracle: per row, 1 = TRUE, 0 = FALSE, -1 = NULL.
comptime T = 1
comptime F = 0
comptime N = -1


def _check(got: BooleanArray, want: List[Int], what: String) raises:
    assert_equal(got.length, len(want), what + ": length")
    var nulls = 0
    for i in range(len(want)):
        var is_null = got.validity and not got.validity.value().test(i)
        if want[i] == N:
            nulls += 1
            assert_true(is_null, what + ": row " + String(i) + " must be NULL")
            # The repo-wide UNKNOWN encoding: data bit 0 under a cleared
            # validity bit, so a data-only consumer (`filter_to_indices`)
            # never selects it.
            assert_false(
                got.data.test(i),
                what + ": row " + String(i) + " is NULL but carries data bit 1",
            )
        else:
            assert_false(is_null, what + ": row " + String(i) + " must be valid")
            assert_equal(
                got.data.test(i), want[i] == T,
                what + ": row " + String(i) + " value",
            )
    assert_equal(got.null_count, nulls, what + ": null_count")


def _in(var values: List[ScalarValue]) -> Expr:
    return Expr.in_list_node(Expr.col_ref("k"), values^)


def _i(v: Int) -> ScalarValue:
    return ScalarValue.from_int64(Int64(v))


def _nul() -> ScalarValue:
    return ScalarValue.null(DType.int64)


# ---------------------------------------------------------------------------
# A NULL ROW
# ---------------------------------------------------------------------------


def test_int64_null_row_whose_payload_equals_a_member_is_null() raises:
    """`k IN (0, 1)` over `[1, 2, NULL(payload 0), 4]` -> T F NULL F."""
    var b = _i64_batch([Int64(1), 2, 0, 4], [False, False, True, False])
    _check(_eval_in_list(_in([_i(0), _i(1)]), b), [T, F, N, F], "int64 IN (0, 1)")


def test_not_in_over_a_null_row_selects_nothing() raises:
    """`NOT (k IN (1, 2))` through `_eval_predicate` -> F F NULL T. The NULL row
    is the one DuckDB drops and the pre-fix evaluator SELECTED."""
    var b = _i64_batch([Int64(1), 2, 0, 4], [False, False, True, False])
    var e = Expr.unary(UN_NOT, _in([_i(1), _i(2)]))
    _check(_eval_predicate(e, b), [F, F, N, T], "NOT (k IN (1, 2))")


def test_float64_null_row_is_null() raises:
    var b = _f64_batch([1.0, 2.0, 0.0, 4.0], [False, False, True, False])
    var vals: List[ScalarValue] = [ScalarValue.from_float(0.0), ScalarValue.from_float(1.0)]
    _check(_eval_in_list(_in(vals^), b), [T, F, N, F], "float64 IN (0.0, 1.0)")


def test_string_null_row_is_not_the_empty_string() raises:
    """`s IN ('', 'a')`: a NULL string is an Arrow `(offset, len 0)` slot, which
    the byte compare read as ''."""
    var b = _str_batch(["a", "b", "", "d"], [False, False, True, False])
    var vals: List[ScalarValue] = [ScalarValue.from_string(""), ScalarValue.from_string("a")]
    _check(_eval_in_list(_in(vals^), b), [T, F, N, F], "string IN ('', 'a')")


def test_string_not_in_over_a_null_row_selects_nothing() raises:
    var b = _str_batch(["a", "b", "", "d"], [False, False, True, False])
    var vals: List[ScalarValue] = [ScalarValue.from_string("a"), ScalarValue.from_string("b")]
    var e = Expr.unary(UN_NOT, _in(vals^))
    _check(_eval_predicate(e, b), [F, F, N, T], "NOT (s IN ('a', 'b'))")


# ---------------------------------------------------------------------------
# A NULL MEMBER
# ---------------------------------------------------------------------------


def test_a_null_member_makes_every_miss_null() raises:
    """`k IN (1, NULL)` over `[1, 2, 0, 4]` (no NULL rows) -> T NULL NULL NULL.
    Pre-fix the NULL member was probed as 0 and MATCHED row 2."""
    var b = _i64_batch([Int64(1), 2, 0, 4], [False, False, False, False])
    _check(_eval_in_list(_in([_i(1), _nul()]), b), [T, N, N, N], "k IN (1, NULL)")


def test_not_in_with_a_null_member_selects_nothing() raises:
    """`k NOT IN (1, NULL)` -> F NULL NULL NULL: the WHERE selects no row."""
    var b = _i64_batch([Int64(1), 2, 0, 4], [False, False, False, False])
    var e = Expr.unary(UN_NOT, _in([_i(1), _nul()]))
    _check(_eval_predicate(e, b), [F, N, N, N], "NOT (k IN (1, NULL))")


def test_only_null_members_answer_null_everywhere() raises:
    var b = _i64_batch([Int64(1), 2, 0, 4], [False, False, True, False])
    _check(_eval_in_list(_in([_nul()]), b), [N, N, N, N], "k IN (NULL)")


def test_a_null_member_and_a_null_row_together() raises:
    var b = _i64_batch([Int64(1), 2, 0, 4], [False, False, True, False])
    _check(
        _eval_in_list(_in([_i(4), _nul()]), b), [N, N, N, T], "k IN (4, NULL)"
    )


def test_string_null_member_is_not_the_empty_string() raises:
    var b = _str_batch(["a", "", "c", "d"], [False, False, False, False])
    var vals: List[ScalarValue] = [ScalarValue.from_string("a"), ScalarValue.null(DType.uint8)]
    _check(_eval_in_list(_in(vals^), b), [T, N, N, N], "s IN ('a', NULL)")


def test_float_null_member_is_not_zero() raises:
    var b = _f64_batch([1.0, 0.0, 3.0, 4.0], [False, False, False, False])
    var vals: List[ScalarValue] = [ScalarValue.from_float(3.0), ScalarValue.null(DType.float64)]
    _check(_eval_in_list(_in(vals^), b), [N, N, T, N], "f IN (3.0, NULL)")


# ---------------------------------------------------------------------------
# CONTROLS — the fast path stays byte-identical where there is no NULL anywhere
# ---------------------------------------------------------------------------


def test_no_validity_and_no_null_member_carries_no_validity() raises:
    var b = _i64_batch_no_validity([Int64(1), 2, 0, 4])
    var got = _eval_in_list(_in([_i(0), _i(1)]), b)
    assert_false(Bool(got.validity), "an all-valid answer grows no validity bitmap")
    _check(got, [T, F, T, F], "no-null control")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
