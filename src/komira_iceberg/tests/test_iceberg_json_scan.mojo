# =============================================================================
# test_iceberg_json_scan.mojo — the scanners over the metadata.json we write.
# =============================================================================
#
# What each test proves (and the defect it catches):
#   1. read_json_string_at decodes every escape the emitter produces, and
#      copies UTF-8 through byte for byte (a per-byte `chr` would re-encode it).
#   2. matching_object_end does not count a brace inside a string, honouring a
#      backslash-escaped quote: a summary value like `a}b` must not end an
#      object early.
#   3. object_array_items returns each object of a named array, nested objects
#      and string braces included, and nothing for an absent or empty array.
#   4. The field readers find a bare number, a string, and refuse an absent key
#      or a value with no digits.
#   5. bytes_to_str keeps valid UTF-8 and turns invalid bytes into U+FFFD rather
#      than building an invalid String; parse_ascii_int reads the first run of
#      digits and refuses a body with none.
# =============================================================================

from std.testing import assert_true, assert_equal, assert_raises

from komira_iceberg.iceberg_json_scan import (
    read_json_string_at,
    matching_object_end,
    object_array_items,
    snapshot_objects,
    json_str_field,
    bare_int64_field,
    substr,
    bytes_to_str,
    parse_ascii_int,
)


def test_string_escapes_and_utf8() raises:
    var src = String('"a\\"b\\\\c\\n\\t\\u0041é日"')
    var r = read_json_string_at(src, 0)
    assert_equal(r.text, String('a"b\\c\n\tAé日'))
    assert_equal(r.end, src.byte_length())
    # Scanning starts where told, and stops after the closing quote.
    var two = String('x"k":"v"')
    var v = read_json_string_at(two, 5)
    assert_equal(v.text, String("v"))
    with assert_raises():
        _ = read_json_string_at(String("abc"), 0)
    with assert_raises():
        _ = read_json_string_at(String('"never closed'), 0)


def test_unicode_escape_of_a_non_ascii_code_point() raises:
    var r = read_json_string_at(String('"\\u00e9"'), 0)
    assert_equal(r.text, String("é"))


def test_object_end_ignores_braces_in_strings() raises:
    var s = String('{"a":"x}y","b":{"c":"{"},"d":"q\\"}z"} tail')
    var end = matching_object_end(s, 0)
    assert_equal(substr(s, 0, end), String('{"a":"x}y","b":{"c":"{"},"d":"q\\"}z"}'))
    # An unterminated object runs to the end of the text.
    assert_equal(matching_object_end(String('{"a":1'), 0), 6)


def test_array_items() raises:
    var j = String(
        '{"x":1,"snapshots":[{"id":1,"s":{"k":"}"}},{"id":2}],'
        '"schemas":[{"schema-id":0}],"empty":[]}'
    )
    var snaps = snapshot_objects(j)
    assert_equal(len(snaps), 2)
    assert_equal(snaps[0], String('{"id":1,"s":{"k":"}"}}'))
    assert_equal(snaps[1], String('{"id":2}'))
    var schemas = object_array_items(j, "schemas")
    assert_equal(len(schemas), 1)
    assert_equal(len(object_array_items(j, "empty")), 0)
    assert_equal(len(object_array_items(j, "absent")), 0)


def test_field_readers() raises:
    var s = String('{"n":-12,"p":"a\\\\b","z":0}')
    assert_equal(bare_int64_field(s, "n"), Int64(-12))
    assert_equal(bare_int64_field(s, "z"), Int64(0))
    assert_equal(json_str_field(s, "p"), String("a\\b"))
    with assert_raises():
        _ = bare_int64_field(s, "absent")
    with assert_raises():
        _ = bare_int64_field(String('{"n":"x"}'), "n")
    with assert_raises():
        _ = json_str_field(s, "absent")


def test_lossy_bytes_and_digit_parsing() raises:
    var ok = List[UInt8](String("é").as_bytes())
    assert_equal(bytes_to_str(ok), String("é"))
    var bad = List[UInt8]()
    bad.append(UInt8(ord("a")))
    bad.append(UInt8(0xFF))
    bad.append(UInt8(ord("b")))
    var s = bytes_to_str(bad)
    assert_true(s.find("a") == 0)
    assert_true(s.find("b") > 0)
    assert_equal(parse_ascii_int(List[UInt8](String("17\n").as_bytes())), 17)
    assert_equal(parse_ascii_int(List[UInt8](String("  8x9").as_bytes())), 8)
    with assert_raises():
        _ = parse_ascii_int(List[UInt8](String("none").as_bytes()))
    assert_equal(substr(String("hello"), -3, 99), String("hello"))
    assert_equal(substr(String("hello"), 3, 2), String(""))


def main() raises:
    test_string_escapes_and_utf8()
    test_unicode_escape_of_a_non_ascii_code_point()
    test_object_end_ignores_braces_in_strings()
    test_array_items()
    test_field_readers()
    test_lossy_bytes_and_digit_parsing()
    print("test_iceberg_json_scan: all passed")
