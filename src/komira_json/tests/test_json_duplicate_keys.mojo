# =============================================================================
# test_json_duplicate_keys.mojo: `refuse_duplicate_keys` refuses an object
# that names a member twice, at any depth, comparing names after unescaping,
# and accepts the same name in two different objects.
# =============================================================================

from std.testing import assert_equal

from komira_json import JsonValue, parse_json_value, refuse_duplicate_keys


def _err_of(doc: String) raises -> String:
    var v = parse_json_value(doc)
    try:
        refuse_duplicate_keys(v)
    except e:
        return String(e)
    return String("")


def test_distinct_names_pass() raises:
    assert_equal(_err_of('{"a":1,"b":2,"c":{"a":3}}'), "")
    assert_equal(_err_of('[{"x":1},{"x":2}]'), "")
    assert_equal(_err_of('"no objects"'), "")
    assert_equal(_err_of("{}"), "")


def test_top_level_duplicate_refused() raises:
    assert_equal(
        _err_of('{"aud":"x","aud":"y"}'),
        "JsonError: duplicate object key 'aud' at line 1",
    )


def test_duplicate_reports_the_second_members_line() raises:
    assert_equal(
        _err_of('{\n"a":1,\n"b":2,\n"a":3\n}'),
        "JsonError: duplicate object key 'a' at line 4",
    )


def test_escaped_spelling_is_the_same_name() raises:
    # "\u0061" unescapes to "a": a byte comparison of the source would miss it.
    assert_equal(
        _err_of('{"a":1,"\\u0061":2}'),
        "JsonError: duplicate object key 'a' at line 1",
    )


def test_nested_object_duplicate_refused() raises:
    assert_equal(
        _err_of('{"keys":[{"kty":"EC","x":"A","x":"B"}]}'),
        "JsonError: duplicate object key 'x' at line 1",
    )
    assert_equal(
        _err_of('{"a":{"b":{"c":1,"c":2}}}'),
        "JsonError: duplicate object key 'c' at line 1",
    )


def test_built_value_has_no_line() raises:
    var v = JsonValue.empty_object()
    v.set_member("k", JsonValue.from_i64(1))
    v.set_member("k", JsonValue.from_i64(2))
    var got = String("")
    try:
        refuse_duplicate_keys(v)
    except e:
        got = String(e)
    assert_equal(got, "JsonError: duplicate object key 'k'")


def main() raises:
    test_distinct_names_pass()
    test_top_level_duplicate_refused()
    test_duplicate_reports_the_second_members_line()
    test_escaped_spelling_is_the_same_name()
    test_nested_object_duplicate_refused()
    test_built_value_has_no_line()
    print("test_json_duplicate_keys: OK")
