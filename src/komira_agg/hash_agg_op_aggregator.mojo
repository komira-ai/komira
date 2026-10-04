# =============================================================================
# hash_agg_op_aggregator.mojo — HashAggOp* -> Aggregator newtype adapters
# =============================================================================
#
# §2.6 / §2.7, the
# `Aggregator` conformance bridge for the LIVE runtime aggregate path.
#
# WHY AN ADAPTER, NOT A REFINEMENT EDGE
# -------------------------------------
# The ExprX family refines `Predicate` / `RowTransform` directly via trait
# inheritance + a delegating default body — the conformer's static method is
# renamed off the collision and the trait forwards to it. That trick works
# because the conformer ALREADY carries everything the unified surface needs.
#
# `HashAggOp*` (`SumF64` etc., `agg_state_slab.mojo`) CANNOT refine
# `Aggregator` the same way: the shapes genuinely differ.
#   - `HashAggOpF64.update_scalar(mut state, value: Float64)` — a RAW SCALAR.
#   - `Aggregator.update_scalar(mut self, mut state, batch: BatchView, i)` —
#     reads the bound input COLUMN off a `BatchView` at row `i`.
# A `HashAggOp*` conformer is a FIELD-LESS marker with no column binding —
# it has no way to know which column to read. So the bridge needs a real
# wrapper that CARRIES the column index. This is the canonical Rust-style
# newtype adapter: it conforms a foreign-shaped type to a trait. It is NOT
# an additive parallel API — there is no sibling
# trait and no duplicated surface; the adapter IS the single `Aggregator`
# conformance for the `HashAggOp*` family.
#
# THE FOUR ADAPTERS (one per HashAggOp DType family)
# --------------------------------------------------
# `Aggregator.finalize` returns `Scalar[Self.OUT_DT]`; `HashAggOpF64.finalize`
# returns `Float64`, `HashAggOpI64` returns `Int64`, etc. Each adapter pins
# `OUT_DT` to the matching DType, so there is one adapter struct per family:
#   - `HashAggOpF64Agg[Op: HashAggOpF64, col: Int]`  -> OUT_DT = float64
#   - `HashAggOpI64Agg[Op: HashAggOpI64, col: Int]`  -> OUT_DT = int64
#   - `HashAggOpI32Agg[Op: HashAggOpI32, col: Int]`  -> OUT_DT = int32
#   - `HashAggOpF32Agg[Op: HashAggOpF32, col: Int]`  -> OUT_DT = float32
# Each is parametric on the concrete `HashAggOp*` conformer `Op` and the
# comptime input-column index `col`. They are field-less (the params are
# comptime) — trivially `Movable & Copyable & Deinitable`.
#
# `combine` forwards to the conformer's `HashAggOp*.combine` static method
# (`combine` is on the `HashAggOp*` trait surface and all 18 conformers — Sum/Count = add, Min/Max = keep extreme, Avg = lane-add,
# Median = reservoir-append).
#
# `update_chunk[W]` is inherited from `Aggregator`'s Pattern B default body
# (per-lane fan-out over `update_scalar`); no override needed.
#
# Encapsulation invariants:
#   - NO `UnsafePointer` in any signature.
#   - NO wildcard origins — `bo: Origin[mut=False]` threads the per-batch
#     lifetime witness.
#
# Cross-references:
#   - aggregator.mojo — the unified `Aggregator` trait.
#   - agg_op_traits.mojo — the `HashAggOp*` traits (now with `combine`).
#   - komira_engine_operators.agg.agg_state_slab — the `HashAggOp*`
#     conformers.
#   - komira_engine_operators.stage_primitives.hash_agg — `AggSlot[A:
#     Aggregator]` consumes these adapters as the `*Aggs` pack.
# =============================================================================

from komira_core.collections.batch_view import BatchView
from komira_core.collections.morsel_view import MorselView

from komira_agg.aggregator import Aggregator
from komira_agg.agg_op_traits import (
    HashAggOpF32,
    HashAggOpF64,
    HashAggOpI32,
    HashAggOpI64,
)


# =============================================================================
# §1 — HashAggOpF64Agg — Float64 aggregate adapter
# =============================================================================


struct HashAggOpF64Agg[Op: HashAggOpF64, col: Int](Aggregator):
    """`Aggregator` adapter wrapping a `HashAggOpF64` conformer `Op` bound to
    input column `col`. Output DType is `float64`.

    Field-less — `Op` and `col` are comptime parameters. `update_scalar`
    reads column `col` off the `BatchView` as Float64 and forwards the raw
    scalar to `Op.update_scalar`.
    """

    comptime StateTy = Self.Op.StateTy
    comptime OUT_DT: DType = DType.float64

    def __init__(out self):
        """Field-less default ctor. `Op` / `col` are comptime params; an
        adapter instance carries no state. Needed so the `AggSlot[A]` /
        `agg_slot[A]` factory can construct a concrete conformer (the abstract
        `Aggregator` trait declares no `__init__`, and a field-less struct
        without an explicit ctor synthesizes only copy/take ctors)."""
        pass

    @staticmethod
    @always_inline
    def make() -> Self:
        """`Aggregator.make` — field-less default-construct (VARIADIC-FACTORY)."""
        return Self()

    @staticmethod
    @always_inline
    def init() -> Self.StateTy:
        return Self.Op.init()

    @always_inline
    def update_scalar[
        bo: Origin[mut=False]
    ](mut self, mut state: Self.StateTy, batch: BatchView[bo], i: Int):
        Self.Op.update_scalar(state, batch.col_f64(Self.col).load[1](i)[0])

    @always_inline
    def update_scalar_mv[
        V: MorselView
    ](mut self, mut state: Self.StateTy, view: V, i: Int):
        """ENGINE-V2 MorselView seam: byte-identical to `update_scalar` --
        `col_scalar_nonraising[float64]` IS `col_f64().load[1][0]`."""
        Self.Op.update_scalar(
            state, view.col_scalar_nonraising[DType.float64](Self.col, i)
        )

    @always_inline
    def combine(
        mut self, mut into: Self.StateTy, var partial: Self.StateTy
    ):
        Self.Op.combine(into, partial)

    @staticmethod
    @always_inline
    def finalize(state: Self.StateTy) -> Scalar[DType.float64]:
        return Self.Op.finalize(state)


# =============================================================================
# §2 — HashAggOpI64Agg — Int64 aggregate adapter
# =============================================================================


struct HashAggOpI64Agg[Op: HashAggOpI64, col: Int](Aggregator):
    """`Aggregator` adapter wrapping a `HashAggOpI64` conformer `Op` bound to
    input column `col`. Output DType is `int64`."""

    comptime StateTy = Self.Op.StateTy
    comptime OUT_DT: DType = DType.int64

    def __init__(out self):
        """Field-less default ctor (see `HashAggOpF64Agg.__init__`)."""
        pass

    @staticmethod
    @always_inline
    def make() -> Self:
        """`Aggregator.make` — field-less default-construct (VARIADIC-FACTORY)."""
        return Self()

    @staticmethod
    @always_inline
    def init() -> Self.StateTy:
        return Self.Op.init()

    @always_inline
    def update_scalar[
        bo: Origin[mut=False]
    ](mut self, mut state: Self.StateTy, batch: BatchView[bo], i: Int):
        Self.Op.update_scalar(state, batch.col_i64(Self.col).load[1](i)[0])

    @always_inline
    def update_scalar_mv[
        V: MorselView
    ](mut self, mut state: Self.StateTy, view: V, i: Int):
        """ENGINE-V2 MorselView seam: byte-identical to `update_scalar` --
        `col_scalar_nonraising[int64]` IS `col_i64().load[1][0]`."""
        Self.Op.update_scalar(
            state, view.col_scalar_nonraising[DType.int64](Self.col, i)
        )

    @always_inline
    def combine(
        mut self, mut into: Self.StateTy, var partial: Self.StateTy
    ):
        Self.Op.combine(into, partial)

    @staticmethod
    @always_inline
    def finalize(state: Self.StateTy) -> Scalar[DType.int64]:
        return Self.Op.finalize(state)


# =============================================================================
# §3 — HashAggOpI32Agg — Int32 aggregate adapter
# =============================================================================


struct HashAggOpI32Agg[Op: HashAggOpI32, col: Int](Aggregator):
    """`Aggregator` adapter wrapping a `HashAggOpI32` conformer `Op` bound to
    input column `col`. Output DType is `int32`."""

    comptime StateTy = Self.Op.StateTy
    comptime OUT_DT: DType = DType.int32

    def __init__(out self):
        """Field-less default ctor (see `HashAggOpF64Agg.__init__`)."""
        pass

    @staticmethod
    @always_inline
    def make() -> Self:
        """`Aggregator.make` — field-less default-construct (VARIADIC-FACTORY)."""
        return Self()

    @staticmethod
    @always_inline
    def init() -> Self.StateTy:
        return Self.Op.init()

    @always_inline
    def update_scalar[
        bo: Origin[mut=False]
    ](mut self, mut state: Self.StateTy, batch: BatchView[bo], i: Int):
        Self.Op.update_scalar(state, batch.col_i32(Self.col).load[1](i)[0])

    @always_inline
    def update_scalar_mv[
        V: MorselView
    ](mut self, mut state: Self.StateTy, view: V, i: Int):
        """ENGINE-V2 MorselView seam: byte-identical to `update_scalar` --
        `col_scalar_nonraising[int32]` IS `col_i32().load[1][0]`."""
        Self.Op.update_scalar(
            state, view.col_scalar_nonraising[DType.int32](Self.col, i)
        )

    @always_inline
    def combine(
        mut self, mut into: Self.StateTy, var partial: Self.StateTy
    ):
        Self.Op.combine(into, partial)

    @staticmethod
    @always_inline
    def finalize(state: Self.StateTy) -> Scalar[DType.int32]:
        return Self.Op.finalize(state)


# =============================================================================
# §4 — HashAggOpF32Agg — Float32 aggregate adapter
# =============================================================================


struct HashAggOpF32Agg[Op: HashAggOpF32, col: Int](Aggregator):
    """`Aggregator` adapter wrapping a `HashAggOpF32` conformer `Op` bound to
    input column `col`. Output DType is `float32`."""

    comptime StateTy = Self.Op.StateTy
    comptime OUT_DT: DType = DType.float32

    def __init__(out self):
        """Field-less default ctor (see `HashAggOpF64Agg.__init__`)."""
        pass

    @staticmethod
    @always_inline
    def make() -> Self:
        """`Aggregator.make` — field-less default-construct (VARIADIC-FACTORY)."""
        return Self()

    @staticmethod
    @always_inline
    def init() -> Self.StateTy:
        return Self.Op.init()

    @always_inline
    def update_scalar[
        bo: Origin[mut=False]
    ](mut self, mut state: Self.StateTy, batch: BatchView[bo], i: Int):
        Self.Op.update_scalar(state, batch.col_f32(Self.col).load[1](i)[0])

    @always_inline
    def update_scalar_mv[
        V: MorselView
    ](mut self, mut state: Self.StateTy, view: V, i: Int):
        """ENGINE-V2 MorselView seam: byte-identical to `update_scalar` --
        `col_scalar_nonraising[float32]` IS `col_f32().load[1][0]`."""
        Self.Op.update_scalar(
            state, view.col_scalar_nonraising[DType.float32](Self.col, i)
        )

    @always_inline
    def combine(
        mut self, mut into: Self.StateTy, var partial: Self.StateTy
    ):
        Self.Op.combine(into, partial)

    @staticmethod
    @always_inline
    def finalize(state: Self.StateTy) -> Scalar[DType.float32]:
        return Self.Op.finalize(state)
