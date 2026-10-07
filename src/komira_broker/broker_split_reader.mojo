# =============================================================================
# broker_split_reader — reads ONE partition of a `komira.broker.topic` scan.
# =============================================================================
#
# `BrokerScanRuntime.plan_splits` (`broker_scan_kind.mojo`) plans one split per
# partition the binding names: from the requested start offset (raised to the
# partition's `log_start`) to an exact stop, the last stable offset for
# `read_committed` and the high-watermark otherwise. `BrokerSplitReader` reads
# one such split. It owns its partition's `ConsumeCore` and its cursor, and is
# polled one segment frame at a time.
#
# ---------------------------------------------------------------------------
# THE POSITION
# ---------------------------------------------------------------------------
#
# A broker `SplitPosition` (version `BROKER_POSITION_VERSION`) is
#
#     [offset: i64 LE][n: u32 LE][n x chunk_seq: i64 LE]
#
# `offset` is the first offset of the partition not yet returned. The chunk
# list is the plan's VISIBILITY decision: the data chunks below the split's
# stop that a `read_committed` read skips (aborted, epoch-fenced, markers),
# decided ONCE against the transaction snapshot the plan pinned. It rides in
# every position of the split, so a reader opened later, or resumed from a
# checkpoint, skips exactly the chunks the plan skipped. Re-reading the
# transaction states instead would be wrong: a transactional id is reused, so
# a committed transaction's control object can read Ongoing again by then, and
# its chunks would vanish. A `read_uncommitted` split carries an empty list.
#
# ---------------------------------------------------------------------------
# WHAT A READER RE-CHECKS
# ---------------------------------------------------------------------------
#
# The window between planning and reading is not bounded by one call, so the
# reader trusts nothing the plan read about the live tier's extent:
#   * at open it reads `log_start`, then the live index, then LISTs the
#     compaction index (that order; see `refuse_compacted_tier`), and refuses
#     a range reaching the compacted (Parquet) tier
#     (`BROKER_SCAN_COMPACTED_TIER_UNREAD`) or a `log_start` that moved past
#     its cursor (`BROKER_SCAN_LOG_START_MOVED`);
#   * before every segment it reads `log_start` again and refuses the same
#     way. The compaction worker commits its index entry BEFORE it advances
#     `log_start`, and reaps a live segment only after that, so a `log_start`
#     at or below the cursor means every live segment from the cursor on is
#     still there.
# It refuses rather than clamps: a clamp would return the live suffix with no
# error and report the missing prefix as retention.
#
# ---------------------------------------------------------------------------
# THE PARTITION BYTE BUDGET (Kafka's partition_max_bytes, KIP-74)
# ---------------------------------------------------------------------------
#
# The first segment of the split that returns a row is returned whole even
# over `partition_max_bytes`; after it, a segment that would take the split
# past the budget is not returned, and the reader answers END with its
# position at that segment. A byte-shaped stop cannot be written as a position
# before reading, so the reader enforces it; but unlike a time-shaped stop it
# is not where the split ends, only where this read of it is cut. END short of
# the split's stop is a CUT (`SPLIT_POLL_END`): `drain_scan` reports the split
# cut, the rest from its position on is still there, and a split that reads
# after it is not opened. The exemption is the SPLIT's: a split cannot see
# whether another split of the same read returned something first.
#
# The scan-wide byte budget is not the reader's: it is `drain_scan`'s
# `max_bytes`, checked between polls. Each poll's `source_bytes` is the
# segment's Arrow IPC stream length, on the poll that returns its first frame.
#
# ---------------------------------------------------------------------------
# SEGMENT DECODE WITHOUT THE ENGINE
# ---------------------------------------------------------------------------
#
# A segment is `Schema, RecordBatch*, EOS` written by `BrokerCore` with
# the core packages' IPC encoder (no dictionary batches). The broker leaf may not
# import the engine's stream reader, so this file decodes the RecordBatch
# frames with the core packages' `decode_record_batch_message` against the topic
# CONFIG's schema (the binding's topic columns are checked against it first,
# `check_topic_schema`). A dictionary frame is refused by name.
#
# ---------------------------------------------------------------------------
# ENCAPSULATION
# ---------------------------------------------------------------------------
#
# No `UnsafePointer`, no wildcard origin, no `unsafe_from_address`. The reader
# holds its `ConsumeCore` and its pending frames by value. An engine holds the
# reader erased (`ErasedSplitReader`), whose home is a typed allocation it
# drops exactly once.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow_ipc.ipc_decoder_dispatch import decode_record_batch_message
from komira_arrow_ipc.ipc_flatbuf import (
    flatbuf_reader_over,
    read_message,
    MESSAGE_HEADER_DICTIONARY_BATCH,
    MESSAGE_HEADER_RECORD_BATCH,
    MESSAGE_HEADER_SCHEMA,
)
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_column_kernels.batch_slice import _slice_batch_range
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion

from komira_scan_resolver.scan_split import (
    SplitPoll,
    SplitPosition,
    SplitReader,
    SPLIT_POLL_ROWS,
)

from komira_objectstore.path import Path
from komira_objectstore.store import CloneableConditionalWriteStore

from .broker_core import BrokerTopicConfig, _manifest_prefix, _topic_config_key
from .broker_scan_binding import (
    BROKER_PARTITION_COLUMN,
    BROKER_SCAN_KIND_NAME,
    broker_scan_kind_id,
)
from .compacted_index import CompactionIndex
from .consume_core import ConsumeCore, SegmentRef
from .log_compaction import (
    decode_compacted_survivor_offsets,
    is_chunk_compacted,
)


comptime BROKER_POSITION_VERSION: UInt8 = 1
"""The version of the broker's `SplitPosition` encoding (module header)."""

comptime BROKER_SCAN_BAD_POSITION: StaticString = "BROKER_SCAN_BAD_POSITION"
"""NAMED ERROR — a broker split position whose bytes do not decode: too short,
or a chunk count that does not match its length."""

comptime BROKER_SCAN_COMPACTED_CHUNK_MISMATCH: StaticString = (
    "BROKER_SCAN_COMPACTED_CHUNK_MISMATCH"
)
"""NAMED ERROR — a log-compacted chunk whose `.seg` does not hold exactly one
row per survivor offset in its sidecar. The production cleaner
(`ProductionLogCleaner`) rewrites the `.seg` and the body together; a chunk
whose body was swapped without its segment cannot be numbered, so it is
refused rather than read with invented offsets."""

comptime BROKER_SCAN_COMPACTED_TIER_UNREAD: StaticString = (
    "BROKER_SCAN_COMPACTED_TIER_UNREAD"
)
"""NAMED ERROR — the requested range reaches offsets held in the COMPACTED
(Parquet) tier (`CompactionIndex`), which this kind does not read yet.
Refused rather than clamped to the live `log_start`,
which the compaction worker advanced past that prefix: a clamp would drop
the prefix with no error and report it as retention."""

comptime BROKER_SCAN_LOG_START_MOVED: StaticString = (
    "BROKER_SCAN_LOG_START_MOVED"
)
"""NAMED ERROR — a partition's `log_start` moved past where a split read is
(retention reaped the rows the plan promised, after the plan was made). The
rows are gone from the live tier; the read is refused rather than resumed at
the new `log_start`, which would skip them with no error."""

comptime BROKER_SCAN_SCHEMA_MISMATCH: StaticString = (
    "BROKER_SCAN_SCHEMA_MISMATCH"
)
"""NAMED ERROR — the binding's topic columns (names or types) disagree with
the topic's durable config. The binding (plan-cached, or decoded off the
wire) is not the authority on how stored segment bytes decode; the config
is."""

comptime BROKER_SCAN_DICTIONARY_SEGMENT: StaticString = (
    "BROKER_SCAN_DICTIONARY_SEGMENT"
)
"""NAMED ERROR — a segment carried a DictionaryBatch frame. `BrokerCore` never
writes one; the schema-directed decoder refuses rather than mis-decode."""


# =============================================================================
# §1 — the position codec
# =============================================================================


def broker_split_position(offset: Int64, skip: List[Int64]) -> SplitPosition:
    """The position at `offset` of a split whose plan skips the data chunks
    `skip` (module header)."""
    var b = List[UInt8](capacity=12 + 8 * len(skip))
    _put_u64(b, UInt64(offset), 8)
    _put_u64(b, UInt64(len(skip)), 4)
    for i in range(len(skip)):
        _put_u64(b, UInt64(skip[i]), 8)
    return SplitPosition(broker_scan_kind_id(), BROKER_POSITION_VERSION, b^)


def broker_position_offset(pos: SplitPosition, what: String) raises -> Int64:
    """The offset `pos` names. Refuses another kind's position, another
    version, or bytes that do not decode, naming `what`."""
    _check_position(pos, what)
    return Int64(_get_u64(pos.bytes, 0, 8))


def broker_position_skip(pos: SplitPosition, what: String) raises -> List[Int64]:
    """The chunks a split skips, as `pos` carries them."""
    _check_position(pos, what)
    var n = Int(_get_u64(pos.bytes, 8, 4))
    var out = List[Int64](capacity=n)
    for i in range(n):
        out.append(Int64(_get_u64(pos.bytes, 12 + 8 * i, 8)))
    return out^


def _check_position(pos: SplitPosition, what: String) raises:
    pos.require_kind(
        broker_scan_kind_id(),
        BROKER_POSITION_VERSION,
        String(BROKER_SCAN_KIND_NAME),
        what,
    )
    var n = len(pos.bytes)
    if n < 12 or n != 12 + 8 * Int(_get_u64(pos.bytes, 8, 4)):
        raise Error(
            String(BROKER_SCAN_BAD_POSITION)
            + String(": the ")
            + what
            + String(" position holds ")
            + String(n)
            + String(" bytes, which is not an offset and a chunk list")
        )


def _put_u64(mut b: List[UInt8], v: UInt64, width: Int):
    for i in range(width):
        b.append(UInt8((v >> UInt64(8 * i)) & UInt64(0xFF)))


def _get_u64(b: List[UInt8], at: Int, width: Int) -> UInt64:
    var v = UInt64(0)
    for i in range(width):
        v |= UInt64(b[at + i]) << UInt64(8 * i)
    return v


# =============================================================================
# §2 — checks shared by the plan and the reader
# =============================================================================


def check_topic_schema[
    S: CloneableConditionalWriteStore
](
    store: S, cluster: String, topic: String, topic_schema: Schema, binding_name: String
) raises -> Schema:
    """Refuse a binding whose topic columns are not the topic's durable
    config schema (name, type, nullability, decimal precision and scale,
    in order), and return the CONFIG's schema, which is what decodes."""
    var cfg = BrokerTopicConfig.decode(
        store.get(Path.parse(_topic_config_key(cluster, topic)))
    )
    var n = cfg.schema.num_columns()
    if topic_schema.num_columns() != n:
        raise Error(
            String(BROKER_SCAN_SCHEMA_MISMATCH)
            + String(": binding '")
            + binding_name
            + String("' declares ")
            + String(topic_schema.num_columns())
            + String(" topic columns; topic '")
            + topic
            + String("' has ")
            + String(n)
        )
    for i in range(n):
        if (
            topic_schema.field_name(i) != cfg.schema.field_name(i)
            or topic_schema.field_arrow_type(i) != cfg.schema.field_arrow_type(i)
            or topic_schema.field_nullable(i) != cfg.schema.field_nullable(i)
            or topic_schema.field_decimal_precision(i)
            != cfg.schema.field_decimal_precision(i)
            or topic_schema.field_decimal_scale(i)
            != cfg.schema.field_decimal_scale(i)
        ):
            raise Error(
                String(BROKER_SCAN_SCHEMA_MISMATCH)
                + String(": binding '")
                + binding_name
                + String("' column ")
                + String(i)
                + String(" ('")
                + topic_schema.field_name(i)
                + String("') does not match topic '")
                + topic
                + String("' column '")
                + cfg.schema.field_name(i)
                + String("' in name, type, nullability or decimal")
                + String(" precision/scale")
            )
    return cfg.schema.copy()


def refuse_compacted_tier[
    S: CloneableConditionalWriteStore
](
    store: S, cluster: String, topic: String, partition: Int64, start: Int64, end: Int64
) raises:
    """Refuse a range `[start, end)` that reaches a compaction-index entry
    (the Parquet tier). One LIST of the compacted lineage; an empty lineage
    costs no GET.

    ORDERING INVARIANT: call this AFTER reading `log_start` (and the live
    index, which reads it too). The compaction worker commits its
    `CompactedEntry` BEFORE it advances `log_start`, so any `log_start` read
    that sees the advance happened after the entry was committed, and this
    LIST, which follows it, sees the entry and refuses. LISTing first lets the
    commit and the advance both land between an empty LIST and the
    `log_start` read."""
    var cidx = CompactionIndex[S].build(
        store.clone(), _manifest_prefix(cluster, topic, partition)
    )
    var entries = cidx.resolve_compacted()
    for e in range(len(entries)):
        ref ent = entries[e]
        if ent.last_offset >= start and ent.base_offset < end:
            raise Error(
                String(BROKER_SCAN_COMPACTED_TIER_UNREAD)
                + String(": topic '")
                + topic
                + String("' partition ")
                + String(partition)
                + String(" offsets ")
                + String(ent.base_offset)
                + String("..")
                + String(ent.last_offset)
                + String(" are in the compacted (Parquet) tier, which this")
                + String(" scan does not read; start at or after ")
                + String(ent.last_offset + Int64(1))
            )


# =============================================================================
# §3 — BrokerSplitReader
# =============================================================================


struct BrokerSplitReader[Storage: CloneableConditionalWriteStore](
    SplitReader, Movable, Deinitable
):
    """Reads one partition from its split's start to its stop (module header).
    Built by `BrokerScanRuntime.open_split` through `open`."""

    var _core: ConsumeCore[Self.Storage]
    var _store: Self.Storage
    var _cluster: String
    var _topic: String
    var _partition: Int64
    var _topic_schema: Schema
    var _index: List[SegmentRef]
    var _seg: Int
    var _cursor: Int64
    var _bound: Int64
    var _skip: List[Int64]
    var _partition_max_bytes: Int64
    var _part_bytes: Int64
    var _returned_any: Bool
    var _pending: Slab[RecordBatch]
    var _pending_next: List[Int64]
    var _pending_at: Int
    var _ended: Bool

    def __init__(
        out self,
        var core: ConsumeCore[Self.Storage],
        var store: Self.Storage,
        var cluster: String,
        var topic: String,
        partition: Int64,
        var topic_schema: Schema,
        var index: List[SegmentRef],
        start: Int64,
        bound: Int64,
        var skip: List[Int64],
        partition_max_bytes: Int64,
    ):
        self._core = core^
        self._store = store^
        self._cluster = cluster^
        self._topic = topic^
        self._partition = partition
        self._topic_schema = topic_schema^
        self._index = index^
        self._seg = 0
        self._cursor = start
        self._bound = bound
        self._skip = skip^
        self._partition_max_bytes = partition_max_bytes
        self._part_bytes = 0
        self._returned_any = False
        self._pending = Slab[RecordBatch]()
        self._pending_next = List[Int64]()
        self._pending_at = 0
        self._ended = False

    @staticmethod
    def open(
        var core: ConsumeCore[Self.Storage],
        var store: Self.Storage,
        var cluster: String,
        var topic: String,
        partition: Int64,
        var topic_schema: Schema,
        start: Int64,
        bound: Int64,
        var skip: List[Int64],
        partition_max_bytes: Int64,
    ) raises -> BrokerSplitReader[Self.Storage]:
        """Re-check the live tier's extent (module header) and return the
        reader at `start`. `topic_schema` is the config's, already checked."""
        var log_start = core.log_start_offset()
        var index = core.resolve_index()
        refuse_compacted_tier(store, cluster, topic, partition, start, bound)
        if log_start > start and start < bound:
            raise _log_start_moved(topic, partition, start, log_start)
        return BrokerSplitReader[Self.Storage](
            core^,
            store^,
            cluster^,
            topic^,
            partition,
            topic_schema^,
            index^,
            start,
            bound,
            skip^,
            partition_max_bytes,
        )

    def _position(self) -> SplitPosition:
        return broker_split_position(self._cursor, self._skip)

    def _end(mut self, at: Int64) -> SplitPoll:
        if at > self._cursor:
            self._cursor = at
        self._ended = True
        return SplitPoll.end(self._position())

    def _pop(mut self, source_bytes: Int64) -> SplitPoll:
        """Return the next pending frame, its position the offset after it."""
        var batch = self._pending.take_at(0)
        self._cursor = self._pending_next[self._pending_at]
        self._pending_at += 1
        if len(self._pending) == 0:
            self._pending_next = List[Int64]()
            self._pending_at = 0
        return SplitPoll.rows(batch^, self._position(), source_bytes=source_bytes)

    def poll(mut self, max_rows: Int64, max_bytes: Int64) raises -> SplitPoll:
        """One frame of one segment per poll. `max_rows` / `max_bytes` never
        bind: a poll returns at most one segment's first frame, which is
        always returned whole (`SplitReader.poll`). The scan-wide budget is
        `drain_scan`'s, the partition budget is this reader's (module
        header)."""
        if self._ended:
            return SplitPoll.end(self._position())
        if len(self._pending) > 0:
            return self._pop(0)
        while True:
            if self._seg >= len(self._index):
                return self._end(self._bound)
            var seg = self._index[self._seg].copy()
            if seg.base_offset >= self._bound:
                return self._end(self._bound)
            if seg.last_offset < self._cursor or _contains_i64(
                self._skip, seg.chunk_seq
            ):
                self._seg += 1
                continue
            var log_start = self._core.log_start_offset()
            if log_start > self._cursor:
                refuse_compacted_tier(
                    self._store,
                    self._cluster,
                    self._topic,
                    self._partition,
                    self._cursor,
                    self._bound,
                )
                raise _log_start_moved(
                    self._topic, self._partition, self._cursor, log_start
                )
            var read = self._core.read_segment(seg.copy())
            var stream = read^.take_stream_bytes()
            var sz = Int64(len(stream))
            if (
                self._returned_any
                and self._partition_max_bytes >= Int64(0)
                and self._part_bytes + sz > self._partition_max_bytes
            ):
                # END short of the stop: a cut, resumable at this segment.
                return self._end(seg.base_offset)
            var body = self._core.read_chunk_body(seg.chunk_seq)
            var emitted = _emit_segment(
                self._pending,
                self._pending_next,
                stream^,
                self._topic_schema,
                is_chunk_compacted(body),
                decode_compacted_survivor_offsets(body),
                seg.base_offset,
                seg.last_offset,
                self._cursor,
                self._partition,
            )
            self._part_bytes += sz
            self._seg += 1
            if emitted > 0:
                self._returned_any = True
                return self._pop(sz)
            # Nothing at or past the cursor (a compacted chunk whose survivors
            # are all below it, or none): consumed, with no rows.
            if seg.last_offset + 1 > self._cursor:
                self._cursor = seg.last_offset + 1
            return SplitPoll(SPLIT_POLL_ROWS, self._position(), source_bytes=sz)


def _log_start_moved(
    topic: String, partition: Int64, at: Int64, log_start: Int64
) -> Error:
    return Error(
        String(BROKER_SCAN_LOG_START_MOVED)
        + String(": topic '")
        + topic
        + String("' partition ")
        + String(partition)
        + String(" was planned from offset ")
        + String(at)
        + String(", and its log_start is now ")
        + String(log_start)
        + String("; the rows between were removed after the scan was planned")
    )


# =============================================================================
# helpers
# =============================================================================


def _contains_i64(xs: List[Int64], x: Int64) -> Bool:
    for i in range(len(xs)):
        if xs[i] == x:
            return True
    return False


def _partition_column(partition: Int64, rows: Int) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int64].allocate(rows)
    for i in range(rows):
        arr.set(i, partition)
    return Column.from_primitive[DType.int64](arr^)


def _emit_segment(
    mut out: Slab[RecordBatch],
    mut next_offsets: List[Int64],
    var stream: List[UInt8],
    topic_schema: Schema,
    compacted: Bool,
    survivors: List[Int64],
    base_offset: Int64,
    last_offset: Int64,
    start: Int64,
    partition: Int64,
) raises -> Int:
    """Decode one segment and append its rows at offsets `>= start`, each with
    the `__partition` column, one batch per IPC frame that keeps a row. For
    each batch, `next_offsets` gets the offset after it: the next physical
    row's, or `last_offset + 1` after the segment's last row. A log-compacted
    chunk's row `r` is at `survivors[r]` (a zero-survivor chunk is compacted
    with an EMPTY sidecar, which is why `compacted` is its own flag); an
    ordinary chunk's at `base_offset + r`. Returns the rows appended."""
    var decoded = _decode_segment_stream(stream^, topic_schema)
    var physical = 0
    for i in range(len(decoded)):
        physical += decoded[i].num_rows()
    if compacted and physical != len(survivors):
        raise Error(
            String(BROKER_SCAN_COMPACTED_CHUNK_MISMATCH)
            + String(": compacted chunk at base offset ")
            + String(base_offset)
            + String(" holds ")
            + String(physical)
            + String(" rows for ")
            + String(len(survivors))
            + String(" survivor offsets")
        )
    var row = 0
    var emitted = 0
    while len(decoded) > 0:
        var batch = decoded.take_at(0)
        var n = batch.num_rows()
        # First row of this frame whose absolute offset reaches `start`.
        var skip = 0
        while skip < n:
            var off = (
                survivors[row + skip] if compacted else base_offset
                + Int64(row + skip)
            )
            if off >= start:
                break
            skip += 1
        row += n
        if skip >= n:
            continue
        var kept: RecordBatch
        if skip == 0:
            kept = batch^
        else:
            kept = _slice_batch_range(batch, skip, n - skip)
        var kn = kept.num_rows()
        kept.append_column(
            Field(String(BROKER_PARTITION_COLUMN), ArrowType.INT64, nullable=False),
            _partition_column(partition, kn),
        )
        out.append(kept^)
        var next = last_offset + 1
        if row < physical:
            next = survivors[row] if compacted else base_offset + Int64(row)
        next_offsets.append(next)
        emitted += kn
    return emitted


def _decode_segment_stream(
    var bytes: List[UInt8], topic_schema: Schema
) raises -> Slab[RecordBatch]:
    """Schema-directed decode of one segment's Arrow IPC stream
    (`Schema, RecordBatch*, EOS`) with the core packages' record-batch decoder.
    The Schema frame is skipped: `topic_schema` is the topic's durable config
    schema (`check_topic_schema` returns it), which is the authority, and a
    frame whose column count disagrees with it is refused by the core decoder's
    own bounds checks."""
    var types = List[ArrowType]()
    for i in range(topic_schema.num_columns()):
        types.append(topic_schema.field_arrow_type(i))
    var n = len(bytes)
    var src = SharedAlignedBuffer[HeapRegion].heap_owned(n)
    src.copy_from_bytes_list(bytes^)
    var out = Slab[RecordBatch]()
    var cursor = 0
    var saw_eos = False
    while cursor + 8 <= n:
        var cont = src.read_u32_le_at(cursor)
        var size_u32 = src.read_u32_le_at(cursor + 4)
        if cont != UInt32(0xFFFFFFFF):
            raise Error(
                String("broker segment decode: no continuation marker at byte ")
                + String(cursor)
            )
        if size_u32 == UInt32(0):
            saw_eos = True
            break
        var meta_size = Int(size_u32)
        if cursor + 8 + meta_size > n:
            raise Error(
                String("broker segment decode: metadata past end at byte ")
                + String(cursor)
            )
        var fb = SharedAlignedBuffer[HeapRegion].heap_owned(meta_size)
        fb.copy_from_view_at(0, src.view_range_ro(cursor + 8, meta_size))
        fb.set_length(meta_size)
        var reader = flatbuf_reader_over(fb)
        var msg = read_message(reader, reader.read_root_offset())
        var body = Int(msg.body_length)
        var frame_size = 8 + meta_size + body
        if body < 0 or cursor + frame_size > n:
            raise Error(
                String("broker segment decode: frame past end at byte ")
                + String(cursor)
            )
        if msg.header_tag == MESSAGE_HEADER_SCHEMA:
            cursor += frame_size
            continue
        if msg.header_tag == MESSAGE_HEADER_DICTIONARY_BATCH:
            raise Error(
                String(BROKER_SCAN_DICTIONARY_SEGMENT)
                + String(": a broker segment carried a DictionaryBatch frame")
            )
        if msg.header_tag != MESSAGE_HEADER_RECORD_BATCH:
            raise Error(
                String("broker segment decode: unexpected message tag ")
                + String(Int(msg.header_tag))
            )
        var frame = SharedAlignedBuffer[HeapRegion].heap_owned(frame_size)
        frame.copy_from_view_at(0, src.view_range_ro(cursor, frame_size))
        frame.set_length(frame_size)
        var cols = decode_record_batch_message(frame^, types)
        var builder = RecordBatchBuilder.with_capacity(len(cols))
        var nc = len(cols)
        for c in range(nc):
            builder.add_column(cols.take_slot_unchecked(c))
        cols.set_len_unchecked(0)
        _ = cols^
        out.append(builder.build(topic_schema.copy()))
        cursor += frame_size
    if not saw_eos:
        raise Error(String("broker segment decode: stream ended without EOS"))
    return out^
