# =============================================================================
# komira_telemetry_read/tests/test_telemetry_log_search.mojo
#   `TelemetryLogSearch` end to end: log segments written by
#   `komira_telemetry_store`, searched through the `komira_log_query` seam.
# =============================================================================
#
# What each case would catch if it were wrong:
#   1   a term-free window returning rows in the wrong order, or the hit body
#       not being the record's `_source` JSON.
#   2   the row-level window check missing (rows outside the window returned
#       from a row group the zone map kept).
#   3   term matching other than substring on the message; `total_matches` not
#       the true count; `limit` not bounding the page.
#   4   the newest-first contract applied per object instead of globally;
#       `sources_scanned` not counting the objects fetched.
#   5   an unstable sort reordering rows whose timestamps tie.
#   6   a segment with the wrong schema silently dropped as an empty page.
#
# HERMETIC: `SharedInMemoryConditionalStore`, no cloud, no clock.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_collections.slab import Slab

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray

from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

from komira_telemetry_store.keys import TELEMETRY_DATASET_LOGS
from komira_telemetry_store.log_writer import (
    LOG_TIME_COLUMN,
    TelemetryLogSegmentWriter,
)

from komira_log_query.hit import ServiceLogQuery

from komira_telemetry_read.log_search import TelemetryLogSearch

# 2026-10-01T00:00:00Z in nanoseconds.
comptime _DAY_T0: Int64 = 1790812800_000_000_000
comptime _MS: Int64 = 1_000_000
comptime _DAY: Int64 = 86_400_000_000_000


def _log_batch(
    var messages: List[String], var ts_ns: List[Int64]
) raises -> RecordBatch:
    """A log batch of the columns: message, _source, timestamp, level,
    module, corr_id, flags, site_id. `_source` is a JSON object holding the
    message, so a search hit's `source_json` is checkable."""
    var n = len(messages)
    var sb = SchemaBuilder()
    sb.add_field(Field(String("message"), ArrowType.STRING, False))
    sb.add_field(Field(String("_source"), ArrowType.STRING, False))
    sb.add_field(Field(String("timestamp"), ArrowType.TIMESTAMP_NS, False))
    sb.add_field(Field(String("level"), ArrowType.STRING, False))
    sb.add_field(Field(String("module"), ArrowType.STRING, False))
    sb.add_field(Field(String("corr_id"), ArrowType.INT64, False))
    sb.add_field(Field(String("flags"), ArrowType.INT64, False))
    sb.add_field(Field(String("site_id"), ArrowType.INT64, False))
    var schema = sb.build()

    var sources = List[String](capacity=n)
    var levels = List[String](capacity=n)
    var modules = List[String](capacity=n)
    var i64s = List[Int64](capacity=n)
    for i in range(n):
        sources.append(String('{"m":"') + messages[i] + String('"}'))
        levels.append(String("INFO"))
        modules.append(String("telemetry"))
        i64s.append(Int64(i))

    var rb = RecordBatchBuilder.with_capacity(8)
    rb.add_column(Column.from_string(StringArray.from_strings(messages)))
    rb.add_column(Column.from_string(StringArray.from_strings(sources)))
    rb.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](
            PrimitiveArray[DType.int64].from_list(ts_ns), ArrowType.TIMESTAMP_NS
        )
    )
    rb.add_column(Column.from_string(StringArray.from_strings(levels)))
    rb.add_column(Column.from_string(StringArray.from_strings(modules)))
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(i64s.copy())
        )
    )
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(i64s.copy())
        )
    )
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(i64s^)
        )
    )
    return rb.build(schema^)


def _one_batch(var rb: RecordBatch) -> Slab[RecordBatch]:
    var s = Slab[RecordBatch](capacity=1)
    s.append(rb^)
    return s^


def _publish(
    store: SharedInMemoryConditionalStore,
    writer_id: String,
    var messages: List[String],
    var ts_ns: List[Int64],
) raises:
    var w = TelemetryLogSegmentWriter[SharedInMemoryConditionalStore](
        store.clone(), writer_id.copy(), rows_per_row_group=4
    )
    _ = w.publish_batches(_one_batch(_log_batch(messages^, ts_ns^)))


def _search(
    store: SharedInMemoryConditionalStore,
) -> TelemetryLogSearch[SharedInMemoryConditionalStore]:
    return TelemetryLogSearch[SharedInMemoryConditionalStore].app_log(
        store.clone()
    )


# =============================================================================
# CASE 1 - A TERM-FREE WINDOW IS THE PRIMARY QUERY. Rows in the window come back
# NEWEST FIRST, with `score` 0.0 and the record's JSON as the hit body, and
# `sources_scanned` counts the objects actually fetched.
# =============================================================================
def test_01_a_term_free_window_returns_newest_first() raises:
    var store = SharedInMemoryConditionalStore()
    var msgs = List[String]()
    var ts = List[Int64]()
    # Written out of order on purpose; the writer sorts, the search re-sorts
    # newest first across objects.
    for i in range(6):
        msgs.append(String("line-") + String(i))
        ts.append(_DAY_T0 + Int64(5 - i) * _MS)
    _publish(store, String("writer-a"), msgs^, ts^)

    var s = _search(store)
    var page = s.scan(
        ServiceLogQuery(_DAY_T0, _DAY_T0 + Int64(10) * _MS, String(""), 100)
    )
    assert_equal(page.total_matches, 6, "1: every row in the window matched")
    assert_equal(len(page.hits), 6, "1: and the page holds all of them")
    assert_equal(page.sources_scanned, 1, "1: one object was fetched")
    for i in range(len(page.hits)):
        assert_equal(
            page.hits[i].timestamp_ns,
            _DAY_T0 + Int64(5 - i) * _MS,
            "1: timestamp_ns DESCENDING: the seam's ordering contract",
        )
        assert_equal(page.hits[i].score, Float64(0.0), "1: no relevance here")
    assert_equal(
        page.hits[0].source_json,
        String('{"m":"line-0"}'),
        "1: the hit body is the record's `_source` JSON; the newest row is"
        " line-0",
    )
    _ = s^


# =============================================================================
# CASE 2 - THE ROW-LEVEL WINDOW CHECK IS NOT REDUNDANT. The plan prunes objects
# and the zone map prunes row groups, but a surviving row group can hold rows
# outside the window; returning them would answer a wider question than asked.
# =============================================================================
def test_02_rows_outside_the_window_are_filtered_inside_a_row_group() raises:
    var store = SharedInMemoryConditionalStore()
    var msgs = List[String]()
    var ts = List[Int64]()
    for i in range(8):
        msgs.append(String("line-") + String(i))
        ts.append(_DAY_T0 + Int64(i) * _MS)
    _publish(store, String("writer-a"), msgs^, ts^)

    # Rows 1..2 sit in the middle of a four-row group: the group survives the
    # zone map, so only the row-level check can drop rows 0 and 3.
    var s = _search(store)
    var page = s.scan(
        ServiceLogQuery(
            _DAY_T0 + Int64(1) * _MS, _DAY_T0 + Int64(2) * _MS, String(""), 100
        )
    )
    assert_equal(page.total_matches, 2, "2: only the two rows in the window")
    assert_equal(
        page.hits[0].timestamp_ns,
        _DAY_T0 + Int64(2) * _MS,
        "2: the newest in-window row first",
    )
    assert_equal(
        page.hits[1].timestamp_ns,
        _DAY_T0 + Int64(1) * _MS,
        "2: the oldest in-window row last (bounds are inclusive)",
    )
    _ = s^


# =============================================================================
# CASE 3 - A TERM IS A SUBSTRING MATCH on the raw message, not an analyzed one.
# `total_matches` is the TRUE count and `limit` truncates only the page.
# =============================================================================
def test_03_a_term_matches_by_substring_and_limit_truncates_the_page() raises:
    var store = SharedInMemoryConditionalStore()
    var msgs = List[String]()
    var ts = List[Int64]()
    for i in range(6):
        if i % 2 == 0:
            msgs.append(String("service deployed #") + String(i))
        else:
            msgs.append(String("heartbeat #") + String(i))
        ts.append(_DAY_T0 + Int64(i) * _MS)
    _publish(store, String("writer-a"), msgs^, ts^)

    var s = _search(store)
    var window_end = _DAY_T0 + Int64(10) * _MS

    var page = s.scan(
        ServiceLogQuery(_DAY_T0, window_end, String("deployed"), 100)
    )
    assert_equal(page.total_matches, 3, "3: three messages contain the term")

    # Substring, not stemming: `deploys` is NOT a substring of `deployed`.
    var stem = s.scan(
        ServiceLogQuery(_DAY_T0, window_end, String("deploys"), 100)
    )
    assert_equal(
        stem.total_matches,
        0,
        "3: matching is SUBSTRING on the raw message, so a stem does not match",
    )
    assert_equal(
        stem.sources_scanned,
        1,
        "3: and the empty page still says an object WAS fetched",
    )

    var limited = s.scan(
        ServiceLogQuery(_DAY_T0, window_end, String("deployed"), 2)
    )
    assert_equal(
        limited.total_matches, 3, "3: total_matches is the true count"
    )
    assert_equal(len(limited.hits), 2, "3: and the page is bounded by limit")
    assert_equal(
        limited.hits[0].timestamp_ns,
        _DAY_T0 + Int64(4) * _MS,
        "3: the page keeps the NEWEST matches",
    )

    # A limit below one is raised to one rather than returning nothing.
    var floor = s.scan(ServiceLogQuery(_DAY_T0, window_end, String(""), 0))
    assert_equal(len(floor.hits), 1, "3: a non-positive limit still returns one")
    _ = s^


# =============================================================================
# CASE 4 - ACROSS OBJECTS AND DAYS. Two writers and two UTC days: the newest-first
# contract is global, not per-object, and a window that prunes everything reports
# zero objects scanned.
# =============================================================================
def test_04_the_ordering_is_global_across_objects_and_days() raises:
    var store = SharedInMemoryConditionalStore()
    var a_msgs = List[String]()
    var a_ts = List[Int64]()
    a_msgs.append(String("a-1"))
    a_ts.append(_DAY_T0 + Int64(1) * _MS)
    a_msgs.append(String("a-3"))
    a_ts.append(_DAY_T0 + Int64(3) * _MS)
    _publish(store, String("writer-a"), a_msgs^, a_ts^)

    var b_msgs = List[String]()
    var b_ts = List[Int64]()
    b_msgs.append(String("b-2"))
    b_ts.append(_DAY_T0 + Int64(2) * _MS)
    b_msgs.append(String("next-day"))
    b_ts.append(_DAY_T0 + _DAY + Int64(1) * _MS)
    _publish(store, String("writer-b"), b_msgs^, b_ts^)

    var s = _search(store)
    var page = s.scan(
        ServiceLogQuery(_DAY_T0, _DAY_T0 + _DAY + Int64(10) * _MS, String(""), 100)
    )
    assert_equal(page.total_matches, 4, "4: all four rows across both days")
    assert_equal(
        page.sources_scanned, 3, "4: three objects: a (day 1), b (day 1), b (day 2)"
    )
    assert_equal(
        page.hits[0].source_json,
        String('{"m":"next-day"}'),
        "4: the newest row overall, from the later day, comes first",
    )
    assert_equal(
        page.hits[1].source_json,
        String('{"m":"a-3"}'),
        "4: then the interleaved rows of the two writers by time",
    )
    assert_equal(page.hits[2].source_json, String('{"m":"b-2"}'), "4: b-2")
    assert_equal(page.hits[3].source_json, String('{"m":"a-1"}'), "4: a-1")

    var none = s.scan(
        ServiceLogQuery(
            _DAY_T0 + Int64(30) * _DAY,
            _DAY_T0 + Int64(30) * _DAY + _MS,
            String(""),
            100,
        )
    )
    assert_equal(none.total_matches, 0, "4: nothing published that far out")
    assert_equal(
        none.sources_scanned,
        0,
        "4: and the page says NO object was fetched: 'nothing published' is"
        " distinguishable from 'nothing matched'",
    )
    _ = s^


# =============================================================================
# CASE 5 - THE SORT IS STABLE. Rows whose timestamps tie keep the order the
# segment holds them in, which is the only signal left once timestamps collide.
# =============================================================================
def test_05_rows_with_equal_timestamps_keep_segment_order() raises:
    var store = SharedInMemoryConditionalStore()
    var msgs = List[String]()
    var ts = List[Int64]()
    msgs.append(String("tie-a"))
    ts.append(_DAY_T0 + Int64(5) * _MS)
    msgs.append(String("tie-b"))
    ts.append(_DAY_T0 + Int64(5) * _MS)
    msgs.append(String("tie-c"))
    ts.append(_DAY_T0 + Int64(5) * _MS)
    msgs.append(String("older"))
    ts.append(_DAY_T0 + Int64(1) * _MS)
    _publish(store, String("writer-a"), msgs^, ts^)

    var s = _search(store)
    var page = s.scan(
        ServiceLogQuery(_DAY_T0, _DAY_T0 + Int64(10) * _MS, String(""), 100)
    )
    assert_equal(page.hits[0].source_json, String('{"m":"tie-a"}'), "5: tie-a")
    assert_equal(page.hits[1].source_json, String('{"m":"tie-b"}'), "5: tie-b")
    assert_equal(page.hits[2].source_json, String('{"m":"tie-c"}'), "5: tie-c")
    assert_equal(page.hits[3].source_json, String('{"m":"older"}'), "5: older")
    _ = s^


# =============================================================================
# CASE 6 - A SCHEMA MISMATCH IS REFUSED, NOT SKIPPED. A segment lacking the
# `_source` column cannot be turned into hits; dropping it would report data
# loss as an empty page.
# =============================================================================
def test_06_a_segment_missing_the_source_column_is_refused() raises:
    var store = SharedInMemoryConditionalStore()
    var sb = SchemaBuilder()
    sb.add_field(Field(String("message"), ArrowType.STRING, False))
    sb.add_field(Field(String("timestamp"), ArrowType.TIMESTAMP_NS, False))
    var schema = sb.build()
    var msgs = List[String]()
    msgs.append(String("only"))
    var ts = List[Int64]()
    ts.append(_DAY_T0 + _MS)
    var rb = RecordBatchBuilder.with_capacity(2)
    rb.add_column(Column.from_string(StringArray.from_strings(msgs)))
    rb.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](
            PrimitiveArray[DType.int64].from_list(ts), ArrowType.TIMESTAMP_NS
        )
    )
    var w = TelemetryLogSegmentWriter[SharedInMemoryConditionalStore](
        store.clone(), String("writer-a")
    )
    _ = w.publish_batches(_one_batch(rb.build(schema^)))

    var s = _search(store)
    var raised = False
    try:
        _ = s.scan(
            ServiceLogQuery(_DAY_T0, _DAY_T0 + Int64(10) * _MS, String(""), 100)
        )
    except:
        raised = True
    assert_true(
        raised,
        "6: a decoded segment without `_source` is REFUSED, not skipped",
    )
    _ = s^


def main() raises:
    test_01_a_term_free_window_returns_newest_first()
    test_02_rows_outside_the_window_are_filtered_inside_a_row_group()
    test_03_a_term_matches_by_substring_and_limit_truncates_the_page()
    test_04_the_ordering_is_global_across_objects_and_days()
    test_05_rows_with_equal_timestamps_keep_segment_order()
    test_06_a_segment_missing_the_source_column_is_refused()
    print("test_telemetry_log_search: OK")
