# =============================================================================
# komira_dispatch_sources.streaming_concat_parallel -- the column-parallel
#   RecordBatch concat, re-exported for the dispatcher.
# =============================================================================
#
# The concat lives in `komira_engine_runtime.streaming_concat_parallel`, which
# both `komira_parquet` and the dispatch packages sit above. The dispatcher's
# in-memory leaf, join and fold modules import it from here.
# =============================================================================

from komira_engine_runtime.streaming_concat_parallel import (
    concat_record_batches_column_parallel,
    concat_record_batches_column_parallel_with_schema,
)
