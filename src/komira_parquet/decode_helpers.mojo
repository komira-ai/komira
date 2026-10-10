# =============================================================================
# Column Decoder Helpers — array construction and type mapping
# =============================================================================
#
# Helpers of the column decoder, kept in their own module. Contains:
#   - _list_to_*_array  : List[T] -> PrimitiveArray[T] (a bulk copy from the
#                         List's own storage, never an address rebuilt from
#                         an integer).
#   - _parquet_type_to_arrow_type_opt / _schema_element_to_arrow_type /
#     schema_element_arrow_type / flba_schema_info : physical-type ->
#     Arrow-type mapping (annotation-aware).
# The nullable expansion helpers are in null_expand.mojo.
#
# SAFETY: Array helpers use UnsafePointer internally for raw-buffer writes,
# but never launder through Int. The `values` List is borrowed for the
# lifetime of the function so the compiler keeps it alive through the loop.
# =============================================================================

from std.memory import unsafe_memcpy, unsafe_memset, UnsafePointer
from std.sys import size_of

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.schema import Field
from komira_arrow.column import Column
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.heap_region import HeapRegion

from komira_parquet_api.types import ParquetType, FieldRepetitionType
from komira_parquet_api.metadata import SchemaElement
from komira_parquet_api.types import (
    CONVERTED_TYPE_BSON,
    CONVERTED_TYPE_DATE,
    CONVERTED_TYPE_DECIMAL,
    CONVERTED_TYPE_ENUM,
    CONVERTED_TYPE_INT_8,
    CONVERTED_TYPE_INT_16,
    CONVERTED_TYPE_JSON,
    CONVERTED_TYPE_UINT_8,
    CONVERTED_TYPE_UINT_16,
    CONVERTED_TYPE_UINT_32,
    CONVERTED_TYPE_UINT_64,
    CONVERTED_TYPE_UTF8,
)


# =============================================================================
# PERF-CRITICAL: Bulk bit-set for all-valid def-level pages
# =============================================================================
# Regression if removed: all-valid fast path in column_decoder falls back to
#                         per-bit OR loop (one iteration per row)
# Impact:                 O(N/8) memset vs O(N) per-bit loop
# =============================================================================


@always_inline
def _set_bits_bulk[
    o: Origin[mut=True]
](
    dst: UnsafePointer[UInt8, o],
    start_bit: Int,
    num_bits: Int,
):
    """Set `num_bits` consecutive bits starting at `start_bit` in a packed
    bitmap buffer.  When start_bit is byte-aligned, uses memset(0xFF) for
    the interior bytes, avoiding per-bit branching.

    PERF-CRITICAL: replaces a per-bit loop for all-valid def-level pages.
    A page of 1M rows is one memset of ~125KB instead of 1M individual OR
    operations.

    Origin-polymorphic: accepts any mutable origin, so a caller passes the
    tight-origin pointer of its own buffer view.
    """
    if num_bits == 0:
        return

    var first_byte = start_bit >> 3
    var first_bit = start_bit & 7
    var end_bit = start_bit + num_bits
    var last_byte = (end_bit - 1) >> 3

    if first_byte == last_byte:
        # All bits in a single byte.
        for i in range(num_bits):
            var bit_pos = first_bit + i
            (dst + first_byte)[] = (
                (dst + first_byte)[] | (UInt8(1) << UInt8(bit_pos))
            )
        return

    # Set partial first byte.
    if first_bit != 0:
        for b in range(first_bit, 8):
            (dst + first_byte)[] = (
                (dst + first_byte)[] | (UInt8(1) << UInt8(b))
            )
        first_byte += 1

    # Set partial last byte.
    var last_bit = end_bit & 7
    if last_bit != 0:
        for b in range(last_bit):
            (dst + last_byte)[] = (
                (dst + last_byte)[] | (UInt8(1) << UInt8(b))
            )
    else:
        last_byte += 1  # end_bit is byte-aligned, include last_byte.

    # Bulk memset the interior full bytes.
    var interior_bytes = last_byte - first_byte
    if interior_bytes > 0:
        unsafe_memset(dst + first_byte, 0xFF, interior_bytes)


# The ConvertedType values (parquet.thrift) this module branches on are named
# in `komira_parquet_api.types`. The four that annotate a BYTE_ARRAY column
# say what it holds: UTF8, ENUM and JSON are UTF-8 text, BSON is a binary
# document. A BYTE_ARRAY carrying none of the text ones (and no equivalent
# LogicalType union member, which the footer parser backfills into
# `converted_type`) is, per parquet.thrift, raw BINARY. This is the one
# distinction inside the BYTE_ARRAY family that the format itself carries;
# string vs large_string vs dictionary<string> is byte-identical on disk and
# is not recoverable from standard metadata.


@always_inline
def _byte_array_is_text(converted_type: Int) -> Bool:
    """True when a BYTE_ARRAY annotation says TEXT rather than raw bytes.

    ENUM and JSON join UTF8: parquet.thrift defines both as UTF-8 encoded
    byte sequences, and every mainstream reader surfaces them as a string
    type. BSON is a binary document and stays binary, like an unannotated
    BYTE_ARRAY.
    """
    return (
        converted_type == CONVERTED_TYPE_UTF8
        or converted_type == CONVERTED_TYPE_ENUM
        or converted_type == CONVERTED_TYPE_JSON
    )


# Thrift TimeUnit union field-ids carried on `SchemaElement.logical_timestamp_unit` (parsed from the modern
# LogicalType union, SchemaElement field 10).  pyarrow writes timestamps ONLY
# via the LogicalType union (converted_type=NONE), so without these a
# timestamp column surfaces as bare INT64.  The unit is value-preserving — the
# INT64 epoch storage is unchanged; only the Arrow type tag (+ tz) changes.
comptime LOGICAL_TS_UNIT_MILLIS = 1
comptime LOGICAL_TS_UNIT_MICROS = 2
comptime LOGICAL_TS_UNIT_NANOS = 3


@always_inline
def _arrow_timestamp_type_for_unit(unit: Int) -> ArrowType:
    """Map a thrift TimeUnit tag (1/2/3) to the Arrow Timestamp type.
    MILLIS -> TIMESTAMP_MS, MICROS -> TIMESTAMP_US, NANOS -> TIMESTAMP_NS."""
    if unit == LOGICAL_TS_UNIT_MILLIS:
        return ArrowType.TIMESTAMP_MS
    elif unit == LOGICAL_TS_UNIT_NANOS:
        return ArrowType.TIMESTAMP_NS
    # MICROS (and any unexpected value) -> microsecond, the parquet default.
    return ArrowType.TIMESTAMP_US


# =============================================================================
# Type conversion helpers
# =============================================================================


def _parquet_type_to_arrow_type_opt(ptype: ParquetType) -> ArrowType:
    """Convert a non-optional ParquetType to ArrowType (no annotations)."""
    if ptype == ParquetType.BOOLEAN:
        return ArrowType.BOOL
    elif ptype == ParquetType.INT32:
        return ArrowType.INT32
    elif ptype == ParquetType.INT64:
        return ArrowType.INT64
    elif ptype == ParquetType.INT96:
        # INT96 timestamps decode to Int64 nanos-since-epoch in the PLAIN
        # page loop (column_decoder), so the Arrow type is INT64.
        return ArrowType.INT64
    elif ptype == ParquetType.FLOAT:
        return ArrowType.FLOAT32
    elif ptype == ParquetType.DOUBLE:
        return ArrowType.FLOAT64
    elif ptype == ParquetType.BYTE_ARRAY:
        return ArrowType.STRING
    elif ptype == ParquetType.FIXED_LEN_BYTE_ARRAY:
        return ArrowType.BINARY
    else:
        return ArrowType.STRING


@always_inline
def _is_decimal_annotated(ptype: ParquetType, converted_type: Int) -> Bool:
    """True if this physical type + annotation is a Parquet DECIMAL column.

    DECIMAL rides on INT32 (precision <= 9), INT64 (precision <= 18),
    FIXED_LEN_BYTE_ARRAY (any precision), or BYTE_ARRAY (any precision). We
    only surface the fixed-width-backed ones (INT32/INT64/FLBA) as
    Decimal128; BYTE_ARRAY-backed decimals are vanishingly rare and stay as
    raw bytes (callers can opt in later).
    """
    if converted_type != CONVERTED_TYPE_DECIMAL:
        return False
    return (
        ptype == ParquetType.INT32
        or ptype == ParquetType.INT64
        or ptype == ParquetType.FIXED_LEN_BYTE_ARRAY
    )


def _schema_element_to_arrow_type(
    ptype: ParquetType,
    converted_type: Int,
) -> ArrowType:
    """Convert a Parquet physical type + annotation to ArrowType.

    A DECIMAL-annotated INT32 / INT64 / FIXED_LEN_BYTE_ARRAY column is surfaced
    as `ArrowType.DECIMAL128` (the precision/scale ride on the `Field` — see
    `field_from_schema_element`). Everything else maps by physical type.

    Args:
        ptype: Parquet physical type.
        converted_type: Raw Thrift ConvertedType value, or -1 if absent.

    Returns:
        The Arrow type that `_decode_column_pages` will produce.
    """
    if _is_decimal_annotated(ptype, converted_type):
        return ArrowType.DECIMAL128
    # Same-storage-width logical re-labels (UINT_32 / UINT_64 / DATE) +
    # storage-narrowing re-labels (INT_8/16, UINT_8/16 -> 1/2-byte Arrow).
    # The narrow-int ArrowType is correct for the
    # schema Field; `_narrow_int_logical_type` narrows the decoded INT32 buffer
    # to match this width.
    if ptype == ParquetType.INT32:
        if converted_type == CONVERTED_TYPE_UINT_32:
            return ArrowType.UINT32
        elif converted_type == CONVERTED_TYPE_DATE:
            return ArrowType.DATE32
        elif converted_type == CONVERTED_TYPE_INT_8:
            return ArrowType.INT8
        elif converted_type == CONVERTED_TYPE_INT_16:
            return ArrowType.INT16
        elif converted_type == CONVERTED_TYPE_UINT_8:
            return ArrowType.UINT8
        elif converted_type == CONVERTED_TYPE_UINT_16:
            return ArrowType.UINT16
    elif ptype == ParquetType.INT64:
        if converted_type == CONVERTED_TYPE_UINT_64:
            return ArrowType.UINT64
    elif ptype == ParquetType.BYTE_ARRAY:
        # UTF8/ENUM/JSON -> STRING; BSON and an UNANNOTATED BYTE_ARRAY are
        # raw BINARY, per parquet.thrift.
        if _byte_array_is_text(converted_type):
            return ArrowType.STRING
        return ArrowType.BINARY
    return _parquet_type_to_arrow_type_opt(ptype)


@always_inline
def schema_element_arrow_type(elem: SchemaElement) -> ArrowType:
    """Arrow type a SchemaElement will decode into (annotation-aware)."""
    if not elem.type:
        return ArrowType.STRING  # group node
    # A LogicalType TIMESTAMP rides INT64
    # physical; surface it as the unit-correct Arrow Timestamp type.  Takes
    # precedence over the physical-type mapping (the ConvertedType path lacks
    # the NANOS unit + tz flag).
    if elem.type.value() == ParquetType.INT64 and elem.logical_timestamp_unit:
        return _arrow_timestamp_type_for_unit(
            elem.logical_timestamp_unit.value()
        )
    var ct = -1
    if elem.converted_type:
        ct = elem.converted_type.value()
    return _schema_element_to_arrow_type(elem.type.value(), ct)


@always_inline
def _relabel_int_logical_type(
    var col: Column[HeapRegion],
    ptype: ParquetType,
    converted_type: Int,
) raises -> Column[HeapRegion]:
    """Re-stamp a decoded INT32/INT64 column's Arrow type from its
    same-storage-width logical annotation (UINT_32, UINT_64, DATE).

    The decode primitives build unsigned and DATE columns as signed
    INT32/INT64 PrimitiveArrays because Parquet's physical type is
    INT32/INT64.  The stored 2's-complement bytes are bit-identical to the
    Arrow unsigned / DATE32 representation, so only the `arrow_type`
    discriminator needs correcting — no re-decode, no byte movement.  This
    is the read-side fix for the UINT_32 / UINT_64 silent sign-corruption
    (an unsigned value crossing the signed boundary surfaced as a negative
    number under `as_primitive[int32/int64]`).

    Kept in sync with `_schema_element_to_arrow_type` so the column's
    arrow_type matches the schema Field's arrow_type (otherwise
    `RecordBatch.column_arrow_type` logs a mismatch warning).  Only fires
    when the column currently carries the bare physical Arrow type
    (INT32 / INT64); DECIMAL columns are already DECIMAL128 upstream and
    are left untouched.
    """
    if converted_type < 0:
        return col^
    if ptype == ParquetType.INT32 and col.arrow_type == ArrowType.INT32:
        if converted_type == CONVERTED_TYPE_UINT_32:
            col.arrow_type = ArrowType.UINT32
        elif converted_type == CONVERTED_TYPE_DATE:
            col.arrow_type = ArrowType.DATE32
    elif ptype == ParquetType.INT64 and col.arrow_type == ArrowType.INT64:
        if converted_type == CONVERTED_TYPE_UINT_64:
            col.arrow_type = ArrowType.UINT64
    return col^


@always_inline
def _relabel_byte_array_binary(
    var col: Column[HeapRegion],
    ptype: ParquetType,
    converted_type: Int,
) raises -> Column[HeapRegion]:
    """Re-stamp a decoded BYTE_ARRAY column as BINARY when the schema carries
    no text annotation.

    The BYTE_ARRAY decode
    primitives always build a `StringArray` (Parquet has one variable-length
    physical type and the decoder does not read the annotation), so an
    UNANNOTATED BYTE_ARRAY column arrives here tagged STRING.

    THIS IS A PURE TAG SWAP AND IS ALLOWED TO BE: `Column.from_string` and
    `Column.from_binary` build the IDENTICAL three buffers -- i32 offsets,
    raw data bytes, optional validity bitmap -- and differ only in the
    `arrow_type` discriminator. No re-decode, no byte movement, validity
    untouched. (That is NOT true of the other two members of this family:
    LARGE_STRING needs i64 offsets and DICTIONARY needs an indices array, so
    neither can be reached by relabelling.)

    Kept in sync with `_schema_element_to_arrow_type` so the Column's
    arrow_type matches the schema Field's -- otherwise
    `RecordBatch.column_arrow_type` logs a mismatch warning and, worse, the
    C-Data export reads the wrong buffer widths.

    Only fires when the column currently carries the bare STRING tag; a
    DICTIONARY-typed column (the `preserve_dict` path) is left alone.
    """
    if ptype != ParquetType.BYTE_ARRAY:
        return col^
    if col.arrow_type != ArrowType.STRING:
        return col^
    if _byte_array_is_text(converted_type):
        return col^
    col.arrow_type = ArrowType.BINARY
    return col^


def _narrow_int32_column[
    target_dtype: DType
](
    col: Column[HeapRegion],
    arrow_type: ArrowType,
) raises -> Column[HeapRegion]:
    """Narrow a decoded INT32 `Column` into a `target_dtype` (int8/int16/
    uint8/uint16) `Column`, preserving validity and per-row values.

    The decode primitives build the column as a 4-byte signed INT32
    PrimitiveArray (Parquet's physical type for INT_8/16 + UINT_8/16).  Arrow
    INT8/INT16/UINT8/UINT16 are 1/2-byte storage, so this performs a real
    storage NARROWING (not a tag swap): each value is truncated to the target
    width.  The low byte(s) of the 2's-complement INT32 are bit-identical to
    the target Arrow representation for every value in the valid domain
    (i8 -128..127, u8 0..255, i16 MIN..MAX, u16 0..65535) — `Scalar` truncation
    keeps exactly those bits.  Null slots keep their truncated bytes (harmless;
    the validity bit marks them null) and the validity bitmap carries over via
    `from_primitive_with_arrow_type`.
    """
    var src = col.as_primitive[DType.int32]()
    var n = src.length
    var out = PrimitiveArray[target_dtype].allocate(n)
    for i in range(n):
        # Scalar[target] truncates the INT32 to the narrow width (low byte(s));
        # value-byte-exact for the in-range domain of each narrow type.
        out.set(i, Scalar[target_dtype](src.get(i)))
    # Re-attach the source validity (allocate() built a non-nullable array; the
    # narrow column must carry the same nulls as the decoded INT32 column).
    if src.validity:
        var bm_len = src.validity.value().length
        var bm = Bitmap.create(bm_len)
        var bm_bytes = (bm_len + 7) >> 3
        if bm_bytes > 0:
            bm.buffer.copy_from_view(
                src.validity.value().buffer.view_range_ro(0, bm_bytes)
            )
            bm.buffer.set_length(bm_bytes)
        out.validity = bm^
        out.null_count = src.null_count
    return Column.from_primitive_with_arrow_type[target_dtype](out, arrow_type)


@always_inline
def _narrow_int_logical_type(
    var col: Column[HeapRegion],
    ptype: ParquetType,
    converted_type: Int,
) raises -> Column[HeapRegion]:
    """Narrow a decoded INT32 column to a 1/2-byte Arrow int from its
    INT_8 / INT_16 / UINT_8 / UINT_16 ConvertedType annotation.

    Completes the read-path type fidelity of UINT_32/64, DATE32 and
    TIMESTAMP.  Unlike those
    same-storage-width re-labels, INT_8/16 + UINT_8/16 are 4-byte INT32 physical
    columns whose faithful Arrow surface is a 1/2-byte storage type, so this
    NARROWS the buffer (see `_narrow_int32_column`).  Only fires on an INT32
    physical column still carrying the bare INT32 Arrow type (DECIMAL / UINT_32
    / DATE columns are already re-typed upstream); a no-op otherwise.  Applied
    at every read funnel alongside `_relabel_int_logical_type` so a filtered /
    gathered narrow-int column is narrowed too.
    """
    if converted_type < 0:
        return col^
    if ptype != ParquetType.INT32 or col.arrow_type != ArrowType.INT32:
        return col^
    if converted_type == CONVERTED_TYPE_INT_8:
        return _narrow_int32_column[DType.int8](col, ArrowType.INT8)
    elif converted_type == CONVERTED_TYPE_INT_16:
        return _narrow_int32_column[DType.int16](col, ArrowType.INT16)
    elif converted_type == CONVERTED_TYPE_UINT_8:
        return _narrow_int32_column[DType.uint8](col, ArrowType.UINT8)
    elif converted_type == CONVERTED_TYPE_UINT_16:
        return _narrow_int32_column[DType.uint16](col, ArrowType.UINT16)
    return col^


@always_inline
def _relabel_timestamp_logical_type(
    var col: Column[HeapRegion],
    ptype: ParquetType,
    timestamp_unit: Int,
) raises -> Column[HeapRegion]:
    """Re-stamp a decoded INT64 column as the unit-correct Arrow Timestamp.

    pyarrow writes timestamps via
    the modern LogicalType union with converted_type=NONE, so the decode
    primitives build a plain INT64 PrimitiveArray (Parquet's physical type).
    Timestamps are INT64-backed in Arrow too — the stored epoch values are
    bit-identical — so only the `arrow_type` discriminator needs correcting
    to TIMESTAMP_MS/US/NS.  No re-decode, no byte movement.  Kept in sync with
    `schema_element_arrow_type` so the column arrow_type matches the schema
    Field's (otherwise `RecordBatch.column_arrow_type` logs a mismatch).  Only
    fires when the column currently carries the bare INT64 Arrow type and a
    LogicalType TIMESTAMP unit was parsed (`timestamp_unit` 1/2/3); -1/0 = not
    a timestamp.
    """
    if timestamp_unit <= 0:
        return col^
    if ptype == ParquetType.INT64 and col.arrow_type == ArrowType.INT64:
        col.arrow_type = _arrow_timestamp_type_for_unit(timestamp_unit)
    return col^


@always_inline
def schema_element_decimal_ps(elem: SchemaElement) -> Tuple[Int, Int]:
    """Return (precision, scale) for a DECIMAL-annotated SchemaElement.

    Returns (0, 0) if the element is not a recognised DECIMAL column. When the
    DECIMAL annotation omits an explicit precision (spec-legal but rare), the
    precision is derived from the backing byte width by the decode primitives
    (`decimal_decode._resolve_precision`); here we just pass through what the
    schema declares (or 0).
    """
    if not elem.type:
        return (0, 0)
    var ct = -1
    if elem.converted_type:
        ct = elem.converted_type.value()
    if not _is_decimal_annotated(elem.type.value(), ct):
        return (0, 0)
    var precision = 0
    if elem.precision:
        precision = elem.precision.value()
    var scale = 0
    if elem.scale:
        scale = elem.scale.value()
    return (precision, scale)


@always_inline
def field_from_schema_element(elem: SchemaElement) raises -> Field:
    """Build the Arrow `Field` for a Parquet leaf SchemaElement.

    For DECIMAL-annotated INT32/INT64/FLBA columns this returns
    `Field.decimal128(name, precision, scale, nullable)`; for everything else
    it returns a plain `Field(name, arrow_type, nullable)`.

    Nullable iff the repetition type is not REQUIRED (matches the existing
    schema-builder logic across the parquet read paths).
    """
    var name = elem.name
    var arrow_type = schema_element_arrow_type(elem)
    var nullable = True
    if elem.repetition_type:
        if elem.repetition_type.value() == FieldRepetitionType.REQUIRED:
            nullable = False
    # Build a tz-carrying Timestamp Field so
    # the IANA tz ("UTC" when isAdjustedToUTC) rides the Field's `_tz` slot.
    if arrow_type.is_timestamp():
        var tz = String("")
        if elem.logical_timestamp_is_utc:
            if elem.logical_timestamp_is_utc.value():
                tz = String("UTC")
        return Field.timestamp(name, arrow_type, tz, nullable)
    if arrow_type == ArrowType.DECIMAL128:
        var ps = schema_element_decimal_ps(elem)
        var p = ps[0]
        var s = ps[1]
        # If the schema omitted precision, derive a safe upper bound from the
        # backing byte width so the Field carries a valid (1..38) precision.
        if p < 1:
            var tl = 0
            if elem.type_length:
                tl = elem.type_length.value()
            if elem.type.value() == ParquetType.INT32:
                p = 9
            elif elem.type.value() == ParquetType.INT64:
                p = 18
            elif tl >= 16:
                p = 38
            elif tl == 8:
                p = 18
            elif tl == 4:
                p = 9
            elif tl >= 1:
                # floor(log10(2^(tl*8-1)-1)); a couple of pessimistic
                # rounds for the odd widths is harmless (precision >= scale).
                p = max(1, (tl * 8 - 1) // 4)
            else:
                p = 38
        if s > p:
            s = p
        return Field.decimal128(name, p, s, nullable)
    return Field(name, arrow_type, nullable)


@always_inline
def flba_schema_info(elem: SchemaElement) -> Tuple[Int, Int, Int, Int]:
    """Return (type_length, converted_type, scale, precision) from a
    SchemaElement.

    Missing fields are returned as `0` for type_length/scale/precision and
    `-1` for converted_type.
    """
    var type_length = 0
    if elem.type_length:
        type_length = elem.type_length.value()
    var converted_type = -1
    if elem.converted_type:
        converted_type = elem.converted_type.value()
    var scale = 0
    if elem.scale:
        scale = elem.scale.value()
    var precision = 0
    if elem.precision:
        precision = elem.precision.value()
    return (type_length, converted_type, scale, precision)


# =============================================================================
# Array construction helpers
# =============================================================================


def _list_to_int32_array(
    values: List[Int32],
) -> PrimitiveArray[DType.int32]:
    """Convert a List[Int32] to a PrimitiveArray[DType.int32].

    PERF-CRITICAL: bulk `memcpy` replaces the per-element
    scalar copy loop. memcpy is libc SIMD-accelerated (NEON vld1/vst1 on
    ARM) and several times faster than scalar stores; Mojo does not
    auto-vectorize the `(out+i)[] = (src+i)[]` pattern.

    SAFETY: `values` is borrowed for
    the function body; its backing storage stays alive until we return.
    `values.unsafe_ptr()` returns a typed pointer tied to that borrow, and
    memcpy takes both pointers as UnsafePointer arguments — no laundering
    through Int, no wildcard origins. An address rebuilt from an integer
    would not keep the List alive; this borrow does.
    """
    var n = len(values)
    comptime int32_size = size_of[Scalar[DType.int32]]()
    var byte_count = n * int32_size
    var buf = OwnedAlignedBuffer(max(byte_count, 1))
    if n > 0:
        # Dest via origin-tied `view_range_mut` on the buffer.
        var dst_view = buf.view_range_mut(0, byte_count)
        # SAFETY: bounded; view alive.
        unsafe_memcpy(
            dest=dst_view._unsafe_ptr(),
            src=values.unsafe_ptr().bitcast[UInt8](),
            count=byte_count,
        )
    buf.set_length(Int64(byte_count))

    return PrimitiveArray[DType.int32](buf^, n, None, 0, 0)


def _list_to_int32_array_from_values(
    values: List[Int32],
) -> PrimitiveArray[DType.int32]:
    """Convert accumulated Int32 values to a PrimitiveArray."""
    return _list_to_int32_array(values)


def _list_to_int64_array_from_values(
    values: List[Int64],
) -> PrimitiveArray[DType.int64]:
    """Convert accumulated Int64 values to a PrimitiveArray.

    PERF-CRITICAL: bulk memcpy — see `_list_to_int32_array` docstring for
    the full rationale. Falls back to a SIMD-accelerated libc memcpy on
    ARM NEON (ldp q/stp q pairs) instead of a scalar Int64 copy.
    """
    var n = len(values)
    comptime int64_size = size_of[Scalar[DType.int64]]()
    var byte_count = n * int64_size
    var buf = OwnedAlignedBuffer(max(byte_count, 1))
    if n > 0:
        # Dest via origin-tied `view_range_mut`.
        var dst_view = buf.view_range_mut(0, byte_count)
        unsafe_memcpy(
            dest=dst_view._unsafe_ptr(),
            src=values.unsafe_ptr().bitcast[UInt8](),
            count=byte_count,
        )
    buf.set_length(Int64(byte_count))

    return PrimitiveArray[DType.int64](buf^, n, None, 0, 0)


def _list_to_float32_array_from_values(
    values: List[Float32],
) -> PrimitiveArray[DType.float32]:
    """Convert accumulated Float32 values to a PrimitiveArray.

    PERF-CRITICAL: bulk memcpy — see `_list_to_int32_array` docstring.
    """
    var n = len(values)
    comptime f32_size = size_of[Scalar[DType.float32]]()
    var byte_count = n * f32_size
    var buf = OwnedAlignedBuffer(max(byte_count, 1))
    if n > 0:
        # Dest via origin-tied `view_range_mut`.
        var dst_view = buf.view_range_mut(0, byte_count)
        unsafe_memcpy(
            dest=dst_view._unsafe_ptr(),
            src=values.unsafe_ptr().bitcast[UInt8](),
            count=byte_count,
        )
    buf.set_length(Int64(byte_count))

    return PrimitiveArray[DType.float32](buf^, n, None, 0, 0)


def _list_to_float64_array_from_values(
    values: List[Float64],
) -> PrimitiveArray[DType.float64]:
    """Convert accumulated Float64 values to a PrimitiveArray.

    PERF-CRITICAL: bulk memcpy — see `_list_to_int32_array` docstring.
    """
    var n = len(values)
    comptime f64_size = size_of[Scalar[DType.float64]]()
    var byte_count = n * f64_size
    var buf = OwnedAlignedBuffer(max(byte_count, 1))
    if n > 0:
        # Dest via origin-tied `view_range_mut`.
        var dst_view = buf.view_range_mut(0, byte_count)
        unsafe_memcpy(
            dest=dst_view._unsafe_ptr(),
            src=values.unsafe_ptr().bitcast[UInt8](),
            count=byte_count,
        )
    buf.set_length(Int64(byte_count))

    return PrimitiveArray[DType.float64](buf^, n, None, 0, 0)
