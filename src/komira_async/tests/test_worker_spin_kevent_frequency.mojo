# =============================================================================
# test_worker_spin_kevent_frequency.mojo
# =============================================================================
# Regression test for the spin-path fix (conditional-kevent guard +
# SPIN_LIMIT 64 → 8192 + drop aarch64 pause_intrinsic).
#
# What the fix does
# -----------------
# In `src/komira_async/runtime/worker.mojo:run_until_shutdown`'s inner
# spin loop, the per-iter `Reactor.poll_completions(Int32(0))` call —
# which on macOS is a `kevent(0)` syscall costing ~12.5 µs/iter, and on
# Linux is an `epoll_wait(0)` syscall costing ~1-3 µs/iter — was firing
# on EVERY spin iteration. Profiling showed this
# dominated the spin iter cost entirely, making the 64-iter spin window
# ~770 µs on an M3 Ultra and causing workers to park between IO-class
# dispatches (gap ~390 µs). With the worker parked, the `wake_with_elision`
# fast-path missed, firing the eventfd-wake syscall every dispatch
# (~50-70 µs wake cost per dispatch).
#
# Fix: guard the kevent call with `if (spun & 0x3F) == 0` (every
# 64th iter only). This drops the per-iter cost to ~2 ns (atomic load
# only) and lets SPIN_LIMIT safely grow to 8192 — covering ~1.5 ms of
# inter-dispatch gap without parking, at negligible idle-CPU cost.
#
# What this test asserts
# ----------------------
# After running exactly N=1024 iterations of the spin body (via the
# test-only `_test_run_spin_iters` helper on Worker), the
# `spin_kevent_call_count()` counter should equal `ceil(N / 64) = 16`
# (kevent fires on iters 0, 64, 128, …, 960 = 16 fires total).
#
# Without the guard, the unguarded call would have fired the kevent on every iter
# (count = N = 1024). The assertion `kevent_count <= ceil(N/64) + 1` is
# a 64-fold tighter bound than the unguarded behavior.
#
# Why this test is the load-bearing regression test
# ----------------------------------------------
# The bug being fixed is a PERFORMANCE bug (each spin iter does too
# much work); the symptom is "wake_with_elision misses IO-class
# inter-dispatch gaps". The structural assertion — that kevent fires
# at the bounded rate (1 per 64 iters) — is the cheapest empirical
# probe of the fix without resorting to a microbenchmark.
# =============================================================================

from std.testing import assert_equal, assert_true

from std.sys.info import CompilationTarget

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    BACKEND_MOCK,
)
from komira_async.runtime.worker import Worker


# =============================================================================
# Helpers
# =============================================================================


def _backend_for_platform() -> UInt8:
    """Select the real-IO backend for the platform the test is running
    on. On Mac we want BACKEND_KQUEUE so `poll_completions(Int32(0))`
    actually fires a `kevent(timeout=0)` syscall; on Linux we want
    BACKEND_EPOLL so it fires `epoll_wait(timeout=0)`. BACKEND_MOCK
    short-circuits inside `Reactor.poll_completions` before reaching
    the syscall, which would defeat the test.
    """
    comptime if CompilationTarget.is_macos():
        return BACKEND_KQUEUE
    else:
        return BACKEND_EPOLL


# =============================================================================
# Tests
# =============================================================================


def test_spin_kevent_count_pre_run_is_zero() raises:
    """Sanity — a fresh worker has never fired a spin-phase kevent."""
    var w = Worker[NoopSink](
        worker_id=UInt16(0),
        sink=NoopSink(_placeholder=UInt8(0)),
        backend=_backend_for_platform(),
    )
    assert_equal(Int(w.spin_kevent_call_count()), 0)


def test_spin_kevent_fires_on_first_iter() raises:
    """Invariant — iter 0 has `(0 & 0x3F) == 0`, so the FIRST spin
    iter fires the kevent. After exactly 1 spin iter, kevent_count==1.
    """
    var w = Worker[NoopSink](
        worker_id=UInt16(0),
        sink=NoopSink(_placeholder=UInt8(0)),
        backend=_backend_for_platform(),
    )
    var n_spun = w._test_run_spin_iters(1)
    # The synthetic spin should run exactly 1 iter (no work arrives).
    assert_equal(n_spun, 1)
    # On iter 0, the guard fires (kevent count = 1).
    assert_equal(Int(w.spin_kevent_call_count()), 1)


def test_spin_kevent_fires_every_64th_iter() raises:
    """Invariant — over N=1024 spin iters with no work, the guarded
    kevent fires exactly ceil(N / 64) = 16 times (iters 0, 64, 128,
    192, 256, 320, 384, 448, 512, 576, 640, 704, 768, 832, 896, 960).

    This is the LOAD-BEARING regression test for the spin-path-audit
    fix. Without the guard, the unguarded call fired on every iter → count
    would have been 1024, NOT 16. A 64× reduction in syscall rate is
    the explicit intent of the fix.
    """
    var w = Worker[NoopSink](
        worker_id=UInt16(0),
        sink=NoopSink(_placeholder=UInt8(0)),
        backend=_backend_for_platform(),
    )
    var n_spun = w._test_run_spin_iters(1024)
    # All 1024 should execute (no MPSC entries, no shutdown signal).
    assert_equal(n_spun, 1024)
    # Exactly 16 kevent calls (every 64th iter, iters 0..960).
    assert_equal(Int(w.spin_kevent_call_count()), 16)


def test_spin_kevent_count_scales_linearly_with_64_cohorts() raises:
    """Invariant — at N=64, kevent fires once (iter 0 only); at
    N=65, fires twice (iter 0 + iter 64); at N=128, fires twice (iter
    0 + iter 64). Verifies the cohort boundary math.
    """
    # N=64: kevent fires once (iter 0; iter 64 is OUT of range since
    # spun < 64 means spun ∈ {0,…,63}).
    var w1 = Worker[NoopSink](
        worker_id=UInt16(0),
        sink=NoopSink(_placeholder=UInt8(0)),
        backend=_backend_for_platform(),
    )
    _ = w1._test_run_spin_iters(64)
    assert_equal(Int(w1.spin_kevent_call_count()), 1)

    # N=65: kevent fires twice (iters 0 and 64).
    var w2 = Worker[NoopSink](
        worker_id=UInt16(0),
        sink=NoopSink(_placeholder=UInt8(0)),
        backend=_backend_for_platform(),
    )
    _ = w2._test_run_spin_iters(65)
    assert_equal(Int(w2.spin_kevent_call_count()), 2)

    # N=128: kevent fires twice (iters 0 and 64; iter 128 is OUT of
    # range — spun ∈ {0,…,127}).
    var w3 = Worker[NoopSink](
        worker_id=UInt16(0),
        sink=NoopSink(_placeholder=UInt8(0)),
        backend=_backend_for_platform(),
    )
    _ = w3._test_run_spin_iters(128)
    assert_equal(Int(w3.spin_kevent_call_count()), 2)


def test_spin_kevent_rate_bound_holds_at_spin_limit_size() raises:
    """Invariant — at N = SPIN_LIMIT (8192), kevent fires
    8192 / 64 = 128 times. This matches the production spin-window
    budget: when a worker spins out its full window with no work
    arriving, it pays 128 kevent syscalls (worst-case ~1.6 ms of
    syscall on macOS @ ~12.5 µs each; ~0.13-0.4 ms on Linux @ ~1-3 µs).
    Compare to unguarded's 8192 syscalls (~100 ms macOS / 8-25 ms Linux)
    — a 64× tightening, exactly the design target.
    """
    var w = Worker[NoopSink](
        worker_id=UInt16(0),
        sink=NoopSink(_placeholder=UInt8(0)),
        backend=_backend_for_platform(),
    )
    var n_spun = w._test_run_spin_iters(8192)
    assert_equal(n_spun, 8192)
    assert_equal(Int(w.spin_kevent_call_count()), 128)


def test_spin_kevent_count_accumulates_across_invocations() raises:
    """Counter is a Worker-lifetime running total — repeated
    `_test_run_spin_iters(64)` invocations add 1 each to the counter.
    """
    var w = Worker[NoopSink](
        worker_id=UInt16(0),
        sink=NoopSink(_placeholder=UInt8(0)),
        backend=_backend_for_platform(),
    )
    _ = w._test_run_spin_iters(64)
    assert_equal(Int(w.spin_kevent_call_count()), 1)
    _ = w._test_run_spin_iters(64)
    assert_equal(Int(w.spin_kevent_call_count()), 2)
    _ = w._test_run_spin_iters(64)
    assert_equal(Int(w.spin_kevent_call_count()), 3)


def main() raises:
    test_spin_kevent_count_pre_run_is_zero()
    test_spin_kevent_fires_on_first_iter()
    test_spin_kevent_fires_every_64th_iter()
    test_spin_kevent_count_scales_linearly_with_64_cohorts()
    test_spin_kevent_rate_bound_holds_at_spin_limit_size()
    test_spin_kevent_count_accumulates_across_invocations()
    print("PASS test_worker_spin_kevent_frequency")
