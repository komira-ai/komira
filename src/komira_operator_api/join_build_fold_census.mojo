# =============================================================================
# join_build_fold_census — copy census for the join BUILD-SIDE fold
# =============================================================================
#
# WHY A COUNTER AND NOT A VALUE ASSERTION. The build-side fold of a hash-join
# sink is VALUE-INVARIANT: whatever shape it uses to assemble the build side,
# the finalized hash index answers every probe identically. So a result
# assertion is structurally blind to the fold's COST — which is the whole of
# what `SemiHashJoinBuildSink.combine` got wrong (a pairwise
# `_concat_two_batches` fold, O(n^2) in bytes, over columns nobody reads).
# Only a copy census can tell "folded once" from "folded n^2 / 2 times", and
# it can do it without a wall-clock assertion on a path this cheap.
#
# ⚠ WHAT EACH NUMBER IS, EXACTLY. Neither is a model:
#
#   * BYTES — the EXACT byte length handed to each destination copy. Recorded
#     AT the copy site, one atomic add per copy operation (never per row), so
#     `bytes` is the number of build-side payload bytes the fold actually
#     moved. It is NOT DRAM traffic — a memcpy the allocator has just handed
#     back may never leave cache — and it must not be quoted as such.
#   * ALLOCS — destination buffers allocated to hold the fold's output. One
#     per allocation. A pairwise fold allocates a fresh buffer PER PAIR
#     (n - 1 of them, each larger than the last); a sized fold allocates 1.
#
# The pair is deliberate: `bytes` alone cannot distinguish "one big copy"
# from "many small ones", and `allocs` alone cannot see a fold that reuses a
# buffer. Together they pin the fold's shape, and both are INDEPENDENT of how
# the build side happened to be morselled — a fold that copies each build key
# exactly once reports the same `bytes` whether the rows arrived in 16
# batches or 64. That invariance is what the regression test asserts.
#
# Mechanism: two named `komira_counters.GlobalCounter` cells, so every module
# of the process that names them reaches the same counter. No env var.
#
# ⚠ PROCESS-GLOBAL, SO A READER MUST RESET FIRST. The counters accumulate
# across every fold in the process; a test reads a DELTA, not an absolute.
# =============================================================================

from komira_counters.global_counter import GlobalCounter


comptime _JBF_BYTES = GlobalCounter["komira_engine_join_build_fold_bytes"]
comptime _JBF_ALLOCS = GlobalCounter["komira_engine_join_build_fold_allocs"]


@always_inline
def join_build_fold_note_copy(n_bytes: Int) raises:
    """Record ONE build-side fold copy of `n_bytes` bytes.

    Call this AT the copy site with the byte length actually handed to the
    copy — never a per-row count and never a figure derived from the batch
    geometry, so the census stays a record of work done rather than a model
    of work intended.
    """
    _JBF_BYTES.add(n_bytes)


@always_inline
def join_build_fold_note_alloc() raises:
    """Record ONE destination buffer allocated to hold the fold's output."""
    _JBF_ALLOCS.incr()


def join_build_fold_bytes() raises -> Int:
    """Read the process-wide build-side fold byte count."""
    return _JBF_BYTES.read()


def join_build_fold_allocs() raises -> Int:
    """Read the process-wide build-side fold destination-allocation count."""
    return _JBF_ALLOCS.read()


def reset_join_build_fold_census() raises:
    """Reset both process-wide counters to 0 (test setup). A reader MUST call
    this first — the counters are process-global and every fold in the process
    accumulates into them."""
    _JBF_BYTES.reset()
    _JBF_ALLOCS.reset()
