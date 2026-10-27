# Recorded reference answers and DuckDB's JSON output, on fixed text.
#
# What each test proves:
# - test_a_recorded_answer_round_trips_and_checks_values_without_an_engine: a
#   signature written with `format_reference` and read back with
#   `parse_references` still compares identical to the rows it came from (ints,
#   doubles, a text with a space and a non-ASCII byte, nulls), keeps its ORDER BY
#   keys, and a changed row no longer matches it.
# - test_a_reference_set_finds_answers_by_id_and_refuses_bad_records: lookup by
#   id, comments and blank lines between records, a repeated id, a record
#   with no end line, an unknown line and a column line of the wrong width are
#   refused.
# - test_json_rows_become_typed_cells: integers, doubles (with a point and with
#   an exponent), texts with every escape and a surrogate pair, booleans as 1
#   and 0, and null parse; the names are the first row's keys; an integer past
#   64 bits becomes a double.
# - test_json_output_edge_cases: no rows (`[]` and empty text) is an empty
#   result; a nested value, a row with a different key, trailing text and an
#   unterminated string are refused.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_bench_duckdb import (
    Cell,
    OrderKey,
    ReferenceAnswer,
    ResultSet,
    compare_signatures,
    format_reference,
    parse_json_rows,
    parse_references,
    signature_of,
)
from komira_bench_duckdb.cells import KIND_FLOAT, KIND_INT, KIND_NULL, KIND_TEXT


def _sample(last_int: Int) -> ResultSet:
    var rs = ResultSet()
    rs.names.append(String("n"))
    rs.names.append(String("x"))
    rs.names.append(String("t"))
    var texts = List[String]()
    texts.append(String("two words"))
    texts.append(String("caf") + chr(233))
    texts.append(String(""))
    for i in range(3):
        var row = List[Cell]()
        row.append(Cell.integer(Int64(10 + i * 5 if i < 2 else last_int)))
        if i == 1:
            row.append(Cell.null())
        else:
            row.append(Cell.real(0.1 * Float64(i + 1)))
        row.append(Cell.text(texts[i]))
        rs.add_row(row^)
    return rs^


def test_a_recorded_answer_round_trips_and_checks_values_without_an_engine() raises:
    var ans = ReferenceAnswer(String("q1"))
    ans.signature = signature_of(_sample(20))
    ans.order.append(OrderKey(0, True, True))
    ans.order.append(OrderKey(2))
    var text = format_reference(ans)
    var set = parse_references(text)
    assert_equal(len(set.answers), 1)
    var back = set.answers[0].copy()
    assert_equal(back.id, String("q1"))
    assert_equal(len(back.order), 2)
    assert_equal(back.order[0].column, 0)
    assert_true(back.order[0].descending)
    assert_true(back.order[0].nulls_first)
    assert_equal(back.order[1].column, 2)
    assert_false(back.order[1].descending)
    assert_false(back.order[1].nulls_first)
    assert_true(compare_signatures(signature_of(_sample(20)), back.signature).identical)
    assert_false(compare_signatures(signature_of(_sample(21)), back.signature).identical)
    # writing what was read gives the same text
    assert_equal(format_reference(back), text)


def _record(id: String) -> String:
    return (
        String("query ") + id + String("\nrows 0\ncolumn 0 0 0 0 3 0 0 0 0 0 0 0 0 0 x x\nend\n")
    )


def _refuses(text: String) -> Bool:
    try:
        _ = parse_references(text)
    except:
        return True
    return False


def test_a_reference_set_finds_answers_by_id_and_refuses_bad_records() raises:
    var text = String("# recorded answers\n\n") + _record(String("a")) + String("\n# next\n") + _record(String("b"))
    var set = parse_references(text)
    assert_equal(len(set.answers), 2)
    assert_equal(set.find(String("b")), 1)
    assert_equal(set.find(String("a")), 0)
    assert_equal(set.find(String("c")), -1)
    assert_true(_refuses(_record(String("a")) + _record(String("a"))))
    assert_true(_refuses(String("query a\nrows 0\n")))
    assert_true(_refuses(String("query a\nrows 0\nbogus 1\nend\n")))
    assert_true(_refuses(String("query a\nrows 0\ncolumn 1 2 3\nend\n")))
    assert_true(_refuses(String("rows 0\nend\n")))
    assert_true(_refuses(String("query a\nend\n")))


def test_json_rows_become_typed_cells() raises:
    var text = String(
        '[{"i":42,"f":1.5,"e":2e3,"s":"a\\"b\\\\c\\n\\t\\u00e9\\ud83d\\ude00","b":true,"c":false,"z":null,"big":123456789012345678901234567890},\n'
        '{"i":-7,"f":0.25,"e":1E-2,"s":"","b":false,"c":true,"z":null,"big":1}]\n'
    )
    var rs = parse_json_rows(text)
    assert_equal(rs.row_count(), 2)
    assert_equal(rs.names[0], String("i"))
    assert_equal(rs.names[7], String("big"))
    assert_equal(rs.rows[0][0].kind, KIND_INT)
    assert_equal(rs.rows[0][0].i, Int64(42))
    assert_equal(rs.rows[1][0].i, Int64(-7))
    assert_equal(rs.rows[0][1].kind, KIND_FLOAT)
    assert_equal(rs.rows[0][1].f, 1.5)
    assert_equal(rs.rows[0][2].kind, KIND_FLOAT)
    assert_equal(rs.rows[0][2].f, 2000.0)
    assert_equal(rs.rows[0][3].kind, KIND_TEXT)
    assert_equal(rs.rows[0][3].s, String("a\"b\\c\n\t") + chr(233) + chr(0x1F600))
    assert_equal(rs.rows[0][4].i, Int64(1))
    assert_equal(rs.rows[0][5].i, Int64(0))
    assert_equal(rs.rows[0][6].kind, KIND_NULL)
    assert_equal(rs.rows[0][7].kind, KIND_FLOAT)
    assert_equal(rs.rows[1][7].kind, KIND_INT)


def _json_refused(text: String) -> Bool:
    try:
        _ = parse_json_rows(text)
    except:
        return True
    return False


def test_json_output_edge_cases() raises:
    assert_equal(parse_json_rows(String("[]")).row_count(), 0)
    assert_equal(parse_json_rows(String("")).row_count(), 0)
    assert_equal(parse_json_rows(String("  \n")).column_count(), 0)
    assert_true(_json_refused(String('[{"a":[1,2]}]')))
    assert_true(_json_refused(String('[{"a":{"b":1}}]')))
    assert_true(_json_refused(String('[{"a":1},{"b":2}]')))
    assert_true(_json_refused(String('[{"a":1,"b":2},{"a":3}]')))
    assert_true(_json_refused(String('[{"a":1}] trailing')))
    assert_true(_json_refused(String('[{"a":"open}]')))
    assert_true(_json_refused(String('[{"a":}]')))
    assert_true(_json_refused(String('[{"a":nonsense}]')))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
