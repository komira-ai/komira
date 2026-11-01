# =============================================================================
# komira_telemetry_read: THE DIRECT QUERY PATH over telemetry at rest.
#   A time range in. Object keys out. No service in the middle.
# =============================================================================
#
# This package is the read side of `komira_telemetry_store`: time-partitioned
# Parquet is the base at-rest artifact for logs and metrics, and any Parquet
# engine (this one, DuckDB, Polars) can query the objects directly. What such an
# engine cannot do without help is turn a time range into a set of object keys,
# because that requires replaying the manifest. So:
#
#   `plan_telemetry_scan` IS THE SHARED CODE PATH.
#   `TelemetryScanPlan.object_keys()` is the handoff; everything downstream is
#   replaceable by the reader's engine of choice.
#
# -- THE FILES ----------------------------------------------------------------
#   scan_plan.mojo     `plan_telemetry_scan`: compute the day partitions, one
#                      shard-enumeration LIST per day, exact-GET manifest replay
#                      with a forward probe past a lagging `_HEAD`, prune on the
#                      catalog entries alone. THE SURFACE.
#   segment_read.mojo  exact-key GET of the planned objects, row-group zone-map
#                      prune on the time column, IO-free Parquet decode. The
#                      convenience half.
#   log_search.mojo    `TelemetryLogSearch`: a `komira_log_query` search-seam
#                      conformer whose body is the plan, the read, a row-level
#                      filter and a sort.
#
# There is no `keys` module here. The key layout, the UTC day arithmetic and the
# catalog entry are defined ONCE, in `komira_telemetry_store`, and re-exported
# below, so a reader and a writer share one derivation. A second copy that
# disagreed about a field order or a sidecar suffix would cross-decode to wrong
# values with no error.
#
# -- WHAT A METRICS READ LOOKS LIKE -------------------------------------------
#   var plan = plan_telemetry_scan(
#       store, TELEMETRY_DATASET_METRICS, t0_ns, t1_ns,
#       TelemetrySeriesFilter.range(series_lo, series_hi),
#   )
#   var (batches, stats) = read_telemetry_segments(store, plan, "ts")
#
# The planner is schema-blind. It prunes on `min_ts_ns`/`max_ts_ns` from the
# catalog entry, and `TelemetrySeriesFilter` adds the second dimension
# (`min_series_id`/`max_series_id`) the same entry already carries. Metrics sort
# `(series_id, ts)`, so for them the row-group `ts` prune is second-order (a row
# group spans the file's whole time range) and the file-level manifest prune
# does the work. Not built here: the per-partition series side table (attribute
# joins), and a metrics batch reader with its own time column name.
#
# Value types across every public signature: String, Int64, List, RecordBatch,
# owned Slab. No pointer type.
# =============================================================================

from komira_telemetry_store.keys import (
    MAX_TELEMETRY_DAYS_PER_QUERY,
    NS_PER_DAY,
    TELEMETRY_DATA_SEGMENT,
    TELEMETRY_DATASET_LOGS,
    TELEMETRY_DATASET_METRICS,
    TELEMETRY_ROOT,
    TELEMETRY_TEXT_SEGMENT,
    day_string_from_ns,
    days_covering,
    telemetry_data_key,
    telemetry_partition_prefix,
    telemetry_text_sidecar_key,
)
from komira_telemetry_store.segment_entry import (
    TELEMETRY_SEGMENT_ENTRY_VERSION,
    TELEMETRY_UUID_BYTES,
    TelemetrySegmentEntry,
    decode_telemetry_segment_entry,
    encode_telemetry_segment_entry,
    make_log_segment_entry,
    make_metric_segment_entry,
    make_raw_segment_entry,
    uuid_in_flat,
)
from komira_telemetry_read.scan_plan import (
    TelemetryScanPlan,
    TelemetrySeriesFilter,
    plan_telemetry_scan,
)
from komira_telemetry_read.log_search import (
    TELEMETRY_LOG_MESSAGE_COLUMN,
    TELEMETRY_LOG_SOURCE_COLUMN,
    TelemetryLogSearch,
)
from komira_telemetry_read.segment_read import (
    TELEMETRY_LOG_TS_COLUMN,
    TelemetryReadStats,
    decode_telemetry_segment_bytes,
    read_telemetry_segments,
    telemetry_time_predicate,
)
