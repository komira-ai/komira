# =============================================================================
# src/kci_api/tests/test_authored_version.mojo
#   schema_version of an authored file: found at the top level only, read
#   before the file's own fields, each refusal by its message.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_textproto import TOKEN_WORD, TokenCursor, lex

from kci_api import FORMAT_CHANNELS, FORMAT_MACHINE, authored_schema_version, skip_schema_version


def _v(text: String) -> String:
    try:
        return String(authored_schema_version(lex(text, String("f")), String(FORMAT_CHANNELS), String("f")))
    except e:
        return String(e)


def test_found_at_the_top_level() raises:
    assert_equal(_v(String("schema_version: 1\nchannel { name: \"a\" }\n")), String("1"))
    # position at the top level does not matter
    assert_equal(_v(String("channel { name: \"a\" }\nschema_version: 1\n")), String("1"))


def test_a_nested_field_of_that_name_is_not_it() raises:
    assert_equal(
        _v(String("channel { schema_version: 1 }\n")),
        String("f: no schema_version; add `schema_version: 1` (this kci reads kci.channels up to major 1)"),
    )
    # a value spelled schema_version is not the field either
    assert_true(_v(String("kind: schema_version\n")).find(String("no schema_version")) >= 0)


def test_refusals() raises:
    assert_equal(
        _v(String("schema_version: 2\nchannel { future_field: 1 }\n")),
        String("f: schema_version 2 needs a newer kci (this kci reads kci.channels up to major 1)"),
    )
    assert_equal(
        _v(String("schema_version: 0\n")),
        String("f: schema_version 0 is no longer read (this kci reads kci.channels major 1)"),
    )
    assert_equal(
        _v(String("schema_version: 1\n\nschema_version: 1\n")),
        String("f: line 3: field 'schema_version' is set twice (first on line 1)"),
    )
    assert_equal(
        _v(String("schema_version: \"1\"\n")),
        String("f: line 1: schema_version is not a decimal integer (expected `schema_version: <major>`)"),
    )
    assert_true(_v(String("schema_version: 01\n")).find(String("not a decimal integer")) >= 0)
    assert_true(_v(String("schema_version: -1\n")).find(String("not a decimal integer")) >= 0)
    assert_true(_v(String("schema_version: 1.0\n")).find(String("not a decimal integer")) >= 0)
    assert_true(_v(String("schema_version\n")).find(String("not a decimal integer")) >= 0)
    # nine digits is the longest major read; a tenth digit is refused on its
    # line, never read as a (wrapped or huge) number. Only the refusal and its
    # line are asserted: the message today says "not a decimal integer", which
    # is false (komira-ai/komira#1016).
    assert_equal(
        _v(String("schema_version: 999999999\n")),
        String("f: schema_version 999999999 needs a newer kci (this kci reads kci.channels up to major 1)"),
    )
    var ten = _v(String("schema_version: 1000000000\n"))
    assert_true(ten.startswith(String("f: line 1: schema_version ")), ten)


def test_skip_then_parse_the_rest() raises:
    var toks = lex(String("schema_version: 1\nmachine_field: \"x\"\n"), String("f"))
    _ = authored_schema_version(toks, String(FORMAT_MACHINE), String("f"))
    var c = TokenCursor(toks^, String("f"))
    var f = c.expect(TOKEN_WORD)
    assert_equal(f.text, String("schema_version"))
    skip_schema_version(c)
    assert_equal(c.expect(TOKEN_WORD).text, String("machine_field"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
