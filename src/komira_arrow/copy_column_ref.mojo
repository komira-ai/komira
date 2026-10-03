# =============================================================================
# copy_column_ref — Column deep-copy helper
# =============================================================================
#
# Lives in core so that low-level packages (e.g. the async multi-consumer
# source) can call it without depending on the engine dispatch layer (which
# would form a cycle).
#
# The function has no engine / dispatch / parquet types in its
# signature — it operates over a borrowed `Column` reference and
# returns an owned `Column`, so arrow is its natural home; `komira_core`
# covers all needed primitives (Column, Bitmap, OwnedAlignedBuffer,
# ArrowType, size_of).
# =============================================================================

from std.sys import simd_width_of, size_of

from komira_arrow.arrow_types import ArrowType, arrow_fixed_byte_width
from komira_arrow.column import Column
from komira_arrow.bitmap import Bitmap, copy_bits_aligned_buffer
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.varlen_width_guard import (
    carries_children,
    carries_offsets,
    check_fixed_width_dispatch,
    offset_width_bytes_or_raise,
)
from komira_buffer.heap_region import HeapRegion


@always_inline
def _elem_byte_width(at: ArrowType) raises -> Int:
    """Byte width for fixed-BYTE-width Arrow types; raise otherwise.

    ⚠ NOT ITS OWN LADDER: delegates to the canonical table.
    `copy_column_ref` gates the var-len layouts, DICTIONARY **and BOOL** (via
    `copy_bits_aligned_buffer`) before ever calling it. What an
    `else: return 8  # fallback` would be live for here is the nested
    layouts (LIST / LARGE_LIST / STRUCT / MAP / UNION_* / FIXED_SIZE_LIST),
    FIXED_SIZE_BINARY, the four *_VIEW layouts and NULL — each copied as
    `num_rows * 8` opaque bytes into a Column with `offsets=None` and no
    children. Those raise, naming the type.
    """
    return arrow_fixed_byte_width(at)


def _copy_varlen_arm[
    dt: DType, o: Origin[mut=False]
](
    ref [o] col_ref: Column[HeapRegion],
    num_rows: Int,
    var validity: Optional[Bitmap[HeapRegion]],
    null_count: Int,
) raises -> Column[HeapRegion]:
    """Copy ONE Arrow variable-length layout, at the offset stride `dt` names.

    ⭐ ONE ARM FOR THE FAMILY, NOT ONE ARM PER TYPE. STRING / BINARY /
    LARGE_STRING / LARGE_BINARY differ in exactly one thing — whether the
    offsets buffer is Int32 or Int64 — and that one thing is already written
    down, once, in `varlen_width_guard.offset_width_bytes`. Parameterising on
    it means a future Int64-offset varlen type is served the day the guard
    classifies it, instead of the day somebody notices the fifth hand-written
    copy of this loop is missing an entry. (A per-type `else: return 8`
    fallthrough is a silent-wrong-answer hazard; see `arrow_types.mojo`.)

    ⚠ `dt` IS NOT A FREE CHOICE AT THE CALL SITE. It is derived from the
    column's own type tag via `offset_width_bytes_or_raise`, which RAISES
    rather than defaulting to 4 — a LARGE_STRING's Int64 offsets read at Int32
    stride produce a column with a correct row count and wrong values, which is
    the exact defect shape this file's guard exists to prevent.

    Parameters:
        dt: The offsets DType — `int32` or `int64`, chosen by the caller from
            the type's declared offset width.
        o: Origin of the borrowed source column.

    Args:
        col_ref: The borrowed source column.
        num_rows: Rows to copy, starting at `col_ref._offset`.
        validity: The already-copied validity bitmap (moved in).
        null_count: Null count of the copied window.

    Returns:
        An owned, offset-0-rebased copy.
    """
    comptime off_size = size_of[Scalar[dt]]()
    var at = col_ref.arrow_type
    var offset = col_ref._offset
    ref src_off_buf = col_ref._offsets.value()
    var data_start = Int(src_off_buf.get_typed[Scalar[dt]](offset))
    var data_end = Int(src_off_buf.get_typed[Scalar[dt]](offset + num_rows))
    var data_len = data_end - data_start

    var data_buf = OwnedAlignedBuffer(max(data_len, 1))
    if data_len > 0:
        data_buf.copy_from_view(
            col_ref._data.view_range_ro(data_start, data_len)
        )
    else:
        data_buf.set_length(0)

    var off_bytes = (num_rows + 1) * off_size
    var off_buf = OwnedAlignedBuffer(off_bytes)
    var base = Scalar[dt](data_start)
    # Unit-stride subtract. Mojo does not autovectorize the scalar
    # set_typed loop. Hand-stage W lanes via load_simd / store_simd. The
    # buffer's pad-to-64 invariant
    # guarantees the SIMD store of the final partial vector lands within
    # capacity, but we still issue the scalar tail to avoid clobbering bits
    # past `(num_rows + 1) * off_size`.
    comptime W = simd_width_of[dt]()
    var n_off = num_rows + 1
    var src_byte_base = offset * off_size
    var simd_end = (n_off // W) * W
    var base_vec = SIMD[dt, W](base)
    var i = 0
    while i < simd_end:
        var v = src_off_buf.load_simd[dt, W](src_byte_base + i * off_size)
        off_buf.store_simd[dt, W](i * off_size, v - base_vec)
        i += W
    # Scalar tail.
    while i < n_off:
        off_buf.set_typed[Scalar[dt]](
            i, src_off_buf.get_typed[Scalar[dt]](offset + i) - base
        )
        i += 1
    off_buf.set_length(Int64(off_bytes))

    return Column[HeapRegion](
        arrow_type=at, data=data_buf^, offsets=off_buf^,
        validity=validity^, length=num_rows, null_count=null_count, offset=0,
    )


def copy_column_ref[o: Origin[mut=False]](
    ref [o] col_ref: Column[HeapRegion],
    num_rows: Int,
) raises -> Column[HeapRegion]:
    """Create an owned copy of a Column[HeapRegion] from a borrowed Column[HeapRegion] reference.

    For fixed-width types, copies the data buffer. For string/dict types,
    copies offsets + data. Preserves validity bitmap.

    The column is borrowed as `ref [o] Column`; the caller's RecordBatch
    keeps it alive through the borrow.

    Lives in core so that low-level packages can call it without a
    dependency on the engine dispatch layer.
    """
    var at = col_ref.arrow_type
    var offset = col_ref._offset

    # Copy validity if present.
    #
    # `Bitmap.copy_bits_into` (memcpy-backed bulk copy when offset is
    # byte-aligned; bit-walk fallback otherwise) + SIMD `popcount` for
    # null_count, rather than a per-bit
    # `for i: validity.test(offset+i); bm.set/clear(i)` loop (a hot site).
    var validity = Optional[Bitmap[HeapRegion]](None)
    var null_count = 0
    if col_ref._validity:
        var bm = Bitmap.create(num_rows)
        Bitmap.copy_bits_into(
            bm, 0, col_ref._validity.value(), offset, num_rows
        )
        null_count = num_rows - bm.popcount()
        validity = bm^

    # NULL — the Arrow layout with NO data buffer and no offsets. Every row
    # is null BY THE TYPE, so there is nothing to copy but the shape. It
    # reached the fixed-width arm before this (`arrow_fixed_byte_width` raises
    # for it, naming the type), which made a batch carrying an all-null column
    # — what the Arrow IPC decoder emits for a Null field, and what the C Data
    # Interface importer builds for format string "n" — uncopyable, hence
    # un-windowable and un-scannable.
    if at == ArrowType.NULL:
        return Column[HeapRegion](
            arrow_type=ArrowType.NULL,
            data=OwnedAlignedBuffer(0),
            offsets=None,
            validity=validity^,
            length=num_rows,
            # Per the Arrow spec (and `ipc_decoder_dispatch._build_null_column`)
            # a Null column's null_count IS its length; it carries no validity
            # bitmap that could say otherwise.
            null_count=num_rows,
            offset=0,
        )

    # VARIABLE-LENGTH — STRING / BINARY / LARGE_STRING / LARGE_BINARY, ONE arm.
    # Graded by the copy_column_ref ingress type-matrix test (every flat
    # reachable type) and a LARGE_STRING fallthrough test (offsets read at
    # Int64 stride + the buffer's byte length, which a round-trip cannot see).
    #
    # ⭐ THE PREDICATE IS THE LAYOUT CLASSIFIER, NOT A TYPE LIST.
    # `carries_offsets and not carries_children` is exactly the set of Arrow
    # layouts that are "validity + offsets + payload" and nothing else; LIST /
    # LARGE_LIST / MAP carry offsets too, but their values live in CHILD
    # columns a byte copy would drop, so they stay with the refusal below.
    # Written as a list of four type tags this arm would need editing for the
    # next varlen type; written as the classifier it does not.
    if carries_offsets(at) and not carries_children(at):
        var ow = offset_width_bytes_or_raise("copy_column_ref", at)
        if ow == 8:
            return _copy_varlen_arm[DType.int64](
                col_ref, num_rows, validity^, null_count
            )
        return _copy_varlen_arm[DType.int32](
            col_ref, num_rows, validity^, null_count
        )

    if at == ArrowType.DICTIONARY:
        # Copy the CODES at the column's own code byte width. Handles BOTH the
        # string dict shape (int32 codes + dict offsets + packed bytes) AND the
        # NUMERIC dict shape (int32/int64 codes + flat numeric dict-values
        # buffer, NO offsets, discriminated by `is_numeric_dict()`). A
        # hardcoded int32 code stride that dropped `_dict_index_byte_width` /
        # `_dict_value_dtype` would make a numeric dict column rebuilt through
        # the survivor-gather reorder lose its numeric-dict identity (and
        # mis-read int64 codes). Mirrors the `gather_batch` DICTIONARY arm.
        comptime int32_size = size_of[Int32]()
        var code_w = col_ref._dict_index_byte_width
        var idx_byte_start = offset * code_w
        var idx_byte_len = num_rows * code_w
        var idx_buf = OwnedAlignedBuffer(max(idx_byte_len, 1))
        if idx_byte_len > 0:
            idx_buf.copy_from_view(
                col_ref._data.view_range_ro(idx_byte_start, idx_byte_len)
            )
        else:
            idx_buf.set_length(0)


        var dict_offsets = Optional[OwnedAlignedBuffer](None)
        var dict_data = Optional[OwnedAlignedBuffer](None)
        if col_ref._offsets:
            ref src_offsets_buf = col_ref._offsets.value()
            var src_len = src_offsets_buf.len()
            var buf = OwnedAlignedBuffer(max(src_len, 1))
            if src_len > 0:
                buf.copy_from_view(src_offsets_buf.view_range_ro(0, src_len))
            else:
                buf.set_length(0)

            dict_offsets = buf^
        if col_ref._dict_data:
            ref src_dict_data_buf = col_ref._dict_data.value()
            var src_len = src_dict_data_buf.len()
            var buf = OwnedAlignedBuffer(max(src_len, 1))
            if src_len > 0:
                buf.copy_from_view(src_dict_data_buf.view_range_ro(0, src_len))
            else:
                buf.set_length(0)

            dict_data = buf^

        var col = Column[HeapRegion](
            arrow_type=ArrowType.DICTIONARY,
            data=idx_buf^, offsets=dict_offsets^,
            validity=validity^, length=num_rows, null_count=null_count, offset=0,
        )
        # Bridge Optional[MmapAlignedBuffer] -> Optional[SAB].
        col._set_dict_data_from_opt_oab(dict_data^)
        col._dict_size = col_ref._dict_size
        # Carry the code-width + value-dtype discriminator so the
        # rebuilt column keeps its numeric-dict identity (string dicts keep
        # width 4 / value-dtype invalid — unchanged behavior).
        col._dict_index_byte_width = code_w
        col._dict_value_dtype = col_ref._dict_value_dtype
        return col^

    if at == ArrowType.BOOL:
        var bm_bytes = (num_rows + 7) >> 3
        var data_buf = OwnedAlignedBuffer(max(bm_bytes, 1))
        data_buf.zero()
        # BOOL slice copy via `copy_bits_aligned_buffer` (memcpy-backed when
        # `offset` is byte-aligned; bit-walk fallback otherwise). Same
        # primitive the validity bitmap copy uses; both feed
        # `Bitmap.copy_bits_into`'s buffer-level core.
        copy_bits_aligned_buffer(
            data_buf, 0, col_ref._data, offset, num_rows
        )
        data_buf.set_length(Int64(bm_bytes))

        return Column[HeapRegion](
            arrow_type=ArrowType.BOOL, data=data_buf^, offsets=None,
            validity=validity^, length=num_rows, null_count=null_count, offset=0,
        )

    # Fixed-width numeric.
    #
    # ⚠ GUARD: LIST / LARGE_LIST / STRUCT / MAP / UNION_* / FIXED_SIZE_LIST
    # are unnamed by every arm above and land here — and for those a byte-width
    # table is no help, because they have no byte width at all. An 8-byte
    # `else` fallback would read n_rows*8 bytes of child payload as
    # fixed-width cells and emit `offsets=None`. Raise instead.
    #
    # ⚠ LARGE_STRING / LARGE_BINARY are served by the
    # `carries_offsets and not carries_children` arm above, at the Int64 stride
    # their type declares. Do NOT route them here: this arm is byte-stride
    # arithmetic and they have no byte width. The refusal below is still the
    # right answer for everything that owns CHILD columns.
    check_fixed_width_dispatch("copy_column_ref", at, num_rows)
    var elem_size = _elem_byte_width(at)
    var byte_start = offset * elem_size
    var byte_len = num_rows * elem_size
    var data_buf = OwnedAlignedBuffer(max(byte_len, 1))
    if byte_len > 0:
        data_buf.copy_from_view(
            col_ref._data.view_range_ro(byte_start, byte_len)
        )
    else:
        data_buf.set_length(0)

    var out = Column[HeapRegion](
        arrow_type=at, data=data_buf^, offsets=None,
        validity=validity^, length=num_rows, null_count=null_count, offset=0,
    )
    # ⛔ (p, s) IS NOT DECORATION ON A DECIMAL COLUMN — IT IS WHAT MAKES IT
    # READABLE. `Column.as_decimal128` / `as_decimal256` RAISE when precision
    # < 1, so a 16- or 32-byte slab copied without these two Ints is a column
    # whose bytes are perfect and whose only accessor refuses. The buffer-copy
    # arm above is width-correct for DECIMAL128/256 (16 / 32 bytes via
    # `arrow_fixed_byte_width`) but would drop them silently; the window
    # clone type matrix asserts the round-trip, because the window sink
    # reaches this arm for every fixed-width type.
    # Non-decimal columns carry 0/0 here, so this is unconditional by design —
    # a copy that is correct for every type beats a branch that has to be kept
    # in sync with the type list.
    out._decimal_p = col_ref._decimal_p
    out._decimal_s = col_ref._decimal_s
    return out^
