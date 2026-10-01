# =============================================================================
# test_json_value.mojo: JsonValue accessors, builders and integer parsing.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_json import (
    JSON_ARRAY,
    JSON_BOOL,
    JSON_NULL,
    JSON_NUMBER,
    JSON_OBJECT,
    JSON_STRING,
    JsonValue,
    parse_int64_text,
    parse_json_value,
    parse_uint64_text,
)


def _err_of_int64(s: String) -> String:
    try:
        _ = parse_int64_text(s)
    except e:
        return String(e)
    return String("")


def _err_of_uint64(s: String) -> String:
    try:
        _ = parse_uint64_text(s)
    except e:
        return String(e)
    return String("")


def _nan() -> Float64:
    var z = Float64(0.0)
    return z / z


def _says(msg: String, needle: String) -> Bool:
    return msg.find(needle) >= 0


def test_int64_bounds() raises:
    assert_equal(
        parse_int64_text("-9223372036854775808"), Int64(-9223372036854775808)
    )
    assert_equal(
        parse_int64_text("9223372036854775807"), Int64(9223372036854775807)
    )
    assert_equal(parse_int64_text("+42"), Int64(42))
    assert_equal(parse_int64_text("-0"), Int64(0))
    assert_equal(parse_int64_text("007"), Int64(7))
    assert_true(_says(_err_of_int64("9223372036854775808"), "out of range"))
    assert_true(_says(_err_of_int64("-9223372036854775809"), "out of range"))
    assert_true(_says(_err_of_int64("99999999999999999999"), "out of range"))
    assert_true(_says(_err_of_int64(""), "empty"))
    assert_true(_says(_err_of_int64("-"), "no digits"))
    assert_true(_says(_err_of_int64("1.0"), "non-digit"))
    assert_true(_says(_err_of_int64("1e3"), "non-digit"))
    assert_true(_says(_err_of_int64(" 1"), "non-digit"))
    print("  test_int64_bounds: PASS")


def test_uint64_bounds() raises:
    assert_equal(
        parse_uint64_text("18446744073709551615"), UInt64(18446744073709551615)
    )
    assert_equal(parse_uint64_text("0"), UInt64(0))
    assert_true(_says(_err_of_uint64("18446744073709551616"), "out of range"))
    assert_true(_says(_err_of_uint64("-1"), "non-digit"))
    assert_true(_says(_err_of_uint64("+"), "no digits"))
    print("  test_uint64_bounds: PASS")


def test_accessors_from_parsed_values() raises:
    var doc = parse_json_value(
        '{"n":-17,"s":"-17","u":"18446744073709551615","f":2.5,'
        + '"b":true,"z":null,"a":[1,2]}'
    )
    assert_equal(doc.get("n").as_int64(), Int64(-17))
    # proto3 JSON carries int64 as a string: both forms read.
    assert_equal(doc.get("s").as_int64(), Int64(-17))
    assert_equal(doc.get("u").as_uint64(), UInt64(18446744073709551615))
    assert_equal(doc.get("f").as_float64(), Float64(2.5))
    assert_true(doc.get("b").as_bool())
    assert_true(doc.get("z").is_null())
    assert_equal(doc.value_kind(0), JSON_NUMBER)
    assert_equal(doc.value_kind(1), JSON_STRING)
    assert_equal(doc.value_kind(4), JSON_BOOL)
    assert_equal(doc.value_kind(5), JSON_NULL)
    assert_equal(doc.value_kind(6), JSON_ARRAY)
    assert_equal(doc.kind_tag(), JSON_OBJECT)
    assert_true(doc.get("n").is_number())
    assert_true(doc.get("s").is_string())
    assert_true(doc.get("b").is_bool())
    print("  test_accessors_from_parsed_values: PASS")


def _raises(msg: String, needle: String, label: String) raises:
    assert_true(
        msg.find(String("JsonError: ")) == 0 and msg.find(needle) >= 0,
        label + ": got '" + msg + "'",
    )


def test_wrong_kind_raises() raises:
    var doc = parse_json_value('{"a":[1],"s":"x"}')
    var m = String("")
    try:
        _ = doc.get("missing")
    except e:
        m = String(e)
    _raises(m, "no key 'missing'", "get missing")
    m = String("")
    try:
        _ = doc.get("s").as_int64()
    except e:
        m = String(e)
    _raises(m, "non-digit", "as_int64 of 'x'")
    m = String("")
    try:
        _ = doc.get("a").get("k")
    except e:
        m = String(e)
    _raises(m, "get() on a non-object", "get on array")
    m = String("")
    try:
        _ = doc.get("a").element_at(1)
    except e:
        m = String(e)
    _raises(m, "out of range", "element_at oob")
    m = String("")
    try:
        _ = doc.get("s").as_bool()
    except e:
        m = String(e)
    _raises(m, "non-bool", "as_bool of string")
    m = String("")
    try:
        _ = doc.key_at(2)
    except e:
        m = String(e)
    _raises(m, "out of range", "key_at oob")
    # The non-raising counts are 0 for the wrong kind.
    assert_equal(doc.array_len(), 0)
    assert_equal(doc.get("a").num_members(), 0)
    assert_false(doc.get("a").has("k"))
    print("  test_wrong_kind_raises: PASS")


def test_builders_and_serialize() raises:
    var obj = JsonValue.empty_object()
    obj.set_member("name", JsonValue.from_string("a\"b"))
    obj.set_member("min", JsonValue.from_i64(Int64(-9223372036854775808)))
    obj.set_member("max", JsonValue.from_u64(UInt64(18446744073709551615)))
    obj.set_member("pi", JsonValue.from_f64(Float64(0.25)))
    obj.set_member("nan", JsonValue.from_f64(_nan()))
    obj.set_member("ok", JsonValue.from_bool(True))
    var arr = JsonValue.empty_array()
    arr.push(JsonValue.null())
    arr.push(JsonValue.from_i64(Int64(0)))
    obj.set_member("list", arr^)
    var text = obj.serialize()
    assert_equal(
        text,
        String(
            '{"name":"a\\"b","min":-9223372036854775808,'
            + '"max":18446744073709551615,"pi":0.25,"nan":null,"ok":true,'
            + '"list":[null,0]}'
        ),
    )
    # It parses back to the same values.
    var back = parse_json_value(text)
    assert_equal(back.get("min").as_int64(), Int64(-9223372036854775808))
    assert_equal(back.get("max").as_uint64(), UInt64(18446744073709551615))
    assert_true(back.get("nan").is_null())
    # Builders refuse the wrong kind.
    var m = String("")
    try:
        var s = JsonValue.from_string("x")
        s.push(JsonValue.null())
    except e:
        m = String(e)
    _raises(m, "push() on a non-array", "push on string")
    m = String("")
    try:
        var a = JsonValue.empty_array()
        a.set_member("k", JsonValue.null())
    except e:
        m = String(e)
    _raises(m, "set_member() on a non-object", "set_member on array")
    # write_to appends to an existing buffer.
    var buf = List[UInt8]()
    buf.append(0x3E)  # '>'
    JsonValue.from_bool(False).write_to(buf)
    assert_equal(String(unsafe_from_utf8=Span(buf)), String(">false"))
    print("  test_builders_and_serialize: PASS")


def test_copy_is_deep() raises:
    var a = parse_json_value('{"k":[1,{"x":"y"}]}')
    var b = a.copy()
    b.children[0].children[1].children[0].text = String("changed")
    assert_equal(a.get("k").element_at(1).get("x").as_string(), String("y"))
    assert_equal(b.get("k").element_at(1).get("x").as_string(), String("changed"))
    print("  test_copy_is_deep: PASS")


def main() raises:
    print("test_json_value")
    test_int64_bounds()
    test_uint64_bounds()
    test_accessors_from_parsed_values()
    test_wrong_kind_raises()
    test_builders_and_serialize()
    test_copy_is_deep()
    print("test_json_value: ALL PASS")
