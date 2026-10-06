# =============================================================================
# test_row_cell.mojo — the `RowCell` value model and its equality.
# =============================================================================
#
# `komira_rowcell` has no encode/decode of its own (that belongs to each table
# format), so the round trip under test here is constructor -> accessor: every
# typed constructor stores its value in the arm its tag says, at the full range
# of that type, and the accessor hands it back unchanged.
#
# The equality tests pin the three rules an equality-delete match depends on:
#
#   1. Different type tags never compare equal, even for the same number
#      (`int 5` vs `long 5`, `float 1.5` vs `double 1.5`).
#   2. A NULL cell equals only a NULL cell of the same type. A NULL cell's value
#      arms are zero, so a check that compared arms before the null flag would
#      call `NULL long` equal to `long 0`; `test_null_never_equals_a_zero_value`
#      is the test that sees that.
#   3. Only the active arm is compared: two string cells are compared by their
#      bytes, two numeric cells by their number.
#
# `rows_equal` is the row-level form: same arity and every cell equal.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_rowcell import (
    CELL_T_BOOLEAN,
    CELL_T_DOUBLE,
    CELL_T_FLOAT,
    CELL_T_INT,
    CELL_T_LONG,
    CELL_T_STRING,
    RowCell,
    make_boolean_cell,
    make_double_cell,
    make_float_cell,
    make_int_cell,
    make_long_cell,
    make_null_cell,
    make_string_cell,
    rows_equal,
)


def _all_tags() -> List[Int]:
    var out = List[Int]()
    out.append(CELL_T_BOOLEAN)
    out.append(CELL_T_INT)
    out.append(CELL_T_LONG)
    out.append(CELL_T_FLOAT)
    out.append(CELL_T_DOUBLE)
    out.append(CELL_T_STRING)
    return out^


def _row(a: RowCell, b: RowCell, c: RowCell) -> List[RowCell]:
    var out = List[RowCell]()
    out.append(a.copy())
    out.append(b.copy())
    out.append(c.copy())
    return out^


def _utf8(*bytes: Int) -> String:
    var b = List[UInt8]()
    for i in range(len(bytes)):
        b.append(UInt8(bytes[i]))
    return String(unsafe_from_utf8=Span(b))


def _assert_unused_arms_zero(c: RowCell, what: String) raises:
    var t = c.type_tag
    if t != CELL_T_BOOLEAN and t != CELL_T_INT and t != CELL_T_LONG:
        assert_equal(c.as_long(), Int64(0), what + ": integral arm is zero")
    if t != CELL_T_FLOAT and t != CELL_T_DOUBLE:
        assert_equal(c.as_double(), Float64(0), what + ": float arm is zero")
    if t != CELL_T_STRING:
        assert_equal(c.as_string(), String(""), what + ": string arm is empty")


# -----------------------------------------------------------------------------
# The tags
# -----------------------------------------------------------------------------


def test_type_tags_are_distinct() raises:
    """Six kinds, six discriminants. Two equal tags would make two kinds compare
    as one, so equality across them would stop refusing."""
    var tags = _all_tags()
    for i in range(len(tags)):
        for j in range(i + 1, len(tags)):
            assert_true(
                tags[i] != tags[j],
                "tags " + String(i) + " and " + String(j) + " collide",
            )


# -----------------------------------------------------------------------------
# Constructor -> accessor round trip, at the edges of each type
# -----------------------------------------------------------------------------


def test_boolean_cell_round_trip() raises:
    var t = make_boolean_cell(True)
    var f = make_boolean_cell(False)
    assert_equal(t.type_tag, CELL_T_BOOLEAN)
    assert_equal(t.as_long(), Int64(1), "true is stored as 1")
    assert_equal(f.as_long(), Int64(0), "false is stored as 0")
    assert_false(t.is_null())
    assert_false(t.equals(f), "true != false")
    _assert_unused_arms_zero(t, "boolean")


def test_int_cell_round_trip_is_sign_extended() raises:
    """A 32-bit int is stored in the 64-bit arm sign-extended, so a negative int
    reads back negative, not as a large positive number."""
    var neg = make_int_cell(Int32(-1))
    assert_equal(neg.type_tag, CELL_T_INT)
    assert_equal(neg.as_long(), Int64(-1), "-1 sign-extends")
    assert_equal(
        make_int_cell(Int32.MIN).as_long(), Int64(-2147483648), "int min"
    )
    assert_equal(
        make_int_cell(Int32.MAX).as_long(), Int64(2147483647), "int max"
    )
    assert_false(neg.is_null())
    _assert_unused_arms_zero(neg, "int")


def test_long_cell_round_trip_at_the_limits() raises:
    var lo = make_long_cell(Int64.MIN)
    var hi = make_long_cell(Int64.MAX)
    assert_equal(lo.type_tag, CELL_T_LONG)
    assert_equal(lo.as_long(), Int64.MIN, "long min")
    assert_equal(hi.as_long(), Int64.MAX, "long max")
    assert_false(lo.equals(hi))
    _assert_unused_arms_zero(hi, "long")


def test_float_cell_is_stored_widened() raises:
    """A float is stored as the exact f64 widening of the f32, not as the
    nearest f64 to the decimal literal: `0.1f` reads back as `Float64(0.1f)`."""
    var v = Float32(0.1)
    var c = make_float_cell(v)
    assert_equal(c.type_tag, CELL_T_FLOAT)
    assert_equal(c.as_double(), Float64(v), "exact widening of the f32")
    assert_true(c.as_double() != Float64(0.1), "not the f64 nearest 0.1")
    assert_equal(make_float_cell(Float32(-2.5)).as_double(), Float64(-2.5))
    _assert_unused_arms_zero(c, "float")


def test_double_cell_round_trip() raises:
    var c = make_double_cell(Float64(-1234.5678))
    assert_equal(c.type_tag, CELL_T_DOUBLE)
    assert_equal(c.as_double(), Float64(-1234.5678))
    assert_equal(make_double_cell(Float64(1e308)).as_double(), Float64(1e308))
    _assert_unused_arms_zero(c, "double")


def test_string_cell_round_trip_keeps_bytes() raises:
    """Empty and multi-byte UTF-8 strings come back byte for byte."""
    var empty = make_string_cell(String(""))
    assert_equal(empty.type_tag, CELL_T_STRING)
    assert_equal(empty.as_string().byte_length(), 0)
    var s = String("kéy — 日本")
    var c = make_string_cell(String(s))
    assert_equal(c.as_string(), s)
    assert_equal(c.as_string().byte_length(), s.byte_length())
    assert_false(c.is_null())
    _assert_unused_arms_zero(c, "string")


def test_copy_is_an_equal_independent_cell() raises:
    var a = make_string_cell(String("alpha"))
    var b = a.copy()
    assert_true(b.equals(a))
    b.s = String("beta")
    assert_equal(a.as_string(), String("alpha"), "the original is untouched")
    assert_false(b.equals(a))
    var n = make_null_cell(CELL_T_LONG)
    assert_true(n.copy().is_null(), "copy keeps the null flag")


# -----------------------------------------------------------------------------
# NULL cells
# -----------------------------------------------------------------------------


def test_null_cell_of_every_tag() raises:
    var tags = _all_tags()
    for i in range(len(tags)):
        var n = make_null_cell(tags[i])
        var what = "null of tag " + String(tags[i])
        assert_true(n.is_null(), what)
        assert_equal(n.type_tag, tags[i], what + ": keeps its declared type")
        assert_equal(n.as_long(), Int64(0), what)
        assert_equal(n.as_double(), Float64(0), what)
        assert_equal(n.as_string(), String(""), what)
        assert_true(n.equals(make_null_cell(tags[i])), what + " == itself")


def test_null_never_equals_a_zero_value() raises:
    """A NULL cell's arms are zero, so this is the case where comparing arms
    without the null flag gives the wrong answer. Both directions."""
    var pairs = List[RowCell]()
    pairs.append(make_boolean_cell(False))
    pairs.append(make_int_cell(Int32(0)))
    pairs.append(make_long_cell(Int64(0)))
    pairs.append(make_float_cell(Float32(0)))
    pairs.append(make_double_cell(Float64(0)))
    pairs.append(make_string_cell(String("")))
    for i in range(len(pairs)):
        var zero = pairs[i].copy()
        var n = make_null_cell(zero.type_tag)
        var what = "tag " + String(zero.type_tag)
        assert_false(n.equals(zero), what + ": NULL == zero value")
        assert_false(zero.equals(n), what + ": zero value == NULL")


def test_nulls_of_different_types_are_not_equal() raises:
    assert_false(
        make_null_cell(CELL_T_INT).equals(make_null_cell(CELL_T_LONG)),
        "NULL int == NULL long",
    )


# -----------------------------------------------------------------------------
# Equality across and within types
# -----------------------------------------------------------------------------


def test_same_number_different_type_is_not_equal() raises:
    assert_false(
        make_int_cell(Int32(5)).equals(make_long_cell(Int64(5))),
        "int 5 == long 5",
    )
    assert_false(
        make_float_cell(Float32(1.5)).equals(make_double_cell(Float64(1.5))),
        "float 1.5 == double 1.5",
    )
    assert_false(
        make_boolean_cell(True).equals(make_long_cell(Int64(1))),
        "true == long 1",
    )
    assert_false(
        make_string_cell(String("")).equals(make_long_cell(Int64(0))),
        "'' == long 0",
    )


def test_like_typed_cells_compare_by_value() raises:
    assert_true(make_long_cell(Int64(42)).equals(make_long_cell(Int64(42))))
    assert_false(make_long_cell(Int64(42)).equals(make_long_cell(Int64(43))))
    assert_true(
        make_double_cell(Float64(2.25)).equals(make_double_cell(Float64(2.25)))
    )
    assert_false(
        make_double_cell(Float64(2.25)).equals(make_double_cell(Float64(2.5)))
    )


def test_string_equality_is_bytewise() raises:
    """Same bytes equal; a prefix, a one-byte change and a different encoding
    of a similar-looking text do not."""
    var a = make_string_cell(String("abc"))
    assert_true(a.equals(make_string_cell(String("abc"))))
    assert_false(a.equals(make_string_cell(String("ab"))), "prefix")
    assert_false(a.equals(make_string_cell(String("abcd"))), "extension")
    assert_false(a.equals(make_string_cell(String("abd"))), "last byte")
    # U+00E9 precomposed (c3 a9) vs e + U+0301 combining (65 cc 81): the
    # same glyph, different bytes.
    assert_false(
        make_string_cell(_utf8(0xC3, 0xA9)).equals(
            make_string_cell(_utf8(0x65, 0xCC, 0x81))
        ),
        "different byte sequences",
    )


# -----------------------------------------------------------------------------
# rows_equal
# -----------------------------------------------------------------------------


def test_rows_equal_cell_by_cell() raises:
    var a = _row(
        make_long_cell(Int64(1)),
        make_string_cell(String("x")),
        make_null_cell(CELL_T_DOUBLE),
    )
    var b = _row(
        make_long_cell(Int64(1)),
        make_string_cell(String("x")),
        make_null_cell(CELL_T_DOUBLE),
    )
    assert_true(rows_equal(a, b))
    assert_true(rows_equal(b, a))
    assert_true(rows_equal(List[RowCell](), List[RowCell]()), "empty rows")


def test_rows_differing_in_one_cell_are_not_equal() raises:
    var a = _row(
        make_long_cell(Int64(1)),
        make_string_cell(String("x")),
        make_null_cell(CELL_T_DOUBLE),
    )
    var last = _row(
        make_long_cell(Int64(1)),
        make_string_cell(String("x")),
        make_double_cell(Float64(0)),
    )
    var first = _row(
        make_long_cell(Int64(2)),
        make_string_cell(String("x")),
        make_null_cell(CELL_T_DOUBLE),
    )
    assert_false(rows_equal(a, last), "last cell NULL vs 0.0")
    assert_false(rows_equal(a, first), "first cell differs")


def test_rows_of_different_arity_are_not_equal() raises:
    var a = _row(
        make_long_cell(Int64(1)),
        make_long_cell(Int64(2)),
        make_long_cell(Int64(3)),
    )
    var prefix = List[RowCell]()
    prefix.append(make_long_cell(Int64(1)))
    prefix.append(make_long_cell(Int64(2)))
    assert_false(rows_equal(a, prefix), "longer vs its prefix")
    assert_false(rows_equal(prefix, a), "prefix vs longer")
    assert_false(rows_equal(a, List[RowCell]()), "row vs empty")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
