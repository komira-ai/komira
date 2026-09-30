# =============================================================================
# komira_core.tensor — Tensor + SparseTensor value types and encoders
# =============================================================================
#
# First-class SDK types for Apache Arrow Tensor + SparseTensor messages.
# OUTSIDE the Column hierarchy per Arrow spec: Tensor is a separate Arrow
# IPC message type (header_tag=4) with its own Flatbuffers schema; there is
# no Tensor variant in Schema.fbs::Type union, so Tensor cannot appear as
# a RecordBatch column.
#
# Members:
#   tensor_column        — TensorColumn struct (dtype + shape + body)
#   tensor_encoder       — encode_tensor / decode_tensor end-to-end
#   sparse_tensor_column — SparseTensorColumn struct
#   sparse_tensor_encoder — encode_sparse_tensor / decode_sparse_tensor
#
# Shape storage: InlineArray[Int, MAX_TENSOR_DIMS=8] (bounded, no List heap
# on a value type that might cross destroy-recreate cycles).
# Tensors above 8 dimensions are vanishingly rare in practice; if a future
# workload needs more, raise the constant.
# =============================================================================

from .tensor_column import MAX_TENSOR_DIMS, TensorColumn
from .tensor_encoder import encode_tensor, decode_tensor
from .sparse_tensor_column import SparseTensorColumn
from .sparse_tensor_encoder import encode_sparse_tensor, decode_sparse_tensor
