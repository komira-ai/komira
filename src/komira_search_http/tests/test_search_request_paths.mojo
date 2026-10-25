# =============================================================================
# test_search_request_paths.mojo: reading an untrusted request target
# =============================================================================
#
# The path helpers see bytes a client chose. Each test names the input and the
# answer it must get:
#   * strip_query cuts at the first '?', whatever follows, and copes with a
#     megabyte of path;
#   * split_path accepts exactly `/seg/seg` with one optional trailing '/', and
#     answers an empty list (no route) for a missing leading slash, an empty
#     segment, more than 8 segments or a path over 4096 bytes;
#   * is_valid_index_name accepts 1 to 255 bytes of a-z, 0-9, '.', '_', '-'
#     starting with a letter or digit, and refuses everything else, including
#     '%' (a percent-escape is never decoded, so it is never a name);
#   * body_too_large is true strictly above the limit;
#   * unsupported_query_param is false for no query and for refresh, pretty,
#     human and error_trace (with or without a value), and true for any other
#     name, including an escaped spelling and a name that only starts like an
#     allowed one;
#   * count_ndjson_lines counts non-empty lines, whatever the line ending.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_search_http.request_path import (
    body_too_large,
    count_ndjson_lines,
    unsupported_query_param,
    is_valid_index_name,
    split_path,
    strip_query,
)


def test_strip_query_cuts_at_the_first_question_mark() raises:
    assert_equal(strip_query(String("/a/_bulk")), String("/a/_bulk"))
    assert_equal(strip_query(String("/a/_bulk?x=1")), String("/a/_bulk"))
    assert_equal(strip_query(String("/a/_bulk?x=1?y=2")), String("/a/_bulk"))
    assert_equal(strip_query(String("?x")), String(""))
    assert_equal(strip_query(String("")), String(""))
    assert_equal(strip_query(String("/a?/b")), String("/a"))


def test_strip_query_on_a_huge_path() raises:
    # A smoke test: it checks the answer for a megabyte of path. It cannot
    # fail on slowness, and the linear cost of strip_query is by construction
    # (one pass), not proved by this test.
    var long = String("/") + String("a" * 1_000_000) + String("?q")
    var cut = strip_query(long)
    assert_equal(cut.byte_length(), 1_000_001)


def test_split_path_accepts_the_two_segment_shape() raises:
    var s = split_path(String("/idx/_bulk"))
    assert_equal(len(s), 2)
    assert_equal(s[0], String("idx"))
    assert_equal(s[1], String("_bulk"))
    var t = split_path(String("/idx/_search/"))
    assert_equal(len(t), 2)
    assert_equal(t[1], String("_search"))


def test_split_path_refuses_odd_shapes() raises:
    assert_equal(len(split_path(String(""))), 0)
    assert_equal(len(split_path(String("/"))), 0)
    assert_equal(len(split_path(String("idx/_bulk"))), 0)
    assert_equal(len(split_path(String("//idx/_bulk"))), 0)
    assert_equal(len(split_path(String("/idx//_bulk"))), 0)
    assert_equal(len(split_path(String("/idx/_bulk//"))), 0)
    assert_equal(len(split_path(String("///"))), 0)


def test_split_path_bounds_segments_and_length() raises:
    assert_equal(len(split_path(String("/a/b/c/d/e/f/g/h"))), 8)
    assert_equal(len(split_path(String("/a/b/c/d/e/f/g/h/i"))), 0)
    var many = String("")
    for _i in range(100_000):
        many += String("/a")
    assert_equal(len(split_path(many)), 0)
    var long = String("/") + String("a" * 5000)
    assert_equal(len(split_path(long)), 0)
    var ok = String("/") + String("a" * 4000)
    assert_equal(len(split_path(ok)), 1)
    # The limit is 4096 bytes including the leading '/'.
    assert_equal(len(split_path(String("/") + String("a" * 4095))), 1)
    assert_equal(len(split_path(String("/") + String("a" * 4096))), 0)


def test_valid_index_names() raises:
    assert_true(is_valid_index_name(String("docs")))
    assert_true(is_valid_index_name(String("a")))
    assert_true(is_valid_index_name(String("0")))
    assert_true(is_valid_index_name(String("my-index_v1.2")))
    assert_true(is_valid_index_name(String("a" * 255)))


def test_invalid_index_names() raises:
    assert_false(is_valid_index_name(String("")))
    assert_false(is_valid_index_name(String("a" * 256)))
    assert_false(is_valid_index_name(String("Docs")))
    assert_false(is_valid_index_name(String("-a")))
    assert_false(is_valid_index_name(String("_a")))
    assert_false(is_valid_index_name(String(".a")))
    assert_false(is_valid_index_name(String(".")))
    assert_false(is_valid_index_name(String("..")))
    assert_false(is_valid_index_name(String("a b")))
    assert_false(is_valid_index_name(String("a/b")))
    assert_false(is_valid_index_name(String("a\\b")))
    assert_false(is_valid_index_name(String("a%2Fb")))
    assert_false(is_valid_index_name(String("a*")))
    assert_false(is_valid_index_name(String("a?")))
    assert_false(is_valid_index_name(String("a#")))
    assert_false(is_valid_index_name(String("a,b")))
    assert_false(is_valid_index_name(String("a:b")))
    assert_false(is_valid_index_name(String("a") + chr(0) + String("b")))
    assert_false(is_valid_index_name(String("a\nb")))
    assert_false(is_valid_index_name(String("café")))


def test_body_limit_is_strict() raises:
    assert_false(body_too_large(0, 10))
    assert_false(body_too_large(10, 10))
    assert_true(body_too_large(11, 10))


def test_unsupported_query_params() raises:
    assert_false(unsupported_query_param(String("/a/_bulk")))
    assert_false(unsupported_query_param(String("/a/_bulk?")))
    assert_false(unsupported_query_param(String("/a/_bulk?&&")))
    assert_false(unsupported_query_param(String("/a/_bulk?refresh")))
    assert_false(unsupported_query_param(String("/a/_bulk?refresh=wait_for")))
    assert_false(unsupported_query_param(String("/a?pretty&human=true&error_trace=1")))
    assert_true(unsupported_query_param(String("/a?size=1")))
    assert_true(unsupported_query_param(String("/a?pretty&size=1")))
    assert_true(unsupported_query_param(String("/a?size")))
    assert_true(unsupported_query_param(String("/a?=x")))
    assert_true(unsupported_query_param(String("/a?prettyx")))
    assert_true(unsupported_query_param(String("/a?pret")))
    assert_true(unsupported_query_param(String("/a?%72efresh=true")))
    assert_true(unsupported_query_param(String("/a?refresh=1&q=x")))
    # Only the part after the FIRST '?' is the query string.
    assert_true(unsupported_query_param(String("/a?pretty?size=1")))
    assert_false(unsupported_query_param(String("/size=1/a")))


def test_count_ndjson_lines() raises:
    assert_equal(count_ndjson_lines(Span(List[UInt8]())), 0)
    assert_equal(count_ndjson_lines(Span(String("\n\n\n").as_bytes())), 0)
    assert_equal(count_ndjson_lines(Span(String("a").as_bytes())), 1)
    assert_equal(count_ndjson_lines(Span(String("a\n").as_bytes())), 1)
    assert_equal(count_ndjson_lines(Span(String("a\nb").as_bytes())), 2)
    assert_equal(count_ndjson_lines(Span(String("\na\n\nb\n\n").as_bytes())), 2)
    assert_equal(count_ndjson_lines(Span(String("a\r\nb\r\n").as_bytes())), 2)
    assert_equal(count_ndjson_lines(Span(String("1\n" * 100_000).as_bytes())), 100_000)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
