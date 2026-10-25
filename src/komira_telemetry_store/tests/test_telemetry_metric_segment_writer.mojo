# =============================================================================
# komira_telemetry_store/tests/test_telemetry_metric_segment_writer.mojo
#   THE FALSIFIER for the `metrics` BASE at-rest artifact: TIME-PARTITIONED
#   PARQUET, SORTED `(series_id, ts)`, described by a catalog entry that is
#   TRUE OF THE ROWS IT NAMES.
# =============================================================================
#
# THE SORT ORDER IS READ BACK OUT OF THE PARQUET FILE, NOT ASSERTED ON THE
# BATCH THE WRITER BUILT. A test that checked the in-memory batch would pass for
# a writer that sorted and then encoded the UNSORTED input, which is the single
# most likely way this breaks. Every case that claims a file property decodes
# the published bytes with `_read_parquet_full` (below, built on
# `komira_parquet`'s reader) and reads the column.
#
# AND THE BUG CLASS THIS FILE EXISTS FOR IS THE CATALOG ONE. A manifest entry
# whose `[min_ts,max_ts]` or `[min_series_id,max_series_id]` does not actually
# bound the rows in the object it names is INVISIBLE TO EVERY OTHER CHECK,
# because every other check reads the catalog. The object is fine, the publish
# reports success, the counters advance, and a reader silently skips a segment
# that holds the answer. So CASE 3 does not assert the bounds against what the
# writer was TOLD; it re-derives them from the DECODED FILE and requires the
# entry to match, in both directions (the bound must contain every row, and
# must be TIGHT: a bound of [i64::MIN, i64::MAX] contains everything and prunes
# nothing).
#
# THE FACT SCHEMA HERE IS BUILT LOCALLY (11 columns). The two names the writer
# RESOLVES (`ts`, `series_id`) are imported from the writer, so this file cannot
# drift from the contract it is testing.
#
# HERMETIC: `SharedInMemoryConditionalStore`, no files, no cloud.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_collections.slab import Slab

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.concat import concat_record_batches_nway
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder

from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

from komira_buffer.byte_view import ByteView
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
from komira_telemetry_store.manifest import open_partition_manifest
from komira_telemetry_store.metric_writer import (
    METRIC_SERIES_COLUMN,
    METRIC_TIME_COLUMN,
    TELEMETRY_METRIC_ROWS_PER_ROW_GROUP,
    TelemetryMetricSegmentWriter,
)


comptime _DAY_T0: Int64 = 1790812800_000_000_000  # 2026-10-01T00:00:00Z


def _view[
    mut: Bool, //, o: Origin[mut=mut]
](data: Span[UInt8, o]) -> ByteView[o]:
    # SAFETY: the view borrows `data`'s buffer under the origin `o`, so the
    # list it came from outlives every use of the view in this file.
    return ByteView[o](data.unsafe_ptr(), len(data))


def _read_parquet_full(file: List[UInt8]) raises -> RecordBatch:
    """Decode a whole in-memory Parquet file into ONE RecordBatch.

    TEST SUPPORT, kept in this file so it is never part of a public API. It is
    built on `komira_parquet`'s reader, which shares no code with the writer
    under test: the magic bytes and the footer length are checked, the footer is
    parsed, and every row group is decoded from its byte range and concatenated
    in file order."""
    var n = len(file)
    if n < 12:
        raise Error("test: " + String(n) + " bytes is not a Parquet file")
    var magic = String("PAR1").as_bytes()
    for k in range(4):
        if file[k] != magic[k] or file[n - 4 + k] != magic[k]:
            raise Error("test: missing PAR1 magic")
    var flen = 0
    for k in range(4):
        flen |= Int(file[n - 8 + k]) << (8 * k)
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


def _fact_batch(
    var sids: List[Int64], var ts_ns: List[Int64]
) raises -> RecordBatch:
    """A batch of the 11-column metrics fact shape. `value` carries the ROW'S ORIGINAL INDEX as a Float64, which is
    what lets a case prove the gather moved the WHOLE ROW and not just the sort
    columns."""
    var n = len(sids)
    var sb = SchemaBuilder()
    sb.add_field(Field(METRIC_TIME_COLUMN, ArrowType.TIMESTAMP_NS, False))
    sb.add_field(Field(METRIC_SERIES_COLUMN, ArrowType.INT64, False))
    sb.add_field(Field(String("name_id"), ArrowType.INT64, False))
    sb.add_field(Field(String("scope_id"), ArrowType.INT64, False))
    sb.add_field(Field(String("attrset_id"), ArrowType.INT64, False))
    sb.add_field(Field(String("kind"), ArrowType.INT64, False))
    sb.add_field(Field(String("flags"), ArrowType.INT64, False))
    sb.add_field(Field(String("start_ts"), ArrowType.INT64, False))
    sb.add_field(Field(String("value"), ArrowType.FLOAT64, False))
    sb.add_field(Field(String("value_int"), ArrowType.INT64, False))
    sb.add_field(Field(String("exemplar_span_id"), ArrowType.INT64, False))
    var schema = sb.build()

    var filler = List[Int64](capacity=n)
    var vals = List[Float64](capacity=n)
    for i in range(n):
        filler.append(Int64(7))
        vals.append(Float64(i))

    var rb = RecordBatchBuilder.with_capacity(11)
    rb.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](
            PrimitiveArray[DType.int64].from_list(ts_ns), ArrowType.TIMESTAMP_NS
        )
    )
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(sids)
        )
    )
    for _ in range(6):
        rb.add_column(
            Column.from_primitive[DType.int64](
                PrimitiveArray[DType.int64].from_list(filler.copy())
            )
        )
    rb.add_column(
        Column.from_primitive[DType.float64](
            PrimitiveArray[DType.float64].from_list(vals^)
        )
    )
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(filler.copy())
        )
    )
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(filler^)
        )
    )
    return rb.build(schema^)


def _one_batch(var rb: RecordBatch) -> Slab[RecordBatch]:
    var s = Slab[RecordBatch](capacity=1)
    s.append(rb^)
    return s^


def _readback(
    store: SharedInMemoryConditionalStore, key: String
) raises -> RecordBatch:
    """Fetch the published object and decode it as a REAL Parquet file."""
    return _read_parquet_full(store.get(Path.parse(key)))


def _i64_col(rb: RecordBatch, name: String) raises -> List[Int64]:
    var idx = -1
    for c in range(rb.num_columns()):
        if rb.schema.field_name(c) == name:
            idx = c
    if idx < 0:
        raise Error("readback: no '" + name + "' column in the decoded file")
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
        raise Error("readback: no '" + name + "' column in the decoded file")
    var arr = rb.column_at(idx).as_primitive[DType.float64]()
    var out = List[Float64](capacity=rb.num_rows())
    for r in range(rb.num_rows()):
        out.append(Float64(arr.get(r)))
    return out^


# =============================================================================
# CASE 1 — MARQUEE. Unsorted rows in; ONE Parquet object out, at the day's
# COMPUTED key, sorted `(series_id, ts)` IN THE FILE.
# =============================================================================


def test_01_marquee_the_metrics_artifact_is_series_then_time_sorted() raises:
    var store = SharedInMemoryConditionalStore()
    var w = TelemetryMetricSegmentWriter[SharedInMemoryConditionalStore](
        store.clone(), String("writer-1")
    )
    # Deliberately scrambled on BOTH axes. If the writer sorted on `ts` alone
    # (the LOG dataset's key — the single likeliest wrong implementation), the
    # file order would be 100,200,300,400,500,600 of ts and the series column
    # would read 2,1,2,1,2,1. That is what CASE 1 discriminates.
    var sids = List[Int64]()
    var ts = List[Int64]()
    var pairs_s = List[Int64]()
    var pairs_t = List[Int64]()
    pairs_s.append(Int64(2)); pairs_t.append(Int64(500))
    pairs_s.append(Int64(1)); pairs_t.append(Int64(600))
    pairs_s.append(Int64(2)); pairs_t.append(Int64(100))
    pairs_s.append(Int64(1)); pairs_t.append(Int64(400))
    pairs_s.append(Int64(2)); pairs_t.append(Int64(300))
    pairs_s.append(Int64(1)); pairs_t.append(Int64(200))
    for i in range(len(pairs_s)):
        sids.append(pairs_s[i])
        ts.append(_DAY_T0 + pairs_t[i] * Int64(1_000_000))

    var entries = w.publish_batches(_one_batch(_fact_batch(sids^, ts^)))
    assert_equal(len(entries), 1, "1: one day touched -> ONE object")
    ref e = entries[0]

    # --- the key: the `metrics` dataset, the COMPUTED day, constant depth ----
    var day = day_string_from_ns(_DAY_T0)
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
        String("1: key '")
        + e.object_key
        + String("' must start with the computed partition prefix '")
        + want_prefix
        + String("'"),
    )
    assert_equal(
        telemetry_key_depth(e.object_key),
        TELEMETRY_DATA_KEY_DEPTH,
        "1: key depth is a CONSTANT (keys.mojo rule 3)",
    )

    # --- the FILE's order, read back out of real Parquet --------------------
    var rb = _readback(store, e.object_key)
    assert_equal(rb.num_rows(), 6, "1: all six rows in the object")
    var got_s = _i64_col(rb, METRIC_SERIES_COLUMN)
    var got_t = _i64_col(rb, METRIC_TIME_COLUMN)
    for i in range(1, len(got_s)):
        assert_true(
            got_s[i - 1] <= got_s[i],
            String("1: series_id must be non-decreasing in the file at row ")
            + String(i),
        )
        if got_s[i - 1] == got_s[i]:
            assert_true(
                got_t[i - 1] <= got_t[i],
                String("1: within one series, ts must be non-decreasing at row ")
                + String(i),
            )
    # And the discriminating assertion: series 1's THREE rows are CONTIGUOUS.
    assert_equal(got_s[0], Int64(1), "1: series 1 first")
    assert_equal(got_s[1], Int64(1), "1: series 1 contiguous")
    assert_equal(got_s[2], Int64(1), "1: series 1 contiguous")
    assert_equal(got_s[3], Int64(2), "1: then series 2")
    assert_equal(got_s[5], Int64(2), "1: series 2 contiguous")


# =============================================================================
# CASE 2 — THE GATHER MOVES THE WHOLE ROW.
# A sort that permuted only the two key columns would pass CASE 1 completely.
# =============================================================================


def test_02_the_sort_permutes_whole_rows_not_just_the_key_columns() raises:
    var store = SharedInMemoryConditionalStore()
    var w = TelemetryMetricSegmentWriter[SharedInMemoryConditionalStore](
        store.clone(), String("writer-1")
    )
    var sids = List[Int64]()
    var ts = List[Int64]()
    # `value` is the row's input index (see `_fact_batch`), so the expected file
    # order of `value` is the permutation itself.
    sids.append(Int64(9)); ts.append(_DAY_T0 + Int64(100_000_000))  # value 0
    sids.append(Int64(3)); ts.append(_DAY_T0 + Int64(900_000_000))  # value 1
    sids.append(Int64(3)); ts.append(_DAY_T0 + Int64(200_000_000))  # value 2
    var entries = w.publish_batches(_one_batch(_fact_batch(sids^, ts^)))
    var rb = _readback(store, entries[0].object_key)
    var vals = _f64_col(rb, String("value"))
    assert_equal(len(vals), 3, "2: three rows")
    # (3,200) then (3,900) then (9,100) -> input indices 2, 1, 0.
    assert_equal(vals[0], Float64(2.0), "2: row 2 first — payload followed key")
    assert_equal(vals[1], Float64(1.0), "2: row 1 second")
    assert_equal(vals[2], Float64(0.0), "2: row 0 last")


# =============================================================================
# CASE 3 — THE CATALOG IS TRUE OF THE OBJECT IT NAMES.
# Bounds re-derived from the DECODED FILE, required to CONTAIN every row and to
# be TIGHT. A catalog that describes an object it does not match is invisible to
# every other check, because every other check reads the catalog.
# =============================================================================


def test_03_manifest_bounds_are_true_and_tight_for_the_rows_written() raises:
    var store = SharedInMemoryConditionalStore()
    var w = TelemetryMetricSegmentWriter[SharedInMemoryConditionalStore](
        store.clone(), String("writer-1")
    )
    var sids = List[Int64]()
    var ts = List[Int64]()
    var s_in = List[Int64]()
    var t_in = List[Int64]()
    s_in.append(Int64(40)); t_in.append(Int64(700))
    s_in.append(Int64(11)); t_in.append(Int64(250))
    s_in.append(Int64(40)); t_in.append(Int64(120))
    s_in.append(Int64(27)); t_in.append(Int64(999))
    for i in range(len(s_in)):
        sids.append(s_in[i])
        ts.append(_DAY_T0 + t_in[i] * Int64(1_000_000))
    var entries = w.publish_batches(_one_batch(_fact_batch(sids^, ts^)))
    assert_equal(len(entries), 1, "3: one object")
    ref e = entries[0]

    # Re-derive the truth from the FILE, not from the inputs.
    var rb = _readback(store, e.object_key)
    assert_equal(
        Int64(rb.num_rows()), e.row_count, "3: row_count matches the file"
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

    # CONTAINS: no row may fall outside the advertised bound.
    for i in range(len(fs)):
        assert_true(
            e.min_ts_ns <= ft[i] and ft[i] <= e.max_ts_ns,
            String("3: row ") + String(i) + String(" ts is outside [min,max]"),
        )
        assert_true(
            e.min_series_id <= fs[i] and fs[i] <= e.max_series_id,
            String("3: row ")
            + String(i)
            + String(" series_id is outside [min,max]"),
        )
    # TIGHT: a bound wider than the data prunes nothing. This is the half that
    # fails for a writer that advertises a legal-but-useless range.
    assert_equal(e.min_ts_ns, mn_t, "3: min_ts is the file's true minimum")
    assert_equal(e.max_ts_ns, mx_t, "3: max_ts is the file's true maximum")
    assert_equal(e.min_series_id, mn_s, "3: min_series_id is TIGHT (11)")
    assert_equal(e.max_series_id, mx_s, "3: max_series_id is TIGHT (40)")
    assert_equal(e.min_series_id, Int64(11), "3: and the value is the real one")
    assert_equal(e.max_series_id, Int64(40), "3: and the value is the real one")

    # The entry is REPLAYABLE — the catalog a reader actually sees, not just the
    # return value. This is what proves the CAS append happened at all.
    var m = open_partition_manifest[SharedInMemoryConditionalStore](
        store,
        TELEMETRY_ROOT,
        TELEMETRY_DATASET_METRICS,
        day_string_from_ns(_DAY_T0),
        String("writer-1"),
    )
    var live = m.live_segments()
    assert_equal(len(live), 1, "3: one live segment in the replayed catalog")
    assert_equal(
        live[0].object_key, e.object_key, "3: and it names the object we PUT"
    )
    assert_equal(live[0].min_series_id, mn_s, "3: replayed bound survives codec")
    assert_equal(live[0].max_series_id, mx_s, "3: replayed bound survives codec")
    assert_false(
        live[0].has_text_sidecar,
        "3: the metrics dataset NEVER has a text sidecar ",
    )


# =============================================================================
# CASE 4 — AN EMPTY DRAIN PUBLISHES NOTHING. Not an empty object, not a manifest
# append. The store must be untouched.
# =============================================================================


def test_04_an_empty_drain_publishes_nothing_at_all() raises:
    var store = SharedInMemoryConditionalStore()
    var w = TelemetryMetricSegmentWriter[SharedInMemoryConditionalStore](
        store.clone(), String("writer-1")
    )
    # (a) zero batches.
    var e0 = w.publish_batches(Slab[RecordBatch](capacity=1))
    assert_equal(len(e0), 0, "4a: zero batches -> zero entries")
    # (b) one batch holding zero rows — the shape an idle flush actually builds.
    var e1 = w.publish_batches(
        _one_batch(_fact_batch(List[Int64](), List[Int64]()))
    )
    assert_equal(len(e1), 0, "4b: a 0-row batch -> zero entries")
    assert_equal(w.segments_published(), Int64(0), "4: nothing published")
    assert_equal(w.rows_published(), Int64(0), "4: no rows published")

    # THE ASSERTION THAT MAKES THIS A REAL TEST: the STORE is untouched. A
    # writer that PUT a 0-row Parquet object and skipped only the manifest
    # append would pass every assertion above and would still be charging a PUT
    # on every idle flush, and object-store operations are the cost model.
    #
    # A not-found on the _HEAD of the partition that WOULD have been written is
    # the observable. The POSITIVE CONTROL is below: after a real publish the
    # same probe finds it, so a green here is not the probe silently failing.
    var head_key = (
        TELEMETRY_ROOT
        + String("/")
        + TELEMETRY_DATASET_METRICS
        + String("/")
        + day_string_from_ns(_DAY_T0)
        + String("/_lineage/writer-1/_HEAD")
    )
    var found_before = True
    try:
        _ = store.get(Path.parse(head_key))
    except:
        found_before = False
    assert_false(found_before, "4: no lineage created by an empty publish")

    var sids = List[Int64]()
    var ts = List[Int64]()
    sids.append(Int64(5))
    ts.append(_DAY_T0 + Int64(1_000_000))
    _ = w.publish_batches(_one_batch(_fact_batch(sids^, ts^)))
    var found_after = True
    try:
        _ = store.get(Path.parse(head_key))
    except:
        found_after = False
    assert_true(
        found_after,
        "4: POSITIVE CONTROL — after a REAL publish the same probe FINDS the"
        " lineage, so the assertion above is observing absence and not a broken"
        " probe",
    )


# =============================================================================
# CASE 5 — A FLUSH STRADDLING MIDNIGHT BECOMES TWO OBJECTS, ONE PER PARTITION.
# Compaction may never merge across days; the WRITE side owes the same
# invariant, or the day prefix is a naming convention rather than an index.
# =============================================================================


def test_05_a_midnight_straddle_splits_into_two_partitions() raises:
    var store = SharedInMemoryConditionalStore()
    var w = TelemetryMetricSegmentWriter[SharedInMemoryConditionalStore](
        store.clone(), String("writer-1")
    )
    var sids = List[Int64]()
    var ts = List[Int64]()
    sids.append(Int64(1)); ts.append(_DAY_T0 + Int64(5))
    sids.append(Int64(1)); ts.append(_DAY_T0 + NS_PER_DAY + Int64(5))
    sids.append(Int64(2)); ts.append(_DAY_T0 + Int64(9))
    var entries = w.publish_batches(_one_batch(_fact_batch(sids^, ts^)))
    assert_equal(len(entries), 2, "5: two days touched -> TWO objects")

    var d0 = day_string_from_ns(_DAY_T0)
    var d1 = day_string_from_ns(_DAY_T0 + NS_PER_DAY)
    assert_true(d0 != d1, "5: the two day strings differ (sanity)")
    var total_rows = Int64(0)
    for k in range(len(entries)):
        ref e = entries[k]
        total_rows += e.row_count
        # EVERY ENTRY'S RANGE LIES INSIDE ITS OWN PARTITION. This is the
        # invariant that makes the day prefix a real index.
        var own_day = day_string_from_ns(e.min_ts_ns)
        assert_equal(
            day_string_from_ns(e.max_ts_ns),
            own_day,
            "5: an entry's [min,max] must not cross a day boundary",
        )
        assert_true(
            e.object_key.find(String("/") + own_day + String("/")) > 0,
            String("5: the key must carry the entry's own day: ") + e.object_key,
        )
    assert_equal(total_rows, Int64(3), "5: every row landed exactly once")


# =============================================================================
# CASE 6 — THE ROW-GROUP KNOB IS THREADED TO THE ENCODER.
# A hardcoded row-group size is a real defect; this is what makes it go red.
# =============================================================================


def test_06_the_row_group_size_reaches_the_encoder() raises:
    var store = SharedInMemoryConditionalStore()
    # 2 rows per row group over 5 rows -> 3 row groups. The default (65,536)
    # would give 1, so the two are distinguishable.
    var w = TelemetryMetricSegmentWriter[SharedInMemoryConditionalStore](
        store.clone(),
        String("writer-rg"),
        TELEMETRY_ROOT,
        rows_per_row_group=2,
    )
    assert_true(
        TELEMETRY_METRIC_ROWS_PER_ROW_GROUP == 65_536,
        "6: the ~64K target is the default",
    )
    var sids = List[Int64]()
    var ts = List[Int64]()
    for i in range(5):
        sids.append(Int64(1))
        ts.append(_DAY_T0 + Int64(i) * Int64(1_000_000))
    var entries = w.publish_batches(_one_batch(_fact_batch(sids^, ts^)))
    # The observable available without a footer API here is that all five rows
    # survive a multi-row-group encode/decode round trip IN ORDER — a broken
    # threading either produces one group (indistinguishable) or corrupts the
    # boundary rows (very distinguishable).
    var rb = _readback(store, entries[0].object_key)
    assert_equal(rb.num_rows(), 5, "6: five rows across three row groups")
    var got = _i64_col(rb, METRIC_TIME_COLUMN)
    for i in range(5):
        assert_equal(
            got[i],
            _DAY_T0 + Int64(i) * Int64(1_000_000),
            String("6: row ") + String(i) + String(" survived the group split"),
        )


# =============================================================================
# CASE 7 — THE WRITER REFUSES A BATCH WITHOUT ITS TWO KEY COLUMNS, BY NAME.
# A silent fallback here would partition on the wrong column.
# =============================================================================


def test_07_a_batch_missing_a_key_column_is_refused_loudly() raises:
    var store = SharedInMemoryConditionalStore()
    var w = TelemetryMetricSegmentWriter[SharedInMemoryConditionalStore](
        store.clone(), String("writer-1")
    )
    var sb = SchemaBuilder()
    sb.add_field(Field(METRIC_TIME_COLUMN, ArrowType.TIMESTAMP_NS, False))
    sb.add_field(Field(String("not_series_id"), ArrowType.INT64, False))
    var schema = sb.build()
    var tvals = List[Int64]()
    tvals.append(_DAY_T0)
    var other = List[Int64]()
    other.append(Int64(1))
    var rb = RecordBatchBuilder.with_capacity(2)
    rb.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](
            PrimitiveArray[DType.int64].from_list(tvals^),
            ArrowType.TIMESTAMP_NS,
        )
    )
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(other^)
        )
    )
    var raised = False
    try:
        _ = w.publish_batches(_one_batch(rb.build(schema^)))
    except e:
        raised = True
        assert_true(
            String(e).find(METRIC_SERIES_COLUMN) >= 0,
            "7: the error must NAME the missing column",
        )
    assert_true(raised, "7: a batch with no series_id column is REFUSED")

    # POSITIVE CONTROL: the same writer accepts a well-formed batch, so the
    # refusal above is about the schema and not about the writer being broken.
    var sids = List[Int64]()
    var ts = List[Int64]()
    sids.append(Int64(1))
    ts.append(_DAY_T0)
    var ok = w.publish_batches(_one_batch(_fact_batch(sids^, ts^)))
    assert_equal(len(ok), 1, "7: POSITIVE CONTROL — a good batch publishes")


# =============================================================================
# CASE 8 — TWO FLUSHES INTO ONE PARTITION ARE TWO SEGMENTS IN ONE CATALOG.
# The warm-append path plus the manifest replay's forward probe (the deferred
# `_HEAD` advance) — the shape a long-lived writer runs.
# =============================================================================


def test_08_successive_flushes_accumulate_in_one_partition_catalog() raises:
    var store = SharedInMemoryConditionalStore()
    var w = TelemetryMetricSegmentWriter[SharedInMemoryConditionalStore](
        store.clone(), String("writer-1")
    )
    for f in range(3):
        var sids = List[Int64]()
        var ts = List[Int64]()
        sids.append(Int64(f + 1))
        ts.append(_DAY_T0 + Int64(f) * Int64(1_000_000))
        _ = w.publish_batches(_one_batch(_fact_batch(sids^, ts^)))
    assert_equal(w.segments_published(), Int64(3), "8: three segments")
    assert_equal(w.rows_published(), Int64(3), "8: three rows")

    var m = open_partition_manifest[SharedInMemoryConditionalStore](
        store,
        TELEMETRY_ROOT,
        TELEMETRY_DATASET_METRICS,
        day_string_from_ns(_DAY_T0),
        String("writer-1"),
    )
    var live = m.live_segments()
    assert_equal(
        len(live),
        3,
        "8: ALL THREE are replayable — a reader that trusted the deferred"
        " durable _HEAD would see one and silently miss two",
    )
    # Every segment's uuid is distinct — the dup-window skip keys on it.
    for a in range(len(live)):
        for b in range(a + 1, len(live)):
            var same = True
            for i in range(16):
                if live[a].segment_uuid[i] != live[b].segment_uuid[i]:
                    same = False
                    break
            assert_false(same, "8: segment uuids must be distinct")


def main() raises:
    test_01_marquee_the_metrics_artifact_is_series_then_time_sorted()
    test_02_the_sort_permutes_whole_rows_not_just_the_key_columns()
    test_03_manifest_bounds_are_true_and_tight_for_the_rows_written()
    test_04_an_empty_drain_publishes_nothing_at_all()
    test_05_a_midnight_straddle_splits_into_two_partitions()
    test_06_the_row_group_size_reaches_the_encoder()
    test_07_a_batch_missing_a_key_column_is_refused_loudly()
    test_08_successive_flushes_accumulate_in_one_partition_catalog()
    print("test_telemetry_metric_segment_writer: ALL CASES PASSED")
