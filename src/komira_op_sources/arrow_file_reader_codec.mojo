# =============================================================================
# arrow_file_reader_codec.mojo -- the File-format readers that report and enforce the body codec.
# =============================================================================
#
# Split out of `arrow_file_reader.mojo` (the File-format layout, the
# auto-detect rule and the safety contract are described there) so each
# file stays under 1,000 lines.

from komira_arrow_ipc.ipc_body_compression import peek_dictionary_batch_codec_from_frame
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
    _strict_codec_name,
)
from komira_op_sources.arrow_stream_reader import (
    decode_arrow_ipc_stream,
    decode_arrow_ipc_stream_with_observed_codec,
    decode_arrow_ipc_stream_with_observed_codec_with_dispatcher,
)
from komira_collections.slab import Slab
from komira_op_sources.ipc_dict_cache import IpcDictCache
from komira_buffer.heap_region import HeapRegion
from komira_op_sources.arrow_file_reader import (
    _bytes_match_arrow1_header,
    _bytes_match_arrow1_trailer,
    _read_i32_le_from_list,
    decode_arrow_ipc_auto,
    decode_arrow_ipc_file,
)

# =============================================================================
# decode_arrow_ipc_file_with_observed_codec — strict-mode plumbing
# ARROW-IPC-PHASE-4 step 4
# =============================================================================
#
# Sidechannel sibling of `decode_arrow_ipc_file_with_dict_cache`. Walks
# the same File-format byte sequence + ALSO surfaces the BodyCompression
# .codec id of the first RecordBatch frame encountered via the mut
# out-param. Used by `ctx.read_arrow_strict[C]` (RFC v0.3.2 §0.8
# CHANGE-C).
#
# v1 records ONLY the first observed codec (no mixed-codec detection
# within ONE file — PHASE-4-FOLLOWUP-STRICT-MIXED-CODEC).


def decode_arrow_ipc_file_with_observed_codec(
    var bytes: List[UInt8],
    mut cache: IpcDictCache,
    mut observed_codec_id: Int8,
    strict_expected_codec_id: Int8,
) raises -> RecordBatch:
    """Serial-fallback wrapper. See
    `decode_arrow_ipc_file_with_observed_codec_with_dispatcher` for the
    dispatcher-aware variant.

    File-format equivalent of `decode_arrow_ipc_stream_with_observed_codec`.
    """
    # Class C: serial-fallback substitutes D=NoDispatch with a CONCRETE
    # origin, NOT MutAnyOrigin.
    var _nd = NoDispatch()
    comptime nd_o = origin_of(_nd)
    return _decode_arrow_ipc_file_with_observed_codec_impl[
        NoDispatch, has_pool=False, disp_o=nd_o,
    ](
        bytes^,
        cache,
        observed_codec_id,
        strict_expected_codec_id,
        Optional[Pointer[NoDispatch, nd_o]](None),
        CancellationToken.never(),
    )


def decode_arrow_ipc_file_with_observed_codec_with_dispatcher[
    disp_o: Origin[mut=True],
](
    var bytes: List[UInt8],
    mut cache: IpcDictCache,
    mut observed_codec_id: Int8,
    strict_expected_codec_id: Int8,
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
) raises -> RecordBatch:
    """Dispatcher-aware variant of `decode_arrow_ipc_file_with_observed_
    codec`. Class C: binds the concrete `LocalDispatcher[NoopSink]` as
    the `D: ParallelDispatch` parameter of the dispatcher-generic impl.

    ARROW-IPC-DISPATCHER-PLUMB-CASCADE-COMPLETE.
    """
    return _decode_arrow_ipc_file_with_observed_codec_impl[
        LocalDispatcher[NoopSink], has_pool=True, disp_o=disp_o,
    ](
        bytes^,
        cache,
        observed_codec_id,
        strict_expected_codec_id,
        Optional[Pointer[LocalDispatcher[NoopSink], disp_o]](dispatcher_ptr),
        cancel_token^,
    )


def _decode_arrow_ipc_file_with_observed_codec_impl[
    D: ParallelDispatch,
    has_pool: Bool,
    disp_o: Origin[mut=True],
](
    var bytes: List[UInt8],
    mut cache: IpcDictCache,
    mut observed_codec_id: Int8,
    strict_expected_codec_id: Int8,
    dispatcher_ptr: Optional[Pointer[D, disp_o]],
    var cancel_token: CancellationToken,
) raises -> RecordBatch:
    """Shared body for the bare + `_with_dispatcher` `decode_arrow_ipc_
    file_with_observed_codec` variants."""
    observed_codec_id = Int8(-1)

    var n = len(bytes)
    if n < 8 + 4 + 6:
        raise Error(
            "decode_arrow_ipc_file: input too short ("
            + String(n)
            + " bytes); a valid Arrow File is at least ARROW1 + Schema"
            + " + Footer + i32 length + ARROW1 (~162 bytes minimum)"
        )

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

    var footer_len = Int(_read_i32_le_from_list(bytes, n - 10))
    if footer_len <= 0:
        raise Error(
            "decode_arrow_ipc_file: invalid footer_length "
            + String(footer_len)
            + " (must be > 0)"
        )
    var footer_start = n - 10 - footer_len
    if footer_start < 8:
        raise Error(
            "decode_arrow_ipc_file: footer_length " + String(footer_len)
            + " is too large for file size " + String(n)
            + " (would start at byte " + String(footer_start) + ")"
        )

    # ARROW-IPC-PERF: bulk memcpy via copy_from_bytes_list +
    # copy_from_view_at. Mirrors the non-observed-codec variant fix above.
    var src = SharedAlignedBuffer[HeapRegion].heap_owned(n)
    src.copy_from_bytes_list(bytes^)

    var footer_fb = SharedAlignedBuffer[HeapRegion].heap_owned(footer_len)
    footer_fb.copy_from_view_at(0, src.view_range_ro(footer_start, footer_len))
    footer_fb.set_length(footer_len)
    var footer_reader = flatbuf_reader_over(footer_fb)
    var footer = read_footer(
        footer_reader, footer_reader.read_root_offset()
    )

    var schema_desc = read_schema(footer_reader, footer.schema_table_pos)
    var schema = _ipc_schema_desc_to_komira_schema(schema_desc, footer_fb)
    var arrow_types: List[ArrowType] = List[ArrowType]()
    for i in range(schema.num_columns()):
        arrow_types.append(schema.field_arrow_type(i))
    # PHASE-4-FOLLOWUP-DICT-DECODE-COLUMN commit 2/3:
    # symmetric to the non-observed-codec variant.
    var is_dict_encoded_obs = _extract_is_dict_encoded(schema_desc)
    var dict_ids_obs = _extract_dict_ids(schema_desc)
    # PHASE-4-FOLLOWUP-DICT-WIDER-INDEX.
    var dict_widths_obs = _extract_dict_index_widths(schema_desc)
    var any_dict_encoded_obs = False
    for i in range(len(is_dict_encoded_obs)):
        if is_dict_encoded_obs[i]:
            any_dict_encoded_obs = True
            break

    # Walk dictionaries (codec observation only applies to RB blocks; the
    # dict batches share the body-compression contract but are observed on
    # the RB side in strict-mode v1).
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
        # PHASE-4-FOLLOWUP-STRICT-MIXED-CODEC: enforce per-
        # dict-block codec match BEFORE consume on SUBSEQUENT dict
        # blocks; first-block mismatch left to the ctx-level layer.
        if strict_expected_codec_id != Int8(-2) and di != 0:
            var d_observed = peek_dictionary_batch_codec_from_frame(d_frame)
            if d_observed != strict_expected_codec_id:
                raise Error(
                    "StrictMixedCodec: expected "
                    + _strict_codec_name(strict_expected_codec_id)
                    + " across all batches but DictionaryBatch["
                    + String(di) + "] has "
                    + _strict_codec_name(d_observed)
                    + " (observed_codec_id="
                    + String(Int(d_observed))
                    + ", expected_codec_id="
                    + String(Int(strict_expected_codec_id)) + ")."
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

    # PHASE-4-FOLLOWUP-STRICT-MIXED-CODEC: per-RB-block
    # codec enforcement — when strict_expected_codec_id != -2 every RB
    # block has its peek'd codec compared against the expected id;
    # mismatch raises immediately. v1 captured FIRST block only for
    # back-compat; strict-mode now ALSO compares every subsequent block.
    var n_rb = len(footer.record_batches)
    if n_rb == 0:
        var empty_builder = RecordBatchBuilder.with_capacity(
            schema.num_columns()
        )
        return empty_builder.build(schema^)

    var per_block = Slab[RecordBatch]()
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

        # ARROW-IPC-PERF: bulk memcpy via copy_from_view_at.
        var rb_frame = SharedAlignedBuffer[HeapRegion].heap_owned(frame_len)
        rb_frame.copy_from_view_at(
            0, src.view_range_ro(blk_offset, frame_len)
        )
        rb_frame.set_length(frame_len)

        # Observe the BodyCompression codec id BEFORE decode. First-block
        # value captured in `observed_codec_id`; strict-mode enforces
        # uniformity across SUBSEQUENT blocks only (PHASE-4-FOLLOWUP-
        # STRICT-MIXED-CODEC). First-block mismatch with the
        # declared codec is left to the ctx-level layer to surface with
        # its "codec mismatch" diagnostic.
        var rb_block_codec = peek_record_batch_codec_from_frame(rb_frame)
        if bi == 0:
            observed_codec_id = rb_block_codec
        if (
            strict_expected_codec_id != Int8(-2)
            and bi != 0
            and rb_block_codec != strict_expected_codec_id
        ):
            raise Error(
                "StrictMixedCodec: expected "
                + _strict_codec_name(strict_expected_codec_id)
                + " across all batches but RecordBatch["
                + String(bi) + "] has "
                + _strict_codec_name(rb_block_codec)
                + " (observed_codec_id="
                + String(Int(rb_block_codec))
                + ", expected_codec_id="
                + String(Int(strict_expected_codec_id)) + ")."
            )

        # PHASE-4-FOLLOWUP-DICT-DECODE-COLUMN commit 2/3.
        var cols: Slab[Column[HeapRegion]]
        if any_dict_encoded_obs:
            var dict_values_obs = _build_dict_values_per_col(
                is_dict_encoded_obs, dict_ids_obs, cache,
            )

            comptime if has_pool:
                cols = decode_record_batch_message_with_dicts_with_dispatcher[
                    D, disp_o,
                ](
                    rb_frame^,
                    arrow_types,
                    is_dict_encoded_obs,
                    dict_values_obs^,
                    dict_widths_obs,
                    dispatcher_ptr.value(),
                    cancel_token.clone(),
                )
            else:
                cols = decode_record_batch_message_with_dicts(
                    rb_frame^,
                    arrow_types,
                    is_dict_encoded_obs,
                    dict_values_obs^,
                    dict_widths_obs,
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

    _ = schema^
    _ = cancel_token^
    return _concat_batches(per_block^)


def decode_arrow_ipc_auto_with_observed_codec(
    var bytes: List[UInt8],
    mut cache: IpcDictCache,
    mut observed_codec_id: Int8,
    strict_expected_codec_id: Int8,
) raises -> RecordBatch:
    """Auto-detect Stream vs File and dispatch to the matching
    `_with_observed_codec` decoder. Serial-fallback wrapper. See
    `decode_arrow_ipc_auto_with_observed_codec_with_dispatcher` for the
    dispatcher-aware variant.

    ARROW-IPC-PHASE-4 step 4 + PHASE-4-FOLLOWUP-STRICT-MIXED-CODEC
.
    """
    observed_codec_id = Int8(-1)
    if len(bytes) < 8:
        raise Error(
            "decode_arrow_ipc_auto: input too short ("
            + String(len(bytes))
            + " bytes); cannot peek magic (need >= 8 bytes)"
        )
    if _bytes_match_arrow1_header(bytes):
        return decode_arrow_ipc_file_with_observed_codec(
            bytes^, cache, observed_codec_id, strict_expected_codec_id,
        )
    return decode_arrow_ipc_stream_with_observed_codec(
        bytes^, cache, observed_codec_id, strict_expected_codec_id,
    )


def decode_arrow_ipc_auto_with_observed_codec_with_dispatcher[
    disp_o: Origin[mut=True],
](
    var bytes: List[UInt8],
    mut cache: IpcDictCache,
    mut observed_codec_id: Int8,
    strict_expected_codec_id: Int8,
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
) raises -> RecordBatch:
    """Dispatcher-aware variant of `decode_arrow_ipc_auto_with_observed_
    codec`.

    ARROW-IPC-DISPATCHER-PLUMB-CASCADE-COMPLETE.
    """
    observed_codec_id = Int8(-1)
    if len(bytes) < 8:
        _ = cancel_token^
        raise Error(
            "decode_arrow_ipc_auto: input too short ("
            + String(len(bytes))
            + " bytes); cannot peek magic (need >= 8 bytes)"
        )
    if _bytes_match_arrow1_header(bytes):
        return decode_arrow_ipc_file_with_observed_codec_with_dispatcher[
            disp_o,
        ](
            bytes^, cache, observed_codec_id, strict_expected_codec_id,
            dispatcher_ptr, cancel_token^,
        )
    return decode_arrow_ipc_stream_with_observed_codec_with_dispatcher[disp_o](
        bytes^, cache, observed_codec_id, strict_expected_codec_id,
        dispatcher_ptr, cancel_token^,
    )
