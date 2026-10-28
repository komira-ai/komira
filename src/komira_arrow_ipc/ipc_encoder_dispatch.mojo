# =============================================================================
# ipc_encoder_dispatch.mojo — Per-DType encoder dispatch driver
# Driver + shared helpers
# =============================================================================
#
# Comptime fold-by-ArrowType cascade dispatching from a type-erased
# `Column` to the matching per-DType encoder body. Mirrors the existing
# `c_data_stream.mojo` build-record-batch driver shape — NOT a trampoline;
# a static if-else cascade where each arm calls a comptime-monomorphized
# encoder body.
#
# Shared helpers in this file:
#   encode_record_batch_message — top-level entry; returns complete IPC frame
#   encode_column                — comptime cascade dispatch entry per column
#   emit_validity_bitmap         — shared validity bitmap emit
#   emit_primitive_value_buffer  — shared primitive value-buffer emit
#   _align_to_8                  — body alignment helper
#   _copy_bytes_into_body        — bounded-buffer byte copy
#
# Per-DType encoder bodies live in:
#   ipc_encoder_primitive.mojo  (Int8..Int64, UInt8..UInt64, Float16/32/64, Bool, Null)
#   ipc_encoder_varlen.mojo     (String, LargeString, Binary, LargeBinary)
#   ipc_encoder_temporal.mojo   (Date/Time/Timestamp/Duration/Interval/Decimal)
#   ipc_encoder_nested.mojo     (List/LargeList/Struct/Map/Union/Dictionary)
#
# Mojo has no comptime-extend-trait operator. This encoder emits
# UNCOMPRESSED buffers; the compressed path uses the `ArrowIpcCompression`
# sub-trait + per-Buffer 8-byte uncompressed-length prefix
# (`ipc_body_compression.mojo`).
# =============================================================================

from komira_buffer.aligned_buffer_trait import AlignedBufferTrait
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.schema import Schema
from komira_buffer.byte_view import ByteView
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion
from komira_arrow_ipc.ipc_body_sink import (
    BodySink,
    AlignedBufferBodySink,
    StreamingFileBodySink,
)
from komira_arrow_ipc.ipc_flatbuf import (
    FlatbufWriter,
    BufferDescriptor,
    FieldNode,
    write_record_batch,
    write_message,
    write_ipc_message,
    write_field,
    write_schema,
    write_dictionary_encoding,
    write_type_int,
    write_type_floating_point,
    write_type_utf8,
    write_type_bool,
    write_type_null,
    write_type_binary,
    write_type_large_binary,
    write_type_large_utf8,
    write_type_date,
    write_type_time,
    write_type_timestamp,
    write_type_duration,
    write_type_interval,
    write_type_decimal,
    PRECISION_HALF,
    PRECISION_SINGLE,
    PRECISION_DOUBLE,
    DATE_UNIT_DAY,
    DATE_UNIT_MILLISECOND,
    TIME_UNIT_SECOND,
    TIME_UNIT_MILLISECOND,
    TIME_UNIT_MICROSECOND,
    TIME_UNIT_NANOSECOND,
    INTERVAL_UNIT_YEAR_MONTH,
    INTERVAL_UNIT_DAY_TIME,
    INTERVAL_UNIT_MONTH_DAY_NANO,
    ENDIANNESS_LITTLE,
    METADATA_VERSION_V5,
    MESSAGE_HEADER_SCHEMA,
    MESSAGE_HEADER_RECORD_BATCH,
    MESSAGE_HEADER_DICTIONARY_BATCH,
    TYPE_NULL,
    TYPE_INT,
    TYPE_FLOATING_POINT,
    TYPE_BINARY,
    TYPE_UTF8,
    TYPE_BOOL,
    TYPE_DECIMAL,
    TYPE_DATE,
    TYPE_TIME,
    TYPE_TIMESTAMP,
    TYPE_DURATION,
    TYPE_INTERVAL,
    TYPE_LARGE_BINARY,
    TYPE_LARGE_UTF8,
    write_dictionary_batch,
    write_footer,
    Block,
    IPC_CONTINUATION_MARKER,
)
from komira_arrow_ipc.ipc_encoder_primitive import (
    encode_int8,
    encode_int16,
    encode_int32,
    encode_int64,
    encode_uint8,
    encode_uint16,
    encode_uint32,
    encode_uint64,
    encode_float16,
    encode_float32,
    encode_float64,
    encode_bool,
    encode_null,
)
from komira_arrow_ipc.ipc_encoder_varlen import (
    encode_string,
    encode_binary,
    encode_large_string,
    encode_large_binary,
)
from komira_arrow_ipc.ipc_encoder_temporal import (
    encode_date32,
    encode_date64,
    encode_time32,
    encode_time64,
    encode_timestamp,
    encode_duration,
    encode_interval_ym,
    encode_interval_dt,
    encode_interval_mdn,
    encode_decimal128,
    encode_decimal256,
    encode_fixed_size_binary,
)


# =============================================================================
# Nested encoder imports
# =============================================================================
#
# Nested encoders (LIST / STRUCT / MAP / UNION_SPARSE / UNION_DENSE) emit
# their OWN FieldNode + Buffer entries; CHILD recursion is performed by
# this dispatch driver (encode_column) directly after the per-arm call
# returns. The previous fn-pointer `recurse: EncoderRecurseFn` parameter
# pattern was dropped in — fn-pointer
# aliases with Movable-only payload types (`Column`) hit a Mojo 1.0.0b1
# call-site materialization hole. Direct self-call (the standard Mojo
# recursion idiom) is the canonical replacement.
from komira_arrow_ipc.ipc_encoder_nested import (
    encode_list,
    encode_large_list,
    encode_fixed_size_list,
    encode_struct,
    encode_map,
    encode_union_sparse,
    encode_union_dense,
    encode_dictionary,
)


# =============================================================================
# Public entry — encode_record_batch_message
# =============================================================================


def encode_record_batch_message(
    var columns: Slab[Column[HeapRegion]],
) raises -> SharedAlignedBuffer[HeapRegion]:
    """Encode N columns as one Arrow IPC RecordBatch message frame.

    Output: [u32 0xFFFFFFFF, u32 size, FB(Message{header=RecordBatch}), pad,
             body bytes]. Body layout is concatenated per-column Buffer
             entries with 8-byte alignment padding between them.

    The Schema is NOT part of this message — caller emits a Schema message
    first (separately).

    Back-compat entry: wraps an `AlignedBufferBodySink` and returns the
    fully-staged IPC frame. Suitable for compressed encoders (which need
    a contiguous in-memory body to feed the codec) and for memory-mode
    callers (`accept_arrow` stream-mode, dict batch encoder, tests).

    For the new streaming path used by uncompressed file writes, see
    `encode_record_batch_message_streaming[O]` below — it bypasses the
    body-staging copy by writing per-buffer bytes directly through a
    FileHandle.
    """
    if len(columns) == 0:
        raise Error("encode_record_batch_message: zero columns")

    # All columns in a RecordBatch must have the same row count.
    var row_count = columns[0]._length
    for i in range(1, len(columns)):
        if columns[i]._length != row_count:
            raise Error(
                "encode_record_batch_message: row count mismatch at column "
                + String(i)
                + " (expected "
                + String(row_count)
                + ", got "
                + String(columns[i]._length)
                + ")"
            )

    # Conservatively pre-size the body buffer.
    # dropped the
    # `body.zero()` blanket. Every byte in `[0, body_cursor)` is now
    # explicitly covered: `_copy_bytes_into_body` writes its target
    # range, and the new `_align_to_8_zero_pad` helper writes 0 at the
    # 0-7-byte gap between adjacent buffer entries.
    var sink = AlignedBufferBodySink(_estimate_body_size(columns))
    var body_cursor: Int = 0
    var buffers = List[BufferDescriptor]()
    var nodes = List[FieldNode]()

    for i in range(len(columns)):
        body_cursor = encode_column[AlignedBufferBodySink](
            columns[i], sink, body_cursor, buffers, nodes
        )

    # Pad the body to an 8-byte
    # boundary per Arrow IPC spec §4 ("body buffers MUST be padded to
    # an 8-byte boundary"). The padded length is encoded in the
    # Message.bodyLength field — pyarrow asserts Block.bodyLength ==
    # Message.bodyLength at read time and rejects mismatches.
    var body_pad = (8 - (body_cursor % 8)) % 8
    if body_pad > 0:
        for _ in range(body_pad):
            sink.write_u8_at(body_cursor, UInt8(0))
            body_cursor += 1

    # Take ownership of the inner buffer (length set to body_cursor).
    var body = sink.finalize()

    # Build FB metadata.
    var w = FlatbufWriter(2048)
    var rb_pos = write_record_batch(
        w, Int64(row_count), nodes, buffers
    )
    var msg_pos = write_message(
        w,
        Int16(4),  # MetadataVersion.V5
        MESSAGE_HEADER_RECORD_BATCH,
        rb_pos,
        Int64(body_cursor),
    )
    var fb_payload = w^.finalize(msg_pos)

    # Wrap in IPC outer frame.
    var w2 = FlatbufWriter(64)
    var body_span = body.view_range_ro(0, body_cursor).into_span()
    var frame = write_ipc_message(w2, fb_payload^, body_span, True)
    _ = body^  # keep body alive until span is consumed
    return frame^


# =============================================================================
# encode_record_batch_message_streaming — zero-stage-body uncompressed path
# =============================================================================
#
#
# Writes the IPC frame DIRECTLY through a borrowed FileHandle, without
# allocating a contiguous body MmapAlignedBuffer. Per-buffer bytes flow
# source → file via the StreamingFileBodySink (small writes coalesce in
# a 1 MiB staging buffer; large writes BYPASS staging entirely and flow
# straight to the file handle).
#
# Output shape is byte-identical to `encode_record_batch_message` ->
# `_write_arrow_bytes(frame)` — same continuation marker, same metadata
# size, same FB payload, same body bytes, same 8-byte body-pad.
# The compressed path is untouched (still uses `encode_record_batch_
# message_compressed[C]` which needs a contiguous body for the codec).
#
# Returns the **total bytes written** (= continuation_marker + metadata
# size + FB payload + pad-after-FB + body + body-pad). Caller uses this
# for Block.body_length / arrow_bytes_written bookkeeping (matches the
# pre-refactor `frame.length + body_pad` accounting in
# `accept_arrow_file`).


struct StreamingEncodeResult(Movable):
    """Return value of `encode_record_batch_message_streaming`.

    Tracks the bytes that landed in the file so the caller can update
    Block.body_length, Block.meta_data_length, and
    arrow_bytes_written exactly as the legacy path did.
    """
    # Total bytes written (frame + body-pad), matches the legacy
    # `frame.length + body_pad` sum.
    var total_bytes: Int
    # Metadata-only length (continuation_marker + size_u32 + FB_payload
    # + pad-after-FB). Mirrors `arrow_ipc_message_metadata_length(rb_frame)`.
    var meta_data_length: Int
    # Body-only byte count (post-pad). Caller stores this in
    # Block.body_length.
    var body_length: Int

    def __init__(
        out self,
        total_bytes: Int,
        meta_data_length: Int,
        body_length: Int,
    ):
        self.total_bytes = total_bytes
        self.meta_data_length = meta_data_length
        self.body_length = body_length


def encode_record_batch_message_streaming[
    B: BodySink
](
    var columns: Slab[Column[HeapRegion]],
    mut body_sink: B,
) raises -> StreamingEncodeResult:
    """Encode N columns as one Arrow IPC RecordBatch frame and write it
    DIRECTLY through `body_sink`, without staging the body in an
    MmapAlignedBuffer.

    Generic over `B: BodySink` — the encoder NO LONGER knows about the
    concrete handle type. Caller constructs the conformer (e.g.
    `StreamingFileBodySink(hptr)` wrapping a FileHandle pointer, or any
    future cloud-FS sink) and passes it in by `mut` borrow. This is the
    design that decouples the encoder from the file_sink kind=3 raw FileHandle
    field while keeping that field POD-shape (avoids §2.3 Optional[heap-
    owning-T]-during-multi-hop-moves hazard).

    The header writes (continuation marker + metadata size + FB payload
    + pad-after-FB) AND the body-pad write all flow through
    `body_sink.copy_from_view_at` / `body_sink.write_u8_at`. The
    BodySink trait is the encoder's ONLY contact with byte storage.

    Frame layout (byte-identical to `encode_record_batch_message`):
      [u32 0xFFFFFFFF, u32 metadata_size, FB(Message{...}), pad-after-FB,
       body bytes, body-pad-to-8].

    Two-pass execution:
      Pass 1: dry-run the encoder cascade to compute body bytes per
              column + populate the BufferDescriptor + FieldNode lists.
              Uses a NULL sink that only tracks cursor, no bytes written.
      Pass 2: build FB metadata, write the [continuation + size + FB +
              pad-after-FB] header through `body_sink`, then run the
              encoder cascade AGAIN against `body_sink`. Finally write
              the body pad.

    Why two passes: the IPC frame layout puts FB metadata BEFORE the
    body, but BufferDescriptor entries (in the FB metadata) need to
    know each buffer's body-relative offset + length — which requires
    walking the columns once to compute offsets. The dry-run is cheap
    (just cursor arithmetic, no memcpy); the wet-run pays the actual
    memcpy cost. Together they're still ~1× the legacy single-pass
    cost because the legacy path paid for the staging memcpy AND the
    write_ipc_message body memcpy (2 memcpy passes); we pay 0 staging
    + 1 file write (1 effective pass).

    Cursor semantics:
      `body_sink.bytes_written()` is the absolute count of bytes
      emitted through this sink since construction. The caller MUST
      construct a fresh sink per call (existing pattern). The body
      starts at sink-cursor = header_size (after the header writes).
      The encoder threads its OWN `body_cursor: Int` that starts at 0
      (body-relative). To bridge: every body-arm write computes
      `absolute = header_size + body_cursor` and calls the sink at
      that absolute position. Header writes go in at sink-cursor 0,
      header_size at sink-cursor = header_size.
    """
    if len(columns) == 0:
        raise Error(
            "encode_record_batch_message_streaming: zero columns"
        )

    # Row count parity check.
    var row_count = columns[0]._length
    for i in range(1, len(columns)):
        if columns[i]._length != row_count:
            raise Error(
                "encode_record_batch_message_streaming: row count "
                "mismatch at column "
                + String(i)
                + " (expected "
                + String(row_count)
                + ", got "
                + String(columns[i]._length)
                + ")"
            )

    # === PASS 1: dry-run to populate BufferDescriptor + FieldNode lists.
    # The NULL sink only tracks cursor; no bytes are written. This
    # populates `buffers` (offset+length per buffer) and `nodes` (length,
    # null_count per column) — both of which the FB metadata needs
    # BEFORE we write the body.
    var dry_sink = _NullBodySink()
    var dry_cursor: Int = 0
    var buffers = List[BufferDescriptor]()
    var nodes = List[FieldNode]()
    for i in range(len(columns)):
        dry_cursor = encode_column[_NullBodySink](
            columns[i], dry_sink, dry_cursor, buffers, nodes
        )
    # Apply 8-byte body-pad to dry_cursor (same as legacy path).
    var body_pad = (8 - (dry_cursor % 8)) % 8
    var body_length = dry_cursor + body_pad

    # === Build FB metadata.
    var w = FlatbufWriter(2048)
    var rb_pos = write_record_batch(
        w, Int64(row_count), nodes, buffers
    )
    var msg_pos = write_message(
        w,
        Int16(4),  # MetadataVersion.V5
        MESSAGE_HEADER_RECORD_BATCH,
        rb_pos,
        Int64(body_length),
    )
    var fb_payload = w^.finalize(msg_pos)
    var fb_size = fb_payload.len()
    var fb_aligned = ((fb_size + 7) // 8) * 8
    var pad_after_fb = fb_aligned - fb_size

    # === Build the frame header (continuation + size + FB + pad).
    # This is small (~few hundred bytes); allocate a tiny MmapAlignedBuffer.
    var header_size = 4 + 4 + fb_aligned
    var header = SharedAlignedBuffer[HeapRegion].heap_owned(max(header_size, 1))
    var pos: Int = 0
    header.write_u32_le_at(pos, IPC_CONTINUATION_MARKER)
    pos += 4
    header.write_u32_le_at(pos, UInt32(fb_aligned))
    pos += 4
    header.copy_from_aligned_buffer_at(pos, fb_payload, 0, fb_size)
    pos += fb_size
    if pad_after_fb > 0:
        for i in range(pad_after_fb):  # cov: unreachable a Message payload holds an i64 field, so finalize pads it to 8
            header.write_u8_at(pos + i, UInt8(0))  # cov: unreachable a Message payload holds an i64 field, so finalize pads it to 8
        pos += pad_after_fb
    header.set_length(header_size)

    # Write the header through the body_sink (trait-mediated; no direct
    # FileHandle access). The sink's bytes_written starts at 0; after
    # this write it advances to header_size.
    var sink_cursor_before_header = body_sink.bytes_written()
    var header_view = header.view_range_ro(0, header_size)
    body_sink.copy_from_view_at(sink_cursor_before_header, header_view)
    _ = header^
    _ = fb_payload^

    # === PASS 2: re-walk columns and emit body bytes through body_sink.
    # The encoder per-DType arms compute body-relative cursors; the
    # sink tracks absolute bytes (= header_size + body_cursor). Each
    # arm calls sink at the absolute position.
    #
    # To preserve the existing per-DType encoder contract (cursor
    # arithmetic is body-relative), we wrap body_sink in a thin
    # body-relative adapter `_BodyOffsetSink[B, O]` so the encoders'
    # arms continue to call `sink.copy_from_view_at(body_cursor, ...)`
    # / `sink.write_u8_at(body_cursor, ...)` exactly as today. The
    # adapter rewrites the cursor to `header_size + body_cursor` and
    # forwards to the underlying `body_sink`.
    var sink_ptr = Pointer(to=body_sink)
    comptime O = origin_of(body_sink)
    var sink = _BodyOffsetSink[B, O](sink_ptr, header_size)
    var body_cursor: Int = 0
    var buffers2 = List[BufferDescriptor]()
    var nodes2 = List[FieldNode]()
    for i in range(len(columns)):
        body_cursor = encode_column[_BodyOffsetSink[B, O]](
            columns[i], sink, body_cursor, buffers2, nodes2
        )
    if body_cursor != dry_cursor:
        raise Error(  # cov: unreachable both passes run the same encoders over the same columns
            "encode_record_batch_message_streaming: pass-2 cursor "  # cov: unreachable both passes run the same encoders over the same columns
            + String(body_cursor)  # cov: unreachable both passes run the same encoders over the same columns
            + " != pass-1 cursor "  # cov: unreachable both passes run the same encoders over the same columns
            + String(dry_cursor)  # cov: unreachable both passes run the same encoders over the same columns
            + " (encoder dry-run / wet-run divergence)"  # cov: unreachable both passes run the same encoders over the same columns
        )
    # Write body-pad bytes (0-7) through the adapter.
    if body_pad > 0:
        for _ in range(body_pad):
            sink.write_u8_at(body_cursor, UInt8(0))
            body_cursor += 1
    _ = sink^

    var total_bytes = header_size + body_length
    return StreamingEncodeResult(
        total_bytes=total_bytes,
        meta_data_length=header_size,
        body_length=body_length,
    )


# Internal: a no-op BodySink that only tracks cursor (used by Pass 1
# of `encode_record_batch_message_streaming` to compute body offsets
# without paying memcpy cost).
struct _NullBodySink(BodySink, Movable):
    var _written: Int

    def __init__(out self):
        self._written = 0

    def write_u8_at(mut self, cursor: Int, value: UInt8) raises:
        var new_w = cursor + 1
        if new_w > self._written:
            self._written = new_w

    def copy_from_view_at(
        mut self, cursor: Int, src: ByteView[_]
    ) raises:
        var new_w = cursor + src.len()
        if new_w > self._written:
            self._written = new_w

    def capacity(self) -> Int:
        return 1 << 62

    def bytes_written(self) -> Int:
        return self._written


# Internal: body-relative-cursor adapter for `encode_record_batch_message_
# streaming`. Per-DType encoders compute cursor positions RELATIVE to the
# body's first byte (offset 0 = first body byte). The underlying body_sink
# tracks ABSOLUTE bytes since sink construction (offset 0 = first frame
# byte, including header). This adapter wraps a `Pointer[BS, O]` to the
# real sink and rewrites every body-relative call to its absolute
# position by adding `_offset` (= header_size).
#
# Non-Movable: holds a borrowed pointer to the underlying sink. Constructed
# locally inside `encode_record_batch_message_streaming` for the duration
# of Pass 2; the underlying sink outlives the adapter (lifetime tracked
# by the pointer's origin parameter).
struct _BodyOffsetSink[BS: BodySink, O: Origin[mut=True]](BodySink):
    var _sink: Pointer[Self.BS, Self.O]
    var _offset: Int

    def __init__(out self, sink: Pointer[Self.BS, Self.O], offset: Int):
        self._sink = sink
        self._offset = offset

    def write_u8_at(mut self, cursor: Int, value: UInt8) raises:
        self._sink[].write_u8_at(self._offset + cursor, value)

    def copy_from_view_at(
        mut self, cursor: Int, src: ByteView[_]
    ) raises:
        self._sink[].copy_from_view_at(self._offset + cursor, src)

    def capacity(self) -> Int:
        return self._sink[].capacity()

    def bytes_written(self) -> Int:
        # Body-relative count: subtract the header offset from the
        # underlying sink's absolute count.
        var abs = self._sink[].bytes_written()
        if abs < self._offset:
            return 0
        return abs - self._offset


# =============================================================================
# Per-column dispatch — encode_column
# =============================================================================


def encode_column[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    """Comptime fold-by-ArrowType cascade. Parametric on `B: BodySink`.

    For each arm:
      1. Appends FieldNode{length, null_count} for this column.
      2. Appends BufferDescriptor entries for the column's buffers.
      3. Writes the column's bytes into `body` starting at `body_cursor`.

    Returns the new body_cursor after writing.
    """
    # Primitives — fixed-width int / uint / float.
    if col.arrow_type == ArrowType.INT8:
        return encode_int8[B](col, body, body_cursor, buffers, nodes)
    if col.arrow_type == ArrowType.INT16:
        return encode_int16[B](col, body, body_cursor, buffers, nodes)
    if col.arrow_type == ArrowType.INT32:
        return encode_int32[B](col, body, body_cursor, buffers, nodes)
    if col.arrow_type == ArrowType.INT64:
        return encode_int64[B](col, body, body_cursor, buffers, nodes)
    if col.arrow_type == ArrowType.UINT8:
        return encode_uint8[B](col, body, body_cursor, buffers, nodes)
    if col.arrow_type == ArrowType.UINT16:
        return encode_uint16[B](col, body, body_cursor, buffers, nodes)
    if col.arrow_type == ArrowType.UINT32:
        return encode_uint32[B](col, body, body_cursor, buffers, nodes)
    if col.arrow_type == ArrowType.UINT64:
        return encode_uint64[B](col, body, body_cursor, buffers, nodes)
    if col.arrow_type == ArrowType.FLOAT16:
        return encode_float16[B](col, body, body_cursor, buffers, nodes)
    if col.arrow_type == ArrowType.FLOAT32:
        return encode_float32[B](col, body, body_cursor, buffers, nodes)
    if col.arrow_type == ArrowType.FLOAT64:
        return encode_float64[B](col, body, body_cursor, buffers, nodes)
    if col.arrow_type == ArrowType.BOOL:
        return encode_bool[B](col, body, body_cursor, buffers, nodes)
    if col.arrow_type == ArrowType.NULL:
        encode_null(col, nodes)
        return body_cursor

    # Variable-length.
    if col.arrow_type == ArrowType.STRING:
        return encode_string[B](col, body, body_cursor, buffers, nodes)
    if col.arrow_type == ArrowType.BINARY:
        return encode_binary[B](col, body, body_cursor, buffers, nodes)
    if col.arrow_type == ArrowType.LARGE_STRING:
        return encode_large_string[B](col, body, body_cursor, buffers, nodes)
    if col.arrow_type == ArrowType.LARGE_BINARY:
        return encode_large_binary[B](col, body, body_cursor, buffers, nodes)

    # Temporal.
    if col.arrow_type == ArrowType.DATE32:
        return encode_date32[B](col, body, body_cursor, buffers, nodes)
    if col.arrow_type == ArrowType.DATE64:
        return encode_date64[B](col, body, body_cursor, buffers, nodes)
    if (
        col.arrow_type == ArrowType.TIME32_S
        or col.arrow_type == ArrowType.TIME32_MS
    ):
        return encode_time32[B](col, body, body_cursor, buffers, nodes)
    if (
        col.arrow_type == ArrowType.TIME64_US
        or col.arrow_type == ArrowType.TIME64_NS
    ):
        return encode_time64[B](col, body, body_cursor, buffers, nodes)
    if (
        col.arrow_type == ArrowType.TIMESTAMP
        or col.arrow_type == ArrowType.TIMESTAMP_S
        or col.arrow_type == ArrowType.TIMESTAMP_MS
        or col.arrow_type == ArrowType.TIMESTAMP_US
        or col.arrow_type == ArrowType.TIMESTAMP_NS
    ):
        return encode_timestamp[B](col, body, body_cursor, buffers, nodes)
    if (
        col.arrow_type == ArrowType.DURATION_S
        or col.arrow_type == ArrowType.DURATION_MS
        or col.arrow_type == ArrowType.DURATION_US
        or col.arrow_type == ArrowType.DURATION_NS
    ):
        return encode_duration[B](col, body, body_cursor, buffers, nodes)
    if col.arrow_type == ArrowType.INTERVAL_YEAR_MONTH:
        return encode_interval_ym[B](col, body, body_cursor, buffers, nodes)
    if col.arrow_type == ArrowType.INTERVAL_DAY_TIME:
        return encode_interval_dt[B](col, body, body_cursor, buffers, nodes)
    if col.arrow_type == ArrowType.INTERVAL_MONTH_DAY_NANO:
        return encode_interval_mdn[B](col, body, body_cursor, buffers, nodes)

    # Decimal.
    if col.arrow_type == ArrowType.DECIMAL128:
        return encode_decimal128[B](col, body, body_cursor, buffers, nodes)
    if col.arrow_type == ArrowType.DECIMAL256:
        return encode_decimal256[B](col, body, body_cursor, buffers, nodes)

    # FIXED_SIZE_BINARY — byte_width from
    # col._inner_size.
    if col.arrow_type == ArrowType.FIXED_SIZE_BINARY:
        return encode_fixed_size_binary[B](
            col, body, body_cursor, buffers, nodes
        )

    # Nested. The per-arm encoder emits the parent's
    # FieldNode + Buffer entries; we then recurse into each child via
    # direct self-call.
    if col.arrow_type == ArrowType.LIST:
        var cursor = encode_list[B](col, body, body_cursor, buffers, nodes)
        return encode_column[B](
            col.child_at(0), body, cursor, buffers, nodes
        )
    if col.arrow_type == ArrowType.LARGE_LIST:
        var cursor = encode_large_list[B](
            col, body, body_cursor, buffers, nodes
        )
        return encode_column[B](
            col.child_at(0), body, cursor, buffers, nodes
        )
    if col.arrow_type == ArrowType.FIXED_SIZE_LIST:
        var cursor = encode_fixed_size_list[B](
            col, body, body_cursor, buffers, nodes
        )
        return encode_column[B](
            col.child_at(0), body, cursor, buffers, nodes
        )
    if col.arrow_type == ArrowType.STRUCT:
        var cursor = encode_struct[B](col, body, body_cursor, buffers, nodes)
        var n_children = col.num_children()
        for i in range(n_children):
            cursor = encode_column[B](
                col.child_at(i), body, cursor, buffers, nodes
            )
        return cursor
    if col.arrow_type == ArrowType.MAP:
        var cursor = encode_map[B](col, body, body_cursor, buffers, nodes)
        return encode_column[B](
            col.child_at(0), body, cursor, buffers, nodes
        )
    if col.arrow_type == ArrowType.UNION_SPARSE:
        var cursor = encode_union_sparse[B](
            col, body, body_cursor, buffers, nodes
        )
        var n_children = col.num_children()
        for i in range(n_children):
            cursor = encode_column[B](
                col.child_at(i), body, cursor, buffers, nodes
            )
        return cursor
    if col.arrow_type == ArrowType.UNION_DENSE:
        var cursor = encode_union_dense[B](
            col, body, body_cursor, buffers, nodes
        )
        var n_children = col.num_children()
        for i in range(n_children):
            cursor = encode_column[B](
                col.child_at(i), body, cursor, buffers, nodes
            )
        return cursor
    if col.arrow_type == ArrowType.DICTIONARY:
        return encode_dictionary[B](col, body, body_cursor, buffers, nodes)

    # View types — encoders intentionally raise: only the view-type
    # DECODER side exists (lossy decode-into-expanded-types). The encoder
    # side has no callers (no column emits as a View type since no
    # Column.from_*_view factory exists).
    if (
        col.arrow_type == ArrowType.BINARY_VIEW
        or col.arrow_type == ArrowType.UTF8_VIEW
        or col.arrow_type == ArrowType.LIST_VIEW
        or col.arrow_type == ArrowType.LARGE_LIST_VIEW
    ):
        raise Error(
            "ipc_encoder_dispatch: View-type encode (ArrowType "
            + String(Int(col.arrow_type.type_id))
            + ") is not supported. Only the view-type DECODER side "
            + "exists (lossy decode-into-expanded-types). No column "
            + "constructor emits view types."
        )

    raise Error(
        "ipc_encoder_dispatch: ArrowType "
        + String(Int(col.arrow_type.type_id))
        + " not yet wired in the IPC column encoder (covers primitives "
        + "+ var-len + temporal + decimal + nested + FixedSize*)"
    )


# =============================================================================
# Shared helpers — used by per-DType encoder bodies
# =============================================================================


def emit_validity_bitmap[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
) raises -> Int:
    """Emit the validity bitmap Buffer entry for a column.

    Per Arrow spec, if `null_count == 0` AND the column has no `_validity`
    bitmap, emit a ZERO-LENGTH Buffer entry (offset + length = 0). This
    signals "all non-null" to the reader.

    If validity is present, emit the bitmap bytes (LSB-first 1-bit pack;
    already in that layout in `col._validity.buffer`) + record the Buffer
    entry.

    Returns the new body_cursor.
    """
    if col._null_count == 0 and not col._validity:
        # No validity bitmap needed — zero-length Buffer entry at current
        # cursor.
        buffers.append(
            BufferDescriptor(offset=Int64(body_cursor), length=Int64(0))
        )
        return body_cursor

    if not col._validity:
        raise Error(
            "emit_validity_bitmap: null_count > 0 but no validity bitmap"
        )

    ref bitmap_ref = col._validity.value()
    var bitmap_bytes = (col._length + 7) // 8
    if bitmap_bytes > bitmap_ref.buffer.len():
        raise Error(
            "emit_validity_bitmap: bitmap.buffer.length "
            + String(bitmap_ref.buffer.len())
            + " < expected "
            + String(bitmap_bytes)
            + " for "
            + String(col._length)
            + " rows"
        )

    var aligned_cursor = _align_to_8_zero_pad[B](body, body_cursor)
    _copy_bytes_into_body[B](
        body,
        aligned_cursor,
        bitmap_ref.buffer,
        0,
        bitmap_bytes,
    )
    buffers.append(
        BufferDescriptor(
            offset=Int64(aligned_cursor), length=Int64(bitmap_bytes)
        )
    )
    return aligned_cursor + bitmap_bytes


def emit_primitive_value_buffer[
    B: BodySink
](
    col: Column[HeapRegion],
    bytes_per_element: Int,
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
) raises -> Int:
    """Emit a primitive value buffer (fixed-width element bytes).

    Reads from `col._data` starting at `col._offset * bytes_per_element`
    (zero-copy slice offset honored).

    Returns the new body_cursor.
    """
    var n = col._length
    var values_bytes = n * bytes_per_element
    var aligned_cursor = _align_to_8_zero_pad[B](body, body_cursor)
    _copy_bytes_into_body[B](
        body,
        aligned_cursor,
        col._data,
        col._offset * bytes_per_element,
        values_bytes,
    )
    buffers.append(
        BufferDescriptor(
            offset=Int64(aligned_cursor), length=Int64(values_bytes)
        )
    )
    return aligned_cursor + values_bytes


# =============================================================================
# Internal helpers
# =============================================================================


def _align_to_8(cursor: Int) -> Int:
    """Round `cursor` up to the next 8-byte boundary (Arrow body
    alignment for sub-buffer entries)."""
    return ((cursor + 7) // 8) * 8


def _align_to_8_zero_pad[
    B: BodySink
](
    mut body: B, cursor: Int
) raises -> Int:
    """Round `cursor` up to the next 8-byte boundary AND write 0-7 pad
    zero bytes at positions `[cursor, aligned_cursor)`.

    The per-RB body buffer (sized by `_estimate_body_size(columns)`, an
    over-estimate of the content) is not blanket-zeroed. Arrow spec §4
    requires the padding bytes between buffers to be 0, and every byte
    position in `[0, body_cursor)` that is NOT written by an
    `_copy_bytes_into_body` lives in the `[cursor, aligned_cursor)` gap
    of some `_align_to_8` call site. Writing 0 at exactly those positions
    in this helper (0-7 bytes per gap) costs at most `n_buffers * 7` byte
    writes instead of a memset of the whole body. Pad bytes are emitted between adjacent buffer entries,
    which is exactly what Arrow IPC spec §4 specifies for
    bodies-as-emitted (the post-loop end-of-body 0-7 pad bytes are
    handled by the `body_pad` loop in
    `encode_record_batch_message`).
    """
    var aligned = ((cursor + 7) // 8) * 8
    var pad = aligned - cursor
    if pad > 0:
        # 0-7 byte gap. Bound-checked via body.capacity in write_u8_at.
        for i in range(pad):
            body.write_u8_at(cursor + i, UInt8(0))
    return aligned


def _copy_bytes_into_body[
    B: BodySink,
    B_src: AlignedBufferTrait,
](
    mut body: B,
    cursor: Int,
    src: B_src,
    src_offset: Int,
    count: Int,
) raises:
    """Copy `count` bytes from `src[src_offset .. src_offset+count)` into
    `body[cursor .. cursor+count)`. Bounds-checks both ends.

    The copy builds a `ByteView` over the source range and lets
    `MmapAlignedBuffer.copy_from_view_at` route through libc memcpy (a
    scalar `write_u8_at` loop is not auto-vectorized, and for a wide table
    this copy is the dominant write-encoder cost). Same shape as the
    read-path memcpy slots.
    Bounds-check semantics preserved (`view_range_ro` panics on bad
    range; the explicit raise is for the caller-friendly diagnostic).
    """
    if cursor + count > body.capacity():
        raise Error(
            "_copy_bytes_into_body: cursor "
            + String(cursor)
            + " + count "
            + String(count)
            + " > body.capacity "
            + String(body.capacity())
        )
    if src_offset < 0 or src_offset + count > src.len():
        raise Error(
            "_copy_bytes_into_body: src_offset "
            + String(src_offset)
            + " + count "
            + String(count)
            + " out of src.length "
            + String(src.len())
        )
    if count > 0:
        body.copy_from_view_at(cursor, src.view_range_ro(src_offset, count))


def _estimate_column_body_size(ref col: Column[HeapRegion]) -> Int:
    """Conservative upper bound on the body bytes ONE column emits.

    Budgeting the value buffer as `n * 8` (worst-case Int64/Float64) is
    correct for fixed-width primitives but DRAMATICALLY UNDER-allocates for
    variable-length columns (BINARY / STRING / LARGE_*), whose data buffer
    is `col._data.len()` bytes — unbounded by `n * 8` (e.g. 20 rows ×
    64-byte values = 1280 bytes, vs 160). An under-allocation lets the
    encoder write past the pre-sized `AlignedBufferBodySink` capacity; with
    the release-elided bounds debug_assert that corrupts adjacent heap
    memory and can HANG a flush. Int64-only columns never show it, because
    there `n * 8` is exact.

    This sizes from the ACTUAL buffer lengths the encoder copies:
    validity bitmap + the real data buffer (`_data.len()`) + the real
    offsets buffer (`_offsets.len()` when present) + nested children —
    each rounded up for the 8-byte inter-buffer alignment padding. This
    is a true upper bound for every Arrow type the encoder handles, so
    the sink is never undersized again.
    """
    var n = col._length
    # Validity bitmap (one per node), 8-byte aligned + a pad slot.
    var total = (n + 7) // 8 + 8
    # Actual data buffer the encoder copies verbatim, + alignment pad.
    total += col._data.len() + 8
    # Actual offsets buffer (variable-length types only), + alignment pad.
    if col._offsets:
        total += col._offsets.value().len() + 8
    else:
        # Fixed-width primitives carry no offsets buffer; the value bytes
        # already live in `_data` (counted above). Keep a worst-case
        # offsets-shaped slot so any encoder that synthesizes offsets has
        # head-room.
        total += (n + 1) * 8 + 8
    # Nested children (Struct / List / etc.) contribute their own buffers.
    for ci in range(len(col._children)):
        total += _estimate_column_body_size(col._children[ci])
    return total


def _estimate_body_size(ref columns: Slab[Column[HeapRegion]]) -> Int:
    """Conservative upper bound on the RecordBatch body byte size for
    pre-allocating the body sink. Sums every column's actual buffer
    lengths (see `_estimate_column_body_size`) plus an 8-byte
    whole-body alignment pad."""
    var total = 0
    for i in range(len(columns)):
        total += _estimate_column_body_size(columns[i])
    # Whole-body 8-byte trailing pad (encode_record_batch_message appends
    # up to 7 pad bytes after the last buffer).
    total += 8
    return max(total, 64)


# =============================================================================
# encode_dictionary_batch_message_from_string_column
# =============================================================================
#
# High-level driver for the DICTIONARY message half (
# DICTIONARY-BATCH). Emits a complete IPC frame for the dictionary VALUES
# half (the INDEX half rides in the RecordBatch — see
# encode_dictionary in ipc_encoder_nested.mojo).
#
# Only STRING-valued dictionaries are supported (the only Column.from_dictionary
# variant in tree). The dict_data + dict_offsets are extracted from the
# Dictionary column's _dict_data / _offsets / _dict_size fields,
# repackaged as a synthetic 1-column STRING RecordBatch, and wrapped in
# a Message with header_tag=DictionaryBatch.
#
# Stream-level emit ordering: the DictionaryBatch frame MUST be emitted
# BEFORE the first RecordBatch that references dict_id. The FileSink
# integration handles that ordering; this driver just builds the frame.


def encode_dictionary_batch_message_from_string_column(
    dict_id: Int64,
    var dict_col: Column[HeapRegion],
    is_delta: Bool,
) raises -> SharedAlignedBuffer[HeapRegion]:
    """Encode a DictionaryBatch IPC message frame for a STRING-valued
    dictionary.

    Caller passes a synthetic Column constructed via
    `_make_string_dict_values_column(dict_col)` (or any Column whose
    _data + _offsets are the dictionary's STRING value bytes).

    Returns a complete IPC frame: [u32 0xFFFFFFFF, u32 size,
    FB(Message{header=DictionaryBatch{id, data, isDelta}}), pad, body].
    """
    # 1. Build the inner data RecordBatch: 1 STRING column whose buffers
    #    are exactly the dictionary's _offsets + _data bytes.
    #    Caller is expected to pass dict_col as a STRING-shaped Column
    #    (arrow_type=STRING, _data=value bytes, _offsets=Int32 offsets,
    #    length=dict_size).
    if dict_col.arrow_type != ArrowType.STRING:
        raise Error(
            "encode_dictionary_batch_message_from_string_column: "
            "dict_col.arrow_type must be STRING; got "
            + String(Int(dict_col.arrow_type.type_id))
            + " (only STRING-valued dictionaries are supported; pyarrow's "
            "pa.dictionary(<index>, pa.string()) maps here)"
        )

    # Build the dict's body bytes + Buffer entries + FieldNode by
    # encoding the single STRING column.
    var dict_cols = Slab[Column[HeapRegion]]()
    dict_cols.append(dict_col^)
    var dict_row_count = 0  # captured below
    # dropped the
    # `dict_body.zero()` blanket. Same rationale as
    # `encode_record_batch_message` above: every position in
    # `[0, dict_body_cursor)` is now explicitly covered by either
    # `_copy_bytes_into_body` (buffer payload) or
    # `_align_to_8_zero_pad` (0-7 byte alignment gaps).
    var dict_sink = AlignedBufferBodySink(_estimate_body_size(dict_cols))
    var dict_body_cursor: Int = 0
    var dict_buffers = List[BufferDescriptor]()
    var dict_nodes = List[FieldNode]()
    for i in range(len(dict_cols)):
        ref c = dict_cols[i]
        if i == 0:
            dict_row_count = c._length
        dict_body_cursor = encode_column[AlignedBufferBodySink](
            c, dict_sink, dict_body_cursor, dict_buffers, dict_nodes
        )

    # Pad the body
    # to an 8-byte boundary per Arrow IPC spec §4.
    var dict_body_pad = (8 - (dict_body_cursor % 8)) % 8
    if dict_body_pad > 0:
        for _ in range(dict_body_pad):
            dict_sink.write_u8_at(dict_body_cursor, UInt8(0))
            dict_body_cursor += 1

    var dict_body = dict_sink.finalize()

    # 2. Build the FB metadata: RecordBatch table → DictionaryBatch
    #    table → Message wrapper.
    var w = FlatbufWriter(2048)
    var rb_pos = write_record_batch(
        w, Int64(dict_row_count), dict_nodes, dict_buffers
    )
    var db_pos = write_dictionary_batch(w, dict_id, rb_pos, is_delta)
    var msg_pos = write_message(
        w,
        Int16(4),  # MetadataVersion.V5
        MESSAGE_HEADER_DICTIONARY_BATCH,
        db_pos,
        Int64(dict_body_cursor),
    )
    var fb_payload = w^.finalize(msg_pos)

    # 3. Wrap in IPC outer frame.
    var w2 = FlatbufWriter(64)
    var body_span = dict_body.view_range_ro(0, dict_body_cursor).into_span()
    var frame = write_ipc_message(w2, fb_payload^, body_span, True)
    _ = dict_body^  # keep alive until span consumed
    return frame^


def make_string_dict_values_column_from_dictionary(
    var dict_col: Column[HeapRegion],
) raises -> Column[HeapRegion]:
    """Helper: build a STRING-shaped Column[HeapRegion] whose buffers are the
    dictionary VALUES half of a `Column.from_dictionary(...)` column.

    Storage layout of a DICTIONARY `Column`:
      dict_col._offsets: Int32 dictionary string offsets (dict_size + 1)
      dict_col._dict_data: dictionary string bytes
      dict_col._dict_size: number of unique dictionary entries

    Returned column: arrow_type=STRING, length=dict_size, _data=dict_bytes,
    _offsets=dict_offsets. Used as input to
    `encode_dictionary_batch_message_from_string_column`.
    """
    if dict_col.arrow_type != ArrowType.DICTIONARY:
        raise Error(
            "make_string_dict_values_column_from_dictionary: input must "
            "have arrow_type=DICTIONARY; got "
            + String(Int(dict_col.arrow_type.type_id))
        )
    if not dict_col._dict_data:
        raise Error(
            "make_string_dict_values_column_from_dictionary: dict_col "
            "has no _dict_data (dictionary values missing)"
        )
    if not dict_col._offsets:
        raise Error(
            "make_string_dict_values_column_from_dictionary: dict_col "
            "has no _offsets (dictionary string offsets missing)"
        )

    # Move the dict_data + offsets buffers into a fresh STRING Column.
    # NOTE: this CONSUMES dict_col (var); the original Column is
    # invalidated. Caller can pass a deep_copy if they need to retain it.
    var dict_data_buf = dict_col._dict_data.take()
    var dict_offsets_buf = dict_col._offsets.take()
    return Column[HeapRegion](
        arrow_type=ArrowType.STRING,
        data=dict_data_buf^,
        offsets=dict_offsets_buf^,
        validity=None,
        length=dict_col._dict_size,
        null_count=0,
        offset=0,
    )


def slice_string_values_column(
    values_col: Column[HeapRegion], lo: Int, hi: Int
) raises -> Column[HeapRegion]:
    """Slice a STRING-typed values Column[HeapRegion] to entries `[lo..hi)`.



    Builds a fresh STRING Column carrying ONLY the entries
    `[lo..hi)` (zero-indexed, half-open). Used by the FileSink dict-
    isDelta emit path to produce a DictionaryBatch frame whose body
    carries only the NEW entries appended to a previously-emitted
    dictionary (Arrow spec isDelta=True semantic).

    The returned Column owns fresh buffers (offsets re-based to start
    at 0 + a slab-sliced data buffer). The input is borrowed.

    Raises if:
      - `values_col.arrow_type` is not STRING
      - `lo` or `hi` is out of range, or `lo > hi`
    """
    if values_col.arrow_type != ArrowType.STRING:
        raise Error(
            "slice_string_values_column: values_col.arrow_type must "
            "be STRING; got "
            + String(Int(values_col.arrow_type.type_id))
        )
    if not values_col._offsets:
        raise Error(
            "slice_string_values_column: values_col missing offsets "
            "buffer (expected STRING values column with Int32 offsets)"
        )
    var total = values_col._length
    if lo < 0 or hi < lo or hi > total:
        raise Error(
            "slice_string_values_column: range out of bounds: lo="
            + String(lo)
            + ", hi="
            + String(hi)
            + ", total="
            + String(total)
        )

    var new_len = hi - lo
    ref src_offs = values_col._offsets.value()
    # Read the byte-range covered by entries [lo..hi).
    var byte_lo = Int(src_offs.read_i32_le_at(lo * 4))
    var byte_hi = Int(src_offs.read_i32_le_at(hi * 4))
    var data_bytes = byte_hi - byte_lo

    # Fresh offsets buffer: new_len + 1 slots, re-based to start at 0.
    var new_off_bytes = (new_len + 1) * 4
    var new_off = OwnedAlignedBuffer(max(new_off_bytes, 4))
    new_off.zero()
    new_off.set_length(Int64(new_off_bytes))

    for i in range(new_len + 1):
        var v = Int32(
            Int(src_offs.read_i32_le_at((lo + i) * 4)) - byte_lo
        )
        new_off.write_i32_le_at(i * 4, v)

    # Fresh data buffer: copy bytes [byte_lo..byte_hi) from src.
    var new_data = OwnedAlignedBuffer(max(data_bytes, 1))
    if data_bytes > 0:
        new_data.copy_from_view(
            values_col._data.view_range_ro(byte_lo, data_bytes)
        )
    new_data.set_length(Int64(data_bytes))


    return Column[HeapRegion](
        arrow_type=ArrowType.STRING,
        data=new_data^,
        offsets=new_off^,
        validity=None,
        length=new_len,
        null_count=0,
        offset=0,
    )


def string_values_prefix_matches(
    values_col: Column[HeapRegion], prior: Column[HeapRegion], prefix_len: Int
) raises -> Bool:
    """Test whether the first `prefix_len` entries of two STRING values
    columns are byte-identical.



    Used by the FileSink dict-isDelta emit path to verify that a later
    batch's dict is a strict SUPERSET of the previously-emitted dict
    (Arrow spec requires preservation of the first N entries when
    isDelta=True semantic is used). Returns False if:
      - either column is too short to cover `prefix_len`
      - any entry byte-disagrees in the prefix

    The arrow_type of both inputs MUST be STRING.
    """
    if (
        values_col.arrow_type != ArrowType.STRING
        or prior.arrow_type != ArrowType.STRING
    ):
        raise Error(
            "string_values_prefix_matches: both inputs must be STRING; "
            "got "
            + String(Int(values_col.arrow_type.type_id))
            + " and "
            + String(Int(prior.arrow_type.type_id))
        )
    if prefix_len < 0:
        raise Error("string_values_prefix_matches: prefix_len < 0")
    if values_col._length < prefix_len or prior._length < prefix_len:
        return False
    if not values_col._offsets or not prior._offsets:
        raise Error(
            "string_values_prefix_matches: missing offsets on inputs"
        )
    ref va = values_col._offsets.value()
    ref vb = prior._offsets.value()
    for i in range(prefix_len):
        var a_lo = Int(va.read_i32_le_at(i * 4))
        var a_hi = Int(va.read_i32_le_at((i + 1) * 4))
        var b_lo = Int(vb.read_i32_le_at(i * 4))
        var b_hi = Int(vb.read_i32_le_at((i + 1) * 4))
        if (a_hi - a_lo) != (b_hi - b_lo):
            return False
        var run = a_hi - a_lo
        for k in range(run):
            if (
                values_col._data.read_u8_at(a_lo + k)
                != prior._data.read_u8_at(b_lo + k)
            ):
                return False
    return True


# =============================================================================
# encode_schema_message — Schema → Arrow IPC Schema message frame
# =============================================================================
#
# Symmetric to `encode_record_batch_message`: takes a `Schema` and emits one
# complete IPC Schema message frame
# [u32 0xFFFFFFFF, u32 metadata_size, FB(Message{header=Schema}), pad,
#  body=empty(0 bytes)] suitable for prepending to an Arrow IPC stream.
#
# The Schema message is ALWAYS the first message in an Arrow
# IPC stream. Schema messages have `bodyLength=0` (no per-column buffer
# bytes — those ride in the RecordBatch messages that follow).
#
# ⛔ COVERAGE: THE TWO LEGS DO NOT AGREE. More types are BODY-encodable
# (`encode_column`) than SCHEMA-writable (`_write_type_for_arrow_type`); a
# stream can carry only the intersection. The body-encodable but
# schema-REFUSED types are FIXED_SIZE_BINARY, LIST, LARGE_LIST,
# FIXED_SIZE_LIST, STRUCT, MAP, UNION_SPARSE, UNION_DENSE: a column of any
# of them encodes its BUFFERS fine and then has no Field to ride in. They all
# need CHILDREN in the Field rather than two integers, which is a materially
# larger arm.
#
# ⚠ THE DECIMAL ARM IS CONDITIONAL, which no other writable id is: a
# decimal Field that states no precision is STILL refused, by the arm rather
# than by the catch-all. "Writable" therefore means "writable when the Field
# carries its parameters" for DECIMAL128 / DECIMAL256.
#
# ⚠ DO NOT RE-DERIVE THE COUNTS BY READING THIS CASCADE. The IPC type
# census test computes them from the two dispatchers themselves and is red
# in BOTH directions — red when a type stops encoding AND red on good news
# when one starts.
#
# When ArrowIpcCompression.ARROW_IPC_CODEC_ID
# == -1 (Uncompressed), the Schema metadata does NOT carry a
# BodyCompression hint — the per-batch RecordBatch table is what carries
# (or omits) the codec. The Schema message stays codec-agnostic.
# =============================================================================


def _write_type_for_arrow_type(
    mut w: FlatbufWriter, schema: Schema, index: Int
) raises -> Tuple[Int, UInt8]:
    """Map field `index` of `schema` to (type_table_pos, ipc_type_tag).

    Cascades over the active ArrowType set, calling the matching
    `write_type_*` helper. Returns the FB position of the Type table +
    the IPC type discriminator (TYPE_INT / TYPE_UTF8 / ...).

    ★ IT TAKES A FIELD, NOT A TYPE. The four TIMESTAMP arms must write the
    field's TIMEZONE (`Schema.field_tz`; the parquet reader sets `tz="UTC"`
    for `isAdjustedToUTC`), which a bare `ArrowType` cannot carry. Writing
    `""` instead would hand every foreign Arrow consumer a TZ-NAIVE column:
    an instant relabelled as wall-clock, wrong by the UTC offset, with no
    error anywhere — and a Mojo decoder round-trip would not notice, since
    it reads the same `""` back.

    ⚠ NOTHING ELSE MAY READ `t` FROM THE ARGUMENT LIST AGAIN. The whole
    point of taking `(schema, index)` is that the remaining per-FIELD
    parameters this function still cannot express — FIXED_SIZE_BINARY's byte
    width, UNION's `field_union_type_ids` — are now one accessor away rather
    than one signature change away. Those types are still REFUSED below; they
    are refused because the arms are unwritten, not because the data is
    unreachable.

    ⭐ DECIMAL WAS ON THAT LIST AND CAME OFF IT. Its arm reads
    `field_decimal_precision` / `_scale` straight off the field — the payoff
    the paragraph above was written to predict, and the reason the signature
    change is worth more than the timezone it was made for.

    Coverage: primitives (Int*, UInt*, Float*, Bool, Null), var-len
    (String, Binary, LargeString, LargeBinary), Date/Time/
    Timestamp/Duration/Interval, Dictionary, Decimal128/256. Nested +
    FixedSize* are refused. The IPC type census test is the falsifier for
    exactly which ids fall on each side, in both directions.
    """
    var t = schema.field_arrow_type(index)
    # ★ THE FIELD'S TIMEZONE. "" for every non-Timestamp field (and for a
    # NAIVE Timestamp), which is the Arrow sentinel `write_type_timestamp`
    # already understood — it has taken a `timezone` argument since it was
    # written and every caller passed the empty literal.
    var tz = schema.field_tz(index)

    # --- Integer types (signed + unsigned) ---
    if t == ArrowType.INT8:
        return (write_type_int(w, 8, True), TYPE_INT)
    if t == ArrowType.INT16:
        return (write_type_int(w, 16, True), TYPE_INT)
    if t == ArrowType.INT32:
        return (write_type_int(w, 32, True), TYPE_INT)
    if t == ArrowType.INT64:
        return (write_type_int(w, 64, True), TYPE_INT)
    if t == ArrowType.UINT8:
        return (write_type_int(w, 8, False), TYPE_INT)
    if t == ArrowType.UINT16:
        return (write_type_int(w, 16, False), TYPE_INT)
    if t == ArrowType.UINT32:
        return (write_type_int(w, 32, False), TYPE_INT)
    if t == ArrowType.UINT64:
        return (write_type_int(w, 64, False), TYPE_INT)

    # --- Float types ---
    if t == ArrowType.FLOAT16:
        return (
            write_type_floating_point(w, Int(PRECISION_HALF)),
            TYPE_FLOATING_POINT,
        )
    if t == ArrowType.FLOAT32:
        return (
            write_type_floating_point(w, Int(PRECISION_SINGLE)),
            TYPE_FLOATING_POINT,
        )
    if t == ArrowType.FLOAT64:
        return (
            write_type_floating_point(w, Int(PRECISION_DOUBLE)),
            TYPE_FLOATING_POINT,
        )

    # --- Bool / Null ---
    if t == ArrowType.BOOL:
        return (write_type_bool(w), TYPE_BOOL)
    if t == ArrowType.NULL:
        return (write_type_null(w), TYPE_NULL)

    # --- Variable-length byte arrays ---
    if t == ArrowType.STRING:
        return (write_type_utf8(w), TYPE_UTF8)
    if t == ArrowType.BINARY:
        return (write_type_binary(w), TYPE_BINARY)
    if t == ArrowType.LARGE_STRING:
        return (write_type_large_utf8(w), TYPE_LARGE_UTF8)
    if t == ArrowType.LARGE_BINARY:
        return (write_type_large_binary(w), TYPE_LARGE_BINARY)

    # --- Temporal: Date / Time / Timestamp / Duration / Interval ---
    if t == ArrowType.DATE32:
        return (write_type_date(w, DATE_UNIT_DAY), TYPE_DATE)
    if t == ArrowType.DATE64:
        return (write_type_date(w, DATE_UNIT_MILLISECOND), TYPE_DATE)
    if t == ArrowType.TIME32_S:
        return (write_type_time(w, TIME_UNIT_SECOND, 32), TYPE_TIME)
    if t == ArrowType.TIME32_MS:
        return (write_type_time(w, TIME_UNIT_MILLISECOND, 32), TYPE_TIME)
    if t == ArrowType.TIME64_US:
        return (write_type_time(w, TIME_UNIT_MICROSECOND, 64), TYPE_TIME)
    if t == ArrowType.TIME64_NS:
        return (write_type_time(w, TIME_UNIT_NANOSECOND, 64), TYPE_TIME)
    # ★ ALL FOUR TIMESTAMP ARMS PASS `tz`, NOT `""`. See the docstring: the
    # empty literal here was a wrong-answer class, not a TODO.
    if t == ArrowType.TIMESTAMP_S:
        return (
            write_type_timestamp(w, TIME_UNIT_SECOND, tz),
            TYPE_TIMESTAMP,
        )
    if t == ArrowType.TIMESTAMP_MS:
        return (
            write_type_timestamp(w, TIME_UNIT_MILLISECOND, tz),
            TYPE_TIMESTAMP,
        )
    if t == ArrowType.TIMESTAMP_US or t == ArrowType.TIMESTAMP:
        return (
            write_type_timestamp(w, TIME_UNIT_MICROSECOND, tz),
            TYPE_TIMESTAMP,
        )
    if t == ArrowType.TIMESTAMP_NS:
        return (
            write_type_timestamp(w, TIME_UNIT_NANOSECOND, tz),
            TYPE_TIMESTAMP,
        )
    if t == ArrowType.DURATION_S:
        return (write_type_duration(w, TIME_UNIT_SECOND), TYPE_DURATION)
    if t == ArrowType.DURATION_MS:
        return (write_type_duration(w, TIME_UNIT_MILLISECOND), TYPE_DURATION)
    if t == ArrowType.DURATION_US:
        return (write_type_duration(w, TIME_UNIT_MICROSECOND), TYPE_DURATION)
    if t == ArrowType.DURATION_NS:
        return (write_type_duration(w, TIME_UNIT_NANOSECOND), TYPE_DURATION)
    if t == ArrowType.INTERVAL_YEAR_MONTH:
        return (
            write_type_interval(w, INTERVAL_UNIT_YEAR_MONTH),
            TYPE_INTERVAL,
        )
    if t == ArrowType.INTERVAL_DAY_TIME:
        return (write_type_interval(w, INTERVAL_UNIT_DAY_TIME), TYPE_INTERVAL)
    if t == ArrowType.INTERVAL_MONTH_DAY_NANO:
        return (
            write_type_interval(w, INTERVAL_UNIT_MONTH_DAY_NANO),
            TYPE_INTERVAL,
        )

    # --- Decimal (fixed-point) ---
    #
    # ★ THE ONE PLACE THE `(schema, index)` SIGNATURE PAYS FOR ITSELF TWICE.
    # The docstring above says the still-refused types "are refused because the
    # arms are unwritten, not because the data is unreachable"; this is that
    # sentence being cashed. `Decimal{precision, scale, bitWidth}` needs two
    # per-FIELD integers, and a signature without `(schema, index)` has no
    # way to ask for them — the same structural reason a TIMESTAMP arm would
    # write `""` for its timezone.
    #
    # ⛔ AND THERE IS NO DEFAULT. Arrow does not define one — `pa.decimal128()`
    # takes precision positionally — so a Field that states no precision is not
    # an under-specified decimal, it is not a decimal. The refusal below is
    # therefore NOT a leftover of the unwritten arm; it is the arm's answer for
    # an input that cannot be expressed, and it must stay.
    #
    # ⛔⛔ THE ONE FIX THAT IS FORBIDDEN HERE IS THE ONE THAT PRODUCES BYTES:
    # inventing a precision, or falling through to FLOAT64. `12352.5315` is
    # unscaled 123525315 at scale 4, exact in an i128 and NOT representable in
    # a float64; a widening conversion egresses a value that is WRONG with no
    # error anywhere, for a product whose decimal users are the ones who care.
    # An empty stream beside a numbered refusal is strictly better than that.
    #
    # The BODY halves (`encode_decimal128` / `encode_decimal256`, 16- and
    # 32-byte little-endian slabs + validity) have shipped since
    # only the Field was missing, which is why a decimal column could encode
    # its buffers and still have nothing to ride in.
    if t == ArrowType.DECIMAL128 or t == ArrowType.DECIMAL256:
        var is128 = t == ArrowType.DECIMAL128
        var bit_width = 128 if is128 else 256
        # The same ceilings `Field.decimal128` / `Field.decimal256` enforce at
        # construction. Re-checked here because a Schema can also arrive over
        # the plan wire or out of the 4-arg `Schema.__init__`, which ZERO-FILLS
        # the decimal slots — the exact path that would otherwise write
        # `precision=0` and call it a decimal.
        var max_p = 38 if is128 else 76
        var p = schema.field_decimal_precision(index)
        var s = schema.field_decimal_scale(index)
        if p < 1 or p > max_p or s < 0 or s > p:
            # ⚠ BOTH SUBSTRINGS BELOW ARE LOAD-BEARING, for the reasons the
            # catch-all's own comment gives: callers re-code on the
            # `_write_type_for_arrow_type:` prefix, while the IPC type census
            # test reads the numeric id to tell a NAMED refusal from an
            # anonymous one.
            raise Error(
                "_write_type_for_arrow_type: ArrowType type_id "
                + String(Int(t.type_id))
                + " (field "
                + String(index)
                + ", '"
                + schema.field_name(index)
                + "') carries precision "
                + String(p)
                + " / scale "
                + String(s)
                + ", which is not a valid Decimal"
                + String(bit_width)
                + " (need 1 <= precision <= "
                + String(max_p)
                + " and 0 <= scale <= precision). Arrow defines NO default"
                + " precision, so this is refused rather than guessed — a"
                + " guessed scale moves every value's decimal point silently."
            )
        return (write_type_decimal(w, p, s, bit_width), TYPE_DECIMAL)

    # DICTIONARY arm — lossy-expand-to-STRING contract.
    # The Field.type union carries the dictionary VALUES type (STRING
    # for v1; pyarrow's pa.dictionary(<index>, pa.string()) shape), and
    # the dict-encoding metadata (id + indexType + isOrdered) rides in
    # the Field.dictionary slot which `encode_schema_message` populates
    # separately via `write_dictionary_encoding`. Other values types are
    # not written.
    if t == ArrowType.DICTIONARY:
        return (write_type_utf8(w), TYPE_UTF8)

    # ⚠ THE STRING `_write_type_for_arrow_type` IS LOAD-BEARING IN THIS
    # MESSAGE. A plan-execution endpoint re-codes an encoder failure to
    # PLAN_ENDPOINT_UNSUPPORTED_ARROW_TYPE(16) only when the message names
    # an unwritable TYPE, and its gate greps stderr for this identifier so a
    # BLANKET re-code cannot pass as a narrow one. Renaming this function
    # means updating both.
    raise Error(
        "_write_type_for_arrow_type: ArrowType type_id "
        + String(Int(t.type_id))
        + " (field "
        + String(index)
        + ", '"
        + schema.field_name(index)
        + "') not yet wired in the Schema-message encoder (covers "
        + "primitives + var-len + temporal + DICTIONARY + DECIMAL128/256; "
        + "Nested / FixedSize are not)."
    )


def encode_schema_message(schema: Schema) raises -> SharedAlignedBuffer[HeapRegion]:
    """Encode a `Schema` as one Arrow IPC Schema message frame.

    Output: [u32 0xFFFFFFFF, u32 size, FB(Message{header=Schema, bodyLength=0}),
             pad]. Body is empty (Schema messages carry no per-batch bytes).

    The frame is suitable for passing to a `WritableHandle.write_all`
    call as the FIRST message of a stream-format Arrow IPC byte sequence.
    RecordBatch messages produced by `encode_record_batch_message` follow.

    The stream layout is:
        [Schema message] [RecordBatch message]* [EOS marker]

    Symmetric to `encode_record_batch_message`. Schema-level metadata
    (custom KeyValue pairs on the Schema, per-field metadata) is NOT
    emitted.
    """
    var n_fields = schema.num_columns()
    var w = FlatbufWriter(2048)

    # Build each Field table; collect their FB positions.
    var field_positions = List[Int]()
    for i in range(n_fields):
        var arrow_type = schema.field_arrow_type(i)
        var nullable = schema.field_nullable(i)
        var name = schema.field_name(i)
        # Write the Type variant table FIRST so its position is known
        # before write_field consumes it.
        # ⚠ `(schema, i)`, NOT `(arrow_type)` — the Type table needs the
        # FIELD's parameters (timezone today; precision/scale/width when
        # those arms land), and passing only the tag is what dropped every
        # tz on the floor. See `_write_type_for_arrow_type`'s docstring.
        var type_pair = _write_type_for_arrow_type(w, schema, i)
        # For DICTIONARY-typed fields, additionally emit the
        # DictionaryEncoding inner table + pass its position to
        # write_field slot 4. dict_id = Int64(column_index)
        # (deterministic mapping).
        #
        var dict_pos = -1
        if arrow_type == ArrowType.DICTIONARY:
            var idx_type = schema.field_dict_index_type(i)
            # INT8/16/32/64 → bit_width + signed (the Field carries the
            # index type; emits whatever Field.dictionary() factory
            # captured, defaulting to INT32 signed).
            var idx_bw = 32
            var idx_signed = True
            if idx_type == ArrowType.INT8:
                idx_bw = 8
            elif idx_type == ArrowType.INT16:
                idx_bw = 16
            elif idx_type == ArrowType.INT64:
                idx_bw = 64
            # ARROW_FLAG_DICTIONARY_ORDERED bit on Field._flags maps to
            # DictionaryEncoding.isOrdered (bit 1).
            var flags = schema.field_flags(i)
            var is_ordered = (flags & Int64(1)) != Int64(0)
            dict_pos = write_dictionary_encoding(
                w,
                Int64(i),  # dict_id = column index (deterministic v1)
                idx_bw,
                idx_signed,
                is_ordered,
            )
        var field_pos = write_field(
            w, name, nullable, type_pair[1], type_pair[0],
            dictionary_pos=dict_pos,
        )
        field_positions.append(field_pos)

    # Write Schema table referencing all field positions.
    var schema_pos = write_schema(w, ENDIANNESS_LITTLE, field_positions)

    # Wrap in Message{header=Schema, bodyLength=0}.
    var msg_pos = write_message(
        w,
        Int16(Int(METADATA_VERSION_V5)),
        MESSAGE_HEADER_SCHEMA,
        schema_pos,
        Int64(0),  # bodyLength = 0 for Schema messages
    )
    var fb_payload = w^.finalize(msg_pos)

    # Wrap in IPC outer frame with empty body bytes.
    var w2 = FlatbufWriter(64)
    var empty_body = SharedAlignedBuffer[HeapRegion].heap_owned(1)
    empty_body.set_length(0)

    var body_span = empty_body.view_range_ro(0, 0).into_span()
    var frame = write_ipc_message(w2, fb_payload^, body_span, True)
    _ = empty_body^
    return frame^


# =============================================================================
# Arrow IPC stream EOS marker
# =============================================================================
#
# Stream-format Arrow IPC terminates with 8 bytes:
#     [u32 0xFFFFFFFF, u32 0x00000000]
# Continuation marker + zero metadata-size = "no more messages". The
# canonical reader stops walking after seeing these 8 bytes.
# =============================================================================


def arrow_ipc_eos_bytes() -> SharedAlignedBuffer[HeapRegion]:
    """Return an 8-byte buffer holding the Arrow IPC Stream EOS marker.

    Caller passes the bytes to `WritableHandle.write_all` as the LAST
    write of an Arrow IPC stream.
    """
    var buf = SharedAlignedBuffer[HeapRegion].heap_owned(8)
    buf.zero()
    # u32 0xFFFFFFFF at offset 0 (LE).
    buf.write_u32_le_at(0, UInt32(0xFFFFFFFF))
    # u32 0x00000000 at offset 4 (LE) — already zeroed.
    buf.set_length(8)

    return buf^


# =============================================================================
# Arrow IPC File-format helpers
# =============================================================================
#
# The Arrow File ("Feather v2") wire grammar:
#
#   [ARROW1 magic: 6 bytes "ARROW1" + 2 bytes padding = 8 bytes]
#   [Schema message frame]                  <- same as Stream
#   [DictionaryBatch message frame] *       <- same as Stream
#   [RecordBatch message frame] *           <- same as Stream
#   <NO EOS marker in File format>
#   [Footer flatbuffer]
#   [i32 footer_length LE]
#   [ARROW1 magic trailer: 6 bytes]
#
# Key difference vs Stream format:
#   - leading 8-byte ARROW1\0\0 magic header
#   - NO EOS marker terminator
#   - trailing Footer flatbuffer + i32 length + 6-byte ARROW1 magic
#
# The Footer holds two `[Block]` struct vectors (offsets + meta-data
# lengths + body lengths) for random-access reads of the record-batch
# and dictionary-batch messages embedded in the file.
# =============================================================================


# ARROW1 magic bytes. 6 bytes "ARROW1" per spec. Header has 2 trailing
# pad bytes (to keep the first message 8-aligned); trailer is 6 bytes only.
comptime ARROW1_MAGIC_LEN: Int = 6
comptime ARROW1_HEADER_LEN: Int = 8  # 6 magic + 2 pad


def arrow_ipc_file_magic_header() -> SharedAlignedBuffer[HeapRegion]:
    """Return the 8-byte Arrow File header: 6 bytes 'ARROW1' + 2 pad bytes.

    The Arrow File format begins with the magic
    string 'ARROW1' (6 bytes) padded to 8 bytes so the first Message
    frame that follows starts on an 8-byte boundary.
    """
    var buf = SharedAlignedBuffer[HeapRegion].heap_owned(ARROW1_HEADER_LEN)
    buf.zero()
    # 'A' = 0x41, 'R' = 0x52, 'R' = 0x52, 'O' = 0x4F, 'W' = 0x57, '1' = 0x31
    buf.write_u8_at(0, UInt8(0x41))  # 'A'
    buf.write_u8_at(1, UInt8(0x52))  # 'R'
    buf.write_u8_at(2, UInt8(0x52))  # 'R'
    buf.write_u8_at(3, UInt8(0x4F))  # 'O'
    buf.write_u8_at(4, UInt8(0x57))  # 'W'
    buf.write_u8_at(5, UInt8(0x31))  # '1'
    # bytes 6..7 are 2 pad zero bytes (already zeroed by buf.zero()).
    buf.set_length(ARROW1_HEADER_LEN)

    return buf^


def arrow_ipc_file_magic_trailer() -> SharedAlignedBuffer[HeapRegion]:
    """Return the 6-byte Arrow File trailer: 'ARROW1'.

    The Arrow File ends with: [Footer bytes][i32
    footer_length][6 bytes 'ARROW1']. No padding — the trailing magic
    is exactly 6 bytes.
    """
    var buf = SharedAlignedBuffer[HeapRegion].heap_owned(ARROW1_MAGIC_LEN)
    buf.zero()
    buf.write_u8_at(0, UInt8(0x41))  # 'A'
    buf.write_u8_at(1, UInt8(0x52))  # 'R'
    buf.write_u8_at(2, UInt8(0x52))  # 'R'
    buf.write_u8_at(3, UInt8(0x4F))  # 'O'
    buf.write_u8_at(4, UInt8(0x57))  # 'W'
    buf.write_u8_at(5, UInt8(0x31))  # '1'
    buf.set_length(ARROW1_MAGIC_LEN)

    return buf^


def arrow_ipc_message_metadata_length(frame: SharedAlignedBuffer[HeapRegion]) raises -> Int32:
    """Extract the `metaDataLength` Block field for a complete Arrow IPC
    message frame.

    A v0.15+ frame layout is:
        [u32 0xFFFFFFFF][u32 fb_aligned_size][FB payload pad][body bytes]
    The Block.metaDataLength per Arrow File spec §1.5 is the byte count
    from message-offset to end of FB metadata INCLUDING the continuation
    marker + size prefix + the FB padding to 8-byte alignment. For a
    v0.15+ frame, that's `4 (continuation) + 4 (size_u32) + fb_aligned`
    = `8 + fb_aligned`.

    Reads the `fb_aligned` u32 at byte offset 4 of the frame.
    """
    if frame.len() < 8:
        raise Error(
            "arrow_ipc_message_metadata_length: frame too short ("
            + String(frame.len())
            + " bytes, need >= 8)"
        )
    var fb_aligned = Int(frame.read_u32_le_at(4))
    return Int32(8 + fb_aligned)


def encode_footer_message(
    schema: Schema,
    var dictionary_blocks: List[Block],
    var record_batch_blocks: List[Block],
) raises -> SharedAlignedBuffer[HeapRegion]:
    """Encode an Arrow File-format Footer + i32 length + 6-byte ARROW1
    trailer as one SharedAlignedBuffer[HeapRegion].

    The Footer is a FlatBuffer table:
        Footer {
            0: version: MetadataVersion (i16; V5)
            1: schema: Schema (re-emitted from stream's first message)
            2: dictionaries: [Block] (vector of inline 24-byte structs)
            3: recordBatches: [Block] (vector of inline 24-byte structs)
            4: custom_metadata: [KeyValue] (skipped)
        }

    The output bytes follow the wire layout at the END of an Arrow File:
        [Footer flatbuffer bytes]
        [i32 footer_length LE]    # byte count of the Footer flatbuffer
        [6 bytes 'ARROW1']         # trailer magic

    `dictionary_blocks` lists the DictionaryBatch blocks (may be `[]`).
    `record_batch_blocks` is
    the per-batch positions accumulated during the write loop.

    Output is the EXACT tail to append after the last RecordBatch
    message frame; the writer prepends ARROW1 header (8 bytes) +
    Schema/RecordBatch frames separately.
    """
    # Build the Footer flatbuffer.
    #
    # The
    # Footer flatbuffer carries:
    #   - A re-emitted Schema table (per-field name + type table +
    #     optional DictionaryEncoding); empirically ~80-120 bytes per
    #     simple field, up to ~256 for DICTIONARY-typed fields. Use
    #     384 bytes / field as a comfortable upper bound (header +
    #     Schema table + Endianness + custom_metadata vec stub).
    #   - Two `[Block]` vectors (`dictionaries` + `recordBatches`).
    #     Each Block is 24 bytes inline + ~4 bytes vec overhead.
    #   - Footer table itself (version i16 + 3 offsets + vtable) plus
    #     trailer scratch (i32 length + 6-byte ARROW1 magic).
    #
    # A capacity hard-coded to 2048 is fine for
    # `len(record_batch_blocks) == 1` but overflows at N>~10 Block
    # entries (89 entries × 24 = 2136 B for the recordBatches vector
    # alone, before schema/footer).
    #
    # The formula scales linearly with both schema width and the
    # total Block count, with a generous 4 KB minimum floor so small
    # files (single-RB / few-field) never regress through the cap
    # shrink path. MmapAlignedBuffer.reserve in Mojo 1.0.0b1 is
    # destructive (no copy-preserving grow), so the writer's
    # `_ensure_capacity` raises on overflow — making the pre-allocation
    # the load-bearing safety boundary.
    var n_fields_est = schema.num_columns()
    var n_blocks_total = len(dictionary_blocks) + len(record_batch_blocks)
    var per_field_overhead = 384
    var per_block_overhead = 32  # 24 inline + ~8 padding / vec slack
    var trailer_scratch = 256
    var fb_capacity = (
        trailer_scratch
        + n_fields_est * per_field_overhead
        + n_blocks_total * per_block_overhead
    )
    if fb_capacity < 4096:
        fb_capacity = 4096
    var w = FlatbufWriter(fb_capacity)

    # Re-emit the Schema (referenced by Footer.schema offset). Mirrors
    # `encode_schema_message`'s body but stops at write_schema — the
    # Footer table wraps the Schema directly without a Message frame.
    # The Footer's Schema must mirror the stream's Schema-message bit-for-
    # bit including DictionaryEncoding slots for DICTIONARY-typed fields
    # — otherwise pyarrow's File-mode reader sees inconsistent dict
    # metadata between Schema-message and Footer.schema. Same dict_id =
    # column_index deterministic mapping.
    var n_fields = schema.num_columns()
    var field_positions = List[Int]()
    for i in range(n_fields):
        var arrow_type = schema.field_arrow_type(i)
        var nullable = schema.field_nullable(i)
        # ⚠ SAME CALL SHAPE AS `encode_schema_message` ABOVE, AND IT MUST
        # STAY THAT WAY: pyarrow's File-mode reader compares the Footer's
        # Schema against the stream's Schema message, so a timezone written
        # in one and not the other is an INCONSISTENT file rather than a
        # merely lossy one.
        var name = schema.field_name(i)
        var type_pair = _write_type_for_arrow_type(w, schema, i)
        var dict_pos = -1
        if arrow_type == ArrowType.DICTIONARY:
            var idx_type = schema.field_dict_index_type(i)
            var idx_bw = 32
            var idx_signed = True
            if idx_type == ArrowType.INT8:
                idx_bw = 8
            elif idx_type == ArrowType.INT16:
                idx_bw = 16
            elif idx_type == ArrowType.INT64:
                idx_bw = 64
            var flags = schema.field_flags(i)
            var is_ordered = (flags & Int64(1)) != Int64(0)
            dict_pos = write_dictionary_encoding(
                w,
                Int64(i),
                idx_bw,
                idx_signed,
                is_ordered,
            )
        var field_pos = write_field(
            w, name, nullable, type_pair[1], type_pair[0],
            dictionary_pos=dict_pos,
        )
        field_positions.append(field_pos)

    var schema_pos = write_schema(w, ENDIANNESS_LITTLE, field_positions)

    # Build Footer table referencing schema + block vectors.
    var footer_pos = write_footer(
        w,
        Int16(Int(METADATA_VERSION_V5)),
        schema_pos,
        dictionary_blocks^,
        record_batch_blocks^,
    )
    var fb_payload = w^.finalize(footer_pos)
    var fb_size = fb_payload.len()

    # Assemble final tail bytes: [Footer FB][i32 footer_length][ARROW1].
    var trailer_size = fb_size + 4 + ARROW1_MAGIC_LEN
    var out = SharedAlignedBuffer[HeapRegion].heap_owned(trailer_size)
    out.zero()
    var pos = 0
    # Footer flatbuffer bytes.
    for i in range(fb_size):
        out.write_u8_at(pos + i, fb_payload.read_u8_at(i))
    pos += fb_size
    # i32 footer_length LE — the byte count of the Footer flatbuffer
    # ONLY (NOT including the i32 itself or the trailer magic). Arrow
    # readers consume this i32 to seek back to the Footer's start.
    out.write_u32_le_at(pos, UInt32(fb_size))
    pos += 4
    # 'ARROW1' trailer (6 bytes).
    out.write_u8_at(pos + 0, UInt8(0x41))  # 'A'
    out.write_u8_at(pos + 1, UInt8(0x52))  # 'R'
    out.write_u8_at(pos + 2, UInt8(0x52))  # 'R'
    out.write_u8_at(pos + 3, UInt8(0x4F))  # 'O'
    out.write_u8_at(pos + 4, UInt8(0x57))  # 'W'
    out.write_u8_at(pos + 5, UInt8(0x31))  # '1'

    out.set_length(trailer_size)

    _ = fb_payload^
    return out^
