# =============================================================================
# tensor_encoder.mojo — TensorColumn ↔ Arrow IPC bytes
# =============================================================================
#
# Drives the existing ipc_flatbuf write_tensor + write_ipc_message paths
# end-to-end. encode_tensor returns a complete IPC message frame
# (continuation marker + size + FB metadata + body). decode_tensor
# unwraps it back into a TensorColumn.
#
# Bytes-on-wire layout (per Arrow IPC v0.15+):
#   [u32 0xFFFFFFFF, u32 size, FB(Message{header=Tensor, bodyLength=N}), pad, body[N]]
#
# Where FB Message wraps a Tensor table with:
#   {type, shape, strides=empty (contiguous), data=Buffer{offset=0, length=N}}
#
# Contiguous-only; non-contiguous tensors raise at
# encode time.
# =============================================================================

from std.collections import Array
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_arrow.arrow_types import ArrowType
from komira_buffer.heap_region import HeapRegion
from komira_arrow_ipc.ipc_flatbuf import (
    FlatbufWriter,
    flatbuf_reader_over,
    parse_ipc_message,
    write_tensor,
    read_tensor,
    write_message,
    read_message,
    write_ipc_message,
    write_type_int,
    write_type_floating_point,
    read_type_int,
    read_type_floating_point,
    BufferDescriptor,
    TensorDimDescriptor,
    MESSAGE_HEADER_TENSOR,
    TYPE_INT,
    TYPE_FLOATING_POINT,
    PRECISION_HALF,
    PRECISION_SINGLE,
    PRECISION_DOUBLE,
)

from komira_arrow_ipc.tensor_column import (
    MAX_TENSOR_DIMS,
    TensorColumn,
    empty_shape,
    tensor_byte_size,
)


# =============================================================================
# dtype ↔ IPC Type union translation
# =============================================================================


def _write_type_for_dtype(
    mut writer: FlatbufWriter, dtype: ArrowType
) raises -> Int:
    """Write the appropriate Type variant table for a TensorColumn dtype.

    Returns the offset position of the emitted Type table.
    """
    if dtype == ArrowType.INT8:
        return write_type_int(writer, 8, True)
    if dtype == ArrowType.INT16:
        return write_type_int(writer, 16, True)
    if dtype == ArrowType.INT32:
        return write_type_int(writer, 32, True)
    if dtype == ArrowType.INT64:
        return write_type_int(writer, 64, True)
    if dtype == ArrowType.UINT8:
        return write_type_int(writer, 8, False)
    if dtype == ArrowType.UINT16:
        return write_type_int(writer, 16, False)
    if dtype == ArrowType.UINT32:
        return write_type_int(writer, 32, False)
    if dtype == ArrowType.UINT64:
        return write_type_int(writer, 64, False)
    if dtype == ArrowType.FLOAT16:
        return write_type_floating_point(writer, Int(PRECISION_HALF))
    if dtype == ArrowType.FLOAT32:
        return write_type_floating_point(writer, Int(PRECISION_SINGLE))
    if dtype == ArrowType.FLOAT64:
        return write_type_floating_point(writer, Int(PRECISION_DOUBLE))
    raise Error(
        "tensor encoder: unsupported dtype " + String(Int(dtype.type_id))
    )


def _arrow_type_to_ipc_tag(dtype: ArrowType) raises -> UInt8:
    """Return the Type union discriminator tag for a TensorColumn dtype."""
    if (
        dtype == ArrowType.INT8
        or dtype == ArrowType.INT16
        or dtype == ArrowType.INT32
        or dtype == ArrowType.INT64
        or dtype == ArrowType.UINT8
        or dtype == ArrowType.UINT16
        or dtype == ArrowType.UINT32
        or dtype == ArrowType.UINT64
    ):
        return TYPE_INT
    if (
        dtype == ArrowType.FLOAT16
        or dtype == ArrowType.FLOAT32
        or dtype == ArrowType.FLOAT64
    ):
        return TYPE_FLOATING_POINT
    raise Error(
        "tensor encoder: no IPC tag for dtype "
        + String(Int(dtype.type_id))
    )


def _int_arms_to_arrow_type(bit_width: Int, is_signed: Bool) raises -> ArrowType:
    """Map (bit_width, is_signed) → ArrowType for the Int Type variant."""
    if is_signed:
        if bit_width == 8:
            return ArrowType.INT8
        if bit_width == 16:
            return ArrowType.INT16
        if bit_width == 32:
            return ArrowType.INT32
        if bit_width == 64:
            return ArrowType.INT64
    else:
        if bit_width == 8:
            return ArrowType.UINT8
        if bit_width == 16:
            return ArrowType.UINT16
        if bit_width == 32:
            return ArrowType.UINT32
        if bit_width == 64:
            return ArrowType.UINT64
    raise Error("tensor decoder: unknown Int width " + String(bit_width))


def _fp_precision_to_arrow_type(precision: UInt8) raises -> ArrowType:
    """Map FP precision → ArrowType for the FloatingPoint Type variant."""
    if precision == PRECISION_HALF:
        return ArrowType.FLOAT16
    if precision == PRECISION_SINGLE:
        return ArrowType.FLOAT32
    if precision == PRECISION_DOUBLE:
        return ArrowType.FLOAT64
    raise Error(
        "tensor decoder: unknown FP precision " + String(Int(precision))
    )


# =============================================================================
# encode_tensor
# =============================================================================


def encode_tensor(var t: TensorColumn) raises -> SharedAlignedBuffer[HeapRegion]:
    """Encode a TensorColumn to a complete Arrow IPC Tensor message.

    Output layout: [u32 0xFFFFFFFF, u32 size, FB(Message wrapping Tensor),
    pad, body bytes]. The body bytes are the contiguous tensor data
    starting at byte 0 of `t.body` (offset is forced to 0; length is
    `t.body.length`).

    Raises if:
        - dtype is unsupported (non-primitive)
        - ndim is out of range
        - body length doesn't match product(shape) * sizeof(dtype)
    """
    # Validate body size vs declared shape.
    var expected = tensor_byte_size(t.dtype, t.shape, t.ndim)
    if expected != t.body.len():
        raise Error(
            "encode_tensor: body length "
            + String(t.body.len())
            + " != expected "
            + String(expected)
            + " (product(shape) * sizeof(dtype))"
        )
    # Validate dim_names.
    var names_len = len(t.dim_names)
    if names_len != 0 and names_len != t.ndim:
        raise Error(
            "encode_tensor: dim_names length "
            + String(names_len)
            + " must be 0 or "
            + String(t.ndim)
        )

    # --- Build FB metadata (Type + Tensor + Message tables) ---
    var w = FlatbufWriter(2048)
    var type_pos = _write_type_for_dtype(w, t.dtype)

    var shape_list = List[TensorDimDescriptor]()
    shape_list.reserve(t.ndim)
    for i in range(t.ndim):
        var dim_name: String
        if names_len > 0:
            dim_name = t.dim_names[i]
        else:
            dim_name = String("")
        shape_list.append(
            TensorDimDescriptor(size=Int64(t.shape[i]), name=dim_name^)
        )

    # Contiguous: empty strides per Arrow Tensor spec.
    var strides = List[Int64]()
    var data = BufferDescriptor(
        offset=Int64(0), length=Int64(t.body.len())
    )
    var ipc_tag = _arrow_type_to_ipc_tag(t.dtype)
    var tensor_pos = write_tensor(
        w, ipc_tag, type_pos, shape_list, strides, data
    )
    var msg_pos = write_message(
        w,
        Int16(4),  # MetadataVersion.V5
        MESSAGE_HEADER_TENSOR,
        tensor_pos,
        Int64(t.body.len()),
    )
    var fb_payload = w^.finalize(msg_pos)

    # --- Wrap in IPC outer framing + append body bytes ---
    var w2 = FlatbufWriter(64)
    var body_span = t.body.view_range_ro(0, t.body.len()).into_span()
    return write_ipc_message(w2, fb_payload^, body_span, True)


# =============================================================================
# decode_tensor
# =============================================================================


def decode_tensor(var buf: SharedAlignedBuffer[HeapRegion]) raises -> TensorColumn:
    """Decode an Arrow IPC Tensor message frame into a TensorColumn.

    The input is a complete frame (continuation marker + size + FB
    payload + body). Validates that the message header_tag is TENSOR.

    Raises if:
        - frame is malformed (too short, invalid framing)
        - message tag != MESSAGE_HEADER_TENSOR
        - tensor type union arm is non-primitive (Decimal, etc — not supported)
        - shape's ndim exceeds MAX_TENSOR_DIMS
    """
    # 1. Parse IPC framing → metadata + body positions.
    var frame = parse_ipc_message(buf)

    # 2. Extract FB metadata into a fresh SharedAlignedBuffer so FlatbufReader's
    # root_offset is at byte 0 of the new buffer.
    var fb = SharedAlignedBuffer[HeapRegion].heap_owned(frame.metadata_size)
    for i in range(frame.metadata_size):
        fb.write_u8_at(i, buf.read_u8_at(frame.metadata_pos + i))
    fb.set_length(frame.metadata_size)

    var reader = flatbuf_reader_over(fb)

    # 3. Read Message + assert TENSOR header.
    var msg = read_message(reader, reader.read_root_offset())
    if msg.header_tag != MESSAGE_HEADER_TENSOR:
        raise Error(
            "decode_tensor: expected Tensor header (tag "
            + String(Int(MESSAGE_HEADER_TENSOR))
            + "), got "
            + String(Int(msg.header_tag))
        )

    # 4. Read Tensor table.
    var td = read_tensor(reader, msg.header_table_pos)
    var ndim = len(td.shape)
    if ndim <= 0 or ndim > MAX_TENSOR_DIMS:
        raise Error(
            "decode_tensor: ndim "
            + String(ndim)
            + " out of range [1, "
            + String(MAX_TENSOR_DIMS)
            + "]"
        )

    # 5. Decode dtype via type union arm. We support Int + FloatingPoint
    #    for v1; other arms raise.
    var dtype: ArrowType
    if td.type_tag == TYPE_INT:
        var it = read_type_int(reader, td.type_table_pos)
        dtype = _int_arms_to_arrow_type(it.bit_width, it.is_signed)
    elif td.type_tag == TYPE_FLOATING_POINT:
        var fp = read_type_floating_point(reader, td.type_table_pos)
        dtype = _fp_precision_to_arrow_type(fp.precision)
    else:
        raise Error(
            "decode_tensor: unsupported Type tag "
            + String(Int(td.type_tag))
            + " (only Int + FloatingPoint are supported)"
        )

    # 6. Build shape + dim_names from TensorDimDescriptor list.
    var shape = empty_shape()
    var dim_names = List[String]()
    var any_name = False
    for i in range(ndim):
        shape[i] = Int(td.shape[i].size)
        if td.shape[i].name.byte_length() > 0:
            any_name = True
    if any_name:
        dim_names.reserve(ndim)
        for i in range(ndim):
            dim_names.append(td.shape[i].name)

    # 7. Validate strides are absent (contiguous-only per v1).
    if len(td.strides) != 0:
        # Strict-mode: raise. (Could be relaxed to "accept and verify
        # they match contiguous row-major" — but spec says strides MAY
        # be omitted for contiguous, so producer that emits them is fine
        # if they match.)
        # For v1 we only support empty strides — non-contiguous tensors
        # would require a separate stride-aware copy path.
        var elt_size = _elt_size_for_dtype(dtype)
        var expected_strides = _compute_row_major_strides(shape, ndim, elt_size)
        for i in range(ndim):
            if td.strides[i] != Int64(expected_strides[i]):
                raise Error(
                    "decode_tensor: non-contiguous tensor (stride mismatch "
                    "at dim " + String(i) + ")"
                )

    # 8. Validate body size vs Tensor.data.length.
    var data_len = Int(td.data.length)
    if data_len > frame.body_size:
        raise Error(
            "decode_tensor: Tensor.data.length "
            + String(data_len)
            + " > body_size "
            + String(frame.body_size)
        )

    # 9. Copy body bytes [data.offset, data.offset + data.length) into
    #    a fresh SharedAlignedBuffer.
    var data_off = Int(td.data.offset)
    var body = SharedAlignedBuffer[HeapRegion].heap_owned(data_len)
    for i in range(data_len):
        body.write_u8_at(i, buf.read_u8_at(frame.body_pos + data_off + i))
    body.set_length(data_len)


    return TensorColumn(
        dtype=dtype,
        ndim=ndim,
        shape=shape^,
        dim_names=dim_names^,
        body=body^,
    )


# =============================================================================
# Decode-side helpers
# =============================================================================
# Dtype decoding is inlined in decode_tensor (avoids origin-parameter
# threading on a helper) — see step 5 there.


def _compute_row_major_strides(
    shape: Array[Int, MAX_TENSOR_DIMS], ndim: Int, elt_size: Int
) -> List[Int]:
    """Row-major contiguous strides: stride[i] = elt_size * product(shape[i+1:])."""
    var strides = List[Int]()
    strides.reserve(ndim)
    for i in range(ndim):
        var s = elt_size
        for j in range(i + 1, ndim):
            s *= shape[j]
        strides.append(s)
    return strides^


def _elt_size_for_dtype(dtype: ArrowType) raises -> Int:
    """Per-element byte size (same as tensor_column._arrow_type_element_size
    but local to avoid an import cycle; identical semantics)."""
    if dtype == ArrowType.INT8 or dtype == ArrowType.UINT8:
        return 1
    if dtype == ArrowType.INT16 or dtype == ArrowType.UINT16:
        return 2
    if dtype == ArrowType.INT32 or dtype == ArrowType.UINT32:
        return 4
    if dtype == ArrowType.INT64 or dtype == ArrowType.UINT64:
        return 8
    if dtype == ArrowType.FLOAT16:
        return 2
    if dtype == ArrowType.FLOAT32:
        return 4
    if dtype == ArrowType.FLOAT64:
        return 8
    raise Error(
        "tensor decoder: unsupported dtype "
        + String(Int(dtype.type_id))
    )
