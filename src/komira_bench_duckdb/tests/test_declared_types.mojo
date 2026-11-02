# Declared column types: the mapping of DuckDB's type names onto the shared
# vocabulary and the comparison of the declared types of two results. Pure
# values: no engine, no process, no clock.
#
# What each test proves, and the defect it catches:
# - test_the_same_value_at_another_scale_fails_with_a_type_message: 123.45 at
#   DECIMAL(38,2) against DECIMAL(38,4) is not identical, the only failure is
#   the declared type, it is listed as a type failure and its message names the
#   column, the word "declared type" and both types. Catches a comparison that
#   passes by value alone.
# - test_equal_declared_types_and_values_pass: DECIMAL(38,4) on both sides with
#   the same value is identical, with no type failure. Catches a type check
#   that fails everything.
# - test_a_whole_number_as_bigint_against_decimal_18_0_fails: the integer 7 as
#   BIGINT against 7 as DECIMAL(18,0) fails on the type alone. Catches a
#   comparison that treats an integer and a scale-0 decimal as one type.
# - test_double_against_double_passes: DOUBLE on both sides with equal values
#   is identical.
# - test_an_unmapped_type_is_reported_not_passed: DuckDB's TIMESTAMP maps to no
#   vocabulary entry; the same unmapped type on both sides, or on one side
#   only, is a type failure that says the type is not in the mapping. Catches
#   an unknown type that compares equal to itself.
# - test_the_duckdb_names_map_onto_the_vocabulary: every name the README table
#   lists maps to its vocabulary entry; DECIMAL(p,s) is kept with its
#   precision and scale; names outside the table, and DECIMAL forms DuckDB
#   cannot have, are unmapped and keep the name they came with.
# - test_types_recorded_on_one_side_only_fail: an answer with declared types
#   against one with none fails with a message that says so; two answers
#   with none (built by hand) compare by value alone.
# - test_results_with_no_rows_compare_their_types_when_both_have_them: no rows
#   on both sides with different declared types fails, with equal ones passes,
#   and with the types on one side only passes (an engine that sends no batch
#   for an empty result has no schema to compare).
# - test_signature_of_keeps_the_declared_types: the signature carries the
#   types of the result, and refuses types that are not one per column.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_bench_duckdb import (
    Cell,
    ResultSet,
    ValueVerdict,
    compare_signatures,
    duckdb_declared_type,
    is_unmapped,
    signature_of,
)


def _typed_ints(ty: String, values: List[Int]) -> ResultSet:
    var rs = ResultSet()
    rs.names.append(String("v"))
    rs.types.append(ty)
    for v in values:
        var row = List[Cell]()
        row.append(Cell.integer(Int64(v)))
        rs.add_row(row^)
    return rs^


def _typed_decimals(ty: String, texts: List[String]) raises -> ResultSet:
    var rs = ResultSet()
    rs.names.append(String("v"))
    rs.types.append(ty)
    for t in texts:
        var row = List[Cell]()
        row.append(Cell.decimal(t))
        rs.add_row(row^)
    return rs^


def _typed_doubles(ty: String, values: List[Float64]) -> ResultSet:
    var rs = ResultSet()
    rs.names.append(String("v"))
    rs.types.append(ty)
    for v in values:
        var row = List[Cell]()
        row.append(Cell.real(v))
        rs.add_row(row^)
    return rs^


def _one_int() -> List[Int]:
    var out = List[Int]()
    out.append(7)
    return out^


def _one_decimal(text: String) -> List[String]:
    var out = List[String]()
    out.append(text)
    return out^


def _compare(a: ResultSet, b: ResultSet) raises -> ValueVerdict:
    return compare_signatures(signature_of(a), signature_of(b))


def test_the_same_value_at_another_scale_fails_with_a_type_message() raises:
    var two = _typed_decimals(String("DECIMAL(38,2)"), _one_decimal(String("123.45")))
    var four = _typed_decimals(String("DECIMAL(38,4)"), _one_decimal(String("123.4500")))
    var v = _compare(two, four)
    assert_false(v.identical, "a different scale is a different declared type")
    assert_equal(len(v.type_reasons), 1)
    assert_equal(len(v.reasons), 1, "the values are equal: the type is the only failure")
    ref why = v.type_reasons[0]
    assert_true(why.find(String("column 0")) >= 0, why)
    assert_true(why.find(String("declared type")) >= 0, why)
    assert_true(why.find(String("DECIMAL(38,2)")) >= 0, why)
    assert_true(why.find(String("DECIMAL(38,4)")) >= 0, why)
    assert_equal(v.reasons[0], why)


def test_equal_declared_types_and_values_pass() raises:
    var a = _typed_decimals(String("DECIMAL(38,4)"), _one_decimal(String("123.4500")))
    var b = _typed_decimals(String("DECIMAL(38,4)"), _one_decimal(String("123.45")))
    var v = _compare(a, b)
    assert_true(v.identical, v.label())
    assert_equal(len(v.type_reasons), 0)


def test_a_whole_number_as_bigint_against_decimal_18_0_fails() raises:
    var big = _typed_ints(String("BIGINT"), _one_int())
    var dec = _typed_ints(String("DECIMAL(18,0)"), _one_int())
    var v = _compare(big, dec)
    assert_false(v.identical)
    assert_equal(len(v.type_reasons), 1)
    assert_equal(len(v.reasons), 1, "equal whole values: only the type differs")
    assert_true(v.type_reasons[0].find(String("BIGINT")) >= 0, v.type_reasons[0])
    assert_true(v.type_reasons[0].find(String("DECIMAL(18,0)")) >= 0, v.type_reasons[0])
    var back = _compare(dec, big)
    assert_false(back.identical, "the other direction fails too")
    assert_equal(len(back.type_reasons), 1)


def test_double_against_double_passes() raises:
    var values = List[Float64]()
    values.append(1.5)
    values.append(2.25)
    var v = _compare(_typed_doubles(String("DOUBLE"), values), _typed_doubles(String("DOUBLE"), values))
    assert_true(v.identical, v.label())
    assert_equal(len(v.type_reasons), 0)


def test_an_unmapped_type_is_reported_not_passed() raises:
    var raw = String("TIMESTAMP")
    var mapped = duckdb_declared_type(raw)
    assert_true(is_unmapped(mapped), "TIMESTAMP is in no vocabulary entry: " + mapped)
    assert_true(mapped.find(raw) >= 0, "the unmapped entry keeps the name it came with: " + mapped)
    assert_false(is_unmapped(String("BIGINT")))
    var a = _typed_ints(mapped, _one_int())
    var b = _typed_ints(mapped, _one_int())
    var same = _compare(a, b)
    assert_false(same.identical, "an unmapped type never passes, even against itself")
    assert_true(len(same.type_reasons) >= 1)
    assert_true(same.type_reasons[0].find(String("not in the mapping")) >= 0, same.type_reasons[0])
    assert_true(same.type_reasons[0].find(raw) >= 0, same.type_reasons[0])
    var one_side = _compare(a, _typed_ints(String("BIGINT"), _one_int()))
    assert_false(one_side.identical)
    assert_true(one_side.type_reasons[0].find(String("not in the mapping")) >= 0, one_side.type_reasons[0])


def _maps(raw: String, want: String) -> Bool:
    var got = duckdb_declared_type(raw)
    return got == want and not is_unmapped(got)


def test_the_duckdb_names_map_onto_the_vocabulary() raises:
    var same = List[String]()
    for n in [
        "BOOLEAN", "TINYINT", "SMALLINT", "INTEGER", "BIGINT", "HUGEINT",
        "UTINYINT", "USMALLINT", "UINTEGER", "UBIGINT", "UHUGEINT",
        "FLOAT", "DOUBLE", "VARCHAR", "DATE",
    ]:
        same.append(String(n))
    for i in range(len(same)):
        assert_true(_maps(same[i], same[i]), same[i] + String(" maps to itself"))
    assert_true(_maps(String("DECIMAL(38,4)"), String("DECIMAL(38,4)")))
    assert_true(_maps(String("DECIMAL(1,0)"), String("DECIMAL(1,0)")))
    assert_true(_maps(String("DECIMAL(18,3)"), String("DECIMAL(18,3)")))
    assert_true(_maps(String("DECIMAL(38,38)"), String("DECIMAL(38,38)")))
    var unmapped = List[String]()
    for n in [
        "TIMESTAMP", "TIME", "BLOB", "INTERVAL", "UUID", "INTEGER[]", "STRUCT(a INTEGER)",
        "MAP(VARCHAR, INTEGER)", "DECIMAL(39,0)", "DECIMAL(0,0)", "DECIMAL(5,6)", "DECIMAL(10)",
        "DECIMAL(a,b)", "DECIMAL(10,2)[]", "DECIMAL(10,-1)", "bigint", "", "BIGINT ",
    ]:
        unmapped.append(String(n))
    for i in range(len(unmapped)):
        var got = duckdb_declared_type(unmapped[i])
        assert_true(is_unmapped(got), String("`") + unmapped[i] + String("` is unmapped, got: ") + got)
        assert_true(got.find(unmapped[i]) >= 0, "the name it came with is kept: " + got)


def test_types_recorded_on_one_side_only_fail() raises:
    var typed = _typed_ints(String("BIGINT"), _one_int())
    var bare = _typed_ints(String("BIGINT"), _one_int())
    bare.types = List[String]()
    var v = _compare(typed, bare)
    assert_false(v.identical)
    assert_equal(len(v.type_reasons), 1)
    assert_true(v.type_reasons[0].find(String("declared types")) >= 0, v.type_reasons[0])
    var w = _compare(bare, typed)
    assert_false(w.identical)
    assert_equal(len(w.type_reasons), 1)
    assert_true(_compare(bare, bare).identical, "two answers with no declared types compare by value")


def test_results_with_no_rows_compare_their_types_when_both_have_them() raises:
    var empty_big = ResultSet()
    empty_big.types.append(String("BIGINT"))
    var empty_int = ResultSet()
    empty_int.types.append(String("INTEGER"))
    var untyped = ResultSet()
    var differ = _compare(empty_big, empty_int)
    assert_false(differ.identical)
    assert_equal(len(differ.type_reasons), 1)
    assert_true(_compare(empty_big, empty_big).identical)
    assert_true(_compare(empty_big, untyped).identical)
    assert_true(_compare(untyped, empty_int).identical)


def test_signature_of_keeps_the_declared_types() raises:
    var rs = _typed_decimals(String("DECIMAL(15,2)"), _one_decimal(String("1.5")))
    var sig = signature_of(rs)
    assert_equal(len(sig.types), 1)
    assert_equal(sig.types[0], String("DECIMAL(15,2)"))
    var wrong = _typed_ints(String("BIGINT"), _one_int())
    wrong.types.append(String("DOUBLE"))
    var raised = False
    try:
        _ = signature_of(wrong)
    except e:
        raised = True
        assert_true(String(e).find(String("declared types")) >= 0, String(e))
    assert_true(raised, "two types for one column are refused")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
