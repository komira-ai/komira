# =============================================================================
# ipc_stream_frames.mojo -- the frame-level pieces both Arrow IPC readers share.
# =============================================================================
#
# Split out of `arrow_stream_reader.mojo` so each file stays under 1,000
# lines. Converts the IPC Schema message into a Komira `Schema` (with the
# per-column dictionary ids, flags and index widths), consumes a
# DictionaryBatch frame into an `IpcDictCache`, slices one frame out of the
# byte sequence, concatenates decoded batches, and names a codec id for the
# strict-codec diagnostic. The per-batch decoding is
# `komira_arrow_ipc.ipc_decoder_dispatch`; nothing here re-parses a body.
#
# Every name here is private to the package: `arrow_stream_reader` and
# `arrow_file_reader*` import them; callers outside the package use the
# readers' `decode_arrow_ipc_*` functions.

from komira_compression.compression_codecs import Lz4Frame, Zstd
from komira_arrow_ipc.ipc_body_compression import (
    decompress_dictionary_batch_frame,
    decompress_dictionary_batch_frame_with_dispatcher,
    peek_dictionary_batch_codec_from_frame,
)
from komira_arrow_ipc.ipc_decoder_dispatch import _validate_rb_buffers_in_bounds
from komira_async_api.token import CancellationToken
from komira_async_api.parallel_dispatch import ParallelDispatch, NoDispatch
from komira_arrow_ipc.ipc_flatbuf import (
    SchemaDescriptor,
    FieldDescriptor,
    flatbuf_reader_over,
    parse_ipc_message,
    read_dictionary_batch,
    read_message,
    read_record_batch,
    read_type_int,
    read_type_floating_point,
    TYPE_NULL,
    TYPE_INT,
    TYPE_FLOATING_POINT,
    TYPE_BINARY,
    TYPE_UTF8,
    TYPE_BOOL,
    TYPE_DATE,
    TYPE_TIME,
    TYPE_TIMESTAMP,
    TYPE_INTERVAL,
    TYPE_LARGE_BINARY,
    TYPE_LARGE_UTF8,
    TYPE_DURATION,
)
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_buffer.heap_region import HeapRegion
from komira_arrow.column import Column
from komira_arrow.concat import concat_record_batches_nway
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_collections.slab import Slab
from .ipc_dict_cache import IpcDictCache



# =============================================================================
# _ipc_field_to_arrow_type — FB type-tag + Int/Float details → ArrowType.
# =============================================================================
#
# The FlatBuffer Field carries a u8 type-tag (TYPE_INT, TYPE_UTF8, ...)
# plus a side table at `type_table_pos` for parametric types (Int's
# bit_width / is_signed; FloatingPoint's precision; Timestamp's unit;
# etc.). PHASE-3 covers primitives + var-len + temporal — the flat
# subset the encoder ships. Nested + decimal + fixed-size raise a
# PHASE-3-FOLLOWUP error.


def _ipc_field_to_arrow_type(
    field: FieldDescriptor,
    metadata_buf: SharedAlignedBuffer[HeapRegion],
) raises -> ArrowType:
    """Convert an IPC `FieldDescriptor` (FB Field decode) to a Komira
    `ArrowType`.

    `metadata_buf` is the FB metadata slice that the field's
    `type_table_pos` indexes into (the same buffer `read_schema` walked).
    Caller passes it so we can call the type-detail readers
    (`read_type_int`, `read_type_floating_point`) without re-parsing.
    """
    var reader = flatbuf_reader_over(metadata_buf)
    var tag = field.type_tag

    if tag == TYPE_NULL:
        return ArrowType.NULL
    if tag == TYPE_BOOL:
        return ArrowType.BOOL
    if tag == TYPE_BINARY:
        return ArrowType.BINARY
    if tag == TYPE_UTF8:
        return ArrowType.STRING
    if tag == TYPE_LARGE_BINARY:
        return ArrowType.LARGE_BINARY
    if tag == TYPE_LARGE_UTF8:
        return ArrowType.LARGE_STRING

    if tag == TYPE_INT:
        var int_desc = read_type_int(reader, field.type_table_pos)
        if int_desc.is_signed:
            if int_desc.bit_width == 8:
                return ArrowType.INT8
            if int_desc.bit_width == 16:
                return ArrowType.INT16
            if int_desc.bit_width == 32:
                return ArrowType.INT32
            if int_desc.bit_width == 64:
                return ArrowType.INT64
        else:
            if int_desc.bit_width == 8:
                return ArrowType.UINT8
            if int_desc.bit_width == 16:
                return ArrowType.UINT16
            if int_desc.bit_width == 32:
                return ArrowType.UINT32
            if int_desc.bit_width == 64:
                return ArrowType.UINT64
        raise Error(
            "_ipc_field_to_arrow_type: TYPE_INT bit_width "
            + String(int_desc.bit_width)
            + " not supported (PHASE-3 ships 8/16/32/64)"
        )

    if tag == TYPE_FLOATING_POINT:
        var fp_desc = read_type_floating_point(reader, field.type_table_pos)
        # PRECISION_HALF=0, PRECISION_SINGLE=1, PRECISION_DOUBLE=2 per
        # Arrow Type.fbs (Phase 1.c spec).
        if Int(fp_desc.precision) == 0:
            return ArrowType.FLOAT16
        if Int(fp_desc.precision) == 1:
            return ArrowType.FLOAT32
        if Int(fp_desc.precision) == 2:
            return ArrowType.FLOAT64
        raise Error(
            "_ipc_field_to_arrow_type: TYPE_FLOATING_POINT precision "
            + String(Int(fp_desc.precision))
            + " not recognized (expected 0=HALF, 1=SINGLE, 2=DOUBLE)"
        )

    # Temporal: PHASE-3 currently round-trips through the encoder's
    # default unit emit. The reader returns the matching default-unit
    # ArrowType. A future PHASE-3-FOLLOWUP (unit-aware temporal round-
    # trip) reads the inner Date/Time/Timestamp/Duration/Interval table
    # for unit precision.
    if tag == TYPE_DATE:
        # Default emit: DATE32 (day unit).
        return ArrowType.DATE32
    if tag == TYPE_TIME:
        return ArrowType.TIME32_MS
    if tag == TYPE_TIMESTAMP:
        return ArrowType.TIMESTAMP_US
    if tag == TYPE_DURATION:
        return ArrowType.DURATION_US
    if tag == TYPE_INTERVAL:
        return ArrowType.INTERVAL_MONTH_DAY_NANO

    raise Error(
        "_ipc_field_to_arrow_type: type_tag "
        + String(Int(tag))
        + " not yet wired in PHASE-3 reader (nested LIST/STRUCT/MAP/UNION,"
        + " DECIMAL, FIXED_SIZE are PHASE-3-FOLLOWUP)."
    )


def _ipc_schema_desc_to_komira_schema(
    desc: SchemaDescriptor,
    metadata_buf: SharedAlignedBuffer[HeapRegion],
) raises -> Schema:
    """Convert a decoded IPC `SchemaDescriptor` → Komira `Schema`.

    Reads each FieldDescriptor's type_tag + type_table_pos via
    `_ipc_field_to_arrow_type`, then assembles a `Schema` via
    `SchemaBuilder` (handles the `_dtypes` storage-side projection that
    bare `Schema.__init__(names, arrow_types, dtypes, nullables)` would
    require us to compute by hand).

    PHASE-4-FOLLOWUP-DICT-DECODE-COLUMN commit 2/3: if a
    FieldDescriptor carries `dictionary_encoding`, the field type is
    reported as STRING (per v1 lossy-expand contract — the wire Type
    union is also STRING; Field.dictionary slot carries the dict-
    encoding metadata). Use `_extract_dict_metadata` alongside this
    def to get the per-column dict_id list for dict-aware decoding.
    """
    var sb = SchemaBuilder()
    var n = len(desc.fields)
    for i in range(n):
        ref f = desc.fields[i]
        var at = _ipc_field_to_arrow_type(f, metadata_buf)
        sb.add_field(Field(String(f.name), at, f.nullable))
    return sb.build()


def _extract_is_dict_encoded(
    desc: SchemaDescriptor,
) raises -> List[Bool]:
    """Build a per-column `is_dict_encoded` list from a decoded
    SchemaDescriptor.

    PHASE-4-FOLLOWUP-DICT-DECODE-COLUMN commit 2/3. True
    at index `i` means the FieldDescriptor's `dictionary_encoding`
    slot is populated on the wire (= column `i` is dict-encoded and
    the decoder dispatches via `decode_record_batch_message_with_dicts`).
    """
    var out = List[Bool]()
    var n = len(desc.fields)
    for i in range(n):
        ref f = desc.fields[i]
        out.append(Bool(f.dictionary_encoding))
    return out^


def _extract_dict_ids(
    desc: SchemaDescriptor,
) raises -> List[Int64]:
    """Build a per-column `dict_id` list from a decoded SchemaDescriptor.

    PHASE-4-FOLLOWUP-DICT-DECODE-COLUMN commit 2/3. For
    columns where `is_dict_encoded[i]` is True, this entry carries the
    on-wire `dict_id` (from Field.dictionary.id, the cache lookup key).
    For non-dict columns the entry is 0 (sentinel; unused by the
    decoder because the dict-arm is gated on is_dict_encoded[i]).
    """
    var out = List[Int64]()
    var n = len(desc.fields)
    for i in range(n):
        ref f = desc.fields[i]
        if f.dictionary_encoding:
            ref de = f.dictionary_encoding.value()
            out.append(de.id)
        else:
            out.append(Int64(0))
    return out^


def _extract_dict_index_widths(
    desc: SchemaDescriptor,
) raises -> List[Int]:
    """Build a per-column index bit-width list from a decoded
    SchemaDescriptor.

    PHASE-4-FOLLOWUP-DICT-WIDER-INDEX. For columns where
    `is_dict_encoded[i]` is True, this entry carries the on-wire
    `index_type_bit_width` (32 for Int32 v1 default; 64 for Int64
    >2G dict entries). For non-dict columns the entry is 32 (sentinel;
    unused by the decoder because the dict-arm is gated on
    is_dict_encoded[i]).
    """
    var out = List[Int]()
    var n = len(desc.fields)
    for i in range(n):
        ref f = desc.fields[i]
        if f.dictionary_encoding:
            ref de = f.dictionary_encoding.value()
            out.append(de.index_type_bit_width)
        else:
            out.append(32)
    return out^


def _build_dict_values_per_col(
    is_dict_encoded: List[Bool],
    dict_ids: List[Int64],
    cache: IpcDictCache,
) raises -> Slab[Column[HeapRegion]]:
    """Build the parallel `dict_values: Slab[Column[HeapRegion]]` argument for
    `decode_record_batch_message_with_dicts`.

    For each column index `i`:
      - If `is_dict_encoded[i]` is True, look up the cumulative dict
        values via `cache.get(dict_ids[i])` → deep-copy STRING column.
      - Otherwise, append a default `Column()` placeholder (the dict
        driver ignores this slot since `is_dict_encoded[i]` is False).

    PHASE-4-FOLLOWUP-DICT-DECODE-COLUMN commit 2/3.
    """
    var out = Slab[Column[HeapRegion]]()
    var n = len(is_dict_encoded)
    for i in range(n):
        if is_dict_encoded[i]:
            var vals = cache.get(dict_ids[i])
            out.append(vals^)
        else:
            out.append(Column[HeapRegion]())
    return out^


# =============================================================================
# Stream walker — message-by-message frame extraction.
# =============================================================================
#
# The walker maintains a byte cursor and an offset table for each
# message. Per-message format:
#
#   [u32 continuation = 0xFFFFFFFF]
#   [u32 metadata_size]
#   [N bytes FB metadata]   (N = metadata_size, may include FB padding)
#   [M bytes body]          (M = msg.body_length, 0 for Schema messages)
#
# EOS sentinel: continuation + metadata_size==0 (8 bytes total).
#
# The walker computes the per-frame byte count as
#     4 (continuation) + 4 (metadata_size_u32) + metadata_size + body_length
# and advances the cursor by that many bytes after each frame is sliced
# into its own MmapAlignedBuffer (the IPC decoder expects frame-at-byte-0
# input).


# =============================================================================
# Multi-batch concat helper — PHASE-6A-FOLLOWUP-MULTI-BATCH-CONCAT
# =============================================================================
#
# Both decode_arrow_ipc_stream and decode_arrow_ipc_file accumulate one
# RecordBatch per Block/frame in a Slab[RecordBatch]. v1 of these readers
# raised on `len(batches) > 1` because the engine had no Arrow scan
# operator to consume a multi-batch DataFrame. PHASE-6A-FOLLOWUP wires
# Column.concat (already implemented as `_concat_columns` in
# komira_arrow/concat.mojo) into a pair-wise fold over the batches,
# returning ONE merged RecordBatch.
#
# Type coverage: `_concat_columns` already handles primitives + STRING /
# BINARY + BOOL + DICTIONARY — that's the full type set produced by
# pyarrow's `ipc.RecordBatchFileWriter.write_table` on lineitem-SF1.
#
# ⚠ COMMENT CORRECTED (string_t S0). The line here used to read
# "Other types raise inside `_concat_columns` itself with a clear message."
# That was FALSE, and it is the kind of false assurance that stops the next
# reader from checking. `_concat_columns` has exactly three arms (STRING /
# BINARY, BOOL, DICTIONARY) and NO else-raise: every other type — including
# LARGE_STRING / LARGE_BINARY, LIST / LARGE_LIST / MAP, STRUCT and UNION_* —
# fell through to its fixed-width arm, where `_arrow_type_byte_width`'s 8-byte
# `else` fallback reinterpreted the payload buffer as n_rows*8 fixed-width
# cells, dropped the offsets buffer and the children, and returned a column
# still tagged with the original type and carrying an exactly-correct row
# count. Silent wrong answer, not a raise.
#
# The claim is TRUE as of the S0 guard: `_concat_columns` now calls
# `varlen_width_guard.check_fixed_width_dispatch` immediately before that arm,
# so an offset-carrying or child-carrying type raises `ArrowFixedWidthFallthrough`
# naming the type and the site. Guard + falsifier:
# an internal test.
#
# The implementation drains `batches[0]` as the running accumulator, then
# for each subsequent batch performs `_concat_columns(acc.col_at(c),
# next.col_at(c))` per column. The output RecordBatch shares the schema
# of the first batch (RB schemas in a single stream are byte-identical
# per Arrow spec).


def _concat_batches(var batches: Slab[RecordBatch]) raises -> RecordBatch:
    """N-way fold of N RecordBatches into one via per-column N-way concat.

    Preconditions:
      - `batches.len >= 1`. Caller handles the 0-batch case (returns an
        empty RecordBatch with the schema-only contract).
      - All batches in the Slab share the SAME Schema (Arrow spec for a
        single Stream / File). The output's Schema is taken from the
        FIRST batch.

    Returns:
      A merged RecordBatch with rows = sum(batch.num_rows()) across all
      batches.

    ARROW-IPC-PERF-CONCAT-NWAY-FOLD: replaces the prior
    pair-wise `acc = _concat_columns(acc, next)` fold (O(N^2) memcpy
    traffic) with a single-pass N-way concat per column (O(total_bytes)).
    Implementation lives in `komira_arrow/concat.mojo` under
    `concat_record_batches_nway`. Profile-confirmed #1 hotspot fix
    (47% of uncompressed read wall on SF1 lineitem).
    """
    return concat_record_batches_nway(batches^)


def _slice_frame(
    src: SharedAlignedBuffer[HeapRegion], start: Int, frame_size: Int
) raises -> SharedAlignedBuffer[HeapRegion]:
    """Copy `frame_size` bytes from `src[start..start+frame_size]` into a
    fresh SharedAlignedBuffer[HeapRegion] whose `length` is `frame_size`.

    `decode_record_batch_message` requires the frame to start at byte 0
    of its own buffer (parse_ipc_message reads continuation at offset 0).

    ARROW-IPC-PERF: bulk memcpy via copy_from_view_at; the
    prior scalar `for i in range(frame_size): out.write_u8_at(...)` loop
    contributed measurably to per-RB-frame walk cost (~49 frames on SF1
    lineitem). See an internal doc §0.
    """
    var out = SharedAlignedBuffer[HeapRegion].heap_owned(frame_size)
    out.copy_from_view_at(0, src.view_range_ro(start, frame_size))
    out.set_length(frame_size)
    return out^


# =============================================================================
# Dictionary batch consume — ARROW-IPC-PHASE-4 step 3
# =============================================================================
#
# Decode the inner 1-column RecordBatch carrying a dictionary's VALUES
# half (per Arrow spec, DictionaryBatch's `data` field is a RecordBatch
# table whose single column has the dict's value type — typically
# STRING). Then update the cache:
#   isDelta == False → cache.replace(dict_id, values)
#   isDelta == True  → cache.append_to(dict_id, values)
#
# PHASE-4 step 3 v1 hard-codes STRING value type (matches the encoder
# side at `encode_dictionary_batch_message_from_string_column` — the
# only DictionaryBatch shape that the v0.4 encoder emits). Wider
# value types (BINARY / LARGE_STRING / etc.) are filed as PHASE-4-
# FOLLOWUP-DICT-VALUE-WIDER-TYPES and gate on the corresponding
# `encode_dictionary_batch_message_from_*` factory landing.


def _consume_dictionary_batch_frame(
    var dict_frame: SharedAlignedBuffer[HeapRegion],
    header_table_pos: Int,
    metadata_size: Int,
    body_length: Int,
    mut cache: IpcDictCache,
) raises:
    """Serial-fallback wrapper. See `_consume_dictionary_batch_frame_with_
    dispatcher` for the dispatcher-aware variant that drives the per-
    buffer decompress in parallel.

    Decode a DictionaryBatch frame + update `cache`.

    `dict_frame` is the complete frame: [u32 0xFFFFFFFF, u32 metadata_size,
    FB(Message{header=DictionaryBatch, body_length}), pad, body].
    `header_table_pos` is the position of the DictionaryBatch FB table
    within the FB metadata payload (caller passes it from the already-
    decoded MessageDescriptor).
    """
    # Class C: serial-fallback substitutes D=NoDispatch with a CONCRETE
    # origin, NOT MutAnyOrigin. None Optional; has_pool=False prunes the
    # dispatch branch.
    var _nd = NoDispatch()
    comptime nd_o = origin_of(_nd)
    return _consume_dictionary_batch_frame_impl[
        NoDispatch, has_pool=False, disp_o=nd_o,
    ](
        dict_frame^,
        header_table_pos,
        metadata_size,
        body_length,
        cache,
        Optional[Pointer[NoDispatch, nd_o]](None),
        CancellationToken.never(),
    )


def _consume_dictionary_batch_frame_with_dispatcher[
    D: ParallelDispatch,
    disp_o: Origin[mut=True],
](
    var dict_frame: SharedAlignedBuffer[HeapRegion],
    header_table_pos: Int,
    metadata_size: Int,
    body_length: Int,
    mut cache: IpcDictCache,
    dispatcher_ptr: Pointer[D, disp_o],
    var cancel_token: CancellationToken,
) raises:
    """Dispatcher-aware variant of `_consume_dictionary_batch_frame`.
    Generic over `D: ParallelDispatch` (Class C).

    ARROW-IPC-DISPATCHER-PLUMB-CASCADE-COMPLETE.
    """
    return _consume_dictionary_batch_frame_impl[
        D, has_pool=True, disp_o=disp_o,
    ](
        dict_frame^,
        header_table_pos,
        metadata_size,
        body_length,
        cache,
        Optional[Pointer[D, disp_o]](dispatcher_ptr),
        cancel_token^,
    )


def _consume_dictionary_batch_frame_impl[
    D: ParallelDispatch,
    has_pool: Bool,
    disp_o: Origin[mut=True],
](
    var dict_frame: SharedAlignedBuffer[HeapRegion],
    header_table_pos: Int,
    metadata_size: Int,
    body_length: Int,
    mut cache: IpcDictCache,
    dispatcher_ptr: Optional[Pointer[D, disp_o]],
    var cancel_token: CancellationToken,
) raises:
    """Shared body for the bare + `_with_dispatcher` `_consume_dictionary_
    batch_frame` variants. Comptime `has_pool` prunes the parallel
    decompress branch.

    Steps:
      1. Re-read the FB metadata slice + decode DictionaryBatch table
         (id + data table pos + isDelta).
      2. Decode the inner RecordBatch (1 STRING column carrying dict
         values) by re-slicing the frame as a synthetic RecordBatch
         message payload + calling `decode_record_batch_message`.
      3. Apply to cache per isDelta.

    PHASE-4-FOLLOWUP-DICT-COMPRESSED-VALUES: if the inner
    RecordBatch table carries a BodyCompression field with
    codec != -1, the frame is rewritten into an uncompressed-equivalent
    frame via `decompress_dictionary_batch_frame[C]` BEFORE the
    DictionaryBatch + inner RB tables are walked.
    """
    # PHASE-4-FOLLOWUP-DICT-COMPRESSED-VALUES pre-pass.
    var dict_codec_id = peek_dictionary_batch_codec_from_frame(dict_frame)
    if (
        dict_codec_id != Int8(-1)
        and dict_codec_id != Int8(0)
        and dict_codec_id != Int8(1)
    ):
        _ = cancel_token^
        raise Error(
            "_consume_dictionary_batch_frame: unknown BodyCompression"
            ".codec " + String(Int(dict_codec_id))
            + " (valid: -1 Uncompressed, 0 LZ4_FRAME, 1 ZSTD)"
        )
    var working_frame = dict_frame^
    var working_header_table_pos: Int = header_table_pos
    var working_metadata_size: Int = metadata_size

    comptime if has_pool:
        if dict_codec_id == Int8(0):
            working_frame = (
                decompress_dictionary_batch_frame_with_dispatcher[
                    Lz4Frame, D, disp_o
                ](
                    working_frame^,
                    dispatcher_ptr.value(),
                    cancel_token.clone(),
                )
            )
        elif dict_codec_id == Int8(1):
            working_frame = (
                decompress_dictionary_batch_frame_with_dispatcher[
                    Zstd[3], D, disp_o
                ](
                    working_frame^,
                    dispatcher_ptr.value(),
                    cancel_token.clone(),
                )
            )
    else:
        if dict_codec_id == Int8(0):
            working_frame = decompress_dictionary_batch_frame[Lz4Frame](
                working_frame^
            )
        elif dict_codec_id == Int8(1):
            working_frame = decompress_dictionary_batch_frame[Zstd[3]](
                working_frame^
            )
    _ = cancel_token^
    if dict_codec_id != Int8(-1):
        # Re-derive metadata_size + header_table_pos from the rewritten
        # frame's outer framing + Message table (old caller-supplied
        # values point into the original compressed frame).
        var nf = parse_ipc_message(working_frame)
        # ARROW-IPC-PERF: bulk memcpy via copy_from_view_at.
        var nfb = SharedAlignedBuffer[HeapRegion].heap_owned(nf.metadata_size)
        nfb.copy_from_view_at(
            0,
            working_frame.view_range_ro(nf.metadata_pos, nf.metadata_size),
        )
        nfb.set_length(nf.metadata_size)
        var nreader = flatbuf_reader_over(nfb)
        var nmsg = read_message(nreader, nreader.read_root_offset())
        working_header_table_pos = nmsg.header_table_pos
        working_metadata_size = nf.metadata_size

    # 1. Re-read FB metadata + DictionaryBatch table.
    # ARROW-IPC-PERF: bulk memcpy via copy_from_view_at.
    var fb = SharedAlignedBuffer[HeapRegion].heap_owned(working_metadata_size)
    fb.copy_from_view_at(
        0, working_frame.view_range_ro(8, working_metadata_size)
    )
    fb.set_length(working_metadata_size)
    var reader = flatbuf_reader_over(fb)
    var db_desc = read_dictionary_batch(reader, working_header_table_pos)

    # 2. The inner RecordBatch lives at `db_desc.data_table_pos` within
    # the SAME FB metadata. To re-use `decode_record_batch_message` we
    # synthesize a RecordBatch-shaped frame: [u32 0xFFFFFFFF, u32 size',
    # FB(Message{header=RecordBatch, header_table_pos=db_desc.data_table_pos,
    # body_length=dict_frame.body_length}), pad, body].
    #
    # Simpler approach (avoids re-FlatBuffers): the existing FB metadata
    # carries a Message wrapper with `header_table_pos` pointing at the
    # DictionaryBatch table. Within that table, `data` is the
    # RecordBatch's FB position. We re-read the RecordBatch table
    # directly + walk it via the existing low-level path. PHASE-4 step 3
    # v1 only needs to materialize the 1-column STRING dict-values
    # Column, so we call read_record_batch + a minimal column-decode
    # loop instead of synthesizing a Message wrapper.
    var rb_desc = read_record_batch(reader, db_desc.data_table_pos)

    # 3. Walk the single column: STRING expects (validity + offsets +
    # data) = 3 buffers + 1 FieldNode. Read the buffers from the body
    # bytes (which start at `8 + metadata_size` in the frame, exactly
    # as encoded by `write_ipc_message`).
    if len(rb_desc.nodes) != 1:
        raise Error(
            "_consume_dictionary_batch_frame: inner RecordBatch must "
            "have exactly 1 FieldNode (PHASE-4 step 3 v1 supports "
            "1-column STRING dict-values RecordBatch only); got "
            + String(len(rb_desc.nodes))
        )
    if len(rb_desc.buffers) != 3:
        raise Error(
            "_consume_dictionary_batch_frame: inner RecordBatch must "
            "have exactly 3 Buffers for a STRING dict-values column "
            "(validity + offsets + data); got "
            + String(len(rb_desc.buffers))
        )
    ref node = rb_desc.nodes[0]
    var n_dict_rows = Int(node.length)
    ref validity_buf = rb_desc.buffers[0]
    ref offsets_buf = rb_desc.buffers[1]
    ref data_buf = rb_desc.buffers[2]

    var body_pos = 8 + working_metadata_size  # body starts after framing

    # ==================================================================
    # ASSERT=none HARDENING — the DictionaryBatch arm had NO
    # buffer-descriptor gate.
    #
    # `_validate_rb_buffers_in_bounds` was added after a
    # RED-verified SIGSEGV and is called by all three RecordBatch entry
    # points (ipc_decoder_dispatch.mojo:557 / :1207 / :1769) — but NOT
    # here. Everything below resolves body bytes as
    # `working_frame.read_u8_at(body_pos + Int(buf.offset) + i)`, whose
    # only residual guard is `SharedAlignedBuffer.read_u8_at`'s
    # `debug_assert`. Mojo's `debug_assert` defaults to
    # assert_mode="none" — live only at ASSERT=all — so that guard is
    # already dead in the ASSERT=safe binaries we ship TODAY, and the
    # crash reproduces in both configs (measured: SIGSEGV at
    # both ASSERT=safe and ASSERT=none on
    # tests/fixtures/arrow_ipc/malformed_dict_*.arrow).
    #
    # Reached from Flight DoPut with fully attacker-controlled bytes: the
    # schema flatbuffer declares Field.dictionary_encoding, then a
    # DictionaryBatch frame carries the crafted descriptors.
    #
    # ONE check at the parse boundary, before any allocation or copy. The
    # three copy loops below then need no per-byte checking.
    # ==================================================================
    _validate_rb_buffers_in_bounds(
        rb_desc.buffers,
        body_pos,
        working_frame.len(),
        "_consume_dictionary_batch_frame",
    )

    # n_dict_rows is FieldNode.length — an unbounded flatbuffer i64 that
    # becomes an allocation size (`Bitmap.create`) AND the decoded Column's
    # `length`, which is the `dict_n` that `expand_dict_indices_to_string`
    # bounds every index against. An inflated value therefore makes ANY
    # index legal downstream. A STRING column of n rows requires exactly
    # (n + 1) Int32 offset entries, so the offsets buffer — now known to be
    # inside the frame — is the authority that bounds it.
    if n_dict_rows < 0:
        raise Error(
            "_consume_dictionary_batch_frame: FieldNode.length is negative ("
            + String(n_dict_rows)
            + "); dictionary row count cannot be negative"
        )
    # Division, not multiplication: `(n_dict_rows + 1) * 4` is itself an
    # overflow primitive on the same untrusted i64 it is meant to bound.
    # `offsets_buf.length` is already known non-negative and frame-bounded.
    if n_dict_rows > 0 and n_dict_rows > Int(offsets_buf.length) // 4 - 1:
        raise Error(
            "_consume_dictionary_batch_frame: FieldNode.length "
            + String(n_dict_rows)
            + " needs "
            + String(n_dict_rows)
            + "+1 Int32 offset entries but Buffer[1] (offsets) is only "
            + String(Int(offsets_buf.length))
            + " bytes"
        )

    # Decode validity (Optional[Bitmap[HeapRegion]]) — None when buffer length == 0.
    var validity_opt: Optional[Bitmap[HeapRegion]] = None
    if validity_buf.length > 0:
        var vbytes = (n_dict_rows + 7) // 8
        if Int(validity_buf.length) < vbytes:
            raise Error(
                "_consume_dictionary_batch_frame: validity buffer too "
                "small (got " + String(Int(validity_buf.length))
                + ", expected " + String(vbytes) + ")"
            )
        var bm = Bitmap.create(n_dict_rows)
        for i in range(vbytes):
            bm.buffer.write_u8_at(
                i,
                working_frame.read_u8_at(
                    body_pos + Int(validity_buf.offset) + i
                ),
            )
        bm.buffer.set_length(vbytes)

        validity_opt = bm^

    # Copy offsets buffer.
    var offsets_bytes = Int(offsets_buf.length)
    var offsets = OwnedAlignedBuffer(max(offsets_bytes, 1))
    for i in range(offsets_bytes):
        offsets.write_u8_at(
            i,
            working_frame.read_u8_at(
                body_pos + Int(offsets_buf.offset) + i
            ),
        )
    offsets.set_length(Int64(offsets_bytes))


    # Copy data buffer.
    var data_bytes = Int(data_buf.length)
    var data = OwnedAlignedBuffer(max(data_bytes, 1))
    for i in range(data_bytes):
        data.write_u8_at(
            i,
            working_frame.read_u8_at(
                body_pos + Int(data_buf.offset) + i
            ),
        )
    data.set_length(Int64(data_bytes))


    var values_col = Column[HeapRegion](
        arrow_type=ArrowType.STRING,
        data=data^,
        offsets=offsets^,
        validity=validity_opt^,
        length=n_dict_rows,
        null_count=Int(node.null_count),
        offset=0,
    )

    _ = body_length  # unused; body_pos derived from metadata_size + 8
    _ = working_frame^

    # 4. Apply to cache per isDelta.
    if db_desc.is_delta:
        cache.append_to(db_desc.id, values_col^)
    else:
        cache.replace(db_desc.id, values_col^)
# PHASE-4-FOLLOWUP-STRICT-MIXED-CODEC helper:
#
# Map a codec id to a human-readable name used by the `StrictMixedCodec`
# diagnostic. Mirrors `_arrow_ipc_codec_id_name` in `session_context.mojo`
# but lives here so the decoder + ctx layers share the same vocabulary
# without import cycles. The two helpers must stay in sync; the codec id
# space is the Arrow Message.fbs `CompressionType` enum:
#   -1 = Uncompressed (no BodyCompression flatbuf emitted)
#    0 = LZ4_FRAME
#    1 = ZSTD


def _write_strict_codec_name[W: Writer](mut writer: W, codec_id: Int8):
    """WRITE what `_strict_codec_name` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link binds INDEPENDENTLY; a
    shipped `_komira` bound such a pair CROSSED and took the
    interpreter with it. And
    `scripts/lint_literal_return_ladder.py`."""
    if codec_id == Int8(-1):
        writer.write(String("Uncompressed"))
        return
    if codec_id == Int8(0):
        writer.write(String("Lz4Frame"))
        return
    if codec_id == Int8(1):
        writer.write(String("Zstd"))
        return
    writer.write(String("<unknown codec_id=") + String(Int(codec_id)) + String(">"))
    return


def _strict_codec_name(codec_id: Int8) -> String:
    var out = String()
    _write_strict_codec_name(out, codec_id)
    return out^
