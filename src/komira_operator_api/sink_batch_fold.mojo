# =============================================================================
# sink_batch_fold — ONE sized N-way fold for every sink that concatenates its
#                   per-worker / per-bucket batches
# =============================================================================
#
# ⛔ WHAT THIS EXISTS TO DELETE. Six sinks folded their staged batches
# PAIRWISE, inside the drain loop:
#
#     if combined:
#         var prev = combined.take()
#         combined = _concat_two_batches(prev^, b^)
#     else:
#         combined = b^
#
# `_concat_two_batches` allocates a FRESH destination per column and copies
# BOTH inputs into it, so the accumulator is re-copied at every step: batch k
# of nb is moved (nb - k) times. That is O(nb^2) destination bytes and
# `(nb - 1) * num_columns` destination allocations, each larger than the last,
# to produce a batch a single N-way concat produces in `num_columns`
# allocations and one pass. The same defect was fixed on the (dead)
# `SemiHashJoinBuildSink` build side by ``; these six sites are the
# LIVE ones — sort, topn, partition-by, and the two window partition-scan
# drivers.
#
# ⚠ THE FIX IS NOT "COPY FEWER COLUMNS". On the SEMI build side the fold was
# ALSO folding columns that `finalize` then dropped, and the landed fix
# materialised the key column alone. That half does NOT transfer here: sort,
# topn and the window kernels need the WHOLE payload. Only the quadratic half
# transfers, so this is a sized allocation + emit-at-offset — nothing is
# dropped and the output is row-for-row, byte-for-byte what the pairwise fold
# produced.
#
# ⛔ AND THE HALF THAT MAKES IT A CORRECTNESS QUESTION RATHER THAN A COST ONE.
# `_concat_two_batches` merges the per-batch VALIDITY bitmaps and sums the
# per-batch null counts for free. A hand-rolled value-only sized fill would
# silently drop both, and on THESE paths that is a wrong ANSWER, not a slow
# one: `sort_multi.mojo:232` reads `key_col._validity` to place NULLs under
# the NULLS-FIRST/LAST contract, and the partition-by kernels group on key
# equality where a null key is not equal to anything. That is exactly why this
# delegates to `concat_record_batches_nway` — the tree's audited N-way concat,
# whose every arm routes validity through `_merge_validity_nway` and carries
# `null_count`, `decimal_p/s`, the offsets buffer and the dictionary — instead
# of open-coding a memcpy loop at six sites. `test_sink_batch_fold_census.mojo`
# pins the validity half with its own fixtures.
#
# BYTE-EQUIVALENCE WITH WHAT IT REPLACES. `concat_record_batches_nway` takes
# its schema from batch 0 and visits the batches in slab order, exactly as the
# pairwise accumulator did (the accumulator is seeded from the first batch and
# folds left). Bucket-ordered callers — `partition_scan_sink_parallel` and
# `partition_scan_sink_hash_scatter`, whose bucket order IS the output sort
# order — therefore keep their ordering unchanged. Its per-column dispatcher
# `_concat_one_column_nway` falls back to the SAME pairwise `_concat_columns`
# kernel for BOOL / divergent-dictionary / nested columns, so those types are
# not merely supported, they are folded by the identical code.
# =============================================================================

from komira_arrow.concat import concat_record_batches_nway
from komira_arrow.schema import RecordBatch
from komira_collections.slab import Slab

from .join_build_fold_census import (
    join_build_fold_note_alloc,
    join_build_fold_note_copy,
)


def _batch_payload_bytes(ref b: RecordBatch) -> Int:
    """PAYLOAD bytes held by `b`'s column buffers: data + offsets + dictionary.

    ⚠ WHAT THIS IS, EXACTLY. It reads the buffers' OWN byte extents off the
    batch that was just produced — it is the size of the destination the fold
    allocated and filled, read back, not a figure derived from a row count and
    an assumed width. Validity bitmaps are DELIBERATELY excluded and the census
    says so: a bitmap is 1/64th of an INT64 column, it cannot change the
    linear-vs-quadratic verdict, and `Bitmap` exposes no byte extent to read,
    so including it would mean deriving `bytes_for_bits(length)` — a model,
    beside numbers that are measurements.
    """
    var total = 0
    for c in range(b.num_columns()):
        ref col = b.column_at(c)
        total += col._data.len()
        if col._offsets:
            total += col._offsets.value().len()
        if col._dict_data:
            total += col._dict_data.value().len()
    return total


def fold_batches_into_one(var staged: Slab[RecordBatch]) raises -> RecordBatch:
    """Fold `staged` into ONE RecordBatch in `num_columns` allocations.

    The single funnel for every sink-side batch fold. Callers stage their
    batches into a `Slab[RecordBatch]` in the order they want them
    concatenated (batches MOVE into the slab — nothing is copied by the
    staging pass) and call this once.

    Args:
        staged: The batches to fold, in output order. CONSUMED.

    Returns:
        The concatenated batch. An empty slab yields an empty `RecordBatch`;
        a one-batch slab yields that batch MOVED, with no copy and no census
        entry (the pairwise fold it replaces also copied nothing at nb == 1,
        so the two agree at every shape including this one).

    Raises:
        Whatever `concat_record_batches_nway` raises — a per-column layout
        disagreement between batches, or a nested type with no N-way kernel.
    """
    var n = len(staged)
    if n == 0:
        _ = staged^
        return RecordBatch()
    if n == 1:
        var only = staged.take_slot_unchecked(0)
        staged.set_len_unchecked(0)
        _ = staged^
        return only^

    var out = concat_record_batches_nway(staged^)

    # Census AT the fold site. One `note_alloc` per destination column buffer
    # and ONE `note_copy` carrying the destination extent this fold actually
    # allocated and wrote — never per row. Under the pairwise fold this same
    # pair, emitted per `_concat_two_batches` call, is quadratic in the batch
    # count at constant row count; that difference is the whole assertion in
    # `test_sink_batch_fold_census.mojo`.
    #
    # ⚠ The instrument is `join_build_fold_census`, and the "join" in the name
    # is HISTORY, not scope: it was built for the SEMI build fold (``)
    # and is the tree's one fold-copy census. It is shared, and its counters are
    # PROCESS-GLOBAL, so a reader resets before the window it measures.
    for _c in range(out.num_columns()):
        join_build_fold_note_alloc()
    join_build_fold_note_copy(_batch_payload_bytes(out))
    return out^
