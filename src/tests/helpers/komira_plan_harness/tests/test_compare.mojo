# Comparison under the expected file's policy, and the parser's refusals.
#
# Defects these catch: `order: total` compared as a multiset (swapped rows
# pass); comparison that stops at the first mismatch (the report holds one
# entry where there are several); a multiset compare that cascades after one
# missing row; key ties compared positionally; a schema or row-count
# difference going unreported; a malformed expected file being read
# anyway.

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field

from komira_plan_harness import (
    CanonPolicy,
    FloatTolerance,
    check_batch,
    compare_canon,
    parse_canon,
    render_batch,
)
from komira_plan_harness.fixtures import (
    BatchBuilder,
    all_valid,
    fixed_column,
    ints,
    string_column,
)


def _doc(order: String, schema: String, rows: String) -> String:
    return (
        String("#! komira-plan-conformance v1\n#  order: ") + order
        + "\n#  float: ulps=0\n" + schema + "\n" + rows
    )


def _cmp(order: String, schema: String, e_rows: String, a_rows: String) raises -> Int:
    var e = parse_canon(_doc(order, schema, e_rows))
    var a = parse_canon(_doc(order, schema, a_rows))
    return compare_canon(e, a).count()


def test_total_order_is_positional() raises:
    var s = String("k:int32\tv:string")
    assert_equal(_cmp("total", s, "1\ta\n2\tb\n", "1\ta\n2\tb\n"), 0)
    # The same rows swapped: four differing cells, not a pass.
    var e = parse_canon(_doc("total", s, "1\ta\n2\tb\n"))
    var a = parse_canon(_doc("total", s, "2\tb\n1\ta\n"))
    var report = compare_canon(e, a)
    assert_equal(report.count(), 4)
    assert_equal(report.count_of("cell"), 4)


def test_every_mismatch_is_reported() raises:
    var s = String("k:int32\tv:string\tw:bool")
    var e = parse_canon(_doc("total", s, "1\ta\ttrue\n2\tb\tfalse\n3\tc\ttrue\n"))
    var a = parse_canon(_doc("total", s, "1\tX\ttrue\n2\tb\ttrue\n9\tc\ttrue\n"))
    var report = compare_canon(e, a)
    assert_equal(report.count(), 3)
    ref m0 = report.mismatches[0]
    assert_equal(m0.kind, "cell")
    assert_equal(m0.row, 0)
    assert_equal(m0.column, "v")
    assert_equal(m0.expected, "a")
    assert_equal(m0.actual, "X")
    assert_equal(report.mismatches[1].row, 1)
    assert_equal(report.mismatches[1].column, "w")
    assert_equal(report.mismatches[2].row, 2)
    assert_equal(report.mismatches[2].column, "k")
    assert_equal(report.mismatches[2].expected, "3")
    assert_equal(report.mismatches[2].actual, "9")
    var text = String(report)
    assert_true(text.startswith("3 mismatch(es)"))
    assert_true(text.find("cell row 2 column k: expected [3] actual [9]") >= 0)


def test_row_count_and_extra_rows() raises:
    var s = String("k:int32")
    var e = parse_canon(_doc("total", s, "1\n2\n"))
    var a = parse_canon(_doc("total", s, "1\n2\n3\n4\n"))
    var report = compare_canon(e, a)
    assert_equal(report.count_of("row_count"), 1)
    assert_equal(report.count_of("extra_row"), 2)
    assert_equal(report.count(), 3)


def test_unordered_is_a_multiset() raises:
    var s = String("k:int32\tv:string")
    assert_equal(_cmp("none", s, "1\ta\n2\tb\n2\tb\n", "2\tb\n1\ta\n2\tb\n"), 0)
    # Multiplicity counts.
    var e = parse_canon(_doc("none", s, "1\ta\n2\tb\n2\tb\n"))
    var a = parse_canon(_doc("none", s, "1\ta\n1\ta\n2\tb\n"))
    var report = compare_canon(e, a)
    assert_equal(report.count_of("missing_row"), 1)
    assert_equal(report.count_of("extra_row"), 1)
    # One row missing is one report, not a cascade over the rows after it.
    var e2 = parse_canon(_doc("none", s, "1\ta\n2\tb\n3\tc\n4\td\n5\te\n"))
    var a2 = parse_canon(_doc("none", s, "5\te\n4\td\n3\tc\n1\ta\n"))
    var r2 = compare_canon(e2, a2)
    assert_equal(r2.count(), 2)
    assert_equal(r2.count_of("row_count"), 1)
    assert_equal(r2.count_of("missing_row"), 1)
    assert_equal(r2.mismatches[1].row, 1)


def test_keys_order_with_ties() raises:
    var s = String("k:int32\tv:string")
    # Rows that tie on the key may come in any order ...
    assert_equal(_cmp("keys=k", s, "1\tx\n1\ty\n2\tz\n", "1\ty\n1\tx\n2\tz\n"), 0)
    # ... but the key projection is ordered.
    var e = parse_canon(_doc("keys=k", s, "1\tx\n1\ty\n2\tz\n"))
    var a = parse_canon(_doc("keys=k", s, "2\tz\n1\tx\n1\ty\n"))
    var report = compare_canon(e, a)
    assert_true(report.count_of("key") >= 2)
    # A row moving between tie groups is caught even when keys still agree.
    assert_true(_cmp("keys=k", s, "1\tx\n2\ty\n", "1\ty\n2\tx\n") > 0)


def test_schema_mismatch_is_reported() raises:
    var e = parse_canon(_doc("total", "a:int32\tb:string?", "1\tx\n"))
    var a = parse_canon(_doc("total", "a:int32?\tb:string?", "1\tx\n"))
    var report = compare_canon(e, a)
    assert_equal(report.count(), 1)
    assert_equal(report.mismatches[0].kind, "schema")
    assert_equal(report.mismatches[0].column, "a")
    var a3 = parse_canon(_doc("total", "a:int32", "1\n"))
    var r3 = compare_canon(e, a3)
    assert_equal(r3.count_of("schema"), 1)


def test_column_tolerance_override() raises:
    var text = String(
        "#! komira-plan-conformance v1\n#  order: total\n#  float: ulps=0\n"
        "#  float[y]: ulps=1\n# derivation: y is a sum, so one ulp is allowed\n"
        "x:float64\ty:float64\n1.0\t1.0\n"
    )
    var e = parse_canon(text)
    var a = parse_canon(
        _doc("total", "x:float64\ty:float64", "1.0\t1.0000000000000002|0x3FF0000000000001\n")
    )
    assert_true(compare_canon(e, a).ok())
    var a2 = parse_canon(
        _doc("total", "x:float64\ty:float64", "1.0000000000000002|0x3FF0000000000001\t1.0\n")
    )
    assert_equal(compare_canon(e, a2).count(), 1)
    # The text form keeps the override.
    assert_true(e.to_text().find("#  float[y]: ulps=1\n") >= 0)


def test_policy_from_the_api_matches_the_text() raises:
    var keys: List[String] = ["k"]
    var p = CanonPolicy.keyed(keys)
    p.set_column_tolerance("v", FloatTolerance.parse("rel=1e-9"))
    var bb = BatchBuilder()
    var k: List[Int] = [1]
    bb.add(Field("k", ArrowType.INT32, False), fixed_column(ArrowType.INT32, 4, ints(k), all_valid(1)))
    var v: List[UInt64] = [0x3FF0000000000000]
    bb.add(Field("v", ArrowType.FLOAT64, False), fixed_column(ArrowType.FLOAT64, 8, v, all_valid(1)))
    var got = render_batch(bb.build(), p^)
    assert_equal(
        got.to_text(),
        "#! komira-plan-conformance v1\n#  order: keys=k\n#  float: ulps=0\n"
        "#  float[v]: rel=1e-9\nk:int32\tv:float64\n1\t1.0|0x3FF0000000000000\n",
    )


def test_malformed_expected_files_are_refused() raises:
    with assert_raises(contains="the first line must be"):
        _ = parse_canon("k:int32\n1\n")
    with assert_raises(contains="needs both an order line and a float line"):
        _ = parse_canon("#! komira-plan-conformance v1\n#  order: total\nk:int32\n")
    with assert_raises(contains="is not total, none or keys"):
        _ = parse_canon(_doc("sorted", "k:int32", ""))
    with assert_raises(contains="names 0 columns"):
        _ = parse_canon(_doc("keys=z", "k:int32", ""))
    with assert_raises(contains="has 2 cells, the schema 1"):
        _ = parse_canon(_doc("total", "k:int32", "1\t2\n"))
    with assert_raises(contains="holds \\N inside a value"):
        _ = parse_canon(_doc("total", "s:string", "a\\Nb\n"))
    with assert_raises(contains="unknown escape"):
        _ = parse_canon(_doc("total", "s:string", "a\\qb\n"))
    with assert_raises(contains="raw CR"):
        _ = parse_canon(_doc("total", "s:string", "a\r\n"))
    with assert_raises(contains="line 5 column x"):
        _ = parse_canon(_doc("total", "x:float64", "0.1\n"))
    with assert_raises(contains="names no float column"):
        _ = parse_canon(
            "#! komira-plan-conformance v1\n#  order: total\n#  float: ulps=0\n"
            "#  float[k]: ulps=1\nk:int32\n"
        )


def test_check_batch_end_to_end() raises:
    var bb = BatchBuilder()
    var k: List[Int] = [2, 1]
    var valid: List[Bool] = [True, False]
    bb.add(Field("k", ArrowType.INT64, True), fixed_column(ArrowType.INT64, 8, ints(k), valid))
    var vs: List[String] = ["b", "a"]
    bb.add(Field("v", ArrowType.STRING, False), string_column(vs, all_valid(2)))
    var batch = bb.build()
    var expected = String(
        "#! komira-plan-conformance v1\n#  order: none\n#  float: ulps=0\n"
        "k:int64?\tv:string\n\\N\ta\n2\tb\n"
    )
    assert_true(check_batch(expected, batch).ok())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
