# =============================================================================
# tensor_column.mojo — TensorColumn value type
# =============================================================================
#
# In-memory Tensor value matching Apache Arrow Tensor.fbs:
#
#   table Tensor {
#       0: type: Type union  (limited to fixed-width primitives in practice)
#       2: shape: [TensorDim]
#       3: strides: [i64]    (absent = contiguous row-major)
#       4: data: Buffer      (inline 16-byte struct: offset + length)
#   }
#
# Design notes:
#   - shape is InlineArray[Int, 8] (bounded, no heap). 8 dims covers
#     image batches (NCHW=4), video batches (NCTHW=5), and most ML
#     tensor shapes; raise the constant if it proves too low.
#   - body is SharedAlignedBuffer[HeapRegion] so the encoder's
#     write_ipc_message path can derive its body span directly.
#   - dim_names is List[String] (empty allowed; len 0 OR len == ndim).
#   - dtype is restricted to fixed-width primitives at encode/decode
#     time (Arrow Tensor spec); we don't enforce here to allow future
#     fixed-size-binary / decimal128 tensors.
#   - CONTIGUOUS ONLY (strides=empty on wire).
#     Non-contiguous tensors raise at encode time.
# =============================================================================

from std.collections import Array
from komira_core.arrow.shared_aligned_buffer import SharedAlignedBuffer
from komira_core.arrow.arrow_types import ArrowType
from komira_core.io.heap_region import HeapRegion


comptime MAX_TENSOR_DIMS: Int = 8


@fieldwise_init
struct TensorColumn(Movable):
    """In-memory Arrow Tensor value (contiguous row-major).

    Fields:
        dtype: ArrowType identifying element type. Per Arrow Tensor spec,
            restricted to fixed-width primitive types at encode/decode
            time (INT8..INT64, UINT8..UINT64, FLOAT16/32/64; Decimal128
            and FixedSizeBinary are valid per spec but not supported here).
        ndim: Number of valid entries in `shape`. Range [1, MAX_TENSOR_DIMS].
        shape: Element counts per dimension. Only the first `ndim` are
            populated; remaining are 0.
        dim_names: Optional dimension labels. Empty (len 0) means no
            dim_names; otherwise len must equal ndim. Carries through to
            Arrow Tensor TensorDim.name field.
        body: Raw contiguous bytes, row-major layout, totaling
            `product(shape[:ndim]) * sizeof(dtype)` bytes. SharedAlignedBuffer
            [HeapRegion] so the IPC framing path's body_span can be derived
            directly.
    """
    var dtype: ArrowType
    var ndim: Int
    var shape: Array[Int, MAX_TENSOR_DIMS]
    var dim_names: List[String]
    var body: SharedAlignedBuffer[HeapRegion]


# =============================================================================
# Construction helpers
# =============================================================================


def empty_shape() -> Array[Int, MAX_TENSOR_DIMS]:
    """Return a zero-filled shape array. Caller populates entries
    [0, ndim) before assigning into a TensorColumn."""
    return Array[Int, MAX_TENSOR_DIMS](fill=0)


def tensor_byte_size(dtype: ArrowType, shape: Array[Int, MAX_TENSOR_DIMS], ndim: Int) raises -> Int:
    """Compute the contiguous row-major byte size of a tensor.

    Raises on unsupported dtype (non-primitive).
    """
    if ndim <= 0 or ndim > MAX_TENSOR_DIMS:
        raise Error(
            "tensor_byte_size: ndim "
            + String(ndim)
            + " out of range [1, "
            + String(MAX_TENSOR_DIMS)
            + "]"
        )
    var elt_size = _arrow_type_element_size(dtype)
    var total = 1
    for i in range(ndim):
        if shape[i] < 0:
            raise Error("tensor_byte_size: negative size at dim " + String(i))
        total *= shape[i]
    return total * elt_size


def _arrow_type_element_size(dtype: ArrowType) raises -> Int:
    """Return per-element byte size for fixed-width primitive Arrow types
    supported by the Tensor encoder."""
    if dtype == ArrowType.BOOL:
        # Tensor spec doesn't support Bool (1 bit per element). Reject.
        raise Error("tensor: BOOL dtype not supported (Arrow Tensor spec)")
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
        "tensor: unsupported dtype "
        + String(Int(dtype.type_id))
        + " (only fixed-width primitives in v1)"
    )
