# duckdb_tsv: DuckDB's TSV read by value into canonical text, and compared.
# The cells here are spelt as the pinned DuckDB spells them (komira_test_oracle's
# test_duckdb_spellings holds the reader to bytes DuckDB itself wrote).
#
# Defects these catch: the empty string read as NULL or NULL as the empty
# string; a doubled quote not undone, or a quoted cell cut at its TAB or LF;
# junk after a closing quote, an unclosed quote, a ragged row or a missing
# last LF accepted; a NULL let into a column that is not nullable; a float
# compared as text (`1.50` against `1.5`, `1e+300` against `1e300`) or
# rounded to the wrong neighbour; -0.0 read as 0.0; a NaN spelling that is
# not a NaN; an integer out of its type's range, a sign on an unsigned type
# or `1.0` in an integer column accepted; a decimal whose scale differs;
# names not held to the schema; a type the reader cannot read compared as
# text instead of refused.

from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_plan_harness import (
    CanonText,
    compare_canon,
    duckdb_tsv_canon,
    parse_canon,
    parse_duckdb_tsv,
)


def _like(order: String, schema: String, rows: String = "") raises -> CanonText:
    return parse_canon(
        String("#! komira-plan-conformance v1\n#  order: ") + order
        + "\n#  float: ulps=0\n" + schema + "\n" + rows
    )


def _canon(schema: String, tsv: String) raises -> CanonText:
    return duckdb_tsv_canon(parse_duckdb_tsv(tsv), _like("total", schema))


def _f64(x: Float64) -> String:
    return String("|0x") + hex(bitcast[DType.uint64](x), prefix="").upper()


def test_quoting_and_null() raises:
    var t = parse_duckdb_tsv(
        "s\tn\n\"\"\t1\n\t2\n\"say \"\"hi\"\"\"\t3\n\"tab\there\nline\"\t4\n\\N\t5\na,b\t6\n"
    )
    assert_equal(len(t.names), 2)
    assert_equal(len(t.rows), 6)
    assert_true(Bool(t.rows[0][0]))
    assert_equal(t.rows[0][0].value(), "")
    assert_true(not t.rows[1][0])
    assert_equal(t.rows[2][0].value(), "say \"hi\"")
    assert_equal(t.rows[3][0].value(), "tab\there\nline")
    assert_equal(t.rows[4][0].value(), "\\N")
    assert_equal(t.rows[5][0].value(), "a,b")
    var c = _canon("s:string?\tn:int64", "s\tn\n\"\"\t1\n\t2\n\"tab\there\nline\"\t4\n\\N\t5\n")
    assert_equal(c.rows[0][0], "")
    assert_equal(c.rows[1][0], "\\N")
    assert_equal(c.rows[2][0], "tab\\there\\nline")
    assert_equal(c.rows[3][0], "\\\\N")


def test_one_column_null_row() raises:
    # A one-column row holding NULL is an empty line.
    var c = _canon("x:int64?", "x\n1\n\n3\n")
    assert_equal(c.num_rows(), 3)
    assert_equal(c.rows[1][0], "\\N")


def test_malformed_files_are_refused() raises:
    with assert_raises(contains="is not closed"):
        _ = parse_duckdb_tsv("s\n\"open\n")
    with assert_raises(contains="followed by something other"):
        _ = parse_duckdb_tsv("s\n\"a\"b\n")
    with assert_raises(contains="holds a quote or a CR"):
        _ = parse_duckdb_tsv("s\na\"b\n")
    with assert_raises(contains="holds a quote or a CR"):
        _ = parse_duckdb_tsv("s\na\rb\n")
    with assert_raises(contains="row 2 has 1 cells, the header 2"):
        _ = parse_duckdb_tsv("a\tb\n1\t2\n3\n")
    with assert_raises(contains="does not end in LF"):
        _ = parse_duckdb_tsv("a\n1")
    with assert_raises(contains="no header line"):
        _ = parse_duckdb_tsv("")
    with assert_raises(contains="header cell 2 is empty"):
        _ = parse_duckdb_tsv("a\t\n1\t2\n")


def test_names_and_nullability_are_the_schemas() raises:
    with assert_raises(contains="column 2 is 'y', the schema's 'x'"):
        _ = _canon("k:int64\tx:int64", "k\ty\n1\t2\n")
    with assert_raises(contains="1 columns, the schema 2"):
        _ = _canon("k:int64\tx:int64", "k\n1\n")
    with assert_raises(contains="row 1 column k: NULL in a column that is not nullable"):
        _ = _canon("k:int64", "k\n\n")


def test_integers_by_type() raises:
    var c = _canon(
        "a:int8\tb:int64\tc:uint64\td:uint8",
        "a\tb\tc\td\n-128\t-9223372036854775808\t18446744073709551615\t0\n127\t9223372036854775807\t0\t255\n",
    )
    assert_equal(c.rows[0][0], "-128")
    assert_equal(c.rows[0][1], "-9223372036854775808")
    assert_equal(c.rows[0][2], "18446744073709551615")
    assert_equal(c.rows[1][3], "255")
    with assert_raises(contains="'128' is above the range of int8"):
        _ = _canon("a:int8", "a\n128\n")
    with assert_raises(contains="'-129' is below the range of int8"):
        _ = _canon("a:int8", "a\n-129\n")
    with assert_raises(contains="'18446744073709551616' is above the range of uint64"):
        _ = _canon("a:uint64", "a\n18446744073709551616\n")
    with assert_raises(contains="'-1' is negative, and uint32 is unsigned"):
        _ = _canon("a:uint32", "a\n-1\n")
    with assert_raises(contains="'1.0' is not an integer"):
        _ = _canon("a:int64", "a\n1.0\n")
    with assert_raises(contains="'-' is not an integer"):
        _ = _canon("a:int64", "a\n-\n")


def test_bool_and_decimal() raises:
    var c = _canon(
        "b:bool\td:decimal128(9,2)\tz:decimal128(5,0)",
        "b\td\tz\ntrue\t-9999999.99\t12345\nfalse\t0.00\t-0\n",
    )
    assert_equal(c.rows[0][0], "true")
    assert_equal(c.rows[0][1], "-999999999e-2")
    assert_equal(c.rows[0][2], "12345e0")
    assert_equal(c.rows[1][1], "0e-2")
    assert_equal(c.rows[1][2], "0e0")
    with assert_raises(contains="'TRUE' is not true or false"):
        _ = _canon("b:bool", "b\nTRUE\n")
    with assert_raises(contains="'1.5' has 1 digits after the point, the scale is 2"):
        _ = _canon("d:decimal128(9,2)", "d\n1.5\n")
    with assert_raises(contains="has more than 3 digits"):
        _ = _canon("d:decimal128(3,1)", "d\n123.4\n")


def test_floats_by_value() raises:
    var c = _canon(
        "f:float64\tg:float32",
        "f\tg\n-0.0\t-0.0\n0.1\t0.1\n1e+300\t1e+30\n1.5e-07\t1e-45\n5e-324\t3.4028235e+38\n"
        + "1.7976931348623157e+308\t-2.5\nnan\t-nan\ninf\t-inf\n",
    )
    assert_equal(c.rows[0][0], "-0.0|0x8000000000000000")
    assert_equal(c.rows[0][1], "-0.0|0x80000000")
    assert_true(c.rows[1][0].endswith(_f64(0.1)))
    assert_true(c.rows[1][1].endswith("|0x3DCCCCCD"))
    assert_true(c.rows[2][0].endswith(_f64(1e300)))
    assert_true(c.rows[2][1].endswith("|0x7149F2CA"))
    assert_true(c.rows[3][0].endswith(_f64(1.5e-07)))
    assert_true(c.rows[3][1].endswith("|0x00000001"))
    assert_true(c.rows[4][0].endswith("|0x0000000000000001"))
    assert_true(c.rows[4][1].endswith("|0x7F7FFFFF"))
    assert_true(c.rows[5][0].endswith("|0x7FEFFFFFFFFFFFFF"))
    assert_equal(c.rows[6][0], "NaN")
    assert_equal(c.rows[6][1], "NaN")
    assert_equal(c.rows[7][0], "inf|0x7FF0000000000000")
    assert_equal(c.rows[7][1], "-inf|0xFF800000")
    with assert_raises(contains="is not a decimal number"):
        _ = _canon("f:float64", "f\n1.5x\n")
    with assert_raises(contains="'1e999' is not a finite float64"):
        _ = _canon("f:float64", "f\n1e999\n")


def test_compare_is_by_value() raises:
    # The HAND side writes 1.5, -0.0 and a bare NaN; DuckDB writes 1.50
    # (as a decimal digit string a float column reads by value), -0.0, -nan.
    var hand = _like("total", "f:float64?\tk:int64", "1.5\t1\n-0.0\t2\nNaN\t3\n\\N\t4\n")
    var duck = duckdb_tsv_canon(parse_duckdb_tsv("f\tk\n1.50\t1\n-0.0\t2\n-nan\t3\n\t4\n"), hand)
    assert_equal(compare_canon(hand, duck).count(), 0)
    # 0.0 is not -0.0, 0.2 is not 0.1, a value is not NULL: one mismatch each.
    var off = duckdb_tsv_canon(parse_duckdb_tsv("f\tk\n1.5\t1\n0.0\t2\n0.2\t3\n1\t4\n"), hand)
    var report = compare_canon(hand, off)
    assert_equal(report.count_of("cell"), 3)


def test_policy_is_the_schema_sides() raises:
    # order: none, the rows in another order: equal; under total: not.
    var hand = _like("none", "k:int64\ts:string?", "1\ta\n2\t\n")
    var duck = duckdb_tsv_canon(parse_duckdb_tsv("k\ts\n2\t\"\"\n1\ta\n"), hand)
    assert_equal(compare_canon(hand, duck).count(), 0)
    var total = _like("total", "k:int64\ts:string?", "1\ta\n2\t\n")
    var duck2 = duckdb_tsv_canon(parse_duckdb_tsv("k\ts\n2\t\"\"\n1\ta\n"), total)
    assert_true(compare_canon(total, duck2).count() > 0)


def test_unread_types_are_refused() raises:
    with assert_raises(contains="row 1 column d: this reader does not read type date32"):
        _ = _canon("d:date32", "d\n2026-09-01\n")
    with assert_raises(contains="this reader does not read type binary"):
        _ = _canon("b:binary?", "b\n\\xFF\n")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
