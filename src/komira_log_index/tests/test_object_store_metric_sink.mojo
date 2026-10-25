# =============================================================================
# test_object_store_metric_sink.mojo
#   `ObjectStoreMetricSink`: real `MetricPoint`s go in and a `metrics` Parquet
#   object plus a true catalog entry come out; the object is written before its
#   catalog entry is appended.
# =============================================================================
#
# This file sits on the side of the dependency edge that can name both halves:
# `komira_metrics.MetricPoint` (the in-process record) and
# `komira_telemetry_store` (the at-rest format). The writer's own tests prove the
# format over a hand-built batch; this one proves the binding: that the transpose
# lowers a point's identity, its value arm and its clock into the columns the
# writer partitions, sorts and bounds on.
#
# Every claim about the file is read back out of the published bytes. A test that
# asserted on the sink's own counters would pass for a sink that counted
# correctly and wrote nothing. The reader is a private copy of the whole-file
# Parquet decode, built on `komira_parquet`, which shares no code with the writer.
#
# Hermetic: `SharedInMemoryConditionalStore`. No cloud, no installed log manager,
# no engine: the sink takes a `List[MetricPoint]`, which is what
# `SharedEngine.take_metric_points` returns.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_arrow.concat import concat_record_batches_nway
from komira_arrow.record_batch import RecordBatch
from komira_buffer.byte_view import ByteView
from komira_collections.slab import Slab

from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore import (
    CloneableConditionalWriteStore,
    CoalescePolicy,
    ConditionalWriteStore,
    ListResult,
    ObjectMeta,
    ObjectStore,
    WritePrecondition,
)

from komira_metrics.metric_point import (
    MFLAG_VALUE_IS_DOUBLE,
    MetricPoint,
    counter_point,
    gauge_point,
)

from komira_parquet.bytes_decode import (
    decode_row_group_from_bytes,
    row_group_byte_range,
)
from komira_parquet.metadata_parser import parse_full_metadata
from komira_parquet.morsel_reader import ColumnProjection

from komira_telemetry_store.keys import (
    NS_PER_DAY,
    TELEMETRY_DATA_KEY_DEPTH,
    TELEMETRY_DATASET_METRICS,
    TELEMETRY_ROOT,
    day_string_from_ns,
    telemetry_key_depth,
)
from komira_telemetry_store.manifest import (
    open_partition_manifest,
    plan_time_range_read,
)
from komira_telemetry_store.metric_writer import (
    METRIC_SERIES_COLUMN,
    METRIC_TIME_COLUMN,
)

from komira_log_index.metric_transpose import (
    METRICS_FACT_COLUMNS,
    metric_points_to_record_batch,
    metric_series_id,
    metrics_fact_schema,
)
from komira_log_index.object_store_metric_sink import ObjectStoreMetricSink


comptime _DAY_T0: Int64 = 1788307200_000_000_000  # 2026-09-02T00:00:00Z


def _view[
    mut: Bool, //, o: Origin[mut=mut]
](data: Span[UInt8, o]) -> ByteView[o]:
    # SAFETY: the view borrows `data`'s buffer under the origin `o`, so the
    # list it came from outlives every use of the view in this file.
    return ByteView[o](data.unsafe_ptr(), len(data))


def _read_parquet_full(file: List[UInt8]) raises -> RecordBatch:
    """Decode a whole in-memory Parquet file into one RecordBatch.

    Test support, kept in this file so it is never part of a public API. Built
    on `komira_parquet`'s reader: checks the magic and footer length, parses the
    footer, decodes each row group from its byte range and concatenates them in
    file order."""
    var n = len(file)
    if n < 12:
        raise Error("test: " + String(n) + " bytes is not a Parquet file")
    var par1 = String("PAR1")
    var magic = par1.as_bytes()
    for k in range(4):
        if file[k] != magic[k] or file[n - 4 + k] != magic[k]:
            raise Error("test: missing PAR1 magic")
    var flen = 0
    for k in range(4):
        flen |= Int(file[n - 8 + k]) << (8 * k)
    if flen <= 0 or flen > n - 12:
        raise Error("test: footer length out of range")
    var md = parse_full_metadata(_view(Span(file)[n - 8 - flen : n - 8]))
    var groups = Slab[RecordBatch](capacity=len(md.row_groups))
    for g in range(len(md.row_groups)):
        ref rg = md.row_groups[g]
        var br = row_group_byte_range(rg)
        groups.append(
            decode_row_group_from_bytes(
                _view(Span(file)[br.start : br.end]),
                br,
                rg,
                md.schema,
                ColumnProjection.all(),
            )
        )
    if len(groups) == 1:
        var only = groups.pop()
        return only.take()
    return concat_record_batches_nway(groups^)


def _readback(
    store: SharedInMemoryConditionalStore, key: String
) raises -> RecordBatch:
    return _read_parquet_full(store.get(Path.parse(key)))


def _i64_col(rb: RecordBatch, name: String) raises -> List[Int64]:
    var idx = -1
    for c in range(rb.num_columns()):
        if rb.schema.field_name(c) == name:
            idx = c
    if idx < 0:
        raise Error("readback: no '" + name + "' column")
    var arr = rb.column_at(idx).as_primitive[DType.int64]()
    var out = List[Int64](capacity=rb.num_rows())
    for r in range(rb.num_rows()):
        out.append(Int64(arr.get(r)))
    return out^


def _f64_col(rb: RecordBatch, name: String) raises -> List[Float64]:
    var idx = -1
    for c in range(rb.num_columns()):
        if rb.schema.field_name(c) == name:
            idx = c
    if idx < 0:
        raise Error("readback: no '" + name + "' column")
    var arr = rb.column_at(idx).as_primitive[DType.float64]()
    var out = List[Float64](capacity=rb.num_rows())
    for r in range(rb.num_rows()):
        out.append(Float64(arr.get(r)))
    return out^


def _sink(
    store: SharedInMemoryConditionalStore, var wid: String
) raises -> ObjectStoreMetricSink[SharedInMemoryConditionalStore]:
    return ObjectStoreMetricSink[SharedInMemoryConditionalStore](
        store.clone(), wid^
    )


# =============================================================================
# CASE 1 — MARQUEE. Points in, ONE `metrics` Parquet object out, at the
# COMPUTED UTC-day prefix, sorted `(series_id, ts)` IN THE FILE.
# =============================================================================


def test_01_marquee_points_become_a_series_sorted_metrics_object() raises:
    var store = SharedInMemoryConditionalStore()
    var sink = _sink(store, String("node-a"))

    # Two series interleaved in emission order, each with three observations.
    # `name_id` differs -> two distinct series_ids.
    var pts = List[MetricPoint]()
    var order = List[Int]()
    order.append(0); order.append(1); order.append(0)
    order.append(1); order.append(0); order.append(1)
    for i in range(len(order)):
        var nid = UInt32(1001) if order[i] == 0 else UInt32(2002)
        var t = UInt64(_DAY_T0 + Int64(600 - i * 100) * Int64(1_000_000))
        pts.append(
            counter_point(nid, UInt32(7), UInt32(0), Int64(i), t - UInt64(10), t)
        )
    var sid_a = metric_series_id(UInt32(1001), UInt32(7), UInt32(0))
    var sid_b = metric_series_id(UInt32(2002), UInt32(7), UInt32(0))
    assert_true(sid_a != sid_b, "1: two names -> two series ids (sanity)")

    assert_equal(sink.offer_points(pts^), 6, "1: six points accepted")
    assert_equal(sink.buffered_points(), 6, "1: and they are PENDING")
    assert_equal(
        sink.points_published(),
        Int64(0),
        "1: an offer PUBLISHES NOTHING — the flush does",
    )

    var n = sink.flush_pending_now()
    assert_equal(n, 6, "1: six points published")
    assert_equal(sink.buffered_points(), 0, "1: the buffer is drained")
    assert_equal(sink.segments_published(), Int64(1), "1: ONE object")

    # --- the catalog, replayed. The key carries the COMPUTED day. -----------
    var day = day_string_from_ns(_DAY_T0)
    var m = open_partition_manifest[SharedInMemoryConditionalStore](
        store, TELEMETRY_ROOT, TELEMETRY_DATASET_METRICS, day, String("node-a")
    )
    var live = m.live_segments()
    assert_equal(len(live), 1, "1: one live segment")
    ref e = live[0]
    var want_prefix = (
        TELEMETRY_ROOT
        + String("/")
        + TELEMETRY_DATASET_METRICS
        + String("/")
        + day
        + String("/data/")
    )
    assert_true(
        e.object_key.find(want_prefix) == 0,
        String("1: key '") + e.object_key + String("' is under ") + want_prefix,
    )
    assert_equal(
        telemetry_key_depth(e.object_key),
        TELEMETRY_DATA_KEY_DEPTH,
        "1: key depth is a constant",
    )

    # --- the FILE's order ---------------------------------------------------
    var rb = _readback(store, e.object_key)
    assert_equal(rb.num_rows(), 6, "1: six rows in the object")
    assert_equal(
        rb.num_columns(),
        METRICS_FACT_COLUMNS,
        "1: the fact table's column count survived the round trip",
    )
    var fs = _i64_col(rb, METRIC_SERIES_COLUMN)
    var ft = _i64_col(rb, METRIC_TIME_COLUMN)
    for i in range(1, len(fs)):
        assert_true(
            fs[i - 1] <= fs[i], "1: series_id non-decreasing in the file"
        )
        if fs[i - 1] == fs[i]:
            assert_true(
                ft[i - 1] <= ft[i], "1: ts non-decreasing WITHIN a series"
            )
    # The discriminator against a `ts`-only sort: each series' three rows are
    # CONTIGUOUS. Under `(ts)` alone they would alternate.
    assert_equal(fs[0], fs[1], "1: series contiguous (rows 0,1)")
    assert_equal(fs[1], fs[2], "1: series contiguous (rows 1,2)")
    assert_true(fs[2] != fs[3], "1: the series changes exactly once")
    assert_equal(fs[3], fs[4], "1: second series contiguous")
    assert_equal(fs[4], fs[5], "1: second series contiguous")


# =============================================================================
# CASE 2 — THE CATALOG IS TRUE OF THE ROWS. Bounds re-derived from the
# DECODED FILE; required to CONTAIN every row and to be TIGHT.
# =============================================================================


def test_02_the_catalog_bounds_are_true_and_tight_for_the_rows_written() raises:
    var store = SharedInMemoryConditionalStore()
    var sink = _sink(store, String("node-a"))

    var pts = List[MetricPoint]()
    var nids = List[UInt32]()
    nids.append(UInt32(31)); nids.append(UInt32(9)); nids.append(UInt32(77))
    nids.append(UInt32(9)); nids.append(UInt32(31))
    var offs = List[Int64]()
    offs.append(Int64(400)); offs.append(Int64(50)); offs.append(Int64(950))
    offs.append(Int64(720)); offs.append(Int64(120))
    for i in range(len(nids)):
        var t = UInt64(_DAY_T0 + offs[i] * Int64(1_000_000))
        pts.append(
            gauge_point(nids[i], UInt32(3), UInt32(0), Int64(i * 10), t)
        )
    _ = sink.offer_points(pts^)
    _ = sink.flush_pending_now()

    var m = open_partition_manifest[SharedInMemoryConditionalStore](
        store,
        TELEMETRY_ROOT,
        TELEMETRY_DATASET_METRICS,
        day_string_from_ns(_DAY_T0),
        String("node-a"),
    )
    var live = m.live_segments()
    assert_equal(len(live), 1, "2: one segment")
    ref e = live[0]

    var rb = _readback(store, e.object_key)
    assert_equal(
        Int64(rb.num_rows()),
        e.row_count,
        "2: the entry's row_count is the file's row count",
    )
    var fs = _i64_col(rb, METRIC_SERIES_COLUMN)
    var ft = _i64_col(rb, METRIC_TIME_COLUMN)
    var mn_s = fs[0]
    var mx_s = fs[0]
    var mn_t = ft[0]
    var mx_t = ft[0]
    for i in range(len(fs)):
        if fs[i] < mn_s:
            mn_s = fs[i]
        if fs[i] > mx_s:
            mx_s = fs[i]
        if ft[i] < mn_t:
            mn_t = ft[i]
        if ft[i] > mx_t:
            mx_t = ft[i]
    # CONTAINS — no row outside the advertised bound.
    for i in range(len(fs)):
        assert_true(
            e.min_ts_ns <= ft[i] and ft[i] <= e.max_ts_ns,
            "2: every row's ts is inside the advertised time bound",
        )
        assert_true(
            e.min_series_id <= fs[i] and fs[i] <= e.max_series_id,
            "2: every row's series_id is inside the advertised series bound",
        )
    # TIGHT — a legal-but-useless bound prunes nothing and is the failure a
    # containment-only assertion cannot see.
    assert_equal(e.min_ts_ns, mn_t, "2: min_ts is TIGHT")
    assert_equal(e.max_ts_ns, mx_t, "2: max_ts is TIGHT")
    assert_equal(e.min_series_id, mn_s, "2: min_series_id is TIGHT")
    assert_equal(e.max_series_id, mx_s, "2: max_series_id is TIGHT")
    # And the bound is a REAL range, not a degenerate one — three distinct
    # series were written, so a writer that stamped 0/0 (the LOG dataset's
    # values) would go red here and nowhere else.
    assert_true(
        e.max_series_id > e.min_series_id,
        "2: the series bound is a REAL range — a metrics entry stamped with"
        " logs' 0/0 would be pruned out by every series-filtered query",
    )


# =============================================================================
# CASE 3 — AN EMPTY DRAIN PUBLISHES NOTHING. The store is UNTOUCHED, with a
# positive control proving the probe can see a publish when there is one.
# =============================================================================


def test_03_an_empty_drain_publishes_nothing_and_touches_no_object() raises:
    var store = SharedInMemoryConditionalStore()
    var sink = _sink(store, String("node-a"))

    # (a) the idle serve iteration: the engine's drain returns an empty list.
    assert_equal(
        sink.offer_points(List[MetricPoint]()), 0, "3a: empty offer accepted"
    )
    assert_equal(sink.flush_pending_now(), 0, "3a: nothing published")
    # (b) a flush with nothing ever offered.
    assert_equal(sink.flush_pending_now(), 0, "3b: still nothing")
    # (c) the shutdown path over an empty buffer.
    assert_equal(sink.final_flush(), 0, "3c: final_flush over empty is a no-op")

    assert_equal(sink.segments_published(), Int64(0), "3: no segments")
    assert_equal(sink.points_published(), Int64(0), "3: no points")
    assert_equal(sink.flush_publishes(), Int64(0), "3: no flush published")

    var head_key = (
        TELEMETRY_ROOT
        + String("/")
        + TELEMETRY_DATASET_METRICS
        + String("/")
        + day_string_from_ns(_DAY_T0)
        + String("/_lineage/node-a/_HEAD")
    )
    var found_before = True
    try:
        _ = store.get(Path.parse(head_key))
    except:
        found_before = False
    assert_false(
        found_before,
        "3: THREE empty flushes created NO object and NO lineage — an empty"
        " object plus a manifest entry whose [min,max] is meaningless would be"
        " a PUT charged on every idle serve iteration (a PUT costs"
        " far more than the bytes it carries)",
    )

    # POSITIVE CONTROL — the same probe FINDS the lineage after a real publish,
    # so the assertion above is observing absence and not a broken probe.
    var pts = List[MetricPoint]()
    pts.append(
        counter_point(
            UInt32(1),
            UInt32(1),
            UInt32(0),
            Int64(1),
            UInt64(_DAY_T0),
            UInt64(_DAY_T0 + Int64(1_000_000)),
        )
    )
    _ = sink.offer_points(pts^)
    assert_equal(sink.flush_pending_now(), 1, "3: the control publishes one")
    var found_after = True
    try:
        _ = store.get(Path.parse(head_key))
    except:
        found_after = False
    assert_true(found_after, "3: POSITIVE CONTROL — the probe CAN see a publish")


# =============================================================================
# CASE 4 — THE VALUE ARM. `MFLAG_VALUE_IS_DOUBLE` decides which column is
# meaningful, and an Int64 counter above 2^53 survives EXACTLY.
# =============================================================================


def test_04_the_value_flag_selects_the_column_and_int64_is_exact() raises:
    var store = SharedInMemoryConditionalStore()
    var sink = _sink(store, String("node-a"))

    # A counter beyond Float64's exact-integer range. Lowered into a FLOAT64
    # column it would come back as a DIFFERENT number.
    var big = Int64(9007199254740993)  # 2^53 + 1
    var t0 = UInt64(_DAY_T0 + Int64(1_000_000))
    var pi = counter_point(UInt32(5), UInt32(1), UInt32(0), big, t0, t0)
    var pd = gauge_point(
        UInt32(5), UInt32(1), UInt32(0), Int64(0), t0 + UInt64(1_000_000)
    )
    var pd2 = pd.copy()
    pd2.set_double_value(Float64(0.125))
    assert_true(pd2.value_is_double(), "4: the double point carries the flag")
    assert_false(pi.value_is_double(), "4: the int point does not")

    var pts = List[MetricPoint]()
    pts.append(pi.copy())
    pts.append(pd2.copy())
    _ = sink.offer_points(pts^)
    _ = sink.flush_pending_now()

    var m = open_partition_manifest[SharedInMemoryConditionalStore](
        store,
        TELEMETRY_ROOT,
        TELEMETRY_DATASET_METRICS,
        day_string_from_ns(_DAY_T0),
        String("node-a"),
    )
    var live = m.live_segments()
    var rb = _readback(store, live[0].object_key)
    var flags = _i64_col(rb, String("flags"))
    var vint = _i64_col(rb, String("value_int"))
    var vdbl = _f64_col(rb, String("value"))
    assert_equal(rb.num_rows(), 2, "4: two rows")

    # Same series, so file order is by ts: the int point first.
    assert_equal(
        vint[0], big, "4: the Int64 counter round-tripped EXACTLY (2^53 + 1)"
    )
    assert_equal(
        vdbl[0], Float64(0.0), "4: the unused arm is 0, not a lossy copy"
    )
    assert_true(
        (flags[0] & Int64(Int(MFLAG_VALUE_IS_DOUBLE))) == Int64(0),
        "4: and the flag says to read value_int",
    )
    assert_equal(vdbl[1], Float64(0.125), "4: the double round-tripped")
    assert_equal(vint[1], Int64(0), "4: its unused arm is 0")
    assert_true(
        (flags[1] & Int64(Int(MFLAG_VALUE_IS_DOUBLE))) != Int64(0),
        "4: and the flag says to read value",
    )


# =============================================================================
# CASE 5 — THE SERIES IDENTITY IS RECOVERABLE FROM THE ROWS, and `series_id` is
# reproducible from them. This is what makes a process-local `attrset_id` a
# stated residue rather than a silent one.
# =============================================================================


def test_05_the_series_identity_is_recoverable_from_the_fact_columns() raises:
    var store = SharedInMemoryConditionalStore()
    var sink = _sink(store, String("node-a"))
    var t0 = UInt64(_DAY_T0 + Int64(5_000_000))
    var pts = List[MetricPoint]()
    pts.append(counter_point(UInt32(42), UInt32(9), UInt32(3), Int64(1), t0, t0))
    _ = sink.offer_points(pts^)
    _ = sink.flush_pending_now()

    var m = open_partition_manifest[SharedInMemoryConditionalStore](
        store,
        TELEMETRY_ROOT,
        TELEMETRY_DATASET_METRICS,
        day_string_from_ns(_DAY_T0),
        String("node-a"),
    )
    var live = m.live_segments()
    var rb = _readback(store, live[0].object_key)
    var nid = _i64_col(rb, String("name_id"))
    var scid = _i64_col(rb, String("scope_id"))
    var aid = _i64_col(rb, String("attrset_id"))
    var sid = _i64_col(rb, METRIC_SERIES_COLUMN)
    assert_equal(nid[0], Int64(42), "5: name_id is its own column")
    assert_equal(scid[0], Int64(9), "5: scope_id is its own column")
    assert_equal(aid[0], Int64(3), "5: attrset_id is its own column")
    # A reader holding THE ROW CAN RE-DERIVE THE KEY. So `series_id` never has
    # to be trusted as a global name, which is exactly what makes the
    # process-local `attrset_id` survivable.
    assert_equal(
        sid[0],
        metric_series_id(UInt32(42), UInt32(9), UInt32(3)),
        "5: series_id is reproducible from the three identity columns",
    )
    assert_true(sid[0] >= Int64(0), "5: and it is non-negative")


# =============================================================================
# CASE 6 — A FLUSH ACROSS MIDNIGHT LANDS IN TWO PARTITIONS, and a range read
# planned over ONE day gets ONE object.
# =============================================================================


def test_06_a_midnight_flush_splits_and_a_day_scoped_read_prunes() raises:
    var store = SharedInMemoryConditionalStore()
    var sink = _sink(store, String("node-a"))
    var pts = List[MetricPoint]()
    var t_a = UInt64(_DAY_T0 + Int64(3_000_000))
    var t_b = UInt64(_DAY_T0 + NS_PER_DAY + Int64(3_000_000))
    pts.append(counter_point(UInt32(1), UInt32(1), UInt32(0), Int64(1), t_a, t_a))
    pts.append(counter_point(UInt32(1), UInt32(1), UInt32(0), Int64(2), t_b, t_b))
    _ = sink.offer_points(pts^)
    assert_equal(sink.flush_pending_now(), 2, "6: both points published")
    assert_equal(
        sink.segments_published(),
        Int64(2),
        "6: TWO objects — one per UTC day, never one straddling the boundary",
    )

    # The prune, through the shipped planner: a read scoped to day 0 alone.
    var plan = plan_time_range_read[SharedInMemoryConditionalStore](
        store,
        TELEMETRY_ROOT,
        TELEMETRY_DATASET_METRICS,
        _DAY_T0,
        _DAY_T0 + NS_PER_DAY - Int64(1),
    )
    assert_equal(plan.partitions_scanned, 1, "6: ONE day partition computed")
    assert_equal(
        len(plan.segments),
        1,
        "6: and ONE object survives — the day-2 segment is never GET",
    )
    assert_true(
        plan.segments[0].object_key.find(
            String("/") + day_string_from_ns(_DAY_T0) + String("/")
        )
        > 0,
        "6: and it is the day-0 object",
    )


# =============================================================================
# CASE 7 — THE BUFFER SURVIVES A FAILED PUBLISH, and the overflow ceiling drops
# the OLDEST and COUNTS what it dropped.
# =============================================================================


def test_07_the_pending_buffer_is_bounded_and_drops_the_oldest_loudly() raises:
    var store = SharedInMemoryConditionalStore()
    var sink = ObjectStoreMetricSink[SharedInMemoryConditionalStore](
        store.clone(), String("node-a"), TELEMETRY_ROOT, buffer_max=3
    )
    assert_equal(sink.buffer_max(), 3, "7: the ceiling is what we asked for")
    var pts = List[MetricPoint]()
    for i in range(5):
        var t = UInt64(_DAY_T0 + Int64(i + 1) * Int64(1_000_000))
        pts.append(
            counter_point(UInt32(1), UInt32(1), UInt32(0), Int64(i), t, t)
        )
    assert_equal(
        sink.offer_points(pts^),
        3,
        "7: five offered, only the newest three of them are pending",
    )
    assert_equal(sink.buffered_points(), 3, "7: three retained")
    assert_equal(
        sink.points_dropped(),
        Int64(2),
        "7: and the two dropped are COUNTED, never silent",
    )
    _ = sink.flush_pending_now()

    var m = open_partition_manifest[SharedInMemoryConditionalStore](
        store,
        TELEMETRY_ROOT,
        TELEMETRY_DATASET_METRICS,
        day_string_from_ns(_DAY_T0),
        String("node-a"),
    )
    var live = m.live_segments()
    var rb = _readback(store, live[0].object_key)
    var vint = _i64_col(rb, String("value_int"))
    assert_equal(len(vint), 3, "7: three rows survived")
    # The newest survive. A dashboard asks for the recent tail, so degrading
    # there is the one place the drop would be maximally visible.
    assert_equal(vint[0], Int64(2), "7: the OLDEST two (0,1) were the ones lost")
    assert_equal(vint[1], Int64(3), "7: newest retained")
    assert_equal(vint[2], Int64(4), "7: newest retained")


# =============================================================================
# CASE 8 — A REFUSED PUBLISH RETAINS THE POINTS. A metrics gap is recoverable;
# a silently-dropped counter delta is a permanently wrong rate.
# =============================================================================


def test_08_a_failed_publish_retains_the_points_for_the_next_flush() raises:
    var store = SharedInMemoryConditionalStore()
    # A writer rooted at a segment containing '/' is REFUSED by `keys.mojo`
    # rule 3 at PUBLISH time — a deterministic in-band failure, so the retention
    # behaviour is observable without a fault-injecting store.
    var sink = ObjectStoreMetricSink[SharedInMemoryConditionalStore](
        store.clone(), String("node-a"), String("bad/root")
    )
    var pts = List[MetricPoint]()
    var t = UInt64(_DAY_T0 + Int64(1_000_000))
    pts.append(counter_point(UInt32(1), UInt32(1), UInt32(0), Int64(1), t, t))
    _ = sink.offer_points(pts^)
    assert_equal(sink.buffered_points(), 1, "8: one pending")

    var raised = False
    try:
        _ = sink.flush_pending_now()
    except:
        raised = True
    assert_true(raised, "8: the raising form RAISES — it does not swallow")
    assert_equal(
        sink.buffered_points(),
        1,
        "8: the point is still pending — the buffer is cleared only AFTER a"
        " publish returns, so a transient failure is a delay and not a loss",
    )
    assert_equal(sink.points_published(), Int64(0), "8: nothing was published")

    # The swallowing form COUNTS instead of raising, and still retains.
    assert_equal(sink.try_flush_pending_now(), 0, "8: swallowed, published 0")
    assert_equal(
        sink.publish_failures(), Int64(1), "8: and the failure is COUNTED"
    )
    assert_equal(sink.buffered_points(), 1, "8: still retained")


# =============================================================================
# CASE 9 — THE TRANSPOSE AND THE SCHEMA AGREE. A column added to one and not the
# other is the defect this catches, in the file that owns both.
# =============================================================================


def test_09_the_transpose_matches_the_declared_fact_schema() raises:
    var schema = metrics_fact_schema()
    assert_equal(
        schema.num_columns(),
        METRICS_FACT_COLUMNS,
        "9: the declared schema has the declared column count",
    )
    var pts = List[MetricPoint]()
    var t = UInt64(_DAY_T0)
    pts.append(counter_point(UInt32(1), UInt32(2), UInt32(3), Int64(4), t, t))
    var rb = metric_points_to_record_batch(pts)
    assert_equal(
        rb.num_columns(),
        METRICS_FACT_COLUMNS,
        "9: the transpose emits exactly that many columns",
    )
    for c in range(METRICS_FACT_COLUMNS):
        assert_equal(
            rb.schema.field_name(c),
            schema.field_name(c),
            String("9: column ") + String(c) + String(" name agrees"),
        )
    # The two names the WRITER resolves must be where it looks for them.
    assert_equal(rb.schema.field_name(0), METRIC_TIME_COLUMN, "9: ts is col 0")
    assert_equal(
        rb.schema.field_name(1), METRIC_SERIES_COLUMN, "9: series_id is col 1"
    )
    # An EMPTY transpose is a 0-row batch, not a raise — the idle-flush shape.
    var empty = metric_points_to_record_batch(List[MetricPoint]())
    assert_equal(empty.num_rows(), 0, "9: an empty transpose is a 0-row batch")
    assert_equal(
        empty.num_columns(),
        METRICS_FACT_COLUMNS,
        "9: with the full schema still attached",
    )


# =============================================================================
# Publish ordering and failure. A recording store logs the order of its write
# verbs and can be told to fail, so the tests observe what reached the store.
# =============================================================================


struct _State(Movable):
    var log: List[String]
    var fail_put: Bool
    var fail_conditional: Bool

    def __init__(out self):
        self.log = List[String]()
        self.fail_put = False
        self.fail_conditional = False


struct RecordingStore(
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    var _inner: SharedInMemoryConditionalStore
    var _st: ArcPointer[_State]

    def __init__(out self):
        self._inner = SharedInMemoryConditionalStore()
        self._st = ArcPointer[_State](_State())

    def __init__(
        out self,
        var inner: SharedInMemoryConditionalStore,
        var st: ArcPointer[_State],
    ):
        self._inner = inner^
        self._st = st^

    def clone(self) -> Self:
        return Self(self._inner.clone(), self._st.copy())

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        self._st[].log.append(String("cond:") + path.raw())
        if self._st[].fail_conditional:
            raise Error("RecordingStore: injected conditional_put failure")
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        return self.conditional_put(
            path, bytes, WritePrecondition.if_match(expected_version)
        )

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        self._st[].log.append(String("put:") + path.raw())
        if self._st[].fail_put:
            raise Error("RecordingStore: injected put failure")
        return self._inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        return self._inner.get(path)

    def delete(self, path: Path) raises -> None:
        self._inner.delete(path)

    def log(self) -> List[String]:
        return self._st[].log.copy()

    def set_fail_put(self, v: Bool):
        self._st[].fail_put = v

    def set_fail_conditional(self, v: Bool):
        self._st[].fail_conditional = v


def _two_points() -> List[MetricPoint]:
    var pts = List[MetricPoint]()
    var t = UInt64(_DAY_T0 + Int64(2_000_000))
    pts.append(counter_point(UInt32(1), UInt32(1), UInt32(0), Int64(1), t, t))
    pts.append(
        counter_point(UInt32(2), UInt32(1), UInt32(0), Int64(2), t, t)
    )
    return pts^


def _live_count(store: RecordingStore) raises -> Int:
    var m = open_partition_manifest[RecordingStore](
        store,
        TELEMETRY_ROOT,
        TELEMETRY_DATASET_METRICS,
        day_string_from_ns(_DAY_T0),
        String("node-a"),
    )
    return len(m.live_segments())


def _is_data_put(verb: String) -> Bool:
    return verb.startswith(String("put:")) and verb.endswith(
        String(".parquet")
    )


def _count_data_puts(log: List[String]) -> Int:
    var c = 0
    for i in range(len(log)):
        if _is_data_put(log[i]):
            c += 1
    return c


def _count_cond(log: List[String]) -> Int:
    var c = 0
    for i in range(len(log)):
        if log[i].startswith(String("cond:")):
            c += 1
    return c


# =============================================================================
# CASE 10 — THE OBJECT IS WRITTEN BEFORE ITS CATALOG ENTRY IS APPENDED.
# Defect caught: a sink or writer that appended the manifest entry first would,
# on a crash between the two writes, leave an entry naming a missing object.
# =============================================================================


def test_10_the_object_is_put_before_the_entry_is_appended() raises:
    var store = RecordingStore()
    var sink = ObjectStoreMetricSink[RecordingStore](
        store.clone(), String("node-a")
    )
    _ = sink.offer_points(_two_points())
    assert_equal(sink.flush_pending_now(), 2, "10: both points published")

    var log = store.log()
    assert_true(len(log) >= 2, "10: the flush wrote to the store")
    assert_true(
        _is_data_put(log[0]),
        String("10: the FIRST write verb is the Parquet object's PUT, got ")
        + log[0],
    )
    assert_equal(_count_data_puts(log), 1, "10: exactly one object PUT")
    assert_true(
        _count_cond(log) >= 1,
        "10: and the catalog append (a conditional write) followed it",
    )
    for i in range(1, len(log)):
        assert_true(
            not _is_data_put(log[i]),
            "10: no object PUT after the first verb — every later write is the"
            " manifest's",
        )
    # The appended entry names exactly the object that was written.
    var m = open_partition_manifest[RecordingStore](
        store,
        TELEMETRY_ROOT,
        TELEMETRY_DATASET_METRICS,
        day_string_from_ns(_DAY_T0),
        String("node-a"),
    )
    var live = m.live_segments()
    assert_equal(len(live), 1, "10: one live entry")
    assert_equal(
        String("put:") + live[0].object_key,
        log[0],
        "10: the entry names the object written first",
    )


# =============================================================================
# CASE 11 — A FAILED OBJECT PUT PUBLISHES NOTHING and keeps the points.
# Defect caught: appending the entry despite a failed PUT, or dropping the
# buffer before the publish returned.
# =============================================================================


def test_11_a_failed_object_put_appends_no_entry_and_retains_points() raises:
    var store = RecordingStore()
    var sink = ObjectStoreMetricSink[RecordingStore](
        store.clone(), String("node-a")
    )
    _ = sink.offer_points(_two_points())
    store.set_fail_put(True)

    var raised = False
    try:
        _ = sink.flush_pending_now()
    except:
        raised = True
    assert_true(raised, "11: the failed PUT surfaces as a raise")
    var log = store.log()
    assert_equal(_count_data_puts(log), 1, "11: the PUT was attempted")
    assert_equal(
        _count_cond(log),
        0,
        "11: and NO catalog write followed the failed PUT",
    )
    assert_equal(_live_count(store), 0, "11: no live entry")
    assert_equal(sink.buffered_points(), 2, "11: the points are still pending")

    # The retry publishes what was held.
    store.set_fail_put(False)
    assert_equal(sink.flush_pending_now(), 2, "11: the retry publishes both")
    assert_equal(_live_count(store), 1, "11: and the entry is live")
    assert_equal(sink.buffered_points(), 0, "11: the buffer is drained")


# =============================================================================
# CASE 12 — A FAILED CATALOG APPEND leaves only an unreferenced object.
# Defect caught: a publish that reported success, or cleared the buffer, when
# the entry never landed.
# =============================================================================


def test_12_a_failed_append_leaves_an_unreferenced_object_and_retains() raises:
    var store = RecordingStore()
    var sink = ObjectStoreMetricSink[RecordingStore](
        store.clone(), String("node-a")
    )
    _ = sink.offer_points(_two_points())
    store.set_fail_conditional(True)

    var raised = False
    try:
        _ = sink.flush_pending_now()
    except:
        raised = True
    assert_true(raised, "12: the failed append surfaces as a raise")
    var log = store.log()
    assert_true(_is_data_put(log[0]), "12: the object was written first")
    assert_equal(_live_count(store), 0, "12: but no entry references it")
    assert_equal(sink.points_published(), Int64(0), "12: nothing counted")
    assert_equal(sink.buffered_points(), 2, "12: the points are still pending")

    store.set_fail_conditional(False)
    assert_equal(sink.flush_pending_now(), 2, "12: the retry publishes both")
    assert_equal(_live_count(store), 1, "12: one live entry after the retry")
    assert_equal(
        _count_data_puts(store.log()),
        2,
        "12: the first object stayed behind, unreferenced",
    )


def main() raises:
    test_01_marquee_points_become_a_series_sorted_metrics_object()
    test_02_the_catalog_bounds_are_true_and_tight_for_the_rows_written()
    test_03_an_empty_drain_publishes_nothing_and_touches_no_object()
    test_04_the_value_flag_selects_the_column_and_int64_is_exact()
    test_05_the_series_identity_is_recoverable_from_the_fact_columns()
    test_06_a_midnight_flush_splits_and_a_day_scoped_read_prunes()
    test_07_the_pending_buffer_is_bounded_and_drops_the_oldest_loudly()
    test_08_a_failed_publish_retains_the_points_for_the_next_flush()
    test_09_the_transpose_matches_the_declared_fact_schema()
    test_10_the_object_is_put_before_the_entry_is_appended()
    test_11_a_failed_object_put_appends_no_entry_and_retains_points()
    test_12_a_failed_append_leaves_an_unreferenced_object_and_retains()
    print("PASS komira_log_index.test_object_store_metric_sink (metric")
    print("     points reach object store as time-partitioned Parquet sorted")
    print("     (series_id, ts), with a catalog entry whose bounds are TRUE")
    print("     and TIGHT for the rows in the object it names)")
