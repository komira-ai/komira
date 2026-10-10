# =============================================================================
# Nullable column expansion — dense decoded values scattered into nullable
# arrays by their definition-level bits
# =============================================================================
#
# The column decoder decodes only the non-null values of a page. These helpers
# place them at their rows: `_expand_with_nulls_*` (one per decoded array
# type) reads the definition-level bits (1 = valid, LSB-first), copies them
# into the output's validity bitmap and scatters the dense values to the set
# bits; `_all_null_primitive` / `_all_null_binary` build a column with no live
# value at all.
#
# SAFETY: the helpers take the definition-level bits as a pointer into the
# caller's bit buffer, which must hold at least `total` bits and outlive the
# call; every read of it is bounded by `total`. They never launder an address
# through Int.
# =============================================================================

from std.memory import unsafe_memcpy, UnsafePointer
from std.sys import size_of

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.bitmap import Bitmap
from komira_arrow.binary_array import BinaryArray
from komira_arrow.string_array import StringArray
from komira_arrow.boolean_array import BooleanArray
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.heap_region import HeapRegion
from komira_arrow.decimal_array import Decimal128Array, DECIMAL128_BYTE_WIDTH


# =============================================================================
# Nullable column expansion helpers
# =============================================================================


@always_inline
def _def_bit_is_set[
    o: Origin[mut=True]
](
    def_bits: UnsafePointer[UInt8, o], i: Int
) -> Bool:
    """Read a single definition-level bit from a little-endian bit-packed
    buffer. Bit `i` lives at `byte (i >> 3)`, position `(i & 7)`, with
    bit 0 as the least significant bit -- matching Bitmap layout.

    Origin-polymorphic: accepts any mutable origin, so callers pass the
    tight-origin pointer of their own buffer. The `mut=True`
    requirement mirrors the existing caller shape — swap to a bool-gated
    origin later if read-only callers appear.
    """
    var byte_idx = i >> 3
    var bit_idx = i & 7
    return ((def_bits + byte_idx)[] >> UInt8(bit_idx)) & UInt8(1) != UInt8(0)


# =============================================================================
# PERF-CRITICAL: _expand_with_nulls_* fast path
# =============================================================================
# allocate_nullable() returns an array whose data buffer is zero-filled AND
# whose validity bitmap is ALL-VALID (bits = 1). `def_bits` has exactly the
# layout we want for the output validity bitmap: 1 = valid, 0 = null, LSB-
# first — same as our Bitmap. So we memcpy the def_bits into the validity
# buffer in one shot (instead of a per-bit set/clear loop), compute the
# null_count via popcount, and scatter only the valid values.
#
# The scatter (val_idx++ when bit set) is inherently serial; we keep it
# scalar but skip the branch to touch the validity bitmap on every row.
# Output data for null slots stays zero (allocate_nullable already zeroed).
# =============================================================================


@always_inline
def _copy_def_bits_to_validity[
    o: Origin[mut=True]
](
    mut arr_validity: Bitmap[HeapRegion],
    def_bits: UnsafePointer[UInt8, o],
    total: Int,
):
    """Replace an all-valid validity bitmap's bytes with def_bits.

    Both are LSB-first bit-packed with `total` bits. memcpy the whole-byte
    run; the trailing bits in the last byte past `total` must be cleared
    (create_all_valid already did this, but the memcpy may reintroduce
    garbage if def_bits' trailing bits aren't clean).
    """
    var num_bytes = (total + 7) >> 3
    if num_bytes == 0:
        return
    # SAFETY: the bitmap was created for `total` bits, so its buffer holds at
    # least `num_bytes`; `dest_view` borrows it mutably for the copy and the
    # trailing-bit fix below.
    var dest_view = arr_validity.buffer.view_mut()
    var dest = dest_view._unsafe_ptr()
    unsafe_memcpy(dest=dest, src=def_bits, count=num_bytes)
    # Clear trailing bits past `total` in the final byte.
    var trailing = total & 7
    if trailing > 0:
        var mask = UInt8((1 << trailing) - 1)
        var last = dest + num_bytes - 1
        last[] = last[] & mask


def _expand_with_nulls_int32[
    o: Origin[mut=True]
](
    values: PrimitiveArray[DType.int32],
    def_bits: UnsafePointer[UInt8, o],
    total: Int,
) -> PrimitiveArray[DType.int32]:
    """Expand a dense array using bit-packed definition levels to insert
    nulls. `def_bits` is a bit-packed buffer with `total` valid bits
    (1 = valid value, 0 = null); it is borrowed for the call and must
    outlive this function in the caller's scope."""
    var arr = PrimitiveArray[DType.int32].allocate_nullable(total)
    _copy_def_bits_to_validity(arr.validity.value(), def_bits, total)
    var val_view = values.view_ro()
    var val_ptr = val_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
    var out_view = arr.view_mut()
    var out_ptr = out_view._unsafe_ptr().bitcast[Scalar[DType.int32]]()
    var val_idx = 0

    # Scatter only the valid values. Null slots stay zero (allocate_nullable
    # zero-filled the data buffer). NOT-VECTORIZABLE: val_idx++ on each
    # set bit is a serial RAW dependency chain.
    for i in range(total):
        if _def_bit_is_set(def_bits, i) and val_idx < values.length:
            (out_ptr + i)[] = (val_ptr + val_idx)[]
            val_idx += 1

    arr.null_count = total - arr.validity.value().popcount()
    return arr^


def _expand_with_nulls_int64[
    o: Origin[mut=True]
](
    values: PrimitiveArray[DType.int64],
    def_bits: UnsafePointer[UInt8, o],
    total: Int,
) -> PrimitiveArray[DType.int64]:
    """Expand a dense Int64 array with nulls from bit-packed definition
    levels. See `_expand_with_nulls_int32` for the bit layout contract."""
    var arr = PrimitiveArray[DType.int64].allocate_nullable(total)
    _copy_def_bits_to_validity(arr.validity.value(), def_bits, total)
    var val_view = values.view_ro()
    var val_ptr = val_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
    var out_view = arr.view_mut()
    var out_ptr = out_view._unsafe_ptr().bitcast[Scalar[DType.int64]]()
    var val_idx = 0

    for i in range(total):
        if _def_bit_is_set(def_bits, i) and val_idx < values.length:
            (out_ptr + i)[] = (val_ptr + val_idx)[]
            val_idx += 1

    arr.null_count = total - arr.validity.value().popcount()
    return arr^


def _expand_with_nulls_float32[
    o: Origin[mut=True]
](
    values: PrimitiveArray[DType.float32],
    def_bits: UnsafePointer[UInt8, o],
    total: Int,
) -> PrimitiveArray[DType.float32]:
    """Expand a dense Float32 array with nulls from bit-packed definition
    levels. See `_expand_with_nulls_int32` for the bit layout contract."""
    var arr = PrimitiveArray[DType.float32].allocate_nullable(total)
    _copy_def_bits_to_validity(arr.validity.value(), def_bits, total)
    var val_view = values.view_ro()
    var val_ptr = val_view._unsafe_ptr().bitcast[Scalar[DType.float32]]()
    var out_view = arr.view_mut()
    var out_ptr = out_view._unsafe_ptr().bitcast[Scalar[DType.float32]]()
    var val_idx = 0

    for i in range(total):
        if _def_bit_is_set(def_bits, i) and val_idx < values.length:
            (out_ptr + i)[] = (val_ptr + val_idx)[]
            val_idx += 1

    arr.null_count = total - arr.validity.value().popcount()
    return arr^


def _expand_with_nulls_float64[
    o: Origin[mut=True]
](
    values: PrimitiveArray[DType.float64],
    def_bits: UnsafePointer[UInt8, o],
    total: Int,
) -> PrimitiveArray[DType.float64]:
    """Expand a dense Float64 array with nulls from bit-packed definition
    levels. See `_expand_with_nulls_int32` for the bit layout contract."""
    var arr = PrimitiveArray[DType.float64].allocate_nullable(total)
    _copy_def_bits_to_validity(arr.validity.value(), def_bits, total)
    var val_view = values.view_ro()
    var val_ptr = val_view._unsafe_ptr().bitcast[Scalar[DType.float64]]()
    var out_view = arr.view_mut()
    var out_ptr = out_view._unsafe_ptr().bitcast[Scalar[DType.float64]]()
    var val_idx = 0

    for i in range(total):
        if _def_bit_is_set(def_bits, i) and val_idx < values.length:
            (out_ptr + i)[] = (val_ptr + val_idx)[]
            val_idx += 1

    arr.null_count = total - arr.validity.value().popcount()
    return arr^


def _expand_with_nulls_decimal128[
    o: Origin[mut=True]
](
    values: Decimal128Array[HeapRegion],
    def_bits: UnsafePointer[UInt8, o],
    total: Int,
) raises -> Decimal128Array[HeapRegion]:
    """Expand a dense Decimal128Array[HeapRegion] with nulls from bit-packed definition
    levels. See `_expand_with_nulls_int32` for the bit layout contract.

    `values` holds the `popcount(def_bits)` non-null unscaled i128s in order;
    `total` is the output element count (valid + null). Null slots stay zero
    (allocate_nullable zero-fills) and `(precision, scale)` carry over.
    """
    var arr = Decimal128Array.allocate_nullable(
        total, values.precision, values.scale
    )
    _copy_def_bits_to_validity(arr.validity.value(), def_bits, total)
    var val_idx = 0
    for i in range(total):
        if _def_bit_is_set(def_bits, i) and val_idx < values.length:
            arr.data.write_i128_le_at(
                i * DECIMAL128_BYTE_WIDTH,
                values.data.read_i128_le_at(val_idx * DECIMAL128_BYTE_WIDTH),
            )
            val_idx += 1
    arr.null_count = total - arr.validity.value().popcount()
    return arr^


def _expand_with_nulls_string[
    o: Origin[mut=True]
](
    values: StringArray[HeapRegion],
    def_bits: UnsafePointer[UInt8, o],
    total: Int,
) raises -> StringArray[HeapRegion]:
    """Expand a dense StringArray with nulls from bit-packed definition levels.

    `values` holds the `popcount(def_bits)` non-null strings in order;
    `total` is the output element count (valid + null). For each output
    position `i`, if def-bit `i` is set the next dense value is placed at
    `i`; otherwise position `i` is NULL (validity bit cleared, empty slot).
    Mirrors `_expand_with_nulls_int32` but for the variable-width BYTE_ARRAY
    layout — without this, nullable STRING columns silently drop their null
    rows (the dense decode produces only the non-null values, so the column
    comes back short by `total - popcount` rows). See the bit layout contract
    in `_expand_with_nulls_int32`.

    NOT-VECTORIZABLE: `val_idx++` on each set bit is a serial RAW dependency
    chain, and the variable-width copy is inherent to the string layout.
    Building `List[String]` + `List[Bool]` and delegating to
    `StringArray.from_strings_with_validity` keeps the offsets/validity
    construction in one audited place.
    """
    var out_vals = List[String](capacity=total)
    var out_valid = List[Bool](capacity=total)
    var val_idx = 0
    for i in range(total):
        if _def_bit_is_set(def_bits, i) and val_idx < values.length:
            out_vals.append(values.get(val_idx))
            out_valid.append(True)
            val_idx += 1
        else:
            out_vals.append(String(""))
            out_valid.append(False)
    return StringArray.from_strings_with_validity(out_vals, out_valid)


def _expand_with_nulls_boolean[
    o: Origin[mut=True]
](
    dense: Bitmap[HeapRegion],
    dense_count: Int,
    def_bits: UnsafePointer[UInt8, o],
    total: Int,
) raises -> BooleanArray:
    """Expand a dense bit-packed boolean run with nulls from def levels.

    `dense` holds the `popcount(def_bits)` non-null boolean values packed
    LSB-first in its first `dense_count` bits; `total` is the output element
    count (valid + null). For each output position `i`, if def-bit `i` is set
    the next dense value is scattered to position `i`; otherwise position `i`
    is NULL (validity bit cleared, value left False). Mirrors
    `_expand_with_nulls_int32` for the BOOLEAN physical type — without this,
    nullable BOOLEAN columns both DROP their null rows (the dense decode
    produces only the non-null values, contiguous from 0) and never surface a
    validity bitmap.

    NOT-VECTORIZABLE: `val_idx++` on each set bit is a serial RAW chain.
    """
    var arr = BooleanArray.allocate_nullable(total)
    _copy_def_bits_to_validity(arr.validity.value(), def_bits, total)
    var val_idx = 0
    for i in range(total):
        if _def_bit_is_set(def_bits, i) and val_idx < dense_count:
            if dense.test(val_idx):
                arr.set(i, True)
            val_idx += 1
    arr.null_count = total - arr.validity.value().popcount()
    return arr^


# =============================================================================
# ALL-NULL COLUMN CONSTRUCTORS
# =============================================================================
#
# ⛔ THESE EXIST BECAUSE "NO VALUES" AND "NO ROWS" ARE DIFFERENT THINGS AND THE
# READER USED TO CONFLATE THEM. A column chunk whose every row is NULL decodes
# ZERO values, so none of `_decode_column_pages`'s value accumulators fires and
# assembly reached its "return an empty column of the right type" fallback —
# which built a LENGTH-0 array and dropped the definition levels that said the
# chunk had N rows. `RecordBatchBuilder.build` then refused the whole batch
# (`column N has length 0, expected <rows>`), taking down queries that never
# named the column.
#
# ⭐ THE OTHER WIDTHS DO NOT NEED A CONSTRUCTOR HERE: `_expand_with_nulls_*`
# above already produces exactly this shape when handed a ZERO-LENGTH dense
# array (the scatter loop's `val_idx < values.length` is never true, so every
# output row is left null), and reusing them is strictly preferable to a second
# implementation of the same layout. These two cover the widths that have no
# `_expand_with_nulls_*` sibling: the narrow ints, whose parquet storage is
# INT32 but whose Arrow storage is 1 or 2 bytes, and BINARY.
# =============================================================================


def _all_null_primitive[dtype: DType](total: Int) -> PrimitiveArray[dtype]:
    """A `total`-row PrimitiveArray in which EVERY row is NULL.

    `Bitmap.create` zeroes, so the validity bitmap is all-clear and
    `null_count == total`; the data buffer is zeroed and is never read,
    because no consumer may read a slot whose validity bit is clear.

    ⚠ CALLERS MUST HAVE ESTABLISHED THAT NO VALUE WAS DECODED. This takes no
    definition levels and therefore cannot honour a set one — it is the
    zero-live-value case only. `_decode_column_pages` proves that by counting
    the live def-level bits before it calls this.
    """
    comptime elem_size = size_of[Scalar[dtype]]()
    var buf = OwnedAlignedBuffer(max(total, 1) * elem_size)
    buf.zero()
    buf.set_length(Int64(total * elem_size))
    var bm = Bitmap.create(total)
    return PrimitiveArray[dtype](buf^, total, bm^, total, 0)


def _all_null_binary(total: Int) raises -> BinaryArray[HeapRegion]:
    """A `total`-row BinaryArray in which EVERY row is NULL.

    Per Arrow, a null variable-width row still occupies an `(offset,
    length=0)` slot, so the offsets buffer is N+1 zeros over an empty data
    buffer. Same contract as `_all_null_primitive`: zero live values.
    """
    var offsets = List[Int32](capacity=total + 1)
    for _ in range(total + 1):
        offsets.append(Int32(0))
    var bm = Bitmap.create(total)
    return BinaryArray.from_buffers(
        offsets, List[UInt8](), Optional[Bitmap[HeapRegion]](bm^), total
    )
