# =============================================================================
# Tests for cast & null eval — imports from komira_arrow and komira_core.eval
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false


from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.bitmap import Bitmap
from komira_column_kernels.cast_null import eval_cast, bitmap_and, eval_gt_nullable
from komira_column_kernels.cast_null import eval_cast_float_to_int, round_half_to_even
from komira_column_kernels.cast_null import eval_is_null, eval_is_not_null


# =============================================================================
# Cast tests
# =============================================================================


def test_eval_cast_int32_to_float64() raises:
    """eval_cast converts int32 to float64."""
    var values: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](1),
        Scalar[DType.int32](2),
        Scalar[DType.int32](3),
    ]
    var col = PrimitiveArray[DType.int32].from_list(values)
    var result = eval_cast[DType.int32, DType.float64](col)
    assert_equal(result.length, 3)
    assert_equal(result.get(0), Scalar[DType.float64](1.0))
    assert_equal(result.get(1), Scalar[DType.float64](2.0))
    assert_equal(result.get(2), Scalar[DType.float64](3.0))


def test_eval_cast_int64_to_int32() raises:
    """eval_cast converts int64 to int32 (narrowing)."""
    var values: List[Scalar[DType.int64]] = [
        Scalar[DType.int64](100),
        Scalar[DType.int64](200),
    ]
    var col = PrimitiveArray[DType.int64].from_list(values)
    var result = eval_cast[DType.int64, DType.int32](col)
    assert_equal(result.length, 2)
    assert_equal(result.get(0), Scalar[DType.int32](100))
    assert_equal(result.get(1), Scalar[DType.int32](200))


def test_eval_cast_float64_to_int32() raises:
    """eval_cast converts float64 to int32 (TRUNCATES — and is not the SQL cast).

    ⚠ THE TRUNCATION HERE IS CORRECT AND MUST NOT BE "FIXED" TO MATCH DuckDB.
    `eval_cast` is the raw SIMD `.cast[T]()` primitive; the SQL
    `CAST(<float> AS <int>)` rule is HALF TO EVEN and lives in
    `eval_cast_float_to_int` (tested below). ⛔ 1.9 and 2.1 are deliberately NOT
    ties, so this case cannot distinguish the two rules and does not silently
    become a second, contradictory specification of the cast.
    """
    var values: List[Scalar[DType.float64]] = [
        Scalar[DType.float64](1.9),
        Scalar[DType.float64](2.1),
    ]
    var col = PrimitiveArray[DType.float64].from_list(values)
    var result = eval_cast[DType.float64, DType.int32](col)
    assert_equal(result.length, 2)
    assert_equal(result.get(0), Scalar[DType.int32](1))
    assert_equal(result.get(1), Scalar[DType.int32](2))


# =============================================================================
# Bitmap AND
# =============================================================================


def test_bitmap_and() raises:
    """bitmap_and ANDs two validity bitmaps byte-by-byte."""
    # a: valid except index 1 and 3 -> 0xFF & ~0x02 & ~0x08 = 0xF5
    var a = Bitmap.create_all_valid(8)
    a.clear(1)
    a.clear(3)
    assert_equal(Int((a.buffer.view_typed_ro[DType.uint8]() + 0)[]), 0xF5)

    # b: valid except index 2 and 3 -> 0xFF & ~0x04 & ~0x08 = 0xF3
    var b = Bitmap.create_all_valid(8)
    b.clear(2)
    b.clear(3)
    assert_equal(Int((b.buffer.view_typed_ro[DType.uint8]() + 0)[]), 0xF3)

    var result = bitmap_and(a, b)

    # AND: 0xF5 & 0xF3 = 0xF1 = 11110001
    # Null at indices 1, 2, 3; valid at 0, 4, 5, 6, 7
    assert_equal(result.length, 8)
    var byte_val = (result.buffer.view_typed_ro[DType.uint8]() + 0)[]
    assert_equal(Int(byte_val), 0xF1)


# =============================================================================
# Null-propagating comparison
# =============================================================================


def test_eval_gt_nullable_no_nulls() raises:
    """eval_gt_nullable behaves like eval_gt when no nulls present."""
    var values: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](1),
        Scalar[DType.int32](5),
        Scalar[DType.int32](10),
    ]
    var col = PrimitiveArray[DType.int32].from_list(values)
    var result = eval_gt_nullable[DType.int32](col, Scalar[DType.int32](3))
    assert_equal(len(result), 3)
    assert_false(result.get(0))
    assert_true(result.get(1))
    assert_true(result.get(2))


def test_eval_gt_nullable_with_nulls() raises:
    """eval_gt_nullable propagates nulls from input to output."""
    var col = PrimitiveArray[DType.int32].allocate_nullable(4)
    col.set(0, Scalar[DType.int32](1))
    col.set(1, Scalar[DType.int32](10))
    col.set(2, Scalar[DType.int32](5))
    col.set(3, Scalar[DType.int32](20))

    # Mark index 2 as null using the Bitmap API
    col.validity.value().clear(2)
    col.null_count = 1

    var result = eval_gt_nullable[DType.int32](col, Scalar[DType.int32](3))
    assert_equal(len(result), 4)
    assert_equal(result.null_count, 1)
    assert_true(Bool(result.validity))  # output has validity bitmap


# =============================================================================
# is_null / is_not_null
# =============================================================================


def test_eval_is_null_no_bitmap() raises:
    """eval_is_null returns all False for non-nullable array."""
    var values: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](1),
        Scalar[DType.int32](2),
        Scalar[DType.int32](3),
    ]
    var col = PrimitiveArray[DType.int32].from_list(values)
    var result = eval_is_null[DType.int32](col)
    assert_equal(len(result), 3)
    for i in range(3):
        assert_false(result.get(i))


def test_eval_is_null_with_nulls() raises:
    """eval_is_null returns True at null positions."""
    var col = PrimitiveArray[DType.int32].allocate_nullable(4)
    col.set(0, Scalar[DType.int32](1))
    col.set(1, Scalar[DType.int32](2))
    col.set(2, Scalar[DType.int32](3))
    col.set(3, Scalar[DType.int32](4))

    # Mark index 1 as null using the Bitmap API
    col.validity.value().clear(1)
    col.null_count = 1

    var result = eval_is_null[DType.int32](col)
    assert_false(result.get(0))  # valid
    assert_true(result.get(1))   # null -> True
    assert_false(result.get(2))  # valid
    assert_false(result.get(3))  # valid


def test_eval_is_not_null_no_bitmap() raises:
    """eval_is_not_null returns all True for non-nullable array."""
    var values: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](1),
        Scalar[DType.int32](2),
    ]
    var col = PrimitiveArray[DType.int32].from_list(values)
    var result = eval_is_not_null[DType.int32](col)
    assert_equal(len(result), 2)
    for i in range(2):
        assert_true(result.get(i))


def test_eval_is_not_null_with_nulls() raises:
    """eval_is_not_null returns False at null positions."""
    var col = PrimitiveArray[DType.int32].allocate_nullable(3)
    col.set(0, Scalar[DType.int32](10))
    col.set(1, Scalar[DType.int32](20))
    col.set(2, Scalar[DType.int32](30))

    # Mark index 0 as null using the Bitmap API
    col.validity.value().clear(0)
    col.null_count = 1

    var result = eval_is_not_null[DType.int32](col)
    assert_false(result.get(0))  # null -> False
    assert_true(result.get(1))   # valid -> True
    assert_true(result.get(2))   # valid -> True


# =============================================================================
# ⭐⭐ THE FLOAT -> INTEGER CAST ROUNDING RULE — HALF TO EVEN
# =============================================================================
#
# ⛔ THE DEFECT THESE PIN: a float->integer cast that TRUNCATES TOWARD ZERO
# answers `CAST(-1.5::DOUBLE AS BIGINT)` = -1 where DuckDB v1.5.3 answers -2.
#
# ⚠⚠ EVERY TIE BELOW IS LOAD-BEARING AND THE SET IS CHOSEN TO KILL ALL FOUR
# PLAUSIBLE WRONG MODELS. A fix is only correct if it disagrees with each:
#
#     x       -3.5  -2.5  -1.5  -0.5   0.5   1.5   2.5   3.5   4.5
#   HALF-EVEN   -4    -2    -2     0     0     2     2     4     4   <- DuckDB
#   truncate    -3    -2    -1     0     0     1     2     3     4
#   half-away   -4    -3    -2    -1     1     2     3     4     5
#   floor       -4    -3    -2    -1     0     1     2     3     4
#   ceil        -3    -2    -1     0     1     2     3     4     5
#
# ⛔ NO SINGLE VALUE SEPARATES ALL FIVE. -1.5 alone kills truncate and ceil but
# NOT half-away or floor; 2.5 alone kills half-away and ceil but not floor or
# truncate. THE POSITIVE ODD HALVES (1.5, 3.5) ARE THE ONES THE OLD CORPUS
# LACKED ENTIRELY — over its f64 column the other ties agreed with truncation by
# coincidence of the even neighbour, so a "halves round toward zero" fix would
# have printed GREEN while shipping 3.5 -> 3.


def test_round_half_to_even_is_the_rule_duckdb_uses() raises:
    """The shared rounding rule, over both signs of every .5 boundary.

    ⭐ THESE NINE ANSWERS ARE A TRANSCRIPT, not a derivation: measured on the
    `duckdb` v1.5.3 CLI 2026-09-15 as `CAST(x AS BIGINT)` over a DOUBLE COLUMN.
    ⚠ Over a LITERAL they differ — `CAST(2.5 AS BIGINT)` is 3, because a bare
    `2.5` is DECIMAL(2,1) and DECIMAL rounds half AWAY FROM ZERO. Re-deriving
    these from the CLI the short way reproduces the wrong model.
    """
    var xs: List[Float64] = [-3.5, -2.5, -1.5, -0.5, 0.5, 1.5, 2.5, 3.5, 4.5]
    var want: List[Int64] = [-4, -2, -2, 0, 0, 2, 2, 4, 4]
    for i in range(len(xs)):
        var got = Int64(round_half_to_even[DType.float64, 1](
            SIMD[DType.float64, 1](xs[i]))[0])
        assert_equal(got, want[i])


def test_round_half_to_even_leaves_non_ties_alone() raises:
    """A non-tie rounds to its nearest neighbour in BOTH directions.

    ⚠ WITHOUT THIS, "always return the even integer below" passes every tie case
    above. 2.6 -> 3 (odd) is the assertion that forbids it.
    """
    var xs: List[Float64] = [2.4, 2.6, -2.4, -2.6, 0.0, 7.0, -7.0]
    var want: List[Int64] = [2, 3, -2, -3, 0, 7, -7]
    for i in range(len(xs)):
        var got = Int64(round_half_to_even[DType.float64, 1](
            SIMD[DType.float64, 1](xs[i]))[0])
        assert_equal(got, want[i])


def test_cast_f64_to_i64_rounds_half_to_even() raises:
    """The ARRAY kernel on the live SQL path: FLOAT64 -> INT64."""
    var values: List[Scalar[DType.float64]] = [
        Scalar[DType.float64](-3.5), Scalar[DType.float64](-2.5),
        Scalar[DType.float64](-1.5), Scalar[DType.float64](-0.5),
        Scalar[DType.float64](0.5),  Scalar[DType.float64](1.5),
        Scalar[DType.float64](2.5),  Scalar[DType.float64](3.5),
    ]
    var col = PrimitiveArray[DType.float64].from_list(values)
    var out = eval_cast_float_to_int[DType.float64, DType.int64](col)
    var want: List[Int64] = [-4, -2, -2, 0, 0, 2, 2, 4]
    assert_equal(out.length, 8)
    for i in range(8):
        assert_equal(out.get(i), Scalar[DType.int64](want[i]))


def test_cast_f64_to_i32_rounds_half_to_even() raises:
    """FLOAT64 -> INT32 is a SEPARATE instantiation and is asserted separately.

    ⛔ NOT REDUNDANT WITH THE I64 CASE. The two widths reached the executor
    through different arms, and the corpus registered them as two divergences
    for exactly that reason: a fix confined to the 64-bit target left this live.
    """
    var values: List[Scalar[DType.float64]] = [
        Scalar[DType.float64](-3.5), Scalar[DType.float64](-1.5),
        Scalar[DType.float64](2.5),  Scalar[DType.float64](3.5),
    ]
    var col = PrimitiveArray[DType.float64].from_list(values)
    var out = eval_cast_float_to_int[DType.float64, DType.int32](col)
    var want: List[Int32] = [-4, -2, 2, 4]
    for i in range(4):
        assert_equal(out.get(i), Scalar[DType.int32](want[i]))


def test_cast_f32_source_rounds_half_to_even() raises:
    """FLOAT32 -> INT64. A THIRD instantiation, and the source width is the point.

    ⚠ Without a FLOAT32 source arm in the executor's cast ladder,
    `CAST(f32 AS BIGINT)` does not merely round wrongly — it RAISES
    `PipelineCompiler: unsupported EXPR_CAST from float32 to int64` at the
    customer. Every value here is exactly representable in float32, so the expected
    column is not an artefact of the literal's decimal spelling.
    """
    var values: List[Scalar[DType.float32]] = [
        Scalar[DType.float32](-3.5), Scalar[DType.float32](-2.5),
        Scalar[DType.float32](-1.5), Scalar[DType.float32](-0.5),
        Scalar[DType.float32](0.5),  Scalar[DType.float32](1.5),
        Scalar[DType.float32](2.5),  Scalar[DType.float32](3.5),
    ]
    var col = PrimitiveArray[DType.float32].from_list(values)
    var out = eval_cast_float_to_int[DType.float32, DType.int64](col)
    var want: List[Int64] = [-4, -2, -2, 0, 0, 2, 2, 4]
    for i in range(8):
        assert_equal(out.get(i), Scalar[DType.int64](want[i]))


def test_cast_float_to_int_preserves_the_null_mask() raises:
    """A nullable cast keeps its nulls.

    ⛔ THE SILENT-WRONG THIS FORBIDS: a cast that came back all-valid would turn
    every NULL into the integer its garbage slot happened to round to, and the
    corpus rows all carry a NULL row precisely to catch it.
    """
    var col = PrimitiveArray[DType.float64].allocate_nullable(3)
    col.set(0, Scalar[DType.float64](2.5))
    col.set(1, Scalar[DType.float64](0.0))
    col.set(2, Scalar[DType.float64](3.5))
    col.validity.value().clear(1)
    col.null_count = 1

    var out = eval_cast_float_to_int[DType.float64, DType.int64](col)
    assert_equal(out.null_count, 1)
    assert_true(out.is_null(1))
    assert_false(out.is_null(0))
    assert_false(out.is_null(2))
    assert_equal(out.get(0), Scalar[DType.int64](2))
    assert_equal(out.get(2), Scalar[DType.int64](4))


# =============================================================================
# FLOAT -> INTEGER CAST: THE OVERFLOW GUARD
# =============================================================================
#
# ⭐ THE ACCEPT WINDOW IS A TRANSCRIPT OF DuckDB v1.5.3, MEASURED ON THE CLI,
# NOT A DERIVATION. Every boundary below was run as
# `SELECT CAST(<literal>::<DOUBLE|FLOAT> AS <BIGINT|INTEGER>)`:
#
#     CAST(9223372036854774784::DOUBLE AS BIGINT)   -> 9223372036854774784
#     CAST(9223372036854775807::DOUBLE AS BIGINT)   -> Conversion Error   (the
#         literal is 2^63 exactly once it is a DOUBLE; `= 9223372036854775808::DOUBLE`
#         is TRUE, which is why INT64_MAX itself cannot be cast back)
#     CAST(-9223372036854775808::DOUBLE AS BIGINT)  -> -9223372036854775808
#     CAST(-9223372036854777856::DOUBLE AS BIGINT)  -> Conversion Error
#     CAST(2147483647.4::DOUBLE AS INTEGER)         -> 2147483647
#     CAST(2147483648.0::DOUBLE AS INTEGER)         -> Conversion Error
#     CAST(-2147483648.0::DOUBLE AS INTEGER)        -> -2147483648
#     CAST(-2147483648.4::DOUBLE AS INTEGER)        -> Conversion Error
#     CAST(2147483520.0::FLOAT  AS INTEGER)         -> 2147483520
#     CAST(2147483648.0::FLOAT  AS INTEGER)         -> Conversion Error
#     CAST(9223371487098961920::FLOAT AS BIGINT)    -> 9223371487098961920
#     CAST('nan'::DOUBLE AS BIGINT) / 'inf' / '-inf' -> Conversion Error
#
# ⛔⛔ THE TEST THE `-2147483648.4` ROW EXISTS TO FORBID, AND IT IS THE ONE A
# GUARD WRITTEN THE OBVIOUS WAY FAILS. `-2147483648.4` ROUNDS to `-2147483648`,
# which IS representable — so a guard that rounds FIRST and range-checks the
# ROUNDED value ACCEPTS it, where DuckDB raises. The window is checked on the
# RAW value: `v >= -2^(N-1)` and `v < +2^(N-1)`, both bounds exact in float32
# and float64 alike. That single comparison also rejects NaN (every comparison
# against NaN is false) and both infinities, so the specials need no arm.
#
# ⚠ AND THE OPPOSITE RESIDUAL IS REAL AND IS ASSERTED BELOW: `2147483647.5`
# PASSES the raw window and then rounds half-to-even to `2147483648`, which does
# NOT fit an INT32. DuckDB v1.5.3 answers `2147483647` there. That answer is
# ARM's saturating `fcvtzs` showing through a `static_cast` DuckDB leaves
# undefined, not a decided rule -- an x86 build of the same version would answer
# INT32_MIN. `eval_cast_float_to_int` CLAMPS, so this engine answers the same
# number on every platform and matches the oracle box.


def test_cast_f64_to_i64_overflow_raises() raises:
    """`CAST(1e308 AS BIGINT)` must REFUSE, not answer a wrapped integer.

    ⛔ THE DEFECT THIS CLOSES: a wrapped integer is a plausible finite number and
    NOTHING in the result marks it as manufactured -- the customer cannot tell it
    from a real answer. Same class as a spreadsheet `EXP(1000)` overflow
    rendered as Int64::MIN with `ISNUMBER` answering TRUE.
    """
    var values: List[Scalar[DType.float64]] = [Scalar[DType.float64](1e308)]
    var col = PrimitiveArray[DType.float64].from_list(values)
    var raised = False
    var msg = String("")
    var got = Int64(0)
    try:
        var out = eval_cast_float_to_int[DType.float64, DType.int64](col)
        got = Int64(out.get(0))
    except e:
        raised = True
        msg = String(e)
    assert_true(
        raised,
        "CAST(1e308 AS BIGINT): expected a Conversion Error, ANSWERED "
        + String(got),
    )
    assert_true("out of range" in msg, "message must say out of range: " + msg)
    assert_true("INT64" in msg, "message must name the destination type: " + msg)


def test_cast_f64_to_i64_negative_overflow_raises() raises:
    """The NEGATIVE side, which a guard written only for the upper bound misses.

    ⭐ Registered as its own case for the same reason `refuse:ovf_i64_min_minus_1`
    is registered beside `refuse:ovf_i64_max_plus_1` in the SQL-cast ledger.
    """
    var values: List[Scalar[DType.float64]] = [Scalar[DType.float64](-1e308)]
    var col = PrimitiveArray[DType.float64].from_list(values)
    var raised = False
    var got = Int64(0)
    try:
        var out = eval_cast_float_to_int[DType.float64, DType.int64](col)
        got = Int64(out.get(0))
    except e:
        raised = True
    assert_true(
        raised,
        "CAST(-1e308 AS BIGINT): expected a Conversion Error, ANSWERED "
        + String(got),
    )


def test_cast_f64_to_i64_nan_and_infinities_raise() raises:
    """NaN, +Inf and -Inf each get a DECIDED answer, and it is REFUSE.

    ⚠ MEASURED, not assumed: DuckDB v1.5.3 raises for all three and uses the SAME
    sentence it uses for a finite out-of-range value ("... with value nan can't be
    cast because the value is out of range"). It does not have a NaN-specific arm
    and neither does this kernel -- the raw-value window rejects all three because
    every comparison against NaN is false.
    """
    var xs: List[Float64] = [
        Float64("nan"), Float64("inf"), Float64("-inf"),
    ]
    for i in range(len(xs)):
        var values: List[Scalar[DType.float64]] = [Scalar[DType.float64](xs[i])]
        var col = PrimitiveArray[DType.float64].from_list(values)
        var raised = False
        var got = Int64(0)
        try:
            var out = eval_cast_float_to_int[DType.float64, DType.int64](col)
            got = Int64(out.get(0))
        except e:
            raised = True
        assert_true(
            raised,
            "specials["
            + String(i)
            + "]: expected a Conversion Error, ANSWERED "
            + String(got),
        )


def test_cast_f64_to_i32_overflow_raises() raises:
    """FLOAT64 -> INT32 is a SEPARATE instantiation and is asserted separately.

    ⛔ NOT REDUNDANT WITH THE I64 CASE: 3e9 is perfectly in range for an INT64 and
    out of range only for the narrower target, so a guard that hard-codes the
    64-bit bounds passes the I64 cases and ships this one wrong.
    """
    var values: List[Scalar[DType.float64]] = [Scalar[DType.float64](3e9)]
    var col = PrimitiveArray[DType.float64].from_list(values)
    var raised = False
    var msg = String("")
    var got = Int32(0)
    try:
        var out = eval_cast_float_to_int[DType.float64, DType.int32](col)
        got = Int32(out.get(0))
    except e:
        raised = True
        msg = String(e)
    assert_true(
        raised,
        "CAST(3e9 AS INTEGER): expected a Conversion Error, ANSWERED "
        + String(got),
    )
    assert_true("INT32" in msg, "message must name the destination type: " + msg)


def test_cast_f32_source_overflow_raises_for_both_targets() raises:
    """FLOAT32 source, BOTH integer targets. Two more instantiations.

    ⚠ 1e30 is out of range for INT64 *and* INT32, so one value asks both
    questions; the two targets are still separate template instantiations and a
    fix confined to one leaves the other live (the same shape as a FLOAT32
    source arm missing entirely).
    """
    var values: List[Scalar[DType.float32]] = [Scalar[DType.float32](1e30)]
    var col = PrimitiveArray[DType.float32].from_list(values)
    var raised64 = False
    var got64 = Int64(0)
    try:
        var o64 = eval_cast_float_to_int[DType.float32, DType.int64](col)
        got64 = Int64(o64.get(0))
    except e:
        raised64 = True
    assert_true(
        raised64,
        "CAST(1e30::FLOAT AS BIGINT): expected a Conversion Error, ANSWERED "
        + String(got64),
    )
    var raised32 = False
    var got32 = Int32(0)
    try:
        var o32 = eval_cast_float_to_int[DType.float32, DType.int32](col)
        got32 = Int32(o32.get(0))
    except e:
        raised32 = True
    assert_true(
        raised32,
        "CAST(1e30::FLOAT AS INTEGER): expected a Conversion Error, ANSWERED "
        + String(got32),
    )


def test_cast_f64_to_i64_accepts_the_largest_representable() raises:
    """The window is not merely CLOSED -- it is closed IN THE RIGHT PLACE.

    ⛔ WITHOUT THIS, "raise on everything above 1e18" passes every refusal case
    above while REFUSING a value DuckDB answers. Both bounds are exact doubles:
    -2^63 is INT64_MIN exactly, and 9223372036854774784 is the largest double
    strictly below 2^63.
    """
    var values: List[Scalar[DType.float64]] = [
        Scalar[DType.float64](9223372036854774784.0),
        Scalar[DType.float64](-9223372036854775808.0),
        Scalar[DType.float64](0.0),
    ]
    var col = PrimitiveArray[DType.float64].from_list(values)
    var out = eval_cast_float_to_int[DType.float64, DType.int64](col)
    assert_equal(out.get(0), Scalar[DType.int64](9223372036854774784))
    assert_equal(out.get(1), Scalar[DType.int64](-9223372036854775808))
    assert_equal(out.get(2), Scalar[DType.int64](0))


def test_cast_f64_to_i32_window_is_checked_on_the_raw_value() raises:
    """⛔⛔ THE CASE A ROUND-THEN-CHECK GUARD GETS WRONG, IN BOTH DIRECTIONS.

    `-2147483648.4` rounds to INT32_MIN, which fits -- and DuckDB v1.5.3 RAISES,
    because its window is `v >= -2^31 and v < 2^31` over the RAW value. The
    accepted twin `2147483647.4` proves the upper bound is not simply INT32_MAX.
    """
    var ok: List[Scalar[DType.float64]] = [
        Scalar[DType.float64](2147483647.4),
        Scalar[DType.float64](-2147483648.0),
    ]
    var okcol = PrimitiveArray[DType.float64].from_list(ok)
    var okout = eval_cast_float_to_int[DType.float64, DType.int32](okcol)
    assert_equal(okout.get(0), Scalar[DType.int32](2147483647))
    assert_equal(okout.get(1), Scalar[DType.int32](-2147483648))

    var bad: List[Float64] = [-2147483648.4, 2147483648.0, -2147483649.0]
    for i in range(len(bad)):
        var values: List[Scalar[DType.float64]] = [Scalar[DType.float64](bad[i])]
        var col = PrimitiveArray[DType.float64].from_list(values)
        var raised = False
        var got = Int32(0)
        try:
            var out = eval_cast_float_to_int[DType.float64, DType.int32](col)
            got = Int32(out.get(0))
        except e:
            raised = True
        assert_true(
            raised,
            "raw-window["
            + String(i)
            + "]: expected a Conversion Error, ANSWERED "
            + String(got),
        )


def test_cast_f64_to_i32_clamps_the_one_rounding_overshoot() raises:
    """2147483647.5 PASSES the raw window and rounds half-to-even PAST INT32_MAX.

    ⚠ A DECIDED ANSWER, NOT A MEASURED RULE. DuckDB v1.5.3 on this arm64 box
    answers 2147483647 -- ARM's saturating `fcvtzs` showing through a cast its
    source leaves undefined. The kernel CLAMPS so the answer is the same on every
    platform. The neighbouring `2147483645.5 -> 2147483646` row is DuckDB's own
    (half to even, and the even neighbour is DOWN) and pins that the clamp has
    not been written as "always return MAX".
    """
    var values: List[Scalar[DType.float64]] = [
        Scalar[DType.float64](2147483647.5),
        Scalar[DType.float64](2147483645.5),
    ]
    var col = PrimitiveArray[DType.float64].from_list(values)
    var out = eval_cast_float_to_int[DType.float64, DType.int32](col)
    assert_equal(out.get(0), Scalar[DType.int32](2147483647))
    assert_equal(out.get(1), Scalar[DType.int32](2147483646))


# =============================================================================
# TRY_CAST: THE OTHER HALF OF EVERY OVERFLOW ABOVE
# =============================================================================


def test_try_cast_float_to_int_nulls_the_overflowing_rows() raises:
    """`TRY_CAST(1e308 AS BIGINT)` is NULL where `CAST` raises (DuckDB v1.5.3).

    ⛔⛔ AND THE NULL MUST BE CARRIED BY A VALIDITY BITMAP THAT EXISTS. If
    `walk_expr_field` declared a TRY over a non-nullable child NON-NULLABLE
    while its kernel produced NULLs -- `Field.nullable` is read
    downstream as a licence to allocate NO validity bitmap, so the value reaching
    the customer would be a garbage NUMBER. This asserts the bitmap, the per-row
    `is_null`, AND `null_count`, because a kernel that sets the bytes and forgets
    the count is the same silent wrong one layer down.
    """
    var values: List[Scalar[DType.float64]] = [
        Scalar[DType.float64](1e308),
        Scalar[DType.float64](2.5),
        Scalar[DType.float64](-1e308),
        Scalar[DType.float64](-3.5),
    ]
    var col = PrimitiveArray[DType.float64].from_list(values)
    var out = eval_cast_float_to_int[DType.float64, DType.int64](col, True)
    assert_equal(out.length, 4)
    assert_true(Bool(out.validity), "TRY overflow: a validity bitmap must exist")
    assert_equal(out.null_count, 2)
    assert_true(out.is_null(0), "row 0 (1e308) must be NULL")
    assert_false(out.is_null(1), "row 1 (2.5) must be valid")
    assert_true(out.is_null(2), "row 2 (-1e308) must be NULL")
    assert_false(out.is_null(3), "row 3 (-3.5) must be valid")
    assert_equal(out.get(1), Scalar[DType.int64](2))
    assert_equal(out.get(3), Scalar[DType.int64](-4))


def test_try_cast_float_to_int_nulls_nan_and_infinities() raises:
    """NaN / +Inf / -Inf under TRY are NULL, matching DuckDB v1.5.3.

    ⚠ ASSERTED OVER A MIXED COLUMN so the surviving row proves the kernel did not
    simply null everything -- an all-null output would pass a test that only
    checked the three specials.
    """
    var values: List[Scalar[DType.float64]] = [
        Scalar[DType.float64](Float64("nan")),
        Scalar[DType.float64](7.0),
        Scalar[DType.float64](Float64("inf")),
        Scalar[DType.float64](Float64("-inf")),
    ]
    var col = PrimitiveArray[DType.float64].from_list(values)
    var out = eval_cast_float_to_int[DType.float64, DType.int64](col, True)
    assert_equal(out.null_count, 3)
    assert_true(out.is_null(0), "nan -> NULL")
    assert_false(out.is_null(1), "7.0 stays")
    assert_true(out.is_null(2), "inf -> NULL")
    assert_true(out.is_null(3), "-inf -> NULL")
    assert_equal(out.get(1), Scalar[DType.int64](7))


def test_try_cast_float_to_int_unions_source_nulls_with_overflow_nulls() raises:
    """A SOURCE null and an OVERFLOW null land in the SAME bitmap and BOTH count.

    ⛔ THE ARITHMETIC THIS FORBIDS: a kernel that builds the overflow mask and
    then OVERWRITES the output validity with a copy of the input's loses every
    overflow null (and vice versa loses every source null). Either way the count
    reads 1 where it must read 2.
    """
    var col = PrimitiveArray[DType.float64].allocate_nullable(4)
    col.set(0, Scalar[DType.float64](1e308))
    col.set(1, Scalar[DType.float64](0.0))
    col.set(2, Scalar[DType.float64](2.5))
    col.set(3, Scalar[DType.float64](3.5))
    col.validity.value().clear(1)
    col.null_count = 1

    var out = eval_cast_float_to_int[DType.float64, DType.int64](col, True)
    assert_equal(out.null_count, 2)
    assert_true(out.is_null(0), "overflow row")
    assert_true(out.is_null(1), "source-null row")
    assert_false(out.is_null(2), "2.5 survives")
    assert_equal(out.get(2), Scalar[DType.int64](2))
    assert_equal(out.get(3), Scalar[DType.int64](4))


def test_try_cast_f32_and_i32_targets_null_too() raises:
    """The TRY arm exists on ALL FOUR instantiations, not only the f64->i64 one.

    ⚠ `try_mode` is a RUNTIME argument to a COMPTIME-parameterised kernel, so
    nothing in the type system makes one instantiation's behaviour evidence for
    another's. Four call sites, four assertions.
    """
    var f32vals: List[Scalar[DType.float32]] = [
        Scalar[DType.float32](1e30), Scalar[DType.float32](2.5)
    ]
    var f32col = PrimitiveArray[DType.float32].from_list(f32vals)
    var a = eval_cast_float_to_int[DType.float32, DType.int64](f32col, True)
    assert_equal(a.null_count, 1)
    assert_true(a.is_null(0))
    assert_equal(a.get(1), Scalar[DType.int64](2))
    var b = eval_cast_float_to_int[DType.float32, DType.int32](f32col, True)
    assert_equal(b.null_count, 1)
    assert_true(b.is_null(0))
    assert_equal(b.get(1), Scalar[DType.int32](2))

    var f64vals: List[Scalar[DType.float64]] = [
        Scalar[DType.float64](3e9), Scalar[DType.float64](-3.5)
    ]
    var f64col = PrimitiveArray[DType.float64].from_list(f64vals)
    var c = eval_cast_float_to_int[DType.float64, DType.int32](f64col, True)
    assert_equal(c.null_count, 1)
    assert_true(c.is_null(0))
    assert_equal(c.get(1), Scalar[DType.int32](-4))


def test_strict_cast_still_answers_every_in_range_value() raises:
    """⛔ THE REGRESSION A GUARD CAN CAUSE: refusing a value that always worked.

    Re-asserts the half-to-even transcript THROUGH the new guard, so a window
    written one ulp too tight reds here rather than in a customer's query.
    """
    var values: List[Scalar[DType.float64]] = [
        Scalar[DType.float64](-3.5), Scalar[DType.float64](-2.5),
        Scalar[DType.float64](-1.5), Scalar[DType.float64](-0.5),
        Scalar[DType.float64](0.5),  Scalar[DType.float64](1.5),
        Scalar[DType.float64](2.5),  Scalar[DType.float64](3.5),
    ]
    var col = PrimitiveArray[DType.float64].from_list(values)
    var out = eval_cast_float_to_int[DType.float64, DType.int64](col)
    var want: List[Int64] = [-4, -2, -2, 0, 0, 2, 2, 4]
    for i in range(8):
        assert_equal(out.get(i), Scalar[DType.int64](want[i]))
    assert_equal(out.null_count, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
