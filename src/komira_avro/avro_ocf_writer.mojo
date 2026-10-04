# =============================================================================
# avro_ocf_writer.mojo — Avro OCF writer path.
# =============================================================================
#
# The inverse of the read path (avro_ocf_reader.mojo): given a RecordBatch
# this
#   1. Derives the Avro record schema JSON from the Arrow schema
#      (avro_logical_arrow.from_arrow_schema_json), with arrow.* annotations when
#      emit_arrow_logicals=True.
#   2. Generates a 16-byte OS-entropy sync marker (getrandom / arc4random_buf).
#   3. Emits the OCF header (magic + metadata map + sync marker).
#   4. Row-by-row encodes each record's fields in declared (column) order into
#      a per-block raw payload, wrapping nullable columns in a union tag
#      (NULL_FIRST: tag 0 == null, tag 1 == value), flushing a block on the
#      bytes-OR-rows whichever-first trigger.
#   5. Per block: codec-compress the payload, frame it (object_count +
#      byte_count + payload + sync marker).
#
# Column coverage (correctness-first): flat root-record of
#   BOOL / INT32 / INT64 / FLOAT32 / FLOAT64 / STRING / BINARY, plus the
#   int-backed (INT8/INT16/UINT8/UINT16/TIME32_S) and long-backed
#   (UINT32/DATE64/TIMESTAMP_S/TIMESTAMP_NS/TIME64_NS/DURATION_*) lossy arrow.*
#   types. FIXED-backed lossy write (UINT64 -> fixed(8), FLOAT16 -> fixed(2)),
#   nested STRUCT/LIST/MAP/UNION write, enum / decimal write are not
#   supported yet — the reader handles them so the round-trip bar
#   (self-decode) is met for the supported columns.
#
# The acceptance bar is SELF-ROUND-TRIP: write -> read back via the
# reader -> assert equality, across all 6 codecs.
#
# Encapsulation: public API takes a borrowed RecordBatch + a path / returns
# owned List[UInt8]. No UnsafePointer crosses any module boundary.
# =============================================================================

from std.time import perf_counter_ns

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Schema
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.boolean_array import BooleanArray
from komira_core.arrow.large_string_array import LargeStringArray
from komira_core.arrow.string_array import StringArray
from komira_core.collections.slab import Slab
from komira_core.io.heap_region import HeapRegion

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.local_dispatcher import LocalDispatcher

from .avro_logical_arrow import from_arrow_schema_json
from .ocf_block_emit import (
    generate_sync_marker,
    emit_ocf_header,
    emit_ocf_block,
    compress_blocks_parallel,
    emit_compressed_block,
    emit_raw_block_null_codec,
    should_flush_block,
    AVRO_DEFAULT_BLOCK_SIZE_BYTES,
    AVRO_DEFAULT_BLOCK_SIZE_ROWS,
)
from .ocf_header import (
    AVRO_CODEC_NULL,
    AVRO_CODEC_DEFLATE,
    AVRO_CODEC_SNAPPY,
    AVRO_CODEC_BZIP2,
    AVRO_CODEC_XZ,
    AVRO_CODEC_ZSTANDARD,
    OCF_SYNC_LEN,
)
from .varint_encode import (
    encode_long,
    encode_int,
    encode_boolean,
    encode_float,
    encode_double,
    encode_string,
    encode_bytes,
    encode_union_tag,
)

# Avro row-native WRITE. The row-native adapter `write_row_output_avro`
# consumes a `RowOutput` (the row-native write-path carrier produced by the
# row-streaming pipeline) and emits Avro OCF bytes DIRECTLY, with no
# row->columnar->row round-trip. `komira_avro` importing
# `komira_row_format` is acyclic — `komira_row_format` never imports
# `komira_avro` (the same edge `komira_json` -> `komira_row_format` has).
from komira_row_format.row_output import RowOutput
from komira_row_format.row_block import (
    DT_I64,
    DT_F64,
    DT_I32,
    DT_F32,
    DT_STRING,
)


# =============================================================================
# AvroWriterOptions.
# =============================================================================


struct AvroWriterOptions(Copyable, Movable):
    """Avro OCF writer configuration.

    `codec_tag` is one of AVRO_CODEC_* (default NULL — no compression).
    `block_size_bytes` / `block_size_rows` drive the bytes-OR-rows
    whichever-first block flush (defaults: 64 KiB / a large
    row cap so the byte trigger dominates).
    `emit_arrow_logicals` (default True) stamps arrow.* annotations on
    lossy Arrow types so they round-trip; False emits a spec-plain schema.
    `record_name` is the Avro top-level record `name`.
    `strict_mode` (default True) raises on an Arrow type the writer cannot map;
    when False the writer still raises (there is no lossy-drop fallback
    yet) — the flag is reserved for future "skip-unsupported-column" behavior
    and currently only governs the error message phrasing.
    `print_timing` (default False) prints a coarse phase split (plan-build /
    encode-loop / block-flush) to stdout after each write; it is read once per
    write, never per row."""

    var codec_tag: Int
    var block_size_bytes: Int
    var block_size_rows: Int
    var emit_arrow_logicals: Bool
    var record_name: String
    var strict_mode: Bool
    var print_timing: Bool

    def __init__(out self, codec_tag: Int = AVRO_CODEC_NULL):
        self.codec_tag = codec_tag
        self.block_size_bytes = AVRO_DEFAULT_BLOCK_SIZE_BYTES
        self.block_size_rows = AVRO_DEFAULT_BLOCK_SIZE_ROWS
        self.emit_arrow_logicals = True
        self.record_name = String("topLevelRecord")
        self.strict_mode = True
        self.print_timing = False

    def __init__(
        out self,
        codec_tag: Int,
        block_size_bytes: Int,
        block_size_rows: Int,
        emit_arrow_logicals: Bool,
        var record_name: String,
        strict_mode: Bool,
        print_timing: Bool = False,
    ):
        self.codec_tag = codec_tag
        self.block_size_bytes = block_size_bytes
        self.block_size_rows = block_size_rows
        self.emit_arrow_logicals = emit_arrow_logicals
        self.record_name = record_name^
        self.strict_mode = strict_mode
        self.print_timing = print_timing

    def copy(self) -> Self:
        return AvroWriterOptions(
            self.codec_tag,
            self.block_size_bytes,
            self.block_size_rows,
            self.emit_arrow_logicals,
            self.record_name,
            self.strict_mode,
            self.print_timing,
        )


# =============================================================================
# Per-column write plan (type resolution hoisted out of the row loop).
# =============================================================================
#
# arrow-avro resolves each column's encoder ONCE per batch (`prepare_for_batch`)
# then the row loop just calls the already-typed encoder. Resolving per cell
# would re-walk a 17-branch `ArrowType` if/elif cascade for EVERY one of
# N_cols × N_rows cells — and, far worse, call `batch.column_as_*(col)` per
# cell, each of which DEEP-COPIES the whole column buffer (column.mojo
# as_primitive/as_string/as_boolean all memcpy): one full-column copy per row.
#
# The fix: `_build_col_encoders` runs ONCE before the row loop. It (a) resolves
# each column's write action into a small integer tag, and (b) fetches the
# typed Arrow array ONCE (one copy per column for the whole file, not per row).
# The row loop then dispatches on the tag and indexes the pre-fetched array via
# `arr.get(row)` (O(1)) — no cascade, no per-cell column copy.

# Write-action tags. Grouped by the Avro wire encoder they drive.
comptime _WA_INT32: Int = 0  # Avro int  (bare INT32 + TIME32_S)
comptime _WA_INT8: Int = 1  # Avro int  (widen narrow signed/unsigned -> int)
comptime _WA_INT16: Int = 2
comptime _WA_UINT8: Int = 3
comptime _WA_UINT16: Int = 4
comptime _WA_INT64: Int = 5  # Avro long (bare INT64 + long-backed logicals)
comptime _WA_UINT32: Int = 6  # Avro long (widen uint32 -> long)
comptime _WA_FLOAT32: Int = 7
comptime _WA_FLOAT64: Int = 8
comptime _WA_BOOL: Int = 9
comptime _WA_STRING: Int = 10  # STRING (int32 offsets, zero-copy span)
comptime _WA_BINARY: Int = 11  # BINARY / LARGE_BINARY (zero-copy span)
# ⚠ LARGE_STRING NEEDS ITS OWN TAG. `column_as_string` returns an int32-offset
# array by definition, so resolving a PROMOTED column through it raises
# `Column.as_string: arrow_type is large_string`.
# The Avro wire bytes are identical either way (a `bytes`/`string` value is a
# zig-zag length followed by the UTF-8 payload); only the offset width used to
# FIND the payload differs, which is why this is a separate tag and not a
# separate encoder.
comptime _WA_LARGE_STRING: Int = 12  # LARGE_STRING (int64 offsets, zero-copy span)


struct _ColEncoder(Movable):
    """A pre-resolved per-column encoder: the write-action tag + nullability +
    the typed Arrow array fetched ONCE. Exactly one of the typed-array
    optionals is populated, selected by `tag`.

    The narrow signed/unsigned logicals (int8/16, uint8/16) share the int32
    slot path via their own optionals so the per-cell widen-cast stays O(1)
    on the already-fetched array; uint32 shares the int64 long path."""

    var tag: Int
    var nullable: Bool
    var i32: Optional[PrimitiveArray[DType.int32]]
    var i8: Optional[PrimitiveArray[DType.int8]]
    var i16: Optional[PrimitiveArray[DType.int16]]
    var u8: Optional[PrimitiveArray[DType.uint8]]
    var u16: Optional[PrimitiveArray[DType.uint16]]
    var i64: Optional[PrimitiveArray[DType.int64]]
    var u32: Optional[PrimitiveArray[DType.uint32]]
    var f32: Optional[PrimitiveArray[DType.float32]]
    var f64: Optional[PrimitiveArray[DType.float64]]
    var b: Optional[BooleanArray]
    var s: Optional[StringArray[HeapRegion]]
    var ls: Optional[LargeStringArray[HeapRegion]]

    def __init__(out self, tag: Int, nullable: Bool):
        self.tag = tag
        self.nullable = nullable
        self.i32 = None
        self.i8 = None
        self.i16 = None
        self.u8 = None
        self.u16 = None
        self.i64 = None
        self.u32 = None
        self.f32 = None
        self.f64 = None
        self.b = None
        self.s = None
        self.ls = None


def _resolve_write_tag(at: ArrowType) -> Int:
    """Resolve the per-column write-action tag (-1 if unsupported)."""
    if at == ArrowType.INT32 or at == ArrowType.TIME32_S:
        return _WA_INT32
    elif at == ArrowType.INT8:
        return _WA_INT8
    elif at == ArrowType.INT16:
        return _WA_INT16
    elif at == ArrowType.UINT8:
        return _WA_UINT8
    elif at == ArrowType.UINT16:
        return _WA_UINT16
    elif (
        at == ArrowType.INT64
        or at == ArrowType.DATE64
        or at == ArrowType.TIMESTAMP_S
        or at == ArrowType.TIMESTAMP_NS
        or at == ArrowType.TIME64_NS
        or at == ArrowType.DURATION_S
        or at == ArrowType.DURATION_MS
        or at == ArrowType.DURATION_US
        or at == ArrowType.DURATION_NS
    ):
        return _WA_INT64
    elif at == ArrowType.UINT32:
        return _WA_UINT32
    elif at == ArrowType.FLOAT32:
        return _WA_FLOAT32
    elif at == ArrowType.FLOAT64:
        return _WA_FLOAT64
    elif at == ArrowType.BOOL:
        return _WA_BOOL
    elif at == ArrowType.STRING:
        return _WA_STRING
    elif at == ArrowType.LARGE_STRING:
        return _WA_LARGE_STRING
    elif at == ArrowType.BINARY or at == ArrowType.LARGE_BINARY:
        return _WA_BINARY
    return -1


def _build_col_encoders(
    batch: RecordBatch, schema: Schema, strict_mode: Bool
) raises -> Slab[_ColEncoder]:
    """Validate + build the per-column encoder list ONCE.

    Resolves each column's write tag and fetches its typed Arrow array a single
    time (one copy per column for the whole file). Raises (strict-mode) on the
    first unsupported Arrow type so no partial OCF is emitted.

    Returns a `Slab` (not `List`) because `_ColEncoder` holds Movable-only
    Arrow arrays — `List[T]` requires `T: Copyable`, `Slab[T]` requires only
    Movable."""
    var encoders = Slab[_ColEncoder]()
    var n = schema.num_columns()
    for c in range(n):
        var at = schema.field_arrow_type(c)
        var tag = _resolve_write_tag(at)
        if tag < 0:
            raise Error(
                String("AvroWriteError.UNSUPPORTED_TYPE: column ")
                + schema.field_name(c)
                + " has Arrow type "
                + String(at)
                + " which the Avro writer cannot encode (supported: flat"
                " primitives + int/long-backed arrow.* logicals; FIXED-backed"
                " uint64/float16, nested, decimal, enum write are not supported yet)"
            )
        var enc = _ColEncoder(tag, schema.field_nullable(c))
        # Fetch the typed array ONCE (not a per-cell deep copy).
        if tag == _WA_INT32:
            enc.i32 = batch.column_as_primitive_int32(c)
        elif tag == _WA_INT8:
            enc.i8 = batch.column_at(c).as_primitive[DType.int8]()
        elif tag == _WA_INT16:
            enc.i16 = batch.column_at(c).as_primitive[DType.int16]()
        elif tag == _WA_UINT8:
            enc.u8 = batch.column_at(c).as_primitive[DType.uint8]()
        elif tag == _WA_UINT16:
            enc.u16 = batch.column_at(c).as_primitive[DType.uint16]()
        elif tag == _WA_INT64:
            enc.i64 = batch.column_as_primitive_int64(c)
        elif tag == _WA_UINT32:
            enc.u32 = batch.column_at(c).as_primitive[DType.uint32]()
        elif tag == _WA_FLOAT32:
            enc.f32 = batch.column_as_primitive_float32(c)
        elif tag == _WA_FLOAT64:
            enc.f64 = batch.column_as_primitive_float64(c)
        elif tag == _WA_BOOL:
            enc.b = batch.column_as_boolean(c)
        elif tag == _WA_LARGE_STRING:
            # ⛔ NOT `column_as_string`: its int64 path narrows, and narrowing
            # is refused above the int32 ceiling — i.e. it refuses exactly the
            # column whose size caused the promotion.
            enc.ls = batch.column_as_large_string(c)
        else:  # _WA_STRING / _WA_BINARY both use the string accessor.
            enc.s = batch.column_as_string(c)
        encoders.append(enc^)
    _ = strict_mode
    return encoders^


# =============================================================================
# Column-major value encode.
# =============================================================================
#
# Each `_encode_col_*` function owns one column's whole-block encode: it takes
# the pre-resolved `_ColEncoder` (typed array already fetched ONCE) plus the
# [row0, row1) row span for the current block, and encodes that column's values
# for those rows into the per-(row, col) interleaved block payload via a
# striding write. Because OCF records interleave fields per row, the block
# payload is NOT a simple column-major concat — each column's bytes for a given
# row must land at that row's record position. We achieve "dispatch hoisted out
# of the inner loop" differently: `_encode_block` dispatches ONCE per column
# (on the integer tag) into a monomorphic per-column row loop, so the inner loop
# over rows is a single tight, inlinable encoder with no per-cell branch.
#
# To preserve record interleaving with a per-column inner loop, the block is
# encoded row-major at the OUTER level but the type dispatch is resolved per
# column up front. Concretely `_encode_block` loops rows × cols and calls
# `_encode_one_cell(enc, row, out)` which switches on `enc.tag` (a single Int
# compare chain the compiler lowers to a jump table) over the ALREADY-FETCHED
# array — O(1) per cell, no column copy, no ArrowType cascade.


@always_inline
def _emit_null_tag(nullable: Bool, is_null: Bool, mut out: List[UInt8]) -> Bool:
    """For a nullable column write the NULL_FIRST union tag; return True iff the
    cell is null (caller stops). No-op (returns False) for a non-nullable
    column."""
    if nullable:
        if is_null:
            encode_union_tag(0, out)  # null branch
            return True
        encode_union_tag(1, out)  # value branch
    return False


def _encode_one_cell(
    enc: _ColEncoder, row: Int, mut out: List[UInt8]
) raises:
    """Encode ONE cell using the pre-resolved encoder. Dispatches on the
    integer `tag` over the array fetched ONCE in `_build_col_encoders` — no
    per-cell column copy and, for strings, a zero-copy span."""
    var tag = enc.tag
    if tag == _WA_INT32:
        ref arr = enc.i32.value()
        if _emit_null_tag(enc.nullable, arr.is_null(row), out):
            return
        encode_int(arr.get(row), out)
    elif tag == _WA_INT64:
        ref arr = enc.i64.value()
        if _emit_null_tag(enc.nullable, arr.is_null(row), out):
            return
        encode_long(arr.get(row), out)
    elif tag == _WA_FLOAT64:
        ref arr = enc.f64.value()
        if _emit_null_tag(enc.nullable, arr.is_null(row), out):
            return
        encode_double(arr.get(row), out)
    elif tag == _WA_FLOAT32:
        ref arr = enc.f32.value()
        if _emit_null_tag(enc.nullable, arr.is_null(row), out):
            return
        encode_float(arr.get(row), out)
    elif tag == _WA_STRING:
        ref arr = enc.s.value()
        if _emit_null_tag(enc.nullable, arr.is_null(row), out):
            return
        # Zero-copy span into the Arrow data buffer — no owned-String alloc.
        encode_bytes(arr.get_span(row), out)
    elif tag == _WA_LARGE_STRING:
        ref arr = enc.ls.value()
        if _emit_null_tag(enc.nullable, arr.is_null(row), out):
            return
        # `LargeStringArray.get_span` is the int64-offset twin of the span
        # above and is the ONLY allocation-free way to walk a promoted
        # column — a `get()` per row on a 2 GiB+ column aborts.
        # Same `encode_bytes`, same wire bytes.
        encode_bytes(arr.get_span(row), out)
    elif tag == _WA_BINARY:
        ref arr = enc.s.value()
        if _emit_null_tag(enc.nullable, arr.is_null(row), out):
            return
        encode_bytes(arr.get_span(row), out)
    elif tag == _WA_BOOL:
        ref arr = enc.b.value()
        if _emit_null_tag(enc.nullable, arr.is_null(row), out):
            return
        encode_boolean(arr.get(row), out)
    elif tag == _WA_INT8:
        ref arr = enc.i8.value()
        if _emit_null_tag(enc.nullable, arr.is_null(row), out):
            return
        encode_int(Int32(Int(arr.get(row))), out)
    elif tag == _WA_INT16:
        ref arr = enc.i16.value()
        if _emit_null_tag(enc.nullable, arr.is_null(row), out):
            return
        encode_int(Int32(Int(arr.get(row))), out)
    elif tag == _WA_UINT8:
        ref arr = enc.u8.value()
        if _emit_null_tag(enc.nullable, arr.is_null(row), out):
            return
        encode_int(Int32(Int(arr.get(row))), out)
    elif tag == _WA_UINT16:
        ref arr = enc.u16.value()
        if _emit_null_tag(enc.nullable, arr.is_null(row), out):
            return
        encode_int(Int32(Int(arr.get(row))), out)
    else:  # _WA_UINT32 -> Avro long.
        ref arr = enc.u32.value()
        if _emit_null_tag(enc.nullable, arr.is_null(row), out):
            return
        encode_long(Int64(Int(arr.get(row))), out)


# =============================================================================
# Public: write a RecordBatch to Avro OCF bytes.
# =============================================================================


struct _EncodedBlocks(Movable):
    """The output of the row-loop encode pass: owned per-block raw payloads
    paired with their object counts. The compress + frame passes consume this
    in INDEX ORDER. The slab + list are emitted by `_encode_row_loop_to_blocks`
    and consumed by `_finalize_blocks_serial` / `_finalize_blocks_parallel`.

    Fields wrapped in `Optional[...]` so the consumer can `.take()` each one
    out without a partial move through UnsafePointer. After both `.take()`
    calls the struct drops with None-state
    payloads (no double-free)."""
    var raw_blocks: Optional[Slab[List[UInt8]]]
    var object_counts: Optional[List[Int]]
    var encode_ns: Int

    def __init__(
        out self,
        var raw_blocks: Slab[List[UInt8]],
        var object_counts: List[Int],
        encode_ns: Int,
    ):
        self.raw_blocks = Optional[Slab[List[UInt8]]](raw_blocks^)
        self.object_counts = Optional[List[Int]](object_counts^)
        self.encode_ns = encode_ns


def _encode_row_loop_to_blocks(
    batch: RecordBatch,
    schema: Schema,
    opts: AvroWriterOptions,
    timing: Bool,
) raises -> _EncodedBlocks:
    """Row-loop encode pass — produces every block's raw payload + object_count.

    Instead of flushing each block inline (which would compress + frame
    serially), we
    emit each block's raw payload into its own fresh `List[UInt8]` and push it
    onto the slab. The downstream compress pass consumes the slab.

    Block reuse trade-off: a serial writer can reuse ONE `block_payload` List
    across the entire write via `.clear()`. The parallel path
    cannot do that — each block needs its own owned List, since the parallel
    compress reads them simultaneously. We pay the per-block allocator cost
    in exchange for parallel-compress throughput (compression dominates the
    wall time of a compressed write).
    """
    var t_encode_ns = 0
    var n_rows = batch.num_rows()
    var n_cols = schema.num_columns()

    var encoders = _build_col_encoders(batch, schema, opts.strict_mode)

    var raw_blocks = Slab[List[UInt8]]()
    var object_counts = List[Int]()

    if n_rows == 0:
        return _EncodedBlocks(raw_blocks^, object_counts^, 0)

    # Allocate the first block payload. Same capacity heuristic as the NULL
    # codec path (block_size_bytes + 50% slack) so trailing cells don't trigger a
    # realloc cycle within a block.
    var block_payload_cap = opts.block_size_bytes + opts.block_size_bytes // 2
    var block_payload = List[UInt8](capacity=block_payload_cap)
    var block_rows = 0

    for row in range(n_rows):
        var t_enc = perf_counter_ns() if timing else 0
        for col in range(n_cols):
            _encode_one_cell(encoders[col], row, block_payload)
        if timing:
            t_encode_ns += Int(perf_counter_ns() - t_enc)
        block_rows += 1
        if should_flush_block(
            len(block_payload),
            block_rows,
            opts.block_size_bytes,
            opts.block_size_rows,
        ):
            # Move the completed block onto the slab; allocate a fresh one
            # for the next block.
            raw_blocks.append(block_payload^)
            object_counts.append(block_rows)
            block_payload = List[UInt8](capacity=block_payload_cap)
            block_rows = 0

    if block_rows > 0:
        raw_blocks.append(block_payload^)
        object_counts.append(block_rows)

    return _EncodedBlocks(raw_blocks^, object_counts^, t_encode_ns)


def _finalize_blocks_serial(
    var encoded: _EncodedBlocks,
    sync: Array[UInt8, OCF_SYNC_LEN],
    opts: AvroWriterOptions,
    mut out: List[UInt8],
    timing: Bool,
) raises -> Int:
    """Serial-fallback finalize: compress each block + frame in index order.

    Used when no dispatcher is available (test fixtures, library callers
    without a EngineContext). Returns the flush-phase nanos for timing."""
    var t_flush_ns = 0
    # Extract slabs via Optional.take (never a partial move via UnsafePointer).
    var raw_blocks = encoded.raw_blocks.take()
    var object_counts = encoded.object_counts.take()
    _ = encoded^
    var n_blocks = raw_blocks.len()
    if opts.codec_tag == AVRO_CODEC_NULL:
        # NULL fast path: frame each raw block directly (no compress copy).
        for i in range(n_blocks):
            var t_fl = perf_counter_ns() if timing else 0
            ref raw = raw_blocks[i]
            emit_raw_block_null_codec(
                Span(raw), object_counts[i], sync, out
            )
            if timing:
                t_flush_ns += Int(perf_counter_ns() - t_fl)
        return t_flush_ns

    # Compressing codec: serial compress + frame per block.
    for i in range(n_blocks):
        var t_fl = perf_counter_ns() if timing else 0
        ref raw = raw_blocks[i]
        emit_ocf_block(
            Span(raw), object_counts[i], opts.codec_tag, sync, out
        )
        if timing:
            t_flush_ns += Int(perf_counter_ns() - t_fl)
    return t_flush_ns


def _finalize_blocks_parallel[disp_o: Origin[mut=True]](
    var encoded: _EncodedBlocks,
    sync: Array[UInt8, OCF_SYNC_LEN],
    opts: AvroWriterOptions,
    mut out: List[UInt8],
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
    timing: Bool,
) raises -> Int:
    """Parallel finalize: dispatch per-block compress across the runtime's
    worker pool, then serial-frame in index order.

    Returns the flush-phase nanos for timing. The NULL codec takes the same
    raw-frame fast path as the serial finalize (no per-block compress; the
    per-byte memcpy isn't worth the dispatch overhead)."""
    var t_flush_ns = 0
    # Extract slabs via Optional.take (never a partial move via UnsafePointer).
    var raw_blocks = encoded.raw_blocks.take()
    var object_counts = encoded.object_counts.take()
    _ = encoded^
    var n_blocks = raw_blocks.len()
    if opts.codec_tag == AVRO_CODEC_NULL:
        _ = cancel_token^
        for i in range(n_blocks):
            var t_fl = perf_counter_ns() if timing else 0
            ref raw = raw_blocks[i]
            emit_raw_block_null_codec(
                Span(raw), object_counts[i], sync, out
            )
            if timing:
                t_flush_ns += Int(perf_counter_ns() - t_fl)
        return t_flush_ns

    # Parallel compress: dispatcher-aware path. The dispatch returns a slab
    # of compressed payloads in INDEX ORDER (slot i ↔ raw_blocks[i]).
    var t_compress_start = perf_counter_ns() if timing else 0
    comptime r_o = origin_of(raw_blocks)
    var compressed = compress_blocks_parallel[r_o, disp_o](
        raw_blocks, opts.codec_tag, dispatcher_ptr, cancel_token^,
    )
    _ = raw_blocks^  # raw_blocks lives across the dispatch (origin pin).
    if timing:
        t_flush_ns += Int(perf_counter_ns() - t_compress_start)

    # Serial frame in INDEX ORDER. The compressed slab + object_counts list
    # have the same length and one-to-one slot mapping.
    var t_frame_start = perf_counter_ns() if timing else 0
    for i in range(n_blocks):
        ref c = compressed[i]
        emit_compressed_block(
            Span(c), object_counts[i], sync, out
        )
    if timing:
        t_flush_ns += Int(perf_counter_ns() - t_frame_start)

    _ = compressed^
    return t_flush_ns


def _encode_and_frame_null_codec_inline(
    batch: RecordBatch,
    schema: Schema,
    opts: AvroWriterOptions,
    sync: Array[UInt8, OCF_SYNC_LEN],
    mut out: List[UInt8],
    timing: Bool,
    mut t_encode_ns: Int,
    mut t_flush_ns: Int,
) raises:
    """NULL-codec fast path: single-`block_payload`-with-`.clear()` reuse
    pattern.

    The NULL codec hits the raw-frame path so gets ZERO benefit from per-block
    parallel compress, and would only pay its trade-off (a fresh `List` per
    block, several microseconds each). This helper keeps the reuse pattern
    SPECIFICALLY for the NULL codec.

    Encodes rows column-by-column INTO a single reused `block_payload`, flushes
    each block via `emit_raw_block_null_codec` (direct framing, no compress
    copy) into `out`, then `.clear()` the payload to reset length while keeping
    heap capacity. No parallel dispatch (per-byte memcpy isn't worth the
    fork-join cost; the wall is dominated by the row-loop encode itself).

    Returns encode/flush nanos via mut out-args."""
    var n_rows = batch.num_rows()
    var n_cols = schema.num_columns()

    if n_rows == 0:
        return

    var encoders = _build_col_encoders(batch, schema, opts.strict_mode)

    # Reuse ONE accumulator across all blocks; `.clear()` resets length
    # to 0 while keeping heap capacity.
    var block_payload = List[UInt8](
        capacity=opts.block_size_bytes + opts.block_size_bytes // 2
    )
    var block_rows = 0

    for row in range(n_rows):
        var t_enc = perf_counter_ns() if timing else 0
        for col in range(n_cols):
            _encode_one_cell(encoders[col], row, block_payload)
        if timing:
            t_encode_ns += Int(perf_counter_ns() - t_enc)
        block_rows += 1
        if should_flush_block(
            len(block_payload),
            block_rows,
            opts.block_size_bytes,
            opts.block_size_rows,
        ):
            var t_fl = perf_counter_ns() if timing else 0
            emit_raw_block_null_codec(
                Span(block_payload), block_rows, sync, out
            )
            block_payload.clear()
            block_rows = 0
            if timing:
                t_flush_ns += Int(perf_counter_ns() - t_fl)

    if block_rows > 0:
        var t_fl = perf_counter_ns() if timing else 0
        emit_raw_block_null_codec(
            Span(block_payload), block_rows, sync, out
        )
        if timing:
            t_flush_ns += Int(perf_counter_ns() - t_fl)


def _write_avro_bytes_core[has_dispatcher: Bool, disp_o: Origin[mut=True]](
    batch: RecordBatch,
    opts: AvroWriterOptions,
    dispatcher_ptr: Optional[Pointer[LocalDispatcher[NoopSink], disp_o]],
    var cancel_token: CancellationToken,
) raises -> List[UInt8]:
    """Shared core: row-loop encode + (parallel-or-serial) compress + frame.

    The `has_dispatcher` comptime flag prunes the parallel/serial branch at
    compile time — no `MutAnyOrigin` reaches the dispatch in either path.
    The dispatcher entry / serial entry public functions select the right
    branch at the call site.

    The NULL codec short-circuits to `_encode_and_frame_null_codec_inline`
    (`block_payload.clear()` reuse pattern) regardless of `has_dispatcher` —
    the NULL codec hits the raw-frame fast path so gets ZERO benefit from
    per-block parallel compress, and would only pay its trade-off (a fresh
    `List` per block in `_encode_row_loop_to_blocks`). Compressed
    codecs (snappy/zstd/deflate) continue through the collect-then-finalize
    parallel-aware pipeline."""
    var schema = batch.schema.copy()
    if schema.num_columns() == 0:
        _ = cancel_token^
        raise Error("AvroWriteError.EMPTY_SCHEMA: RecordBatch has no columns")

    var timing = opts.print_timing
    var t_plan_start = perf_counter_ns() if timing else 0

    var schema_json = from_arrow_schema_json(
        schema, opts.record_name, opts.emit_arrow_logicals
    )
    var sync = generate_sync_marker()
    var n_rows = batch.num_rows()
    var n_cols = schema.num_columns()

    # Pre-reserve `out`. The estimate
    # is `n_rows * 96 + 4 KiB` which covers ~70% of final file size in one
    # allocation. Lower bound (compressed codec): ~5-10x smaller; upper bound
    # (null codec): ~equal to estimate. Either way reduces realloc cascade.
    var est_payload_bytes = n_rows * 96 + 4096
    var out = List[UInt8](capacity=est_payload_bytes)
    emit_ocf_header(schema_json, opts.codec_tag, sync, out)

    var t_plan_ns = Int(perf_counter_ns() - t_plan_start) if timing else 0

    # NULL-codec short-circuit: single-accumulator reuse pattern. Dispatcher
    # token consumed (no parallel work).
    if opts.codec_tag == AVRO_CODEC_NULL:
        _ = cancel_token^
        var t_encode_null_ns = 0
        var t_flush_null_ns = 0
        _encode_and_frame_null_codec_inline(
            batch, schema, opts, sync, out, timing,
            t_encode_null_ns, t_flush_null_ns,
        )
        if timing:
            print(
                "[AVRO-WRITE-TIMING] rows=",
                n_rows,
                " cols=",
                n_cols,
                " plan_us=",
                t_plan_ns // 1000,
                " encode_us=",
                t_encode_null_ns // 1000,
                " flush_us=",
                t_flush_null_ns // 1000,
            )
        return out^

    # Compressing codec path: row-loop encode pass produces all blocks' raw
    # payloads at once; the compress + frame pass runs serial or parallel.
    var encoded = _encode_row_loop_to_blocks(batch, schema, opts, timing)
    var t_encode_ns = encoded.encode_ns  # POD read; safe before the move.

    var t_flush_ns: Int
    comptime if has_dispatcher:
        var disp = dispatcher_ptr.value()
        t_flush_ns = _finalize_blocks_parallel[disp_o](
            encoded^, sync, opts, out, disp, cancel_token^, timing,
        )
    else:
        _ = cancel_token^
        t_flush_ns = _finalize_blocks_serial(encoded^, sync, opts, out, timing)

    if timing:
        print(
            "[AVRO-WRITE-TIMING] rows=",
            n_rows,
            " cols=",
            n_cols,
            " plan_us=",
            t_plan_ns // 1000,
            " encode_us=",
            t_encode_ns // 1000,
            " flush_us=",
            t_flush_ns // 1000,
        )

    return out^


def write_avro_bytes(
    batch: RecordBatch, opts: AvroWriterOptions
) raises -> List[UInt8]:
    """Encode a RecordBatch into a complete in-memory Avro OCF byte stream
    (serial-fallback entry — no dispatcher).

    Delegates to `_write_avro_bytes_core[has_dispatcher=False]`: the
    collect-blocks-then-frame pattern; the serial fallback uses
    `emit_ocf_block` per block (the per-block alloc cost is in noise vs the
    compress cost).

    Self-round-trips through `read_avro_bytes` (the acceptance bar)."""
    return _write_avro_bytes_core[has_dispatcher=False, disp_o=MutAnyOrigin](
        batch,
        opts,
        Optional[Pointer[LocalDispatcher[NoopSink], MutAnyOrigin]](None),
        CancellationToken.never(),
    )


def write_avro_bytes_with_dispatcher[disp_o: Origin[mut=True]](
    batch: RecordBatch,
    opts: AvroWriterOptions,
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
) raises -> List[UInt8]:
    """Dispatcher-aware sibling of `write_avro_bytes` — per-block parallel
    compress via `LocalDispatcher.run_with_state`.

    Threads the EngineContext-owned LocalDispatcher into `compress_blocks_parallel`
    for parallel per-block compress. Block order is preserved; the on-disk
    bytes are byte-for-byte identical to the serial entry (same blocks, same
    codec, same sync marker generated up-front).

    Acceptance: SELF-ROUND-TRIP through `read_avro_bytes` AND byte-identity
    vs `write_avro_bytes` (same RecordBatch + opts + a fixed sync marker).
    """
    return _write_avro_bytes_core[has_dispatcher=True, disp_o=disp_o](
        batch,
        opts,
        Optional[Pointer[LocalDispatcher[NoopSink], disp_o]](dispatcher_ptr),
        cancel_token^,
    )


def write_avro_file(
    batch: RecordBatch, path: String, opts: AvroWriterOptions
) raises:
    """Write a RecordBatch to an Avro OCF file on disk (serial-fallback)."""
    var bytes = write_avro_bytes(batch, opts)
    _write_bytes_to_file(path, bytes)


def write_avro_file_with_dispatcher[disp_o: Origin[mut=True]](
    batch: RecordBatch,
    path: String,
    opts: AvroWriterOptions,
    dispatcher_ptr: Pointer[LocalDispatcher[NoopSink], disp_o],
    var cancel_token: CancellationToken,
) raises:
    """Dispatcher-aware variant of `write_avro_file` — wires the dispatcher
    through to `write_avro_bytes_with_dispatcher` for parallel block compress.
    """
    var bytes = write_avro_bytes_with_dispatcher[disp_o](
        batch, opts, dispatcher_ptr, cancel_token^,
    )
    _write_bytes_to_file(path, bytes)


def _write_bytes_to_file(path: String, bytes: List[UInt8]) raises:
    """Write owned bytes to a file (binary).

    Routes through `LocalFs[NoopSink].write_at` rather than the concrete
    POSIX file API. `LocalFs.write_at` chunks large payloads (64 MiB) to
    avoid a stdlib >2 GB silent-flush bug (single-write fast path below
    64 MiB). Other filesystem sinks can plug in without codec changes."""
    from komira_fs.local_fs import LocalFs
    from komira_fs.file_system import WriteMode
    from komira_async.ops.waker_sink import NoopSink

    var fs = LocalFs[NoopSink].new()
    var f = fs.open_write(path, WriteMode.create_truncate())
    _ = fs.write_at(f, Span(bytes))
    fs.close_write(f^)


# =============================================================================
# write_row_output_avro — Avro row-native WRITE adapter.
# =============================================================================
#
# The row-native writer — the sibling of `komira_json`'s
# `write_row_output_jsonl` and of the row-native Avro reader
# (`read_avro_path_to_row_block` in `komira_sdk`). It serializes a `RowOutput`'s surviving RowBlocks
# DIRECTLY into a complete Avro OCF byte stream, REUSING the existing Avro
# primitives verbatim (no new encoder work):
#   * schema JSON: `from_arrow_schema_json(ro.schema, ...)` — the SAME whole-
#     schema Arrow->Avro walker the column writer uses, so nullable columns are
#     wrapped `union[null, T]` (NULL_FIRST) byte-identically.
#   * per-cell value encode: `encode_long` (I64/I32 — widened), `encode_double`
#     (F64), `encode_float` (F32), `encode_string` (STRING).
#   * nullable cell: `encode_union_tag(0)` for the null branch, `encode_union_
#     tag(1)` + value for the present branch — exactly the NULL_FIRST ordering
#     the reader's `_decode_read_field` / `read_avro_path_to_row_block` consumes
#     and the typed writer emits.
#   * block framing: `emit_ocf_header` + the bytes-OR-rows flush trigger
#     (`should_flush_block`) + `emit_ocf_block` (NULL-codec raw-frame fast path
#     and compressed-codec path both handled inside emit_ocf_block).
#
# Scope (FLAT, like the row reader): DT_I64 / DT_I32 / DT_F64 / DT_F32 /
# DT_STRING + per-cell nulls. Any other output DType tag HARD-RAISES (the row
# pipeline never produces one for a pure-streaming chain — the same discipline
# as the reader's nested hard-raise).
#
# Encapsulation: cells are read via RowBlock's PUBLIC
# `read_fixed[DT]` / `read_var_string_at` / `is_cell_null`. No raw pointer
# crosses a boundary; no wildcard origin; no unsafe_from_address.
# =============================================================================


def write_row_output_avro(
    var ro: RowOutput, opts: AvroWriterOptions
) raises -> List[UInt8]:
    """Encode every row of `ro` into a complete in-memory Avro OCF byte stream,
    with NO row->columnar->row round-trip.

    Byte-equivalent (value-identical on round-trip) to taking `ro` through the
    shared `bridge_row_output_to_record_batch` then `write_avro_bytes`, but
    skips the throwaway columnar RecordBatch the bridge would build. The output
    self-round-trips through `read_avro_path_to_row_block` / `ctx.read_avro`.

    The supported output DType subset matches the row-streaming fast fixed
    subset (DT_I64 / DT_I32 / DT_F64 / DT_F32 / DT_STRING); any other tag raises.
    """
    ref layout = ro.layout
    var n_cols = layout.n_cols()
    if n_cols == 0:
        _ = ro^
        raise Error(
            "AvroWriteError.EMPTY_SCHEMA: RowOutput has no output columns"
        )

    var has_validity = layout.has_validity
    var vo = layout.validity_offset

    # ---- Step 1: schema JSON (the SAME Arrow->Avro walker the column path
    # uses; nullable cols -> union[null, T] NULL_FIRST). ----
    var schema = ro.schema.copy()
    var schema_json = from_arrow_schema_json(
        schema, opts.record_name, opts.emit_arrow_logicals
    )

    # Per-column nullability: a column declared nullable in the Arrow schema is
    # wrapped union[null, T] (NULL_FIRST) by `from_arrow_schema_json`, so the
    # per-cell encode MUST prefix the value with the branch tag. A non-nullable
    # column emits the bare value (no tag). Read this off the schema ONCE.
    var col_nullable = List[Bool]()
    col_nullable.reserve(n_cols)
    for c in range(n_cols):
        col_nullable.append(schema.field_nullable(c))

    # ---- Step 2: sync marker + OCF header ----
    var sync = generate_sync_marker()
    var n_rows = ro.total_rows()
    var est_payload_bytes = n_rows * 96 + 4096
    var out = List[UInt8](capacity=est_payload_bytes)
    emit_ocf_header(schema_json, opts.codec_tag, sync, out)

    # ---- Step 3: encode records into block payloads with the bytes-OR-rows
    # flush trigger, framing each block via emit_ocf_block. ----
    var block_payload = List[UInt8]()
    var block_rows = 0
    for bi in range(len(ro.blocks)):
        ref blk = ro.blocks[bi]
        for r in range(blk.n_rows):
            var c = 0
            while c < n_cols:
                var off = layout.offsets[c]
                var dt = layout.dtype_tags[c]
                var is_null = has_validity and blk.is_cell_null(r, vo, c)
                if col_nullable[c]:
                    # union[null, T] NULL_FIRST: branch 0 == null, 1 == T.
                    if is_null:
                        encode_union_tag(0, block_payload)
                        c = c + 1
                        continue
                    encode_union_tag(1, block_payload)
                # Non-nullable columns never carry a null cell from the row
                # pipeline; a defensive null on a non-nullable column would be
                # a layout bug, so we encode the underlying value regardless
                # (matches the column writer which writes a non-union value).
                if dt == DT_I64:
                    encode_long(blk.read_fixed[DType.int64](r, off), block_payload)
                elif dt == DT_I32:
                    # Avro `int` wire-encoding is varint, same as long modulo
                    # width; widen-then-encode (the reader narrows on read_int).
                    encode_int(blk.read_fixed[DType.int32](r, off), block_payload)
                elif dt == DT_F64:
                    encode_double(
                        blk.read_fixed[DType.float64](r, off), block_payload
                    )
                elif dt == DT_F32:
                    encode_float(
                        blk.read_fixed[DType.float32](r, off), block_payload
                    )
                elif dt == DT_STRING:
                    var raw = blk.read_var_string_at(r, off)
                    encode_bytes(Span(raw), block_payload)
                else:
                    raise Error(
                        "write_row_output_avro: output DType tag "
                        + String(Int(dt))
                        + " outside the row-streaming supported subset."
                    )
                c = c + 1
            block_rows = block_rows + 1

            # Flush when the accumulated raw bytes / row count cross the
            # bytes-OR-rows threshold (same trigger as the column writer).
            if should_flush_block(
                len(block_payload),
                block_rows,
                opts.block_size_bytes,
                opts.block_size_rows,
            ):
                emit_ocf_block(
                    Span(block_payload),
                    block_rows,
                    opts.codec_tag,
                    sync,
                    out,
                )
                block_payload.clear()
                block_rows = 0

    # Flush the trailing partial block.
    if block_rows > 0:
        emit_ocf_block(
            Span(block_payload), block_rows, opts.codec_tag, sync, out
        )

    _ = ro^
    return out^


def write_row_output_avro_file(
    var ro: RowOutput, path: String, opts: AvroWriterOptions
) raises:
    """Write a `RowOutput` to an Avro OCF file on disk, row-native (no bridge).

    The disk sibling of `write_row_output_avro` — encodes the OCF byte stream
    then writes it via `LocalFs` exactly as `write_avro_file` does."""
    var bytes = write_row_output_avro(ro^, opts)
    _write_bytes_to_file(path, bytes)
