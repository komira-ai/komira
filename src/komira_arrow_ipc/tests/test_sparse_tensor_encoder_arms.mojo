# =============================================================================
# test_sparse_tensor_encoder_arms.mojo: dim names, FloatingPoint values and
# every refusal of decode_sparse_tensor on a hand-built frame
# =============================================================================
#
# test_sparse_tensor_encoder.mojo round-trips COO and CSX tensors of Int
# values without dimension names, and the encoder's refusals of CSF, a
# non-2D CSX and an index width other than 32 or 64. This file round-trips
# a FLOAT32 COO tensor with dimension names, refuses a dim_names list of the
# wrong length, and feeds decode_sparse_tensor frames written with the
# ipc_flatbuf writers: a Tensor header, zero and nine dimensions, a Utf8
# values Type, a CSF index and an index tag no version defines.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion
from komira_arrow.arrow_types import ArrowType
from komira_arrow_ipc.ipc_flatbuf import (
    FlatbufWriter,
    BufferDescriptor,
    TensorDimDescriptor,
    MESSAGE_HEADER_TENSOR,
    MESSAGE_HEADER_SPARSE_TENSOR,
    SPARSE_TENSOR_INDEX_COO,
    SPARSE_TENSOR_INDEX_CSF,
    TYPE_INT,
    TYPE_UTF8,
    write_sparse_tensor,
    write_sparse_tensor_index_coo,
    write_message,
    write_ipc_message,
    write_type_int,
    write_type_utf8,
)
from komira_arrow_ipc.sparse_tensor_column import (
    SPARSE_KIND_COO,
    SparseTensorColumn,
)
from komira_arrow_ipc.tensor_column import empty_shape
from komira_arrow_ipc.sparse_tensor_encoder import (
    encode_sparse_tensor,
    decode_sparse_tensor,
)


def _bytes(n: Int, first: Int) raises -> SharedAlignedBuffer[HeapRegion]:
    var b = SharedAlignedBuffer[HeapRegion].heap_owned(max(n, 1))
    for i in range(n):
        b.write_u8_at(i, UInt8(first + i))
    b.set_length(n)
    return b^


def _coo_float32(var names: List[String]) raises -> SparseTensorColumn:
    """A 3x4 FLOAT32 COO tensor with two non-zeros at (0, 1) and (2, 3),
    Int32 indices."""
    var shape = empty_shape()
    shape[0] = 3
    shape[1] = 4
    var idx = SharedAlignedBuffer[HeapRegion].heap_owned(16)
    idx.write_i32_le_at(0, Int32(0))
    idx.write_i32_le_at(4, Int32(1))
    idx.write_i32_le_at(8, Int32(2))
    idx.write_i32_le_at(12, Int32(3))
    idx.set_length(16)
    return SparseTensorColumn(
        dtype=ArrowType.FLOAT32,
        ndim=2,
        shape=shape^,
        dim_names=names^,
        non_zero_length=Int64(2),
        index_kind=SPARSE_KIND_COO,
        index_bit_width=32,
        is_canonical=False,
        compressed_axis=UInt8(0),
        indptr_bytes=_bytes(0, 0),
        indices_bytes=idx^,
        values_bytes=_bytes(8, 0x41),
    )


def test_coo_float32_with_dim_names_round_trips() raises:
    var names = List[String]()
    names.append(String("row"))
    names.append(String("col"))
    var d = decode_sparse_tensor(encode_sparse_tensor(_coo_float32(names^)))
    assert_equal(d.dtype, ArrowType.FLOAT32)
    assert_equal(d.ndim, 2)
    assert_equal(len(d.dim_names), 2)
    assert_equal(d.dim_names[0], String("row"))
    assert_equal(d.dim_names[1], String("col"))
    assert_true(not d.is_canonical)
    assert_equal(d.index_bit_width, 32)
    assert_equal(d.indices_bytes.read_i32_le_at(12), Int32(3))
    assert_equal(d.values_bytes.len(), 8)
    for i in range(8):
        assert_equal(d.values_bytes.read_u8_at(i), UInt8(0x41 + i))


def test_coo_with_only_a_later_dim_named_keeps_both_names() raises:
    """One named dimension makes the decoder return a name per dimension
    (the unnamed one as the empty string)."""
    var names = List[String]()
    names.append(String(""))
    names.append(String("col"))
    var d = decode_sparse_tensor(encode_sparse_tensor(_coo_float32(names^)))
    assert_equal(len(d.dim_names), 2)
    assert_equal(d.dim_names[0], String(""))
    assert_equal(d.dim_names[1], String("col"))


def test_encode_refuses_dim_names_of_the_wrong_length() raises:
    var names = List[String]()
    names.append(String("only"))
    var msg = String("")
    try:
        _ = encode_sparse_tensor(_coo_float32(names^))
    except e:
        msg = String(e)
    assert_true(
        "encode_sparse_tensor: dim_names length 1 must be 0 or 2" in msg, msg
    )


# ---------------------------------------------------------------------------
# Hand-built frames
# ---------------------------------------------------------------------------


def _frame(
    header_tag: UInt8, utf8_values: Bool, ndim: Int, index_tag: UInt8
) raises -> SharedAlignedBuffer[HeapRegion]:
    """A frame whose Message (header `header_tag`) holds a SparseTensor of
    `ndim` dimensions of size 2, Int8 values (Utf8 if `utf8_values`) and a
    COO index table under the index tag `index_tag`; 8 body bytes."""
    var w = FlatbufWriter(2048)
    var type_pos: Int
    var tag: UInt8
    if utf8_values:
        type_pos = write_type_utf8(w)
        tag = TYPE_UTF8
    else:
        type_pos = write_type_int(w, 8, True)
        tag = TYPE_INT
    var idx_type = write_type_int(w, 64, True)
    var coo = write_sparse_tensor_index_coo(
        w,
        idx_type,
        List[Int64](),
        BufferDescriptor(offset=Int64(0), length=Int64(0)),
        False,
    )
    var shape = List[TensorDimDescriptor]()
    for _ in range(ndim):
        shape.append(TensorDimDescriptor(size=Int64(2), name=String("")))
    var pos = write_sparse_tensor(
        w,
        tag,
        type_pos,
        shape,
        Int64(0),
        index_tag,
        coo,
        BufferDescriptor(offset=Int64(0), length=Int64(0)),
    )
    var msg = write_message(w, Int16(4), header_tag, pos, Int64(8))
    var fb = w^.finalize(msg)
    var body = List[UInt8]()
    for i in range(8):
        body.append(UInt8(i))
    var w2 = FlatbufWriter(64)
    return write_ipc_message(w2, fb^, Span(body), True)


def _decode_error(var frame: SharedAlignedBuffer[HeapRegion]) -> String:
    try:
        _ = decode_sparse_tensor(frame^)
    except e:
        return String(e)
    return String("no error")


def test_hand_built_frame_with_a_coo_index_decodes() raises:
    """The control: the frame every refusal below changes one field of
    decodes."""
    var d = decode_sparse_tensor(
        _frame(MESSAGE_HEADER_SPARSE_TENSOR, False, 2, SPARSE_TENSOR_INDEX_COO)
    )
    assert_equal(d.dtype, ArrowType.INT8)
    assert_equal(d.ndim, 2)
    assert_equal(d.index_kind, SPARSE_KIND_COO)
    assert_equal(d.index_bit_width, 64)


def test_decode_refuses_a_tensor_header() raises:
    var msg = _decode_error(
        _frame(MESSAGE_HEADER_TENSOR, False, 2, SPARSE_TENSOR_INDEX_COO)
    )
    assert_true(
        "decode_sparse_tensor: expected SparseTensor header (tag 5), got 4"
        in msg,
        msg,
    )


def test_decode_refuses_zero_and_nine_dimensions() raises:
    var msg = _decode_error(
        _frame(MESSAGE_HEADER_SPARSE_TENSOR, False, 0, SPARSE_TENSOR_INDEX_COO)
    )
    assert_true("decode_sparse_tensor: ndim 0 out of range [1, 8]" in msg, msg)
    msg = _decode_error(
        _frame(MESSAGE_HEADER_SPARSE_TENSOR, False, 9, SPARSE_TENSOR_INDEX_COO)
    )
    assert_true("decode_sparse_tensor: ndim 9 out of range [1, 8]" in msg, msg)
    var d = decode_sparse_tensor(
        _frame(MESSAGE_HEADER_SPARSE_TENSOR, False, 8, SPARSE_TENSOR_INDEX_COO)
    )
    assert_equal(d.ndim, 8)


def test_decode_refuses_utf8_values() raises:
    var msg = _decode_error(
        _frame(MESSAGE_HEADER_SPARSE_TENSOR, True, 2, SPARSE_TENSOR_INDEX_COO)
    )
    assert_true(
        "decode_sparse_tensor: unsupported Type tag 5 (only Int +" in msg, msg
    )


def test_decode_refuses_csf_and_an_unknown_index_tag() raises:
    var msg = _decode_error(
        _frame(MESSAGE_HEADER_SPARSE_TENSOR, False, 2, SPARSE_TENSOR_INDEX_CSF)
    )
    assert_true(
        "decode_sparse_tensor: CSF index_kind is not supported" in msg, msg
    )
    msg = _decode_error(
        _frame(MESSAGE_HEADER_SPARSE_TENSOR, False, 2, UInt8(4))
    )
    assert_true("decode_sparse_tensor: unknown sparse_index_tag 4" in msg, msg)


def main() raises:
    var suite = TestSuite()
    suite.test[test_coo_float32_with_dim_names_round_trips]()
    suite.test[test_coo_with_only_a_later_dim_named_keeps_both_names]()
    suite.test[test_encode_refuses_dim_names_of_the_wrong_length]()
    suite.test[test_hand_built_frame_with_a_coo_index_decodes]()
    suite.test[test_decode_refuses_a_tensor_header]()
    suite.test[test_decode_refuses_zero_and_nine_dimensions]()
    suite.test[test_decode_refuses_utf8_values]()
    suite.test[test_decode_refuses_csf_and_an_unknown_index_tag]()
    suite^.run()
