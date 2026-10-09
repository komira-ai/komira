# =============================================================================
# optimizer_payload_narrow — INTEGRAL PAYLOAD NARROWING for equi-joins
# =============================================================================
#
# DuckDB analogue: `src/optimizer/compressed_materialization/
# compress_comparison_join.cpp`, the join arm of `compressed_materialization`.
# Measured INSIDE DuckDB on the hc4 cell with a single variable
# (`SET disabled_optimizers='compressed_materialization'`): 0.978 s on vs
# 1.038 s off — 5.7% of their own wall.
#
# WHAT IT DOES. For an INNER equi-join whose sides bottom out in Parquet scans,
# every NON-KEY integer column the join has to carry is examined against the
# folded `[min, max]` on `ScanData.table_stats`. When the span fits in fewer
# bytes than the column's declared width, a `PayloadNarrowSpec` naming the
# column, the narrowest sufficient unsigned width, and the frame-of-reference
# `base` is stamped on that side's SCAN. Nothing is rewritten: no node is added,
# removed, or re-typed, and the plan's output schema is untouched.
#
# ⛔ WHY IT STAMPS DATA RATHER THAN INSERTING PROJECTIONS. See the header of
# `komira_plan_expr/payload_narrow.mojo`. In one line: a compress `Project`
# below the join and a decompress `Project` above it EACH take the join off the
# fused parquet-on-parquet leaf — the first because the leaf's side resolver
# requires a PURE COL-REF project, the second because the leaf declines an
# OFF-ROOT join — so DuckDB's spelling would disable the route it is supposed
# to accelerate. The leaf performs both halves internally instead.
#
# ⛔ PAYLOAD ONLY. THE JOIN KEY IS NEVER NARROWED. `join_node_exec` declines
# the direct/fused leaf for a non-INT64 key (at three separate checks), and
# the fallback it declines to reached 130 GB anon-RSS / rc=137 on a 1M x 250K
# join with a dense INT32 key (reproduced twice, once under an 8 GiB cap).
# Key narrowing is a
# separate, BLOCKED piece of work. The key columns are excluded here by name,
# on both sides, and that exclusion is the rule's most important line.
#
# ⚠ AND THE RULE IS THE CHEAP HALF. The measured ladder that motivates it was
# taken by CASTING THE FIXTURE, i.e. by handing the engine data that was
# already narrow on disk; this rule hands the engine a WIDE file and narrows it
# internally, so it delivers the gather-side and output-side terms and NOT a
# cheaper scan. On hc4 that over-credit is bounded and small — the two fixtures
# differ by 0.003% on disk — but on a cell whose key is dense the same 8->4
# cast shrinks the parquet 22%, and most of the apparent win there is a smaller
# file. Check the file-size delta before quoting this rule's number anywhere
# but hc4.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_JOIN,
    PLAN_AGGREGATE,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_TOPN,
    PLAN_DISTINCT,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_ASOF_JOIN,
    JOIN_INNER,
    SOURCE_PARQUET,
)
from komira_plan_expr.payload_narrow import (
    PayloadNarrowSpec,
    choose_narrow_width,
    PAYLOAD_NARROW_NONE,
)
from komira_plan_stats.table_stats import ColumnStats


# =============================================================================
# §1 — the per-column decision
# =============================================================================


def _column_narrow_width(
    imm stats_min: Int64, imm stats_max: Int64
) -> UInt8:
    """Thin wrapper so the ladder has exactly one implementation."""
    return choose_narrow_width(stats_min, stats_max)


def _is_narrowable_declared_type(t: ArrowType) -> Bool:
    """Only a DECLARED 8-byte signed integer is narrowed.

    ⚠ INT64 ONLY, AND THAT IS NOT CONSERVATISM FOR ITS OWN SAKE. The widen half
    reconstructs `Int64(stored) + base`, so the column's declared type has to be
    the one that reconstruction produces. Admitting INT32 here would mean two
    reconstruction types and two sets of kernel arms for a column that is
    already half the width — all of the risk for a quarter of the prize.
    """
    return t == ArrowType.INT64


# =============================================================================
# §2 — resolving a join side to its SCAN
# =============================================================================
#
# ⚠ THIS MIRRORS `join_node_exec._resolve_join_scan_side` AND MUST STAY A
# SUBSET OF IT. Stamping a scan the leaf will not recognise is harmless (the
# spec is advisory and nothing reads it) but it is dead weight and it makes the
# EXPLAIN lie about what will happen. The shapes admitted here —
# `PLAN_PROJECT? -> PLAN_FILTER* -> PLAN_SCAN(parquet)` — are exactly the ones
# that resolver accepts.


def _peel_to_parquet_scan(mut node: LogicalPlan) -> Bool:
    """True iff `node` is a shape whose bottom is a Parquet SCAN. Does not
    mutate; the `mut` is only so the caller can hand us the same reference it
    will later stamp through."""
    if node.tag == PLAN_SCAN:
        if not node._scan:
            return False
        return node._scan.value()[].source_type == SOURCE_PARQUET
    if node.tag == PLAN_FILTER and node._filter:
        return _peel_to_parquet_scan(node._filter.value()[].child[])
    if node.tag == PLAN_PROJECT and node._project:
        # A COMPUTED project is not peeled: the leaf declines it, and a column
        # this rule narrowed would be read by an expression evaluator that
        # knows nothing about `base`.
        ref pd = node._project.value()[]
        if pd.udf:
            return False
        for i in range(len(pd.exprs)):
            ref e = pd.exprs[i]
            var pure = e.is_col_ref()
            if (not pure) and e.is_alias():
                pure = e.alias_child_ref().is_col_ref()
            if not pure:
                return False
        return _peel_to_parquet_scan(pd.child[])
    return False


def _stamp_scan_specs(
    mut node: LogicalPlan, var specs: List[PayloadNarrowSpec]
) -> Bool:
    """Walk down to the bottom Parquet SCAN and install `specs` on it.

    Returns True when a scan was reached and stamped. The walk mirrors
    `_peel_to_parquet_scan` exactly — they are called as a pair and a
    divergence between them is a silent no-op, never a wrong answer.
    """
    if node.tag == PLAN_SCAN:
        if not node._scan:
            return False
        if node._scan.value()[].source_type != SOURCE_PARQUET:
            return False
        node._scan.value()[].payload_narrow = specs^
        return True
    if node.tag == PLAN_FILTER and node._filter:
        return _stamp_scan_specs(node._filter.value()[].child[], specs^)
    if node.tag == PLAN_PROJECT and node._project:
        return _stamp_scan_specs(node._project.value()[].child[], specs^)
    return False


def _scan_stats_min_max(
    imm node: LogicalPlan, imm col: String
) -> Optional[List[Int64]]:
    """The folded `[min, max]` for `col`, read off the bottom SCAN's
    `table_stats`. None when the scan, the stats, the column entry, or either
    endpoint is absent, or when either endpoint is not an integer.

    ⚠ A FILTER BETWEEN THE JOIN AND THE SCAN IS SAFE AND IS DELIBERATELY NOT
    CONSULTED. Footer `[min, max]` is a SUPERSET of the post-filter domain, so
    a pushed predicate can only make the true range narrower than the one the
    width ladder was proved against. A superset is the safe direction: the
    chosen width still holds every surviving value. (It is also why this rule
    does not need selectivity: it needs a BOUND, not an estimate.)
    """
    if node.tag == PLAN_SCAN:
        if not node._scan:
            return None
        ref sd = node._scan.value()[]
        if not sd.table_stats:
            return None
        ref ts = sd.table_stats.value()
        var idx = ts.find_column(col)
        if idx < 0:
            return None
        ref cs = ts.column_stats[idx]
        if not cs.min_value or not cs.max_value:
            return None
        ref mn = cs.min_value.value()
        ref mx = cs.max_value.value()
        if not mn.is_int() or not mx.is_int():
            return None
        var out = List[Int64]()
        out.append(mn.int_val)
        out.append(mx.int_val)
        return Optional[List[Int64]](out^)
    if node.tag == PLAN_FILTER and node._filter:
        return _scan_stats_min_max(node._filter.value()[].child[], col)
    if node.tag == PLAN_PROJECT and node._project:
        return _scan_stats_min_max(node._project.value()[].child[], col)
    return None


# =============================================================================
# §3 — the per-side pass
# =============================================================================


def _narrow_one_side(
    mut side: LogicalPlan, imm key_names: List[String]
) raises -> Int:
    """Decide + stamp one join side. Returns the number of columns narrowed.

    `key_names` are THIS side's equi-key column names. Every one of them is
    excluded — see the PAYLOAD ONLY block at the top of this file.
    """
    if not _peel_to_parquet_scan(side):
        return 0

    var specs = List[PayloadNarrowSpec]()
    ref schema = side.output_schema
    for c in range(schema.num_columns()):
        var name = schema.field_name(c)

        # (a) NEVER THE KEY.
        var is_key = False
        for k in range(len(key_names)):
            if key_names[k] == name:
                is_key = True
                break
        if is_key:
            continue

        # (b) DECLARED INT64 only.
        ref f = schema.field_at_unchecked(c)
        if not _is_narrowable_declared_type(f.arrow_type):
            continue

        # (c) NON-NULLABLE only. A narrowed column keeps its validity bitmap,
        # but the value under a NULL slot is unconstrained — it is not covered
        # by `[min, max]`, so `v - base` on it can wrap into a different
        # residue and the widen would reconstruct a DIFFERENT garbage value.
        # Harmless while the slot stays null, and a silent wrong answer the
        # moment anything reads through the mask. v1 refuses rather than
        # reasons about it.
        if f.nullable:
            continue

        # (d) Statistics must PROVE the bound. No stats -> no narrowing; this
        # rule never guesses a domain.
        var mm = _scan_stats_min_max(side, name)
        if not mm:
            continue
        ref mmv = mm.value()
        var width = _column_narrow_width(mmv[0], mmv[1])
        if width == PAYLOAD_NARROW_NONE:
            continue

        specs.append(PayloadNarrowSpec(name.copy(), width, mmv[0]))

    if len(specs) == 0:
        return 0
    var n = len(specs)
    if not _stamp_scan_specs(side, specs^):
        # ⚠ REACHED ONLY IF THE TWO WALKS DISAGREE, which is a bug in THIS file
        # (they are written as a pair).
        return 0  # cov: unreachable _peel_to_parquet_scan admitted this side and the stamp walk follows every shape it admits to the same Parquet scan
    return n


# =============================================================================
# §4 — the walk
# =============================================================================


def narrow_join_payload_inplace(mut plan: LogicalPlan) raises -> Int:
    """In-place stamp. Returns the number of columns narrowed across the plan
    (0 for the overwhelmingly common case — a plan with no eligible join).
    """
    var total = 0
    if plan.tag == PLAN_JOIN and plan._join:
        # Recurse first so a nested join's sides are decided against their own
        # scans, then decide this one.
        total += narrow_join_payload_inplace(plan._join.value()[].left[])
        total += narrow_join_payload_inplace(plan._join.value()[].right[])

        ref jd = plan._join.value()[]
        # INNER only. LEFT/SEMI/ANTI/RIGHT/FULL take emit paths (null
        # extension, probe-only) whose widen point is not the one this rule's
        # consumer owns.
        if jd.join_type != JOIN_INNER:
            return total
        # A residual is evaluated by name over the JOINED batch, inside the
        # leaf, and this rule cannot see where that evaluation sits relative to
        # the widen. Refuse.
        if jd.has_residual():
            return total
        # Single equi-key per side — the shape the measured route takes.
        if len(jd.left_on) != 1 or len(jd.right_on) != 1:
            return total

        total += _narrow_one_side(jd.left[], jd.left_on)
        total += _narrow_one_side(jd.right[], jd.right_on)
        return total

    # Non-join nodes: pure recursion.
    if plan.tag == PLAN_FILTER and plan._filter:
        return total + narrow_join_payload_inplace(plan._filter.value()[].child[])
    if plan.tag == PLAN_PROJECT and plan._project:
        return total + narrow_join_payload_inplace(plan._project.value()[].child[])
    if plan.tag == PLAN_AGGREGATE and plan._aggregate:
        return total + narrow_join_payload_inplace(
            plan._aggregate.value()[].child[]
        )
    if plan.tag == PLAN_SORT and plan._sort:
        return total + narrow_join_payload_inplace(plan._sort.value()[].child[])
    if plan.tag == PLAN_LIMIT and plan._limit:
        return total + narrow_join_payload_inplace(plan._limit.value()[].child[])
    if plan.tag == PLAN_TOPN and plan._topn:
        return total + narrow_join_payload_inplace(plan._topn.value()[].child[])
    if plan.tag == PLAN_DISTINCT and plan._distinct:
        return total + narrow_join_payload_inplace(
            plan._distinct.value()[].child[]
        )
    if plan.tag == PLAN_PARTITION_BY and plan._partition_by:
        return total + narrow_join_payload_inplace(
            plan._partition_by.value()[].child[]
        )
    if plan.tag == PLAN_PARTITION_TOPN and plan._partition_topn:
        return total + narrow_join_payload_inplace(
            plan._partition_topn.value()[].child[]
        )
    if plan.tag == PLAN_ASOF_JOIN and plan._asof_join:
        total += narrow_join_payload_inplace(plan._asof_join.value()[].left[])
        total += narrow_join_payload_inplace(plan._asof_join.value()[].right[])
        return total
    return total


def narrow_join_payload(var plan: LogicalPlan) raises -> LogicalPlan:
    """Value-taking wrapper for the pipeline."""
    _ = narrow_join_payload_inplace(plan)
    return plan^
