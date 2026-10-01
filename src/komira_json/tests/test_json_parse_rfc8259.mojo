# =============================================================================
# test_json_parse_rfc8259.mojo: well-formed documents parse to the right tree.
# =============================================================================
#
# The two RFC 8259 §13 examples, the §13 scalar texts, every escape (§7)
# including the §7 G-clef surrogate pair, the number grammar's edge forms
# kept verbatim (§6), whitespace (§2), duplicate keys, source lines, and the
# nesting limit at exactly its bound.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_json import (
    JSON_DEFAULT_MAX_DEPTH,
    JSON_MAX_DEPTH,
    JSON_NUMBER,
    JSON_OBJECT,
    JSON_STRING,
    JsonValue,
    parse_json_bytes,
    parse_json_value,
)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def _assert_bytes(s: String, want: List[UInt8], label: String) raises:
    var got = _bytes(s)
    assert_equal(len(got), len(want), label + " (length)")
    for i in range(len(want)):
        assert_equal(Int(got[i]), Int(want[i]), label + " (byte)")


def test_rfc8259_example_object() raises:
    var doc = parse_json_value(
        String(
            "{\n" +
            '  "Image": {\n' +
            '      "Width":  800,\n' +
            '      "Height": 600,\n' +
            '      "Title":  "View from 15th Floor",\n' +
            '      "Thumbnail": {\n' +
            '          "Url":    "http://www.example.com/image/481989943",\n' +
            '          "Height": 125,\n' +
            '          "Width":  100\n' +
            "      },\n" +
            '      "Animated" : false,\n' +
            '      "IDs": [116, 943, 234, 38793]\n' +
            "    }\n" +
            "}\n"
        )
    )
    assert_true(doc.is_object())
    assert_equal(doc.num_members(), 1)
    var image = doc.get("Image")
    assert_equal(image.num_members(), 6)
    assert_equal(image.get("Width").as_int64(), Int64(800))
    assert_equal(image.get("Height").as_int64(), Int64(600))
    assert_equal(image.get("Title").as_string(), String("View from 15th Floor"))
    var thumb = image.get("Thumbnail")
    assert_equal(
        thumb.get("Url").as_string(), "http://www.example.com/image/481989943"
    )
    assert_equal(thumb.get("Width").as_int64(), Int64(100))
    assert_false(image.get("Animated").as_bool())
    var ids = image.get("IDs")
    assert_true(ids.is_array())
    assert_equal(ids.array_len(), 4)
    assert_equal(ids.element_at(3).as_int64(), Int64(38793))
    # Member order is document order.
    assert_equal(image.key_at(0), String("Width"))
    assert_equal(image.key_at(5), String("IDs"))
    assert_equal(image.value_kind(3), JSON_OBJECT)
    # Source lines: "Image" key on line 2, "IDs" on line 12.
    assert_equal(doc.src_line, 1)
    assert_equal(image.key_line, 2)
    assert_equal(image.get("IDs").key_line, 12)
    assert_equal(thumb.key_line, 6)
    assert_equal(thumb.get("Url").src_line, 7)
    print("  test_rfc8259_example_object: PASS", flush=True)


def test_rfc8259_example_array() raises:
    var doc = parse_json_value(
        String(
            "[\n" +
            "  {\n" +
            '     "precision": "zip",\n' +
            '     "Latitude":  37.7668,\n' +
            '     "Longitude": -122.3959,\n' +
            '     "Address":   "",\n' +
            '     "City":      "SAN FRANCISCO",\n' +
            '     "State":     "CA",\n' +
            '     "Zip":       "94107",\n' +
            '     "Country":   "US"\n' +
            "  },\n" +
            "  {\n" +
            '     "precision": "zip",\n' +
            '     "Latitude":  37.371991,\n' +
            '     "Longitude": -122.026020,\n' +
            '     "Address":   "",\n' +
            '     "City":      "SUNNYVALE",\n' +
            '     "State":     "CA",\n' +
            '     "Zip":       "94085",\n' +
            '     "Country":   "US"\n' +
            "  }\n" +
            "]"
        )
    )
    assert_equal(doc.array_len(), 2)
    var a = doc.element_at(0)
    var b = doc.element_at(1)
    assert_equal(a.get("Latitude").as_float64(), Float64(37.7668))
    assert_equal(a.get("Longitude").as_float64(), Float64(-122.3959))
    assert_equal(a.get("Address").as_string(), String(""))
    assert_equal(b.get("City").as_string(), String("SUNNYVALE"))
    # A number keeps its source text verbatim, trailing zero included.
    assert_equal(b.get("Longitude").text, String("-122.026020"))
    assert_false(b.get("Longitude").is_integral_number())
    # "Zip" is a string, not a number.
    assert_equal(a.value_kind(6), JSON_STRING)
    assert_equal(b.src_line, 12)
    print("  test_rfc8259_example_array: PASS", flush=True)


def test_rfc8259_scalar_texts() raises:
    """§2 / §13: any value may be the whole text."""
    assert_equal(parse_json_value('"Hello world!"').as_string(), String("Hello world!"))
    assert_equal(parse_json_value("42").as_int64(), Int64(42))
    assert_true(parse_json_value("true").as_bool())
    assert_false(parse_json_value("false").as_bool())
    assert_true(parse_json_value("null").is_null())
    assert_true(parse_json_value("[]").is_array())
    assert_equal(parse_json_value("{}").num_members(), 0)
    # Surrounding whitespace of all four kinds.
    var v = parse_json_value(String(" \t\r\n 7 \n\t\r "))
    assert_equal(v.as_int64(), Int64(7))
    assert_equal(v.src_line, 2)
    print("  test_rfc8259_scalar_texts: PASS", flush=True)


def test_number_forms_kept_verbatim() raises:
    var forms = List[String]()
    forms.append("0")
    forms.append("-0")
    forms.append("-0.0")
    forms.append("0.5")
    forms.append("1e5")
    forms.append("1E+5")
    forms.append("1e-05")
    forms.append("-1.25e-3")
    forms.append("123456789012345678901234567890")
    for f in forms:
        var v = parse_json_value(f)
        assert_equal(v.kind_tag(), JSON_NUMBER, f)
        assert_equal(v.text, f, "number text kept verbatim")
        # And it re-serializes byte for byte.
        assert_equal(v.serialize(), f)
    assert_true(parse_json_value("-12").is_integral_number())
    assert_false(parse_json_value("1e2").is_integral_number())
    print("  test_number_forms_kept_verbatim: PASS", flush=True)


def test_every_escape_decodes() raises:
    var v = parse_json_value(
        String('"q\\"b\\\\s\\/b\\bf\\fn\\nr\\rt\\tu\\u0041\\u00e9\\u0000z"')
    )
    var want: List[UInt8] = [
        0x71, 0x22,  # q "
        0x62, 0x5C,  # b \
        0x73, 0x2F,  # s /
        0x62, 0x08,  # b BS
        0x66, 0x0C,  # f FF
        0x6E, 0x0A,  # n LF
        0x72, 0x0D,  # r CR
        0x74, 0x09,  # t TAB
        0x75, 0x41,  # u A
        0xC3, 0xA9,  # é (2-byte UTF-8)
        0x00,  # \u0000 -> NUL
        0x7A,  # z
    ]
    _assert_bytes(v.as_string(), want, "escapes")
    # Uppercase hex is accepted too.
    var upper: List[UInt8] = [0xC3, 0x89]
    _assert_bytes(parse_json_value('"\\u00C9"').as_string(), upper, "upper hex")
    print("  test_every_escape_decodes: PASS", flush=True)


def test_surrogate_pair_decodes_to_one_code_point() raises:
    """RFC 8259 §7: G clef U+1D11E is `\\uD834\\uDD1E`; it must decode to
    the 4-byte UTF-8 F0 9D 84 9E, not two 3-byte encoded surrogates."""
    var gclef: List[UInt8] = [0xF0, 0x9D, 0x84, 0x9E]
    _assert_bytes(parse_json_value('"\\ud834\\udd1e"').as_string(), gclef, "G clef")
    # The highest code point, U+10FFFF.
    var top: List[UInt8] = [0xF4, 0x8F, 0xBF, 0xBF]
    _assert_bytes(parse_json_value('"\\uDBFF\\uDFFF"').as_string(), top, "U+10FFFF")
    # A pair inside other text, then decoded again after re-serialization:
    # serialize writes the raw UTF-8, which re-parses to the same bytes.
    var v = parse_json_value('"a\\uD83D\\uDE00b"')
    var emoji: List[UInt8] = [0x61, 0xF0, 0x9F, 0x98, 0x80, 0x62]
    _assert_bytes(v.as_string(), emoji, "emoji pair")
    _assert_bytes(
        parse_json_value(v.serialize()).as_string(), emoji, "emoji pair round trip"
    )
    print("  test_surrogate_pair_decodes_to_one_code_point: PASS", flush=True)


def test_raw_utf8_accepted_verbatim() raises:
    # 2-, 3- and 4-byte sequences at the edges of the well-formed table.
    var body: List[UInt8] = [
        0x22,
        0xC2, 0x80,  # U+0080
        0xDF, 0xBF,  # U+07FF
        0xE0, 0xA0, 0x80,  # U+0800
        0xED, 0x9F, 0xBF,  # U+D7FF
        0xEE, 0x80, 0x80,  # U+E000
        0xEF, 0xBF, 0xBF,  # U+FFFF
        0xF0, 0x90, 0x80, 0x80,  # U+10000
        0xF4, 0x8F, 0xBF, 0xBF,  # U+10FFFF
        0x22,
    ]
    var v = parse_json_bytes(body)
    var want = List[UInt8]()
    for i in range(1, len(body) - 1):
        want.append(body[i])
    _assert_bytes(v.as_string(), want, "raw utf-8")
    print("  test_raw_utf8_accepted_verbatim: PASS", flush=True)


def test_duplicate_keys_kept_first_wins() raises:
    var v = parse_json_value('{"a":1,"b":2,"a":3}')
    assert_equal(v.num_members(), 3)
    assert_equal(v.get("a").as_int64(), Int64(1))
    assert_equal(v.value_at(2).as_int64(), Int64(3))
    assert_true(v.has("b"))
    assert_false(v.has("c"))
    print("  test_duplicate_keys_kept_first_wins: PASS", flush=True)


def _nested(depth: Int) -> String:
    var s = String("")
    for _ in range(depth):
        s += "["
    s += "1"
    for _ in range(depth):
        s += "]"
    return s^


def test_nesting_up_to_the_limit_parses() raises:
    var v = parse_json_value(_nested(JSON_DEFAULT_MAX_DEPTH))
    var d = 0
    while v.is_array():
        v = v.element_at(0)
        d += 1
    assert_equal(d, JSON_DEFAULT_MAX_DEPTH)
    assert_equal(v.as_int64(), Int64(1))
    # An explicit limit: depth 3 at limit 3 parses; a scalar at limit 0.
    _ = parse_json_value("[{\"a\":[1]}]", 3)
    assert_equal(parse_json_value("5", 0).as_int64(), Int64(5))
    # A raised limit admits deeper documents, up to the cap. A tree at the
    # cap can be copied, serialized and destroyed (each recurses per level).
    var text = _nested(JSON_MAX_DEPTH)
    var deep = parse_json_value(text, JSON_MAX_DEPTH)
    var twin = deep.copy()
    assert_equal(twin.serialize(), text)
    assert_equal(deep.serialize(), text)
    print("  test_nesting_up_to_the_limit_parses: PASS", flush=True)


def test_serialize_round_trip() raises:
    var text = String(
        '{"a":[1,-2.5e3,true,false,null,"x\\ny"],"b":{},"c":[],"d":{"e":""}}'
    )
    assert_equal(parse_json_value(text).serialize(), text)
    print("  test_serialize_round_trip: PASS", flush=True)


def main() raises:
    print("test_json_parse_rfc8259", flush=True)
    test_rfc8259_example_object()
    test_rfc8259_example_array()
    test_rfc8259_scalar_texts()
    test_number_forms_kept_verbatim()
    test_every_escape_decodes()
    test_surrogate_pair_decodes_to_one_code_point()
    test_raw_utf8_accepted_verbatim()
    test_duplicate_keys_kept_first_wins()
    test_nesting_up_to_the_limit_parses()
    test_serialize_round_trip()
    print("test_json_parse_rfc8259: ALL PASS", flush=True)
