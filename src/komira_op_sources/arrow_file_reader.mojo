# =============================================================================
# arrow_file_reader.mojo — read-side driver for `ctx.read_arrow(path/handle)`.
# ARROW-IPC-PHASE-4 step 2.
# =============================================================================
#
# Sibling to `arrow_stream_reader.mojo`. Decodes Arrow IPC byte streams
# in File-format (RFC v0.3.2 §1.5) AND dispatches stream-vs-file on
# auto-detect (`decode_arrow_ipc_auto`). The File format wraps the
# Stream-format middle (Schema + RecordBatch frames are byte-identical
# to Stream-mode); the differences are:
#
#   Layout (RFC §1.5):
#     [ARROW1\0\0  magic header (8 bytes)]
#     [Schema-msg FB frame]                  <- continuation + size + FB
#     [DictionaryBatch-msg FB frame] *       <- PHASE-4 step 3 (read merge)
#     [RecordBatch-msg FB frame + body] *
#     <NO EOS marker>
#     [Footer flatbuffer]
#     [i32 footer_length LE]                 <- 4 bytes
#     [ARROW1 trailer (6 bytes)]
#
# Random-access read driver (this file):
#   1. Validate ARROW1\0\0 magic at start + ARROW1 trailer at end.
#   2. Read i32 footer_length at byte n-10.
#   3. Slice the Footer FB at [n - 10 - footer_length, n - 10) into a
#      fresh MmapAlignedBuffer; decode via `read_footer`.
#   4. Decode the Footer's Schema (re-emitted; pyarrow + arrow-rs trust
#      this copy on read — Arrow spec allows it to differ from the head
#      Schema-message Schema).
#   5. For each Block in `recordBatches`: slice [block.offset,
#      block.offset + block.metaDataLength + block.bodyLength) into a
#      fresh MmapAlignedBuffer + decode via `decode_record_batch_message`.
#   6. Merge into one RecordBatch (PHASE-4 v1: 0 / 1 batches supported;
#      N > 1 raises clear PHASE-4-FOLLOWUP-MULTI-BATCH-CONCAT, mirroring
#      `arrow_stream_reader.mojo`).
#
# Modules: this file holds the in-memory File reader and the auto-detect
# entry points; `arrow_file_reader_codec.mojo` the readers that report and
# enforce the body codec; `arrow_file_reader_mmap.mojo` the memory-mapped
# reader for a path. The frame helpers both formats share are in
# `ipc_stream_frames.mojo`.
#
# Auto-detect path:
#   - Peek bytes[0..8]; if equals 'ARROW1\0\0' → File-format
#     (`decode_arrow_ipc_file`); else → Stream-format
#     (`decode_arrow_ipc_stream`).
#   - The auto-detector is what `ctx.read_arrow(path/handle)` calls;
#     `ctx.read_arrow_stream(path/handle)` continues to bypass the
#     auto-detect for Stream-only callers.
#
# === Why eager materialize in PHASE-4 v1 ===
#
# RFC §2.6 reserves the lazy `FileSource[Arrow[C]]` shape for the engine
# scan-operator integration. PHASE-4 step 2 ships the eager path (decode
# entire file → in-memory DataFrame). The engine has no Arrow scan
# operator wired today (`SOURCE_VARIANT_ARROW_UNCOMPRESSED` has zero
# downstream consumers in the compiler or the engine runtime),
# so the lazy shape would be invisible to the engine. PHASE-4-FOLLOWUP-
# ARROW-SCAN-OPERATOR adds the operator and wires a lazy reader.
#
# === SAFETY contract ===
#
# - No `UnsafePointer` in any public signature.
# - No wildcard origins. `Span[UInt8, _]` is the canonical byte view.
# - Frame-size accounting is u64-arithmetic-safe (no truncation).
# - Decoder per-message errors propagate verbatim — caller sees the
#   underlying decoder's diagnostic.
# =============================================================================

from komira_arrow_ipc.ipc_body_compression import decompress_all_rbs_into_with_dispatcher
from komira_compression.compression_codecs import Lz4Frame, Zstd
from komira_arrow_ipc.ipc_decoder_dispatch import (
    decode_record_batch_message,
    decode_record_batch_message_with_dicts,
    decode_record_batch_message_with_dicts_with_dispatcher,
    decode_record_batch_message_with_dispatcher,
    peek_record_batch_codec_from_frame,
)
from komira_async_api.token import CancellationToken
from komira_async_api.parallel_dispatch import ParallelDispatch, NoDispatch
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_arrow_ipc.ipc_encoder_dispatch import ARROW1_HEADER_LEN, ARROW1_MAGIC_LEN
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
from komira_op_sources.arrow_stream_reader import (
    decode_arrow_ipc_stream,
    decode_arrow_ipc_stream_with_dict_cache,
    decode_arrow_ipc_stream_with_dict_cache_with_dispatcher,
)
from komira_collections.slab import Slab
from komira_op_sources.ipc_dict_cache import IpcDictCache
from komira_counters.runtime_introspection import trace_alloc
from komira_buffer.heap_region import HeapRegion



# =============================================================================
# Magic-byte helpers
# =============================================================================
#
# Reuses the ARROW1_HEADER_LEN / ARROW1_MAGIC_LEN comptime aliases from
# `ipc_encoder_dispatch.mojo` to keep the magic-byte constants in one
# place; the read-side just compares.


def _bytes_match_arrow1_header(bytes: List[UInt8]) -> Bool:
    """Return True iff `bytes[0..8]` is the 8-byte ARROW1\\0\\0 magic
    header ('A''R''R''O''W''1' + 2 zero pad bytes).

    Used by `decode_arrow_ipc_auto` to dispatch Stream vs File format
    without raising — a Stream-format buffer DOES NOT start with these
    bytes (Stream begins with the continuation marker 0xFFFFFFFF =
    bytes[0..4] = 0xFF * 4).
    """
    if len(bytes) < ARROW1_HEADER_LEN:
        return False
    if bytes[0] != UInt8(0x41):  # 'A'
        return False
    if bytes[1] != UInt8(0x52):  # 'R'
        return False
    if bytes[2] != UInt8(0x52):  # 'R'
        return False
    if bytes[3] != UInt8(0x4F):  # 'O'
        return False
    if bytes[4] != UInt8(0x57):  # 'W'
        return False
    if bytes[5] != UInt8(0x31):  # '1'
        return False
    if bytes[6] != UInt8(0x00):  # pad
        return False
    if bytes[7] != UInt8(0x00):  # pad
        return False
    return True


def _bytes_match_arrow1_trailer(bytes: List[UInt8]) -> Bool:
    """Return True iff `bytes[-6..]` is the 6-byte ARROW1 trailer magic."""
    var n = len(bytes)
    if n < ARROW1_MAGIC_LEN:
        return False
    if bytes[n - 6] != UInt8(0x41):
        return False
    if bytes[n - 5] != UInt8(0x52):
        return False
    if bytes[n - 4] != UInt8(0x52):
        return False
    if bytes[n - 3] != UInt8(0x4F):
        return False
    if bytes[n - 2] != UInt8(0x57):
        return False
    if bytes[n - 1] != UInt8(0x31):
        return False
    return True


def _read_i32_le_from_list(bytes: List[UInt8], offset: Int) -> Int32:
    """Read a little-endian i32 from a List[UInt8] at byte offset."""
    var b0 = Int(bytes[offset]) & 0xFF
    var b1 = Int(bytes[offset + 1]) & 0xFF
    var b2 = Int(bytes[offset + 2]) & 0xFF
    var b3 = Int(bytes[offset + 3]) & 0xFF
    return Int32(b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))


# =============================================================================
# decode_arrow_ipc_file — File-format bytes → RecordBatch
# =============================================================================


def decode_arrow_ipc_file(
    var bytes: List[UInt8],
) raises -> RecordBatch:
    """Decode a complete Arrow IPC File-format byte sequence to one
    `RecordBatch`.

    Layout (RFC v0.3.2 §1.5):
        [ARROW1\\0\\0 8 bytes]
        [Schema frame]
        [DictionaryBatch frame] *   (PHASE-4 step 3 — read-side cache)
        [RecordBatch frame] *
        [Footer FB]
        [i32 footer_length LE]
        [ARROW1 6 bytes]

    PHASE-4 step 3: the `dictionaries` block list is now
    walked + each DictionaryBatch frame is decoded into a transient
    `IpcDictCache`. The cache is dropped on return.

    Multi-batch policy is unchanged from step 2:
      - 0 RecordBatch blocks → Schema-only file → empty batch with the
        decoded Schema (zero rows / zero columns appended).
      - 1 RecordBatch block  → that batch.
      - N RecordBatch blocks → raises a clear PHASE-4-FOLLOWUP-MULTI-
        BATCH-CONCAT error (multi-batch concat needs `Column.concat`
        which is not in the v0.4 Column surface; same constraint as
        the stream reader has).

    Raises on:
        - Missing/invalid ARROW1 magic (head or trailer).
        - Invalid i32 footer_length (negative / out of range).
        - Footer FB decode failure.
        - Per-RecordBatch decode failure (forwarded from
          `decode_record_batch_message`).
        - DictionaryBatch decode failure (forwarded from
          `_consume_dictionary_batch_frame`).
        - More than 1 RecordBatch block (PHASE-4-FOLLOWUP-MULTI-BATCH).

    The bytes are consumed (`var bytes: List[UInt8]`).

    Dict-cache: this is a thin wrapper around
    `decode_arrow_ipc_file_with_dict_cache` that uses a transient
    local cache (dropped on return). PHASE-4 step 3 callers that need
    the cumulative dictionary state visible across multiple top-level
    reads (e.g. `EngineContext.read_arrow` which clears the
    EngineContext-owned cache at entry) use the `_with_dict_cache`
    variant directly.

    PHASE-6A-FOLLOWUP-TRACE-ALLOC: emits an `arrow_ipc.driver_enter`
    marker for bench attribution (0 bytes; logical entry tag).
    """
    # PHASE-6A-FOLLOWUP-TRACE-ALLOC: file-driver entry marker.
    trace_alloc["arrow_ipc.driver_enter"](0)
    var cache = IpcDictCache()
    return decode_arrow_ipc_file_with_dict_cache(bytes^, cache)


def decode_arrow_ipc_file_with_dict_cache(
    var bytes: List[UInt8],
    mut cache: IpcDictCache,
) raises -> RecordBatch:
    """Dict-cache-aware variant of `decode_arrow_ipc_file`. Serial-fallback
    wrapper. See `decode_arrow_ipc_file_with_dict_cache_with_dispatcher`
    for the dispatcher-aware variant that drives the per-buffer decompress
    in parallel.

    Walks `footer.dictionaries: List[Block]` first (each Block is a
    DictionaryBatch frame at `block.offset` of length `block.meta_data
    _length + block.body_length`), then walks `footer.record_batches`.
    Per Arrow spec, DictionaryBatch frames in a File-format file are
    indexed by the Footer's `dictionaries` field rather than being
    encountered inline in a forward walk; the read order is
    "dictionaries first, then record batches" for random-access shape.

    See `decode_arrow_ipc_file` for the full layout + multi-batch
    policy. Dict-cache semantics: per Arrow spec, the first
    DictionaryBatch for any given dict_id MUST be isDelta=False (the
    cache enforces this — `append_to` raises if no prior entry exists).
    Subsequent DictionaryBatch entries with the same id MAY be
    isDelta=True (append) or isDelta=False (replace).
    """
    # Class C: serial-fallback substitutes D=NoDispatch with a CONCRETE
    # origin, NOT MutAnyOrigin.
    var _nd = NoDispatch()
    comptime nd_o = origin_of(_nd)
    return _decode_arrow_ipc_file_with_dict_cache_impl[
        NoDispatch, has_pool=False, disp_o=nd_o,
    ](
        bytes^,
        cache,
        Optional[Pointer[NoDispatch, nd_o]](None),
        CancellationToken.never(),
    )


def decode_arrow_ipc_file_with_dict_cache_with_dispatcher[
    disp_o: Origin[mut=True],
](
    var bytes: List[UInt8],
    mut cache: IpcDictCache,
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
) raises -> RecordBatch:
    """Dispatcher-aware variant of `decode_arrow_ipc_file_with_dict_cache`.

    Threads EngineContext-owned dispatcher + cancel_token down to the
    per-buffer body decompression pre-pass for parallel codec dispatch.
    Class C: binds the concrete `LocalDispatcher[NoopSink]` as the
    `D: ParallelDispatch` parameter of the dispatcher-generic impl.

    ARROW-IPC-DISPATCHER-PLUMB-CASCADE-COMPLETE.
    """
    return _decode_arrow_ipc_file_with_dict_cache_impl[
        LocalDispatcher[NoopSink], has_pool=True, disp_o=disp_o,
    ](
        bytes^,
        cache,
        Optional[Pointer[LocalDispatcher[NoopSink], disp_o]](dispatcher_ptr),
        cancel_token^,
    )


def _decode_arrow_ipc_file_with_dict_cache_impl[
    D: ParallelDispatch,
    has_pool: Bool,
    disp_o: Origin[mut=True],
](
    var bytes: List[UInt8],
    mut cache: IpcDictCache,
    dispatcher_ptr: Optional[Pointer[D, disp_o]],
    var cancel_token: CancellationToken,
) raises -> RecordBatch:
    """Shared body for the bare + `_with_dispatcher` `decode_arrow_ipc_
    file_with_dict_cache` variants. Comptime `has_pool` prunes the parallel
    decompress branch."""
    var n = len(bytes)
    # Minimum valid Arrow File: ARROW1 header(8) + Schema-frame(~64 min)
    # + Footer-FB(~80 min) + i32 length(4) + ARROW1 trailer(6) = ~162.
    # Use a conservative lower bound of head(8) + footer-length(4) +
    # trailer(6) = 18 (will fail on Footer-FB decode if smaller).
    if n < 8 + 4 + 6:
        raise Error(
            "decode_arrow_ipc_file: input too short ("
            + String(n)
            + " bytes); a valid Arrow File is at least ARROW1 + Schema"
            + " + Footer + i32 length + ARROW1 (~162 bytes minimum)"
        )

    # 1. Validate magic at head + trailer.
    if not _bytes_match_arrow1_header(bytes):
        raise Error(
            "decode_arrow_ipc_file: missing ARROW1\\0\\0 magic header at byte 0"
            " (got 0x" + String(Int(bytes[0])) + " " + String(Int(bytes[1]))
            + " " + String(Int(bytes[2])) + " " + String(Int(bytes[3]))
            + " ...). Use `decode_arrow_ipc_stream` for Stream-format input."
        )
    if not _bytes_match_arrow1_trailer(bytes):
        raise Error(
            "decode_arrow_ipc_file: missing ARROW1 magic trailer at bytes"
            " [n-6..n]; file truncated or not Arrow File format"
        )

    # 2. Read i32 footer_length at n-10 (last 6 = trailer; 4 before = length).
    var footer_len = Int(_read_i32_le_from_list(bytes, n - 10))
    if footer_len <= 0:
        raise Error(
            "decode_arrow_ipc_file: invalid footer_length "
            + String(footer_len)
            + " (must be > 0)"
        )
    # Footer FB starts at n - 10 - footer_len; must come AFTER the magic
    # header (offset 8 minimum).
    var footer_start = n - 10 - footer_len
    if footer_start < 8:
        raise Error(
            "decode_arrow_ipc_file: footer_length " + String(footer_len)
            + " is too large for file size " + String(n)
            + " (would start at byte " + String(footer_start) + ")"
        )

    # 3. Slurp the file bytes into an MmapAlignedBuffer for cross-frame access.
    # ARROW-IPC-PERF: bulk memcpy via `copy_from_bytes_list`.
    # The prior scalar `for i in range(n): src.write_u8_at(i, bytes[i])`
    # loop dominated the uncompressed-read wall (~80% of 2.2s on SF1
    # lineitem 1.16 GB) because Mojo's autovec does NOT lift unit-stride
    # byte loops -- see an internal doc §0.
    var src = SharedAlignedBuffer[HeapRegion].heap_owned(n)
    src.copy_from_bytes_list(bytes^)

    # 4. Slice the Footer FB into its own buffer; decode via read_footer.
    # ARROW-IPC-PERF: bulk memcpy via copy_from_view_at +
    # view_range_ro. Same rationale as the bytes-list copy above.
    var footer_fb = SharedAlignedBuffer[HeapRegion].heap_owned(footer_len)
    footer_fb.copy_from_view_at(0, src.view_range_ro(footer_start, footer_len))
    footer_fb.set_length(footer_len)
    var footer_reader = flatbuf_reader_over(footer_fb)
    var footer = read_footer(
        footer_reader, footer_reader.read_root_offset()
    )

    # 5. Decode the Footer's re-emitted Schema → Komira Schema. The
    #    Arrow spec allows the Footer's Schema to differ from the head
    #    Schema-message Schema; the read side trusts the Footer's copy
    #    (matches pyarrow + arrow-rs behavior).
    var schema_desc = read_schema(footer_reader, footer.schema_table_pos)
    var schema = _ipc_schema_desc_to_komira_schema(schema_desc, footer_fb)
    var arrow_types: List[ArrowType] = List[ArrowType]()
    for i in range(schema.num_columns()):
        arrow_types.append(schema.field_arrow_type(i))
    # PHASE-4-FOLLOWUP-DICT-DECODE-COLUMN commit 2/3:
    # extract dict_metadata from the Footer's Schema (mirrors the
    # Stream-format wiring in arrow_stream_reader).
    var is_dict_encoded = _extract_is_dict_encoded(schema_desc)
    var dict_ids = _extract_dict_ids(schema_desc)
    # PHASE-4-FOLLOWUP-DICT-WIDER-INDEX.
    var dict_widths = _extract_dict_index_widths(schema_desc)
    var any_dict_encoded = False
    for i in range(len(is_dict_encoded)):
        if is_dict_encoded[i]:
            any_dict_encoded = True
            break

    # 5.5. PHASE-4 step 3: walk the Footer's `dictionaries` block list +
    #      decode each DictionaryBatch frame into the cache, BEFORE the
    #      RecordBatch decode. Per Arrow spec, dict batches must be
    #      consumable before any RecordBatch that references them is
    #      decoded (the cache holds the cumulative state across isDelta
    #      replace + append chains).
    var n_dict = len(footer.dictionaries)
    for di in range(n_dict):
        ref dblk = footer.dictionaries[di]
        var d_offset = Int(dblk.offset)
        var d_meta_len = Int(dblk.meta_data_length)
        var d_body_len = Int(dblk.body_length)
        var d_frame_len = d_meta_len + d_body_len
        if d_offset < 0 or d_offset + d_frame_len > n:
            raise Error(
                "decode_arrow_ipc_file: DictionaryBatch Block out of range"
                + " (idx=" + String(di)
                + ", offset=" + String(d_offset)
                + ", frame_len=" + String(d_frame_len)
                + ", file_size=" + String(n) + ")"
            )
        # ARROW-IPC-PERF: bulk memcpy via copy_from_view_at.
        var d_frame = SharedAlignedBuffer[HeapRegion].heap_owned(d_frame_len)
        d_frame.copy_from_view_at(0, src.view_range_ro(d_offset, d_frame_len))
        d_frame.set_length(d_frame_len)

        # Re-parse the framing to learn metadata_size + header table pos
        # (the Footer's Block carries metaDataLength + bodyLength but
        # not the header_table_pos; we re-decode the FB Message header
        # to extract it). Same shape as the Stream-format consume path.
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
                "decode_arrow_ipc_file: footer.dictionaries[" + String(di)
                + "] points at a Message whose header_tag is "
                + String(Int(d_msg.header_tag))
                + " (expected DICTIONARY_BATCH = "
                + String(Int(MESSAGE_HEADER_DICTIONARY_BATCH)) + ")"
            )

        comptime if has_pool:
            _consume_dictionary_batch_frame_with_dispatcher[D, disp_o](
                d_frame^, d_msg.header_table_pos,
                fi.metadata_size, Int(d_msg.body_length), cache,
                dispatcher_ptr.value(), cancel_token.clone(),
            )
        else:
            _consume_dictionary_batch_frame(
                d_frame^, d_msg.header_table_pos,
                fi.metadata_size, Int(d_msg.body_length), cache,
            )

    # 6. PHASE-6A-FOLLOWUP-MULTI-BATCH-CONCAT: walk the
    # Footer's recordBatches block list + decode each one into its own
    # RecordBatch, then fold them via `_concat_batches` (a pair-wise
    # `_concat_columns` fold) into ONE merged RecordBatch.
    #
    # Schema-only file (n_rb == 0) → zero-row batch with the decoded Schema.
    var n_rb = len(footer.record_batches)
    if n_rb == 0:
        var empty_builder = RecordBatchBuilder.with_capacity(
            schema.num_columns()
        )
        return empty_builder.build(schema^)

    # 7. Decode each Block into a per-block RecordBatch.
    #
    # ARROW-IPC-PERF-RB-COALESCE: file-level coalesced
    # decompress. Before this slot, each RB called
    # `decompress_record_batch_frame_with_dispatcher[C]` separately,
    # producing N fork-join barriers (49 for lineitem). The
    # `_dispatch_semaphore_wait_slow` samples dominated the LZ4 read
    # profile (38% main-thread idle on 11 cores).
    #
    # New shape: slurp all RB frames first, peek codec on the first RB,
    # then call `decompress_all_rbs_into_with_dispatcher[C]` to
    # decompress ALL RBs in ONE coalesced dispatch (workers stride
    # across RB boundaries; one wake-word barrier total). The per-RB
    # decoders downstream see uncompressed frames + short-circuit the
    # `_decompress_frame_if_needed*` peek.
    #
    # Gated on `has_pool` (dispatcher available) AND first-RB codec id
    # != -1 (file is compressed). Uncompressed files keep the prior
    # per-RB shape (no decompress work to coalesce).
    var per_block = Slab[RecordBatch]()

    # PASS 0: slurp all RB frames into a slab.
    var rb_frames = Slab[SharedAlignedBuffer[HeapRegion]]()
    for bi in range(n_rb):
        ref blk = footer.record_batches[bi]
        var blk_offset = Int(blk.offset)
        var blk_meta_len = Int(blk.meta_data_length)
        var blk_body_len = Int(blk.body_length)
        var frame_len = blk_meta_len + blk_body_len
        if blk_offset < 0 or blk_offset + frame_len > n:
            raise Error(
                "decode_arrow_ipc_file: RecordBatch Block out of range"
                + " (idx=" + String(bi)
                + ", offset=" + String(blk_offset)
                + ", frame_len=" + String(frame_len)
                + ", file_size=" + String(n) + ")"
            )
        var rb_frame = SharedAlignedBuffer[HeapRegion].heap_owned(frame_len)
        rb_frame.copy_from_view_at(
            0, src.view_range_ro(blk_offset, frame_len)
        )
        rb_frame.set_length(frame_len)
        rb_frames.append(rb_frame^)

    # PASS 1: optionally pre-decompress all RBs in ONE coalesced dispatch.
    comptime if has_pool:
        if n_rb > 0:
            var first_codec = peek_record_batch_codec_from_frame(
                rb_frames[0]
            )
            if first_codec == Int8(0):
                # LZ4_FRAME: coalesced decompress for the whole file.
                rb_frames = decompress_all_rbs_into_with_dispatcher[
                    Lz4Frame, D, disp_o
                ](
                    rb_frames^,
                    dispatcher_ptr.value(),
                    cancel_token.clone(),
                )
            elif first_codec == Int8(1):
                # ZSTD: coalesced decompress for the whole file.
                rb_frames = decompress_all_rbs_into_with_dispatcher[
                    Zstd[3], D, disp_o
                ](
                    rb_frames^,
                    dispatcher_ptr.value(),
                    cancel_token.clone(),
                )
            # codec_id == -1 (Uncompressed): no decompress work; the
            # per-RB decoders below see uncompressed frames directly.

    # ARROW-IPC-DECODE-ERROR-UNWIND-TCMALLOC fix: drain the
    # `rb_frames` slab RAISE-SAFELY. The prior shape took slot `bi` via
    # `take_slot_unchecked(bi)` (which moves the bits out but does NOT
    # touch `_len_t` — see Slab.take_slot_unchecked's SAFETY CONTRACT) and
    # only reset the length via `set_len_unchecked(0)` AFTER the loop on
    # the success path. When a per-RB decode raised mid-loop (e.g. a
    # corrupt RecordBatch Buffer descriptor caught by
    # `_validate_rb_buffers_in_bounds`), the raise unwound with
    # `rb_frames._len_t == n_rb`, so `Slab.__del__` re-ran `destroy_pointee`
    # over the already-moved-out slot `bi` — a use-after-free that
    # corrupts the tcmalloc free-list and crashes a LATER allocation
    # (the next process-wide `tc_memalign` walks the poisoned span).
    #
    # Fix: drain the FRONT slot via `take_at(0)`, which shifts the
    # remaining tail down and decrements `_len_t` atomically, so the
    # slab's tracked length ALWAYS equals the count of still-initialized
    # slots. On any raise the destructor drops exactly the un-drained
    # slots and nothing is dropped twice. Forward draining preserves the
    # multi-batch concat order. (n_rb = record-batch block count, small;
    # the O(n) shift per take is negligible vs the per-RB decode.)
    for _ in range(n_rb):
        var rb_frame = rb_frames.take_at(0)

        # PHASE-4-FOLLOWUP-DICT-DECODE-COLUMN commit 2/3:
        # dispatch to dict-aware decoder if ANY column on this schema
        # is dict-encoded. Cache already populated above by the
        # `footer.dictionaries` walk.
        var cols: Slab[Column[HeapRegion]]
        if any_dict_encoded:
            var dict_values = _build_dict_values_per_col(
                is_dict_encoded, dict_ids, cache,
            )

            comptime if has_pool:
                cols = decode_record_batch_message_with_dicts_with_dispatcher[
                    D, disp_o,
                ](
                    rb_frame^,
                    arrow_types,
                    is_dict_encoded,
                    dict_values^,
                    dict_widths,
                    dispatcher_ptr.value(),
                    cancel_token.clone(),
                )
            else:
                cols = decode_record_batch_message_with_dicts(
                    rb_frame^,
                    arrow_types,
                    is_dict_encoded,
                    dict_values^,
                    dict_widths,
                )
        else:

            comptime if has_pool:
                cols = decode_record_batch_message_with_dispatcher[D, disp_o](
                    rb_frame^,
                    arrow_types,
                    dispatcher_ptr.value(),
                    cancel_token.clone(),
                )
            else:
                cols = decode_record_batch_message(rb_frame^, arrow_types)

        var builder = RecordBatchBuilder.with_capacity(len(cols))
        var num_cols = len(cols)
        for i in range(num_cols):
            builder.add_column(cols.take_slot_unchecked(i))
        cols.set_len_unchecked(0)
        _ = cols^
        per_block.append(builder.build(schema.copy()))

    # 8. rb_frames is now fully drained (`_len_t == 0` after the last
    # take_at); the slab drop is a no-op over zero live slots.
    _ = rb_frames^

    # 9. Fold the per-block batches into one merged RecordBatch. The schema
    # for the merged result is taken from the first batch (all Block
    # schemas are byte-identical for a single Arrow File per spec).
    _ = schema^
    _ = cancel_token^
    return _concat_batches(per_block^)


# =============================================================================
# decode_arrow_ipc_auto — magic-peek dispatch over Stream vs File format
# =============================================================================
#
# Used by `ctx.read_arrow(path/handle)` — the load-bearing auto-detector
# for the user-facing API. Bytes that start with 'ARROW1\0\0' route to
# `decode_arrow_ipc_file`; otherwise they route to
# `decode_arrow_ipc_stream`. A Stream-format byte sequence cannot start
# with these 8 bytes (Stream begins with the IPC continuation marker
# 0xFFFFFFFF), so the dispatch is unambiguous.


def decode_arrow_ipc_auto(
    var bytes: List[UInt8],
) raises -> RecordBatch:
    """Auto-detect Stream vs File Arrow IPC format and dispatch.

    Peeks `bytes[0..8]`:
      - 'ARROW1\\0\\0' (8 bytes) → `decode_arrow_ipc_file(bytes)`.
      - anything else (typically the continuation marker `0xFFFFFFFF`
        followed by a u32 metadata_size) → `decode_arrow_ipc_stream(bytes)`.

    Returns the merged `RecordBatch`. Bytes are consumed.

    Raises on:
      - bytes too short to peek the magic (< 8 bytes).
      - underlying decoder errors (forwarded verbatim).

    PHASE-6A-FOLLOWUP-TRACE-ALLOC: emits an `arrow_ipc.driver_enter`
    marker for bench attribution (0 bytes; logical entry tag). The
    underlying file/stream driver emits its own driver_enter marker
    after dispatch, so a complete read sees TWO driver_enter markers
    (auto + concrete). Bench gate consumers can de-dupe via label
    if needed.
    """
    # PHASE-6A-FOLLOWUP-TRACE-ALLOC: auto-detect driver entry marker.
    trace_alloc["arrow_ipc.driver_enter"](0)
    var cache = IpcDictCache()
    return decode_arrow_ipc_auto_with_dict_cache(bytes^, cache)


def decode_arrow_ipc_auto_with_dict_cache(
    var bytes: List[UInt8],
    mut cache: IpcDictCache,
) raises -> RecordBatch:
    """Dict-cache-aware variant of `decode_arrow_ipc_auto`. Serial-fallback
    wrapper. See `decode_arrow_ipc_auto_with_dict_cache_with_dispatcher`
    for the dispatcher-aware variant that drives the per-buffer decompress
    in parallel.

    Peeks `bytes[0..8]` and dispatches to the cache-aware Stream or
    File decoder. The cache is mutated in place with the cumulative
    dictionary state assembled during the decode; the caller (typically
    `EngineContext.read_arrow_codec[*]`) is responsible for clearing
    the cache at entry of the top-level read.
    """
    if len(bytes) < 8:
        raise Error(
            "decode_arrow_ipc_auto: input too short ("
            + String(len(bytes))
            + " bytes); cannot peek magic (need >= 8 bytes)"
        )
    if _bytes_match_arrow1_header(bytes):
        return decode_arrow_ipc_file_with_dict_cache(bytes^, cache)
    return decode_arrow_ipc_stream_with_dict_cache(bytes^, cache)


def decode_arrow_ipc_auto_with_dict_cache_with_dispatcher[
    disp_o: Origin[mut=True],
](
    var bytes: List[UInt8],
    mut cache: IpcDictCache,
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
) raises -> RecordBatch:
    """Dispatcher-aware variant of `decode_arrow_ipc_auto_with_dict_cache`.

    ARROW-IPC-DISPATCHER-PLUMB-CASCADE-COMPLETE.
    """
    if len(bytes) < 8:
        _ = cancel_token^
        raise Error(
            "decode_arrow_ipc_auto: input too short ("
            + String(len(bytes))
            + " bytes); cannot peek magic (need >= 8 bytes)"
        )
    if _bytes_match_arrow1_header(bytes):
        return decode_arrow_ipc_file_with_dict_cache_with_dispatcher[disp_o](
            bytes^, cache, dispatcher_ptr, cancel_token^,
        )
    return decode_arrow_ipc_stream_with_dict_cache_with_dispatcher[disp_o](
        bytes^, cache, dispatcher_ptr, cancel_token^,
    )
