# =============================================================================
# an INT64 literal that does not fit in
# an INT32 was TRUNCATED TO ITS LOW 32 BITS by every executor arm that reads a
# literal at the column's PHYSICAL width.
# =============================================================================
#
# THE PROPERTY THIS FILE VARIES is the literal's MAGNITUDE. Every cell any
# previous suite sent through these arms carried a value inside
# `[-2^31, 2^31)`, where `Int32(Int(v))` is the IDENTITY — so six narrowing
# casts were exercised only where narrowing cannot be observed.
#
#     compiler_eval_predicate.mojo   the INT32 column comparison arm
#     compiler_eval_predicate.mojo   `_eval_temporal_col_vs_literal` int32 arm
#                                    (DATE32 / TIME32_S / TIME32_MS)
#     compiler_eval_predicate.mojo   `_numeric_dict_keep_int32` LUT threshold
#     compiler_eval_predicate.mojo   `numeric_dict_filter_via_flat` int32 arm
#     compiler_eval_in_list.mojo     the INT32 / DATE32 membership value table
#     compiler_eval_column.mojo      `_eval_binary_col_scalar`'s INT32 arm
#                                    (+ - * /) — THE SIXTH, and the one the
#                                    composition below runs through
#
# ★ THE FIXTURE IS THE FIRST DELIVERABLE FOR TWO OF THEM. The plan-wire
# narrowing falsifier exercised three of
# the six and recorded the two NUMERIC-DICTIONARY sites as executed by NOTHING,
# because no PARQUET fixture in this repo has an int32-valued dictionary column.
# That is a property of the CORPUS, not of the engine: `Column.from_numeric_dict
# [DType.int32, DType.int32]` builds exactly that column IN MEMORY, so leg 4
# below reaches both sites directly. An unexercised path is not a safe path.
#
# ============================== THE RULE, DERIVED =============================
#
# A comparison, a membership probe, or an arithmetic op between a value of
# physical type T and a literal L must be evaluated in a domain that CONTAINS
# BOTH OPERANDS. When L is not exactly representable in T the T-width arm may
# not be used — the operation WIDENS (to int64, the literal's own domain), it
# does not narrow the literal.
#
# `int_literal_fits[dtype]` (komira_compiler/literal_domain.mojo) is that
# test, and it is a ROUND TRIP through the type rather than a bound ladder, so
# a new integer width needs no new constant anywhere.
#
# ============================ THE ORACLE, MEASURED ============================
#
# DuckDB v1.5.3, executed over
# `t(i32 INTEGER)` = {0, 40, -5, 2147483647, -2147483648, NULL}:
#
#     i32 >  4294967296  -> 0 rows      i32 >  -4294967296 -> 5 rows
#     i32 <  4294967296  -> 5 rows      i32 =   4294967296 -> 0 rows
#     i32 <> 4294967296  -> 5 rows      i32 IN (4294967296, 40) -> 1 row
#     i32 // 4294967296  -> 0 on every non-null row, NULL on the null row
#     i32 +  4294967296  -> 4294967296, 4294967336, ... typeof BIGINT
#
# ⚠ `//` IS THE RIGHT ORACLE COLUMN FOR OUR `/`, NOT `/`. DuckDB's `/` on
# integers returns DOUBLE (`40 / 4294967296` = 9.31e-09); this engine's BIN_DIV
# on an integral pair returns an integer. That divergence is OPEN, DELIBERATE
# and pinned elsewhere (`komira_core/eval/arithmetic.mojo`'s header, and
# `test_div_truncates_toward_zero_control`) — it is not what this file is about.
# Against DuckDB's INTEGER-division column the answer is 0, and 0 is what leg 5
# demands.
#
# ★★ LEG 5 IS A COMPOSITION OF TWO DEFECTS, WHICH IS WHY IT IS HERE.
# `SELECT q32 / 4294967296` over an INT32 column returned NULL for every row
# while the oracle says 0. The truncation makes the divisor genuinely ZERO, and
# the divide-by-zero guard — which correctly replaced a PROCESS KILL — then
# does the right thing with a zero divisor and yields NULL. Before the guard the
# same query CRASHED. Fixing the truncation dissolves it; WEAKENING THE GUARD
# WOULD REOPEN A CRASH REACHABLE FROM ANY FRONT END. Leg 5 asserts BOTH
# halves: the out-of-range divisor now answers 0, and a genuine `/ 0` still
# answers NULL on the same arm.
#
# =========================== THE CONTROLS, BOTH WAYS ==========================
#
# Leg 6 carries what must STILL WORK: every in-range literal on every one of the
# six sites, including the exact int32 BOUNDARY values (2147483647 /
# -2147483648, where a naive "does it fit" test off by one would fire), and the
# INT64-column arm reading the identical out-of-range literal — which was always
# correct and must stay correct, because it is what attributes the defect to the
# int32 cast rather than to the literal, the Expr, or the dispatcher.
#
# Leg 7 carries NULLs: an out-of-range comparison over a nullable int32 column
# must still absorb null lanes under 3VL. The widening must not lose validity —
# the widened path deliberately finalizes through the ORIGINAL array's validity
# and offset, never the cast copy's (`eval_cast` clones a bitmap from BIT 0 and
# is offset-blind; see `compiler_eval_column.mojo`'s header).
#
# =============================================================================
# WHAT THIS FILE DELIBERATELY DOES NOT PROVE
# =============================================================================
# * ONE PLAN POSITION. Every cell calls `_eval_predicate` / `_eval_column_expr`
#   directly. A narrowing under a JOIN residual or inside a CASE arm is sent by
#   no cell here.
# * NOT the UINT64-above-2^63 literal. `ScalarValue.int_val` is an Int64 and no
#   producer in this tree writes a wider one; the round-trip test is total over
#   the SIGNED widths it is instantiated at.
# * NOT the DICTIONARY ENTRY's own truncation. `_numeric_dict_keep_int32` also
#   truncates the ENTRY (`dict_value_i64(code) & 0xFFFFFFFF`) to mirror
#   `resolve_numeric_dict_to_flat`. That is a DATA-side question about a
#   malformed int32 dictionary, not a literal-domain one, and it is untouched
#   here: leg 4's entries are all genuinely int32.
# * NOT TIME32_S / TIME32_MS. They share the int32 temporal arm with DATE32 and
#   are fixed by the same line; leg 2 drives DATE32 only.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.schema import (
    Field,
    RecordBatch,
    SchemaBuilder,
    RecordBatchBuilder,
)
from komira_core.arrow.boolean_array import BooleanArray
from komira_core.arrow.bitmap import Bitmap
from komira_core.arrow.owned_aligned_buffer import OwnedAlignedBuffer
from komira_core.plan.col_expr import col
from komira_core.plan.expr import Expr, BIN_GT, BIN_LT, BIN_EQ, BIN_NE, BIN_GE, BIN_LE
from komira_core.plan.scalar_value import ScalarValue
from komira_core.io.heap_region import HeapRegion
from komira_compiler.compiler_eval_predicate import (
    _eval_predicate,
    numeric_dict_filter_bool_mask,
    numeric_dict_filter_via_flat,
)
from komira_compiler.compiler_eval_column import _eval_column_expr
from komira_core.plan.literal_domain import int_literal_fits


# -----------------------------------------------------------------------------
# The out-of-range literals. Each is chosen so that its LOW 32 BITS collide with
# a value that IS present in the fixture — that collision is what makes the
# defect a wrong ANSWER instead of a harmless miss.
# -----------------------------------------------------------------------------

comptime TWO_P32: Int = 4294967296  # low 32 bits == 0        -> collides with 0
comptime TWO_P32_P40: Int = 4294967336  # low 32 bits == 40   -> collides with 40
comptime NEG_TWO_P32: Int = -4294967296  # low 32 bits == 0    -> collides with 0
comptime I32_MAX: Int = 2147483647
comptime I32_MIN: Int = -2147483648

# The fixture column, and its ORACLE values as plain Mojo Int64 (arbitrary
# comparisons below are computed at Int64 width in this file, so the oracle
# cannot share the defect under test).
comptime N_ROWS: Int = 6


def _i32_col(vals: List[Int32]) raises -> Column[HeapRegion]:
    var l: List[Scalar[DType.int32]] = []
    for i in range(len(vals)):
        l.append(vals[i])
    return Column.from_primitive[DType.int32](
        PrimitiveArray[DType.int32].from_list(l)
    )


def _i32_col_nullable(
    vals: List[Int32], null_rows: List[Int]
) raises -> Column[HeapRegion]:
    var n = len(vals)
    var buf = OwnedAlignedBuffer(max(n * 4, 1))
    var p = buf.view_typed_ro[DType.int32]()
    for i in range(n):
        p[i] = vals[i]
    buf.set_length(Int64(n * 4))
    var bm = Bitmap.create_all_valid(n)
    var nulls = 0
    for k in range(len(null_rows)):
        bm.clear(null_rows[k])
        nulls += 1
    var arr = PrimitiveArray[DType.int32](buf^, n, Optional(bm^), nulls, 0)
    return Column.from_primitive[DType.int32](arr^)


def _i64_col(vals: List[Int64]) raises -> Column[HeapRegion]:
    var l: List[Scalar[DType.int64]] = []
    for i in range(len(vals)):
        l.append(vals[i])
    return Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(l)
    )


def _batch(field_type: ArrowType, var c0: Column[HeapRegion]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("x"), field_type, True))
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(c0^)
    return rbb.build(sb.build())


def _fixture_vals() -> List[Int32]:
    """{0, 40, -5, INT32_MAX, INT32_MIN, 7}. The first two are exactly the low
    32 bits of the two positive out-of-range literals."""
    return [Int32(0), Int32(40), Int32(-5), Int32(I32_MAX), Int32(I32_MIN), Int32(7)]


def _oracle_cmp(v: Int64, lit: Int64, op: UInt8) raises -> Bool:
    """The comparison computed at INT64 width, in this file, from Mojo's own
    Int64 operators. Shares no code with the arms under test."""
    if op == BIN_GT:
        return v > lit
    elif op == BIN_LT:
        return v < lit
    elif op == BIN_EQ:
        return v == lit
    elif op == BIN_NE:
        return v != lit
    elif op == BIN_GE:
        return v >= lit
    elif op == BIN_LE:
        return v <= lit
    raise Error("_oracle_cmp: bad op " + String(Int(op)))


def _pred(lit: Int, op: UInt8) raises -> Expr:
    if op == BIN_GT:
        return col("x") > lit
    elif op == BIN_LT:
        return col("x") < lit
    elif op == BIN_EQ:
        return col("x") == lit
    elif op == BIN_NE:
        return col("x") != lit
    elif op == BIN_GE:
        return col("x") >= lit
    elif op == BIN_LE:
        return col("x") <= lit
    raise Error("_pred: bad op " + String(Int(op)))


def _op_name(op: UInt8) -> StaticString:
    if op == BIN_GT:
        return ">"
    elif op == BIN_LT:
        return "<"
    elif op == BIN_EQ:
        return "="
    elif op == BIN_NE:
        return "<>"
    elif op == BIN_GE:
        return ">="
    return "<="


def _all_ops() -> List[UInt8]:
    return [BIN_GT, BIN_LT, BIN_EQ, BIN_NE, BIN_GE, BIN_LE]


# -----------------------------------------------------------------------------
# LEG 0 — the domain test itself, at its EXACT boundaries.
# -----------------------------------------------------------------------------


def test_int_literal_fits_boundaries() raises:
    assert_true(int_literal_fits[DType.int32](Int64(I32_MAX)), "int32 max fits")
    assert_true(int_literal_fits[DType.int32](Int64(I32_MIN)), "int32 min fits")
    assert_false(
        int_literal_fits[DType.int32](Int64(I32_MAX) + 1), "max+1 does not fit"
    )
    assert_false(
        int_literal_fits[DType.int32](Int64(I32_MIN) - 1), "min-1 does not fit"
    )
    assert_false(int_literal_fits[DType.int32](Int64(TWO_P32)), "2^32 does not fit")
    assert_false(
        int_literal_fits[DType.int32](Int64(NEG_TWO_P32)), "-2^32 does not fit"
    )
    assert_true(int_literal_fits[DType.int32](Int64(0)), "0 fits")
    # Total over the family, not a hand-written int32 rule.
    assert_true(int_literal_fits[DType.int64](Int64.MAX), "int64 max fits int64")
    assert_true(int_literal_fits[DType.int16](Int64(32767)), "int16 max fits")
    assert_false(int_literal_fits[DType.int16](Int64(32768)), "int16 max+1")
    assert_true(int_literal_fits[DType.int8](Int64(-128)), "int8 min fits")
    assert_false(int_literal_fits[DType.int8](Int64(-129)), "int8 min-1")


# -----------------------------------------------------------------------------
# LEG 1 — the INT32 column comparison arm, all six ops x three out-of-range
# literals. THE DEFECT: `x > 2^32` selected every row whose value exceeds ZERO.
# -----------------------------------------------------------------------------


def _check_i32_cmp(lit: Int, op: UInt8) raises:
    var vals = _fixture_vals()
    var batch = _batch(ArrowType.INT32, _i32_col(vals))
    var mask = _eval_predicate(_pred(lit, op), batch)
    assert_equal(mask.length, len(vals), "i32 cmp length")
    for i in range(len(vals)):
        var want = _oracle_cmp(Int64(Int(vals[i])), Int64(lit), op)
        assert_equal(
            mask.get(i),
            want,
            "i32 x " + _op_name(op) + " " + String(lit) + " row " + String(i)
            + " (value " + String(Int(vals[i])) + ")",
        )
    _ = batch^


def test_i32_cmp_out_of_range_positive() raises:
    var ops = _all_ops()
    for k in range(len(ops)):
        _check_i32_cmp(TWO_P32, ops[k])


def test_i32_cmp_out_of_range_positive_colliding_40() raises:
    var ops = _all_ops()
    for k in range(len(ops)):
        _check_i32_cmp(TWO_P32_P40, ops[k])


def test_i32_cmp_out_of_range_negative() raises:
    var ops = _all_ops()
    for k in range(len(ops)):
        _check_i32_cmp(NEG_TWO_P32, ops[k])


# -----------------------------------------------------------------------------
# LEG 2 — the temporal int32-physical arm (DATE32). The same cast, a second
# column type.
# -----------------------------------------------------------------------------


def test_date32_cmp_out_of_range() raises:
    # DATE32 days-since-epoch; 20458 is the shape the SQL corpus carries.
    var vals: List[Int32] = [Int32(0), Int32(20456), Int32(20458), Int32(40)]
    var ops = _all_ops()
    for k in range(len(ops)):
        var op = ops[k]
        var batch = _batch(ArrowType.DATE32, _i32_col(vals))
        var mask = _eval_predicate(_pred(TWO_P32_P40, op), batch)
        for i in range(len(vals)):
            var want = _oracle_cmp(Int64(Int(vals[i])), Int64(TWO_P32_P40), op)
            assert_equal(
                mask.get(i),
                want,
                "date32 " + _op_name(op) + " row " + String(i),
            )
        _ = batch^


# -----------------------------------------------------------------------------
# LEG 3 — the IN-list int32 membership table. An out-of-range member can match
# NOTHING; it must not become its low 32 bits and match a real row.
# -----------------------------------------------------------------------------


def _in_list_mask(
    var values: List[ScalarValue], vals: List[Int32], at: ArrowType
) raises -> BooleanArray:
    var e = Expr.in_list_node(col("x").copy_expr(), values^)
    var batch = _batch(at, _i32_col(vals))
    var m = _eval_predicate(e, batch)
    _ = batch^
    return m^


def test_in_list_i32_out_of_range_members_match_nothing() raises:
    var vals = _fixture_vals()
    var members: List[ScalarValue] = [
        ScalarValue.from_int(TWO_P32),
        ScalarValue.from_int(TWO_P32_P40),
    ]
    var mask = _in_list_mask(members^, vals, ArrowType.INT32)
    for i in range(len(vals)):
        assert_false(
            mask.get(i),
            "IN (2^32, 2^32+40) must match no row; row " + String(i)
            + " value " + String(Int(vals[i])),
        )


def test_in_list_i32_mixed_range_keeps_the_in_range_member() raises:
    """The load-bearing half: an out-of-range member is DROPPED from the value
    table, not the whole list — the in-range member must still match."""
    var vals = _fixture_vals()
    var members: List[ScalarValue] = [
        ScalarValue.from_int(TWO_P32),
        ScalarValue.from_int(40),
    ]
    var mask = _in_list_mask(members^, vals, ArrowType.INT32)
    for i in range(len(vals)):
        assert_equal(
            mask.get(i),
            vals[i] == Int32(40),
            "IN (2^32, 40) row " + String(i),
        )


def test_in_list_date32_out_of_range_member() raises:
    var vals: List[Int32] = [Int32(20456), Int32(20458), Int32(0)]
    var members: List[ScalarValue] = [
        ScalarValue.from_int(4294987752),  # low 32 bits == 20456
        ScalarValue.from_int(20458),
    ]
    var mask = _in_list_mask(members^, vals, ArrowType.DATE32)
    var want: List[Bool] = [False, True, False]
    for i in range(len(vals)):
        assert_equal(mask.get(i), want[i], "date32 IN row " + String(i))


# -----------------------------------------------------------------------------
# LEG 4 — THE NUMERIC-DICTIONARY PAIR. Executed by nothing before this file.
# Both the LUT (`numeric_dict_filter_bool_mask`) and its flat byte-verify oracle
# (`numeric_dict_filter_via_flat`) narrowed the threshold; they are asserted
# EQUAL to each other AND to the int64-width truth, so a fix that moves only one
# of them fails here.
# -----------------------------------------------------------------------------


def _dict_i32(codes: List[Int32], dvals: List[Int32]) raises -> Column[HeapRegion]:
    var entries = List[Int64]()
    for i in range(len(dvals)):
        entries.append(Int64(Int(dvals[i])))
    var l: List[Scalar[DType.int32]] = []
    for i in range(len(codes)):
        l.append(codes[i])
    return Column.from_numeric_dict[DType.int32, DType.int32](
        PrimitiveArray[DType.int32].from_list(l), entries^
    )


def test_numeric_dict_i32_out_of_range_literal() raises:
    # dict entries [0, 40, -5, INT32_MAX]; rows pick 0,1,2,3,1,0.
    var codes: List[Int32] = [Int32(0), Int32(1), Int32(2), Int32(3), Int32(1), Int32(0)]
    var dvals: List[Int32] = [Int32(0), Int32(40), Int32(-5), Int32(I32_MAX)]
    var row_vals: List[Int64] = [0, 40, -5, Int64(I32_MAX), 40, 0]
    var lits: List[Int] = [TWO_P32, TWO_P32_P40, NEG_TWO_P32]
    var ops = _all_ops()

    for li in range(len(lits)):
        var lit = lits[li]
        for k in range(len(ops)):
            var op = ops[k]
            var p = _pred(lit, op)
            var lv = p.binary_right_ref().literal_value()
            var lut = numeric_dict_filter_bool_mask(
                _dict_i32(codes, dvals), p.binary_op(), lv
            )
            var flat = numeric_dict_filter_via_flat(
                _dict_i32(codes, dvals), p.binary_op(), lv.copy()
            )
            for i in range(len(row_vals)):
                var want = _oracle_cmp(row_vals[i], Int64(lit), op)
                assert_equal(
                    lut.get(i),
                    want,
                    "numeric-dict LUT " + _op_name(op) + " " + String(lit)
                    + " row " + String(i),
                )
                assert_equal(
                    flat.get(i),
                    want,
                    "numeric-dict FLAT " + _op_name(op) + " " + String(lit)
                    + " row " + String(i),
                )
            # End-to-end through the dispatcher arm.
            var batch = _batch(ArrowType.INT32, _dict_i32(codes, dvals))
            var e2e = _eval_predicate(_pred(lit, op), batch)
            for i in range(len(row_vals)):
                assert_equal(
                    e2e.get(i),
                    _oracle_cmp(row_vals[i], Int64(lit), op),
                    "numeric-dict e2e " + _op_name(op) + " row " + String(i),
                )
            _ = batch^


# -----------------------------------------------------------------------------
# LEG 5 — THE COMPOSITION. `i32 / 4294967296` answered NULL
# on every row because the truncated divisor WAS zero and the divide-by-zero
# guard did the right thing with it.
# -----------------------------------------------------------------------------


def _project_i32(vals: List[Int32], var e: Expr) raises -> Column[HeapRegion]:
    var batch = _batch(ArrowType.INT32, _i32_col(vals))
    var out = _eval_column_expr(e, batch)
    _ = batch^
    return out^


def _col_i64_at(c: Column[HeapRegion], i: Int) raises -> Int64:
    """Read row `i` of an INT64-or-INT32 result column at int64 width."""
    if c.arrow_type == ArrowType.INT64:
        return c.as_primitive[DType.int64]().get(i)
    return Int64(Int(c.as_primitive[DType.int32]().get(i)))


def _col_is_null_at(c: Column[HeapRegion], i: Int) raises -> Bool:
    if c.arrow_type == ArrowType.INT64:
        return c.as_primitive[DType.int64]().is_null(i)
    return c.as_primitive[DType.int32]().is_null(i)


def test_composition_div_by_out_of_range_literal_is_not_null() raises:
    var vals = _fixture_vals()
    var out = _project_i32(vals, (col("x") // TWO_P32).copy_expr())
    assert_equal(out.length(), len(vals), "div result length")
    for i in range(len(vals)):
        assert_false(
            _col_is_null_at(out, i),
            "row " + String(i) + " must NOT be NULL — the divisor is 2^32, not 0",
        )
        # Every fixture value has |v| < 2^32, so integer division by 2^32 is 0
        # under BOTH truncation and flooring — the answer does not depend on
        # this engine's toward-zero rounding, which is pinned elsewhere.
        assert_equal(
            _col_i64_at(out, i),
            Int64(0),
            "x // 2^32 row " + String(i) + " (DuckDB v1.5.3 `//`: 0)",
        )


def test_composition_div_by_literal_zero_still_answers_null() raises:
    """THE OTHER HALF, and it must not move. The divide-by-zero guard replaced a PROCESS
    KILL with NULL for a genuine zero divisor. Widening the literal must not
    reopen it."""
    var vals = _fixture_vals()
    var out = _project_i32(vals, (col("x") // 0).copy_expr())
    for i in range(len(vals)):
        assert_true(
            _col_is_null_at(out, i), "x // 0 row " + String(i) + " must be NULL"
        )


def test_arith_out_of_range_literal_add_mul_sub() raises:
    var vals = _fixture_vals()
    var add = _project_i32(vals, (col("x") + TWO_P32).copy_expr())
    var sub = _project_i32(vals, (col("x") - TWO_P32).copy_expr())
    for i in range(len(vals)):
        var v = Int64(Int(vals[i]))
        assert_equal(_col_i64_at(add, i), v + Int64(TWO_P32), "add row " + String(i))
        assert_equal(_col_i64_at(sub, i), v - Int64(TWO_P32), "sub row " + String(i))
    # `* 2` is IN RANGE as a LITERAL — the control that the int32 fast arm
    # survives — so it is asked over the rows whose PRODUCT fits int32.
    # ⛔ An int32 product that leaves int32 RAISES DuckDB 1.5.3's
    # `Out of Range Error: Overflow in multiplication of INT32 (...)!`, so the
    # full-fixture product is asserted as that raise instead of being skipped.
    var fits: List[Int32] = [Int32(0), Int32(40), Int32(-5), Int32(7)]
    var mul = _project_i32(fits, (col("x") * 2).copy_expr())
    for i in range(len(fits)):
        var v = Int64(Int(fits[i]))
        assert_equal(_col_i64_at(mul, i), v * 2, "mul-in-range row " + String(i))
    var msg = String("")
    try:
        _ = _project_i32(vals, (col("x") * 2).copy_expr())
    except e:
        msg = String(e)
    assert_true(
        msg.find("Overflow in multiplication of INT32 (2147483647 * 2)!") >= 0,
        String("INT32_MAX * 2 must raise DuckDB's sentence, got `") + msg + "`",
    )


# -----------------------------------------------------------------------------
# LEG 6 — CONTROLS THAT MUST STILL WORK. In-range literals on every site,
# including both int32 boundary values, and the INT64 column reading the SAME
# out-of-range literal (always correct; the attribution control).
# -----------------------------------------------------------------------------


def test_control_in_range_literals_unchanged() raises:
    var lits: List[Int] = [0, 40, -5, 7, I32_MAX, I32_MIN]
    var ops = _all_ops()
    for li in range(len(lits)):
        for k in range(len(ops)):
            _check_i32_cmp(lits[li], ops[k])


def test_control_int64_column_same_literal_is_correct() raises:
    var vals: List[Int64] = [0, 40, -5, Int64(I32_MAX), Int64(I32_MIN), Int64(TWO_P32)]
    var ops = _all_ops()
    for k in range(len(ops)):
        var op = ops[k]
        var batch = _batch(ArrowType.INT64, _i64_col(vals))
        var mask = _eval_predicate(_pred(TWO_P32, op), batch)
        for i in range(len(vals)):
            assert_equal(
                mask.get(i),
                _oracle_cmp(vals[i], Int64(TWO_P32), op),
                "int64-col control " + _op_name(op) + " row " + String(i),
            )
        _ = batch^


def test_control_in_range_in_list_and_dict() raises:
    var vals = _fixture_vals()
    var members: List[ScalarValue] = [
        ScalarValue.from_int(40),
        ScalarValue.from_int(I32_MIN),
    ]
    var mask = _in_list_mask(members^, vals, ArrowType.INT32)
    for i in range(len(vals)):
        assert_equal(
            mask.get(i),
            vals[i] == Int32(40) or vals[i] == Int32(I32_MIN),
            "in-range IN row " + String(i),
        )
    var codes: List[Int32] = [Int32(0), Int32(1), Int32(2)]
    var dvals: List[Int32] = [Int32(-5), Int32(0), Int32(100)]
    var p = col("x") >= 0
    var lut = numeric_dict_filter_bool_mask(
        _dict_i32(codes, dvals), p.binary_op(), p.binary_right_ref().literal_value()
    )
    var want: List[Bool] = [False, True, True]
    for i in range(3):
        assert_equal(lut.get(i), want[i], "in-range dict row " + String(i))


# -----------------------------------------------------------------------------
# LEG 7 — NULLS. The widened path must finalize through the ORIGINAL column's
# validity, so a null row stays out under 3VL for an out-of-range literal too.
# -----------------------------------------------------------------------------


def test_nullable_i32_out_of_range_absorbs_null_lanes() raises:
    var vals = _fixture_vals()
    var null_rows: List[Int] = [1, 4]  # the 40 row and the INT32_MIN row
    var ops = _all_ops()
    for k in range(len(ops)):
        var op = ops[k]
        var batch = _batch(
            ArrowType.INT32, _i32_col_nullable(vals, null_rows)
        )
        var mask = _eval_predicate(_pred(TWO_P32_P40, op), batch)
        for i in range(len(vals)):
            var is_null_row = i == 1 or i == 4
            if is_null_row:
                assert_false(
                    mask.get(i),
                    "null row " + String(i) + " must not be selected ("
                    + _op_name(op) + ")",
                )
            else:
                assert_equal(
                    mask.get(i),
                    _oracle_cmp(Int64(Int(vals[i])), Int64(TWO_P32_P40), op),
                    "nullable i32 " + _op_name(op) + " row " + String(i),
                )
        _ = batch^


def test_nullable_i32_div_out_of_range_keeps_null_mask() raises:
    var vals = _fixture_vals()
    var null_rows: List[Int] = [0, 3]
    var batch = _batch(ArrowType.INT32, _i32_col_nullable(vals, null_rows))
    var out = _eval_column_expr((col("x") // TWO_P32).copy_expr(), batch)
    for i in range(len(vals)):
        if i == 0 or i == 3:
            assert_true(
                _col_is_null_at(out, i), "null row " + String(i) + " stays NULL"
            )
        else:
            assert_false(
                _col_is_null_at(out, i), "valid row " + String(i) + " stays valid"
            )
            assert_equal(_col_i64_at(out, i), Int64(0), "row " + String(i))
    _ = batch^


def main() raises:
    var suite = TestSuite()
    suite.test[test_int_literal_fits_boundaries]()
    suite.test[test_i32_cmp_out_of_range_positive]()
    suite.test[test_i32_cmp_out_of_range_positive_colliding_40]()
    suite.test[test_i32_cmp_out_of_range_negative]()
    suite.test[test_date32_cmp_out_of_range]()
    suite.test[test_in_list_i32_out_of_range_members_match_nothing]()
    suite.test[test_in_list_i32_mixed_range_keeps_the_in_range_member]()
    suite.test[test_in_list_date32_out_of_range_member]()
    suite.test[test_numeric_dict_i32_out_of_range_literal]()
    suite.test[test_composition_div_by_out_of_range_literal_is_not_null]()
    suite.test[test_composition_div_by_literal_zero_still_answers_null]()
    suite.test[test_arith_out_of_range_literal_add_mul_sub]()
    suite.test[test_control_in_range_literals_unchanged]()
    suite.test[test_control_int64_column_same_literal_is_correct]()
    suite.test[test_control_in_range_in_list_and_dict]()
    suite.test[test_nullable_i32_out_of_range_absorbs_null_lanes]()
    suite.test[test_nullable_i32_div_out_of_range_keeps_null_mask]()
    suite^.run()
