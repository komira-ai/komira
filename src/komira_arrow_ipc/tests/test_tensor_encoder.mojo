# =============================================================================
# test_tensor_encoder.mojo — TensorColumn ↔ Arrow IPC round-trip
# =============================================================================
#
# Round-trip tests for the end-to-end TensorColumn encode/decode path:
#   TensorColumn → encode_tensor → SharedAlignedBuffer[HeapRegion] (IPC frame)
#                → decode_tensor → TensorColumn (byte-identical)
#
# The encoder's output for a 1D Int64 1000-element Tensor should
# structurally match pyarrow's encoding of the same tensor. Byte-level
# identity is NOT asserted here — that is the pyarrow parity test's job —
# but structural fields (shape, dtype, body length) must match.
# =============================================================================

from std.collections import Array
from std.testing import TestSuite, assert_equal, assert_true

from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion
from komira_arrow.arrow_types import ArrowType
from komira_arrow_ipc.tensor_column import (
    MAX_TENSOR_DIMS,
    TensorColumn,
    empty_shape,
    tensor_byte_size,
)
from komira_arrow_ipc.tensor_encoder import encode_tensor, decode_tensor


# ---------------------------------------------------------------------------
# Helper — build a TensorColumn from primitive shape/body.
# ---------------------------------------------------------------------------


def _build_int64_1d(values: List[Int64]) raises -> TensorColumn:
    """Construct a 1D Int64 TensorColumn from a list of values.

    Writes values as little-endian 8-byte i64s into the body buffer.
    """
    var n = len(values)
    var shape = empty_shape()
    shape[0] = n
    var body = SharedAlignedBuffer[HeapRegion].heap_owned(n * 8)
    for i in range(n):
        var v = values[i]
        body.write_i64_le_at(i * 8, v)
    body.set_length(n * 8)

    return TensorColumn(
        dtype=ArrowType.INT64,
        ndim=1,
        shape=shape^,
        dim_names=List[String](),
        body=body^,
    )


# ---------------------------------------------------------------------------
# Round-trip tests
# ---------------------------------------------------------------------------


def test_round_trip_1d_int64_small() raises:
    """5-element 1D Int64 tensor round-trips byte-identical."""
    var vals = List[Int64]()
    vals.append(Int64(10))
    vals.append(Int64(20))
    vals.append(Int64(30))
    vals.append(Int64(40))
    vals.append(Int64(50))
    var t = _build_int64_1d(vals)
    var frame = encode_tensor(t^)
    var decoded = decode_tensor(frame^)
    assert_equal(decoded.dtype, ArrowType.INT64)
    assert_equal(decoded.ndim, 1)
    assert_equal(decoded.shape[0], 5)
    assert_equal(decoded.body.len(), 40)  # 5 * 8 bytes
    for i in range(5):
        assert_equal(decoded.body.read_i64_le_at(i * 8), vals[i])


def test_round_trip_1d_int64_1000() raises:
    """1000-element Int64 tensor (the pyarrow fixture's size)
    round-trips correctly. Body length should be 8000 bytes."""
    var vals = List[Int64]()
    vals.reserve(1000)
    for i in range(1000):
        vals.append(Int64(i))
    var t = _build_int64_1d(vals)
    var frame = encode_tensor(t^)
    var decoded = decode_tensor(frame^)
    assert_equal(decoded.dtype, ArrowType.INT64)
    assert_equal(decoded.ndim, 1)
    assert_equal(decoded.shape[0], 1000)
    assert_equal(decoded.body.len(), 8000)
    # Spot-check a few values.
    assert_equal(decoded.body.read_i64_le_at(0), Int64(0))
    assert_equal(decoded.body.read_i64_le_at(500 * 8), Int64(500))
    assert_equal(decoded.body.read_i64_le_at(999 * 8), Int64(999))


def test_round_trip_2d_int32_with_dim_names() raises:
    """2D Int32 tensor with dim_names round-trips with names preserved."""
    var shape = empty_shape()
    shape[0] = 4  # rows
    shape[1] = 3  # cols
    var body = SharedAlignedBuffer[HeapRegion].heap_owned(4 * 3 * 4)  # 4 bytes per i32
    var idx = 0
    for r in range(4):
        for c in range(3):
            var v = Int32(r * 100 + c)
            body.write_i32_le_at(idx * 4, v)
            idx += 1
    body.set_length(4 * 3 * 4)

    var names = List[String]()
    names.append(String("rows"))
    names.append(String("cols"))
    var t = TensorColumn(
        dtype=ArrowType.INT32,
        ndim=2,
        shape=shape^,
        dim_names=names^,
        body=body^,
    )
    var frame = encode_tensor(t^)
    var decoded = decode_tensor(frame^)
    assert_equal(decoded.dtype, ArrowType.INT32)
    assert_equal(decoded.ndim, 2)
    assert_equal(decoded.shape[0], 4)
    assert_equal(decoded.shape[1], 3)
    assert_equal(decoded.body.len(), 48)
    assert_equal(len(decoded.dim_names), 2)
    assert_equal(String(decoded.dim_names[0]), String("rows"))
    assert_equal(String(decoded.dim_names[1]), String("cols"))
    # Spot-check first + last value.
    assert_equal(decoded.body.read_i32_le_at(0), Int32(0))
    assert_equal(decoded.body.read_i32_le_at(11 * 4), Int32(302))


def test_round_trip_3d_uint8() raises:
    """3D UInt8 tensor (typical image batch shape NHWC=2,2,2,3 would
    be 4D; we use a 3D NHC=2,2,3 to test 3-dim handling)."""
    var shape = empty_shape()
    shape[0] = 2
    shape[1] = 2
    shape[2] = 3
    var body = SharedAlignedBuffer[HeapRegion].heap_owned(2 * 2 * 3)
    for i in range(2 * 2 * 3):
        body.write_u8_at(i, UInt8(i))
    body.set_length(2 * 2 * 3)

    var t = TensorColumn(
        dtype=ArrowType.UINT8,
        ndim=3,
        shape=shape^,
        dim_names=List[String](),
        body=body^,
    )
    var frame = encode_tensor(t^)
    var decoded = decode_tensor(frame^)
    assert_equal(decoded.dtype, ArrowType.UINT8)
    assert_equal(decoded.ndim, 3)
    assert_equal(decoded.shape[0], 2)
    assert_equal(decoded.shape[1], 2)
    assert_equal(decoded.shape[2], 3)
    assert_equal(decoded.body.len(), 12)
    for i in range(12):
        assert_equal(decoded.body.read_u8_at(i), UInt8(i))


# ---------------------------------------------------------------------------
# Error path tests
# ---------------------------------------------------------------------------


def test_body_size_mismatch_raises() raises:
    """encode_tensor raises when body length != product(shape) * sizeof(dtype)."""
    var shape = empty_shape()
    shape[0] = 10  # claims 10 i64 elements = 80 bytes
    var body = SharedAlignedBuffer[HeapRegion].heap_owned(40)  # but body is 40 bytes
    body.set_length(40)

    var t = TensorColumn(
        dtype=ArrowType.INT64,
        ndim=1,
        shape=shape^,
        dim_names=List[String](),
        body=body^,
    )
    var threw = False
    try:
        var _frame = encode_tensor(t^)
    except _:
        threw = True
    assert_true(threw)


def test_dim_names_length_mismatch_raises() raises:
    """encode_tensor raises when dim_names has wrong length (must be 0
    or equal to ndim)."""
    var shape = empty_shape()
    shape[0] = 3
    shape[1] = 4
    var body = SharedAlignedBuffer[HeapRegion].heap_owned(3 * 4 * 8)
    body.set_length(3 * 4 * 8)

    var names = List[String]()
    names.append(String("only_one"))  # length 1 but ndim=2
    var t = TensorColumn(
        dtype=ArrowType.INT64,
        ndim=2,
        shape=shape^,
        dim_names=names^,
        body=body^,
    )
    var threw = False
    try:
        var _frame = encode_tensor(t^)
    except _:
        threw = True
    assert_true(threw)


# ---------------------------------------------------------------------------
# tensor_byte_size helper tests
# ---------------------------------------------------------------------------


def test_tensor_byte_size_int64() raises:
    """tensor_byte_size for INT64 returns product(shape) * 8."""
    var shape = empty_shape()
    shape[0] = 10
    shape[1] = 20
    assert_equal(tensor_byte_size(ArrowType.INT64, shape, 2), 1600)


def test_tensor_byte_size_float32() raises:
    """tensor_byte_size for FLOAT32 returns product(shape) * 4."""
    var shape = empty_shape()
    shape[0] = 7
    shape[1] = 11
    shape[2] = 13
    assert_equal(
        tensor_byte_size(ArrowType.FLOAT32, shape, 3), 7 * 11 * 13 * 4
    )


# ---------------------------------------------------------------------------
# TestSuite registration
# ---------------------------------------------------------------------------


def main() raises:
    var suite = TestSuite()
    suite.test[test_round_trip_1d_int64_small]()
    suite.test[test_round_trip_1d_int64_1000]()
    suite.test[test_round_trip_2d_int32_with_dim_names]()
    suite.test[test_round_trip_3d_uint8]()
    suite.test[test_body_size_mismatch_raises]()
    suite.test[test_dim_names_length_mismatch_raises]()
    suite.test[test_tensor_byte_size_int64]()
    suite.test[test_tensor_byte_size_float32]()
    suite^.run()
