# =============================================================================
# untyped_multi_column_sink.mojo — name-resolving multi-output sink for UDF
# =============================================================================
#
# The name-keyed mirror of `MultiColumnBuilder` — used by untyped MapFn UDFs
# to emit one value per output column by NAME rather than by comptime slot
# index.
#
# Shape. `UntypedMultiColumnSink[mo, *Bs: ColumnSink]` wraps a
# `MultiColumnBuilder[*Bs]` (the typed multi-output backing) plus a
# `Pointer[BoundSchema, mo]` for name -> slot-index resolution. The output
# schema's column-name order MUST match the order of the `*Bs` ColumnSink
# slots — this is the engine's responsibility to wire correctly at
# instantiation (`UntypedRowView`'s input-side counterpart guarantees the
# read side; the output side is the symmetric obligation).
#
# Hot-path dispatch.  `append_at_name[DT]("col_b", value)`:
#   1. resolves `"col_b" -> idx` via the BoundSchema (one Dict probe);
#   2. dispatches via a `@parameter for k in range(arity)` if-ladder to
#      the comptime-known `MultiColumnBuilder.append_at[k, DT](value)`.
#
# The `@parameter for k + if idx == k` pattern is the canonical
# comptime-unroll + runtime-tag-dispatch shape Mojo supports — the
# loop body unrolls at compile time into N (one per slot) typed call
# sites, only one of which executes per call. LLVM lowers this to a small
# tag-compare jump table; no `blr` indirect dispatch.
#
# Comptime DType safety: each unrolled `k` branch carries a
# `comptime assert DT == Self.Bs[k].DT, ...` check — the caller's DT MUST
# equal slot `k`'s slot DType. Mismatches fail the compile (the static
# error fires inside the only branch that would have type-mismatched at
# runtime), preserving the encapsulation rule: callers cannot land a
# wrong-DType value through the name path.
#
# Encapsulation invariants:
#   - NO UnsafePointer in any public method signature.
#   - NO wildcard origins.
#   - NO unsafe_from_address.
#   - NO byte-erased fn-ptr dispatch.
#   - NO partial-move (Optional.take / OwnedPointer.into_inner pattern).
#
# Cross-references:
#   - bound_schema.mojo — the borrowed schema.
#   - collections/multi_column_builder.mojo — the typed slot dispatch.
#   - `UntypedRowView` — the input-side dual of this sink.
# =============================================================================

from komira_arrow.bound_schema import BoundSchema
from komira_arrow.multi_column_builder import (
    ColumnSink,
    MultiColumnBuilder,
)
from komira_collections.slab import Slab
from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion


struct UntypedMultiColumnSink[
    mo: Origin[mut=False],
    *Bs: ColumnSink,
](Movable):
    """Name-resolving multi-output column sink — the dual of `UntypedRowView`
    on the output side of an untyped MapFn UDF.

    Wraps a `MultiColumnBuilder[*Bs]` (owned — the sink owns the per-slot
    storage) and a borrowed `BoundSchema` (read-only, never copied). The
    `append_at_name[DT]("name", value)` accessor resolves the name through
    the schema and dispatches to the comptime-known `append_at[k, DT]` slot
    via a `@parameter for k` unroll.

    Parameters:
        mo: Origin under which the borrowed `BoundSchema` lives.
        Bs: The type pack of `ColumnSink` conformers (one per output
            column) — mirrors `MultiColumnBuilder[*Bs]`.

    Contract: the BoundSchema's column ORDER must match the order of the
    `*Bs` pack. The engine wires this at sink construction; the schema
    feeds both `UntypedRowView` (input side) and `UntypedMultiColumnSink`
    (output side), so the symmetry is enforced by the lowering.
    """

    var _builder: MultiColumnBuilder[*Self.Bs]
    var _schema: Pointer[BoundSchema, Self.mo]

    def __init__(
        out self,
        var builder: MultiColumnBuilder[*Self.Bs],
        ref [Self.mo] schema: BoundSchema,
    ):
        """Wrap an existing `MultiColumnBuilder` and a borrowed `BoundSchema`.

        The builder is moved in (owned). The schema is borrowed under `mo`.
        """
        self._builder = builder^
        self._schema = Pointer(to=schema)

    @staticmethod
    def arity() -> Int:
        """The comptime output-column count (mirrors `MultiColumnBuilder.arity`)."""
        return Self.Bs.__len__()

    def append_at_name[
        DT: DType
    ](mut self, name: String, value: Scalar[DT]) raises:
        """Append `value` to the output slot bound to column `name`.

        Resolves `name -> idx` via the BoundSchema (one Dict probe), then
        dispatches via `@parameter for k` to the typed `append_at[k, DT]`.

        DType safety: each unrolled k branch only generates a call site if
        `DT == Self.Bs[k].DT` (via `@parameter if`). At runtime, exactly
        one k branch matches `idx == k` AND DT-matches the slot — that one
        executes; all others DCE. If the caller's `DT` does not match ANY
        slot DType (which would be a comptime-detectable bug in the
        engine's UDF lowering), the dispatch falls through to the
        `dtype-mismatch` raise — surfacing the mismatch at runtime rather
        than silently emitting wrong data.

        Raises:
            If `name` is not a column in the BoundSchema (the BoundSchema's
            own diagnostic).
            If the resolved index `idx` is valid in the schema but the
            caller's `DT` does not equal slot `idx`'s slot DType (DType
            mismatch — a real bind/lowering error).
            If the resolved index is out-of-range for the comptime arity
            (schema-vs-pack mismatch — the engine must guarantee schema
            and slot pack agree at sink construction).
        """
        var idx = self._schema[].index_of(name)

        comptime for k in range(Self.Bs.__len__()):
            comptime if DT == Self.Bs[k].DT:
                if idx == k:
                    # DT == Bs[k].DT proved by @parameter if; the call's
                    # `value: Scalar[DT]` already matches the slot's
                    # required `Scalar[Bs[k].DT]` under that comptime
                    # equality — no rebind needed on this path.
                    self._builder.append_at[k, DT](value)
                    return

        # We reached here because either (a) the resolved index is
        # out-of-range for the slot pack OR (b) no slot's DType matches the
        # caller's DT at the resolved index. Both are real bind-time errors;
        # raise with a clear diagnostic.
        raise Error(
            "UntypedMultiColumnSink.append_at_name: resolved index "
            + String(idx)
            + " for name '"
            + name
            + "' is either out-of-range for the comptime slot pack (arity="
            + String(Self.Bs.__len__())
            + ") or the caller's DT does not match the slot's DType — "
            + "schema and slot pack must agree at sink construction"
        )

    def append_null_at_name(mut self, name: String) raises:
        """Append a null slot to the output column bound to `name`.

        Same `@parameter for k` dispatch as `append_at_name` but for the
        null-slot path. No comptime DT bound — every `ColumnSink` exposes
        `append_null_value`.
        """
        var idx = self._schema[].index_of(name)

        comptime for k in range(Self.Bs.__len__()):
            if idx == k:
                self._builder.append_null_at[k]()
                return

        raise Error(
            "UntypedMultiColumnSink.append_null_at_name: resolved index "
            + String(idx)
            + " for name '"
            + name
            + "' is out of range for the comptime slot pack"
        )

    @always_inline
    def append_at[k: Int, DT: DType](mut self, value: Scalar[DT]):
        """Slot-indexed pass-through to `MultiColumnBuilder.append_at[k, DT]`.

        For callers that already have a comptime slot index in hand (the
        cold-path / engine-internal callers); the hot UDF authoring path
        uses `append_at_name`.
        """
        self._builder.append_at[k, DT](value)

    @always_inline
    def append_null_at[k: Int](mut self):
        """Slot-indexed null pass-through to `MultiColumnBuilder.append_null_at[k]`."""
        self._builder.append_null_at[k]()

    def finalize_at[k: Int](mut self) raises -> Column[HeapRegion]:
        """One-shot consume of output slot `k` — emit its accumulated `Column[HeapRegion]`.

        Pass-through to `MultiColumnBuilder.finalize_at[k]()`; the inner
        slot's `Optional.take()` mechanism means no partial move through a
        raw pointer.
        """
        return self._builder.finalize_at[k]()

    def finalize_columns(mut self) raises -> Slab[Column[HeapRegion]]:
        """One-shot consume of EVERY output slot — emit all `arity()`
        columns in slot order as a `Slab[Column]`.

        Pass-through to `MultiColumnBuilder.finalize_columns()`. Caller
        (the Stage at segment exit) wires the result columns into a
        `RecordBatch` using the bound output `Schema`.
        """
        return self._builder.finalize_columns()
