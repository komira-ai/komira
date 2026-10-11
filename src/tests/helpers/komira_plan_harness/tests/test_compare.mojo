# Comparison under the expected file's policy, and the parser's refusals.
#
# Defects these catch: `order: total` compared as a multiset (swapped rows
# pass); comparison that stops at the first mismatch (the report holds one
# entry where there are several); a multiset compare that cascades after one
# missing row; key ties compared positionally; a schema or row-count
# difference going unreported; a malformed expected file being read
# anyway; a `\xHH` escape of well-formed UTF-8 or a nested float in
# lower-case or short bits accepted (cells no result can match); the
# first-fit search run when the sorted walk is already exact.

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


def test_escapes_canon_does_not_write_are_refused() raises:
    with assert_raises(contains="escape canon does not write"):
        _ = parse_canon(_doc("total", "s:string", "\\x41\n"))
    with assert_raises(contains="escape canon does not write"):
        _ = parse_canon(_doc("total", "s:string", "\\xFF\n"))
    with assert_raises(contains="escape canon does not write"):
        _ = parse_canon(_doc("total", "s:string", "\\x09\n"))
    assert_equal(parse_canon(_doc("total", "s:string", "\\xff\\x01\n")).num_rows(), 1)


def test_nested_cells_are_checked() raises:
    var s = String("l:list<string>")
    assert_equal(parse_canon(_doc("total", s, "[\\N,a\\,b,\\\\N]\n")).num_rows(), 1)
    assert_equal(parse_canon(_doc("total", s, "\\N\n")).num_rows(), 1)
    with assert_raises(contains="unclosed bracket"):
        _ = parse_canon(_doc("total", s, "[1,2\n"))
    with assert_raises(contains="mismatched bracket"):
        _ = parse_canon(_doc("total", s, "[1}\n"))
    with assert_raises(contains="text after its value"):
        _ = parse_canon(_doc("total", s, "[1]x\n"))
    with assert_raises(contains="not \\N or a bracketed value"):
        _ = parse_canon(_doc("total", s, "1\n"))
    with assert_raises(contains="holds \\N inside a value"):
        _ = parse_canon(_doc("total", s, "[a\\Nb]\n"))
    with assert_raises(contains="unknown escape"):
        _ = parse_canon(_doc("total", s, "[a\\qb]\n"))
    with assert_raises(contains="escape canon does not write"):
        _ = parse_canon(_doc("total", s, "[\\x41]\n"))


def test_float_against_text_column_is_compared_as_text() raises:
    var e = parse_canon(_doc("total", "x:float64", "1.0\n"))
    var a = parse_canon(_doc("total", "x:string", "abc\n"))
    var report = compare_canon(e, a)
    assert_equal(report.count_of("schema"), 1)
    assert_equal(report.count_of("cell"), 1)


def test_unordered_pairs_what_the_sorted_walk_misses() raises:
    # Sorted, the bare NaN goes last and NaN|..01 pairs against ..00 first;
    # the search after the walk pairs the rest.
    var s = String("x:float64")
    var e = parse_canon(_doc("none", s, "NaN\nNaN|0x7FF8000000000001\n"))
    var a = parse_canon(_doc("none", s, "NaN|0x7FF8000000000000\nNaN|0x7FF8000000000001\n"))
    var report = compare_canon(e, a)
    if not report.ok():
        raise Error(String(report))


def test_hex_escapes_of_well_formed_utf8_are_refused() raises:
    """Canon writes a byte >= 0x80 as `\\xHH` only when the bytes from it on
    are not well-formed UTF-8; `\\xc3\\xa9` is the text of `é`, which canon
    writes raw, so a file that escapes it holds a cell no result can match."""
    var s = String("s:string")
    var refused: List[String] = ["\\xc3\\xa9", "a\\xe2\\x82\\xacb", "\\xf0\\x9f\\x98\\x80"]
    for cell in refused:
        with assert_raises(contains="escape canon does not write"):
            _ = parse_canon(_doc("total", s, cell + "\n"))
    with assert_raises(contains="escape canon does not write"):
        _ = parse_canon(_doc("total", "l:list<string>", "[\\xc3\\xa9]\n"))
    # Escapes canon does write: a lead byte without its continuation, a lone
    # continuation byte, a lead byte followed by a raw character.
    var kept: List[String] = ["\\xc3A", "\\xc3\\xc3", "\\xa9", "\\xe2\\x82A", "\\xc3é", "\\xed\\xa0\\x80"]
    for cell in kept:
        assert_equal(parse_canon(_doc("total", s, cell + "\n")).num_rows(), 1)


def test_nested_float_bits_are_canons_spelling() raises:
    """A float inside a nested value is `0x` and upper-case hex digits of its
    width (or NaN); `0x3ff0...` is never canon's text, so it is refused, in
    every nested layout. A string leaf that reads like bits is not a float."""
    var bad: List[List[String]] = [
        ["l:list<float64>", "[0x3ff0000000000000]"],
        ["l:list<float64>", "[0x3FF0]"],
        ["l:fixed_size_list(2)<float32>", "[\\N,0x3f800000]"],
        ["st:struct<a:string,b:float32>", "{a:0xab,b:0x3f800000}"],
        ["m:map<string,float16>", "{0xab:0x3c00}"],
        ["u:union_sparse(5,7)<float64,string>", "(5:0x3ff0000000000000)"],
        ["l:list<dictionary<int32,float32>>", "[0x3f800000]"],
        ["l:list<list<float64>>", "[[0x3FF0000000000000],[0x3ff0000000000000]]"],
    ]
    for c in bad:
        with assert_raises(contains="nested float"):
            _ = parse_canon(_doc("total", c[0], c[1] + "\n"))
    var good: List[List[String]] = [
        ["l:list<float64>", "[0x3FF0000000000000,NaN,\\N]"],
        ["l:list<string>", "[0x3ff0]"],
        ["st:struct<a:string,b:float32>", "{a:0xab,b:0x3F800000}"],
        ["m:map<string,float16>", "{0xab:0x3C00}"],
        ["u:union_sparse(5,7)<float64,string>", "(7:0xab)"],
        ["l:list<list<float64>>?", "[[0x3FF0000000000000],[]]"],
    ]
    for c in good:
        assert_equal(parse_canon(_doc("total", c[0], c[1] + "\n")).num_rows(), 1)


def test_exact_multiset_skips_the_first_fit_search() raises:
    """With no tolerance and no bare NaN the sorted walk is exact, so the
    first-fit search (O(missing x extra)) must not run: 40 missing and 40
    extra rows are 80 reports and zero probes. Under a tolerance it runs."""
    var e_rows = String()
    var a_rows = String()
    for r in range(40):
        e_rows += String(r) + "\n"
        a_rows += String(r + 100) + "\n"
    var e = parse_canon(_doc("none", "k:int32", e_rows))
    var a = parse_canon(_doc("none", "k:int32", a_rows))
    var report = compare_canon(e, a)
    assert_equal(report.count(), 80)
    assert_equal(report.first_fit_probes, 0)
    # ulps=1: the walk leaves 1.0 and 2.0 unpaired and the search must run
    # (a tolerance can make rows match that sort apart).
    var tol = String(
        "#! komira-plan-conformance v1\n#  order: none\n#  float: ulps=1\nx:float64\n"
    )
    var tr = compare_canon(parse_canon(tol + "1.0\n"), parse_canon(tol + "2.0\n"))
    assert_equal(tr.count(), 2)
    assert_true(tr.first_fit_probes > 0)


def test_rel_tolerance_runs_the_first_fit_search() raises:
    """A `rel=` tolerance (ulps stays 0) also makes the walk inexact. Sorted,
    expected is (1.0,b),(1.0625,a) and actual (1.0,a),(1.0625,b): the walk
    pairs (1.0,b) with (1.0625,b) under rel=0.1 and leaves (1.0625,a) and
    (1.0,a) unpaired, which match only under the tolerance. The search must
    pair them; skipping it reports a missing and an extra row."""
    var head = String(
        "#! komira-plan-conformance v1\n#  order: none\n#  float: rel=0.1\nx:float64\ts:string\n"
    )
    var e = parse_canon(head + "1.0\tb\n1.0625\ta\n")
    var a = parse_canon(head + "1.0625\tb\n1.0\ta\n")
    var report = compare_canon(e, a)
    if not report.ok():
        raise Error(String(report))
    assert_true(report.first_fit_probes > 0)


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
