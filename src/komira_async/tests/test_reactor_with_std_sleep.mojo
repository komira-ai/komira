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
# Each yield must also still wait (the branch exists so a caller's loop does
# not pin a core): the elapsed time is checked to be at least 10 µs.
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true
from std.time import perf_counter_ns, sleep

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    BACKEND_MOCK,
    Reactor,
)

comptime _MIN_YIELD_NS = 10_000


def test_std_sleep_waits() raises:
    """`std.time.sleep` runs in the same program as the reactor."""
    var t0 = perf_counter_ns()
    sleep(Float64(0.001))
    assert_true(perf_counter_ns() - t0 >= 1_000_000, "slept 1 ms")


def test_mock_run_once_block_intent_yields() raises:
    var r = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    var t0 = perf_counter_ns()
    assert_equal(r.run_once(timeout_us=Int32(-1)), 0)
    assert_true(perf_counter_ns() - t0 >= _MIN_YIELD_NS, "run_once(-1) yields")


def test_mock_park_on_fds_yields() raises:
    var r = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    var fds = List[Int32]()
    fds.append(Int32(-1))
    var t0 = perf_counter_ns()
    assert_equal(r.park_on_fds(fds, Int32(1000)), 0)
    assert_true(perf_counter_ns() - t0 >= _MIN_YIELD_NS, "mock park yields")


def test_park_on_fds_nothing_pollable_yields() raises:
    var backend = BACKEND_KQUEUE if CompilationTarget.is_macos() else BACKEND_EPOLL
    var r = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), backend)
    var fds = List[Int32]()
    fds.append(Int32(-1))
    var t0 = perf_counter_ns()
    assert_equal(r.park_on_fds(fds, Int32(1000)), 0)
    assert_true(
        perf_counter_ns() - t0 >= _MIN_YIELD_NS, "park with no pollable fd yields"
    )


def test_mock_poll_completions_block_intent_yields() raises:
    var r = Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    var t0 = perf_counter_ns()
    var out = r.poll_completions(Int32(-1))
    assert_equal(len(out), 0)
    assert_true(
        perf_counter_ns() - t0 >= _MIN_YIELD_NS, "poll_completions(-1) yields"
    )


def main() raises:
    test_std_sleep_waits()
    test_mock_run_once_block_intent_yields()
    test_mock_park_on_fds_yields()
    test_park_on_fds_nothing_pollable_yields()
    test_mock_poll_completions_block_intent_yields()
    print("PASS komira_async.reactor with std.time.sleep")
