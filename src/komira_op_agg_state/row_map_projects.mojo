# =============================================================================
# row_map_projects.mojo — `RowMapProjects[M]`: the ProjectsLike slot for a
#                         multi-output ROW map UDF
# =============================================================================
#
# UDF-3 (board ``). The executable half of
# `komira_eval.row_udf.RowMapUdf[In, Out, //, m]` — the customer's
# `def margin(row: Order) -> Priced` running in the typed Stage's projection
# slot, producing ONE OUTPUT COLUMN PER FIELD of `Out`.
#
# ── Why neither existing ProjectsLike conformer serves this ─────────────────
#
# There are two, and each fails on a different axis:
#
#   `ProjectList[*Outs: RowTransform]` — ONE output column per `Outs[k]`. It
#     calls `self._outs[k].project_one[bo, 0, MCB]` once per (column, row),
#     reading `Outs[k].dtype_at[0]()`. Handed a single 2-output `RowTransform`
#     it emits ONE column, and the only way to get two is to list the map
#     TWICE — which runs the customer's function ONCE PER OUTPUT COLUMN. For
#     `margin` that doubles the work; for a fallible or a stateful one it is
#     simply wrong. It also names its columns `out0`, `out1`, …
#
#   `EvaluatorAdapterFor_Map[F: MapFn, col0]` — ONE input column, ONE output
#     column, named `out0`. `MapFn.run_row` returns `Scalar[OutType]`, so it
#     cannot carry a struct at all.
#
# So this is a THIRD conformer of a trait that already has several, not an
# additive parallel API for an existing one: it is the only shape in which
# `f` is called exactly once per row and lands N values.
#
# ── The two properties worth stating ────────────────────────────────────────
#
# 1. `f` RUNS ONCE PER ROW. The per-survivor loop stores the `Out` values in a
#    `List[Out]`, then builds each output column from that list. The cost is
#    one morsel's worth of `Out` structs (bounded by the morsel row count, not
#    the file) and it buys the once-per-row guarantee, which is a CORRECTNESS
#    property once the map is fallible or stateful, not a micro-optimisation.
#
#    ⚠ The obvious alternative — an N-slot `MultiColumnBuilder` written
#    directly from `write_one` — is NOT available: the N-slot builder type
#    `MultiColumnBuilder[ColumnSlot[dt0], ColumnSlot[dt1], …]` cannot be
#    constructed from a comptime pack of DTypes in Mojo 1.0.0 (there is no
#    comptime map from a DType value pack to a dependent type list; the
#    `multi_column_builder.mojo` header's WHY-A-TYPE-PACK note records it, and
#    `ProjectList.emit_projected` sidesteps it the same way, with 1-slot
#    builders). The `List[Out]` is what lets us keep ONE call per row while
#    still building one column at a time.
#
# 2. THE OUTPUT COLUMNS CARRY THE CUSTOMER'S OWN NAMES. `Priced{margin,
#    bucket}` emits columns `margin` and `bucket`, from
#    `reflect[Out].field_names()`, not `out0` / `out1`. That is the whole
#    reason the row form exists: the names comptime cannot read off a `def`'s
#    parameter list, it CAN read off a struct's fields.
#
# ── Encapsulation invariants (the internal development notes hard bans) ──────────────────────────
#   - NO `UnsafePointer` in any signature. The one offset read lives inside
#     `komira_eval.row_builder._read_row_field`, over the caller's own local.
#   - NO wildcard origins — `bo: Origin[mut=False]` threads end to end.
#   - NO `unsafe_from_address`, no `take_pointee`, no `ArcPointer`.
# =============================================================================

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.schema import (
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
    Field,
)
from komira_core.collections.batch_view import BatchView
from komira_core.collections.multi_column_builder import (
    MultiColumnBuilder,
    ColumnSlot,
    column_slot,
)

from komira_expr.stage_program import ProjectsLike
from komira_udf.column_resolver import ColumnResolver
from komira_udf.row_builder import _build_row_n, _read_row_field
from komira_udf.auto_komira_schema import AutoKomiraSchema
from komira_udf.row_udf import RowMapUdf


@fieldwise_init
struct RowMapProjects[
    In: AutoKomiraSchema & Deinitable,
    Out: AutoKomiraSchema & Deinitable, //,
    m: def(In) thin -> Out,
    id: StringLiteral = "",
](ProjectsLike, Copyable, Movable, ImplicitlyCopyable):
    """`ProjectsLike` slot for the row map `m`, emitting one column per field
    of `Out`, each carrying `Out`'s own field name.

    Parameters:
        In: the input row struct — inferred from `m`.
        Out: the output row struct — inferred from `m`.
        m: the customer's map function; a comptime parameter, so the call in
           `emit_projected` is a direct monomorphized call with no fn-ptr and
           no trampoline.
        id: the UDF-4 disambiguator, threaded so this adapter's identity
           matches the `RowMapUdf` the SDK seam authored.

    Zero fields: the function IS the type. That is what makes the per-worker
    `StreamingStageFactory` clone free.
    """

    comptime Udf = RowMapUdf[m = Self.m, id = Self.id]
    comptime ARITY: Int = reflect[Self.Out].field_count()

    @staticmethod
    def pdescribe() -> Int:
        """`ProjectsLike` discriminator. MUST be nonzero: the Stage NoBreaker
        arm comptime-elides the project pass and emits via `gather_batch`
        when `pdescribe() == 0`, so a zero here would silently pass the INPUT
        columns through and never call the customer's map at all.

        2049 — one past the 2048 the two `EvaluatorAdapterFor_*` families use,
        keeping the row-map family separately identifiable in the per-family
        bucket convention. Per-`m` discrimination is by the monomorphizer;
        each `m` is a distinct struct identity."""
        return 2049

    @staticmethod
    def make_default() -> Self:
        """A `RowMapProjects` is fully determined by its comptime parameters,
        so unlike `ProjectList` / `EvaluatorAdapterFor_Map` it CAN be default
        constructed — there is no UDF value to lose. The `Stage(state=...)`
        convenience ctor is therefore usable with this slot."""
        return Self()

    def bind(mut self, resolver: ColumnResolver) raises:
        """No-op. A row map has no name-keyed leaves to resolve: its input
        columns are bound POSITIONALLY by the scan projection the SDK seam
        authored from `row_projection[In]()` (field k <- column k), which is
        exactly the contract `_build_row_n` documents. There is nothing for a
        resolver to stamp."""
        pass

    def emit_projected[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], survivors: List[Int]
    ) raises -> RecordBatch:
        """Run `m` once per surviving row and emit `ARITY` named columns.

        Order of operations is load-bearing: the map runs FIRST, over every
        survivor, into `outs`; the columns are built afterwards. Building
        column-major with the map inline would call `m` once per (column,
        row)."""
        comptime S = Self.Udf.OutputSchema

        var outs = List[Self.Out](capacity=len(survivors))
        for si in range(len(survivors)):
            outs.append(Self.m(_build_row_n[Self.In, bo](batch, survivors[si])))

        var sb = SchemaBuilder()
        comptime for k in range(Self.ARITY):
            comptime nm = String(S.cols[k].name)
            comptime dt = Self.Udf.out_dtype_at[k]()
            sb.add_field(Field(nm, ArrowType.from_dtype(dt), False))
        var schema = sb.build()

        var rb = RecordBatchBuilder.with_capacity(Self.ARITY)
        comptime for k in range(Self.ARITY):
            comptime dt = Self.Udf.out_dtype_at[k]()
            var mcb = MultiColumnBuilder[ColumnSlot[dt]](
                column_slot[dt](len(outs))
            )
            for j in range(len(outs)):
                mcb.append_at[0, dt](_read_row_field[Self.Out, k, dt](outs[j]))
            rb.add_column(mcb.finalize_at[0]())

        return rb.build(schema^)
