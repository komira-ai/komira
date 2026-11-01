# =============================================================================
# komira_telemetry_read/tests/test_telemetry_segment_read.mojo
#   Segment reads against REAL Parquet bytes: a segment written by
#   `komira_telemetry_store`'s log writer is planned, fetched by exact key,
#   pruned by row group on the footer zone map, and decoded.
# =============================================================================
#
# What each case would catch if it were wrong:
#   1   the reader's time column name drifting from the writer's, which would
#       silently disable every row-group prune.
#   2   rows lost, duplicated or reordered on the way from the planned key to
#       the decoded batches, and wrong accounting.
#   3   the row-group zone-map prune not firing (correct rows, no saving).
#   4   a half-open time predicate dropping rows at the edges of a group, and
#       one that wrongly keeps a neighbouring group whose edge touches a bound.
#   5   a corrupt object read as "no rows" instead of refused.
#   6   a plan with nothing in it still issuing GETs.
#   7   the writer and the reader disagreeing on where the text sidecar lives,
#       or the plan naming the sidecar as a data object.
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

from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

from komira_telemetry_store.keys import (
    TELEMETRY_DATASET_LOGS,
    telemetry_text_sidecar_key,
)
from komira_telemetry_store.log_writer import (
    LOG_TIME_COLUMN,
    TelemetryLogSegmentWriter,
)

from komira_telemetry_read.scan_plan import plan_telemetry_scan
from komira_telemetry_read.segment_read import (
    TELEMETRY_LOG_TS_COLUMN,
    TelemetryReadStats,
    decode_telemetry_segment_bytes,
    read_telemetry_segments,
    telemetry_time_predicate,
)

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


def _publish_ramp(
    store: SharedInMemoryConditionalStore, rows: Int, rows_per_row_group: Int
) raises -> String:
    """Write `rows` log lines, one millisecond apart from `_DAY_T0`, as ONE
    segment with `rows_per_row_group` rows in each row group. Returns the key."""
    var w = TelemetryLogSegmentWriter[SharedInMemoryConditionalStore](
        store.clone(),
        String("writer-ramp"),
        rows_per_row_group=rows_per_row_group,
    )
    var msgs = List[String]()
    var ts = List[Int64]()
    for i in range(rows):
        msgs.append(String("line-") + String(i))
        ts.append(_DAY_T0 + Int64(i) * _MS)
    var entries = w.publish_batches(_one_batch(_log_batch(msgs^, ts^)))
    assert_equal(len(entries), 1, "fixture: one day touched -> one object")
    return entries[0].object_key.copy()


def _ts_values(batch: RecordBatch) raises -> List[Int64]:
    var idx = -1
    for c in range(batch.num_columns()):
        if batch.schema.field_name(c) == TELEMETRY_LOG_TS_COLUMN:
            idx = c
    if idx < 0:
        raise Error("no timestamp column in a decoded batch")
    var arr = batch.column_at(idx).as_primitive[DType.int64]()
    var out = List[Int64](capacity=batch.num_rows())
    for r in range(batch.num_rows()):
        out.append(Int64(arr.get(r)))
    return out^


# =============================================================================
# CASE 1 - the time column name is the writer's. `TELEMETRY_LOG_TS_COLUMN` is
# the store's `LOG_TIME_COLUMN` under the reader's name; the predicate must name
# a column the footer has, or every row-group prune silently stops.
# =============================================================================
def test_01_the_reader_time_column_is_the_writers() raises:
    assert_equal(
        String(TELEMETRY_LOG_TS_COLUMN),
        String(LOG_TIME_COLUMN),
        "1: the reader's time column name must be the writer's",
    )


# =============================================================================
# CASE 2 - REAL BYTES, END TO END. A segment written by the store's writer is
# planned and read back through this package: every row comes back, the stats
# add up to it, and exactly the planned objects were fetched.
# =============================================================================
def test_02_a_written_segment_reads_back_through_the_plan() raises:
    var store = SharedInMemoryConditionalStore()
    var key = _publish_ramp(store, 12, 4)

    var plan = plan_telemetry_scan(
        store,
        String(TELEMETRY_DATASET_LOGS),
        _DAY_T0,
        _DAY_T0 + Int64(11) * _MS,
    )
    assert_equal(len(plan.object_keys()), 1, "2: the plan names the segment")
    assert_equal(plan.object_keys()[0], key, "2: and it is the written key")
    assert_equal(plan.rows_selected(), Int64(12), "2: rows known at plan time")
    assert_true(plan.bytes_selected() > Int64(0), "2: bytes known at plan time")

    var read = read_telemetry_segments(
        store, plan, String(TELEMETRY_LOG_TS_COLUMN)
    )
    ref batches = read[0]
    ref stats = read[1]
    assert_equal(stats.objects_fetched, 1, "2: exactly the planned object")
    assert_equal(stats.rgs_total, 3, "2: 12 rows / 4 per group = 3 groups")
    assert_equal(stats.rgs_pruned, 0, "2: the whole range prunes no group")
    assert_equal(stats.rgs_decoded, 3, "2: every group was decoded")
    assert_equal(stats.rows_decoded, 12, "2: every row came back")
    assert_equal(len(batches), 3, "2: one batch per surviving row group")

    var seen = 0
    var prev = Int64(-1)
    for b in range(len(batches)):
        var ts = _ts_values(batches[b])
        for i in range(len(ts)):
            assert_equal(
                ts[i],
                _DAY_T0 + Int64(seen) * _MS,
                "2: rows come back in the file's time order, none missing",
            )
            assert_true(ts[i] > prev, "2: strictly ascending")
            prev = ts[i]
            seen += 1
    assert_equal(seen, 12, "2: all twelve rows were seen")


# =============================================================================
# CASE 3 - THE ROW-GROUP PRUNE, MEASURED. A narrow range inside the last row
# group decodes ONE group and prunes the other two.
#
# A zero in `rgs_pruned` here would be a performance regression that returns
# correct rows (the time column carried no usable statistics, or the predicate
# stopped reaching the pruner), so nothing but this accounting would notice it.
# The plan alone does not prune: the segment overlaps the range, so the
# file-level prune keeps it.
# =============================================================================
def test_03_a_narrow_range_prunes_row_groups_by_zone_map() raises:
    var store = SharedInMemoryConditionalStore()
    _ = _publish_ramp(store, 12, 4)

    var t0 = _DAY_T0 + Int64(8) * _MS
    var t1 = _DAY_T0 + Int64(11) * _MS
    var plan = plan_telemetry_scan(store, String(TELEMETRY_DATASET_LOGS), t0, t1)
    assert_equal(
        len(plan.object_keys()),
        1,
        "3: the file-level prune keeps a segment the range overlaps",
    )
    var read = read_telemetry_segments(
        store, plan, String(TELEMETRY_LOG_TS_COLUMN)
    )
    ref batches = read[0]
    ref stats = read[1]
    assert_equal(stats.rgs_total, 3, "3: three groups in the file")
    assert_equal(
        stats.rgs_pruned,
        2,
        "3: the two groups wholly before t0 are pruned on the footer zone map",
    )
    assert_equal(stats.rgs_decoded, 1, "3: and one group is decoded")
    assert_equal(stats.rows_decoded, 4, "3: only that group's rows came back")
    assert_equal(len(batches), 1, "3: one surviving batch")
    var ts = _ts_values(batches[0])
    assert_equal(ts[0], t0, "3: the surviving group starts at t0")
    assert_equal(ts[len(ts) - 1], t1, "3: and ends at t1 (inclusive)")


# =============================================================================
# CASE 4 - THE PREDICATE IS CLOSED AT BOTH ENDS. A range whose bounds fall on the
# first and last row of a group keeps that group, and a bound that sits exactly
# on a group's edge keeps that group alone. The three groups hold rows 0-3, 4-7
# and 8-11. A query [row3,row3] touches group 1's max only: a `>` in place of
# `>=` drops it (0 groups decoded). A query [row8,row8] touches group 3's min
# only: a `<` in place of `<=` drops it. The [row4,row7] query alone cannot see
# either, because the middle group straddles both bounds.
# =============================================================================
def test_04_the_time_predicate_is_inclusive_at_both_ends() raises:
    var store = SharedInMemoryConditionalStore()
    _ = _publish_ramp(store, 12, 4)

    # Exactly the middle group: rows 4..7.
    var t0 = _DAY_T0 + Int64(4) * _MS
    var t1 = _DAY_T0 + Int64(7) * _MS
    var plan = plan_telemetry_scan(store, String(TELEMETRY_DATASET_LOGS), t0, t1)
    var read = read_telemetry_segments(
        store, plan, String(TELEMETRY_LOG_TS_COLUMN)
    )
    ref stats = read[1]
    assert_equal(stats.rgs_decoded, 1, "4: the group whose bounds ARE t0/t1")
    assert_equal(stats.rgs_pruned, 2, "4: the groups on either side prune")
    assert_equal(stats.rows_decoded, 4, "4: and all four of its rows come back")

    # t0 == t1 == the max of group 1: only that group may survive.
    var edge = _DAY_T0 + Int64(3) * _MS
    var plan_hi = plan_telemetry_scan(
        store, String(TELEMETRY_DATASET_LOGS), edge, edge
    )
    var read_hi = read_telemetry_segments(
        store, plan_hi, String(TELEMETRY_LOG_TS_COLUMN)
    )
    ref stats_hi = read_hi[1]
    assert_equal(stats_hi.rgs_decoded, 1, "4: a bound on a group's max keeps it")
    assert_equal(stats_hi.rgs_pruned, 2, "4: and prunes the other two")
    assert_equal(stats_hi.rows_decoded, 4, "4: the whole group is decoded")

    # t0 == t1 == the min of group 3: only that group may survive.
    var edge_lo = _DAY_T0 + Int64(8) * _MS
    var plan_lo = plan_telemetry_scan(
        store, String(TELEMETRY_DATASET_LOGS), edge_lo, edge_lo
    )
    var read_lo = read_telemetry_segments(
        store, plan_lo, String(TELEMETRY_LOG_TS_COLUMN)
    )
    ref stats_lo = read_lo[1]
    assert_equal(stats_lo.rgs_decoded, 1, "4: a bound on a group's min keeps it")
    assert_equal(stats_lo.rgs_pruned, 2, "4: and prunes the other two")
    assert_equal(stats_lo.rows_decoded, 4, "4: the whole group is decoded")


# =============================================================================
# CASE 5 - A BAD OBJECT IS REFUSED, NOT FOLDED TO ZERO ROWS. A telemetry read
# that returned an empty result for a corrupt object would report "nothing was
# logged" for a bucket that is full.
# =============================================================================
def _raises_decoding(var bytes: List[UInt8]) -> Bool:
    var stats = TelemetryReadStats(0, 0, 0, 0, 0)
    var filter = telemetry_time_predicate(
        String(TELEMETRY_LOG_TS_COLUMN), Int64(0), Int64(1)
    )
    try:
        _ = decode_telemetry_segment_bytes(bytes^, filter, stats)
    except:
        return True
    return False


def test_05_a_corrupt_object_is_refused_not_read_as_empty() raises:
    var tiny = List[UInt8]()
    for _ in range(11):
        tiny.append(UInt8(0))
    assert_true(
        _raises_decoding(tiny^),
        "5: an object under 12 bytes cannot be a Parquet file",
    )

    var no_magic = List[UInt8]()
    for _ in range(64):
        no_magic.append(UInt8(7))
    assert_true(
        _raises_decoding(no_magic^),
        "5: an object without the trailing PAR1 magic is refused",
    )

    # Valid trailing magic, impossible footer length (larger than the file).
    var bad_footer = List[UInt8]()
    for _ in range(60):
        bad_footer.append(UInt8(0))
    bad_footer.append(UInt8(0xFF))
    bad_footer.append(UInt8(0xFF))
    bad_footer.append(UInt8(0xFF))
    bad_footer.append(UInt8(0x0F))
    bad_footer.append(UInt8(80))
    bad_footer.append(UInt8(65))
    bad_footer.append(UInt8(82))
    bad_footer.append(UInt8(49))
    assert_true(
        _raises_decoding(bad_footer^),
        "5: a footer length larger than the object is refused",
    )

    var zero_footer = List[UInt8]()
    for _ in range(60):
        zero_footer.append(UInt8(0))
    zero_footer.append(UInt8(0))
    zero_footer.append(UInt8(0))
    zero_footer.append(UInt8(0))
    zero_footer.append(UInt8(0))
    zero_footer.append(UInt8(80))
    zero_footer.append(UInt8(65))
    zero_footer.append(UInt8(82))
    zero_footer.append(UInt8(49))
    assert_true(
        _raises_decoding(zero_footer^),
        "5: a zero footer length is refused",
    )


# =============================================================================
# CASE 6 - AN EMPTY PLAN READS NOTHING. A window that pruned every segment
# fetches no object and reports zero everywhere, distinguishable from a window
# that fetched objects and matched nothing.
# =============================================================================
def test_06_an_empty_plan_fetches_nothing() raises:
    var store = SharedInMemoryConditionalStore()
    _ = _publish_ramp(store, 12, 4)

    # A window a week after the data: the day partition has no lineage at all.
    var plan = plan_telemetry_scan(
        store,
        String(TELEMETRY_DATASET_LOGS),
        _DAY_T0 + Int64(7) * _DAY,
        _DAY_T0 + Int64(7) * _DAY + _MS,
    )
    assert_equal(len(plan.object_keys()), 0, "6: nothing to open")
    assert_equal(plan.entries_replayed, 0, "6: and the catalog is empty there")
    store.reset_op_counts()
    var read = read_telemetry_segments(
        store, plan, String(TELEMETRY_LOG_TS_COLUMN)
    )
    ref batches = read[0]
    ref stats = read[1]
    assert_equal(len(batches), 0, "6: no batches")
    assert_equal(stats.objects_fetched, 0, "6: no objects fetched")
    assert_equal(stats.rows_decoded, 0, "6: no rows decoded")
    assert_equal(store.n_get(), Int64(0), "6: and the store saw no GET at all")


# =============================================================================
# CASE 7 - THE WRITER AND THE READER AGREE ON THE SIDECAR. A segment published
# with a text sidecar puts it in the store at the key derived from the data key
# (`telemetry_text_sidecar_key`), flags the entry, and the planner still names
# only the data object: a sidecar key handed to a Parquet decoder would be
# refused as a corrupt object.
# =============================================================================
def test_07_a_written_sidecar_is_at_the_derived_key_and_not_planned() raises:
    var store = SharedInMemoryConditionalStore()
    var w = TelemetryLogSegmentWriter[SharedInMemoryConditionalStore](
        store.clone(), String("writer-sidecar"), rows_per_row_group=4
    )
    var msgs = List[String]()
    var ts = List[Int64]()
    for i in range(4):
        msgs.append(String("line-") + String(i))
        ts.append(_DAY_T0 + Int64(i) * _MS)
    var sidecar = List[UInt8]()
    for i in range(7):
        sidecar.append(UInt8(200 + i))
    var entries = w.publish_batches(
        _one_batch(_log_batch(msgs^, ts^)), Optional[List[UInt8]](sidecar.copy())
    )
    assert_equal(len(entries), 1, "7: one day, one object")
    assert_true(entries[0].has_text_sidecar, "7: the entry records the sidecar")

    var side_key = telemetry_text_sidecar_key(entries[0].object_key)
    var got = store.get(Path.parse(side_key))
    assert_equal(len(got), 7, "7: the sidecar is at the derived key")
    for i in range(7):
        assert_equal(Int(got[i]), 200 + i, "7: with the bytes that were given")

    var plan = plan_telemetry_scan(
        store, String(TELEMETRY_DATASET_LOGS), _DAY_T0, _DAY_T0 + _DAY - Int64(1)
    )
    assert_equal(len(plan.object_keys()), 1, "7: the plan names one object")
    assert_equal(
        plan.object_keys()[0], entries[0].object_key, "7: the data object"
    )
    var read = read_telemetry_segments(
        store, plan, String(TELEMETRY_LOG_TS_COLUMN)
    )
    ref stats7 = read[1]
    assert_equal(stats7.rows_decoded, 4, "7: the data object reads normally")


def main() raises:
    test_01_the_reader_time_column_is_the_writers()
    test_02_a_written_segment_reads_back_through_the_plan()
    test_03_a_narrow_range_prunes_row_groups_by_zone_map()
    test_04_the_time_predicate_is_inclusive_at_both_ends()
    test_05_a_corrupt_object_is_refused_not_read_as_empty()
    test_06_an_empty_plan_fetches_nothing()
    test_07_a_written_sidecar_is_at_the_derived_key_and_not_planned()
    print("test_telemetry_segment_read: OK")
