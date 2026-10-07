# =============================================================================
# partition_row_view.mojo — the arity-agnostic ROW-VIEW for partition-UDF inputs
# =============================================================================
#
# The partition-UDF row-view (the arity-agnostic input reader). The
# ROW-VIEW INVERSION: instead of the engine assembling a heterogeneous
# positional pack and handing it to a single variadic user call
# (`run_scalar_state[*Ts](s, *vals)` — which on Mojo 1.0.0b1 cannot be driven
# generically: tuple-splat crashes `ParamInf::inferForCall`, het-Tuple assembly
# is rejected, and the opaque `InRow` has no generically-callable ctor), the
# engine hands the UDF a MONOMORPHIC accessor and the UDF reads its OWN inputs.
#
# `PartitionRowView[origin]` wraps `(Pointer[RecordBatch, origin], row)` plus a
# comptime-fixed mapping from the UDF's OWN 0-based input position to the
# resolved batch column index. The UDF reads `view.get[local_input_idx, dt]()`
# by comptime column index — it knows its arity + per-position dtypes from its
# `InputSchema`, so the per-arity unrolling moves to the UDF (which knows its
# arity at comptime). The engine constructs ONE view per row in a single
# arity-agnostic loop — NO `comptime if n_in == N` ladder, NO `_call_arityK`
# siblings.
#
# # Encapsulation invariants
#   - NO UnsafePointer in any signature; NO wildcard origins; NO
#     unsafe_from_address; NO take_pointee; NO ArcPointer. This is the canonical
#     `BatchView` shape: a `Pointer[RecordBatch, origin]` field with a CONCRETE
#     origin parameter, re-deriving the typed cell read per call. The view's
#     lifetime is bound by `origin`; it cannot outlive the borrowed batch.
# =============================================================================

from komira_arrow.record_batch import RecordBatch


# Max partition-UDF input arity. The resolved-index map is a fixed InlineArray
# (POD, slab-safe — no heap-owning element); the comptime-known per-UDF arity
# (`InputSchema.num_cols()`) is asserted <= this at the construction site.
comptime MAX_PARTITION_UDF_ARITY: Int = 16


struct PartitionRowView[origin: Origin[mut=False]](Copyable, Movable):
    """A monomorphic per-row accessor over `(batch, row)` that maps the UDF's
    OWN 0-based input position to a resolved batch column index.

    The engine constructs ONE per row in a single arity-agnostic loop; the UDF
    reads `view.get[local_input_idx, dt]()` for each of its inputs. The view
    re-derives the typed cell read per call (the canonical `BatchView` pattern —
    a `Pointer[RecordBatch, origin]` field, sub-origin Column ref consumed
    locally inside each call).

    Parameters:
        origin: The immutable Origin under which the borrowed sorted batch
            lives. The view cannot outlive `origin`.
    """

    var _batch: Pointer[RecordBatch, Self.origin]
    var _row: Int
    # Resolved batch column index for each of the UDF's input positions. POD
    # fixed array — slab-safe (no heap-owning element), no wildcard origin.
    var _cols: Array[Int, MAX_PARTITION_UDF_ARITY]

    @always_inline
    def __init__(
        out self,
        ptr: Pointer[RecordBatch, Self.origin],
        row: Int,
        cols: Array[Int, MAX_PARTITION_UDF_ARITY],
    ):
        self._batch = ptr
        self._row = row
        self._cols = cols.copy()

    @always_inline
    def get[local_input_idx: Int, dt: DType](self) raises -> Scalar[dt]:
        """Read this row's value for the UDF's `local_input_idx`-th input as
        `Scalar[dt]`. The UDF supplies `local_input_idx` + `dt` at comptime
        (from its `InputSchema`); the view resolves the batch column index at
        runtime and re-derives the typed read.

        Comptime DType ladder — same 4-numeric-DType coverage as the prior
        `_read_cell` (int64 / int32 / float64 / float32)."""
        var col = self._cols[local_input_idx]
        comptime if dt == DType.int64:
            return rebind[Scalar[dt]](
                self._batch[]
                .column_as_primitive_int64(col)
                .load[1](self._row)[0]
            )
        elif dt == DType.int32:
            return rebind[Scalar[dt]](
                self._batch[]
                .column_as_primitive_int32(col)
                .load[1](self._row)[0]
            )
        elif dt == DType.float64:
            return rebind[Scalar[dt]](
                self._batch[]
                .column_as_primitive_float64(col)
                .load[1](self._row)[0]
            )
        elif dt == DType.float32:
            return rebind[Scalar[dt]](
                self._batch[]
                .column_as_primitive_float32(col)
                .load[1](self._row)[0]
            )
        else:
            comptime assert False, ("PartitionRowView.get: input column DType not supported (supported:"
                " int64 / int32 / float64 / float32).")
