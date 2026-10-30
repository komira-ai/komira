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
# - test_a_recorded_answer_keeps_large_non_finite_and_exact_values: sums that
#   overflowed to infinity, 0.1+0.2 and 1e-300 as double sums, integers whose
#   64-bit sums wrap, and the hash sum of a text column come back from the
#   recorded text bit for bit and compare identical.
# - test_a_record_without_a_format_line_is_refused: a record in the layout
#   written before the exact DECIMAL kind existed (no format line) is refused
#   with a message that names the format, instead of being read as a record of
#   the current layout; a record naming another format is refused too.
# - test_json_rows_become_typed_cells: integers, doubles (with a point and with
#   an exponent), texts with every escape and a surrogate pair, booleans as 1
#   and 0, and null parse; the names are the first row's keys; an integer past
#   64 bits becomes a double.
# - test_json_integers_at_the_64_bit_boundaries: 9223372036854775807 and
#   -9223372036854775808 stay integers, 9223372036854775808,
#   -9223372036854775809 and 18446744073709551615 become doubles, and none of
#   them wraps.
# - test_json_non_finite_words_and_malformed_numbers: NaN, Infinity and
#   -Infinity are doubles, the same words quoted are texts, and `1.2.3`,
#   `12x`, `1e`, `-`, `1.` and `--1` are refused.
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


def test_a_recorded_answer_keeps_large_non_finite_and_exact_values() raises:
    var rs = ResultSet()
    rs.names.append(String("big"))
    rs.names.append(String("f"))
    rs.names.append(String("k"))
    rs.names.append(String("t"))
    var ints = List[Int]()
    ints.append(4_611_686_018_427_387_904)
    ints.append(9_223_372_036_854_775_807)
    ints.append(-3)
    var floats = List[Float64]()
    floats.append(1.0e200)
    floats.append(0.1 + 0.2)
    floats.append(1.0e-300)
    var texts = List[String]()
    texts.append(String("aa"))
    texts.append(String("bc"))
    texts.append(String("zz"))
    for i in range(3):
        var row = List[Cell]()
        row.append(Cell.real(floats[i]))
        row.append(Cell.real(floats[(i + 1) % 3]))
        row.append(Cell.integer(Int64(ints[i])))
        row.append(Cell.text(texts[i]))
        rs.add_row(row^)
    var original = signature_of(rs)
    var ans = ReferenceAnswer(String("q"))
    ans.signature = original.copy()
    var text = format_reference(ans)
    var back = parse_references(text).answers[0].copy()
    assert_true(compare_signatures(original, back.signature).identical)
    assert_equal(back.signature.columns[0].sumsq, original.columns[0].sumsq)
    assert_equal(back.signature.columns[1].sum, original.columns[1].sum)
    assert_equal(back.signature.columns[1].min_v, 1.0e-300)
    assert_equal(back.signature.columns[2].isum, original.columns[2].isum)
    assert_equal(back.signature.columns[2].isumsq, original.columns[2].isumsq)
    assert_equal(back.signature.columns[3].text_hash, original.columns[3].text_hash)
    assert_true(original.columns[3].text_hash != Int64(0))
    assert_equal(format_reference(back), text)
    # the 0.1+0.2 sum survives as the very same double
    var one = ResultSet()
    one.names.append(String("v"))
    var cell = List[Cell]()
    cell.append(Cell.real(0.1 + 0.2))
    one.add_row(cell^)
    var rec = ReferenceAnswer(String("p"))
    rec.signature = signature_of(one)
    var again = parse_references(format_reference(rec)).answers[0].copy()
    assert_equal(again.signature.columns[0].sum, 0.1 + 0.2)


def test_json_integers_at_the_64_bit_boundaries() raises:
    var rs = parse_json_rows(
        String(
            '[{"a":9223372036854775807,"b":-9223372036854775808,"c":9223372036854775808,'
            '"d":-9223372036854775809,"e":18446744073709551615,"f":0,"g":-0,"h":9223372036854775806}]'
        )
    )
    assert_equal(rs.rows[0][0].kind, KIND_INT)
    assert_equal(rs.rows[0][0].i, Int64(9223372036854775807))
    assert_equal(rs.rows[0][1].kind, KIND_INT)
    assert_equal(rs.rows[0][1].i, Int64(-9223372036854775807) - Int64(1))
    assert_equal(rs.rows[0][2].kind, KIND_FLOAT)
    assert_true(rs.rows[0][2].f > 9.2e18 and rs.rows[0][2].f < 9.3e18)
    assert_equal(rs.rows[0][3].kind, KIND_FLOAT)
    assert_true(rs.rows[0][3].f < -9.2e18 and rs.rows[0][3].f > -9.3e18)
    assert_equal(rs.rows[0][4].kind, KIND_FLOAT)
    assert_true(rs.rows[0][4].f > 1.8e19 and rs.rows[0][4].f < 1.9e19)
    assert_equal(rs.rows[0][5].i, Int64(0))
    assert_equal(rs.rows[0][6].i, Int64(0))
    assert_equal(rs.rows[0][7].i, Int64(9223372036854775806))


def test_json_non_finite_words_and_malformed_numbers() raises:
    var rs = parse_json_rows(String('[{"a":NaN,"b":Infinity,"c":-Infinity,"d":"NaN","e":inf,"f":-inf,"g":nan}]'))
    assert_equal(rs.rows[0][0].kind, KIND_FLOAT)
    assert_true(rs.rows[0][0].f != rs.rows[0][0].f)
    assert_equal(rs.rows[0][1].kind, KIND_FLOAT)
    var infinity = Float64.MAX * 2.0
    assert_true(rs.rows[0][1].f == infinity)
    assert_true(rs.rows[0][2].f == -infinity)
    assert_equal(rs.rows[0][3].kind, KIND_TEXT)
    assert_true(rs.rows[0][4].f == infinity)
    assert_true(rs.rows[0][5].f == -infinity)
    assert_true(rs.rows[0][6].f != rs.rows[0][6].f)
    assert_true(_json_refused(String('[{"a":1.2.3}]')))
    assert_true(_json_refused(String('[{"a":12x}]')))
    assert_true(_json_refused(String('[{"a":1e}]')))
    assert_true(_json_refused(String('[{"a":-}]')))
    assert_true(_json_refused(String('[{"a":1.}]')))
    assert_true(_json_refused(String('[{"a":--1}]')))


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


def test_a_record_without_a_format_line_is_refused() raises:
    var old = String(
        "query q1\nrows 1\n"
        "column 1 1 0 0 5 25 5 5 5.0 25.0 5.0 5.0 0 0 x x\n"
        "end\n"
    )
    var raised = False
    try:
        _ = parse_references(old)
    except e:
        raised = True
        assert_true(String(e).find(String("format")) >= 0, "the message names the format: " + String(e))
    assert_true(raised, "a record with no format line must be refused, not misread")
    var other = String("format 1\n") + old
    raised = False
    try:
        _ = parse_references(other)
    except e:
        raised = True
        assert_true(String(e).find(String("format")) >= 0, "the message names the format: " + String(e))
    assert_true(raised, "a record of another format must be refused")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
