# =============================================================================
# cross_batch_gather -- gather rows from several RecordBatches into one
# =============================================================================
#
# The multi-source form of `compiler_helpers.gather_batch`, after Arrow's
# `interleave`: given source batches that share one schema and a list of
# `(source_idx, row_idx)` pairs, build one batch whose row `i` is
# `sources[indices[i][0]]` row `indices[i][1]`. The output schema (metadata
# included) is source 0's. The external sort materializes its merged output
# with it.
#
# Column types supported, exactly:
#   * 8-byte: INT64, UINT64, FLOAT64, DATE64, TIMESTAMP, TIMESTAMP_S / _MS /
#     _US / _NS, TIME64_US, TIME64_NS, DURATION_S / _MS / _US / _NS;
#   * 4-byte: INT32, UINT32, FLOAT32, DATE32, TIME32_S, TIME32_MS;
#   * 2-byte: INT16, UINT16, FLOAT16; 1-byte: INT8, UINT8;
#   * STRING and BINARY (Int32 offsets), LARGE_STRING (Int64 offsets), BOOL
#     (bit-packed) and NULL.
# Every other type raises "unsupported column type": DECIMAL128, DECIMAL256,
# INTERVAL_MONTH_DAY_NANO, DICTIONARY, LIST, STRUCT, UNION, ... (the 16- and
# 32-byte types have no gather arm).
#
# Output row order is `indices` order. Validity is carried row by row.
# =============================================================================

from std.memory import memcpy
from std.sys import size_of

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.offset_overflow import check_int32_offsets
from .gather_width_counter import gather_note_narrow_typed
from komira_buffer.heap_region import HeapRegion
from komira_arrow.column import Column
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_collections.slab import Slab


# =============================================================================
# Helpers
# =============================================================================


@always_inline
def _fixed_elem_size(at: ArrowType) -> Int:
    """Byte width of a fixed-width ArrowType (0 for non-fixed).

    Matches the coverage in `_gather_batch` / `_concat_fixed_columns_multi`.
    """
    if at == ArrowType.INT8 or at == ArrowType.UINT8:
        return 1
    elif at == ArrowType.INT16 or at == ArrowType.UINT16 or at == ArrowType.FLOAT16:
        return 2
    elif at == ArrowType.INT32 or at == ArrowType.UINT32 or at == ArrowType.FLOAT32:
        return 4
    elif at == ArrowType.INT64 or at == ArrowType.UINT64 or at == ArrowType.FLOAT64:
        return 8
    elif at == ArrowType.DATE32 or at == ArrowType.TIME32_S or at == ArrowType.TIME32_MS:
        return 4
    elif at == ArrowType.DATE64 or at == ArrowType.TIMESTAMP:
        return 8
    elif (
        at == ArrowType.TIMESTAMP_S
        or at == ArrowType.TIMESTAMP_MS
        or at == ArrowType.TIMESTAMP_US
        or at == ArrowType.TIMESTAMP_NS
    ):
        return 8
    elif at == ArrowType.TIME64_US or at == ArrowType.TIME64_NS:
        return 8
    elif (
        at == ArrowType.DURATION_S
        or at == ArrowType.DURATION_MS
        or at == ArrowType.DURATION_US
        or at == ArrowType.DURATION_NS
    ):
        return 8
    else:
        return 0


@always_inline
def _is_supported(at: ArrowType) -> Bool:
    """Whether cross_batch_gather can handle this column type.

    Returns False for DECIMAL128/256, INTERVAL_MONTH_DAY_NANO, DICTIONARY,
    LIST, STRUCT and the other nested types — the caller must route those
    through pairwise concat or decode upstream.
    """
    if at == ArrowType.STRING or at == ArrowType.LARGE_STRING:
        return True
    if at == ArrowType.BINARY:
        return True
    if at == ArrowType.BOOL:
        return True
    if at == ArrowType.NULL:
        return True
    return _fixed_elem_size(at) > 0


# =============================================================================
# Per-column gather kernels
# =============================================================================


def _gather_fixed_column(
    sources: Slab[RecordBatch],
    indices: List[Tuple[Int, Int]],
    col: Int,
    at: ArrowType,
) raises -> Column[HeapRegion]:
    """Cross-source gather for a fixed-width column of 1, 2, 4 or 8 bytes.

    One output row per index pair. Reads elem_size bytes from the referenced
    source and writes them contiguously to the output buffer. Honors each
    source column's `_offset` (zero-copy slicing).
    """
    var elem_size = _fixed_elem_size(at)
    if elem_size == 0:
        raise Error("_gather_fixed_column: non-fixed ArrowType " + String(at))

    var count = len(indices)
    var data_buf = OwnedAlignedBuffer(max(count * elem_size, 1))

    # NOT-VECTORIZABLE: Cross-source gather with two-level indirection
    # (src_idx, row_idx). src_idx varies per element preventing contiguous loads.
    # Run-length batching possible but complex; scalar is correct baseline.
    if elem_size == 8:
        # PERF-CRITICAL: typed-pointer dest preserves direct typed store.
        # R3.2c.13: migrate off banned _typed_ptr_{ro,mut} wildcard shims onto
        # origin-tied view_{ro,mut} + _unsafe_ptr + bitcast.
        # ByteView pins data_buf borrow alive across the gather loop.
        var dst8_view = data_buf.view_mut()
        var dst8 = dst8_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
        for i in range(count):
            var pair = indices[i]
            var src_idx = pair[0]
            var row_idx = pair[1]
            ref src_col = sources[src_idx].column_at(col)
            var src8_view = src_col._data.view_ro()
            var src8 = src8_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
            (dst8 + i)[] = (src8 + src_col._offset + row_idx)[]
    elif elem_size == 4:
        # PERF-CRITICAL: typed-pointer dest preserves direct typed store.
        # R3.2c.13: migrate off banned _typed_ptr_{ro,mut} wildcard shims onto
        # origin-tied view_{ro,mut} + _unsafe_ptr + bitcast.
        var dst4_view = data_buf.view_mut()
        var dst4 = dst4_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
        for i in range(count):
            var pair = indices[i]
            var src_idx = pair[0]
            var row_idx = pair[1]
            ref src_col = sources[src_idx].column_at(col)
            var src4_view = src_col._data.view_ro()
            var src4 = src4_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
            (dst4 + i)[] = (src4 + src_col._offset + row_idx)[]
    elif elem_size == 2:
        # INT16 / UINT16 / FLOAT16 take a typed store, matching the 8- and
        # 4-byte arms.
        var dst2_view = data_buf.view_mut()
        var dst2 = dst2_view._unsafe_ptr().bitcast[Scalar[DType.int16]]()
        gather_note_narrow_typed(count)
        for i in range(count):
            var pair = indices[i]
            var src_idx = pair[0]
            var row_idx = pair[1]
            ref src_col = sources[src_idx].column_at(col)
            var src2_view = src_col._data.view_ro()
            var src2 = src2_view._unsafe_ptr().bitcast[Scalar[DType.int16]]()
            (dst2 + i)[] = (src2 + src_col._offset + row_idx)[]
    elif elem_size == 1:
        var dst1_view = data_buf.view_mut()
        var dst1 = dst1_view._unsafe_ptr().bitcast[Scalar[DType.int8]]()
        gather_note_narrow_typed(count)
        for i in range(count):
            var pair = indices[i]
            var src_idx = pair[0]
            var row_idx = pair[1]
            ref src_col = sources[src_idx].column_at(col)
            var src1_view = src_col._data.view_ro()
            var src1 = src1_view._unsafe_ptr().bitcast[Scalar[DType.int8]]()
            (dst1 + i)[] = (src1 + src_col._offset + row_idx)[]
    else:
        # Unreachable: `_fixed_elem_size` returns 1, 2, 4 or 8 for a supported
        # type and the width check above refused 0.
        raise Error("_gather_fixed_column: unexpected width " + String(elem_size))
    data_buf.set_length(Int64(count * elem_size))


    # Validity: build output bitmap only if any source column has one.
    var validity = Optional[Bitmap[HeapRegion]](None)
    var null_count = 0
    var any_validity = False
    var n_sources = len(sources)
    for s in range(n_sources):
        if sources[s].column_at(col)._validity:
            any_validity = True
            break
    if any_validity:
        var bm = Bitmap.create_all_valid(count)
        for i in range(count):
            var pair = indices[i]
            var src_idx = pair[0]
            var row_idx = pair[1]
            ref src_col = sources[src_idx].column_at(col)
            if src_col._validity:
                if not src_col._validity.value().test(src_col._offset + row_idx):
                    bm.clear(i)
                    null_count += 1
        validity = bm^

    return Column[HeapRegion](
        arrow_type=at,
        data=data_buf^,
        offsets=None,
        validity=validity^,
        length=count,
        null_count=null_count,
        offset=0,
    )


def _gather_string_column[offset_width: Int](
    sources: Slab[RecordBatch],
    indices: List[Tuple[Int, Int]],
    col: Int,
    at: ArrowType,
) raises -> Column[HeapRegion]:
    """Cross-source gather for STRING / LARGE_STRING / BINARY.

    Parameters:
        offset_width: 4 for STRING/BINARY (Int32 offsets), 8 for LARGE_STRING
                      (Int64 offsets).

    Two-pass: (1) sum output data bytes + per-row lengths; (2) allocate and
    memcpy each selected string slice. Mirrors `_gather_batch`'s STRING arm
    and `_concat_string_columns_multi`.
    """
    comptime off_size = offset_width
    var count = len(indices)

    # Pass 1: totals.
    var total_bytes = 0
    for i in range(count):
        var pair = indices[i]
        var src_idx = pair[0]
        var row_idx = pair[1]
        ref src_col = sources[src_idx].column_at(col)
        if not src_col._offsets:
            raise Error("_gather_string_column: missing offsets buffer")
        var row = src_col._offset + row_idx
        # R3.2c.13: migrate off banned _typed_ptr_ro wildcard shim onto
        # origin-tied view_ro + _unsafe_ptr + bitcast.
        if off_size == 4:
            var off_view = src_col._offsets.value().view_ro()
            var off_ptr = off_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
            var s = Int((off_ptr + row)[])
            var e = Int((off_ptr + row + 1)[])
            total_bytes += e - s
        else:
            var off_view64 = src_col._offsets.value().view_ro()
            var off_ptr64 = off_view64._unsafe_ptr().bitcast[Scalar[DType.int64]]()
            var s64 = Int((off_ptr64 + row)[])
            var e64 = Int((off_ptr64 + row + 1)[])
            total_bytes += e64 - s64

    # Int32-offset ceiling: only the 4-byte arm can wrap. LARGE_STRING
    # (off_size == 8) has no such ceiling, so it is deliberately unchecked.
    # Fires before either output buffer is allocated.
    comptime if off_size == 4:
        var _gc_name = String()
        if len(sources) > 0:
            _gc_name = sources[0].schema.field_name(col)
        check_int32_offsets(
            "_gather_string_column", _gc_name, total_bytes, count
        )

    # Allocate output buffers.
    var out_offsets_bytes = (count + 1) * off_size
    var offsets_buf = OwnedAlignedBuffer(max(out_offsets_bytes, off_size))
    offsets_buf.set_length(Int64(out_offsets_bytes))

    var data_buf = OwnedAlignedBuffer(max(total_bytes, 1))
    data_buf.set_length(Int64(total_bytes))


    # Pass 2: copy payload bytes + write offsets + build validity.
    var any_validity = False
    var n_sources = len(sources)
    for s in range(n_sources):
        if sources[s].column_at(col)._validity:
            any_validity = True
            break

    var validity = Optional[Bitmap[HeapRegion]](None)
    var null_count = 0
    if any_validity:
        validity = Bitmap.create_all_valid(count)

    var dst_cursor = 0
    if off_size == 4:
        # R3.2c.13: migrate off banned _typed_ptr_{ro,mut} wildcard shims onto
        # origin-tied view_{ro,mut} + _unsafe_ptr + bitcast.
        var out_off32_view = offsets_buf.view_mut()
        var out_off32 = out_off32_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
        (out_off32 + 0)[] = Int32(0)
        for i in range(count):
            var pair = indices[i]
            var src_idx = pair[0]
            var row_idx = pair[1]
            ref src_col = sources[src_idx].column_at(col)
            var row = src_col._offset + row_idx
            var off_view = src_col._offsets.value().view_ro()
            var off_ptr = off_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
            var s = Int((off_ptr + row)[])
            var e = Int((off_ptr + row + 1)[])
            var n = e - s
            if n > 0:
                data_buf.copy_from_view_at(
                    dst_cursor, src_col._data.view_range_ro(s, n)
                )
            dst_cursor += n
            (out_off32 + i + 1)[] = Int32(dst_cursor)
            if any_validity and src_col._validity:
                if not src_col._validity.value().test(row):
                    validity.value().clear(i)
                    null_count += 1
    else:
        # R3.2c.13: migrate off banned _typed_ptr_{ro,mut} wildcard shims onto
        # origin-tied view_{ro,mut} + _unsafe_ptr + bitcast.
        var out_off64_view = offsets_buf.view_mut()
        var out_off64 = out_off64_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
        (out_off64 + 0)[] = Int64(0)
        for i in range(count):
            var pair = indices[i]
            var src_idx = pair[0]
            var row_idx = pair[1]
            ref src_col = sources[src_idx].column_at(col)
            var row = src_col._offset + row_idx
            var off_view64 = src_col._offsets.value().view_ro()
            var off_ptr64 = off_view64._unsafe_ptr().bitcast[Scalar[DType.int64]]()
            var s64 = Int((off_ptr64 + row)[])
            var e64 = Int((off_ptr64 + row + 1)[])
            var n = e64 - s64
            if n > 0:
                data_buf.copy_from_view_at(
                    dst_cursor, src_col._data.view_range_ro(s64, n)
                )
            dst_cursor += n
            (out_off64 + i + 1)[] = Int64(dst_cursor)
            if any_validity and src_col._validity:
                if not src_col._validity.value().test(row):
                    validity.value().clear(i)
                    null_count += 1

    return Column[HeapRegion](
        arrow_type=at,
        data=data_buf^,
        offsets=offsets_buf^,
        validity=validity^,
        length=count,
        null_count=null_count,
        offset=0,
    )


def _gather_bool_column(
    sources: Slab[RecordBatch],
    indices: List[Tuple[Int, Int]],
    col: Int,
) raises -> Column[HeapRegion]:
    """Cross-source gather for a BOOL column (bit-packed).

    Builds a fresh Bitmap output, setting each bit from the source's data
    bitmap. Also builds output validity if any source has one.
    """
    var count = len(indices)
    # SAFETY: allocate the packed-bit data buffer directly (matches
    # Column.from_boolean at column.mojo:226 which copies Bitmap bytes into
    # an MmapAlignedBuffer). Avoids a partial-move of Bitmap.buffer which Mojo
    # 0.26 forbids (see feedback_mojo_partial_move_forbidden).
    var bm_bytes = (count + 7) >> 3
    var data_buf = OwnedAlignedBuffer(max(bm_bytes, 1))
    # Zero-initialize: MmapAlignedBuffer.create does NOT zero. Use memset
    # against the capacity span (origin tracks through `data_buf`).
    from std.memory import memset
    memset(data_buf.into_span_capacity().unsafe_ptr(), 0, max(bm_bytes, 1))
    # PERF-CRITICAL: typed-byte pointer cache for the per-row bit-pack
    # write loop below. Origin tied to data_buf, identical codegen.
    # R3.2c.13: migrate off banned _typed_ptr_mut wildcard shim onto
    # origin-tied view_mut + _unsafe_ptr + bitcast.
    var data_ptr_view = data_buf.view_mut()
    var data_ptr = data_ptr_view._unsafe_ptr().bitcast[Scalar[DType.uint8]]()

    var any_validity = False
    var n_sources = len(sources)
    for s in range(n_sources):
        if sources[s].column_at(col)._validity:
            any_validity = True
            break

    var validity = Optional[Bitmap[HeapRegion]](None)
    var null_count = 0
    if any_validity:
        validity = Bitmap.create_all_valid(count)

    for i in range(count):
        var pair = indices[i]
        var src_idx = pair[0]
        var row_idx = pair[1]
        ref src_col = sources[src_idx].column_at(col)
        var row = src_col._offset + row_idx
        # Read source data bit directly from the packed data buffer.
        # Column's data buffer IS the bit-packed Bitmap bytes (see
        # Column.from_boolean at column.mojo:226).
        var src_byte_idx = row >> 3
        var src_bit_idx = row & 7
        var src_byte = src_col._data.read_u8_at(src_byte_idx)
        var bit_set = (src_byte >> UInt8(src_bit_idx)) & UInt8(1) == UInt8(1)
        if bit_set:
            var dst_byte_idx = i >> 3
            var dst_bit_idx = i & 7
            (data_ptr + dst_byte_idx)[] = (data_ptr + dst_byte_idx)[] | (UInt8(1) << UInt8(dst_bit_idx))
        if any_validity and src_col._validity:
            if not src_col._validity.value().test(row):
                validity.value().clear(i)
                null_count += 1

    data_buf.set_length(Int64(bm_bytes))


    return Column[HeapRegion](
        arrow_type=ArrowType.BOOL,
        data=data_buf^,
        offsets=None,
        validity=validity^,
        length=count,
        null_count=null_count,
        offset=0,
    )


def _gather_null_column(count: Int) -> Column[HeapRegion]:
    """NULL column: length-only, no data, all entries logically null."""
    var data_buf = OwnedAlignedBuffer(1)
    data_buf.set_length(0)

    return Column[HeapRegion](
        arrow_type=ArrowType.NULL,
        data=data_buf^,
        offsets=None,
        validity=None,
        length=count,
        null_count=count,
        offset=0,
    )


# =============================================================================
# Public entry point
# =============================================================================


def cross_batch_gather(
    sources: Slab[RecordBatch],
    indices: List[Tuple[Int, Int]],
) raises -> RecordBatch:
    """Gather rows from multiple source RecordBatches into a single output.

    Each `indices[i] = (source_idx, row_idx)` selects one row from
    `sources[source_idx]` at row `row_idx`. Output row order matches the
    order of `indices` (stable).

    All sources MUST share the same schema (byte-identical ArrowType sequence).
    Output schema equals `sources[0].schema`.

    Args:
        sources: Non-empty array of source RecordBatches. Ownership retained
            by the caller (no consumption). Validated to be non-empty.
        indices: Per-output-row (source_idx, row_idx) pairs. Empty indices
            yields an empty RecordBatch with the same schema.

    Returns:
        A new RecordBatch of length `len(indices)` and schema equal to
        `sources[0].schema` (by column-wise reconstruction).

    Raises:
        If `sources` is empty, if an index pair is out of range, or if any
        column has an unsupported ArrowType (DICTIONARY / LIST / STRUCT).
    """
    var n_sources = len(sources)
    if n_sources == 0:
        raise Error("cross_batch_gather: sources must be non-empty")

    var count = len(indices)
    var num_cols = sources[0].num_columns()

    # Build the output schema from sources[0]'s schema.
    # preserve metadata.
    var sb = SchemaBuilder()
    for c in range(num_cols):
        sb.add_field(sources[0].schema.field_at(c))

    # Empty indices: return an empty batch with the right schema.
    if count == 0:
        var empty_builder = RecordBatchBuilder.with_capacity(num_cols)
        for c in range(num_cols):
            var at = sources[0].schema.field_arrow_type(c)
            # Empty column of the right type. Use a 1-byte stub data buffer
            # for fixed-width types and a (1-entry) offsets buffer for
            # variable-width types to satisfy Column's buffer invariants.
            if at == ArrowType.NULL:
                empty_builder.add_column(_gather_null_column(0))
            elif at == ArrowType.BOOL:
                var empty_data = OwnedAlignedBuffer(1)
                empty_data.set_length(0)

                empty_builder.add_column(Column[HeapRegion](
                    arrow_type=ArrowType.BOOL,
                    data=empty_data^,
                    offsets=None,
                    validity=None,
                    length=0,
                    null_count=0,
                    offset=0,
                ))
            elif at == ArrowType.STRING or at == ArrowType.BINARY:
                var d = OwnedAlignedBuffer(1)
                d.set_length(0)

                var o = OwnedAlignedBuffer(size_of[Int32]())
                o.set_typed[Int32](0, Int32(0))
                o.set_length(Int64(size_of[Int32]()))

                empty_builder.add_column(Column[HeapRegion](
                    arrow_type=at,
                    data=d^,
                    offsets=o^,
                    validity=None,
                    length=0,
                    null_count=0,
                    offset=0,
                ))
            elif at == ArrowType.LARGE_STRING:
                var d = OwnedAlignedBuffer(1)
                d.set_length(0)

                var o = OwnedAlignedBuffer(size_of[Int64]())
                o.set_typed[Int64](0, Int64(0))
                o.set_length(Int64(size_of[Int64]()))

                empty_builder.add_column(Column[HeapRegion](
                    arrow_type=at,
                    data=d^,
                    offsets=o^,
                    validity=None,
                    length=0,
                    null_count=0,
                    offset=0,
                ))
            else:
                var elem = _fixed_elem_size(at)
                if elem == 0:
                    raise Error(
                        "cross_batch_gather: unsupported column type "
                        + String(at)
                    )
                var d = OwnedAlignedBuffer(max(elem, 1))
                d.set_length(0)

                empty_builder.add_column(Column[HeapRegion](
                    arrow_type=at,
                    data=d^,
                    offsets=None,
                    validity=None,
                    length=0,
                    null_count=0,
                    offset=0,
                ))
        return empty_builder.build(sb.build())

    # Bounds check index pairs once up-front.
    for i in range(count):
        var pair = indices[i]
        var src_idx = pair[0]
        var row_idx = pair[1]
        if src_idx < 0 or src_idx >= n_sources:
            raise Error(
                "cross_batch_gather: source index "
                + String(src_idx)
                + " out of range [0, "
                + String(n_sources)
                + ")"
            )
        var src_rows = sources[src_idx].num_rows()
        if row_idx < 0 or row_idx >= src_rows:
            raise Error(
                "cross_batch_gather: row index "
                + String(row_idx)
                + " out of range for source "
                + String(src_idx)
            )

    # Gather each column.
    var builder = RecordBatchBuilder.with_capacity(num_cols)
    for c in range(num_cols):
        var at = sources[0].schema.field_arrow_type(c)
        # Consistency check: all sources share the same type per column.
        for s in range(1, n_sources):
            var at_s = sources[s].schema.field_arrow_type(c)
            if at_s != at:
                raise Error(
                    "cross_batch_gather: source "
                    + String(s)
                    + " column "
                    + String(c)
                    + " has type "
                    + String(at_s)
                    + ", expected "
                    + String(at)
                )

        if not _is_supported(at):
            raise Error(
                "cross_batch_gather: unsupported column type "
                + String(at)
                + " (DECIMAL, INTERVAL and nested types are not gathered; caller must "
                + "route through pairwise concat)"
            )

        if at == ArrowType.NULL:
            builder.add_column(_gather_null_column(count))
        elif at == ArrowType.BOOL:
            builder.add_column(_gather_bool_column(sources, indices, c))
        elif at == ArrowType.STRING or at == ArrowType.BINARY:
            builder.add_column(_gather_string_column[4](sources, indices, c, at))
        elif at == ArrowType.LARGE_STRING:
            builder.add_column(_gather_string_column[8](sources, indices, c, at))
        else:
            builder.add_column(_gather_fixed_column(sources, indices, c, at))

    return builder.build(sb.build())
