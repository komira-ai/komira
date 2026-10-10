# =============================================================================
# test_optimizer_topn_below_project_rule.mojo -- Rule 14b, plan-shape only.
# =============================================================================
#
#     TopN(keys, n, Project(P, Aggregate))  ==>  Project(P, TopN(keys', n, Aggregate))
#
# The rule fires only when its tie-order proof goes through (see the section
# header in optimizer_misc.mojo). These tests drive every gate of
# `_build_topn_below_project` and every arm of its walk with plans built in
# memory, and assert the SHAPE: fired (Project over TopN over Aggregate, keys
# translated, placement carried) or declined (the plan comes back as built).
# An answer-on-ties oracle needs a TopN executor, which is not in this tree;
# it is an integration test, not this module's coverage.
#
# The fixtures are the shapes the rule was written for (ClickBench Q35 and
# Q39, a renamed string key) plus one falsifier per gate.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT, AGG_SUM
from komira_plan_expr.expr import (
    Expr,
    EXPR_COL_REF,
    BIN_ADD,
    BIN_SUB,
    BIN_MUL,
    UN_NEGATE,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.udf_data import UdfData, UDF_KIND_MAP
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    JOIN_INNER,
    SOURCE_PARQUET,
)
from komira_optimizer.optimizer_misc import (
    push_topn_below_project,
    _colref_source,
    _schema_index,
    _name_in,
    _is_float_type,
    _row_local_shape,
)


# -----------------------------------------------------------------------------
# fixtures
# -----------------------------------------------------------------------------


def _scan(names: List[String], types: List[ArrowType]) -> LogicalPlan:
    var sb = SchemaBuilder()
    for i in range(len(names)):
        sb.add_field(Field(names[i], types[i], True))
    return LogicalPlan.scan("hits.parquet", SOURCE_PARQUET, sb.build())


def _agg(
    keys: List[String], types: List[ArrowType], count_name: String
) -> LogicalPlan:
    """`Aggregate[keys..., count(*) AS count_name]` over a scan of `keys`."""
    var scan = _scan(keys, types)
    var gb = ExprArray()
    for i in range(len(keys)):
        gb.append(Expr.col_ref(keys[i]))
    var aggs = AggExprArray()
    var no_child: Optional[Expr] = None
    aggs.append(AggExpr(AGG_COUNT, no_child^, Optional(count_name)))
    return LogicalPlan.aggregate(gb^, aggs^, scan^)


def _lit(n: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(n))


def _minus(col: String, k: Int) -> Expr:
    return Expr.binary(BIN_SUB, Expr.col_ref(col), _lit(k))


def _strs(a: String) -> List[String]:
    var l = List[String]()
    l.append(a)
    return l^


def _strs2(a: String, b: String) -> List[String]:
    var l = _strs(a)
    l.append(b)
    return l^


def _bools(a: Bool) -> List[Bool]:
    var l = List[Bool]()
    l.append(a)
    return l^


def _bools2(a: Bool, b: Bool) -> List[Bool]:
    var l = _bools(a)
    l.append(b)
    return l^


def _topn(
    var child: LogicalPlan, keys: List[String], desc: List[Bool], n: Int
) -> LogicalPlan:
    return LogicalPlan.topn(keys.copy(), desc.copy(), n, child^)


def _q35_topn() -> LogicalPlan:
    """TopN [c DESC, client_ip] n=3 over
    Project [client_ip, client_ip-1 AS c1, client_ip-2 AS c2, client_ip-3 AS c3, c]
    over Aggregate [client_ip; count(*) AS c]."""
    var agg = _agg(_strs("client_ip"), [ArrowType.INT64], "c")
    var p = ExprArray()
    p.append(Expr.col_ref("client_ip"))
    p.append(Expr.alias(_minus("client_ip", 1), "c1"))
    p.append(Expr.alias(_minus("client_ip", 2), "c2"))
    p.append(Expr.alias(_minus("client_ip", 3), "c3"))
    p.append(Expr.col_ref("c"))
    var proj = LogicalPlan.project(p^, agg^)
    return _topn(proj^, _strs2("c", "client_ip"), _bools2(True, False), 3)


def _rename_string_key_topn() -> LogicalPlan:
    """TopN [c DESC] over Project [url AS u, c] over Aggregate [url; count(*) c].
    Not total (a STRING is no tie-break column), served on identity."""
    var agg = _agg(_strs("url"), [ArrowType.STRING], "c")
    var p = ExprArray()
    p.append(Expr.alias(Expr.col_ref("url"), "u"))
    p.append(Expr.col_ref("c"))
    var proj = LogicalPlan.project(p^, agg^)
    return _topn(proj^, _strs("c"), _bools(True), 3)


def _ab_agg() -> LogicalPlan:
    return _agg(_strs2("a", "b"), [ArrowType.INT64, ArrowType.INT64], "c")


def _rewritten(imm plan: LogicalPlan) raises -> LogicalPlan:
    return push_topn_below_project(plan.copy())


def _fired(imm out: LogicalPlan) raises -> Bool:
    return (
        out.tag == PLAN_PROJECT
        and out._project.value()[].child[].tag == PLAN_TOPN
        and out._project.value()[].child[]._topn.value()[].child[].tag
        == PLAN_AGGREGATE
    )


def _declined(imm out: LogicalPlan) raises -> Bool:
    """Came back as built: TopN over Project."""
    return out.tag == PLAN_TOPN and out._topn.value()[].child[].tag == PLAN_PROJECT


def _topn_keys(imm out: LogicalPlan) raises -> List[String]:
    return out._project.value()[].child[]._topn.value()[].keys.copy()


# -----------------------------------------------------------------------------
# fires
# -----------------------------------------------------------------------------


def test_q35_fires_and_drops_the_restored_keys() raises:
    # Widened above: (c, client_ip, c1, c2, c3); c1..c3 are functions of
    # client_ip, which precedes them, so they are dropped. (c, client_ip) holds
    # the only group key and no float: total. Defect: the FD drop or the total
    # arm broken (no fire), or the keys / n / output schema changed.
    var before = _q35_topn()
    var after = _rewritten(before)
    assert_true(_fired(after))
    var keys = _topn_keys(after)
    assert_equal(len(keys), 2)
    assert_equal(keys[0], "c")
    assert_equal(keys[1], "client_ip")
    ref td = after._project.value()[].child[]._topn.value()[]
    assert_equal(td.n, 3)
    assert_true(td.descending[0])
    assert_false(td.descending[1])
    assert_equal(after.output_schema.num_columns(), 5)
    for i in range(5):
        assert_equal(
            after.output_schema.field_name(i), before.output_schema.field_name(i)
        )


def test_renamed_string_key_fires_on_identity() raises:
    # Arm (i): nothing dropped, the two lists identical. Defect: the identity
    # arm removed (only total orders served) declines this.
    var after = _rewritten(_rename_string_key_topn())
    assert_true(_fired(after))
    var keys = _topn_keys(after)
    assert_equal(len(keys), 1)
    assert_equal(keys[0], "c")


def test_renamed_order_by_key_translates_to_the_aggregate_column() raises:
    # `a AS x ... ORDER BY x DESC`: the key below the Project is `a`, DESC.
    # Defect: the key not translated (TopN' names a column the Aggregate lacks)
    # or its direction lost.
    var p = ExprArray()
    p.append(Expr.alias(Expr.col_ref("a"), "x"))
    p.append(Expr.col_ref("b"))
    p.append(Expr.col_ref("c"))
    var proj = LogicalPlan.project(p^, _ab_agg())
    var after = _rewritten(_topn(proj^, _strs("x"), _bools(True), 3))
    assert_true(_fired(after))
    var keys = _topn_keys(after)
    assert_equal(len(keys), 1)
    assert_equal(keys[0], "a")
    assert_true(after._project.value()[].child[]._topn.value()[].descending[0])


def test_second_name_for_a_compared_column_is_dropped() raises:
    # Project [a, a AS a2, b, c] ORDER BY c DESC widens to (c, a, a2, b); a2 is
    # a second name for a and orders nothing. Defect: the duplicate kept (the
    # lists then differ and the rule declines), or kept as an explicit key.
    var p = ExprArray()
    p.append(Expr.col_ref("a"))
    p.append(Expr.alias(Expr.col_ref("a"), "a2"))
    p.append(Expr.col_ref("b"))
    p.append(Expr.col_ref("c"))
    var proj = LogicalPlan.project(p^, _ab_agg())
    var after = _rewritten(_topn(proj^, _strs("c"), _bools(True), 3))
    assert_true(_fired(after))
    assert_equal(len(_topn_keys(after)), 1)


def test_explicit_nulls_first_survives_the_move() raises:
    # NULL placement must survive. Defect: TopN' rebuilt with the derived placement.
    var agg = _agg(_strs("client_ip"), [ArrowType.INT64], "c")
    var p = ExprArray()
    p.append(Expr.alias(Expr.col_ref("client_ip"), "ip"))
    p.append(Expr.col_ref("c"))
    var proj = LogicalPlan.project(p^, agg^)
    var nf = List[Bool]()
    nf.append(True)
    nf.append(False)
    var before = LogicalPlan.topn(
        _strs2("c", "ip"), _bools2(True, False), 3, proj^, Optional(nf^)
    )
    var after = _rewritten(before)
    assert_true(_fired(after))
    ref td = after._project.value()[].child[]._topn.value()[]
    assert_equal(len(td.nulls_first), 2)
    assert_true(td.nulls_first[0])
    assert_false(td.nulls_first[1])
    assert_equal(td.keys[1], "client_ip")


def test_rule_is_idempotent() raises:
    # A second run sees TopN over Aggregate and changes nothing. Defect: the
    # child-is-a-Project gate removed (it would try to rewrite again).
    var once = _rewritten(_q35_topn())
    assert_true(_fired(once))
    var twice = push_topn_below_project(once.copy())
    assert_true(_fired(twice))
    assert_equal(len(_topn_keys(twice)), 2)


def test_the_walk_reaches_a_site_under_every_parent_kind() raises:
    # Defect: a parent arm of the walk that does not recurse leaves its site.
    var l = push_topn_below_project(LogicalPlan.limit(2, _q35_topn()))
    assert_true(_fired(l._limit.value()[].child[]), "Limit arm")
    var f = push_topn_below_project(
        LogicalPlan.filter(Expr.literal(ScalarValue.from_bool(True)), _q35_topn())
    )
    assert_true(_fired(f._filter.value()[].child[]), "Filter arm")
    var pe = ExprArray()
    pe.append(Expr.col_ref("c"))
    var p = push_topn_below_project(LogicalPlan.project(pe^, _q35_topn()))
    assert_true(_fired(p._project.value()[].child[]), "Project arm")
    var gb = ExprArray()
    gb.append(Expr.col_ref("c"))
    var a = push_topn_below_project(
        LogicalPlan.aggregate(gb^, AggExprArray(), _q35_topn())
    )
    assert_true(_fired(a._aggregate.value()[].child[]), "Aggregate arm")
    var s = push_topn_below_project(
        LogicalPlan.sort(_strs("c"), _bools(False), _q35_topn())
    )
    assert_true(_fired(s._sort.value()[].child[]), "Sort arm")
    var none: Optional[List[String]] = None
    var d = push_topn_below_project(LogicalPlan.distinct(none^, _q35_topn()))
    assert_true(_fired(d._distinct.value()[].child[]), "Distinct arm")
    var t = push_topn_below_project(_topn(_q35_topn(), _strs("c"), _bools(True), 1))
    assert_true(_fired(t._topn.value()[].child[]), "TopN child recursed first")
    var lk = List[String]()
    lk.append("c")
    var rk = List[String]()
    rk.append("c")
    var j = push_topn_below_project(
        LogicalPlan.join(_q35_topn(), _q35_topn(), lk^, rk^, JOIN_INNER)
    )
    assert_true(_fired(j._join.value()[].left[]), "Join left")
    assert_true(_fired(j._join.value()[].right[]), "Join right")
    var sc = push_topn_below_project(_scan(_strs("a"), [ArrowType.INT64]))
    assert_equal(Int(sc.tag), Int(PLAN_SCAN))


# -----------------------------------------------------------------------------
# declines: one per gate
# -----------------------------------------------------------------------------


def test_declines_when_the_project_carries_a_udf() raises:
    # A UDF Project cannot be re-evaluated over `n` rows. Defect: the udf gate
    # removed (the rebuild through `LogicalPlan.project` would also drop it).
    var ic = List[Tuple[String, UInt8]]()
    ic.append(("c", UInt8(2)))
    var oc = List[Tuple[String, UInt8]]()
    oc.append(("y", UInt8(2)))
    var udf = UdfData(
        kind=UDF_KIND_MAP,
        name=String("f"),
        input_columns=ic^,
        output_columns=oc^,
        operator_factory_id=UInt32(9301),
        call_site_salt=UInt32(5),
        registered_handle_id=Optional(Int(3)),
    )
    var p = ExprArray()
    p.append(Expr.alias(Expr.col_ref("client_ip"), "ip"))
    p.append(Expr.col_ref("c"))
    var agg = _agg(_strs("client_ip"), [ArrowType.INT64], "c")
    var proj = LogicalPlan.project_with_udf(p^, agg^, OwnedPointer[UdfData](udf^))
    var after = _rewritten(_topn(proj^, _strs("c"), _bools(True), 3))
    assert_true(_declined(after))
    assert_true(after._topn.value()[].child[].has_udf())


def test_declines_without_an_aggregate_below() raises:
    # Over a scan no group key makes the comparator total. Defect: the
    # Aggregate gate removed.
    var scan = _scan(_strs2("a", "b"), [ArrowType.INT64, ArrowType.INT64])
    var p = ExprArray()
    p.append(Expr.alias(Expr.col_ref("a"), "x"))
    p.append(Expr.col_ref("b"))
    var proj = LogicalPlan.project(p^, scan^)
    assert_true(_declined(_rewritten(_topn(proj^, _strs("b"), _bools(True), 3))))


def test_declines_over_a_global_aggregate() raises:
    # No group key at all. Defect: the `n_group_keys < 1` gate removed.
    var scan = _scan(_strs("a"), [ArrowType.INT64])
    var aggs = AggExprArray()
    var none: Optional[Expr] = None
    aggs.append(AggExpr(AGG_COUNT, none^, Optional(String("c"))))
    var agg = LogicalPlan.aggregate(ExprArray(), aggs^, scan^)
    var p = ExprArray()
    p.append(Expr.alias(Expr.col_ref("c"), "n"))
    var proj = LogicalPlan.project(p^, agg^)
    assert_true(_declined(_rewritten(_topn(proj^, _strs("n"), _bools(True), 1))))


def test_declines_on_malformed_key_lists() raises:
    # No explicit key; a direction list of another length; a placement list
    # of another length. Defect: any of the three length checks removed (the
    # rebuild would index past a list).
    var p1 = ExprArray()
    p1.append(Expr.alias(Expr.col_ref("a"), "x"))
    p1.append(Expr.col_ref("c"))
    var proj1 = LogicalPlan.project(p1^, _ab_agg())
    assert_true(_declined(_rewritten(_topn(proj1^, List[String](), List[Bool](), 3))))
    var p2 = ExprArray()
    p2.append(Expr.alias(Expr.col_ref("a"), "x"))
    p2.append(Expr.col_ref("c"))
    var proj2 = LogicalPlan.project(p2^, _ab_agg())
    assert_true(_declined(_rewritten(_topn(proj2^, _strs2("c", "x"), _bools(True), 3))))
    var p3 = ExprArray()
    p3.append(Expr.alias(Expr.col_ref("a"), "x"))
    p3.append(Expr.col_ref("c"))
    var proj3 = LogicalPlan.project(p3^, _ab_agg())
    var nf = List[Bool]()
    nf.append(False)
    nf.append(False)
    var t3 = LogicalPlan.topn(_strs("c"), _bools(True), 3, proj3^, Optional(nf^))
    assert_true(_declined(_rewritten(t3)))


def test_declines_on_a_duplicate_output_name() raises:
    # Two Project outputs under one name. Defect: the duplicate-name gate
    # removed.
    var p = ExprArray()
    p.append(Expr.alias(Expr.col_ref("a"), "x"))
    p.append(Expr.alias(Expr.col_ref("b"), "x"))
    p.append(Expr.col_ref("c"))
    var proj = LogicalPlan.project(p^, _ab_agg())
    assert_true(_declined(_rewritten(_topn(proj^, _strs("c"), _bools(True), 3))))


def test_declines_when_a_pass_through_names_no_aggregate_column() raises:
    # `zz AS z` reads a column the Aggregate does not output. Defect: the
    # source lookup skipped (TopN' would name a missing column).
    var p = ExprArray()
    p.append(Expr.alias(Expr.col_ref("zz"), "z"))
    p.append(Expr.col_ref("c"))
    var proj = LogicalPlan.project(p^, _ab_agg())
    assert_true(_declined(_rewritten(_topn(proj^, _strs("c"), _bools(True), 3))))


def test_declines_on_a_pure_pass_through_project() raises:
    # Same-name col-refs only: moving the TopN buys nothing. Defect: the
    # `moves_work` gate removed.
    var agg = _agg(_strs("client_ip"), [ArrowType.INT64], "c")
    var p = ExprArray()
    p.append(Expr.col_ref("c"))
    p.append(Expr.col_ref("client_ip"))
    var proj = LogicalPlan.project(p^, agg^)
    var before = _topn(proj^, _strs2("c", "client_ip"), _bools2(True, False), 3)
    assert_true(_declined(_rewritten(before)))


def test_declines_on_a_nested_non_row_local_entry() raises:
    # `sqrt(client_ip) + 1 AS r`: the top tag is a BINARY_OP, the leg is not
    # allow-listed. Defect: a top-tag check in place of the whole-tree walk.
    var agg = _agg(_strs("client_ip"), [ArrowType.INT64], "c")
    var p = ExprArray()
    p.append(Expr.alias(Expr.col_ref("client_ip"), "ip"))
    p.append(Expr.col_ref("c"))
    p.append(
        Expr.alias(Expr.binary(BIN_ADD, Expr.sqrt(Expr.col_ref("client_ip")), _lit(1)), "r")
    )
    var proj = LogicalPlan.project(p^, agg^)
    assert_true(_declined(_rewritten(_topn(proj^, _strs("c"), _bools(True), 3))))


def test_declines_on_a_key_the_project_does_not_output() raises:
    # Defect: an unknown key translated as if it were a column.
    var p = ExprArray()
    p.append(Expr.alias(Expr.col_ref("a"), "x"))
    p.append(Expr.col_ref("c"))
    var proj = LogicalPlan.project(p^, _ab_agg())
    assert_true(_declined(_rewritten(_topn(proj^, _strs("nope"), _bools(True), 3))))


def test_declines_on_a_computed_order_by_key() raises:
    # ORDER BY c1 DESC, c1 = client_ip - 1: nothing precedes it, it orders
    # rows, and it cannot be named below. Defect: computed entries dropped
    # without checking their inputs precede them.
    var agg = _agg(_strs("client_ip"), [ArrowType.INT64], "c")
    var p = ExprArray()
    p.append(Expr.col_ref("client_ip"))
    p.append(Expr.alias(_minus("client_ip", 1), "c1"))
    p.append(Expr.col_ref("c"))
    var proj = LogicalPlan.project(p^, agg^)
    assert_true(_declined(_rewritten(_topn(proj^, _strs("c1"), _bools(True), 3))))


def test_declines_when_every_explicit_key_is_dropped() raises:
    # ORDER BY a literal column: it reads no column, so it is dropped, and no
    # explicit key is left. Defect: the empty-key gate removed (a TopN with no
    # keys).
    var p = ExprArray()
    p.append(Expr.alias(_lit(1), "one"))
    p.append(Expr.alias(Expr.col_ref("a"), "x"))
    p.append(Expr.col_ref("c"))
    var proj = LogicalPlan.project(p^, _ab_agg())
    assert_true(_declined(_rewritten(_topn(proj^, _strs("one"), _bools(False), 3))))


def test_declines_on_a_float_input_to_a_dropped_entry() raises:
    # f - 1 over a FLOAT64 f: -0.0 == 0.0 but a function of them need not
    # agree. Defect: the float check on a dropped entry's inputs removed.
    var agg = _agg(_strs("f"), [ArrowType.FLOAT64], "c")
    var p = ExprArray()
    p.append(Expr.col_ref("f"))
    p.append(Expr.alias(_minus("f", 1), "g"))
    p.append(Expr.col_ref("c"))
    var proj = LogicalPlan.project(p^, agg^)
    assert_true(_declined(_rewritten(_topn(proj^, _strs2("c", "f"), _bools2(True, False), 3))))


def test_declines_on_a_float_key_when_an_entry_was_dropped() raises:
    # (m DESC, a, a1) with m = sum(v) FLOAT64: a1 dropped, so only arm (ii)
    # could serve, and a float in the list is not total. Defect: the float
    # check in the TOTAL loop removed.
    var scan = _scan(_strs2("a", "v"), [ArrowType.INT64, ArrowType.FLOAT64])
    var gb = ExprArray()
    gb.append(Expr.col_ref("a"))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional(Expr.col_ref("v")), Optional(String("m"))))
    var agg = LogicalPlan.aggregate(gb^, aggs^, scan^)
    var p = ExprArray()
    p.append(Expr.col_ref("a"))
    p.append(Expr.alias(Expr.binary(BIN_ADD, Expr.col_ref("a"), _lit(1)), "a1"))
    p.append(Expr.col_ref("m"))
    var proj = LogicalPlan.project(p^, agg^)
    assert_true(_declined(_rewritten(_topn(proj^, _strs("m"), _bools(True), 3))))


def test_declines_on_a_reordering_project() raises:
    # Project [b AS bb, a AS aa, c]: above it the tie-break is (c, bb, aa) =
    # (c, b, a); below it (c, a, b). Both total, different orders: a tie at
    # the cut keeps a different row. Defect: `starts_with` not checked.
    var p = ExprArray()
    p.append(Expr.alias(Expr.col_ref("b"), "bb"))
    p.append(Expr.alias(Expr.col_ref("a"), "aa"))
    p.append(Expr.col_ref("c"))
    var proj = LogicalPlan.project(p^, _ab_agg())
    assert_true(_declined(_rewritten(_topn(proj^, _strs("c"), _bools(True), 3))))


def test_declines_when_not_total_and_not_identical() raises:
    # Project [a, a*2 AS a2, c] over Aggregate [a, s STRING; count c], ORDER BY
    # c DESC: above (c, a, a2), a2 dropped -> (c, a); the group key s is not in
    # the list, so not total, and a drop rules out identity. Defect: the
    # group-key membership loop removed (it would call this total).
    var agg = _agg(_strs2("a", "s"), [ArrowType.INT64, ArrowType.STRING], "c")
    var p = ExprArray()
    p.append(Expr.col_ref("a"))
    p.append(Expr.alias(Expr.binary(BIN_MUL, Expr.col_ref("a"), _lit(2)), "a2"))
    p.append(Expr.col_ref("c"))
    var proj = LogicalPlan.project(p^, agg^)
    assert_true(_declined(_rewritten(_topn(proj^, _strs("c"), _bools(True), 3))))


# -----------------------------------------------------------------------------
# helpers, directly
# -----------------------------------------------------------------------------


def test_colref_source() raises:
    # Defect: an alias of a computed expr reported as a pass-through.
    assert_equal(_colref_source(Expr.col_ref("a")), "a")
    assert_equal(_colref_source(Expr.alias(Expr.col_ref("a"), "x")), "a")
    assert_equal(_colref_source(Expr.alias(_minus("a", 1), "x")), "")
    assert_equal(_colref_source(_lit(1)), "")


def test_schema_index_and_name_in() raises:
    # Defect: a missing name raises or returns a valid index.
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    sb.add_field(Field("b", ArrowType.INT64, True))
    var s = sb.build()
    assert_equal(_schema_index(s, "b"), 1)
    assert_equal(_schema_index(s, "z"), -1)
    assert_true(_name_in(_strs2("a", "b"), "b"))
    assert_false(_name_in(_strs2("a", "b"), "c"))


def test_is_float_type() raises:
    # Defect: a float width missed (its -0.0 / NaN hazard admitted).
    assert_true(_is_float_type(ArrowType.FLOAT16))
    assert_true(_is_float_type(ArrowType.FLOAT32))
    assert_true(_is_float_type(ArrowType.FLOAT64))
    assert_false(_is_float_type(ArrowType.INT64))


def test_row_local_shape_is_a_whole_tree_allow_list() raises:
    # Defect: an allow-listed tag refused, or a non-listed one admitted at any
    # depth.
    assert_true(_row_local_shape(Expr.col_ref("a")))
    assert_true(_row_local_shape(_lit(1)))
    assert_true(_row_local_shape(Expr.alias(Expr.col_ref("a"), "x")))
    assert_true(_row_local_shape(Expr.cast(Expr.col_ref("a"), DType.int32)))
    assert_true(_row_local_shape(Expr.unary(UN_NEGATE, Expr.col_ref("a"))))
    assert_true(_row_local_shape(_minus("a", 1)))
    assert_false(_row_local_shape(Expr.sqrt(Expr.col_ref("a"))))
    assert_false(_row_local_shape(Expr.cast(Expr.sqrt(Expr.col_ref("a")), DType.int32)))
    assert_false(_row_local_shape(Expr.binary(BIN_ADD, _lit(1), Expr.sqrt(Expr.col_ref("a")))))
    assert_false(_row_local_shape(Expr.binary(BIN_ADD, Expr.sqrt(Expr.col_ref("a")), _lit(1))))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
