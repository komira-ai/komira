# =============================================================================
# Chunk statistics across several RecordBatches
# =============================================================================
#
# A writer that encodes N batches as one column chunk (no Arrow concat first)
# still owes the chunk its statistics. `_compute_stats_across_batches` folds
# column `col` of each batch into one `Statistics`, the one
# `_plain_statistics` (writer_encode) would give for the batches'
# concatenation:
#
#   INT32 / INT64   min/max, null_count and an HLL distinct_count with its
#                   registers (`IntStatsAccumulator`);
#   FLOAT / DOUBLE  parquet.thrift's rules, NaN never in min/max, `nan_count`,
#                   signed zero (`FloatMinMax`), and `null_count`; no HLL;
#   any other type  None (an unsigned or narrow integer's signed order is not
#                   its own, and strings are not computed here).
#
# None also for a column with no rows. A column of only nulls gets just its
# null count. Null slots never enter min/max whatever bytes they hold, and
# each batch's own offset (a sliced column) is honored.
#
# ⚠ THE FLOAT ARM IS NOT THE INTEGER ARM WITH A DIFFERENT DTYPE: a NaN-
# propagating min would take a NaN lane, and seeding from element 0 would
# seed a NaN. `FloatMinMax` owns those rules, so the float arm never uses the
# integer scan.
# =============================================================================

from komira_arrow.record_batch import RecordBatch
from komira_collections.slab import Slab
from komira_parquet_api.metadata import Statistics

from .stats import IntStatsAccumulator
from .writer_float_stats import (
    FloatMinMax,
    float_minmax_from_array,
    make_float_statistics,
)


def _compute_float_stats_across_batches[
    dtype: DType
](
    ref batches: Slab[RecordBatch],
    n_batches: Int,
    col: Int,
) raises -> Optional[Statistics]:
    """FLOAT / DOUBLE statistics of column `col` across `n_batches` batches."""
    var acc = FloatMinMax[dtype]()
    var total_rows = 0
    var total_nulls = 0
    for i in range(n_batches):
        var arr = batches[i].column_at(col).as_primitive[dtype]()
        total_rows += arr.length
        if arr.validity and arr.null_count > 0:
            total_nulls += arr.null_count
        acc.merge(float_minmax_from_array[dtype](arr, skip_nulls=True))
    if total_rows == 0:
        return None
    return Optional[Statistics](
        make_float_statistics[dtype](acc, null_count=total_nulls)
    )


def _compute_integer_stats_across_batches[
    dtype: DType
](
    ref batches: Slab[RecordBatch],
    n_batches: Int,
    col: Int,
) raises -> Optional[Statistics]:
    """INT32 / INT64 statistics of column `col` across `n_batches` batches."""
    var acc = IntStatsAccumulator[dtype]()
    var total_rows = 0
    for i in range(n_batches):
        var arr = batches[i].column_at(col).as_primitive[dtype]()
        total_rows += arr.length
        acc.add(arr)
    if total_rows == 0:
        return None
    return Optional[Statistics](acc.finish())


def _compute_stats_across_batches[
    dtype: DType
](
    ref batches: Slab[RecordBatch],
    n_batches: Int,
    col: Int,
) raises -> Optional[Statistics]:
    """The statistics of column `col` over the first `n_batches` of `batches`
    as one column chunk; see the module header for each type's rule.

    Raises:
        Error: a batch's column is not stored as `dtype`.
    """
    comptime if dtype == DType.float32 or dtype == DType.float64:
        return _compute_float_stats_across_batches[dtype](
            batches, n_batches, col
        )
    elif dtype == DType.int32 or dtype == DType.int64:
        return _compute_integer_stats_across_batches[dtype](
            batches, n_batches, col
        )
    else:
        return None
