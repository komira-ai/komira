# =============================================================================
# ipc_decoder_dispatch.mojo — Per-DType decoder dispatch (RecordBatch read path)
# Symmetric read path to encoder
# =============================================================================
#
# Decodes Arrow IPC RecordBatch message bytes back into a `List[Column]`.
# The driver is the inverse of `encode_record_batch_message`:
#
#   SharedAlignedBuffer[HeapRegion] frame
#     → parse_ipc_message (frame header)
#     → FlatbufReader over metadata slice
#     → read_message (asserts header_tag = RECORD_BATCH)
#     → read_record_batch (BufferDescriptor offsets + FieldNode metadata)
#     → for each (schema_type, FieldNode, Buffer[*]) tuple, dispatch
#       to per-DType decoder body
#     → List[Column]
#
# THIS PATH IS COPY-ON-READ (symmetric to the copy-on-write encoder).
#
# Zero-copy decode for uncompressed fixed-width primitives borrows the
# frame's bytes instead; see `decode_record_batch_zerocopy` and the
# mmap-backed decoder below. Copy-on-read is architecturally correct and
# matches the encoder's pattern.
# =============================================================================

from std.memory import ArcPointer

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_collections.slab import Slab
from komira_buffer.heap_region import HeapRegion
from komira_buffer.mmap_region import MmapRegion
from komira_compression.compression_codecs import Lz4Frame, Zstd
from komira_arrow.offset_overflow import check_int32_offsets
from komira_arrow_ipc.ipc_body_compression import (
    decompress_record_batch_frame,
    decompress_record_batch_frame_with_dispatcher,
)
from komira_async_api.token import CancellationToken
from komira_async_api.parallel_dispatch import (
    ParallelDispatch,
    NoDispatch,
)
from komira_arrow_ipc.ipc_field_node_check import (
    check_buffer_size,
    check_field_node,
    check_node_index,
    check_record_batch_length,
    check_top_level_node,
    check_top_level_nodes,
    checked_bitmap_bytes,
    checked_offsets_bytes,
    checked_size_mul,
    validity_present,
    varlen_offsets_bytes,
)
from komira_arrow_ipc.ipc_nested_buffer_check import (
    check_node_buffers,
    check_struct_child_length,
    nested_node_buffer_count,
)
from komira_arrow_ipc.ipc_flatbuf import (
    BufferDescriptor,
    FieldNode,
    RecordBatchDescriptor,
    flatbuf_reader_over,
    parse_ipc_message,
    read_message,
    read_record_batch,
    MESSAGE_HEADER_RECORD_BATCH,
)
# Zero-copy gate hook. OFF-mode (production) is zero overhead via
# @parameter if; ON-mode requires -D KOMIRA_TRACE_TCMALLOC=true at
# build time.
from komira_counters.runtime_introspection import trace_alloc


# =============================================================================
# Malformed-input robustness — RecordBatch buffer-descriptor bounds check
# =============================================================================
#
# Malformed/corrupt-input robustness.
#
# The per-column builders (`_build_fixed_width_column` / `_build_varlen_column`
# / `_build_bool_column` copy-on-read, and `decode_record_batch_zerocopy`'s
# `from_borrowed_*` arms) all resolve a body slice via
# `frame.view_range_ro(body_pos + Int(buf.offset), Int(buf.length))`. The
# `(offset, length)` come straight from the untrusted FB Buffer descriptors
# in the RecordBatch metadata. `view_range_ro` only guards with a
# `debug_assert` — which is ELIDED in release builds — so on an
# adversarial/corrupt file a Buffer descriptor whose `offset` (or
# `offset + length`) points past the frame drives an out-of-bounds read
# (RED-verified SIGSEGV / SIGBUS: a structurally-valid IPC file with a
# `Buffer.offset` past the body crashed the read path before this gate).
#
# This is the exact class as the PARQUET-READ page-size fix:
# a length/offset field that lies about staying within the buffer must be
# caught with an EXPLICIT raise at the parse boundary, not a release-elided
# debug_assert. Each `(offset, length)` is validated against
# `[0, frame_len - body_pos]` (the body region) BEFORE any per-column
# builder dispatch. A zero-length buffer is always valid (offset is then
# don't-care and never dereferenced).


def _validate_rb_buffers_in_bounds(
    buffers: List[BufferDescriptor],
    body_pos: Int,
    frame_len: Int,
    context: StringLiteral,
) raises:
    """Raise (clean error) if any RecordBatch Buffer descriptor's
    `[body_pos + offset, body_pos + offset + length)` range lies outside
    the frame `[0, frame_len)`. Guards the per-column `view_range_ro`
    body slices against untrusted FB offsets/lengths (release builds
    elide `view_range_ro`'s internal debug_assert)."""
    var body_size = frame_len - body_pos
    for i in range(len(buffers)):
        ref b = buffers[i]
        var off = Int(b.offset)
        var length = Int(b.length)
        if length < 0:
            raise Error(
                String(context)
                + ": Buffer["
                + String(i)
                + "] has negative length "
                + String(length)
            )
        if length == 0:
            # Empty buffer is never dereferenced; offset is don't-care.
            continue
        if off < 0:
            raise Error(
                String(context)
                + ": Buffer["
                + String(i)
                + "] has negative offset "
                + String(off)
            )
        # off + length checked against the body region. Guard against
        # Int overflow by checking each term against body_size first.
        if off > body_size or length > body_size or off + length > body_size:
            raise Error(
                String(context)
                + ": Buffer["
                + String(i)
                + "] range (offset="
                + String(off)
                + ", length="
                + String(length)
                + ") exceeds the message body (body_pos="
                + String(body_pos)
                + ", body_size="
                + String(body_size)
                + ", frame_len="
                + String(frame_len)
                + ")"
            )


def _validate_mmap_frame_in_region(
    abs_frame_offset: Int,
    frame_len: Int,
    region_len: Int,
    context: StringLiteral,
) raises:
    """Raise unless the frame `[abs_frame_offset, abs_frame_offset +
    frame_len)` lies inside the mapped region `[0, region_len)`.

    The mmap decoder borrows each column buffer from the region at
    `abs_frame_offset + body_pos + Buffer.offset`. With every Buffer inside
    the frame's body (`_validate_rb_buffers_in_bounds`) and the frame inside
    the region (this check), every borrowed byte is inside the mapping. The
    caller-supplied offset is compared without forming `abs_frame_offset +
    frame_len`, which can wrap Int.
    """
    if (
        abs_frame_offset < 0
        or abs_frame_offset > region_len
        or frame_len > region_len - abs_frame_offset
    ):
        raise Error(
            String(context)
            + ": frame (offset="
            + String(abs_frame_offset)
            + ", length="
            + String(frame_len)
            + ") lies outside the mapped region (length="
            + String(region_len)
            + ")"
        )


# =============================================================================
# ColumnTypeSpec — recursive schema spec for nested decode
# =============================================================================
#
# The nested decoder uses this hierarchical spec to thread
# child-type information through the nested decoder. The flat
# `List[ArrowType]` input shape (used by decode_record_batch_message)
# is sufficient for primitives + var-len but doesn't carry child-type
# info for LIST/STRUCT/MAP/UNION.
#
# Construction helpers:
#   - ColumnTypeSpec.leaf(arrow_type) — non-nested types (primitives,
#     temporal, decimal, var-len, BOOL, NULL).
#   - ColumnTypeSpec.list_of(inner) — LIST<inner>.
#   - ColumnTypeSpec.struct_of(fields) — STRUCT with N child specs.
#   - ColumnTypeSpec.map_of(entries_struct) — MAP with 1 STRUCT<k,v> child.
#   - ColumnTypeSpec.union_of(mode, type_ids, children) — UNION_SPARSE/
#     UNION_DENSE with N children + type_ids list.


@fieldwise_init
struct ColumnTypeSpec(Movable):
    """Recursive schema spec for a single column. `children` is a Slab
    (matches Column._children's storage shape; Slab supports recursive
    Movable element types).
    """
    var arrow_type: ArrowType
    var children: Slab[ColumnTypeSpec]
    # For STRUCT: parallel names. Empty for non-STRUCT.
    var field_names: List[String]
    # For UNION_*: parallel declared type-ids. Empty for non-UNION.
    var type_ids: List[Int]
    # For FIXED_SIZE_BINARY (byte_width per row) + FIXED_SIZE_LIST
    # (element count per row). 0 for other types. Mirrors
    # Column._inner_size.
    var inner_size: Int

    @staticmethod
    def leaf(arrow_type: ArrowType) raises -> ColumnTypeSpec:
        """Construct a leaf (non-nested) ColumnTypeSpec."""
        return ColumnTypeSpec(
            arrow_type=arrow_type,
            children=Slab[ColumnTypeSpec](),
            field_names=List[String](),
            type_ids=List[Int](),
            inner_size=0,
        )

    @staticmethod
    def fixed_size_binary(byte_width: Int) raises -> ColumnTypeSpec:
        """Construct FIXED_SIZE_BINARY with a specific byte_width."""
        return ColumnTypeSpec(
            arrow_type=ArrowType.FIXED_SIZE_BINARY,
            children=Slab[ColumnTypeSpec](),
            field_names=List[String](),
            type_ids=List[Int](),
            inner_size=byte_width,
        )

    @staticmethod
    def fixed_size_list_of(
        var inner: ColumnTypeSpec, list_size: Int
    ) raises -> ColumnTypeSpec:
        """Construct FIXED_SIZE_LIST<inner>(list_size). Inner element
        count per row is fixed; no offsets buffer; child column has
        exactly `length * list_size` rows."""
        if list_size <= 0:
            raise Error(
                "ColumnTypeSpec.fixed_size_list_of: list_size must be > 0; "
                "got " + String(list_size)
            )
        var kids = Slab[ColumnTypeSpec]()
        kids.append(inner^)
        return ColumnTypeSpec(
            arrow_type=ArrowType.FIXED_SIZE_LIST,
            children=kids^,
            field_names=List[String](),
            type_ids=List[Int](),
            inner_size=list_size,
        )

    @staticmethod
    def list_of(var inner: ColumnTypeSpec) raises -> ColumnTypeSpec:
        """Construct LIST<inner>."""
        var kids = Slab[ColumnTypeSpec]()
        kids.append(inner^)
        return ColumnTypeSpec(
            arrow_type=ArrowType.LIST,
            children=kids^,
            field_names=List[String](),
            type_ids=List[Int](),
            inner_size=0,
        )

    @staticmethod
    def large_list_of(var inner: ColumnTypeSpec) raises -> ColumnTypeSpec:
        """Construct LARGE_LIST<inner> (Int64 offsets vs LIST's Int32)."""
        var kids = Slab[ColumnTypeSpec]()
        kids.append(inner^)
        return ColumnTypeSpec(
            arrow_type=ArrowType.LARGE_LIST,
            children=kids^,
            field_names=List[String](),
            type_ids=List[Int](),
            inner_size=0,
        )

    @staticmethod
    def struct_of(
        var children: Slab[ColumnTypeSpec],
        var field_names: List[String],
    ) raises -> ColumnTypeSpec:
        """Construct STRUCT with N children + parallel field names."""
        if len(children) != len(field_names):
            raise Error(
                "ColumnTypeSpec.struct_of: children count "
                + String(len(children))
                + " != field_names count "
                + String(len(field_names))
            )
        return ColumnTypeSpec(
            arrow_type=ArrowType.STRUCT,
            children=children^,
            field_names=field_names^,
            type_ids=List[Int](),
            inner_size=0,
        )

    @staticmethod
    def map_of(var entries: ColumnTypeSpec) raises -> ColumnTypeSpec:
        """Construct MAP with 1 entries STRUCT<key, value> child."""
        var kids = Slab[ColumnTypeSpec]()
        kids.append(entries^)
        return ColumnTypeSpec(
            arrow_type=ArrowType.MAP,
            children=kids^,
            field_names=List[String](),
            type_ids=List[Int](),
            inner_size=0,
        )


# =============================================================================
# Public helper — peek_record_batch_codec_from_frame
# =============================================================================
#
# Lightweight helper used by the
# strict-mode read entry points (`ctx.read_arrow_strict[C]`) to observe
# the `BodyCompression.codec` field on a RecordBatch frame WITHOUT
# performing the full per-column decode pass. Returns the codec id
# surfaced by `read_record_batch` on the supplied frame:
#
#   -1 = Uncompressed (no BodyCompression flatbuf field emitted)
#    0 = LZ4_FRAME
#    1 = ZSTD
#
# The strict-mode read driver calls this on EACH RecordBatch frame
# in the byte stream + asserts uniformity against the declared
# `C.ARROW_IPC_CODEC_ID` compile-time value. Cost: O(metadata_size)
# (one FB parse pass per RB frame) — same as the parse_ipc_message
# step the full decoder runs anyway; the observation incurs only the
# extra `_read_table_field_offset(.., 3) + _read_table_field_u8(.., 0)`
# probe on the RecordBatch table. Negligible vs the body decode itself.


def peek_record_batch_codec_from_frame(
    ref frame: SharedAlignedBuffer[HeapRegion],
) raises -> Int8:
    """Peek the `BodyCompression.codec` field on a RecordBatch IPC
    frame WITHOUT decoding the column bodies.

    Returns:
      -1 (Uncompressed sentinel) when the RecordBatch table has no
        `compression` field (field 3 offset absent) — the Arrow
        spec's "no BodyCompression = uncompressed body" case.
      0 (LZ4_FRAME) or 1 (ZSTD) when the writer emitted a
        BodyCompression child table with the codec id.

    Args:
        frame: A complete RecordBatch IPC frame (continuation + size +
            metadata FB + body bytes). The function inspects metadata
            only; the body bytes are untouched.

    Raises:
        Error from `parse_ipc_message` / `read_message` /
        `read_record_batch` (forwarded verbatim) on malformed frames.
    """
    var f = parse_ipc_message(frame)
    # scalar-loop → memcpy.
    var fb = SharedAlignedBuffer[HeapRegion].heap_owned(max(f.metadata_size, 1))
    if f.metadata_size > 0:
        fb.copy_from_view_at(
            0,
            frame.view_range_ro(f.metadata_pos, f.metadata_size),
        )
    fb.set_length(f.metadata_size)

    var reader = flatbuf_reader_over(fb)
    var msg = read_message(reader, reader.read_root_offset())
    if msg.header_tag != MESSAGE_HEADER_RECORD_BATCH:
        raise Error(
            "peek_record_batch_codec_from_frame: expected RECORD_BATCH"
            " header (tag "
            + String(Int(MESSAGE_HEADER_RECORD_BATCH))
            + "), got "
            + String(Int(msg.header_tag))
        )
    var rb = read_record_batch(reader, msg.header_table_pos)
    return rb.body_compression_codec


# =============================================================================
# Public entry — decode_record_batch_message
# =============================================================================


def decode_record_batch_message(
    var frame: SharedAlignedBuffer[HeapRegion],
    schema_types: List[ArrowType],
) raises -> Slab[Column[HeapRegion]]:
    """Decode an Arrow IPC RecordBatch message frame into a list of Columns.

    Serial-fallback wrapper. See `decode_record_batch_message_with_dispatcher`
    for the dispatcher-aware variant that drives the per-buffer
    decompress in parallel.

    Inverse of `encode_record_batch_message`. The caller supplies the
    `schema_types` list (one ArrowType per column) — Arrow IPC's
    RecordBatch message does not carry per-column types (those live in
    the preceding Schema message which is decoded separately).

    Buffer order per column follows the Arrow pre-order:
      - Primitive (fixed-width): validity + values (2 buffers)
      - Variable-length (String/Binary/LargeString/LargeBinary): validity
        + offsets + data (3 buffers)
      - Bool: validity + value bitmap (2 buffers)
      - Null: NO buffers (0 buffers)
      - Temporal / Decimal / IntervalMDN: same as fixed-width primitive
        (storage-DType-compatible)
      - Nested (List/Struct/Map/Union): not decoded here (this path
        covers primitives + var-len); see
        `decode_record_batch_message_nested`.

    This path is COPY-ON-READ. See the module header.

    if the frame's RecordBatch metadata carries
    a BodyCompression field with codec != -1, the frame is rewritten
    into an uncompressed-equivalent frame BEFORE the per-column build
    pass (see `_decompress_frame_if_needed` below). Downstream
    builders see uncompressed buffer offsets / lengths regardless of
    what the writer emitted.

    Each per-column buffer
    allocation site is tagged via `trace_alloc["arrow_ipc.decode_record
    _batch_copy"](buffer_bytes_total)`. OFF-mode is zero overhead;
    ON-mode (via -D KOMIRA_TRACE_TCMALLOC=true) emits a marker that
    an allocation gate counts to assert the per-codec threshold table.
    """
    # Class C: serial-fallback substitutes D=NoDispatch with a CONCRETE
    # origin, NOT MutAnyOrigin.
    var _nd = NoDispatch()
    comptime nd_o = origin_of(_nd)
    return _decode_record_batch_message_impl[
        NoDispatch, has_pool=False, disp_o=nd_o,
    ](
        frame^,
        schema_types,
        Optional[Pointer[NoDispatch, nd_o]](None),
        CancellationToken.never(),
    )


def decode_record_batch_message_with_dispatcher[
    D: ParallelDispatch,
    disp_o: Origin[mut=True],
](
    var frame: SharedAlignedBuffer[HeapRegion],
    schema_types: List[ArrowType],
    dispatcher_ptr: Pointer[D, disp_o],
    var cancel_token: CancellationToken,
) raises -> Slab[Column[HeapRegion]]:
    """Dispatcher-aware variant of `decode_record_batch_message`.

    Threads `dispatcher_ptr` + `cancel_token` from the calling
    EngineContext down to the per-buffer body decompression pre-pass
    for parallel codec dispatch. `D` is the monomorphized concrete
    dispatcher.


    """
    return _decode_record_batch_message_impl[
        D, has_pool=True, disp_o=disp_o,
    ](
        frame^,
        schema_types,
        Optional[Pointer[D, disp_o]](dispatcher_ptr),
        cancel_token^,
    )


def _decode_record_batch_message_impl[
    D: ParallelDispatch,
    has_pool: Bool,
    disp_o: Origin[mut=True],
](
    var frame: SharedAlignedBuffer[HeapRegion],
    schema_types: List[ArrowType],
    dispatcher_ptr: Optional[Pointer[D, disp_o]],
    var cancel_token: CancellationToken,
) raises -> Slab[Column[HeapRegion]]:
    """Shared body for the bare + `_with_dispatcher` `decode_record_batch_
    message` variants. Comptime `has_pool` prunes the parallel-decompress
    branch; no wildcard origin reaches the dispatch in either path
    (canonical _dedup_count_parallel_impl pattern).
    """
    # Entry-point marker. Tagged with 0
    # bytes since per-buffer markers fire inside the column builders;
    # this driver-level marker labels "we entered the copy-on-read
    # decode" for attribution.
    trace_alloc["arrow_ipc.decode_record_batch_copy"](0)
    # Per-buffer body decompression pre-pass.
    var working_frame: SharedAlignedBuffer[HeapRegion]

    comptime if has_pool:
        working_frame = _decompress_frame_if_needed_with_dispatcher[D, disp_o](
            frame^, dispatcher_ptr.value(), cancel_token^,
        )
    else:
        _ = cancel_token^
        working_frame = _decompress_frame_if_needed(frame^)

    # 1. Parse outer IPC framing → metadata + body positions.
    var f = parse_ipc_message(working_frame)

    # 2. Extract FB metadata slice → fresh MmapAlignedBuffer at byte 0 so
    #    FlatbufReader's root_offset anchors correctly.
    # scalar byte-copy
    # loop replaced with single memcpy via copy_from_view_at. The autovec
    # does not lift the scalar loop; libc memcpy is the canonical bulk-byte
    # copy primitive (same as the file-slurp read path).
    var fb = SharedAlignedBuffer[HeapRegion].heap_owned(max(f.metadata_size, 1))
    if f.metadata_size > 0:
        fb.copy_from_view_at(
            0,
            working_frame.view_range_ro(f.metadata_pos, f.metadata_size),
        )
    fb.set_length(f.metadata_size)

    var reader = flatbuf_reader_over(fb)

    # 3. Decode Message + assert RECORD_BATCH header.
    var msg = read_message(reader, reader.read_root_offset())
    if msg.header_tag != MESSAGE_HEADER_RECORD_BATCH:
        raise Error(  # cov: unreachable peek_record_batch_codec_from_frame refused a non-RecordBatch frame first
            "decode_record_batch_message: expected RECORD_BATCH header "  # cov: unreachable peek_record_batch_codec_from_frame refused a non-RecordBatch frame first
            "(tag "
            + String(Int(MESSAGE_HEADER_RECORD_BATCH))  # cov: unreachable peek_record_batch_codec_from_frame refused a non-RecordBatch frame first
            + "), got "  # cov: unreachable peek_record_batch_codec_from_frame refused a non-RecordBatch frame first
            + String(Int(msg.header_tag))  # cov: unreachable peek_record_batch_codec_from_frame refused a non-RecordBatch frame first
        )

    # 4. Decode RecordBatch table (length + nodes + buffers).
    var rb = read_record_batch(reader, msg.header_table_pos)
    var row_count = Int(rb.length)
    var n_cols = len(schema_types)

    # 5. Validate per-column buffer/node counts vs schema.
    var expected_node_count = 0
    var expected_buffer_count = 0
    for i in range(n_cols):
        var t = schema_types[i]
        expected_node_count += _node_count_for(t)
        expected_buffer_count += _buffer_count_for(t)
    if len(rb.nodes) != expected_node_count:
        raise Error(
            "decode_record_batch_message: FieldNode count mismatch (got "
            + String(len(rb.nodes))
            + ", expected "
            + String(expected_node_count)
            + " for "
            + String(n_cols)
            + " columns)"
        )
    if len(rb.buffers) != expected_buffer_count:
        raise Error(
            "decode_record_batch_message: Buffer count mismatch (got "
            + String(len(rb.buffers))
            + ", expected "
            + String(expected_buffer_count)
            + ")"
        )

    # 5b. ROBUSTNESS: validate every Buffer descriptor's
    # (offset, length) against the message body BEFORE per-column
    # dispatch. An untrusted/corrupt RecordBatch whose Buffer.offset (or
    # offset+length) points past the frame would otherwise drive an
    # out-of-bounds read in `_build_*_column` (view_range_ro's internal
    # debug_assert is release-elided). Clean raise instead of SIGSEGV.
    _validate_rb_buffers_in_bounds(
        rb.buffers, f.body_pos, working_frame.len(),
        "decode_record_batch_message",
    )
    # 5c. ROBUSTNESS: every buffer size below is formed from a FieldNode's
    # length; refuse a negative or inconsistent node before any is formed.
    check_top_level_nodes("decode_record_batch_message", rb.nodes, row_count)

    # 6. Dispatch decode per column. Track positional cursors into
    #    rb.nodes / rb.buffers.
    var columns = Slab[Column[HeapRegion]]()
    var node_idx = 0
    var buf_idx = 0
    for i in range(n_cols):
        var col_decoded = _decode_column(
            schema_types[i],
            rb.nodes,
            rb.buffers,
            node_idx,
            buf_idx,
            working_frame,
            f.body_pos,
            row_count,
        )
        # Mojo 1.0.0b1: partial-move via `^` of a non-Copyable struct
        # field (`col_decoded.column^`) triggers the "field destroyed
        # out of the middle of a value" check when the parent struct is
        # also used afterwards (cursor reads). Canonical replacement
        # primitive is stdlib `swap(field, default)`
        # — swap the column out into a local, leaving the result struct
        # in a destructor-safe (empty NULL column) state. The default
        # Column() is a no-alloc NULL column.
        node_idx = col_decoded.next_node_idx
        buf_idx = col_decoded.next_buffer_idx
        var col_out = Column[HeapRegion]()
        swap(col_decoded.column, col_out)
        columns.append(col_out^)
    _ = row_count
    return columns^


# =============================================================================
# Body decompression pre-pass
# =============================================================================
#
# Wrapper that peeks the BodyCompression.codec field on a RecordBatch
# frame; if codec != -1 (Uncompressed sentinel), rewrites the frame
# into an uncompressed-equivalent frame via
# `decompress_record_batch_frame[C]`. The output frame is consumed by
# the existing `decode_record_batch_message` / nested-decoder body
# without any change to the per-column builders (they see uncompressed
# offsets / lengths in BufferDescriptors).
#
# Runtime codec-id dispatch (NOT compile-time): the writer is
# external (pyarrow / arrow-rs / Spark / DuckDB) so the codec is
# detected from wire bytes — not the reader's declared type. The
# strict-mode read entry points layer codec-strictness on top of this
# (see ctx.read_arrow_strict[C] in session_context).


def _decompress_frame_if_needed(
    var frame: SharedAlignedBuffer[HeapRegion],
) raises -> SharedAlignedBuffer[HeapRegion]:
    """Serial-fallback wrapper. See
    `_decompress_frame_if_needed_with_dispatcher` for the dispatcher-
    aware variant that drives the per-buffer decompress in parallel.

    Serial entry point for callers without an EngineContext-owned
    dispatcher.

    Codec dispatch:
      - 0 (LZ4_FRAME) → `decompress_record_batch_frame[Lz4Frame]`
      - 1 (ZSTD)       → `decompress_record_batch_frame[Zstd[3]]`

    Note: ZSTD's `level` parameter on the writer side determines the
    compressed bytes' density, NOT how to decompress them — the ZSTD
    bytestream is self-describing. We pass `Zstd[3]` here purely as
    the trait-conformer marker; the FFI body ignores `level` for
    decompress.
    """
    # Fast-path: peek codec id without instantiating the FB parse twice.
    var codec_id = peek_record_batch_codec_from_frame(frame)
    if codec_id == Int8(-1):
        return frame^
    # Decompression hot path marker.
    trace_alloc["arrow_ipc.decompress"](Int(frame.len()))
    if codec_id == Int8(0):
        return decompress_record_batch_frame[Lz4Frame](frame^)
    if codec_id == Int8(1):
        return decompress_record_batch_frame[Zstd[3]](frame^)
    raise Error(
        "_decompress_frame_if_needed: unknown BodyCompression.codec "
        + String(Int(codec_id))
        + " (valid: -1 Uncompressed, 0 LZ4_FRAME, 1 ZSTD)"
    )


def _decompress_frame_if_needed_with_dispatcher[
    D: ParallelDispatch,
    disp_o: Origin[mut=True],
](
    var frame: SharedAlignedBuffer[HeapRegion],
    dispatcher_ptr: Pointer[D, disp_o],
    var cancel_token: CancellationToken,
) raises -> SharedAlignedBuffer[HeapRegion]:
    """Dispatcher-aware variant — threads
    EngineContext.dispatcher() + cancel_token() into the per-buffer
    decompress for parallel codec dispatch. `D` is the monomorphized
    concrete dispatcher.


    """
    var codec_id = peek_record_batch_codec_from_frame(frame)
    if codec_id == Int8(-1):
        _ = cancel_token^
        return frame^
    trace_alloc["arrow_ipc.decompress"](Int(frame.len()))
    if codec_id == Int8(0):
        return decompress_record_batch_frame_with_dispatcher[
            Lz4Frame, D, disp_o
        ](frame^, dispatcher_ptr, cancel_token^)
    if codec_id == Int8(1):
        return decompress_record_batch_frame_with_dispatcher[
            Zstd[3], D, disp_o
        ](frame^, dispatcher_ptr, cancel_token^)
    _ = cancel_token^
    raise Error(
        "_decompress_frame_if_needed_with_dispatcher: unknown"
        + " BodyCompression.codec " + String(Int(codec_id))
        + " (valid: -1 Uncompressed, 0 LZ4_FRAME, 1 ZSTD)"
    )


# =============================================================================
# Per-column decode dispatch
# =============================================================================


@fieldwise_init
struct _ColumnDecodeResult(Movable):
    """Carrier for the per-column decode return: the constructed Column[HeapRegion]
    plus the advanced node + buffer cursors so the driver can continue."""
    var column: Column[HeapRegion]
    var next_node_idx: Int
    var next_buffer_idx: Int


def _decode_column(
    arrow_type: ArrowType,
    nodes: List[FieldNode],
    buffers: List[BufferDescriptor],
    node_idx: Int,
    buffer_idx: Int,
    frame: SharedAlignedBuffer[HeapRegion],
    body_pos: Int,
    row_count: Int,
) raises -> _ColumnDecodeResult:
    """Decode one column at (node_idx, buffer_idx) into a Column.

    Returns the column + advanced cursors. Used for top-level RecordBatch
    decode and (eventually) nested recursion.
    """
    _ = row_count  # unused; per-column length comes from the FieldNode

    # NULL: 0 buffers, 1 FieldNode.
    if arrow_type == ArrowType.NULL:
        ref n = nodes[node_idx]
        var col = _build_null_column(Int(n.length))
        return _ColumnDecodeResult(
            column=col^,
            next_node_idx=node_idx + 1,
            next_buffer_idx=buffer_idx,
        )

    # Primitive / temporal / decimal / interval — fixed-width with
    # validity + values (2 buffers).
    var fixed_width = _fixed_width_bytes_for(arrow_type)
    if fixed_width > 0:
        ref n = nodes[node_idx]
        var col = _build_fixed_width_column(
            arrow_type,
            Int(n.length),
            Int(n.null_count),
            fixed_width,
            buffers[buffer_idx],     # validity buffer
            buffers[buffer_idx + 1], # values buffer
            frame,
            body_pos,
            node_idx,
        )
        return _ColumnDecodeResult(
            column=col^,
            next_node_idx=node_idx + 1,
            next_buffer_idx=buffer_idx + 2,
        )

    # BOOL: validity + value bitmap (2 buffers; value buffer is
    # (length+7)/8 byte LSB-first pack, not bytes_per_element × length).
    if arrow_type == ArrowType.BOOL:
        ref n = nodes[node_idx]
        var col = _build_bool_column(
            Int(n.length),
            Int(n.null_count),
            buffers[buffer_idx],     # validity
            buffers[buffer_idx + 1], # value bitmap
            frame,
            body_pos,
            node_idx,
        )
        return _ColumnDecodeResult(
            column=col^,
            next_node_idx=node_idx + 1,
            next_buffer_idx=buffer_idx + 2,
        )

    # Variable-length (3 buffers: validity + offsets + data).
    if (
        arrow_type == ArrowType.STRING
        or arrow_type == ArrowType.BINARY
        or arrow_type == ArrowType.LARGE_STRING
        or arrow_type == ArrowType.LARGE_BINARY
    ):
        ref n = nodes[node_idx]
        var col = _build_varlen_column(
            arrow_type,
            Int(n.length),
            Int(n.null_count),
            buffers[buffer_idx],     # validity
            buffers[buffer_idx + 1], # offsets
            buffers[buffer_idx + 2], # data
            frame,
            body_pos,
            node_idx,
        )
        return _ColumnDecodeResult(
            column=col^,
            next_node_idx=node_idx + 1,
            next_buffer_idx=buffer_idx + 3,
        )

    # DICTIONARY arm RAISES from the standard decoder path — the dict
    # decode needs IpcDictCache access (sdk-layer) so it can't live
    # here without breaking the arrow → sdk dep direction. Callers that want dict-aware decode MUST use the SDK-
    # side `decode_arrow_ipc_stream_with_dict_cache` /
    # `decode_arrow_ipc_file_with_dict_cache` siblings which thread the
    # IpcDictCache through to a custom per-column walker (see
    # `arrow_stream_reader.mojo` / `arrow_file_reader.mojo`). The
    # helper `expand_dict_indices_to_string` below provides the
    # actual indices-into-values expansion primitive that the SDK
    # uses (decoupled from the cache so it's reusable by any caller
    # holding pre-decoded dict values).
    if arrow_type == ArrowType.DICTIONARY:
        raise Error(
            "_decode_column: DICTIONARY columns require dict-aware "
            "decode via SDK-side `decode_arrow_ipc_stream_with_dict_cache` "
            "/ `decode_arrow_ipc_file_with_dict_cache` (per the "
            "arrow -> sdk dep direction). Callers using "
            "the bare `decode_record_batch_message` cannot decode "
            "DICTIONARY-encoded columns because the dict VALUES live "
            "in a preceding DictionaryBatch frame which only the SDK-"
            "level stream walker consumes."
        )

    raise Error(
        "_decode_column: ArrowType "
        + String(Int(arrow_type.type_id))
        + " not wired in the flat decoder (covers primitives + temporal "
        + "+ decimal + bool + var-len; nested types go through "
        + "decode_record_batch_message_nested)"
    )


# =============================================================================
# Dict-index → STRING expansion helper
# =============================================================================
#
# Lossy-expand contract: the decoder reads the wire shape (validity +
# Int32 indices + DictionaryBatch values), then EXPANDS the indices
# into a freshly-allocated STRING column. The output column has
# `arrow_type=STRING` (NOT DICTIONARY) — symmetric to what pyarrow
# does when round-tripping a dict-encoded Arrow stream into a non-
# dict-aware consumer.
#
# This helper is the dict-VALUES-already-decoded primitive: the SDK
# decoder reads the indices buffer + walks the DictionaryBatch cache,
# then hands both to this fn which produces the expanded STRING column.
#
# Decoupled from IpcDictCache so this can live in arrow and be
# unit-tested independently. Lossless DICTIONARY column production is
# not implemented.


def expand_dict_indices_to_string(
    var indices_buf: OwnedAlignedBuffer,
    n_rows: Int,
    var validity: Optional[Bitmap[HeapRegion]],
    dict_values_col: Column[HeapRegion],
    index_bit_width: Int = 32,
) raises -> Column[HeapRegion]:
    """Expand a Dict (Int32/Int64 indices) + STRING values into a fresh
    STRING column.

    Args:
        indices_buf: MmapAlignedBuffer holding `n_rows` × Int{32,64} indices
            in LE layout. Each index addresses a row in
            `dict_values_col` (a STRING column).
        n_rows: Number of rows (also the number of index entries in
            `indices_buf`).
        validity: Optional validity bitmap for the index column.
            Bit-clear means the OUTPUT row at that position is NULL
            (its expanded string is empty + validity propagates).
        dict_values_col: A STRING-typed Column carrying the dictionary
            VALUES (from the preceding DictionaryBatch frame, looked
            up by dict_id in IpcDictCache.get()).
        index_bit_width: Bit width of each index entry in `indices_buf`
            (32 for the Int32 default; 64 for Int64 >2G dict entries).
            Driven by
            the on-wire FieldDescriptor.dictionary_encoding.
            index_type_bit_width.

    Returns:
        A freshly-allocated STRING column with `n_rows` rows whose
        string at row i is `dict_values_col[indices_buf[i]]` (or NULL
        if validity[i] is clear). null_count carries through from the
        index column's validity.

    Raises:
        Error if `dict_values_col.arrow_type` is not STRING (the
        lossy-expand contract).
        Error if any index is out of range
        [0, dict_values_col.length).
        Error if `index_bit_width` is not 32 or 64.
    """
    if index_bit_width != 32 and index_bit_width != 64:
        raise Error(
            "expand_dict_indices_to_string: index_bit_width must be "
            "32 (Int32 v1 default) or 64 (Int64 for >2G dict entries); "
            "got " + String(index_bit_width)
        )
    var idx_byte_width = index_bit_width // 8
    if dict_values_col.arrow_type != ArrowType.STRING:
        raise Error(
            "expand_dict_indices_to_string: dict_values_col must have "
            "arrow_type=STRING (v1 lossy-expand contract); got type_id "
            + String(Int(dict_values_col.arrow_type.type_id))
        )

    var dict_n = dict_values_col._length
    # The dict_values column carries STRING semantics: _offsets is
    # (dict_n + 1) Int32 entries; _data is the contiguous byte slab.
    # We read each row's start/end offset to know its length, then
    # copy those bytes into the output's data buffer.
    if not dict_values_col._offsets:
        raise Error(
            "expand_dict_indices_to_string: dict_values_col has no "
            "_offsets buffer (corrupt STRING dictionary)"
        )
    ref dict_offsets = dict_values_col._offsets.value()

    # =================================================================
    # ASSERT=none HARDENING — the dictionary's offset array
    # is validated ONCE, HERE, and never re-checked per row.
    #
    # THE DEFECT THIS CLOSES (attacker-controlled heap WRITE, not just an
    # OOB read). The two passes below both compute `end - start` from
    # `dict_offsets`, which for a Flight DoPut originates in the
    # DictionaryBatch body. Nothing checked `end >= start`, so mixed-sign
    # entries made the passes DISAGREE: offsets [0, 65536, 0, 0] over
    # indices [0,1,2,1,0] sum to total_out_bytes = 0, so pass 1 allocates
    # `OwnedAlignedBuffer(max(0, 1))` = ONE byte and pass 2 then writes
    # 65536 bytes into it via `out_data.write_u8_at` — a `debug_assert`
    # plus a raw store in `OwnedAlignedBuffer.write_u8_at`, which is a
    # SIGSEGV at both ASSERT=safe and ASSERT=none.
    #
    # `idx < dict_n` (below) is a real check but could not help: `dict_n`
    # is the decoded Column's length, which is FieldNode.length from the
    # same untrusted DictionaryBatch, so it can be inflated to make any
    # index legal. That is now bounded at the DictionaryBatch parse
    # boundary (arrow_stream_reader `_consume_dictionary_batch_frame_impl`);
    # this gate makes the expansion safe INDEPENDENTLY of that caller.
    #
    # WHY HERE AND NOT IN THE ROW LOOPS: this is O(dict_n) once, whereas
    # a per-row check is O(n_rows) and n_rows >> dict_n is the entire
    # point of dictionary encoding. After this returns, both passes may
    # use `end - start` with no further checking.
    # =================================================================
    var dict_n_offsets = dict_offsets.len() // 4
    if dict_n < 0:
        raise Error(
            "expand_dict_indices_to_string: dictionary declares a negative"
            " value count (" + String(dict_n) + ")"
        )
    # A 0-value dictionary is legal and needs NO walk: the `idx < dict_n` check
    # in the row loop rejects every index, so nothing can reach the offsets at
    # all. Guarding this explicitly matters because an encoder may emit a
    # 0-length offsets buffer for an empty dictionary, and `range(dict_n + 1)`
    # would then read offsets[0] out of an empty buffer — the check becoming
    # the bug it was added to prevent.
    if dict_n > 0:
        # `dict_n > dict_n_offsets - 1`, not `dict_n + 1 > dict_n_offsets`: the
        # addition is itself an overflow primitive on the untrusted value.
        if dict_n > dict_n_offsets - 1:
            raise Error(
                "expand_dict_indices_to_string: dictionary declares "
                + String(dict_n)
                + " values, which needs "
                + String(dict_n) + "+1 Int32 offset entries, but the offsets"
                " buffer holds only " + String(dict_n_offsets)
                + " (" + String(dict_offsets.len()) + " bytes)"
            )
        var dict_data_len = dict_values_col._data.len()
        var prev_off = 0
        for e in range(dict_n + 1):
            var off_e = Int(dict_offsets.read_u32_le_at(e * 4))
            if off_e < prev_off:
                raise Error(
                    "expand_dict_indices_to_string: dictionary offsets are not"
                    " monotonic — offsets[" + String(e) + "]=" + String(off_e)
                    + " < offsets[" + String(e - 1) + "]=" + String(prev_off)
                    + " (a negative string length would make the sizing pass"
                    " and the copy pass disagree)"
                )
            if off_e > dict_data_len:
                raise Error(
                    "expand_dict_indices_to_string: dictionary offsets["
                    + String(e) + "]=" + String(off_e)
                    + " exceeds the dictionary data buffer length "
                    + String(dict_data_len)
                )
            prev_off = off_e

    # Output offsets: (n_rows + 1) Int32. Output data: variable; we
    # build it in two passes — first pass computes the output's
    # cumulative byte size (so we know how big a buffer to alloc),
    # second pass writes the actual bytes.
    # `n_rows` is a FieldNode length off the wire. Compare by division, not
    # `n_rows * idx_byte_width`, which wraps for a huge count (2^62 Int32
    # indices need 2^64 bytes, 0 in Int) and would pass.
    if n_rows < 0:
        raise Error(
            "expand_dict_indices_to_string: n_rows " + String(n_rows)
            + " is negative"
        )
    var indices_n_bytes = indices_buf.len()
    if indices_n_bytes // idx_byte_width < n_rows:
        raise Error(
            "expand_dict_indices_to_string: indices_buf length "
            + String(indices_n_bytes) + " < n_rows*idx_byte_width ("
            + String(n_rows) + " x " + String(idx_byte_width) + ")"
        )

    # First pass: total bytes + validate indices.
    # Arrow spec: indices are signed Int{32,64} but always >= 0 (cannot
    # address negative dict entries). We read as UInt{32,64} and Int()-
    # cast which preserves the non-negative semantic without needing a
    # bitcast import — same convention as `read_record_batch` reading
    # buffer offsets/lengths.
    var total_out_bytes = 0
    var null_count_out = 0
    for i in range(n_rows):
        var is_valid = True
        if validity:
            ref bm = validity.value()
            is_valid = bm.test(i)
        if not is_valid:
            null_count_out += 1
            continue
        var idx: Int
        if idx_byte_width == 4:
            idx = Int(indices_buf.read_u32_le_at(i * 4))
        else:
            # idx_byte_width == 8 (Int64 LE).
            idx = Int(indices_buf.read_u64_le_at(i * 8))
        if idx < 0 or idx >= dict_n:
            raise Error(
                "expand_dict_indices_to_string: index "
                + String(idx) + " at row " + String(i)
                + " out of range [0, " + String(dict_n) + ")"
            )
        # String length = dict_offsets[idx+1] - dict_offsets[idx]
        var start = Int(dict_offsets.read_u32_le_at(idx * 4))
        var end = Int(dict_offsets.read_u32_le_at((idx + 1) * 4))
        total_out_bytes += (end - start)

    # Allocate output buffers.
    var out_offsets = OwnedAlignedBuffer((n_rows + 1) * 4)
    out_offsets.set_length(Int64((n_rows + 1) * 4))

    var out_data = OwnedAlignedBuffer(max(total_out_bytes, 1))
    out_data.set_length(Int64(total_out_bytes))


    # Second pass: write offsets + bytes.
    var cursor = 0
    out_offsets.write_u32_le_at(0, UInt32(0))
    for i in range(n_rows):
        var is_valid = True
        if validity:
            ref bm = validity.value()
            is_valid = bm.test(i)
        if not is_valid:
            # NULL rows: zero-length contribution (offsets stay at cursor).
            out_offsets.write_u32_le_at((i + 1) * 4, UInt32(cursor))
            continue
        var idx: Int
        if idx_byte_width == 4:
            idx = Int(indices_buf.read_u32_le_at(i * 4))
        else:
            idx = Int(indices_buf.read_u64_le_at(i * 8))
        var start = Int(dict_offsets.read_u32_le_at(idx * 4))
        var end = Int(dict_offsets.read_u32_le_at((idx + 1) * 4))
        var blen = end - start
        # Copy the bytes from dict_data[start..end] → out_data[cursor..cursor+blen]
        for j in range(blen):
            out_data.write_u8_at(
                cursor + j, dict_values_col._data.read_u8_at(start + j)
            )
        cursor += blen
        out_offsets.write_u32_le_at((i + 1) * 4, UInt32(cursor))

    _ = indices_buf^
    return Column[HeapRegion](
        arrow_type=ArrowType.STRING,
        data=out_data^,
        offsets=out_offsets^,
        validity=validity^,
        length=n_rows,
        null_count=null_count_out,
        offset=0,
    )


# =============================================================================
# decode_record_batch_message_with_dicts — dict-aware RecordBatch decoder
# =============================================================================
#
# Sibling of `decode_record_batch_message` that supports DICTIONARY-
# encoded columns by accepting a parallel `dict_values: Slab[Column]`
# carrying the pre-decoded dict-VALUES STRING column per dict-encoded
# column (the SDK looks these up via IpcDictCache.get(dict_id) before
# calling this driver). For non-dict columns, the slot in `dict_values`
# is unused (the SDK passes a default `Column()` placeholder).
#
# The wire-shape is 2 buffers per dict
# column (validity + Int32 indices) and the OUTPUT column has
# arrow_type=STRING (lossy expand). Schema-tracking that the column
# was dict-encoded on the wire is the SDK's responsibility — this
# driver just sees `schema_types[i] == DICTIONARY` as the cue to take
# the matching `dict_values[i]` slot + expand.


def decode_record_batch_message_with_dicts(
    var frame: SharedAlignedBuffer[HeapRegion],
    schema_types: List[ArrowType],
    is_dict_encoded: List[Bool],
    var dict_values: Slab[Column[HeapRegion]],
    dict_index_widths: List[Int] = List[Int](),
) raises -> Slab[Column[HeapRegion]]:
    """Dict-aware sibling of `decode_record_batch_message`.

    Serial-fallback wrapper. See `decode_record_batch_message_with_
    dicts_with_dispatcher` for the dispatcher-aware variant that drives
    the per-buffer decompress in parallel.

    Args:
        frame: The complete RecordBatch IPC frame.
        schema_types: One ArrowType per column. For columns where
            `is_dict_encoded[i]` is True, this carries the OUTPUT
            arrow_type (STRING for v1 lossy expand); the on-wire
            buffer shape is dict (validity + indices), and the
            output Column produced is STRING-typed.
        is_dict_encoded: Parallel list — True if column `i` is dict-
            encoded on the wire (validity + indices); the driver
            dispatches to the dict-arm and expands via the matching
            `dict_values[i]` slot. False for non-dict columns
            (standard `_decode_column` dispatch).
        dict_values: Parallel slab of pre-decoded dict-VALUES STRING
            columns (one per column index; for non-dict columns this
            slot is a placeholder `Column()` and is ignored).
            CONSUMED — the dict-arm `take_slot_unchecked`s the
            matching slot.
        dict_index_widths: Parallel list of per-column index bit
            widths (32 or 64) — driven by the on-wire
            FieldDescriptor.dictionary_encoding.index_type_bit_width.
            Empty
            list (the default) means "treat every dict-encoded column
            as 32-bit indices" — preserves backward compat with
            callers that haven't been wired through. For non-dict
            columns the entry is unused (sentinel 32 ok).

    Returns:
        `Slab[Column]` of decoded columns. Dict-encoded columns are
        EXPANDED to arrow_type=STRING per the lossy-expand
        contract.
    """
    # Class C: serial-fallback substitutes D=NoDispatch with a CONCRETE
    # origin, NOT MutAnyOrigin.
    var _nd = NoDispatch()
    comptime nd_o = origin_of(_nd)
    return _decode_record_batch_message_with_dicts_impl[
        NoDispatch, has_pool=False, disp_o=nd_o,
    ](
        frame^,
        schema_types,
        is_dict_encoded,
        dict_values^,
        dict_index_widths,
        Optional[Pointer[NoDispatch, nd_o]](None),
        CancellationToken.never(),
    )


def decode_record_batch_message_with_dicts_with_dispatcher[
    D: ParallelDispatch,
    disp_o: Origin[mut=True],
](
    var frame: SharedAlignedBuffer[HeapRegion],
    schema_types: List[ArrowType],
    is_dict_encoded: List[Bool],
    var dict_values: Slab[Column[HeapRegion]],
    dict_index_widths: List[Int],
    dispatcher_ptr: Pointer[D, disp_o],
    var cancel_token: CancellationToken,
) raises -> Slab[Column[HeapRegion]]:
    """Dispatcher-aware variant of `decode_record_batch_message_with_dicts`.


    """
    return _decode_record_batch_message_with_dicts_impl[
        D, has_pool=True, disp_o=disp_o,
    ](
        frame^,
        schema_types,
        is_dict_encoded,
        dict_values^,
        dict_index_widths,
        Optional[Pointer[D, disp_o]](dispatcher_ptr),
        cancel_token^,
    )


def _decode_record_batch_message_with_dicts_impl[
    D: ParallelDispatch,
    has_pool: Bool,
    disp_o: Origin[mut=True],
](
    var frame: SharedAlignedBuffer[HeapRegion],
    schema_types: List[ArrowType],
    is_dict_encoded: List[Bool],
    var dict_values: Slab[Column[HeapRegion]],
    dict_index_widths: List[Int],
    dispatcher_ptr: Optional[Pointer[D, disp_o]],
    var cancel_token: CancellationToken,
) raises -> Slab[Column[HeapRegion]]:
    """Shared body for the bare + `_with_dispatcher` variants. Comptime
    `has_pool` prunes the parallel-decompress branch."""
    trace_alloc["arrow_ipc.decode_record_batch_copy"](0)
    var working_frame: SharedAlignedBuffer[HeapRegion]

    comptime if has_pool:
        working_frame = _decompress_frame_if_needed_with_dispatcher[D, disp_o](
            frame^, dispatcher_ptr.value(), cancel_token^,
        )
    else:
        _ = cancel_token^
        working_frame = _decompress_frame_if_needed(frame^)

    var f = parse_ipc_message(working_frame)
    # scalar-loop → memcpy.
    var fb = SharedAlignedBuffer[HeapRegion].heap_owned(max(f.metadata_size, 1))
    if f.metadata_size > 0:
        fb.copy_from_view_at(
            0,
            working_frame.view_range_ro(f.metadata_pos, f.metadata_size),
        )
    fb.set_length(f.metadata_size)

    var reader = flatbuf_reader_over(fb)

    var msg = read_message(reader, reader.read_root_offset())
    if msg.header_tag != MESSAGE_HEADER_RECORD_BATCH:
        raise Error(  # cov: unreachable peek_record_batch_codec_from_frame refused a non-RecordBatch frame first
            "decode_record_batch_message_with_dicts: expected "  # cov: unreachable peek_record_batch_codec_from_frame refused a non-RecordBatch frame first
            "RECORD_BATCH header (tag "
            + String(Int(MESSAGE_HEADER_RECORD_BATCH))  # cov: unreachable peek_record_batch_codec_from_frame refused a non-RecordBatch frame first
            + "), got "  # cov: unreachable peek_record_batch_codec_from_frame refused a non-RecordBatch frame first
            + String(Int(msg.header_tag))  # cov: unreachable peek_record_batch_codec_from_frame refused a non-RecordBatch frame first
        )

    var rb = read_record_batch(reader, msg.header_table_pos)
    var row_count = Int(rb.length)
    var n_cols = len(schema_types)

    # Per-column node + buffer count validation. Dict-encoded
    # columns consume 1 node + 2 buffers on the wire (validity +
    # Int32 indices) — regardless of the OUTPUT arrow_type.
    var expected_node_count = 0
    var expected_buffer_count = 0
    for i in range(n_cols):
        if is_dict_encoded[i]:
            # On-wire shape for dict-encoded: 1 node, 2 buffers.
            expected_node_count += 1
            expected_buffer_count += 2
        else:
            expected_node_count += _node_count_for(schema_types[i])
            expected_buffer_count += _buffer_count_for(schema_types[i])
    if len(rb.nodes) != expected_node_count:
        raise Error(
            "decode_record_batch_message_with_dicts: FieldNode "
            "count mismatch (got "
            + String(len(rb.nodes))
            + ", expected "
            + String(expected_node_count)
            + ")"
        )
    if len(rb.buffers) != expected_buffer_count:
        raise Error(
            "decode_record_batch_message_with_dicts: Buffer count "
            "mismatch (got "
            + String(len(rb.buffers))
            + ", expected "
            + String(expected_buffer_count)
            + ")"
        )

    # ROBUSTNESS: validate Buffer descriptors against the
    # body before per-column dispatch (same gate as the non-dict path).
    _validate_rb_buffers_in_bounds(
        rb.buffers, f.body_pos, working_frame.len(),
        "decode_record_batch_message_with_dicts",
    )
    check_top_level_nodes(
        "decode_record_batch_message_with_dicts", rb.nodes, row_count
    )

    # Per-column dispatch.
    # The front-drain below takes exactly one slot per column. `Slab.take_at`
    # guards its index with a `debug_assert`, which is elided in every mode we
    # ship — so state the contract as a real raise, once, here.
    # `< n_cols`, not `!= n_cols`: only a SHORTFALL is dangerous (take_at would
    # run off the end). Surplus trailing slots are simply dropped by the slab's
    # own destructor, and refusing them would be a new failure mode rather than
    # a guard.
    if dict_values.len() < n_cols:
        raise Error(
            "decode_record_batch_message_with_dicts: dict_values has only "
            + String(dict_values.len())
            + " entries but the schema has "
            + String(n_cols)
            + " columns (one slot per column is required — placeholder"
            " Columns for non-dict columns)"
        )

    var columns = Slab[Column[HeapRegion]]()
    var node_idx = 0
    var buf_idx = 0
    var widths_provided = len(dict_index_widths) > 0
    for i in range(n_cols):
        var t = schema_types[i]
        # DECODE-ERROR UNWIND SAFETY.
        #
        # FRONT-DRAIN every iteration — dict column or not — so `dict_values`'
        # tracked length ALWAYS equals its count of still-initialized slots.
        # Taking slot `i` via `take_slot_unchecked(i)` moves the bits out but
        # deliberately does NOT touch `_len_t` (see
        # Slab.take_slot_unchecked's SAFETY CONTRACT); resetting the length
        # only AFTER the loop, on the SUCCESS path, means ANY raise out of
        # `expand_dict_indices_to_string` unwinds with `_len_t == n_cols` and
        # `Slab.__del__` re-runs `destroy_pointee` over the already-moved-out
        # slot — a use-after-free that poisons the tcmalloc free-list and
        # kills a LATER allocation. That turns every clean error on this path
        # (e.g. a malformed, non-monotonic dictionary offsets buffer) into a
        # crash in an unrelated allocation. The Arrow file reader's
        # `rb_frames` drain has the identical shape and the identical fix.
        #
        # `take_at(0)` shifts the tail down and decrements `_len_t` together,
        # so on any raise the destructor drops exactly the un-drained slots and
        # nothing is dropped twice. n_cols is small and the non-dict slots hold
        # empty placeholder Columns, so the O(n) shift is free.
        var dict_vals_col = dict_values.take_at(0)
        if is_dict_encoded[i]:
            # DICTIONARY arm: read validity + Int{32,64} indices
            # buffers, use this column's dict_values slot, expand via
            # `expand_dict_indices_to_string`. Per-column index bit
            # width is driven by the Field.dictionary.indexType slot
            # surfaced by `_extract_dict_index_widths` (defaults to
            # 32 for backward compat when caller passes an empty
            # `dict_index_widths`).
            ref node = rb.nodes[node_idx]
            ref validity_buf = rb.buffers[buf_idx]
            ref indices_buf_desc = rb.buffers[buf_idx + 1]
            var dict_n_rows = Int(node.length)
            var idx_bit_width = 32
            if widths_provided:
                idx_bit_width = dict_index_widths[i]
            var validity = _maybe_decode_validity_bitmap(
                validity_buf, dict_n_rows, Int(node.null_count), node_idx,
                working_frame, f.body_pos,
            )
            var indices_bytes = Int(indices_buf_desc.length)
            var indices_buf = OwnedAlignedBuffer(max(indices_bytes, 1))
            trace_alloc["arrow_ipc.decode_record_batch_copy"](indices_bytes)
            # scalar-loop → memcpy.
            if indices_bytes > 0:
                indices_buf.copy_from_view_at(
                    0,
                    working_frame.view_range_ro(
                        f.body_pos + Int(indices_buf_desc.offset),
                        indices_bytes,
                    ),
                )
            indices_buf.set_length(Int64(indices_bytes))

            var expanded = expand_dict_indices_to_string(
                indices_buf^,
                dict_n_rows,
                validity^,
                dict_vals_col,
                idx_bit_width,
            )
            columns.append(expanded^)
            node_idx += 1
            buf_idx += 2
            continue

        # Non-dict column: the slot drained above is the caller's unused
        # placeholder Column; drop it and delegate to `_decode_column`.
        _ = dict_vals_col^
        var col_decoded = _decode_column(
            t,
            rb.nodes,
            rb.buffers,
            node_idx,
            buf_idx,
            working_frame,
            f.body_pos,
            row_count,
        )
        node_idx = col_decoded.next_node_idx
        buf_idx = col_decoded.next_buffer_idx
        var col_out = Column[HeapRegion]()
        swap(col_decoded.column, col_out)
        columns.append(col_out^)

    # The loop front-drained one slot per column, so `dict_values` is already
    # empty and its tracked length already agrees. (The former
    # `set_len_unchecked(0)` here was the success-path-only reconciliation the
    # unwind bug above rode on; front-draining makes it unnecessary and, more
    # importantly, makes the length correct at every point in between.)
    _ = dict_values^
    _ = row_count
    return columns^


# =============================================================================
# Per-shape column builders
# =============================================================================


def _build_null_column(length: Int) raises -> Column[HeapRegion]:
    """Build a NULL Column. null_count == length per Arrow spec."""
    return Column[HeapRegion](
        arrow_type=ArrowType.NULL,
        data=OwnedAlignedBuffer(0),
        offsets=None,
        validity=None,
        length=length,
        null_count=length,
        offset=0,
    )


def _build_fixed_width_column(
    arrow_type: ArrowType,
    length: Int,
    null_count: Int,
    bytes_per_element: Int,
    validity_buf: BufferDescriptor,
    values_buf: BufferDescriptor,
    frame: SharedAlignedBuffer[HeapRegion],
    body_pos: Int,
    node_index: Int,
) raises -> Column[HeapRegion]:
    """Construct a fixed-width Column[HeapRegion] by copy-on-read from the IPC body."""
    var validity = _maybe_decode_validity_bitmap(
        validity_buf, length, null_count, node_index, frame, body_pos
    )
    var values_bytes_expected = checked_size_mul(
        "_build_fixed_width_column", node_index, "values buffer", length,
        bytes_per_element,
    )
    check_buffer_size(
        "_build_fixed_width_column", node_index, "values",
        Int(values_buf.length), values_bytes_expected, length,
    )
    var data = OwnedAlignedBuffer(max(values_bytes_expected, 1))
    # Per-buffer marker for the values
    # buffer (fixed-width primitive copy-on-read path).
    trace_alloc["arrow_ipc.decode_record_batch_copy"](values_bytes_expected)
    # scalar byte-copy loop
    # replaced with single memcpy via copy_from_view_at. This is the dominant
    # hotspot on the uncompressed arm; Mojo's autovec does NOT lift `for i: a[i] = b[i]`; libc memcpy is the
    # canonical bulk-byte primitive (NEON LD1/ST1 throughput-bound).
    if values_bytes_expected > 0:
        data.copy_from_view_at(
            0,
            frame.view_range_ro(
                body_pos + Int(values_buf.offset), values_bytes_expected
            ),
        )
    data.set_length(Int64(values_bytes_expected))

    return Column[HeapRegion](
        arrow_type=arrow_type,
        data=data^,
        offsets=None,
        validity=validity^,
        length=length,
        null_count=null_count,
        offset=0,
    )


def _build_bool_column(
    length: Int,
    null_count: Int,
    validity_buf: BufferDescriptor,
    value_bitmap_buf: BufferDescriptor,
    frame: SharedAlignedBuffer[HeapRegion],
    body_pos: Int,
    node_index: Int,
) raises -> Column[HeapRegion]:
    """Construct a BOOL Column[HeapRegion] by copy-on-read. Value buffer is
    LSB-first 1-bit pack, (length+7)/8 bytes."""
    var validity = _maybe_decode_validity_bitmap(
        validity_buf, length, null_count, node_index, frame, body_pos
    )
    var expected_bitmap_bytes = checked_bitmap_bytes(
        "_build_bool_column", node_index, "value bitmap buffer", length
    )
    check_buffer_size(
        "_build_bool_column", node_index, "value bitmap",
        Int(value_bitmap_buf.length), expected_bitmap_bytes, length,
    )
    var data = OwnedAlignedBuffer(max(expected_bitmap_bytes, 1))
    # Per-buffer marker for the BOOL
    # value-bitmap buffer.
    trace_alloc["arrow_ipc.decode_record_batch_copy"](expected_bitmap_bytes)
    # scalar-loop → memcpy.
    if expected_bitmap_bytes > 0:
        data.copy_from_view_at(
            0,
            frame.view_range_ro(
                body_pos + Int(value_bitmap_buf.offset),
                expected_bitmap_bytes,
            ),
        )
    data.set_length(Int64(expected_bitmap_bytes))

    return Column[HeapRegion](
        arrow_type=ArrowType.BOOL,
        data=data^,
        offsets=None,
        validity=validity^,
        length=length,
        null_count=null_count,
        offset=0,
    )


def _build_varlen_column(
    arrow_type: ArrowType,
    length: Int,
    null_count: Int,
    validity_buf: BufferDescriptor,
    offsets_buf: BufferDescriptor,
    data_buf: BufferDescriptor,
    frame: SharedAlignedBuffer[HeapRegion],
    body_pos: Int,
    node_index: Int,
) raises -> Column[HeapRegion]:
    """Construct a String/Binary/LargeString/LargeBinary Column[HeapRegion] by
    copy-on-read."""
    var validity = _maybe_decode_validity_bitmap(
        validity_buf, length, null_count, node_index, frame, body_pos
    )

    # Copy offsets buffer. It must hold the node's `length + 1` offsets (the
    # offsets' values against the data buffer are a separate check).
    var offsets_bytes = Int(offsets_buf.length)
    check_buffer_size(
        "_build_varlen_column", node_index, "offsets", offsets_bytes,
        varlen_offsets_bytes(
            "_build_varlen_column", node_index, length,
            _varlen_offset_width(arrow_type),
        ),
        length,
    )
    var offsets = OwnedAlignedBuffer(max(offsets_bytes, 1))
    # Per-buffer marker for var-len offsets.
    trace_alloc["arrow_ipc.decode_record_batch_copy"](offsets_bytes)
    # scalar-loop → memcpy.
    if offsets_bytes > 0:
        offsets.copy_from_view_at(
            0,
            frame.view_range_ro(
                body_pos + Int(offsets_buf.offset), offsets_bytes
            ),
        )
    offsets.set_length(Int64(offsets_bytes))


    # Copy data buffer.
    var data_bytes = Int(data_buf.length)
    var data = OwnedAlignedBuffer(max(data_bytes, 1))
    # Per-buffer marker for var-len data.
    trace_alloc["arrow_ipc.decode_record_batch_copy"](data_bytes)
    # scalar-loop → memcpy.
    if data_bytes > 0:
        data.copy_from_view_at(
            0,
            frame.view_range_ro(
                body_pos + Int(data_buf.offset), data_bytes
            ),
        )
    data.set_length(Int64(data_bytes))


    return Column[HeapRegion](
        arrow_type=arrow_type,
        data=data^,
        offsets=offsets^,
        validity=validity^,
        length=length,
        null_count=null_count,
        offset=0,
    )


def _maybe_decode_validity_bitmap(
    validity_buf: BufferDescriptor,
    length: Int,
    null_count: Int,
    node_index: Int,
    frame: SharedAlignedBuffer[HeapRegion],
    body_pos: Int,
) raises -> Optional[Bitmap[HeapRegion]]:
    """Decode a validity bitmap from the body. Returns None when the
    Buffer entry's length is 0 (encoder's signal for "all non-null"),
    which is refused when the node declares nulls."""
    if not validity_present(
        "_maybe_decode_validity_bitmap", node_index,
        Int(validity_buf.length), length, null_count,
    ):
        return None
    var bytes = checked_bitmap_bytes(
        "_maybe_decode_validity_bitmap", node_index, "bitmap buffer", length
    )
    var bm = Bitmap.create(length)
    # Per-buffer marker for the validity
    # bitmap (copy-on-read path).
    trace_alloc["arrow_ipc.decode_record_batch_copy"](bytes)
    # scalar-loop → memcpy.
    if bytes > 0:
        bm.buffer.copy_from_view_at(
            0,
            frame.view_range_ro(
                body_pos + Int(validity_buf.offset), bytes
            ),
        )
    bm.buffer.set_length(bytes)

    return bm^


def _varlen_offset_width(arrow_type: ArrowType) -> Int:
    """Offset width of a STRING/BINARY (4) or LARGE_STRING/LARGE_BINARY (8)
    column."""
    if (
        arrow_type == ArrowType.LARGE_STRING
        or arrow_type == ArrowType.LARGE_BINARY
    ):
        return 8
    return 4


# =============================================================================
# Type → buffer/node count tables
# =============================================================================


def _node_count_for(arrow_type: ArrowType) raises -> Int:
    """FieldNode count for a column of this ArrowType.

    The flat decoder handles top-level Columns only. Nested types'
    FieldNode counts (parent + recursive children) belong to the nested
    decoder; this raises on nested.
    """
    # Leaf types (primitives + temporal + decimal + bool + null +
    # var-len) all emit ONE FieldNode at the column level.
    if (
        arrow_type == ArrowType.NULL
        or arrow_type == ArrowType.BOOL
        or arrow_type == ArrowType.STRING
        or arrow_type == ArrowType.BINARY
        or arrow_type == ArrowType.LARGE_STRING
        or arrow_type == ArrowType.LARGE_BINARY
    ):
        return 1
    # DICTIONARY on the wire = 1 FieldNode for the index column
    # (the dict VALUES come from the preceding DictionaryBatch frame
    # via IpcDictCache; not part of the RecordBatch's FieldNode list).
    if arrow_type == ArrowType.DICTIONARY:
        return 1
    if _fixed_width_bytes_for(arrow_type) > 0:
        return 1
    raise Error(
        "_node_count_for: ArrowType "
        + String(Int(arrow_type.type_id))
        + " not supported in the flat decoder (nested types go through "
        + "decode_record_batch_message_nested)"
    )


def _buffer_count_for(arrow_type: ArrowType) raises -> Int:
    """Buffer count for a column of this ArrowType."""
    if arrow_type == ArrowType.NULL:
        return 0
    if arrow_type == ArrowType.BOOL:
        return 2  # validity + value bitmap
    if (
        arrow_type == ArrowType.STRING
        or arrow_type == ArrowType.BINARY
        or arrow_type == ArrowType.LARGE_STRING
        or arrow_type == ArrowType.LARGE_BINARY
    ):
        return 3  # validity + offsets + data
    # DICTIONARY on the wire = validity + Int32 indices (2 buffers,
    # same shape as a fixed-width Int32 column). The dict VALUES
    # buffers live in the preceding DictionaryBatch frame's body
    # (separate Message; counted independently by _consume_dictionary
    # _batch_frame).
    if arrow_type == ArrowType.DICTIONARY:
        return 2
    if _fixed_width_bytes_for(arrow_type) > 0:
        return 2  # validity + values
    raise Error(
        "_buffer_count_for: ArrowType "
        + String(Int(arrow_type.type_id))
        + " not supported in the flat decoder"
    )


def _fixed_width_bytes_for(arrow_type: ArrowType) -> Int:
    """Return bytes-per-element for fixed-width primitive + temporal
    + decimal + intervalMDN. Returns 0 for non-fixed-width types.
    """
    # Primitives.
    if arrow_type == ArrowType.INT8 or arrow_type == ArrowType.UINT8:
        return 1
    if arrow_type == ArrowType.INT16 or arrow_type == ArrowType.UINT16:
        return 2
    if arrow_type == ArrowType.INT32 or arrow_type == ArrowType.UINT32:
        return 4
    if arrow_type == ArrowType.INT64 or arrow_type == ArrowType.UINT64:
        return 8
    if arrow_type == ArrowType.FLOAT16:
        return 2
    if arrow_type == ArrowType.FLOAT32:
        return 4
    if arrow_type == ArrowType.FLOAT64:
        return 8
    # Temporal.
    if arrow_type == ArrowType.DATE32:
        return 4
    if arrow_type == ArrowType.DATE64:
        return 8
    if (
        arrow_type == ArrowType.TIME32_S
        or arrow_type == ArrowType.TIME32_MS
    ):
        return 4
    if (
        arrow_type == ArrowType.TIME64_US
        or arrow_type == ArrowType.TIME64_NS
    ):
        return 8
    if (
        arrow_type == ArrowType.TIMESTAMP
        or arrow_type == ArrowType.TIMESTAMP_S
        or arrow_type == ArrowType.TIMESTAMP_MS
        or arrow_type == ArrowType.TIMESTAMP_US
        or arrow_type == ArrowType.TIMESTAMP_NS
    ):
        return 8
    if (
        arrow_type == ArrowType.DURATION_S
        or arrow_type == ArrowType.DURATION_MS
        or arrow_type == ArrowType.DURATION_US
        or arrow_type == ArrowType.DURATION_NS
    ):
        return 8
    if arrow_type == ArrowType.INTERVAL_YEAR_MONTH:
        return 4
    if arrow_type == ArrowType.INTERVAL_DAY_TIME:
        return 8
    if arrow_type == ArrowType.INTERVAL_MONTH_DAY_NANO:
        return 16
    # Decimal.
    if arrow_type == ArrowType.DECIMAL128:
        return 16
    if arrow_type == ArrowType.DECIMAL256:
        return 32
    return 0


# =============================================================================
# Zero-copy decoder
# =============================================================================
#
# The load-bearing read primitive for streaming checkpoint rehydrate +
# multi-node shuffle agg-partition reads. Eliminates the 2× I/O
# bandwidth penalty of copy-on-read by borrowing into the source
# frame's bytes.
#
# Contract (caller-managed lifetime — same shape as
# `PrimitiveArray.from_view`):
#   - Caller passes the source IPC frame BY-REFERENCE (`ref [bo] frame`).
#   - Decoder returns a Slab[Column] whose buffer fields BORROW into
#     `frame`'s bytes (non-owning MmapAlignedBuffer; `capacity == 0`; drops
#     are no-ops).
#   - Caller MUST keep `frame` alive while using the returned Columns.
#     The borrowed MmapAlignedBuffer's MutExternalOrigin field-type drops
#     origin tracking, so the compiler can't enforce this — caller
#     responsibility, same as the PrimitiveArray.from_view pattern.
#
# Coverage:
#   - All-non-null fixed-width primitives (Int*, UInt*, Float*, Date*,
#     Time*, Timestamp*, Duration*, Interval_*, Decimal128/256)
#   - All-non-null var-len (STRING, BINARY, LARGE_STRING, LARGE_BINARY)
#   - NULL columns (no data buffer)
#
# Out of scope (raise to copy-on-read fallback):
#   - Nullable columns (columns with null_count > 0 raise)
#   - BOOL (1-bit-packed; can't zero-copy without per-byte unpacking)
#   - Nested (see the nested zero-copy decoder below)
#
# Alignment caveat: the borrowed MmapAlignedBuffer is typed as
# `MmapAlignedBuffer[64]` but the source bytes may only be 8-byte-aligned
# (FB spec minimum). Byte-granular reads via `read_u32_le_at` etc.
# work safely; SIMD aligned-load code paths would not (would need a
# realignment shim). This decoder uses byte-granular reads.


def decode_record_batch_zerocopy[
    bo: Origin[mut=False]
](
    ref [bo] frame: SharedAlignedBuffer[HeapRegion],
    schema_types: List[ArrowType],
) raises -> Slab[Column[HeapRegion]]:
    """Zero-copy decode an Arrow IPC RecordBatch message into a list of
    Columns whose buffers borrow into `frame`'s bytes.

    See module-level header for the caller-lifetime contract + coverage.

    Raises on:
      - Schema mismatch (FieldNode/Buffer count vs schema_types)
      - Nullable columns (null_count > 0) — use decode_record_batch_message
        (copy-on-read) instead, or wait for
        ZEROCOPY.
      - BOOL columns — use copy-on-read.
      - Nested types — use copy-on-read.

    Emits a single
    `arrow_ipc.decode_record_batch_zerocopy` marker at entry with
    `bytes=0` to advertise the zero-copy contract to an allocation
    gate (strict-zero on `Arrow[Uncompressed]`).
    """
    # Zero-copy claim marker (0 bytes
    # advertises "this site allocates no column buffer memory").
    trace_alloc["arrow_ipc.decode_record_batch_zerocopy"](0)
    # 1. Parse outer IPC framing.
    var f = parse_ipc_message(frame)

    # 2. FB metadata: still requires a fresh copy because FlatbufReader
    #    needs its own MmapAlignedBuffer with root_offset anchored at byte 0.
    #    The METADATA is tiny (~few hundred bytes for typical batch); this
    #    is NOT the hot path we're optimizing. The body bytes — where the
    #    real I/O bandwidth lives — are borrowed below.
    var fb = SharedAlignedBuffer[HeapRegion].heap_owned(f.metadata_size)
    for i in range(f.metadata_size):
        fb.write_u8_at(i, frame.read_u8_at(f.metadata_pos + i))
    fb.set_length(f.metadata_size)

    var reader = flatbuf_reader_over(fb)

    var msg = read_message(reader, reader.read_root_offset())
    if msg.header_tag != MESSAGE_HEADER_RECORD_BATCH:
        raise Error(
            "decode_record_batch_zerocopy: expected RECORD_BATCH header "
            "(tag "
            + String(Int(MESSAGE_HEADER_RECORD_BATCH))
            + "), got "
            + String(Int(msg.header_tag))
        )

    var rb = read_record_batch(reader, msg.header_table_pos)
    var n_cols = len(schema_types)

    var expected_node_count = 0
    var expected_buffer_count = 0
    for i in range(n_cols):
        var t = schema_types[i]
        expected_node_count += _node_count_for(t)
        expected_buffer_count += _buffer_count_for(t)
    if len(rb.nodes) != expected_node_count:
        raise Error(
            "decode_record_batch_zerocopy: FieldNode count mismatch (got "
            + String(len(rb.nodes))
            + ", expected "
            + String(expected_node_count)
            + ")"
        )
    if len(rb.buffers) != expected_buffer_count:
        raise Error(
            "decode_record_batch_zerocopy: Buffer count mismatch (got "
            + String(len(rb.buffers))
            + ", expected "
            + String(expected_buffer_count)
            + ")"
        )

    # 2b. ROBUSTNESS: validate Buffer descriptors against the
    # body BEFORE building borrowed-view columns. Same gate as the
    # copy-on-read path — a corrupt Buffer.offset/length past the frame
    # would otherwise OOB-read through `view_range_ro` (release-elided
    # debug_assert). Clean raise instead of SIGSEGV.
    _validate_rb_buffers_in_bounds(
        rb.buffers, f.body_pos, frame.len(),
        "decode_record_batch_zerocopy",
    )
    # 2c. ROBUSTNESS: the borrowed columns below are sized from the FieldNode
    # lengths and nothing is read while they are built, so a node that lies
    # about its length (or a buffer short of it) yields columns that read
    # past their buffers. Refuse both before the first borrow.
    check_top_level_nodes(
        "decode_record_batch_zerocopy", rb.nodes, Int(rb.length)
    )

    # 3. Per-column dispatch. Each arm constructs a Column via
    #    Column.from_borrowed_* — buffers point into frame's bytes.
    var columns = Slab[Column[HeapRegion]]()
    var node_idx = 0
    var buf_idx = 0
    for i in range(n_cols):
        var t = schema_types[i]
        ref node = rb.nodes[node_idx]
        var length = Int(node.length)
        var null_count = Int(node.null_count)

        # NULL: no buffers, no body bytes to borrow. Construct an empty
        # Column directly.
        if t == ArrowType.NULL:
            columns.append(
                Column[HeapRegion](
                    arrow_type=ArrowType.NULL,
                    data=OwnedAlignedBuffer(0),
                    offsets=None,
                    validity=None,
                    length=length,
                    null_count=length,
                    offset=0,
                )
            )
            node_idx += 1
            continue

        # BOOL + nested still raise for v1 zero-copy (caller falls
        # back to copy-on-read decode_record_batch_message). Nullable
        # is now supported via
        if t == ArrowType.BOOL:
            raise Error(
                "decode_record_batch_zerocopy: BOOL columns not zero-copy "
                "(1-bit packed; use decode_record_batch_message copy-on-read)"
            )

        # Fixed-width primitive: 2 buffers (validity + values). Borrow
        # the values buffer. If null_count > 0, also borrow the validity
        # buffer.
        var fixed_width = _fixed_width_bytes_for(t)
        if fixed_width > 0:
            ref validity_desc = rb.buffers[buf_idx]
            ref values_desc = rb.buffers[buf_idx + 1]
            check_buffer_size(
                "decode_record_batch_zerocopy", node_idx, "values",
                Int(values_desc.length),
                checked_size_mul(
                    "decode_record_batch_zerocopy", node_idx, "values buffer",
                    length, fixed_width,
                ),
                length,
            )
            _ = validity_present(
                "decode_record_batch_zerocopy", node_idx,
                Int(validity_desc.length), length, null_count,
            )
            var values_view = frame.view_range_ro(
                f.body_pos + Int(values_desc.offset),
                Int(values_desc.length),
            )
            if null_count == 0:
                columns.append(
                    Column.from_borrowed_primitive_no_nulls(
                        t, values_view, length
                    )
                )
            else:
                var validity_view = frame.view_range_ro(
                    f.body_pos + Int(validity_desc.offset),
                    Int(validity_desc.length),
                )
                columns.append(
                    Column.from_borrowed_primitive_nullable(
                        t, values_view, validity_view, length, null_count
                    )
                )
            node_idx += 1
            buf_idx += 2
            continue

        # Var-len (STRING/BINARY/LARGE_STRING/LARGE_BINARY): 3 buffers
        # (validity + offsets + data). Borrow offsets + data; validity
        # only if null_count > 0.
        if (
            t == ArrowType.STRING
            or t == ArrowType.BINARY
            or t == ArrowType.LARGE_STRING
            or t == ArrowType.LARGE_BINARY
        ):
            ref validity_desc = rb.buffers[buf_idx]
            ref offsets_desc = rb.buffers[buf_idx + 1]
            ref data_desc = rb.buffers[buf_idx + 2]
            check_buffer_size(
                "decode_record_batch_zerocopy", node_idx, "offsets",
                Int(offsets_desc.length),
                varlen_offsets_bytes(
                    "decode_record_batch_zerocopy", node_idx, length,
                    _varlen_offset_width(t),
                ),
                length,
            )
            _ = validity_present(
                "decode_record_batch_zerocopy", node_idx,
                Int(validity_desc.length), length, null_count,
            )
            var offsets_view = frame.view_range_ro(
                f.body_pos + Int(offsets_desc.offset),
                Int(offsets_desc.length),
            )
            var data_view = frame.view_range_ro(
                f.body_pos + Int(data_desc.offset),
                Int(data_desc.length),
            )
            if null_count == 0:
                columns.append(
                    Column.from_borrowed_varlen_no_nulls(
                        t, data_view, offsets_view, length
                    )
                )
            else:
                var validity_view = frame.view_range_ro(
                    f.body_pos + Int(validity_desc.offset),
                    Int(validity_desc.length),
                )
                columns.append(
                    Column.from_borrowed_varlen_nullable(
                        t,
                        data_view,
                        offsets_view,
                        validity_view,
                        length,
                        null_count,
                    )
                )
            node_idx += 1
            buf_idx += 3
            continue

        raise Error(
            "decode_record_batch_zerocopy: ArrowType "
            + String(Int(t.type_id))
            + " not supported in the flat zero-copy decoder (nested types "
            + "go through the nested zero-copy decoder)"
        )

    return columns^


# =============================================================================
# Nested decoder
# =============================================================================
#
# Symmetric decode for LIST / LARGE_LIST / STRUCT / MAP / UNION_SPARSE /
# UNION_DENSE — inverse of ipc_encoder_nested. Recursive via direct
# self-call (same canonical Mojo pattern as the encoder).
#
# Copy-on-read; the zero-copy variant is the nested zero-copy decoder.
#
# DICTIONARY decode requires reading the preceding DictionaryBatch
# message.


@fieldwise_init
struct _NestedDecodeCursor(Movable):
    """Carrier for nested decode: returned Column[HeapRegion] + advanced cursors.

    `next_view_col_idx` tracks which view-typed column we are on next
    (used to index into RecordBatch.variadicBufferCounts). Bumped by
    one for each BinaryView/Utf8View/ListView/LargeListView column
    encountered during the recursive walk.
    """
    var column: Column[HeapRegion]
    var next_node_idx: Int
    var next_buffer_idx: Int
    var next_view_col_idx: Int


def decode_record_batch_message_nested(
    var frame: SharedAlignedBuffer[HeapRegion],
    var schema_specs: Slab[ColumnTypeSpec],
) raises -> Slab[Column[HeapRegion]]:
    """Decode an Arrow IPC RecordBatch message into a list of Columns,
    with support for nested types (LIST / LARGE_LIST / STRUCT / MAP /
    UNION_SPARSE / UNION_DENSE).

    Serial-fallback wrapper. See `decode_record_batch_message_nested_with_
    dispatcher` for the dispatcher-aware variant that drives the per-
    buffer decompress in parallel.

    Inverse of `encode_record_batch_message` for the nested cases.
    Caller passes `schema_specs: List[ColumnTypeSpec]` describing
    each top-level column's full tree (including children for nested).

    For flat-only columns (primitives + var-len), the existing
    `decode_record_batch_message(frame, schema_types: List[ArrowType])`
    is slightly simpler — but this nested variant is a strict
    superset (handles flat too).

    Per-buffer body decompression uses the
    same `_decompress_frame_if_needed` helper used by
    `decode_record_batch_message`. Codec dispatch is by wire-detected
    BodyCompression.codec id (-1 = no-op, 0 = LZ4_FRAME, 1 = ZSTD).

    Same instrumentation
    shape as the flat copy-on-read path -- entry marker plus per-buffer
    markers inside the column builders.
    """
    # Class C: serial-fallback substitutes D=NoDispatch with a CONCRETE
    # origin, NOT MutAnyOrigin.
    var _nd = NoDispatch()
    comptime nd_o = origin_of(_nd)
    return _decode_record_batch_message_nested_impl[
        NoDispatch, has_pool=False, disp_o=nd_o,
    ](
        frame^,
        schema_specs^,
        Optional[Pointer[NoDispatch, nd_o]](None),
        CancellationToken.never(),
    )


def decode_record_batch_message_nested_with_dispatcher[
    D: ParallelDispatch,
    disp_o: Origin[mut=True],
](
    var frame: SharedAlignedBuffer[HeapRegion],
    var schema_specs: Slab[ColumnTypeSpec],
    dispatcher_ptr: Pointer[D, disp_o],
    var cancel_token: CancellationToken,
) raises -> Slab[Column[HeapRegion]]:
    """Dispatcher-aware variant of `decode_record_batch_message_nested`.


    """
    return _decode_record_batch_message_nested_impl[
        D, has_pool=True, disp_o=disp_o,
    ](
        frame^,
        schema_specs^,
        Optional[Pointer[D, disp_o]](dispatcher_ptr),
        cancel_token^,
    )


def _decode_record_batch_message_nested_impl[
    D: ParallelDispatch,
    has_pool: Bool,
    disp_o: Origin[mut=True],
](
    var frame: SharedAlignedBuffer[HeapRegion],
    var schema_specs: Slab[ColumnTypeSpec],
    dispatcher_ptr: Optional[Pointer[D, disp_o]],
    var cancel_token: CancellationToken,
) raises -> Slab[Column[HeapRegion]]:
    """Shared body for the bare + `_with_dispatcher` `decode_record_batch_
    message_nested` variants. Comptime `has_pool` prunes the parallel-
    decompress branch."""
    # Nested-decode copy-on-read entry.
    trace_alloc["arrow_ipc.decode_record_batch_copy"](0)
    var working_frame: SharedAlignedBuffer[HeapRegion]

    comptime if has_pool:
        working_frame = _decompress_frame_if_needed_with_dispatcher[D, disp_o](
            frame^, dispatcher_ptr.value(), cancel_token^,
        )
    else:
        _ = cancel_token^
        working_frame = _decompress_frame_if_needed(frame^)
    var f = parse_ipc_message(working_frame)

    var fb = SharedAlignedBuffer[HeapRegion].heap_owned(f.metadata_size)
    for i in range(f.metadata_size):
        fb.write_u8_at(i, working_frame.read_u8_at(f.metadata_pos + i))
    fb.set_length(f.metadata_size)

    var reader = flatbuf_reader_over(fb)

    var msg = read_message(reader, reader.read_root_offset())
    if msg.header_tag != MESSAGE_HEADER_RECORD_BATCH:
        raise Error(  # cov: unreachable peek_record_batch_codec_from_frame refused a non-RecordBatch frame first
            "decode_record_batch_message_nested: expected RECORD_BATCH "  # cov: unreachable peek_record_batch_codec_from_frame refused a non-RecordBatch frame first
            "header (tag "
            + String(Int(MESSAGE_HEADER_RECORD_BATCH))  # cov: unreachable peek_record_batch_codec_from_frame refused a non-RecordBatch frame first
            + "), got "  # cov: unreachable peek_record_batch_codec_from_frame refused a non-RecordBatch frame first
            + String(Int(msg.header_tag))  # cov: unreachable peek_record_batch_codec_from_frame refused a non-RecordBatch frame first
        )

    var rb = read_record_batch(reader, msg.header_table_pos)
    # ROBUSTNESS: the same Buffer-descriptor gate as the flat decoders, before
    # any column reads the body (`view_range_ro` only debug_asserts).
    _validate_rb_buffers_in_bounds(
        rb.buffers, f.body_pos, working_frame.len(),
        "decode_record_batch_message_nested",
    )
    var n_cols = len(schema_specs)
    var rb_length = Int(rb.length)
    check_record_batch_length("decode_record_batch_message_nested", rb_length)

    var columns = Slab[Column[HeapRegion]]()
    var node_idx = 0
    var buf_idx = 0
    var view_col_idx = 0
    for i in range(n_cols):
        # ROBUSTNESS: a top-level column must have the batch's length; inner
        # nodes are checked where they are read.
        check_node_index(
            "decode_record_batch_message_nested",
            node_idx,
            len(rb.nodes),
        )
        check_top_level_node(
            "decode_record_batch_message_nested",
            i,
            node_idx,
            Int(rb.nodes[node_idx].length),
            Int(rb.nodes[node_idx].null_count),
            rb_length,
        )
        var cursor = _decode_column_nested(
            schema_specs[i],
            rb.nodes,
            rb.buffers,
            node_idx,
            buf_idx,
            view_col_idx,
            rb.variadic_buffer_counts,
            working_frame,
            f.body_pos,
        )
        node_idx = cursor.next_node_idx
        buf_idx = cursor.next_buffer_idx
        view_col_idx = cursor.next_view_col_idx
        var col_out = Column[HeapRegion]()
        swap(cursor.column, col_out)
        columns.append(col_out^)

    return columns^


def _decode_column_nested(
    spec: ColumnTypeSpec,
    nodes: List[FieldNode],
    buffers: List[BufferDescriptor],
    node_idx: Int,
    buffer_idx: Int,
    view_col_idx: Int,
    variadic_buffer_counts: List[Int64],
    frame: SharedAlignedBuffer[HeapRegion],
    body_pos: Int,
) raises -> _NestedDecodeCursor:
    """Recursive per-column decode. Walks pre-order: parent's FieldNode +
    buffers first, then each child via self-call.

    `view_col_idx` indexes into `variadic_buffer_counts`. Each view-typed
    column (BINARY_VIEW / UTF8_VIEW / LIST_VIEW / LARGE_LIST_VIEW) bumps
    it by 1. Non-view children re-emit the same index.
    """
    var t = spec.arrow_type
    # ROBUSTNESS: this walk follows the schema, not a node count, and every
    # buffer size below is formed from this node's length.
    check_node_index("_decode_column_nested", node_idx, len(nodes))
    ref n = nodes[node_idx]
    var length = Int(n.length)
    var null_count = Int(n.null_count)
    check_field_node("_decode_column_nested", node_idx, length, null_count)
    # ROBUSTNESS: the Buffer list is the message's; refuse a node whose
    # descriptors it does not carry before an arm indexes one.
    check_node_buffers(
        "_decode_column_nested",
        node_idx,
        buffer_idx,
        nested_node_buffer_count(
            t,
            len(spec.children),
            spec.inner_size,
            _fixed_width_bytes_for(t),
            view_col_idx,
            variadic_buffer_counts,
            zerocopy=False,
        ),
        len(buffers),
    )

    # Leaf cases (NULL / fixed-width primitive / BOOL / var-len) — delegate
    # to the flat _decode_column helper. Same shape as the flat decoder.
    if (
        t == ArrowType.NULL
        or _fixed_width_bytes_for(t) > 0
        or t == ArrowType.BOOL
        or t == ArrowType.STRING
        or t == ArrowType.BINARY
        or t == ArrowType.LARGE_STRING
        or t == ArrowType.LARGE_BINARY
    ):
        var leaf = _decode_column(
            t, nodes, buffers, node_idx, buffer_idx, frame, body_pos, length
        )
        var col_out = Column[HeapRegion]()
        swap(leaf.column, col_out)
        return _NestedDecodeCursor(
            column=col_out^,
            next_node_idx=leaf.next_node_idx,
            next_buffer_idx=leaf.next_buffer_idx,
            next_view_col_idx=view_col_idx,
        )

    # FIXED_SIZE_BINARY: byte_width per row from
    # spec.inner_size (not in _fixed_width_bytes_for because it's
    # data-dependent, not ArrowType-dependent). Same buffer layout as
    # primitives: validity + N-byte values.
    if t == ArrowType.FIXED_SIZE_BINARY:
        if spec.inner_size <= 0:
            raise Error(
                "_decode_column_nested FIXED_SIZE_BINARY: spec.inner_size "
                "must be > 0 (use ColumnTypeSpec.fixed_size_binary(byte_width))"
            )
        var col = _build_fixed_width_column(
            ArrowType.FIXED_SIZE_BINARY,
            length,
            null_count,
            spec.inner_size,
            buffers[buffer_idx],     # validity
            buffers[buffer_idx + 1], # values
            frame,
            body_pos,
            node_idx,
        )
        col._inner_size = spec.inner_size
        return _NestedDecodeCursor(
            column=col^,
            next_node_idx=node_idx + 1,
            next_buffer_idx=buffer_idx + 2,
            next_view_col_idx=view_col_idx,
        )

    # FIXED_SIZE_LIST: validity ONLY + 1 child of
    # `length * list_size` rows. NO offsets per Arrow spec.
    if t == ArrowType.FIXED_SIZE_LIST:
        if spec.inner_size <= 0:
            raise Error(
                "_decode_column_nested FIXED_SIZE_LIST: spec.inner_size "
                "(list_size) must be > 0 (use "
                "ColumnTypeSpec.fixed_size_list_of(inner, list_size))"
            )
        if len(spec.children) != 1:
            raise Error(
                "_decode_column_nested FIXED_SIZE_LIST: expected 1 child"
            )
        var col = _build_struct_column(
            length,
            null_count,
            buffers[buffer_idx],  # validity (the only buffer)
            frame,
            body_pos,
            node_idx,
        )
        # _build_struct_column produces arrow_type=STRUCT; fix-up to
        # FIXED_SIZE_LIST + carry _inner_size.
        col.arrow_type = ArrowType.FIXED_SIZE_LIST
        col._inner_size = spec.inner_size
        var child_cursor = _decode_column_nested(
            spec.children[0],
            nodes,
            buffers,
            node_idx + 1,
            buffer_idx + 1,
            view_col_idx,
            variadic_buffer_counts,
            frame,
            body_pos,
        )
        var child_out = Column[HeapRegion]()
        swap(child_cursor.column, child_out)
        # Validate child row count = length * list_size, formed without
        # wrapping (a wrapped product could equal a small child length).
        var fsl_child_rows = checked_size_mul(
            "_decode_column_nested FIXED_SIZE_LIST", node_idx, "child rows",
            length, spec.inner_size,
        )
        if child_out._length != fsl_child_rows:
            raise Error(
                "_decode_column_nested FIXED_SIZE_LIST: decoded child "
                "length "
                + String(child_out._length)
                + " != length * list_size = "
                + String(fsl_child_rows)
            )
        col._children.append(child_out^)
        return _NestedDecodeCursor(
            column=col^,
            next_node_idx=child_cursor.next_node_idx,
            next_buffer_idx=child_cursor.next_buffer_idx,
            next_view_col_idx=child_cursor.next_view_col_idx,
        )

    # LIST / LARGE_LIST: validity + Int32/Int64 offsets + 1 child.
    # LARGE_LIST re-wired by
    if t == ArrowType.LIST or t == ArrowType.LARGE_LIST:
        var offset_bytes = 4 if t == ArrowType.LIST else 8
        var col = _build_list_column(
            t,
            length,
            null_count,
            offset_bytes,
            buffers[buffer_idx],     # validity
            buffers[buffer_idx + 1], # offsets
            frame,
            body_pos,
            node_idx,
        )
        var next_node = node_idx + 1
        var next_buf = buffer_idx + 2
        if len(spec.children) != 1:
            raise Error(
                "_decode_column_nested LIST: spec.children count "
                + String(len(spec.children))
                + " != 1"
            )
        var child_cursor = _decode_column_nested(
            spec.children[0],
            nodes,
            buffers,
            next_node,
            next_buf,
            view_col_idx,
            variadic_buffer_counts,
            frame,
            body_pos,
        )
        var child_out = Column[HeapRegion]()
        swap(child_cursor.column, child_out)
        col._children.append(child_out^)
        return _NestedDecodeCursor(
            column=col^,
            next_node_idx=child_cursor.next_node_idx,
            next_buffer_idx=child_cursor.next_buffer_idx,
            next_view_col_idx=child_cursor.next_view_col_idx,
        )

    # STRUCT: validity only + N children.
    if t == ArrowType.STRUCT:
        var col = _build_struct_column(
            length,
            null_count,
            buffers[buffer_idx],  # validity
            frame,
            body_pos,
            node_idx,
        )
        # Copy field_names into the Column.
        for fn_i in range(len(spec.field_names)):
            col._field_names.append(spec.field_names[fn_i])
        var next_node = node_idx + 1
        var next_buf = buffer_idx + 1
        var next_view = view_col_idx
        for child_i in range(len(spec.children)):
            var child_cursor = _decode_column_nested(
                spec.children[child_i],
                nodes,
                buffers,
                next_node,
                next_buf,
                next_view,
                variadic_buffer_counts,
                frame,
                body_pos,
            )
            var child_out = Column[HeapRegion]()
            swap(child_cursor.column, child_out)
            check_struct_child_length(
                "_decode_column_nested",
                node_idx,
                length,
                child_i,
                next_node,
                child_out._length,
            )
            col._children.append(child_out^)
            next_node = child_cursor.next_node_idx
            next_buf = child_cursor.next_buffer_idx
            next_view = child_cursor.next_view_col_idx
        return _NestedDecodeCursor(
            column=col^,
            next_node_idx=next_node,
            next_buffer_idx=next_buf,
            next_view_col_idx=next_view,
        )

    # MAP: validity + Int32 offsets + 1 entries-STRUCT child.
    if t == ArrowType.MAP:
        var col = _build_list_column(
            ArrowType.MAP,
            length,
            null_count,
            4,
            buffers[buffer_idx],
            buffers[buffer_idx + 1],
            frame,
            body_pos,
            node_idx,
        )
        var next_node = node_idx + 1
        var next_buf = buffer_idx + 2
        if len(spec.children) != 1:
            raise Error("_decode_column_nested MAP: expected 1 child")
        var child_cursor = _decode_column_nested(
            spec.children[0],
            nodes,
            buffers,
            next_node,
            next_buf,
            view_col_idx,
            variadic_buffer_counts,
            frame,
            body_pos,
        )
        var child_out = Column[HeapRegion]()
        swap(child_cursor.column, child_out)
        col._children.append(child_out^)
        return _NestedDecodeCursor(
            column=col^,
            next_node_idx=child_cursor.next_node_idx,
            next_buffer_idx=child_cursor.next_buffer_idx,
            next_view_col_idx=child_cursor.next_view_col_idx,
        )

    # UNION_SPARSE: type_ids only (NO validity) + N children.
    if t == ArrowType.UNION_SPARSE:
        var col = _build_union_sparse_column(
            length,
            null_count,
            buffers[buffer_idx],  # type_ids
            frame,
            body_pos,
        )
        var next_node = node_idx + 1
        var next_buf = buffer_idx + 1
        var next_view = view_col_idx
        for child_i in range(len(spec.children)):
            var child_cursor = _decode_column_nested(
                spec.children[child_i],
                nodes,
                buffers,
                next_node,
                next_buf,
                next_view,
                variadic_buffer_counts,
                frame,
                body_pos,
            )
            var child_out = Column[HeapRegion]()
            swap(child_cursor.column, child_out)
            col._children.append(child_out^)
            next_node = child_cursor.next_node_idx
            next_buf = child_cursor.next_buffer_idx
            next_view = child_cursor.next_view_col_idx
        for ti in range(len(spec.type_ids)):
            col._type_ids.append(spec.type_ids[ti])
        return _NestedDecodeCursor(
            column=col^,
            next_node_idx=next_node,
            next_buffer_idx=next_buf,
            next_view_col_idx=next_view,
        )

    # UNION_DENSE: type_ids + offsets + N children.
    if t == ArrowType.UNION_DENSE:
        var col = _build_union_dense_column(
            length,
            null_count,
            buffers[buffer_idx],     # type_ids
            buffers[buffer_idx + 1], # offsets
            frame,
            body_pos,
            node_idx,
        )
        var next_node = node_idx + 1
        var next_buf = buffer_idx + 2
        var next_view = view_col_idx
        for child_i in range(len(spec.children)):
            var child_cursor = _decode_column_nested(
                spec.children[child_i],
                nodes,
                buffers,
                next_node,
                next_buf,
                next_view,
                variadic_buffer_counts,
                frame,
                body_pos,
            )
            var child_out = Column[HeapRegion]()
            swap(child_cursor.column, child_out)
            col._children.append(child_out^)
            next_node = child_cursor.next_node_idx
            next_buf = child_cursor.next_buffer_idx
            next_view = child_cursor.next_view_col_idx
        for ti in range(len(spec.type_ids)):
            col._type_ids.append(spec.type_ids[ti])
        return _NestedDecodeCursor(
            column=col^,
            next_node_idx=next_node,
            next_buffer_idx=next_buf,
            next_view_col_idx=next_view,
        )

    # BINARY_VIEW / UTF8_VIEW:
    # 2 fixed buffers (validity + 16-byte view) + N variadic data
    # buffers. variadic count from variadic_buffer_counts[view_col_idx].
    # Lossy-expanded into BINARY / STRING.
    if t == ArrowType.BINARY_VIEW or t == ArrowType.UTF8_VIEW:
        if view_col_idx >= len(variadic_buffer_counts):
            raise Error(
                "_decode_column_nested view: view_col_idx "
                + String(view_col_idx)
                + " out of range; variadic_buffer_counts has "
                + String(len(variadic_buffer_counts))
                + " entries"
            )
        var n_variadic = Int(variadic_buffer_counts[view_col_idx])
        if n_variadic < 0:
            raise Error("variadic_buffer_counts entry must be non-negative")
        var variadic_descs = List[BufferDescriptor]()
        variadic_descs.reserve(n_variadic)
        for vi in range(n_variadic):
            variadic_descs.append(buffers[buffer_idx + 2 + vi].copy())
        var out_type = (
            ArrowType.STRING if t == ArrowType.UTF8_VIEW
            else ArrowType.BINARY
        )
        # The RecordBatch body has no field names — they live in the
        # Schema message, which this decoder never sees. The field-node
        # index + wire type is the most specific column identity
        # available here, and it is what an operator needs to find the
        # offending column in the schema.
        var col_label = (
            String("field node #")
            + String(node_idx)
            + String(
                " (UTF8_VIEW)" if t == ArrowType.UTF8_VIEW
                else " (BINARY_VIEW)"
            )
        )
        var col = _decode_binary_or_utf8_view(
            out_type,
            col_label,
            length,
            null_count,
            buffers[buffer_idx],     # validity
            buffers[buffer_idx + 1], # 16-byte view buffer
            variadic_descs,
            frame,
            body_pos,
            node_idx,
        )
        return _NestedDecodeCursor(
            column=col^,
            next_node_idx=node_idx + 1,
            next_buffer_idx=buffer_idx + 2 + n_variadic,
            next_view_col_idx=view_col_idx + 1,
        )

    # LIST_VIEW / LARGE_LIST_VIEW:
    # validity + offsets + sizes + 1 child. Decoded into expanded
    # LIST / LARGE_LIST cumulative offsets. Requires in-order
    # non-overlapping ranges; overlapping is not supported.
    if t == ArrowType.LIST_VIEW or t == ArrowType.LARGE_LIST_VIEW:
        if len(spec.children) != 1:
            raise Error(
                "_decode_column_nested ListView: spec.children count "
                + String(len(spec.children))
                + " != 1"
            )
        var offset_bytes = 4 if t == ArrowType.LIST_VIEW else 8
        var out_type = (
            ArrowType.LIST if t == ArrowType.LIST_VIEW
            else ArrowType.LARGE_LIST
        )
        var lv_label = (
            String("field node #")
            + String(node_idx)
            + String(
                " (LIST_VIEW)" if t == ArrowType.LIST_VIEW
                else " (LARGE_LIST_VIEW)"
            )
        )
        var col = _decode_list_view(
            out_type,
            lv_label,
            offset_bytes,
            length,
            null_count,
            buffers[buffer_idx],     # validity
            buffers[buffer_idx + 1], # offsets
            buffers[buffer_idx + 2], # sizes
            frame,
            body_pos,
            node_idx,
        )
        # ListView / LargeListView do NOT consume variadic_buffer_counts
        # entries — that field is only populated by BinaryView / Utf8View
        # per the Arrow Columnar Format spec. Re-emit view_col_idx unchanged.
        var child_cursor = _decode_column_nested(
            spec.children[0],
            nodes,
            buffers,
            node_idx + 1,
            buffer_idx + 3,
            view_col_idx,
            variadic_buffer_counts,
            frame,
            body_pos,
        )
        var child_out = Column[HeapRegion]()
        swap(child_cursor.column, child_out)
        col._children.append(child_out^)
        return _NestedDecodeCursor(
            column=col^,
            next_node_idx=child_cursor.next_node_idx,
            next_buffer_idx=child_cursor.next_buffer_idx,
            next_view_col_idx=child_cursor.next_view_col_idx,
        )

    raise Error(
        "_decode_column_nested: ArrowType "
        + String(Int(t.type_id))
        + " not supported (DICTIONARY needs the preceding DictionaryBatch)"
    )


# =============================================================================
# Per-nested-arm Column builders (copy-on-read)
# =============================================================================


def _build_list_column(
    arrow_type: ArrowType,
    length: Int,
    null_count: Int,
    offset_bytes: Int,
    validity_desc: BufferDescriptor,
    offsets_desc: BufferDescriptor,
    frame: SharedAlignedBuffer[HeapRegion],
    body_pos: Int,
    node_index: Int,
) raises -> Column[HeapRegion]:
    """Build a LIST/LARGE_LIST/MAP Column[HeapRegion] (validity + offsets only — child
    is appended by the caller after recursive decode)."""
    var validity = _maybe_decode_validity_bitmap(
        validity_desc, length, null_count, node_index, frame, body_pos
    )
    var offsets_bytes = checked_offsets_bytes(
        "_build_list_column", node_index, "offsets buffer", length, offset_bytes
    )
    check_buffer_size(
        "_build_list_column", node_index, "offsets",
        Int(offsets_desc.length), offsets_bytes, length,
    )
    var offsets = OwnedAlignedBuffer(max(offsets_bytes, 1))
    for i in range(offsets_bytes):
        offsets.write_u8_at(
            i, frame.read_u8_at(body_pos + Int(offsets_desc.offset) + i)
        )
    offsets.set_length(Int64(offsets_bytes))

    return Column[HeapRegion](
        arrow_type=arrow_type,
        data=OwnedAlignedBuffer(0),
        offsets=offsets^,
        validity=validity^,
        length=length,
        null_count=null_count,
        offset=0,
    )


def _build_struct_column(
    length: Int,
    null_count: Int,
    validity_desc: BufferDescriptor,
    frame: SharedAlignedBuffer[HeapRegion],
    body_pos: Int,
    node_index: Int,
) raises -> Column[HeapRegion]:
    """Build a STRUCT Column[HeapRegion] (validity only — no value/offset buffers;
    children appended by caller)."""
    var validity = _maybe_decode_validity_bitmap(
        validity_desc, length, null_count, node_index, frame, body_pos
    )
    return Column[HeapRegion](
        arrow_type=ArrowType.STRUCT,
        data=OwnedAlignedBuffer(0),
        offsets=None,
        validity=validity^,
        length=length,
        null_count=null_count,
        offset=0,
    )


def _build_union_sparse_column(
    length: Int,
    null_count: Int,
    type_ids_desc: BufferDescriptor,
    frame: SharedAlignedBuffer[HeapRegion],
    body_pos: Int,
) raises -> Column[HeapRegion]:
    """Build a UNION_SPARSE Column[HeapRegion] (Int8 type_ids in _data; NO validity
    per Arrow spec)."""
    var type_ids_bytes = length
    var got = Int(type_ids_desc.length)
    if got < type_ids_bytes:
        raise Error(
            "_build_union_sparse_column: type_ids buffer too small (got "
            + String(got)
            + ", expected "
            + String(type_ids_bytes)
            + ")"
        )
    var data = OwnedAlignedBuffer(max(type_ids_bytes, 1))
    for i in range(type_ids_bytes):
        data.write_u8_at(
            i, frame.read_u8_at(body_pos + Int(type_ids_desc.offset) + i)
        )
    data.set_length(Int64(type_ids_bytes))

    return Column[HeapRegion](
        arrow_type=ArrowType.UNION_SPARSE,
        data=data^,
        offsets=None,
        validity=None,
        length=length,
        null_count=null_count,
        offset=0,
    )


def _build_union_dense_column(
    length: Int,
    null_count: Int,
    type_ids_desc: BufferDescriptor,
    offsets_desc: BufferDescriptor,
    frame: SharedAlignedBuffer[HeapRegion],
    body_pos: Int,
    node_index: Int,
) raises -> Column[HeapRegion]:
    """Build a UNION_DENSE Column[HeapRegion] (Int8 type_ids in _data + Int32 offsets;
    NO validity per Arrow spec)."""
    var type_ids_bytes = length
    var offsets_bytes = checked_size_mul(
        "_build_union_dense_column", node_index, "offsets buffer", length, 4
    )
    if Int(type_ids_desc.length) < type_ids_bytes:
        raise Error("_build_union_dense_column: type_ids buffer too small")
    if Int(offsets_desc.length) < offsets_bytes:
        raise Error("_build_union_dense_column: offsets buffer too small")
    var data = OwnedAlignedBuffer(max(type_ids_bytes, 1))
    for i in range(type_ids_bytes):
        data.write_u8_at(
            i, frame.read_u8_at(body_pos + Int(type_ids_desc.offset) + i)
        )
    data.set_length(Int64(type_ids_bytes))

    var offsets = OwnedAlignedBuffer(max(offsets_bytes, 1))
    for i in range(offsets_bytes):
        offsets.write_u8_at(
            i, frame.read_u8_at(body_pos + Int(offsets_desc.offset) + i)
        )
    offsets.set_length(Int64(offsets_bytes))

    return Column[HeapRegion](
        arrow_type=ArrowType.UNION_DENSE,
        data=data^,
        offsets=offsets^,
        validity=None,
        length=length,
        null_count=null_count,
        offset=0,
    )


# =============================================================================
# View-type lossy decoders
# =============================================================================
#
# View-type bytes
# (Arrow v0.15+ BinaryView / Utf8View / ListView / LargeListView)
# decode into EXPANDED native columns:
#   - BinaryView → BINARY (Int32 offsets + concatenated bytes)
#   - Utf8View   → STRING
#   - ListView   → LIST (cumulative Int32 offsets + 1 child)
#   - LargeListView → LARGE_LIST (cumulative Int64 offsets + 1 child)
#
# Lossy on round-trip: the view-vs-storage distinction is dropped on
# read. There are no native View column types.
#
# Wire layout (per Arrow Columnar Format):
#   BinaryView/Utf8View column: validity + 16-byte view buffer + N
#     variadic data buffers (count from RecordBatch.variadicBufferCounts).
#   ListView/LargeListView column: validity + offsets + sizes + 1 child.
#
# 16-byte view layout:
#   bytes [0..4) = length (i32 LE)
#   if length <= 12:
#     bytes [4..16) = inline data (zero-padded)
#   if length > 12:
#     bytes [4..8) = 4-byte prefix of the actual data
#     bytes [8..12) = buffer_idx (i32 LE) — index into variadic buffers
#     bytes [12..16) = offset within that buffer (i32 LE)


def _decode_binary_or_utf8_view(
    out_arrow_type: ArrowType,
    imm column_label: String,
    length: Int,
    null_count: Int,
    validity_desc: BufferDescriptor,
    view_desc: BufferDescriptor,
    variadic_descs: List[BufferDescriptor],
    frame: SharedAlignedBuffer[HeapRegion],
    body_pos: Int,
    node_index: Int,
) raises -> Column[HeapRegion]:
    """Lossy decode of BinaryView/Utf8View into expanded BINARY/STRING.

    Iterates the 16-byte view buffer; for each view resolves to actual
    bytes (inline or indirect via variadic buffers); builds cumulative
    Int32 offsets + flat concatenated data buffer.

    `out_arrow_type` must be ArrowType.BINARY or ArrowType.STRING (the
    expanded type). View-vs-storage distinction is dropped.

    `column_label` names the column in any raised error. The IPC
    RecordBatch body carries no field names (they live in the Schema
    message), so the caller passes the field-node index + wire type —
    the most specific identity this decoder can have.
    """
    var validity = _maybe_decode_validity_bitmap(
        validity_desc, length, null_count, node_index, frame, body_pos
    )
    var view_bytes_total = Int(view_desc.length)
    var expected_view_bytes = checked_size_mul(
        "_decode_binary_or_utf8_view", node_index, "view buffer", length, 16
    )
    if view_bytes_total < expected_view_bytes:
        raise Error(
            "_decode_binary_or_utf8_view: view buffer too small (got "
            + String(view_bytes_total)
            + ", expected "
            + String(expected_view_bytes)
            + " = length × 16)"
        )

    # First pass: compute total expanded data bytes (sum of lengths).
    #
    # THE INT32 OFFSET CEILING. The output is an expanded
    # BINARY / STRING column, whose offsets buffer is **Int32** — so
    # `offsets[N] == data_bytes_total` must fit in a signed 32-bit int.
    # `cum_offset` is summed in 64-bit `Int` and then narrowed at the
    # `Int32(cum_offset)` write below, which past 2 GiB is a silent
    # two's-complement wrap to a NEGATIVE offset while the row COUNT
    # stays exactly right. Every other producer in this tree guards that
    # narrowing with `check_int32_offsets`; this file had ZERO guards.
    # See `offset_overflow.mojo` for the full mechanism.
    #
    # Each `view_len` is an attacker-controlled Int32 off the wire, so it
    # can also be NEGATIVE. A negative length is not merely a small sum:
    # it drives `cum_offset` below zero, and the `data.write_u8_at(
    # cum_offset + b, ...)` stores below are guarded only by a
    # `debug_assert`, which is ELIDED in the ASSERT=none configuration we
    # ship — i.e. a raw heap write BEFORE the allocation, plus negative
    # offsets in the returned column. Reject non-negative-length
    # violations here, in the same pass that establishes the total, so
    # the sum that the Int32 check is applied to is genuinely monotone.
    var data_bytes_total = 0
    var view_base = body_pos + Int(view_desc.offset)
    for i in range(length):
        var view_off = view_base + i * 16
        var view_len = Int(frame.read_i32_le_at(view_off))
        if view_len < 0:
            raise Error(
                "_decode_binary_or_utf8_view: "
                + column_label
                + " view "
                + String(i)
                + " declares a NEGATIVE length of "
                + String(view_len)
                + "; Arrow BinaryView/Utf8View lengths are unsigned byte"
                " counts. A negative length drives the cumulative offset"
                " below zero, which writes below the data allocation and"
                " emits negative offsets."
            )
        data_bytes_total += view_len

    # Fail BEFORE allocating: an overflowing column raises without first
    # committing >2 GiB, and no wrapped offset is ever written.
    check_int32_offsets(
        "ipc_decoder._decode_binary_or_utf8_view",
        column_label,
        data_bytes_total,
        length,
    )

    # Allocate offsets + data buffers.
    var offsets = OwnedAlignedBuffer((length + 1) * 4)
    offsets.set_length(Int64((length + 1) * 4))

    var data = OwnedAlignedBuffer(max(data_bytes_total, 1))
    data.set_length(Int64(data_bytes_total))


    var cum_offset = 0
    offsets.write_i32_le_at(0, Int32(0))
    for i in range(length):
        var view_off = view_base + i * 16
        var view_len = Int(frame.read_i32_le_at(view_off))
        # Resolve view bytes — inline if length ≤ 12, else indirect.
        if view_len <= 12:
            # Inline bytes at view_off + 4 .. view_off + 4 + view_len.
            for b in range(view_len):
                data.write_u8_at(
                    cum_offset + b, frame.read_u8_at(view_off + 4 + b)
                )
        else:
            # Indirect: buffer_idx + offset within that buffer.
            var buf_idx = Int(frame.read_i32_le_at(view_off + 8))
            var in_off = Int(frame.read_i32_le_at(view_off + 12))
            if buf_idx < 0 or buf_idx >= len(variadic_descs):
                raise Error(
                    "_decode_binary_or_utf8_view: buffer_idx "
                    + String(buf_idx)
                    + " out of range [0, "
                    + String(len(variadic_descs))
                    + ")"
                )
            ref data_desc = variadic_descs[buf_idx]
            # `in_off` is an attacker-controlled Int32 off the wire. The
            # extent test below is a ONE-SIDED upper bound: for in_off < 0
            # it passes trivially, and `src_base` then points BEFORE the
            # variadic buffer, so the copy loop reads out of bounds. The
            # only thing standing between that and the process is
            # `read_u8_at`'s `debug_assert`, elided at ASSERT=none.
            if in_off < 0:
                raise Error(
                    "_decode_binary_or_utf8_view: "
                    + column_label
                    + " view "
                    + String(i)
                    + " declares a NEGATIVE variadic-buffer offset of "
                    + String(in_off)
                )
            if in_off + view_len > Int(data_desc.length):
                raise Error(
                    "_decode_binary_or_utf8_view: view extends past "
                    "variadic buffer end"
                )
            var src_base = body_pos + Int(data_desc.offset) + in_off
            for b in range(view_len):
                data.write_u8_at(
                    cum_offset + b, frame.read_u8_at(src_base + b)
                )
        cum_offset += view_len
        offsets.write_i32_le_at((i + 1) * 4, Int32(cum_offset))

    return Column[HeapRegion](
        arrow_type=out_arrow_type,
        data=data^,
        offsets=offsets^,
        validity=validity^,
        length=length,
        null_count=null_count,
        offset=0,
    )


def _decode_list_view(
    out_arrow_type: ArrowType,
    imm column_label: String,
    offset_bytes: Int,
    length: Int,
    null_count: Int,
    validity_desc: BufferDescriptor,
    offsets_desc: BufferDescriptor,
    sizes_desc: BufferDescriptor,
    frame: SharedAlignedBuffer[HeapRegion],
    body_pos: Int,
    node_index: Int,
) raises -> Column[HeapRegion]:
    """Lossy decode of ListView/LargeListView into expanded LIST/LARGE_LIST.

    ListView/LargeListView store parallel (offsets, sizes) buffers
    permitting out-of-order and overlapping ranges into the child
    column. The expanded LIST/LARGE_LIST form requires CUMULATIVE
    offsets (offsets[i+1] = offsets[i] + size[i]), and only supports
    in-order non-overlapping ranges.

    Raises if input ranges are not already in-order + tightly packed
    (offsets[i+1] == offsets[i] + sizes[i]). Full re-materialization of
    overlapping/out-of-order ranges (which would require copying child
    rows) is not supported.

    `out_arrow_type` must be ArrowType.LIST (offset_bytes=4) or
    ArrowType.LARGE_LIST (offset_bytes=8). View-vs-storage distinction
    is dropped.
    """
    var validity = _maybe_decode_validity_bitmap(
        validity_desc, length, null_count, node_index, frame, body_pos
    )
    var expected_off_bytes = checked_size_mul(
        "_decode_list_view", node_index, "offsets buffer", length, offset_bytes
    )
    var expected_sz_bytes = expected_off_bytes
    if Int(offsets_desc.length) < expected_off_bytes:
        raise Error(
            "_decode_list_view: offsets buffer too small (got "
            + String(Int(offsets_desc.length))
            + ", expected "
            + String(expected_off_bytes)
            + ")"
        )
    if Int(sizes_desc.length) < expected_sz_bytes:
        raise Error(
            "_decode_list_view: sizes buffer too small (got "
            + String(Int(sizes_desc.length))
            + ", expected "
            + String(expected_sz_bytes)
            + ")"
        )

    var off_base = body_pos + Int(offsets_desc.offset)
    var sz_base = body_pos + Int(sizes_desc.offset)

    # THE INT32 OFFSET CEILING, PASS 0.
    #
    # The expanded LIST output carries **Int32** cumulative offsets, so
    # `offsets[N] == sum(sizes)` must fit in a signed 32-bit int. The
    # loop below sums into a 64-bit `Int` and narrows at the
    # `Int32(cum)` write — a silent two's-complement wrap past 2 GiB.
    #
    # The in-order check `off_i != cum` does NOT close this: it pins
    # every INTERMEDIATE `cum` to an Int32-range `off_i`, but the FINAL
    # `cum` (written as `offsets[length]`, the total) is compared
    # against nothing. Two sizes of 2^30 each yield `offsets[2] ==
    # -2147483647` in a 12-byte buffer — no crash, no large allocation,
    # correct row COUNT, and `get_length(1)` garbage. That is the whole
    # silent class, reachable with 24 bytes of wire input.
    #
    # A negative `sz_i` is equally malformed (Arrow ListView sizes are
    # unsigned element counts) and makes `cum` non-monotone, so the
    # total would no longer bound the intermediates. Both are rejected
    # in this pre-pass, so the check is complete and happens BEFORE any
    # offset is written.
    if offset_bytes == 4:
        var size_total = Int(0)
        for i in range(length):
            var sz_i = Int(frame.read_i32_le_at(sz_base + i * 4))
            if sz_i < 0:
                raise Error(
                    "_decode_list_view: "
                    + column_label
                    + " range "
                    + String(i)
                    + " declares a NEGATIVE size of "
                    + String(sz_i)
                    + "; Arrow ListView sizes are unsigned element counts"
                )
            size_total += sz_i
        check_int32_offsets(
            "ipc_decoder._decode_list_view",
            column_label,
            size_total,
            length,
        )

    # Validate ranges are in-order + tightly packed; build cumulative
    # offsets buffer at the same time.
    var out_offsets = OwnedAlignedBuffer((length + 1) * offset_bytes)
    out_offsets.set_length(Int64((length + 1) * offset_bytes))

    if offset_bytes == 4:
        out_offsets.write_i32_le_at(0, Int32(0))
        var cum = Int(0)
        for i in range(length):
            var off_i = Int(frame.read_i32_le_at(off_base + i * 4))
            var sz_i = Int(frame.read_i32_le_at(sz_base + i * 4))
            if off_i != cum:
                raise Error(
                    "_decode_list_view: range "
                    + String(i)
                    + " offset "
                    + String(off_i)
                    + " not in-order (expected "
                    + String(cum)
                    + "); overlapping/out-of-order ListView is not supported"
                )
            cum += sz_i
            out_offsets.write_i32_le_at((i + 1) * 4, Int32(cum))
    else:
        out_offsets.write_i64_le_at(0, Int64(0))
        var cum = Int64(0)
        for i in range(length):
            var off_i = Int64(frame.read_i64_le_at(off_base + i * 8))
            var sz_i = Int64(frame.read_i64_le_at(sz_base + i * 8))
            # SAME SHAPE, LARGE arm. Int64 offsets cannot realistically
            # wrap, but a negative size still makes the emitted
            # LARGE_LIST offsets non-monotone — `get_length` negative,
            # `get_span` slicing at a negative start — with the row COUNT
            # intact. The Int32 arm above rejects this in its pre-pass;
            # this arm has no pre-pass, so it rejects in place.
            if sz_i < 0:
                raise Error(
                    "_decode_list_view: "
                    + column_label
                    + " range "
                    + String(i)
                    + " declares a NEGATIVE size of "
                    + String(Int(sz_i))
                    + "; Arrow LargeListView sizes are unsigned element"
                    " counts"
                )
            if off_i != cum:
                raise Error(
                    "_decode_list_view: range "
                    + String(i)
                    + " offset "
                    + String(Int(off_i))
                    + " not in-order (expected "
                    + String(Int(cum))
                    + "); overlapping/out-of-order LargeListView is not supported"
                )
            cum += sz_i
            out_offsets.write_i64_le_at((i + 1) * 8, Int64(cum))

    return Column[HeapRegion](
        arrow_type=out_arrow_type,
        data=OwnedAlignedBuffer(0),
        offsets=out_offsets^,
        validity=validity^,
        length=length,
        null_count=null_count,
        offset=0,
    )


# =============================================================================
# Nested zero-copy decoder
# =============================================================================
#
# Extends `decode_record_batch_zerocopy` (flat primitives + var-len) to
# nested types: LIST / LARGE_LIST / STRUCT / MAP / UNION_SPARSE /
# UNION_DENSE / FIXED_SIZE_BINARY / FIXED_SIZE_LIST.
#
# Caller passes `Slab[ColumnTypeSpec]` (same recursive spec used by
# `decode_record_batch_message_nested`); returns `Slab[Column]` whose
# buffer fields BORROW into `frame`'s bytes. Identical caller-managed
# lifetime contract as the flat zerocopy: `frame` must outlive the
# returned Columns.
#
# Out of scope (raises to copy-on-read fallback):
#   - BOOL (1-bit-packed; needs unpacking)
#   - View types (BinaryView / Utf8View / ListView / LargeListView) —
#     decoded to expanded BINARY/STRING/LIST, which
#     requires materialization, fundamentally incompatible with
#     zero-copy. Caller falls back to nested copy-on-read decoder
#     when view types are present.
#   - DICTIONARY (needs preceding DictionaryBatch message).


def decode_record_batch_message_nested_zerocopy[
    bo: Origin[mut=False]
](
    ref [bo] frame: SharedAlignedBuffer[HeapRegion],
    var schema_specs: Slab[ColumnTypeSpec],
) raises -> Slab[Column[HeapRegion]]:
    """Zero-copy nested decode of an Arrow IPC RecordBatch message.
    Buffers in the returned Columns borrow into `frame`'s bytes.

    See module-level header for the caller-lifetime contract + coverage.

    interaction: zero-copy decode is INCOMPATIBLE
    with per-buffer compression — the decompressed bytes must
    materialize into a fresh heap buffer with a different lifetime.
    If the frame carries `BodyCompression.codec != -1`, this function
    raises a clear error pointing at the copy-on-read sibling.
    Callers needing compressed-input decode MUST use
    `decode_record_batch_message_nested` (copy-on-read) instead.

    Emits a zero-copy marker at
    entry (0 bytes; strict-zero gate consumer).
    """
    # Zero-copy nested entry-point marker.
    trace_alloc["arrow_ipc.decode_record_batch_zerocopy"](0)
    var observed_codec = peek_record_batch_codec_from_frame(frame)
    if observed_codec != Int8(-1):
        raise Error(
            "decode_record_batch_message_nested_zerocopy: frame carries"
            " BodyCompression.codec="
            + String(Int(observed_codec))
            + " (compressed); zero-copy decode requires uncompressed bodies."
            + " Use `decode_record_batch_message_nested` (copy-on-read)"
            + " for compressed input."
        )
    var f = parse_ipc_message(frame)

    var fb = SharedAlignedBuffer[HeapRegion].heap_owned(f.metadata_size)
    for i in range(f.metadata_size):
        fb.write_u8_at(i, frame.read_u8_at(f.metadata_pos + i))
    fb.set_length(f.metadata_size)

    var reader = flatbuf_reader_over(fb)

    var msg = read_message(reader, reader.read_root_offset())
    if msg.header_tag != MESSAGE_HEADER_RECORD_BATCH:
        raise Error(  # cov: unreachable peek_record_batch_codec_from_frame refused a non-RecordBatch frame first
            "decode_record_batch_message_nested_zerocopy: expected "  # cov: unreachable peek_record_batch_codec_from_frame refused a non-RecordBatch frame first
            "RECORD_BATCH header (tag "
            + String(Int(MESSAGE_HEADER_RECORD_BATCH))  # cov: unreachable peek_record_batch_codec_from_frame refused a non-RecordBatch frame first
            + "), got "  # cov: unreachable peek_record_batch_codec_from_frame refused a non-RecordBatch frame first
            + String(Int(msg.header_tag))  # cov: unreachable peek_record_batch_codec_from_frame refused a non-RecordBatch frame first
        )

    var rb = read_record_batch(reader, msg.header_table_pos)
    # ROBUSTNESS: the returned columns borrow `frame`'s bytes at
    # `body_pos + Buffer.offset`; refuse any Buffer outside the body before a
    # single borrow is made (same gate as `decode_record_batch_zerocopy`).
    _validate_rb_buffers_in_bounds(
        rb.buffers, f.body_pos, frame.len(),
        "decode_record_batch_message_nested_zerocopy",
    )
    var n_cols = len(schema_specs)
    var rb_length = Int(rb.length)
    check_record_batch_length(
        "decode_record_batch_message_nested_zerocopy",
        rb_length,
    )

    var columns = Slab[Column[HeapRegion]]()
    var node_idx = 0
    var buf_idx = 0
    var view_col_idx = 0
    for i in range(n_cols):
        # ROBUSTNESS: a top-level column must have the batch's length; inner
        # nodes are checked where they are read.
        check_node_index(
            "decode_record_batch_message_nested_zerocopy",
            node_idx,
            len(rb.nodes),
        )
        check_top_level_node(
            "decode_record_batch_message_nested_zerocopy",
            i,
            node_idx,
            Int(rb.nodes[node_idx].length),
            Int(rb.nodes[node_idx].null_count),
            rb_length,
        )
        var cursor = _decode_column_nested_zerocopy[bo](
            schema_specs[i],
            rb.nodes,
            rb.buffers,
            node_idx,
            buf_idx,
            view_col_idx,
            rb.variadic_buffer_counts,
            frame,
            f.body_pos,
        )
        node_idx = cursor.next_node_idx
        buf_idx = cursor.next_buffer_idx
        view_col_idx = cursor.next_view_col_idx
        var col_out = Column[HeapRegion]()
        swap(cursor.column, col_out)
        columns.append(col_out^)

    return columns^


def _decode_column_nested_zerocopy[
    bo: Origin[mut=False]
](
    spec: ColumnTypeSpec,
    nodes: List[FieldNode],
    buffers: List[BufferDescriptor],
    node_idx: Int,
    buffer_idx: Int,
    view_col_idx: Int,
    variadic_buffer_counts: List[Int64],
    ref [bo] frame: SharedAlignedBuffer[HeapRegion],
    body_pos: Int,
) raises -> _NestedDecodeCursor:
    """Recursive zero-copy decode of one column. Builds the parent
    Column via `from_borrowed_*` factories, then appends recursively-
    decoded child Columns to `_children`.
    """
    var t = spec.arrow_type
    # ROBUSTNESS: nothing below reads the borrowed bytes, so every size this
    # node implies is checked here, before the borrow (see
    # `ipc_field_node_check`).
    check_node_index("_decode_column_nested_zerocopy", node_idx, len(nodes))
    ref n = nodes[node_idx]
    var length = Int(n.length)
    var null_count = Int(n.null_count)
    check_field_node(
        "_decode_column_nested_zerocopy",
        node_idx,
        length,
        null_count,
    )
    # ROBUSTNESS: the Buffer list is the message's; refuse a node whose
    # descriptors it does not carry before an arm indexes one.
    check_node_buffers(
        "_decode_column_nested_zerocopy",
        node_idx,
        buffer_idx,
        nested_node_buffer_count(
            t,
            len(spec.children),
            spec.inner_size,
            _fixed_width_bytes_for(t),
            view_col_idx,
            variadic_buffer_counts,
            zerocopy=True,
        ),
        len(buffers),
    )

    # NULL: 0 buffers, all-null sentinel.
    if t == ArrowType.NULL:
        return _NestedDecodeCursor(
            column=Column[HeapRegion](
                arrow_type=ArrowType.NULL,
                data=OwnedAlignedBuffer(0),
                offsets=None,
                validity=None,
                length=length,
                null_count=length,
                offset=0,
            ),
            next_node_idx=node_idx + 1,
            next_buffer_idx=buffer_idx,
            next_view_col_idx=view_col_idx,
        )

    # BOOL: 1-bit pack needs unpacking, raise.
    if t == ArrowType.BOOL:
        raise Error(
            "_decode_column_nested_zerocopy: BOOL columns not zero-copy "
            "(1-bit packed; use decode_record_batch_message_nested "
            "copy-on-read)"
        )

    # Fixed-width primitives (Int*, UInt*, Float*, Date*, Time*, Timestamp*,
    # Duration*, Interval_*, Decimal128/256): 2 buffers (validity + values).
    var fixed_width = _fixed_width_bytes_for(t)
    if fixed_width > 0:
        ref validity_desc = buffers[buffer_idx]
        ref values_desc = buffers[buffer_idx + 1]
        check_buffer_size(
            "_decode_column_nested_zerocopy",
            node_idx,
            "values",
            Int(values_desc.length),
            checked_size_mul(
                "_decode_column_nested_zerocopy",
                node_idx,
                "values buffer",
                length,
                fixed_width,
            ),
            length,
        )
        _ = validity_present(
            "_decode_column_nested_zerocopy",
            node_idx,
            Int(validity_desc.length),
            length,
            null_count,
        )
        var values_view = frame.view_range_ro(
            body_pos + Int(values_desc.offset),
            Int(values_desc.length),
        )
        var col: Column[HeapRegion]
        if null_count == 0:
            col = Column.from_borrowed_primitive_no_nulls(
                t, values_view, length
            )
        else:
            var validity_view = frame.view_range_ro(
                body_pos + Int(validity_desc.offset),
                Int(validity_desc.length),
            )
            col = Column.from_borrowed_primitive_nullable(
                t, values_view, validity_view, length, null_count
            )
        return _NestedDecodeCursor(
            column=col^,
            next_node_idx=node_idx + 1,
            next_buffer_idx=buffer_idx + 2,
            next_view_col_idx=view_col_idx,
        )

    # Var-len (STRING / BINARY / LARGE_STRING / LARGE_BINARY): 3 buffers.
    if (
        t == ArrowType.STRING
        or t == ArrowType.BINARY
        or t == ArrowType.LARGE_STRING
        or t == ArrowType.LARGE_BINARY
    ):
        ref validity_desc = buffers[buffer_idx]
        ref offsets_desc = buffers[buffer_idx + 1]
        ref data_desc = buffers[buffer_idx + 2]
        check_buffer_size(
            "_decode_column_nested_zerocopy",
            node_idx,
            "offsets",
            Int(offsets_desc.length),
            varlen_offsets_bytes(
                "_decode_column_nested_zerocopy",
                node_idx,
                length,
                _varlen_offset_width(t),
            ),
            length,
        )
        _ = validity_present(
            "_decode_column_nested_zerocopy",
            node_idx,
            Int(validity_desc.length),
            length,
            null_count,
        )
        var offsets_view = frame.view_range_ro(
            body_pos + Int(offsets_desc.offset),
            Int(offsets_desc.length),
        )
        var data_view = frame.view_range_ro(
            body_pos + Int(data_desc.offset),
            Int(data_desc.length),
        )
        var col: Column[HeapRegion]
        if null_count == 0:
            col = Column.from_borrowed_varlen_no_nulls(
                t, data_view, offsets_view, length
            )
        else:
            var validity_view = frame.view_range_ro(
                body_pos + Int(validity_desc.offset),
                Int(validity_desc.length),
            )
            col = Column.from_borrowed_varlen_nullable(
                t,
                data_view,
                offsets_view,
                validity_view,
                length,
                null_count,
            )
        return _NestedDecodeCursor(
            column=col^,
            next_node_idx=node_idx + 1,
            next_buffer_idx=buffer_idx + 3,
            next_view_col_idx=view_col_idx,
        )

    # FIXED_SIZE_BINARY: validity + N-byte values.
    if t == ArrowType.FIXED_SIZE_BINARY:
        if spec.inner_size <= 0:
            raise Error(
                "_decode_column_nested_zerocopy FIXED_SIZE_BINARY: "
                "spec.inner_size must be > 0"
            )
        ref validity_desc = buffers[buffer_idx]
        ref values_desc = buffers[buffer_idx + 1]
        check_buffer_size(
            "_decode_column_nested_zerocopy",
            node_idx,
            "values",
            Int(values_desc.length),
            checked_size_mul(
                "_decode_column_nested_zerocopy",
                node_idx,
                "values buffer",
                length,
                spec.inner_size,
            ),
            length,
        )
        _ = validity_present(
            "_decode_column_nested_zerocopy",
            node_idx,
            Int(validity_desc.length),
            length,
            null_count,
        )
        var values_view = frame.view_range_ro(
            body_pos + Int(values_desc.offset),
            Int(values_desc.length),
        )
        var validity_view = frame.view_range_ro(
            body_pos + Int(validity_desc.offset),
            Int(validity_desc.length),
        )
        var col = Column.from_borrowed_fixed_size_binary(
            values_view,
            validity_view,
            length,
            null_count,
            spec.inner_size,
        )
        return _NestedDecodeCursor(
            column=col^,
            next_node_idx=node_idx + 1,
            next_buffer_idx=buffer_idx + 2,
            next_view_col_idx=view_col_idx,
        )

    # FIXED_SIZE_LIST: validity only + 1 child of length * list_size rows.
    if t == ArrowType.FIXED_SIZE_LIST:
        if spec.inner_size <= 0:
            raise Error(
                "_decode_column_nested_zerocopy FIXED_SIZE_LIST: "
                "spec.inner_size (list_size) must be > 0"
            )
        if len(spec.children) != 1:
            raise Error(
                "_decode_column_nested_zerocopy FIXED_SIZE_LIST: "
                "expected 1 child"
            )
        ref validity_desc = buffers[buffer_idx]
        _ = validity_present(
            "_decode_column_nested_zerocopy",
            node_idx,
            Int(validity_desc.length),
            length,
            null_count,
        )
        var validity_view = frame.view_range_ro(
            body_pos + Int(validity_desc.offset),
            Int(validity_desc.length),
        )
        var col = Column.from_borrowed_fixed_size_list(
            validity_view,
            length,
            null_count,
            spec.inner_size,
        )
        var child_cursor = _decode_column_nested_zerocopy[bo](
            spec.children[0],
            nodes,
            buffers,
            node_idx + 1,
            buffer_idx + 1,
            view_col_idx,
            variadic_buffer_counts,
            frame,
            body_pos,
        )
        var child_out = Column[HeapRegion]()
        swap(child_cursor.column, child_out)
        # The child must hold length * list_size rows (the copy-on-read
        # decoder's check); consumers index it at row * list_size.
        var fsl_child_rows = checked_size_mul(
            "_decode_column_nested_zerocopy",
            node_idx,
            "FIXED_SIZE_LIST child rows",
            length,
            spec.inner_size,
        )
        if child_out._length != fsl_child_rows:
            raise Error(
                "_decode_column_nested_zerocopy FIXED_SIZE_LIST: decoded"
                " child length "
                + String(child_out._length)
                + " != length * list_size = "
                + String(fsl_child_rows)
            )
        col._children.append(child_out^)
        return _NestedDecodeCursor(
            column=col^,
            next_node_idx=child_cursor.next_node_idx,
            next_buffer_idx=child_cursor.next_buffer_idx,
            next_view_col_idx=child_cursor.next_view_col_idx,
        )

    # LIST / LARGE_LIST: validity + offsets + 1 child.
    if t == ArrowType.LIST or t == ArrowType.LARGE_LIST:
        if len(spec.children) != 1:
            raise Error(
                "_decode_column_nested_zerocopy LIST: spec.children "
                "count != 1"
            )
        ref validity_desc = buffers[buffer_idx]
        ref offsets_desc = buffers[buffer_idx + 1]
        check_buffer_size(
            "_decode_column_nested_zerocopy",
            node_idx,
            "offsets",
            Int(offsets_desc.length),
            checked_offsets_bytes(
                "_decode_column_nested_zerocopy",
                node_idx,
                "offsets buffer",
                length,
                4 if t == ArrowType.LIST else 8,
            ),
            length,
        )
        _ = validity_present(
            "_decode_column_nested_zerocopy",
            node_idx,
            Int(validity_desc.length),
            length,
            null_count,
        )
        var offsets_view = frame.view_range_ro(
            body_pos + Int(offsets_desc.offset),
            Int(offsets_desc.length),
        )
        var validity_view = frame.view_range_ro(
            body_pos + Int(validity_desc.offset),
            Int(validity_desc.length),
        )
        var col = Column.from_borrowed_list(
            t, offsets_view, validity_view, length, null_count
        )
        var child_cursor = _decode_column_nested_zerocopy[bo](
            spec.children[0],
            nodes,
            buffers,
            node_idx + 1,
            buffer_idx + 2,
            view_col_idx,
            variadic_buffer_counts,
            frame,
            body_pos,
        )
        var child_out = Column[HeapRegion]()
        swap(child_cursor.column, child_out)
        col._children.append(child_out^)
        return _NestedDecodeCursor(
            column=col^,
            next_node_idx=child_cursor.next_node_idx,
            next_buffer_idx=child_cursor.next_buffer_idx,
            next_view_col_idx=child_cursor.next_view_col_idx,
        )

    # STRUCT: validity only + N children.
    if t == ArrowType.STRUCT:
        ref validity_desc = buffers[buffer_idx]
        _ = validity_present(
            "_decode_column_nested_zerocopy",
            node_idx,
            Int(validity_desc.length),
            length,
            null_count,
        )
        var validity_view = frame.view_range_ro(
            body_pos + Int(validity_desc.offset),
            Int(validity_desc.length),
        )
        var col = Column.from_borrowed_struct(
            validity_view, length, null_count
        )
        # Copy field_names into the Column.
        for fn_i in range(len(spec.field_names)):
            col._field_names.append(spec.field_names[fn_i])
        var next_node = node_idx + 1
        var next_buf = buffer_idx + 1
        var next_view = view_col_idx
        for child_i in range(len(spec.children)):
            var child_cursor = _decode_column_nested_zerocopy[bo](
                spec.children[child_i],
                nodes,
                buffers,
                next_node,
                next_buf,
                next_view,
                variadic_buffer_counts,
                frame,
                body_pos,
            )
            var child_out = Column[HeapRegion]()
            swap(child_cursor.column, child_out)
            check_struct_child_length(
                "_decode_column_nested_zerocopy",
                node_idx,
                length,
                child_i,
                next_node,
                child_out._length,
            )
            col._children.append(child_out^)
            next_node = child_cursor.next_node_idx
            next_buf = child_cursor.next_buffer_idx
            next_view = child_cursor.next_view_col_idx
        return _NestedDecodeCursor(
            column=col^,
            next_node_idx=next_node,
            next_buffer_idx=next_buf,
            next_view_col_idx=next_view,
        )

    # MAP: validity + Int32 offsets + 1 entries-STRUCT child.
    if t == ArrowType.MAP:
        if len(spec.children) != 1:
            raise Error(
                "_decode_column_nested_zerocopy MAP: expected 1 child"
            )
        ref validity_desc = buffers[buffer_idx]
        ref offsets_desc = buffers[buffer_idx + 1]
        check_buffer_size(
            "_decode_column_nested_zerocopy",
            node_idx,
            "offsets",
            Int(offsets_desc.length),
            checked_offsets_bytes(
                "_decode_column_nested_zerocopy",
                node_idx,
                "offsets buffer",
                length,
                4,
            ),
            length,
        )
        _ = validity_present(
            "_decode_column_nested_zerocopy",
            node_idx,
            Int(validity_desc.length),
            length,
            null_count,
        )
        var offsets_view = frame.view_range_ro(
            body_pos + Int(offsets_desc.offset),
            Int(offsets_desc.length),
        )
        var validity_view = frame.view_range_ro(
            body_pos + Int(validity_desc.offset),
            Int(validity_desc.length),
        )
        var col = Column.from_borrowed_list(
            ArrowType.MAP,
            offsets_view,
            validity_view,
            length,
            null_count,
        )
        var child_cursor = _decode_column_nested_zerocopy[bo](
            spec.children[0],
            nodes,
            buffers,
            node_idx + 1,
            buffer_idx + 2,
            view_col_idx,
            variadic_buffer_counts,
            frame,
            body_pos,
        )
        var child_out = Column[HeapRegion]()
        swap(child_cursor.column, child_out)
        col._children.append(child_out^)
        return _NestedDecodeCursor(
            column=col^,
            next_node_idx=child_cursor.next_node_idx,
            next_buffer_idx=child_cursor.next_buffer_idx,
            next_view_col_idx=child_cursor.next_view_col_idx,
        )

    # UNION_SPARSE: type_ids only + N children.
    if t == ArrowType.UNION_SPARSE:
        ref type_ids_desc = buffers[buffer_idx]
        check_buffer_size(
            "_decode_column_nested_zerocopy",
            node_idx,
            "type_ids",
            Int(type_ids_desc.length),
            length,
            length,
        )
        var type_ids_view = frame.view_range_ro(
            body_pos + Int(type_ids_desc.offset),
            Int(type_ids_desc.length),
        )
        var col = Column.from_borrowed_union_sparse(
            type_ids_view, length, null_count
        )
        var next_node = node_idx + 1
        var next_buf = buffer_idx + 1
        var next_view = view_col_idx
        for child_i in range(len(spec.children)):
            var child_cursor = _decode_column_nested_zerocopy[bo](
                spec.children[child_i],
                nodes,
                buffers,
                next_node,
                next_buf,
                next_view,
                variadic_buffer_counts,
                frame,
                body_pos,
            )
            var child_out = Column[HeapRegion]()
            swap(child_cursor.column, child_out)
            col._children.append(child_out^)
            next_node = child_cursor.next_node_idx
            next_buf = child_cursor.next_buffer_idx
            next_view = child_cursor.next_view_col_idx
        for ti in range(len(spec.type_ids)):
            col._type_ids.append(spec.type_ids[ti])
        return _NestedDecodeCursor(
            column=col^,
            next_node_idx=next_node,
            next_buffer_idx=next_buf,
            next_view_col_idx=next_view,
        )

    # UNION_DENSE: type_ids + offsets + N children.
    if t == ArrowType.UNION_DENSE:
        ref type_ids_desc = buffers[buffer_idx]
        ref offsets_desc = buffers[buffer_idx + 1]
        check_buffer_size(
            "_decode_column_nested_zerocopy",
            node_idx,
            "offsets",
            Int(offsets_desc.length),
            checked_size_mul(
                "_decode_column_nested_zerocopy",
                node_idx,
                "offsets buffer",
                length,
                4,
            ),
            length,
        )
        check_buffer_size(
            "_decode_column_nested_zerocopy",
            node_idx,
            "type_ids",
            Int(type_ids_desc.length),
            length,
            length,
        )
        var type_ids_view = frame.view_range_ro(
            body_pos + Int(type_ids_desc.offset),
            Int(type_ids_desc.length),
        )
        var offsets_view = frame.view_range_ro(
            body_pos + Int(offsets_desc.offset),
            Int(offsets_desc.length),
        )
        var col = Column.from_borrowed_union_dense(
            type_ids_view, offsets_view, length, null_count
        )
        var next_node = node_idx + 1
        var next_buf = buffer_idx + 2
        var next_view = view_col_idx
        for child_i in range(len(spec.children)):
            var child_cursor = _decode_column_nested_zerocopy[bo](
                spec.children[child_i],
                nodes,
                buffers,
                next_node,
                next_buf,
                next_view,
                variadic_buffer_counts,
                frame,
                body_pos,
            )
            var child_out = Column[HeapRegion]()
            swap(child_cursor.column, child_out)
            col._children.append(child_out^)
            next_node = child_cursor.next_node_idx
            next_buf = child_cursor.next_buffer_idx
            next_view = child_cursor.next_view_col_idx
        for ti in range(len(spec.type_ids)):
            col._type_ids.append(spec.type_ids[ti])
        return _NestedDecodeCursor(
            column=col^,
            next_node_idx=next_node,
            next_buffer_idx=next_buf,
            next_view_col_idx=next_view,
        )

    # View types — fundamentally incompatible with zero-copy
    # (lossy materialization into BINARY/STRING/LIST expanded form).
    if (
        t == ArrowType.BINARY_VIEW
        or t == ArrowType.UTF8_VIEW
        or t == ArrowType.LIST_VIEW
        or t == ArrowType.LARGE_LIST_VIEW
    ):
        raise Error(
            "_decode_column_nested_zerocopy: view types are not "
            "zero-copy (lossy expansion required); use "
            "decode_record_batch_message_nested copy-on-read"
        )

    raise Error(
        "_decode_column_nested_zerocopy: ArrowType "
        + String(Int(t.type_id))
        + " not supported (DICTIONARY requires preceding "
        + "DictionaryBatch message)"
    )


# =============================================================================
# — mmap-backed RecordBatch decode
# =============================================================================
#
# Decoder that constructs per-column buffers via
# `MmapAlignedBuffer.borrow_from_mmap(region, abs_offset, length)` instead of
# allocating + memcpy from a frame buffer. The ArcPointer<MmapRegion>
# keepalive baked into each MmapAlignedBuffer keeps the mmap region alive
# until the last consumer (Column / RecordBatch / DataFrame) drops.
#
# Contract:
#   - Frame's body_pos is RELATIVE to the rb_frame start (parsed via
#     parse_ipc_message). The caller supplies `abs_frame_offset_in_mmap`
#     (the file-absolute offset where this RB frame begins in the mmap
#     region). The absolute body offset = abs_frame_offset_in_mmap +
#     body_pos.
#   - rb_frame is the mmap-borrowed MmapAlignedBuffer covering the entire
#     RB IPC message (continuation + size + metadata FB + body). The
#     FB metadata is COPIED (small, ~few hundred bytes per RB) to a
#     fresh owning MmapAlignedBuffer for FlatbufReader parsing — this is
#     unavoidable because the FB reader needs root_offset anchored at
#     byte 0.
#   - The per-column buffers (validity, offsets, data) are
#     `borrow_from_mmap`'d directly into the mmap region.
#
# Codec gating:
#   - This function REQUIRES `BodyCompression.codec == -1` (Uncompressed).
#     Compressed frames cannot be zero-copy mmap'd because the
#     decompressed bytes must materialize into a fresh heap buffer with
#     a different lifetime. The caller (file-mode driver) MUST peek the
#     codec and fall back to the copy-on-read path for compressed
#     blocks.
#
# Returns a Slab[Column] of borrowed-from-mmap Columns. Each Column's
# `_data` (and `_offsets` for var-len + `_validity.buffer` when present)
# carries an ArcPointer<MmapRegion> keepalive.


def decode_record_batch_message_mmap(
    var rb_frame: SharedAlignedBuffer[HeapRegion],
    schema_types: List[ArrowType],
    region: ArcPointer[MmapRegion],
    abs_frame_offset_in_mmap: Int,
) raises -> Slab[Column[HeapRegion]]:
    """Decode an Arrow IPC RecordBatch message into a list of Columns
    whose buffers borrow into the mmap region (zero-copy + zero-alloc
    on the per-column path).

    Mmap-backed decoder. The rb_frame is itself an mmap-borrowed
    MmapAlignedBuffer covering [abs_frame_offset_in_mmap, abs_frame_offset_in_
    mmap + rb_frame.length). The decoder parses the FB metadata (copied
    locally, ~few hundred bytes) and constructs per-column borrowed
    buffers via `MmapAlignedBuffer.borrow_from_mmap`.

    Args:
        rb_frame: MmapAlignedBuffer over the full RB IPC frame, with mmap
            keepalive. CONSUMED — dropped before return.
        schema_types: One ArrowType per column (from the Footer Schema).
        region: ArcPointer to the mmap region. Refcount-bumped on every
            per-column buffer construction.
        abs_frame_offset_in_mmap: File-absolute byte offset where the RB
            frame begins in the mmap region. Used to compute the
            absolute offset of each per-column buffer:
                `abs_buf_offset = abs_frame_offset_in_mmap + body_pos +
                                  buf.offset`.

    Raises:
        - `BodyCompression.codec != -1`: compressed frame; caller must
          use the copy-on-read path.
        - DICTIONARY columns: dict-aware decode requires the
          IpcDictCache (SDK layer); caller must use the copy path or
          the dict-aware dispatch.
        - A frame that does not lie inside `region` at
          `abs_frame_offset_in_mmap`, or a Buffer descriptor outside the
          message body: refused before any buffer is borrowed.
        - Schema mismatches; standard validation errors.
    """
    trace_alloc["arrow_ipc.decode_record_batch_mmap"](0)

    # 1. Codec must be Uncompressed for mmap path.
    var codec_id = peek_record_batch_codec_from_frame(rb_frame)
    if codec_id != Int8(-1):
        raise Error(
            "decode_record_batch_message_mmap: frame carries"
            " BodyCompression.codec="
            + String(Int(codec_id))
            + "; mmap path requires Uncompressed bodies. Caller should"
            + " fall back to copy-on-read path for compressed frames."
        )

    # 2. Parse IPC framing.
    var f = parse_ipc_message(rb_frame)

    # 3. FB metadata: small copy to anchor FlatbufReader's root_offset at
    #    byte 0. Same as the existing copy-on-read path; this is NOT the
    #    hot allocation (FB is ~few hundred bytes per RB).
    var fb = SharedAlignedBuffer[HeapRegion].heap_owned(max(f.metadata_size, 1))
    if f.metadata_size > 0:
        fb.copy_from_view_at(
            0,
            rb_frame.view_range_ro(f.metadata_pos, f.metadata_size),
        )
    fb.set_length(f.metadata_size)

    var reader = flatbuf_reader_over(fb)

    var msg = read_message(reader, reader.read_root_offset())
    if msg.header_tag != MESSAGE_HEADER_RECORD_BATCH:
        raise Error(  # cov: unreachable peek_record_batch_codec_from_frame refused a non-RecordBatch frame first
            "decode_record_batch_message_mmap: expected RECORD_BATCH"  # cov: unreachable peek_record_batch_codec_from_frame refused a non-RecordBatch frame first
            " header (tag "
            + String(Int(MESSAGE_HEADER_RECORD_BATCH))  # cov: unreachable peek_record_batch_codec_from_frame refused a non-RecordBatch frame first
            + "), got "  # cov: unreachable peek_record_batch_codec_from_frame refused a non-RecordBatch frame first
            + String(Int(msg.header_tag))  # cov: unreachable peek_record_batch_codec_from_frame refused a non-RecordBatch frame first
        )

    var rb = read_record_batch(reader, msg.header_table_pos)
    var n_cols = len(schema_types)

    # 4. Validate per-column counts.
    var expected_node_count = 0
    var expected_buffer_count = 0
    for i in range(n_cols):
        var t = schema_types[i]
        expected_node_count += _node_count_for(t)
        expected_buffer_count += _buffer_count_for(t)
    if len(rb.nodes) != expected_node_count:
        raise Error(
            "decode_record_batch_message_mmap: FieldNode count mismatch"
            " (got " + String(len(rb.nodes)) + ", expected "
            + String(expected_node_count) + ")"
        )
    if len(rb.buffers) != expected_buffer_count:
        raise Error(
            "decode_record_batch_message_mmap: Buffer count mismatch"
            " (got " + String(len(rb.buffers)) + ", expected "
            + String(expected_buffer_count) + ")"
        )

    # 4b. ROBUSTNESS: every column buffer below is borrowed from `region` at
    #    `abs_frame_offset_in_mmap + body_pos + Buffer.offset`, and nothing is
    #    read until a consumer touches it, so an unchecked descriptor or frame
    #    offset yields columns that read outside the mapping. Bound the frame
    #    inside the mapping, then every Buffer inside the frame's body (the
    #    copy paths' validator and text), BEFORE the first borrow.
    _validate_mmap_frame_in_region(
        abs_frame_offset_in_mmap, rb_frame.len(), region[].len(),
        "decode_record_batch_message_mmap",
    )
    _validate_rb_buffers_in_bounds(
        rb.buffers, f.body_pos, rb_frame.len(),
        "decode_record_batch_message_mmap",
    )
    # 4c. ROBUSTNESS: each builder sizes its borrow from the FieldNode
    #    length; refuse a negative or inconsistent node first.
    check_top_level_nodes(
        "decode_record_batch_message_mmap", rb.nodes, Int(rb.length)
    )

    # 5. Per-column dispatch. Each builder constructs a Column whose
    #    buffers are borrow_from_mmap'd into `region` at the absolute
    #    byte offsets derived from body_pos + buf.offset.
    var abs_body_offset = abs_frame_offset_in_mmap + f.body_pos
    var columns = Slab[Column[HeapRegion]]()
    var node_idx = 0
    var buf_idx = 0
    for i in range(n_cols):
        var t = schema_types[i]
        ref node = rb.nodes[node_idx]
        var length = Int(node.length)
        var null_count = Int(node.null_count)

        # NULL: no buffers; construct empty Column.
        if t == ArrowType.NULL:
            columns.append(
                Column[HeapRegion](
                    arrow_type=ArrowType.NULL,
                    data=OwnedAlignedBuffer(0),
                    offsets=None,
                    validity=None,
                    length=length,
                    null_count=length,
                    offset=0,
                )
            )
            node_idx += 1
            continue

        # Fixed-width primitive: validity + values (2 buffers).
        var fixed_width = _fixed_width_bytes_for(t)
        if fixed_width > 0:
            ref validity_desc = rb.buffers[buf_idx]
            ref values_desc = rb.buffers[buf_idx + 1]
            var col = _build_fixed_width_column_mmap(
                t,
                length,
                null_count,
                fixed_width,
                validity_desc,
                values_desc,
                region,
                abs_body_offset,
                node_idx,
            )
            columns.append(col^)
            node_idx += 1
            buf_idx += 2
            continue

        # BOOL: validity + value bitmap (2 buffers; value buffer is
        # 1-bit-packed (length+7)/8 bytes).
        if t == ArrowType.BOOL:
            ref validity_desc = rb.buffers[buf_idx]
            ref value_bitmap_desc = rb.buffers[buf_idx + 1]
            var col = _build_bool_column_mmap(
                length,
                null_count,
                validity_desc,
                value_bitmap_desc,
                region,
                abs_body_offset,
                node_idx,
            )
            columns.append(col^)
            node_idx += 1
            buf_idx += 2
            continue

        # Var-len: validity + offsets + data (3 buffers).
        if (
            t == ArrowType.STRING
            or t == ArrowType.BINARY
            or t == ArrowType.LARGE_STRING
            or t == ArrowType.LARGE_BINARY
        ):
            ref validity_desc = rb.buffers[buf_idx]
            ref offsets_desc = rb.buffers[buf_idx + 1]
            ref data_desc = rb.buffers[buf_idx + 2]
            var col = _build_varlen_column_mmap(
                t,
                length,
                null_count,
                validity_desc,
                offsets_desc,
                data_desc,
                region,
                abs_body_offset,
                node_idx,
            )
            columns.append(col^)
            node_idx += 1
            buf_idx += 3
            continue

        # DICTIONARY: requires dict-aware decode (SDK-layer dispatch).
        # The count pass in step 4 is the type guard for this loop:
        # _node_count_for and _buffer_count_for raise for every type
        # outside NULL, the fixed-width types, BOOL, the four var-len
        # types and DICTIONARY. The arms above take all of those but
        # DICTIONARY, so DICTIONARY is the only type that reaches here.
        # A type admitted by the count pass needs its own arm above.
        raise Error(
            "decode_record_batch_message_mmap: DICTIONARY columns"
            + " require dict-aware decode. Caller should use the"
            + " copy-on-read dict-aware dispatch instead of the"
            + " mmap path for files containing dict-encoded columns."
        )

    # rb_frame is dropped here; its mmap keepalive is independent of the
    # per-column borrowed buffers' keepalives (each holds its own Arc
    # refcount).
    _ = rb_frame^
    return columns^


def _build_fixed_width_column_mmap(
    arrow_type: ArrowType,
    length: Int,
    null_count: Int,
    bytes_per_element: Int,
    validity_desc: BufferDescriptor,
    values_desc: BufferDescriptor,
    region: ArcPointer[MmapRegion],
    abs_body_offset: Int,
    node_index: Int,
) raises -> Column[HeapRegion]:
    """Construct a fixed-width Column[HeapRegion] whose buffers borrow into the mmap
    region (zero-copy + zero-alloc on the per-column path).
    """
    # The borrow below is exactly this size and nothing reads it until a
    # consumer does, so a wrapped or negative size would hand out a column
    # whose rows lie past its buffer. Formed checked; no `max(..., 0)`.
    var values_bytes_expected = checked_size_mul(
        "_build_fixed_width_column_mmap", node_index, "values buffer",
        length, bytes_per_element,
    )
    check_buffer_size(
        "_build_fixed_width_column_mmap", node_index, "values",
        Int(values_desc.length), values_bytes_expected, length,
    )

    #
    # Keeps the mmap path zero-copy instead of
    # `borrow_from_mmap(...).realign_to[64]()` (one alloc+memcpy per
    # buffer per column per RB). `borrow_mmap_erased`
    # returns `SAB[HeapRegion]` (the type `Column[HeapRegion]._data`
    # requires) aliasing the mmap'd page-cache bytes DIRECTLY; the mmap
    # mapping is pinned by the type-erased `ArcPointer[MmapRegion]` keepalive
    # cookie inside the buffer (flows Column → RecordBatch; munmap deferred
    # to last-ref). No memcpy, no fresh heap allocation.
    var data = SharedAlignedBuffer.borrow_mmap_erased(
        ArcPointer[MmapRegion](copy=region),
        Int64(abs_body_offset + Int(values_desc.offset)),
        Int64(values_bytes_expected),
    )

    var validity = _maybe_build_validity_bitmap_mmap(
        validity_desc, length, null_count, node_index, region,
        abs_body_offset,
    )
    return Column[HeapRegion](
        arrow_type=arrow_type,
        data=data^,
        offsets=None,
        validity=validity^,
        length=length,
        null_count=null_count,
        offset=0,
    )


def _build_bool_column_mmap(
    length: Int,
    null_count: Int,
    validity_desc: BufferDescriptor,
    value_bitmap_desc: BufferDescriptor,
    region: ArcPointer[MmapRegion],
    abs_body_offset: Int,
    node_index: Int,
) raises -> Column[HeapRegion]:
    """BOOL Column[HeapRegion] with mmap-borrowed validity + value bitmap.

    See `_build_fixed_width_column_mmap` for the realign-at-boundary rationale.
    """
    var expected_bitmap_bytes = checked_bitmap_bytes(
        "_build_bool_column_mmap", node_index, "value bitmap buffer", length
    )
    check_buffer_size(
        "_build_bool_column_mmap", node_index, "value bitmap",
        Int(value_bitmap_desc.length), expected_bitmap_bytes, length,
    )
    # Zero-copy mmap borrow
    # via the type-erased keepalive cookie (see _build_fixed_width_column_mmap).
    var data = SharedAlignedBuffer.borrow_mmap_erased(
        ArcPointer[MmapRegion](copy=region),
        Int64(abs_body_offset + Int(value_bitmap_desc.offset)),
        Int64(expected_bitmap_bytes),
    )
    var validity = _maybe_build_validity_bitmap_mmap(
        validity_desc, length, null_count, node_index, region,
        abs_body_offset,
    )
    return Column[HeapRegion](
        arrow_type=ArrowType.BOOL,
        data=data^,
        offsets=None,
        validity=validity^,
        length=length,
        null_count=null_count,
        offset=0,
    )


def _build_varlen_column_mmap(
    arrow_type: ArrowType,
    length: Int,
    null_count: Int,
    validity_desc: BufferDescriptor,
    offsets_desc: BufferDescriptor,
    data_desc: BufferDescriptor,
    region: ArcPointer[MmapRegion],
    abs_body_offset: Int,
    node_index: Int,
) raises -> Column[HeapRegion]:
    """Var-len Column[HeapRegion] (STRING/BINARY/LARGE_*) with mmap-borrowed validity
    + offsets + data.

    See `_build_fixed_width_column_mmap` for the realign-at-boundary rationale.
    """
    var offsets_bytes = Int(offsets_desc.length)
    check_buffer_size(
        "_build_varlen_column_mmap", node_index, "offsets", offsets_bytes,
        varlen_offsets_bytes(
            "_build_varlen_column_mmap", node_index, length,
            _varlen_offset_width(arrow_type),
        ),
        length,
    )
    # Zero-copy mmap borrow
    # via the type-erased keepalive cookie (see _build_fixed_width_column_mmap).
    var offsets = SharedAlignedBuffer.borrow_mmap_erased(
        ArcPointer[MmapRegion](copy=region),
        Int64(abs_body_offset + Int(offsets_desc.offset)),
        Int64(offsets_bytes),
    )

    var data_bytes = Int(data_desc.length)
    var data = SharedAlignedBuffer.borrow_mmap_erased(
        ArcPointer[MmapRegion](copy=region),
        Int64(abs_body_offset + Int(data_desc.offset)),
        Int64(data_bytes),
    )

    var validity = _maybe_build_validity_bitmap_mmap(
        validity_desc, length, null_count, node_index, region,
        abs_body_offset,
    )
    return Column[HeapRegion](
        arrow_type=arrow_type,
        data=data^,
        offsets=offsets^,
        validity=validity^,
        length=length,
        null_count=null_count,
        offset=0,
    )


def _maybe_build_validity_bitmap_mmap(
    validity_desc: BufferDescriptor,
    length: Int,
    null_count: Int,
    node_index: Int,
    region: ArcPointer[MmapRegion],
    abs_body_offset: Int,
) raises -> Optional[Bitmap[HeapRegion]]:
    """Build a validity Bitmap from the mmap region. Returns
    None when validity_desc.length == 0 (encoder's signal for
    'all non-null').

    Realign-at-boundary: `Bitmap.from_mmap` returns a `Bitmap[MmapRegion]`
    (zero-copy borrow), but `Column._validity` is
    `Optional[Bitmap[HeapRegion]]` (the validity field is not parametric
    over the region). To bridge the K mismatch, we realign the
    mmap-borrowed buffer to a fresh HeapRegion allocation here (one memcpy
    per validity bitmap per RecordBatch decode); the zero-copy promise
    holds for the bulk values + offsets buffers, not for the bitmap. Making
    the validity field region-parametric would restore it for the bitmap
    too, at the cost of a very wide cascade.
    """
    if not validity_present(
        "_maybe_build_validity_bitmap_mmap", node_index,
        Int(validity_desc.length), length, null_count,
    ):
        return None
    # Zero-copy mmap-borrow
    # validity bitmap via the type-erased keepalive cookie. Returns
    # Bitmap[HeapRegion] (the Column._validity field type) aliasing the mmap
    # bytes directly — no realign memcpy. The mapping is pinned by the
    # keepalive cookie inside the bitmap's inner SAB.
    return Bitmap.from_mmap_erased(
        region,
        abs_body_offset + Int(validity_desc.offset),
        length,
    )
