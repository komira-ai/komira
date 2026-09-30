# =============================================================================
# sparse_tensor_encoder.mojo — SparseTensorColumn ↔ Arrow IPC bytes
# =============================================================================
#
# Drives the existing ipc_flatbuf SparseTensor write/read paths end-to-end
# under the SDK-friendly SparseTensorColumn struct.
#
# Index kind dispatch (runtime if-else cascade —
# branches ONCE per message, not per cell):
#   COO  → write_sparse_tensor_index_coo
#   CSX  → write_sparse_matrix_index_csx (CSR if compressed_axis=ROW,
#          CSC if =COLUMN)
#   CSF  → raise (not supported)
#
# Body packing per index kind:
#   COO: [indices_bytes][pad to 8B][values_bytes]
#   CSX: [indptr_bytes][pad][indices_bytes][pad][values_bytes]
# =============================================================================

from std.collections import Array
from komira_core.arrow.shared_aligned_buffer import SharedAlignedBuffer
from komira_core.arrow.arrow_types import ArrowType
from komira_core.io.heap_region import HeapRegion
from komira_core.arrow.ipc_flatbuf import (
    FlatbufWriter,
    flatbuf_reader_over,
    parse_ipc_message,
    write_sparse_tensor,
    read_sparse_tensor,
    write_sparse_tensor_index_coo,
    read_sparse_tensor_index_coo,
    write_sparse_matrix_index_csx,
    read_sparse_matrix_index_csx,
    write_message,
    read_message,
    write_ipc_message,
    write_type_int,
    read_type_int,
    read_type_floating_point,
    BufferDescriptor,
    TensorDimDescriptor,
    MESSAGE_HEADER_SPARSE_TENSOR,
    SPARSE_TENSOR_INDEX_COO,
    SPARSE_TENSOR_INDEX_CSX,
    SPARSE_TENSOR_INDEX_CSF,
    TYPE_INT,
    TYPE_FLOATING_POINT,
)

from .sparse_tensor_column import (
    SPARSE_KIND_COO,
    SPARSE_KIND_CSX,
    SparseTensorColumn,
    _pad_to_8,
)
from .tensor_column import MAX_TENSOR_DIMS, empty_shape
from .tensor_encoder import (
    _write_type_for_dtype,
    _arrow_type_to_ipc_tag,
    _int_arms_to_arrow_type,
    _fp_precision_to_arrow_type,
)


# =============================================================================
# encode_sparse_tensor
# =============================================================================


def encode_sparse_tensor(var st: SparseTensorColumn) raises -> SharedAlignedBuffer[HeapRegion]:
    """Encode a SparseTensorColumn to a complete Arrow IPC SparseTensor
    message frame.

    Output: [u32 0xFFFFFFFF, u32 size, FB(Message wrapping SparseTensor +
    SparseTensorIndex), pad, body_bytes].

    Body layout:
        COO: [indices_bytes][pad8][values_bytes]
        CSX: [indptr_bytes][pad8][indices_bytes][pad8][values_bytes]
    """
    # Validate index_kind + early raise on CSF.
    if st.index_kind != SPARSE_KIND_COO and st.index_kind != SPARSE_KIND_CSX:
        raise Error(
            "encode_sparse_tensor: unsupported index_kind "
            + String(Int(st.index_kind))
            + " (supported: COO + CSX; CSF is not supported)"
        )

    # Validate dim_names.
    var names_len = len(st.dim_names)
    if names_len != 0 and names_len != st.ndim:
        raise Error(
            "encode_sparse_tensor: dim_names length "
            + String(names_len)
            + " must be 0 or "
            + String(st.ndim)
        )

    # Validate CSX requires 2D.
    if st.index_kind == SPARSE_KIND_CSX and st.ndim != 2:
        raise Error(
            "encode_sparse_tensor: CSX index_kind requires ndim==2, got "
            + String(st.ndim)
        )

    # Validate index_bit_width.
    if st.index_bit_width != 32 and st.index_bit_width != 64:
        raise Error(
            "encode_sparse_tensor: index_bit_width must be 32 or 64, got "
            + String(st.index_bit_width)
        )

    # --- Compute body layout offsets ---
    var idx_len = st.indices_bytes.len()
    var indptr_len = st.indptr_bytes.len()
    var values_len = st.values_bytes.len()

    var indptr_off = 0
    var indptr_padded: Int
    var indices_off: Int
    var indices_padded: Int
    var values_off: Int

    if st.index_kind == SPARSE_KIND_CSX:
        indptr_off = 0
        indptr_padded = _pad_to_8(indptr_len)
        indices_off = indptr_padded
        indices_padded = _pad_to_8(idx_len)
        values_off = indptr_padded + indices_padded
    else:
        # COO
        indices_off = 0
        indices_padded = _pad_to_8(idx_len)
        values_off = indices_padded

    var body_total = values_off + values_len

    # --- Build FB metadata ---
    var w = FlatbufWriter(4096)

    # Values type variant.
    var values_type_pos = _write_type_for_dtype(w, st.dtype)
    var values_tag = _arrow_type_to_ipc_tag(st.dtype)

    # Indices type variant (signed Int with declared bit_width).
    var indices_type_pos = write_type_int(w, st.index_bit_width, True)

    # SparseTensorIndex variant (offset-to-table, written before parent).
    var sparse_idx_tag: UInt8
    var sparse_idx_pos: Int
    if st.index_kind == SPARSE_KIND_COO:
        var indices_strides = List[Int64]()
        # Empty strides: per spec, defaults to contiguous row-major over
        # the (non_zero, ndim) shape.
        var indices_buffer = BufferDescriptor(
            offset=Int64(indices_off), length=Int64(idx_len)
        )
        sparse_idx_pos = write_sparse_tensor_index_coo(
            w,
            indices_type_pos,
            indices_strides,
            indices_buffer,
            st.is_canonical,
        )
        sparse_idx_tag = SPARSE_TENSOR_INDEX_COO
    else:
        # CSX
        var indptr_type_pos = write_type_int(w, st.index_bit_width, True)
        var indptr_buffer = BufferDescriptor(
            offset=Int64(indptr_off), length=Int64(indptr_len)
        )
        var indices_buffer = BufferDescriptor(
            offset=Int64(indices_off), length=Int64(idx_len)
        )
        sparse_idx_pos = write_sparse_matrix_index_csx(
            w,
            st.compressed_axis,
            indptr_type_pos,
            indptr_buffer,
            indices_type_pos,
            indices_buffer,
        )
        sparse_idx_tag = SPARSE_TENSOR_INDEX_CSX

    # Shape vector.
    var shape_list = List[TensorDimDescriptor]()
    shape_list.reserve(st.ndim)
    for i in range(st.ndim):
        var dim_name: String
        if names_len > 0:
            dim_name = st.dim_names[i]
        else:
            dim_name = String("")
        shape_list.append(
            TensorDimDescriptor(size=Int64(st.shape[i]), name=dim_name^)
        )

    # Data Buffer descriptor (offset into body where values begin).
    var data = BufferDescriptor(
        offset=Int64(values_off), length=Int64(values_len)
    )

    var sparse_pos = write_sparse_tensor(
        w,
        values_tag,
        values_type_pos,
        shape_list,
        st.non_zero_length,
        sparse_idx_tag,
        sparse_idx_pos,
        data,
    )
    var msg_pos = write_message(
        w,
        Int16(4),  # V5
        MESSAGE_HEADER_SPARSE_TENSOR,
        sparse_pos,
        Int64(body_total),
    )
    var fb_payload = w^.finalize(msg_pos)

    # --- Pack body bytes into a single SharedAlignedBuffer + wrap framing ---
    var body = SharedAlignedBuffer[HeapRegion].heap_owned(body_total)
    body.zero()

    if st.index_kind == SPARSE_KIND_CSX:
        # indptr bytes
        for i in range(indptr_len):
            body.write_u8_at(indptr_off + i, st.indptr_bytes.read_u8_at(i))
        # indices bytes
        for i in range(idx_len):
            body.write_u8_at(indices_off + i, st.indices_bytes.read_u8_at(i))
    else:
        # COO: indices only (no indptr)
        for i in range(idx_len):
            body.write_u8_at(indices_off + i, st.indices_bytes.read_u8_at(i))

    # values bytes
    for i in range(values_len):
        body.write_u8_at(values_off + i, st.values_bytes.read_u8_at(i))
    body.set_length(body_total)


    var w2 = FlatbufWriter(64)
    var body_span = body.view_range_ro(0, body_total).into_span()
    var result = write_ipc_message(w2, fb_payload^, body_span, True)
    _ = body^  # keep alive until span is consumed
    return result^


# =============================================================================
# decode_sparse_tensor
# =============================================================================


def decode_sparse_tensor(
    var buf: SharedAlignedBuffer[HeapRegion],
) raises -> SparseTensorColumn:
    """Decode an Arrow IPC SparseTensor message frame into a SparseTensorColumn.

    Raises if:
        - frame is malformed
        - message tag != MESSAGE_HEADER_SPARSE_TENSOR
        - sparse_index_tag is CSF (not supported)
        - values dtype is non-primitive (not supported)
        - ndim exceeds MAX_TENSOR_DIMS
    """
    # 1. Parse IPC framing.
    var frame = parse_ipc_message(buf)

    # 2. Extract FB metadata into a fresh SharedAlignedBuffer.
    var fb = SharedAlignedBuffer[HeapRegion].heap_owned(frame.metadata_size)
    for i in range(frame.metadata_size):
        fb.write_u8_at(i, buf.read_u8_at(frame.metadata_pos + i))
    fb.set_length(frame.metadata_size)

    var reader = flatbuf_reader_over(fb)

    # 3. Read Message + assert SPARSE_TENSOR header.
    var msg = read_message(reader, reader.read_root_offset())
    if msg.header_tag != MESSAGE_HEADER_SPARSE_TENSOR:
        raise Error(
            "decode_sparse_tensor: expected SparseTensor header (tag "
            + String(Int(MESSAGE_HEADER_SPARSE_TENSOR))
            + "), got "
            + String(Int(msg.header_tag))
        )

    # 4. Read SparseTensor table.
    var std_ = read_sparse_tensor(reader, msg.header_table_pos)
    var ndim = len(std_.shape)
    if ndim <= 0 or ndim > MAX_TENSOR_DIMS:
        raise Error(
            "decode_sparse_tensor: ndim "
            + String(ndim)
            + " out of range [1, "
            + String(MAX_TENSOR_DIMS)
            + "]"
        )

    # 5. Decode values dtype.
    var dtype: ArrowType
    if std_.type_tag == TYPE_INT:
        var it = read_type_int(reader, std_.type_table_pos)
        dtype = _int_arms_to_arrow_type(it.bit_width, it.is_signed)
    elif std_.type_tag == TYPE_FLOATING_POINT:
        var fp = read_type_floating_point(reader, std_.type_table_pos)
        dtype = _fp_precision_to_arrow_type(fp.precision)
    else:
        raise Error(
            "decode_sparse_tensor: unsupported Type tag "
            + String(Int(std_.type_tag))
            + " (only Int + FloatingPoint are supported)"
        )

    # 6. Build shape + dim_names.
    var shape = empty_shape()
    var dim_names = List[String]()
    var any_name = False
    for i in range(ndim):
        shape[i] = Int(std_.shape[i].size)
        if std_.shape[i].name.byte_length() > 0:
            any_name = True
    if any_name:
        dim_names.reserve(ndim)
        for i in range(ndim):
            dim_names.append(std_.shape[i].name)

    # 7. Dispatch on sparse_index_tag.
    var index_kind: UInt8
    var index_bit_width: Int
    var is_canonical: Bool = False
    var compressed_axis: UInt8 = 0
    var indices_off: Int
    var indices_len: Int
    var indptr_off: Int = 0
    var indptr_len: Int = 0
    if std_.sparse_index_tag == SPARSE_TENSOR_INDEX_COO:
        index_kind = SPARSE_KIND_COO
        var coo = read_sparse_tensor_index_coo(
            reader, std_.sparse_index_table_pos
        )
        is_canonical = coo.is_canonical
        # Indices type (signed Int).
        var coo_it = read_type_int(reader, coo.indices_type_table_pos)
        index_bit_width = coo_it.bit_width
        indices_off = Int(coo.indices_buffer.offset)
        indices_len = Int(coo.indices_buffer.length)
    elif std_.sparse_index_tag == SPARSE_TENSOR_INDEX_CSX:
        index_kind = SPARSE_KIND_CSX
        var csx = read_sparse_matrix_index_csx(
            reader, std_.sparse_index_table_pos
        )
        compressed_axis = csx.compressed_axis
        var csx_it = read_type_int(reader, csx.indices_type_table_pos)
        index_bit_width = csx_it.bit_width
        indptr_off = Int(csx.indptr_buffer.offset)
        indptr_len = Int(csx.indptr_buffer.length)
        indices_off = Int(csx.indices_buffer.offset)
        indices_len = Int(csx.indices_buffer.length)
    elif std_.sparse_index_tag == SPARSE_TENSOR_INDEX_CSF:
        raise Error(
            "decode_sparse_tensor: CSF index_kind is not supported"
        )
    else:
        raise Error(
            "decode_sparse_tensor: unknown sparse_index_tag "
            + String(Int(std_.sparse_index_tag))
        )

    # 8. Extract body slices.
    var values_off = Int(std_.data.offset)
    var values_len = Int(std_.data.length)

    var indptr_bytes = SharedAlignedBuffer[HeapRegion].heap_owned(max(indptr_len, 1))
    for i in range(indptr_len):
        indptr_bytes.write_u8_at(i, buf.read_u8_at(frame.body_pos + indptr_off + i))
    indptr_bytes.set_length(indptr_len)


    var indices_bytes = SharedAlignedBuffer[HeapRegion].heap_owned(max(indices_len, 1))
    for i in range(indices_len):
        indices_bytes.write_u8_at(
            i, buf.read_u8_at(frame.body_pos + indices_off + i)
        )
    indices_bytes.set_length(indices_len)


    var values_bytes = SharedAlignedBuffer[HeapRegion].heap_owned(max(values_len, 1))
    for i in range(values_len):
        values_bytes.write_u8_at(
            i, buf.read_u8_at(frame.body_pos + values_off + i)
        )
    values_bytes.set_length(values_len)


    return SparseTensorColumn(
        dtype=dtype,
        ndim=ndim,
        shape=shape^,
        dim_names=dim_names^,
        non_zero_length=std_.non_zero_length,
        index_kind=index_kind,
        index_bit_width=index_bit_width,
        is_canonical=is_canonical,
        compressed_axis=compressed_axis,
        indptr_bytes=indptr_bytes^,
        indices_bytes=indices_bytes^,
        values_bytes=values_bytes^,
    )
