# =============================================================================
# test_avro_schema_json_grammar.mojo: the RFC 8259 grammar of Avro schema JSON
# (numbers, control characters in strings) and the byte offsets in its errors.
# =============================================================================
#
# The schema JSON comes from the `avro.schema` header entry of a file, so it is
# untrusted. The number scanner took any run of `0-9 . e E + -` as a number,
# and the string decoder copied raw control characters (U+0000..U+001F) into
# the string. Inputs are the JSONTestSuite test_parsing files, byte for byte
# (the corpus pinned in third_party/jsontestsuite; file names in each table).
#
# What each test proves, and the defect it catches:
#   G1  the 26 n_number_* / n_array_just_minus files that broke only the
#       number grammar are each refused with the exact text: reason and the
#       offset of the first byte that breaks the grammar. Catches: the old
#       character-class scanner (all accepted), and each grammar rule dropped
#       on its own (leading zero, '-' digit, '.' digit, exponent digits, the
#       byte after a number).
#   G2  the 3 n_string_unescaped_* files are refused with the exact text,
#       naming the control byte and its offset. Catches: control bytes copied
#       through, a bound of < 0x1F instead of < 0x20 (U+001F case), and a
#       check that skips the first byte of a run (n_string_unescaped_tab: the
#       tab is the first byte after the quote).
#   G3  number forms refused before the number scanner (hex, NaN, Infinity,
#       '+', a leading '.') keep their exact texts with offsets; "-Infinity"
#       and "- 1" now name the '-'. Catches: a regression that lets one of
#       them through, or a wrong offset in the structural errors.
#   G4  number shapes the grammar allows parse to the right default: 0,
#       -0, multi-digit ints, fractions, both exponent marks and signs, and
#       one-, two- and three-digit exponents (1e001, 0E+100); each literal
#       is checked right before ',' and right before '}', and numbers (one
#       with a two-digit exponent) sit before ',' and ']' in an array.
#       Catches: a scanner that refuses a valid form or stops early, e.g.
#       one that reads at most one or two exponent digits (then the next
#       byte is refused).
#   G5  escaped control characters and U+007F stay legal; a raw 'é' and
#       the escape \u00e9 decode to C3 A9, and the escaped surrogate pair
#       \ud83d\ude00 to F0 9F 98 80, in a default. Catches: the control-character check refusing escapes or a
#       byte >= 0x20, and a regression of the byte-exact string decoding.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_avro import AvroSchema
from komira_avro.avro_schema import AVRO_DEFAULT_DOUBLE, AVRO_DEFAULT_INT


def _refusal(text: String) -> String:
    try:
        var _s = AvroSchema.parse(text)
    except e:
        return String(e)
    return String("(accepted)")


def _refused(text: String, want: String, what: String) raises:
    assert_equal(_refusal(text), want, what)


def _bad_number(at: Int, reason: String) -> String:
    return (
        String("AvroSchemaError.MALFORMED_JSON: bad number at byte ")
        + String(at)
        + ": "
        + reason
    )


comptime _MINUS = "'-' is not followed by a digit"
comptime _ZERO = "a leading zero is followed by a digit"
comptime _DOT = "'.' is not followed by a digit"
comptime _EXP = "the exponent has no digits"


def test_number_grammar_refusals() raises:
    """G1."""
    _refused("[-]", _bad_number(2, _MINUS), "n_array_just_minus")
    _refused("[-01]", _bad_number(3, _ZERO), "n_number_-01")
    _refused(
        "[-1.0.]",
        _bad_number(5, "'.' cannot follow a number"),
        "n_number_-1.0.",
    )
    _refused("[-2.]", _bad_number(4, _DOT), "n_number_-2.")
    _refused(
        "[0.1.2]",
        _bad_number(4, "'.' cannot follow a number"),
        "n_number_0.1.2",
    )
    _refused("[0.3e+]", _bad_number(6, _EXP), "n_number_0.3e+")
    _refused("[0.3e]", _bad_number(5, _EXP), "n_number_0.3e")
    _refused("[0.e1]", _bad_number(3, _DOT), "n_number_0.e1")
    _refused("[0E+]", _bad_number(4, _EXP), "n_number_0_capital_E+")
    _refused("[0E]", _bad_number(3, _EXP), "n_number_0_capital_E")
    _refused("[0e+]", _bad_number(4, _EXP), "n_number_0e+")
    _refused("[0e]", _bad_number(3, _EXP), "n_number_0e")
    _refused("[1.0e+]", _bad_number(6, _EXP), "n_number_1.0e+")
    _refused("[1.0e-]", _bad_number(6, _EXP), "n_number_1.0e-")
    _refused("[1.0e]", _bad_number(5, _EXP), "n_number_1.0e")
    _refused("[1eE2]", _bad_number(3, _EXP), "n_number_1eE2")
    _refused("[2.e+3]", _bad_number(3, _DOT), "n_number_2.e+3")
    _refused("[2.e-3]", _bad_number(3, _DOT), "n_number_2.e-3")
    _refused("[2.e3]", _bad_number(3, _DOT), "n_number_2.e3")
    _refused("[9.e+]", _bad_number(3, _DOT), "n_number_9.e+")
    _refused(
        "[1+2]",
        _bad_number(2, "'+' cannot follow a number"),
        "n_number_expression",
    )
    _refused("[0e+-1]", _bad_number(4, _EXP), "n_number_invalid+-")
    _refused(
        "[-012]", _bad_number(3, _ZERO), "n_number_neg_int_starting_with_zero"
    )
    _refused(
        "[-.123]", _bad_number(2, _MINUS), "n_number_neg_real_without_int_part"
    )
    _refused(
        "[1.]", _bad_number(3, _DOT), "n_number_real_without_fractional_part"
    )
    _refused("[012]", _bad_number(2, _ZERO), "n_number_with_leading_zero")
    # Not from the suite: each of '-', 'e' and 'E' straight after a complete
    # exponent, refused by the trailing-byte check with its own text.
    _refused(
        "[1e5-2]", _bad_number(4, "'-' cannot follow a number"), "1e5-2"
    )
    _refused(
        "[1e5e5]", _bad_number(4, "'e' cannot follow a number"), "1e5e5"
    )
    _refused(
        "[1.5e2E1]", _bad_number(6, "'E' cannot follow a number"), "1.5e2E1"
    )


def _ctrl(hex2: String, at: Int) -> String:
    return (
        String("AvroSchemaError.MALFORMED_JSON: unescaped control character 0x")
        + hex2
        + " in a string at byte "
        + String(at)
    )


def test_control_characters_refused() raises:
    """G2."""
    var nul = String('["a') + chr(0) + 'a"]'
    _refused(nul, _ctrl("00", 3), "n_string_unescaped_ctrl_char")
    _refused('["new\nline"]', _ctrl("0A", 5), "n_string_unescaped_newline")
    _refused('["\t"]', _ctrl("09", 2), "n_string_unescaped_tab")
    # U+001F, the top of the range, inside an object key.
    var us = String('{"a') + chr(0x1F) + '":1}'
    _refused(us, _ctrl("1F", 3), "U+001F in a key")


def test_other_number_forms_refused() raises:
    """G3."""
    comptime UNEXPECTED = "AvroSchemaError.MALFORMED_JSON: unexpected character at byte 1"
    comptime NOT_SEP = "AvroSchemaError.MALFORMED_JSON: expected ',' or ']' at byte 2"
    _refused("[0x1]", NOT_SEP, "n_number_hex_1_digit")
    _refused("[0x42]", NOT_SEP, "n_number_hex_2_digits")
    _refused("[NaN]", UNEXPECTED, "n_number_NaN")
    _refused("[Infinity]", UNEXPECTED, "n_number_infinity")
    _refused("[+1]", UNEXPECTED, "n_number_+1")
    _refused("[+Inf]", UNEXPECTED, "n_number_+Inf")
    _refused("[.2e-3]", UNEXPECTED, "n_number_.2e-3")
    _refused("[.123]", UNEXPECTED, "n_number_starting_with_dot")
    _refused("[-Infinity]", _bad_number(2, _MINUS), "n_number_minus_infinity")
    _refused("[-NaN]", _bad_number(2, _MINUS), "n_number_-NaN")
    _refused("[- 1]", _bad_number(2, _MINUS), "n_number_minus_space_1")
    _refused(
        "[1 000.0]",
        "AvroSchemaError.MALFORMED_JSON: expected ',' or ']' at byte 3",
        "n_number_1_000",
    )
    _refused(
        '{"type":"int"} x',
        "AvroSchemaError.MALFORMED_JSON: trailing data after schema at byte 15",
        "trailing data",
    )


def _record(lit: String) -> String:
    """A record with two fields defaulting to `lit`: in field `a` a "doc"
    member follows the default, so `lit` sits right before ','; in field `b`
    the default is the last member, so `lit` sits right before '}'."""
    return (
        String('{"type":"record","name":"R","fields":[')
        + '{"name":"a","type":"double","default":'
        + lit
        + ',"doc":"d"},{"name":"b","type":"long","default":'
        + lit
        + "}]}"
    )


def _check_int(lit: String, want: Int) raises:
    var s = AvroSchema.parse(_record(lit))
    var defaults = s.nodes[s.root_idx].field_defaults.copy()
    for i in range(2):
        assert_equal(defaults[i].kind, AVRO_DEFAULT_INT, lit + ": kind")
        assert_equal(Int(defaults[i].int_val), want, lit + ": value")


def _check_float(lit: String, want: Float64) raises:
    var s = AvroSchema.parse(_record(lit))
    var defaults = s.nodes[s.root_idx].field_defaults.copy()
    for i in range(2):
        assert_equal(defaults[i].kind, AVRO_DEFAULT_DOUBLE, lit + ": kind")
        assert_equal(defaults[i].double_val, want, lit + ": value")


def test_valid_numbers_parse() raises:
    """G4."""
    _check_int("0", 0)
    _check_int("-0", 0)
    _check_int("7", 7)
    _check_int("-120", -120)
    _check_int("9007199254740993", 9007199254740993)
    _check_float("0.5", 0.5)
    _check_float("-0.25", -0.25)
    _check_float("10.75", 10.75)
    _check_float("0e0", 0.0)
    _check_float("1E2", 100.0)
    _check_float("1e+2", 100.0)
    _check_float("5e-1", 0.5)
    _check_float("-1.5E+3", -1500.0)
    _check_float("0.0", 0.0)
    # Exponents of two or more digits: a scanner that reads one exponent
    # digit stops before the second and refuses the next byte.
    _check_float("1e10", 1e10)
    _check_float("25E-01", 2.5)
    _check_float("123e45", 123e45)
    # Three-digit exponents, with values exact under the parser's multiply
    # loop: a scanner that stops after two exponent digits refuses the third.
    _check_float("1e001", 10.0)
    _check_float("0E+100", 0.0)
    # A number right before '}' (the fixed size) and at the end of an array.
    var f = AvroSchema.parse(String('{"type":"fixed","name":"F","size":16}'))
    assert_equal(f.nodes[f.root_idx].size, 16, "size before '}'")
    var e = AvroSchema.parse(
        String('{"type":"enum","name":"E","symbols":["A"],')
        + '"x":[1,2.5e1,1E22]}'
    )
    assert_equal(len(e.nodes[e.root_idx].symbols), 1, "number before ']'")


def _string_default(lit: String) raises -> String:
    var s = AvroSchema.parse(
        String('{"type":"record","name":"R","fields":[')
        + '{"name":"a","type":"string","default":'
        + lit
        + "}]}"
    )
    return s.nodes[s.root_idx].field_defaults[0].str_val


def _assert_bytes(got: String, want: List[Int], what: String) raises:
    var g = got.as_bytes()
    assert_equal(len(g), len(want), what + ": byte length")
    for i in range(len(want)):
        assert_equal(Int(g[i]), want[i], what + ": byte " + String(i))


def test_strings_still_decode() raises:
    """G5."""
    _assert_bytes(
        _string_default('"\\u0000\\n\\t\\u001f"'),
        [0x00, 0x0A, 0x09, 0x1F],
        "escaped controls",
    )
    _assert_bytes(
        _string_default(String('" ') + chr(0x7F) + '"'),
        [0x20, 0x7F],
        "space and DEL",
    )
    _assert_bytes(_string_default('"é"'), [0xC3, 0xA9], "raw e-acute")
    _assert_bytes(_string_default('"\\u00e9"'), [0xC3, 0xA9], "escaped e-acute")
    _assert_bytes(
        _string_default('"\\ud83d\\ude00"'),
        [0xF0, 0x9F, 0x98, 0x80],
        "surrogate pair",
    )


def main() raises:
    test_number_grammar_refusals()
    test_control_characters_refused()
    test_other_number_forms_refused()
    test_valid_numbers_parse()
    test_strings_still_decode()
    print("test_avro_schema_json_grammar: ALL PASS")
