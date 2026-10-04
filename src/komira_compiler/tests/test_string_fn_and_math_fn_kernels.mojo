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

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.string_array import StringArray
from komira_core.arrow import PrimitiveArray
from komira_core.arrow.schema import (
    SchemaBuilder,
    Field,
    RecordBatch,
    RecordBatchBuilder,
)
from komira_core.helpers.compiler_helpers import field_for_expr
from komira_core.plan.expr import (
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
from komira_core.plan.expr import (
    STRFNN_LEVENSHTEIN,
    STRFNN_DAMERAU_LEVENSHTEIN,
    STRFNN_HAMMING,
)
from komira_compiler.compiler_eval_column import _eval_column_expr


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


# ===========================================================================
# 1. THE STRING -> INT BUCKET. Five ops, and four of them are pairwise
#    confusable on any ASCII fixture.
# ===========================================================================


def test_ascii_and_unicode_differ_ONLY_on_the_empty_string() raises:
    """`ascii(v)` and `unicode(v)`, MEASURED on DuckDB v1.5.3.

    ⛔ THE ONLY ROW THAT SEPARATES THEM IS ROW 3. Every other row is the same
    number in both columns, so binding `unicode` as an alias of `ascii` — the
    obvious reading, since `ord`/`unicode`/`ascii` all sound like one function
    — is green on any fixture without an empty string.

    ⛔ AND BOTH ARE CODEPOINTS, NOT BYTES, WHICH ROW 5 DOES NOT PROVE.
    `'Straße'` begins with `S`, so its answer (83) is the same either way. The
    codepoint claim is pinned by
    `test_ascii_decodes_a_multibyte_lead_character` below, over a fixture
    written for it; this test would pass against a `b[0]` kernel.
    """
    var want_ascii: List[Int] = [32, 99, 32, 0, 32, 83, 0]
    var want_unicode: List[Int] = [32, 99, 32, -1, 32, 83, 0]
    _assert_str_int_op(STRFN_ASCII, String("ascii"), want_ascii)
    _assert_str_int_op(STRFN_UNICODE, String("unicode"), want_unicode)


def test_ascii_decodes_a_multibyte_lead_character() raises:
    """`ascii('é')` = 233 and `ascii('😀')` = 128512 — MEASURED on v1.5.3.

    ★ THIS IS THE CELL THE MAIN FIXTURE CANNOT ASK. A kernel returning the
    first BYTE answers 195 and 240 respectively: plausible small integers, and
    CORRECT FOR ALL OF ASCII, which is five of the six zoo rows.

    The 4-byte case is here beside the 2-byte one because a decoder that
    handles `0xC0..0xDF` and forgets `0xF0..0xF7` is green on `é` alone.
    """
    var sb = SchemaBuilder()
    sb.add_field(Field(String("v"), ArrowType.STRING, True))
    var vals = List[String]()
    vals.append(String("é"))
    vals.append(String("😀"))
    vals.append(String("€"))
    vals.append(String("A"))
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_string(StringArray.from_strings(vals)))
    var batch = rb.build(sb.build())

    var col = _eval_column_expr(Expr.string_fn(STRFN_ASCII, _v()), batch)
    var pa = col.as_primitive[DType.int64]()
    # 2-byte, 4-byte, 3-byte, 1-byte — one of each UTF-8 width.
    assert_equal(Int(pa.get(0)), 233, "ascii('é') is the CODEPOINT, not 195")
    assert_equal(Int(pa.get(1)), 128512, "ascii('😀') — a 4-byte codepoint")
    assert_equal(Int(pa.get(2)), 8364, "ascii('€') — a 3-byte codepoint")
    assert_equal(Int(pa.get(3)), 65, "ascii('A') — the 1-byte path")

    var bcol = _eval_column_expr(Expr.string_fn(STRFN_STRLEN, _v()), batch)
    var bpa = bcol.as_primitive[DType.int64]()
    assert_equal(Int(bpa.get(0)), 2, "strlen('é') is 2 BYTES")
    assert_equal(Int(bpa.get(1)), 4, "strlen('😀') is 4 BYTES")
    assert_equal(Int(bpa.get(2)), 3, "strlen('€') is 3 BYTES")

    var ncol = _eval_column_expr(Expr.string_fn(STRFN_LENGTH, _v()), batch)
    var npa = ncol.as_primitive[DType.int64]()
    assert_equal(Int(npa.get(0)), 1, "length('é') is 1 CHARACTER")
    assert_equal(Int(npa.get(1)), 1, "length('😀') is 1 CHARACTER")


def test_the_three_length_shaped_names_are_three_functions() raises:
    """`strlen` (BYTES), `bit_length` (bytes*8) and `length` (CHARACTERS).

    ⛔ ROW 5 IS THE WHOLE TEST. `'Straße'` is 6 characters over 7 bytes, so
    `strlen` = 7 and `length` = 6; on the other five rows the two are equal.
    `strlen` was a NAMED REFUSAL in the SQL frontend until this wave precisely
    so that nobody would bind it to the character count, and this is the
    assertion that keeps that from happening quietly.

    `bit_length` is graded in the same call because `8 *` is the kind of
    factor that gets dropped: without it, `bit_length` and `strlen` are the
    same column and both agree with a plausible reading of the name.
    """
    var want_strlen: List[Int] = [6, 3, 3, 0, 2, 7, 0]
    var want_length: List[Int] = [6, 3, 3, 0, 2, 6, 0]
    var want_bits: List[Int] = [48, 24, 24, 0, 16, 56, 0]
    _assert_str_int_op(STRFN_STRLEN, String("strlen"), want_strlen)
    _assert_str_int_op(STRFN_LENGTH, String("length"), want_length)
    _assert_str_int_op(STRFN_BIT_LENGTH, String("bit_length"), want_bits)


# ===========================================================================
# 2. THE Utf8-RETURNING MEMBERS — the family's majority, and until this file
#    they had no executing test either.
# ===========================================================================


def test_the_utf8_returning_members_execute_at_all() raises:
    """`upper` / `lower` / `trim` / `ltrim` / `rtrim` / `reverse`.

    ⚠ THIS IS THE FIRST MOJO TEST THAT RUNS ANY OF THEM. EVERY expectation is
    DuckDB v1.5.3's. It was not always: rows 5 of `upper`/`lower` used to hold
    THIS ENGINE's answer, because the kernels were ASCII-only.

    ⛔ `trim` STRIPS THE SPACE CHARACTER ONLY, NOT WHITESPACE. Measured:
    `trim(e'\\t hi \\t')` in DuckDB comes back WITH BOTH TABS. The fixture has
    no tab, so this call does not test that — it is stated here rather than
    asserted falsely.

    ⭐ ROW 5 IS WHERE THE ASCII DIVERGENCE USED TO BE, AND IT CLOSED THE WAY
    THIS TEST ASKED IT TO. The expectation was `STRAßE` — the engine's own
    answer — under a note saying "a kernel that started folding `ß` would turn
    this test RED and be told to come and say so". It went red
    and the answer is now DuckDB's `STRAẞE`.

    ⛔ `STRAẞE`, NOT `STRASSE`, AND THE DIFFERENCE IS THE WHOLE DESIGN. DuckDB
    v1.5.3 does SIMPLE (1:1) case mapping, measured over all 1,112,064
    codepoints: `upper('ß')` is the
    single codepoint U+1E9E, never the two-character `SS` of FULL case folding.
    An implementation "upgraded" to full folding fails right here.

    ⚠ `lower` ROW 5 IS UNCHANGED AND THAT IS NOT AN OVERSIGHT: `ß` has no
    lowercase mapping, so `lower('Straße')` was already right for the wrong
    reason. It is kept as the control that the fix did not just uppercase
    everything it touched.
    """
    var want_upper: List[String] = [
            String("  AB  "),
            String("CD "),
            String(" EF"),
            String(""),
            String("  "),
            String("STRAẞE"),
            String(""),
    ]
    _assert_str_utf8_op(STRFN_UPPER, String("upper"), want_upper)
    var want_lower: List[String] = [
            String("  ab  "),
            String("cd "),
            String(" ef"),
            String(""),
            String("  "),
            String("straße"),
            String(""),
    ]
    _assert_str_utf8_op(STRFN_LOWER, String("lower"), want_lower)
    var want_trim: List[String] = [
            String("Ab"),
            String("cD"),
            String("ef"),
            String(""),
            String(""),
            String("Straße"),
            String(""),
    ]
    _assert_str_utf8_op(STRFN_TRIM, String("trim"), want_trim)
    var want_ltrim: List[String] = [
            String("Ab  "),
            String("cD "),
            String("ef"),
            String(""),
            String(""),
            String("Straße"),
            String(""),
    ]
    _assert_str_utf8_op(STRFN_LTRIM, String("ltrim"), want_ltrim)
    var want_rtrim: List[String] = [
            String("  Ab"),
            String("cD"),
            String(" ef"),
            String(""),
            String(""),
            String("Straße"),
            String(""),
    ]
    _assert_str_utf8_op(STRFN_RTRIM, String("rtrim"), want_rtrim)
    # ⛔ CODEPOINTS, NOT BYTES. A byte reverse of row 5 emits `ß`'s
    # continuation byte first and produces INVALID UTF-8 out of valid input —
    # worse than a wrong answer, because the consumer cannot decode it.
    var want_reverse: List[String] = [
            String("  bA  "),
            String(" Dc"),
            String("fe "),
            String(""),
            String("  "),
            String("eßartS"),
            String(""),
    ]
    _assert_str_utf8_op(STRFN_REVERSE, String("reverse"), want_reverse)


def test_the_three_digests_execute_and_are_three_different_functions() raises:
    """`md5` / `sha1` / `sha256` — SQL-DIGEST.

    ⭐ THE EXPECTATIONS ARE `hashlib`'s AND THE STANDARDS', NOT DuckDB's, and
    that is what makes this test independent of the parity target's build. All
    three algorithms have fixed published vectors (RFC 1321 §A.5, RFC 3174,
    FIPS 180-2 §B.1). DuckDB v1.5.3 was measured over a COLUMN and agrees on
    all six rows; if it ever stopped agreeing, the standard would still be
    right and this file would still be the place that says so.

    ⛔ ROW 5 (`"Straße"`) IS THE BYTES-vs-CODEPOINTS WITNESS. `ß` is TWO UTF-8
    bytes (C3 9F) and DuckDB digests the BYTES, so a kernel that fed codepoints
    to the compression function is GREEN ON THE FIVE ASCII ROWS and red only
    here. This repo has shipped that exact confusion four times.

    ⛔ ROW 3 (`""`) IS THE EMPTY-INPUT CONSTANT and row 6 is NULL. A kernel
    that treated `""` as NULL reds row 3 on all three ops at once, which is
    how you tell it from a per-op defect.

    ⛔ THE THREE WIDTHS ARE 32 / 40 / 64 CHARACTERS. An eval arm that fell
    through to a neighbouring digest cannot produce a plausible answer,
    because the LENGTH is wrong before the value is — asserted explicitly
    below rather than left to the value comparison.

    ⚠ ALL THREE ARE LOWERCASE, where `hex`/`to_hex` on this same tag are
    UPPERCASE. Sharing a hex renderer between the two families would red every
    row of all three ops here at once.
    """
    var want_md5: List[String] = [
            String("f4553bc7af643cbe022b92db9a13e372"),
            String("38185dd07400ed20b31799902f9f8637"),
            String("286f0a5ac93b2d81541b6299058023b0"),
            String("d41d8cd98f00b204e9800998ecf8427e"),
            String("23b58def11b45727d3351702515f86af"),
            String("a763ca073cfda1fce8a14f2f0cc84591"),
            String(""),
    ]
    _assert_str_utf8_op(STRFN_MD5, String("md5"), want_md5)
    var want_sha1: List[String] = [
            String("85cef4c498e2a6346cc4ece5b46c1c229f27b9e1"),
            String("4e6f0ba430ffe6a171139e6612b0c72ca796743e"),
            String("03b71a9710fc964ccd22eafd28198fb0110280ee"),
            String("da39a3ee5e6b4b0d3255bfef95601890afd80709"),
            String("099600a10a944114aac406d136b625fb416dd779"),
            String("880c6886fd25455f5534ec8b46e24a832dfb43b3"),
            String(""),
    ]
    _assert_str_utf8_op(STRFN_SHA1, String("sha1"), want_sha1)
    var want_sha256: List[String] = [
            String(
                "6be21e154970c2d2e16f2ee48dccd080f552fe09b06d89ac29e7ffa332fdcc26"
            ),
            String(
                "6b3d2eb4afd08b9d11eef2abfc38a31fdf5992190aafdf5ea3cd31ddfc1d9017"
            ),
            String(
                "401f7ea6ccaf738f10f024520d625e1f7f6d94585141c319758791d55470a5f2"
            ),
            String(
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
            ),
            String(
                "6c179f21e6f62b629055d8ab40f454ed02e48b68563913473b857d3638e23b28"
            ),
            String(
                "58a3778c18c41726cd53c2a4c77dcbed8512f962d7e616717abee95ca41d0029"
            ),
            String(""),
    ]
    _assert_str_utf8_op(STRFN_SHA256, String("sha256"), want_sha256)

    # ⛔ THE WIDTHS, ASSERTED DIRECTLY. This is the cheapest witness that the
    # eval ladder dispatched to the op it was handed, and unlike the value
    # comparison above it survives any future change to the fixture.
    var batch = _s_batch()
    var m_col = _eval_column_expr(Expr.string_fn(STRFN_MD5, _v()), batch)
    var s1_col = _eval_column_expr(Expr.string_fn(STRFN_SHA1, _v()), batch)
    var s2_col = _eval_column_expr(Expr.string_fn(STRFN_SHA256, _v()), batch)
    assert_equal(
        m_col.as_string().get(0).byte_length(), 32,
        "md5 is 128 bits = 32 hex chars"
    )
    assert_equal(
        s1_col.as_string().get(0).byte_length(), 40,
        "sha1 is 160 bits = 40 hex chars"
    )
    assert_equal(
        s2_col.as_string().get(0).byte_length(), 64,
        "sha256 is 256 bits = 64 hex chars",
    )
    # ⛔ AND NO TWO OF THEM ARE THE SAME COLUMN. Three rows pointed at one op
    # would be internally consistent and wrong.
    assert_true(
        m_col.as_string().get(0) != s1_col.as_string().get(0)
        and s1_col.as_string().get(0) != s2_col.as_string().get(0),
        "md5, sha1 and sha256 must be THREE different functions",
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


def test_the_digests_match_the_PUBLISHED_STANDARD_VECTORS() raises:
    """`md5` / `sha1` / `sha256` against RFC 1321 §A.5, RFC 3174 and FIPS 180-2.

    ⛔ WHY THIS EXISTS SEPARATELY FROM THE FIXTURE TEST ABOVE. The seven-row
    fixture's longest row is SEVEN BYTES. All three digests pad a message of
    `n < 56` bytes into ONE 64-byte block, so every fixture row takes the same
    branch of the same loop — the fixture cannot distinguish a correct kernel
    from one whose multi-block loop, whose 56-byte padding branch, or whose
    64-bit length field is wrong. Those are not exotic defects; they are the
    three that a hand-written compression function gets wrong.

    THE VECTORS BELOW ARE THE PUBLISHED ONES THROUGH len 640; the last two
    (len 1000, len 8192) are CONSTRUCTED boundary vectors whose expectations
    were taken from Python `hashlib`, and they are marked as such rather than
    passed off as standard. Their lengths are chosen so the set crosses every
    boundary:

        len 0      the empty-input constant, all three algorithms
        len 1..26  the single-block interior
        len 56     ⛔ THE PADDING BOUNDARY. 56 bytes + the 8-byte length field
                   is exactly 64, so the 0x80 terminator has NO room and a
                   SECOND block is required. An off-by-one here is green on
                   every shorter message.
        len 62,80  the two-block case with a partial second block
        len 640    ten identical 64-byte blocks — the multi-block loop
        len 1000   a long multi-block message with a PARTIAL final block
                   (1000 = 15*64 + 40), so the tail path runs after the loop
        len 8192   ⛔ THE 16-BIT LENGTH-FIELD BOUNDARY, and the FIRST vector
                   here that crosses it. 8192 bytes is 65536 bits == 2**16, so
                   a length field truncated to 16 bits writes ZERO and all
                   three digests change. ⚠ EVERY SHORTER VECTOR ABOVE IS GREEN
                   UNDER THAT DEFECT, len 1000 INCLUDED: its bit-count is
                   8000, which needs 13 bits and fits a UInt16 (max 65535)
                   with room to spare. This line previously claimed len 1000
                   caught it; that was arithmetically false and was PROVEN so
                   by mutation — truncating `bitlen` to `& 0xFFFF` in all
                   three kernels left the whole file GREEN.

    ★ THE ORACLE IS THE STANDARD, NOT DuckDB AND NOT THIS REPO. RFC 1321 §A.5
    is MD5's own test suite verbatim; `abcdbcde...nopq` is RFC 3174's TEST2
    and FIPS 180-2 §B.2 at once, which is why one string grades two algorithms.
    Cross-checked against Python `hashlib` at authoring time; hashlib is not
    the authority, the RFCs are, and both agree.

    ⚠ THREE OF THE SHA-256 VECTORS BELOW ARE THE ONES `komira_crypto` ALSO
    ASSERTS, AND THAT IS HOW THE REPO'S TWO SHA-256 IMPLEMENTATIONS ARE MADE
    TO AGREE. `komira_crypto/tests/test_sha256_kat.mojo` — welded to
    `komira_crypto` and executing (its `main` calls each KAT directly) — pins
    the AWS-LC-backed `sha256` to exactly:

        ""                    e3b0c44298fc1c14...7852b855   (vector 0 here)
        "abc"                 ba7816bf8f01cfea...f20015ad   (vector 2 here)
        "abcdbcde...nopq"     248d6a61d20638b8...19db06c1   (vector 7 here)

    Those three byte strings appear in BOTH files. `test_cavp_sha256_short.mojo`
    carries the NIST CAVP corpus against the same implementation.

    ⛔ WHY THAT IS THE FORM THE AGREEMENT TAKES, rather than one test calling
    both. `komira_core` (which owns `eval/digest_functions.mojo`) and
    `komira_crypto` are DISJOINT LEAVES of the build graph — neither depends
    on the other — and the libraries that do see both are cloud clients;
    welding a digest-agreement test to one of those would gate an unrelated
    library on it. `eval/digest_functions.mojo`'s own header states the
    product-side half of the same reason: reaching `komira_crypto` from the
    evaluator would put its tests and native library on every engine build. The
    shared published vector is therefore the oracle both implementations
    answer to, and it is a STRONGER one than each other: if both were wrong
    the same way, a direct comparison would still be green.
    """
    # RFC 3174 TEST4 — ten repetitions of a 64-byte block (640 bytes), and a
    # 1000-byte message. Built rather than spelled so the source stays legible.
    var long640 = String("")
    for _ in range(10):
        long640 += String(
            "0123456701234567012345670123456701234567012345670123456701234567"
        )
    var thousand_a = String("")
    for _ in range(1000):
        thousand_a += String("a")
    # ⛔ THE 16-BIT LENGTH-FIELD BOUNDARY. 8192 bytes == 65536 bits == 2**16,
    # the SMALLEST length whose bit-count does not fit a UInt16. Built from 128
    # copies of a 64-byte block (not 8192 one-byte concatenations) so the
    # fixture stays cheap. ⚠ NOT by doubling: `x += x` aliases `self` and
    # `other` in `__iadd__` and does not compile.
    var boundary8192 = String("")
    for _ in range(128):
        boundary8192 += String(
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        )
    assert_equal(
        boundary8192.byte_length(),
        8192,
        "the 16-bit boundary vector must be exactly 8192 bytes, or it does"
        " not cross the boundary it exists to cross",
    )

    var vals = List[String]()
    vals.append(String(""))
    vals.append(String("a"))
    vals.append(String("abc"))
    vals.append(String("message digest"))
    vals.append(String("abcdefghijklmnopqrstuvwxyz"))
    vals.append(
        String("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
    )
    vals.append(
        String("12345678901234567890123456789012345678901234567890"
               "123456789012345678901234567890")
    )
    vals.append(
        String("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
    )
    vals.append(long640)
    vals.append(thousand_a)
    vals.append(boundary8192)

    var want_md5: List[String] = [
        String("d41d8cd98f00b204e9800998ecf8427e"),
        String("0cc175b9c0f1b6a831c399e269772661"),
        String("900150983cd24fb0d6963f7d28e17f72"),
        String("f96b697d7cb7938d525a2f31aaf161d0"),
        String("c3fcd3d76192e4007dfb496cca67e13b"),
        String("d174ab98d277d9f5a5611c2c9f419d9f"),
        String("57edf4a22be3c955ac49da2e2107b67a"),
        String("8215ef0796a20bcaaae116d3876c664a"),
        String("ffeaeb581c29c85301f6d7252808fa3d"),
        String("cabe45dcc9ae5b66ba86600cca6b8ba8"),
        String("221994040b14294bdf7fbc128e66633c"),
    ]
    _assert_digest_over(STRFN_MD5, String("md5/std"), vals, want_md5)

    var want_sha1: List[String] = [
        String("da39a3ee5e6b4b0d3255bfef95601890afd80709"),
        String("86f7e437faa5a7fce15d1ddcb9eaeaea377667b8"),
        String("a9993e364706816aba3e25717850c26c9cd0d89d"),
        String("c12252ceda8be8994d5fa0290a47231c1d16aae3"),
        String("32d10c7b8cf96570ca04ce37f2a19d84240d3a89"),
        String("761c457bf73b14d27e9e9265c46f4b4dda11f940"),
        String("50abf5706a150990a08b2c5ea40fa0e585554732"),
        String("84983e441c3bd26ebaae4aa1f95129e5e54670f1"),
        String("dea356a2cddd90c7a7ecedc5ebb563934f460452"),
        String("291e9a6c66994949b57ba5e650361e98fc36b1ba"),
        String("2727756cfee3fbfe24bf5650123fd7743d7b3465"),
    ]
    _assert_digest_over(STRFN_SHA1, String("sha1/std"), vals, want_sha1)

    var want_sha256: List[String] = [
        String(
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        ),
        String(
            "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb"
        ),
        String(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        ),
        String(
            "f7846f55cf23e14eebeab5b4e1550cad5b509e3348fbc4efa3a1413d393cb650"
        ),
        String(
            "71c480df93d6ae2f1efad1447c66c9525e316218cf51fc8d9ed832f2daf18b73"
        ),
        String(
            "db4bfcbd4da0cd85a60c3c37d3fbd8805c77f15fc6b1fdfe614ee0a7c8fdb4c0"
        ),
        String(
            "f371bc4a311f2b009eef952dd83ca80e2b60026c8e935592d0f9c308453c813e"
        ),
        String(
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        ),
        String(
            "594847328451bdfa85056225462cc1d867d877fb388df0ce35f25ab5562bfbb5"
        ),
        String(
            "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3"
        ),
        String(
            "dd4e6730520932767ec0a9e33fe19c4ce24399d6eba4ff62f13013c9ed30ef87"
        ),
    ]
    _assert_digest_over(STRFN_SHA256, String("sha256/std"), vals, want_sha256)


def test_the_digests_hash_UTF8_BYTES_not_CODEPOINTS() raises:
    """`md5` / `sha1` / `sha256` over seven MULTI-BYTE inputs.

    ⛔⛔ THIS IS THE DEFECT THIS REPO HAS SHIPPED FOUR TIMES. `chr` here is a
    CODEPOINT constructor, and every previous instance of the confusion was a
    kernel that walked a String as codepoints and handed those to a byte-taking
    routine. A digest built that way produces a well-formed hex string of the
    right length that is simply the digest of DIFFERENT BYTES — the single
    failure mode that no length check, no distinctness check and no NULL check
    can see.

    ⛔ VECTOR 0 IS THE MINIMAL WITNESS. `é` is U+00E9: TWO UTF-8 bytes
    (C3 A9), one codepoint whose value 0xE9 fits in ONE byte. A codepoint-fed
    kernel digests the single byte E9 and answers
    `md5` = `3406877694691ddd1dfb0aca54681407` (MEASURED: the MD5 of the
    single byte E9) instead of `66ddcd97cfdeabb2f6fb8a999b4bc76f`. Both are
    well-formed 32-character lowercase hex. Every ASCII vector in the test
    above is GREEN under that defect, because for ASCII the two readings
    coincide.

    ⛔ VECTOR 4 IS THE PADDING WITNESS AND IT IS THE IMPORTANT ONE. `漢`×20 is
    60 BYTES but 20 CHARACTERS. 60 crosses the 56-byte padding boundary and 20
    does not, so a kernel that counted CHARACTERS to decide how many blocks to
    emit — or to write the 64-bit length field — produces a different digest
    here even if it fed the right bytes to the compression function. That is a
    second, independent codepoint defect, and vector 0 cannot see it.

    ⛔ VECTOR 5 IS 56 BYTES EXACTLY (`é`×28), the boundary itself, reached only
    by counting bytes: as characters it is 28.

    ⚠ VECTOR 3 IS A 4-BYTE CODEPOINT (U+1F30D). A kernel that narrowed
    codepoints through a UInt16 truncates it; one that widened UTF-8 to UTF-32
    reds every vector here at once, which is how the two are told apart.

    Oracle: `hashlib` over the UTF-8 encoding, which is what the RFCs define
    (they define a digest over an OCTET STRING; the choice of encoding is
    SQL's, and DuckDB v1.5.3 digests the UTF-8 bytes of a VARCHAR).
    """
    var cjk20 = String("")
    for _ in range(20):
        cjk20 += String("漢")
    var e28 = String("")
    for _ in range(28):
        e28 += String("é")
    var mixed = String("")
    for _ in range(7):
        mixed += String("aé漢🌍")

    var vals = List[String]()
    vals.append(String("é"))
    vals.append(String("Straße"))
    vals.append(String("漢字"))
    vals.append(String("🌍"))
    vals.append(cjk20)
    vals.append(e28)
    vals.append(mixed)

    var want_md5: List[String] = [
        String("66ddcd97cfdeabb2f6fb8a999b4bc76f"),
        String("a763ca073cfda1fce8a14f2f0cc84591"),
        String("3817a0e701ec589ed75b4b1a01398747"),
        String("b60e8108aa184f9f8cfd1e6afb44ad8b"),
        String("b602b98a56a1677a9a5be0d668451736"),
        String("20b0102488adc14d6375a20e9e1ed8b3"),
        String("6cd5edcb97bb661d9a9c2a8e6d56f87c"),
    ]
    _assert_digest_over(STRFN_MD5, String("md5/utf8"), vals, want_md5)

    var want_sha1: List[String] = [
        String("bf15be717ac1b080b4f1c456692825891ff5073d"),
        String("880c6886fd25455f5534ec8b46e24a832dfb43b3"),
        String("50008262c76205f015248f124c87b9fe463ead9f"),
        String("757ce75a595ab42d6cbbddd942bf60922eedaf0b"),
        String("be12297ed9a0c74eca3fa69a7c5ad7f988e707dc"),
        String("95bec3c7bb4821a5e9fad9a89c094682d91b179e"),
        String("7f1fab1fe60f217c49d68243220857ae032ba845"),
    ]
    _assert_digest_over(STRFN_SHA1, String("sha1/utf8"), vals, want_sha1)

    var want_sha256: List[String] = [
        String(
            "4a99557e4033c3539de2eb65472017cad5f9557f7a0625a09f1c3f6e2ba69c4c"
        ),
        String(
            "58a3778c18c41726cd53c2a4c77dcbed8512f962d7e616717abee95ca41d0029"
        ),
        String(
            "c6d297713595d2f5127b438aa2ec2cb3049bb096cff7fe128f620a609c32a00f"
        ),
        String(
            "8cba3282fe37fa6054ce64531ce17410a1404e2bc4afbf113824097037b1e498"
        ),
        String(
            "754cce71c1adc39ff46599b9cdf8a9c073952e0f11df043253ba563bb3103d2e"
        ),
        String(
            "a2e7c1f809d17958e21b7cd370a1d7d030e07f3af72588be133d4f73fadee71d"
        ),
        String(
            "03d648dcc8ac8ad3ccad76cd941e01e6f152e06d5fa897e0558773f81c64d9cc"
        ),
    ]
    _assert_digest_over(STRFN_SHA256, String("sha256/utf8"), vals, want_sha256)


# ===========================================================================
# 3. `EXPR_MATH_FN` — TWENTY-FOUR OPS, AND NOT ONE OF THEM HAD AN EXECUTING
#    MOJO TEST BEFORE THIS FILE.
# ===========================================================================


def test_the_inverse_hyperbolics_and_gamma_compute() raises:
    """`acosh` / `asinh` / `gamma`, MEASURED on DuckDB v1.5.3, EXACT.

    Domain note: `acosh` needs `x >= 1`, so the fixture starts AT the boundary
    (`acosh(1.0)` = 0.0 exactly, the value a series approximation misses).
    `gamma` is on the same fixture because `gamma(n) = (n-1)!` for integer n —
    `gamma(5)` = 24 and `gamma(10)` = 362880 are recognisable, which makes a
    kernel wired to `lgamma` instead (3.178 and 12.80) obvious rather than
    merely different.

    ⛔ `gamma`'s EXPECTATIONS ARE libm's AND CANNOT BE TAKEN FROM CPython —
    see this file's header. `gamma(1.5)` = 0.886226925452758 here; CPython
    says 0.8862269254527578.
    """
    var xs: List[Float64] = [1.0, 1.5, 2.0, 5.0, 10.0]
    var want_acosh: List[Float64] = [
        0.0,
        0.9624236501192069,
        1.3169578969248166,
        2.2924316695611777,
        2.993222846126381,
    ]
    var want_asinh: List[Float64] = [
        0.881373587019543,
        1.1947632172871094,
        1.4436354751788103,
        2.3124383412727525,
        2.99822295029797,
    ]
    var want_gamma: List[Float64] = [
        1.0, 0.886226925452758, 1.0, 24.0, 362880.0
    ]
    _assert_math_op(MATH_ACOSH, String("acosh"), xs, want_acosh)
    _assert_math_op(MATH_ASINH, String("asinh"), xs, want_asinh)
    _assert_math_op(MATH_GAMMA, String("gamma"), xs, want_gamma)


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
