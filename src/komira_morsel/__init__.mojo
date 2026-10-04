"""`komira_morsel` — shared low-level package.

Shared low-level package created to break the
`komira_async ↔ komira_engine_runtime` Bazel build-graph cycle that
Phase A W.1 surfaced (see
an internal doc). Houses the
Morsel data primitive + the trait surface that BOTH sides of the cycle
need (MorselSourceImpl / MorselSinkImpl / MorselOperatorImpl), plus
the pipeline-execution context that MorselSinkImpl.combine() carries
as a method-parameter type.

Dependencies (DAG, cycle-free): komira_arrow, komira_collections,
komira_compiler, komira_core, komira_obs. ZERO deps on engine
packages or komira_async. Topologically sits between
komira_compiler/komira_obs (its deps) and komira_async /
komira_engine_runtime (its consumers).

Public API: import directly from `komira_morsel.<module>` OR via the
convenience facade re-exports below.
"""

from .morsel import Morsel, MorselArray, MorselView, MorselViewArray, split_record_batch, split_into_views
from .morsel_source import MorselSourceImpl
from .morsel_sink import MorselSinkImpl
# Streaming ADR Phase 0 (CONTRACTS-ONLY): the first-class
# streaming source / sink traits + the opaque checkpointable Offset
# (`Position`) abstraction. DISTINCT from the batch MorselSource/Sink traits
# above (additive — they do NOT overload them). No impls yet.
from .streaming_source import (
    StreamingMorselSource,
    CheckpointSerializable,
    StreamPoll,
    StreamSourceCaps,
    STREAM_POLL_ITEM,
    STREAM_POLL_IDLE,
    STREAM_POLL_WATERMARK,
    STREAM_POLL_CLOSED,
)
from .streaming_sink import (
    StreamingMorselSink,
    StepId,
    CommitToken,
    SinkClass,
    SINK_CLASS_IDEMPOTENT,
    SINK_CLASS_TRANSACTIONAL,
    SINK_CLASS_AT_LEAST_ONCE,
)
from .morsel_segment import (
    SOURCE_PARQUET,
    SOURCE_BATCH,
    SOURCE_SINK_OUTPUT,
    OP_FILTER,
    OP_PROJECT,
    OP_LIMIT,
    OP_JOIN_PROBE,
    SINK_AGG,
    SINK_SORT,
    SINK_TOPN,
    SINK_COLLECT,
    SINK_HASH_BUILD,
    SINK_PARTITION_BY,
    SINK_PARTITION_TOPN,
    SINK_SMJ_BUILD,
    SINK_ASOF_JOIN,
    ParquetSourceData,
    AggSinkData,
    SortSinkData,
    TopNSinkData,
    PartitionBySinkData,
    PartitionTopNSinkData,
    AsofJoinSinkData,
    HashBuildSinkData,
    SMJBuildSinkData,
    MorselOp,
)
from .morsel_operator import MorselOperatorImpl
from .dynamic_join_filter import DynamicJoinFilter
from .bloom_mask import bloom_mask_int64, range_mask_int64, in_list_mask_int64
from .bypass_ref import ParquetBypassRef
from .pipeline_execution import PipelineExecution
