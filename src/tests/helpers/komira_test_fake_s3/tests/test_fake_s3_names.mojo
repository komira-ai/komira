# The fake's own reading of a URL-encoded name, which it applies to every
# request target and query value: `%XX` is a byte, `+` a space, and a `%`
# not followed by two hex digits is refused, so a client's encoding defect
# reaches the test as a different key, not as the right one.
from std.testing import assert_equal, assert_raises

from komira_test_fake_s3 import unquote_plus


def test_escapes_and_plus() raises:
    assert_equal(unquote_plus("lake/a%2Fb+c"), "lake/a/b c")
    assert_equal(unquote_plus("region%3Deu"), "region=eu")
    assert_equal(unquote_plus("%e2%82%ac"), "€")
    assert_equal(unquote_plus("plain"), "plain")


def test_a_bad_escape_is_refused() raises:
    with assert_raises(contains="ends inside an escape"):
        _ = unquote_plus("lake/a%4")
    with assert_raises(contains="a bad escape"):
        _ = unquote_plus("lake/a%zz")


def main() raises:
    test_escapes_and_plus()
    test_a_bad_escape_is_refused()
    print("OK")
