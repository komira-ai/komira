# =============================================================================
# komira_telemetry_store.log_writer: THE BASE AT-REST ARTIFACT FOR LOGS:
#   TIME-PARTITIONED, TIME-SORTED PARQUET.
# =============================================================================
#
# Time-partitioned Parquet is the base at-rest artifact for logs and metrics; a
# text index may sit beside it as an optional sidecar.
#
# -- WHAT THIS FIXES, IN ONE SENTENCE -----------------------------------------
# If the base artifact were a text index with time as a field inside it, the
# manifest entry a reader replays would carry no time range, and "the last 200
# lines", the most common log query, would have to fetch EVERY LIVE OBJECT. This
# module puts time in the object key and in the file's sort order, and the
# manifest entry carries `[min_ts,max_ts]`, so a time-range read prunes before a
# single byte is fetched.
#
# -- THE BATCH SCHEMA ---------------------------------------------------------
# The writer takes batches of any schema that has a column named `timestamp`
# (TIMESTAMP_NS or INT64 epoch nanoseconds) and locates it BY NAME. It declares
# no schema of its own and carries every other column through unchanged, in the
# batch's own order. The emitting service is not part of the key; if rows must
# be filtered by service, it is a column of the batch.
#
# -- WHAT THIS MODULE DELIBERATELY DOES NOT DO --------------------------------
# IT DOES NOT CHOOSE THE FLUSH CADENCE. The caller decides when a batch is
# flushed; frequent flushes make many small objects, and the answer to the
# object count is a scheduled compaction job, not a longer buffer that can be
# lost. This format is built so that job is possible (`merge_ops`,
# `merge_input_uuids`, per-partition lineages, and a key layout a merge can
# rewrite within one day). The job itself is not here.
#
# -- COMPACTION MAY NEVER MERGE ACROSS DAY PARTITIONS -------------------------
# A cross-day merge produces one object whose [min_ts,max_ts] spans the
# retention window: an entry that prunes NOTHING and must be fetched by every
# query. `publish_batches` enforces the same invariant on the WRITE side: rows
# are SPLIT BY UTC DAY BEFORE ENCODING, so no object this writer produces can
# straddle a partition boundary and every entry's range lies inside its own
# partition. That invariant is what makes the day prefix a real index rather
# than a naming convention.
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
    TELEMETRY_DATASET_LOGS,
    TELEMETRY_ROOT,
    day_index_from_ns,
    day_string_from_day_index,
    telemetry_data_key,
    telemetry_text_sidecar_key,
)
from komira_telemetry_store.manifest import (
    TelemetrySegmentManifest,
    open_partition_manifest,
)
from komira_telemetry_store.segment_entry import (
    TELEMETRY_UUID_BYTES,
    TelemetrySegmentEntry,
    make_log_segment_entry,
)


comptime LOG_TIME_COLUMN: String = "timestamp"
"""The time column NAME. Located BY NAME so a column reorder is a loud failure
rather than a silently mis-partitioned dataset."""

comptime TELEMETRY_DEFAULT_CODEC: CompressionCodec = CompressionCodec.SNAPPY
"""The default page codec for the `logs` dataset. It is a constructor argument,
so ZSTD (smaller files, more CPU) is one argument away, and
`test_telemetry_log_segment_writer` exercises BOTH arms. The default is a
choice, not a measured optimum."""

comptime TELEMETRY_LOG_ROWS_PER_ROW_GROUP: Int = 65_536
"""Rows per Parquet row group for the `logs` dataset. Half the writer's 122,880
default.

The row group is the READ unit, so it bounds the decode working set and the size
of a re-read after a transient failure. A smaller group also prunes harder when
the `timestamp` column carries per-row-group min/max statistics, which the
Parquet writer emits for INT64 columns. It takes effect on NEWLY WRITTEN
segments only: a segment already at rest keeps the footer it was written with.

THE **VALUE** IS PINNED BY NOTHING. `test_telemetry_log_segment_writer` CASE 11
proves the knob is THREADED to the encoder (a hardcoded row-group size is a real
defect and goes red there), but no test or bench measures 65,536 against any
other number: pinning an unmeasured constant turns a guess into a requirement."""


# =============================================================================
# §1 — a stable sort of row indices by an i64 key.
# =============================================================================


def _stable_sort_indices(keys: List[Int64], var idx: List[Int]) -> List[Int]:
    """Bottom-up merge sort of `idx` by `keys[idx[i]]`. STABLE, O(n log n).

    Stability matters and is not decoration: two log lines emitted in the same
    nanosecond must keep their EMISSION order in the file, or a "last 200 lines"
    read returns them shuffled. An insertion sort would also be stable but is
    O(n^2) over a flush buffer that can hold a whole request's logging."""
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
                # `<=` keeps equal keys in left-run order -> STABLE.
                if keys[idx[a]] <= keys[idx[b]]:
                    buf[w] = idx[a]
                    a += 1
                else:
                    buf[w] = idx[b]
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


def _time_column_index(batch: RecordBatch) raises -> Int:
    """Position of the frozen schema's `timestamp` column, BY NAME."""
    var ncol = batch.num_columns()
    for c in range(ncol):
        if batch.schema.field_name(c) == LOG_TIME_COLUMN:
            var at = batch.schema.field_arrow_type(c)
            if at != ArrowType.TIMESTAMP_NS and at != ArrowType.INT64:
                raise Error(
                    "telemetry log writer: column '"
                    + LOG_TIME_COLUMN
                    + "' is not TIMESTAMP_NS/INT64 — the partition key and the"
                    " manifest [min_ts,max_ts] both read it as epoch"
                    " nanoseconds, so a different unit would file rows under"
                    " the wrong day and prune them out of their own query"
                )
            return c
    raise Error(
        "telemetry log writer: no '"
        + LOG_TIME_COLUMN
        + "' column in the batch schema — this writer partitions and sorts by"
        " time and cannot do either without it"
    )


# =============================================================================
# §2 — the writer.
# =============================================================================


struct TelemetryLogSegmentWriter[Storage: CloneableConditionalWriteStore](
    Movable, Deinitable
):
    """Publishes the BASE at-rest artifact for the `logs` dataset: one
    time-sorted Parquet object per UTC day touched, plus one CAS-manifest entry
    per object carrying its `[min_ts,max_ts]`.

    ONE INSTANCE PER WRITER SHARD. `writer_id` selects the sub-lineage
    `<root>/logs/<YYYYMMDD>/_lineage/<writer_id>`, so concurrent writers never
    CAS-contend on one `_HEAD`."""

    var _store: Self.Storage
    var _root: String
    var _writer_id: String
    var _codec: CompressionCodec
    var _rows_per_row_group: Int
    var _retry: RetryPolicy
    var _seq: Int64
    var _worker_disc: UInt8
    # THE PER-CONSTRUCTION NONCE. See `_next_uuid`: without it a writer
    # re-created with the same `writer_id` and `worker_disc` (a process restart)
    # re-mints byte-identical segment uuids inside the SAME
    # sub-lineage.
    var _nonce: Int64
    var _segments_published: Int64
    var _rows_published: Int64
    var _sidecars_published: Int64
    # THE ONE-DAY MANIFEST CACHE, AND IT IS NOT A MICRO-OPTIMISATION.
    #
    # A fresh `CasManifestStore` per flush starts with a COLD head cache, so
    # every append pays a `_HEAD` GET to re-establish a tail this writer already
    # knows. Object-store operations per flush are the cost model, so paying two
    # avoidable ones on every flush is the wrong default.
    #
    # Holding the handle also puts the writer on the SAME warm-append path every
    # other CasManifestStore writer uses, which means it inherits the DEFERRED
    # durable `_HEAD` advance (up to 64 warm appends) and therefore depends on
    # the replay's forward probe, exactly like a held-handle compactor would. A
    # per-flush handle would have hidden that dependency behind an eager `_HEAD`
    # advance and left the probe untested by the writer.
    #
    # ONE slot, keyed by day string: a flush touches one partition, or two
    # across midnight, and the second is a new day the next flush will keep.
    var _cached_day: String
    var _cached_manifest: Optional[TelemetrySegmentManifest[Self.Storage]]

    def __init__(
        out self,
        var store: Self.Storage,
        var writer_id: String,
        var root: String = TELEMETRY_ROOT,
        codec: CompressionCodec = TELEMETRY_DEFAULT_CODEC,
        rows_per_row_group: Int = TELEMETRY_LOG_ROWS_PER_ROW_GROUP,
        retry: RetryPolicy = RetryPolicy.default(),
        worker_disc: UInt8 = UInt8(0),
        nonce: Int64 = Int64(-1),
    ) raises:
        """`codec` is a PARAMETER, not a constant: it is the one knob whose right
        answer depends on the dataset.

        `nonce` seeds the segment-uuid namespace and DEFAULTS TO THE WALL CLOCK
        (`nonce < 0` reads `now_unix_ms()`). It is a parameter only so a test can
        make two writers collide ON PURPOSE and prove the nonce is what separates
        them — a production caller must never pass one. See `_next_uuid`."""
        if writer_id.byte_length() == 0:
            raise Error(
                "telemetry log writer: empty writer_id — the sub-lineage"
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
        self._sidecars_published = Int64(0)
        self._cached_day = String("")
        self._cached_manifest = None

    @always_inline
    def segments_published(self) -> Int64:
        return self._segments_published

    @always_inline
    def rows_published(self) -> Int64:
        return self._rows_published

    @always_inline
    def sidecars_published(self) -> Int64:
        return self._sidecars_published

    def _next_uuid(mut self) -> InlineArray[UInt8, TELEMETRY_UUID_BYTES]:
        """Mint a per-writer segment uuid: worker discriminant, a 7-byte
        per-construction NONCE, and an 8-byte monotone counter.

        THE NONCE IS NOT DECORATION. The counter starts at 0 in EVERY process,
        so `(worker_disc, counter)` alone re-mints byte-identical uuids after a
        restart with the same `writer_id`, the usual shape when `writer_id` is
        derived from a stable node id. `merge_input_uuids` / `uuid_in_flat` (the
        dup-window skip) key on this uuid, so a collision makes the replay skip
        the WRONG live segment and silently drop its rows from every read. The
        counter is kept because it is what makes uuids ORDER within one writer's
        run; the nonce is what makes two runs disjoint.

        THE BOUND IS MILLISECOND GRANULARITY, STATED RATHER THAN OVERSOLD. The
        nonce is `now_unix_ms()` at construction, so it separates any two writer
        lifetimes more than 1 ms apart, which covers every restart. Two writers
        constructed in the SAME millisecond with the SAME `writer_id` AND the
        same `worker_disc` still collide; inside one process `worker_disc`
        separates them, and across processes that is two instances sharing a
        node id, which already contend on one `_HEAD`. A CSPRNG nonce would
        close the residue; it is not taken here because it would put a
        cryptographic-library dependency on the write path."""
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
        mut self,
        var batches: Slab[RecordBatch],
        var text_sidecar: Optional[List[UInt8]] = None,
    ) raises -> List[TelemetrySegmentEntry]:
        """THE WRITE PATH. Consumes one flush's batches and publishes the base
        artifact(s) for it.

          1. concat to one batch, read the `timestamp` column;
          2. SPLIT ROWS BY UTC DAY — never one object across a partition
             boundary (see the header);
          3. per day: STABLE-SORT by ts, gather, encode Parquet with the day's
             rows only, PUT at the computed key;
          4. optionally PUT the text sidecar at the DERIVED key;
          5. CAS-append the manifest entry carrying [min_ts,max_ts].

        ORDER IS LOAD-BEARING: the object is PUT before its manifest entry is
        appended. The append is the linearization point that makes a segment
        readable, so a crash between them leaves a harmless orphan object; the
        reverse order would leave an entry naming an object that does not exist,
        which a reader cannot distinguish from a transient 404.

        Returns one entry per published object (one per day partition touched).
        An empty input publishes NOTHING and returns an empty list — a 0-row
        segment's [min,max] is meaningless."""
        var n_batches = len(batches)
        if n_batches == 0:
            _ = batches^
            _ = text_sidecar^
            return List[TelemetrySegmentEntry]()
        var one = concat_record_batches_nway(batches^)
        var nrows = one.num_rows()
        if nrows == 0:
            _ = one^
            _ = text_sidecar^
            return List[TelemetrySegmentEntry]()

        var tcol = _time_column_index(one)
        var ts = List[Int64](capacity=nrows)
        var arr = one.column_at(tcol).as_primitive[DType.int64]()
        for r in range(nrows):
            ts.append(Int64(arr.get(r)))

        # ---- step 2: split row indices by UTC day, preserving arrival order --
        # Two passes rather than a nested-list append: the day set is TINY (1,
        # or 2 across midnight — that is the whole point of a day partition), so
        # the second pass is O(rows x days) with days <= 2 in practice.
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

        # A SIDECAR NAMES ROW IDS INSIDE *ONE* OBJECT (one sidecar per data
        # object, same basename). A flush that straddles
        # midnight becomes two objects, and one sidecar cannot name rows in
        # both. Splitting the split index is not something this writer can do,
        # so it REFUSES rather than pairing a sidecar with the wrong object —
        # a sidecar naming row ids in an object that does not hold them is
        # worse than no sidecar at all.
        if text_sidecar and len(day_ids) > 1:
            raise Error(
                "telemetry log writer: a text sidecar was supplied for a flush"
                " spanning "
                + String(len(day_ids))
                + " day partitions. A sidecar names row ids inside ONE data"
                " object; pairing it with either half would name rows the"
                " object does not hold. Publish the sidecar per-partition or"
                " not at all"
            )

        var out = List[TelemetrySegmentEntry]()
        for k in range(len(day_ids)):
            var order = List[Int]()
            for r in range(nrows):
                if row_day[r] == day_ids[k]:
                    order.append(r)
            # ---- step 3: THE FILE'S SORT ORDER. logs sort on (ts) alone ------
            # [min_ts,max_ts] IS COMPUTED BY AN INDEPENDENT SCAN, NOT READ OFF
            # THE SORTED ARRAY'S ENDS. Taking it from `sorted_idx[0]` /
            # `sorted_idx[-1]` is one line shorter and couples the manifest's
            # pruning range to the sort being correct — so a mis-sort would
            # publish a WRONG range, and the test that should have caught the
            # mis-sort would instead trip an inverted-range guard somewhere else.
            # Independent, the range is right whatever the sort does, and the
            # file-order assertion is the sole discriminator for the sort.
            var min_ts = ts[order[0]]
            var max_ts = ts[order[0]]
            for i in range(len(order)):
                var v = ts[order[i]]
                if v < min_ts:
                    min_ts = v
                if v > max_ts:
                    max_ts = v
            var row_count = Int64(len(order))
            var sorted_idx = _stable_sort_indices(ts, order^)
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
                TELEMETRY_DATASET_LOGS,
                day,
                min_ts // NS_PER_MS,
                uuid,
            )
            # ---- the PUT, BEFORE the manifest append ------------------------
            _ = self._store.put(Path.parse(key), bytes^)

            var has_sidecar = False
            if text_sidecar:
                var side_key = telemetry_text_sidecar_key(key)
                var side_bytes = text_sidecar.take()
                _ = self._store.put(Path.parse(side_key), side_bytes^)
                has_sidecar = True
                self._sidecars_published += Int64(1)

            var entry = make_log_segment_entry(
                uuid^, key.copy(), min_ts, max_ts, row_count, byte_size,
                has_sidecar,
            )
            if self._cached_day != day or not self._cached_manifest:
                self._cached_manifest = open_partition_manifest[Self.Storage](
                    self._store,
                    self._root,
                    TELEMETRY_DATASET_LOGS,
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
        _ = text_sidecar^
        return out^
