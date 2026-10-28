# =============================================================================
# tests/komira_log_index/test_telemetry_log_base_artifact.mojo
#   The frozen log schema's own batch, produced by the REAL transpose,
#   published as the time-partitioned Parquet base artifact.
# =============================================================================
#
# Time-partitioned Parquet is the base at-rest artifact for logs.
#
# WHY THIS FILE EXISTS AND WHY IT IS HERE. `komira_telemetry_store`'s own
# falsifier builds a batch in the frozen schema's shape, locally. That is a
# re-spelling, and a re-spelling of a frozen schema is a second thing to drift:
# the writer could keep passing while `transpose.mojo` moved underneath it.
#
# This is the one place that can name BOTH arms. `komira_telemetry_store`
# deliberately does NOT depend on `komira_log_index` (the edge runs the other
# way), and a `test_srcs` entry compiles against ITS library's deps, so the
# test that drives `log_views_to_record_batch` into `TelemetryLogSegmentWriter`
# lives on this side of the edge.
#
# WHAT WOULD OTHERWISE GO UNNOTICED. The frozen schema's `timestamp` column is
# TIMESTAMP_NS, and `log_views_to_record_batch` says so in a comment with the
# reason: "from_primitive[i64] would stamp INT64 and mismatch the schema". A
# Parquet writer that only handles INT32, INT64, FLOAT, STRING, BOOL and DECIMAL
# column tags raises on that column. The shipped log batch would then be
# unwritable as Parquet, and no test in either package alone would say so.
#
# ARRIVAL IS ASSERTED BY THE ROW'S OWN VALUES, never by a count. Every case
# reads the manifest entry's [min_ts,max_ts] against the wall-clock values the
# views carried, and CASE 1 checks the published object really is a Parquet
# file by its magic: a `row_count` assertion alone is satisfied by an entry
# naming an object that was never PUT.
#
# HERMETIC: `SharedInMemoryConditionalStore`. No cloud, no container, no thread.
# No UnsafePointer in any signature.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_collections.slab import Slab

from komira_arrow.record_batch import RecordBatch

from komira_log.engine.log_record_view import LogRecordView

from komira_log_index.transpose import (
    LOG_INDEX_TIMESTAMP_FIELD,
    log_index_schema,
    log_views_to_record_batch,
)

from komira_objectstore.cas_manifest import decode_head
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

from komira_telemetry_store.keys import (
    TELEMETRY_DATASET_LOGS,
    TELEMETRY_ROOT,
    day_string_from_ns,
)
from komira_telemetry_store.log_writer import (
    LOG_TIME_COLUMN,
    TelemetryLogSegmentWriter,
)
from komira_telemetry_store.manifest import open_partition_manifest


comptime _DAY_MS: Int64 = 1788307200_000  # 2026-09-02T00:00:00Z, milliseconds


def _view(var message: String, wall_ms: Int64) -> LogRecordView:
    """A drain-shaped `LogRecordView`. `wall_ms` is the field the transpose
    multiplies by 1e6 to produce the TIMESTAMP_NS column — the one this whole
    layout partitions and sorts on."""
    return LogRecordView(
        UInt8(2),  # level
        UInt16(0),  # flags
        UInt32(7),  # site_id
        UInt32(3),  # module_id
        UInt64(0),  # raw ticks (unused by the transpose)
        UInt64(0xABCD),  # corr_id
        wall_ms,
        message^,
        String("telemetry_binding"),
        List[String](),
        List[String](),
    )


def _one(var rb: RecordBatch) -> Slab[RecordBatch]:
    var s = Slab[RecordBatch](capacity=1)
    s.append(rb^)
    return s^


# =============================================================================
# CASE 1 — MARQUEE. Real views -> the REAL transpose -> the base artifact.
# =============================================================================


def test_01_the_frozen_log_batch_publishes_as_time_partitioned_parquet() raises:
    var store = SharedInMemoryConditionalStore()
    var w = TelemetryLogSegmentWriter[SharedInMemoryConditionalStore](
        store.clone(), String("binding-1")
    )
    # OUT of time order on purpose — the writer must impose the sort.
    var views = List[LogRecordView]()
    views.append(_view(String("third"), _DAY_MS + Int64(300)))
    views.append(_view(String("first"), _DAY_MS + Int64(100)))
    views.append(_view(String("second"), _DAY_MS + Int64(200)))

    var batch = log_views_to_record_batch(views)
    assert_equal(
        batch.num_columns(),
        8,
        "1: precondition — the FROZEN 8-column schema, straight from"
        " log_views_to_record_batch. If this ever changes, everything below is"
        " measuring a different artifact",
    )
    assert_equal(
        batch.schema.field_name(2),
        LOG_INDEX_TIMESTAMP_FIELD,
        "1: precondition — column 2 is the frozen `timestamp` field",
    )
    assert_equal(
        LOG_TIME_COLUMN,
        LOG_INDEX_TIMESTAMP_FIELD,
        "1: THE BINDING ITSELF. The telemetry writer locates its partition"
        " and sort key BY NAME; that name must be the frozen schema's. A"
        " rename in transpose.mojo goes RED here rather than silently"
        " mis-partitioning every log line ever written",
    )

    var entries = w.publish_batches(_one(batch^))
    assert_equal(len(entries), 1, "1: one day touched -> ONE base object")
    ref e = entries[0]

    # --- the object really exists, and really is Parquet ---------------------
    var bytes = store.get(Path.parse(e.object_key))
    assert_true(
        len(bytes) > 8,
        "1: the base object was PUT and is non-empty. An entry naming an"
        " absent object is the one ordering that loses data instead of bytes",
    )
    assert_equal(Int(bytes[0]), 0x50, "1: PAR1 magic byte 0 ('P')")
    assert_equal(Int(bytes[1]), 0x41, "1: PAR1 magic byte 1 ('A')")
    assert_equal(Int(bytes[2]), 0x52, "1: PAR1 magic byte 2 ('R')")
    assert_equal(Int(bytes[3]), 0x31, "1: PAR1 magic byte 3 ('1')")

    # --- the key carries the day the DATA is in ------------------------------
    assert_true(
        e.object_key.find(String("telemetry/logs/20260902/data/")) == 0,
        "1: the object key carries the UTC day of its own rows, COMPUTED from"
        " the transposed timestamps. Got: " + e.object_key,
    )
    # --- the manifest range is the views' TRUE wall-clock range, in ns -------
    assert_equal(
        e.min_ts_ns,
        (_DAY_MS + Int64(100)) * Int64(1_000_000),
        "1: min_ts_ns is the EARLIEST view's wall_ms x 1e6 — the transpose's"
        " own conversion, asserted by VALUE not by ordering",
    )
    assert_equal(
        e.max_ts_ns,
        (_DAY_MS + Int64(300)) * Int64(1_000_000),
        "1: max_ts_ns is the LATEST view's",
    )
    assert_equal(e.row_count, Int64(3), "1: every view became a row")
    assert_false(e.has_text_sidecar, "1: no sidecar asked for")
    _ = w^
    _ = store^


# =============================================================================
# CASE 2 — a fresh reader finds it by MANIFEST REPLAY and prunes by time.
# =============================================================================


def test_02_a_time_range_read_resolves_to_the_parquet_base() raises:
    var store = SharedInMemoryConditionalStore()
    var w = TelemetryLogSegmentWriter[SharedInMemoryConditionalStore](
        store.clone(), String("binding-2")
    )
    for k in range(4):
        var views = List[LogRecordView]()
        views.append(
            _view(String("flush-") + String(k), _DAY_MS + Int64(k) * Int64(60_000))
        )
        _ = w.publish_batches(_one(log_views_to_record_batch(views)))

    var r = open_partition_manifest[SharedInMemoryConditionalStore](
        store, TELEMETRY_ROOT, TELEMETRY_DATASET_LOGS,
        day_string_from_ns(_DAY_MS * Int64(1_000_000)), String("binding-2"),
    )
    # PRECONDITION, DECODED — not "a _HEAD exists". The assertion below is
    # about the forward probe, and it is only about the forward probe if the
    # durable tail actually LAGS. Measured: on an eagerly-advancing
    # substrate (`_try_append_at(..., defer_durable_advance=False)`) this case
    # stayed GREEN with nothing to probe.
    var head_raw = store.get(Path.parse(r.prefix() + "/_HEAD"))
    var durable_head = decode_head(head_raw).chunk_seq
    assert_true(
        durable_head < Int64(3),
        "2: PRECONDITION — the durable _HEAD must LAG the last published seq"
        " (3). If it does not, the four-segment assertion below is satisfied by"
        " the durably-known region alone and says nothing about the probe."
        " Observed chunk_seq = " + String(durable_head),
    )
    assert_equal(
        len(r.live_segments()),
        4,
        "2: a FRESH reader replays all four — the durable _HEAD is pinned at"
        " the first publish by the deferred-advance optimization, so a reader"
        " that trusted it would see ONE",
    )
    var hit = r.segments_overlapping(
        (_DAY_MS + Int64(120_000)) * Int64(1_000_000),
        (_DAY_MS + Int64(120_000)) * Int64(1_000_000),
    )
    assert_equal(len(hit), 1, "2: a point query selects exactly ONE segment")
    assert_true(
        hit[0].object_key.find(String(".parquet")) > 0,
        "2: and it resolves to the .parquet BASE. That is the inversion:"
        " the text split stays produced by the existing sink and stops being"
        " the artifact a time query must open. Got: " + hit[0].object_key,
    )
    assert_equal(
        hit[0].min_ts_ns,
        (_DAY_MS + Int64(120_000)) * Int64(1_000_000),
        "2: ...and it is the RIGHT segment, by its own time bound",
    )
    _ = r^
    _ = w^
    _ = store^


# =============================================================================
# CASE 3 — the frozen schema itself, so a drift in transpose.mojo is loud here.
# =============================================================================


def test_03_the_frozen_schema_still_has_its_time_column_where_we_read_it() raises:
    var schema = log_index_schema()
    assert_equal(schema.num_columns(), 8, "3: eight columns, frozen")
    assert_equal(
        schema.field_name(2),
        String("timestamp"),
        "3: the time column is named `timestamp` at position 2. The telemetry"
        " writer finds it BY NAME (position is not load-bearing for it), but"
        " the name is — and this is the assertion that ties the two packages"
        " together with no import from the writer's side",
    )
    _ = schema^


def main() raises:
    test_01_the_frozen_log_batch_publishes_as_time_partitioned_parquet()
    test_02_a_time_range_read_resolves_to_the_parquet_base()
    test_03_the_frozen_schema_still_has_its_time_column_where_we_read_it()
    print("PASS komira_log_index.test_telemetry_log_base_artifact (the FROZEN")
    print("     8-column log batch, produced by the REAL transpose, publishes")
    print("     as time-partitioned Parquet and a time-range read resolves to")
    print("     that .parquet base — not to a search split)")
