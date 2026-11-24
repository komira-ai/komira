"""tpch_compare.py, the answer check of the TPC-H run through the wheel
(test_tpch_installed.py): it must pass an answer that equals the recorded one
and refuse every kind of difference, since a check that passes everything
would make the 22-query table meaningless.

    test_tpch_compare.py

Each case builds the answer and the recorded signature from cells, as the wheel
test does from a pyarrow table and the answers file.
"""

import datetime
import decimal
import io
import sys

import pyarrow as pa

import tpch_compare as t


def sig(types, *rows):
    return t.signature_of(t.Result([list(r) for r in rows], list(types)))


def reasons_of(actual, expected):
    return t.compare(actual, expected)[0]


def check(cond, what):
    if not cond:
        raise AssertionError(what)


def expect_reason(actual, expected, fragment):
    reasons = reasons_of(actual, expected)
    check(any(fragment in r for r in reasons), "wanted a reason with {!r}, got {}".format(fragment, reasons))


I = t.integer
D = t.exact
T = t.text
R = t.real
N = t.null


def test_equal_answers_agree_in_any_row_order():
    a = sig(["BIGINT", "VARCHAR", "DECIMAL(15,2)", "DOUBLE"], [I(1), T("x"), D("1.50"), R(0.25)], [I(2), T("y"), D("2.5"), R(0.5)], [N(), N(), N(), N()])
    b = sig(["BIGINT", "VARCHAR", "DECIMAL(15,2)", "DOUBLE"], [N(), N(), N(), N()], [I(2), T("y"), D("2.50"), R(0.5)], [I(1), T("x"), D("1.5"), R(0.25)])
    check(reasons_of(a, b) == [], reasons_of(a, b))


def test_a_changed_integer_is_a_difference_even_when_the_sum_is_kept():
    expected = sig(["BIGINT"], [I(1)], [I(5)])
    expect_reason(sig(["BIGINT"], [I(2)], [I(4)]), expected, "sum of squares")
    expect_reason(sig(["BIGINT"], [I(1)], [I(6)]), expected, "sum differs")


def test_integer_sums_wrap_like_signed_64_bit_arithmetic():
    big = (1 << 62)
    a = sig(["BIGINT"], [I(big)], [I(big)], [I(big)])
    check(a.columns[0].isum == t.wrap64(3 * big) and a.columns[0].isum < 0, a.columns[0].isum)


def test_a_decimal_that_differs_in_its_last_digit_is_a_difference():
    expected = sig(["DECIMAL(38,2)"], [D("12345678901234567890.12")])
    expect_reason(sig(["DECIMAL(38,2)"], [D("12345678901234567890.13")]), expected, "sum differs")
    check(reasons_of(sig(["DECIMAL(38,2)"], [D("12345678901234567890.120")]), expected) == [], "trailing zeros are one value")


def test_a_decimal_column_never_compares_with_a_double_column():
    expect_reason(sig(["DOUBLE"], [R(1.5)]), sig(["DECIMAL(15,2)"], [D("1.5")]), "has kind")


def test_texts_that_differ_in_one_character_are_a_difference():
    expected = sig(["VARCHAR"], [T("abc")], [T("abd")])
    expect_reason(sig(["VARCHAR"], [T("abc")], [T("abe")]), expected, "largest text differs")
    expect_reason(sig(["VARCHAR"], [T("abd")], [T("abd")]), expected, "smallest text differs")
    middle = sig(["VARCHAR"], [T("a")], [T("c")], [T("b")])
    expect_reason(sig(["VARCHAR"], [T("a")], [T("c")], [T("x")]), middle, "texts differ")


def test_text_extremes_follow_utf8_byte_order():
    s = sig(["VARCHAR"], [T("～")], [T("~")])
    check(s.columns[0].text_min == "~" and s.columns[0].text_max == "～", (s.columns[0].text_min, s.columns[0].text_max))


def test_doubles_agree_within_the_relative_tolerance_and_not_beyond():
    expected = sig(["DOUBLE"], [R(1000.0)])
    check(reasons_of(sig(["DOUBLE"], [R(1000.0 * (1 + 2e-10))]), expected) == [], "within the tolerance (the sum of squares moves twice as far)")
    expect_reason(sig(["DOUBLE"], [R(1000.0 * (1 + 1e-7))]), expected, "sum differs")


def test_an_integer_column_against_a_double_column_compares_as_numbers():
    expected = sig(["DOUBLE"], [I(3)], [I(4)])
    check(reasons_of(sig(["DOUBLE"], [R(3.0)], [R(4.0)]), expected) == [], "equal values as doubles and integers")
    expect_reason(sig(["DOUBLE"], [R(3.0)], [R(4.5)]), expected, "sum differs")


def test_row_count_null_count_and_column_count_differences_are_named():
    expected = sig(["BIGINT"], [I(1)], [N()])
    expect_reason(sig(["BIGINT"], [I(1)]), expected, "row count differs")
    expect_reason(sig(["BIGINT"], [I(1)], [I(1)]), expected, "null count differs")
    expect_reason(sig(["BIGINT", "BIGINT"], [I(1), I(1)], [N(), N()]), expected, "column count differs")


def test_a_declared_type_that_differs_fails_even_when_the_values_agree():
    expect_reason(sig(["INTEGER"], [I(1)]), sig(["BIGINT"], [I(1)]), "declared type differs: INTEGER against BIGINT")
    expect_reason(sig(["DECIMAL(38,4)"], [D("1")]), sig(["DECIMAL(38,2)"], [D("1")]), "declared type differs")
    expect_reason(sig(["UNMAPPED(arrow type timestamp[us])"], [I(1)]), sig(["BIGINT"], [I(1)]), "not in the mapping")


def test_hugeint_as_decimal_38_0_is_a_departure_only_for_equal_values():
    expected = sig(["HUGEINT"], [D("123456789012345678901234567890")])
    reasons, departures = t.compare(sig(["DECIMAL(38,0)"], [D("123456789012345678901234567890")]), expected)
    check(reasons == [] and departures == ["Arrow has no 128-bit integer: HUGEINT as DECIMAL(38,0)"], (reasons, departures))
    reasons, departures = t.compare(sig(["DECIMAL(38,0)"], [D("123456789012345678901234567891")]), expected)
    check(reasons and departures == [], (reasons, departures))
    expect_reason(sig(["BIGINT"], [I(1)]), sig(["HUGEINT"], [I(1)]), "declared type differs")


def test_a_column_mixing_numbers_and_text_is_a_difference():
    mixed = sig(["BIGINT"], [I(1)], [T("a")])
    expect_reason(mixed, mixed, "mixes values")


def test_the_order_check_follows_the_keys_directions_and_nulls():
    types = ["BIGINT", "VARCHAR"]

    def result(*rows):
        return t.Result([list(r) for r in rows], types)

    asc = [(0, False, False)]
    check(t.check_order(result([I(1), T("a")], [I(1), T("a")], [I(2), T("a")], [N(), T("a")]), asc) is None, "nulls sort last")
    check("row 1" in t.check_order(result([I(2), T("a")], [I(1), T("a")]), asc), "ascending violated")
    check(t.check_order(result([I(2), T("a")], [I(1), T("a")]), [(0, True, False)]) is None, "descending")
    check("row 1" in t.check_order(result([I(1), T("a")], [N(), T("a")]), [(0, False, True)]), "nulls first violated")
    check(t.check_order(result([I(1), T("b")], [I(1), T("a")]), [(0, False, False), (1, True, False)]) is None, "second key")
    check("row 1" in t.check_order(result([I(1), T("b")], [I(1), T("a")]), [(0, False, False), (1, False, False)]), "second key violated")
    check(t.check_order(result([I(1), T("～")], [I(1), T("~")]), [(1, True, False)]) is None, "texts order by bytes")
    try:
        t.check_order(result([I(1), T("a")]), [(5, False, False)])
    except ValueError as e:
        check("out of range" in str(e), str(e))
    else:
        raise AssertionError("a key outside the columns was accepted")


def test_a_pyarrow_table_becomes_cells_and_declared_types():
    table = pa.table(
        {
            "d": pa.array([decimal.Decimal("1.50"), None], pa.decimal128(15, 2)),
            "day": pa.array([datetime.date(1995, 3, 15), None], pa.date32()),
            "big": pa.array([1, 2 ** 63], pa.uint64()),
            "n": pa.array([7, None], pa.int32()),
            "f": pa.array([0.5, None], pa.float64()),
            "s": pa.array(["x", None], pa.string()),
        }
    )
    result = t.result_of_table(table)
    check(result.types == ["DECIMAL(15,2)", "DATE", "UBIGINT", "INTEGER", "DOUBLE", "VARCHAR"], result.types)
    first, second = result.rows
    check([c.kind for c in first] == [t.KIND_DECIMAL, t.KIND_TEXT, t.KIND_INT, t.KIND_INT, t.KIND_FLOAT, t.KIND_TEXT], [c.kind for c in first])
    check(first[0].value == "1.5" and first[1].value == "1995-03-15", (first[0].value, first[1].value))
    check(second[0].kind == t.KIND_NULL and second[2].kind == t.KIND_DECIMAL and second[2].value == str(2 ** 63), "uint64 past 63 bits is an exact decimal")


def test_an_arrow_type_with_no_cell_is_refused_by_name():
    table = pa.table({"ts": pa.array([datetime.datetime(2000, 1, 1)], pa.timestamp("us"))})
    try:
        t.result_of_table(table)
    except t.Refused as e:
        check(str(e) == "RESULT_TYPE_UNSUPPORTED: arrow type timestamp[us]", str(e))
    else:
        raise AssertionError("a timestamp column was converted")


def _column_line(kind, count, nulls, nans, ints, floats, texts, dec, declared):
    isum, isumsq, imin, imax = ints
    s, sq, lo, hi = floats
    tbytes, thash, tmin, tmax = texts
    dcount, dsum, dmin, dmax, dhash = dec
    return "column {} {} {} {} {} {} {} {} {} {} {} {} {} {} x{} x{} {} {} {} {} {} {}".format(
        kind, count, nulls, nans, isum, isumsq, imin, imax, s, sq, lo, hi, tbytes, thash, tmin.encode().hex(), tmax.encode().hex(), dcount, dsum, dmin, dmax, dhash, declared
    )


def test_recorded_answers_read_back_as_the_signature_of_the_rows_they_describe():
    rows = [[I(3), T("ab"), D("1.25")], [I(5), T("c"), D("0.75")]]
    actual = sig(["BIGINT", "VARCHAR", "DECIMAL(15,2)"], *rows)
    h = t.wrap64(t.cell_hash("ab") + t.cell_hash("c"))
    dh = t.wrap64(t.cell_hash("1.25") + t.cell_hash("0.75"))
    text = "\n".join(
        [
            "# derived from TPC-H; not comparable to published TPC-H results",
            "format 3",
            "query q99",
            "rows 2",
            "order 0:d:l,1:a:f",
            _column_line(1, 2, 0, 0, (8, 34, 3, 5), (8.0, 34.0, 3.0, 5.0), (0, 0, "", ""), (0, "0", "0", "0", 0), "BIGINT"),
            _column_line(3, 2, 0, 0, (0, 0, 0, 0), (0.0, 0.0, 0.0, 0.0), (3, h, "ab", "c"), (0, "0", "0", "0", 0), "VARCHAR"),
            _column_line(4, 2, 0, 0, (0, 0, 0, 0), (0.0, 0.0, 0.0, 0.0), (0, 0, "", ""), (2, "2", "0.75", "1.25", dh), "DECIMAL(15,2)"),
            "end",
            "",
        ]
    )
    answer = _parse_text(text)["q99"]
    check(answer.order == [(0, True, False), (1, False, True)], answer.order)
    check(answer.signature.rows == 2 and answer.signature.types == ["BIGINT", "VARCHAR", "DECIMAL(15,2)"], "rows and types")
    check(reasons_of(actual, answer.signature) == [], reasons_of(actual, answer.signature))
    changed = sig(["BIGINT", "VARCHAR", "DECIMAL(15,2)"], [I(3), T("ab"), D("1.25")], [I(5), T("c"), D("0.76")])
    expect_reason(changed, answer.signature, "column 2 sum differs")


def _parse_text(text):
    return t.parse_answers(io.StringIO(text))


def test_answers_that_are_malformed_or_of_another_format_are_refused():
    for text, fragment in (
        ("format 2\nquery q1\n", "not in format 3"),
        ("query q1\nrows 1\nend\n", "bad query line"),
        ("format 3\nquery q1\nrows 1\n", "no end line"),
        ("format 3\nquery q1\nend\n", "has no rows line"),
        ("format 3\nquery q1\nrows 0\nend\nquery q1\n", "bad query line"),
        ("format 3\nquery q1\nrows 0\nbogus 1\nend\n", "unknown line"),
        ("format 3\nquery q1\nrows 1\ncolumn 1 2\nend\n", "23 fields"),
        ("format 3\nrows 1\n", "outside a record"),
    ):
        try:
            _parse_text(text)
        except ValueError as e:
            check(fragment in str(e), "{!r} raised {}".format(text, e))
        else:
            raise AssertionError("{!r} was accepted".format(text))


def test_a_decimal_text_is_canonical_and_a_malformed_one_is_refused():
    check(t.canonical_decimal("007.5000") == "7.5", t.canonical_decimal("007.5000"))
    check(t.canonical_decimal("-0.00") == "0", t.canonical_decimal("-0.00"))
    check(t.decimal_text(decimal.Decimal("1E+3")) == "1000", t.decimal_text(decimal.Decimal("1E+3")))
    for bad in ("", "1.", ".5", "1e3", "a", "1." + "0" * 3 + "1" * 39):
        try:
            t.canonical_decimal(bad)
        except ValueError:
            pass
        else:
            raise AssertionError("{!r} was accepted".format(bad))


def main():
    tests = [(name, fn) for name, fn in sorted(globals().items()) if name.startswith("test_") and callable(fn)]
    for name, fn in tests:
        fn()
    print("{} tests passed".format(len(tests)))


if __name__ == "__main__":
    sys.exit(main())
