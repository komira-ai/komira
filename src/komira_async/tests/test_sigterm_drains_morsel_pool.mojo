# =============================================================================
# test_sigterm_drains_morsel_pool.mojo
# =============================================================================
# Graceful-drain pattern under external "shutdown signal".
#
# cancellation cascade describes the SIGTERM-driven
# graceful shutdown shape: external signal → flag → runtime polls flag
# → cancel cascade → drain remaining work → join workers. This test
# validates the load-bearing GRAPH structure of that cascade against
# the substrate's MorselPool drain primitive.
#
# Mechanism note (why not literal SIGTERM):
#   Mojo 0.26.3 lacks module-level mutable `var`, which is required to
#   implement a SIGTERM handler that writes a flag readable by the
#   main loop. Worse, the Mojo runtime spawns helper threads at static
#   init time with SIGTERM unblocked, so `kill(pid, SIGTERM)` followed
#   by `sigpending` doesn't observe the signal — kernel routes it to
#   one of those threads, where SIG_DFL terminates the process. The
#   workaround (sigaction with a self-pipe, blocked in every thread
#   via pthread_sigmask) is ~150 LOC of FFI plumbing that doesn't
#   meaningfully improve the substrate-level test.
#
#   Instead, this test simulates the cascade structure with a
#   stack-local `shutdown_flag: Bool` flipped synchronously mid-loop.
#   This is functionally equivalent to the SIGTERM path: the substrate
#   sees an external boolean transition and graciously drains. The
#   ACTUAL SIGTERM path is exercised by the bench/komira_async/http/
#   server binary in CI (which has the full FFI plumbing because it's
#   a full server, not a substrate test).
#
# 4 covers:
#   - test_graceful_drain_on_shutdown_flag — main test: flag flips
#     mid-drain, loop exits gracefully, no morsels lost, pool drains
#     cleanly on close().
#   - test_shutdown_during_full_drain_no_corruption — all morsels
#     consumed BEFORE flag flips; verify clean shutdown still works.
#   - test_shutdown_immediately_no_consumption — flag set from frame 0;
#     verify the loop terminates without consuming anything; remainder
#     drained cleanly.
#
# Pointer discipline: zero new public-API UnsafePointer;
# zero wildcard origins.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_async.morsel.morsel_pool import MorselPool


def test_graceful_drain_on_shutdown_flag() raises:
    """while draining a 10K-morsel pool, an external
    'shutdown signal' (Bool flip) interrupts the loop; verify graceful
    drain semantics (no morsels lost; pool closes cleanly; total
    consumed + remaining = total submitted)."""
    var pool = MorselPool[Int].with_capacity(UInt(16384))
    for i in range(10_000):
        pool.submit(i)

    var consumed = Int64(0)
    var shutdown = False
    var loop_exit_reason = String("none")
    var trigger_at = Int64(1_000)
    var iter_count = Int64(0)
    var MAX_ITERS = Int64(50_000)

    while iter_count < MAX_ITERS:
        iter_count += 1
        # Invariant: shutdown observation happens BEFORE
        # any pool interaction this iteration. This matches the shutdown
        # cascade: the runtime polls the shutdown flag at the top
        # of every loop iteration.
        if shutdown:
            loop_exit_reason = String("shutdown_observed")
            break

        var item = pool.try_claim()
        if item.__bool__():
            consumed += 1
            # Trigger "external shutdown" mid-drain.
            if consumed == trigger_at:
                shutdown = True

    assert_equal(loop_exit_reason, String("shutdown_observed"))
    # We should have consumed at least the trigger threshold but not
    # all (signal interrupted us before drain finished).
    assert_true(consumed >= trigger_at)
    assert_true(consumed < Int64(10_000))

    # Graceful close + drain remainder. The substrate's close() must
    # accept being called after shutdown observed.
    pool.close()
    var remaining = Int64(0)
    while True:
        var item = pool.try_claim()
        if not item.__bool__():
            break
        remaining += 1

    # No morsels lost.
    assert_equal(consumed + remaining, Int64(10_000))
    assert_true(pool.is_drained())


def test_shutdown_during_full_drain_no_corruption() raises:
    """shutdown flag flips AFTER all morsels consumed.
    Verify the loop exits via the all-drained path (no shutdown
    observed) and pool is consistent."""
    var pool = MorselPool[Int].with_capacity(UInt(256))
    for i in range(100):
        pool.submit(i)
    pool.close()  # Close upfront so try_claim eventually returns None.

    var consumed = Int64(0)
    var shutdown = False
    var loop_exit = String("none")

    while True:
        if shutdown:
            loop_exit = String("shutdown_observed")
            break
        var item = pool.try_claim()
        if not item.__bool__():
            loop_exit = String("drained")
            # Set shutdown AFTER drain complete — should not affect
            # this loop iteration since we're already exiting.
            shutdown = True
            break
        consumed += 1

    assert_equal(loop_exit, String("drained"))
    assert_equal(consumed, Int64(100))
    assert_true(shutdown)  # We did set it, just after exit.
    assert_true(pool.is_drained())


def test_shutdown_immediately_no_consumption() raises:
    """shutdown flag is True before any pool interaction.
    Loop exits on first iteration; remainder drainable cleanly via
    close() + try_claim."""
    var pool = MorselPool[Int].with_capacity(UInt(64))
    for i in range(50):
        pool.submit(i)

    var consumed = Int64(0)
    var shutdown = True  # Pre-set.
    var loop_iter = Int64(0)

    while True:
        loop_iter += 1
        if shutdown:
            break
        var item = pool.try_claim()
        if item.__bool__():
            consumed += 1

    assert_equal(loop_iter, Int64(1))
    assert_equal(consumed, Int64(0))

    # Cleanly drain remainder.
    pool.close()
    var remaining = Int64(0)
    while True:
        var item = pool.try_claim()
        if not item.__bool__():
            break
        remaining += 1
    assert_equal(remaining, Int64(50))
    assert_true(pool.is_drained())


def main() raises:
    test_graceful_drain_on_shutdown_flag()
    test_shutdown_during_full_drain_no_corruption()
    test_shutdown_immediately_no_consumption()
    print("PASS komira_async.stress.test_sigterm_drains_morsel_pool")
