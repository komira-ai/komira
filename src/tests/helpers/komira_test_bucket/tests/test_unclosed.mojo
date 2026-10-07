# An unclosed handle: its destructor tears down and then aborts. The abort
# itself would end this test, so the test drives the same internal path the
# destructor runs (`_teardown_unclosed`) and checks that the teardown ran and
# the abort message is the marker followed by the verdict.

from std.testing import assert_equal, assert_true

from komira_test_bucket import (
    UNCLOSED_HANDLE_MARKER,
    FakeObjectStore,
    StoreScope,
    StoreTarget,
    open_test_bucket,
)
from komira_test_run_id import FixedWallClock, RunId
from komira_test_verdict import VERDICT_CLEAN, VERDICT_LEAK


def _scope() -> StoreScope:
    return StoreScope(
        StoreTarget("http://store.invalid:9000", "r1", "test-bucket", "/c/credentials"), 600, 60
    )


comptime _ID: String = "1790000000-00000000000000bb"
comptime _PREFIX: String = "runs/1790000000-00000000000000bb/"


def test_unclosed_teardown_runs_and_builds_the_message() raises:
    var clock = FixedWallClock(1790000000)
    var b = open_test_bucket(
        RunId(String(_ID), 1790000000), _scope(), "//p:t", FakeObjectStore(), clock
    )
    var body = String("x")
    b.client().put(b.key("a.bin"), body.as_bytes())
    var msg = b._teardown_unclosed()
    assert_true(msg.startswith(String(UNCLOSED_HANDLE_MARKER) + " CLEAN"), msg)
    assert_true(msg.startswith("komira_test_bucket: UNCLOSED HANDLE (LEAK-RISK)"), msg)
    assert_true(b.is_closed())
    assert_true(not b.client().has(_PREFIX + "a.bin"), "teardown did not delete")
    assert_true(not b.client().has(_PREFIX + "_lease.textproto"), "teardown kept the lease")
    # Closed now, so the destructor that runs after this last use is silent.
    assert_equal(b.close().kind, VERDICT_CLEAN)


def test_unclosed_message_carries_a_leak() raises:
    var clock = FixedWallClock(1790000000)
    var store = FakeObjectStore()
    store.sticky_keys.append(_PREFIX + "kept.bin")
    var b = open_test_bucket(
        RunId(String(_ID), 1790000000), _scope(), "//p:t", store^, clock
    )
    var body = String("x")
    b.client().put(b.key("kept.bin"), body.as_bytes())
    var msg = b._teardown_unclosed()
    assert_true(msg.startswith(String(UNCLOSED_HANDLE_MARKER) + " LEAK"), msg)
    assert_true("kept.bin" in msg and "_lease.textproto" in msg, msg)
    assert_equal(b.close().kind, VERDICT_LEAK)


def main() raises:
    test_unclosed_teardown_runs_and_builds_the_message()
    test_unclosed_message_carries_a_leak()
    print("test_unclosed: OK")
