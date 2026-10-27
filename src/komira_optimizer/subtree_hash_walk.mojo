# =============================================================================
# subtree_hash_walk.mojo -- the analysis shared by `plan_cse` and
# `scan_dedup_compile`: which subtrees hold a scan, which are pure, and how
# many times each scan-bearing subtree occurs, keyed on `structural_hash`.
#
# ONE PASS. `analyze_subtrees` walks a plan once, bottom-up, and records for
# every node (in pre-order position) whether its subtree is pure, whether it
# holds a scan, how many nodes it spans, its `structural_hash`, and the text
# of its output schema. Every later question is answered from those tables, so
# purity and has-scan are linear in the plan. The one cost that is not linear
# is the hash: `structural_hash` renders a subtree to text, so a scan-bearing
# node costs one render of its whole subtree, and a deep chain of scan-bearing
# nodes costs the sum of those renders (quadratic in depth).
#
# The key is `LogicalPlan.structural_hash()`, the hash of the plan's rendered
# text. The render omits things (a file scan's output schema is one), and a
# 64-bit hash can collide, so the key alone does not prove two subtrees are
# equal. `subtree_identity` is the proof a rewrite compares: the full render
# plus the output schema of every node of the subtree.
#
# PURITY. A subtree is pure when re-evaluating it has no observable effect, so
# two occurrences may be computed once. A node answers False when
#   * it carries a typed UDF (`has_udf`), whose body is opaque and may hold
#     state, so two occurrences are never shared even when their rendered text
#     (UDF id and call-site salt included) is identical;
#   * one of its expressions (a scan's pushed-down filter, a Filter predicate,
#     Project expressions, Aggregate group keys and aggregate inputs, a Join
#     residual) holds a registered UDF call (`EXPR_UDF_CALL`), or holds a
#     subquery expression. A subquery expression renders only its kind, its
#     outer-reference count and the tag of its inner plan, so two Filters that
#     differ only in the inner plan render alike;
#   * its kind is not on the allowlist (cast, exchange, map_batches, step, or
#     a kind added later), so a new kind is not shared until it is listed here.
# A view reference and a CSE reference are pure leaves: the first names a
# registered view, the second names an already-shared pure subtree. A call of
# a `UdfRef` (`EXPR_UDF_APPLY`) is not reported by the UDF-call walk and is
# not treated as a UDF here.
# =============================================================================

from std.collections import Dict

from komira_plan_expr.expr import Expr
from komira_plan_ir.expr_udf_sites import collect_udf_calls
from komira_plan_ir.logical_plan import (
    LogicalPlan,
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
)

comptime _PURE: Int = 1
comptime _SCAN: Int = 2


struct SubtreeFacts(Movable):
    """Per-node facts about one plan, indexed by the node's pre-order
    position (the root is 0). Children are numbered in the order Join and
    AsofJoin store them (left, then right) and a Union stores its branches.

    `hash[i]` is meaningful only where `has_scan[i]` is True and the facts
    were built with hashes.
    """

    var pure: List[Bool]
    var has_scan: List[Bool]
    var size: List[Int]
    var hash: List[UInt64]
    var schema_sig: List[String]

    def __init__(out self):
        self.pure = List[Bool]()
        self.has_scan = List[Bool]()
        self.size = List[Int]()
        self.hash = List[UInt64]()
        self.schema_sig = List[String]()


def _expr_blocks_sharing(expr: Expr) -> Bool:
    """True when `expr` holds a registered UDF call or a subquery expression,
    or when the UDF-call walk cannot read it. The walk is total over
    expression tags and raises on a subquery expression, so every failure to
    read answers "do not share"."""
    var sites = List[Expr]()
    try:
        collect_udf_calls(expr, sites, refuse_correlated_subquery=True)
    except:
        return True
    return len(sites) > 0


def _node_is_pure(plan: LogicalPlan) -> Bool:
    """Whether `plan` itself (not its children) may be shared: no typed UDF
    and no UDF call or subquery in any expression it holds. The node kinds
    that hold an `Expr` are Scan (pushed-down filter), Filter, Project,
    Aggregate and Join (residual); every other kind holds column names."""
    if plan.tag == PLAN_SCAN:
        ref sd = plan._scan.value()[]
        if sd.filter:
            return not _expr_blocks_sharing(sd.filter.value())
        return True
    if plan.tag == PLAN_FILTER:
        ref fd = plan._filter.value()[]
        if fd.has_udf():
            return False
        return not _expr_blocks_sharing(fd.predicate)
    if plan.tag == PLAN_PROJECT:
        ref pd = plan._project.value()[]
        if pd.has_udf():
            return False
        for i in range(len(pd.exprs)):
            if _expr_blocks_sharing(pd.exprs[i]):
                return False
        return True
    if plan.tag == PLAN_AGGREGATE:
        ref ad = plan._aggregate.value()[]
        if ad.has_udf():
            return False
        for i in range(len(ad.group_by)):
            if _expr_blocks_sharing(ad.group_by[i]):
                return False
        for i in range(len(ad.agg_exprs)):
            if ad.agg_exprs[i].child:
                if _expr_blocks_sharing(ad.agg_exprs[i].child.value()):
                    return False
            if ad.agg_exprs[i].child1:
                if _expr_blocks_sharing(ad.agg_exprs[i].child1.value()):
                    return False
            if ad.agg_exprs[i].child2:
                if _expr_blocks_sharing(ad.agg_exprs[i].child2.value()):
                    return False
            if ad.agg_exprs[i].child3:
                if _expr_blocks_sharing(ad.agg_exprs[i].child3.value()):
                    return False
        return True
    if plan.tag == PLAN_JOIN:
        ref jd = plan._join.value()[]
        if jd.residual:
            return not _expr_blocks_sharing(jd.residual.value()[])
        return True
    return True


def _fold(m: Int, mut pure: Bool, mut scan: Bool):
    """Fold one child's `_PURE`/`_SCAN` mask into its parent's flags."""
    if (m & _PURE) == 0:
        pure = False
    if (m & _SCAN) != 0:
        scan = True


def _analyze(plan: LogicalPlan, mut f: SubtreeFacts, hashes: Bool) -> Int:
    """Append `plan`'s subtree to `f` in pre-order and return its mask."""
    var idx = len(f.pure)
    f.pure.append(False)
    f.has_scan.append(False)
    f.size.append(1)
    f.hash.append(0)
    var sig = String("")
    sig.write(plan.output_schema)
    f.schema_sig.append(sig^)

    var pure = _node_is_pure(plan)
    var scan = False
    if plan.tag == PLAN_SCAN:
        scan = True
    elif plan.tag == PLAN_FILTER:
        _fold(_analyze(plan._filter.value()[].child[], f, hashes), pure, scan)
    elif plan.tag == PLAN_PROJECT:
        _fold(_analyze(plan._project.value()[].child[], f, hashes), pure, scan)
    elif plan.tag == PLAN_AGGREGATE:
        _fold(
            _analyze(plan._aggregate.value()[].child[], f, hashes), pure, scan
        )
    elif plan.tag == PLAN_JOIN:
        _fold(_analyze(plan._join.value()[].left[], f, hashes), pure, scan)
        _fold(_analyze(plan._join.value()[].right[], f, hashes), pure, scan)
    elif plan.tag == PLAN_SORT:
        _fold(_analyze(plan._sort.value()[].child[], f, hashes), pure, scan)
    elif plan.tag == PLAN_LIMIT:
        _fold(_analyze(plan._limit.value()[].child[], f, hashes), pure, scan)
    elif plan.tag == PLAN_DISTINCT:
        _fold(
            _analyze(plan._distinct.value()[].child[], f, hashes), pure, scan
        )
    elif plan.tag == PLAN_TOPN:
        _fold(_analyze(plan._topn.value()[].child[], f, hashes), pure, scan)
    elif plan.tag == PLAN_PARTITION_BY:
        _fold(
            _analyze(plan._partition_by.value()[].child[], f, hashes),
            pure,
            scan,
        )
    elif plan.tag == PLAN_PARTITION_TOPN:
        _fold(
            _analyze(plan._partition_topn.value()[].child[], f, hashes),
            pure,
            scan,
        )
    elif plan.tag == PLAN_ASOF_JOIN:
        _fold(
            _analyze(plan._asof_join.value()[].left[], f, hashes), pure, scan
        )
        _fold(
            _analyze(plan._asof_join.value()[].right[], f, hashes), pure, scan
        )
    elif plan.tag == PLAN_UNION:
        ref ud = plan._union.value()[]
        for i in range(len(ud.children)):
            _fold(_analyze(ud.children[i][], f, hashes), pure, scan)
    elif plan.tag == PLAN_VIEW_REF or plan.tag == PLAN_CSE_REF:
        pass
    else:
        # A kind off the allowlist is not pure and is not entered.
        pure = False

    f.pure[idx] = pure
    f.has_scan[idx] = scan
    f.size[idx] = len(f.pure) - idx
    if hashes and scan:
        f.hash[idx] = plan.structural_hash()
    var m = 0
    if pure:
        m |= _PURE
    if scan:
        m |= _SCAN
    return m


def analyze_subtrees(plan: LogicalPlan) -> SubtreeFacts:
    """The facts of every subtree of `plan`, hashes included."""
    var f = SubtreeFacts()
    _ = _analyze(plan, f, True)
    return f^


def plan_is_pure(plan: LogicalPlan) -> Bool:
    """True iff `plan` and every descendant is on the pure allowlist and
    neither carries a typed UDF nor holds a UDF call or a subquery in any
    expression (see the file header)."""
    var f = SubtreeFacts()
    _ = _analyze(plan, f, False)
    return f.pure[0]


def plan_has_scan(plan: LogicalPlan) -> Bool:
    """True iff `plan` or any descendant is a PLAN_SCAN node. A view or CSE
    reference is a leaf with no scan."""
    var f = SubtreeFacts()
    _ = _analyze(plan, f, False)
    return f.has_scan[0]


def count_scan_subtrees(
    facts: SubtreeFacts,
    mut counts: Dict[UInt64, Int],
    pure_only: Bool,
) raises:
    """Add one to `counts[hash]` for every subtree in `facts` (the root
    included) that holds a scan.

    With `pure_only`, a subtree that is not pure is skipped together with
    everything below it, so a UDF-bearing node never reaches a count of two
    through its own text. Without it, every scan-bearing subtree is counted.
    Union branches are counted.
    """
    var n = len(facts.pure)
    var i = 0
    while i < n:
        if (pure_only and not facts.pure[i]) or not facts.has_scan[i]:
            i += facts.size[i]
            continue
        var h = facts.hash[i]
        if h in counts:
            counts[h] = counts[h] + 1
        else:
            counts[h] = 1
        i += 1


def count_duplicate_groups(counts: Dict[UInt64, Int]) -> Int:
    """The number of hashes in `counts` seen at least twice."""
    var n = 0
    for kv in counts.items():
        if kv.value > 1:
            n += 1
    return n


def subtree_identity(
    plan: LogicalPlan, facts: SubtreeFacts, idx: Int
) -> String:
    """The text two subtrees must share to be treated as equal: the render of
    `plan` (the node at pre-order position `idx` of `facts`) followed by the
    output schema of every node in its subtree, in pre-order.

    The hash is a summary of the render; this is what the hash summarises plus
    the schemas the render leaves out."""
    var s = String("")
    s.write(plan)
    for j in range(idx, idx + facts.size[idx]):
        s.write("\n", facts.schema_sig[j])
    return s^
