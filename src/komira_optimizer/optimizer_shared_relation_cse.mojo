# =============================================================================
# optimizer_shared_relation_cse.mojo -- materialize a shared BASE RELATION ONCE
# below the two aggregates a decorrelated scalar subquery produces, and share it
# across both consumers (a walker-safe, tree-preserving CSE). The q11 lever.
#
# WHY THIS EXISTS (TPC-H q11 "Important Stock"; the double-executed shared join)
# ============================================================================
# q11 is `partsupp x supplier x nation[GERMANY] GROUP BY ps_partkey HAVING
# sum(value) > (SELECT sum(value)*fraction FROM the SAME germany join)`.
# `scalar_subquery_decorrelate` turns the uncorrelated scalar
# threshold into a broadcast `JOIN_CROSS`, so after that pass the plan is:
#
#   Filter(part_value > __scalar_subq_0)
#     Join(CROSS)
#       Aggregate(group_by=[ps_partkey], SUM(value) AS part_value)   <- LEFT
#         <GERMANY JOIN>                                              (needs pk)
#       Project(__scalar_subq_0 = __scalar_total * fraction)         <- RIGHT
#         Aggregate(group_by=[], SUM(value) AS __scalar_total)
#           <GERMANY JOIN>                                           (needs value)
#
# BOTH branches carry the identical `partsupp x supplier x nation[GERMANY]`
# join, so executing the plan as written runs the base join TWICE. DuckDB
# computes it once (the HAVING scalar is one aggregate over the same relation).
# Subtree-level plan-CSE (`plan_cse_eliminate`, not in this tree) would fold
# them, but its `PLAN_CSE_REF` output is a DAG edge, and this rewrite keeps the
# plan a tree; and column pruning (a pass not in this tree) does not keep the
# two germany-join subtrees structurally identical: it prunes them
# DIFFERENTIALLY (the LEFT reads ps_partkey, the RIGHT does not) -> different
# `structural_hash` -> nothing folds them.
#
# THE FIX (the walker-safe "materialize once, share the OUTPUT batch"
# pattern; `optimizer_agg_cse` applies it to q15's aggregate)
# ============================================================================
# Recognize the two germany-join relations as THE SAME relation modulo scan
# projection (a projection-insensitive fingerprint), materialize the WIDER of
# the two (whose output columns are a superset) EXACTLY ONCE to a `RecordBatch`,
# and replace BOTH aggregate children with an `InMemorySource` scan leaf that
# shares that batch by ArcPointer refcount. This module does the two pure
# halves (`detect_shared_cross_canonical`, `install_shared_cross_source`);
# materializing the batch between them is the caller's, outside
# komira_optimizer. The IR stays a TREE (walker-safe --
# an in-memory scan is a leaf the walker already resolves) and each consumer
# reads its OWN copy of the shared batch, so the single-consumer invariant is
# preserved and the compared values are byte-identical. The germany join is
# then built once, by that caller.
#
# BYTE-SAFETY: an aggregate's output schema depends ONLY on its group_by + agg
# exprs (resolved by column NAME against its child), never on which EXTRA
# columns the child carries. So replacing the (narrower) RIGHT relation with the
# wider shared batch -- which has a superset of columns -- leaves every
# aggregate output byte-identical; the extra `ps_partkey` column the RIGHT
# ungrouped SUM never references is simply ignored. The projection-insensitive
# match requires one relation's output columns to be a proper SUPERSET of the
# other's (else the fold DECLINES -- conservative, never a wrong answer).
#
# The recurse-and-rebuild walks below cover the single-child kinds and joins;
# node kinds not walked simply do not fold.
# =============================================================================

from std.collections import Dict, List, Optional
from std.memory import OwnedPointer

from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    SourceVariant,
    JOIN_CROSS,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    PLAN_ASOF_JOIN,
    PLAN_UNION,
)
from komira_plan_expr.expr import Expr, EXPR_COL_REF
from komira_arrow.schema import Schema
from komira_scan_source.in_memory_source import InMemorySource

from komira_plan_ir.plan_helpers import _copy_plan, _copy_schema


# -----------------------------------------------------------------------------
# small local expr/agg array copies (ExprArray/AggExprArray == Slab[Expr]/[AggExpr])
# -----------------------------------------------------------------------------
def _copy_exprs(arr: ExprArray) -> ExprArray:
    var out = ExprArray()
    for i in range(len(arr)):
        out.append(arr[i].copy())
    return out^


def _copy_aggs(arr: AggExprArray) -> AggExprArray:
    var out = AggExprArray()
    for i in range(len(arr)):
        out.append(arr[i].copy())
    return out^


# -----------------------------------------------------------------------------
# Projection-insensitive relation fingerprint.
#
# `_relation_fingerprint(rel)` is an FNV-1a hash over the relation's STRUCTURE
# that IGNORES column projection at BOTH the scan level (a scan's projected
# column list is never hashed — only its `source.structural_id()`, the same
# content/path identity `structural_hash` keys scans on) AND the Project level
# (a PURE-SELECT project of bare col-refs is skipped; a computation-bearing
# project's non-col-ref exprs ARE hashed). It DOES hash filters, join
# type/keys/residual, and aggregate group_by/aggs. So two relations that differ
# ONLY in which columns they project (the q11 differential-prune shape)
# fingerprint EQUAL, while relations differing in a filter, a join, a source, or
# a computed column fingerprint DIFFERENT -- a fold can never merge two relations
# that would produce different ROWS.
#
# ⛔ THE FINGERPRINT IS THE WHOLE DECISION. There is no second equality check
# after it, and `install_shared_cross_source` swaps EVERY aggregate child that
# matches, so each field that changes the ROWS must be folded and every string
# must be folded with its LENGTH (`_fnv_str`), or two key lists whose bytes
# concatenate alike (`ab`=`c` vs `a`=`bc`) collide. Row-changing fields:
# TopN n/keys/directions/null placement, Sort keys/directions/null placement
# (they decide which rows a Limit above keeps), Limit n AND offset. DISTINCT
# is the one node whose rows depend on the PROJECTION below it (distinct
# `(pk, v)` rows are not distinct `(v)` rows), so it folds the projection-
# SENSITIVE `structural_hash` of its whole subtree and never folds across a
# differential prune. Falsifier: `test_shared_relation_fingerprint_identity`.
# -----------------------------------------------------------------------------
comptime _FNV_OFFSET: UInt64 = 0xcbf29ce484222325
comptime _FNV_PRIME: UInt64 = 0x100000001b3


@always_inline
def _fnv_u64(h: UInt64, v: UInt64) -> UInt64:
    return (h ^ v) * _FNV_PRIME


def _fnv_str(h: UInt64, s: String) -> UInt64:
    """Fold `s` LENGTH-FIRST, so consecutive strings keep their boundaries."""
    var bytes = s.as_bytes()
    var acc = _fnv_u64(h, UInt64(len(bytes)))
    for i in range(len(bytes)):
        acc = (acc ^ UInt64(bytes[i])) * _FNV_PRIME
    return acc


def _fold_order(
    h: UInt64, keys: List[String], descending: List[Bool], nulls_first: List[Bool]
) -> UInt64:
    """Fold a sort specification: each list with its length, each key with its
    direction and NULL placement."""
    var acc = _fnv_u64(h, UInt64(len(keys)))
    for i in range(len(keys)):
        acc = _fnv_str(acc, keys[i])
    acc = _fnv_u64(acc, UInt64(len(descending)))
    for i in range(len(descending)):
        acc = _fnv_u64(acc, UInt64(1) if descending[i] else UInt64(0))
    acc = _fnv_u64(acc, UInt64(len(nulls_first)))
    for i in range(len(nulls_first)):
        acc = _fnv_u64(acc, UInt64(1) if nulls_first[i] else UInt64(0))
    return acc


def _fp_accumulate(plan: LogicalPlan, h: UInt64) raises -> UInt64:
    var acc = _fnv_u64(h, UInt64(Int(plan.tag)))
    if plan.tag == PLAN_SCAN:
        ref sd = plan._scan.value()[]
        # `structural_id()` (NOT the per-ctor-unique `fingerprint()`): the
        # CONTENT/path identity `structural_hash` itself uses, so two scans of
        # the same source hash equal regardless of projection.
        acc = _fnv_u64(acc, sd.source.structural_id())
        if sd.filter:
            acc = _fnv_str(acc, String(sd.filter.value()))
        return acc
    elif plan.tag == PLAN_FILTER:
        acc = _fnv_str(acc, String(plan._filter.value()[].predicate))
        return _fp_accumulate(plan._filter.value()[].child[], acc)
    elif plan.tag == PLAN_PROJECT:
        ref pj = plan._project.value()[]
        # Skip a PURE SELECT (all bare col-refs -> projection only); a
        # computed expr IS hashed (a derived column changes the rows).
        for i in range(len(pj.exprs)):
            if pj.exprs[i].tag != EXPR_COL_REF:
                acc = _fnv_str(acc, String(pj.exprs[i]))
        return _fp_accumulate(pj.child[], acc)
    elif plan.tag == PLAN_JOIN:
        ref jd = plan._join.value()[]
        acc = _fnv_u64(acc, UInt64(Int(jd.join_type)))
        acc = _fnv_u64(acc, UInt64(len(jd.left_on)))
        for i in range(len(jd.left_on)):
            acc = _fnv_str(acc, jd.left_on[i])
        for i in range(len(jd.right_on)):
            acc = _fnv_str(acc, jd.right_on[i])
        if jd.has_residual():
            acc = _fnv_str(acc, String(jd.residual.value()[]))
        acc = _fp_accumulate(jd.left[], acc)
        return _fp_accumulate(jd.right[], acc)
    elif plan.tag == PLAN_AGGREGATE:
        ref ad = plan._aggregate.value()[]
        acc = _fnv_u64(acc, UInt64(len(ad.group_by)))
        for i in range(len(ad.group_by)):
            acc = _fnv_str(acc, String(ad.group_by[i]))
        for i in range(len(ad.agg_exprs)):
            acc = _fnv_str(acc, String(ad.agg_exprs[i]))
        return _fp_accumulate(ad.child[], acc)
    elif plan.tag == PLAN_SORT:
        ref srt = plan._sort.value()[]
        acc = _fold_order(acc, srt.keys, srt.descending, srt.nulls_first)
        return _fp_accumulate(srt.child[], acc)
    elif plan.tag == PLAN_DISTINCT:
        # Projection-SENSITIVE on purpose (see the block above): the columns
        # under a DISTINCT decide its rows.
        return _fnv_u64(acc, plan.structural_hash())
    elif plan.tag == PLAN_LIMIT:
        acc = _fnv_u64(acc, UInt64(plan._limit.value()[].n))
        acc = _fnv_u64(acc, UInt64(plan._limit.value()[].offset))
        return _fp_accumulate(plan._limit.value()[].child[], acc)
    elif plan.tag == PLAN_TOPN:
        ref tn = plan._topn.value()[]
        acc = _fnv_u64(acc, UInt64(tn.n))
        acc = _fold_order(acc, tn.keys, tn.descending, tn.nulls_first)
        return _fp_accumulate(tn.child[], acc)
    # Un-handled kinds: fold in the projection-SENSITIVE structural_hash (a
    # consistent, conservative fallback -- may miss a fold, never a wrong fold).
    return _fnv_u64(acc, plan.structural_hash())


def _relation_fingerprint(plan: LogicalPlan) raises -> UInt64:
    return _fp_accumulate(plan, _FNV_OFFSET)


# -----------------------------------------------------------------------------
# Schema column-name superset test.
# -----------------------------------------------------------------------------
def _colnames_superset(a: Schema, b: Schema) -> Bool:
    """True iff every column name in `b` is present in `a` (a's names are a
    superset of b's)."""
    for j in range(b.num_columns()):
        var bn = b.field_name(j)
        var found = False
        for i in range(a.num_columns()):
            if a.field_name(i) == bn:
                found = True
                break
        if not found:
            return False
    return True


# -----------------------------------------------------------------------------
# Extract the base RELATION under a CROSS-branch's aggregate. Descends through
# single-child wrappers (Project / Filter / Sort / Limit /
# Distinct / TopN) to the FIRST aggregate and returns a COPY of that aggregate's
# child (the relation the aggregate reduces).
# -----------------------------------------------------------------------------
def _extract_agg_relation(plan: LogicalPlan) raises -> Optional[LogicalPlan]:
    if plan.tag == PLAN_AGGREGATE:
        return Optional[LogicalPlan](_copy_plan(plan._aggregate.value()[].child[]))
    elif plan.tag == PLAN_PROJECT:
        return _extract_agg_relation(plan._project.value()[].child[])
    elif plan.tag == PLAN_FILTER:
        return _extract_agg_relation(plan._filter.value()[].child[])
    elif plan.tag == PLAN_SORT:
        return _extract_agg_relation(plan._sort.value()[].child[])
    elif plan.tag == PLAN_LIMIT:
        return _extract_agg_relation(plan._limit.value()[].child[])
    elif plan.tag == PLAN_DISTINCT:
        return _extract_agg_relation(plan._distinct.value()[].child[])
    elif plan.tag == PLAN_TOPN:
        return _extract_agg_relation(plan._topn.value()[].child[])
    return None


# -----------------------------------------------------------------------------
# Phase 1 -- detect: find the FIRST JOIN_CROSS (the shape a decorrelated scalar
# subquery produces) whose two branches
# reduce THE SAME relation (projection-insensitive) with one branch's columns a
# superset of the other's. Returns a COPY of the WIDER relation (the one to
# materialize once) or None.
# -----------------------------------------------------------------------------
def detect_shared_cross_canonical(
    plan: LogicalPlan,
) raises -> Optional[LogicalPlan]:
    if plan.tag == PLAN_JOIN and plan._join.value()[].join_type == JOIN_CROSS:
        var l_rel = _extract_agg_relation(plan._join.value()[].left[])
        var r_rel = _extract_agg_relation(plan._join.value()[].right[])
        if l_rel:
            if r_rel:
                if _relation_fingerprint(
                    l_rel.value()
                ) == _relation_fingerprint(r_rel.value()):
                    # Materialize whichever relation's columns are a SUPERSET;
                    # only then does the wider batch satisfy BOTH aggregates'
                    # column needs. If neither side is a clean superset, DECLINE.
                    if _colnames_superset(
                        l_rel.value().output_schema, r_rel.value().output_schema
                    ):
                        return Optional[LogicalPlan](_copy_plan(l_rel.value()))
                    if _colnames_superset(
                        r_rel.value().output_schema, l_rel.value().output_schema
                    ):
                        return Optional[LogicalPlan](_copy_plan(r_rel.value()))
    # Recurse (a nested CROSS, or the CROSS below a root Project/Filter/Sort).
    return _detect_children(plan)


def _detect_children(plan: LogicalPlan) raises -> Optional[LogicalPlan]:
    if plan.tag == PLAN_FILTER:
        return detect_shared_cross_canonical(plan._filter.value()[].child[])
    elif plan.tag == PLAN_PROJECT:
        return detect_shared_cross_canonical(plan._project.value()[].child[])
    elif plan.tag == PLAN_AGGREGATE:
        return detect_shared_cross_canonical(plan._aggregate.value()[].child[])
    elif plan.tag == PLAN_JOIN:
        var l = detect_shared_cross_canonical(plan._join.value()[].left[])
        if l:
            return l^
        return detect_shared_cross_canonical(plan._join.value()[].right[])
    elif plan.tag == PLAN_SORT:
        return detect_shared_cross_canonical(plan._sort.value()[].child[])
    elif plan.tag == PLAN_LIMIT:
        return detect_shared_cross_canonical(plan._limit.value()[].child[])
    elif plan.tag == PLAN_DISTINCT:
        return detect_shared_cross_canonical(plan._distinct.value()[].child[])
    elif plan.tag == PLAN_TOPN:
        return detect_shared_cross_canonical(plan._topn.value()[].child[])
    elif plan.tag == PLAN_ASOF_JOIN:
        var la = detect_shared_cross_canonical(plan._asof_join.value()[].left[])
        if la:
            return la^
        return detect_shared_cross_canonical(plan._asof_join.value()[].right[])
    elif plan.tag == PLAN_UNION:
        ref ud = plan._union.value()[]
        for i in range(len(ud.children)):
            var uc = detect_shared_cross_canonical(ud.children[i][])
            if uc:
                return uc^
    return None


# -----------------------------------------------------------------------------
# Phase 2 -- install: every AGGREGATE whose child relation fingerprints == target
# gets its child replaced by a shared `InMemorySource` scan leaf (schema =
# `batch_schema`, the materialized wider-relation schema). Refcount-bump per
# occurrence (each `source.copy()` shares the same batch bytes).
# -----------------------------------------------------------------------------
def install_shared_cross_source(
    var plan: LogicalPlan,
    target: UInt64,
    source: InMemorySource,
    batch_schema: Schema,
) raises -> LogicalPlan:
    if plan.tag == PLAN_AGGREGATE:
        ref ad = plan._aggregate.value()[]
        var group_by = _copy_exprs(ad.group_by)
        var agg_exprs = _copy_aggs(ad.agg_exprs)
        if _relation_fingerprint(ad.child[]) == target:
            var leaf = LogicalPlan.scan_from_source(
                SourceVariant(source.copy()), _copy_schema(batch_schema)
            )
            return LogicalPlan.aggregate(group_by^, agg_exprs^, leaf^)
        var child = install_shared_cross_source(
            _copy_plan(ad.child[]), target, source, batch_schema
        )
        return LogicalPlan.aggregate(group_by^, agg_exprs^, child^)
    elif plan.tag == PLAN_FILTER:
        var child = install_shared_cross_source(
            _copy_plan(plan._filter.value()[].child[]),
            target,
            source,
            batch_schema,
        )
        var pred = plan._filter.value()[].predicate.copy()
        return LogicalPlan.filter(pred^, child^)
    elif plan.tag == PLAN_PROJECT:
        var child = install_shared_cross_source(
            _copy_plan(plan._project.value()[].child[]),
            target,
            source,
            batch_schema,
        )
        var exprs = _copy_exprs(plan._project.value()[].exprs)
        return LogicalPlan.project(exprs^, child^)
    elif plan.tag == PLAN_JOIN:
        var left = install_shared_cross_source(
            _copy_plan(plan._join.value()[].left[]), target, source, batch_schema
        )
        var right = install_shared_cross_source(
            _copy_plan(plan._join.value()[].right[]),
            target,
            source,
            batch_schema,
        )
        var left_on = plan._join.value()[].left_on.copy()
        var right_on = plan._join.value()[].right_on.copy()
        var sd_algo = plan._join.value()[].algo_hint
        var sd_resid: Optional[OwnedPointer[Expr]] = None
        if plan._join.value()[].has_residual():
            sd_resid = OwnedPointer(plan._join.value()[].residual.value()[].copy())
        return LogicalPlan.join(
            left^,
            right^,
            left_on^,
            right_on^,
            plan._join.value()[].join_type,
            sd_algo,
            sd_resid^,
        )
    elif plan.tag == PLAN_SORT:
        var child = install_shared_cross_source(
            _copy_plan(plan._sort.value()[].child[]), target, source, batch_schema
        )
        var keys = plan._sort.value()[].keys.copy()
        var desc = plan._sort.value()[].descending.copy()
        # carry the EXPLICIT NULL
        # placement; omitting it silently re-derives the DEFAULT
        # (`null_order_policy.derived_nulls_first`).
        var nf_copy = Optional(plan._sort.value()[].nulls_first.copy())
        return LogicalPlan.sort(keys^, desc^, child^, nf_copy^)
    elif plan.tag == PLAN_LIMIT:
        var child = install_shared_cross_source(
            _copy_plan(plan._limit.value()[].child[]),
            target,
            source,
            batch_schema,
        )
        ref ld = plan._limit.value()[]
        return LogicalPlan.limit(ld.n, child^, offset=ld.offset)
    elif plan.tag == PLAN_DISTINCT:
        var child = install_shared_cross_source(
            _copy_plan(plan._distinct.value()[].child[]),
            target,
            source,
            batch_schema,
        )
        var cols_opt: Optional[List[String]] = None
        if plan._distinct.value()[].columns:
            cols_opt = plan._distinct.value()[].columns.value().copy()
        return LogicalPlan.distinct(cols_opt^, child^)
    elif plan.tag == PLAN_TOPN:
        var child = install_shared_cross_source(
            _copy_plan(plan._topn.value()[].child[]),
            target,
            source,
            batch_schema,
        )
        var keys = plan._topn.value()[].keys.copy()
        var desc = plan._topn.value()[].descending.copy()
        # carry the EXPLICIT NULL
        # placement; omitting it silently re-derives the DEFAULT
        # (`null_order_policy.derived_nulls_first`).
        var nf_copy = Optional(plan._topn.value()[].nulls_first.copy())
        return LogicalPlan.topn(
            keys^, desc^, plan._topn.value()[].n, child^, nf_copy^
        )

    # Un-walked kinds (scan, partition-by / partition-topn, asof join, union,
    # view / cse refs, cast): no fold.
    return plan^
