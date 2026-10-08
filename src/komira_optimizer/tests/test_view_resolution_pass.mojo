"""Direct tests of `komira_optimizer.view_resolution_pass`.

The pass replaces every `PLAN_VIEW_REF` with a copy of the plan it names,
looking in the statement's CTE bindings first and then in the view registry,
resolving refs inside the expanded plan too (depth limit 16, cycle check by
name). Each test names the defect it catches.
"""

from std.collections import Optional, Dict
from std.memory import OwnedPointer
from std.testing import assert_equal, assert_true, assert_false

from komira_arrow.schema import SchemaBuilder, Field, Schema
from komira_arrow.arrow_types import ArrowType
from komira_collections.slab import Slab
from komira_plan_expr.expr import Expr, BIN_GT
from komira_plan_expr.partition_expr import PartitionExpr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    AsofTolerance,
    ASOF_BACKWARD,
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
    SOURCE_PARQUET,
    JOIN_INNER,
)

from komira_optimizer.view_resolution_pass import (
    view_resolution_pass,
    view_resolution_pass_inplace,
    plan_contains_view_ref,
    VIEW_RESOLUTION_DEPTH_LIMIT,
)


# =============================================================================
# Fixtures
# =============================================================================


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    return sb.build()


def _scan(path: String) -> LogicalPlan:
    return LogicalPlan.scan(path, SOURCE_PARQUET, _schema())


def _ref(name: String) -> LogicalPlan:
    return LogicalPlan.view_ref(name, _schema())


def _one(a: String) -> List[String]:
    var out = List[String]()
    out.append(a)
    return out^


def _scan_path(plan: LogicalPlan) raises -> String:
    assert_equal(plan.tag, PLAN_SCAN)
    return plan._scan.value()[].source_path


struct _Registry(Movable):
    """A view registry in the shape the pass reads: a slab of plans and a
    name -> slot map."""

    var slab: Slab[Optional[LogicalPlan]]
    var idx: Dict[String, Int]

    def __init__(out self):
        self.slab = Slab[Optional[LogicalPlan]]()
        self.idx = Dict[String, Int]()

    def add(mut self, name: String, var plan: LogicalPlan):
        self.idx[name] = len(self.slab)
        self.slab.append(Optional(plan^))


# =============================================================================
# Lookup
# =============================================================================


def test_registry_view_is_inlined() raises:
    """`Filter(view_ref v)` with `v` registered as a scan of v.parquet: the
    3-argument form splices the scan under the Filter.

    Catches: the splice skipped (the ref stays); the wrong registry slot
    expanded."""
    var reg = _Registry()
    reg.add("w", _scan("w.parquet"))
    reg.add("v", _scan("v.parquet"))
    var pred = Expr.binary(BIN_GT, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int(1)))
    var plan = LogicalPlan.filter(pred^, _ref("v"))
    assert_true(plan_contains_view_ref(plan))
    var out = view_resolution_pass(plan^, reg.slab, reg.idx)
    assert_equal(out.tag, PLAN_FILTER)
    assert_false(plan_contains_view_ref(out))
    assert_equal(_scan_path(out._filter.value()[].child[]), String("v.parquet"))


def test_cte_binding_shadows_a_registered_view() raises:
    """With `v` both registered (v.parquet) and bound as a CTE (cte.parquet),
    the CTE wins; the CTE list is searched past a non-matching first name;
    a name bound only in the registry still resolves through it.

    Catches: the registry consulted before the CTE scope; the CTE loop
    stopping at its first entry."""
    var reg = _Registry()
    reg.add("v", _scan("v.parquet"))
    reg.add("only_view", _scan("only.parquet"))
    var names = List[String]()
    names.append("other")
    names.append("v")
    var plans = Slab[LogicalPlan]()
    plans.append(_scan("other.parquet"))
    plans.append(_scan("cte.parquet"))

    var out = view_resolution_pass(_ref("v"), reg.slab, reg.idx, names, plans)
    assert_equal(_scan_path(out), String("cte.parquet"))
    var out2 = view_resolution_pass(_ref("only_view"), reg.slab, reg.idx, names, plans)
    assert_equal(_scan_path(out2), String("only.parquet"))


def test_unknown_name_raises_view_not_found() raises:
    """A ref naming nothing in either scope raises `ViewNotFound` with the
    name.

    Catches: a missing name silently left as a ref, or resolved to some
    other plan."""
    var reg = _Registry()
    reg.add("v", _scan("v.parquet"))
    var raised = False
    try:
        _ = view_resolution_pass(_ref("typo"), reg.slab, reg.idx)
    except e:
        var msg = String(e)
        raised = msg.find("ViewNotFound: 'typo'") >= 0
    assert_true(raised)

def test_registered_name_with_an_empty_slot_raises() raises:
    """A name mapped to a registry slot that holds no plan (the registry's
    own invariant broken) raises `ViewNotFound` with the name; the process
    keeps running.

    Catches: the empty slot read with `Optional.value()`, which aborts the
    process instead of raising a catchable Error."""
    var reg = _Registry()
    reg.add("v", _scan("v.parquet"))
    reg.idx["gone"] = len(reg.slab)
    reg.slab.append(Optional[LogicalPlan](None))
    var raised = False
    try:
        _ = view_resolution_pass(_ref("gone"), reg.slab, reg.idx)
    except e:
        raised = String(e).find("ViewNotFound: 'gone'") >= 0
    assert_true(raised)



# =============================================================================
# Chains, the depth limit, cycles
# =============================================================================


def _chain(n: Int) -> _Registry:
    """Views v0 .. v{n-1}: v{i} is a ref to v{i+1}; the last is a scan."""
    var reg = _Registry()
    for i in range(n):
        if i == n - 1:
            reg.add("v" + String(i), _scan("end.parquet"))
        else:
            reg.add("v" + String(i), _ref("v" + String(i + 1)))
    return reg^


def test_chain_of_sixteen_resolves_and_seventeen_raises() raises:
    """A chain of 16 views resolves to the final scan; a chain of 17 raises
    `ViewRecursionLimitExceeded` naming the limit and the chain so far,
    rendered `v0 -> v1 -> ...`.

    Catches: the depth guard off by one (`>` for `>=` lets 17 through, a
    limit of 15 rejects 16); expanded plans not resolved recursively (the
    16-chain would keep a ref); the chain text losing its separators."""
    assert_equal(VIEW_RESOLUTION_DEPTH_LIMIT, 16)
    var ok = _chain(16)
    var out = view_resolution_pass(_ref("v0"), ok.slab, ok.idx)
    assert_equal(_scan_path(out), String("end.parquet"))

    var deep = _chain(17)
    var raised = False
    try:
        _ = view_resolution_pass(_ref("v0"), deep.slab, deep.idx)
    except e:
        var msg = String(e)
        raised = (
            msg.find("ViewRecursionLimitExceeded") >= 0
            and msg.find("depth limit 16") >= 0
            and msg.find("v0 -> v1 -> v2") >= 0
            and msg.find("v15)") >= 0
        )
    assert_true(raised)


def test_cycle_raises_before_the_depth_limit() raises:
    """`a -> b -> a` raises the cycle message naming `a`, not the depth
    message.

    Catches: the cycle guard removed (the chain then runs to the depth
    limit and raises the other message)."""
    var reg = _Registry()
    reg.add("a", _ref("b"))
    reg.add("b", _ref("a"))
    var raised = False
    try:
        _ = view_resolution_pass(_ref("a"), reg.slab, reg.idx)
    except e:
        var msg = String(e)
        raised = (
            msg.find("cycle detected resolving 'a'") >= 0
            and msg.find("a -> b") >= 0
        )
    assert_true(raised)


def test_same_view_twice_in_one_plan_is_not_a_cycle() raises:
    """`Join(view_ref v, view_ref v)` resolves both sides: the name is taken
    off the resolution stack after the first expansion.

    Catches: the `name_stack.pop()` removed (the second `v` is then reported
    as a cycle)."""
    var reg = _Registry()
    reg.add("v", _scan("v.parquet"))
    var plan = LogicalPlan.join(_ref("v"), _ref("v"), _one("a"), _one("a"), JOIN_INNER)
    var out = view_resolution_pass(plan^, reg.slab, reg.idx)
    assert_false(plan_contains_view_ref(out))
    assert_equal(_scan_path(out._join.value()[].right[]), String("v.parquet"))


# =============================================================================
# The plan walk and the invariant check
# =============================================================================


def _wrap(kind: Int, var child: LogicalPlan) raises -> LogicalPlan:
    """`child` under one node of the kind numbered `kind` (0..11); kinds 9
    and 10 put `child` on the right of a two-input node with a scan on the
    left, and kind 11 puts it second in a Union."""
    var desc = List[Bool]()
    desc.append(False)
    if kind == 0:
        return LogicalPlan.filter(
            Expr.binary(BIN_GT, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int(0))),
            child^,
        )
    if kind == 1:
        var exprs = ExprArray()
        exprs.append(Expr.col_ref("a"))
        return LogicalPlan.project(exprs^, child^)
    if kind == 2:
        var gb = ExprArray()
        gb.append(Expr.col_ref("a"))
        return LogicalPlan.aggregate(gb^, AggExprArray(), child^)
    if kind == 3:
        return LogicalPlan.sort(_one("a"), desc^, child^)
    if kind == 4:
        return LogicalPlan.limit(5, child^)
    if kind == 5:
        return LogicalPlan.distinct(None, child^)
    if kind == 6:
        return LogicalPlan.topn(_one("a"), desc^, 5, child^)
    if kind == 7:
        return LogicalPlan.partition_by(
            _one("a"), _one("a"), desc^, List[PartitionExpr](), child^
        )
    if kind == 8:
        return LogicalPlan.partition_topn(_one("a"), _one("a"), desc^, 1, child^)
    if kind == 9:
        return LogicalPlan.join(_scan("l.parquet"), child^, _one("a"), _one("a"), JOIN_INNER)
    if kind == 10:
        return LogicalPlan.asof_join(
            _scan("l.parquet"), child^, _one("a"), _one("a"), "a", "a",
            ASOF_BACKWARD, AsofTolerance.none(),
        )
    if kind == 11:
        var kids = List[OwnedPointer[LogicalPlan]]()
        kids.append(OwnedPointer(_scan("u.parquet")))
        kids.append(OwnedPointer(child^))
        return LogicalPlan.union(kids^, _schema())
    raise Error("test: unknown wrapper kind " + String(kind))


def _tag_of(kind: Int) -> UInt8:
    if kind == 0:
        return PLAN_FILTER
    if kind == 1:
        return PLAN_PROJECT
    if kind == 2:
        return PLAN_AGGREGATE
    if kind == 3:
        return PLAN_SORT
    if kind == 4:
        return PLAN_LIMIT
    if kind == 5:
        return PLAN_DISTINCT
    if kind == 6:
        return PLAN_TOPN
    if kind == 7:
        return PLAN_PARTITION_BY
    if kind == 8:
        return PLAN_PARTITION_TOPN
    if kind == 9:
        return PLAN_JOIN
    if kind == 10:
        return PLAN_ASOF_JOIN
    return PLAN_UNION


def test_walk_resolves_a_ref_under_every_node_kind() raises:
    """A view ref under each of Filter, Project, Aggregate, Sort, Limit,
    Distinct, TopN, PartitionBy, PartitionTopN, the right input of a Join
    and of an AsOf join, and the second branch of a Union: the invariant
    check sees it before the pass and not after, and the wrapper keeps its
    kind.

    Catches: any one recursion arm of the walk removed (that ref survives);
    any one arm of `plan_contains_view_ref` removed (it misses the ref
    before the pass); a two-input arm or the Union loop looking only at the
    first input."""
    var reg = _Registry()
    reg.add("v", _scan("v.parquet"))
    for kind in range(12):
        var plan = _wrap(kind, _ref("v"))
        assert_true(plan_contains_view_ref(plan))
        var empty_names = List[String]()
        var empty_plans = Slab[LogicalPlan]()
        view_resolution_pass_inplace(plan, reg.slab, reg.idx, empty_names, empty_plans)
        assert_equal(plan.tag, _tag_of(kind))
        assert_false(plan_contains_view_ref(plan))


def test_left_inputs_are_walked_and_checked() raises:
    """A view ref on the LEFT of a Join and of an AsOf join (scan on the
    right) is found by the check and resolved by the walk.

    Catches: a two-input arm that walks or checks only its right input."""
    var reg = _Registry()
    reg.add("v", _scan("v.parquet"))
    var j = LogicalPlan.join(_ref("v"), _scan("r.parquet"), _one("a"), _one("a"), JOIN_INNER)
    var aj = LogicalPlan.asof_join(
        _ref("v"), _scan("r.parquet"), _one("a"), _one("a"), "a", "a",
        ASOF_BACKWARD, AsofTolerance.none(),
    )
    assert_true(plan_contains_view_ref(j))
    assert_true(plan_contains_view_ref(aj))
    var j_out = view_resolution_pass(j^, reg.slab, reg.idx)
    var aj_out = view_resolution_pass(aj^, reg.slab, reg.idx)
    assert_equal(_scan_path(j_out._join.value()[].left[]), String("v.parquet"))
    assert_equal(_scan_path(aj_out._asof_join.value()[].left[]), String("v.parquet"))


def test_plan_without_refs_is_unchanged() raises:
    """A scan and a Union of two scans have no refs: the check says so and
    the pass leaves them as they were.

    Catches: the check reporting a ref where none is (the Union loop's
    False exit, the scan fall-through)."""
    var reg = _Registry()
    var plan = _wrap(11, _scan("x.parquet"))
    assert_false(plan_contains_view_ref(plan))
    var out = view_resolution_pass(plan^, reg.slab, reg.idx)
    assert_equal(out.tag, PLAN_UNION)
    assert_equal(len(out._union.value()[].children), 2)
    var s = view_resolution_pass(_scan("x.parquet"), reg.slab, reg.idx)
    assert_equal(_scan_path(s), String("x.parquet"))
    var bare = _ref("v")
    assert_equal(bare.tag, PLAN_VIEW_REF)
    assert_true(plan_contains_view_ref(bare))


def main() raises:
    test_registry_view_is_inlined()
    test_cte_binding_shadows_a_registered_view()
    test_unknown_name_raises_view_not_found()
    test_registered_name_with_an_empty_slot_raises()
    test_chain_of_sixteen_resolves_and_seventeen_raises()
    test_cycle_raises_before_the_depth_limit()
    test_same_view_twice_in_one_plan_is_not_a_cycle()
    test_walk_resolves_a_ref_under_every_node_kind()
    test_left_inputs_are_walked_and_checked()
    test_plan_without_refs_is_unchanged()
    print("All view_resolution_pass tests passed.")
