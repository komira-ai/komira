# =============================================================================
# concat_schema_check: the concat's input precondition, as a refusal.
# =============================================================================
#
# The concat kernels read column `c` of EVERY input batch, and take the column
# types from one schema batch. A batch with fewer columns would be read out of
# range, and a batch whose column has another type would be read through the
# wrong layout (an INT32 column copied as INT64, a fixed-width column read as
# STRING offsets). Both used to produce a result or a crash rather than an
# error, so the check lives here and runs once, before any buffer is allocated
# or any dispatch is made.
#
# It is a LEAF on purpose: `_concat_impl` must not gain control flow of its own
# (see `concat_fan_plan._concat_fan_plan`).
# =============================================================================

from komira_arrow.schema import RecordBatch
from komira_collections.slab import Slab


def _check_batches_share_schema(
    imm batches: Slab[RecordBatch], schema_idx: Int, num_cols: Int
) raises:
    """Raise unless every batch can be concatenated with the schema batch.

    Every batch, empty or not, must have exactly `num_cols` columns (the
    kernels index the column of each batch before they look at its row count).
    A batch with rows must also carry, for each column, the same `arrow_type`
    as `batches[schema_idx]`. A zero-row batch may carry any type: it
    contributes no values and no kernel reads its layout.

    Args:
        batches: The input batches.
        schema_idx: The batch that supplies the column types: the first with
            rows and columns.
        num_cols: That batch's column count.

    Raises:
        Error: naming the batch, the column and the two types or counts.
    """
    ref schema_batch = batches[schema_idx]
    for i in range(len(batches)):
        ref b = batches[i]
        if b.num_columns() != num_cols:
            raise Error(
                "concat_record_batches_column_parallel: batch " + String(i)
                + " has " + String(b.num_columns()) + " column(s), but the"
                " schema batch " + String(schema_idx) + " has "
                + String(num_cols) + "; every batch must have the same columns"
            )
        if i == schema_idx or b.num_rows() == 0:
            continue
        for c in range(num_cols):
            if b.column_at(c).arrow_type != schema_batch.column_at(c).arrow_type:
                raise Error(
                    "concat_record_batches_column_parallel: column "
                    + String(c) + " of batch " + String(i) + " is "
                    + String(b.column_at(c).arrow_type) + ", but the schema"
                    " batch " + String(schema_idx) + " has "
                    + String(schema_batch.column_at(c).arrow_type)
                    + "; every batch must have the same column types"
                )
