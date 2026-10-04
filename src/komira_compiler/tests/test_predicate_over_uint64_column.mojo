# =============================================================================
# test_predicate_over_uint64_column.mojo
# =============================================================================
#
# ★★ THE PREDICATE LADDER HAD NO `UINT64` ARM AT ALL — `WHERE v > 2` over an
#    unsigned 64-bit column fell to the `else` and raised
#    `PipelineCompiler: unsupported column type for predicate: uint64`.
#
# WHERE THAT WAS VISIBLE, AND WHERE IT WAS NOT. A door that sends the filter
# straight to this evaluator gets the refusal:
#
#         "PipelineCompiler: unsupported column type for predicate: uint64"
#
# while the doors that push the predicate into the SCAN got "0 rows, want 3".
# The other three doors push the predicate into the SCAN, where the row-group
# zonemap dropped the whole row group first (`rg_pruner`, repaired in the same
# change, and pinned by `komira_parquet`'s unsigned-int64 stats test) — so
# execution never REACHED this
# refusal and the caller got a silent empty answer instead of an error. Both
# halves have to land together: repairing only the pruner converts a wrong
# answer into a refusal, and repairing only this arm leaves the wrong answer.
#
# ⚠ NO SINGLE INTEGER TYPE HOLDS BOTH OPERANDS, which is why this is not
# `_scalar_cmp_i32_widening` with another width. The column is UInt64 and the
# literal arrives as `ScalarValue.int_val`, an Int64. Widening the column to
# Int64 is the defect `rg_pruner` had (a value above `Int64.MAX` reads
# negative); narrowing the literal wraps a NEGATIVE one onto a huge positive.
# §3 below is the negative-literal arm that exists for exactly that reason.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.boolean_array import BooleanArray
from komira_core.arrow.column import Column
from komira_core.arrow.decimal_array import Decimal128Array
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from komira_core.io.heap_region import HeapRegion
from komira_core.plan.expr import (
    Expr,
    BIN_ADD,
    BIN_EQ,
    BIN_GE,
    BIN_GT,
    BIN_LE,
    BIN_LT,
    BIN_NE,
)
from komira_core.plan.scalar_value import ScalarValue

from komira_compiler.compiler_eval_predicate import _eval_predicate


comptime _U64_MAX: UInt64 = 18446744073709551615
comptime _I64_MAX_AS_U64: UInt64 = 9223372036854775807


def _u64_values() -> List[UInt64]:
    """The cross-surface corpus's own uint64 TypeSpec fixture. The top value is
    ABOVE `Int64.MAX` on purpose: it is the only region where a signed read is
    observably wrong, and every other value in the list is a control that a
    signed read gets RIGHT."""
    var v: List[UInt64] = [
        UInt64(0),
        UInt64(1),
        UInt64(2),
        UInt64(3),
        UInt64(4),
        _U64_MAX,
    ]
    return v^


def _u64_batch(values: List[UInt64]) raises -> RecordBatch:
    var n = len(values)
    var arr = PrimitiveArray[DType.uint64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        (p + i)[] = values[i]
    var col = Column.from_primitive[DType.uint64](arr^)
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(col^)
    var sb = SchemaBuilder()
    sb.add_field(Field(String("v"), ArrowType.UINT64, False))
    return rbb.build(sb.build())


def _pred(op: UInt8, lit: Int) -> Expr:
    return Expr.binary(
        op,
        Expr.col_ref("v"),
        Expr.literal(ScalarValue.from_int(lit)),
    )


def _oracle(op: UInt8, values: List[UInt64], lit: Int) -> List[Bool]:
    """The answer computed in the UNSIGNED domain, in plain Mojo, with no
    kernel involved. A negative literal is answered on its own terms — every
    unsigned value is strictly above it."""
    var out = List[Bool]()
    for i in range(len(values)):
        var v = values[i]
        var r: Bool
        if lit < 0:
            r = (op == BIN_GT or op == BIN_GE or op == BIN_NE)
        else:
            var u = UInt64(lit)
            if op == BIN_GT:
                r = v > u
            elif op == BIN_GE:
                r = v >= u
            elif op == BIN_LT:
                r = v < u
            elif op == BIN_LE:
                r = v <= u
            elif op == BIN_EQ:
                r = v == u
            else:
                r = v != u
        out.append(r)
    return out^


def _check(op: UInt8, lit: Int, label: String) raises:
    var values = _u64_values()
    var batch = _u64_batch(values)
    var mask = _eval_predicate(_pred(op, lit), batch)
    var want = _oracle(op, values, lit)
    assert_equal(mask.length, len(values), label + ": length")
    for i in range(len(values)):
        assert_true(
            mask.get(i) == want[i],
            label + ": row " + String(i) + " (val " + String(values[i])
            + ") want " + String(want[i]) + " got " + String(mask.get(i)),
        )


# =============================================================================
# §0 — the premise
# =============================================================================


def test_fixture_premise() raises:
    """⛔ EVERY CHECK BELOW IS VACUOUS IF THE COLUMN IS NOT UINT64, and vacuous
    in the direction that looks like a pass: the ladder's INT64 arm would
    answer, correctly, about a different type."""
    var batch = _u64_batch(_u64_values())
    assert_equal(batch.column_arrow_type(0), ArrowType.UINT64)
    assert_true(_U64_MAX > _I64_MAX_AS_U64)


# =============================================================================
# §1 — THE CORPUS CELL. `v > 2` keeps rows 3, 4 and 2**64-1.
# =============================================================================


def test_gt_keeps_the_above_int64_max_row() raises:
    _check(BIN_GT, 2, String("v > 2"))


def test_every_ordered_operator() raises:
    """⛔ SIX OPERATORS, NOT ONE. `>` and `>=` read the value one way, `<` and
    `<=` the other, and `=`/`!=` neither — a repair that landed in one kernel
    call would leave the rest on the raising `else`."""
    _check(BIN_GE, 3, String("v >= 3"))
    _check(BIN_LT, 3, String("v < 3"))
    _check(BIN_LE, 4, String("v <= 4"))
    _check(BIN_EQ, 4, String("v = 4"))
    _check(BIN_NE, 4, String("v != 4"))


# =============================================================================
# §2 — THE BOUNDARY ITSELF
# =============================================================================


def test_at_the_signed_boundary() raises:
    """`v > Int64.MAX` selects EXACTLY the one row a signed read calls
    negative. Under the old widening this was the empty set."""
    _check(BIN_GT, 9223372036854775807, String("v > Int64.MAX"))
    _check(BIN_LE, 9223372036854775807, String("v <= Int64.MAX"))


# =============================================================================
# §3 — THE NEGATIVE LITERAL, which no shared domain can express
# =============================================================================


def test_negative_literal() raises:
    """`v > -1` holds for every unsigned row; `v < -1` for none; `v = -1` for
    none. ⛔ A repair that narrowed the literal to UInt64 would turn `-1` into
    `2**64-1` and answer all three backwards."""
    _check(BIN_GT, -1, String("v > -1"))
    _check(BIN_LT, -1, String("v < -1"))
    _check(BIN_EQ, -1, String("v = -1"))
    _check(BIN_NE, -5, String("v != -5"))


# =============================================================================
# §4 — a DEGENERATE fixture, so the mask is not merely "the same six bits"
# =============================================================================


def test_all_high_values() raises:
    """Every row above `Int64.MAX`. A signed read makes them all negative and
    ORDERED AMONG THEMSELVES, so a comparison between two of them can still
    come out right — which is why the mixed fixture above cannot be the only
    one."""
    var values: List[UInt64] = [
        _U64_MAX,
        _U64_MAX - UInt64(1),
        _U64_MAX - UInt64(2),
        UInt64(9223372036854775808),
    ]
    var batch = _u64_batch(values)
    var mask = _eval_predicate(
        _pred(BIN_GT, 9223372036854775807), batch
    )
    assert_equal(mask.length, 4)
    for i in range(4):
        assert_true(mask.get(i), String("row ") + String(i))



# =============================================================================
# §5 — THE **FLOAT** LITERAL, which is the only literal one whole door can send
# =============================================================================
#
# ⛔ THE ARM ABOVE READS `lit_val.int_val`, AND THAT FIELD IS A WELL-FORMED
#    ZERO FOR A LITERAL BUILT BY `ScalarValue.from_float`. So `v > 2.0` was
#    evaluated as `v > 0` — TRUE for every non-zero row — which is the exact
#    shape `literal_arm_domain`'s header describes for `shipmode > 5`, this
#    time reached through a numeric arm the domain check ADMITS (`is_numeric`
#    accepts a float literal so that the INT64/INT32 promotion below can pick
#    it up, and UINT64 had no promotion).
#
# ⛔⛔ THIS IS NOT HYPOTHETICAL AND IT IS NOT THE SQL DOOR'S PROBLEM. A
#    spreadsheet-formula front end has no integer literal at all: it folds
#    every number with `ScalarValue.from_float`, so `FILTER(t, t__v > 2)`
#    arrives here as a FLOAT 2.0. With a UINT64 arm that reads `int_val` and
#    no float handling, the same cell goes from a clean refusal to a
#    WHOLE-TABLE answer ("5 rows, want 3").
#
# ⚠ THE REPAIR IS NOT `column.cast[float64]`. That is what the INT64 arm
#   does, and above 2**53 it is lossy in exactly the region this column exists
#   to reach: `18446744073709551615` and `18446744073709551614` are the SAME
#   Float64. The reduction below stays in the UNSIGNED domain — it turns the
#   float THRESHOLD into an exact integer threshold plus (possibly) a different
#   operator, and answers out-of-range thresholds on their own terms.


def _pred_f(op: UInt8, lit: Float64) -> Expr:
    return Expr.binary(
        op,
        Expr.col_ref("v"),
        Expr.literal(ScalarValue.from_float(lit)),
    )


def _oracle_f(op: UInt8, values: List[UInt64], lit: Float64) -> List[Bool]:
    """The answer in EXACT arithmetic, computed WITHOUT converting the column
    to Float64 — the conversion is the thing under test. Each unsigned value is
    compared against the float threshold by deciding, in the unsigned domain,
    which side of `floor(lit)` it falls on."""
    var out = List[Bool]()
    var in_range = lit == lit and lit >= 0.0 and lit < 18446744073709551616.0
    # ⚠ COMPUTED ONLY IN RANGE. A conversion of `1.0e30` — or of `2**63`, which
    # is not a representable Int64 either — is undefined, so the oracle must not
    # reach for a floor it has already decided it does not need.
    var u = _trunc_u64(lit) if in_range else UInt64(0)
    var frac = (_as_f64(u) != lit) if in_range else False
    for i in range(len(values)):
        var v = values[i]
        var r: Bool
        if lit != lit:  # NaN: no ordering holds; only `!=` is true
            r = op == BIN_NE
        elif lit < 0.0:
            r = (op == BIN_GT or op == BIN_GE or op == BIN_NE)
        elif not in_range:  # at or above 2**64, and +inf
            r = (op == BIN_LT or op == BIN_LE or op == BIN_NE)
        else:
            if op == BIN_GT:
                r = v > u
            elif op == BIN_GE:
                r = v > u if frac else v >= u
            elif op == BIN_LT:
                r = v <= u if frac else v < u
            elif op == BIN_LE:
                r = v <= u
            elif op == BIN_EQ:
                r = False if frac else v == u
            else:
                r = True if frac else v != u
        out.append(r)
    return out^


def _trunc_u64(x: Float64) -> UInt64:
    """`floor` for a NON-NEGATIVE, in-UInt64-range argument only — truncation
    toward zero IS floor there, and the caller guarantees the range. ⚠ NOT
    `UInt64(Int(x))`: `Int` is 64-bit SIGNED, so every argument at or above
    `2**63` — the whole half of the domain this file exists to reach — would
    convert through an unrepresentable intermediate."""
    return Scalar[DType.float64](x).cast[DType.uint64]()


def _as_f64(u: UInt64) -> Float64:
    return Scalar[DType.uint64](u).cast[DType.float64]()


def _check_f(op: UInt8, lit: Float64, label: String) raises:
    var values = _u64_values()
    var batch = _u64_batch(values)
    var mask = _eval_predicate(_pred_f(op, lit), batch)
    var want = _oracle_f(op, values, lit)
    assert_equal(mask.length, len(values), label + ": length")
    for i in range(len(values)):
        assert_true(
            mask.get(i) == want[i],
            label + ": row " + String(i) + " (val " + String(values[i])
            + ") want " + String(want[i]) + " got " + String(mask.get(i)),
        )


def test_float_literal_is_not_read_as_zero() raises:
    """⭐ THE FLOAT-LITERAL CELL. `v > 2.0` must keep 3, 4 and 2**64-1 — three rows of
    the six-row fixture. Reading `int_val` answers `v > 0`, which keeps FIVE.
    ⛔ A count-only assertion would pass on `v > 1.0`; `_oracle_f` grades every
    row."""
    _check_f(BIN_GT, 2.0, String("v > 2.0"))


def test_float_literal_every_operator() raises:
    _check_f(BIN_GE, 3.0, String("v >= 3.0"))
    _check_f(BIN_LT, 3.0, String("v < 3.0"))
    _check_f(BIN_LE, 4.0, String("v <= 4.0"))
    _check_f(BIN_EQ, 4.0, String("v = 4.0"))
    _check_f(BIN_NE, 4.0, String("v != 4.0"))


def test_float_literal_with_a_fraction() raises:
    """⛔ A FRACTIONAL THRESHOLD IS NOT `floor` FOR EVERY OPERATOR. `v > 2.5`
    and `v > 2.0` select the same rows here, but `v >= 2.5` and `v >= 2.0` do
    NOT, and `v = 2.5` is EMPTY while `v != 2.5` is EVERY row. A repair that
    truncated the literal to an integer and reused the operator answers three
    of these five wrong."""
    _check_f(BIN_GT, 2.5, String("v > 2.5"))
    _check_f(BIN_GE, 2.5, String("v >= 2.5"))
    _check_f(BIN_LT, 2.5, String("v < 2.5"))
    _check_f(BIN_LE, 2.5, String("v <= 2.5"))
    _check_f(BIN_EQ, 2.5, String("v = 2.5"))
    _check_f(BIN_NE, 2.5, String("v != 2.5"))


def test_float_literal_below_zero() raises:
    """Every unsigned value is above a negative threshold. ⛔ `UInt64(-1.0)` is
    not a portable way to find that out."""
    _check_f(BIN_GT, -1.0, String("v > -1.0"))
    _check_f(BIN_LT, -0.5, String("v < -0.5"))
    _check_f(BIN_EQ, -1.0, String("v = -1.0"))


def test_float_literal_above_the_unsigned_domain() raises:
    """★ THE BOUNDARY THAT ONLY EXISTS FOR THIS PAIR. `18446744073709551615`
    written as a FLOAT is `2**64` — the surface cannot express the largest
    UInt64 at all — so `v = 18446744073709551615.0` is legitimately EMPTY and
    `v < ...` is every row. A `UInt64(f)` conversion at 2**64 is undefined and
    on this target wraps to 0, which answers both backwards."""
    _check_f(BIN_LT, 18446744073709551615.0, String("v < 2**64"))
    _check_f(BIN_GE, 18446744073709551615.0, String("v >= 2**64"))
    _check_f(BIN_EQ, 18446744073709551615.0, String("v = 2**64"))
    _check_f(BIN_GT, 1.0e30, String("v > 1e30"))
    _check_f(BIN_LE, 1.0e30, String("v <= 1e30"))


def test_float_literal_at_the_signed_boundary() raises:
    """The same region §2 pins for an integer literal, reached through the
    float arm: `Int64.MAX` as a Float64 is `2**63` exactly."""
    _check_f(BIN_GT, 9223372036854775808.0, String("v > 2**63"))
    _check_f(BIN_LE, 9223372036854775808.0, String("v <= 2**63"))


# =============================================================================
# §6 — THE **UNSIGNED-TAGGED** LITERAL, which is the only literal that can name
#      the top half of a UInt64 column's domain at all
# =============================================================================
#
# ⛔ EVERY SECTION ABOVE SPELLS ITS LITERAL WITH `ScalarValue.from_int`, whose
#    argument is a SIGNED `Int`. So the whole suite, six operators and a
#    boundary section included, could only ever ask about values at or below
#    `Int64.MAX` — and `18446744073709551615` is not one of them. The fixture
#    CONTAINS that value; no test above could compare against it.
#
# ⛔⛔ AND THE WIRE CAN ALREADY CARRY IT. `komira_plan_wire.plan_wire_codec.
#    _scalar_from_wire` maps `_DT_UINT64` (code 9) to `DType.uint64` and copies
#    `w.int_val` through, and `ScalarValue.from_uint64` stores the unsigned
#    value as its TWO'S-COMPLEMENT BIT PATTERN in that same `int_val`
#    (`scalar_value.mojo:361-373`, whose docstring says so: *"a plain `int_val`
#    read reinterprets values >= 2**63 as negative"*).
#
# ⇒ THE DEFECT: the UINT64 arm read `lit_val.int_val` SIGNED and never asked
#   `is_uint`, so `18446744073709551615` arrived as `-1`, took the arm's
#   "the literal is NEGATIVE" branch — the one §3 exists to protect — and
#   answered `v = 2**64-1` as ZERO ROWS and `v <> 2**64-1` as EVERY row.
#   SILENTLY. That is a WRONG ANSWER, not a refusal, and it is the reason the
#   TypeScript plan encoder refuses to spell such a literal at all.
#
# ⚠ §3 IS THE CONTROL THAT KEEPS THE REPAIR HONEST, and it is not optional:
#   a "fix" that read every literal unsigned would turn the genuinely NEGATIVE
#   `-1` of §3 into `2**64-1` and answer those three cases backwards. The two
#   sections are the two directions of the same boundary, and the discriminator
#   is the literal's own TAG — `is_uint` — never the sign of its bits.


def _pred_u(op: UInt8, lit: UInt64) -> Expr:
    return Expr.binary(
        op,
        Expr.col_ref("v"),
        Expr.literal(ScalarValue.from_uint64(lit)),
    )


def _oracle_u(op: UInt8, values: List[UInt64], u: UInt64) -> List[Bool]:
    """Both operands are UInt64, so — unlike every other oracle in this file —
    there is no domain question to answer: the comparison IS the answer."""
    var out = List[Bool]()
    for i in range(len(values)):
        var v = values[i]
        var r: Bool
        if op == BIN_GT:
            r = v > u
        elif op == BIN_GE:
            r = v >= u
        elif op == BIN_LT:
            r = v < u
        elif op == BIN_LE:
            r = v <= u
        elif op == BIN_EQ:
            r = v == u
        else:
            r = v != u
        out.append(r)
    return out^


def _check_u(op: UInt8, lit: UInt64, label: String) raises:
    var values = _u64_values()
    var batch = _u64_batch(values)
    var mask = _eval_predicate(_pred_u(op, lit), batch)
    var want = _oracle_u(op, values, lit)
    assert_equal(mask.length, len(values), label + ": length")
    for i in range(len(values)):
        assert_true(
            mask.get(i) == want[i],
            label + ": row " + String(i) + " (val " + String(values[i])
            + ") want " + String(want[i]) + " got " + String(mask.get(i)),
        )


def test_uint64_literal_premise() raises:
    """⛔ VACUOUS IF THE LITERAL IS NOT ACTUALLY TAGGED UNSIGNED, and vacuous in
    the direction that looks like a pass — a literal that came out `int64` would
    be graded by the arm §1 already covers."""
    var lit = ScalarValue.from_uint64(_U64_MAX)
    assert_true(lit.is_uint(), "from_uint64 must produce an unsigned literal")
    assert_equal(lit.dtype, DType.uint64)
    assert_true(lit.uint64_value() == _U64_MAX, "uint64_value round trip")
    # ★ THE DEFECT IN ONE LINE: the same bytes read SIGNED are -1, which is
    # exactly the input §3's negative arm is built to answer.
    assert_true(lit.int_val == Int64(-1), "the signed read of 2**64-1 is -1")


def test_uint64_literal_eq_at_the_top_of_the_domain() raises:
    """⭐ THE DEFECT'S OWN SENTENCE: `u64 = 18446744073709551615` must select the
    ONE row that holds it. Reading the literal signed sent it to the negative
    branch, where `=` is false for every unsigned value — ZERO ROWS, silently.
    ⛔ A count-only assertion would pass on the row-5 fixture for `v > 4`;
    `_oracle_u` grades every row."""
    _check_u(BIN_EQ, _U64_MAX, String("v = 2**64-1"))
    _check_u(BIN_NE, _U64_MAX, String("v != 2**64-1"))


def test_uint64_literal_every_operator_above_the_signed_boundary() raises:
    """⛔ SIX OPERATORS, AND THE SIGNED READ GETS ALL SIX WRONG IN TWO
    DIFFERENT DIRECTIONS: the negative branch answers `>`/`>=`/`!=` for EVERY
    row and `<`/`<=`/`=` for NONE, while the truth here is nearly the
    complement of that."""
    _check_u(BIN_GT, _U64_MAX, String("v > 2**64-1"))
    _check_u(BIN_GE, _U64_MAX, String("v >= 2**64-1"))
    _check_u(BIN_LT, _U64_MAX, String("v < 2**64-1"))
    _check_u(BIN_LE, _U64_MAX, String("v <= 2**64-1"))


def test_uint64_literal_at_the_signed_boundary_itself() raises:
    """`2**63` is the FIRST value a signed read calls negative, and `2**63-1`
    the last it calls positive — so the pair straddles the exact bit where the
    old branch selection flipped."""
    _check_u(BIN_GE, UInt64(9223372036854775808), String("v >= 2**63"))
    _check_u(BIN_LT, UInt64(9223372036854775808), String("v < 2**63"))
    _check_u(BIN_GT, _I64_MAX_AS_U64, String("v > Int64.MAX (unsigned tag)"))
    _check_u(BIN_LE, _I64_MAX_AS_U64, String("v <= Int64.MAX (unsigned tag)"))


def test_uint64_literal_below_the_boundary_is_unchanged() raises:
    """★ THE CONTROL ON THE REPAIR'S OTHER SIDE. An unsigned literal whose
    value a signed read gets RIGHT must keep answering exactly as §1 does —
    the new branch may not change the common case, only the top half."""
    _check_u(BIN_GT, UInt64(2), String("v > 2u"))
    _check_u(BIN_EQ, UInt64(4), String("v = 4u"))
    _check_u(BIN_LE, UInt64(0), String("v <= 0u"))


def test_uint64_literal_over_all_high_fixture() raises:
    """§4's degenerate fixture, asked with an unsigned literal: every row is
    above `Int64.MAX`, so a signed read makes the COLUMN negative too and a
    comparison between two negatives can still come out right. Only a literal
    from the same region discriminates."""
    var values: List[UInt64] = [
        _U64_MAX,
        _U64_MAX - UInt64(1),
        _U64_MAX - UInt64(2),
        UInt64(9223372036854775808),
    ]
    var batch = _u64_batch(values)
    var mask = _eval_predicate(_pred_u(BIN_GE, _U64_MAX - UInt64(1)), batch)
    var want = _oracle_u(BIN_GE, values, _U64_MAX - UInt64(1))
    assert_equal(mask.length, 4)
    for i in range(4):
        assert_true(
            mask.get(i) == want[i],
            String("v >= 2**64-2: row ") + String(i),
        )


# =============================================================================
# §7 — ⛔ THE UNSIGNED / NARROW LITERAL **OUTSIDE** THE COLUMN LADDER
# =============================================================================
#
# §6 repaired ONE reader of an unsigned-tagged literal — the UINT64 column arm.
# The same literal reaches four more readers inside `_eval_predicate`, each of
# which picked the field to read from the COLUMN and so misread the TAG.
# MEASURED through this function, before the repair:
#
#   int64 [-1,0,3]    v IN (2**64-1 uint64)       ->  100    want 000
#   int32 [-1,0,3]    v IN (2**64-1 uint64)       ->  100    want 000
#   f64   [0,3,10]    v IN (3 uint8)              ->  100    want 010
#   f64   [0.5,3,10]  (v + 0.0) > 3 uint8         ->  011    want 001
#   int64 [-1,0,3]    (v + 0) > 2**64-1 uint64    ->  001    want 000
#   f64   [0.5,3,10]  3 uint8 < v                 ->  011    want 001
#   dec(38,2)         v > 3 uint8                 ->  RAISE "unsupported literal type"
#
# i.e. the IN-list value table read `int_val` signed (and the float one read
# `float_val` for anything but int64/int32); the computed-operand path fed the
# literal to `broadcast_scalar`, whose arms test `dtype == int64 / int32 /
# float64 / float32` and turn every other integer tag into an INT64 ZERO; and
# the DECIMAL arm only knew `is_int`. Every expectation below is DuckDB
# v1.5.3's answer to the same SQL, (`v IN
# (18446744073709551615::UBIGINT)` over BIGINT is empty; over DOUBLE it selects
# 1.8446744073709552e19; `18446744073709551615::UBIGINT > v` holds for every
# BIGINT row; DECIMAL(38,2) `v > 3::UTINYINT` is [3.01]).
# =============================================================================


def _i64_batch3(a: Int64, b: Int64, c: Int64) raises -> RecordBatch:
    var arr = PrimitiveArray[DType.int64].allocate(3)
    arr.set(0, a)
    arr.set(1, b)
    arr.set(2, c)
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(Column.from_primitive[DType.int64](arr^))
    var sb = SchemaBuilder()
    sb.add_field(Field(String("v"), ArrowType.INT64, False))
    return rbb.build(sb.build())


def _i32_batch3(a: Int32, b: Int32, c: Int32) raises -> RecordBatch:
    var arr = PrimitiveArray[DType.int32].allocate(3)
    arr.set(0, a)
    arr.set(1, b)
    arr.set(2, c)
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(Column.from_primitive[DType.int32](arr^))
    var sb = SchemaBuilder()
    sb.add_field(Field(String("v"), ArrowType.INT32, False))
    return rbb.build(sb.build())


def _f64_batch(imm vals: List[Float64]) raises -> RecordBatch:
    var arr = PrimitiveArray[DType.float64].allocate(len(vals))
    for i in range(len(vals)):
        arr.set(i, vals[i])
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(Column.from_primitive[DType.float64](arr^))
    var sb = SchemaBuilder()
    sb.add_field(Field(String("v"), ArrowType.FLOAT64, False))
    return rbb.build(sb.build())


def _dec_batch(imm scaled: List[Int], precision: Int, scale: Int) raises -> RecordBatch:
    var arr = Decimal128Array.allocate(len(scaled), precision, scale)
    for i in range(len(scaled)):
        arr.set_i128(i, SIMD[DType.int128, 1](scaled[i]))
    var sb = SchemaBuilder()
    sb.add_field(Field.decimal128("v", precision, scale, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_decimal128(arr^))
    return rbb.build(sb.build())


def _mask_bits(imm batch: RecordBatch, imm pred: Expr) raises -> String:
    var m = _eval_predicate(pred, batch)
    var s = String("")
    for i in range(m.length):
        s += "1" if m.get(i) else "0"
    return s


def _expect(imm batch: RecordBatch, var pred: Expr, want: String, label: String) raises:
    var got = _mask_bits(batch, pred)
    assert_true(got == want, label + ": got " + got + " want " + want)


def _in(var vals: List[ScalarValue]) -> Expr:
    return Expr.in_list_node(Expr.col_ref("v"), vals^)


def _u64_lit(u: UInt64) -> Expr:
    return Expr.literal(ScalarValue.from_uint64(u))


def test_in_list_int64_column_reads_the_unsigned_tag() raises:
    """No Int64 equals a value above Int64.MAX, so such a member contributes
    NOTHING to `IN` — it is dropped from the probe table, exactly as the int32
    kernel already drops a member outside int32."""
    var b = _i64_batch3(-1, 0, 3)
    _expect(b, _in([ScalarValue.from_uint64(_U64_MAX)]), "000", "i64 IN (2**64-1)")
    _expect(
        b,
        _in([ScalarValue.from_uint64(UInt64(9223372036854775808))]),
        "000",
        "i64 IN (2**63)",
    )
    _expect(
        b,
        _in([ScalarValue.from_uint8(UInt8(3)), ScalarValue.from_uint64(_U64_MAX)]),
        "001",
        "i64 IN (3u8, 2**64-1) — the in-domain member still matches",
    )
    # ★ CONTROL: a genuinely NEGATIVE signed member is not an unsigned one.
    _expect(b, _in([ScalarValue.from_int64(-1)]), "100", "i64 IN (-1) [control]")


def test_in_list_int32_column_reads_the_unsigned_tag() raises:
    var b = _i32_batch3(-1, 0, 3)
    _expect(b, _in([ScalarValue.from_uint64(_U64_MAX)]), "000", "i32 IN (2**64-1)")
    _expect(b, _in([ScalarValue.from_int16(Int16(3))]), "001", "i32 IN (3i16)")


def test_in_list_float64_column_reads_every_integer_tag() raises:
    """DuckDB casts each member to DOUBLE, so `2**64-1` IS `2**64` here."""
    var vals: List[Float64] = [0.0, 3.0, 10.0, 18446744073709551616.0]
    var b = _f64_batch(vals)
    _expect(b, _in([ScalarValue.from_uint8(UInt8(3))]), "0100", "f64 IN (3u8)")
    _expect(b, _in([ScalarValue.from_int16(Int16(10))]), "0010", "f64 IN (10i16)")
    _expect(b, _in([ScalarValue.from_uint64(_U64_MAX)]), "0001", "f64 IN (2**64-1)")
    # CONTROL: the INT64 tag was always read.
    _expect(b, _in([ScalarValue.from_int64(3)]), "0100", "f64 IN (3i64) [control]")


def test_computed_lhs_reads_the_literal_tag() raises:
    """`(v + 0) OP lit` materializes the left side and BROADCASTS the literal.
    The broadcast read the tag through an allow-list (int64/int32/float64/
    float32) and made every other integer an INT64 ZERO — the literal has to
    reach it already read, at the computed column's type."""
    var fv: List[Float64] = [0.5, 3.0, 10.0]
    var bf = _f64_batch(fv)
    _expect(
        bf,
        Expr.binary(
            BIN_GT,
            Expr.binary(BIN_ADD, Expr.col_ref("v"), Expr.literal(ScalarValue.from_float(0.0))),
            Expr.literal(ScalarValue.from_uint8(UInt8(3))),
        ),
        "001",
        "f64 (v + 0.0) > 3u8",
    )
    var bi = _i64_batch3(-1, 0, 3)
    _expect(
        bi,
        Expr.binary(
            BIN_GT,
            Expr.binary(BIN_ADD, Expr.col_ref("v"), Expr.literal(ScalarValue.from_int(0))),
            _u64_lit(_U64_MAX),
        ),
        "000",
        "i64 (v + 0) > 2**64-1",
    )
    _expect(
        bi,
        Expr.binary(
            BIN_LT,
            Expr.binary(BIN_ADD, Expr.col_ref("v"), Expr.literal(ScalarValue.from_int(0))),
            _u64_lit(_U64_MAX),
        ),
        "111",
        "i64 (v + 0) < 2**64-1",
    )
    _expect(
        bi,
        Expr.binary(
            BIN_EQ,
            Expr.binary(BIN_ADD, Expr.col_ref("v"), Expr.literal(ScalarValue.from_int(0))),
            Expr.literal(ScalarValue.from_uint16(UInt16(3))),
        ),
        "001",
        "i64 (v + 0) = 3u16",
    )


def test_literal_on_the_left_reads_its_tag() raises:
    """`lit OP v` is `v MIRROR(OP) lit`; the literal-on-the-left spelling took
    the computed-operand path and so the same zero broadcast."""
    var fv: List[Float64] = [0.5, 3.0, 10.0]
    var bf = _f64_batch(fv)
    _expect(
        bf,
        Expr.binary(BIN_LT, Expr.literal(ScalarValue.from_uint8(UInt8(3))), Expr.col_ref("v")),
        "001",
        "f64 3u8 < v",
    )
    var bi = _i64_batch3(-1, 0, 3)
    _expect(bi, Expr.binary(BIN_GT, _u64_lit(_U64_MAX), Expr.col_ref("v")), "111", "2**64-1 > v")
    _expect(bi, Expr.binary(BIN_LE, _u64_lit(_U64_MAX), Expr.col_ref("v")), "000", "2**64-1 <= v")
    _expect(
        bi,
        Expr.binary(BIN_GE, Expr.literal(ScalarValue.from_int8(Int8(0))), Expr.col_ref("v")),
        "110",
        "0i8 >= v",
    )
    # CONTROL: an INT64 literal on the left was always right.
    _expect(
        bf,
        Expr.binary(BIN_LT, Expr.literal(ScalarValue.from_int64(3)), Expr.col_ref("v")),
        "001",
        "f64 3i64 < v [control]",
    )


def test_decimal_column_reads_every_integer_tag() raises:
    """The DECIMAL arm scale-aligned only an `is_int` (int64/int32) literal and
    REFUSED the other six tags — a refusal the admission check
    (`literal_arm_domain`, which admits `is_any_integer` against a decimal
    column) said could not happen. The literal's exact value is what is
    scale-aligned now, including a uint64 above Int64.MAX."""
    var s: List[Int] = [-150, 300, 301]
    var b = _dec_batch(s, 38, 2)
    _expect(b, Expr.binary(BIN_GT, Expr.col_ref("v"), Expr.literal(ScalarValue.from_uint8(UInt8(3)))), "001", "dec > 3u8")
    _expect(b, Expr.binary(BIN_GE, Expr.col_ref("v"), Expr.literal(ScalarValue.from_int16(Int16(3)))), "011", "dec >= 3i16")
    _expect(b, Expr.binary(BIN_LT, Expr.col_ref("v"), _u64_lit(_U64_MAX)), "111", "dec < 2**64-1")
    # CONTROL: the INT64 tag was always scale-aligned.
    _expect(b, Expr.binary(BIN_GT, Expr.col_ref("v"), Expr.literal(ScalarValue.from_int64(3))), "001", "dec > 3i64 [control]")
    # The top of the unsigned domain, EXACTLY — a DECIMAL(38,0) can hold it.
    var arr = Decimal128Array.allocate(2, 38, 0)
    arr.set_i128(0, SIMD[DType.int128, 1](18446744073709551615))
    arr.set_i128(1, SIMD[DType.int128, 1](18446744073709551614))
    var sb = SchemaBuilder()
    sb.add_field(Field.decimal128("v", 38, 0, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_decimal128(arr^))
    var b0 = rbb.build(sb.build())
    _expect(b0, Expr.binary(BIN_EQ, Expr.col_ref("v"), _u64_lit(_U64_MAX)), "10", "dec(38,0) = 2**64-1")


def test_a_malformed_narrow_literal_is_refused_not_read() raises:
    """A `uint8` tag carrying 300 has no value; only a hand-built wire message
    can produce one (`plan_wire_codec._scalar_from_wire` copies `int_val`
    verbatim). Reading its bits answered `v = 300` — the tag is what says what
    the bits mean, so the literal is REFUSED."""
    var b = _i64_batch3(-1, 0, 300)
    var bad = ScalarValue(DType.uint8, Int64(300), 0.0, String(""), False)
    with assert_raises(contains="EVAL_MALFORMED_INTEGER_LITERAL"):
        _ = _eval_predicate(
            Expr.binary(BIN_EQ, Expr.col_ref("v"), Expr.literal(bad^)), b
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
