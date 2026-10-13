# =============================================================================
# test_string_fn_and_math_fn_kernels — `EXPR_STRING_FN` and `EXPR_MATH_FN`
# EXECUTED, cell for cell against DuckDB v1.5.3
# =============================================================================
#
# ⭐ WHY THIS FILE EXISTS: the round-trip corpus proves an op SURVIVES
# ENCODING and the binder-signature corpus proves a NAME REACHES an op; between
# them they would be entirely green with every arm of `scalar_math._apply_unary`
# returning `x`. This file is the third leg — KERNEL VALUES — for the math ops
# and the single-argument string ops (`test_string_fn_n_kernels.mojo` is its
# sibling for the VARIADIC family).
#
# ⛔ EVERY EXPECTED VALUE BELOW WAS MEASURED OUT OF DuckDB v1.5.3 OVER THESE
# EXACT ROWS AND TRANSCRIBED. Do not "correct" one by reading the kernel — that
# inverts what the file is for.
#
# ⛔⛔ AND ONE OF THEM CANNOT COME FROM PYTHON. CPython's `math.gamma` is NOT
# libm's `tgamma`: it is a Lanczos series in `Modules/mathmodule.c`, and over
# [1.5, 2, 2.5, 3.7, 6.5, 10, 17, 33, 60] FOUR of the nine disagree with libm
# in the last ulp (`gamma(1.5)` = 0.886226925452758 from libm and from DuckDB,
# 0.8862269254527578 from CPython). The same is true of `math.lgamma`, which
# is why `lgamma` has no op in this engine at all. The `gamma` expectations
# below are DuckDB's, i.e. libm's.
#
# ⛔⛔ AND ONE EXPECTATION IS NOT DuckDB's AT ALL — `atanh` @row 1. This file
# found, on its FIRST farm run, that glibc (where it executes) and Apple libm
# (where every oracle in this repo is measured) return ADJACENT DOUBLES for
# `atanh(-0.25)`. The full measurement, the attribution and the reason the
# fixture value is kept rather than swapped out are written at the value
# itself. It is the only such row; the other four `atanh` inputs and every
# `acosh`/`asinh`/`gamma`/`atan2` input agree in every bit across both.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.string_array import StringArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    SchemaBuilder,
    Field,
    RecordBatch,
    RecordBatchBuilder,
)
from komira_column_kernels.compiler_helpers import field_for_expr
from komira_plan_expr.expr import (
    Expr,
    STRFN_UPPER,
    STRFN_LOWER,
    STRFN_TRIM,
    STRFN_LTRIM,
    STRFN_RTRIM,
    STRFN_LENGTH,
    STRFN_REVERSE,
    STRFN_MD5,
    STRFN_SHA1,
    STRFN_SHA256,
    STRFN_ASCII,
    STRFN_UNICODE,
    STRFN_STRLEN,
    STRFN_BIT_LENGTH,
    MATH_ACOSH,
    MATH_ASINH,
    MATH_ATANH,
    MATH_GAMMA,
    MATH_SQRT,
    MATH2_ATAN2,
    string_fn_returns_int,
)
from komira_plan_expr.expr import (
    STRFNN_LEVENSHTEIN,
    STRFNN_DAMERAU_LEVENSHTEIN,
    STRFNN_HAMMING,
)
from komira_batch_eval.eval_column import _eval_column_expr


comptime S_ROWS: Int = 7
comptime M_ROWS: Int = 5


# ---------------------------------------------------------------------------
# The STRING fixture — the same seven rows as `test_string_fn_n_kernels`, on
# purpose, so a divergence between the two families is visible as a difference
# in the ANSWERS rather than in the inputs.
#
#   0  "  Ab  "  leading AND trailing spaces, mixed case
#   1  "cD "     trailing spaces only
#   2  " ef"     leading spaces only
#   3  ""        THE EMPTY STRING — the ONLY row where `ascii` (0) and
#                `unicode` (-1) differ. Without it those two ops are the same
#                function and an alias would be green.
#   4  "  "      all spaces
#   5  "Straße"  MULTI-BYTE — the ONLY row where `strlen` (7 BYTES) and
#                `length` (6 CHARACTERS) differ. Without it those two ops are
#                the same function too.
#   6  NULL      stored as "" so a kernel reading the VALUE instead of the
#                VALIDITY answers row 3's numbers, which differ from NULL for
#                every op here.
#
# ⚠ ROWS 3 AND 5 ARE THE ENTIRE DISCRIMINATING POWER OF THIS FILE'S STRING
# HALF. Delete either and four ops collapse into two.
# ---------------------------------------------------------------------------


def _s_batch() raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("v"), ArrowType.STRING, True))

    var vals = List[String]()
    vals.append(String("  Ab  "))
    vals.append(String("cD "))
    vals.append(String(" ef"))
    vals.append(String(""))
    vals.append(String("  "))
    vals.append(String("Straße"))
    vals.append(String(""))

    var valid = List[Bool]()
    for i in range(S_ROWS):
        valid.append(i != 6)

    var rb = RecordBatchBuilder()
    rb.add_column(
        Column.from_string(StringArray.from_strings_with_validity(vals, valid))
    )
    return rb.build(sb.build())


def _f64_batch(name: String, vals: List[Float64]) raises -> RecordBatch:
    """`name` = `vals`, with the LAST row NULL.

    The null row carries `0.0`, a value inside every domain used here, so a
    kernel that read the value instead of the validity bit would produce a
    finite number rather than an obvious NaN — i.e. it would look right.
    """
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.FLOAT64, True))
    var arr = PrimitiveArray[DType.float64].allocate_nullable(len(vals) + 1)
    for i in range(len(vals)):
        arr.set(i, Scalar[DType.float64](vals[i]))
    arr.validity.value().clear(len(vals))
    arr.null_count = 1
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.float64](arr))
    return rb.build(sb.build())


def _v() -> Expr:
    return Expr.col_ref(String("v"))


def _x() -> Expr:
    return Expr.col_ref(String("x"))


# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------


def _assert_str_int_op(
    op: UInt8, label: String, expect: List[Int]
) raises:
    """Run `EXPR_STRING_FN(op)(v)` and grade all seven rows as INT64.

    ⚠ THE DECLARED TYPE IS GRADED BEFORE THE VALUES, and that ordering is the
    point rather than tidiness. This family's output type is PER-OP
    (`string_fn_returns_int`), read at four independent sites; a site that
    switched on the TAG would declare Utf8 here while the kernel emitted
    INT64, giving a schema that contradicts its own column. A value-only
    assertion cannot see that at all.
    """
    assert_true(
        string_fn_returns_int(op),
        label + ": this op must be declared INT64-returning",
    )
    var e = Expr.string_fn(op, _v())
    var batch = _s_batch()
    var fld = field_for_expr(e, batch.schema)
    assert_equal(
        fld.arrow_type,
        ArrowType.INT64,
        label + ": DECLARED output type must be INT64",
    )
    var col = _eval_column_expr(e, batch)
    assert_equal(col.arrow_type, ArrowType.INT64, label + ": column type")
    var pa = col.as_primitive[DType.int64]()
    for i in range(S_ROWS):
        if i == 6:
            assert_true(pa.is_null(i), label + ": row 6 must be NULL")
        else:
            assert_equal(
                Int(pa.get(i)), expect[i], label + " @row " + String(i)
            )


def _assert_str_utf8_op(
    op: UInt8, label: String, expect: List[String]
) raises:
    var e = Expr.string_fn(op, _v())
    var batch = _s_batch()
    var col = _eval_column_expr(e, batch)
    assert_equal(col.arrow_type, ArrowType.STRING, label + ": column type")
    var sa = col.as_string()
    for i in range(S_ROWS):
        if i == 6:
            assert_true(sa.is_null(i), label + ": row 6 must be NULL")
        else:
            assert_equal(sa.get(i), expect[i], label + " @row " + String(i))


def _assert_math_op(
    op: UInt8, label: String, xs: List[Float64], expect: List[Float64]
) raises:
    """Run `EXPR_MATH_FN(op)(x)` over `xs` (+ a trailing NULL row).

    ⚠ EXACT EQUALITY, NOT A TOLERANCE, AND THAT IS A REAL PROPERTY HERE. The
    kernel calls libm through `external_call` and DuckDB v1.5.3 calls the same
    libm, so every digit below is reproducible rather than approximate. A
    tolerance would hide exactly the defect this file is for — a kernel wired
    to the neighbouring libm function, which is usually within a tolerance
    somewhere on the fixture.
    """
    var e = Expr.math_fn(op, _x())
    var batch = _f64_batch(String("x"), xs)
    var col = _eval_column_expr(e, batch)
    assert_equal(col.arrow_type, ArrowType.FLOAT64, label + ": column type")
    var pa = col.as_primitive[DType.float64]()
    for i in range(len(xs)):
        assert_equal(
            Float64(pa.get(i)), expect[i], label + " @row " + String(i)
        )
    assert_true(
        pa.is_null(len(xs)),
        label + ": the trailing NULL row must stay NULL — null in, null out",
    )


comptime _ONE_ULP_REL: Float64 = 2.221e-16
"""One unit-in-the-last-place, as a RELATIVE bound, for a Float64.

`2**-52` = 2.220446049250313e-16 is the largest relative gap between adjacent
doubles, so this covers exactly one ulp everywhere and nothing wider. It is
deliberately NOT a round number like `1e-15`: at 1e-15 a kernel wired to a
NEIGHBOURING libm function would still have to be caught by the values
themselves, and the whole point of the bound is that it is too tight for any
wrong function to slip through.
"""


def _assert_math_op_within_one_ulp(
    op: UInt8, label: String, xs: List[Float64], want: List[Float64]
) raises:
    """Like `_assert_math_op`, but allows the result to differ from `want` by
    AT MOST ONE ULP.

    ⛔⛔ USED BY EXACTLY ONE OP, AND ONLY BECAUSE THE DIVERGENCE WAS MEASURED
    RATHER THAN ANTICIPATED. Do not reach for this helper to make a red go
    away — every other op in this file is asserted EXACTLY and must stay that
    way, because a kernel wired to the wrong libm function is wrong by orders
    of magnitude and an ulp bound would still catch it, while a kernel wired
    to the RIGHT function and given the wrong ARGUMENT often is not.

    THE MEASUREMENT, on this file's first two farm runs. `atanh`
    is bit-identical between DuckDB v1.5.3, Apple libm and CPython, and the
    LINUX farm's glibc disagrees with all three on TWO of five inputs:

        x       glibc (the farm)        Apple libm / CPython / DuckDB
        -0.25   -0.25541281188299536    -0.2554128118829953
         0.5     0.5493061443340548      0.5493061443340549

    Both pairs are ADJACENT doubles. `x = -0.75`, `0.0` and `0.875` agree in
    every bit, so it is neither a systematic drift nor a single input.

    ⇒ ASSERTING AN EXACT DOUBLE FOR `atanh` WOULD BE ASSERTING A PLATFORM, NOT
    A KERNEL. Pinning glibc's bits reds this file on every developer mac;
    pinning Apple's reds it on the farm, which is where it is GATED and where
    every deployment runs. Choosing the fixture until both agree would tune
    the test until the answer came out right and would erase a real, measured,
    sub-ulp parity difference. A one-ulp bound is the only form of this
    assertion that is true on both platforms and still false for a wrong
    kernel — and `want` below stays DuckDB's, so the parity target is still
    what is written down.

    ⚠ ZERO IS STILL EXACT. `atanh(0.0)` = 0.0 in every implementation, and a
    relative bound around zero admits any value at all — so a `want` of zero
    is graded with `==` and never with the bound.
    """
    var e = Expr.math_fn(op, _x())
    var batch = _f64_batch(String("x"), xs)
    var col = _eval_column_expr(e, batch)
    assert_equal(col.arrow_type, ArrowType.FLOAT64, label + ": column type")
    var pa = col.as_primitive[DType.float64]()
    for i in range(len(xs)):
        var got = Float64(pa.get(i))
        var w = want[i]
        if w == 0.0:
            assert_equal(
                got, w, label + " @row " + String(i) + " (exact-at-zero)"
            )
            continue
        var d = got - w
        if d < 0.0:
            d = -d
        var mag = w
        if mag < 0.0:
            mag = -mag
        assert_true(
            d <= _ONE_ULP_REL * mag,
            label + " @row " + String(i) + ": " + String(got)
            + " is more than ONE ULP from " + String(w)
            + " — an ulp bound is for a platform libm difference, and this is"
            + " wider than one, so it is a kernel defect",
        )
    assert_true(
        pa.is_null(len(xs)),
        label + ": the trailing NULL row must stay NULL — null in, null out",
    )


# ---------------------------------------------------------------------------
# `_v_batch` — a ONE-COLUMN string batch over ARBITRARY rows.
#
# `_s_batch` above is a fixed seven-row fixture whose longest row is SEVEN
# BYTES. Every one of its rows therefore takes the SAME padding branch of all
# three digests (`n < 56`, one 64-byte block), so it cannot see a defect in
# the multi-block loop, in the length field, or in the second-block padding
# branch. That is what this builder is for.
# ---------------------------------------------------------------------------
def _v_batch(vals: List[String]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("v"), ArrowType.STRING, True))
    var valid = List[Bool]()
    for _ in range(len(vals)):
        valid.append(True)
    var rb = RecordBatchBuilder()
    rb.add_column(
        Column.from_string(StringArray.from_strings_with_validity(vals, valid))
    )
    return rb.build(sb.build())


def _assert_digest_over(
    op: UInt8, label: String, vals: List[String], expect: List[String]
) raises:
    """Run `EXPR_STRING_FN(op)` over `vals` and grade every row."""
    assert_equal(
        len(vals), len(expect), label + ": vector/expectation length mismatch"
    )
    var batch = _v_batch(vals)
    var col = _eval_column_expr(Expr.string_fn(op, _v()), batch)
    assert_equal(col.arrow_type, ArrowType.STRING, label + ": column type")
    var sa = col.as_string()
    for i in range(len(vals)):
        assert_equal(sa.get(i), expect[i], label + " @vector " + String(i))


def test_atanh_computes_on_the_open_unit_interval() raises:
    """`atanh`, MEASURED on DuckDB v1.5.3, EXACT.

    ⚠ ITS OWN FIXTURE BECAUSE ITS DOMAIN IS THE OPEN INTERVAL (-1, 1) — the
    one used above is entirely outside it, where `atanh` is NaN, and a cell
    asserting NaN-equality would state nothing about the kernel.

    ⭐ OUTSIDE [-1, 1] THE TWO ENGINES NOW AGREE, AND THIS PARAGRAPH USED TO
    SAY THE OPPOSITE. Until `atanh(2.0)` RAISED `Invalid Input
    Error: ATANH is undefined outside [-1,1]` in DuckDB and was NaN here,
    because this kernel called libm with no domain check — the same
    libm-vs-raise divergence the engine had for `sqrt(-1)`, `ln(0)`, `acos(2)`
    and `asin(2)`, an engine-wide class rather than anything `atanh`
    introduced. `scalar_math.check_unary_domain` closed all of them, and this file's own kernel
    path — `_eval_column_expr` -> `eval_math_unary` — is the GUARDED one, so
    an out-of-interval fixture here would now RAISE rather than return NaN.
    ⚠ THAT IS WHY THIS FIXTURE STAYS STRICTLY INSIDE THE INTERVAL. The bound
    is `|x| > 1` STRICTLY, so the closed endpoints would still answer; the
    refusal side is graded at the kernel by `komira_core`'s unary-math
    domain-guard test. This file grades VALUES, and it keeps doing only that.
    """
    var xs: List[Float64] = [-0.75, -0.25, 0.0, 0.5, 0.875]
    var want: List[Float64] = [
        -0.9729550745276566,
        # ⚠⚠ ROWS 1 AND 3 ARE WHERE THE FARM AND THE PARITY TARGET DIVERGE
        # BY EXACTLY ONE ULP, AND THE VALUES BELOW ARE THE PARITY TARGET'S.
        # That is why this one op is graded by
        # `_assert_math_op_within_one_ulp` and every other op in this file is
        # graded exactly; the full measurement and the reasoning are on that
        # helper. Keep DuckDB's numbers here — they are what parity MEANS —
        # and let the helper carry the platform tolerance.
        -0.2554128118829953,
        0.0,
        0.5493061443340549,
        1.354025100551105,
    ]
    _assert_math_op_within_one_ulp(MATH_ATANH, String("atanh"), xs, want)


def test_a_neighbouring_math_op_is_not_the_same_column() raises:
    """★ THE ANTI-OFF-BY-ONE CONTROL, and the reason it is a separate test.

    `MATH_*` is a dense block of consecutive `UInt8`s that reaches libm through
    a wire enum and an `if/elif` ladder. An off-by-one anywhere in that chain
    silently swaps two NEIGHBOURS, and the four ops this wave added are
    numbered 20..23 — adjacent to each other and to `MATH_TANH` at 19. Three
    tests that each check one op in isolation cannot see a consistent shift;
    this one asserts the columns are pairwise DIFFERENT on the same input.

    `sqrt` is the fourth participant because it is FAR from the new block, so
    a red here that includes `sqrt` says "the ladder", where a red among only
    20..23 says "the newest block".
    """
    var xs: List[Float64] = [1.5, 2.0, 5.0]
    var batch = _f64_batch(String("x"), xs)
    var ops: List[UInt8] = [MATH_ACOSH, MATH_ASINH, MATH_GAMMA, MATH_SQRT]
    var cols = List[List[Float64]]()
    for oi in range(len(ops)):
        var c = _eval_column_expr(Expr.math_fn(ops[oi], _x()), batch)
        var pa = c.as_primitive[DType.float64]()
        var vals = List[Float64]()
        for i in range(len(xs)):
            vals.append(Float64(pa.get(i)))
        cols.append(vals^)
    for a in range(len(ops)):
        for b in range(a + 1, len(ops)):
            var same = True
            for i in range(len(xs)):
                if cols[a][i] != cols[b][i]:
                    same = False
                    break
            assert_true(
                not same,
                "MATH ops " + String(Int(ops[a])) + " and "
                + String(Int(ops[b]))
                + " produced the SAME column — the op is being dropped or the"
                + " ladder is shifted by one",
            )


def test_atan2_the_binary_family_executes_and_is_ORDER_SENSITIVE() raises:
    """`atan2(y, x)` — the op that was WIRED EVERYWHERE AND REACHABLE FROM
    NOTHING until this wave, and whose argument ORDER is the thing to pin.

    MEASURED on DuckDB v1.5.3: `atan2(1,2)` = 0.4636476090008061 and
    `atan2(2,1)` = 1.1071487177940904. Both are plausible radian values in the
    first quadrant, so a swapped pair is NOT visibly wrong — it is only
    visibly DIFFERENT, which is why the test computes both.
    """
    var sb = SchemaBuilder()
    sb.add_field(Field(String("y"), ArrowType.FLOAT64, True))
    sb.add_field(Field(String("x"), ArrowType.FLOAT64, True))
    var ya = PrimitiveArray[DType.float64].allocate(2)
    ya.set(0, Scalar[DType.float64](1.0))
    ya.set(1, Scalar[DType.float64](2.0))
    var xa = PrimitiveArray[DType.float64].allocate(2)
    xa.set(0, Scalar[DType.float64](2.0))
    xa.set(1, Scalar[DType.float64](1.0))
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.float64](ya))
    rb.add_column(Column.from_primitive[DType.float64](xa))
    var batch = rb.build(sb.build())

    var e = Expr.math_fn2(
        MATH2_ATAN2, Expr.col_ref(String("y")), Expr.col_ref(String("x"))
    )
    var col = _eval_column_expr(e, batch)
    assert_equal(col.arrow_type, ArrowType.FLOAT64, "atan2 column type")
    var pa = col.as_primitive[DType.float64]()
    assert_equal(
        Float64(pa.get(0)), 0.4636476090008061, "atan2(1.0, 2.0)"
    )
    assert_equal(
        Float64(pa.get(1)), 1.1071487177940904, "atan2(2.0, 1.0)"
    )


# ===========================================================================
# 4. THE EDIT-DISTANCE FAMILY — three
#    `EXPR_STRING_FN_N` ops whose every documented property is confusable.
# ===========================================================================


def _pair_batch(
    a: List[String], b: List[String]
) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("a"), ArrowType.STRING, True))
    sb.add_field(Field(String("b"), ArrowType.STRING, True))
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_string(StringArray.from_strings(a)))
    rb.add_column(Column.from_string(StringArray.from_strings(b)))
    return rb.build(sb.build())


def _dist(op: UInt8, a: List[String], b: List[String]) raises -> List[Int]:
    var args = List[Expr]()
    args.append(Expr.col_ref(String("a")))
    args.append(Expr.col_ref(String("b")))
    var batch = _pair_batch(a, b)
    var col = _eval_column_expr(Expr.string_fn_n(op, args^), batch)
    var pa = col.as_primitive[DType.int64]()
    var out = List[Int]()
    for i in range(len(a)):
        out.append(Int(pa.get(i)))
    return out^


def test_levenshtein_is_BYTE_based_and_has_no_transposition() raises:
    """`levenshtein(a, b)` — MEASURED on DuckDB v1.5.3, every pair.

    ⛔ TWO INDEPENDENT CLAIMS, AND EACH HAS ITS OWN ROW.

    (1) BYTES, NOT CHARACTERS. `('é','')` = 2 and `('😀','x')` = 4 — one
        CHARACTER against nothing, answering the BYTE count. A character-based
        kernel — which is what every textbook and most libraries write —
        answers 1 and 1, and is right on every other row here.

    (2) NO TRANSPOSITION. `('ab','ba')` = 2, where a swap counted as one edit
        gives 1. That row is the entire difference from
        `damerau_levenshtein`, which is asserted beside it below.
    """
    var a: List[String] = [
        String("kitten"), String("ca"), String("ab"), String("é"),
        String("😀"), String(""), String("abc"), String(""),
        String("Straße"),
    ]
    var b: List[String] = [
        String("sitting"), String("abc"), String("ba"), String(""),
        String("x"), String("abc"), String(""), String(""),
        String("Strasse"),
    ]
    var want: List[Int] = [3, 3, 2, 2, 4, 3, 3, 0, 2]
    var got = _dist(STRFNN_LEVENSHTEIN, a, b)
    for i in range(len(want)):
        assert_equal(got[i], want[i], "levenshtein @row " + String(i))


def test_damerau_is_the_UNRESTRICTED_variant_not_OSA() raises:
    """`damerau_levenshtein(a, b)` — and ROW 1 IS THE WHOLE TEST.

    ⛔⛔ `('ca','abc')` = **2** ON DuckDB v1.5.3, AND THE OPTIMAL STRING
    ALIGNMENT DISTANCE ANSWERS **3**. OSA is the variant that fits in the same
    two-row DP as `levenshtein` — add one transposition arm and stop — and it
    is what nearly every library ships under the Damerau name, because the
    unrestricted algorithm needs an alphabet last-occurrence table and a full
    matrix with sentinel rows.

    The two variants AGREE on every other row here: `('ab','ba')` = 1,
    `('kitten','sitting')` = 3, and both byte-length rows. So an OSA kernel
    passes eight of nine assertions in this test, and deleting row 1 would
    make this test unable to tell the two algorithms apart at all.
    """
    var a: List[String] = [
        String("kitten"), String("ca"), String("ab"), String("é"),
        String("😀"), String(""), String("abc"), String(""),
        String("Straße"),
    ]
    var b: List[String] = [
        String("sitting"), String("abc"), String("ba"), String(""),
        String("x"), String("abc"), String(""), String(""),
        String("Strasse"),
    ]
    var want: List[Int] = [3, 2, 1, 2, 4, 3, 3, 0, 2]
    var got = _dist(STRFNN_DAMERAU_LEVENSHTEIN, a, b)
    for i in range(len(want)):
        assert_equal(got[i], want[i], "damerau_levenshtein @row " + String(i))
    # ★ AND THE PAIRWISE CONTROL. The two ops must not be one kernel: they
    # differ on rows 1 and 2 and agree everywhere else, so an aliasing bug is
    # only visible as a DIFFERENCE, never as an implausible value.
    var lev = _dist(STRFNN_LEVENSHTEIN, a, b)
    assert_true(
        lev[1] != got[1] and lev[2] != got[2],
        "levenshtein and damerau_levenshtein produced the SAME answer on the"
        " two rows where a transposition is available — they are being"
        " dispatched to one kernel",
    )


def test_hamming_counts_bytes_and_REFUSES_two_inputs() raises:
    """`hamming(a, b)` — the count, and then the TWO refusals.

    ⛔ BOTH REFUSALS ARE MEASURED ON DuckDB v1.5.3 AND BOTH ARE EASY TO GET
    WRONG IN THE PERMISSIVE DIRECTION:

      * UNEQUAL LENGTHS raise. And the comparison is on BYTES, so
        `hamming('é','e')` raises there for two operands that are ONE
        CHARACTER EACH — the row that makes "bytes" an assertion rather than
        an implementation note.
      * TWO EMPTY STRINGS raise. This is the counter-intuitive one:
        `levenshtein('','')` is 0, and "the number of differing positions" in
        two empty sequences is naturally 0. A kernel answering 0 looks right
        and accepts a call the parity target rejects.
    """
    var a: List[String] = [
        String("abc"), String("abc"), String("Straße"), String("a"),
    ]
    var b: List[String] = [
        String("abd"), String("abc"), String("Strasse"), String("b"),
    ]
    # ⚠ ROW 2 IS THE ROW A CHARACTER-BASED KERNEL GETS WRONG **TWICE**, and
    # both ways it is wrong are silent. `Straße` is 6 CHARACTERS over 7 BYTES
    # and `Strasse` is 7 of each, so:
    #   * an equal-length CHECK written over characters (6 != 7) RAISES here,
    #     where DuckDB answers;
    #   * a COUNT written over characters compares `ß` with `s` and then `e`
    #     with `s`, giving 2 for different reasons than the byte answer.
    # MEASURED on v1.5.3: hamming('Straße','Strasse') = **2** — the `C3 9F`
    # of `ß` against the `73 73` of `ss`, with the trailing `e` matching.
    var want: List[Int] = [1, 0, 2, 1]
    var got = _dist(STRFNN_HAMMING, a, b)
    for i in range(len(want)):
        assert_equal(got[i], want[i], "hamming @row " + String(i))

    _assert_hamming_raises(String("abc"), String("abcd"), String("unequal"))
    _assert_hamming_raises(String("é"), String("e"), String("byte-unequal"))
    _assert_hamming_raises(String(""), String(""), String("both empty"))


def _assert_hamming_raises(a: String, b: String, why: String) raises:
    var av = List[String]()
    av.append(a)
    var bv = List[String]()
    bv.append(b)
    var raised = False
    try:
        var _r = _dist(STRFNN_HAMMING, av, bv)
    except e:
        raised = True
    assert_true(
        raised,
        "hamming(" + a + ", " + b + ") must RAISE (" + why + ") — DuckDB"
        " v1.5.3 refuses it and answering a number accepts a call the parity"
        " target rejects",
    )


# ===========================================================================
# 8. THE INT64-RETURNING FAMILY'S **OUTPUT SHAPE** AND ITS SIMD BLOCK
#
# ⛔ SECTIONS 1-7 ABOVE CANNOT FALSIFY EITHER OF THE TWO THINGS TESTED HERE,
# AND THAT IS MEASURED RATHER THAN ASSUMED:
#
#   * every fixture above is `_s_batch`, which carries a NULL at row 6, so
#     the family's non-nullable arm is never taken. A kernel that attached a
#     validity buffer to every output — which is what it used to do — is
#     invisible to a value assertion, because an ALL-VALID bitmap and NO
#     bitmap describe the identical seven cells;
#   * `_s_batch`'s longest value is `'Straße'` at SEVEN BYTES, and the SIMD
#     block in `_utf8_char_count` only runs from `simd_width_of[uint8]`
#     bytes up (16 on arm64). So `simd_end == 0` on every row of every test
#     above and the vector arm is NEVER EXECUTED by them.
# ===========================================================================


def _rep(b: List[UInt8], k: Int) -> List[UInt8]:
    """`k` verbatim repetitions of the byte sequence `b`."""
    var out = List[UInt8]()
    for _ in range(k):
        for j in range(len(b)):
            out.append(b[j])
    return out^


def _nonnull_v_batch(rows: List[List[UInt8]]) raises -> RecordBatch:
    """A one-column `v` STRING batch built from RAW BYTES and carrying **NO
    validity buffer at all** — the shape parquet's dense BYTE_ARRAY decode
    produces for a zero-null column (`column_decoder.mojo:2107`).

    ⚠ BYTES, NOT `String` LITERALS. The point of the fixture is where the
    UTF-8 CONTINUATION bytes land relative to a 16-byte SIMD lane, so the
    bytes are written out rather than round-tripped through a source-file
    encoding.
    """
    var sb = SchemaBuilder()
    sb.add_field(Field(String("v"), ArrowType.STRING, True))
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_string(StringArray.from_byte_lists(rows)))
    return rb.build(sb.build())


def test_the_INT64_family_emits_NO_validity_buffer_on_a_nonnullable_input() raises:
    """⭐ THE OUTPUT SHAPE IS THE ASSERTION, NOT THE VALUES.

    `length`/`strlen`/`bit_length`/`ascii`/`unicode` over an input with no
    validity buffer must produce a column with no validity buffer. This is
    the contract the `EXPR_SUBSTRING` arm in the same file already keeps
    (`if null_count > 0: out_sa.validity = ...`), and the INT64 arm did not:
    it called `allocate_nullable` unconditionally, so every output carried an
    ALL-VALID bitmap that cost a `create_all_valid` fill, a per-row
    read-modify-write in `PrimitiveArray.set` -> `_set_valid`, and a second
    copy of the bitmap in `Column.from_primitive`.

    ⛔ NO VALUE ASSERTION ANYWHERE IN THIS FILE CAN SEE THAT — an all-valid
    bitmap and an absent bitmap agree on every cell. This is the falsifier.
    """
    var r_abc: List[UInt8] = [0x61, 0x62, 0x63]  # "abc"
    var r_empty = List[UInt8]()  # ""
    var r_x: List[UInt8] = [0x78]  # "x"
    var rows = List[List[UInt8]]()
    rows.append(r_abc^)
    rows.append(r_empty^)
    rows.append(r_x^)
    var batch = _nonnull_v_batch(rows)

    var ops: List[UInt8] = [
        STRFN_LENGTH,
        STRFN_STRLEN,
        STRFN_BIT_LENGTH,
        STRFN_ASCII,
        STRFN_UNICODE,
    ]
    var labels: List[String] = [
        String("length"),
        String("strlen"),
        String("bit_length"),
        String("ascii"),
        String("unicode"),
    ]
    for oi in range(len(ops)):
        var col = _eval_column_expr(Expr.string_fn(ops[oi], _v()), batch)
        assert_equal(
            col.arrow_type, ArrowType.INT64, labels[oi] + ": column type"
        )
        assert_true(
            not col.has_validity_buffer(),
            labels[oi]
            + ": a non-nullable input must produce a column with NO"
            + " validity buffer (got one)",
        )
        assert_equal(col.null_count(), 0, labels[oi] + ": null_count")


def test_the_INT64_family_STILL_carries_a_bitmap_when_a_null_arrives() raises:
    """The other side of the same gate, so the fast path cannot be applied
    unconditionally without this going red.

    `_s_batch` row 6 is NULL. The output MUST carry a validity buffer and
    report `null_count == 1`; the value arm of `_assert_str_int_op` already
    grades the cell, but it would stay green if the column reported the null
    through a bitmap it no longer allocated (it would crash) — or, in the
    likelier mutation, if the fast path were taken for a nullable input and
    row 6 came back as `0` with no bitmap at all.
    """
    var batch = _s_batch()
    var ops: List[UInt8] = [STRFN_LENGTH, STRFN_STRLEN, STRFN_BIT_LENGTH]
    var labels: List[String] = [
        String("length"),
        String("strlen"),
        String("bit_length"),
    ]
    for oi in range(len(ops)):
        var col = _eval_column_expr(Expr.string_fn(ops[oi], _v()), batch)
        assert_true(
            col.has_validity_buffer(),
            labels[oi] + ": a NULL-bearing input must keep a validity buffer",
        )
        assert_equal(col.null_count(), 1, labels[oi] + ": null_count")
        var pa = col.as_primitive[DType.int64]()
        assert_true(pa.is_null(6), labels[oi] + ": row 6 must be NULL")


def test_length_counts_codepoints_ACROSS_the_simd_lane_boundary() raises:
    """⭐ THE FIXTURE IS LONG ENOUGH TO RUN THE VECTOR ARM, WHICH IS THE ONLY
    REASON IT EXISTS.

    `_utf8_char_count` counts bytes that are NOT continuation bytes
    (`(c & 0xC0) != 0x80`) `simd_width_of[uint8]` at a time with a scalar
    tail. Three families of defect are invisible to a short fixture and all
    three are graded here:

      * a vector arm that never runs (every row under 16 bytes);
      * a tail that is skipped or double-counted (`n % W != 0`);
      * continuation bytes that straddle a lane boundary — the ASCII-prefix
        family below shifts them through every offset mod 16.

    ⚠ `strlen` is asserted alongside on the SAME rows. It reads the OFFSETS
    and never the data buffer, so it is an independent oracle for the byte
    length: if `length` and `strlen` were ever wired to the same kernel, the
    multi-byte rows below separate them (2-byte and 4-byte codepoints).
    """
    var E2: List[UInt8] = [0xC3, 0xA9]  # 'é'  — 2 bytes, 1 codepoint
    var E4: List[UInt8] = [0xF0, 0x9F, 0x98, 0x80]  # '😀' — 4 bytes, 1 cp
    var A: List[UInt8] = [0x61]  # 'a'

    var rows = List[List[UInt8]]()
    var want_chars = List[Int]()
    var want_bytes = List[Int]()

    # 0..20 two-byte codepoints => 0..40 bytes, crossing 16 and 32.
    for k in range(21):
        rows.append(_rep(E2, k))
        want_chars.append(k)
        want_bytes.append(2 * k)

    # j ASCII bytes then 9 two-byte codepoints (18 bytes): j = 1..16 walks
    # the first continuation byte through every offset mod 16.
    for j in range(1, 17):
        var r = _rep(A, j)
        var tail = _rep(E2, 9)
        for t in range(len(tail)):
            r.append(tail[t])
        rows.append(r^)
        want_chars.append(j + 9)
        want_bytes.append(j + 18)

    # 1..11 four-byte codepoints => 4..44 bytes, THREE continuation bytes per
    # character, so a kernel that counted lead bytes by `>= 0x80` instead of
    # by `(c & 0xC0) != 0x80` is off by 3x here and correct on the E2 family.
    for k in range(1, 12):
        rows.append(_rep(E4, k))
        want_chars.append(k)
        want_bytes.append(4 * k)

    var batch = _nonnull_v_batch(rows)
    var n = len(want_chars)

    var lc = _eval_column_expr(Expr.string_fn(STRFN_LENGTH, _v()), batch)
    var lpa = lc.as_primitive[DType.int64]()
    for i in range(n):
        assert_equal(
            Int(lpa.get(i)),
            want_chars[i],
            String("length @row ") + String(i),
        )

    var sc = _eval_column_expr(Expr.string_fn(STRFN_STRLEN, _v()), batch)
    var spa = sc.as_primitive[DType.int64]()
    for i in range(n):
        assert_equal(
            Int(spa.get(i)),
            want_bytes[i],
            String("strlen @row ") + String(i),
        )


def main() raises:
    # ⛔ AUTO-DISCOVERY, NOT A HAND-WRITTEN ROSTER. The previous form
    # enumerated each test with `suite.test[...]`, and two
    # NEWLY ADDED value tests were left off that roster: they compiled,
    # they type-checked, the gate went GREEN, and their assertions never
    # ran. `assert_true(False)` as their first statement was measured
    # GREEN through this gate. A roster that must be edited in a second
    # place is a roster that will be forgotten; `__functions_in_module`
    # cannot be.
    TestSuite.discover_tests[__functions_in_module()]().run()
