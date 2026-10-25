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
#   * body_too_large is true strictly above the limit.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_search_http.request_path import (
    body_too_large,
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
