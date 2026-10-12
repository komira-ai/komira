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
