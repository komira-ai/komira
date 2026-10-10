# =============================================================================
# test_tensor_encoder_arms.mojo: every dtype arm of the Tensor codec, and
# every refusal of decode_tensor on a hand-built frame
# =============================================================================
#
# test_tensor_encoder.mojo round-trips INT64, INT32 and UINT8. This file
# round-trips every other dtype the encoder accepts (so each arm of the
# dtype -> Type table, dtype -> IPC tag and Type table -> dtype maps runs and
# must agree with its inverse), and feeds decode_tensor frames written
# directly with the ipc_flatbuf writers: a non-Tensor header, zero and nine
# dimensions, a Utf8 Type, an Int of width 128, a FloatingPoint of precision
# 7, explicit row-major strides (accepted) and wrong strides (refused), and a
# data length past the body.
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
    MESSAGE_HEADER_RECORD_BATCH,
    TYPE_INT,
    TYPE_FLOATING_POINT,
    TYPE_UTF8,
    write_tensor,
    write_message,
    write_ipc_message,
    write_type_int,
    write_type_floating_point,
    write_type_utf8,
)
from komira_arrow_ipc.tensor_column import (
    TensorColumn,
    empty_shape,
    tensor_byte_size,
)
from komira_arrow_ipc.tensor_encoder import (
    encode_tensor,
    decode_tensor,
    _write_type_for_dtype,
    _arrow_type_to_ipc_tag,
    _elt_size_for_dtype,
)


# ---------------------------------------------------------------------------
# Round trips of every dtype arm
# ---------------------------------------------------------------------------


def _round_trip(dtype: ArrowType, elt: Int) raises:
    """A 2x3 tensor of `dtype` (element size `elt`) whose bytes are 0..N-1
    decodes to the same dtype, shape and bytes."""
    var shape = empty_shape()
    shape[0] = 2
    shape[1] = 3
    var n = 6 * elt
    assert_equal(tensor_byte_size(dtype, shape, 2), n)
    var body = SharedAlignedBuffer[HeapRegion].heap_owned(n)
    for i in range(n):
        body.write_u8_at(i, UInt8(i + 1))
    body.set_length(n)
    var t = TensorColumn(
        dtype=dtype, ndim=2, shape=shape^, dim_names=List[String](), body=body^
    )
    var decoded = decode_tensor(encode_tensor(t^))
    assert_equal(decoded.dtype, dtype)
    assert_equal(decoded.ndim, 2)
    assert_equal(decoded.shape[0], 2)
    assert_equal(decoded.shape[1], 3)
    assert_equal(decoded.body.len(), n)
    for i in range(n):
        assert_equal(decoded.body.read_u8_at(i), UInt8(i + 1))
    assert_equal(_elt_size_for_dtype(dtype), elt)


def test_round_trip_every_signed_int() raises:
    _round_trip(ArrowType.INT8, 1)
    _round_trip(ArrowType.INT16, 2)


def test_round_trip_every_unsigned_int() raises:
    _round_trip(ArrowType.UINT16, 2)
    _round_trip(ArrowType.UINT32, 4)
    _round_trip(ArrowType.UINT64, 8)


def test_round_trip_every_float() raises:
    _round_trip(ArrowType.FLOAT16, 2)
    _round_trip(ArrowType.FLOAT32, 4)
    _round_trip(ArrowType.FLOAT64, 8)


def test_elt_size_of_the_round_tripped_int_widths() raises:
    """The decoder's local size table agrees with tensor_column's for the
    widths test_tensor_encoder.mojo round-trips."""
    assert_equal(_elt_size_for_dtype(ArrowType.UINT8), 1)
    assert_equal(_elt_size_for_dtype(ArrowType.INT32), 4)
    assert_equal(_elt_size_for_dtype(ArrowType.INT64), 8)


# ---------------------------------------------------------------------------
# Refusals of the dtype maps and of tensor_byte_size
# ---------------------------------------------------------------------------


def test_type_maps_refuse_a_non_primitive_dtype() raises:
    var w = FlatbufWriter(256)
    var msg = String("")
    try:
        _ = _write_type_for_dtype(w, ArrowType.STRING)
    except e:
        msg = String(e)
    assert_true("tensor encoder: unsupported dtype 13" in msg, msg)
    msg = String("")
    try:
        _ = _arrow_type_to_ipc_tag(ArrowType.STRING)
    except e:
        msg = String(e)
    assert_true("tensor encoder: no IPC tag for dtype 13" in msg, msg)
    msg = String("")
    try:
        _ = _elt_size_for_dtype(ArrowType.BINARY)
    except e:
        msg = String(e)
    assert_true("tensor decoder: unsupported dtype 14" in msg, msg)


def test_tensor_byte_size_refusals() raises:
    var shape = empty_shape()
    shape[0] = 2
    var msg = String("")
    try:
        _ = tensor_byte_size(ArrowType.INT8, shape, 0)
    except e:
        msg = String(e)
    assert_true("tensor_byte_size: ndim 0 out of range [1, 8]" in msg, msg)
    msg = String("")
    try:
        _ = tensor_byte_size(ArrowType.INT8, shape, 9)
    except e:
        msg = String(e)
    assert_true("tensor_byte_size: ndim 9 out of range" in msg, msg)
    shape[1] = -1
    msg = String("")
    try:
        _ = tensor_byte_size(ArrowType.INT8, shape, 2)
    except e:
        msg = String(e)
    assert_true("tensor_byte_size: negative size at dim 1" in msg, msg)
    msg = String("")
    try:
        _ = tensor_byte_size(ArrowType.BOOL, shape, 1)
    except e:
        msg = String(e)
    assert_true("tensor: BOOL dtype not supported" in msg, msg)
    msg = String("")
    try:
        _ = tensor_byte_size(ArrowType.STRING, shape, 1)
    except e:
        msg = String(e)
    assert_true("tensor: unsupported dtype 13" in msg, msg)
    # A size-0 dimension is not negative: the tensor is empty.
    shape[1] = 0
    assert_equal(tensor_byte_size(ArrowType.FLOAT64, shape, 2), 0)


# ---------------------------------------------------------------------------
# Hand-built frames for decode_tensor
# ---------------------------------------------------------------------------

comptime _KIND_INT = 0
comptime _KIND_FP = 1
comptime _KIND_UTF8 = 2


def _frame(
    header_tag: UInt8,
    kind: Int,
    width_or_precision: Int,
    dims: List[Int],
    strides: List[Int64],
    data_len: Int,
    body_len: Int,
) raises -> SharedAlignedBuffer[HeapRegion]:
    """An IPC frame whose Message has `header_tag` over a Tensor table of
    the given Type, dimensions, strides and data length, followed by
    `body_len` body bytes (byte i = i + 1)."""
    var w = FlatbufWriter(2048)
    var type_pos: Int
    var tag: UInt8
    if kind == _KIND_INT:
        type_pos = write_type_int(w, width_or_precision, True)
        tag = TYPE_INT
    elif kind == _KIND_FP:
        type_pos = write_type_floating_point(w, width_or_precision)
        tag = TYPE_FLOATING_POINT
    else:
        type_pos = write_type_utf8(w)
        tag = TYPE_UTF8
    var shape = List[TensorDimDescriptor]()
    for i in range(len(dims)):
        shape.append(TensorDimDescriptor(size=Int64(dims[i]), name=String("")))
    var data = BufferDescriptor(offset=Int64(0), length=Int64(data_len))
    var tensor_pos = write_tensor(w, tag, type_pos, shape, strides, data)
    var msg_pos = write_message(
        w, Int16(4), header_tag, tensor_pos, Int64(body_len)
    )
    var fb = w^.finalize(msg_pos)
    var body = List[UInt8]()
    for i in range(body_len):
        body.append(UInt8(i + 1))
    var w2 = FlatbufWriter(64)
    return write_ipc_message(w2, fb^, Span(body), True)


def _decode_error(var frame: SharedAlignedBuffer[HeapRegion]) -> String:
    try:
        _ = decode_tensor(frame^)
    except e:
        return String(e)
    return String("no error")


def _dims(a: Int, b: Int) -> List[Int]:
    var d = List[Int]()
    d.append(a)
    d.append(b)
    return d^


def test_decode_refuses_a_non_tensor_header() raises:
    var msg = _decode_error(
        _frame(MESSAGE_HEADER_RECORD_BATCH, _KIND_INT, 8, _dims(2, 2),
               List[Int64](), 4, 4)
    )
    assert_true(
        "decode_tensor: expected Tensor header (tag 4), got 3" in msg, msg
    )


def test_decode_refuses_zero_and_nine_dimensions() raises:
    var msg = _decode_error(
        _frame(MESSAGE_HEADER_TENSOR, _KIND_INT, 8, List[Int](),
               List[Int64](), 0, 0)
    )
    assert_true("decode_tensor: ndim 0 out of range [1, 8]" in msg, msg)
    var nine = List[Int]()
    for _ in range(9):
        nine.append(1)
    msg = _decode_error(
        _frame(MESSAGE_HEADER_TENSOR, _KIND_INT, 8, nine, List[Int64](), 1, 1)
    )
    assert_true("decode_tensor: ndim 9 out of range [1, 8]" in msg, msg)


def test_decode_eight_dimensions_is_the_largest_accepted() raises:
    var eight = List[Int]()
    for _ in range(8):
        eight.append(1)
    var t = decode_tensor(
        _frame(MESSAGE_HEADER_TENSOR, _KIND_INT, 8, eight, List[Int64](), 1, 8)
    )
    assert_equal(t.ndim, 8)
    assert_equal(t.dtype, ArrowType.INT8)


def test_decode_refuses_a_utf8_type() raises:
    var msg = _decode_error(
        _frame(MESSAGE_HEADER_TENSOR, _KIND_UTF8, 0, _dims(1, 1),
               List[Int64](), 0, 0)
    )
    assert_true(
        "decode_tensor: unsupported Type tag 5 (only Int + FloatingPoint"
        in msg,
        msg,
    )


def test_decode_refuses_an_unknown_int_width_and_fp_precision() raises:
    var msg = _decode_error(
        _frame(MESSAGE_HEADER_TENSOR, _KIND_INT, 128, _dims(1, 1),
               List[Int64](), 0, 0)
    )
    assert_true("tensor decoder: unknown Int width 128" in msg, msg)
    msg = _decode_error(
        _frame(MESSAGE_HEADER_TENSOR, _KIND_FP, 7, _dims(1, 1),
               List[Int64](), 0, 0)
    )
    assert_true("tensor decoder: unknown FP precision 7" in msg, msg)


def test_decode_accepts_row_major_strides() raises:
    """Strides equal to the row-major ones of a 2x3x4 FLOAT32 tensor
    (48, 16, 4) are accepted and change nothing."""
    var dims = List[Int]()
    dims.append(2)
    dims.append(3)
    dims.append(4)
    var strides = List[Int64]()
    strides.append(48)
    strides.append(16)
    strides.append(4)
    var t = decode_tensor(
        _frame(MESSAGE_HEADER_TENSOR, _KIND_FP, 1, dims, strides, 96, 96)
    )
    assert_equal(t.dtype, ArrowType.FLOAT32)
    assert_equal(t.ndim, 3)
    assert_equal(t.shape[2], 4)
    assert_equal(t.body.len(), 96)
    assert_equal(t.body.read_u8_at(95), UInt8(96))


def test_decode_refuses_strides_of_another_layout() raises:
    """Column-major strides (8, 16) of a 2x3 INT64 tensor: dim 0 differs
    from row-major (24); the same tensor with only the last stride wrong
    names dim 1."""
    var strides = List[Int64]()
    strides.append(8)
    strides.append(16)
    var msg = _decode_error(
        _frame(MESSAGE_HEADER_TENSOR, _KIND_INT, 64, _dims(2, 3), strides,
               48, 48)
    )
    assert_true(
        "decode_tensor: non-contiguous tensor (stride mismatch at dim 0)"
        in msg,
        msg,
    )
    var last = List[Int64]()
    last.append(24)
    last.append(16)
    msg = _decode_error(
        _frame(MESSAGE_HEADER_TENSOR, _KIND_INT, 64, _dims(2, 3), last, 48, 48)
    )
    assert_true("stride mismatch at dim 1)" in msg, msg)


def test_decode_refuses_data_longer_than_the_body() raises:
    var msg = _decode_error(
        _frame(MESSAGE_HEADER_TENSOR, _KIND_INT, 8, _dims(2, 4),
               List[Int64](), 16, 8)
    )
    assert_true(
        "decode_tensor: Tensor.data.length 16 > body_size 8" in msg, msg
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_round_trip_every_signed_int]()
    suite.test[test_round_trip_every_unsigned_int]()
    suite.test[test_round_trip_every_float]()
    suite.test[test_elt_size_of_the_round_tripped_int_widths]()
    suite.test[test_type_maps_refuse_a_non_primitive_dtype]()
    suite.test[test_tensor_byte_size_refusals]()
    suite.test[test_decode_refuses_a_non_tensor_header]()
    suite.test[test_decode_refuses_zero_and_nine_dimensions]()
    suite.test[test_decode_eight_dimensions_is_the_largest_accepted]()
    suite.test[test_decode_refuses_a_utf8_type]()
    suite.test[test_decode_refuses_an_unknown_int_width_and_fp_precision]()
    suite.test[test_decode_accepts_row_major_strides]()
    suite.test[test_decode_refuses_strides_of_another_layout]()
    suite.test[test_decode_refuses_data_longer_than_the_body]()
    suite^.run()
