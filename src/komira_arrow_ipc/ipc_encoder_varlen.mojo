# =============================================================================
# ipc_encoder_varlen.mojo — Variable-length Arrow type encoders
# (variable-length)
# =============================================================================
#
# Covers the 4 variable-length types with offsets:
#   String       — UTF-8 + Int32 offsets
#   LargeString  — UTF-8 + Int64 offsets
#   Binary       — raw bytes + Int32 offsets
#   LargeBinary  — raw bytes + Int64 offsets
#
# FixedSizeBinary has its own ArrowType arm.
#
# Var-len Arrow types emit 3 buffers per column:
#   Buffer 0 — validity bitmap (always; zero-length if all non-null)
#   Buffer 1 — offsets buffer ((length+1) × offset_bytes)
#   Buffer 2 — data buffer (total byte count = offsets[length])
#
# String/Binary share the Int32 offsets path; LargeString/LargeBinary
# share the Int64 offsets path. The byte width parameter is the only
# difference — same code body via a shared `_encode_varlen` helper.
# =============================================================================

from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_arrow_ipc.ipc_flatbuf import BufferDescriptor, FieldNode
from komira_arrow_ipc.ipc_body_sink import BodySink
from komira_arrow_ipc.ipc_encoder_dispatch import (
    emit_validity_bitmap,
    _align_to_8,
    _align_to_8_zero_pad,
    _copy_bytes_into_body,
)


# =============================================================================
# Shared body
#
# parametric
# on BodySink (see ipc_body_sink.mojo header).
# =============================================================================


def _encode_varlen[
    B: BodySink
](
    col: Column[HeapRegion],
    offset_bytes: Int,
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    """Shared body for all variable-length Arrow types.

    Emits:
      FieldNode{length, null_count}
      Buffer 0 — validity bitmap
      Buffer 1 — offsets buffer ((length+1) × offset_bytes)
      Buffer 2 — data buffer (length determined by offsets, which is
                 the byte count = col._data.length)

    `offset_bytes` is 4 for Int32 offsets (STRING/BINARY) or 8 for
    Int64 offsets (LARGE_STRING/LARGE_BINARY).

    Returns the new body_cursor.
    """
    nodes.append(
        FieldNode(
            length=Int64(col._length),
            null_count=Int64(col._null_count),
        )
    )
    var cursor = emit_validity_bitmap(col, body, body_cursor, buffers)

    # Offsets buffer.
    if not col._offsets:
        raise Error(
            "_encode_varlen: column has no _offsets buffer (required for "
            "variable-length type)"
        )
    ref off_buf_ref = col._offsets.value()
    var offsets_bytes_total = (col._length + 1) * offset_bytes
    if offsets_bytes_total > off_buf_ref.len():
        raise Error(
            "_encode_varlen: offsets buffer too small (have "
            + String(off_buf_ref.len())
            + " bytes, need "
            + String(offsets_bytes_total)
            + ")"
        )
    var aligned_off = _align_to_8_zero_pad(body, cursor)
    _copy_bytes_into_body(
        body, aligned_off, off_buf_ref, 0, offsets_bytes_total
    )
    buffers.append(
        BufferDescriptor(
            offset=Int64(aligned_off), length=Int64(offsets_bytes_total)
        )
    )
    cursor = aligned_off + offsets_bytes_total

    # Data buffer. Length = col._data.length (the cumulative byte count
    # for all rows).
    var data_bytes = col._data.len()
    var aligned_data = _align_to_8_zero_pad(body, cursor)
    _copy_bytes_into_body(body, aligned_data, col._data, 0, data_bytes)
    buffers.append(
        BufferDescriptor(
            offset=Int64(aligned_data), length=Int64(data_bytes)
        )
    )
    return aligned_data + data_bytes


# =============================================================================
# Public per-DType encoders
# =============================================================================


def encode_string[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    """STRING: validity + Int32 offsets + UTF-8 data."""
    return _encode_varlen[B](col, 4, body, body_cursor, buffers, nodes)


def encode_binary[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    """BINARY: validity + Int32 offsets + raw bytes."""
    return _encode_varlen[B](col, 4, body, body_cursor, buffers, nodes)


def encode_large_string[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    """LARGE_STRING: validity + Int64 offsets + UTF-8 data."""
    return _encode_varlen[B](col, 8, body, body_cursor, buffers, nodes)


def encode_large_binary[
    B: BodySink
](
    col: Column[HeapRegion],
    mut body: B,
    body_cursor: Int,
    mut buffers: List[BufferDescriptor],
    mut nodes: List[FieldNode],
) raises -> Int:
    """LARGE_BINARY: validity + Int64 offsets + raw bytes."""
    return _encode_varlen[B](col, 8, body, body_cursor, buffers, nodes)
