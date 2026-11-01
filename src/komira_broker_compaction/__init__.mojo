"""komira_broker_compaction: the compaction adapter over the object-store broker.

It layers the format bridge for compaction above the broker core. It exists
because compaction needs the Arrow-IPC stream decoder (`komira_op_sources`) and
the Parquet writer (`komira_parquet_writer`), neither of which `komira_broker`
may depend on: that would invert the build graph.

What lives where:
  * `komira_broker`: the compaction index (a separate compare-and-swap lineage
    under `compacted/`), the SLO back-pressure decision, dual-tier resolution
    (offset range to object key, plus the read-repair re-query), and the
    reaper reuse (`ReapWorker`). See `komira_broker/compacted_index.mojo`.
  * this package: concat and transcode (Arrow-IPC segments to Parquet), the
    `CompactionWorker` orchestration, the log-cleaner and maintenance drivers,
    and the format-aware dual-tier consume (Parquet decode, Arrow-IPC decode
    and the read-repair fetch).

Build graph (acyclic): this package depends on `komira_broker` (cores and the
compaction index), `komira_op_sources` (`decode_arrow_ipc_stream`),
`komira_parquet_writer` and `komira_parquet` (Parquet bytes encode and decode),
`komira_engine_runtime` (the predicate filter), `komira_arrow` and
`komira_objectstore`.
"""

from .transcode import (
    decode_segment_stream,
    assert_uniform_schema,
    transcode_segments_to_parquet,
)

# The CompactionWorker orchestrator (one bounded round per topic-partition) and
# the SLO back-pressure decision surface.
from .compaction_worker import (
    CompactionWorker,
    CompactionRoundResult,
)

# Dual-tier consume (compacted Parquet decode, live Arrow-IPC decode and
# read-repair) and the in-memory Parquet decoder.
from .dual_tier_consume import (
    DualTierConsumer,
    DecodedTierBatch,
    decode_compacted_parquet_bytes,
    # Compacted-tier row-group and column pruning, the cross-tier pushdown
    # consume and its aggregate row-group accounting.
    decode_compacted_parquet_bytes_pushdown,
    CompactedDecodeResult,
    DualTierPushdownResult,
)

# The log-cleaner driver (cleanup.policy=compact). It decodes cleanable `.seg`
# objects, computes the latest record per key (with a tombstone grace
# measured against the caller's `now_ms`), re-encodes the survivors as a new `.seg`, swaps the manifest chunk
# body by compare-and-swap (offsets preserved) and, after a grace period,
# garbage-collects the orphaned original `.seg`. Same shape as
# `CompactionWorker` and `RetentionPass`.
from .log_cleaner_driver import (
    ProductionLogCleaner,
    ProductionCleanResult,
    CompactionReapWorker,
)

# The run-once maintenance library a scheduled job calls once per tick. It
# enumerates the cluster's topics and dispatches the per-partition and
# per-topic drivers by cleanup.policy (delete runs RetentionPass; compact runs
# the log cleaner; compact,delete runs both; auto runs the merge scan). It is
# not a daemon. It is stateless, idempotent and safe to run concurrently (every
# write is a compare-and-swap).
from .maintenance import (
    MaintenanceSummary,
    TopicMaintenanceResult,
    enumerate_topics,
    maintain_topic,
    run_maintenance_pass,
)
