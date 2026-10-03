# =============================================================================
# IPC — Simple binary serialization for RecordBatch (Komira internal format)
# =============================================================================
#
# This is a simplified binary format for serializing/deserializing
# RecordBatches of PrimitiveArrays. It is NOT the Arrow IPC spec (which
# uses Flatbuffers). It provides the ability to serialize/deserialize
# RecordBatches for inter-process communication within Komira.
#
# Wire format:
#   Header:
#     4 bytes: magic "THRM"
#     4 bytes: num_columns (Int32, little-endian)
#     4 bytes: num_rows (Int32, little-endian)
#     Per column:
#       1 byte:  ArrowType type_id
#       4 bytes: buffer_length (data buffer size in bytes, Int32 LE)
#       1 byte:  has_validity (0 or 1)
#       4 bytes: validity_length (bitmap bytes, 0 if no validity, Int32 LE)
#   Body:
#     Per column:
#       data buffer bytes (padded to 64-byte alignment)
#       validity buffer bytes (padded to 64-byte alignment, if present)
#
# Alignment padding uses zero bytes. The 64-byte alignment matches Arrow's
# recommended buffer alignment for SIMD operations.
# =============================================================================

from std.memory import unsafe_memcpy, unsafe_memset, alloc
from std.sys import size_of

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_arrow.arrow_types import ArrowType
from komira_buffer.heap_region import HeapRegion
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, Schema, SchemaBuilder, RecordBatch, RecordBatchBuilder
from komira_collections.slab import Slab
from komira_buffer.byte_view import ByteView


# --- Magic bytes ---
# "THRM" as 4 bytes
comptime MAGIC_T = UInt8(0x54)  # 'T'
comptime MAGIC_H = UInt8(0x48)  # 'H'
comptime MAGIC_R = UInt8(0x52)  # 'R'
comptime MAGIC_M = UInt8(0x4D)  # 'M'


@always_inline
def _align_to_64(size: Int) -> Int:
    """Round up to next 64-byte boundary (bitwise, no division)."""
    return (size + 63) & ~63


# _write_int32_le / _read_int32_le take ByteView signatures (not
# wildcard-origin raw pointers), routing origin tracking through the
# caller's buffer.

@always_inline
def _write_int32_le(view: ByteView[mut=True, _], offset: Int, value: Int32):
    """Write an Int32 in little-endian format at the given byte offset.

    Uses ByteView's bounds-checked typed write to stay within the caller's
    buffer; no raw pointer arithmetic crosses the helper boundary.
    """
    view.write_i32_le_at(offset, value)


@always_inline
def _read_int32_le(view: ByteView[_], offset: Int) -> Int32:
    """Read an Int32 in little-endian format from the given byte offset.

    Uses ByteView's bounds-checked typed read; no raw pointer arithmetic
    crosses the helper boundary.
    """
    return view.read_i32_le_at(offset)


def serialize_primitive_batch(batch: RecordBatch) raises -> SharedAlignedBuffer[HeapRegion]:
    """Serialize a RecordBatch of PrimitiveArrays to bytes.

    The batch must contain only fixed-width primitive columns (INT8 through
    FLOAT64). String, binary, nested, and dictionary columns are not
    supported by this simple serializer.

    Args:
        batch: The RecordBatch to serialize. All columns must be primitive.

    Returns:
        An MmapAlignedBuffer containing the serialized bytes.

    Raises:
        Error if any column is not a fixed-width primitive type.
    """
    var num_cols = batch.num_columns()
    var num_rows = batch.num_rows()

    # --- Compute sizes ---
    # Header: 4 (magic) + 4 (num_cols) + 4 (num_rows) = 12 bytes
    # Per column descriptor: 1 (type_id) + 4 (buf_len) + 1 (has_validity) + 4 (validity_len) = 10
    var header_size = 12 + num_cols * 10

    # Compute body size (data buffers + validity buffers, each 64-byte aligned)
    var body_size = 0
    for i in range(num_cols):
        ref col_ref = batch.column_at(i)
        var at = col_ref.arrow_type

        # Validate: must be a fixed-width primitive type
        if not at.is_numeric() and at != ArrowType.BOOL:
            raise Error(
                "serialize_primitive_batch: column "
                + String(i)
                + " has non-primitive type "
                + String(at)
            )

        var data_bytes = col_ref._data.len()
        body_size += _align_to_64(data_bytes)

        if col_ref._validity:
            var validity_bytes = (col_ref._length + 7) >> 3
            body_size += _align_to_64(validity_bytes)

    var total_size = header_size + body_size
    var buf = OwnedAlignedBuffer(total_size)
    buf.zero()
    buf.set_length(Int64(total_size))

    var buf_view = buf.view_mut()

    # --- Write header ---
    buf_view.write_u8_at(0, MAGIC_T)
    buf_view.write_u8_at(1, MAGIC_H)
    buf_view.write_u8_at(2, MAGIC_R)
    buf_view.write_u8_at(3, MAGIC_M)
    _write_int32_le(buf_view, 4, Int32(num_cols))
    _write_int32_le(buf_view, 8, Int32(num_rows))

    # --- Write per-column descriptors ---
    var desc_offset = 12
    for i in range(num_cols):
        ref col_ref = batch.column_at(i)

        var data_bytes = col_ref._data.len()
        var has_validity = Bool(col_ref._validity.__bool__())
        var validity_bytes = 0
        if has_validity:
            validity_bytes = (col_ref._length + 7) >> 3

        buf_view.write_u8_at(desc_offset, col_ref.arrow_type.type_id)
        _write_int32_le(buf_view, desc_offset + 1, Int32(data_bytes))
        if has_validity:
            buf_view.write_u8_at(desc_offset + 5, UInt8(1))
        else:
            buf_view.write_u8_at(desc_offset + 5, UInt8(0))
        _write_int32_le(buf_view, desc_offset + 6, Int32(validity_bytes))
        desc_offset += 10

    # --- Write body ---
    var body_offset = header_size
    for i in range(num_cols):
        ref col_ref = batch.column_at(i)

        # Write data buffer
        var data_bytes = col_ref._data.len()
        if data_bytes > 0:
            var dst = buf.view_range_mut(body_offset, data_bytes)
            dst.copy_from_view_at(0, col_ref._data.view_range_ro(0, data_bytes))
        body_offset += _align_to_64(data_bytes)

        # Write validity buffer if present
        if col_ref._validity:
            var validity_bytes = (col_ref._length + 7) >> 3
            if validity_bytes > 0:
                var dst = buf.view_range_mut(body_offset, validity_bytes)
                dst.copy_from_view_at(
                    0,
                    col_ref._validity.value().buffer.view_range_ro(
                        0, validity_bytes
                    ),
                )
            body_offset += _align_to_64(validity_bytes)

    return SharedAlignedBuffer.from_owned(buf^)


def deserialize_primitive_batch(data: SharedAlignedBuffer[HeapRegion]) raises -> RecordBatch:
    """Deserialize bytes back to a RecordBatch of PrimitiveArrays.

    Reads the Komira simple binary format produced by
    serialize_primitive_batch(). Validates the magic bytes and
    reconstructs the Schema and Columns.

    Args:
        data: The MmapAlignedBuffer containing the serialized bytes.

    Returns:
        A new RecordBatch with the deserialized columns.

    Raises:
        Error if the magic bytes are wrong, the buffer is too short,
        or the format is invalid.
    """
    var data_view = data.view_ro()
    var total_len = data.len()

    # Validate minimum size (header magic + counts)
    if total_len < 12:
        raise Error(
            "deserialize_primitive_batch: buffer too short ("
            + String(total_len)
            + " bytes, need at least 12)"
        )

    # Validate magic
    if data_view.read_u8_at(0) != MAGIC_T or data_view.read_u8_at(1) != MAGIC_H \
        or data_view.read_u8_at(2) != MAGIC_R or data_view.read_u8_at(3) != MAGIC_M:
        raise Error("deserialize_primitive_batch: invalid magic bytes")

    var num_cols = Int(_read_int32_le(data_view, 4))
    var num_rows = Int(_read_int32_le(data_view, 8))

    # Validate header size
    var header_size = 12 + num_cols * 10
    if total_len < header_size:
        raise Error(
            "deserialize_primitive_batch: buffer too short for header ("
            + String(total_len)
            + " bytes, need "
            + String(header_size)
            + ")"
        )

    # Handle empty batch (0 columns)
    if num_cols == 0:
        var schema = Schema()
        return RecordBatch.from_columns_0(schema^)

    # --- Two-pass deserialization ---
    # Pass 1: Read descriptors and build schema.
    # Pass 2: Read body buffers and build columns.
    # This avoids storing intermediate lists and works around potential
    # compiler issues with single-iteration loops.

    # Pass 1: Build schema by reading column descriptors
    var schema_builder = SchemaBuilder()
    var pass1_offset = 12
    for i in range(num_cols):
        var type_id = data_view.read_u8_at(pass1_offset)
        var has_val = data_view.read_u8_at(pass1_offset + 5) != UInt8(0)
        var at = ArrowType(type_id)
        schema_builder.add_field(
            Field("col_" + String(i), at, nullable=has_val)
        )
        pass1_offset += 10
    var schema = schema_builder.build()

    # Pass 2: Build columns by re-reading descriptors and body buffers
    var columns = Slab[Column[HeapRegion]].create(num_cols)
    var desc_offset = 12
    var body_offset = header_size
    for _ in range(num_cols):
        var type_id = data_view.read_u8_at(desc_offset)
        var data_bytes = Int(_read_int32_le(data_view, desc_offset + 1))
        var has_val = data_view.read_u8_at(desc_offset + 5) != UInt8(0)
        var val_bytes = Int(_read_int32_le(data_view, desc_offset + 6))
        desc_offset += 10

        var at = ArrowType(type_id)

        # Copy data buffer
        var col_data = OwnedAlignedBuffer(max(data_bytes, 1))
        if data_bytes > 0:
            var dst = col_data.view_range_mut(0, data_bytes)
            dst.copy_from_view_at(0, data.view_range_ro(body_offset, data_bytes))
        col_data.set_length(Int64(data_bytes))

        body_offset += _align_to_64(data_bytes)

        # Copy validity buffer if present
        var validity = Optional[Bitmap[HeapRegion]](None)
        if has_val and val_bytes > 0:
            var bm = Bitmap.create(num_rows)
            var dst = bm.buffer.view_range_mut(0, val_bytes)
            dst.copy_from_view_at(0, data.view_range_ro(body_offset, val_bytes))
            bm.buffer.set_length(val_bytes)

            validity = bm^
        if has_val:
            body_offset += _align_to_64(val_bytes)

        # Count nulls from validity bitmap (using popcount, not scalar loop)
        var null_count = 0
        if validity:
            null_count = validity.value().null_count()

        var col = Column[HeapRegion](
            arrow_type=at,
            data=col_data^,
            offsets=None,
            validity=validity^,
            length=num_rows,
            null_count=null_count,
            offset=0,
        )
        columns.append(col^)

    # Assemble RecordBatch directly
    var batch = RecordBatch()
    batch.schema = schema^
    batch._columns = columns^
    batch._num_rows = num_rows
    return batch^
