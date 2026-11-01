# =============================================================================
# komira_db/tests/test_text_array_literal.mojo
# A TEXT[] value is carried as one array literal string (DbValue._text). Every
# String element must come back exactly, through both read paths:
# `DbValue.text_array_elements()` (what the Firestore encoder uses) and
# `DbRow.get_text_array()` (what every backend's row read uses).
# =============================================================================
# The expected literals are written out by hand from PostgreSQL's array output
# rules (array_out): an element is double-quoted when it is empty, spells NULL
# in any case, or holds '{' '}' ',' '"' '\' or whitespace; inside the quotes
# '"' and '\' are backslash-escaped. Nothing here is computed by the code under
# test.
#
# Defect each test catches:
#   * test_round_trip_*: an unquoted writer or a split-on-',' reader turns
#     ["a,b"] into ["a", "b"], ["x}y", "z"] into ["x"], [""] into [].
#   * test_literal_spelling: a writer that quotes too little (a bare NULL,
#     a bare space) or too much (quoting a plain label), or escapes wrongly.
#   * test_unquoted_literal_reads: a reader that stops accepting the unquoted
#     `{red,blue}` form (every TEXT[] stored before quoting existed).
# =============================================================================

from std.testing import assert_equal

from komira_db.db_row import DbRow
from komira_db.db_value import DbValue, LOGICAL_TEXT_ARRAY


def _one(a: String) -> List[String]:
    var l = List[String]()
    l.append(a)
    return l^


def _two(a: String, b: String) -> List[String]:
    var l = List[String]()
    l.append(a)
    l.append(b)
    return l^


def _three(a: String, b: String, c: String) -> List[String]:
    var l = List[String]()
    l.append(a)
    l.append(b)
    l.append(c)
    return l^


def _show(xs: List[String]) -> String:
    """Unambiguous rendering for messages: each element bracketed, with its
    length, so ["a,b"] and ["a", "b"] never print the same."""
    var out = String(len(xs)) + String(" elements:")
    for i in range(len(xs)):
        out += String(" <") + xs[i] + String(">")
    return out^


def _assert_same(got: List[String], want: List[String], what: String) raises:
    var ok = len(got) == len(want)
    if ok:
        for i in range(len(want)):
            if got[i] != want[i]:
                ok = False
    if not ok:
        raise Error(
            what + String(": want ") + _show(want) + String(", got ") + _show(got)
        )


def _cases() -> List[List[String]]:
    var c = List[List[String]]()
    c.append(_one("a,b"))
    c.append(_two("x}y", "z"))
    c.append(_one(""))
    c.append(_one('a"b'))
    c.append(_one("a\\b"))
    c.append(_one("NULL"))
    c.append(_one("null"))
    c.append(_one("{x}"))
    c.append(_two(" lead", "trail "))
    c.append(_one("tab\there"))
    c.append(_two("", ""))
    c.append(_three("a", "", "b"))
    c.append(_two('"', "\\"))
    c.append(_one("--list=a,b"))
    c.append(_two("Zürich", "東京, Tokyo"))
    c.append(_two("plain", "labels"))
    c.append(List[String]())
    return c^


def test_round_trip_text_array_elements() raises:
    var cases = _cases()
    for i in range(len(cases)):
        var v = DbValue.text_array(cases[i].copy())
        _assert_same(
            v.text_array_elements(),
            cases[i],
            String("text_array_elements case ") + String(i),
        )


def test_round_trip_db_row_get_text_array() raises:
    var cases = _cases()
    for i in range(len(cases)):
        var vals = List[DbValue]()
        vals.append(DbValue.text_array(cases[i].copy()))
        var names = List[String]()
        names.append(String("tags"))
        var row = DbRow.from_values(vals, names)
        _assert_same(
            row.get_text_array(0),
            cases[i],
            String("get_text_array case ") + String(i),
        )


def test_literal_spelling() raises:
    assert_equal(DbValue.text_array(List[String]()).as_text(), "{}")
    assert_equal(DbValue.text_array(_two("red", "blue")).as_text(), "{red,blue}")
    assert_equal(DbValue.text_array(_two("a,b", "plain")).as_text(), '{"a,b",plain}')
    assert_equal(DbValue.text_array(_one("")).as_text(), '{""}')
    assert_equal(DbValue.text_array(_one("NULL")).as_text(), '{"NULL"}')
    assert_equal(DbValue.text_array(_one("nUlL")).as_text(), '{"nUlL"}')
    assert_equal(DbValue.text_array(_one("NULLS")).as_text(), "{NULLS}")
    assert_equal(DbValue.text_array(_one("a b")).as_text(), '{"a b"}')
    assert_equal(DbValue.text_array(_one("x}y")).as_text(), '{"x}y"}')
    assert_equal(DbValue.text_array(_one('a"b\\c')).as_text(), '{"a\\"b\\\\c"}')
    assert_equal(DbValue.text_array(_one("Zürich")).as_text(), "{Zürich}")
    assert_equal(DbValue.text_array(_one("x")).logical_type, LOGICAL_TEXT_ARRAY)


def test_unquoted_literal_reads() raises:
    """The unquoted form (every value written before elements were quoted)
    still reads as before: elements split at ',' and taken verbatim."""
    var v = DbValue(LOGICAL_TEXT_ARRAY, False, String("{red,blue}"))
    _assert_same(v.text_array_elements(), _two("red", "blue"), "unquoted pair")
    var e = DbValue(LOGICAL_TEXT_ARRAY, False, String("{}"))
    _assert_same(e.text_array_elements(), List[String](), "empty literal")
    var m = DbValue(LOGICAL_TEXT_ARRAY, False, String('{plain,"a,b",""}'))
    _assert_same(m.text_array_elements(), _three("plain", "a,b", ""), "mixed")


def main() raises:
    test_round_trip_text_array_elements()
    test_round_trip_db_row_get_text_array()
    test_literal_spelling()
    test_unquoted_literal_reads()
