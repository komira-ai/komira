# Session: the state behind a context handle.
#
# Rows: a fresh session holds no error; set_error stores a text that
# last_error returns as a copy (changing the copy leaves the session alone);
# a second set_error replaces the first; clear_error empties it; a session
# moved to a new owner keeps its text. try_new_session, what komira_ctx_new
# hands out (None becomes the NULL handle): options the engine refuses give
# None and raise nothing, for each refused option; good options give a
# session over an engine with that worker count and no error. Session itself
# raises the engine's refusal word for word. session_options, the options of
# komira_ctx_new_with_options: 0 is absent for each argument and any other
# value is passed on as given (1, a large value, -1 and INT64_MIN); a session
# over its options has exactly that worker count and memory budget, a 0 keeps
# the host's own value, and a negative worker count or budget gives no session.
from std.testing import assert_equal, assert_false, assert_true

from sdk_exec.engine_options import EngineOptions

from so import Session, session_options, try_new_session


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


def test_session_options_zero_is_absent() raises:
    var o = session_options(0, 0)
    assert_false(Bool(o.worker_count))
    assert_false(Bool(o.memory_budget_bytes))
    assert_false(Bool(o.spill_directory))


def test_session_options_pass_values_on_as_given() raises:
    var o = session_options(1, 1)
    assert_equal(o.worker_count.value(), 1)
    assert_equal(o.memory_budget_bytes.value(), 1)
    o = session_options(3, Int64(1) << 40)
    assert_equal(o.worker_count.value(), 3)
    assert_equal(o.memory_budget_bytes.value(), 1 << 40)
    o = session_options(-1, Int64.MIN)
    assert_equal(o.worker_count.value(), -1)
    assert_equal(o.memory_budget_bytes.value(), Int(Int64.MIN))
    # Each argument is its own option: one absent, the other given.
    o = session_options(0, 7)
    assert_false(Bool(o.worker_count))
    assert_equal(o.memory_budget_bytes.value(), 7)
    o = session_options(7, 0)
    assert_equal(o.worker_count.value(), 7)
    assert_false(Bool(o.memory_budget_bytes))


def test_a_session_over_session_options_has_them() raises:
    var made = try_new_session(session_options(2, 1 << 20))
    assert_true(Bool(made))
    var s = made.take()
    assert_equal(s.engine.host_profile.thread_count, 2)
    assert_equal(s.engine.host_profile.memory_budget_bytes, 1 << 20)
    # A 0 keeps the host's own value: for the budget, the default of the
    # hardware that session's own probe measured (available RAM moves
    # between two probes, so it is not compared with another session's).
    var host = Session()
    var kept = try_new_session(session_options(1, 0))
    assert_true(Bool(kept))
    var k = kept.take()
    assert_equal(k.engine.host_profile.thread_count, 1)
    assert_equal(
        k.engine.host_profile.memory_budget_bytes,
        max(1, k.engine.host_profile.hardware.default_memory_budget()),
    )
    var budget_only = try_new_session(session_options(0, 4096))
    assert_true(Bool(budget_only))
    var b = budget_only.take()
    assert_equal(b.engine.host_profile.memory_budget_bytes, 4096)
    assert_equal(
        b.engine.host_profile.thread_count,
        host.engine.host_profile.thread_count,
    )


def test_negative_session_options_give_no_session() raises:
    assert_false(Bool(try_new_session(session_options(-1, 0))))
    assert_false(Bool(try_new_session(session_options(0, -1))))
    assert_false(Bool(try_new_session(session_options(Int64.MIN, 0))))
    assert_false(Bool(try_new_session(session_options(0, Int64.MIN))))


def main() raises:
    test_fresh_session_is_empty()
    test_set_and_replace()
    test_clear()
    test_move_keeps_the_text()
    test_engine_that_cannot_start_gives_no_session()
    test_engine_that_starts_gives_a_session()
    test_session_raises_the_engine_refusal()
    test_session_options_zero_is_absent()
    test_session_options_pass_values_on_as_given()
    test_a_session_over_session_options_has_them()
    test_negative_session_options_give_no_session()
    print("OK")
