# The one allowed departure from "the same result as DuckDB": DuckDB's HUGEINT
# against the komira engine's DECIMAL(38,0), because Arrow has no 128-bit
# integer. Pure values: no engine, no process, no clock.
#
# What each test proves, and the defect it catches:
# - test_hugeint_against_decimal_38_0_with_equal_values_is_a_departure: a
#   HUGEINT column read from DuckDB's JSON (small values and a value of 38
#   digits) against the same values as DECIMAL(38,0) is not a failure; its label
#   is DEPARTURE with the reason "Arrow has no 128-bit integer: HUGEINT as
#   DECIMAL(38,0)", in both directions, and it is not IDENTICAL. Catches a
#   comparison that fails the pair, and one that passes it unlabelled.
# - test_hugeint_against_decimal_38_0_with_unequal_values_fails: one value a
#   unit apart is DIVERGENT and never a DEPARTURE. Catches a departure that
#   hides a value difference.
# - test_hugeint_against_int64_fails_by_type: HUGEINT against BIGINT with equal
#   small values fails and names both types: INT64 can overflow where HUGEINT
#   does not.
# - test_decimal_38_0_against_decimal_38_0_is_plainly_identical: the same type
#   on both sides is IDENTICAL, with no departure.
# - test_every_other_type_pair_still_fails_by_name: UHUGEINT against
#   DECIMAL(38,0), HUGEINT against DECIMAL(37,0), DECIMAL(38,1) and UHUGEINT,
#   and DECIMAL(38,0) against BIGINT each fail on the declared type, naming it.
#   Catches a departure rule wider than its table.
# - test_the_departure_table_has_one_entry: the table lists HUGEINT against
#   DECIMAL(38,0) with the reason and nothing else; the lookup answers in both
#   directions and refuses HUGEINT against BIGINT and UHUGEINT against
#   DECIMAL(38,0).
# - test_a_stored_reference_keeps_the_departure: a HUGEINT answer written with
#   format_reference and read back with parse_references still compares as a
#   DEPARTURE against DECIMAL(38,0), and as a failure when a value differs.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_bench_duckdb import (
    Cell,
    ReferenceAnswer,
    ResultSet,
    ValueVerdict,
    allowed_departures,
    compare_signatures,
    departure_reason,
    format_reference,
    parse_json_rows,
    parse_references,
    signature_of,
)

comptime _REASON: String = "Arrow has no 128-bit integer: HUGEINT as DECIMAL(38,0)"
comptime _NINES: String = "99999999999999999999999999999999999999"
comptime _EIGHTS: String = "99999999999999999999999999999999999998"


def _types(ty: String) -> List[String]:
    var out = List[String]()
    out.append(ty)
    return out^


def _duckdb_side(ty: String, values: List[String]) raises -> ResultSet:
    """The rows DuckDB's JSON gives for one column of type `ty`: every value is
    quoted, as DuckDB's shell quotes a HUGEINT or a DECIMAL."""
    var json = String("[")
    for i in range(len(values)):
        if i > 0:
            json += String(",")
        json += String('{"v":"') + values[i] + String('"}')
    json += String("]")
    var rs = parse_json_rows(json, _types(ty))
    rs.types = _types(ty)
    return rs^


def _komira_decimals(ty: String, values: List[String]) raises -> ResultSet:
    var rs = ResultSet()
    rs.names.append(String("v"))
    rs.types.append(ty)
    for t in values:
        var row = List[Cell]()
        row.append(Cell.decimal(t))
        rs.add_row(row^)
    return rs^


def _komira_ints(ty: String, values: List[Int]) -> ResultSet:
    var rs = ResultSet()
    rs.names.append(String("v"))
    rs.types.append(ty)
    for v in values:
        var row = List[Cell]()
        row.append(Cell.integer(Int64(v)))
        rs.add_row(row^)
    return rs^


def _values() -> List[String]:
    var out = List[String]()
    out.append(String("5"))
    out.append(String("-7"))
    out.append(String("9223372036854775808"))
    out.append(String(_NINES))
    return out^


def _values_one_apart() -> List[String]:
    var out = List[String]()
    out.append(String("5"))
    out.append(String("-7"))
    out.append(String("9223372036854775808"))
    out.append(String(_EIGHTS))
    return out^


def _compare(a: ResultSet, b: ResultSet) raises -> ValueVerdict:
    return compare_signatures(signature_of(a), signature_of(b))


def test_hugeint_against_decimal_38_0_with_equal_values_is_a_departure() raises:
    var duck = _duckdb_side(String("HUGEINT"), _values())
    var komira = _komira_decimals(String("DECIMAL(38,0)"), _values())
    for pair in range(2):
        var v = _compare(komira, duck) if pair == 0 else _compare(duck, komira)
        assert_true(v.identical, v.label())
        assert_equal(len(v.reasons), 0)
        assert_equal(v.label(), String("DEPARTURE: ") + String(_REASON))
        assert_true(v.label() != String("IDENTICAL"))


def test_hugeint_against_decimal_38_0_with_unequal_values_fails() raises:
    var duck = _duckdb_side(String("HUGEINT"), _values())
    var komira = _komira_decimals(String("DECIMAL(38,0)"), _values_one_apart())
    var v = _compare(komira, duck)
    assert_false(v.identical)
    assert_true(v.label().startswith(String("DIVERGENT")), v.label())
    assert_true(v.label().find(String("DEPARTURE")) < 0, v.label())
    var back = _compare(duck, komira)
    assert_false(back.identical)
    assert_true(back.label().startswith(String("DIVERGENT")), back.label())


def test_hugeint_against_int64_fails_by_type() raises:
    var small = List[Int]()
    small.append(5)
    small.append(-7)
    var small_text = List[String]()
    small_text.append(String("5"))
    small_text.append(String("-7"))
    var duck = _duckdb_side(String("HUGEINT"), small_text)
    var komira = _komira_ints(String("BIGINT"), small)
    for pair in range(2):
        var v = _compare(komira, duck) if pair == 0 else _compare(duck, komira)
        assert_false(v.identical)
        assert_true(len(v.type_reasons) >= 1)
        assert_true(v.type_reasons[0].find(String("HUGEINT")) >= 0, v.type_reasons[0])
        assert_true(v.type_reasons[0].find(String("BIGINT")) >= 0, v.type_reasons[0])
        assert_true(v.label().startswith(String("DIVERGENT")), v.label())


def test_decimal_38_0_against_decimal_38_0_is_plainly_identical() raises:
    var a = _komira_decimals(String("DECIMAL(38,0)"), _values())
    var b = _duckdb_side(String("DECIMAL(38,0)"), _values())
    var v = _compare(a, b)
    assert_true(v.identical, v.label())
    assert_equal(v.label(), String("IDENTICAL"))


def _fails_naming(duck: ResultSet, komira: ResultSet, first: String, second: String) raises:
    for pair in range(2):
        var v = _compare(komira, duck) if pair == 0 else _compare(duck, komira)
        assert_false(v.identical, first + String(" against ") + second)
        assert_true(len(v.type_reasons) >= 1, first + String(" against ") + second)
        assert_true(v.type_reasons[0].find(first) >= 0, v.type_reasons[0])
        assert_true(v.type_reasons[0].find(second) >= 0, v.type_reasons[0])
        assert_true(v.label().startswith(String("DIVERGENT")), v.label())


def test_every_other_type_pair_still_fails_by_name() raises:
    var one = List[String]()
    one.append(String("5"))
    var one_int = List[Int]()
    one_int.append(5)
    _fails_naming(
        _duckdb_side(String("UHUGEINT"), one), _komira_decimals(String("DECIMAL(38,0)"), one),
        String("UHUGEINT"), String("DECIMAL(38,0)"),
    )
    _fails_naming(
        _duckdb_side(String("HUGEINT"), one), _komira_decimals(String("DECIMAL(37,0)"), one),
        String("HUGEINT"), String("DECIMAL(37,0)"),
    )
    _fails_naming(
        _duckdb_side(String("HUGEINT"), one), _komira_decimals(String("DECIMAL(38,1)"), one),
        String("HUGEINT"), String("DECIMAL(38,1)"),
    )
    _fails_naming(
        _duckdb_side(String("HUGEINT"), one), _komira_decimals(String("UHUGEINT"), one),
        String("HUGEINT"), String("UHUGEINT"),
    )
    _fails_naming(
        _duckdb_side(String("DECIMAL(38,0)"), one), _komira_ints(String("BIGINT"), one_int),
        String("DECIMAL(38,0)"), String("BIGINT"),
    )


def test_a_stored_reference_keeps_the_departure() raises:
    var duck = _duckdb_side(String("HUGEINT"), _values())
    var ans = ReferenceAnswer(String("q"))
    ans.signature = signature_of(duck)
    var text = format_reference(ans)
    var back = parse_references(text).answers[0].copy()
    assert_equal(back.signature.types[0], String("HUGEINT"))
    var komira = _komira_decimals(String("DECIMAL(38,0)"), _values())
    var v = compare_signatures(signature_of(komira), back.signature)
    assert_true(v.identical, v.label())
    assert_equal(v.label(), String("DEPARTURE: ") + String(_REASON))
    var other = _komira_decimals(String("DECIMAL(38,0)"), _values_one_apart())
    var w = compare_signatures(signature_of(other), back.signature)
    assert_false(w.identical)
    assert_true(w.label().startswith(String("DIVERGENT")), w.label())


def test_the_departure_table_has_one_entry() raises:
    var table = allowed_departures()
    assert_equal(len(table), 1)
    assert_equal(table[0].duckdb, String("HUGEINT"))
    assert_equal(table[0].komira, String("DECIMAL(38,0)"))
    assert_equal(table[0].reason, String(_REASON))
    var either = departure_reason(String("DECIMAL(38,0)"), String("HUGEINT"))
    assert_true(Bool(either))
    assert_equal(either.value(), String(_REASON))
    assert_true(Bool(departure_reason(String("HUGEINT"), String("DECIMAL(38,0)"))))
    assert_false(Bool(departure_reason(String("HUGEINT"), String("BIGINT"))))
    assert_false(Bool(departure_reason(String("UHUGEINT"), String("DECIMAL(38,0)"))))
    assert_false(Bool(departure_reason(String("HUGEINT"), String("HUGEINT"))))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
