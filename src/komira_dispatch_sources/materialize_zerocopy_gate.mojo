# =============================================================================
# komira_dispatch_sources.materialize_zerocopy_gate -- the bare multi-batch
#   in-memory scan: fold the resident chunks by reference into one owned batch.
# =============================================================================
#
# The in-memory leaf resolves a multi-chunk in-memory scan to one dense
# `RecordBatch`. Its general arm copies each chunk, collects the copies morsel-
# parallel and concatenates them column-parallel: two full copies of the
# payload. When the plan is exactly a bare scan (a PLAN_SCAN root with no
# pushed projection and no pushed filter) over more than one chunk, this gate
# concatenates the chunks directly, by reference, with
# `concat_record_batches_nway_ref`: one copy, and no dispatch.
#
# The SHAPE comes from the plan; the CHUNKS come from the caller's
# `ref [o] chunks`. This module names no source type: the caller already holds
# the chunks (from an in-memory source or a scan registry payload), so it has
# already established what kind of source it is, and neither function reaches
# into the plan for bytes.
#
# Ownership: the by-ref concat reads through each chunk's column buffers (and
# their keepalives) and allocates owned output buffers, so the returned batch
# owns its bytes and outlives the source. The source chunks are borrowed,
# never moved or copied, and are intact after the fold.
#
# Both arms return the same rows in the same order; what differs is the copy
# count and whether a fork happens. The shape envelope (no pushed projection or
# filter) is kept although the caller applies those afterwards: the two arms'
# concat kernels have no pinned byte-equivalence outside it.
# =============================================================================

from komira_arrow.concat import concat_record_batches_nway_ref
from komira_arrow.record_batch import RecordBatch
from komira_collections.slab import Slab
from komira_plan_ir.logical_plan import LogicalPlan, PLAN_SCAN


def is_bare_multi_batch_in_memory_scan[
    o: Origin[mut=False]
](imm plan: LogicalPlan, ref [o] chunks: Slab[RecordBatch]) -> Bool:
    """True iff `plan` is a bare scan and `chunks` holds more than one batch.

    The shape is read from `plan`: the root is PLAN_SCAN (no operator above
    the scan) and the scan carries neither a pushed projection nor a pushed
    filter. The size is read from `chunks`. That the source is in memory is the
    caller's precondition (it holds the chunks) and is not re-asked here.

    A plan whose root is an operator, a scan with a projection or a filter, or
    zero or one chunk returns False, and the caller takes its general arm."""
    if plan.tag != PLAN_SCAN or not plan._scan:
        return False
    ref scan_data = plan.scan_data_ref()
    if scan_data.projection:
        return False
    if scan_data.filter:
        return False
    return len(chunks) > 1


def run_bare_multi_batch_in_memory_scan[
    o: Origin[mut=False]
](ref [o] chunks: Slab[RecordBatch]) raises -> RecordBatch:
    """Concatenate `chunks`, by reference and in order, into one owned dense
    `RecordBatch` (the caller checks the shape with
    `is_bare_multi_batch_in_memory_scan`).

    `chunks` is an immutable borrow forwarded to
    `concat_record_batches_nway_ref`: nothing is copied out of it before the
    concat and nothing is moved, so the source Slab can be folded again. The
    result owns its bytes.

    Raises:
        Whatever `concat_record_batches_nway_ref` raises (chunks whose column
        types disagree, an unsupported column type). That the chunks share
        column names and count is the caller's precondition.
    """
    return concat_record_batches_nway_ref(chunks)
