# =============================================================================
# map_fn_rt.mojo — MapFn -> RowTransform newtype adapter
# =============================================================================
#
# The `RowTransform` conformance bridge for the user-facing `MapFn` family.
#
# WHY AN ADAPTER, NOT A REFINEMENT EDGE
# -------------------------------------
# The ExprX family refines `RowTransform` directly via trait inheritance +
# a delegating default body — the conformer's static method is renamed off
# the collision and the trait forwards to it. That trick works because the
# ExprX conformer ALREADY carries everything the unified surface needs.
#
# `MapFn` CANNOT refine `RowTransform` the same way: the shapes genuinely
# differ.
#   - `MapFn.run_scalar[*Ts](mut self, *vals: *Ts)` — POSITIONAL het-pack
#     of typed scalars, no `BatchView`, no `i: Int`, returns
#     `Scalar[Self.OutType]` (a SINGLE column).
#   - `RowTransform.write_one(mut self, batch: BatchView, i, mut
#     builders: MCB)` — BatchView-keyed, writes ALL `ARITY` columns via
#     `builders.append_at[k, DT]`.
# A `MapFn` conformer is a typed scalar-oracle with NO column binding —
# it has no way to know which `BatchView` column to read. So the bridge
# needs a real wrapper that CARRIES the column index AND an instance of
# the MapFn (because the MapFn oracle is `mut self`-bound — a stateful
# MapFn carries captures and must persist them across rows). This is
# the canonical Rust-style newtype adapter: it conforms a foreign-shaped
# type to a trait. It is NOT an additive parallel API — there is no sibling
# trait and no duplicated surface; the
# adapter IS the single `RowTransform` conformance for the `MapFn`
# family.
#
# The precedent is `HashAggOpF64Agg[Op, col]` (`hash_agg_op_aggregator.mojo`)
# for static-method conformers + `AggFnAcc[F]`
# (`komira_engine_operators.agg_fn_acc`) for instance-method
# conformers. `MapFn` is instance-method-shape so the storage shape
# mirrors `AggFnAcc`: hold `_udf: F` as a field, construct from `var
# udf: F`, call `self._udf.run_scalar(v)` per row.
#
# SCOPE — ARITY=1 INPUT (single-column MapFn)
# ------------------------------------------------
# This adapter covers the ARITY=1 INPUT case (one input column -> one output
# column), matching the `HashAggOpF64Agg[Op, col]` shape. Multi-input-column
# MapFn adapters (arity-2/3/4 input via per-arity branches, mirroring
# `agg_fn_acc._update_arity{2,3,4}`) are not provided, nor is a
# multi-OUTPUT MapFn shape.
#
# Per-DType `comptime if` ladder on the input column
# --------------------------------------------------
# `BatchView` exposes only typed `col_i64`/`col_i32`/`col_f64`/`col_f32`/
# `col_bool` accessors (no `col_any[dt]`). The adapter reads the input
# DType off `F.InputSchema.cols[0].dtype` at comptime and lands a
# `comptime if`-laddered call to the matching `BatchView` accessor —
# the SAME canonical pattern `sort_buffer._read_sort_key_scalar` and
# `hash_agg._read_key_scalar` use, which is why those compile to
# byte-identical direct loads (no runtime dispatch).
#
# Note on `project_one`
# -------------------------------------------------------------------
# `RowTransform.project_one` is `mut self` (so `ProjectList.emit_projected`
# can dispatch through bound Out instances — name-keyed leaf conformers carry
# a runtime `_idx` populated by `bind`). MapFnRT provides a real
# implementation mirroring `write_one` but writing to `dst_k` instead of `0`.
#
# Encapsulation invariants:
#   - NO `UnsafePointer` in any signature.
#   - NO wildcard origins — `bo: Origin[mut=False]` threads the per-batch
#     lifetime witness end-to-end.
#
# Cross-references:
#   - row_transform.mojo — the unified `RowTransform` trait (target).
#   - map_fn.mojo — the user-facing `MapFn` trait (source).
#   - hash_agg_op_aggregator.mojo — the precedent adapter family pattern
#     (static-method conformer variant).
#   - komira_engine_operators.agg_fn_acc — the precedent
#     instance-method-conformer adapter shape (`_udf: F` field).
# =============================================================================

from komira_core.collections.batch_view import BatchView
from komira_core.collections.multi_column_builder import (
    MultiColumnSink,
    SinkKind,
)

from komira_eval.map_fn import MapFn
from komira_eval.row_builder import _build_row
from komira_eval.row_transform import RowTransform
from komira_eval.schema_descriptor import dtag_to_dtype


# =============================================================================
# §1 — MapFnRT — RowTransform adapter for single-input-column MapFn
# =============================================================================


struct MapFnRT[F: MapFn, col0: Int](RowTransform):
    """`RowTransform` adapter wrapping a `MapFn` conformer `F` bound to
    input column `col0`. Output ARITY=1; output DType is `F.OutType`.

    Fields
    ------
    _udf: The user's `F` instance (per-worker copy — the typed UDF
        executor lifecycle; mirrors the `_udf` field on
        `AggFnAcc[F: AggFn]`). `mut self.write_one` borrows it
        mutably per row, preserving any stateful MapFn captures
        across rows within the same worker.

    `write_one` reads column `col0` off the `BatchView` per
    `F.InputSchema.cols[0].dtype` (via a comptime-folded `comptime if`
    ladder over the four `BatchView` typed accessors), builds the UDF's
    `InRow` from that cell with `_build_row[F.InRow]`, forwards it to
    `self._udf.run_row(row)`, and lands the result into output slot 0 of
    the multi-column builder via `builders.append_at[0, F.OutType](result)`.

    This is the canonical Rust-style newtype adapter — see module doc.
    """

    var _udf: Self.F

    def __init__(out self, var udf: Self.F):
        """Construct a `MapFnRT` wrapping the given `F` instance.

        Args:
            udf: The user's `F` instance. Ownership is transferred
                 (the adapter owns its per-worker copy — mirrors
                 `AggFnAcc.__init__`).
        """
        self._udf = udf^

    # __moveinit__ / __copyinit__ / __del__ auto-synthesized — F is
    # Movable & Copyable & Deinitable.

    comptime ARITY: Int = 1

    @staticmethod
    @always_inline
    def out_kind_at[k: Int]() -> SinkKind:
        """Output channel of slot `k`. A `MapFn`'s output is pinned to a
        `DType` by `run_row`'s `-> Scalar[Self.OutType]` return, so a
        `MapFnRT` is always NUMERIC. A String-returning UDF cannot reach
        this adapter at all — it cannot conform to `MapFn` in the first
        place; multi-column / String row output is the `RowMapFn`
        carrier's job, not this one's."""
        return SinkKind.NUMERIC

    @staticmethod
    @always_inline
    def dtype_at[k: Int]() -> DType:
        """Output DType of slot `k`. ARITY=1, so only `k=0` is legal;
        the value is `F.OutType` (the wrapped MapFn's single output
        column DType)."""
        return Self.F.OutType

    @always_inline
    def write_one[
        bo: Origin[mut=False], MCB: MultiColumnSink
    ](mut self, batch: BatchView[bo], i: Int, mut builders: MCB) raises:
        """Write the MapFn's single output value for input row `i` into
        output slot 0 of `builders`.

        Reads input column `col0` per `F.InputSchema.cols[0].dtype`
        (comptime-known), builds `F.InRow` from that cell via
        `_build_row[F.InRow]`, forwards it to `self._udf.run_row`, and
        lands the result via `builders.append_at[0, F.OutType]`. The
        `comptime if` ladder folds away — the adapter compiles to a direct
        typed load + direct `self._udf.run_row` call + direct `append_at`
        (the same zero-`bl` pattern as `HashAggOpF64Agg.update_scalar`,
        with the one extra `_udf` field load that AggFnAcc also has).

        ROW-BUILD COST: the row build is a store into an
        `InlineArray[F.InRow, 1]` slot and a load back out, and at ARITY=1
        it is FREE — the optimizer folds it after inlining (an interleaved
        A/B, memory-bound and cache-resident, differs only by run-to-run
        noise). Method note for whoever re-measures:
        the sink must STORE (as the real MultiColumnBuilder does), not
        accumulate — a `+=` sink puts a serial FP add on every iteration
        and the loop becomes dependency-bound, which hides exactly the
        store-to-load round trip being measured.
        """
        comptime dt0 = dtag_to_dtype(Self.F.InputSchema.cols[0].dtype)
        comptime if dt0 == DType.int64:
            var v = batch.col_i64(Self.col0).load[1](i)[0]
            builders.append_at[0, Self.F.OutType](
                self._udf.run_row(_build_row[Self.F.InRow](v))
            )
        elif dt0 == DType.int32:
            var v = batch.col_i32(Self.col0).load[1](i)[0]
            builders.append_at[0, Self.F.OutType](
                self._udf.run_row(_build_row[Self.F.InRow](v))
            )
        elif dt0 == DType.float64:
            var v = batch.col_f64(Self.col0).load[1](i)[0]
            builders.append_at[0, Self.F.OutType](
                self._udf.run_row(_build_row[Self.F.InRow](v))
            )
        elif dt0 == DType.float32:
            var v = batch.col_f32(Self.col0).load[1](i)[0]
            builders.append_at[0, Self.F.OutType](
                self._udf.run_row(_build_row[Self.F.InRow](v))
            )
        else:
            # this covers I64/I32/F64/F32 — the four BatchView typed
            # accessors. Other input DTypes (Bool, U8/U16/U32/U64, dates,
            # strings) are not supported.
            comptime assert False, ("MapFnRT: input column DType is not yet supported ("
                "supported: int64 / int32 / float64 / float32; extend the "
                "ladder when adding new input DType coverage).")

    @always_inline
    def project_one[
        bo: Origin[mut=False], dst_k: Int, MCB: MultiColumnSink
    ](mut self, batch: BatchView[bo], i: Int, mut builders: MCB) raises:
        """`RowTransform.project_one` — instance-method implementation lands
        the MapFn's output value at output slot `dst_k`.

        `RowTransform.project_one`
        flipped from `@staticmethod` to `mut self` so this adapter can finally
        provide a real implementation. Pre-flip the static method had no
        access to `self._udf` (the wrapped MapFn's per-worker copy); the
        method was a `constrained[False]` compile-time-reject stub. Post-flip
        the body mirrors `write_one` except `append_at[dst_k]` instead of
        `append_at[0]`.
        """
        comptime dt0 = dtag_to_dtype(Self.F.InputSchema.cols[0].dtype)
        comptime if dt0 == DType.int64:
            var v = batch.col_i64(Self.col0).load[1](i)[0]
            builders.append_at[dst_k, Self.F.OutType](
                self._udf.run_row(_build_row[Self.F.InRow](v))
            )
        elif dt0 == DType.int32:
            var v = batch.col_i32(Self.col0).load[1](i)[0]
            builders.append_at[dst_k, Self.F.OutType](
                self._udf.run_row(_build_row[Self.F.InRow](v))
            )
        elif dt0 == DType.float64:
            var v = batch.col_f64(Self.col0).load[1](i)[0]
            builders.append_at[dst_k, Self.F.OutType](
                self._udf.run_row(_build_row[Self.F.InRow](v))
            )
        elif dt0 == DType.float32:
            var v = batch.col_f32(Self.col0).load[1](i)[0]
            builders.append_at[dst_k, Self.F.OutType](
                self._udf.run_row(_build_row[Self.F.InRow](v))
            )
        else:
            comptime assert False, ("MapFnRT.project_one: input column DType is not yet "
                "supported (the ladder covers int64 / int32 / float64 / "
                "float32; extend the ladder when adding new input DType "
                "coverage).")
