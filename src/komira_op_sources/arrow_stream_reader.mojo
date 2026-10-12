# =============================================================================
# arrow_stream_reader.mojo — read-side driver for `ctx.read_arrow_stream(h)`.
# ARROW-IPC-PHASE-3 step 4.
# =============================================================================
#
# Companion to `file_sink.mojo` Arrow arms (write side). Consumes a byte
# sequence in Arrow IPC Stream-format (RFC v0.3.2 §1.2):
#
#     [Schema message frame]
#     [RecordBatch message frame] *
#     [EOS marker (8 bytes: 0xFFFFFFFF 0x00000000)]
#
# The driver walks the stream message-by-message:
#   1. First message must be Schema → decode SchemaDescriptor → convert
#      to a Komira `Schema`.
#   2. Subsequent messages either RecordBatch or EOS (4-byte continuation
#      `0xFFFFFFFF` followed by 4-byte metadata_size=0).
#   3. Each RecordBatch frame is sliced into a fresh `SharedAlignedBuffer[HeapRegion]`
#      and decoded via `decode_record_batch_message` (flat-types variant
#      — primitives + var-len; PHASE-3 schemas use that subset).
#   4. Decoded `Slab[Column]` is wrapped in a `RecordBatch`. Multiple
#      RecordBatches are concatenated into one (PHASE-3 returns an
#      eagerly-materialized in-memory DataFrame).
#
# v0.4 supports the same flat-types subset the encoder ships
# (`komira_arrow/ipc_encoder_dispatch._write_type_for_arrow_type`):
# primitives (int/uint/float), BOOL, NULL, STRING/BINARY/LARGE_STRING
# /LARGE_BINARY, DATE/TIME/TIMESTAMP/DURATION/INTERVAL. Nested types
# (LIST/STRUCT/MAP/UNION) and DECIMAL/FIXED_SIZE are PHASE-3-FOLLOWUP
# items — the helper raises with a clear "PHASE-3-FOLLOWUP" message on
# encountering one in the Schema message.
#
# === Why eager materialize in PHASE-3 ===
#
# RFC §2.7 specifies that PHASE-4's `File`-format read path returns a
# lazy DataFrame backed by `FileSource[Arrow[C]]`. PHASE-3 ships the
# Stream-format which is by definition consumed in one pass — the
# caller's bytes are already in memory after `handle.read_all()`. So
# the natural shape for PHASE-3 is to decode all batches inline and
# return a `DataFrame.from_record_batch(rb)` carrying the concatenated
# result. A future slot can wire the lazy `ArrowStreamSource` if
# profiling shows the all-in-memory shape is a bottleneck.
#
# === SAFETY contract ===
#
# - No `UnsafePointer` in any public signature.
# - No wildcard origins. `Span[UInt8, _]` is the canonical byte view.
# - Frame-size accounting is u64-arithmetic-safe (no truncation).
# - Decoder per-message errors propagate verbatim — caller sees the
#   underlying decoder's diagnostic.
# =============================================================================

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
    flatbuf_reader_over,
    parse_ipc_message,
    read_message,
    read_schema,
    MESSAGE_HEADER_DICTIONARY_BATCH,
    MESSAGE_HEADER_RECORD_BATCH,
    MESSAGE_HEADER_SCHEMA,
)
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_arrow.arrow_types import ArrowType
from komira_buffer.heap_region import HeapRegion
from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Schema
from komira_collections.slab import Slab
from .ipc_dict_cache import IpcDictCache
from komira_counters.runtime_introspection import trace_alloc
from komira_op_sources.ipc_stream_frames import (
    _build_dict_values_per_col,
    _concat_batches,
    _consume_dictionary_batch_frame,
    _consume_dictionary_batch_frame_with_dispatcher,
    _extract_dict_ids,
    _extract_dict_index_widths,
    _extract_is_dict_encoded,
    _ipc_schema_desc_to_komira_schema,
    _slice_frame,
    _strict_codec_name,
)




# =============================================================================
# decode_arrow_ipc_stream — bytes → (Schema, List[Slab[Column]])
# =============================================================================
#
# Splits decode into two stages so the caller (EngineContext.
# read_arrow_stream) can build the in-memory DataFrame's RecordBatch
# from the schema + per-batch columns. PHASE-3 returns a single
# RecordBatch via the `RecordBatchBuilder` (one column per Schema field
# from the FIRST RecordBatch — multi-batch concat in PHASE-3 is
# explicit; see PHASE-3-FOLLOWUP-MULTI-BATCH-CONCAT for the unrolled
# stream-aggregate path).


def decode_arrow_ipc_stream(
    var bytes: List[UInt8],
) raises -> RecordBatch:
    """Decode a complete Arrow IPC Stream-format byte sequence to one
    `RecordBatch`.

    Layout (RFC v0.3.2 §1.2):
        [Schema frame] [RecordBatch frame]* [EOS marker]

    PHASE-3 v1 returns a single concatenated RecordBatch:
      - 0 RecordBatch frames → empty batch (Schema-only stream).
      - 1 RecordBatch frame → that batch.
      - N RecordBatch frames → first batch is returned + a clear
        "PHASE-3-FOLLOWUP" error if N > 1 is observed. (Multi-batch
        concat is a clean follow-up — wire `Column.concat` over the
        per-frame Slab[Column] in PHASE-3-FOLLOWUP-MULTI-BATCH-CONCAT.)

    The bytes are consumed (`var bytes: List[UInt8]`).

    Returns:
        A `RecordBatch` whose Schema is decoded from the stream's Schema
        message and whose Columns hold the (decoded) per-batch data.

    Dict-cache: this is a thin wrapper around
    `decode_arrow_ipc_stream_with_dict_cache` that uses a transient
    local cache (the cache is dropped on return). PHASE-4 step 3
    callers that need the cumulative dictionary state across multiple
    calls (e.g. `EngineContext.read_arrow_stream` which clears the
    EngineContext-owned cache at entry) use the `_with_dict_cache`
    variant directly.

    PHASE-6A-FOLLOWUP-TRACE-ALLOC: emits an `arrow_ipc.driver_enter`
    marker for bench attribution (0 bytes; logical entry tag).
    """
    # PHASE-6A-FOLLOWUP-TRACE-ALLOC: stream-driver entry marker.
    trace_alloc["arrow_ipc.driver_enter"](0)
    var cache = IpcDictCache()
    return decode_arrow_ipc_stream_with_dict_cache(bytes^, cache)


def decode_arrow_ipc_stream_with_dict_cache(
    var bytes: List[UInt8],
    mut cache: IpcDictCache,
) raises -> RecordBatch:
    """Dict-cache-aware variant of `decode_arrow_ipc_stream`. Serial-fallback
    wrapper. See `decode_arrow_ipc_stream_with_dict_cache_with_dispatcher`
    for the dispatcher-aware variant that drives the per-buffer decompress
    in parallel.
    """
    # Class C: serial-fallback substitutes D=NoDispatch with a CONCRETE
    # origin, NOT MutAnyOrigin.
    var _nd = NoDispatch()
    comptime nd_o = origin_of(_nd)
    return _decode_arrow_ipc_stream_with_dict_cache_impl[
        NoDispatch, has_pool=False, disp_o=nd_o,
    ](
        bytes^,
        cache,
        Optional[Pointer[NoDispatch, nd_o]](None),
        CancellationToken.never(),
    )


def decode_arrow_ipc_stream_with_dict_cache_with_dispatcher[
    disp_o: Origin[mut=True],
](
    var bytes: List[UInt8],
    mut cache: IpcDictCache,
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
) raises -> RecordBatch:
    """Dispatcher-aware variant of `decode_arrow_ipc_stream_with_dict_cache`.

    Class C: the concrete `LocalDispatcher[NoopSink]` is bound as the
    `D: ParallelDispatch` type parameter of the (now dispatcher-generic)
    core entries; the call devirtualizes per instantiation.

    ARROW-IPC-DISPATCHER-PLUMB-CASCADE-COMPLETE.
    """
    return _decode_arrow_ipc_stream_with_dict_cache_impl[
        LocalDispatcher[NoopSink], has_pool=True, disp_o=disp_o,
    ](
        bytes^,
        cache,
        Optional[Pointer[LocalDispatcher[NoopSink], disp_o]](dispatcher_ptr),
        cancel_token^,
    )


def _decode_arrow_ipc_stream_with_dict_cache_impl[
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
    stream_with_dict_cache` variants. Comptime `has_pool` prunes the
    parallel decompress branch.
    """
    var n = len(bytes)
    if n < 8:
        raise Error(
            "decode_arrow_ipc_stream: input too short ("
            + String(n)
            + " bytes); a valid stream is at least Schema frame + EOS"
        )

    # Load bytes into an MmapAlignedBuffer for parse_ipc_message.
    # ARROW-IPC-PERF: bulk memcpy via copy_from_bytes_list.
    # The prior scalar loop dominated SF1-lineitem uncompressed-read wall.
    var src = SharedAlignedBuffer[HeapRegion].heap_owned(n)
    src.copy_from_bytes_list(bytes^)

    var cursor = 0

    # -------------------------------------------------------------------
    # First message: must be Schema.
    # -------------------------------------------------------------------
    if cursor + 8 > n:
        raise Error(
            "decode_arrow_ipc_stream: insufficient bytes for Schema frame"
            " header at cursor=" + String(cursor)
        )

    # Slice the first frame using parse_ipc_message on a tail view; we
    # need to first learn the metadata_size and body_length to know how
    # many bytes the frame spans. parse_ipc_message on the full src
    # treats `total = src.length` as the WHOLE-buffer body, which over-
    # counts; instead slice a tail-window into a fresh buffer for parse.
    # ARROW-IPC-PERF: bulk memcpy via copy_from_view_at.

    var tail = SharedAlignedBuffer[HeapRegion].heap_owned(n - cursor)
    tail.copy_from_view_at(0, src.view_range_ro(cursor, n - cursor))
    tail.set_length(n - cursor)

    var schema_frame_info = parse_ipc_message(tail)
    # Build a fresh MmapAlignedBuffer holding ONLY this frame for further
    # decoding. Frame length = continuation(4) + size_u32(4) +
    # metadata_size + body_length (= 0 for Schema messages).
    # Note: parse_ipc_message subtracts the continuation marker offset
    # internally; the conservative formula is
    #     (metadata_pos + metadata_size + body_length) bytes
    # which already includes both the continuation marker and the size
    # u32 (because metadata_pos = 4+4 = 8 when continuation is present).

    # Decode message FB to learn body_length authoritatively (the
    # parse_ipc_message's body_size field is total-minus-body_pos, which
    # is whole-tail rather than this message's body size).
    # ARROW-IPC-PERF: bulk memcpy via copy_from_view_at.
    var schema_fb = SharedAlignedBuffer[HeapRegion].heap_owned(schema_frame_info.metadata_size)
    schema_fb.copy_from_view_at(
        0,
        tail.view_range_ro(
            schema_frame_info.metadata_pos, schema_frame_info.metadata_size
        ),
    )
    schema_fb.set_length(schema_frame_info.metadata_size)
    var schema_reader = flatbuf_reader_over(schema_fb)
    var schema_msg = read_message(
        schema_reader, schema_reader.read_root_offset()
    )
    if schema_msg.header_tag != MESSAGE_HEADER_SCHEMA:
        raise Error(
            "decode_arrow_ipc_stream: first message must be Schema (tag "
            + String(Int(MESSAGE_HEADER_SCHEMA))
            + "), got tag "
            + String(Int(schema_msg.header_tag))
        )
    if schema_msg.body_length != Int64(0):
        raise Error(
            "decode_arrow_ipc_stream: Schema message must have body_length"
            "=0; got " + String(Int(schema_msg.body_length))
        )

    # Decode the Schema body into SchemaDescriptor → Komira Schema.
    var schema_desc = read_schema(schema_reader, schema_msg.header_table_pos)
    var schema = _ipc_schema_desc_to_komira_schema(schema_desc, schema_fb)
    var arrow_types: List[ArrowType] = List[ArrowType]()
    for i in range(schema.num_columns()):
        arrow_types.append(schema.field_arrow_type(i))
    # PHASE-4-FOLLOWUP-DICT-DECODE-COLUMN commit 2/3:
    # extract per-column is_dict_encoded + dict_id metadata so the
    # RecordBatch decode dispatches to `decode_record_batch_message_
    # with_dicts` when ANY column is dict-encoded.
    var is_dict_encoded = _extract_is_dict_encoded(schema_desc)
    var dict_ids = _extract_dict_ids(schema_desc)
    # PHASE-4-FOLLOWUP-DICT-WIDER-INDEX: per-column
    # index bit width (32 default; 64 for >2G dict entries).
    var dict_widths = _extract_dict_index_widths(schema_desc)
    var any_dict_encoded = False
    for i in range(len(is_dict_encoded)):
        if is_dict_encoded[i]:
            any_dict_encoded = True
            break

    # Advance cursor past the Schema frame.
    # Schema-frame byte size = metadata_pos + metadata_size + 0 (no body).
    var schema_frame_size = (
        schema_frame_info.metadata_pos + schema_frame_info.metadata_size
    )
    cursor += schema_frame_size

    # -------------------------------------------------------------------
    # Subsequent messages: RecordBatch* + EOS.
    # -------------------------------------------------------------------
    var batches = Slab[RecordBatch]()
    var saw_eos = False

    while cursor + 8 <= n:
        # Read continuation + size to detect EOS.
        var cont = src.read_u32_le_at(cursor)
        var size_u32 = src.read_u32_le_at(cursor + 4)
        if cont != UInt32(0xFFFFFFFF):
            raise Error(
                "decode_arrow_ipc_stream: expected continuation marker"
                " 0xFFFFFFFF at byte " + String(cursor) + ", got 0x"
                + String(Int(cont))
            )
        if size_u32 == UInt32(0):
            # EOS marker.
            saw_eos = True
            cursor += 8
            break

        # Inspect message header_tag — dispatch RecordBatch vs DictionaryBatch.
        var msg_metadata_size = Int(size_u32)
        var msg_metadata_pos_in_src = cursor + 8
        # ASSERT=none HARDENING: VALIDATE, THEN ALLOCATE. The
        # `heap_owned` below used to run TWO LINES ABOVE this check, so an
        # 8-byte tail claiming metadata_size = 0xFFFFFFF0 reserved ~4 GiB and
        # only then raised. `read_string_at` (ipc_flatbuf.mojo:801) already had
        # the right ordering — `_check_bounds` before `bytes.reserve` — this is
        # the same shape.
        if msg_metadata_pos_in_src + msg_metadata_size > n:
            raise Error(
                "decode_arrow_ipc_stream: message metadata "
                "extends past end of buffer at byte " + String(cursor)
                + " (metadata_size=" + String(msg_metadata_size)
                + ", remaining=" + String(n - msg_metadata_pos_in_src) + ")"
            )
        var msg_fb = SharedAlignedBuffer[HeapRegion].heap_owned(msg_metadata_size)
        # ARROW-IPC-PERF: bulk memcpy via copy_from_view_at.
        msg_fb.copy_from_view_at(
            0,
            src.view_range_ro(msg_metadata_pos_in_src, msg_metadata_size),
        )
        msg_fb.set_length(msg_metadata_size)
        var msg_reader = flatbuf_reader_over(msg_fb)
        var msg_hdr = read_message(msg_reader, msg_reader.read_root_offset())

        var msg_body_length = Int(msg_hdr.body_length)
        # ASSERT=none HARDENING: Message.bodyLength is an
        # unbounded flatbuffer i64 and the ONLY guard below is the UPPER
        # bound `cursor + msg_frame_size > n`, which a NEGATIVE value passes
        # trivially. A negative frame size reaches
        # `SharedAlignedBuffer.heap_owned(negative)` + `view_range_ro(start,
        # negative)`, and `cursor += msg_frame_size` then moves the cursor
        # BACKWARD — a re-parse / non-termination primitive. `parse_ipc_message`
        # (ipc_flatbuf.mojo:3661) already tests its sibling field this way.
        if msg_body_length < 0:
            raise Error(
                "decode_arrow_ipc_stream: message bodyLength is negative ("
                + String(msg_body_length) + ") at byte " + String(cursor)
            )
        var msg_frame_size = 4 + 4 + msg_metadata_size + msg_body_length
        if cursor + msg_frame_size > n:
            raise Error(
                "decode_arrow_ipc_stream: message frame extends past"
                " end of buffer at byte " + String(cursor)
                + " (frame_size=" + String(msg_frame_size)
                + ", remaining=" + String(n - cursor) + ")"
            )

        if msg_hdr.header_tag == MESSAGE_HEADER_DICTIONARY_BATCH:
            # DictionaryBatch frame — decode + update cache per isDelta.
            var dict_frame = _slice_frame(src, cursor, msg_frame_size)

            comptime if has_pool:
                _consume_dictionary_batch_frame_with_dispatcher[D, disp_o](
                    dict_frame^, msg_hdr.header_table_pos,
                    msg_metadata_size, msg_body_length, cache,
                    dispatcher_ptr.value(), cancel_token.clone(),
                )
            else:
                _consume_dictionary_batch_frame(
                    dict_frame^, msg_hdr.header_table_pos,
                    msg_metadata_size, msg_body_length, cache,
                )
            cursor += msg_frame_size
            continue

        if msg_hdr.header_tag != MESSAGE_HEADER_RECORD_BATCH:
            _ = cancel_token^
            raise Error(
                "decode_arrow_ipc_stream: expected RecordBatch (tag "
                + String(Int(MESSAGE_HEADER_RECORD_BATCH))
                + ") or DictionaryBatch (tag "
                + String(Int(MESSAGE_HEADER_DICTIONARY_BATCH))
                + "), got tag " + String(Int(msg_hdr.header_tag))
                + " at byte " + String(cursor)
            )

        # Slice the entire frame into its own buffer for
        # decode_record_batch_message (it expects continuation at 0).
        var rb_frame = _slice_frame(src, cursor, msg_frame_size)
        # PHASE-4-FOLLOWUP-DICT-DECODE-COLUMN commit 2/3:
        # dispatch to dict-aware decoder if ANY column on this schema
        # is dict-encoded. Non-dict columns flow through the
        # `_decode_column` path inside the dict-aware driver, so this
        # is a strict superset of the non-dict path (zero-cost when
        # `any_dict_encoded == False` — the standard path is taken).
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

        # Build a RecordBatch from the decoded columns + schema copy.
        var builder = RecordBatchBuilder.with_capacity(len(cols))
        var num_cols = len(cols)
        for i in range(num_cols):
            builder.add_column(cols.take_slot_unchecked(i))
        cols.set_len_unchecked(0)
        _ = cols^
        var batch = builder.build(schema.copy())
        batches.append(batch^)

        cursor += msg_frame_size

    _ = cancel_token^

    if not saw_eos:
        # Either bytes ended without an EOS or the loop broke at a
        # non-EOS continuation. Either way: missing-EOS is a recoverable
        # protocol error per RFC §1.2 ("EOS marker SHOULD terminate the
        # stream"); raise a clear message.
        raise Error(
            "decode_arrow_ipc_stream: stream ended without EOS marker"
            " (remaining bytes=" + String(n - cursor) + ")"
        )

    # PHASE-6A-FOLLOWUP-MULTI-BATCH-CONCAT: pair-wise fold
    # over N batches via `_concat_columns`. Schema-only stream → zero-row
    # batch with the schema.
    var n_batches = len(batches)
    if n_batches == 0:
        var empty_builder = RecordBatchBuilder.with_capacity(
            schema.num_columns()
        )
        return empty_builder.build(schema^)

    return _concat_batches(batches^)


# =============================================================================
# decode_arrow_ipc_stream_with_dict_cache_and_observed_codec
# ARROW-IPC-PHASE-4 step 4
# =============================================================================
#
# Sidechannel sibling of `decode_arrow_ipc_stream_with_dict_cache`. Also
# observes the BodyCompression.codec id of the FIRST RecordBatch frame
# encountered + reports it via the mut out-param. Used by
# `ctx.read_arrow_strict[C]` (RFC v0.3.2 §0.8 CHANGE-C compression-
# strict layer).
#
# Implementation strategy (avoid body duplication): the existing
# `decode_arrow_ipc_stream_with_dict_cache` does not surface the rb-level
# codec; this wrapper peeks the codec via
# `peek_record_batch_codec_from_frame` BEFORE the decode + delegates to
# the existing function. The peek is O(metadata_size) per frame — same
# parse pass the decoder runs internally — and the bytes are then
# consumed by the actual decode. Because the existing function consumes
# `var bytes`, we have to inline the byte-walking loop with the peek
# inserted at the RecordBatch arm.
#


# PHASE-4-FOLLOWUP-STRICT-MIXED-CODEC extension:
#
# `strict_expected_codec_id` is the codec id the caller wants to ENFORCE
# across every frame (`C.ARROW_IPC_CODEC_ID` from
# `ctx.read_arrow_strict[C]`). Sentinel `-2` disables strict enforcement
# (v1 observe-only mode preserved for non-strict callers).
#
# When `strict_expected_codec_id != -2`, EVERY RecordBatch frame AND
# EVERY DictionaryBatch frame has its `BodyCompression.codec` (or `-1`
# Uncompressed-sentinel when no BodyCompression flatbuf is emitted)
# compared against the expected value; on mismatch, the function raises
# `StrictMixedCodec: ...` immediately, identifying the frame index +
# observed vs expected codec.
#
# `observed_codec_id` continues to capture the FIRST observed codec for
# back-compat / diagnostic; even when strict-check fires it is
# initialized to the first frame's codec before the raise.


def decode_arrow_ipc_stream_with_observed_codec(
    var bytes: List[UInt8],
    mut cache: IpcDictCache,
    mut observed_codec_id: Int8,
    strict_expected_codec_id: Int8,
) raises -> RecordBatch:
    """Serial-fallback wrapper. See
    `decode_arrow_ipc_stream_with_observed_codec_with_dispatcher` for the
    dispatcher-aware variant.

    Walk an Arrow IPC Stream-format byte sequence, decode it into a
    RecordBatch, AND surface the BodyCompression.codec id of the first
    RB frame encountered (or `-1` Uncompressed sentinel if no RB frames
    are present or no BodyCompression flatbuf is emitted).
    """
    # Class C: serial-fallback substitutes D=NoDispatch with a CONCRETE
    # origin, NOT MutAnyOrigin.
    var _nd = NoDispatch()
    comptime nd_o = origin_of(_nd)
    return _decode_arrow_ipc_stream_with_observed_codec_impl[
        NoDispatch, has_pool=False, disp_o=nd_o,
    ](
        bytes^,
        cache,
        observed_codec_id,
        strict_expected_codec_id,
        Optional[Pointer[NoDispatch, nd_o]](None),
        CancellationToken.never(),
    )


def decode_arrow_ipc_stream_with_observed_codec_with_dispatcher[
    disp_o: Origin[mut=True],
](
    var bytes: List[UInt8],
    mut cache: IpcDictCache,
    mut observed_codec_id: Int8,
    strict_expected_codec_id: Int8,
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
) raises -> RecordBatch:
    """Dispatcher-aware variant of `decode_arrow_ipc_stream_with_observed_
    codec`. Class C: binds the concrete `LocalDispatcher[NoopSink]` as
    the `D: ParallelDispatch` parameter of the dispatcher-generic impl.

    ARROW-IPC-DISPATCHER-PLUMB-CASCADE-COMPLETE.
    """
    return _decode_arrow_ipc_stream_with_observed_codec_impl[
        LocalDispatcher[NoopSink], has_pool=True, disp_o=disp_o,
    ](
        bytes^,
        cache,
        observed_codec_id,
        strict_expected_codec_id,
        Optional[Pointer[LocalDispatcher[NoopSink], disp_o]](dispatcher_ptr),
        cancel_token^,
    )


def _decode_arrow_ipc_stream_with_observed_codec_impl[
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
    stream_with_observed_codec` variants."""
    # Initialize to Uncompressed sentinel; first RB frame's codec
    # observation overwrites if a non-default codec is present.
    observed_codec_id = Int8(-1)

    var n = len(bytes)
    if n < 8:
        raise Error(
            "decode_arrow_ipc_stream: input too short ("
            + String(n)
            + " bytes); a valid stream is at least Schema frame + EOS"
        )

    # ARROW-IPC-PERF: bulk memcpy via copy_from_bytes_list +
    # copy_from_view_at. Mirrors the non-observed-codec variant fix above.
    var src = SharedAlignedBuffer[HeapRegion].heap_owned(n)
    src.copy_from_bytes_list(bytes^)

    var cursor = 0
    if cursor + 8 > n:
        raise Error(
            "decode_arrow_ipc_stream: insufficient bytes for Schema frame"
            " header at cursor=" + String(cursor)
        )

    var tail = SharedAlignedBuffer[HeapRegion].heap_owned(n - cursor)
    tail.copy_from_view_at(0, src.view_range_ro(cursor, n - cursor))
    tail.set_length(n - cursor)
    var schema_frame_info = parse_ipc_message(tail)
    var schema_fb = SharedAlignedBuffer[HeapRegion].heap_owned(schema_frame_info.metadata_size)
    schema_fb.copy_from_view_at(
        0,
        tail.view_range_ro(
            schema_frame_info.metadata_pos, schema_frame_info.metadata_size
        ),
    )
    schema_fb.set_length(schema_frame_info.metadata_size)
    var schema_reader = flatbuf_reader_over(schema_fb)
    var schema_msg = read_message(
        schema_reader, schema_reader.read_root_offset()
    )
    if schema_msg.header_tag != MESSAGE_HEADER_SCHEMA:
        raise Error(
            "decode_arrow_ipc_stream: first message must be Schema (tag "
            + String(Int(MESSAGE_HEADER_SCHEMA))
            + "), got tag "
            + String(Int(schema_msg.header_tag))
        )
    if schema_msg.body_length != Int64(0):
        raise Error(
            "decode_arrow_ipc_stream: Schema message must have body_length"
            "=0; got " + String(Int(schema_msg.body_length))
        )

    var schema_desc = read_schema(schema_reader, schema_msg.header_table_pos)
    var schema = _ipc_schema_desc_to_komira_schema(schema_desc, schema_fb)
    var arrow_types: List[ArrowType] = List[ArrowType]()
    for i in range(schema.num_columns()):
        arrow_types.append(schema.field_arrow_type(i))
    # PHASE-4-FOLLOWUP-DICT-DECODE-COLUMN commit 2/3:
    # symmetric to decode_arrow_ipc_stream_with_dict_cache.
    var is_dict_encoded_obs = _extract_is_dict_encoded(schema_desc)
    var dict_ids_obs = _extract_dict_ids(schema_desc)
    # PHASE-4-FOLLOWUP-DICT-WIDER-INDEX.
    var dict_widths_obs = _extract_dict_index_widths(schema_desc)
    var any_dict_encoded_obs = False
    for i in range(len(is_dict_encoded_obs)):
        if is_dict_encoded_obs[i]:
            any_dict_encoded_obs = True
            break

    var schema_frame_size = (
        schema_frame_info.metadata_pos + schema_frame_info.metadata_size
    )
    cursor += schema_frame_size

    var batches = Slab[RecordBatch]()
    var saw_eos = False
    var first_codec_seen = False
    # PHASE-4-FOLLOWUP-STRICT-MIXED-CODEC: per-frame index
    # counter for the diagnostic. RB and Dict frames each have their
    # own running index because the wire-format treats them distinctly.
    var rb_frame_idx: Int = 0
    var dict_frame_idx: Int = 0

    while cursor + 8 <= n:
        var cont = src.read_u32_le_at(cursor)
        var size_u32 = src.read_u32_le_at(cursor + 4)
        if cont != UInt32(0xFFFFFFFF):
            raise Error(
                "decode_arrow_ipc_stream: expected continuation marker"
                " 0xFFFFFFFF at byte " + String(cursor) + ", got 0x"
                + String(Int(cont))
            )
        if size_u32 == UInt32(0):
            saw_eos = True
            cursor += 8
            break

        var msg_metadata_size = Int(size_u32)
        var msg_metadata_pos_in_src = cursor + 8
        # ASSERT=none HARDENING: VALIDATE, THEN ALLOCATE — see the
        # sibling loop in `_decode_arrow_ipc_stream_with_dict_cache_impl`.
        if msg_metadata_pos_in_src + msg_metadata_size > n:
            raise Error(
                "decode_arrow_ipc_stream: message metadata "
                "extends past end of buffer at byte " + String(cursor)
                + " (metadata_size=" + String(msg_metadata_size)
                + ", remaining=" + String(n - msg_metadata_pos_in_src) + ")"
            )
        var msg_fb = SharedAlignedBuffer[HeapRegion].heap_owned(msg_metadata_size)
        # ARROW-IPC-PERF: bulk memcpy via copy_from_view_at.
        msg_fb.copy_from_view_at(
            0,
            src.view_range_ro(msg_metadata_pos_in_src, msg_metadata_size),
        )
        msg_fb.set_length(msg_metadata_size)
        var msg_reader = flatbuf_reader_over(msg_fb)
        var msg_hdr = read_message(msg_reader, msg_reader.read_root_offset())

        var msg_body_length = Int(msg_hdr.body_length)
        # ASSERT=none HARDENING: Message.bodyLength is an
        # unbounded flatbuffer i64 and the ONLY guard below is the UPPER
        # bound `cursor + msg_frame_size > n`, which a NEGATIVE value passes
        # trivially. A negative frame size reaches
        # `SharedAlignedBuffer.heap_owned(negative)` + `view_range_ro(start,
        # negative)`, and `cursor += msg_frame_size` then moves the cursor
        # BACKWARD — a re-parse / non-termination primitive. `parse_ipc_message`
        # (ipc_flatbuf.mojo:3661) already tests its sibling field this way.
        if msg_body_length < 0:
            raise Error(
                "decode_arrow_ipc_stream: message bodyLength is negative ("
                + String(msg_body_length) + ") at byte " + String(cursor)
            )
        var msg_frame_size = 4 + 4 + msg_metadata_size + msg_body_length
        if cursor + msg_frame_size > n:
            raise Error(
                "decode_arrow_ipc_stream: message frame extends past"
                " end of buffer at byte " + String(cursor)
                + " (frame_size=" + String(msg_frame_size)
                + ", remaining=" + String(n - cursor) + ")"
            )

        if msg_hdr.header_tag == MESSAGE_HEADER_DICTIONARY_BATCH:
            var dict_frame = _slice_frame(src, cursor, msg_frame_size)
            # PHASE-4-FOLLOWUP-STRICT-MIXED-CODEC: enforce per-dict-frame
            # codec match BEFORE consume on SUBSEQUENT dict frames.
            # First dict-frame mismatch is left for the ctx-level layer
            # to surface (same back-compat shape as the RB frame path).
            if (
                strict_expected_codec_id != Int8(-2)
                and dict_frame_idx != 0
            ):
                var dict_observed = peek_dictionary_batch_codec_from_frame(
                    dict_frame
                )
                if dict_observed != strict_expected_codec_id:
                    raise Error(
                        "StrictMixedCodec: expected "
                        + _strict_codec_name(strict_expected_codec_id)
                        + " across all batches but DictionaryBatch["
                        + String(dict_frame_idx) + "] has "
                        + _strict_codec_name(dict_observed)
                        + " (observed_codec_id="
                        + String(Int(dict_observed))
                        + ", expected_codec_id="
                        + String(Int(strict_expected_codec_id)) + ")."
                    )

            comptime if has_pool:
                _consume_dictionary_batch_frame_with_dispatcher[D, disp_o](
                    dict_frame^, msg_hdr.header_table_pos,
                    msg_metadata_size, msg_body_length, cache,
                    dispatcher_ptr.value(), cancel_token.clone(),
                )
            else:
                _consume_dictionary_batch_frame(
                    dict_frame^, msg_hdr.header_table_pos,
                    msg_metadata_size, msg_body_length, cache,
                )
            dict_frame_idx += 1
            cursor += msg_frame_size
            continue

        if msg_hdr.header_tag != MESSAGE_HEADER_RECORD_BATCH:
            _ = cancel_token^
            raise Error(
                "decode_arrow_ipc_stream: expected RecordBatch (tag "
                + String(Int(MESSAGE_HEADER_RECORD_BATCH))
                + ") or DictionaryBatch (tag "
                + String(Int(MESSAGE_HEADER_DICTIONARY_BATCH))
                + "), got tag " + String(Int(msg_hdr.header_tag))
                + " at byte " + String(cursor)
            )

        var rb_frame = _slice_frame(src, cursor, msg_frame_size)
        # PHASE-4-FOLLOWUP-STRICT-MIXED-CODEC: per-frame codec observation
        # + strict check. The per-frame peek runs on every RB; the FIRST
        # value is captured in `observed_codec_id` for the ctx-level
        # diagnostic (existing PHASE-4 step 4 contract). The
        # `StrictMixedCodec` decoder-level raise fires on the SECOND
        # and subsequent frames only; first-frame mismatch is left for
        # the ctx-level layer to surface with its own "codec mismatch"
        # message + C.NAME context.
        var rb_observed_codec = peek_record_batch_codec_from_frame(rb_frame)
        var is_first_frame = not first_codec_seen
        if is_first_frame:
            observed_codec_id = rb_observed_codec
            first_codec_seen = True
        if (
            strict_expected_codec_id != Int8(-2)
            and not is_first_frame
            and rb_observed_codec != strict_expected_codec_id
        ):
            raise Error(
                "StrictMixedCodec: expected "
                + _strict_codec_name(strict_expected_codec_id)
                + " across all batches but RecordBatch["
                + String(rb_frame_idx) + "] has "
                + _strict_codec_name(rb_observed_codec)
                + " (observed_codec_id="
                + String(Int(rb_observed_codec))
                + ", expected_codec_id="
                + String(Int(strict_expected_codec_id)) + ")."
            )
        rb_frame_idx += 1
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
        var batch = builder.build(schema.copy())
        batches.append(batch^)

        cursor += msg_frame_size

    _ = cancel_token^

    if not saw_eos:
        raise Error(
            "decode_arrow_ipc_stream: stream ended without EOS marker"
            " (remaining bytes=" + String(n - cursor) + ")"
        )

    # PHASE-6A-FOLLOWUP-MULTI-BATCH-CONCAT.
    var n_batches = len(batches)
    if n_batches == 0:
        var empty_builder = RecordBatchBuilder.with_capacity(
            schema.num_columns()
        )
        return empty_builder.build(schema^)

    return _concat_batches(batches^)
