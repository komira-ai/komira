# =============================================================================
# optimize_window_rewrite: the helpers, the name preview, the Pattern C
# predicate, and every arm of the recurse-and-rebuild walk.
# =============================================================================
#
# The moved window tests pin Patterns A, B and C at the top of a plan. This
# file covers what they leave out:
#
#   * the list/triple comparators and `_is_window_or_alias_window`, called
#     directly so each early return is reached on its own;
#   * `_preview_partition_expr_name` for an alias and for EVERY window
#     function tag (one `elif` per tag, the last one the `else` for PF_MAX);
#   * `_sort_keys_redundant_after_partition_by`, one call per return;
#   * `_recurse_into_children`: for every node kind it rebuilds, a window
#     Project is put UNDER the node, and the test asserts both that the window
#     was lowered (the walk descended) and that the node's own payload came
#     back unchanged (the rebuild copied every field). A Union is the one kind
#     the walk does not rebuild: it is returned as is, windows below included.
#   * two Pattern A / Pattern B effects the moved tests do not pin: two
#     windows shadowing the SAME child column name, and the recursion below
#     an outer PartitionBy whose triple does not match the one under it.
#
# Every plan is built in memory; no file is read.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.schema import Schema, Field
from komira_arrow.arrow_types import ArrowType

from komira_plan_expr.col_expr import col
from komira_plan_expr.expr import Expr, EXPR_ALIAS, BIN_GT, BIN_LT
from komira_plan_expr.agg_expr import AggExpr, AGG_CORR
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.partition_frame import PartitionFrame
from komira_plan_expr.partition_expr import (
    PartitionExpr,
    PF_ROW_NUMBER, PF_RANK, PF_DENSE_RANK, PF_PERCENT_RANK,
    PF_CUME_DIST, PF_NTILE, PF_LAG, PF_LEAD,
    PF_FIRST_VALUE, PF_LAST_VALUE, PF_NTH_VALUE,
    PF_SUM, PF_AVG, PF_MIN, PF_MAX, PF_COUNT,
)
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    AsofTolerance,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_ASOF_JOIN,
    PLAN_UNION,
    JOIN_INNER,
    JOIN_ALGO_HASH,
    ASOF_FORWARD,
    ASOF_TOL_INT64,
)

from komira_optimizer.optimizer_window_rewrite import (
    optimize_window_rewrite,
    _str_lists_equal,
    _bool_lists_equal,
    _triples_equal,
    _is_window_or_alias_window,
    _preview_partition_expr_name,
    _sort_keys_redundant_after_partition_by,
)


# =============================================================================
# Builders
# =============================================================================


def _scan2(a: String, b: String) raises -> LogicalPlan:
    """An in-memory Scan with two INT64 columns `a` and `b`."""
    var schema = Schema.from_fields_2(
        Field(a, ArrowType.INT64, False),
        Field(b, ArrowType.INT64, False),
    )
    return LogicalPlan.scan(String("__test"), UInt8(3), schema^)


def _window_project(g: String, v: String, name: String) raises -> LogicalPlan:
    """Project([g, v, rank() OVER (PARTITION BY g) AS name]) over Scan(g, v):
    the Pattern A shape, which the rule lowers to Project over PartitionBy."""
    var exprs = ExprArray()
    exprs.append(Expr.col_ref(g))
    exprs.append(Expr.col_ref(v))
    exprs.append(col(v).rank().over(g).alias(name))
    return LogicalPlan.project(exprs^, _scan2(g, v))


def _assert_lowered(plan: LogicalPlan, what: String) raises:
    """The window Project under a rebuilt node was rewritten: it is now a
    Project whose child is a PartitionBy."""
    assert_equal(Int(plan.tag), Int(PLAN_PROJECT), what)
    assert_equal(
        Int(plan.project_data_ref().child[].tag), Int(PLAN_PARTITION_BY), what
    )


def _pexpr(func: UInt8, alias_name: String) -> PartitionExpr:
    """A PartitionExpr of tag `func`; only `func` and `alias_name` matter to
    the name preview."""
    return PartitionExpr(
        func, String(""), 0, ScalarValue(), False,
        PartitionFrame.default_ordered(), alias_name.copy(),
    )


# =============================================================================
# Comparators
# =============================================================================


def test_str_lists_equal_each_return() raises:
    """Catches a comparator that checks only lengths, or only the first
    element: equal lists, a length mismatch and a later-element mismatch."""
    var a: List[String] = ["x", "y"]
    var same: List[String] = ["x", "y"]
    var shorter: List[String] = ["x"]
    var differs: List[String] = ["x", "z"]
    assert_true(_str_lists_equal(a, same))
    assert_false(_str_lists_equal(a, shorter), "length mismatch")
    assert_false(_str_lists_equal(a, differs), "second element differs")


def test_bool_lists_equal_each_return() raises:
    """Catches a Bool comparator that checks only lengths: a direction flip
    in the second key must compare unequal."""
    var a: List[Bool] = [False, True]
    var same: List[Bool] = [False, True]
    var shorter: List[Bool] = [False]
    var differs: List[Bool] = [False, False]
    assert_true(_bool_lists_equal(a, same))
    assert_false(_bool_lists_equal(a, shorter), "length mismatch")
    assert_false(_bool_lists_equal(a, differs), "second element differs")


def test_triples_equal_each_component() raises:
    """Catches a triple comparison that skips a component: partition keys,
    order keys and directions each decide inequality on their own."""
    var p: List[String] = ["g"]
    var o: List[String] = ["t"]
    var d: List[Bool] = [True]
    var p2: List[String] = ["h"]
    var o2: List[String] = ["u"]
    var d2: List[Bool] = [False]
    assert_true(_triples_equal(p, o, d, p, o, d))
    assert_false(_triples_equal(p, o, d, p2, o, d), "partition keys differ")
    assert_false(_triples_equal(p, o, d, p, o2, d), "order keys differ")
    assert_false(_triples_equal(p, o, d, p, o, d2), "directions differ")


def test_is_window_or_alias_window() raises:
    """Catches an Alias arm that answers True for any alias: an alias of a
    plain column is not a window."""
    assert_true(_is_window_or_alias_window(col("v").rank().over("g")))
    assert_true(_is_window_or_alias_window(col("v").rank().over("g").alias("r")))
    assert_false(_is_window_or_alias_window(Expr.col_ref("v")))
    assert_false(_is_window_or_alias_window(Expr.alias(Expr.col_ref("v"), "w")))


def test_a_project_aliasing_a_plain_column_is_not_rewritten() raises:
    """Catches the same defect end to end: Project([g, v AS w]) has no window,
    so no PartitionBy may appear under it."""
    var exprs = ExprArray()
    exprs.append(Expr.col_ref("g"))
    exprs.append(Expr.alias(Expr.col_ref("v"), "w"))
    var plan = LogicalPlan.project(exprs^, _scan2("g", "v"))
    var out = optimize_window_rewrite(plan^)
    assert_equal(Int(out.tag), Int(PLAN_PROJECT))
    assert_equal(Int(out.project_data_ref().child[].tag), Int(PLAN_SCAN))


# =============================================================================
# Output-name preview
# =============================================================================


def test_preview_name_uses_the_alias() raises:
    """Catches a preview that ignores the alias: the user's name wins over the
    generated `_w<idx>_<func>` name."""
    assert_equal(_preview_partition_expr_name(_pexpr(PF_RANK, "rk"), 3), String("rk"))


def test_preview_name_for_every_function_tag() raises:
    """Catches a wrong or swapped base name in any `elif` of the tag chain
    (and in the final `else`, PF_MAX). The generated name must equal what
    `partition_expr_output_field` gives the PartitionBy column, or the
    Project's col_ref names a column that does not exist."""
    var tags: List[UInt8] = [
        PF_ROW_NUMBER, PF_RANK, PF_DENSE_RANK, PF_PERCENT_RANK, PF_CUME_DIST,
        PF_NTILE, PF_LAG, PF_LEAD, PF_FIRST_VALUE, PF_LAST_VALUE,
        PF_NTH_VALUE, PF_SUM, PF_COUNT, PF_AVG, PF_MIN, PF_MAX,
    ]
    var bases: List[String] = [
        "row_number", "rank", "dense_rank", "percent_rank", "cume_dist",
        "ntile", "lag", "lead", "first_value", "last_value",
        "nth_value", "sum", "count", "avg", "min", "max",
    ]
    for i in range(len(tags)):
        assert_equal(
            _preview_partition_expr_name(_pexpr(tags[i], ""), 2),
            String("_w2_") + bases[i],
        )


# =============================================================================
# Pattern C predicate
# =============================================================================


def test_sort_redundancy_predicate_each_return() raises:
    """One call per return of `_sort_keys_redundant_after_partition_by`.
    Catches: a missing length guard, an empty Sort treated as redundant, an
    unordered PartitionBy treated as ordered, a missing `pb_desc` length
    guard, a Sort longer than (P ++ O) accepted, partition keys taken as
    anything but ASC, a key or direction compared on the wrong side of the
    P/O boundary, a NULL placement left out of the comparison."""
    var e: List[String] = []
    var eb: List[Bool] = []
    var a: List[String] = ["a"]
    var b: List[String] = ["b"]
    var ab: List[String] = ["a", "b"]
    var ac: List[String] = ["a", "c"]
    var abc: List[String] = ["a", "b", "c"]
    var f: List[Bool] = [False]
    var t: List[Bool] = [True]
    var ff: List[Bool] = [False, False]
    var ft: List[Bool] = [False, True]
    var tf: List[Bool] = [True, False]
    var fff: List[Bool] = [False, False, False]
    # Lengths of keys and directions differ.
    assert_false(_sort_keys_redundant_after_partition_by(a, eb, f, a, b, f))
    # Empty Sort.
    assert_false(_sort_keys_redundant_after_partition_by(e, eb, eb, a, b, f))
    # No partition and no order keys: the sink does not sort.
    assert_false(_sort_keys_redundant_after_partition_by(a, f, f, e, e, eb))
    # Order keys and their directions differ in length.
    assert_false(_sort_keys_redundant_after_partition_by(a, f, f, a, b, eb))
    # Sort longer than (P ++ O).
    assert_false(_sort_keys_redundant_after_partition_by(abc, fff, fff, a, b, f))
    # A partition key sorted DESC: the sink sorts it ASC.
    assert_false(_sort_keys_redundant_after_partition_by(a, t, f, a, b, f))
    # A partition key that is not the first partition key.
    assert_false(_sort_keys_redundant_after_partition_by(b, f, f, a, b, f))
    # Exact (P ++ O) with the order key's direction.
    assert_true(_sort_keys_redundant_after_partition_by(ab, ft, ff, a, b, t))
    # The order key differs.
    assert_false(_sort_keys_redundant_after_partition_by(ac, ft, ff, a, b, t))
    # The order key's direction differs.
    assert_false(_sort_keys_redundant_after_partition_by(ab, ff, ff, a, b, t))
    # No partition keys: the first Sort key is checked against order key 0.
    assert_true(_sort_keys_redundant_after_partition_by(b, t, f, e, b, t))
    # Keys and NULL placements differ in length.
    assert_false(_sort_keys_redundant_after_partition_by(ab, ft, f, a, b, t))
    # A partition key's NULL placement is not the sink's derived one.
    assert_false(_sort_keys_redundant_after_partition_by(ab, ft, tf, a, b, t))
    # The order key's NULL placement is not the sink's derived one.
    assert_false(_sort_keys_redundant_after_partition_by(ab, ft, ft, a, b, t))


# =============================================================================
# The recurse-and-rebuild walk, one arm per node kind
# =============================================================================


def test_filter_arm_descends_and_keeps_the_predicate() raises:
    """Catches a Filter arm that does not descend, or rebuilds with a
    different predicate."""
    var pred = Expr.binary(
        BIN_GT, Expr.col_ref("rk"), Expr.literal(ScalarValue.from_int(1))
    )
    var plan = LogicalPlan.filter(pred^, _window_project("g", "v", "rk"))
    var out = optimize_window_rewrite(plan^)
    assert_equal(Int(out.tag), Int(PLAN_FILTER))
    ref fd = out.filter_data_ref()
    assert_equal(Int(fd.predicate.binary_op()), Int(BIN_GT))
    _assert_lowered(fd.child[], "filter child")


def test_aggregate_arm_keeps_every_agg_child_slot() raises:
    """Catches an Aggregate rebuild that drops the group keys, or that copies
    an AggExpr through its 3-argument constructor and loses `child1` (the
    second argument of a bivariate aggregate such as corr)."""
    var gb = ExprArray()
    gb.append(Expr.col_ref("g"))
    var aggs = AggExprArray()
    aggs.append(AggExpr(
        AGG_CORR,
        Optional(Expr.col_ref("v")),
        Optional(Expr.col_ref("rk")),
        Optional(String("c")),
    ))
    var plan = LogicalPlan.aggregate(gb^, aggs^, _window_project("g", "v", "rk"))
    var out = optimize_window_rewrite(plan^)
    assert_equal(Int(out.tag), Int(PLAN_AGGREGATE))
    ref ad = out._aggregate.value()[]
    assert_equal(len(ad.group_by), 1)
    assert_equal(ad.group_by[0].col_ref_name(), String("g"))
    assert_equal(len(ad.agg_exprs), 1)
    assert_equal(Int(ad.agg_exprs[0].func), Int(AGG_CORR))
    assert_true(Bool(ad.agg_exprs[0].child1), "child1 survives the rebuild")
    assert_equal(ad.agg_exprs[0].child1.value().col_ref_name(), String("rk"))
    _assert_lowered(ad.child[], "aggregate child")


def test_join_arm_descends_both_sides_and_keeps_the_residual() raises:
    """Catches a Join arm that descends one side only, or drops the keys, the
    join type, the algorithm hint or the residual predicate on rebuild."""
    var lo: List[String] = ["g"]
    var ro: List[String] = ["k"]
    var resid = Optional[OwnedPointer[Expr]](OwnedPointer(
        Expr.binary(BIN_LT, Expr.col_ref("v"), Expr.col_ref("w"))
    ))
    var plan = LogicalPlan.join(
        _window_project("g", "v", "rk"),
        _window_project("k", "w", "rk2"),
        lo^, ro^, JOIN_INNER, JOIN_ALGO_HASH, resid^,
    )
    var out = optimize_window_rewrite(plan^)
    assert_equal(Int(out.tag), Int(PLAN_JOIN))
    ref jd = out.join_data_ref()
    assert_equal(Int(jd.join_type), Int(JOIN_INNER))
    assert_equal(Int(jd.algo_hint), Int(JOIN_ALGO_HASH))
    assert_equal(jd.left_on[0], String("g"))
    assert_equal(jd.right_on[0], String("k"))
    assert_true(jd.has_residual(), "residual survives the rebuild")
    assert_equal(Int(jd.residual.value()[].binary_op()), Int(BIN_LT))
    _assert_lowered(jd.left[], "join left")
    _assert_lowered(jd.right[], "join right")


def test_join_arm_without_a_residual_adds_none() raises:
    """Catches an inverted residual guard: a join built without a residual
    must come back without one."""
    var lo: List[String] = ["g"]
    var ro: List[String] = ["k"]
    var plan = LogicalPlan.join(
        _window_project("g", "v", "rk"), _scan2("k", "w"), lo^, ro^, JOIN_INNER,
    )
    var out = optimize_window_rewrite(plan^)
    ref jd = out.join_data_ref()
    assert_false(jd.has_residual())
    _assert_lowered(jd.left[], "join left")
    assert_equal(Int(jd.right[].tag), Int(PLAN_SCAN))


def test_limit_arm_keeps_n_and_offset() raises:
    """Catches a Limit rebuild that drops the OFFSET (a LIMIT 7 OFFSET 3
    becoming LIMIT 7) or does not descend."""
    var plan = LogicalPlan.limit(7, _window_project("g", "v", "rk"), offset=3)
    var out = optimize_window_rewrite(plan^)
    assert_equal(Int(out.tag), Int(PLAN_LIMIT))
    ref ld = out.limit_data_ref()
    assert_equal(ld.n, 7)
    assert_equal(ld.offset, 3)
    _assert_lowered(ld.child[], "limit child")


def test_distinct_arm_keeps_its_columns() raises:
    """Catches a Distinct rebuild that turns DISTINCT ON (g) into a distinct
    over every column."""
    var cols: List[String] = ["g"]
    var plan = LogicalPlan.distinct(
        Optional[List[String]](cols^), _window_project("g", "v", "rk")
    )
    var out = optimize_window_rewrite(plan^)
    assert_equal(Int(out.tag), Int(PLAN_DISTINCT))
    ref dd = out._distinct.value()[]
    assert_true(Bool(dd.columns), "columns survive the rebuild")
    assert_equal(len(dd.columns.value()), 1)
    assert_equal(dd.columns.value()[0], String("g"))
    _assert_lowered(dd.child[], "distinct child")


def test_distinct_arm_over_all_columns_stays_all_columns() raises:
    """Catches the reverse: a distinct over every column must not gain a
    column list."""
    var plan = LogicalPlan.distinct(None, _window_project("g", "v", "rk"))
    var out = optimize_window_rewrite(plan^)
    ref dd = out._distinct.value()[]
    assert_false(Bool(dd.columns))
    _assert_lowered(dd.child[], "distinct child")


def test_topn_arm_keeps_keys_directions_and_n() raises:
    """Catches a TopN rebuild that loses its keys, directions or N."""
    var keys: List[String] = ["v"]
    var desc: List[Bool] = [True]
    var plan = LogicalPlan.topn(keys^, desc^, 5, _window_project("g", "v", "rk"))
    var out = optimize_window_rewrite(plan^)
    assert_equal(Int(out.tag), Int(PLAN_TOPN))
    ref td = out._topn.value()[]
    assert_equal(td.n, 5)
    assert_equal(td.keys[0], String("v"))
    assert_equal(td.descending[0], True)
    _assert_lowered(td.child[], "topn child")


def test_partition_topn_arm_keeps_func_over_fetch_and_rank_column() raises:
    """Catches a PartitionTopN rebuild that resets `func` to ROW_NUMBER,
    `over_fetch_k` to its default, or drops the emitted rank column (the
    downstream operator that reads it then fails)."""
    var pk: List[String] = ["g"]
    var sk: List[String] = ["v"]
    var desc: List[Bool] = [True]
    var plan = LogicalPlan.partition_topn(
        pk^, sk^, desc^, 4, _window_project("g", "v", "rk"),
        PF_RANK, 20, Optional[String](String("rk_out")),
    )
    var out = optimize_window_rewrite(plan^)
    assert_equal(Int(out.tag), Int(PLAN_PARTITION_TOPN))
    ref ptd = out._partition_topn.value()[]
    assert_equal(ptd.k, 4)
    assert_equal(Int(ptd.func), Int(PF_RANK))
    assert_equal(ptd.over_fetch_k, 20)
    assert_equal(ptd.partition_keys[0], String("g"))
    assert_equal(ptd.sort_keys[0], String("v"))
    assert_equal(ptd.descending[0], True)
    assert_true(Bool(ptd.output_rank_col_name), "rank column survives")
    assert_equal(ptd.output_rank_col_name.value(), String("rk_out"))
    _assert_lowered(ptd.child[], "partition_topn child")


def test_partition_topn_arm_without_a_rank_column_adds_none() raises:
    """Catches an inverted rank-column guard: a node that emits no rank column
    must not gain one."""
    var pk: List[String] = ["g"]
    var sk: List[String] = ["v"]
    var desc: List[Bool] = [False]
    var plan = LogicalPlan.partition_topn(
        pk^, sk^, desc^, 2, _window_project("g", "v", "rk"),
    )
    var out = optimize_window_rewrite(plan^)
    ref ptd = out._partition_topn.value()[]
    assert_false(Bool(ptd.output_rank_col_name))
    assert_equal(Int(ptd.func), Int(PF_ROW_NUMBER))
    _assert_lowered(ptd.child[], "partition_topn child")


def test_asof_join_arm_keeps_every_field() raises:
    """Catches an AsofJoin rebuild that descends one side only or drops any
    of its fields: keys, as-of columns, strategy, tolerance, and the four
    pre-sort hints (a dropped hint costs a sort; an invented one gives wrong
    rows)."""
    var lk: List[String] = ["g"]
    var rk: List[String] = ["k"]
    var lsk: List[String] = ["g"]
    var lsd: List[Bool] = [False]
    var rsk: List[String] = ["k"]
    var rsd: List[Bool] = [True]
    var plan = LogicalPlan.asof_join(
        _window_project("g", "v", "rk"),
        _window_project("k", "w", "rk2"),
        lk^, rk^,
        String("v"), String("w"),
        ASOF_FORWARD, AsofTolerance.int64(5),
        lsk^, lsd^, rsk^, rsd^,
    )
    var out = optimize_window_rewrite(plan^)
    assert_equal(Int(out.tag), Int(PLAN_ASOF_JOIN))
    ref aj = out._asof_join.value()[]
    assert_equal(aj.left_keys[0], String("g"))
    assert_equal(aj.right_keys[0], String("k"))
    assert_equal(aj.left_asof, String("v"))
    assert_equal(aj.right_asof, String("w"))
    assert_equal(Int(aj.strategy), Int(ASOF_FORWARD))
    assert_equal(Int(aj.tolerance.tag), Int(ASOF_TOL_INT64))
    assert_equal(Int(aj.tolerance.int_val), 5)
    assert_equal(aj.left_sort_keys[0], String("g"))
    assert_equal(aj.left_sort_desc[0], False)
    assert_equal(aj.right_sort_keys[0], String("k"))
    assert_equal(aj.right_sort_desc[0], True)
    _assert_lowered(aj.left[], "asof left")
    _assert_lowered(aj.right[], "asof right")


def test_a_union_is_returned_as_is() raises:
    """Pins what the walk does with a node kind it has no arm for (a Union):
    it returns the node unchanged and does NOT descend, so a window Project
    under it stays a Project over the Scan. Catches the pass-through being
    replaced by a raise or by a rebuild that loses the branches."""
    var children = List[OwnedPointer[LogicalPlan]]()
    children.append(OwnedPointer(_window_project("g", "v", "rk")))
    children.append(OwnedPointer(_window_project("g", "v", "rk")))
    var plan = LogicalPlan.union(
        children^,
        Schema.from_fields_2(
            Field("g", ArrowType.INT64, False),
            Field("v", ArrowType.INT64, False),
        ),
    )
    var out = optimize_window_rewrite(plan^)
    assert_equal(Int(out.tag), Int(PLAN_UNION))
    assert_equal(out.union_data_ref().num_children(), 2)
    ref branch = out.union_data_ref().children[0][]
    assert_equal(Int(branch.tag), Int(PLAN_PROJECT))
    assert_equal(Int(branch.project_data_ref().child[].tag), Int(PLAN_SCAN))


# =============================================================================
# Pattern A: two windows shadowing one child name; Pattern B: the recursion
# under a mismatched outer PartitionBy
# =============================================================================


def test_two_windows_shadowing_one_name_get_distinct_internal_names() raises:
    """Two windows aliased to the SAME child column name, `max(v) OVER (g) AS
    v` and `min(v) OVER (g) AS v`, share one triple and so land in ONE
    PartitionBy. Each must be computed under its own internal name, and each
    Project entry must alias back ITS OWN window.

    Catches the Project position being dropped from the internal shadow name:
    both windows would then get the same internal name, the PartitionBy would
    carry two columns of that name, and the second Project entry's col_ref
    would resolve to the first window (the max, not the min)."""
    var exprs = ExprArray()
    exprs.append(Expr.col_ref("g"))
    exprs.append(col("v").max().over("g").alias("v"))
    exprs.append(col("v").min().over("g").alias("v"))
    var plan = LogicalPlan.project(exprs^, _scan2("g", "v"))

    var out = optimize_window_rewrite(plan^)

    assert_equal(Int(out.tag), Int(PLAN_PROJECT))
    ref pd = out.project_data_ref()
    assert_equal(Int(pd.child[].tag), Int(PLAN_PARTITION_BY))
    ref pb = pd.child[].partition_by_data_ref()
    assert_equal(len(pb.partition_exprs), 2, "one triple, one PartitionBy")
    assert_equal(Int(pb.partition_exprs[0].func), Int(PF_MAX))
    assert_equal(Int(pb.partition_exprs[1].func), Int(PF_MIN))
    var max_name = pb.partition_exprs[0].alias_name.copy()
    var min_name = pb.partition_exprs[1].alias_name.copy()
    assert_true(max_name != String("v"), "max shadowed under an internal name")
    assert_true(min_name != String("v"), "min shadowed under an internal name")
    assert_true(
        max_name != min_name,
        "two windows shadowing one name need two internal names",
    )
    # Each Project entry reads its own window and is aliased back to `v`.
    assert_equal(Int(pd.exprs[1].tag), Int(EXPR_ALIAS))
    assert_equal(pd.exprs[1].alias_name(), String("v"))
    assert_equal(pd.exprs[1].alias_child_ref().col_ref_name(), max_name)
    assert_equal(Int(pd.exprs[2].tag), Int(EXPR_ALIAS))
    assert_equal(pd.exprs[2].alias_name(), String("v"))
    assert_equal(pd.exprs[2].alias_child_ref().col_ref_name(), min_name)
    # The PartitionBy output is [g, v, <max>, <min>]: the names resolve once.
    ref pb_schema = pd.child[].output_schema
    assert_equal(pb_schema.num_columns(), 4)
    assert_equal(pb_schema.field_name(2), max_name)
    assert_equal(pb_schema.field_name(3), min_name)


def _pb(
    pk: List[String],
    ok: List[String],
    desc: List[Bool],
    var pexpr: PartitionExpr,
    var child: LogicalPlan,
) raises -> LogicalPlan:
    """A PartitionBy with one PartitionExpr over `child`."""
    var px = List[PartitionExpr]()
    px.append(pexpr^)
    return LogicalPlan.partition_by(
        pk.copy(), ok.copy(), desc.copy(), px^, child^,
    )


def test_mismatched_outer_partition_by_still_fuses_the_pair_below() raises:
    """PB_x(PB_y(PB_y(scan))): the outer triple (PARTITION BY v) differs from
    the inner two (PARTITION BY g ORDER BY v), which match each other. The
    outer node is kept, and the rule must recurse into its child, where the
    matching pair fuses into ONE node (inner pexpr first).

    Catches the mismatch branch rebuilding the outer node over an un-rewritten
    copy of its child: three PartitionBy nodes would remain."""
    var g: List[String] = ["g"]
    var v: List[String] = ["v"]
    var none: List[String] = []
    var asc: List[Bool] = [False]
    var no_desc: List[Bool] = []
    var rn = PartitionExpr.row_number().with_alias(String("rn"))
    var rk = PartitionExpr.rank().with_alias(String("rk"))
    var rx = PartitionExpr.rank().with_alias(String("rx"))
    var inner = _pb(g, v, asc, rn^, _scan2("g", "v"))
    var middle = _pb(g, v, asc, rk^, inner^)
    var plan = _pb(v, none, no_desc, rx^, middle^)

    var out = optimize_window_rewrite(plan^)

    assert_equal(Int(out.tag), Int(PLAN_PARTITION_BY))
    ref outer = out.partition_by_data_ref()
    assert_equal(outer.partition_keys[0], String("v"), "outer node kept")
    assert_equal(len(outer.partition_exprs), 1)
    assert_equal(outer.partition_exprs[0].alias_name, String("rx"))
    assert_equal(
        Int(outer.child[].tag), Int(PLAN_PARTITION_BY), "fused pair below"
    )
    ref fused = outer.child[].partition_by_data_ref()
    assert_equal(len(fused.partition_exprs), 2, "the matching pair fused")
    assert_equal(fused.partition_exprs[0].alias_name, String("rn"))
    assert_equal(fused.partition_exprs[1].alias_name, String("rk"))
    assert_equal(Int(fused.child[].tag), Int(PLAN_SCAN), "nothing left below")


def test_mismatched_outer_partition_by_lowers_a_window_below() raises:
    """PB_x(PB_y(Project with a window)): the triples differ, so the rule
    must recurse into the inner PartitionBy and lower the window Project
    under it. Catches the same missing recursion as the test above, through
    Pattern A instead of Pattern B."""
    var g: List[String] = ["g"]
    var v: List[String] = ["v"]
    var none: List[String] = []
    var asc: List[Bool] = [False]
    var no_desc: List[Bool] = []
    var rn = PartitionExpr.row_number().with_alias(String("rn"))
    var rx = PartitionExpr.rank().with_alias(String("rx"))
    var inner = _pb(g, v, asc, rn^, _window_project("g", "v", "wk"))
    var plan = _pb(v, none, no_desc, rx^, inner^)

    var out = optimize_window_rewrite(plan^)

    assert_equal(Int(out.tag), Int(PLAN_PARTITION_BY))
    ref mid = out.partition_by_data_ref().child[]
    assert_equal(Int(mid.tag), Int(PLAN_PARTITION_BY))
    _assert_lowered(mid.partition_by_data_ref().child[], "under the inner PB")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
