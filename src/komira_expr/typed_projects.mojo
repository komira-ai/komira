# =============================================================================
# typed_projects.mojo — Production ProjectsLike conformer (variadic)
# =============================================================================
#
# `ProjectList[*Outs: RowTransform]` is the single canonical `ProjectsLike`
# conformer — one variadic struct for every output arity and DType mix. The
# output DType of slot k is `Outs[k].dtype_at[0]()` (a `RowTransform`
# member); the arity is the pack length.
#
# Instance store
# -----------------------------------------------------------------------------
# `ProjectList` carries a real `Tuple[*Self.Outs]` instance field, and the
# `ProjectsLike` trait bound is `(Movable, Deinitable)`: a `Tuple[*Pack]` of
# trait conformers is Movable-only when an `Outs` element is not Copyable
# (the same Tuple[*Pack] storage pattern as HashAggTable / SortBuffer /
# JoinBuildTable / DistinctState).
#
# Why an instance and not a pure comptime type pack: the leaf ExprX
# conformers (`ColXI64["name"]`, etc.) carry a runtime `_idx = -1` populated
# by `bind(resolver)`. A static `Self.Outs[k].project_one[...]` path would
# construct `var inst = Self()` per call inside the trait default body
# (`row_transform.mojo`), which is unbound (`_idx = -1`) → SIGSEGV on the
# first `batch.col_i64(-1)` access. So `emit_projected` uses
# `self._outs[k].project_one` instance dispatch (the trait's
# `mut self`-variant — the bound leaf's runtime `_idx` is consulted by
# `eval_scalar_s`). `bind` walks `self._outs[k].bind(resolver)` so each
# leaf under the project pack gets threaded — the SDK/test call site does
# `stage.bind(resolver)` once after construction, and the recursive walker
# bottoms out at the leaves.
#
# CTOR API: `__init__(out self, var *outs: *Self.Outs)` takes the Out
# instances variadically (a direct variadic-arg signature, since ProjectList
# carries no other state). Construct as
# `ProjectList[Out0, Out1](Out0(), Out1())`.
#
# Numeric and String outputs: the numeric `ExprX{I64,F64,I32,F32}` traits and
# `ExprXString` all refine `RowTransform`, so `*Outs: RowTransform` hosts
# them directly. The STRUCT is uniform, but `emit_projected` is not: two
# things are per-output-column:
#
#   * the output `Field`'s ArrowType — `ArrowType.STRING` has no DType to
#     be derived from, so `ArrowType.from_dtype(dtype_at[k]())` cannot
#     produce it;
#   * the SINK TYPE — `ColumnSlot[dt]` vs `StringColumnSlot`, which are
#     different types, so the single-slot `MultiColumnBuilder[...]` that
#     column k is built into is a different type per k.
#
# Both are resolved by a `comptime if` on `Outs[k].out_kind_at[0]()` inside
# the `comptime for k` fan-out — comptime-unrolled, so each column still
# monomorphizes to one concrete builder type with no runtime branch.
#
# Encapsulation invariants:
#   - NO UnsafePointer in any field or signature (POD-only struct).
#   - NO wildcard origins (no fields hold references).
#   - File well under the size guideline.
#
# Cross-references:
#   - ProjectsLike trait + ProjectListStub: komira_expr.stage_program
#   - RowTransform trait: komira_udf.row_transform
#   - Layer A ExprX conformers: komira_eval.expr_x_conformers
#   - Variadic pattern: komira_collections.variadic_pack
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
    Field,
)
from komira_arrow.batch_view import BatchView
from komira_arrow.multi_column_builder import (
    MultiColumnBuilder,
    ColumnSlot,
    SinkKind,
    StringColumnSlot,
    column_slot,
    string_column_slot,
)

from komira_expr.stage_program import ProjectsLike
from komira_udf.column_resolver import ColumnResolver
from komira_udf.row_transform import RowTransform


# -----------------------------------------------------------------------------
# §1 — ProjectList[*Outs: RowTransform] — the single variadic ProjectsLike
#       conformer
# -----------------------------------------------------------------------------


struct ProjectList[*Outs: RowTransform](ProjectsLike):
    """Variadic typed projection list — the single `ProjectsLike` conformer.

    `*Outs` is a comptime type pack of `RowTransform` conformers, one per
    output column. Each `Outs[k]` is the expression producing output column
    k, consumed by the typed Stage's `process_batch` NoBreaker arm.

    Storage: `var _outs: Tuple[*Self.Outs]` — one stored Out instance per
    output column. The Tuple field is required so name-keyed
    leaves (`ColXI64["name"]`) can carry the runtime `_idx` that
    `bind(resolver)` populates; the static `Self.Outs[k].project_one`
    dispatch path constructs unbound `Self()` per call and SIGSEGVs on
    `batch.col_i64(-1)` (see module-header narrative).

    `pdescribe()` returns the output arity `Self.Outs.__len__()` — the
    stable discriminator the `ProjectsLike` trait surface exposes (NoProjects
    returns 0; ProjectListStub returns its `arity`; MapFnProjects returns the
    1024 UDF-family sentinel).

    Replaces the 13-struct `ProjectList_<arity>_<DTypeTuple>` matrix:

        ProjectList[E0]        # 1-output (ctor: ProjectList[E0](e0))
        ProjectList[E0, E1]    # 2-output (ctor: ProjectList[E0, E1](e0, e1))
        ProjectList[E0, ...]   # N-output, no arity ceiling

    The per-DType distinction the old matrix encoded in its struct name is
    recoverable at comptime via `Outs[k].dtype_at[0]()`.
    """

    var _outs: Tuple[*Self.Outs]
    """One stored Out instance per output column.

    The Tuple is constructed at ProjectList init time from the variadic
    `*outs` ctor args. Indexed access in `emit_projected` is
    `self._outs[k]` under a `@parameter for k in range(Self.Outs.__len__())`.

    Why a real instance field (not a `var sentinel: Int`): the leaf ExprX conformers (ColXI64[name] / ColXF64[name] / etc.) carry
    a runtime `_idx = -1` that `bind(resolver)` populates by looking up the
    column name in the file schema. A static
    `Self.Outs[k].project_one[bo, 0, MCB](batch, i, mcb)` path
    inadvertently constructs `var inst = Self()` (the unbound `_idx == -1`
    case) per call inside the trait default body — SIGSEGV on the first
    `batch.col_i64(-1)` access. Storing instances + dispatching through
    `self._outs[k]` ensures the bound runtime `_idx` is consulted.
    """

    def __init__(out self, var *outs: *Self.Outs):
        """Construct from the variadic Out pack.

        Callers pass one constructed Out instance per output column:

            ProjectList[ColXI64["a"], MulXF64[ColXF64["b"], LitXF64[2.0]]](
                ColXI64["a"](),
                MulXF64[ColXF64["b"], LitXF64[2.0]](),
            )

        The variadic args are packed into the `_outs: Tuple[*Self.Outs]`
        field. Per the canonical NARY pattern (HashAggTable / SortBuffer /
        JoinBuildTable), the `var *outs: *Self.Outs` parameter binding
        produces a variadic pack that is moved into `Tuple(*outs^)`.
        """
        self._outs = Tuple(*outs^)

    @staticmethod
    def arity() -> Int:
        """The output-column count — the length of the `*Outs` pack."""
        return Self.Outs.__len__()

    @staticmethod
    def pdescribe() -> Int:
        """`ProjectsLike` discriminator: the output arity."""
        return Self.Outs.__len__()

    @staticmethod
    def make_default() -> Self:
        """NO default — a `ProjectList` is defined by its `*Outs` output pack.
        `comptime assert False` (never monomorphized — the `Stage` convenience
        `state=`-only ctor is used only for sentinel-`NoProjects` breaker
        stages; a `ProjectList` NoBreaker stage uses the 3-arg
        `Stage(filter, projects, state)` ctor)."""
        comptime assert False, (
            "ProjectList has no default — use Stage(filter, projects, state)"
        )

    def bind(mut self, resolver: ColumnResolver) raises:
        """Bind walker: thread `resolver` to every Out instance.

        Each `self._outs[k]` is a stored Out instance whose leaves
        (`ColXI64["name"]` / `ColXF64["name"]` / etc.) carry runtime
        `_idx = -1` until bind populates them. The recursive walker
        bottoms out at the leaves via the per-conformer `bind` chain
        (each ExprX conformer's default `bind` is no-op; the leaf
        conformers override to look up `Self.name` in the resolver and
        stamp `self._idx`).

        Called exactly once per Stage instantiation, from `Stage.bind` —
        the SDK call site does `stage.bind(resolver)` after construction
        and the recursion threads through filter / projects / state.
        """

        comptime for k in range(Self.Outs.__len__()):
            self._outs[k].bind(resolver)

    def emit_projected[bo: Origin[mut=False]](
        mut self, batch: BatchView[bo], survivors: List[Int]
    ) raises -> RecordBatch:
        """Build the projected output `RecordBatch` over the surviving rows.

        The NoBreaker project emit. `survivors` is the post-filter logical-
        row-index list (in input order). `*Outs` is in scope here, so the
        emit `@parameter for`-fans-out over the pack — one OUTPUT column per
        `Outs[k]` in pack order:

          - output column `k`'s DType is `Outs[k].dtype_at[0]()` (comptime);
          - per surviving row, `self._outs[k].project_one[bo, 0, MCB]` lands
            the value into a fresh single-slot `MultiColumnBuilder[
            ColumnSlot[dt]]`. INSTANCE dispatch via the stored Out ensures
            the bound runtime `_idx` is consulted at leaf-eval; a static
            `Self.Outs[k].project_one` path would construct an unbound
            `Self()` and SIGSEGV on `batch.col_i64(-1)`.

        WHY a single-slot builder PER column (not one N-slot builder). The
        N-slot `MultiColumnBuilder[ColumnSlot[dt0], ColumnSlot[dt1], ...]` type
        cannot be constructed from the `*Outs` pack in Mojo 1.0.0b1 — there is
        no comptime map from a value pack of DTypes to a dependent
        `ColumnSlot[...]` type list (the `multi_column_builder.mojo` header's
        WHY-A-TYPE-PACK note). A 1-slot builder per `k` (whose single DType IS
        the comptime `Outs[k].dtype_at[0]()`) sidesteps that entirely; each
        column is built + finalized independently, then appended to the
        `RecordBatchBuilder`. Output column `k` is named `out{k}`; the schema
        nullability is False (a numeric ExprX project produces a non-null
        column from non-null inputs; nullable-output projects land with the
        Kleene-aware ExprX edge).

        `out_kind_at[0]()` picks the arm per output column —
        a `StringColumnSlot` + `ArrowType.STRING` for a STRING transform,
        `ColumnSlot[dtype_at[0]()]` + `ArrowType.from_dtype(...)` otherwise.
        Both arms are inside the SAME `comptime for k`, so a mixed
        `(Int64, String)` project is one pass and each column still
        monomorphizes to one concrete builder type. Non-nullable holds for
        the STRING arm too, and for a stronger reason than the numeric one:
        `ExprXString.eval_scalar_s` returns a `String` and has no way to
        SAY null (see that trait's docstring).
        """
        var sb = SchemaBuilder()

        comptime for k in range(Self.Outs.__len__()):
            comptime kind_k = Self.Outs[k].out_kind_at[0]()
            comptime if kind_k == SinkKind.STRING:
                sb.add_field(
                    Field(String("out") + String(k), ArrowType.STRING, False)
                )
            else:
                sb.add_field(
                    Field(
                        String("out") + String(k),
                        ArrowType.from_dtype(Self.Outs[k].dtype_at[0]()),
                        False,
                    )
                )
        var schema = sb.build()

        var rb = RecordBatchBuilder.with_capacity(Self.Outs.__len__())

        comptime for k in range(Self.Outs.__len__()):
            comptime kind = Self.Outs[k].out_kind_at[0]()
            comptime if kind == SinkKind.STRING:
                # STRING output column: the sink is a `StringColumnSlot`
                # and the transform's `project_one` drives
                # `append_string_at`. `dtype_at[0]()` is NOT read here —
                # a STRING transform's DType is a documented placeholder
                # and this is the branch that must never consult it.
                var smcb = MultiColumnBuilder[StringColumnSlot](
                    string_column_slot(len(survivors))
                )
                for si in range(len(survivors)):
                    self._outs[k].project_one[
                        bo, 0, MultiColumnBuilder[StringColumnSlot]
                    ](batch, survivors[si], smcb)
                rb.add_column(smcb.finalize_at[0]())
            else:
                comptime dt = Self.Outs[k].dtype_at[0]()
                var mcb = MultiColumnBuilder[ColumnSlot[dt]](
                    column_slot[dt](len(survivors))
                )
                for si in range(len(survivors)):
                    # INSTANCE dispatch: self._outs[k] is the bound Out (its
                    # leaves' runtime `_idx` populated by `bind`); the trait's
                    # `mut self` overload of project_one reads through `self`.
                    self._outs[k].project_one[
                        bo, 0, MultiColumnBuilder[ColumnSlot[dt]]
                    ](batch, survivors[si], mcb)
                rb.add_column(mcb.finalize_at[0]())

        return rb.build(schema^)
