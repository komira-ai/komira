# =============================================================================
# sparse_tensor_column.mojo — SparseTensorColumn value type
# =============================================================================
#
# In-memory SparseTensor value matching Apache Arrow SparseTensor.fbs:
#
#   table SparseTensor {
#       0: type: Type union (fixed-width primitives)
#       2: shape: [TensorDim]
#       3: non_zero_length: i64
#       4: sparseIndex_type: u8 union discriminator
#       5: sparseIndex: union payload (offset to SparseTensorIndex variant)
#       6: data: Buffer (inline 16-byte struct)
#   }
#
# Body layout depends on index_kind:
#   COO: [indices_bytes][pad to 8B][values_bytes]
#   CSX: [indptr_bytes][pad][indices_bytes][pad][values_bytes]
#   CSF: not supported.
#
# Design:
#   - Index bytes are stored separately from values bytes so callers
#     don't have to pre-pack the wire layout. The encoder handles
#     packing + alignment.
#   - All index integer buffers use a single declared bit_width
#     (typically 32 or 64) and are signed per pyarrow's COO/CSX convention.
#   - CSX always has indptr + indices using the SAME dtype.
# =============================================================================

from std.collections import Array
from komira_core.arrow.shared_aligned_buffer import SharedAlignedBuffer
from komira_core.arrow.arrow_types import ArrowType
from komira_core.io.heap_region import HeapRegion
from .tensor_column import MAX_TENSOR_DIMS


# Sparse index kind tags. Mirror SPARSE_TENSOR_INDEX_* in ipc_flatbuf.
comptime SPARSE_KIND_COO: UInt8 = 1
comptime SPARSE_KIND_CSX: UInt8 = 2
# CSF (3) is not supported. Raise on encode/decode.

# CSX compressed-axis tags. Mirror SPARSE_AXIS_* in ipc_flatbuf.
comptime SPARSE_AXIS_ROW_CSR: UInt8 = 0  # CSR — row-compressed
comptime SPARSE_AXIS_COLUMN_CSC: UInt8 = 1  # CSC — column-compressed


@fieldwise_init
struct SparseTensorColumn(Movable):
    """In-memory Arrow SparseTensor value.

    Supports COO + CSX (CSR / CSC) index kinds. CSF is not supported.

    Fields:
        dtype: ArrowType for the non-zero values.
        ndim: Number of valid entries in `shape`. COO supports any ndim;
            CSX requires ndim==2.
        shape: Logical shape per dimension.
        dim_names: Optional dimension labels (empty or len == ndim).
        non_zero_length: Number of non-zero entries.
        index_kind: SPARSE_KIND_COO or SPARSE_KIND_CSX.
        index_bit_width: Bit width of index integers (32 or 64).
        is_canonical: For COO only — Arrow's is_canonical flag (set if
            indices are sorted lex by (dim_0, dim_1, ...). Default False.
        compressed_axis: For CSX only — SPARSE_AXIS_ROW_CSR (CSR) or
            SPARSE_AXIS_COLUMN_CSC (CSC). Ignored for COO.
        indptr_bytes: For CSX only — indptr array bytes. Length =
            (compressed_axis_size + 1) * (index_bit_width / 8).
            Empty (length==0) for COO.
        indices_bytes: COO: shape (non_zero, ndim) of index_bit_width
            integers. CSX: indices array, length = non_zero *
            (index_bit_width / 8).
        values_bytes: The non-zero element bytes. Length =
            non_zero_length * sizeof(dtype).
    """
    var dtype: ArrowType
    var ndim: Int
    var shape: Array[Int, MAX_TENSOR_DIMS]
    var dim_names: List[String]
    var non_zero_length: Int64
    var index_kind: UInt8
    var index_bit_width: Int
    var is_canonical: Bool
    var compressed_axis: UInt8
    var indptr_bytes: SharedAlignedBuffer[HeapRegion]
    var indices_bytes: SharedAlignedBuffer[HeapRegion]
    var values_bytes: SharedAlignedBuffer[HeapRegion]


# =============================================================================
# Construction helpers
# =============================================================================


def _pad_to_8(n: Int) -> Int:
    """Round `n` up to the nearest multiple of 8 (Arrow body alignment)."""
    return ((n + 7) // 8) * 8
