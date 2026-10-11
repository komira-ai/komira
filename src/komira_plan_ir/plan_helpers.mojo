# =============================================================================
# core.plan.plan_helpers -- PURE LogicalPlan / Expr / Schema STRUCTURAL
# utilities.
# =============================================================================
#
# ★ WHY IT LIVES IN CORE. It is not an optimizer pass: its ENTIRE import list
# is `std` + the core packages -- no pass, no rule, no engine, no filesystem. SDK
# modules that need only these helpers (agg_node_exec, parquet_helpers,
# agg_scalar_fold, plan_validation_gate, explain_analyze_render, the scan
# share / dedup / CSE passes, ...) would otherwise depend on
# `komira_optimizer` for them, and every SDK module that can reach such an
# importer would be pulled into the execution tier. Keeping these pure
# functions here keeps that edge out of the SDK.
#
# ⚠ THE COST, STATED. Almost everything depends on the core packages, so an edit to
# THIS file invalidates far more than an edit to an optimizer module would.
# That is the price of the tier being correct; it is why a file lands here
# only when its import list proves it is core.
#
# Contains:
#   - TransformedPlan: plan + changed flag (DataFusion pattern)
#   - _take_*_parts: zero-copy ownership extraction via OwnedPointer.into_inner()
#   - _copy_schema: copy a Schema (still needed for schema-deriving nodes)
#   - _copy_expr_array / _copy_agg_expr_array: deep copy expression arrays
#   - _copy_set / _union_sets: Set[String] utilities
#   - _collect_expr_columns: collect column references from expressions
#   - Plan tree introspection (_plan_has_tag, etc.)
# =============================================================================

from std.collections import Set
from std.memory import OwnedPointer, ArcPointer

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.record_batch import RecordBatch
from komira_plan_expr.expr import (
    Expr,
    EXPR_COL_REF,
    EXPR_LITERAL,
    EXPR_BINARY_OP,
    EXPR_UNARY_OP,
    EXPR_CAST,
    EXPR_ALIAS,
    EXPR_STRING_OP,
    EXPR_WHEN,
    EXPR_IN_LIST,
    EXPR_AGG_FN,
    EXPR_WINDOW_FN,
    EXPR_CORRELATED_SUBQUERY,
    EXPR_REGEXP,
    EXPR_MATH_FN,
    EXPR_MATH_FN2,
    EXPR_SUBSTRING,
    EXPR_STRING_FN,
    EXPR_STRING_FN_N,
    EXPR_UDF_CALL,
    EXPR_EXTRACT,
    EXPR_JSON_EXTRACT,
    EXPR_STRUCT_FIELD,
    EXPR_STRUCT_FIELD_IDX,
    EXPR_MAP_GET,
    COL_SIDE_NONE,
    WhenCaseData,
    BIN_AND,
    BIN_OR,
    UN_NOT,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.agg_expr import AggExpr

# `_collect_expr_columns` below is an
# ADAPTER over the ONE column-reference walk; see `expr_walk.mojo`'s header.
from komira_plan_expr.expr_walk import unique_name_sink, walk_expr_column_refs
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    FilterData,
    ProjectData,
    AggregateData,
    JoinData,
    SortData,
    LimitData,
    DistinctData,
    TopNData,
    ScanData,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_ASOF_JOIN,
    PLAN_UNION,
    PLAN_VIEW_REF,
    PLAN_CSE_REF,
    PLAN_CAST_TO_VARCHAR,
    PLAN_TAG_COUNT,
    PartitionByData,
    PartitionTopNData,
    SOURCE_PARQUET,
    SOURCE_IN_MEMORY,
    plan_tag_name,
)
from komira_plan_expr.udf_data import UdfData
from komira_plan_expr.partition_expr import PartitionExpr
from komira_plan_stats.table_stats import TableStats
from komira_scan_source.source_variant import SourceVariant
from komira_scan_source.parquet_source import ParquetSource
from komira_scan_source.in_memory_source import InMemorySource
from komira_collections.slab import Slab


# =============================================================================
# TransformedPlan -- plan + changed flag (DataFusion Transformed pattern)
# =============================================================================

struct TransformedPlan(Movable):
    """A LogicalPlan paired with a flag indicating whether it changed.

    Rules return TransformedPlan instead of bare LogicalPlan. The `changed`
    flag allows the optimizer to skip subsequent rules or avoid rebuilding
    parent nodes when nothing changed.

    Uses OwnedPointer[LogicalPlan] internally to avoid Mojo
    partial-destruction issues with Schema fields in compound structs.
    """
    var _plan: OwnedPointer[LogicalPlan]
    var changed: Bool

    def __init__(out self, var plan: LogicalPlan, changed: Bool):
        self._plan = OwnedPointer(plan^)
        self.changed = changed

    @staticmethod
    @always_inline
    def no(var plan: LogicalPlan) -> Self:
        """Plan was not modified."""
        return Self(plan^, False)

    @staticmethod
    @always_inline
    def yes(var plan: LogicalPlan) -> Self:
        """Plan was modified."""
        return Self(plan^, True)

    @always_inline
    def plan_ref(self) -> ref [origin_of(self._plan[])] LogicalPlan:
        """Get a reference to the plan (read-only)."""
        return self._plan[]


# =============================================================================
# Zero-copy child extraction via OwnedPointer.into_inner()
# =============================================================================
#
# Each _take_*_parts function destructures a plan node into its component
# parts. The plan's variant data is consumed (moved out). After calling
# these, the original plan is in a partially-consumed state and MUST NOT
# be reused -- the caller rebuilds a new plan from the returned parts.
#
# Zero allocations, zero copies.
# =============================================================================

# Zero-copy child extraction is done INLINE at each call site using this pattern:
#
#   var schema = plan.output_schema^          # move schema out first
#   var fd: FilterData = plan._filter.value()[]^  # move variant data out
#   var child: LogicalPlan = fd.child.into_inner()[]  # extracts child
#   var pred = fd.predicate^                    # move predicate
#
# Mojo tuples do not support Movable-only types (like LogicalPlan) in
# tuples of 2+ elements, so helper functions cannot return tuples of parts.
# The inline pattern above achieves zero-copy extraction without tuples.
# The _take_*_child functions below use the deep-copy pattern.


# =============================================================================
# Schema-preserving reconstruction helpers
# =============================================================================
#
# For nodes that do not change the output schema (Filter, Sort, Limit,
# Distinct, TopN), we can move the old schema directly into the new node
# instead of re-deriving it from the child. This avoids iterating fields.
# =============================================================================

def _rebuild_filter(var pred: Expr, var child: LogicalPlan, var schema: Schema) -> LogicalPlan:
    """Rebuild a Filter node with a pre-computed output schema."""
    var plan = LogicalPlan(PLAN_FILTER, schema^)
    plan._filter = OwnedPointer(FilterData(pred^, child^))
    return plan^


def _rebuild_sort(var keys: List[String], var desc: List[Bool], var child: LogicalPlan, var schema: Schema) -> LogicalPlan:
    """Rebuild a Sort node with a pre-computed output schema."""
    var plan = LogicalPlan(PLAN_SORT, schema^)
    plan._sort = OwnedPointer(SortData(keys^, desc^, child^))
    return plan^


def _rebuild_limit(n: Int, var child: LogicalPlan, var schema: Schema, offset: Int = 0) -> LogicalPlan:
    """Rebuild a Limit node with a pre-computed output schema.

    `offset` (default 0) forwards the RANGE window so a
    reconstruction never silently drops it."""
    var plan = LogicalPlan(PLAN_LIMIT, schema^)
    plan._limit = OwnedPointer(LimitData(n, child^, offset=offset))
    return plan^


def _rebuild_distinct(var cols: Optional[List[String]], var child: LogicalPlan, var schema: Schema) -> LogicalPlan:
    """Rebuild a Distinct node with a pre-computed output schema."""
    var plan = LogicalPlan(PLAN_DISTINCT, schema^)
    plan._distinct = OwnedPointer(DistinctData(cols^, child^))
    return plan^


def _rebuild_topn(var keys: List[String], var desc: List[Bool], n: Int, var child: LogicalPlan, var schema: Schema) -> LogicalPlan:
    """Rebuild a TopN node with a pre-computed output schema."""
    var plan = LogicalPlan(PLAN_TOPN, schema^)
    plan._topn = OwnedPointer(TopNData(keys^, desc^, n, child^))
    return plan^


def _rebuild_scan(
    var path: String, stype: UInt8, var full_schema: Optional[Schema],
    var proj: Optional[List[String]], var filt: Optional[Expr], var out_schema: Schema,
    var row_count: Optional[Int] = None,
    var table_stats: Optional[TableStats] = None,
) -> LogicalPlan:
    """Rebuild a Scan node with a pre-computed output schema.

    The source identity is built as
    a `SourceVariant` internally — for PARQUET, wraps path+schema in
    ParquetSource; for IN_MEMORY, builds an empty-batch InMemorySource
    whose `name` carries the registry handle (engine-side `_compile_scan`
    resolves the actual batch via `registry.lookup(name)`). Rule sites
    that build a fresh Scan from scratch always start from a
    non-IN-MEMORY source, so the empty-batch path is sufficient. IN-MEMORY
    scans needing batch preservation use `_copy_plan` (which routes
    through `SourceVariant.copy()` refcount-bump).
    """
    # Build the SourceVariant from the (path, type) args.
    var schema_for_src: Schema
    if full_schema:
        schema_for_src = full_schema.value().copy()
    else:
        schema_for_src = _copy_schema(out_schema)
    var source: SourceVariant
    if stype == SOURCE_PARQUET:
        var ps = ParquetSource(
            String(path),
            schema_for_src^,
            Optional[String](None),
        )
        source = SourceVariant(ps^)
    elif stype == SOURCE_IN_MEMORY:
        var nm: Optional[String] = Optional(String(path))
        var sl = Slab[RecordBatch].create(0)
        var im = InMemorySource._from_record_batches_unchecked(sl^, schema_for_src^, nm^)
        source = SourceVariant(im^)
    else:
        var ps = ParquetSource(
            String(path),
            schema_for_src^,
            Optional[String](None),
        )
        source = SourceVariant(ps^)
    var plan = LogicalPlan(PLAN_SCAN, out_schema^)
    plan._scan = OwnedPointer(ScanData(source^, full_schema^, proj^, filt^, row_count^, table_stats^))
    return plan^


# =============================================================================
# _take_*_child functions
#
# They extract (copy) the child for call sites that only need the child.
# =============================================================================

def _take_filter_child(plan: LogicalPlan) raises -> LogicalPlan:
    """Extract and copy the child from a Filter node."""
    return _copy_plan(plan._filter.value()[].child[])

def _take_project_child(plan: LogicalPlan) raises -> LogicalPlan:
    """Extract and copy the child from a Project node."""
    return _copy_plan(plan._project.value()[].child[])

def _take_aggregate_child(plan: LogicalPlan) raises -> LogicalPlan:
    """Extract and copy the child from an Aggregate node."""
    return _copy_plan(plan._aggregate.value()[].child[])

def _take_join_left(plan: LogicalPlan) raises -> LogicalPlan:
    """Extract and copy the left child from a Join node."""
    return _copy_plan(plan._join.value()[].left[])

def _take_join_right(plan: LogicalPlan) raises -> LogicalPlan:
    """Extract and copy the right child from a Join node."""
    return _copy_plan(plan._join.value()[].right[])

def _take_sort_child(plan: LogicalPlan) raises -> LogicalPlan:
    """Extract and copy the child from a Sort node."""
    return _copy_plan(plan._sort.value()[].child[])

def _take_limit_child(plan: LogicalPlan) raises -> LogicalPlan:
    """Extract and copy the child from a Limit node."""
    return _copy_plan(plan._limit.value()[].child[])

def _take_distinct_child(plan: LogicalPlan) raises -> LogicalPlan:
    """Extract and copy the child from a Distinct node."""
    return _copy_plan(plan._distinct.value()[].child[])

def _take_topn_child(plan: LogicalPlan) raises -> LogicalPlan:
    """Extract and copy the child from a TopN node."""
    return _copy_plan(plan._topn.value()[].child[])

def _take_partition_by_child(plan: LogicalPlan) raises -> LogicalPlan:
    """Extract and copy the child from a PartitionBy node."""
    return _copy_plan(plan._partition_by.value()[].child[])

def _take_partition_topn_child(plan: LogicalPlan) raises -> LogicalPlan:
    """Extract and copy the child from a PartitionTopN node."""
    return _copy_plan(plan._partition_topn.value()[].child[])


# =============================================================================
# Schema copy
# =============================================================================

@always_inline
def _copy_schema(schema: Schema) -> Schema:
    """Create a new Schema with the same fields as the input.

    Use `Schema.field_at_unchecked(idx)`
    rather than the bare 3-arg `Field` ctor, so every metadata
    slot (`_tz`, decimal `(p, s)`, `_dict_index_type`, `_union_type_ids`,
    `_flags`, kv-metadata, nested children) is preserved across the
    optimizer's rule-driven Schema rebuilds (optimizer_filter,
    optimizer_scan_dedup, optimizer_scalar_broadcast, optimizer_projection,
    optimizer_join, _rebuild_scan fallback, and _copy_plan). Uses
    the non-raising `field_at_unchecked` sibling so the function signature
    stays non-raising (preserves every non-raising caller including those
    that are `fn` or `def`-without-`raises`). The loop `range(num_columns())`
    is always in-range by construction. Mirrors the engine-side
    `plan_compiler._copy_schema`.
    """
    var builder = SchemaBuilder()
    for i in range(schema.num_columns()):
        builder.add_field(schema.field_at_unchecked(i))
    return builder.build()


# =============================================================================
# Variant-payload presence — the one fact `_copy_plan`'s post-condition needs
# =============================================================================

def _plan_payload_present(plan: LogicalPlan) -> Bool:
    """Is the variant Optional that `plan.tag` names POPULATED?

    Read-only, allocation-free, one Optional bool-test. It answers exactly one
    question — "does this node carry the payload its tag claims?" — and is the
    predicate `_copy_plan` checks on its own OUTPUT before returning.

    For a tag with no variant field this returns False and that is CORRECT:
    there is nothing to carry. `_copy_plan` therefore
    checks `input_had_payload -> output_has_payload`, not `output_has_payload`
    on its own — a payload-free node must not be reported as a dropped one.
    """
    if plan.tag == PLAN_SCAN:
        return Bool(plan._scan)
    elif plan.tag == PLAN_FILTER:
        return Bool(plan._filter)
    elif plan.tag == PLAN_PROJECT:
        return Bool(plan._project)
    elif plan.tag == PLAN_AGGREGATE:
        return Bool(plan._aggregate)
    elif plan.tag == PLAN_JOIN:
        return Bool(plan._join)
    elif plan.tag == PLAN_SORT:
        return Bool(plan._sort)
    elif plan.tag == PLAN_LIMIT:
        return Bool(plan._limit)
    elif plan.tag == PLAN_DISTINCT:
        return Bool(plan._distinct)
    elif plan.tag == PLAN_TOPN:
        return Bool(plan._topn)
    elif plan.tag == PLAN_PARTITION_BY:
        return Bool(plan._partition_by)
    elif plan.tag == PLAN_PARTITION_TOPN:
        return Bool(plan._partition_topn)
    elif plan.tag == PLAN_ASOF_JOIN:
        return Bool(plan._asof_join)
    elif plan.tag == PLAN_UNION:
        return Bool(plan._union)
    elif plan.tag == PLAN_VIEW_REF:
        return Bool(plan._view_ref)
    elif plan.tag == PLAN_CSE_REF:
        return Bool(plan._cse_ref)
    elif plan.tag == PLAN_CAST_TO_VARCHAR:
        return Bool(plan._cast_to_varchar)
    return False


def _tag_carries_a_variant_payload(tag: UInt8) -> Bool:
    """Does `tag` name a `LogicalPlan` variant field at all?

    THE 16 TAGS. Tags 0..15 are declared in
    `komira_plan_ir/logical_plan.mojo` and each owns a variant Optional on
    `LogicalPlan`. Tag values 16/17 are retired and must not be reused.

    Enumerated rather than written `tag <= PLAN_CAST_TO_VARCHAR` so that adding
    a tag is a decision someone makes here, not an off-by-one that inherits an
    answer.
    """
    return (
        tag == PLAN_SCAN
        or tag == PLAN_FILTER
        or tag == PLAN_PROJECT
        or tag == PLAN_AGGREGATE
        or tag == PLAN_JOIN
        or tag == PLAN_SORT
        or tag == PLAN_LIMIT
        or tag == PLAN_DISTINCT
        or tag == PLAN_TOPN
        or tag == PLAN_PARTITION_BY
        or tag == PLAN_PARTITION_TOPN
        or tag == PLAN_ASOF_JOIN
        or tag == PLAN_UNION
        or tag == PLAN_VIEW_REF
        or tag == PLAN_CSE_REF
        or tag == PLAN_CAST_TO_VARCHAR
    )


# =============================================================================
# Deep copy of plan nodes
# =============================================================================

def _copy_plan(plan: LogicalPlan) raises -> LogicalPlan:
    """Deep copy a LogicalPlan node and all its children.

    THE COPIER MAY NOT PRODUCE A SHELL. A fallback of

        # Unknown tag: return a placeholder
        return LogicalPlan(plan.tag, _copy_schema(plan.output_schema))

    produces a node that KEEPS THE TAG AND DROPS THE PAYLOAD — e.g. a cast
    node that still claims to be a cast and can no longer say what it casts.
    That is silent corruption, and this function is called from many sites
    across the optimizer rule modules plus `EngineContext.explain_analyze`.

    THE GUARANTEE IS STRUCTURAL, NOT CLERICAL. "Every tag has an arm" is a fact
    about today that a future commit can falsify in silence. So the invariant
    is checked, not asserted in a comment:

      * PRE: a node whose tag names a variant field but whose field is EMPTY is
        already corrupt on arrival. Copying it would launder that into
        something that looks freshly built, so it RAISES.
      * BODY: one arm per tag, and a terminal RAISE naming the tag. A tag with
        no arm cannot reach a caller as a plan.
      * POST: if the INPUT carried a payload and the OUTPUT does not, RAISE.
        This is what a future arm that forgets a field runs into -- the check
        does not care which arm produced the node, so it covers arms that do
        not exist yet.

    The post-condition is stated as `input_had -> output_has`, NOT as
    `output_has`, because a tag with no variant field legitimately carries
    nothing (see `_tag_carries_a_variant_payload`). A payload-free node is not
    a dropped one.
    """
    if _tag_carries_a_variant_payload(plan.tag) and not _plan_payload_present(
        plan
    ):
        raise Error(
            "_copy_plan: node has tag "
            + String(Int(plan.tag))
            + " but its variant payload is MISSING -- the node was already"
            " corrupt (or partially consumed) on arrival. Refusing to copy it"
            " into something that looks intact."
        )

    var copied = _copy_plan_body(plan)

    if _plan_payload_present(plan) and not _plan_payload_present(copied):
        raise Error(
            "_copy_plan: DROPPED the variant payload for tag "
            + String(Int(plan.tag))
            + " -- the copy kept the tag and lost the node. Its arm in"
            " `_copy_plan_body` does not populate the variant field the tag"
            " names."
        )

    # ★★ POST-2: THE UDF SNAPSHOT SURVIVED.
    #
    # POST-1 above checks that the VARIANT payload is present, and it passes
    # over a copy that returns a Filter with its `_filter` populated and its
    # `udf` gone. A node can be structurally intact and have lost the
    # customer's function.
    #
    # ⚠ THIS CHECK, NOT THE THREE ARMS, IS THE GUARANTEE. The arms are the
    # answer; this is the invariant, and it covers arms that DO NOT EXIST YET —
    # which is the whole reason POST-1 was written that way. `has_udf()` is
    # already tag-dispatched over all three carriers, so a fourth carrier is
    # covered the moment `LogicalPlan.has_udf()` learns about it.
    if plan.has_udf() and not copied.has_udf():
        raise Error(
            "_copy_plan: DROPPED THE UDF SNAPSHOT for tag "
            + String(Int(plan.tag))
            + " -- the copy is structurally intact and no longer carries the"
            " customer's function. The ordinary field on a UDF-carrying node is"
            " a PLACEHOLDER (`lit(true)` for a filter, placeholder col-refs for"
            " a project), so executing this copy would run the placeholder and"
            " return wrong rows with rc=0. Its arm in `_copy_plan_body` must"
            " use the `*_with_udf` factory."
        )
    return copied^


def _copy_plan_body(plan: LogicalPlan) raises -> LogicalPlan:
    """One arm per plan tag; RAISES on a tag it does not model.

    Call `_copy_plan`, not this -- the pre/post conditions that make the copy
    trustworthy live there.
    """
    if plan.tag == PLAN_SCAN:
        # Route the source identity through
        # `SourceVariant.copy()` (refcount-bumps an InMemorySource's
        # ArcPointer[Slab[RecordBatch]] without buffer byte-copy); the
        # InMemorySource arm of the SourceVariant carries the batch payload.
        var proj_copy: Optional[List[String]] = None
        if plan._scan.value()[].projection:
            proj_copy = plan._scan.value()[].projection.value().copy()
        var filter_copy: Optional[Expr] = None
        if plan._scan.value()[].filter:
            filter_copy = plan._scan.value()[].filter.value().copy()
        var full_schema: Schema
        if plan._scan.value()[].schema:
            full_schema = _copy_schema(plan._scan.value()[].schema.value())
        else:
            full_schema = _copy_schema(plan.output_schema)
        var rc_copy: Optional[Int] = None
        if plan._scan.value()[].row_count:
            rc_copy = plan._scan.value()[].row_count.value()
        var ts_copy: Optional[TableStats] = None
        if plan._scan.value()[].table_stats:
            ts_copy = Optional[TableStats](plan._scan.value()[].table_stats.value().copy())
        # Preserve the scan's
        # `source_kind` across the deep-copy rebuild (the plan-compile cache
        # `.copy()` and every optimizer copy route here). Without threading
        # the kind the copy would reset it to COLUMNAR and a routing predicate
        # would misread the copied scan.
        return LogicalPlan.scan_from_source(
            plan._scan.value()[].source.copy(),
            full_schema^,
            proj_copy^,
            filter_copy^,
            rc_copy^,
            ts_copy^,
            plan._scan.value()[].source_kind,
        )

    elif plan.tag == PLAN_FILTER:
        var child = _copy_plan(plan._filter.value()[].child[])
        var pred = plan._filter.value()[].predicate.copy()
        # ★★ THE UDF SNAPSHOT IS PRESERVED.
        #
        # A copy of a UDF-carrying Filter that drops `udf` comes back WITHOUT
        # the customer's function — and `FilterData.predicate` on that path is
        # the `lit(true)` PLACEHOLDER the UDF path stamps, so the copy would be
        # a node that returns EVERY ROW and says nothing.
        #
        # ⚠ THE BLAST RADIUS IS NOT PUSHDOWN. `_copy_plan` is called from many
        # sites across the optimizer rule modules plus
        # `EngineContext.explain_analyze`, and every `_take_*_child` helper in
        # this file routes through it, so ANY pass that copies a subtree
        # would drop the UDF. Pinned by the optimizer UDF-opacity tests.
        if plan._filter.value()[].has_udf():
            return LogicalPlan.filter_with_udf(
                pred^,
                child^,
                OwnedPointer[UdfData](
                    plan._filter.value()[].udf.value()[].copy()
                ),
            )
        return LogicalPlan.filter(pred^, child^)

    elif plan.tag == PLAN_PROJECT:
        var child = _copy_plan(plan._project.value()[].child[])
        var exprs = _copy_expr_array(plan._project.value()[].exprs)
        # Preserve the
        # `is_cse_introduced` barrier flag across plan copies.
        # `push_predicates_down` reads it to skip pushing past a
        # CSE-materializer Project; dropping it silently would let
        # predicates leak below a synthetic Project and dangle the
        # `_cse_*` ColRef target.
        var cse_flag = plan._project.value()[].is_cse_introduced
        # ★★ THE UDF SNAPSHOT IS PRESERVED. See the FILTER arm above. On a
        # Project a dropped payload is worse to diagnose: `ProjectData.exprs`
        # on the UDF path are PLACEHOLDER col-refs, so the copy would be a
        # valid-looking projection of the wrong columns rather than an
        # obviously empty node.
        if plan._project.value()[].has_udf():
            return LogicalPlan.project_with_udf(
                exprs^,
                child^,
                OwnedPointer[UdfData](
                    plan._project.value()[].udf.value()[].copy()
                ),
                cse_flag,
            )
        return LogicalPlan.project(exprs^, child^, cse_flag)

    elif plan.tag == PLAN_AGGREGATE:
        var child = _copy_plan(plan._aggregate.value()[].child[])
        var gb = _copy_expr_array(plan._aggregate.value()[].group_by)
        var aggs = _copy_agg_expr_array(plan._aggregate.value()[].agg_exprs)
        # ★★ THE UDF SNAPSHOT IS PRESERVED. See the FILTER arm above.
        if plan._aggregate.value()[].has_udf():
            return LogicalPlan.aggregate_with_udf(
                gb^,
                aggs^,
                child^,
                OwnedPointer[UdfData](
                    plan._aggregate.value()[].udf.value()[].copy()
                ),
            )
        return LogicalPlan.aggregate(gb^, aggs^, child^)

    elif plan.tag == PLAN_JOIN:
        var left = _copy_plan(plan._join.value()[].left[])
        var right = _copy_plan(plan._join.value()[].right[])
        # Preserve algo_hint across plan copies. Without this,
        # `_copy_plan` defaults algo_hint to JOIN_ALGO_AUTO and loses explicit
        # HASH/SORT_MERGE choices set by the caller (DataFrame.join algo=,
        # the auto-select rule in _compile_join, etc).
        # Also preserve `residual` (non-equi / range `predicate=`
        # condition) across plan copies — dropping it silently loses the
        # join condition.
        var join_resid: Optional[OwnedPointer[Expr]] = None
        if plan._join.value()[].has_residual():
            join_resid = OwnedPointer(plan._join.value()[].residual.value()[].copy())
        return LogicalPlan.join(
            left^,
            right^,
            plan._join.value()[].left_on.copy(),
            plan._join.value()[].right_on.copy(),
            plan._join.value()[].join_type,
            plan._join.value()[].algo_hint,
            join_resid^,
        )

    elif plan.tag == PLAN_SORT:
        var child = _copy_plan(plan._sort.value()[].child[])
        # ⛔ CARRY THE
        # EXPLICIT NULL PLACEMENT. `nulls_first` is the LAST, OPTIONAL argument
        # of `LogicalPlan.sort`/`.topn`, so omitting it COMPILES, RUNS, and
        # silently re-derives the DEFAULT placement
        # (`null_order_policy.derived_nulls_first`) — the SAME
        # PLAN SHAPE carrying a DIFFERENT ORDER BY. `_copy_plan` is the generic
        # deep copy the optimizer rule modules reach, so it is the highest-fanout
        # dropper in the tree; it is stated in full here and named by tag at the
        # other rebuild sites.
        #
        # ⚠ BOUND TO A LOCAL RATHER THAN SPELLED INSIDE THE CALL, matching the
        # `ref ld` binds on the LIMIT arms: a third walk of the same
        # `plan._sort.value()[]` chain inside one call expression is the shape
        # that bit `.n`/`.offset` on Mojo 1.0.0.
        var nf_copy = Optional(plan._sort.value()[].nulls_first.copy())
        return LogicalPlan.sort(
            plan._sort.value()[].keys.copy(),
            plan._sort.value()[].descending.copy(),
            child^,
            nf_copy^,
        )

    elif plan.tag == PLAN_LIMIT:
        var child = _copy_plan(plan._limit.value()[].child[])
        # Forward the RANGE offset, don't drop it on rebuild.
        return LogicalPlan.limit(
            plan._limit.value()[].n, child^, offset=plan._limit.value()[].offset
        )

    elif plan.tag == PLAN_DISTINCT:
        var child = _copy_plan(plan._distinct.value()[].child[])
        var cols: Optional[List[String]] = None
        if plan._distinct.value()[].columns:
            cols = plan._distinct.value()[].columns.value().copy()
        return LogicalPlan.distinct(cols^, child^)

    elif plan.tag == PLAN_TOPN:
        var child = _copy_plan(plan._topn.value()[].child[])
        # Carry the EXPLICIT NULL
        # placement; omitting it silently re-derives the DEFAULT
        # (`null_order_policy.derived_nulls_first`).
        var nf_copy = Optional(plan._topn.value()[].nulls_first.copy())
        return LogicalPlan.topn(
            plan._topn.value()[].keys.copy(),
            plan._topn.value()[].descending.copy(),
            plan._topn.value()[].n,
            child^,
            nf_copy^,
        )

    elif plan.tag == PLAN_PARTITION_BY:
        var child = _copy_plan(plan._partition_by.value()[].child[])
        var pk = plan._partition_by.value()[].partition_keys.copy()
        var ok = plan._partition_by.value()[].order_keys.copy()
        var desc = plan._partition_by.value()[].descending.copy()
        var exprs = List[PartitionExpr]()
        for i in range(len(plan._partition_by.value()[].partition_exprs)):
            exprs.append(plan._partition_by.value()[].partition_exprs[i].copy())
        # `partition_by()` raises for unknown PartitionExpr func tags. On a copy
        # path the input is already valid, so the raise is unreachable -- but
        # a handler that returned `LogicalPlan(plan.tag, ...)` would answer an
        # "unreachable" case by producing the exact SHELL this function exists
        # never to produce (and `_copy_plan`'s post-condition would then report
        # a dropped payload instead of the PartitionExpr the factory rejected).
        # `_copy_plan` is a `def`, so it simply propagates.
        return LogicalPlan.partition_by(pk^, ok^, desc^, exprs^, child^)

    elif plan.tag == PLAN_PARTITION_TOPN:
        var child = _copy_plan(plan._partition_topn.value()[].child[])
        # Preserve func + over_fetch_k across deep copy.
        # Preserve output_rank_col_name across
        # deep copy. Optional[String] requires explicit Some/None branch
        # construction (no auto-derive sentinel).
        var rank_col_copy: Optional[String] = None
        if plan._partition_topn.value()[].output_rank_col_name:
            rank_col_copy = String(
                plan._partition_topn.value()[].output_rank_col_name.value()
            )
        return LogicalPlan.partition_topn(
            plan._partition_topn.value()[].partition_keys.copy(),
            plan._partition_topn.value()[].sort_keys.copy(),
            plan._partition_topn.value()[].descending.copy(),
            plan._partition_topn.value()[].k,
            child^,
            plan._partition_topn.value()[].func,
            plan._partition_topn.value()[].over_fetch_k,
            rank_col_copy^,
        )

    elif plan.tag == PLAN_ASOF_JOIN:
        # AsofJoin deep copy.
        ref aj = plan._asof_join.value()[]
        var left = _copy_plan(aj.left[])
        var right = _copy_plan(aj.right[])
        return LogicalPlan.asof_join(
            left^, right^,
            aj.left_keys.copy(),
            aj.right_keys.copy(),
            aj.left_asof,
            aj.right_asof,
            aj.strategy,
            aj.tolerance,
            aj.left_sort_keys.copy(),
            aj.left_sort_desc.copy(),
            aj.right_sort_keys.copy(),
            aj.right_sort_desc.copy(),
        )

    # PLAN_CSE_REF / PLAN_UNION / PLAN_VIEW_REF / PLAN_CAST_TO_VARCHAR:
    # delegate to `LogicalPlan.copy()`, which has an arm for every tag. Without
    # these arms the tag would fall through, and a SHELL LogicalPlan with only
    # `tag` + `output_schema` would lose `_cse_ref` / `_union` / `_view_ref` /
    # `_cast_to_varchar` — which breaks plan-level CSE (the canonical's
    # PLAN_CSE_REF would arrive at `plan_compiler._compile_node` with
    # `_cse_ref = None` after `deduplicate_scans` rebuilds the tree through
    # `_copy_plan` -> `_rewrite`). A hand-written arm here would be a second
    # copy of that logic to keep in sync.
    elif (
        plan.tag == PLAN_CSE_REF
        or plan.tag == PLAN_UNION
        or plan.tag == PLAN_VIEW_REF
        or plan.tag == PLAN_CAST_TO_VARCHAR
    ):
        return plan.copy()

    # A TAG WITH NO ARM IS A REFUSAL, NOT A PLACEHOLDER.
    # `return LogicalPlan(plan.tag, _copy_schema(plan.output_schema))` would
    # hand the caller a node that had the right tag and nothing else. Whatever
    # a future `PLAN_*` is, it arrives here first; failing loudly at the copy is
    # the difference between a build error and a wrong answer.
    raise Error(
        "_copy_plan: no arm for plan tag "
        + String(Int(plan.tag))
        + ". Add one (and its `validate_plan_integrity` arm) -- returning a"
        " tag-only shell is what this raise replaced."
    )


# =============================================================================
# ExprArray / AggExprArray / Set copy helpers
# =============================================================================

def _copy_expr_array(arr: ExprArray) -> ExprArray:
    """Deep copy an ExprArray."""
    var result = ExprArray()
    for i in range(len(arr)):
        result.append(arr[i].copy())
    return result^


def _copy_agg_expr_array(arr: AggExprArray) -> AggExprArray:
    """Deep copy an AggExprArray — ALL child slots (child / child1 / child2 /
    child3), via the canonical `AggExpr.copy()`.

    ⚠ NOT the 3-arg `AggExpr(func, child, alias)` ctor, which SILENTLY DROPS
    child1/child2/child3. `_copy_plan` copies every PLAN_AGGREGATE through
    this helper, so a bivariate `corr(x, y)` would lose its 2nd input
    (`child1`=y) on the FIRST optimize copy and look like a malformed unary
    agg. Unary aggs only use slot 0, so they cannot show the difference.
    `AggExpr.copy()` preserves every populated slot."""
    var result = AggExprArray()
    for i in range(len(arr)):
        result.append(arr[i].copy())
    return result^


def _copy_set(s: Set[String]) -> Set[String]:
    """Copy a Set[String]."""
    var result = Set[String]()
    for item in s:
        result.add(item)
    return result^


def _union_sets(a: Set[String], b: Set[String]) -> Set[String]:
    """Return the union of two sets."""
    var result = _copy_set(a)
    for item in b:
        result.add(item)
    return result^


# =============================================================================
# Expression column collection
# =============================================================================

def _collect_expr_columns(expr: Expr, mut cols: Set[String]):
    """Collect every column name `expr` references into `cols`, DEDUPED and
    UNORDERED.

    ★ A THREE-LINE ADAPTER OVER `expr_walk.walk_expr_column_refs` — THE ONE
    column-reference walk (`compiler_helpers.collect_expr_cols` is the other
    adapter, over an ORDERED `List[String]`). Two copies of a walk drift apart
    — see `expr_walk.mojo`'s header for the failures that shape produces.

    The only thing that differs between the consumers is the CONTAINER — a
    `Set` here, an ordered `List` there — which is the `ExprNameSink`
    parameter. `UniqueNameSink` declares `KIND = NameSinkKind.UNIQUE`, so
    handing this sink to an order-dependent consumer is a COMPILE error.

    ⛔ DO NOT RE-INLINE THE LADDER HERE. A second walk in this file is the
    defect class itself.

    Args:
        expr: The expression to walk.
        cols: Output set of referenced column names.
    """
    var sink = unique_name_sink(cols)
    walk_expr_column_refs(expr, sink)


# =============================================================================
# Expression fingerprinting (for CSE detection)
# =============================================================================

# ⛔ THE FINGERPRINT IS AN IDENTITY, SO IT MUST BE INJECTIVE. Two expressions
# that fingerprint equal are treated as ONE value by CSE Phase A (the second
# project column becomes an alias of the first), by OR-factoring, and by
# `udf_call_column_key` (one scratch column). The encoding is unambiguous by
# construction, EXCEPT the `?:` fallback for an un-armed tag (end of
# `_expr_fingerprint`): it keys on the render, so it is only as injective as
# the render is (komira#1004). Everywhere else:
#
#   * every string taken from the query (column, alias and struct-field names,
#     string and binary literals, patterns, regexp fields, JSON path segments,
#     UDF names, the fallback's render) is written LENGTH-PREFIXED by
#     `_fp_str` (`<byte length>:<bytes>`), so its bytes can contain `,` `(`
#     `)` `]` or a whole other key without moving a boundary. Before this,
#     `x IN ('a,L:sb')` and `x IN ('a', 'b')` keyed alike (komira#960);
#   * every other token is a tag, a decimal number or a dtype name, none of
#     which contains a structural character (`,` `(` `)` `[` `]` `;` `=` `>`);
#   * a literal's key carries its TYPE as well as its value (see
#     `_write_scalar_fingerprint`): `int32(7)` and `int64(7)` are different
#     output column types.
#
# Changing the bytes of a key only moves CSE synthetic names and UDF scratch
# column names, both derived and consumed within one process; nothing persists
# a fingerprint. Falsifier: `test_cse_fingerprint_literal_identity.mojo`.


@always_inline
def _fp_str(s: String) -> String:
    """A length-prefixed string token for a fingerprint: `<byte length>:<s>`.
    The prefix is what lets `s` contain any byte without moving a boundary."""
    return String(s.byte_length()) + ":" + s


def _expr_fingerprint(expr: Expr) -> String:
    """Compute a canonical string fingerprint of an expression tree."""
    if expr.tag == EXPR_COL_REF:
        # A side-qualified reference (`Expr.left("x")` in a join predicate) is
        # a different column from the plain `x`; the side is part of the key.
        var side = expr.col_ref_side()
        if side == COL_SIDE_NONE:
            return "C:" + _fp_str(expr.col_ref_name())
        return "C" + String(Int(side)) + ":" + _fp_str(expr.col_ref_name())
    elif expr.tag == EXPR_BINARY_OP:
        var left_fp = _expr_fingerprint(expr.binary_left_ref())
        var right_fp = _expr_fingerprint(expr.binary_right_ref())
        var op = expr.binary_op()
        # Canonicalize commutative ops (AND/OR): sort child fingerprints
        # lexicographically so `a AND b` and `b AND a` fingerprint equal.
        # Required so dedup groups see structurally-equal
        # pushed filters as one group regardless of plan build order.
        if op == BIN_AND or op == BIN_OR:
            if right_fp < left_fp:
                var tmp = left_fp
                left_fp = right_fp
                right_fp = tmp
        return "B:" + String(Int(op)) + "(" + left_fp + "," + right_fp + ")"
    elif expr.tag == EXPR_UNARY_OP:
        var child_fp = _expr_fingerprint(expr.unary_child_ref())
        return "U:" + String(Int(expr.unary_op())) + "(" + child_fp + ")"
    elif expr.tag == EXPR_LITERAL:
        # ONE ladder for a literal's key, shared with the IN-list values below
        # (`_write_scalar_fingerprint`), so the two cannot drift apart.
        return _scalar_fingerprint(expr.literal_value())
    elif expr.tag == EXPR_CAST:
        # The original arm keyed
        # ONLY on the back-compat numeric `cast_target()` DType. For
        # `CAST(x AS DECIMAL(p,s))` the physical DType is identical across
        # different (p,s); for arrow-target casts (DATE32 vs TIMESTAMP_*) the
        # same `cast_target()` DType can map to distinct arrow types. Without
        # the arrow type_id + decimal precision/scale in the key,
        # `CAST(x AS DECIMAL(10,2))` and `CAST(x AS DECIMAL(18,4))` (or
        # `CAST(x AS DATE32)` vs `CAST(x AS TIMESTAMP)`) fingerprint EQUAL and
        # Phase A whole-expr dedup silently collapses the 2nd to the 1st.
        # Append the full cast-target identity, and `:t1` for TRY_CAST only:
        # a strict CAST raises where TRY_CAST yields NULL.
        var child_fp = _expr_fingerprint(expr.cast_child_ref())
        return (
            "T:" + String(expr.cast_target())
            + ":a" + String(Int(expr.cast_target_arrow().type_id))
            + ":p" + String(expr.cast_decimal_precision())
            + ":s" + String(expr.cast_decimal_scale())
            + (String(":t1") if expr.cast_is_try() else String(""))
            + "(" + child_fp + ")"
        )
    elif expr.tag == EXPR_ALIAS:
        return _expr_fingerprint(expr.alias_child_ref())
    elif expr.tag == EXPR_WHEN:
        # Canonical fingerprint: cond_i / result_i pairs in declaration
        # order, then the default branch. Order is part of CASE/WHEN
        # semantics (the first matching case wins), so we do NOT
        # canonicalize sub-expression order — this is intentionally not
        # commutative.
        ref when_data = expr._when.value()
        var s = String("W:[")
        for i in range(len(when_data.cases)):
            if i > 0:
                s += ","
            s += _expr_fingerprint(when_data.cases[i].condition[])
            s += "=>"
            s += _expr_fingerprint(when_data.cases[i].result[])
        s += "];"
        s += _expr_fingerprint(when_data.default[])
        return s
    elif expr.tag == EXPR_IN_LIST:
        # Canonical fingerprint sorts value
        # fingerprints lexicographically — IN-list is set-membership,
        # so `col IN (a, b)` and `col IN (b, a)` must fingerprint equal.
        var child_fp = _expr_fingerprint(expr.in_list_child_ref())
        ref values = expr.in_list_values_ref()
        var n = len(values)
        var val_fps = List[String]()
        for i in range(n):
            val_fps.append(_scalar_fingerprint(values[i]))
        # Insertion sort (n is bounded by the small-IN factory limit).
        for i in range(1, n):
            var j = i
            while j > 0 and val_fps[j] < val_fps[j - 1]:
                var tmp = val_fps[j - 1]
                val_fps[j - 1] = val_fps[j]
                val_fps[j] = tmp
                j -= 1
        var s = String("I:") + child_fp + String("[") + String(n) + String(":")
        for i in range(n):
            if i > 0:
                s += ","
            s += val_fps[i]
        s += "]"
        return s
    elif expr.tag == EXPR_MATH_FN:
        # Unary scalar
        # math fns MUST fingerprint by their op + child. With a tag-only
        # fallback `sqrt(x)`, `sin(x)`, `cos(x)` all fingerprint EQUAL — CSE
        # Phase A would then rewrite the 2nd/3rd math-fn projections in a
        # multi-math-fn `.select` to `Alias(ColRef(<first_output_name>), ..)`,
        # both (a) emitting an EXPR_COL_REF to an intra-project OUTPUT name the
        # lowering's input-only `col_name_to_idx` doesn't carry (a
        # materialize-time raise) AND (b) silently aliasing every math-fn
        # output to the first fn's value. Mirrors the EXPR_UNARY_OP arm shape.
        var child_fp = _expr_fingerprint(expr.math_fn_child_ref())
        return "M:" + String(Int(expr.math_fn_op())) + "(" + child_fp + ")"
    elif expr.tag == EXPR_MATH_FN2:
        # Binary scalar
        # math fns (e.g. atan2) fingerprint by op + (left, right). NOT
        # canonicalized — atan2 is non-commutative. Mirrors the
        # EXPR_BINARY_OP arm shape (without the AND/OR commutative sort).
        var left_fp = _expr_fingerprint(expr.math_fn2_left_ref())
        var right_fp = _expr_fingerprint(expr.math_fn2_right_ref())
        return (
            "M2:" + String(Int(expr.math_fn2_op()))
            + "(" + left_fp + "," + right_fp + ")"
        )
    elif expr.tag == EXPR_STRING_OP:
        # CSE-FINGERPRINT-COMPLETENESS ★R1: a string op's
        # identity is (op-code, pattern, child). Without this arm
        # `s.contains("foo")` and `s.contains("bar")` (or `.starts_with`
        # vs `.like`) would both fingerprint `"?:7"` and Phase A whole-expr
        # dedup would silently collapse the 2nd column to the 1st's value.
        # Mirrors the EXPR_UNARY_OP arm; pattern is part of identity.
        var child_fp = _expr_fingerprint(expr.string_op_child_ref())
        return (
            "S:" + String(Int(expr.string_op_type())) + ":"
            + _fp_str(expr.string_op_pattern()) + "(" + child_fp + ")"
        )
    elif expr.tag == EXPR_EXTRACT:
        # CSE-FINGERPRINT-COMPLETENESS ★R2: the temporal
        # UNIT (year/month/day/hour/quarter/date_trunc_*) is the whole
        # discriminator. Without this arm `year(d)`, `month(d)`, `day(d)`
        # would all fingerprint `"?:20"` and Phase A would collapse month/day
        # to the year value.
        var child_fp = _expr_fingerprint(expr.extract_child_ref())
        return "X:" + String(Int(expr.extract_unit())) + "(" + child_fp + ")"
    elif expr.tag == EXPR_REGEXP:
        # CSE-FINGERPRINT-COMPLETENESS ★R3: op + pattern +
        # replacement + flags + group + group_name are ALL identity.
        # Without this arm `regexp_extract(s, p1)` vs `regexp_extract(s, p2)`
        # would collapse; worse, `regexp_like` (Bool) and `regexp_extract`
        # (Utf8) would collide -> a Bool column silently returns a Utf8 value.
        var child_fp = _expr_fingerprint(expr.regexp_child_ref())
        return (
            "R:" + String(Int(expr.regexp_op())) + ":"
            + _fp_str(expr.regexp_pattern())
            + ":" + _fp_str(expr.regexp_replacement())
            + ":" + _fp_str(expr.regexp_flags())
            + ":" + String(expr.regexp_group())
            + ":" + _fp_str(expr.regexp_group_name())
            + "(" + child_fp + ")"
        )
    elif expr.tag == EXPR_SUBSTRING:
        # substring: (start, length, child) are identity.
        # Without this arm `substring(s,1,2)` and `substring(s,3,2)` would both
        # fall to the tag-only fallback and CSE Phase A could collapse the 2nd
        # column onto the 1st's value (the silent-wrong shape R1-R6 guard).
        var child_fp = _expr_fingerprint(expr.substring_child_ref())
        return (
            "SUB:" + String(expr.substring_start()) + ":"
            + String(expr.substring_length()) + "(" + child_fp + ")"
        )
    elif expr.tag == EXPR_STRING_FN:
        # The OP is identity. Without this arm
        # `upper(s)` and `lower(s)` would both fall to the tag-only fallback
        # and CSE Phase A could collapse the second onto the first's VALUE —
        # the same silent-wrong shape the SUBSTRING arm above guards.
        var sfn_child_fp = _expr_fingerprint(expr.string_fn_child_ref())
        return (
            "STRFN:" + String(Int(expr.string_fn_op()))
            + "(" + sfn_child_fp + ")"
        )
    elif expr.tag == EXPR_STRING_FN_N:
        # The OP is identity, and so is the
        # ARGUMENT COUNT. Without the count `concat(a, b)` and `concat(a, b,
        # c)` differ only inside the joined child fingerprints, and a
        # SEPARATOR-free join makes `concat(col("ab"))` and `concat(col("a"),
        # col("b"))` collide — CSE Phase A would then share one value between
        # two different expressions, the silent-wrong shape the STRFN and
        # SUBSTRING arms above guard.
        var sfnn_fp = String("STRFNN:") + String(Int(expr.string_fn_n_op()))
        sfnn_fp += ":" + String(expr.string_fn_n_num_args()) + "("
        for i in range(expr.string_fn_n_num_args()):
            if i > 0:
                sfnn_fp += ","
            sfnn_fp += _expr_fingerprint(expr.string_fn_n_arg_ref(i))
        sfnn_fp += ")"
        return sfnn_fp
    elif expr.tag == EXPR_UDF_CALL:
        # The UDF's IDENTITY is the (name, handle) pair,
        # and both are in the fingerprint. The HANDLE is included as well as
        # the name because two registrations under one name (the ordinary case
        # after an eviction) are two different functions.
        #
        # ⚠ THIS ARM IS *NOT* WHAT STOPS TWO DIFFERENT UDFs COLLAPSING ONTO ONE
        # VALUE. MEASURED by deleting exactly these lines and re-running
        # `test_scalar_udf_spelling_e2e`: STILL GREEN.
        #
        # The `else` at the bottom of this function is why. It is not a
        # tag-only fallback — the structural class-killer makes it
        # `"?:" + tag + ":" + _fp_str(String(expr))`, the expression's FULL Writable
        # rendering, precisely so a missing arm degrades to "never deduped"
        # (safe) instead of "always deduped" (wrong). `Expr.write_to`'s UDF arm
        # renders the name, the handle and both types, so the fallback still
        # separates two calls.
        #
        # ⛔ THE IDENTITY IS THEREFORE CARRIED REDUNDANTLY, BY THIS ARM **AND**
        # BY `Expr.write_to`'s. Removing EITHER alone is green; removing BOTH
        # is a measured WRONG ANSWER:
        # `test_a_udf_nests_inside_another_udf` and
        # `test_the_same_udf_twice_in_one_query` both fail on VALUES
        # (AssertionError, rc=0 from the engine), not on a refusal.
        #
        # ★ SO WHY KEEP THIS ARM. Because `udf_call_column_key` — the batch
        # column name the SDK's UDF pre-pass WRITES and `_eval_column_expr`
        # READS — is derived from this function. Without this arm that name is
        # derived from EXPLAIN TEXT, and a display-only edit to
        # `Expr.write_to` silently becomes part of the execution contract.
        # A cheap, explicit fingerprint keeps the two concerns apart.
        var udf_child_fp = _expr_fingerprint(expr.udf_call_child_ref())
        var udf_h = expr.udf_call_handle()
        var udf_h_s = String("-")
        if udf_h:
            udf_h_s = String(udf_h.value())
        return (
            "UDF:" + _fp_str(expr.udf_call_name()) + ":" + udf_h_s + ":"
            + String(Int(expr.udf_call_out_type().type_id))
            + "(" + udf_child_fp + ")"
        )
    elif expr.tag == EXPR_JSON_EXTRACT:
        # CSE-FINGERPRINT-COMPLETENESS ★R4: path segments +
        # output type + `->`/`->>` (extension-metadata) flag are identity.
        # Without this arm `j -> '$.user.id'` and `j -> '$.user.name'`
        # would both fingerprint `"?:19"` and collapse.
        var parent_fp = _expr_fingerprint(expr.json_extract_parent_ref())
        var segs = expr.json_extract_path_segments()
        # Count, then each segment length-prefixed: the ONE key `a.b`
        # (`$."a.b"`) and the TWO keys `a`, `b` (`$.a.b`) must not collide.
        var path_fp = String(len(segs))
        for i in range(len(segs)):
            path_fp += "."
            path_fp += _fp_str(segs[i])
        var meta = "1" if expr.json_extract_preserve_extension_metadata() else "0"
        return (
            "J:" + path_fp + ":"
            + String(Int(expr.json_extract_output_type().type_id))
            + ":" + meta + "(" + parent_fp + ")"
        )
    elif expr.tag == EXPR_STRUCT_FIELD:
        # CSE-FINGERPRINT-COMPLETENESS ★R5: the field NAME is
        # the discriminator. Without this arm `addr.field("city")` and
        # `addr.field("zip")` would both fingerprint `"?:16"` and collapse.
        var parent_fp = _expr_fingerprint(expr.struct_field_parent_ref())
        return "SF:" + _fp_str(expr.struct_field_name()) + "(" + parent_fp + ")"
    elif expr.tag == EXPR_MAP_GET:
        # CSE-FINGERPRINT-COMPLETENESS ★R6: the key is a full
        # Expr — fingerprint it recursively. Without this arm
        # `m.get(lit("city"))` and `m.get(lit("zip"))` both `"?:18"`.
        var parent_fp = _expr_fingerprint(expr.map_get_parent_ref())
        var key_fp = _expr_fingerprint(expr.map_get_key_ref())
        return "MG:(" + parent_fp + ")[" + key_fp + "]"
    elif expr.tag == EXPR_STRUCT_FIELD_IDX:
        # CSE-FINGERPRINT-COMPLETENESS ★R7: the field INDEX is
        # the discriminator (typed-DF `df.field["addr","city"]()` surface).
        # Without this arm two distinct indexed field accesses collapse.
        var parent_fp = _expr_fingerprint(expr.struct_field_idx_parent_ref())
        return (
            "SFI:" + String(expr.struct_field_index())
            + "(" + parent_fp + ")"
        )
    else:
        # CSE-FINGERPRINT-COMPLETENESS structural class-killer:
        # any EXPR_* tag WITHOUT a specific arm above MUST NOT fingerprint
        # equal to a DISTINCT expr of the same tag — that would let CSE
        # Phase A whole-expr dedup (which does NOT gate on
        # `_is_cse_eligible`) silently collapse it to the first occurrence
        # (a wrong answer). Salt the fallback with the expr's full Writable
        # text so a missing arm degrades to "never deduped" (safe-
        # conservative: at worst we miss a legitimate CSE) instead of
        # "always deduped" (unsafe: wrong result). This makes the whole
        # silent-collapse bug class structurally impossible: a future added
        # EXPR_* tag the author forgets to fingerprint can only ever LOSE a
        # CSE opportunity, never produce an incorrect result. `String(expr)`
        # is a full structural rendering (Expr conforms to Writable); it
        # allocates, but the fallback only fires for un-armed tags (now just
        # the dormant/rare ones) and is computed once per top-level expr in
        # Phase A, not per row.
        return "?:" + String(Int(expr.tag)) + ":" + _fp_str(String(expr))


@always_inline
def _write_scalar_fingerprint[W: Writer](mut writer: W, sv: ScalarValue):
    """WRITE what `_scalar_fingerprint` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link binds INDEPENDENTLY, so a
    shared library can bind such a pair CROSSED and crash the host
    interpreter.

    This is the ONE literal-key ladder: `_expr_fingerprint`'s EXPR_LITERAL
    arm and the IN-list values both come here."""
    # ⛔ THE KEY CARRIES THE TYPE, NOT ONLY THE VALUE. `is_int()` is true for
    # int32 AND int64 and `is_float()` for float32 AND float64, so an arm that
    # keyed only on the value collapsed `from_int32(7)` onto `from_int64(7)`
    # and CSE Phase A turned an int32 column into an int64 one (komira#960).
    # int64 and float64 keep their historical short forms; every other width
    # is keyed with its dtype name, like the narrow / unsigned arm below.
    if sv.is_int() and sv.dtype == DType.int64:
        writer.write(String("L:i") + String(Int(sv.int_val)))
        return
    elif sv.is_any_integer():
        # int8 / int16 / int32 and uint8..uint64 (uint64 as its two's-
        # complement bit pattern, which is one-to-one).
        writer.write(
            String("L:in:") + String(sv.dtype) + String(":")
            + String(Int(sv.int_val))
        )
        return
    elif sv.is_float() and sv.dtype == DType.float64:
        writer.write(String("L:f") + String(sv.float_val))
        return
    elif sv.is_float():
        writer.write(
            String("L:fn:") + String(sv.dtype) + String(":")
            + String(sv.float_val)
        )
        return
    elif sv.is_bool():
        if sv.bool_val:
            writer.write(String("L:b1"))
            return
        writer.write(String("L:b0"))
        return
    elif sv.is_string():
        writer.write(String("L:s") + _fp_str(sv.string_val))
        return
    # TEMPORAL LOGICAL-vs-PHYSICAL: a temporal literal carries its value in a
    # dedicated field (date32_val / ts_micros), NOT a field any arm above
    # reads -- without these arms it falls to the value-LESS "L:?" so
    # `DATE 'a'` and `DATE 'b'` fingerprint IDENTICALLY and Phase A whole-expr
    # dedup could collapse two DISTINCT date predicates. Same collision class
    # the CAST arm of `_expr_fingerprint` guards.
    elif sv.is_date32():
        writer.write(String("L:d") + String(Int(sv.date32_val)))
        return
    elif sv.is_timestamp():
        writer.write(String("L:ts") + String(Int(sv.ts_micros)))
        return
    # ★★ CSE-FINGERPRINT — EVERY REMAINING VALUE-BEARING `ScalarValue` KIND.
    #
    # MEASURED with a small probe: without these arms two DISTINCT DECIMAL128
    # literals — 30.75 and 40.00, both (12,2) — BOTH fingerprint `L:?`, so
    # Phase A whole-expr dedup (`_cse_rewrite_project_axis1`, which does NOT
    # consult `_is_cse_eligible`) would rewrite the second top-level Project
    # column to an alias of the first: `SELECT <dec 30.75> a, <dec 40.00> b`
    # answers 30.75 twice. This is a second ladder INSIDE one arm of the TAG
    # ladder, so a completeness check of the tag ladder alone misses it.
    #
    # ⭐ ADDING AN ARM CAN ONLY EVER MAKE TWO EXPRESSIONS **MORE**
    # DISTINGUISHABLE, so this direction cannot introduce a collapse that was
    # not already happening.
    elif sv.is_decimal128():
        writer.write(
            String("L:dec128:") + String(Int(sv.dec128_high)) + String(":")
            + String(Int(sv.dec128_low)) + String(":")
            + String(sv.dec128_precision) + String(":")
            + String(sv.dec128_scale)
        )
        return
    elif sv.is_decimal256():
        writer.write(
            String("L:dec256:") + String(Int(sv.dec256_high_hi)) + String(":")
            + String(Int(sv.dec256_high_lo)) + String(":")
            + String(Int(sv.dec128_high)) + String(":")
            + String(Int(sv.dec128_low)) + String(":")
            + String(sv.dec128_precision) + String(":")
            + String(sv.dec128_scale)
        )
        return
    elif sv.is_interval():
        writer.write(
            String("L:iv:") + String(Int(sv.iv_months)) + String(":")
            + String(Int(sv.iv_days)) + String(":") + String(Int(sv.iv_nanos))
        )
        return
    elif sv.is_time():
        writer.write(
            String("L:tod:") + String(Int(sv.time_unit)) + String(":")
            + String(Int(sv.int_val))
        )
        return
    elif sv.is_duration():
        writer.write(
            String("L:dur:") + String(Int(sv.time_unit)) + String(":")
            + String(Int(sv.int_val))
        )
        return
    elif sv.is_binary():
        writer.write(String("L:bin:") + _fp_str(sv.string_val))
        return
    # A NULL is keyed by its declared type. Two NULLs of ONE type still share
    # a key (they are the same value, and an ELSE-less CASE binds one, so CSE
    # on them matters); `null(int64)` and `null(utf8)` are different output
    # column types and must not.
    elif sv.is_null():
        writer.write(String("L:n:") + String(sv.null_type()))
        return
    writer.write(String("L:?"))
    return


@always_inline
def _scalar_fingerprint(sv: ScalarValue) -> String:
    """Helper: fingerprint a single ScalarValue. Matches the EXPR_LITERAL
    fingerprint shape so canonicalized OR-of-eq fingerprints stay stable
    across the EXPR_IN_LIST rewrite."""
    var out = String()
    _write_scalar_fingerprint(out, sv)
    return out^


# =============================================================================
# ⛔ THERE IS NO NAME-SUBSTITUTION WALK HERE. A partial walk (ColRef / Binary
# / Unary / Cast / Alias / CASE / IN list only) returns a MathFn / string /
# window node AS BUILT, so `SELECT g, sum(sqrt(x)) FROM (SELECT t.g, t.x*4.0
# AS x FROM t JOIN u ..) GROUP BY g` would read the ORIGINAL x. The ONE
# name-substitution walk is `optimizer_project_merge_guard
# .substitute_project_refs`, which `merge_projects` takes. Do not add a copy.

# =============================================================================
# Column-side check (for Rule 10: agg pushdown below join)
# =============================================================================

@always_inline
def _all_columns_in_schema(cols: Set[String], schema: Schema) -> Bool:
    """Check if all column names in the set exist in the given schema."""
    for col_name in cols:
        var found = False
        for i in range(schema.num_columns()):
            if schema.field_name(i) == col_name:
                found = True
                break
        if not found:
            return False
    return True


# =============================================================================
# Plan tree introspection -- zero-copy tag scanning
# =============================================================================

def _plan_has_tag(plan: LogicalPlan, target: UInt8) -> Bool:
    """Check if any node in the plan tree has the given tag."""
    if plan.tag == target:
        return True

    if plan.tag == PLAN_FILTER:
        return _plan_has_tag(plan._filter.value()[].child[], target)
    elif plan.tag == PLAN_PROJECT:
        return _plan_has_tag(plan._project.value()[].child[], target)
    elif plan.tag == PLAN_AGGREGATE:
        return _plan_has_tag(plan._aggregate.value()[].child[], target)
    elif plan.tag == PLAN_JOIN:
        return _plan_has_tag(plan._join.value()[].left[], target) or _plan_has_tag(plan._join.value()[].right[], target)
    elif plan.tag == PLAN_SORT:
        return _plan_has_tag(plan._sort.value()[].child[], target)
    elif plan.tag == PLAN_LIMIT:
        return _plan_has_tag(plan._limit.value()[].child[], target)
    elif plan.tag == PLAN_DISTINCT:
        return _plan_has_tag(plan._distinct.value()[].child[], target)
    elif plan.tag == PLAN_TOPN:
        return _plan_has_tag(plan._topn.value()[].child[], target)
    elif plan.tag == PLAN_PARTITION_BY:
        return _plan_has_tag(plan._partition_by.value()[].child[], target)
    elif plan.tag == PLAN_PARTITION_TOPN:
        return _plan_has_tag(plan._partition_topn.value()[].child[], target)
    return False


def _plan_has_any_tag(plan: LogicalPlan, tag1: UInt8, tag2: UInt8) -> Bool:
    """Check if any node in the plan tree has either of two tags."""
    if plan.tag == tag1 or plan.tag == tag2:
        return True

    if plan.tag == PLAN_FILTER:
        return _plan_has_any_tag(plan._filter.value()[].child[], tag1, tag2)
    elif plan.tag == PLAN_PROJECT:
        return _plan_has_any_tag(plan._project.value()[].child[], tag1, tag2)
    elif plan.tag == PLAN_AGGREGATE:
        return _plan_has_any_tag(plan._aggregate.value()[].child[], tag1, tag2)
    elif plan.tag == PLAN_JOIN:
        return _plan_has_any_tag(plan._join.value()[].left[], tag1, tag2) or _plan_has_any_tag(plan._join.value()[].right[], tag1, tag2)
    elif plan.tag == PLAN_SORT:
        return _plan_has_any_tag(plan._sort.value()[].child[], tag1, tag2)
    elif plan.tag == PLAN_LIMIT:
        return _plan_has_any_tag(plan._limit.value()[].child[], tag1, tag2)
    elif plan.tag == PLAN_DISTINCT:
        return _plan_has_any_tag(plan._distinct.value()[].child[], tag1, tag2)
    elif plan.tag == PLAN_TOPN:
        return _plan_has_any_tag(plan._topn.value()[].child[], tag1, tag2)
    elif plan.tag == PLAN_PARTITION_BY:
        return _plan_has_any_tag(plan._partition_by.value()[].child[], tag1, tag2)
    elif plan.tag == PLAN_PARTITION_TOPN:
        return _plan_has_any_tag(plan._partition_topn.value()[].child[], tag1, tag2)
    return False


def _plan_has_consecutive_filters(plan: LogicalPlan) -> Bool:
    """Check if the plan tree has two or more consecutive Filter nodes."""
    if plan.tag == PLAN_FILTER:
        if plan._filter.value()[].child[].tag == PLAN_FILTER:
            return True
        return _plan_has_consecutive_filters(plan._filter.value()[].child[])
    elif plan.tag == PLAN_PROJECT:
        return _plan_has_consecutive_filters(plan._project.value()[].child[])
    elif plan.tag == PLAN_AGGREGATE:
        return _plan_has_consecutive_filters(plan._aggregate.value()[].child[])
    elif plan.tag == PLAN_JOIN:
        return _plan_has_consecutive_filters(plan._join.value()[].left[]) or _plan_has_consecutive_filters(plan._join.value()[].right[])
    elif plan.tag == PLAN_SORT:
        return _plan_has_consecutive_filters(plan._sort.value()[].child[])
    elif plan.tag == PLAN_LIMIT:
        return _plan_has_consecutive_filters(plan._limit.value()[].child[])
    elif plan.tag == PLAN_DISTINCT:
        return _plan_has_consecutive_filters(plan._distinct.value()[].child[])
    elif plan.tag == PLAN_TOPN:
        return _plan_has_consecutive_filters(plan._topn.value()[].child[])
    return False


def _plan_has_sort_above_limit(plan: LogicalPlan) -> Bool:
    """Check if the plan tree has Limit(Sort(...)) for sort+limit fusion."""
    if plan.tag == PLAN_LIMIT:
        if plan._limit.value()[].child[].tag == PLAN_SORT:
            return True
        return _plan_has_sort_above_limit(plan._limit.value()[].child[])
    elif plan.tag == PLAN_FILTER:
        return _plan_has_sort_above_limit(plan._filter.value()[].child[])
    elif plan.tag == PLAN_PROJECT:
        return _plan_has_sort_above_limit(plan._project.value()[].child[])
    elif plan.tag == PLAN_AGGREGATE:
        return _plan_has_sort_above_limit(plan._aggregate.value()[].child[])
    elif plan.tag == PLAN_JOIN:
        return _plan_has_sort_above_limit(plan._join.value()[].left[]) or _plan_has_sort_above_limit(plan._join.value()[].right[])
    elif plan.tag == PLAN_SORT:
        return _plan_has_sort_above_limit(plan._sort.value()[].child[])
    elif plan.tag == PLAN_DISTINCT:
        return _plan_has_sort_above_limit(plan._distinct.value()[].child[])
    elif plan.tag == PLAN_TOPN:
        return _plan_has_sort_above_limit(plan._topn.value()[].child[])
    return False


# =============================================================================
# Expression-level pre-checks (zero-copy)
# =============================================================================

def _expr_has_foldable(expr: Expr) -> Bool:
    """Check if an expression tree contains a constant-foldable operation."""
    if expr.tag == EXPR_BINARY_OP:
        if expr.binary_left_ref().tag == EXPR_LITERAL and expr.binary_right_ref().tag == EXPR_LITERAL:
            return True
        return _expr_has_foldable(expr.binary_left_ref()) or _expr_has_foldable(expr.binary_right_ref())
    elif expr.tag == EXPR_UNARY_OP:
        if expr.unary_child_ref().tag == EXPR_LITERAL:
            return True
        return _expr_has_foldable(expr.unary_child_ref())
    elif expr.tag == EXPR_CAST:
        return _expr_has_foldable(expr.cast_child_ref())
    elif expr.tag == EXPR_ALIAS:
        return _expr_has_foldable(expr.alias_child_ref())
    return False


def _plan_has_foldable_exprs(plan: LogicalPlan) -> Bool:
    """Check if any expression in the plan tree is constant-foldable."""
    if plan.tag == PLAN_FILTER:
        if _expr_has_foldable(plan._filter.value()[].predicate):
            return True
        return _plan_has_foldable_exprs(plan._filter.value()[].child[])
    elif plan.tag == PLAN_PROJECT:
        for i in range(len(plan._project.value()[].exprs)):
            if _expr_has_foldable(plan._project.value()[].exprs[i]):
                return True
        return _plan_has_foldable_exprs(plan._project.value()[].child[])
    elif plan.tag == PLAN_SCAN:
        if plan._scan.value()[].filter:
            return _expr_has_foldable(plan._scan.value()[].filter.value())
        return False
    elif plan.tag == PLAN_AGGREGATE:
        return _plan_has_foldable_exprs(plan._aggregate.value()[].child[])
    elif plan.tag == PLAN_JOIN:
        return _plan_has_foldable_exprs(plan._join.value()[].left[]) or _plan_has_foldable_exprs(plan._join.value()[].right[])
    elif plan.tag == PLAN_SORT:
        return _plan_has_foldable_exprs(plan._sort.value()[].child[])
    elif plan.tag == PLAN_LIMIT:
        return _plan_has_foldable_exprs(plan._limit.value()[].child[])
    elif plan.tag == PLAN_DISTINCT:
        return _plan_has_foldable_exprs(plan._distinct.value()[].child[])
    elif plan.tag == PLAN_TOPN:
        return _plan_has_foldable_exprs(plan._topn.value()[].child[])
    return False


def _expr_has_simplifiable(expr: Expr) -> Bool:
    """Check if an expression tree contains a simplifiable pattern."""
    if expr.tag == EXPR_BINARY_OP:
        var op = expr.binary_op()
        if op == BIN_AND or op == BIN_OR:
            if expr.binary_left_ref().tag == EXPR_LITERAL or expr.binary_right_ref().tag == EXPR_LITERAL:
                return True
        return _expr_has_simplifiable(expr.binary_left_ref()) or _expr_has_simplifiable(expr.binary_right_ref())
    elif expr.tag == EXPR_UNARY_OP:
        if expr.unary_op() == UN_NOT and expr.unary_child_ref().tag == EXPR_UNARY_OP:
            if expr.unary_child_ref().unary_op() == UN_NOT:
                return True
        return _expr_has_simplifiable(expr.unary_child_ref())
    elif expr.tag == EXPR_CAST:
        return _expr_has_simplifiable(expr.cast_child_ref())
    elif expr.tag == EXPR_ALIAS:
        return _expr_has_simplifiable(expr.alias_child_ref())
    return False


def _plan_has_simplifiable_exprs(plan: LogicalPlan) -> Bool:
    """Check if any expression in the plan tree has simplifiable patterns."""
    if plan.tag == PLAN_FILTER:
        if _expr_has_simplifiable(plan._filter.value()[].predicate):
            return True
        return _plan_has_simplifiable_exprs(plan._filter.value()[].child[])
    elif plan.tag == PLAN_PROJECT:
        for i in range(len(plan._project.value()[].exprs)):
            if _expr_has_simplifiable(plan._project.value()[].exprs[i]):
                return True
        return _plan_has_simplifiable_exprs(plan._project.value()[].child[])
    elif plan.tag == PLAN_SCAN:
        if plan._scan.value()[].filter:
            return _expr_has_simplifiable(plan._scan.value()[].filter.value())
        return False
    elif plan.tag == PLAN_AGGREGATE:
        return _plan_has_simplifiable_exprs(plan._aggregate.value()[].child[])
    elif plan.tag == PLAN_JOIN:
        return _plan_has_simplifiable_exprs(plan._join.value()[].left[]) or _plan_has_simplifiable_exprs(plan._join.value()[].right[])
    elif plan.tag == PLAN_SORT:
        return _plan_has_simplifiable_exprs(plan._sort.value()[].child[])
    elif plan.tag == PLAN_LIMIT:
        return _plan_has_simplifiable_exprs(plan._limit.value()[].child[])
    elif plan.tag == PLAN_DISTINCT:
        return _plan_has_simplifiable_exprs(plan._distinct.value()[].child[])
    elif plan.tag == PLAN_TOPN:
        return _plan_has_simplifiable_exprs(plan._topn.value()[].child[])
    return False


# =============================================================================
# Debug mode: plan integrity validation
# =============================================================================

def _project_sibling_scope_ok(plan: LogicalPlan) -> Bool:
    """True unless a PLAN_PROJECT expression references a SIBLING OUTPUT of the
    same Project that the child does not provide.

    Split out of `validate_plan_integrity`'s PLAN_PROJECT arm so no interior
    reference into `plan._project` is held across the recursive call that
    follows it (two live `Optional.value()[]` borrows into one field is a
    compile error, not a runtime one).

    Returns True (no violation provable) when the child publishes ZERO columns:
    an empty schema means "not known here", which is indistinguishable from
    "provides nothing".
    """
    ref pd = plan._project.value()[]
    var child_ncols = pd.child[].output_schema.num_columns()
    if child_ncols == 0:
        return True
    var child_names = Set[String]()
    for i in range(child_ncols):
        child_names.add(pd.child[].output_schema.field_name(i))
    var own_names = Set[String]()
    for i in range(plan.output_schema.num_columns()):
        own_names.add(plan.output_schema.field_name(i))
    var referenced = Set[String]()
    for i in range(len(pd.exprs)):
        _collect_expr_columns(pd.exprs[i], referenced)
    for nm in referenced:
        var nm_s = String(nm)
        if nm_s in own_names and nm_s not in child_names:
            print(
                "INTEGRITY VIOLATION: PLAN_PROJECT expression references '"
                + nm_s
                + "', which is a SIBLING OUTPUT of this same Project and is"
                + " not a column of its child. A Project's expressions resolve"
                + " against the CHILD's schema; siblings are not in scope for"
                + " each other. The shared computation belongs in a Project"
                + " spliced BELOW this one"
            )
            return False
    return True


def validate_plan_integrity(plan: LogicalPlan) -> Bool:
    """Validate plan integrity in debug mode.

    Checks:
    - Every node has the correct variant data populated for its tag
    - Schema has at least 1 column (except possibly after aggressive pruning)
    - Children exist for non-leaf nodes
    - No tag == 255 (sentinel for consumed plans)
    - PLAN_PROJECT: `len(exprs) == output_schema.num_columns()` (arity)
    - PLAN_PROJECT: no expression references a SIBLING OUTPUT of the same
      Project that its child does not provide (scope)

    Returns True if valid, False if corrupt.

    TAG COVERAGE. Every tag is modeled; the fallthrough ("INTEGRITY VIOLATION:
    unknown tag") is reserved for a tag added later without an arm here (which
    is exactly the thing worth reporting). A partial model would report a
    violation on well-formed window / partition-top-n / asof / union / view /
    CSE / cast plans and hard-fail any caller that runs this gate.
    """
    if Int(plan.tag) == 255:
        print("INTEGRITY VIOLATION: plan has sentinel tag 255 (consumed plan)")
        return False

    if plan.tag == PLAN_SCAN:
        if not plan._scan:
            print("INTEGRITY VIOLATION: PLAN_SCAN but _scan is None")
            return False
        return True

    elif plan.tag == PLAN_FILTER:
        if not plan._filter:
            print("INTEGRITY VIOLATION: PLAN_FILTER but _filter is None")
            return False
        return validate_plan_integrity(plan._filter.value()[].child[])

    elif plan.tag == PLAN_PROJECT:
        if not plan._project:
            print("INTEGRITY VIOLATION: PLAN_PROJECT but _project is None")
            return False
        # PROJECT ARITY. `LogicalPlan.project`
        # derives exactly ONE schema field per expr, so every Project is BORN
        # with `len(exprs) == output_schema.num_columns()`. A rule that grows
        # `exprs` through a `ref` without rebuilding the node breaks it, and
        # `push_projections_down` then bounds a loop by `len(exprs)` while
        # subscripting `output_schema.field_name(i)` — an unguarded
        # `Schema.field_name` that `os.abort()`s the process. A gate that
        # checked only tag<->payload agreement would watch that crash go past.
        # This is the right altitude for the invariant: a
        # violation is reported by NAME here instead of killing the process
        # inside a later rule.
        var n_exprs = len(plan._project.value()[].exprs)
        var n_cols = plan.output_schema.num_columns()
        if n_exprs != n_cols:
            print(
                "INTEGRITY VIOLATION: PLAN_PROJECT has "
                + String(n_exprs)
                + " exprs but output_schema has "
                + String(n_cols)
                + " columns (a Project must carry exactly one expr per output"
                + " column; push_projections_down will index the schema out of"
                + " bounds)"
            )
            return False
        # PROJECT SIBLING SCOPE. A
        # Project's expressions are evaluated against its CHILD's schema, so a
        # SIBLING OUTPUT of the same Project is NOT in scope for any of them.
        # A CSE rewrite can break exactly this: dedup'ing a duplicated whole
        # output expression by rewriting the second occurrence to
        # `Alias(ColRef(<first output name>), <second output name>)` leaves
        # nothing to resolve that first name — the optimized schema comes
        # back `[m:FLOAT64, m2:<unknown>]` and materialize raises.
        #
        # WHY IT IS ASSERTED **HERE** AND NOT LEFT TO `plan_validator`: the
        # full column-resolution walk (`plan_validator._validate_project`)
        # would catch it, but its dev-gate wiring runs it on the plan
        # ENTERING `optimize_full` (`validate_plan_at_entry`) — i.e. on the
        # BOUND plan, before any pass has touched it. The
        # only check that runs on the plan LEAVING the optimizer is this
        # function, and it modeled tag<->payload agreement plus arity. A
        # corruption an optimizer PASS introduces is precisely the class
        # pre-pass validation cannot see, so the narrow form of the invariant
        # belongs at this altitude.
        #
        # ⚠ DELIBERATELY NARROW — it flags only a reference to one of THIS
        # node's OWN output names that the child does not provide. A name the
        # child does not provide and that is NOT a sibling output is somebody
        # else's bug (and the full walk's), and reporting it from here would
        # duplicate that check with less type information.
        #
        # ⚠ SKIPPED when the child publishes ZERO columns: an empty schema
        # means "not known at this point" (an unresolved reference leaf) and is
        # indistinguishable from "provides nothing", so a violation cannot be
        # proven.
        if not _project_sibling_scope_ok(plan):
            return False
        return validate_plan_integrity(plan._project.value()[].child[])

    elif plan.tag == PLAN_AGGREGATE:
        if not plan._aggregate:
            print("INTEGRITY VIOLATION: PLAN_AGGREGATE but _aggregate is None")
            return False
        return validate_plan_integrity(plan._aggregate.value()[].child[])

    elif plan.tag == PLAN_JOIN:
        if not plan._join:
            print("INTEGRITY VIOLATION: PLAN_JOIN but _join is None")
            return False
        var left_ok = validate_plan_integrity(plan._join.value()[].left[])
        var right_ok = validate_plan_integrity(plan._join.value()[].right[])
        return left_ok and right_ok

    elif plan.tag == PLAN_SORT:
        if not plan._sort:
            print("INTEGRITY VIOLATION: PLAN_SORT but _sort is None")
            return False
        return validate_plan_integrity(plan._sort.value()[].child[])

    elif plan.tag == PLAN_LIMIT:
        if not plan._limit:
            print("INTEGRITY VIOLATION: PLAN_LIMIT but _limit is None")
            return False
        return validate_plan_integrity(plan._limit.value()[].child[])

    elif plan.tag == PLAN_DISTINCT:
        if not plan._distinct:
            print("INTEGRITY VIOLATION: PLAN_DISTINCT but _distinct is None")
            return False
        return validate_plan_integrity(plan._distinct.value()[].child[])

    elif plan.tag == PLAN_TOPN:
        if not plan._topn:
            print("INTEGRITY VIOLATION: PLAN_TOPN but _topn is None")
            return False
        return validate_plan_integrity(plan._topn.value()[].child[])

    elif plan.tag == PLAN_PARTITION_BY:
        if not plan._partition_by:
            print(
                "INTEGRITY VIOLATION: PLAN_PARTITION_BY but _partition_by is"
                " None"
            )
            return False
        return validate_plan_integrity(plan._partition_by.value()[].child[])

    elif plan.tag == PLAN_PARTITION_TOPN:
        if not plan._partition_topn:
            print(
                "INTEGRITY VIOLATION: PLAN_PARTITION_TOPN but _partition_topn"
                " is None"
            )
            return False
        return validate_plan_integrity(plan._partition_topn.value()[].child[])

    elif plan.tag == PLAN_ASOF_JOIN:
        if not plan._asof_join:
            print("INTEGRITY VIOLATION: PLAN_ASOF_JOIN but _asof_join is None")
            return False
        var a_left_ok = validate_plan_integrity(
            plan._asof_join.value()[].left[]
        )
        var a_right_ok = validate_plan_integrity(
            plan._asof_join.value()[].right[]
        )
        return a_left_ok and a_right_ok

    elif plan.tag == PLAN_UNION:
        if not plan._union:
            print("INTEGRITY VIOLATION: PLAN_UNION but _union is None")
            return False
        var n_children = plan._union.value()[].num_children()
        if n_children == 0:
            print("INTEGRITY VIOLATION: PLAN_UNION with zero children")
            return False
        for i in range(n_children):
            if not validate_plan_integrity(
                plan._union.value()[].children[i][]
            ):
                return False
        return True

    elif plan.tag == PLAN_VIEW_REF:
        # LEAF (opaque until `view_resolution_pass` splices the registered
        # view's subtree in place of this node). Nothing to recurse into.
        if not plan._view_ref:
            print("INTEGRITY VIOLATION: PLAN_VIEW_REF but _view_ref is None")
            return False
        return True

    elif plan.tag == PLAN_CSE_REF:
        # LEAF (a structural-hash reference to the canonical occurrence).
        if not plan._cse_ref:
            print("INTEGRITY VIOLATION: PLAN_CSE_REF but _cse_ref is None")
            return False
        return True

    elif plan.tag == PLAN_CAST_TO_VARCHAR:
        if not plan._cast_to_varchar:
            print(
                "INTEGRITY VIOLATION: PLAN_CAST_TO_VARCHAR but"
                " _cast_to_varchar is None"
            )
            return False
        return validate_plan_integrity(
            plan._cast_to_varchar.value()[].child[]
        )

    print("INTEGRITY VIOLATION: unknown tag", Int(plan.tag))
    return False


# =============================================================================
# Plan explain / analyze output
# =============================================================================

def explain_plan(plan: LogicalPlan) -> String:
    """Return a human-readable explanation of the plan tree.

    Format:
        Filter [schema: (a: Int64, b: Float64)]
          predicate: BinaryOp(GT, ColRef(a), Literal(10))
          Scan [schema: (a: Int64, b: Float64)] path=data.parquet
    """
    var result = String("")
    _explain_node(plan, 0, result)
    return result^


def _explain_node(plan: LogicalPlan, indent: Int, mut out: String):
    """Recursively build explain output."""
    var prefix = String("")
    for _ in range(indent):
        prefix += "  "

    if plan.tag == PLAN_SCAN:
        out += prefix + plan_tag_name(plan.tag)
        if plan._scan.value()[].projection:
            out += " [proj: " + String(len(plan._scan.value()[].projection.value())) + " cols]"
        if plan._scan.value()[].filter:
            out += " [filter: yes]"
        out += " path=" + plan._scan.value()[].source_path + "\n"

    elif plan.tag == PLAN_FILTER:
        out += prefix + plan_tag_name(plan.tag) + " [schema: " + String(plan.output_schema.num_columns()) + " cols]\n"
        out += prefix + "  predicate: " + String(plan._filter.value()[].predicate) + "\n"
        _explain_node(plan._filter.value()[].child[], indent + 1, out)

    elif plan.tag == PLAN_PROJECT:
        out += prefix + plan_tag_name(plan.tag) + " [" + String(len(plan._project.value()[].exprs)) + " exprs]\n"
        _explain_node(plan._project.value()[].child[], indent + 1, out)

    elif plan.tag == PLAN_AGGREGATE:
        out += prefix + plan_tag_name(plan.tag) + " [" + String(len(plan._aggregate.value()[].group_by)) + " keys, "
        out += String(len(plan._aggregate.value()[].agg_exprs)) + " aggs]\n"
        _explain_node(plan._aggregate.value()[].child[], indent + 1, out)

    elif plan.tag == PLAN_JOIN:
        out += prefix + plan_tag_name(plan.tag) + " [type=" + String(Int(plan._join.value()[].join_type)) + "]\n"
        _explain_node(plan._join.value()[].left[], indent + 1, out)
        _explain_node(plan._join.value()[].right[], indent + 1, out)

    elif plan.tag == PLAN_SORT:
        out += prefix + plan_tag_name(plan.tag) + " [" + String(len(plan._sort.value()[].keys)) + " keys]\n"
        _explain_node(plan._sort.value()[].child[], indent + 1, out)

    elif plan.tag == PLAN_LIMIT:
        out += prefix + plan_tag_name(plan.tag) + " [n=" + String(plan._limit.value()[].n) + "]\n"
        _explain_node(plan._limit.value()[].child[], indent + 1, out)

    elif plan.tag == PLAN_DISTINCT:
        out += prefix + plan_tag_name(plan.tag) + "\n"
        _explain_node(plan._distinct.value()[].child[], indent + 1, out)

    elif plan.tag == PLAN_TOPN:
        out += prefix + plan_tag_name(plan.tag) + " [n=" + String(plan._topn.value()[].n) + "]\n"
        _explain_node(plan._topn.value()[].child[], indent + 1, out)

    else:
        out += prefix + "Unknown(tag=" + String(Int(plan.tag)) + ")\n"


def analyze_plan(plan: LogicalPlan) -> String:
    """Return an analysis of the plan tree including node count and depth."""
    var node_count = _count_nodes(plan)
    var depth = _plan_depth(plan)
    var result = "Plan Analysis:\n"
    result += "  Nodes: " + String(node_count) + "\n"
    result += "  Depth: " + String(depth) + "\n"
    result += "  Schema columns: " + String(plan.output_schema.num_columns()) + "\n"
    result += "\nPlan:\n"
    result += explain_plan(plan)
    return result^


def _count_nodes(plan: LogicalPlan) -> Int:
    """Count total nodes in the plan tree."""
    if plan.tag == PLAN_SCAN:
        return 1
    elif plan.tag == PLAN_FILTER:
        return 1 + _count_nodes(plan._filter.value()[].child[])
    elif plan.tag == PLAN_PROJECT:
        return 1 + _count_nodes(plan._project.value()[].child[])
    elif plan.tag == PLAN_AGGREGATE:
        return 1 + _count_nodes(plan._aggregate.value()[].child[])
    elif plan.tag == PLAN_JOIN:
        return 1 + _count_nodes(plan._join.value()[].left[]) + _count_nodes(plan._join.value()[].right[])
    elif plan.tag == PLAN_SORT:
        return 1 + _count_nodes(plan._sort.value()[].child[])
    elif plan.tag == PLAN_LIMIT:
        return 1 + _count_nodes(plan._limit.value()[].child[])
    elif plan.tag == PLAN_DISTINCT:
        return 1 + _count_nodes(plan._distinct.value()[].child[])
    elif plan.tag == PLAN_TOPN:
        return 1 + _count_nodes(plan._topn.value()[].child[])
    return 1


def _plan_depth(plan: LogicalPlan) -> Int:
    """Compute the depth of the plan tree."""
    if plan.tag == PLAN_SCAN:
        return 1
    elif plan.tag == PLAN_FILTER:
        return 1 + _plan_depth(plan._filter.value()[].child[])
    elif plan.tag == PLAN_PROJECT:
        return 1 + _plan_depth(plan._project.value()[].child[])
    elif plan.tag == PLAN_AGGREGATE:
        return 1 + _plan_depth(plan._aggregate.value()[].child[])
    elif plan.tag == PLAN_JOIN:
        var ld = _plan_depth(plan._join.value()[].left[])
        var rd = _plan_depth(plan._join.value()[].right[])
        if ld > rd:
            return 1 + ld
        return 1 + rd
    elif plan.tag == PLAN_SORT:
        return 1 + _plan_depth(plan._sort.value()[].child[])
    elif plan.tag == PLAN_LIMIT:
        return 1 + _plan_depth(plan._limit.value()[].child[])
    elif plan.tag == PLAN_DISTINCT:
        return 1 + _plan_depth(plan._distinct.value()[].child[])
    elif plan.tag == PLAN_TOPN:
        return 1 + _plan_depth(plan._topn.value()[].child[])
    return 1
