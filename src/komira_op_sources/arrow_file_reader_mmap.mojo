# =============================================================================
# arrow_file_reader_mmap.mojo -- the memory-mapped File-format reader for a path.
# =============================================================================
#
# Split out of `arrow_file_reader.mojo` (the File-format layout, the
# auto-detect rule and the safety contract are described there) so each
# file stays under 1,000 lines.

from std.io import FileHandle
from std.memory import ArcPointer
from komira_arrow_ipc.ipc_body_compression import decompress_all_rbs_into_with_dispatcher
from komira_compression.compression import ArrowIpcCompression
from komira_arrow_ipc.ipc_decoder_dispatch import (
    decode_record_batch_message,
    decode_record_batch_message_mmap,
    decode_record_batch_message_with_dicts,
    decode_record_batch_message_with_dicts_with_dispatcher,
    decode_record_batch_message_with_dispatcher,
    peek_record_batch_codec_from_frame,
)
from komira_async_api.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_arrow_ipc.ipc_flatbuf import (
    Block,
    flatbuf_reader_over,
    parse_ipc_message,
    read_footer,
    read_message,
    read_schema,
    MESSAGE_HEADER_DICTIONARY_BATCH,
)
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Schema
from komira_buffer.byte_view import ByteView
from komira_buffer.mmap_region import MmapRegion
from komira_op_sources.ipc_stream_frames import (
    _build_dict_values_per_col,
    _concat_batches,
    _consume_dictionary_batch_frame,
    _consume_dictionary_batch_frame_with_dispatcher,
    _extract_dict_ids,
    _extract_dict_index_widths,
    _extract_is_dict_encoded,
    _ipc_schema_desc_to_komira_schema,
)
from komira_collections.slab import Slab
from komira_op_sources.ipc_dict_cache import IpcDictCache
from komira_counters.runtime_introspection import trace_alloc
from komira_buffer.heap_region import HeapRegion

# =============================================================================
# ARROW-IPC-PERF-MMAP-PHASE-3 — path-mode mmap-backed reader
# =============================================================================
#
# Production integration of the mmap substrate (the keepalive on the
# mapped buffer is `komira_buffer.mmap_region.MmapRegion`).
#
# Strategy:
#   1. mmap the file once via `MmapRegion.open_readonly(path)` and wrap
#      in `ArcPointer<MmapRegion>`. Refcount = 1.
#   2. Walk the Footer (FB metadata copy is unavoidable — small bytes).
#   3. Per-RB block: peek the BodyCompression.codec. If Uncompressed
#      (codec == -1), build the rb_frame as a borrow_from_mmap buffer
#      and decode via `decode_record_batch_message_mmap` — every
#      per-column buffer borrows directly into the mmap region with an
#      ArcPointer keepalive. If compressed, fall back to the standard
#      copy + decompress path (which requires owning bytes for the
#      decompressed output).
#   4. The mmap region's lifetime is bound by the ArcPointer refcount;
#      it stays alive as long as ANY Column (or RecordBatch holding a
#      Column) references it. When the user's DataFrame drops, the
#      mmap region's last refcount goes to zero and `munmap(2)` fires
#      in MmapRegion's destructor.
#
# Codec gating:
#   - Per-RB codec peek; uncompressed → mmap path; compressed →
#     fallback. Mixed-codec files (different RBs with different codecs)
#     are handled correctly because each RB is dispatched independently.
#   - Dictionary-encoded columns are also fallback-only — the dict
#     index → string expansion requires materialized output (lossy v1).


def decode_arrow_ipc_file_path_mmap(
    path: String,
    mut cache: IpcDictCache,
) raises -> RecordBatch:
    """Concat-folded convenience wrapper over
    `decode_arrow_ipc_file_path_mmap_chunked`.

    ARROW-IPC-READ-NO-CONCAT: the decode body now lives in
    the `_chunked` sibling which carries the per-block `Slab[RecordBatch]`
    out un-concatenated (each RB's columns still alias the mmap, anchored
    on the per-column ArcPointer<MmapRegion> keepalive). This wrapper
    preserves the prior single-RecordBatch contract by folding the chunks
    via `_concat_batches` (the ~25ms 49-way memcpy the chunked path avoids
    for the morsel-native engine). Callers that consume multi-batch
    sources (the COLUMN read path → `InMemorySource.from_record_batches`)
    should call the `_chunked` sibling directly.
    """
    return _concat_batches(
        decode_arrow_ipc_file_path_mmap_chunked(path, cache)
    )


def decode_arrow_ipc_file_path_mmap_chunked(
    path: String,
    mut cache: IpcDictCache,
) raises -> Slab[RecordBatch]:
    """PHASE-3 mmap-backed path-mode Arrow IPC File reader.

    Opens `path` via `mmap(MAP_PRIVATE+PROT_READ)`, walks the footer +
    record batches, and constructs Columns whose buffers borrow directly
    into the mmap region (zero-copy + zero-alloc on the per-column
    path). The mmap region's lifetime is anchored on the returned
    RecordBatch via the ArcPointer keepalive chain.

    Per-RB codec gating:
      - Uncompressed (codec == -1): borrowed-from-mmap path (this fn's
        win).
      - Compressed (LZ4_FRAME / ZSTD): falls back to copy-on-read
        decompress path (which allocates owning bytes for the
        decompressed output).

    Dict-encoded columns also fall back (the SDK-level dict expand
    requires materialized output bytes).

    Mixed-codec files: handled per-RB. Each block is independently
    dispatched.

    See `decode_arrow_ipc_file_with_dict_cache` for the equivalent
    bytes-mode path (used when the caller has a BytesHandle or
    FileHandleReader rather than a file path).

    Args:
        path: Filesystem path to an Arrow IPC File-format file.
        cache: IpcDictCache for dictionary state (per-call isolation
            recommended by the caller).

    Raises:
        - Mmap open / fstat / mmap failures (MmapRegion.open_readonly).
        - Invalid Arrow IPC layout (magic / footer / RB blocks).
        - Per-RB / per-column decode errors.
    """
    trace_alloc["arrow_ipc.driver_enter"](0)

    # 1. mmap the file once. ArcPointer refcount = 1 here.
    var region_arc = ArcPointer[MmapRegion](
        MmapRegion.open_readonly(path)
    )
    var n = region_arc[].len()

    if n < 8 + 4 + 6:
        raise Error(
            "decode_arrow_ipc_file_path_mmap: input too short ("
            + String(n)
            + " bytes); a valid Arrow File is at least ARROW1 + Schema"
            + " + Footer + i32 length + ARROW1 (~162 bytes minimum)"
        )

    # 2. Build a borrowed-from-mmap MmapAlignedBuffer over the full file
    #    for FB / magic / footer reads. This is itself a zero-copy
    #    construction (no file slurp).
    var src = SharedAlignedBuffer.borrow_from_mmap(region_arc, 0, Int64(n))

    # 3. Validate ARROW1 magic at head + trailer.
    var head_view = src.view_range_ro(0, 8)
    if not _view_matches_arrow1_magic_8(head_view):
        raise Error(
            "decode_arrow_ipc_file_path_mmap: missing ARROW1\\0\\0 magic"
            + " header at byte 0"
        )
    var tail_view = src.view_range_ro(n - 6, 6)
    if not _view_matches_arrow1_magic_6(tail_view):
        raise Error(
            "decode_arrow_ipc_file_path_mmap: missing ARROW1 magic"
            + " trailer at bytes [n-6..n]"
        )

    # 4. Read footer length + slice Footer FB.
    var footer_len = Int(src.read_i32_le_at(n - 10))
    if footer_len <= 0:
        raise Error(
            "decode_arrow_ipc_file_path_mmap: invalid footer_length "
            + String(footer_len)
        )
    var footer_start = n - 10 - footer_len
    if footer_start < 8:
        raise Error(
            "decode_arrow_ipc_file_path_mmap: footer_length "
            + String(footer_len) + " too large for file size "
            + String(n)
        )

    # FB needs root_offset anchored at byte 0; copy into a small owning
    # buffer (footer_len ~few KB; not the hot allocation).
    var footer_fb = SharedAlignedBuffer[HeapRegion].heap_owned(footer_len)
    footer_fb.copy_from_view_at(0, src.view_range_ro(footer_start, footer_len))
    footer_fb.set_length(footer_len)

    var footer_reader = flatbuf_reader_over(footer_fb)
    var footer = read_footer(
        footer_reader, footer_reader.read_root_offset()
    )

    # 5. Decode the Footer's Schema → Komira Schema.
    var schema_desc = read_schema(footer_reader, footer.schema_table_pos)
    var schema = _ipc_schema_desc_to_komira_schema(schema_desc, footer_fb)
    var arrow_types: List[ArrowType] = List[ArrowType]()
    for i in range(schema.num_columns()):
        arrow_types.append(schema.field_arrow_type(i))
    var is_dict_encoded = _extract_is_dict_encoded(schema_desc)
    var dict_ids = _extract_dict_ids(schema_desc)
    var dict_widths = _extract_dict_index_widths(schema_desc)
    var any_dict_encoded = False
    for i in range(len(is_dict_encoded)):
        if is_dict_encoded[i]:
            any_dict_encoded = True
            break

    # 6. Walk the Footer's dictionary block list + populate cache.
    #    Dict batches use the standard owning-buffer path (lossy expand
    #    requires materialized bytes; mmap path doesn't apply here).
    var n_dict = len(footer.dictionaries)
    for di in range(n_dict):
        ref dblk = footer.dictionaries[di]
        var d_offset = Int(dblk.offset)
        var d_meta_len = Int(dblk.meta_data_length)
        var d_body_len = Int(dblk.body_length)
        var d_frame_len = d_meta_len + d_body_len
        if d_offset < 0 or d_offset + d_frame_len > n:
            raise Error(
                "decode_arrow_ipc_file_path_mmap: DictionaryBatch Block"
                + " out of range (idx=" + String(di) + ")"
            )
        # Dict frames go through the existing owning-buffer path.
        var d_frame = SharedAlignedBuffer[HeapRegion].heap_owned(d_frame_len)
        d_frame.copy_from_view_at(0, src.view_range_ro(d_offset, d_frame_len))
        d_frame.set_length(d_frame_len)


        var fi = parse_ipc_message(d_frame)
        var fb = SharedAlignedBuffer[HeapRegion].heap_owned(fi.metadata_size)
        fb.copy_from_view_at(
            0, d_frame.view_range_ro(fi.metadata_pos, fi.metadata_size)
        )
        fb.set_length(fi.metadata_size)

        var fb_reader = flatbuf_reader_over(fb)
        var d_msg = read_message(fb_reader, fb_reader.read_root_offset())
        if d_msg.header_tag != MESSAGE_HEADER_DICTIONARY_BATCH:
            raise Error(
                "decode_arrow_ipc_file_path_mmap: footer.dictionaries["
                + String(di) + "] is not a DICTIONARY_BATCH"
            )
        _consume_dictionary_batch_frame(
            d_frame^, d_msg.header_table_pos,
            fi.metadata_size, Int(d_msg.body_length), cache,
        )

    # 7. Walk RB blocks. Per-RB codec gating: uncompressed → mmap path;
    #    compressed / dict-encoded → fallback to standard owning path.
    var n_rb = len(footer.record_batches)
    if n_rb == 0:
        var empty_builder = RecordBatchBuilder.with_capacity(
            schema.num_columns()
        )
        _ = src^
        # Chunked contract: carry a single 0-row RB so the downstream
        # `InMemorySource.from_record_batches` can derive the schema.
        var empty_block = Slab[RecordBatch]()
        empty_block.append(empty_builder.build(schema^))
        return empty_block^

    var per_block = Slab[RecordBatch]()
    for bi in range(n_rb):
        ref blk = footer.record_batches[bi]
        var blk_offset = Int(blk.offset)
        var blk_meta_len = Int(blk.meta_data_length)
        var blk_body_len = Int(blk.body_length)
        var frame_len = blk_meta_len + blk_body_len
        if blk_offset < 0 or blk_offset + frame_len > n:
            raise Error(
                "decode_arrow_ipc_file_path_mmap_chunked: RecordBatch Block"
                + " out of range (idx=" + String(bi) + ")"
            )

        # Build the rb_frame as an mmap-borrowed MmapAlignedBuffer (zero
        # alloc, zero memcpy at frame construction time). The FB
        # metadata copy happens inside the mmap decoder (small bytes).
        #
        # OBJECTSTORE-V04 Phase 3b.2 SESSION 3 Path B: realign to
        # HeapRegion for downstream `peek_record_batch_codec_from_frame`
        # / `decode_record_batch_message_mmap` which expect
        # `SharedAlignedBuffer[HeapRegion]` (HeapRegion default). One memcpy per
        # RecordBatch frame; Path A (parametric frame type) deferred.
        var rb_frame = SharedAlignedBuffer.borrow_from_mmap(
            region_arc, Int64(blk_offset), Int64(frame_len)
        ).realign_to[8]()

        # Peek codec — gates between mmap path and fallback.
        var codec_id = peek_record_batch_codec_from_frame(rb_frame)

        var cols: Slab[Column[HeapRegion]]
        if codec_id == Int8(-1) and not any_dict_encoded:
            # Uncompressed + no dict columns: full mmap path.
            cols = decode_record_batch_message_mmap(
                rb_frame^,
                arrow_types,
                region_arc,
                blk_offset,
            )
        else:
            # Compressed OR dict-encoded: copy-on-read fallback.
            # The frame must be an owning MmapAlignedBuffer because
            # decompress writes into owning bytes (and the dict-aware
            # decoder takes a `var frame` consumed by the standard
            # copy-on-read path). We materialize the frame here, then
            # dispatch.
            var owning_frame = SharedAlignedBuffer[HeapRegion].heap_owned(frame_len)
            owning_frame.copy_from_view_at(
                0, rb_frame.view_range_ro(0, frame_len)
            )
            owning_frame.set_length(frame_len)

            _ = rb_frame^

            if any_dict_encoded:
                var dict_values = _build_dict_values_per_col(
                    is_dict_encoded, dict_ids, cache,
                )
                cols = decode_record_batch_message_with_dicts(
                    owning_frame^,
                    arrow_types,
                    is_dict_encoded,
                    dict_values^,
                    dict_widths,
                )
            else:
                cols = decode_record_batch_message(
                    owning_frame^, arrow_types
                )

        var builder = RecordBatchBuilder.with_capacity(len(cols))
        var num_cols = len(cols)
        for i in range(num_cols):
            builder.add_column(cols.take_slot_unchecked(i))
        cols.set_len_unchecked(0)
        _ = cols^
        per_block.append(builder.build(schema.copy()))

    _ = schema^
    _ = src^  # mmap-borrowed file-wide src buffer; Arc refcount
              # decrements but the region stays alive because per-column
              # Arcs hold it.
    # region_arc itself is dropped on function return; the Arc refcount
    # decrements but the mmap stays alive as long as ANY per-column
    # buffer (via its keepalive) is alive. The returned RecordBatches
    # own those columns transitively (each RB's Column→keepalive Arc
    # holds the mmap region; carrying the Slab un-concatenated is
    # STRICTLY safer than the old borrow-then-copy-out concat).
    return per_block^


# =============================================================================
# ARROW-IPC-PERF-MMAP-COMPRESSED-INPUT-FRAME — codec-parametric
# path-mode mmap-backed reader for COMPRESSED File-format reads.
# =============================================================================
#
# Sibling to `decode_arrow_ipc_file_path_mmap` (uncompressed-only mmap path).
# This entry point is reached via `ctx.read_arrow_codec[Lz4Frame/Zstd](path)`
# at the session layer (`session_context.mojo`); the codec-arm gate peeks
# for ARROW1 magic and routes to this fn when present, falling back to the
# byte-slurp `FileHandleReader` path for Stream-format files.
#
# Strategy:
#   1. mmap the file via `MmapRegion.open_readonly(path)`; wrap in
#      ArcPointer<MmapRegion>. Refcount = 1.
#   2. Walk the Footer (FB metadata is small; a few KB copy is fine).
#   3. For each RB block: construct `rb_frame` as a borrow_from_mmap
#      MmapAlignedBuffer (zero-copy, zero-alloc on the per-RB input side).
#      The compressed bytes live in the mmap'd page-cache view.
#   4. Push all rb_frames into a Slab and call
#      `decompress_all_rbs_into_with_dispatcher[C]` — the existing
#      coalesced decompress driver. The driver reads from rb_frames
#      (read-only) and writes into OWNING per-RB output frames it
#      allocates itself (decompressed bytes need writable storage).
#   5. Per-RB Column-build off the OWNING decompressed frames (same as
#      the existing bytes-mode path). The mmap region's lifetime is
#      anchored on the ArcPointer keepalives in the rb_frames; once
#      `decompress_all_rbs_into_with_dispatcher` returns owning frames
#      and the borrowed inputs drop, the mmap region's last ArcPointer
#      reference falls and `munmap(2)` fires.
#
# What's saved (vs the byte-slurp path):
#   * NO `handle.read_all()` 534MB owning `List[UInt8]` heap alloc.
#   * NO `read(2)` syscall memcpy from page cache to userspace.
#   * NO `src` copy into an owning MmapAlignedBuffer for FB / footer access.
#   * The Footer FB still gets a small (~few KB) copy for FB root-offset
#     parsing — unavoidable.
#
# What's UNCHANGED:
#   * The decompress driver still allocates owning per-RB output frames.
#     This is correctness-required: decompression WRITES into the output
#     bytes; a PROT_READ mmap mapping cannot be written.
#   * The per-RB Column-build still constructs Columns over the OWNING
#     decompressed output frames (not the mmap input).
#   * Stream-format files (non-ARROW1) are not reachable here; they
#     keep the existing byte-slurp path.
#
# Dict-encoded handling:
#   * Dict batches in the Footer's `dictionaries` block-index list are
#     consumed via the standard `_consume_dictionary_batch_frame*` (which
#     accepts an owning OR borrowed MmapAlignedBuffer — it takes a `var
#     frame: SharedAlignedBuffer[HeapRegion]` and only reads). For uniformity with the
#     existing PHASE-3 mmap path, we materialize dict frames into owning
#     bytes (small frames; not the hot allocation).


def decode_arrow_ipc_file_path_mmap_codec[
    C: ArrowIpcCompression,
    disp_o: Origin[mut=True],
](
    path: String,
    mut cache: IpcDictCache,
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
) raises -> RecordBatch:
    """Concat-folded convenience wrapper over
    `decode_arrow_ipc_file_path_mmap_codec_chunked`.

    ARROW-IPC-READ-NO-CONCAT: the decode body now lives in
    the `_chunked` sibling which carries the per-block `Slab[RecordBatch]`
    out un-concatenated. This wrapper preserves the prior single-
    RecordBatch contract by folding via `_concat_batches`. Callers that
    consume multi-batch sources (the COLUMN read path →
    `InMemorySource.from_record_batches`) should call the `_chunked`
    sibling directly.
    """
    return _concat_batches(
        decode_arrow_ipc_file_path_mmap_codec_chunked[C, disp_o](
            path, cache, dispatcher_ptr, cancel_token^
        )
    )


def decode_arrow_ipc_file_path_mmap_codec_chunked[
    C: ArrowIpcCompression,
    disp_o: Origin[mut=True],
](
    path: String,
    mut cache: IpcDictCache,
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
) raises -> Slab[RecordBatch]:
    """ARROW-IPC-PERF-MMAP-COMPRESSED-INPUT-FRAME entry point.
    Codec-parametric mmap-backed path-mode Arrow IPC File reader.

    Opens `path` via `mmap(MAP_PRIVATE+PROT_READ)`, walks the Footer + RB
    block index, constructs per-RB compressed input frames as borrowed-
    from-mmap AlignedBuffers, then calls the existing coalesced decompress
    driver `decompress_all_rbs_into_with_dispatcher[C, disp_o]`. The
    driver allocates owning per-RB output frames for the decompressed
    bytes (decompression writes; mmap is read-only).

    Caller is `EngineContext.read_arrow_codec[C](path)` when the path is
    ARROW1-magic (File-format). Stream-format files (no ARROW1) keep the
    existing byte-slurp path.

    Args:
        path: Filesystem path to an Arrow IPC File-format file.
        cache: IpcDictCache for dictionary state (per-call isolation).
        dispatcher_ptr: EngineContext-owned LocalDispatcher for parallel
            per-buffer decompress. Same shape as the bytes-mode dispatcher
            path.
        cancel_token: CancellationToken — propagated to the decompress
            driver.

    Raises:
        - MmapRegion.open_readonly failures (open/fstat/mmap).
        - Invalid Arrow IPC layout (magic / footer / RB blocks).
        - Per-RB decompress errors.
    """
    trace_alloc["arrow_ipc.driver_enter"](0)

    # 1. mmap the file once. ArcPointer refcount = 1 here.
    var region_arc = ArcPointer[MmapRegion](
        MmapRegion.open_readonly(path)
    )
    var n = region_arc[].len()

    if n < 8 + 4 + 6:
        _ = cancel_token^
        raise Error(
            "decode_arrow_ipc_file_path_mmap_codec: input too short ("
            + String(n)
            + " bytes); a valid Arrow File is at least ARROW1 + Schema"
            + " + Footer + i32 length + ARROW1 (~162 bytes minimum)"
        )

    # 2. Build a borrowed-from-mmap MmapAlignedBuffer over the full file
    #    for FB / magic / footer reads. Zero-copy construction.
    var src = SharedAlignedBuffer.borrow_from_mmap(region_arc, 0, Int64(n))

    # 3. Validate ARROW1 magic at head + trailer.
    var head_view = src.view_range_ro(0, 8)
    if not _view_matches_arrow1_magic_8(head_view):
        _ = cancel_token^
        raise Error(
            "decode_arrow_ipc_file_path_mmap_codec: missing ARROW1\\0\\0"
            + " magic header at byte 0"
        )
    var tail_view = src.view_range_ro(n - 6, 6)
    if not _view_matches_arrow1_magic_6(tail_view):
        _ = cancel_token^
        raise Error(
            "decode_arrow_ipc_file_path_mmap_codec: missing ARROW1 magic"
            + " trailer at bytes [n-6..n]"
        )

    # 4. Read footer length + slice Footer FB.
    var footer_len = Int(src.read_i32_le_at(n - 10))
    if footer_len <= 0:
        _ = cancel_token^
        raise Error(
            "decode_arrow_ipc_file_path_mmap_codec: invalid footer_length "
            + String(footer_len)
        )
    var footer_start = n - 10 - footer_len
    if footer_start < 8:
        _ = cancel_token^
        raise Error(
            "decode_arrow_ipc_file_path_mmap_codec: footer_length "
            + String(footer_len) + " too large for file size "
            + String(n)
        )

    # FB needs root_offset anchored at byte 0; copy into a small owning
    # buffer (footer_len ~few KB; not the hot allocation).
    var footer_fb = SharedAlignedBuffer[HeapRegion].heap_owned(footer_len)
    footer_fb.copy_from_view_at(0, src.view_range_ro(footer_start, footer_len))
    footer_fb.set_length(footer_len)

    var footer_reader = flatbuf_reader_over(footer_fb)
    var footer = read_footer(
        footer_reader, footer_reader.read_root_offset()
    )

    # 5. Decode the Footer's Schema → Komira Schema.
    var schema_desc = read_schema(footer_reader, footer.schema_table_pos)
    var schema = _ipc_schema_desc_to_komira_schema(schema_desc, footer_fb)
    var arrow_types: List[ArrowType] = List[ArrowType]()
    for i in range(schema.num_columns()):
        arrow_types.append(schema.field_arrow_type(i))
    var is_dict_encoded = _extract_is_dict_encoded(schema_desc)
    var dict_ids = _extract_dict_ids(schema_desc)
    var dict_widths = _extract_dict_index_widths(schema_desc)
    var any_dict_encoded = False
    for i in range(len(is_dict_encoded)):
        if is_dict_encoded[i]:
            any_dict_encoded = True
            break

    # 6. Walk the Footer's dictionary block list + populate cache.
    #    Dict frames are materialized into owning bytes (small frames;
    #    not the hot allocation). Same pattern as
    #    `decode_arrow_ipc_file_path_mmap` (uncompressed PHASE-3 path).
    var n_dict = len(footer.dictionaries)
    for di in range(n_dict):
        ref dblk = footer.dictionaries[di]
        var d_offset = Int(dblk.offset)
        var d_meta_len = Int(dblk.meta_data_length)
        var d_body_len = Int(dblk.body_length)
        var d_frame_len = d_meta_len + d_body_len
        if d_offset < 0 or d_offset + d_frame_len > n:
            _ = cancel_token^
            raise Error(
                "decode_arrow_ipc_file_path_mmap_codec: DictionaryBatch"
                + " Block out of range (idx=" + String(di) + ")"
            )
        # Dict frames: materialize via copy_from_view_at (small frames).
        var d_frame = SharedAlignedBuffer[HeapRegion].heap_owned(d_frame_len)
        d_frame.copy_from_view_at(0, src.view_range_ro(d_offset, d_frame_len))
        d_frame.set_length(d_frame_len)


        var fi = parse_ipc_message(d_frame)
        var fb = SharedAlignedBuffer[HeapRegion].heap_owned(fi.metadata_size)
        fb.copy_from_view_at(
            0, d_frame.view_range_ro(fi.metadata_pos, fi.metadata_size)
        )
        fb.set_length(fi.metadata_size)

        var fb_reader = flatbuf_reader_over(fb)
        var d_msg = read_message(fb_reader, fb_reader.read_root_offset())
        if d_msg.header_tag != MESSAGE_HEADER_DICTIONARY_BATCH:
            _ = cancel_token^
            raise Error(
                "decode_arrow_ipc_file_path_mmap_codec: footer.dictionaries["
                + String(di) + "] is not a DICTIONARY_BATCH"
            )
        # Class C: this entry keeps a concrete LocalDispatcher[NoopSink]
        # signature (engine_context calls it [C, origin_of(disp)]); bind
        # D=LocalDispatcher[NoopSink] explicitly into the generic core entries.
        _consume_dictionary_batch_frame_with_dispatcher[
            LocalDispatcher[NoopSink], disp_o
        ](
            d_frame^, d_msg.header_table_pos,
            fi.metadata_size, Int(d_msg.body_length), cache,
            dispatcher_ptr, cancel_token.clone(),
        )

    # 7. Walk RB blocks. Each rb_frame is borrowed-from-mmap (zero-copy).
    #    Then dispatch to the coalesced decompress driver.
    var n_rb = len(footer.record_batches)
    if n_rb == 0:
        var empty_builder = RecordBatchBuilder.with_capacity(
            schema.num_columns()
        )
        _ = src^
        _ = cancel_token^
        # Chunked contract: carry a single 0-row RB so the downstream
        # `InMemorySource.from_record_batches` can derive the schema.
        var empty_block = Slab[RecordBatch]()
        empty_block.append(empty_builder.build(schema^))
        return empty_block^

    # PASS 0: build rb_frames slab as borrowed-from-mmap AlignedBuffers.
    var rb_frames = Slab[SharedAlignedBuffer[HeapRegion]]()
    for bi in range(n_rb):
        ref blk = footer.record_batches[bi]
        var blk_offset = Int(blk.offset)
        var blk_meta_len = Int(blk.meta_data_length)
        var blk_body_len = Int(blk.body_length)
        var frame_len = blk_meta_len + blk_body_len
        if blk_offset < 0 or blk_offset + frame_len > n:
            _ = cancel_token^
            raise Error(
                "decode_arrow_ipc_file_path_mmap_codec: RecordBatch Block"
                + " out of range (idx=" + String(bi) + ")"
            )
        # ARROW-IPC-PERF-MMAP-COMPRESSED-INPUT-FRAME core lever: rb_frame
        # is a borrowed-from-mmap MmapAlignedBuffer. Zero alloc, zero memcpy
        # at frame construction. The ArcPointer keepalive on the buffer
        # holds the mmap region alive while the decompress driver reads
        # from it.
        #
        # OBJECTSTORE-V04 Phase 3b.2 SESSION 3 Path B: realign to
        # HeapRegion so it can be stored in `rb_frames: List[MmapAlignedBuffer
        # [8]]` (HeapRegion default). One memcpy per RecordBatch frame
        # at decompress dispatch time; this defeats the
        # COMPRESSED-INPUT-FRAME zero-alloc / zero-memcpy promise above.
        # Path A (parametric List element type) deferred.
        var rb_frame = SharedAlignedBuffer.borrow_from_mmap(
            region_arc, Int64(blk_offset), Int64(frame_len)
        ).realign_to[8]()
        rb_frames.append(rb_frame^)

    # PASS 1: coalesced decompress dispatch. Reads from mmap-borrowed
    # input frames; allocates owning per-RB output frames for the
    # decompressed bytes. The dispatcher does ONE fork-join barrier
    # across all (rb, buf) pairs.
    var decompressed_frames = decompress_all_rbs_into_with_dispatcher[
        C, LocalDispatcher[NoopSink], disp_o
    ](
        rb_frames^,
        dispatcher_ptr,
        cancel_token.clone(),
    )

    # PASS 2: per-RB Column-build off the OWNING decompressed frames.
    # The mmap-borrowed input frames have been consumed by the decompress
    # driver (Slab moved in). The output frames are owning.
    var per_block = Slab[RecordBatch]()
    for bi in range(n_rb):
        var rb_frame = decompressed_frames.take_slot_unchecked(bi)

        var cols: Slab[Column[HeapRegion]]
        if any_dict_encoded:
            var dict_values = _build_dict_values_per_col(
                is_dict_encoded, dict_ids, cache,
            )
            cols = decode_record_batch_message_with_dicts_with_dispatcher[
                LocalDispatcher[NoopSink], disp_o,
            ](
                rb_frame^,
                arrow_types,
                is_dict_encoded,
                dict_values^,
                dict_widths,
                dispatcher_ptr,
                cancel_token.clone(),
            )
        else:
            cols = decode_record_batch_message_with_dispatcher[
                LocalDispatcher[NoopSink], disp_o
            ](
                rb_frame^,
                arrow_types,
                dispatcher_ptr,
                cancel_token.clone(),
            )

        var builder = RecordBatchBuilder.with_capacity(len(cols))
        var num_cols = len(cols)
        for i in range(num_cols):
            builder.add_column(cols.take_slot_unchecked(i))
        cols.set_len_unchecked(0)
        _ = cols^
        per_block.append(builder.build(schema.copy()))

    # Cleanup the decompressed_frames slab.
    decompressed_frames.set_len_unchecked(0)
    _ = decompressed_frames^
    _ = src^
    _ = schema^
    _ = cancel_token^
    # region_arc itself is dropped on function return; the Arc refcount
    # decrements. The mmap region stays alive as long as ANY per-column
    # ArcPointer<MmapRegion> keepalive is alive. In the compressed path,
    # the returned RecordBatch holds OWNING columns built off the
    # decompressed output frames — no per-column mmap keepalive remains.
    # The mmap region's last refcount drops here (or shortly after when
    # the borrowed input frames are dropped inside the decompress driver),
    # firing munmap(2) BEFORE the function returns. This is correct
    # because the decompressed bytes have been fully copied out of the
    # mmap'd source by `decompress_all_rbs_into_with_dispatcher`.
    # ARROW-IPC-READ-NO-CONCAT: carry the per-block chunks un-concatenated.
    return per_block^


# View-based magic helpers (replicas of the bytes-mode versions; kept
# private to this entry point for clarity).
def _view_matches_arrow1_magic_8(view: ByteView[_]) -> Bool:
    """Return True if `view` is exactly 'ARROW1\\0\\0' (8 bytes)."""
    if view.len() < 8:
        return False
    return (
        view.read_u8_at(0) == UInt8(0x41)  # 'A'
        and view.read_u8_at(1) == UInt8(0x52)  # 'R'
        and view.read_u8_at(2) == UInt8(0x52)  # 'R'
        and view.read_u8_at(3) == UInt8(0x4F)  # 'O'
        and view.read_u8_at(4) == UInt8(0x57)  # 'W'
        and view.read_u8_at(5) == UInt8(0x31)  # '1'
        and view.read_u8_at(6) == UInt8(0x00)
        and view.read_u8_at(7) == UInt8(0x00)
    )


def is_arrow1_file_format_path(path: String) -> Bool:
    """Peek the first 8 bytes of `path` and return True iff they match
    the ARROW1\\0\\0 magic header (Arrow IPC File-format).

    Used by `EngineContext.read_arrow(path)` to route File-format
    files into the mmap fast path and Stream-format files into the
    standard bytes-mode auto-detect.

    Returns False on any open / read / short-file failure (the caller's
    fallback path handles those cases with full diagnostics).
    """
    try:
        var fh = FileHandle(path, "r")
        var head = fh.read_bytes(8)
        fh.close()
        if len(head) < 8:
            return False
        return (
            head[0] == UInt8(0x41)
            and head[1] == UInt8(0x52)
            and head[2] == UInt8(0x52)
            and head[3] == UInt8(0x4F)
            and head[4] == UInt8(0x57)
            and head[5] == UInt8(0x31)
            and head[6] == UInt8(0x00)
            and head[7] == UInt8(0x00)
        )
    except:
        return False


def _view_matches_arrow1_magic_6(view: ByteView[_]) -> Bool:
    """Return True if `view` is exactly 'ARROW1' (6 bytes)."""
    if view.len() < 6:
        return False
    return (
        view.read_u8_at(0) == UInt8(0x41)
        and view.read_u8_at(1) == UInt8(0x52)
        and view.read_u8_at(2) == UInt8(0x52)
        and view.read_u8_at(3) == UInt8(0x4F)
        and view.read_u8_at(4) == UInt8(0x57)
        and view.read_u8_at(5) == UInt8(0x31)
    )
