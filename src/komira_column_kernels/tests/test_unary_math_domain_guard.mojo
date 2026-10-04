# =============================================================================
# test_unary_math_domain_guard — the SIXTEEN points DuckDB v1.5.3 REFUSES and
# libm answers, plus the FIVE points a careless guard would refuse and DuckDB
# answers
# =============================================================================
#
# ★ WHY THIS FILE EXISTS. Without a domain check, a unary math op that calls
# libm inherits libm's IEEE result where SQL's answer is an ERROR: `ln(0)` is
# `-inf`, `asin(2)` is `nan`, `cot(0)` is `inf`. ⛔ THAT CLASS IS A WRONG VALUE, NOT A REFUSAL AND NOT A ULP — and it is
# the worst-shaped kind, because `-inf`/`nan` PROPAGATE. A `SUM` over a column
# holding one is `nan` for every row and a `MIN` is `-inf`, so the failure
# arrives at the far end of the query with nothing at the call site left to
# attribute it to. `check_unary_domain` closes it; this file is what keeps it
# closed AT THE KERNEL.
#
# ⚠ THE SQL-DOOR GRADING IS SOMEWHERE ELSE AND THIS DOES NOT REPLACE IT.
# The SQL conformance corpus grades the same points END TO END through the SQL
# door, against DuckDB v1.5.3's own transcript. What THIS file adds is the
# three things an end-to-end corpus cannot ask cheaply, each of which is a way
# to "fix" the defect and introduce a worse one:
#
#   1. THE EXACT SENTENCE, PER POINT. v1.5.3 says "cannot take logarithm of
#      zero" AT zero and "...of a negative number" BELOW it. One message for
#      both points is a DIFFERENT defect from no guard.
#   2. THE POINTS THAT MUST STILL ANSWER — NaN, `-0.0`, and the CLOSED endpoint
#      `|x| == 1`. A guard written as `signbit(x)` or `|x| >= 1` passes every
#      refusal assertion in this file and breaks all three.
#   3. THE NULL EXEMPTION. A null slot's payload bytes are arbitrary (typically
#      0.0 off parquet), so a guard that walked them would turn `ln(NULL)` into
#      "cannot take logarithm of zero" on whichever rows a writer left zeroed.
#
# ⛔ THE ACOSH / GAMMA-AT-NEGATIVE NON-ROWS ARE DELIBERATE AND ARE ASSERTED AS
# CONTROLS, NOT OMITTED. `acosh(0.5)` and `gamma(-8.0)` are OUTSIDE the
# mathematical domain and DuckDB v1.5.3 ANSWERS BOTH WITH NaN, as ordinary
# values. "Undefined in mathematics" is therefore NOT the predicate this
# guard implements; "v1.5.3 raises" is. A reader who adds an ACOSH arm here
# because the maths says so makes this engine refuse a query DuckDB answers,
# which is the same class of divergence pointed the other way.
# =============================================================================

from std.sys import size_of
from std.testing import TestSuite, assert_equal, assert_true, assert_raises

from komira_arrow.bitmap import Bitmap
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.primitive_array import PrimitiveArray
from komira_buffer.heap_region import HeapRegion

from komira_column_kernels.scalar_math import (
    KMATH_ACOS,
    KMATH_ACOSH,
    KMATH_ASIN,
    KMATH_ATANH,
    KMATH_COT,
    KMATH_GAMMA,
    KMATH_LN,
    KMATH_LOG10,
    KMATH_LOG2,
    KMATH_SQRT,
    eval_math_unary,
)


# ---------------------------------------------------------------------------
# Fixtures. ⚠ THE VALUE IN A NULL SLOT IS CHOSEN, NOT LEFT TO THE ALLOCATOR —
# `test_null_slot_payload_does_not_reach_the_guard` asserts a NEGATIVE claim
# ("this does not raise"), and a negative claim over undefined bytes is
# vacuous. 0.0 is chosen because it is what a parquet writer leaves behind and
# because it is in the REFUSING set for LN/COT/GAMMA.
# ---------------------------------------------------------------------------


def _f64(raw: List[Float64]) raises -> PrimitiveArray[DType.float64]:
    """A non-nullable FLOAT64 array — the shape every refusal assertion uses."""
    var n = len(raw)
    comptime elem = size_of[Scalar[DType.float64]]()
    var buf = OwnedAlignedBuffer(max(n, 1) * elem)
    for i in range(n):
        buf.set_typed[Scalar[DType.float64]](i, Scalar[DType.float64](raw[i]))
    buf.set_length(Int64(n * elem))
    return PrimitiveArray[DType.float64](
        buf^, n, Optional[Bitmap[HeapRegion]](None), 0, 0
    )


def _f64_nulls(
    raw: List[Float64], null_at: List[Int]
) raises -> PrimitiveArray[DType.float64]:
    """The same with a validity bitmap — `null_at` slots carry `raw`'s bytes
    anyway, which is the whole point of the null-exemption test."""
    var n = len(raw)
    comptime elem = size_of[Scalar[DType.float64]]()
    var buf = OwnedAlignedBuffer(max(n, 1) * elem)
    for i in range(n):
        buf.set_typed[Scalar[DType.float64]](i, Scalar[DType.float64](raw[i]))
    buf.set_length(Int64(n * elem))
    var validity = Bitmap.create_all_valid(n)
    for k in range(len(null_at)):
        validity.clear(null_at[k])
    return PrimitiveArray[DType.float64](
        buf^, n, Optional[Bitmap[HeapRegion]](validity^), len(null_at), 0
    )


def _one(op: UInt8, x: Float64) raises -> Float64:
    """Drive ONE value through the real kernel and read the cell back."""
    var one: List[Float64] = [x]
    var got = eval_math_unary(op, _f64(one))
    return Float64(got.get(0))


# =============================================================================
# THE SIXTEEN REFUSALS — each one a DuckDB refusal, each sentence verbatim
# =============================================================================


def test_logarithm_of_zero_refuses_with_the_zero_sentence() raises:
    """LN / LOG10 / LOG2 at exactly 0. ⚠ `log` is LOG10 in DuckDB, so `log(0)`
    and `log10(0)` are the SAME kernel point reached through two SQL
    spellings."""
    var logs: List[UInt8] = [KMATH_LN, KMATH_LOG10, KMATH_LOG2]
    for i in range(len(logs)):
        with assert_raises(contains="cannot take logarithm of zero"):
            _ = _one(logs[i], 0.0)


def test_logarithm_of_negative_refuses_with_the_OTHER_sentence() raises:
    """⛔ A DIFFERENT SENTENCE FROM THE ZERO ROWS. A guard that fired
    with one message at both points would satisfy the test above and still
    diverge from v1.5.3 here."""
    var logs: List[UInt8] = [KMATH_LN, KMATH_LOG10, KMATH_LOG2]
    for i in range(len(logs)):
        with assert_raises(contains="logarithm of a negative number"):
            _ = _one(logs[i], -8.0)


def test_sqrt_of_negative_refuses() raises:
    """`sqrt` of a negative number is an ERROR in DuckDB, not a value."""
    with assert_raises(contains="cannot take square root of a negative number"):
        _ = _one(KMATH_SQRT, -1.0)


def test_inverse_circular_refuses_ABOVE_the_interval() raises:
    var inv: List[UInt8] = [KMATH_ASIN, KMATH_ACOS, KMATH_ATANH]
    for i in range(len(inv)):
        with assert_raises(contains="undefined outside [-1,1]"):
            _ = _one(inv[i], 100.0)


def test_inverse_circular_refuses_BELOW_the_interval() raises:
    """⛔ THE INTERVAL TEST IS TWO-SIDED AND THIS IS THE HALF A READER MISSES.
    The one-sided `x > 1.0` shape closes the three rows above and leaves these
    three open."""
    var inv: List[UInt8] = [KMATH_ASIN, KMATH_ACOS, KMATH_ATANH]
    for i in range(len(inv)):
        with assert_raises(contains="undefined outside [-1,1]"):
            _ = _one(inv[i], -8.0)


def test_each_inverse_circular_names_ITSELF_in_its_message() raises:
    """The loops above would pass if all three ops shared one message. v1.5.3
    names the FUNCTION, and a caller reading `ASIN is undefined` off an `acos`
    call has been told the wrong thing about its own query."""
    with assert_raises(contains="ASIN is undefined"):
        _ = _one(KMATH_ASIN, 2.0)
    with assert_raises(contains="ACOS is undefined"):
        _ = _one(KMATH_ACOS, 2.0)
    with assert_raises(contains="ATANH is undefined"):
        _ = _one(KMATH_ATANH, 2.0)


def test_cot_of_zero_refuses() raises:
    """v1.5.3's sentence carries the VALUE, formatted `%f`."""
    with assert_raises(
        contains="input value 0.000000 is out of range for numeric function"
    ):
        _ = _one(KMATH_COT, 0.0)


def test_gamma_of_zero_refuses() raises:
    with assert_raises(contains="cannot take gamma of zero"):
        _ = _one(KMATH_GAMMA, 0.0)


# =============================================================================
# THE POINTS THAT MUST STILL ANSWER — every one of these is a way to over-guard
# =============================================================================


def test_closed_endpoints_still_ANSWER() raises:
    """⚠ `|x| > 1` STRICTLY, NEVER `>=`. v1.5.3 answers `asin(1)` = pi/2,
    `acos(-1)` = pi and `atanh(1)` = +inf, so a `>=` guard turns a VALUE into
    a refusal."""
    var asin1 = _one(KMATH_ASIN, 1.0)
    assert_true(asin1 > 1.5707 and asin1 < 1.5708, "asin(1) == pi/2")
    var acosm1 = _one(KMATH_ACOS, -1.0)
    assert_true(acosm1 > 3.1415 and acosm1 < 3.1416, "acos(-1) == pi")
    var at1 = _one(KMATH_ATANH, 1.0)
    assert_true(at1 > 0.0 and not (at1 < Float64(1.0e308)), "atanh(1) == +inf")


def test_negative_zero_is_NOT_negative() raises:
    """⚠ `sqrt(-0.0)` = `-0.0` in v1.5.3 — a VALUE. `x < 0.0` is FALSE for
    `-0.0`; a
    `signbit()` test would refuse it and be wrong."""
    var got = _one(KMATH_SQRT, -0.0)
    assert_equal(got, Float64(0.0), "sqrt(-0.0) answers, and answers zero")


def test_nan_in_nan_out_is_not_a_refusal() raises:
    """Every comparison in the guard is FALSE for NaN, so a NaN argument falls
    through to libm and returns NaN — which is what v1.5.3 does. ⛔ Do NOT
    "tighten" this into an `isnan` refusal."""
    var nan_in = Float64(0.0) / Float64(0.0)
    var ops: List[UInt8] = [KMATH_SQRT, KMATH_LN, KMATH_ASIN, KMATH_ATANH]
    for i in range(len(ops)):
        var got = _one(ops[i], nan_in)
        assert_true(got != got, "NaN in, NaN out — no raise")


def test_acosh_and_gamma_negative_ANSWER_NaN_and_are_not_guarded() raises:
    """⛔ THE CONTROL THAT STOPS THE GUARD FROM GROWING. Both points are
    OUTSIDE the mathematical domain and v1.5.3 answers NaN at both, as ordinary
    values. The
    predicate this guard implements is "v1.5.3 raises", not "maths is
    undefined"."""
    var a = _one(KMATH_ACOSH, 0.5)
    assert_true(a != a, "acosh(0.5) is NaN and does NOT raise")
    var g = _one(KMATH_GAMMA, -8.0)
    assert_true(g != g, "gamma(-8.0) is NaN and does NOT raise")


def test_null_slot_payload_does_not_reach_the_guard() raises:
    """⛔ THE ROW THE GUARD MUST NOT SEE. Slot 1 is NULL and its payload is
    0.0 — the value a parquet writer leaves behind and, for LN, the value that
    REFUSES. If the guard walked every slot, `ln(NULL)` would become "cannot
    take logarithm of zero" on whichever rows happened to be zeroed, which is a
    data-dependent refusal of a query that has a correct answer (NULL)."""
    var vals: List[Float64] = [1.0, 0.0, 2.718281828459045]
    var nulls: List[Int] = [1]
    var arr = _f64_nulls(vals, nulls)
    var got = eval_math_unary(KMATH_LN, arr^)
    assert_equal(got.length, 3, "null-exempt: length")
    assert_true(got.is_null(1), "the null slot stays NULL, not an error")
    assert_equal(got.null_count, 1, "null-exempt: null_count carried")
    var v0 = Float64(got.get(0))
    assert_true(v0 > -1.0e-9 and v0 < 1.0e-9, "ln(1.0) == 0 on the valid rows")


def test_a_valid_row_BESIDE_a_null_still_refuses() raises:
    """The mirror of the test above, and the reason it is not just "skip
    everything when a bitmap is present". Slot 0 is a REAL 0.0 and must still
    refuse even though slot 1 is NULL — a guard keyed on `Bool(arr.validity)`
    instead of `arr.is_null(i)` would silently stop guarding every nullable
    column in the tree."""
    var vals: List[Float64] = [0.0, 0.0, 1.0]
    var nulls: List[Int] = [1]
    var arr = _f64_nulls(vals, nulls)
    with assert_raises(contains="cannot take logarithm of zero"):
        _ = eval_math_unary(KMATH_LN, arr^)


# =============================================================================
# Entry point
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
