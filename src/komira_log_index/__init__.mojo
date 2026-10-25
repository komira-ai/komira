"""`komira_log_index` — the native log index: log records are transposed to a
typed columnar batch, an L0 index is built over them, and L0 splits are read
and searched.

It imports both `komira_log` (the plain `LogRecordView` seam) and
`komira_search` (the search sink, record batches and split format), so that
`komira_log` itself stays free of any search dependency. The dependency arrow
is one-way: `komira_log_index` depends on `komira_log`, never the reverse.

  * transpose: the frozen log-index schema, `log_views_to_record_batch`
    (the `List[LogRecordView]` to typed multi-column RecordBatch build, with
    the unsigned `corr_id`, `flags` and `site_id` columns widened to Int64),
    and `LogIndexBatchPlan`, the (schema, batch) value a caller drives into a
    search sink.
  * l0_index: the cheap L0 index. `L0PostingBuilder` and `L0PostingIndex` are
    the unsorted term-hash posting and its reader; `L0SegmentBuilder` builds an
    L0 split (an empty term dictionary, a populated doc store and
    fast-field region, and the posting in the additive `l0_posting` footer
    slot).
  * l0_build_task: `L0BuildTask`, a small run-to-completion task that
    transposes a batch, builds the L0 split, writes it to the store and then
    publishes its summary to the metastore.
  * l0_read: `search_l0_split`, the per-split query path for an L0 split
    (filter, sort and aggregations as on an optimized split; term-frequency
    rank instead of BM25).
  * idle_index_hook: the hook a per-core runtime fires when a worker is idle.
    It drains the worker's log ring, builds an L0 split and publishes it to the
    worker's own shard. The store is a type parameter bounded by
    `komira_objectstore`'s `CloneableConditionalWriteStore`.
"""

from komira_log_index.transpose import (
    LOG_INDEX_TEXT_FIELD,
    LOG_INDEX_SOURCE_FIELD,
    log_index_schema,
    log_views_to_record_batch,
    LogIndexBatchPlan,
    build_log_index_plan,
)
from komira_log_index.l0_index import (
    L0_POSTING_VERSION,
    L0PostingBuilder,
    L0PostingIndex,
    L0SegmentBuilder,
)
from komira_log_index.l0_build_task import (
    L0BuildTask,
    L0BuildResult,
)
from komira_log_index.l0_read import (
    search_l0_split,
)
from komira_log_index.idle_index_hook import (
    IdleIndexContext,
    InstalledIndexHook,
    install_native_index_idle_hook,
    drop_installed_hook,
    flush_all_pending_via_hook,
    DRAIN_CAP,
)
from komira_log_index.flush_stage import (
    DEFAULT_FLUSH_BYTES,
    DEFAULT_FLUSH_MS,
    DEFAULT_INFLIGHT_CAP_BYTES,
    FlushRetryPolicy,
    InFlightBytesGate,
    LogIndexFlushBuffer,
)
from komira_log_index.handoff import (
    HandoffUnit,
    LogIndexHandoff,
    offer_log_views,
)
from komira_log_index.consumer import (
    LogIndexConsumer,
    PublishStats,
)
from komira_log_index.flush_thread import (
    DEFAULT_IDLE_PARK_US,
    OffCoreFlushThread,
)
