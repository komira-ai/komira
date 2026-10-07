# =============================================================================
# agg_leaf_resolution — the ONE resolution of an aggregate's parquet LEAF, and
# the structural home of the scan-projection-is-file-derived invariant
# =============================================================================
#
# ★ THE PROBLEM THIS MODULE SOLVES.
#   A streaming agg arm under `agg_node_exec` that probes the parquet FOOTER
#   itself and treats the answer as one schema is conflating TWO:
#
#     1. the SCAN schema     — what the decode can resolve BY NAME (file
#        columns; the footer is the authority), and
#     2. the AGG RESOLUTION schema — what the aggregate's group KEYS and agg
#        INPUTS are named and typed in. After the optimizer materialises a
#        computed group key (`__grp_key_0`) or a computed aggregand
#        (`__agg_in_<n>`) into a PLAN_PROJECT below the AGGREGATE, that is the
#        PROJECT's OUTPUT schema and **it contains names that are in no
#        footer**.
#
#   Conflating them means `AGGREGATE -> PROJECT(computed) -> FILTER? ->
#   SCAN(parquet)` cannot be served by any arm: each arm's
#   `_ext_col_idx(footer_schema, "__agg_in_0") < 0` decline fires, so the whole
#   relation is diverted to a RESIDENT walker collect instead.
#
# ★ WHICH SCHEMA IS THE AUTHORITY FOR THE PROJECT'S OUTPUT — AND IT IS NOT
#   `schema_from_project_exprs`. `MorselOp.project(exprs, out_names)` takes its
#   OUTPUT NAMES from the PROJECT node's `output_schema`
#   (`parquet_helpers._detect_parquet_collect_shape`, mirroring
#   `plan_compiler._compile_project`). So the batch the executor emits is named
#   by `output_schema` — and binding the aggregate's resolution to anything
#   else can only DISAGREE with what the op actually produces. We therefore use
#   `LogicalPlan.output_schema`, which is the FIRST of the two sanctioned entry
#   points to the one `_infer_expr_field` / `walk_expr_field` ladder (the
#   standalone `schema_from_project_exprs` is the second, for callers that hold
#   exprs rather than a node). No third spelling is introduced here.
#
# ⛔ THE INVARIANT — the scan projection is file-derived.
#   The `List[String]` that becomes `ParquetSourceData.projection` for an agg
#   leaf carrying a PROJECT is derived from the column references of the
#   **PROJECT exprs and the leaf PREDICATES ONLY**. It is never derived from
#   `AggregateData` — not from `group_by`, not from `agg_exprs`.
#
#   ★ IT IS ENFORCED STRUCTURALLY, NOT BY CONVENTION: `leaf_scan_projection`'s
#   SIGNATURE CANNOT SEE AN `AggregateData`. A synthetic name (`__grp_key_0`,
#   `__agg_in_<n>`) exists in exactly two places — `AggregateData`, and the
#   PROJECT's OUTPUT names — and this builder is handed neither. It reads the
#   INPUT side of the project's exprs, which is file columns by construction.
#   Make it the only producer of an agg leaf's projection and the invariant is
#   a type fact.
#
#   Backstop already in the tree: `resolve_projection_indices` RAISES
#   ("unknown projection column") for a name absent from the footer, so a
#   violation is loud — never a silent wrong answer.
#
# ⛔ THE AGREEMENT CHECK IS A REAL CHECK, NOT A `debug_assert`.
#   `assert_leaf_schema_agrees` RAISES. `debug_assert` is compiled out of
#   release, and a `debug_assert` on this class of bound is an out-of-bounds
#   WRITE in a release build (the reason `UngroupedAggSink._refuse_past_agg_cap`
#   raises too). The derived resolution schema is
#   the input to every dtype gate in every arm, so a divergence between it and
#   the batch the MapOp actually emits is the residual risk of the whole
#   design; it is checked ONCE per query (not on any per-row path) at the point
#   the leaf becomes a resident batch.
#
# Encapsulation (pointer rules): NO UnsafePointer, NO wildcard origins,
#   NO `unsafe_from_address`, NO partial-move via `take_pointee` in this file.
# =============================================================================

from std.collections import List, Optional

from komira_arrow.schema import Schema
from komira_collections.slab import Slab
from komira_plan_expr.expr import Expr
from komira_arrow.arrow_types import ArrowType
from komira_column_kernels.compiler_helpers import (
    collect_expr_cols,
    field_for_expr,
)
from komira_plan_ir.logical_plan import ExprArray, LogicalPlan, PLAN_PROJECT
from komira_plan_ir.physical_plan import MorselOp


# =============================================================================
# AggLeafProject — the PROJECT an agg leaf carries, in the form the collect
# leaf consumes (exprs + the OUTPUT NAMES read off the node's output_schema).
# =============================================================================


struct AggLeafProject(Movable):
    """The computed PROJECT sitting between an AGGREGATE and its parquet leaf.

    `out_names` comes from the PROJECT node's `output_schema` — the SAME source
    `_detect_parquet_collect_shape` reads for `MorselOp.project`, so the names
    this carries and the names the executor emits cannot drift apart.

    Fields:
        exprs: One projection expression per output column.
        out_names: One output column NAME per expression, in the same order.
    """

    var exprs: ExprArray
    var out_names: List[String]

    def __init__(out self, var exprs: ExprArray, var out_names: List[String]):
        """Take ownership of the projection exprs + their output names."""
        self.exprs = exprs^
        self.out_names = out_names^

    def copy(self) -> Self:
        """Deep-copy (ExprArray is `Slab[Expr]` — move-only, element-wise copy)."""
        var e = ExprArray()
        for i in range(len(self.exprs)):
            e.append(self.exprs[i].copy())
        return Self(e^, self.out_names.copy())

    def subset_by_out_names(self, imm keep: List[String]) -> Self:
        """The sub-PROJECT that emits exactly the columns in `keep`, in THIS
        project's own expression order.

        ⭐ THIS IS THE HALF OF THE 0-KEY FAN-OUT THAT BOUNDS THE TRANSIENT
        PROJECTION WIDTH. Splitting a 90-aggregate 0-key plan
        into 6 passes of <=16 buys nothing if every pass still evaluates all 90
        projection expressions per morsel — the transient batch would still be
        90 columns wide. Each pass takes ONLY the projection outputs ITS
        aggregates read, so the per-morsel materialised width is bounded by
        `MAX_AGGS` (+ the passthroughs those aggregates name) rather than by
        the plan's aggregate count.

        ⚠ IT MAY RETURN FEWER COLUMNS THAN `keep` NAMES, and the caller must
        check. A name in `keep` that this project does not output is an
        aggregate input resolvable in NO schema the leaf will emit; the caller
        DECLINES the whole route rather than running a pass whose sink would
        then fail to resolve its own input column.

        Args:
            keep: The output names this pass needs. Membership only — the
                RESULT's order is this project's, which is what keeps the
                emitted schema a contiguous-in-spirit subset of the full one.

        Returns:
            A project carrying only the matching (expr, out_name) pairs.
        """
        var e = ExprArray()
        var names = List[String]()
        for i in range(len(self.exprs)):
            var wanted = False
            for j in range(len(keep)):
                if keep[j] == self.out_names[i]:
                    wanted = True
                    break
            if wanted:
                e.append(self.exprs[i].copy())
                names.append(self.out_names[i])
        return Self(e^, names^)

    def to_ops(self) -> Slab[MorselOp]:
        """Build the leaf's `Slab[MorselOp]` — ONE `OP_PROJECT` tail.

        The leaf PREDICATES do NOT become `OP_FILTER`s here: every agg arm
        AND-combines them into the `ParquetSourceData` decode filter, which is
        what makes the scan STREAM. The op tail therefore runs AFTER the
        decode-time filter, which is exactly `PROJECT(FILTER(SCAN))`."""
        var e = ExprArray()
        for i in range(len(self.exprs)):
            e.append(self.exprs[i].copy())
        var ops = Slab[MorselOp]()
        ops.append(MorselOp.project(e^, self.out_names.copy()))
        return ops^


# =============================================================================
# AggLeafBinding — the hoisted leaf resolution every arm RECEIVES instead
# of probing the footer for itself.
# =============================================================================


struct AggLeafBinding(Movable):
    """What an agg arm needs to know about its parquet leaf, resolved ONCE by
    the entry point rather than N times by N arms.

    ⚠ TWO SCHEMAS, DELIBERATELY. They are EQUAL for a leaf with no PROJECT, and
    an arm that wants the one it does not have is a bug the names make visible:

        scan_schema        the parquet FOOTER. FILTER columns and the scan
                           projection resolve here, and ONLY here.
        resolution_schema  what the aggregate's KEYS and INPUTS resolve in —
                           the PROJECT's `output_schema` when there is one, the
                           footer schema when there is not.

    Fields:
        scan_schema: The parquet footer schema (file columns).
        resolution_schema: The schema the aggregate's keys/inputs resolve in.
        project: The computed PROJECT, when the leaf carries one.
        scan_projection: The FILE-DERIVED decode projection
            (`leaf_scan_projection`). `Some` iff `project` is `Some`; an arm
            with no project keeps its own agg-derived `needed` list, which is
            file-derived by construction because `resolution_schema` IS the
            footer schema there.
    """

    var scan_schema: Schema
    var resolution_schema: Schema
    var project: Optional[AggLeafProject]
    var scan_projection: Optional[List[String]]

    def __init__(
        out self,
        var scan_schema: Schema,
        var resolution_schema: Schema,
        var project: Optional[AggLeafProject],
        var scan_projection: Optional[List[String]],
    ):
        """Bind a resolved agg leaf."""
        self.scan_schema = scan_schema^
        self.resolution_schema = resolution_schema^
        self.project = project^
        self.scan_projection = scan_projection^

    @staticmethod
    def plain(imm scan_schema: Schema) -> AggLeafBinding:
        """The NO-PROJECT binding: the resolution schema IS the footer schema.

        An arm runs unchanged under this binding — it is the same value the arm
        would probe for itself from the footer."""
        return AggLeafBinding(
            scan_schema.copy(),
            scan_schema.copy(),
            Optional[AggLeafProject](None),
            Optional[List[String]](None),
        )

    def has_project(self) -> Bool:
        """True iff this leaf carries a computed PROJECT."""
        return self.project.__bool__()

    def leaf_ops(self) -> Slab[MorselOp]:
        """The leaf's morsel-op tail — one `OP_PROJECT`, or EMPTY with no
        project (the same `Slab[MorselOp]()` a project-less arm passes)."""
        if self.project:
            return self.project.value().to_ops()
        return Slab[MorselOp]()

    def copy(self) -> Self:
        """Deep-copy the binding (arms take it by `read`; the entry may need
        one per arm attempt)."""
        var p = Optional[AggLeafProject](None)
        if self.project:
            p = Optional[AggLeafProject](self.project.value().copy())
        var sp = Optional[List[String]](None)
        if self.scan_projection:
            sp = Optional[List[String]](self.scan_projection.value().copy())
        return Self(
            self.scan_schema.copy(), self.resolution_schema.copy(), p^, sp^
        )


# =============================================================================
# leaf_scan_projection — ⛔ THE INVARIANT CARRIER. Its signature cannot see an
# `AggregateData`, so it cannot emit a synthetic name.
# =============================================================================


def leaf_scan_projection(
    imm project_exprs: ExprArray,
    imm predicates: Slab[Expr],
) -> List[String]:
    """Derive the FILE columns an agg leaf must decode, from the PROJECT exprs
    and the leaf predicates ONLY.

    First-seen order, de-duplicated. Order is load-bearing for nothing here (the
    arms resolve by name), but a stable order keeps the decode deterministic and
    the traces comparable.

    ⛔ DO NOT ADD AN `AggregateData` PARAMETER, and do not add an "extra names"
    escape hatch. The absence of the aggregate from this signature IS the
    enforcement of the file-derived scan projection: the only two places a
    synthetic `__grp_key_<n>` / `__agg_in_<n>` name exists are `AggregateData`
    and the PROJECT's OUTPUT names, and this function is handed neither. It
    reads the INPUT side of each projection expr, which is file columns by
    construction.

    Args:
        project_exprs: The PROJECT's expressions (their column refs are the
            FILE columns the projection reads).
        predicates: Every predicate that will be evaluated at the leaf (the
            scan-pushed filter and any PLAN_FILTER between the project and the
            scan). A filter column missing from the decode projection is a
            WRONG SURVIVING SET, not a crash, which is why they are a first-
            class input here.

    Returns:
        The de-duplicated file-column projection, first-seen order.
    """
    var raw = List[String]()
    for i in range(len(project_exprs)):
        collect_expr_cols(project_exprs[i], raw)
    for i in range(len(predicates)):
        collect_expr_cols(predicates[i], raw)

    var out = List[String]()
    for i in range(len(raw)):
        var seen = False
        for j in range(len(out)):
            if out[j] == raw[i]:
                seen = True
                break
        if not seen:
            out.append(raw[i])
    return out^


# =============================================================================
# The AGREEMENT CHECK — a real raise, once per query.
# =============================================================================


def assert_leaf_schema_agrees(
    imm expected: Schema, imm actual: Schema, imm site: String
) raises:
    """RAISE if the batch the leaf actually produced does not carry the schema
    the arm's dtype gates were decided against.

    ⛔ NOT a `debug_assert` — see this file's header. The expected schema is
    DERIVED (`_infer_expr_field` never raises; a column it cannot resolve
    becomes `Field(name, ArrowType.NULL, True)`), so a wrong non-NULL inference
    that disagrees with the kernel would otherwise be a SILENT WRONG ANSWER.

    Compares NAMES and `ArrowType`s in order. Nullability is deliberately NOT
    compared: a projection over a non-null column may legitimately widen, and a
    nullability mismatch is not a value hazard for any arm's gate.

    Args:
        expected: The resolution schema the arm's gates were decided against.
        actual: The schema of the batch the leaf produced.
        site: The arm name, for the message.
    """
    var ok = expected.num_columns() == actual.num_columns()
    if ok:
        for i in range(expected.num_columns()):
            if expected.field_name(i) != actual.field_name(i):
                ok = False
                break
            if expected.field_arrow_type(i) != actual.field_arrow_type(i):
                ok = False
                break
    if ok:
        return

    var exp_s = String("[")
    for i in range(expected.num_columns()):
        if i > 0:
            exp_s += String(", ")
        exp_s += expected.field_name(i)
    exp_s += String("]")
    var act_s = String("[")
    for i in range(actual.num_columns()):
        if i > 0:
            act_s += String(", ")
        act_s += actual.field_name(i)
    act_s += String("]")
    raise Error(
        String(
            "agg_leaf_resolution: the agg LEAF's emitted schema disagrees with"
            " the inferred resolution schema at "
        )
        + site
        + String(" — inferred ")
        + exp_s
        + String(" vs emitted ")
        + act_s
        + String(
            ". Every dtype gate on this arm was decided against the INFERRED"
            " schema, so this is refused rather than folded."
        )
    )


# =============================================================================
# The PEEL — a computed PROJECT over a parquet chain, or nothing.
# =============================================================================


def agg_leaf_project_of(imm child: LogicalPlan) -> Optional[AggLeafProject]:
    """If `child` is a `PLAN_PROJECT`, return its exprs + the OUTPUT NAMES read
    off its `output_schema`; otherwise None.

    The caller is responsible for having already established that the chain
    BELOW the project bottoms in a parquet SCAN
    (`_agg_child_is_project_over_scan`) — this function only lifts the node."""
    if child.tag != PLAN_PROJECT or not child._project:
        return None
    ref pd = child._project.value()[]
    var e = ExprArray()
    for i in range(len(pd.exprs)):
        e.append(pd.exprs[i].copy())
    var names = List[String]()
    for i in range(child.output_schema.num_columns()):
        names.append(child.output_schema.field_name(i))
    if len(names) != len(e):
        # A PROJECT whose declared output schema does not have one field per
        # expression is not a shape we can bind — DECLINE rather than guess.
        return None
    return Optional[AggLeafProject](AggLeafProject(e^, names^))


# =============================================================================
# The STREAMING route's agreement gate — a fail-OPEN predicate, not a raise.
# =============================================================================


def leaf_project_agrees_with_resolution(
    imm project: AggLeafProject,
    imm resolution_schema: Schema,
    imm scan_schema: Schema,
) -> Bool:
    """True iff the PROJECT's exprs, inferred against the FOOTER schema the
    decode will actually hand the operator, produce the names and `ArrowType`s
    the aggregate's gates were decided against.

    ⚠ WHY THIS IS A `Bool` AND NOT `assert_leaf_schema_agrees`'s RAISE, and it
    is a deliberate difference from the collect arms. There the divergence is
    discovered AFTER the leaf is already a resident batch, so there is nothing
    left to fall back to and the only safe act is to refuse. Here the gate runs
    BEFORE any decode, and the arm it guards states its own rule: *"a DECLINE
    here is always a fall-through, never a raise — route 2b is still a complete
    answer"*. Route 2b folds over the batch's ACTUAL schema, so falling through
    on a disagreement is not merely safe, it is the correct answer.

    ⚠ AND IT IS NOT VACUOUS EVEN THOUGH BOTH SIDES NOW WALK ONE LADDER.
    `walk_expr_field` is shared, but the two entry points are given DIFFERENT
    SCHEMAS: `resolution_schema` is the PROJECT node's `output_schema`, inferred
    at PLAN-BUILD time against the node's declared child schema, while this
    walks the same exprs against the schema read from the parquet FOOTER. A plan
    built against a declared schema that disagrees with the file — a column
    widened, renamed, or absent — diverges here and nowhere else. A missing
    column makes `field_for_expr` raise; that is caught and reported as a
    disagreement, because it is one.

    Args:
        project: The leaf's computed PROJECT.
        resolution_schema: What the aggregate's inputs were resolved in.
        scan_schema: The parquet footer schema.

    Returns:
        True to admit the streaming route; False to fall through.
    """
    if resolution_schema.num_columns() != len(project.exprs):
        return False
    if len(project.out_names) != len(project.exprs):
        return False
    for i in range(len(project.exprs)):
        if resolution_schema.field_name(i) != project.out_names[i]:
            return False
        var at: ArrowType
        try:
            at = field_for_expr(project.exprs[i], scan_schema).arrow_type
        except:
            # A projection expr referencing a column absent from the FOOTER.
            # The decode could not evaluate it; decline.
            return False
        if resolution_schema.field_arrow_type(i) != at:
            return False
    return True
