# =============================================================================
# test_predicate_over_narrow_and_bool_columns.mojo
# =============================================================================
#
# ★★ THE PREDICATE LADDER MUST SERVE EVERY NUMERIC COLUMN TYPE. With arms for
#    INT64, INT32, UINT64, FLOAT64, DECIMAL128, DICTIONARY, STRING and
#    LARGE_STRING only, `WHERE v > 0` over an `int8` column falls to the `else`:
#
#        PipelineCompiler: unsupported column type for predicate: int8
#
#    across `bool`, `float32`, `int16`, `int8` and `uint8`. DuckDB v1.5.3
#    ANSWERS every one of those cells, so none of those refusals is worth
#    keeping.
#
# ⛔⛔ A NEW ARM IS NOT DONE WHEN THE INTEGER LITERAL WORKS — §3 IS THE HALF
#    THAT GETS SKIPPED. The arm is selected by the COLUMN's type and then reads
#    ONE `ScalarValue` field; an unpopulated field is a WELL-FORMED ZERO. Two
#    facts, both on this exact ladder:
#      * a UINT64 arm reading `int_val` answers `v > 2.0` as `v > 0` (`5 rows,
#        want 3`), and a float literal is not exotic: a spreadsheet-formula
#        front end has no integer literal at all, so it sends a FLOAT for every
#        numeric predicate.
#      * `literal_arm_domain.literal_is_readable_by_column` does NOT stop it:
#        `col_at.is_numeric` deliberately ADMITS a float literal so the
#        INT64/INT32 promotion can pick it up. A new integer arm inherits the
#        admission without the promotion.
#    So every integer case below has a FLOAT-LITERAL twin, including a
#    FRACTIONAL one (`v > 0.5`), which is the spelling an integer threshold
#    cannot imitate.
#
# ⛔ AND §4 IS THE FLOAT32 DOMAIN TRAP. The literal is a Float64
#    (`ScalarValue.float_val`) and the column is float32, so the comparison must
#    happen in a domain holding BOTH. Rounding the THRESHOLD to float32 makes
#    `3.4999998` and `3.5` the same number and answers `v > 3.4999998` as
#    `v > 3.5` — one row short, silently. Same shape as the INT32-LITERAL-DOMAIN
#    defect: widen the column, never narrow the literal.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from komira_buffer.heap_region import HeapRegion
from komira_plan_expr.expr import (
    Expr,
    BIN_EQ,
    BIN_GE,
    BIN_GT,
    BIN_LE,
    BIN_LT,
    BIN_NE,
    UN_NOT,
)
from komira_plan_expr.scalar_value import ScalarValue

from komira_batch_eval.eval_predicate import _eval_predicate
from komira_batch_eval.predicate_numeric_dict import numeric_dict_filter_via_flat


# -----------------------------------------------------------------------------
# Fixtures. Values are the cross-surface corpus's own,
# type boundaries included, because a
# kernel that widens or negates through the wrong width gets ONLY the boundary
# wrong and every interior value right.
# -----------------------------------------------------------------------------


def _num_batch[
    dtype: DType
](
    imm values: List[Scalar[dtype]], at: ArrowType, imm nulls: List[Int]
) raises -> RecordBatch:
    var n = len(values)
    var arr: PrimitiveArray[dtype]
    if len(nulls) > 0:
        # `_set_null` requires an existing validity bitmap; `from_list` builds a
        # NON-nullable array. So the nullable case allocates all-valid, writes
        # the values, then punches — leaving the data slot holding a value that
        # WOULD pass the predicate, which is what makes §5 discriminating.
        arr = PrimitiveArray[dtype].allocate_nullable(n)
        for i in range(n):
            arr.set(i, values[i])
        for i in range(len(nulls)):
            arr._set_null(nulls[i])
    else:
        var vals = values.copy()
        arr = PrimitiveArray[dtype].from_list(vals^)
    var col = Column.from_primitive_with_arrow_type[dtype](arr^, at)
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(col^)
    var sb = SchemaBuilder()
    sb.add_field(Field(String("v"), at, len(nulls) > 0))
    return rbb.build(sb.build())


def _bool_batch(imm values: List[Bool], imm nulls: List[Int]) raises -> RecordBatch:
    var n = len(values)
    var arr = BooleanArray.allocate_nullable(n) if len(
        nulls
    ) > 0 else BooleanArray.allocate(n)
    for i in range(n):
        arr.set(i, values[i])
    for i in range(len(nulls)):
        arr._set_null(nulls[i])
    var col = Column.from_boolean(arr^)
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(col^)
    var sb = SchemaBuilder()
    sb.add_field(Field(String("v"), ArrowType.BOOL, len(nulls) > 0))
    return rbb.build(sb.build())


def _pred_int(op: UInt8, lit: Int) -> Expr:
    return Expr.binary(op, Expr.col_ref("v"), Expr.literal(ScalarValue.from_int(lit)))


def _pred_float(op: UInt8, lit: Float64) -> Expr:
    return Expr.binary(
        op, Expr.col_ref("v"), Expr.literal(ScalarValue.from_float(lit))
    )


def _pred_bool(op: UInt8, lit: Bool) -> Expr:
    return Expr.binary(
        op, Expr.col_ref("v"), Expr.literal(ScalarValue.from_bool(lit))
    )


def _assert_mask(
    imm batch: RecordBatch, imm pred: Expr, imm want: List[Bool], imm label: String
) raises:
    var mask = _eval_predicate(pred, batch)
    assert_equal(mask.length, len(want), label + ": mask length")
    for i in range(len(want)):
        assert_true(
            mask.get(i) == want[i],
            label + ": row " + String(i) + " want " + String(want[i])
            + " got " + String(mask.get(i)),
        )


# =============================================================================
# §3 — ⛔ THE FLOAT LITERAL. A spreadsheet-formula front end sends one for
#      EVERY numeric predicate, so this is not a corner case.
# =============================================================================


def test_int8_float_literal_integral() raises:
    """`v > 0.0` must answer exactly what `v > 0` answers. Reading `int_val` on
    a `from_float` literal gives a well-formed ZERO, which is the same number
    here BY COINCIDENCE — so this case alone cannot falsify the defect and the
    FRACTIONAL one below is the load-bearing half."""
    var v: List[Scalar[DType.int8]] = [
        Int8(-128), Int8(-1), Int8(0), Int8(1), Int8(126), Int8(127)
    ]
    _assert_mask(
        _num_batch[DType.int8](v^, ArrowType.INT8, List[Int]()),
        _pred_float(BIN_GT, 0.0),
        [False, False, False, True, True, True],
        String("int8 v > 0.0"),
    )


def test_int8_float_literal_fractional() raises:
    """★★ THE FALSIFIER. `v > 0.5` keeps `{1, 126, 127}` and `v < 0.5` keeps
    `{-128, -1, 0}`. An arm reading `int_val` sees `0` and answers `v > 0` /
    `v < 0` — which differ from these at row 2 (`v = 0`) in the `<` case. No
    integer literal can spell this threshold."""
    var base: List[Scalar[DType.int8]] = [
        Int8(-128), Int8(-1), Int8(0), Int8(1), Int8(126), Int8(127)
    ]

    _assert_mask(
        _num_batch[DType.int8](base, ArrowType.INT8, List[Int]()), _pred_float(BIN_GT, 0.5), [False, False, False, True, True, True],
        String("int8 v > 0.5"),
    )
    _assert_mask(
        _num_batch[DType.int8](base, ArrowType.INT8, List[Int]()), _pred_float(BIN_LT, 0.5), [True, True, True, False, False, False],
        String("int8 v < 0.5"),
    )
    _assert_mask(
        _num_batch[DType.int8](base, ArrowType.INT8, List[Int]()), _pred_float(BIN_LT, -0.5), [True, True, False, False, False, False],
        String("int8 v < -0.5"),
    )
    _assert_mask(
        _num_batch[DType.int8](base, ArrowType.INT8, List[Int]()), _pred_float(BIN_EQ, 0.5), [False, False, False, False, False, False],
        String("int8 v = 0.5 — no integer equals it"),
    )


def test_uint8_float_literal_fractional() raises:
    var base: List[Scalar[DType.uint8]] = [
        UInt8(0), UInt8(1), UInt8(2), UInt8(128), UInt8(254), UInt8(255)
    ]

    _assert_mask(
        _num_batch[DType.uint8](base, ArrowType.UINT8, List[Int]()), _pred_float(BIN_GT, 2.5), [False, False, False, True, True, True],
        String("uint8 v > 2.5"),
    )
    _assert_mask(
        _num_batch[DType.uint8](base, ArrowType.UINT8, List[Int]()), _pred_float(BIN_LE, 2.5), [True, True, True, False, False, False],
        String("uint8 v <= 2.5"),
    )


def test_int16_float_literal_fractional() raises:
    var v: List[Scalar[DType.int16]] = [
        Int16(-32768), Int16(-1), Int16(0), Int16(1), Int16(32766), Int16(32767)
    ]
    _assert_mask(
        _num_batch[DType.int16](v^, ArrowType.INT16, List[Int]()),
        _pred_float(BIN_GT, 0.5),
        [False, False, False, True, True, True],
        String("int16 v > 0.5"),
    )


def test_float32_integer_literal() raises:
    """The symmetric direction: a FLOAT column against an INTEGER literal. The
    SQL door spells `v > 3` this way, and `float_val` is a well-formed zero for
    a `from_int` literal, so reading it answers `v > 0.0` — the whole table."""
    var v: List[Scalar[DType.float32]] = [
        Float32(-1.5), Float32(0.5), Float32(2.5), Float32(3.5), Float32(4.5),
        Float32(6.5)
    ]
    _assert_mask(
        _num_batch[DType.float32](v^, ArrowType.FLOAT32, List[Int]()),
        _pred_int(BIN_GT, 3),
        [False, False, False, True, True, True],
        String("float32 v > 3"),
    )


# =============================================================================
# §4 — ⛔ THE FLOAT32 DOMAIN. `3.4999998` and `3.5` are the SAME float32.
# =============================================================================


def test_float32_literal_between_two_float32_values() raises:
    """★★ WIDEN THE COLUMN, NEVER NARROW THE LITERAL. `1.00000006` sits strictly
    between `Float32(1.0)` and the next float32 up, so `v > 1.00000006` must
    EXCLUDE the `1.0` row. Rounding the threshold into float32 makes it exactly
    `1.0` and `v > 1.0` is the same mask here — so the discriminating row is the
    `>=`/`<=` pair below, where a rounded threshold ADMITS the 1.0 row."""
    var base: List[Scalar[DType.float32]] = [
        Float32(1.0), Float32(2.0), Float32(3.0), Float32(4.0)
    ]

    # 1.00000006 > Float32(1.0) == 1.0 exactly, and < Float32(1.0000001).
    _assert_mask(
        _num_batch[DType.float32](base, ArrowType.FLOAT32, List[Int]()), _pred_float(BIN_LE, 1.00000006), [True, False, False, False],
        String("float32 v <= 1.00000006"),
    )
    _assert_mask(
        _num_batch[DType.float32](base, ArrowType.FLOAT32, List[Int]()), _pred_float(BIN_GE, 1.00000006), [False, True, True, True],
        String("float32 v >= 1.00000006 — the 1.0 row is BELOW it"),
    )
    _assert_mask(
        _num_batch[DType.float32](base, ArrowType.FLOAT32, List[Int]()), _pred_float(BIN_EQ, 1.00000006), [False, False, False, False],
        String("float32 v = 1.00000006 — no float32 equals it"),
    )


# =============================================================================
# §5 — THREE-VALUED LOGIC. A NULL row is neither kept nor rejected by the
#      value; it is UNKNOWN, and `filter` drops it. The nulled slots carry a
#      value that WOULD pass, so a validity-blind mask keeps them.
# =============================================================================


def test_null_rows_are_not_kept_int8() raises:
    var v: List[Scalar[DType.int8]] = [
        Int8(-1), Int8(127), Int8(0), Int8(1), Int8(126), Int8(2)
    ]
    _assert_mask(
        _num_batch[DType.int8](v^, ArrowType.INT8, [1, 4]),
        _pred_int(BIN_GT, 0),
        [False, False, False, True, False, True],
        String("int8 v > 0 with NULLs at 1, 4 holding 127 and 126"),
    )


def test_null_rows_are_not_kept_float32() raises:
    var v: List[Scalar[DType.float32]] = [
        Float32(1.5), Float32(9.5), Float32(2.5), Float32(4.5), Float32(9.5),
        Float32(6.5)
    ]
    _assert_mask(
        _num_batch[DType.float32](v^, ArrowType.FLOAT32, [1, 4]),
        _pred_float(BIN_GT, 3.5),
        [False, False, False, True, False, True],
        String("float32 v > 3.5 with NULLs at 1, 4 holding 9.5"),
    )


def test_null_rows_are_not_kept_bool() raises:
    _assert_mask(
        _bool_batch([True, True, False, True, True, False], [1, 4]),
        _pred_bool(BIN_EQ, True),
        [True, False, False, True, False, False],
        String("bool v = TRUE with NULLs at 1, 4 holding TRUE"),
    )


def test_null_rows_are_not_kept_uint8() raises:
    var v: List[Scalar[DType.uint8]] = [
        UInt8(0), UInt8(255), UInt8(2), UInt8(128), UInt8(255), UInt8(254)
    ]
    _assert_mask(
        _num_batch[DType.uint8](v^, ArrowType.UINT8, [1, 4]),
        _pred_int(BIN_GT, 2),
        [False, False, False, True, False, True],
        String("uint8 v > 2 with NULLs at 1, 4 holding 255"),
    )


# =============================================================================
# §6 — `WHERE flag` — THE BARE BOOLEAN COLUMN AS THE WHOLE PREDICATE.
# =============================================================================
#
# ★ THE PLAINEST BOOLEAN FILTER THERE IS, AND THE LADDER HAD NO ARM FOR IT.
#   `_eval_predicate` dispatched on `expr.tag` over BINARY_OP / ALIAS /
#   UNARY_OP / IN_LIST / STRING_OP / REGEXP / LITERAL / AGG_FN and fell to the
#   `else` for a bare column reference:
#
#       PipelineCompiler: unsupported predicate expression tag: 0
#
#   MEASURED through the real binary from a TypeScript e2e chain, as
#   PLAN_ENDPOINT_EXECUTION_FAILED(20): `lf.filter(col('flag'))` AND
#   `lf.filter(col('flag').not)` both died on that one sentence. Tag 0 is
#   `EXPR_COL_REF`.
#
# ⚠ THE `NOT` CASE IS NOT A SECOND DEFECT. `UN_NOT` recurses into
#   `_eval_predicate` on its child, so the unary arm reached the same wall one
#   frame down — which is why BOTH spellings reported tag 0 and why ONE arm
#   fixes both. §6.2 asserts that, rather than assuming it.
#
# ⛔ AND THE CONTROL IS §2's `test_bool_eq`, WHICH PASSED ALL ALONG. The mask
#   machinery for a BOOL column existed (`_eval_bool_col_vs_literal`, offset-
#   aware, 3VL-correct); only the SPELLING `WHERE flag` had no way to reach it.
#   `WHERE flag` and `WHERE flag = TRUE` are the same predicate under SQL 3VL —
#   TRUE passes, FALSE fails, NULL is UNKNOWN and is dropped by both — so §6.3
#   asserts the two spellings agree ROW FOR ROW rather than each against a
#   hand-written expectation, which is the assertion a desugar cannot fake.
# =============================================================================


def test_bare_bool_column_is_the_predicate() raises:
    """§6.1 — `WHERE flag`. The mask IS the column."""
    _assert_mask(
        _bool_batch([True, False, True, False, True, False], List[Int]()),
        Expr.col_ref("v"),
        [True, False, True, False, True, False],
        String("WHERE v (bare bool column)"),
    )


def test_not_of_a_bare_bool_column() raises:
    """§6.2 — `WHERE NOT flag`. Reported the SAME tag 0, one frame down."""
    _assert_mask(
        _bool_batch([True, False, True, False, True, False], List[Int]()),
        Expr.unary(UN_NOT, Expr.col_ref("v")),
        [False, True, False, True, False, True],
        String("WHERE NOT v (bare bool column)"),
    )


# =============================================================================
# §7 — ⛔⛔ EVERY INTEGER **TAG** x EVERY NUMERIC COLUMN x EVERY OPERATOR
# =============================================================================
#
# EVERY SECTION ABOVE SPELLS ITS INTEGER LITERAL WITH `from_int` — an INT64 tag
# — so the whole file could only ever ask what the ladder does with ONE of the
# eight integer tags the plan wire carries (`plan_wire_codec._dtype_from_wire`
# decodes int8/16/32/64 and uint8/16/32/64). The arms pick the `ScalarValue`
# field to read from the COLUMN, so a tag they did not expect is read as
# whatever that field holds. MEASURED through this function, before the
# repair, by a throwaway probe:
#
#   int64  col [-5,0,3,MAX]   v >  2**64-1 (uint64)   ->  0111   want 0000
#   int64  col [-5,0,3,MAX]   v <  2**64-1 (uint64)   ->  1000   want 1111
#   f64    col [0.5,3,10]     v >  3       (uint8)    ->  111    want 001
#
# i.e. (a) a uint64 literal above Int64.MAX read SIGNED as a negative threshold,
# and (b) the FLOAT64 arm's int-literal promotion ALLOW-LISTED int64/int32, so
# every other tag read `float_val`, a well-formed ZERO.
#
# THE ORACLE, AND WHY IT IS NOT THE IMPLEMENTATION'S. Every literal below is
# built by ITS OWN TAG'S FACTORY and carries, beside it, the value this test
# KNOWS it holds (an Int128, so no width can wrap it) and DuckDB v1.5.3's cast
# of that value to DOUBLE and to FLOAT — each through its
# own SQL type (`CAST(9007199791611905::BIGINT AS FLOAT)` =
# 9007200328482816.0; the DOUBLE cast of the same value is 9007199791611904.0).
#   * an INTEGER column is graded in EXACT Int128 arithmetic;
#   * a FLOAT64 column against `CAST(lit AS DOUBLE)`, a FLOAT32 one against
#     `CAST(lit AS FLOAT)` — DuckDB's binder casts the integer to the COLUMN's
#     float type (`typeof(1::FLOAT + 1::UBIGINT)` = FLOAT; `f32 = 16777217`
#     selects the 16777216.0 row). ⚠ That makes the FLOAT32 grade a SEMANTIC
#     statement, not only a bug-fix one: before the repair the float32 arm
#     compared `Float64(int_val)` EXACTLY, which DuckDB does not do.
#   * a NULL row (its data slot holding 3, which `= 3` would select) is never
#     kept.
# =============================================================================

comptime I128 = SIMD[DType.int128, 1]
comptime _I64_MAX_I128: I128 = 9223372036854775807


struct _TagCases(Movable):
    """Parallel lists: the literal, the value it holds, and DuckDB's DOUBLE and
    FLOAT casts of that value."""

    var lits: List[ScalarValue]
    var exact: List[I128]
    var as_f64: List[Float64]
    var as_f32: List[Float32]
    var names: List[String]

    def __init__(out self):
        self.lits = List[ScalarValue]()
        self.exact = List[I128]()
        self.as_f64 = List[Float64]()
        self.as_f32 = List[Float32]()
        self.names = List[String]()

    def add(
        mut self,
        var lit: ScalarValue,
        exact: I128,
        f64: Float64,
        f32: Float32,
        name: String,
    ):
        self.lits.append(lit^)
        self.exact.append(exact)
        self.as_f64.append(f64)
        self.as_f32.append(f32)
        self.names.append(name)


def _every_integer_tag() -> _TagCases:
    """Each of the eight tags at its own boundaries, plus the two values where
    Int64 -> Float stops being exact: `2**53+1` (DOUBLE rounds it DOWN to
    2**53) and `2**53+2**29+1` (FLOAT rounds it UP to `2**53+2**30` — and a
    cast through DOUBLE first would land on 2**53, the OTHER neighbour)."""
    var c = _TagCases()
    c.add(ScalarValue.from_int8(Int8(-128)), I128(-128), -128.0, Float32(-128.0), "int8 -128")
    c.add(ScalarValue.from_int8(Int8(-1)), I128(-1), -1.0, Float32(-1.0), "int8 -1")
    c.add(ScalarValue.from_int8(Int8(3)), I128(3), 3.0, Float32(3.0), "int8 3")
    c.add(ScalarValue.from_int8(Int8(127)), I128(127), 127.0, Float32(127.0), "int8 127")
    c.add(ScalarValue.from_int16(Int16(-32768)), I128(-32768), -32768.0, Float32(-32768.0), "int16 -32768")
    c.add(ScalarValue.from_int16(Int16(3)), I128(3), 3.0, Float32(3.0), "int16 3")
    c.add(ScalarValue.from_int16(Int16(32767)), I128(32767), 32767.0, Float32(32767.0), "int16 32767")
    c.add(ScalarValue.from_int32(Int32(-2147483648)), I128(-2147483648), -2147483648.0, Float32(-2147483648.0), "int32 MIN")
    c.add(ScalarValue.from_int32(Int32(3)), I128(3), 3.0, Float32(3.0), "int32 3")
    c.add(ScalarValue.from_int32(Int32(2147483647)), I128(2147483647), 2147483647.0, Float32(2147483648.0), "int32 MAX")
    c.add(ScalarValue.from_int64(Int64(-9223372036854775808)), I128(-9223372036854775808), -9223372036854775808.0, Float32(-9223372036854775808.0), "int64 MIN")
    c.add(ScalarValue.from_int64(Int64(-1)), I128(-1), -1.0, Float32(-1.0), "int64 -1")
    c.add(ScalarValue.from_int64(Int64(3)), I128(3), 3.0, Float32(3.0), "int64 3")
    c.add(ScalarValue.from_int64(Int64(9007199254740993)), I128(9007199254740993), 9007199254740992.0, Float32(9007199254740992.0), "int64 2**53+1")
    c.add(ScalarValue.from_int64(Int64(9007199791611905)), I128(9007199791611905), 9007199791611904.0, Float32(9007200328482816.0), "int64 2**53+2**29+1")
    c.add(ScalarValue.from_int64(Int64(9223372036854775807)), I128(9223372036854775807), 9223372036854775808.0, Float32(9223372036854775808.0), "int64 MAX")
    c.add(ScalarValue.from_uint8(UInt8(0)), I128(0), 0.0, Float32(0.0), "uint8 0")
    c.add(ScalarValue.from_uint8(UInt8(3)), I128(3), 3.0, Float32(3.0), "uint8 3")
    c.add(ScalarValue.from_uint8(UInt8(255)), I128(255), 255.0, Float32(255.0), "uint8 255")
    c.add(ScalarValue.from_uint16(UInt16(3)), I128(3), 3.0, Float32(3.0), "uint16 3")
    c.add(ScalarValue.from_uint16(UInt16(65535)), I128(65535), 65535.0, Float32(65535.0), "uint16 65535")
    c.add(ScalarValue.from_uint32(UInt32(3)), I128(3), 3.0, Float32(3.0), "uint32 3")
    c.add(ScalarValue.from_uint32(UInt32(4294967295)), I128(4294967295), 4294967295.0, Float32(4294967296.0), "uint32 MAX")
    c.add(ScalarValue.from_uint64(UInt64(0)), I128(0), 0.0, Float32(0.0), "uint64 0")
    c.add(ScalarValue.from_uint64(UInt64(3)), I128(3), 3.0, Float32(3.0), "uint64 3")
    c.add(ScalarValue.from_uint64(UInt64(9007199791611905)), I128(9007199791611905), 9007199791611904.0, Float32(9007200328482816.0), "uint64 2**53+2**29+1")
    c.add(ScalarValue.from_uint64(UInt64(9223372036854775807)), I128(9223372036854775807), 9223372036854775808.0, Float32(9223372036854775808.0), "uint64 2**63-1")
    c.add(ScalarValue.from_uint64(UInt64(9223372036854775808)), I128(9223372036854775808), 9223372036854775808.0, Float32(9223372036854775808.0), "uint64 2**63")
    c.add(ScalarValue.from_uint64(UInt64(18446744073709551615)), I128(18446744073709551615), 18446744073709551616.0, Float32(18446744073709551616.0), "uint64 2**64-1")
    return c^


def _six_ops() -> List[UInt8]:
    var ops: List[UInt8] = [BIN_LT, BIN_LE, BIN_GT, BIN_GE, BIN_EQ, BIN_NE]
    return ops^


def _op_name(op: UInt8) -> String:
    if op == BIN_LT:
        return "<"
    if op == BIN_LE:
        return "<="
    if op == BIN_GT:
        return ">"
    if op == BIN_GE:
        return ">="
    if op == BIN_EQ:
        return "="
    return "<>"


def _cmp_i128(op: UInt8, a: I128, b: I128) -> Bool:
    if op == BIN_LT:
        return a < b
    if op == BIN_LE:
        return a <= b
    if op == BIN_GT:
        return a > b
    if op == BIN_GE:
        return a >= b
    if op == BIN_EQ:
        return a == b
    return a != b


def _cmp_f64(op: UInt8, a: Float64, b: Float64) -> Bool:
    if op == BIN_LT:
        return a < b
    if op == BIN_LE:
        return a <= b
    if op == BIN_GT:
        return a > b
    if op == BIN_GE:
        return a >= b
    if op == BIN_EQ:
        return a == b
    return a != b


# How each family decides which of its cells are the CONTROL — the cells the
# pre-repair ladder already answered right, which must pass before AND after.
comptime _KIND_INT = 0  # an integer column whose domain embeds in Int64
comptime _KIND_U64 = 1
comptime _KIND_F64 = 2
comptime _KIND_F32 = 3
comptime _KIND_DICT_FLOAT = 4


def _is_control_cell(kind: Int, c: Int, imm cases: _TagCases) -> Bool:
    if kind == _KIND_INT:
        # A value an `int_val` read gets right: everything but a uint64 tag at
        # or above 2**63.
        return cases.exact[c] <= _I64_MAX_I128
    if kind == _KIND_U64:
        # Repaired by "fix(compiler): a UINT64 predicate reads an
        # UNSIGNED-TAGGED literal unsigned" — the whole sweep is already a
        # control.
        return True
    if kind == _KIND_F64:
        # The two tags the old promotion ALLOW-LISTED.
        var dt = cases.lits[c].dtype
        return dt == DType.int64 or dt == DType.int32
    if kind == _KIND_F32:
        # The old arm compared `Float64(int_val)`; that agrees with the FLOAT
        # cast exactly where the value is a Float32 already.
        return (
            cases.exact[c] <= _I64_MAX_I128
            and cases.as_f64[c] == cases.as_f32[c].cast[DType.float64]()
        )
    return False  # a float DICTIONARY read `float_val` for every integer tag


def _bits(imm m: List[Bool]) -> String:
    var s = String("")
    for i in range(len(m)):
        s += "1" if m[i] else "0"
    return s


def _grade(
    imm batch: RecordBatch,
    imm cases: _TagCases,
    kind: Int,
    control_only: Bool,
    imm want_of: List[List[List[Bool]]],
    imm label: String,
    mut fails: List[String],
) raises -> Int:
    """Evaluate every (case, op) cell and append one line per WRONG cell to
    `fails`. `want_of[c][o]` is the oracle mask. Returns the cells graded."""
    var ops = _six_ops()
    var graded = 0
    for c in range(len(cases.lits)):
        if control_only and not _is_control_cell(kind, c, cases):
            continue
        for o in range(len(ops)):
            graded += 1
            var got = List[Bool]()
            var err = String("")
            try:
                var m = _eval_predicate(
                    Expr.binary(
                        ops[o], Expr.col_ref("v"), Expr.literal(cases.lits[c].copy())
                    ),
                    batch,
                )
                for i in range(m.length):
                    got.append(m.get(i))
            except e:
                err = String(e)
            ref want = want_of[c][o]
            var raised = err.byte_length() > 0
            var ok = not raised and len(got) == len(want)
            if ok:
                for i in range(len(want)):
                    if got[i] != want[i]:
                        ok = False
            if not ok:
                var shown = ("RAISE " + err) if raised else _bits(got)
                fails.append(
                    label + " | v " + _op_name(ops[o]) + " " + cases.names[c]
                    + " | got " + shown + " want " + _bits(want)
                )
    return graded


def _report(imm fails: List[String], graded: Int, imm label: String) raises:
    var msg = (
        label + ": " + String(len(fails)) + " of " + String(graded)
        + " cells WRONG"
    )
    for i in range(min(len(fails), 12)):
        msg += "\n    " + fails[i]
    assert_true(graded > 0, label + ": graded ZERO cells — a vacuous pass")
    assert_true(len(fails) == 0, msg)


def _sweep_int_column[
    dtype: DType
](at: ArrowType, imm rows: List[I128], kind: Int, control_only: Bool) raises:
    """An integer column (flat), graded in exact Int128 arithmetic, with one
    trailing NULL row whose data slot holds 3."""
    var vals = List[Scalar[dtype]]()
    for i in range(len(rows)):
        vals.append(rows[i].cast[dtype]())
    vals.append(Scalar[dtype](3))
    var nulls: List[Int] = [len(rows)]
    var batch = _num_batch[dtype](vals, at, nulls)
    var cases = _every_integer_tag()
    var ops = _six_ops()
    var want_of = List[List[List[Bool]]]()
    for c in range(len(cases.lits)):
        var per_op = List[List[Bool]]()
        for o in range(len(ops)):
            var w = List[Bool]()
            for i in range(len(rows)):
                w.append(_cmp_i128(ops[o], rows[i], cases.exact[c]))
            w.append(False)  # the NULL row
            per_op.append(w^)
        want_of.append(per_op^)
    var fails = List[String]()
    var label = String(at) + " column"
    if control_only:
        label += " (CONTROL cells)"
    var graded = _grade(batch, cases, kind, control_only, want_of, label, fails)
    _report(fails, graded, label)


def _sweep_float_column[
    dtype: DType
](at: ArrowType, imm rows: List[Float64], control_only: Bool) raises:
    """A float column (flat), graded against DuckDB's cast of the literal to the
    COLUMN's float type. `rows` must be values of `dtype`."""
    comptime is_f32 = dtype == DType.float32
    var vals = List[Scalar[dtype]]()
    for i in range(len(rows)):
        vals.append(rows[i].cast[dtype]())
    vals.append(Scalar[dtype](3.0))
    var nulls: List[Int] = [len(rows)]
    var batch = _num_batch[dtype](vals, at, nulls)
    var cases = _every_integer_tag()
    var ops = _six_ops()
    var want_of = List[List[List[Bool]]]()
    for c in range(len(cases.lits)):
        var thr = cases.as_f64[c]
        comptime if is_f32:
            thr = cases.as_f32[c].cast[DType.float64]()
        var per_op = List[List[Bool]]()
        for o in range(len(ops)):
            var w = List[Bool]()
            for i in range(len(rows)):
                w.append(_cmp_f64(ops[o], rows[i], thr))
            w.append(False)
            per_op.append(w^)
        want_of.append(per_op^)
    var fails = List[String]()
    var label = String(at) + " column"
    if control_only:
        label += " (CONTROL cells)"
    var kind = _KIND_F32 if is_f32 else _KIND_F64
    var graded = _grade(batch, cases, kind, control_only, want_of, label, fails)
    _report(fails, graded, label)


def _i8_rows() -> List[I128]:
    var r: List[I128] = [I128(-128), I128(-1), I128(0), I128(3), I128(127)]
    return r^


def _i16_rows() -> List[I128]:
    var r: List[I128] = [I128(-32768), I128(-1), I128(3), I128(32767)]
    return r^


def _i32_rows() -> List[I128]:
    var r: List[I128] = [I128(-2147483648), I128(-1), I128(3), I128(2147483647)]
    return r^


def _i64_rows() -> List[I128]:
    var r: List[I128] = [
        I128(-9223372036854775808), I128(-1), I128(3), I128(9007199254740992),
        I128(9007199254740993), I128(9223372036854775807),
    ]
    return r^


def _u8_rows() -> List[I128]:
    var r: List[I128] = [I128(0), I128(3), I128(255)]
    return r^


def _u16_rows() -> List[I128]:
    var r: List[I128] = [I128(0), I128(3), I128(65535)]
    return r^


def _u32_rows() -> List[I128]:
    var r: List[I128] = [I128(0), I128(3), I128(4294967295)]
    return r^


def _u64_rows() -> List[I128]:
    var r: List[I128] = [
        I128(0), I128(3), I128(9223372036854775807), I128(9223372036854775808),
        I128(18446744073709551615),
    ]
    return r^


def _f64_rows() -> List[Float64]:
    var r: List[Float64] = [
        -1.5, 0.0, 3.0, 2147483647.0, 9007199254740992.0, 9007199791611904.0,
        9223372036854775808.0, 18446744073709551616.0,
    ]
    return r^


def _f32_rows() -> List[Float64]:
    """Every value is a Float32 value, so the column holds exactly these."""
    var r: List[Float64] = [
        -1.5, 0.0, 3.0, 2147483648.0, 4294967296.0, 9007199254740992.0,
        9007200328482816.0, 18446744073709551616.0,
    ]
    return r^


# =============================================================================
# §8 — THE NUMERIC **DICTIONARY** ARMS. The LUT and its byte-verify
#      oracle had NO int-literal
#      promotion at all for a FLOAT dictionary, so even the INT64 literal every
#      door emits read `float_val` — a well-formed ZERO. MEASURED before the
#      repair: `dict<f64> [0.5,3,10]  v > 3 (int64)  ->  111, want 001`.
# =============================================================================


def _codes_identity(n: Int) raises -> PrimitiveArray[DType.int32]:
    """Row i holds code i, then one more row reusing code 0 — so a LUT that
    answered per ROW instead of per ENTRY would disagree with itself."""
    var l = List[Scalar[DType.int32]]()
    for i in range(n):
        l.append(Int32(i))
    l.append(Int32(0))
    return PrimitiveArray[DType.int32].from_list(l)


def _dict_batch(var c: Column[HeapRegion], logical: ArrowType) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("v"), logical, False))
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(c^)
    return rbb.build(sb.build())


def _sweep_int_dict[
    val_dt: DType
](imm entries: List[I128], logical: ArrowType, control_only: Bool) raises:
    var bits = List[Int64]()
    for i in range(len(entries)):
        bits.append(entries[i].cast[DType.int64]())
    var col = Column.from_numeric_dict[DType.int32, val_dt](
        _codes_identity(len(entries)), bits^
    )
    var batch = _dict_batch(col^, logical)
    var rows = entries.copy()
    rows.append(entries[0])
    var cases = _every_integer_tag()
    var ops = _six_ops()
    var want_of = List[List[List[Bool]]]()
    for c in range(len(cases.lits)):
        var per_op = List[List[Bool]]()
        for o in range(len(ops)):
            var w = List[Bool]()
            for i in range(len(rows)):
                w.append(_cmp_i128(ops[o], rows[i], cases.exact[c]))
            per_op.append(w^)
        want_of.append(per_op^)
    var fails = List[String]()
    var label = "dict<" + String(val_dt) + ">"
    if control_only:
        label += " (CONTROL cells)"
    var graded = _grade(batch, cases, _KIND_INT, control_only, want_of, label, fails)
    _report(fails, graded, label)


def _sweep_float_dict[
    val_dt: DType
](imm entries: List[Float64], logical: ArrowType) raises:
    comptime is_f32 = val_dt == DType.float32
    var bits = List[Int64]()
    for i in range(len(entries)):
        comptime if is_f32:
            bits.append(Int64(Int(entries[i].cast[DType.float32]().to_bits())))
        else:
            bits.append(entries[i].to_bits().cast[DType.int64]())
    var col = Column.from_numeric_dict[DType.int32, val_dt](
        _codes_identity(len(entries)), bits^
    )
    var batch = _dict_batch(col^, logical)
    var rows = entries.copy()
    rows.append(entries[0])
    var cases = _every_integer_tag()
    var ops = _six_ops()
    var want_of = List[List[List[Bool]]]()
    for c in range(len(cases.lits)):
        var thr = cases.as_f64[c]
        comptime if is_f32:
            thr = cases.as_f32[c].cast[DType.float64]()
        var per_op = List[List[Bool]]()
        for o in range(len(ops)):
            var w = List[Bool]()
            for i in range(len(rows)):
                w.append(_cmp_f64(ops[o], rows[i], thr))
            per_op.append(w^)
        want_of.append(per_op^)
    var fails = List[String]()
    var label = "dict<" + String(val_dt) + ">"
    var graded = _grade(batch, cases, _KIND_DICT_FLOAT, False, want_of, label, fails)
    _report(fails, graded, label)


def _i64_dict_entries() -> List[I128]:
    var e: List[I128] = [
        I128(-9223372036854775808), I128(-1), I128(0), I128(3),
        I128(9223372036854775807),
    ]
    return e^


def _i32_dict_entries() -> List[I128]:
    var e: List[I128] = [I128(-2147483648), I128(-1), I128(3), I128(2147483647)]
    return e^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
