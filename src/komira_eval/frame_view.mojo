# =============================================================================
# frame_view.mojo — the bounded multi-row FRAME accessor for custom WindowFn
# =============================================================================
#
# The multi-row GENERALIZATION of `partition_row_view.PartitionRowView`: where the
# partition-UDF row view reads ONLY the current `(batch, row)` cell, a window fn
# needs a bounded view of the FRAME rows `[lo, hi)` within the sorted partition
# buffer. `FrameView` keeps `PartitionRowView`'s EXACT encapsulation shape
# (`Pointer[RecordBatch, origin]` + the resolved UDF-input -> batch-column index
# map) and ADDS the `[lo, hi)` frame bounds.
#
# # The ROW-VIEW inversion
#
# The engine does NOT assemble a het-pack and hand it to a variadic user call
# (Mojo 1.0.0b1 cannot drive that generically — tuple-splat crashes
# `ParamInf::inferForCall`, het-Tuple assembly is rejected, opaque `InRow` has
# no generic ctor). The engine hands the UDF a MONOMORPHIC `FrameView` and the
# UDF reads its OWN inputs by comptime index. `WindowFn`'s
# `compute_frame` / `emit` / `enter_row` / `leave_row` therefore receive a
# `FrameView`; the per-arity unrolling lives in the UDF (which knows its arity +
# per-position dtypes from `InputSchema`), and the engine drives ONE
# arity-agnostic frame scan with NO `comptime if n_in == N` ladder. This is the
# SAME inversion `partition_local` validated — NO new variadic machinery.
#
# # Lifetime contract (inherited from `PartitionRowView`)
#
# `FrameView` carries a concrete `origin` tied to the operator's borrowed sorted
# batch — the SAME contract `PartitionRowView` enforces. The Mojo lifetime
# checker rejects stashing a `FrameView` (or a `ref` from it) in `Self.State`
# (which outlives the call). The user copies out scalar values via `get[...]()`
# (returns by value); those copies are unrelated to the operator's buffer. NO
# new lifetime machinery.
#
# # Encapsulation invariants
#   - NO UnsafePointer in any signature; NO wildcard origins; NO
#     unsafe_from_address; NO take_pointee; NO ArcPointer. The canonical
#     `BatchView` shape: a `Pointer[RecordBatch, origin]` field with a CONCRETE
#     origin parameter, re-deriving the typed cell read per call. The view's
#     lifetime is bound by `origin`; it cannot outlive the borrowed batch.
# =============================================================================

from komira_core.arrow.record_batch import RecordBatch

from komira_eval.partition_row_view import MAX_PARTITION_UDF_ARITY


struct FrameView[origin: Origin[mut=False]](Copyable, Movable):
    """A monomorphic bounded-frame accessor over `(batch, [lo, hi))` that maps
    the UDF's OWN 0-based input position to a resolved batch column index.

    The engine constructs ONE per output row in a single arity-agnostic loop;
    the UDF reads `view.get[frame_idx, local_input_idx, dt]()` for each frame
    row it needs. The view re-derives the typed cell read per call (the
    canonical `BatchView` pattern — a `Pointer[RecordBatch, origin]` field with
    the row resolved as `_lo + frame_idx`).

    Parameters:
        origin: The immutable Origin under which the borrowed sorted batch
            lives. The view cannot outlive `origin`.

    Fields:
        _batch: borrowed sorted partition buffer (concrete origin — no
            wildcard, no UnsafePointer).
        _cols : resolved UDF-input-position -> batch-column-index map (POD,
            slab-safe — no heap-owning element).
        _lo   : inclusive lower bound (absolute row index into `_batch`).
        _hi   : exclusive upper bound (absolute row index into `_batch`).
    """

    var _batch: Pointer[RecordBatch, Self.origin]
    # Resolved batch column index for each of the UDF's input positions. POD
    # fixed array — slab-safe (no heap-owning element), no wildcard origin.
    var _cols: Array[Int, MAX_PARTITION_UDF_ARITY]
    var _lo: Int
    var _hi: Int

    @always_inline
    def __init__(
        out self,
        ptr: Pointer[RecordBatch, Self.origin],
        cols: Array[Int, MAX_PARTITION_UDF_ARITY],
        lo: Int,
        hi: Int,
    ):
        self._batch = ptr
        self._cols = cols.copy()
        self._lo = lo
        self._hi = hi

    @always_inline
    def __len__(self) -> Int:
        """The frame width `hi - lo` (the number of rows in this frame)."""
        return self._hi - self._lo

    @always_inline
    def get[
        frame_idx: Int, local_input_idx: Int, dt: DType
    ](self) raises -> Scalar[dt]:
        """Read the `frame_idx`-th frame row's value for the UDF's
        `local_input_idx`-th input as `Scalar[dt]` (i.e. absolute row
        `_lo + frame_idx`). The UDF supplies `frame_idx` (which frame row),
        `local_input_idx` (which of its inputs) + `dt` at comptime (from its
        `InputSchema`); the view resolves the batch column index at runtime and
        re-derives the typed read.

        This is `PartitionRowView.get`'s comptime DType ladder
        (int64 / int32 / float64 / float32) with the row resolved as
        `_lo + frame_idx` instead of a single fixed `_row`. The only change vs
        the partition-UDF view is the row-index arithmetic — the ladder is
        reused verbatim."""
        var col = self._cols[local_input_idx]
        var row = self._lo + frame_idx
        comptime if dt == DType.int64:
            return rebind[Scalar[dt]](
                self._batch[]
                .column_as_primitive_int64(col)
                .load[1](row)[0]
            )
        elif dt == DType.int32:
            return rebind[Scalar[dt]](
                self._batch[]
                .column_as_primitive_int32(col)
                .load[1](row)[0]
            )
        elif dt == DType.float64:
            return rebind[Scalar[dt]](
                self._batch[]
                .column_as_primitive_float64(col)
                .load[1](row)[0]
            )
        elif dt == DType.float32:
            return rebind[Scalar[dt]](
                self._batch[]
                .column_as_primitive_float32(col)
                .load[1](row)[0]
            )
        else:
            comptime assert False, ("FrameView.get: input column DType not supported (supported:"
                " int64 / int32 / float64 / float32).")

    @always_inline
    def get_at[
        local_input_idx: Int, dt: DType
    ](self, frame_idx: Int) raises -> Scalar[dt]:
        """RUNTIME-`frame_idx` variant of `get` — read the `frame_idx`-th frame
        row's value for the UDF's `local_input_idx`-th input. The recompute path
        needs to iterate every frame row (`for i in range(len(view)))`), so
        `frame_idx` is a runtime loop variable here; `local_input_idx` + `dt`
        stay comptime (the UDF's per-input identity). Same comptime DType ladder
        as `get`, only `frame_idx` moves from comptime to runtime."""
        var col = self._cols[local_input_idx]
        var row = self._lo + frame_idx
        comptime if dt == DType.int64:
            return rebind[Scalar[dt]](
                self._batch[]
                .column_as_primitive_int64(col)
                .load[1](row)[0]
            )
        elif dt == DType.int32:
            return rebind[Scalar[dt]](
                self._batch[]
                .column_as_primitive_int32(col)
                .load[1](row)[0]
            )
        elif dt == DType.float64:
            return rebind[Scalar[dt]](
                self._batch[]
                .column_as_primitive_float64(col)
                .load[1](row)[0]
            )
        elif dt == DType.float32:
            return rebind[Scalar[dt]](
                self._batch[]
                .column_as_primitive_float32(col)
                .load[1](row)[0]
            )
        else:
            comptime assert False, ("FrameView.get_at: input column DType not supported (supported:"
                " int64 / int32 / float64 / float32).")
