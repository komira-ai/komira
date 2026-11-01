# =============================================================================
# test_reactor_with_std_sleep.mojo
# =============================================================================
# One program both drives the reactor's ~10 µs yield branches and calls
# `std.time.sleep`.
#
# A program holds one foreign declaration per symbol. When the reactor made
# its own `nanosleep` declaration (timespec as a byte pointer, an Int32
# return), it disagreed with the standard library's, and a binary that
# reached both failed to build. This file IS that binary: it is welded into
# komira_async's build, so the library cannot build while the reactor
# redeclares `nanosleep` with another signature. Each yield branch is
# reached below, so each one is compiled into this program:
#   * run_once(-1) on the mock backend,
#   * park_on_fds on the mock backend,
#   * park_on_fds with no pollable fd on a real backend,
#   * poll_completions(-1) on the mock backend.
# Each test asserts the call's return value and that the call came back. None
# asserts that the branch slept: that needs a clock or a sleep-call counter in
# the reactor, and the file's subject is that the program links and runs, so
# the tests are named for what they check.
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import assert_equal
from std.time import sleep

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    BACKEND_MOCK,
    Reactor,
)

def test_std_sleep_links_with_the_reactor() raises:
    """`std.time.sleep` and a reactor poll run in the same program."""
    sleep(Float64(0.001))
    var r = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    assert_equal(r.run_once(timeout_us=Int32(0)), 0)


def test_mock_run_once_block_intent_returns_zero() raises:
    var r = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    assert_equal(r.run_once(timeout_us=Int32(-1)), 0)


def test_mock_park_on_fds_returns_zero() raises:
    var r = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    var fds = List[Int32]()
    fds.append(Int32(-1))
    assert_equal(r.park_on_fds(fds, Int32(1000)), 0)


def test_park_on_fds_nothing_pollable_returns_zero() raises:
    var backend = BACKEND_KQUEUE if CompilationTarget.is_macos() else BACKEND_EPOLL
    var r = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), backend)
    var fds = List[Int32]()
    fds.append(Int32(-1))
    assert_equal(r.park_on_fds(fds, Int32(1000)), 0)


def test_mock_poll_completions_block_intent_returns_empty() raises:
    var r = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    var out = r.poll_completions(Int32(-1))
    assert_equal(len(out), 0)


def main() raises:
    test_std_sleep_links_with_the_reactor()
    test_mock_run_once_block_intent_returns_zero()
    test_mock_park_on_fds_returns_zero()
    test_park_on_fds_nothing_pollable_returns_zero()
    test_mock_poll_completions_block_intent_returns_empty()
    print("PASS komira_async.reactor with std.time.sleep")
