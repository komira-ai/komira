# =============================================================================
# komira_lowering_rules.payload_narrow: the host rule that narrows join payloads
# =============================================================================
#
# A host-local lowering rule: payload narrowing, rule 3 in the list of
# host-local rules of the optimized-plan design. The producer does not decide
# it. The host derives it from the Parquet footers it opened and verified
# against the plan's pins, because narrowing truncates values: a wrong
# `[min, max]` is a wrong answer, not a slow one, so no statistic a producer
# recorded on the plan may drive it.
#
# `derive_payload_narrow(plan, footer_stats)` is a pure function. It reads its
# two arguments and nothing else (no file, clock, environment or global), it
# does not change the plan, and the same arguments give the same result.
#
# INPUT. `footer_stats` holds one entry per scan of `plan`, in SCAN PRE-ORDER
# (below): the `TableStats` read from that scan's verified footers, or None when
# there are none (a non-Parquet scan, or footers without statistics). A count
# that differs from the plan's scan count is refused with
# `LOWERING_PAYLOAD_NARROW_FOOTER_COUNT`. `ScanData.table_stats` on the plan is
# never read.
#
# OUTPUT. One list per scan, in the same order: the `PayloadNarrowSpec`s for
# that scan, empty when the scan narrows nothing.
#
# SCAN PRE-ORDER. The plan-node tree, a node before its children: a join's
# (and an as-of join's) left side before its right, a union's children in
# order, every other node's one child. A node whose tag carries no payload has
# no children. Plans held inside expressions (subquery payloads) are not
# walked, and their scans are not counted. A tag outside the sixteen `PLAN_*`
# tags is refused with `LOWERING_SCAN_ORDER_UNKNOWN_TAG`.
#
# THE RULE.
#   A join qualifies when it is INNER, has no residual, and has exactly one key
#   on each side. Joins are found by walking the plan through every node kind
#   except UNION and CAST_TO_VARCHAR (a join below either is not considered);
#   VIEW_REF and CSE_REF are leaves.
#   A side qualifies when it is a chain of FILTER and PROJECT nodes ending in a
#   Parquet SCAN, where each PROJECT has no UDF and every expression is a
#   column reference or an alias of one.
#   On a qualifying side, each column of the SIDE's output schema is narrowed
#   when all of these hold:
#     (a) it is not one of that side's join keys (by name);
#     (b) its declared type is INT64;
#     (c) it is declared non-nullable;
#     (d) the side's scan has a footer entry, the entry has a column of that
#         name, and both its min and max are present and integers;
#     (e) `choose_narrow_width(min, max)` is a width (1, 2 or 4 bytes).
#   The spec is (column name, width, base = min), on the side's scan.
#   A filter between the join and the scan is safe: footer bounds hold every
#   value the scan reads, so they hold every value that survives the filter.
#
# PARITY. These are the decisions `komira_optimizer`'s
# `optimizer_payload_narrow` stamps on `ScanData.payload_narrow` when each
# scan's `table_stats` equals its footer entry here; the parity test in
# `src/tests/conformance/komira_lowering_rules_conformance` pins it. Matching it
# exactly keeps two of its behaviours:
#   - a join below a UNION or a CAST_TO_VARCHAR narrows nothing;
#   - a column is judged by the side's output schema (name, type,
#     nullability), while its bounds are looked up under the same name in the
#     scan's footer. A pure PROJECT that renames a column (`a AS b`) therefore
#     takes the bounds of the scan's column `b`, which is unrelated to `a` and
#     may be nullable (or takes none, when the scan has no `b`). Bounds that do
#     not hold `a` cost speed, not correctness: the join's narrowing pass
#     range-checks every value and, on one outside the bounds, runs the join
#     unnarrowed.
#
# POINTER DISCIPLINE: no pointer in any signature; the plan is read through
# `ref`s into its `OwnedPointer` payloads, and nothing is moved out of them.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.payload_narrow import (
    PayloadNarrowSpec,
    PAYLOAD_NARROW_NONE,
    choose_narrow_width,
)
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    JoinData,
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
    JOIN_INNER,
    SOURCE_PARQUET,
)
from komira_plan_stats.table_stats import TableStats


comptime LOWERING_PAYLOAD_NARROW_FOOTER_COUNT = "LOWERING_PAYLOAD_NARROW_FOOTER_COUNT"
"""Refusal: `footer_stats` does not hold exactly one entry per scan."""

comptime LOWERING_SCAN_ORDER_UNKNOWN_TAG = "LOWERING_SCAN_ORDER_UNKNOWN_TAG"
"""Refusal: a node's tag is none of the `PLAN_*` tags, so its children, and
with them the scan order, are unknown."""


def derive_payload_narrow(
    plan: LogicalPlan, footer_stats: List[Optional[TableStats]]
) raises -> List[List[PayloadNarrowSpec]]:
    """The payload-narrowing specs of every scan of `plan`, in scan pre-order.

    Args:
        plan: The admitted plan. It is read, never changed.
        footer_stats: One entry per scan of `plan`, in scan pre-order: the
            statistics of that scan's verified footers, or None.

    Returns:
        One list per scan, in scan pre-order; empty for a scan that narrows
        nothing.

    Raises:
        `LOWERING_PAYLOAD_NARROW_FOOTER_COUNT` when `len(footer_stats)` is not
        the plan's scan count; `LOWERING_SCAN_ORDER_UNKNOWN_TAG` on a node
        whose tag is no `PLAN_*` tag.
    """
    # The first walk decides nothing; it counts the scans by the same walk
    # that the second one indexes `footer_stats` with.
    var counted = List[List[PayloadNarrowSpec]]()
    _walk(plan, False, footer_stats, counted)
    if len(counted) != len(footer_stats):
        raise Error(
            String(LOWERING_PAYLOAD_NARROW_FOOTER_COUNT)
            + ": the plan has "
            + String(len(counted))
            + " scans and footer_stats has "
            + String(len(footer_stats))
            + " entries"
        )
    var out = List[List[PayloadNarrowSpec]]()
    _walk(plan, True, footer_stats, out)
    return out^


# =============================================================================
# The walk
# =============================================================================


def _walk(
    node: LogicalPlan,
    live: Bool,
    footer_stats: List[Optional[TableStats]],
    mut out: List[List[PayloadNarrowSpec]],
) raises:
    """Visit `node` in scan pre-order, appending one entry to `out` per scan.

    `live` is whether a qualifying join here is decided; it is False below a
    UNION or a CAST_TO_VARCHAR, and on the counting walk. A join is decided
    after both its sides are walked, so the index of each side's first scan
    (taken before that side is walked) is known.
    """
    var tag = node.tag
    if tag == PLAN_SCAN:
        out.append(List[PayloadNarrowSpec]())
        return
    if tag == PLAN_JOIN:
        if node._join:
            ref jd = node._join.value()[]
            var left_first = len(out)
            _walk(jd.left[], live, footer_stats, out)
            var right_first = len(out)
            _walk(jd.right[], live, footer_stats, out)
            if live and _join_qualifies(jd):
                _narrow_side(jd.left[], left_first, jd.left_on, footer_stats, out)
                _narrow_side(jd.right[], right_first, jd.right_on, footer_stats, out)
        return
    if tag == PLAN_ASOF_JOIN:
        if node._asof_join:
            _walk(node._asof_join.value()[].left[], live, footer_stats, out)
            _walk(node._asof_join.value()[].right[], live, footer_stats, out)
        return
    if tag == PLAN_UNION:
        if node._union:
            ref children = node._union.value()[].children
            for i in range(len(children)):
                _walk(children[i][], False, footer_stats, out)
        return
    if tag == PLAN_CAST_TO_VARCHAR:
        if node._cast_to_varchar:
            _walk(node._cast_to_varchar.value()[].child[], False, footer_stats, out)
        return
    if tag == PLAN_VIEW_REF or tag == PLAN_CSE_REF:
        return
    if tag == PLAN_FILTER:
        if node._filter:
            _walk(node._filter.value()[].child[], live, footer_stats, out)
        return
    if tag == PLAN_PROJECT:
        if node._project:
            _walk(node._project.value()[].child[], live, footer_stats, out)
        return
    if tag == PLAN_AGGREGATE:
        if node._aggregate:
            _walk(node._aggregate.value()[].child[], live, footer_stats, out)
        return
    if tag == PLAN_SORT:
        if node._sort:
            _walk(node._sort.value()[].child[], live, footer_stats, out)
        return
    if tag == PLAN_LIMIT:
        if node._limit:
            _walk(node._limit.value()[].child[], live, footer_stats, out)
        return
    if tag == PLAN_DISTINCT:
        if node._distinct:
            _walk(node._distinct.value()[].child[], live, footer_stats, out)
        return
    if tag == PLAN_TOPN:
        if node._topn:
            _walk(node._topn.value()[].child[], live, footer_stats, out)
        return
    if tag == PLAN_PARTITION_BY:
        if node._partition_by:
            _walk(node._partition_by.value()[].child[], live, footer_stats, out)
        return
    if tag == PLAN_PARTITION_TOPN:
        if node._partition_topn:
            _walk(node._partition_topn.value()[].child[], live, footer_stats, out)
        return
    raise Error(
        String(LOWERING_SCAN_ORDER_UNKNOWN_TAG)
        + ": plan tag "
        + String(Int(tag))
        + " is no PLAN_* tag"
    )


# =============================================================================
# The join and its sides
# =============================================================================


def _join_qualifies(jd: JoinData) -> Bool:
    """INNER, no residual, one key on each side.

    Other join types take emit paths (null extension, probe-only) the
    narrowing consumer does not own; a residual is evaluated by name over the
    joined batch; a multi-key join is not the route the rule was measured on.
    """
    if jd.join_type != JOIN_INNER:
        return False
    if jd.has_residual():
        return False
    return len(jd.left_on) == 1 and len(jd.right_on) == 1


def _side_reaches_parquet_scan(node: LogicalPlan) -> Bool:
    """True when `node` is FILTER and pure PROJECT nodes over a Parquet SCAN.

    A PROJECT with a UDF, or with an expression other than a column reference
    or an alias of one, ends the side: a computed column would be read by an
    evaluator that knows nothing of the narrowed representation.
    """
    if node.tag == PLAN_SCAN:
        if not node._scan:
            return False
        return node._scan.value()[].source_type == SOURCE_PARQUET
    if node.tag == PLAN_FILTER and node._filter:
        return _side_reaches_parquet_scan(node._filter.value()[].child[])
    if node.tag == PLAN_PROJECT and node._project:
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
        return _side_reaches_parquet_scan(pd.child[])
    return False


def _is_key(name: String, keys: List[String]) -> Bool:
    for k in range(len(keys)):
        if keys[k] == name:
            return True
    return False


def _narrow_side(
    side: LogicalPlan,
    scan_index: Int,
    keys: List[String],
    footer_stats: List[Optional[TableStats]],
    mut out: List[List[PayloadNarrowSpec]],
) raises:
    """Decide one join side and write its specs to `out[scan_index]`.

    `scan_index` is the pre-order index of the side's first scan: for a side
    that qualifies (a chain of one-child nodes over a scan) it is the scan.
    `keys` are this side's join keys, which are never narrowed: the fused
    join leaf declines a key that is not INT64.
    """
    if not _side_reaches_parquet_scan(side):
        return
    ref footer = footer_stats[scan_index]
    if not footer:
        return
    ref ts = footer.value()
    var specs = List[PayloadNarrowSpec]()
    ref schema = side.output_schema
    for c in range(schema.num_columns()):
        var name = schema.field_name(c)
        # (a) never a join key of this side.
        if _is_key(name, keys):
            continue
        ref f = schema.field_at_unchecked(c)
        # (b) declared INT64 only: the widen reconstructs `Int64(stored) + base`.
        if f.arrow_type != ArrowType.INT64:
            continue
        # (c) non-nullable only: the value under a null slot is not inside
        # [min, max], so `v - base` on it could wrap.
        if f.nullable:
            continue
        # (d) the footer must prove the bound; no bound, no narrowing.
        var idx = ts.find_column(name)
        if idx < 0:
            continue
        ref cs = ts.column_stats[idx]
        if not cs.min_value or not cs.max_value:
            continue
        ref mn = cs.min_value.value()
        ref mx = cs.max_value.value()
        if not mn.is_int() or not mx.is_int():
            continue
        # (e) the narrowest width that holds max - min, if any.
        var width = choose_narrow_width(mn.int_val, mx.int_val)
        if width == PAYLOAD_NARROW_NONE:
            continue
        specs.append(PayloadNarrowSpec(name.copy(), width, mn.int_val))
    out[scan_index] = specs^
