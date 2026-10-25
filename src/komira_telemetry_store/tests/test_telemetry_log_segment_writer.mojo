# =============================================================================
# komira_telemetry_store/tests/test_telemetry_log_segment_writer.mojo
#   THE FALSIFIER for the BASE at-rest artifact: TIME-PARTITIONED,
#   TIME-SORTED PARQUET, published before its manifest entry.
# =============================================================================
#
# Time-partitioned Parquet is the base artifact for logs; a text index is an
# optional sidecar beside it. This file is where "the file's sort order" and
# "the day is in the key" stop being prose.
#
# THE SORT ORDER IS READ BACK OUT OF THE PARQUET FILE, NOT ASSERTED ON THE
# BATCH THE WRITER BUILT. A test that checked the in-memory batch would pass for
# a writer that sorted and then encoded the UNSORTED input, which is the single
# most likely way this breaks. Every case that claims a file property decodes
# the published bytes with `_read_parquet_full` (below, built on
# `komira_parquet`'s reader) and reads the column.
#
# THE SCHEMA HERE IS BUILT LOCALLY: 8 columns, `timestamp` among them. CASE 1
# asserts the writer's own column contract by NAME.
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
from komira_arrow.string_array import StringArray

from komira_objectstore.cas_manifest import RetryPolicy
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.store import (
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
)
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)

from komira_buffer.byte_view import ByteView
from komira_parquet.bytes_decode import (
    decode_row_group_from_bytes,
    row_group_byte_range,
)
from komira_parquet.metadata_parser import parse_full_metadata
from komira_parquet.morsel_reader import ColumnProjection
from komira_parquet_api.types import CompressionCodec

from komira_telemetry_store.keys import (
    NS_PER_DAY,
    TELEMETRY_DATASET_LOGS,
    TELEMETRY_ROOT,
    day_string_from_ns,
    telemetry_text_sidecar_key,
)
from komira_telemetry_store.log_writer import (
    LOG_TIME_COLUMN,
    TELEMETRY_DEFAULT_CODEC,
    TELEMETRY_LOG_ROWS_PER_ROW_GROUP,
    TelemetryLogSegmentWriter,
)
from komira_telemetry_store.manifest import open_partition_manifest
from komira_telemetry_store.segment_entry import (
    TELEMETRY_UUID_BYTES,
    TelemetrySegmentEntry,
    make_log_segment_entry,
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


def _log_batch(
    var messages: List[String], var ts_ns: List[Int64]
) raises -> RecordBatch:
    """A log batch of 8 columns: message, _source, timestamp, level, module,
    corr_id, flags, site_id. The writer needs only the `timestamp` column."""
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


def _readback(
    store: SharedInMemoryConditionalStore, key: String
) raises -> RecordBatch:
    """Fetch the published object and decode it as a REAL Parquet file."""
    return _read_parquet_full(store.get(Path.parse(key)))


def _ts_col(rb: RecordBatch) raises -> List[Int64]:
    var idx = -1
    for c in range(rb.num_columns()):
        if rb.schema.field_name(c) == LOG_TIME_COLUMN:
            idx = c
    if idx < 0:
        raise Error("readback: no timestamp column in the decoded file")
    var arr = rb.column_at(idx).as_primitive[DType.int64]()
    var out = List[Int64](capacity=rb.num_rows())
    for r in range(rb.num_rows()):
        out.append(Int64(arr.get(r)))
    return out^


def _msg_col(rb: RecordBatch) raises -> List[String]:
    var arr = rb.column_at(0).as_string()
    var out = List[String](capacity=rb.num_rows())
    for r in range(rb.num_rows()):
        out.append(arr.get(r))
    return out^


# =============================================================================
# CASE 1 — MARQUEE. Unsorted rows in; ONE Parquet object out, at the day's
# computed key, SORTED BY TIME IN THE FILE, with a manifest entry that carries
# the true [min_ts,max_ts].
# =============================================================================


def test_01_marquee_the_base_artifact_is_time_sorted_parquet() raises:
    var store = SharedInMemoryConditionalStore()
    var w = TelemetryLogSegmentWriter[SharedInMemoryConditionalStore](
        store.clone(), String("writer-1")
    )
    # Deliberately OUT of time order — the writer must impose the sort.
    var msgs = List[String]()
    var ts = List[Int64]()
    var offsets = List[Int64]()
    offsets.append(Int64(500))
    offsets.append(Int64(100))
    offsets.append(Int64(900))
    offsets.append(Int64(300))
    for i in range(len(offsets)):
        msgs.append(String("line-") + String(offsets[i]))
        ts.append(_DAY_T0 + offsets[i] * Int64(1_000_000))

    var entries = w.publish_batches(
        _one_batch(_log_batch(msgs^, ts^))
    )
    assert_equal(len(entries), 1, "1: one day touched -> ONE object")
    ref e = entries[0]

    # --- the key carries the partition, COMPUTED from the data ---------------
    assert_true(
        e.object_key.find(String("telemetry/logs/20261001/data/")) == 0,
        "1: the object key must carry the UTC day of its rows. The day prefix"
        " is the index: a reader COMPUTES it from [t0,t1] and never lists."
        " Got: " + e.object_key,
    )
    # --- the manifest entry's range is the rows' TRUE range ------------------
    assert_equal(
        e.min_ts_ns,
        _DAY_T0 + Int64(100) * Int64(1_000_000),
        "1: min_ts_ns is the EARLIEST row, not the first row of the input",
    )
    assert_equal(
        e.max_ts_ns,
        _DAY_T0 + Int64(900) * Int64(1_000_000),
        "1: max_ts_ns is the LATEST row",
    )
    assert_equal(e.row_count, Int64(4), "1: row_count")
    assert_true(e.byte_size > Int64(0), "1: byte_size is the bytes PUT")
    assert_false(e.has_text_sidecar, "1: no sidecar was asked for")

    # --- THE FILE'S SORT ORDER, READ BACK OUT OF THE PARQUET --------------
    var rb = _readback(store, e.object_key)
    assert_equal(rb.num_rows(), 4, "1: every row landed in the file")
    var got = _ts_col(rb)
    for i in range(1, len(got)):
        assert_true(
            got[i - 1] <= got[i],
            "1: the ROWS IN THE FILE must be ascending in `timestamp`. This"
            " is read back from the PUBLISHED BYTES, not from the batch the"
            " writer built — a writer that sorted a copy and encoded the"
            " original would pass the second and fail this",
        )
    var m = _msg_col(rb)
    assert_equal(
        m[0], String("line-100"), "1: ...and the EARLIEST line is row 0, by text"
    )
    assert_equal(
        m[3], String("line-900"), "1: ...and the LATEST line is the last row"
    )
    _ = w^
    _ = store^


# =============================================================================
# CASE 2 — NO OBJECT MAY STRADDLE A DAY BOUNDARY. A flush across midnight
# becomes TWO objects in TWO partitions.
# =============================================================================


def test_02_a_flush_across_midnight_becomes_two_partitioned_objects() raises:
    var store = SharedInMemoryConditionalStore()
    var w = TelemetryLogSegmentWriter[SharedInMemoryConditionalStore](
        store.clone(), String("writer-2")
    )
    var msgs = List[String]()
    var ts = List[Int64]()
    msgs.append(String("before-midnight"))
    ts.append(_DAY_T0 + NS_PER_DAY - Int64(1))
    msgs.append(String("after-midnight"))
    ts.append(_DAY_T0 + NS_PER_DAY)
    msgs.append(String("also-before"))
    ts.append(_DAY_T0 + NS_PER_DAY - Int64(1000))

    var entries = w.publish_batches(
        _one_batch(_log_batch(msgs^, ts^))
    )
    assert_equal(
        len(entries),
        2,
        "2: TWO objects, one per UTC day. An object spanning midnight would"
        " have a [min_ts,max_ts] crossing a partition boundary — the exact"
        " property compaction is forbidden from creating, because such an"
        " entry prunes NOTHING and must be fetched by every query",
    )
    assert_true(
        entries[0].object_key.find(String("telemetry/logs/20261001/data/")) == 0,
        "2: first object in the 08-26 partition. Got: " + entries[0].object_key,
    )
    assert_true(
        entries[1].object_key.find(String("telemetry/logs/20261002/data/")) == 0,
        "2: second object in the 08-27 partition. Got: " + entries[1].object_key,
    )
    assert_equal(entries[0].row_count, Int64(2), "2: two rows before midnight")
    assert_equal(entries[1].row_count, Int64(1), "2: one row after")
    # Each object's range must lie INSIDE its own partition.
    assert_equal(
        day_string_from_ns(entries[0].min_ts_ns),
        day_string_from_ns(entries[0].max_ts_ns),
        "2: ...and object 0's OWN [min,max] does not cross a day",
    )
    assert_equal(
        day_string_from_ns(entries[1].min_ts_ns),
        String("20261002"),
        "2: ...and object 1 is wholly in the next day",
    )
    var rb0 = _readback(store, entries[0].object_key)
    assert_equal(rb0.num_rows(), 2, "2: the 08-26 file really holds 2 rows")
    var rb1 = _readback(store, entries[1].object_key)
    assert_equal(rb1.num_rows(), 1, "2: the 08-27 file really holds 1 row")
    assert_equal(
        _msg_col(rb1)[0],
        String("after-midnight"),
        "2: ...and it is the RIGHT row, by its own text",
    )
    _ = w^
    _ = store^


# =============================================================================
# CASE 3 — the object is PUBLISHED THROUGH THE MANIFEST, and a fresh reader
# finds it by replay and prunes on it.
# =============================================================================


def test_03_the_segment_is_discoverable_by_manifest_replay() raises:
    var store = SharedInMemoryConditionalStore()
    var w = TelemetryLogSegmentWriter[SharedInMemoryConditionalStore](
        store.clone(), String("writer-3")
    )
    for k in range(3):
        var msgs = List[String]()
        var ts = List[Int64]()
        msgs.append(String("flush-") + String(k))
        ts.append(_DAY_T0 + Int64(k) * Int64(60) * Int64(1_000_000_000))
        _ = w.publish_batches(
            _one_batch(_log_batch(msgs^, ts^))
        )
    assert_equal(w.segments_published(), Int64(3), "3: three flushes published")

    var r = open_partition_manifest[SharedInMemoryConditionalStore](
        store, TELEMETRY_ROOT, TELEMETRY_DATASET_LOGS, String("20261001"),
        String("writer-3"),
    )
    var live = r.live_segments()
    assert_equal(
        len(live),
        3,
        "3: a FRESH reader must replay all three — the deferred durable _HEAD"
        " advance pins _HEAD at the first publish",
    )
    # Prune to the middle flush only.
    var hit = r.segments_overlapping(
        _DAY_T0 + Int64(60) * Int64(1_000_000_000),
        _DAY_T0 + Int64(60) * Int64(1_000_000_000),
    )
    assert_equal(len(hit), 1, "3: a point-in-time query selects ONE segment")
    var rb = _readback(store, hit[0].object_key)
    assert_equal(
        _msg_col(rb)[0],
        String("flush-1"),
        "3: ...and the object it selected really holds THAT flush's line —"
        " arrival asserted by content, never by the manifest alone",
    )
    _ = r^
    _ = w^
    _ = store^


# =============================================================================
# CASE 4 — THE DEMOTION. The text split is a SIDECAR: written beside the base
# at a DERIVED key, flagged in the entry, and never the thing a time-range read
# opens.
# =============================================================================


def test_04_the_text_split_is_a_sidecar_beside_the_base() raises:
    var store = SharedInMemoryConditionalStore()
    var w = TelemetryLogSegmentWriter[SharedInMemoryConditionalStore](
        store.clone(), String("writer-4")
    )
    var msgs = List[String]()
    var ts = List[Int64]()
    msgs.append(String("connection refused"))
    ts.append(_DAY_T0 + Int64(5))

    var split = List[UInt8]()
    for i in range(64):
        split.append(UInt8(i))
    var entries = w.publish_batches(
        _one_batch(_log_batch(msgs^, ts^)),
        Optional[List[UInt8]](split^),
    )
    assert_equal(len(entries), 1, "4: one object")
    ref e = entries[0]
    assert_true(
        e.has_text_sidecar,
        "4: the entry records that a sidecar exists — ONE BIT is all a reader"
        " needs, because the sidecar's key is DERIVED from the base's",
    )
    var side_key = telemetry_text_sidecar_key(e.object_key)
    var side = store.get(Path.parse(side_key))
    assert_equal(
        len(side),
        64,
        "4: ...and the sidecar bytes are AT the derived key. No second"
        " manifest, no pairing LIST — the name is derivable."
        " Key: " + side_key,
    )
    assert_equal(Int(side[7]), 7, "4: ...and they are the bytes we handed over")
    assert_equal(w.sidecars_published(), Int64(1), "4: counter agrees")

    # AND THE DEMOTION ITSELF: the base is what a time-range read opens.
    var r = open_partition_manifest[SharedInMemoryConditionalStore](
        store, TELEMETRY_ROOT, TELEMETRY_DATASET_LOGS, String("20261001"),
        String("writer-4"),
    )
    var hit = r.segments_overlapping(_DAY_T0, _DAY_T0 + Int64(10))
    assert_equal(len(hit), 1, "4: the range selects the segment")
    assert_true(
        hit[0].object_key.find(String(".parquet")) > 0,
        "4: a TIME-RANGE READ RESOLVES TO THE .parquet BASE, never to the"
        " .split. That is the whole inversion: the text index stays PRODUCED"
        " but stops being the artifact a time query must open. Got: "
        + hit[0].object_key,
    )
    assert_false(
        hit[0].object_key.find(String(".split")) > 0,
        "4: ...and specifically not the split",
    )
    _ = r^
    _ = w^
    _ = store^


def test_05_a_sidecar_is_refused_when_the_flush_straddles_midnight() raises:
    var store = SharedInMemoryConditionalStore()
    var w = TelemetryLogSegmentWriter[SharedInMemoryConditionalStore](
        store.clone(), String("writer-5")
    )
    var msgs = List[String]()
    var ts = List[Int64]()
    msgs.append(String("before"))
    ts.append(_DAY_T0 + NS_PER_DAY - Int64(1))
    msgs.append(String("after"))
    ts.append(_DAY_T0 + NS_PER_DAY)
    var split = List[UInt8]()
    split.append(UInt8(1))

    var refused = False
    try:
        _ = w.publish_batches(
            _one_batch(_log_batch(msgs^, ts^)),
            Optional[List[UInt8]](split^),
        )
    except:
        refused = True
    assert_true(
        refused,
        "5: a sidecar for a flush spanning TWO partitions must RAISE. A sidecar"
        " names row ids inside ONE data object; pairing it with either half"
        " would name rows that object does not hold — worse than no sidecar",
    )
    _ = w^
    _ = store^


# =============================================================================
# CASE 6 — the writer's own contract, and its refusals.
# =============================================================================


def test_06_a_batch_without_a_timestamp_column_is_refused() raises:
    var store = SharedInMemoryConditionalStore()
    var w = TelemetryLogSegmentWriter[SharedInMemoryConditionalStore](
        store.clone(), String("writer-6")
    )
    var sb = SchemaBuilder()
    sb.add_field(Field(String("message"), ArrowType.STRING, False))
    sb.add_field(Field(String("when"), ArrowType.INT64, False))
    var schema = sb.build()
    var msgs = List[String]()
    msgs.append(String("x"))
    var whens = List[Int64]()
    whens.append(Int64(1))
    var rb = RecordBatchBuilder.with_capacity(2)
    rb.add_column(Column.from_string(StringArray.from_strings(msgs^)))
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(whens^)
        )
    )
    var refused = False
    try:
        _ = w.publish_batches(_one_batch(rb.build(schema^)))
    except:
        refused = True
    assert_true(
        refused,
        "6: a batch with no `timestamp` column must RAISE. This writer"
        " partitions AND sorts by time; silently falling back to input order"
        " would produce an object whose key claims a day its rows are not in",
    )
    assert_equal(
        LOG_TIME_COLUMN,
        String("timestamp"),
        "6: the column name is `timestamp`. If it is renamed, this goes"
        " RED here rather than silently mis-partitioning every log line",
    )
    _ = w^
    _ = store^


def test_07_an_empty_flush_publishes_nothing() raises:
    var store = SharedInMemoryConditionalStore()
    var w = TelemetryLogSegmentWriter[SharedInMemoryConditionalStore](
        store.clone(), String("writer-7")
    )
    var entries = w.publish_batches(Slab[RecordBatch](capacity=0))
    assert_equal(
        len(entries),
        0,
        "7: an empty flush must publish NOTHING — a 0-row segment's [min,max]"
        " is meaningless and its entry would make every query fetch it",
    )
    assert_equal(w.segments_published(), Int64(0), "7: nothing counted either")
    assert_equal(
        store.n_put(), Int64(0), "7: ...and no object was PUT at all"
    )
    _ = w^
    _ = store^


# =============================================================================
# CASE 8 — the codec is a PARAMETER. Both arms produce a readable file.
# =============================================================================


def test_08_both_codecs_round_trip() raises:
    var store = SharedInMemoryConditionalStore()
    var w = TelemetryLogSegmentWriter[SharedInMemoryConditionalStore](
        store.clone(), String("writer-8"), String("telemetry"),
        CompressionCodec.ZSTD,
    )
    var msgs = List[String]()
    var ts = List[Int64]()
    for i in range(8):
        msgs.append(String("zstd-line-") + String(i))
        ts.append(_DAY_T0 + Int64(7 - i) * Int64(1_000_000))
    var entries = w.publish_batches(
        _one_batch(_log_batch(msgs^, ts^))
    )
    assert_equal(len(entries), 1, "8: one object")
    var rb = _readback(store, entries[0].object_key)
    assert_equal(rb.num_rows(), 8, "8: the ZSTD file decodes to every row")
    var got = _ts_col(rb)
    for i in range(1, len(got)):
        assert_true(
            got[i - 1] <= got[i],
            "8: ...and the ZSTD arm is time-sorted too. The default codec is"
            " snappy; the zstd path is covered here rather than left"
            " untested",
        )
    assert_equal(
        _msg_col(rb)[0],
        String("zstd-line-7"),
        "8: ...with the earliest line first, by text",
    )
    _ = w^
    _ = store^


# =============================================================================
# OrderProbeStore — THE INSTRUMENT FOR THE PUT-BEFORE-APPEND ORDERING.
#
# WHY A COUNTER OR AN AFTER-THE-FACT `get` CANNOT DO THIS. `publish_batches`
# documents the ordering as load-bearing — "the object is PUT before its manifest
# entry is appended ... the reverse order would leave an entry naming an object
# that does not exist, which a reader cannot distinguish from a transient 404" —
# and CASE 1 carries an assertion whose stated reason claims to cover it ("An
# entry naming an absent object is the one ordering that loses data instead of
# bytes"). It does not: it `get`s the object AFTER `publish_batches` has
# returned, by which time BOTH operations have run. It cannot observe order at
# all: a writer that PUT the object after the manifest append would pass it.
#
# SO THE PROBE ASKS THE QUESTION AT THE ONLY MOMENT IT IS ANSWERABLE: at the
# instant a manifest CHUNK write is issued, does the `.parquet` object it is
# about to make readable ALREADY EXIST? The verdict is written into the SHARED
# in-memory map (not into a field), because the writer `clone()`s its store for
# the manifest handle and a field on this struct would be a different instance's
# field by then.
#
# The marker keys are prefixed `__probe__/` and are skipped by the probe itself,
# so the instrument cannot observe its own writes.
# =============================================================================

comptime _PROBE_DATA_SEEN: String = "__probe__/data_object_was_put"
comptime _PROBE_OK: String = "__probe__/append_saw_its_object"
comptime _PROBE_VIOLATION: String = "__probe__/append_preceded_its_object"


struct OrderProbeStore(
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    """`SharedInMemoryConditionalStore` that records, for every manifest chunk
    write, whether the `.parquet` object already existed at that instant."""

    var _inner: SharedInMemoryConditionalStore

    def __init__(out self, var inner: SharedInMemoryConditionalStore):
        self._inner = inner^

    def clone(self) -> Self:
        return Self(self._inner.clone())

    def _mark(self, key: String) raises:
        var one = List[UInt8]()
        one.append(UInt8(1))
        _ = self._inner.put(Path.parse(key), one^)

    def _exists(self, key: String) -> Bool:
        try:
            var b = self._inner.get(Path.parse(key))
            _ = b^
            return True
        except:
            return False

    def _note(self, path: Path) raises:
        var raw = path.raw()
        # NEVER observe our own marker writes.
        if raw.find(String("__probe__/")) == 0:
            return
        if raw.find(String(".parquet")) > 0:
            self._mark(_PROBE_DATA_SEEN)
            return
        if raw.find(String("/manifest/")) > 0 and raw.find(String(".chunk")) > 0:
            # THE QUESTION, ASKED AT THE ONLY MOMENT IT IS ANSWERABLE.
            if self._exists(_PROBE_DATA_SEEN):
                self._mark(_PROBE_OK)
            else:
                self._mark(_PROBE_VIOLATION)

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        self._note(path)
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        self._note(path)
        return self._inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        self._note(path)
        return self._inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        return self._inner.get(path)

    def delete(self, path: Path) raises -> None:
        return self._inner.delete(path)


def _marked(store: SharedInMemoryConditionalStore, key: String) -> Bool:
    try:
        var b = store.get(Path.parse(key))
        _ = b^
        return True
    except:
        return False


# =============================================================================
# CASE 9 — THE ORDERING. The `.parquet` object EXISTS at the instant its
# manifest entry is appended.
# =============================================================================


def test_09_the_object_is_put_before_its_manifest_entry_is_appended() raises:
    var inner = SharedInMemoryConditionalStore()
    var store = OrderProbeStore(inner.clone())
    var w = TelemetryLogSegmentWriter[OrderProbeStore](
        store.clone(), String("writer-9")
    )
    var msgs = List[String]()
    var ts = List[Int64]()
    msgs.append(String("ordering-line"))
    ts.append(_DAY_T0 + Int64(42))
    var entries = w.publish_batches(
        _one_batch(_log_batch(msgs^, ts^))
    )
    assert_equal(len(entries), 1, "9: one object published")

    # NON-VACUITY: the probe must have SEEN a manifest chunk write at all. A
    # probe that never fired would satisfy the ordering assertion below for
    # free — which is the exact shape of the assertion this case replaces.
    assert_true(
        _marked(inner, _PROBE_OK) or _marked(inner, _PROBE_VIOLATION),
        "9: NON-VACUITY — the probe observed no manifest chunk write at all,"
        " so the ordering assertion below would be vacuous. Either the append"
        " stopped going through the store or the key shape changed",
    )
    assert_false(
        _marked(inner, _PROBE_VIOLATION),
        "9: ORDER IS LOAD-BEARING — a manifest chunk was appended while its"
        " `.parquet` object did NOT yet exist. That entry names an object a"
        " reader cannot distinguish from a transient 404, so the crash window"
        " loses DATA instead of losing BYTES. The PUT must precede the append",
    )
    assert_true(
        _marked(inner, _PROBE_OK),
        "9: ...and the positive half: the append saw its object present",
    )
    _ = w^
    _ = store^
    _ = inner^


# =============================================================================
# CASE 10 — POSITIVE CONTROL FOR THE INSTRUMENT. The probe DOES fire on the
# inverted ordering, so CASE 9's silence is evidence rather than inertia.
# =============================================================================


def test_10_the_ordering_probe_fires_on_an_entry_naming_an_absent_object() raises:
    var inner = SharedInMemoryConditionalStore()
    var store = OrderProbeStore(inner.clone())
    # Hand-built inverted ordering: append an entry naming an object NOTHING
    # ever PUT. No writer involved — this measures the PROBE, not the writer.
    var m = open_partition_manifest[OrderProbeStore](
        store, TELEMETRY_ROOT, TELEMETRY_DATASET_LOGS, String("20261001"),
        String("writer-10"),
    )
    var u = InlineArray[UInt8, TELEMETRY_UUID_BYTES](fill=UInt8(0))
    u[0] = UInt8(10)
    var e = make_log_segment_entry(
        u^,
        String("telemetry/logs/20261001/data/0000000000-never-put.parquet"),
        _DAY_T0, _DAY_T0 + Int64(1), Int64(1), Int64(1), False,
    )
    _ = m.publish(e^)
    assert_true(
        _marked(inner, _PROBE_VIOLATION),
        "10: POSITIVE CONTROL — the probe MUST report a violation when a"
        " manifest entry is appended for an object that was never PUT. If it"
        " does not, CASE 9 is inert and proves nothing",
    )
    assert_false(
        _marked(inner, _PROBE_OK),
        "10: ...and must NOT also report OK — a probe that marks both is a"
        " probe whose verdict carries no information",
    )
    _ = m^
    _ = store^
    _ = inner^


# =============================================================================
# CASE 11 — the ROW-GROUP knob is THREADED to the encoder.
#
# WHAT THIS DOES AND DOES NOT CLAIM. It pins that
# `TELEMETRY_LOG_ROWS_PER_ROW_GROUP` (and the ctor parameter it defaults) reaches
# `write_record_batches_to_parquet_bytes` — so a writer that hardcoded a
# row-group size, or dropped the argument, goes RED. It does NOT claim 65,536 is
# the right NUMBER: nothing measures that, and the constant's own docstring now
# says so rather than repeating the pruning rationale that the Parquet writer's
# temporal-arm caveat (b) contradicts.
# =============================================================================


def test_11_the_row_group_knob_is_threaded_to_the_encoder() raises:
    var store = SharedInMemoryConditionalStore()

    def _six() raises -> Slab[RecordBatch]:
        var msgs = List[String]()
        var ts = List[Int64]()
        for i in range(6):
            msgs.append(String("rg-line-") + String(i))
            ts.append(_DAY_T0 + Int64(i) * Int64(1_000_000))
        return _one_batch(_log_batch(msgs^, ts^))

    var w_small = TelemetryLogSegmentWriter[SharedInMemoryConditionalStore](
        store.clone(), String("writer-11a"), TELEMETRY_ROOT,
        TELEMETRY_DEFAULT_CODEC, 2,
    )
    var w_default = TelemetryLogSegmentWriter[SharedInMemoryConditionalStore](
        store.clone(), String("writer-11b"),
    )
    var small = w_small.publish_batches(_six())
    var default = w_default.publish_batches(_six())
    assert_equal(len(small), 1, "11: one object from the small-group writer")
    assert_equal(len(default), 1, "11: one object from the default writer")

    # CORRECTNESS FIRST: a row-group split must not change what the file holds.
    var rb_small = _readback(store, small[0].object_key)
    var rb_default = _readback(store, default[0].object_key)
    assert_equal(rb_small.num_rows(), 6, "11: the 3-row-group file holds 6 rows")
    assert_equal(rb_default.num_rows(), 6, "11: so does the 1-row-group file")
    var m_small = _msg_col(rb_small)
    var m_default = _msg_col(rb_default)
    for i in range(6):
        assert_equal(
            m_small[i],
            m_default[i],
            "11: ...and row " + String(i) + " is the SAME line in both, by its"
            " own text — a row-group split must be invisible to the reader",
        )

    # THE THREADING. Six rows at 2 per group is THREE row groups: three times
    # the per-column chunk metadata and three sets of page headers, so the file
    # is strictly larger than the same six rows in one group. If the encoder
    # received a hardcoded size instead of this writer's, the two objects would
    # be byte-for-byte the same size.
    print(
        "    [measured] rows_per_row_group=2 ->", small[0].byte_size,
        "bytes; default(", TELEMETRY_LOG_ROWS_PER_ROW_GROUP, ") ->",
        default[0].byte_size, "bytes",
    )
    assert_true(
        small[0].byte_size > default[0].byte_size,
        "11: the row-group knob must REACH the encoder. Six rows at 2 per"
        " group is three row groups and must cost more footer + page-header"
        " bytes than one group. Equal sizes mean the argument is being"
        " dropped and the knob is decorative. small="
        + String(small[0].byte_size) + " default=" + String(default[0].byte_size),
    )
    _ = w_small^
    _ = w_default^
    _ = store^


# =============================================================================
# CASE 12 — TWO WRITER LIFETIMES DO NOT SHARE A SEGMENT-UUID NAMESPACE.
#
# THE SHAPE THIS PREVENTS IS A PROCESS RESTART. `_next_uuid`'s counter starts at
# 0 in every process, so `(worker_disc, counter)` alone re-mints byte-identical
# uuids after a restart with the same `writer_id`, as happens when `writer_id`
# is derived from a stable node id. `merge_input_uuids` / `uuid_in_flat` key on
# this uuid, so a collision makes the dup-window skip drop the WRONG live
# segment.
#
# The two writers below differ in EXACTLY ONE FIELD — the nonce — and CASE 13 is
# the negative control that shows it is the field doing the work.
# =============================================================================


def _uuid_hex(u: InlineArray[UInt8, TELEMETRY_UUID_BYTES]) -> String:
    var hexd = "0123456789abcdef"
    var hb = hexd.as_bytes()
    var out = String("")
    for i in range(TELEMETRY_UUID_BYTES):
        out += chr(Int(hb[(Int(u[i]) >> 4) & 0xF]))
        out += chr(Int(hb[Int(u[i]) & 0xF]))
    return out^


def _one_line_publish(
    store: SharedInMemoryConditionalStore, writer_id: String, nonce: Int64
) raises -> TelemetrySegmentEntry:
    var w = TelemetryLogSegmentWriter[SharedInMemoryConditionalStore](
        store.clone(), writer_id.copy(), TELEMETRY_ROOT,
        TELEMETRY_DEFAULT_CODEC, TELEMETRY_LOG_ROWS_PER_ROW_GROUP,
        RetryPolicy.default(), UInt8(0), nonce,
    )
    var msgs = List[String]()
    var ts = List[Int64]()
    msgs.append(String("restart-line"))
    ts.append(_DAY_T0 + Int64(7))
    var entries = w.publish_batches(
        _one_batch(_log_batch(msgs^, ts^))
    )
    var e = entries[0].copy()
    _ = w^
    return e^


def test_12_a_recreated_writer_does_not_remint_the_same_segment_uuid() raises:
    var store = SharedInMemoryConditionalStore()
    # SAME writer_id, SAME worker_disc, SAME row content, SAME timestamp — the
    # restart shape. Only the construction nonce differs.
    var first = _one_line_publish(store, String("restarted"), Int64(1_000))
    var second = _one_line_publish(store, String("restarted"), Int64(2_000))
    assert_true(
        _uuid_hex(first.segment_uuid) != _uuid_hex(second.segment_uuid),
        "12: a writer re-created with the SAME writer_id and worker_disc must"
        " NOT re-mint the same segment uuid. The dup-window skip keys on this"
        " uuid, so a collision drops the wrong live segment's rows from every"
        " read. Got the same uuid twice: " + _uuid_hex(first.segment_uuid),
    )
    assert_true(
        first.object_key != second.object_key,
        "12: ...and therefore the object keys differ too. Identical uuids AND"
        " identical timestamps produce the same key, which is the second"
        " process OVERWRITING the first's data object",
    )
    _ = store^


def test_13_the_nonce_is_the_field_that_separates_them() raises:
    """NEGATIVE CONTROL for CASE 12. With the nonce held EQUAL, the two writers
    collide exactly as they did before the fix — which is what proves CASE 12
    measures the nonce and not some incidental difference between two
    constructions."""
    var store = SharedInMemoryConditionalStore()
    var first = _one_line_publish(store, String("collide"), Int64(4_242))
    var second = _one_line_publish(store, String("collide"), Int64(4_242))
    assert_equal(
        _uuid_hex(first.segment_uuid),
        _uuid_hex(second.segment_uuid),
        "13: with the SAME nonce the two writers MUST collide. If they do not,"
        " something other than the nonce is separating them and CASE 12 is not"
        " measuring what it claims",
    )
    _ = store^


def main() raises:
    test_01_marquee_the_base_artifact_is_time_sorted_parquet()
    test_02_a_flush_across_midnight_becomes_two_partitioned_objects()
    test_03_the_segment_is_discoverable_by_manifest_replay()
    test_04_the_text_split_is_a_sidecar_beside_the_base()
    test_05_a_sidecar_is_refused_when_the_flush_straddles_midnight()
    test_06_a_batch_without_a_timestamp_column_is_refused()
    test_07_an_empty_flush_publishes_nothing()
    test_08_both_codecs_round_trip()
    test_09_the_object_is_put_before_its_manifest_entry_is_appended()
    test_10_the_ordering_probe_fires_on_an_entry_naming_an_absent_object()
    test_11_the_row_group_knob_is_threaded_to_the_encoder()
    test_12_a_recreated_writer_does_not_remint_the_same_segment_uuid()
    test_13_the_nonce_is_the_field_that_separates_them()
    print("PASS komira_telemetry_store.test_telemetry_log_segment_writer (the")
    print("     base artifact is TIME-PARTITIONED, TIME-SORTED Parquet — sort")
    print("     order read back OUT OF THE PUBLISHED BYTES — and the text")
    print("     split is a sidecar at a DERIVED key that a time-range read")
    print("     never opens)")
