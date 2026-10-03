# =============================================================================
# komira_async.primitives.need_preempt — task-quota observer
# =============================================================================
# need_preempt() — the global preempt signal — and yield_if_needed().
#
# The canonical preempt-signal read path is the per-Worker accessor
# `worker.stall_detector().need_preempt()`: the ReactorStallDetector owns
# the flag (heap-stable OwnedPointer[Atomic[int32]]) and each Worker has its
# own. need_preempt() here is a no-op global free fn (always False).
#
# yield_if_needed() — convenience wrapper: if need_preempt() returns True,
# yield to per-worker run queue.
# =============================================================================

from komira_async.primitives.yield_now import yield_now


# Why not wire need_preempt() to a global OR'd atomic?
#   - Mojo 0.26.3 has no thread-locals and no proper module-globals; a
#     "global atomic" pattern would need a lazy-init holder that leaks
#     for process lifetime. Acceptable for correctness, but creates a
#     footgun for per-worker narrowing (the leak may need lift-and-relocate
#     once thread-locals or task-context passing exist).
#   - The OR-wired form would also be over-broad (worker 0 stall makes
#     need_preempt() True for tasks on worker 3) — narrowing is a
#     concern that needs a real substrate-wide convention.
#
# Plan: when thread-locals stabilize OR the substrate adopts a
# task-context-passing convention, narrow need_preempt() to read the
# calling worker's _stall_detector flag directly. Until then, callers that
# want preempt-aware behavior should read
# `worker.stall_detector().need_preempt()` at the call site.


def need_preempt() -> Bool:
    """Returns True if the calling task
    should yield (its quota consumed; reactor stall detected).

    returns False unconditionally as the GLOBAL free
    fn. The canonical preempt-signal read path is the per-Worker
    accessor `worker.stall_detector().need_preempt()` — exercised by
    the integration test. A later step may narrow this to a true
    thread-local OR-wired global once Mojo 0.26.3's thread-local story
    or the substrate's task-context convention stabilizes.
    """
    return False


def yield_if_needed() raises:
    """if need_preempt() is True, yield
    to per-worker run queue.

    no-op via the global path (see need_preempt()).
    Per-Worker yield is via `worker.stall_detector().need_preempt() ?
    yield_now()` directly at the call site. Public API shape preserved
    for per-worker narrowing.
    """
    if need_preempt():
        var op = yield_now()
        _ = op^.wait()
