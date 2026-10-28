# =============================================================================
# parallel_gate -- the row count below which a kernel stays serial
# =============================================================================
#
# The parallel inner probes of `parallel_inner_probe` pay a fixed cost to
# split the input into morsels, fork the pool and concatenate the per-worker
# outputs. Below `PARALLEL_THRESHOLD_ROWS` that cost exceeds what the extra
# workers save, so a caller routes such an input to the serial kernel. The
# answer is the same on both routes; only the row order of the output differs.
# =============================================================================

comptime PARALLEL_THRESHOLD_ROWS: Int = 100_000
"""The smallest input, in rows, that `should_parallelize` sends to a parallel
kernel."""


@always_inline
def should_parallelize(num_rows: Int, pool_width: Int) -> Bool:
    """True iff `num_rows` reaches `PARALLEL_THRESHOLD_ROWS` and the pool the
    kernel would fork over has more than one worker.

    Args:
        num_rows: Rows the kernel would process.
        pool_width: The dispatcher's worker count.

    Returns:
        True if the caller should take the parallel kernel.
    """
    return num_rows >= PARALLEL_THRESHOLD_ROWS and pool_width > 1
