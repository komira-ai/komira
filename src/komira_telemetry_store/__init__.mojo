# =============================================================================
# komira_telemetry_store: THE AT-REST FORMAT FOR TELEMETRY IN AN OBJECT STORE.
# =============================================================================
#
# Time-partitioned Parquet is the base at-rest artifact for logs and metrics; a
# text index may sit beside it as an optional sidecar. There is NO SERVICE in
# front of it: any Parquet reader (this engine, DuckDB, Polars) queries the
# objects directly, and the manifest replay finds them without listing.
#
#   keys.mojo           the object-key layout: the day partition IS the index,
#                       and every key is an exact computed name.
#   segment_entry.mojo  `TelemetrySegmentEntry`: the manifest body that carries
#                       a TIME RANGE.
#   manifest.mojo       discovery by MANIFEST REPLAY, never by listing.
#   log_writer.mojo     the writer for the `logs` dataset.
#   metric_writer.mojo  the writer for the `metrics` dataset: the SAME
#                       substrate with a DIFFERENT sort key, `(series_id, ts)`.
#
# THE METRICS FACT TABLE IS HERE; THE PER-PARTITION SERIES SIDE TABLE IS NOT.
# Building it needs the attribute STRINGS, which a producer that hands over
# points carrying only an interned attribute-set id does not supply.
# `TelemetrySegmentEntry` already carries `min_series_id` / `max_series_id`:
# ONE body type across both datasets is what "one container, two schemas" means,
# and retro-fitting the series axis later would have been a body-version bump on
# live data.
# =============================================================================

from komira_telemetry_store.keys import (
    MAX_TELEMETRY_DAYS_PER_QUERY,
    NS_PER_DAY,
    NS_PER_MS,
    TELEMETRY_DATA_KEY_DEPTH,
    TELEMETRY_DATA_SEGMENT,
    TELEMETRY_DATA_SUFFIX,
    TELEMETRY_DATASET_LOGS,
    TELEMETRY_DATASET_METRICS,
    TELEMETRY_PARTITION_PREFIX_DEPTH,
    TELEMETRY_ROOT,
    TELEMETRY_START_MS_WIDTH,
    TELEMETRY_TEXT_SEGMENT,
    TELEMETRY_TEXT_SUFFIX,
    Civil,
    civil_from_day_index,
    day_end_ns,
    day_index_from_civil,
    day_index_from_ns,
    day_start_ns,
    day_string_from_day_index,
    day_string_from_ns,
    days_covering,
    telemetry_data_key,
    telemetry_key_depth,
    telemetry_partition_prefix,
    telemetry_text_sidecar_key,
    uuid_hex,
)

from komira_telemetry_store.segment_entry import (
    TELEMETRY_SEGMENT_ENTRY_VERSION,
    TELEMETRY_UUID_BYTES,
    TelemetrySegmentEntry,
    decode_telemetry_segment_entry,
    encode_telemetry_segment_entry,
    make_log_segment_entry,
    make_metric_segment_entry,
    uuid_in_flat,
)

from komira_telemetry_store.manifest import (
    TelemetryLiveEntry,
    TelemetryReadPlan,
    TelemetrySegmentManifest,
    apply_merge_input_skip,
    discover_partition_writer_ids,
    open_partition_manifest,
    plan_time_range_read,
)

from komira_telemetry_store.log_writer import (
    LOG_TIME_COLUMN,
    TELEMETRY_DEFAULT_CODEC,
    TELEMETRY_LOG_ROWS_PER_ROW_GROUP,
    TelemetryLogSegmentWriter,
)

from komira_telemetry_store.metric_writer import (
    METRIC_SERIES_COLUMN,
    METRIC_TIME_COLUMN,
    TELEMETRY_METRIC_ROWS_PER_ROW_GROUP,
    TelemetryMetricSegmentWriter,
)
