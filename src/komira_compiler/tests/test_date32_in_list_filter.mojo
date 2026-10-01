# =============================================================================
# test_date32_in_list_filter — DATE32 temporal literal in an EXPR_IN_LIST
# =============================================================================
#
# TEMPORAL LOGICAL-vs-PHYSICAL. REGRESSION GUARD for a SILENT-WRONG sibling
# of the DATE32 predicate gap:
# an `EXPR_IN_LIST` over a DATE32 column silently matched NOTHING.
#
# ROOT CAUSE (pre-fix): the IN-list value-table extraction in
# `compiler_eval_in_list._eval_in_list_int32 / _int64` read each literal's value
# from `ScalarValue.int_val`. But a `ScalarValue.date32(D)` carries D in
# `date32_val` and leaves `int_val == 0` (only the field matching the KIND is
# meaningful). A date column is physically stamped INT32 at runtime (Arrow DATE32
# storage == int32; the parquet decode reports INT32), so it routes to the INT32
# kernel, whose value table becomes all-zeros -> every row compared `day != 0` ->
# all-FALSE. The optimizer's `rewrite_in_clauses` folds `d = DATE 'a' OR
# d = DATE 'b'` into `EXPR_IN_LIST`, so this is the live shape for an OR-of-eq on
# a date column.
#
# FAILS ON CURRENT CODE (pre-fix): the direct `_eval_in_list` calls below assert
# the exact per-row membership mask. Pre-fix the date32 IN-list returns an
# all-FALSE mask (int_val == 0 for every date literal, and no fixture day is 0),
# which never equals the closed-form oracle. The plain-int control case passes
# both pre- and post-fix (proving the fix does not regress non-temporal IN-lists).
#
# The fix routes the numeric IN-list value extraction through the CONVERGED
# temporal-literal helper (`_temporal_literal_i64`, lifted to
# `temporal_literal_value.mojo` and shared with `_eval_predicate`) so a temporal
# literal is read from its correct storage field; plain / narrow / unsigned ints
# still read `int_val`.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.boolean_array import BooleanArray
from komira_core.io.heap_region import HeapRegion
from komira_core.arrow.schema import (
    Field, RecordBatch, RecordBatchBuilder, SchemaBuilder,
)
from komira_core.plan.expr import Expr
from komira_core.plan.scalar_value import ScalarValue

from komira_compiler.compiler_eval_in_list import _eval_in_list


# =============================================================================
# Fixtures
# =============================================================================


def _i32_batch(
    values: List[Int32], stamp: ArrowType, col_name: String
) raises -> RecordBatch:
    """Single int32-physical column named `col_name`, stamped `stamp`
    (INT32 = the live parquet-decode shape, or DATE32 = the CAST shape)."""
    var n = len(values)
    var arr = PrimitiveArray[DType.int32].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        (p + i)[] = values[i]
    var col: Column[HeapRegion]
    if stamp == ArrowType.INT32:
        col = Column.from_primitive(arr^)
    else:
        col = Column.from_primitive_with_arrow_type[DType.int32](arr^, stamp)
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(col^)
    var sb = SchemaBuilder()
    sb.add_field(Field(col_name, stamp, False))
    return rbb.build(sb.build())


def _i64_batch(
    values: List[Int64], stamp: ArrowType, col_name: String
) raises -> RecordBatch:
    """Single int64-physical column named `col_name`, stamped `stamp`. A date
    value can be int64-physical on the row-mode walker path (see
    `expr_to_runtime._translate_literal`: parquet l_shipdate is Int64)."""
    var n = len(values)
    var arr = PrimitiveArray[DType.int64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        (p + i)[] = values[i]
    var col: Column[HeapRegion]
    if stamp == ArrowType.INT64:
        col = Column.from_primitive(arr^)
    else:
        col = Column.from_primitive_with_arrow_type[DType.int64](arr^, stamp)
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(col^)
    var sb = SchemaBuilder()
    sb.add_field(Field(col_name, stamp, False))
    return rbb.build(sb.build())


def _assert_membership(
    got: BooleanArray,
    values: List[Int64],
    members: List[Int64],
    label: String,
) raises:
    """Assert `got` matches the INDEPENDENT closed-form membership oracle:
    row i is True iff values[i] is in `members`. Hash-free, no eval kernel."""
    assert_equal(got.length, len(values), label + ": length")
    for i in range(len(values)):
        var want = False
        for j in range(len(members)):
            if values[i] == members[j]:
                want = True
        assert_true(
            got.get(i) == want,
            label + ": row " + String(i) + " (val " + String(values[i])
            + ", want " + String(want) + ", got " + String(got.get(i)) + ")",
        )


# =============================================================================
# 1. DATE32 IN-list over an INT32-stamped column (the LIVE parquet shape).
# =============================================================================
#   d = [100, 175, 200, 175]; IN (DATE 175, DATE 200) -> [F, T, T, T].
#   Pre-fix: int_val == 0 for both date literals -> mask all-FALSE.


def test_date32_in_list_int32_stamped() raises:
    var days: List[Int32] = [100, 175, 200, 175]
    var vals64: List[Int64] = [100, 175, 200, 175]
    var batch = _i32_batch(days, ArrowType.INT32, String("d"))
    var members = List[ScalarValue]()
    members.append(ScalarValue.date32(Int32(175)))
    members.append(ScalarValue.date32(Int32(200)))
    var expr = Expr.in_list_node(Expr.col_ref("d"), members^)
    var mask = _eval_in_list(expr, batch)
    var oracle: List[Int64] = [175, 200]
    _assert_membership(
        mask, vals64, oracle, String("DATE32 IN-list / INT32-stamped col")
    )


# =============================================================================
# 2. DATE32-stamped column (the CAST(x AS DATE) shape).
#   Pre-fix hit the else-RAISE ("unsupported column type: DATE32"); the fix
#   admits a DATE32 column via the INT32 physical reader.
# =============================================================================


def test_date32_in_list_date32_stamped() raises:
    var days: List[Int32] = [100, 175, 200, 175]
    var vals64: List[Int64] = [100, 175, 200, 175]
    var batch = _i32_batch(days, ArrowType.DATE32, String("d"))
    var members = List[ScalarValue]()
    members.append(ScalarValue.date32(Int32(175)))
    members.append(ScalarValue.date32(Int32(200)))
    var expr = Expr.in_list_node(Expr.col_ref("d"), members^)
    var mask = _eval_in_list(expr, batch)
    var oracle: List[Int64] = [175, 200]
    _assert_membership(
        mask, vals64, oracle, String("DATE32 IN-list / DATE32-stamped col")
    )


# =============================================================================
# 3. DATE32 IN-list over an INT64-physical column (row-mode walker date storage).
# =============================================================================


def test_date32_in_list_int64_stamped() raises:
    var days: List[Int64] = [100, 175, 200]
    var batch = _i64_batch(days, ArrowType.INT64, String("d"))
    var members = List[ScalarValue]()
    members.append(ScalarValue.date32(Int32(175)))
    var expr = Expr.in_list_node(Expr.col_ref("d"), members^)
    var mask = _eval_in_list(expr, batch)
    var oracle: List[Int64] = [175]
    _assert_membership(
        mask, days, oracle, String("DATE32 IN-list / INT64-physical col")
    )


# =============================================================================
# 4. CONTROL — plain INT32 IN-list must be UNAFFECTED (no regression).
#   A from_int literal carries its value in int_val; the fix must leave this
#   path byte-identical (passes pre- AND post-fix).
# =============================================================================


def test_plain_int_in_list_unaffected() raises:
    var vals: List[Int32] = [100, 175, 200, 175]
    var vals64: List[Int64] = [100, 175, 200, 175]
    var batch = _i32_batch(vals, ArrowType.INT32, String("d"))
    var members = List[ScalarValue]()
    members.append(ScalarValue.from_int(175))
    members.append(ScalarValue.from_int(100))
    var expr = Expr.in_list_node(Expr.col_ref("d"), members^)
    var mask = _eval_in_list(expr, batch)
    var oracle: List[Int64] = [175, 100]
    _assert_membership(
        mask, vals64, oracle, String("plain INT32 IN-list control")
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_date32_in_list_int32_stamped]()
    suite.test[test_date32_in_list_date32_stamped]()
    suite.test[test_date32_in_list_int64_stamped]()
    suite.test[test_plain_int_in_list_unaffected]()
    suite^.run()
