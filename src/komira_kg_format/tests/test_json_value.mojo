# =============================================================================
# test_json_value.mojo -- the JSON value tree and parser.
# =============================================================================
#
#   reading      objects, arrays and every leaf kind parse and navigate by key
#                and index; has/len/num_fields/field_key_at/field_value_at and
#                the as_* accessors answer, and an accessor of the wrong kind or
#                an absent key or index is an error; a JSON string inside a JSON
#                string (a model envelope) parses in two steps.
#   text         the escapes decode; raw multi-byte UTF-8 passes through byte
#                for byte; \u escapes make code points, a surrogate pair makes
#                one astral code point.
#   numbers      the RFC 8259 number forms parse and read back as Int or Float64.
#   utf8         a raw byte string or key that is not UTF-8 is refused.
#   refusal      each malformed text is an error: a missing value, a missing
#                colon, a trailing comma, a bad literal, text after the root,
#                an unterminated string, a raw control character in a string, a
#                bad escape, a bad \u digit, a lone surrogate, and every number
#                form the grammar forbids (+1, 01, 1., .5, -, 1e, 1e+).
#   depth        nesting up to JSON_MAX_DEPTH parses; one level deeper is
#                refused instead of exhausting the stack.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from komira_kg_format import (
    JSON_ARRAY,
    JSON_BOOL,
    JSON_MAX_DEPTH,
    JSON_NULL,
    JSON_NUMBER,
    JSON_OBJECT,
    JSON_STRING,
    JsonDoc,
)


def _refused(text: String) -> Bool:
    try:
        _ = JsonDoc.parse(text)
        return False
    except:
        return True


def _assert_all_refused(texts: List[String]) raises:
    for i in range(len(texts)):
        assert_true(_refused(texts[i]), "accepted: " + texts[i])


# --- reading -----------------------------------------------------------------


def test_navigates_objects_arrays_and_leaves() raises:
    var doc = JsonDoc.parse(
        String(
            '{"name":"ada","age":36,"pi":3.5,"ok":true,"no":false,'
            '"nothing":null,"tags":["a","b",{"deep":[1,2]}]}'
        )
    )
    var root = doc.root()
    assert_equal(root.kind(), JSON_OBJECT)
    assert_true(root.is_object())
    assert_equal(root.get("name").as_string(), "ada")
    assert_equal(root.get("age").as_int(), 36)
    assert_equal(root.get("pi").as_float(), 3.5)
    assert_true(root.get("ok").as_bool())
    assert_false(root.get("no").as_bool())
    assert_equal(root.get("nothing").kind(), JSON_NULL)
    assert_true(root.get("nothing").is_null())
    var tags = root.get("tags")
    assert_equal(tags.kind(), JSON_ARRAY)
    assert_true(tags.is_array())
    assert_equal(tags.len(), 3)
    assert_equal(tags.at(1).as_string(), "b")
    assert_equal(tags.at(2).get("deep").at(1).as_int(), 2)
    assert_equal(root.get("age").kind(), JSON_NUMBER)
    assert_equal(root.get("ok").kind(), JSON_BOOL)
    assert_equal(root.get("name").kind(), JSON_STRING)
    assert_true(root.get("name").is_string())


def test_has_len_and_field_iteration() raises:
    var doc = JsonDoc.parse(String('{"b":1,"a":[true],"c":{}}'))
    var root = doc.root()
    assert_true(root.has("a"))
    assert_false(root.has("z"))
    assert_false(root.get("a").has("a"))  # an array has no keys
    assert_equal(root.num_fields(), 3)
    assert_equal(root.get("a").num_fields(), 0)
    assert_equal(root.get("a").len(), 1)
    assert_equal(root.get("b").len(), 0)  # a non-array has no length
    # Fields come back in the order the text gave them.
    assert_equal(root.field_key_at(0), "b")
    assert_equal(root.field_key_at(1), "a")
    assert_equal(root.field_key_at(2), "c")
    assert_equal(root.field_value_at(0).as_int(), 1)
    assert_equal(root.field_value_at(2).num_fields(), 0)


def test_wrong_kind_missing_key_and_bad_index_are_errors() raises:
    var doc = JsonDoc.parse(String('{"s":"x","n":1,"a":[1]}'))
    var root = doc.root()
    with assert_raises(contains="missing key 'zz'"):
        _ = root.get("zz")
    with assert_raises(contains="not an object"):
        _ = root.get("s").get("k")
    with assert_raises(contains="not an array"):
        _ = root.get("s").at(0)
    with assert_raises(contains="index out of bounds"):
        _ = root.get("a").at(1)
    with assert_raises(contains="index out of bounds"):
        _ = root.get("a").at(-1)
    with assert_raises(contains="not a string"):
        _ = root.get("n").as_string()
    with assert_raises(contains="not a number"):
        _ = root.get("s").as_int()
    with assert_raises(contains="not a number"):
        _ = root.get("s").as_float()
    with assert_raises(contains="not a bool"):
        _ = root.get("n").as_bool()
    with assert_raises(contains="not an object"):
        _ = root.get("a").field_key_at(0)
    with assert_raises(contains="index out of bounds"):
        _ = root.field_key_at(3)
    with assert_raises(contains="index out of bounds"):
        _ = root.field_value_at(-1)
    # as_int on a fraction is an error, not a truncation.
    var frac = JsonDoc.parse(String("1.5"))
    with assert_raises():
        _ = frac.root().as_int()
    assert_equal(root.get("s").as_string_or("dflt"), "x")
    assert_equal(root.get("n").as_string_or("dflt"), "dflt")


def test_envelope_with_json_inside_a_json_string() raises:
    var envelope = JsonDoc.parse(
        String(
            '{"choices":[{"message":{"content":"{\\"entities\\":[{\\"name\\":'
            '\\"Ada\\"}]}"}}]}'
        )
    )
    var content = envelope.root().get("choices").at(0).get("message").get(
        "content"
    ).as_string()
    var inner = JsonDoc.parse(content)
    assert_equal(inner.root().get("entities").at(0).get("name").as_string(), "Ada")


def test_whitespace_around_the_root_is_allowed() raises:
    var doc = JsonDoc.parse(String(' \t\r\n [ 1 , 2 ]  \n'))
    assert_equal(doc.root().len(), 2)
    assert_equal(JsonDoc.parse(String("  null ")).root().kind(), JSON_NULL)
    assert_equal(JsonDoc.parse(String("{}")).root().num_fields(), 0)
    assert_equal(JsonDoc.parse(String("[]")).root().len(), 0)


# --- text --------------------------------------------------------------------


def test_simple_escapes_decode() raises:
    var doc = JsonDoc.parse(
        String('"q\\" b\\\\ s\\/ n\\n r\\r t\\t bs\\b ff\\f"')
    )
    var s = doc.root().as_string()
    var want = String('q" b\\ s/ n\n r\r t\t bs')
    want += chr(8)
    want += " ff"
    want += chr(12)
    assert_equal(s, want)


def test_raw_multibyte_utf8_passes_through_byte_for_byte() raises:
    var doc = JsonDoc.parse(String('"§ é 日本 😀"'))
    var s = doc.root().as_string()
    assert_equal(s, "§ é 日本 😀")
    assert_equal(s.byte_length(), String("§ é 日本 😀").byte_length())
    # A key with multi-byte text is found by the same bytes.
    var keyed = JsonDoc.parse(String('{"é§":1}'))
    assert_true(keyed.root().has("é§"))


def test_unicode_escapes_make_code_points() raises:
    var doc = JsonDoc.parse(String('"\\u00e9|\\u65e5|\\u0041|\\ud83d\\ude00"'))
    assert_equal(doc.root().as_string(), "é|日|A|😀")
    var nul = JsonDoc.parse(String('"a\\u0000b"'))
    assert_equal(nul.root().as_string().byte_length(), 3)


def test_a_decoded_string_or_key_that_is_not_utf8_is_refused() raises:
    # Raw bytes that no UTF-8 text holds, built unchecked on purpose.
    var bad_value = List[UInt8]()
    bad_value.append(UInt8(ord('"')))
    bad_value.append(UInt8(0xFF))
    bad_value.append(UInt8(ord('"')))
    assert_true(_refused(String(unsafe_from_utf8=Span(bad_value))))
    var bad_key = List[UInt8]()
    for c in [ord("{"), ord('"'), 0xC3, ord('"'), ord(":"), ord("1"), ord("}")]:
        bad_key.append(UInt8(c))
    assert_true(_refused(String(unsafe_from_utf8=Span(bad_key))))
    # The same bytes made valid (C3 A9) parse, so the refusal is the bytes.
    var good_key = List[UInt8]()
    for c in [
        ord("{"), ord('"'), 0xC3, 0xA9, ord('"'), ord(":"), ord("1"), ord("}")
    ]:
        good_key.append(UInt8(c))
    var doc = JsonDoc.parse(String(unsafe_from_utf8=Span(good_key)))
    assert_true(doc.root().has("é"))


# --- numbers -----------------------------------------------------------------


def test_rfc_number_forms_parse() raises:
    assert_equal(JsonDoc.parse(String("0")).root().as_int(), 0)
    assert_equal(JsonDoc.parse(String("-0")).root().as_int(), 0)
    assert_equal(JsonDoc.parse(String("-17")).root().as_int(), -17)
    assert_equal(JsonDoc.parse(String("123456789")).root().as_int(), 123456789)
    assert_equal(JsonDoc.parse(String("0.25")).root().as_float(), 0.25)
    assert_equal(JsonDoc.parse(String("-1.5e3")).root().as_float(), -1500.0)
    assert_equal(JsonDoc.parse(String("2E+2")).root().as_float(), 200.0)
    assert_equal(JsonDoc.parse(String("5e-1")).root().as_float(), 0.5)
    assert_equal(JsonDoc.parse(String("[0,1]")).root().at(1).as_int(), 1)


# --- refusal -----------------------------------------------------------------


def test_malformed_structure_is_refused() raises:
    var bad = List[String]()
    bad.append(String(""))
    bad.append(String("   "))
    bad.append(String('{"a":}'))
    bad.append(String('{"a" 1}'))
    bad.append(String('{"a":1,}'))
    bad.append(String("{1:2}"))
    bad.append(String("{"))
    bad.append(String('{"a":1'))
    bad.append(String("[1,"))
    bad.append(String("[1 2]"))
    bad.append(String("[,1]"))
    bad.append(String("[1,]"))
    bad.append(String("]"))
    bad.append(String("tru"))
    bad.append(String("nul"))
    bad.append(String("falsy"))
    bad.append(String("undefined"))
    bad.append(String("[1] x"))
    bad.append(String('{"a":1} {"b":2}'))
    bad.append(String("1 2"))
    _assert_all_refused(bad)


def test_malformed_strings_are_refused() raises:
    var bad = List[String]()
    bad.append(String('"abc'))
    bad.append(String('"abc\\'))
    bad.append(String('"\\q"'))
    bad.append(String('"\\u12G4"'))
    bad.append(String('"\\u12"'))
    bad.append(String('"\\ud83d"'))  # a lone high surrogate
    bad.append(String('"\\ud83dx"'))
    bad.append(String('"\\ud83d\\u0041"'))  # a high surrogate, not a low one
    bad.append(String('"\\ude00"'))  # a lone low surrogate
    bad.append(String('"a' + chr(1) + 'b"'))  # a raw control character
    bad.append(String('"a\nb"'))  # a raw newline
    _assert_all_refused(bad)


def test_numbers_the_grammar_forbids_are_refused() raises:
    var bad = List[String]()
    for t in ["+1", "01", "00", "-01", "1.", ".5", "-", "-.5", "1e", "1e+", "1.e3", "--1", "1.2.3", "0x10"]:
        bad.append(String(t))
    _assert_all_refused(bad)
    # The same forms are refused inside a container, too.
    assert_true(_refused(String("[01]")))
    assert_true(_refused(String('{"a":1.}')))


# --- depth -------------------------------------------------------------------


def _nested(depth: Int) -> String:
    var s = String()
    for _ in range(depth):
        s += "["
    for _ in range(depth):
        s += "]"
    return s^


def test_nesting_up_to_the_limit_parses_and_one_more_is_refused() raises:
    var doc = JsonDoc.parse(_nested(JSON_MAX_DEPTH))
    var v = doc.root()
    for _ in range(JSON_MAX_DEPTH - 1):
        assert_equal(v.len(), 1)
        v = v.at(0)
    assert_equal(v.len(), 0)
    with assert_raises(contains="nesting deeper than"):
        _ = JsonDoc.parse(_nested(JSON_MAX_DEPTH + 1))
    assert_true(_refused(_nested(100000)))


def test_depth_counts_objects_and_siblings_do_not_accumulate() raises:
    var obj = String()
    for _ in range(JSON_MAX_DEPTH):
        obj += '{"k":'
    obj += "1"
    for _ in range(JSON_MAX_DEPTH):
        obj += "}"
    _ = JsonDoc.parse(obj)
    assert_true(_refused(String('{"k":') + obj + "}"))
    # Many shallow siblings are fine: depth is nesting, not count.
    var wide = String("[")
    for i in range(1000):
        if i > 0:
            wide += ","
        wide += "[[1]]"
    wide += "]"
    assert_equal(JsonDoc.parse(wide).root().len(), 1000)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
