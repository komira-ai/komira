# =============================================================================
# test_optimizer_sum_rewrite_gates -- SUM(x + C) -> SUM(x) + C * COUNT(x)
# =============================================================================
#
# The rewrite on its own (its pairing with aggregate de-duplication is tested
# where that pass lands). Each test pins one of the four gates in the module
# header, the exact shape of the replacement, or one arm of the plan walk:
#   1. 0-key aggregates only;  2. integral columns and integer offsets only;
#   3. a plain column aggregand;  4. at least one non-zero offset.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM, AGG_COUNT, AGG_MAX
from komira_plan_expr.expr import (
    Expr,
    EXPR_BINARY_OP,
    EXPR_COL_REF,
    EXPR_LITERAL,
    BIN_ADD,
    BIN_SUB,
    BIN_MUL,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.udf_data import UdfData, UDF_KIND_AGG, DTAG_I64
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    AggGroupTopK,
    PLAN_AGGREGATE,
    PLAN_PROJECT,
    PLAN_FILTER,
    SOURCE_PARQUET,
    JOIN_INNER,
)

from komira_optimizer.optimizer_sum_rewrite import (
    rewrite_sum_of_offset,
    rewrite_sum_of_offset_inplace,
)


# =============================================================================
# Fixtures
# =============================================================================


def _scan() -> LogicalPlan:
    """One column per dtype the gate distinguishes, plus a float and a uint64."""
    var sb = SchemaBuilder()
    sb.add_field(Field("rw", ArrowType.INT64, True))
    sb.add_field(Field("i8", ArrowType.INT8, True))
    sb.add_field(Field("i16", ArrowType.INT16, True))
    sb.add_field(Field("i32", ArrowType.INT32, True))
    sb.add_field(Field("u8", ArrowType.UINT8, True))
    sb.add_field(Field("u16", ArrowType.UINT16, True))
    sb.add_field(Field("u32", ArrowType.UINT32, True))
    sb.add_field(Field("u64", ArrowType.UINT64, True))
    sb.add_field(Field("f", ArrowType.FLOAT64, True))
    return LogicalPlan.scan("hits.parquet", SOURCE_PARQUET, sb.build())


def _lit(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _plus(name: String, k: Int) -> Expr:
    return Expr.binary(BIN_ADD, Expr.col_ref(name), _lit(k))


def _sum_of(var e: Expr, name: String) -> AggExpr:
    return AggExpr(AGG_SUM, Optional[Expr](e^), Optional[String](name))


def _agg(var aggs: AggExprArray) -> LogicalPlan:
    return LogicalPlan.aggregate(ExprArray(), aggs^, _scan())


def _one(var a: AggExpr) -> AggExprArray:
    var aggs = AggExprArray()
    aggs.append(a^)
    return aggs^


def _names(imm plan: LogicalPlan) -> List[String]:
    var out = List[String]()
    for i in range(plan.output_schema.num_columns()):
        out.append(plan.output_schema.field_name(i))
    return out^


def _declines(var aggs: AggExprArray) raises:
    """The rewrite leaves this 0-key aggregate exactly as built."""
    var plan = _agg(aggs^)
    var before = plan.structural_hash()
    var out = rewrite_sum_of_offset(plan^)
    assert_equal(out.tag, PLAN_AGGREGATE)
    assert_equal(out.structural_hash(), before)


def _folds(var aggs: AggExprArray) raises -> LogicalPlan:
    """The rewrite fires: a Project over a new Aggregate, names unchanged."""
    var plan = _agg(aggs^)
    var before = _names(plan)
    var out = rewrite_sum_of_offset(plan^)
    assert_equal(out.tag, PLAN_PROJECT)
    var after = _names(out)
    assert_equal(len(after), len(before))
    for i in range(len(before)):
        assert_equal(after[i], before[i])
    return out^


def _offset_of(imm out: LogicalPlan, i: Int) raises -> Int:
    """The C of projection i, shaped `alias(sum + C * count)`."""
    ref e = out.project_data_ref().exprs[i].alias_child_ref()
    assert_equal(e.tag, EXPR_BINARY_OP)
    assert_equal(Int(e.binary_op()), Int(BIN_ADD))
    ref term = e.binary_right_ref()
    assert_equal(Int(term.binary_op()), Int(BIN_MUL))
    assert_equal(term.binary_left_ref().tag, EXPR_LITERAL)
    return Int(term.binary_left_ref().literal_value().int_val)


# =============================================================================
# The replacement's exact shape
# =============================================================================


def test_bare_sum_and_offset_sum_become_sum_count_and_a_projection() raises:
    # sum(rw) AS s0, sum(rw + 5) AS s1 -> Aggregate[SUM(rw), SUM(rw),
    # COUNT(rw)] under Project[__sr_s0 AS s0, __sr_s1 + 5 * __sr_c1 AS s1].
    # Catches: COUNT(*) instead of COUNT(rw) (wrong over NULLs), the offset
    # dropped or sign-flipped, an output name moved.
    var aggs = AggExprArray()
    aggs.append(_sum_of(Expr.col_ref("rw"), String("s0")))
    aggs.append(_sum_of(_plus(String("rw"), 5), String("s1")))
    var out = _folds(aggs^)
    ref agg = out.project_data_ref().child[]
    assert_equal(agg.tag, PLAN_AGGREGATE)
    ref ad = agg.aggregate_data_ref()
    assert_equal(len(ad.group_by), 0)
    assert_equal(len(ad.agg_exprs), 3)
    assert_equal(Int(ad.agg_exprs[0].func), Int(AGG_SUM))
    assert_equal(ad.agg_exprs[0].child.value().col_ref_name(), String("rw"))
    assert_equal(Int(ad.agg_exprs[1].func), Int(AGG_SUM))
    assert_equal(Int(ad.agg_exprs[2].func), Int(AGG_COUNT))
    assert_equal(ad.agg_exprs[2].child.value().col_ref_name(), String("rw"))
    assert_equal(ad.agg_exprs[2].alias_name.value(), String("__sr_c1"))
    # Projection 0 is a rename of the bare SUM; projection 1 adds C * COUNT.
    ref p0 = out.project_data_ref().exprs[0].alias_child_ref()
    assert_equal(p0.tag, EXPR_COL_REF)
    assert_equal(p0.col_ref_name(), String("__sr_s0"))
    assert_equal(_offset_of(out, 1), 5)


def test_an_untouched_aggregate_keeps_its_place_and_name() raises:
    # max(rw) AS mx between two foldable sums. Catches: an untouched
    # aggregate dropped, moved, or published under its private name.
    var aggs = AggExprArray()
    aggs.append(_sum_of(_plus(String("rw"), 1), String("a")))
    aggs.append(AggExpr(AGG_MAX, Optional[Expr](Expr.col_ref("rw")), Optional[String]("mx")))
    aggs.append(_sum_of(_plus(String("rw"), 2), String("b")))
    var out = _folds(aggs^)
    ref ad = out.project_data_ref().child[].aggregate_data_ref()
    assert_equal(len(ad.agg_exprs), 5)
    assert_equal(Int(ad.agg_exprs[2].func), Int(AGG_MAX))
    assert_equal(ad.agg_exprs[2].alias_name.value(), String("__sr_k1"))
    ref p1 = out.project_data_ref().exprs[1].alias_child_ref()
    assert_equal(p1.col_ref_name(), String("__sr_k1"))
    assert_equal(_offset_of(out, 0), 1)
    assert_equal(_offset_of(out, 2), 2)


def test_the_three_offset_spellings() raises:
    # col + C, C + col and col - C. Catches: the literal-on-the-left arm
    # dropped, or a subtraction folded with +C (an answer off by 2*C*count).
    var a1 = AggExprArray()
    a1.append(_sum_of(Expr.binary(BIN_ADD, _lit(3), Expr.col_ref("rw")), String("s")))
    assert_equal(_offset_of(_folds(a1^), 0), 3)
    var a2 = AggExprArray()
    a2.append(_sum_of(Expr.binary(BIN_SUB, Expr.col_ref("rw"), _lit(5)), String("s")))
    assert_equal(_offset_of(_folds(a2^), 0), -5)
    # An alias around the column is looked through.
    var a3 = AggExprArray()
    a3.append(
        _sum_of(
            Expr.binary(BIN_ADD, Expr.alias(Expr.col_ref("rw"), String("z")), _lit(4)),
            String("s"),
        )
    )
    var out3 = _folds(a3^)
    assert_equal(_offset_of(out3, 0), 4)
    ref ad = out3.project_data_ref().child[].aggregate_data_ref()
    assert_equal(ad.agg_exprs[0].child.value().col_ref_name(), String("rw"))


def test_every_signed_and_narrow_unsigned_integer_folds() raises:
    # Catches: a dtype dropped from the integral gate (that column's sum
    # would keep its computed input).
    var cols = List[String]()
    cols.append(String("i8"))
    cols.append(String("i16"))
    cols.append(String("i32"))
    cols.append(String("rw"))
    cols.append(String("u8"))
    cols.append(String("u16"))
    cols.append(String("u32"))
    for i in range(len(cols)):
        var out = _folds(_one(_sum_of(_plus(cols[i], 1), String("s"))))
        assert_equal(_offset_of(out, 0), 1)


# =============================================================================
# The refusals
# =============================================================================


def test_float_and_uint64_columns_are_declined() raises:
    # Gate 2. Catches: a float fold (IEEE rounding changes the answer) or a
    # uint64 fold (mixed-sign promotion).
    _declines(_one(_sum_of(_plus(String("f"), 1), String("s"))))
    _declines(_one(_sum_of(_plus(String("u64"), 1), String("s"))))
    # An unknown column is declined, on both the offset and the bare form.
    _declines(_one(_sum_of(_plus(String("nope"), 1), String("s"))))
    var two = AggExprArray()
    two.append(_sum_of(Expr.col_ref("nope"), String("a")))
    two.append(_sum_of(_plus(String("rw"), 1), String("b")))
    var out = _folds(two^)
    ref ad = out.project_data_ref().child[].aggregate_data_ref()
    assert_equal(ad.agg_exprs[0].alias_name.value(), String("__sr_k0"))


def test_offsets_beyond_the_int32_magnitude_are_declined() raises:
    # The residual-overflow guard. Catches: the bound dropped on either
    # spelling. 2147483647 is the largest folded magnitude.
    _declines(_one(_sum_of(_plus(String("rw"), 2147483648), String("s"))))
    _declines(_one(_sum_of(_plus(String("rw"), -2147483648), String("s"))))
    _declines(
        _one(_sum_of(Expr.binary(BIN_ADD, _lit(2147483648), Expr.col_ref("rw")), String("s")))
    )
    _declines(
        _one(_sum_of(Expr.binary(BIN_ADD, _lit(-2147483648), Expr.col_ref("rw")), String("s")))
    )
    var at_max = _folds(_one(_sum_of(_plus(String("rw"), 2147483647), String("s"))))
    assert_equal(_offset_of(at_max, 0), 2147483647)


def test_aggregand_shapes_that_are_declined() raises:
    # Gate 3 and the shape checks. Catches: C - col folded with the sign on
    # the wrong term; col * C, col + col, col + 1.5, col_idx + C, or a
    # computed aggregand admitted; the literal-left arm admitting a
    # non-foldable or oversized column.
    _declines(_one(_sum_of(Expr.binary(BIN_SUB, _lit(5), Expr.col_ref("rw")), String("s"))))
    _declines(_one(_sum_of(Expr.binary(BIN_MUL, Expr.col_ref("rw"), _lit(2)), String("s"))))
    _declines(
        _one(_sum_of(Expr.binary(BIN_ADD, Expr.col_ref("rw"), Expr.col_ref("i8")), String("s")))
    )
    _declines(
        _one(
            _sum_of(
                Expr.binary(BIN_ADD, Expr.col_ref("rw"), Expr.literal(ScalarValue.from_float(1.5))),
                String("s"),
            )
        )
    )
    _declines(_one(_sum_of(Expr.binary(BIN_ADD, Expr.col_idx(0), _lit(1)), String("s"))))
    _declines(_one(_sum_of(Expr.binary(BIN_ADD, _lit(1), Expr.col_ref("f")), String("s"))))
    _declines(_one(_sum_of(_lit(7), String("s"))))


def test_aggregates_that_are_not_a_one_input_sum_are_declined() raises:
    # Catches: MAX(x + C), SUM with no input, or a two-input SUM treated as
    # SUM(x + C).
    _declines(_one(AggExpr(AGG_MAX, Optional[Expr](_plus(String("rw"), 1)), Optional[String]("m"))))
    _declines(_one(AggExpr(AGG_SUM, Optional[Expr](None), Optional[String]("s"))))
    _declines(
        _one(
            AggExpr(
                AGG_SUM,
                Optional[Expr](_plus(String("rw"), 1)),
                Optional[Expr](Expr.col_ref("i8")),
                Optional[String]("s"),
            )
        )
    )
    # The third and fourth input slots are checked too.
    var c2 = _sum_of(_plus(String("rw"), 1), String("s"))
    c2.child2 = Optional[Expr](Expr.col_ref("i8"))
    _declines(_one(c2^))
    var c3 = _sum_of(_plus(String("rw"), 1), String("s"))
    c3.child3 = Optional[Expr](Expr.col_ref("i8"))
    _declines(_one(c3^))


def test_bare_sums_alone_are_declined() raises:
    # Gate 4. Catches: converting sum(x) into sum(x) plus a pointless Project.
    var aggs = AggExprArray()
    aggs.append(_sum_of(Expr.col_ref("rw"), String("a")))
    aggs.append(_sum_of(Expr.col_ref("i8"), String("b")))
    _declines(aggs^)
    _declines(AggExprArray())


def test_grouped_topk_and_udf_aggregates_are_declined() raises:
    # Gate 1 and the two node flags. Catches: a grouped fold (the COUNT
    # becomes a real per-group accumulator), a fold that loses the
    # `group_topk` hint, or one that rebuilds a UDF aggregate without its UDF.
    var gb = ExprArray()
    gb.append(Expr.col_ref("i8"))
    var grouped = LogicalPlan.aggregate(
        gb^, _one(_sum_of(_plus(String("rw"), 1), String("s"))), _scan()
    )
    var gh = grouped.structural_hash()
    var gout = rewrite_sum_of_offset(grouped^)
    assert_equal(gout.tag, PLAN_AGGREGATE)
    assert_equal(gout.structural_hash(), gh)

    var tk = _agg(_one(_sum_of(_plus(String("rw"), 1), String("s"))))
    var order = List[String]()
    order.append(String("s"))
    var desc = List[Bool]()
    desc.append(True)
    tk._aggregate.value()[].group_topk = Optional(AggGroupTopK(order^, desc^, 3))
    rewrite_sum_of_offset_inplace(tk)
    assert_equal(tk.tag, PLAN_AGGREGATE)

    var in_cols = List[Tuple[String, UInt8]]()
    in_cols.append((String("rw"), DTAG_I64))
    var out_cols = List[Tuple[String, UInt8]]()
    out_cols.append((String("u"), DTAG_I64))
    var udf = OwnedPointer(
        UdfData(UDF_KIND_AGG, String("my_agg"), in_cols^, out_cols^, 1, 1)
    )
    var with_udf = LogicalPlan.aggregate_with_udf(
        ExprArray(), _one(_sum_of(_plus(String("rw"), 1), String("s"))), _scan(), udf^
    )
    rewrite_sum_of_offset_inplace(with_udf)
    assert_equal(with_udf.tag, PLAN_AGGREGATE)


# =============================================================================
# The plan walk
# =============================================================================


def _eligible() -> LogicalPlan:
    return _agg(_one(_sum_of(_plus(String("rw"), 1), String("s"))))


def _wrap(kind: Int) -> LogicalPlan:
    var keys = List[String]()
    keys.append(String("s"))
    var desc = List[Bool]()
    desc.append(False)
    if kind == 0:
        return LogicalPlan.filter(Expr.col_ref("s"), _eligible())
    if kind == 1:
        var pe = ExprArray()
        pe.append(Expr.col_ref("s"))
        return LogicalPlan.project(pe^, _eligible())
    if kind == 2:
        return LogicalPlan.sort(keys^, desc^, _eligible())
    if kind == 3:
        return LogicalPlan.limit(3, _eligible())
    if kind == 4:
        return LogicalPlan.distinct(None, _eligible())
    if kind == 5:
        return LogicalPlan.topn(keys^, desc^, 2, _eligible())
    if kind == 6:
        # An Aggregate over an eligible Aggregate: the child is settled first.
        var aggs = AggExprArray()
        aggs.append(AggExpr(AGG_MAX, Optional[Expr](Expr.col_ref("s")), Optional[String]("m")))
        return LogicalPlan.aggregate(ExprArray(), aggs^, _eligible())
    var lk = List[String]()
    lk.append(String("s"))
    var rk = List[String]()
    rk.append(String("s"))
    return LogicalPlan.join(_eligible(), _eligible(), lk^, rk^, JOIN_INNER)


def _child_tag(imm plan: LogicalPlan, kind: Int) -> UInt8:
    if kind == 0:
        return plan.filter_data_ref().child[].tag
    if kind == 1:
        return plan.project_data_ref().child[].tag
    if kind == 2:
        return plan.sort_data_ref().child[].tag
    if kind == 3:
        return plan.limit_data_ref().child[].tag
    if kind == 4:
        return plan.distinct_data_ref().child[].tag
    if kind == 5:
        return plan.topn_data_ref().child[].tag
    if kind == 6:
        return plan.aggregate_data_ref().child[].tag
    return plan.join_data_ref().left[].tag


def test_the_walk_reaches_an_aggregate_under_every_node_kind() raises:
    # Filter, Project, Sort, Limit, Distinct, TopN, Aggregate and both sides
    # of a Join. Catches: a recursion arm dropped (the aggregate below that
    # kind keeps its computed input).
    for kind in range(8):
        var plan = _wrap(kind)
        rewrite_sum_of_offset_inplace(plan)
        assert_equal(_child_tag(plan, kind), PLAN_PROJECT)
        if kind == 7:
            assert_equal(plan.join_data_ref().right[].tag, PLAN_PROJECT)
    # A scan is a leaf.
    var scan = _scan()
    var h = scan.structural_hash()
    rewrite_sum_of_offset_inplace(scan)
    assert_equal(scan.structural_hash(), h)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
