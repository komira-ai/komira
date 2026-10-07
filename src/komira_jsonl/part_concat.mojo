# =============================================================================
# part_concat.mojo -- concatenate the JSONL readers' per-partition and
# per-chunk batches into one
# =============================================================================
#
# The parallel materializers (`columnar_materializer.mojo`) and the streaming
# reader (`streaming_source.mojo`) each read their input in parts and join the
# parts' batches with `_concat_variable_width_batches`. That concat builds its
# output column by column, so a batch with no column (a schema with no fields,
# e.g. inferred from `{}` lines) comes back with 0 rows. Here a zero-column
# join sums the parts' row counts instead: one empty record per object.
# =============================================================================

from komira_arrow.record_batch import RecordBatch
from komira_arrow.streaming_concat import (
    _concat_variable_width_batches,
)
from komira_collections.slab import Slab


def _concat_jsonl_parts(
    mut parts: Slab[Optional[RecordBatch]], k: Int
) raises -> RecordBatch:
    """Join slots [0, k) of `parts`, in order, into one batch; every slot
    is consumed (left empty).

    The schema is the first filled slot's (every part carries the reader's
    schema). With no column, the result carries the schema and the SUM of
    the parts' rows; otherwise the multi-way concat joins the columns. No
    filled slot gives an empty batch, as the concat does."""
    var first = -1
    for i in range(k):
        if parts[i]:
            first = i
            break
    if first >= 0 and parts[first].value().num_columns() == 0:
        var schema = parts[first].value().schema.copy()
        var total_rows = 0
        for i in range(k):
            if parts[i]:
                total_rows += parts[i].value().num_rows()
                _ = parts[i].take()
        var out = RecordBatch.count_only(total_rows)
        out.schema = schema^
        return out^
    # SAFETY: `parts` is borrowed mutably for the whole call, so its storage
    # is live and unmoved while the concat walks slots [0, k) (k <= its
    # length) and `.take()`s each one. The pointer never leaves this call.
    return _concat_variable_width_batches(parts._unsafe_ptr(), k)
