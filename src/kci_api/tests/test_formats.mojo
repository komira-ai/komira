# =============================================================================
# src/kci_api/tests/test_formats.mojo
#   The format table pinned by value, and every version refusal by its
#   message: authored (missing, too new, too old) and produced (format,
#   major, unknown keys ignored).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_json import parse_json_value

from kci_api import (
    FORMAT_ARTIFACTS,
    FORMAT_CELLS,
    FORMAT_CHANNELS,
    FORMAT_RELEASE_SET,
    FORMAT_RESULT,
    KIND_AUTHORED,
    KIND_PRODUCED,
    check_authored_version,
    check_produced_version,
    format_row,
    format_table,
    produced_header,
    unknown_keys,
)
from kci_api.formats import FormatRow, _range_refusal


def _authored(name: String, present: Bool, found: Int) -> String:
    try:
        check_authored_version(name, String("f.textproto"), present, found)
    except e:
        return String(e)
    return String("<ok>")


def _header(text: String, name: String) -> String:
    try:
        var doc = parse_json_value(text)
        return String(produced_header(doc, name, String("r.json")))
    except e:
        return String(e)


def test_golden_table() raises:
    var t = format_table()
    # `kci.stages` went with the `stages` verb
    assert_equal(len(t), 8)
    var want = List[String]()
    want.append(String("kci.artifacts AUTHORED 1 1"))
    want.append(String("kci.cells AUTHORED 1 1"))
    want.append(String("kci.channels AUTHORED 1 1"))
    want.append(String("kci.machine AUTHORED 1 1"))
    want.append(String("kci.artifact_manifest PRODUCED 1 1"))
    want.append(String("kci.conda_metadata PRODUCED 1 1"))
    want.append(String("kci.release_set PRODUCED 2 2"))
    want.append(String("kci.result PRODUCED 1 1"))
    for i in range(len(t)):
        var got = t[i].name + String(" ") + t[i].kind + String(" ") + String(t[i].current_major) + String(" ") + String(t[i].oldest_major_read)
        assert_equal(got, want[i])
        for j in range(i):
            assert_true(t[i].name != t[j].name)


def test_authored_control_and_refusals() raises:
    assert_equal(_authored(String(FORMAT_CHANNELS), True, 1), String("<ok>"))
    assert_equal(
        _authored(String(FORMAT_CHANNELS), False, 0),
        String("f.textproto: no schema_version; add `schema_version: 1` (this kci reads kci.channels up to major 1)"),
    )
    assert_equal(
        _authored(String(FORMAT_ARTIFACTS), True, 2),
        String("f.textproto: schema_version 2 needs a newer kci (this kci reads kci.artifacts up to major 1)"),
    )
    assert_equal(
        _authored(String(FORMAT_CHANNELS), True, 0),
        String("f.textproto: schema_version 0 is no longer read (this kci reads kci.channels major 1)"),
    )
    assert_true(_authored(String(FORMAT_RESULT), True, 1).find(String("is not an authored file")) >= 0)
    assert_true(_authored(String("kci.nope"), True, 1).find(String("not in kci's format table")) >= 0)
    assert_true(_authored(String("kci.stages"), True, 1).find(String("not in kci's format table")) >= 0)


def test_produced_header() raises:
    assert_equal(_header(String('{"format":"kci.result","schema_version":1}'), String(FORMAT_RESULT)), String("1"))
    assert_equal(
        _header(String('{"format":"kci.result","schema_version":2}'), String(FORMAT_RESULT)),
        String("r.json: schema_version 2 needs a newer kci (this kci reads kci.result up to major 1)"),
    )
    assert_equal(
        _header(String('{"format":"kci.release_set","schema_version":1}'), String(FORMAT_RELEASE_SET)),
        String("r.json: schema_version 1 is no longer read (this kci reads kci.release_set major 2)"),
    )
    assert_equal(
        _header(String('{"format":"kci.release_set","schema_version":1}'), String(FORMAT_RESULT)),
        String("r.json: format 'kci.release_set' is not 'kci.result'"),
    )
    assert_equal(_header(String('{"schema_version":1}'), String(FORMAT_RESULT)), String("r.json: no 'format' (a kci.result document names its format)"))
    assert_equal(_header(String('{"format":"kci.result"}'), String(FORMAT_RESULT)), String("r.json: no 'schema_version'"))
    assert_equal(
        _header(String('{"format":"kci.result","schema_version":1.0}'), String(FORMAT_RESULT)),
        String("r.json: 'schema_version' is not an integer"),
    )
    assert_equal(
        _header(String('{"format":"kci.result","schema_version":"1"}'), String(FORMAT_RESULT)),
        String("r.json: 'schema_version' is not an integer"),
    )
    assert_equal(_header(String('[1]'), String(FORMAT_RESULT)), String("r.json: not a JSON object"))
    assert_equal(
        _header(String('{"format":1,"schema_version":1}'), String(FORMAT_RESULT)),
        String("r.json: 'format' is not a string"),
    )
    var refused = False
    try:
        check_produced_version(String(FORMAT_CHANNELS), String("x"), String(FORMAT_CHANNELS), 1)
    except e:
        refused = String(e).find(String("is not a produced document")) >= 0
    assert_true(refused)


def test_unknown_keys_are_listed_not_refused() raises:
    var doc = parse_json_value(String('{"format":"kci.result","schema_version":1,"later":true,"also":1}'))
    var known = List[String]()
    known.append(String("format"))
    known.append(String("schema_version"))
    var u = unknown_keys(doc, known)
    assert_equal(len(u), 2)
    assert_equal(u[0], String("later"))
    assert_equal(u[1], String("also"))


def _range(row: FormatRow, found: Int) -> String:
    try:
        _range_refusal(row, String("s"), found)
    except e:
        return String(e)
    return String("<ok>")


def test_a_row_reading_several_majors_names_the_span() raises:
    # every row of today's table reads one major; the refusal of a row that
    # reads 2..4 names the span, the bounds themselves are read
    var row = FormatRow(String("kci.x"), String(KIND_PRODUCED), 4, 2)
    assert_equal(_range(row, 2), String("<ok>"))
    assert_equal(_range(row, 4), String("<ok>"))
    assert_equal(_range(row, 1), String("s: schema_version 1 is no longer read (this kci reads kci.x major 2..4)"))
    assert_equal(_range(row, 5), String("s: schema_version 5 needs a newer kci (this kci reads kci.x up to major 4)"))


def test_rows_by_name() raises:
    assert_equal(format_row(String(FORMAT_RELEASE_SET)).current_major, 2)
    assert_equal(format_row(String(FORMAT_CHANNELS)).kind, String(KIND_AUTHORED))
    assert_equal(format_row(String(FORMAT_CELLS)).kind, String(KIND_AUTHORED))
    assert_equal(format_row(String(FORMAT_CELLS)).current_major, 1)
    assert_equal(format_row(String(FORMAT_RESULT)).kind, String(KIND_PRODUCED))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
