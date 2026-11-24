# Session: the state behind a context handle.
#
# Rows: a fresh session holds no error; set_error stores a text that
# last_error returns as a copy (changing the copy leaves the session alone);
# a second set_error replaces the first; clear_error empties it; a session
# moved to a new owner keeps its text. try_new_session, what komira_ctx_new
# hands out (None becomes the NULL handle): options the engine refuses give
# None and raise nothing, for each refused option; good options give a
# session over an engine with that worker count and no error. Session itself
# raises the engine's refusal word for word.
from std.testing import assert_equal, assert_false, assert_true

from sdk_exec.engine_options import EngineOptions

from so import Session, try_new_session


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


def test_engine_that_cannot_start_gives_no_session() raises:
    assert_false(Bool(try_new_session(EngineOptions(worker_count=0))))
    assert_false(Bool(try_new_session(EngineOptions(worker_count=-3))))
    assert_false(Bool(try_new_session(EngineOptions(memory_budget_bytes=0))))
    assert_false(Bool(try_new_session(EngineOptions(spill_directory=String("")))))


def test_engine_that_starts_gives_a_session() raises:
    var made = try_new_session(EngineOptions(worker_count=1))
    assert_true(Bool(made))
    var s = made.take()
    assert_equal(s.engine.host_profile.thread_count, 1)
    assert_false(s.has_error())
    assert_false(s.engine.catalog.has("t"))


def test_session_raises_the_engine_refusal() raises:
    var message = String()
    try:
        _ = Session(EngineOptions(worker_count=0))
    except e:
        message = String(e)
    assert_equal(
        message,
        String("ENGINE_OPTIONS_INVALID: worker_count must be at least 1, got 0"),
    )


def main() raises:
    test_fresh_session_is_empty()
    test_set_and_replace()
    test_clear()
    test_move_keeps_the_text()
    test_engine_that_cannot_start_gives_no_session()
    test_engine_that_starts_gives_a_session()
    test_session_raises_the_engine_refusal()
    print("OK")
