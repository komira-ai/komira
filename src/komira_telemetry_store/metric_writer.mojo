# =============================================================================
# komira_telemetry_store.metric_writer: THE BASE AT-REST ARTIFACT FOR METRICS:
#   TIME-PARTITIONED PARQUET, SORTED `(series_id, ts)`.
# =============================================================================
#
# -- THE ONE SENTENCE ---------------------------------------------------------
# This is `log_writer.mojo` with a DIFFERENT SORT KEY and a SECOND PRUNING AXIS,
# riding the identical substrate: the same key layout (`keys.mojo`), the same
# CAS sub-lineage manifest (`manifest.mojo`), the same body type
# (`TelemetrySegmentEntry`), the same PUT-then-append ordering. "ONE container,
# TWO schemas" is not a slogan here; it is why this file is short.
#
# -- WHY THE SORT KEY IS `(series_id, ts)` AND NOT `(ts)` ---------------------
# It is the entire reason `metrics` is a separate dataset rather than a second
# schema in the log one. The dominant metric read is a DASHBOARD: N panels
# re-running "last 30 min of ONE series" on a timer, forever. Sorted by series
# first, that is ONE CONTIGUOUS PAGE RANGE per series. Sorted by time first, the
# same read touches every page.
#
# The cost is stated rather than hidden: with `ts` secondary, a row group's `ts`
# min/max spans the whole file, so an all-series-recent read prunes NOTHING
# inside a file. That is resolved structurally: a file's total time span is
# bounded by the flush cadence (minutes), so "recent" prunes at the FILE level
# on the manifest entry, before any row group is considered. THAT RESOLUTION
# HOLDS ONLY WHILE FILES STAY TIME-NARROW, which is why compaction may never
# merge across days and why `publish_batches` splits rows by UTC day BEFORE
# encoding: no object this writer produces can straddle a partition boundary.
#
# -- WHAT THE ROW-GROUP KNOB BUYS ---------------------------------------------
# Small row groups (~64 K rows) because a row group is the pruning unit. The
# Parquet writer emits per-chunk min/max for the DELTA_BINARY_PACKED `ts`
# column, so the knob does buy pruning on `ts`, on files written from now on (a
# segment already at rest keeps its old footer). The value is still pinned by
# nothing: "it prunes" is not evidence that 64 K is the right group size. What
# the knob buys independently of any of this: the row group is the READ unit,
# so it bounds the decode working set. `log_writer.mojo` says the same about its
# own knob.
#
# -- WHAT THIS WRITER DELIBERATELY DOES NOT DO --------------------------------
# 1. NO TEXT SIDECAR, EVER. A metric point has no message to index.
#    `make_metric_segment_entry` does not even accept the flag.
# 2. NO SERIES SIDE TABLE. A per-partition `series_id -> (attr_key, attr_value)`
#    table would pair with the fact table. It is NOT WRITTEN HERE: building it
#    needs the attribute STRINGS, and a producer that hands over points carrying
#    only an interned attribute-set id gives the writer nothing to resolve it
#    with.
# 3. NO BUCKET, NO RETENTION, NO LIFECYCLE POLICY. The `Storage` is handed in by
#    the caller. WHERE the metrics dataset lands, and how long it lives, is the
#    caller's decision. The key layout is already prefix-separated by dataset
#    (`<root>/logs/...` vs `<root>/metrics/...`), so a lifecycle rule scoped to a
#    prefix can give the two datasets different expiries in one bucket. NOTHING
#    IN THIS FILE DEPENDS ON THE ANSWER.
# 4. NO FLUSH CADENCE. This writer publishes when it is called. The cadence
#    belongs to the caller, which decides when a buffer is due.
#
# NO POINTER CROSSES A MODULE BOUNDARY: the surface is RecordBatch / Slab /
# String / Int64 / owned entries.
# =============================================================================

from komira_collections.slab import Slab

from komira_arrow.arrow_types import ArrowType
from komira_arrow.concat import concat_record_batches_nway
from komira_arrow.record_batch import RecordBatch
from komira_column_kernels.compiler_helpers import gather_batch

from komira_clock.clock import now_unix_ms

from komira_objectstore.cas_manifest import RetryPolicy
from komira_objectstore.path import Path
from komira_objectstore.store import CloneableConditionalWriteStore

from komira_parquet_writer.record_batch_writer import (
    write_record_batches_to_parquet_bytes,
)
from komira_parquet_api.types import CompressionCodec

from komira_telemetry_store.keys import (
    NS_PER_MS,
    TELEMETRY_DATASET_METRICS,
    TELEMETRY_ROOT,
    day_index_from_ns,
    day_string_from_day_index,
    telemetry_data_key,
)
from komira_telemetry_store.log_writer import TELEMETRY_DEFAULT_CODEC
from komira_telemetry_store.manifest import (
    TelemetrySegmentManifest,
    open_partition_manifest,
)
from komira_telemetry_store.segment_entry import (
    TELEMETRY_UUID_BYTES,
    TelemetrySegmentEntry,
    make_metric_segment_entry,
)


# =============================================================================
# §0 — the COLUMN CONTRACT, stated HERE.
# =============================================================================
#
# THESE NAMES ARE DECLARED IN THE WRITER AND IMPORTED BY A PRODUCER, NOT
# SPELLED TWICE: a second statement of a contract agrees with the first until
# one of them is edited.

comptime METRIC_TIME_COLUMN: String = "ts"
"""The metrics fact table's time column. Epoch NANOSECONDS. Read for the day
partition AND for the manifest entry's `[min_ts,max_ts]`."""

comptime METRIC_SERIES_COLUMN: String = "series_id"
"""THE PRIMARY SORT KEY and the second pruning axis. INT64."""

comptime TELEMETRY_METRIC_ROWS_PER_ROW_GROUP: Int = 65_536
"""Rows per Parquet row group for the `metrics` dataset (small, targeting
~64 K rows). See the header for what this does and does not buy.

THE VALUE IS PINNED BY NOTHING and none is added. A test proves the knob is
THREADED to the encoder (a hardcoded row-group size is a real defect); no test
measures 65,536 against another number, because pinning an unmeasured constant
turns a guess into a requirement."""


# =============================================================================
# §1 — the TWO-KEY stable sort.
# =============================================================================


def _stable_sort_indices_2key(
    primary: List[Int64], secondary: List[Int64], var idx: List[Int]
) -> List[Int]:
    """Bottom-up merge sort of `idx` by `(primary[i], secondary[i])`. STABLE,
    O(n log n).

    THIS IS NOT `log_writer._stable_sort_indices` WITH AN EXTRA ARGUMENT, AND
    IT DELIBERATELY DOES NOT REPLACE IT. The comparator arity differs, and
    widening the log sort to save thirty lines here is the wrong trade. The
    duplication is named rather than hidden.

    STABILITY IS LOAD-BEARING, not decoration: two points of the SAME series at
    the SAME nanosecond (a sweep that emits a counter and its exemplar together)
    must keep emission order, or a reader replaying a series sees them shuffled
    between one flush and the next for no reason it can observe."""
    var n = len(idx)
    if n < 2:
        return idx^
    var buf = List[Int](capacity=n)
    buf.resize(n, 0)
    var width = 1
    while width < n:
        var lo = 0
        while lo < n:
            var mid = lo + width
            if mid > n:
                mid = n
            var hi = lo + 2 * width
            if hi > n:
                hi = n
            var a = lo
            var b = mid
            var w = lo
            while a < mid and b < hi:
                # Take from the LEFT run unless the right is strictly smaller —
                # `<=` on the composite key, which is what keeps it STABLE.
                var ia = idx[a]
                var ib = idx[b]
                var take_left: Bool
                if primary[ia] != primary[ib]:
                    take_left = primary[ia] < primary[ib]
                else:
                    take_left = secondary[ia] <= secondary[ib]
                if take_left:
                    buf[w] = ia
                    a += 1
                else:
                    buf[w] = ib
                    b += 1
                w += 1
            while a < mid:
                buf[w] = idx[a]
                a += 1
                w += 1
            while b < hi:
                buf[w] = idx[b]
                b += 1
                w += 1
            lo += 2 * width
        for i in range(n):
            idx[i] = buf[i]
        width *= 2
    return idx^


def _i64_column_index(
    batch: RecordBatch, name: String, what: String
) raises -> Int:
    """Position of an i64-storage column, BY NAME.

    BY NAME rather than by position, so a column reorder in the producer is a
    LOUD failure here instead of a dataset silently partitioned on the wrong
    number. `TIMESTAMP_NS` and `INT64` are both accepted because both are i64
    storage and the schema may legitimately tag the time column either way."""
    var ncol = batch.num_columns()
    for c in range(ncol):
        if batch.schema.field_name(c) == name:
            var at = batch.schema.field_arrow_type(c)
            if at != ArrowType.TIMESTAMP_NS and at != ArrowType.INT64:
                raise Error(
                    "telemetry metric writer: column '"
                    + name
                    + "' is not TIMESTAMP_NS/INT64 — "
                    + what
                )
            return c
    raise Error(
        "telemetry metric writer: no '"
        + name
        + "' column in the batch schema — this writer partitions by UTC day and"
        " sorts by (series_id, ts) and can do neither without it"
    )


def _read_i64_column(batch: RecordBatch, col: Int) raises -> List[Int64]:
    var n = batch.num_rows()
    var arr = batch.column_at(col).as_primitive[DType.int64]()
    var out = List[Int64](capacity=n)
    for r in range(n):
        out.append(Int64(arr.get(r)))
    return out^


# =============================================================================
# §2 — the writer.
# =============================================================================


struct TelemetryMetricSegmentWriter[Storage: CloneableConditionalWriteStore](
    Movable, Deinitable
):
    """Publishes the BASE at-rest artifact for the `metrics` dataset: one
    `(series_id, ts)`-sorted Parquet object per UTC day touched, plus one
    CAS-manifest entry per object carrying BOTH its `[min_ts,max_ts]` and its
    `[min_series_id,max_series_id]`.

    ONE INSTANCE PER WRITER SHARD. `writer_id` selects the sub-lineage
    `<root>/metrics/<YYYYMMDD>/_lineage/<writer_id>`, so concurrent writers never
    CAS-contend on one `_HEAD`.

    A METRICS WRITER AND A LOG WRITER SHARING ONE `writer_id` DO NOT COLLIDE:
    the DATASET segment sits above the lineage in the key, so their manifests are
    different prefixes. Sharing the id is in fact desirable — it is what lets an
    operator who found one shard's logs find the same shard's metrics."""

    var _store: Self.Storage
    var _root: String
    var _writer_id: String
    var _codec: CompressionCodec
    var _rows_per_row_group: Int
    var _retry: RetryPolicy
    var _seq: Int64
    var _worker_disc: UInt8
    # THE PER-CONSTRUCTION NONCE: the same mechanism, and the same reason, as
    # `log_writer._next_uuid`. The counter starts at 0 in EVERY process, so
    # `(worker_disc, counter)` alone re-mints byte-identical uuids after a
    # restart with the same `writer_id`.
    # `merge_input_uuids` (the dup-window skip) keys on this uuid, so a
    # collision makes a replay skip the WRONG live segment and silently drop its
    # rows. On a metrics dashboard a dropped segment is a hole in a line chart
    # that looks like an outage.
    var _nonce: Int64
    var _segments_published: Int64
    var _rows_published: Int64
    # THE ONE-DAY MANIFEST CACHE. Same rationale as the log writer's: a fresh
    # `CasManifestStore` per flush starts with a COLD head cache and pays a
    # `_HEAD` GET per append to re-establish a tail this writer already knows.
    # Object-store operations per flush are the cost model.
    var _cached_day: String
    var _cached_manifest: Optional[TelemetrySegmentManifest[Self.Storage]]

    def __init__(
        out self,
        var store: Self.Storage,
        var writer_id: String,
        var root: String = TELEMETRY_ROOT,
        codec: CompressionCodec = TELEMETRY_DEFAULT_CODEC,
        rows_per_row_group: Int = TELEMETRY_METRIC_ROWS_PER_ROW_GROUP,
        retry: RetryPolicy = RetryPolicy.default(),
        worker_disc: UInt8 = UInt8(0),
        nonce: Int64 = Int64(-1),
    ) raises:
        """`store` is HANDED IN: this writer reads no environment variable and
        resolves no bucket. The configuration is the `Storage` the caller hands
        in, and nothing else, so the bucket and retention decision is a
        construction-site change rather than a code change here.

        `codec` defaults to `TELEMETRY_DEFAULT_CODEC` (SNAPPY).

        `nonce` seeds the segment-uuid namespace and DEFAULTS TO THE WALL CLOCK
        (`nonce < 0` reads `now_unix_ms()`). It is a parameter only so a test can
        make two writers collide ON PURPOSE; a production caller must never pass
        one."""
        if writer_id.byte_length() == 0:
            raise Error(
                "telemetry metric writer: empty writer_id — the sub-lineage"
                " segment would collapse and two writers would CAS-contend on"
                " one _HEAD"
            )
        self._store = store^
        self._root = root^
        self._writer_id = writer_id^
        self._codec = codec
        self._rows_per_row_group = rows_per_row_group
        self._retry = retry
        self._seq = Int64(0)
        self._worker_disc = worker_disc
        self._nonce = nonce if nonce >= Int64(0) else now_unix_ms()
        self._segments_published = Int64(0)
        self._rows_published = Int64(0)
        self._cached_day = String("")
        self._cached_manifest = None

    @always_inline
    def segments_published(self) -> Int64:
        return self._segments_published

    @always_inline
    def rows_published(self) -> Int64:
        return self._rows_published

    def _next_uuid(mut self) -> InlineArray[UInt8, TELEMETRY_UUID_BYTES]:
        """Mint a per-writer segment uuid: worker discriminant, a 7-byte
        per-construction NONCE, and an 8-byte monotone counter. Identical
        construction to `log_writer._next_uuid`; see that docstring for why the
        nonce is not decoration and why a CSPRNG one is deliberately not taken.

        THE TWO WRITERS' UUID SPACES ARE NOT DISJOINT BY CONSTRUCTION, and
        they do not need to be: `merge_input_uuids` is only ever consulted
        against entries replayed from ONE `(dataset, day, writer_id)` lineage,
        and the dataset segment separates those before a uuid is ever compared.
        """
        self._seq += Int64(1)
        var u = InlineArray[UInt8, TELEMETRY_UUID_BYTES](fill=UInt8(0))
        u[0] = self._worker_disc
        var nz = UInt64(self._nonce)
        for i in range(7):
            u[1 + i] = UInt8((nz >> UInt64(8 * i)) & UInt64(0xFF))
        var s = UInt64(self._seq)
        for i in range(8):
            u[8 + i] = UInt8((s >> UInt64(8 * i)) & UInt64(0xFF))
        return u^

    def publish_batches(
        mut self, var batches: Slab[RecordBatch]
    ) raises -> List[TelemetrySegmentEntry]:
        """THE WRITE PATH. Consumes one flush's batches and publishes the
        `metrics` base artifact(s) for it.

          1. concat to one batch; read the `ts` and `series_id` columns;
          2. SPLIT ROWS BY UTC DAY — never one object across a partition
             boundary (see the header);
          3. per day: STABLE-SORT by `(series_id, ts)`, gather, encode Parquet
             with the day's rows only, PUT at the computed key;
          4. CAS-append the manifest entry carrying [min_ts,max_ts] AND
             [min_series_id,max_series_id].

        ORDER IS LOAD-BEARING: the object is PUT before its manifest entry is
        appended. The append is the linearization point that makes a segment
        readable, so a crash between them leaves a harmless orphan object; the
        reverse order would leave an entry naming an object that does not exist,
        which a reader cannot distinguish from a transient 404.

        EVERY BOUND IN THE ENTRY IS COMPUTED BY AN INDEPENDENT SCAN OF THE
        ROWS THAT GO INTO THE OBJECT — never read off the sorted array's ends.
        Taking `[min_series_id,max_series_id]` from `sorted_idx[0]` /
        `sorted_idx[-1]` is shorter and is exactly the bug class that matters
        here: it couples the manifest's pruning range to the sort being correct,
        so a mis-sort publishes a catalog entry that DESCRIBES AN OBJECT IT DOES
        NOT MATCH — and a wrong catalog is invisible to every other check,
        because every other check reads the catalog. Computed independently, the
        range is true whatever the sort does, and the file-order assertion
        becomes the sole discriminator for the sort.

        Returns one entry per published object (one per day partition touched).
        AN EMPTY INPUT PUBLISHES NOTHING and returns an empty list — a 0-row
        segment's [min,max] is meaningless, and an empty object in the bucket
        would be a PUT charged for data that does not exist plus a manifest
        entry that prunes IN for every query."""
        var n_batches = len(batches)
        if n_batches == 0:
            _ = batches^
            return List[TelemetrySegmentEntry]()
        var one = concat_record_batches_nway(batches^)
        var nrows = one.num_rows()
        if nrows == 0:
            _ = one^
            return List[TelemetrySegmentEntry]()

        var tcol = _i64_column_index(
            one,
            METRIC_TIME_COLUMN,
            String(
                "the day partition and the manifest [min_ts,max_ts] both read"
                " it as epoch nanoseconds, so a different unit would file rows"
                " under the wrong day and prune them out of their own query"
            ),
        )
        var scol = _i64_column_index(
            one,
            METRIC_SERIES_COLUMN,
            String(
                "it is the PRIMARY sort key and the manifest's second pruning"
                " axis; a non-integer series id has no order and no bound"
            ),
        )
        var ts = _read_i64_column(one, tcol)
        var sid = _read_i64_column(one, scol)

        # ---- step 2: split row indices by UTC day, preserving arrival order --
        var row_day = List[Int64](capacity=nrows)
        var day_ids = List[Int64]()
        for r in range(nrows):
            var d = day_index_from_ns(ts[r])
            row_day.append(d)
            var seen = False
            for k in range(len(day_ids)):
                if day_ids[k] == d:
                    seen = True
                    break
            if not seen:
                day_ids.append(d)

        var out = List[TelemetrySegmentEntry]()
        for k in range(len(day_ids)):
            var order = List[Int]()
            for r in range(nrows):
                if row_day[r] == day_ids[k]:
                    order.append(r)
            # ---- the INDEPENDENT bound scan. See the docstring. --------------
            var min_ts = ts[order[0]]
            var max_ts = ts[order[0]]
            var min_sid = sid[order[0]]
            var max_sid = sid[order[0]]
            for i in range(len(order)):
                var t = ts[order[i]]
                if t < min_ts:
                    min_ts = t
                if t > max_ts:
                    max_ts = t
                var s = sid[order[i]]
                if s < min_sid:
                    min_sid = s
                if s > max_sid:
                    max_sid = s
            var row_count = Int64(len(order))

            # ---- step 3: THE FILE'S SORT ORDER — `(series_id, ts)` -----------
            var sorted_idx = _stable_sort_indices_2key(sid, ts, order^)
            var part = gather_batch(one, sorted_idx)

            var slab = Slab[RecordBatch](capacity=1)
            slab.append(part^)
            var bytes = write_record_batches_to_parquet_bytes(
                slab^, self._codec, self._rows_per_row_group
            )
            var byte_size = Int64(len(bytes))

            var day = day_string_from_day_index(day_ids[k])
            var uuid = self._next_uuid()
            var key = telemetry_data_key(
                self._root,
                TELEMETRY_DATASET_METRICS,
                day,
                min_ts // NS_PER_MS,
                uuid,
            )
            # ---- the PUT, BEFORE the manifest append ------------------------
            _ = self._store.put(Path.parse(key), bytes^)

            var entry = make_metric_segment_entry(
                uuid^,
                key.copy(),
                min_ts,
                max_ts,
                min_sid,
                max_sid,
                row_count,
                byte_size,
            )
            if self._cached_day != day or not self._cached_manifest:
                self._cached_manifest = open_partition_manifest[Self.Storage](
                    self._store,
                    self._root,
                    TELEMETRY_DATASET_METRICS,
                    day,
                    self._writer_id,
                    self._retry,
                )
                self._cached_day = day.copy()
            _ = self._cached_manifest.value().publish(entry.copy())
            self._segments_published += Int64(1)
            self._rows_published += row_count
            out.append(entry^)
        _ = one^
        return out^
