# =============================================================================
# ipc_encoder_primitive.mojo — Per-DType encoders for primitive Arrow types
# (primitives)
# =============================================================================
#
# Covers the 11 primitive Arrow type arms:
#   Int8/16/32/64, UInt8/16/32/64, Float16/32/64, Bool, Null
#
# Each encoder body:
#   1. Appends FieldNode{length, null_count} for the column.
#   2. Calls emit_validity_bitmap (buffer 0 — always validity).
#   3. Calls emit_primitive_value_buffer with the dtype byte width
#      (Buffer 1 — values).
#
# Primitive Arrow types emit exactly 2 buffers per column:
# validity bitmap + value buffer (in that order).
#
# Bool is special: Buffer 1 is a 1-bit-packed bitmap (NOT a byte buffer);
# byte count = (length + 7) // 8.
#
# Null is special: NO buffers (zero buffer count); only a FieldNode with
# null_count == length (every element is null).
# =============================================================================

from komira_core.arrow.column import Column
from komira_core.io.heap_region import HeapRegion
from komira_core.arrow.ipc_flatbuf import BufferDescriptor, FieldNode
from .ipc_body_sink import BodySink
from .ipc_encoder_dispatch import (
    emit_validity_bitmap,
    emit_primitive_value_buffer,
    _align_to_8,
    _align_to_8_zero_pad,
    _copy_bytes_into_body,
)


# =============================================================================
# Shared body for fixed-width primitives (Int*, UInt*, Float*)
#
# Per-DType
# encoders are parametric on `B: BodySink` so the same body works with
# both the MmapAlignedBuffer-backed sink (compressed path) and
# the streaming-to-FileHandle sink (uncompressed path). Mojo
# monomorphizes per concrete `B` — no virtual dispatch.
# =============================================================================


def _encode_fixed_width_primitive[
    B: BodySink
](
    col: Column[HeapRegion],
    bytes_per_element: Int,
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    """Shared body for all fixed-width primitive Arrow types.

    Emits:
      FieldNode{length=col._length, null_count=col._null_count}
      Buffer 0 — validity bitmap (zero-length if all non-null)
      Buffer 1 — N-byte-per-element value buffer

    Returns the new body_cursor.
    """
    nodes.append(
        FieldNode(
            length=Int64(col._length),
            null_count=Int64(col._null_count),
        )
    )
    var cursor = emit_validity_bitmap(col, body, body_cursor, buffers)
    cursor = emit_primitive_value_buffer(
        col, bytes_per_element, body, cursor, buffers
    )
    return cursor


# =============================================================================
# Signed integers
# =============================================================================


def encode_int8[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    return _encode_fixed_width_primitive[B](
        col, 1, body, body_cursor, buffers, nodes
    )


def encode_int16[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    return _encode_fixed_width_primitive[B](
        col, 2, body, body_cursor, buffers, nodes
    )


def encode_int32[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    return _encode_fixed_width_primitive[B](
        col, 4, body, body_cursor, buffers, nodes
    )


def encode_int64[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    return _encode_fixed_width_primitive[B](
        col, 8, body, body_cursor, buffers, nodes
    )


# =============================================================================
# Unsigned integers
# =============================================================================


def encode_uint8[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    return _encode_fixed_width_primitive[B](
        col, 1, body, body_cursor, buffers, nodes
    )


def encode_uint16[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    return _encode_fixed_width_primitive[B](
        col, 2, body, body_cursor, buffers, nodes
    )


def encode_uint32[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    return _encode_fixed_width_primitive[B](
        col, 4, body, body_cursor, buffers, nodes
    )


def encode_uint64[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    return _encode_fixed_width_primitive[B](
        col, 8, body, body_cursor, buffers, nodes
    )


# =============================================================================
# Floating point
# =============================================================================


def encode_float16[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    return _encode_fixed_width_primitive[B](
        col, 2, body, body_cursor, buffers, nodes
    )


def encode_float32[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    return _encode_fixed_width_primitive[B](
        col, 4, body, body_cursor, buffers, nodes
    )


def encode_float64[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    return _encode_fixed_width_primitive[B](
        col, 8, body, body_cursor, buffers, nodes
    )


# =============================================================================
# Bool — special: Buffer 1 is a 1-bit-packed bitmap
# =============================================================================


def encode_bool[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    """Encode a BOOL column.

    Emits:
      FieldNode{length, null_count}
      Buffer 0 — validity bitmap
      Buffer 1 — value bitmap (LSB-first 1-bit pack; same layout as
                 Column._data which Column.from_boolean already stages)

    Bool's value buffer byte size = (length + 7) // 8 — not the
    bytes_per_element pattern.
    """
    nodes.append(
        FieldNode(
            length=Int64(col._length),
            null_count=Int64(col._null_count),
        )
    )
    var cursor = emit_validity_bitmap(col, body, body_cursor, buffers)

    # Value bitmap.
    var n = col._length
    var bitmap_bytes = (n + 7) // 8
    var aligned_cursor = _align_to_8_zero_pad(body, cursor)
    _copy_bytes_into_body(body, aligned_cursor, col._data, 0, bitmap_bytes)
    buffers.append(
        BufferDescriptor(
            offset=Int64(aligned_cursor), length=Int64(bitmap_bytes)
        )
    )
    return aligned_cursor + bitmap_bytes


# =============================================================================
# Null — special case (no buffers; FieldNode only)
# =============================================================================


def encode_null(col: Column[HeapRegion], mut nodes: List[FieldNode]) raises:
    """Encode a NULL column.

    NULL columns emit NO buffers per Arrow spec. Only a FieldNode with
    `null_count == length`. Validates the invariant.
    """
    if col._null_count != col._length:
        raise Error(
            "encode_null: NULL column must have null_count == length "
            "(got null_count="
            + String(col._null_count)
            + ", length="
            + String(col._length)
            + ")"
        )
    nodes.append(
        FieldNode(
            length=Int64(col._length),
            null_count=Int64(col._length),
        )
    )
