# =============================================================================
# test_retry_scheduler.mojo -- FakeRetryScheduler, the clock-driven RetryScheduler.
# =============================================================================
#
# Time is a counter the test advances; nothing here waits or reads a clock.
#
#   due time     a call armed with delay d at time t is due at t + d: not one
#                second before, and at that second; calls fire in the order they
#                were armed; a call fires once.
#   dedup        arming a key that is pending returns the earlier task id and
#                records nothing; once the call has fired, or been cancelled, the
#                key can be armed again, with a new id and a due time from the
#                new now; two keys are two calls.
#   cancel       a cancelled call never comes due; cancelling an unknown or a
#                fired task is not an error.
#   boot         ensure_ready is counted, and may be called any number of times.
#   refusal      a negative delay is an error.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_raises,
    assert_true,
)

from komira_kg_enrich import FakeRetryScheduler


def test_a_call_is_due_at_now_plus_delay() raises:
    var s = FakeRetryScheduler(Int64(100))
    var id = s.schedule(Int64(30), "/drain", "{\"x\":1}", "k")
    assert_equal(s.last_due_at(), Int64(130))
    assert_equal(s.last_delay(), Int64(30))
    assert_equal(s.last_callback_path(), "/drain")
    assert_equal(s.last_payload(), "{\"x\":1}")
    s.advance(Int64(29))
    assert_equal(len(s.take_due()), 0)
    s.advance(Int64(1))
    var due = s.take_due()
    assert_equal(len(due), 1)
    assert_equal(due[0].task_id, id)
    assert_equal(due[0].due_at_seconds, Int64(130))
    assert_equal(due[0].callback_path, "/drain")
    assert_equal(due[0].payload_json, "{\"x\":1}")
    assert_equal(due[0].dedup_key, "k")
    # It fires once.
    assert_equal(len(s.take_due()), 0)
    s.advance(Int64(1000))
    assert_equal(len(s.take_due()), 0)


def test_due_calls_come_in_arming_order() raises:
    var s = FakeRetryScheduler()
    _ = s.schedule(Int64(20), "/d", "second", "b")
    _ = s.schedule(Int64(10), "/d", "first", "a")
    s.advance(Int64(15))
    var due = s.take_due()
    assert_equal(len(due), 1)
    assert_equal(due[0].payload_json, "first")
    s.advance(Int64(5))
    due = s.take_due()
    assert_equal(len(due), 1)
    assert_equal(due[0].payload_json, "second")
    # Two due together come in the order they were armed.
    _ = s.schedule(Int64(1), "/d", "x", "x")
    _ = s.schedule(Int64(1), "/d", "y", "y")
    s.advance(Int64(5))
    due = s.take_due()
    assert_equal(len(due), 2)
    assert_equal(due[0].payload_json, "x")
    assert_equal(due[1].payload_json, "y")


def test_a_pending_key_is_not_armed_twice() raises:
    var s = FakeRetryScheduler()
    var first = s.schedule(Int64(30), "/d", "p", "k")
    s.advance(Int64(10))
    var second = s.schedule(Int64(30), "/d", "p", "k")
    assert_equal(first, second)
    assert_equal(s.schedule_count(), 1)
    assert_equal(s.pending_count(), 1)
    # The due time is the first arming's, not pushed out by the second.
    assert_equal(s.last_due_at(), Int64(30))
    var other = s.schedule(Int64(30), "/d", "p", "other-key")
    assert_true(other != first)
    assert_equal(s.pending_count(), 2)


def test_a_fired_key_can_be_armed_again_from_the_new_now() raises:
    var s = FakeRetryScheduler()
    var first = s.schedule(Int64(30), "/d", "p", "k")
    s.advance(Int64(30))
    _ = s.take_due()
    s.advance(Int64(5))
    var again = s.schedule(Int64(30), "/d", "p", "k")
    assert_true(again != first)
    assert_equal(s.last_due_at(), Int64(65))
    assert_equal(s.schedule_count(), 2)
    s.advance(Int64(29))
    assert_equal(len(s.take_due()), 0)
    s.advance(Int64(1))
    assert_equal(len(s.take_due()), 1)


def test_cancel() raises:
    var s = FakeRetryScheduler()
    var id = s.schedule(Int64(10), "/d", "p", "k")
    s.cancel(id)
    s.cancel(id)
    s.cancel("no-such-task")
    assert_equal(s.pending_count(), 0)
    s.advance(Int64(100))
    assert_equal(len(s.take_due()), 0)
    # The key is free again.
    var again = s.schedule(Int64(10), "/d", "p", "k")
    assert_true(again != id)
    s.advance(Int64(10))
    assert_equal(len(s.take_due()), 1)
    s.cancel(again)


def test_ensure_ready_is_counted_and_repeatable() raises:
    var s = FakeRetryScheduler()
    s.ensure_ready()
    s.ensure_ready()
    assert_equal(s.ensure_ready_count, 2)


def test_negative_delay_is_an_error() raises:
    var s = FakeRetryScheduler()
    with assert_raises(contains="delay_seconds must not be negative"):
        _ = s.schedule(Int64(-1), "/d", "p", "k")
    assert_equal(s.schedule_count(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
