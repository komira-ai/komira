# Session: the state behind a context handle.
#
# Rows: a fresh session holds no error; set_error stores a text that
# last_error returns as a copy (changing the copy leaves the session alone);
# a second set_error replaces the first; clear_error empties it; a session
# moved to a new owner keeps its text.
from std.testing import assert_equal, assert_false, assert_true

from komira_so import Session


def test_fresh_session_is_empty() raises:
    var s = Session()
    assert_false(s.has_error())
    assert_equal(s.last_error(), String(""))


def test_set_and_replace() raises:
    var s = Session()
    s.set_error(String("first"))
    assert_true(s.has_error())
    assert_equal(s.last_error(), String("first"))
    var copy = s.last_error()
    copy += " edited"
    assert_equal(s.last_error(), String("first"))
    s.set_error(String("second"))
    assert_equal(s.last_error(), String("second"))


def test_clear() raises:
    var s = Session()
    s.set_error(String("boom"))
    s.clear_error()
    assert_false(s.has_error())
    assert_equal(s.last_error(), String(""))


def test_move_keeps_the_text() raises:
    var a = Session()
    a.set_error(String("kept"))
    var b = a^
    assert_equal(b.last_error(), String("kept"))


def main() raises:
    test_fresh_session_is_empty()
    test_set_and_replace()
    test_clear()
    test_move_keeps_the_text()
    print("OK")
