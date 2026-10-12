# =============================================================================
# test_plan_wire_udf_walk.mojo — the UDF gate finds a call wherever a plan can
# hold one (`plan_wire_check_udfs`, plan_wire_udf_check.mojo)
# =============================================================================
#
# The gate is a walk, and a walk's failure mode is an arm that does not
# descend: a call hidden under that expression or node is never checked. So
# every test here hides ONE wrong call (a SCALAR declared over float64, passed
# the int64 column `a`) in one position, and requires the gate to find it
# (OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH). A mutant that drops any arm, or reads
# only one child of a two-child arm, leaves its position unchecked and that
# position's assertion red. The leaves, which hold no expression, pass; a tag
# with no arm at all is refused rather than passed.
#
# The plans are built in process, which is also what this proves of the API:
# the gate is not reachable only through the decoders.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM, AGG_CORR, AGG_UDF
from komira_plan_expr.expr import (
    Expr,
    WhenCaseData,
    EXPR_BETWEEN,
    EXPR_SORT_KEY,
    BIN_ADD,
    BIN_GT,
    UN_NOT,
    STR_LIKE,
    REGEXP_LIKE,
    EXTRACT_YEAR,
)
from komira_plan_expr.partition_expr import (
    PartitionExpr,
    PartitionFrame,
    PF_ROW_NUMBER,
    FRAME_UNITS_ROWS,
    FRAME_BOUND_UNBOUNDED_PRECEDING,
    FRAME_BOUND_CURRENT_ROW,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.udf_data import UDF_NULL_PROPAGATE, UDF_STABILITY_STABLE
from komira_plan_expr.udf_type import UdfType
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    AsofTolerance,
    ASOF_BACKWARD,
    CORR_KIND_EXISTS,
    EXCHANGE_KIND_GATHER,
    JOIN_INNER,
    JOIN_ALGO_AUTO,
)
from komira_plan_ir.udf_ref import (
    UdfCode,
    UdfRef,
    UDF_REF_KIND_SCALAR,
    UDF_REF_KIND_MAP_BATCHES_FRAME,
    CODE_FORM_PACKAGE,
)

from komira_plan_wire import (
    plan_wire_check_udfs,
    OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH,
    OPTIMIZED_UDF_AGGREGATE_OUTSIDE_AGGREGATE,
    OPTIMIZED_UDF_KIND_ARM_MISMATCH,
    OPTIMIZED_UDF_UNDECLARED,
)


# ---- fixtures -----------------------------------------------------------------------


def _f64() -> UdfType:
    return UdfType("y", ArrowType.FLOAT64, DType.float64, True)


def _udfs() -> List[UdfRef]:
    var args = List[UdfType]()
    args.append(UdfType("x", ArrowType.FLOAT64, DType.float64, True))
    var out = List[UdfRef]()
    out.append(
        UdfRef(
            UDF_REF_KIND_SCALAR, UdfCode("komira/python", CODE_FORM_PACKAGE, "m:f"),
            args^, Optional(_f64()), UDF_STABILITY_STABLE, UDF_NULL_PROPAGATE,
        )
    )
    # Entry 1: a frame over the scan's two columns, for the frame positions.
    var cols = List[UdfType]()
    cols.append(UdfType("a", ArrowType.INT64, DType.int64, True))
    cols.append(UdfType("b", ArrowType.FLOAT64, DType.float64, True))
    var ret_cols = List[UdfType]()
    ret_cols.append(UdfType("a", ArrowType.INT64, DType.int64, True))
    ret_cols.append(UdfType("b", ArrowType.FLOAT64, DType.float64, True))
    out.append(
        UdfRef(
            UDF_REF_KIND_MAP_BATCHES_FRAME,
            UdfCode("komira/python", CODE_FORM_PACKAGE, "m:g"),
            cols^,
            Optional(UdfType("out", ArrowType.STRUCT, Field("out", ArrowType.STRUCT, True).dtype, True, ret_cols^)),
            UDF_STABILITY_STABLE, UDF_NULL_PROPAGATE,
        )
    )
    return out^


def _bad() -> Expr:
    """The wrong call: float64 declared, the int64 column `a` passed."""
    var args = List[Expr]()
    args.append(Expr.col_ref("a"))
    return Expr.udf_apply(0, _f64(), args^)


def _c() -> Expr:
    return Expr.col_ref("b")


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    sb.add_field(Field("b", ArrowType.FLOAT64, True))
    return sb.build()


def _scan() -> LogicalPlan:
    return LogicalPlan.scan(
        String("/nonexistent/walk.parquet"), 0, _schema(),
        Optional[List[String]](None), Optional[Expr](None), Optional[Int](None),
    )


def _project(var e: Expr) raises -> LogicalPlan:
    var exprs = ExprArray()
    exprs.append(e^)
    return LogicalPlan.project(exprs^, _scan())


def _gate(p: LogicalPlan) raises -> String:
    try:
        plan_wire_check_udfs(p, _udfs())
    except e:
        return String(e)
    return String("")


def _found(p: LogicalPlan, where: String) raises:
    var msg = _gate(p)
    assert_true(
        msg.startswith(OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH),
        where + ": the call hidden here was not checked; got: " + msg,
    )


def _two(var a: Expr, var b: Expr) -> List[Expr]:
    var out = List[Expr]()
    out.append(a^)
    out.append(b^)
    return out^


# ---- expressions ------------------------------------------------------------------------


def test_a_call_under_every_one_child_expression_is_found() raises:
    """Defect: a one-child arm that does not descend."""
    _found(_project(Expr.unary(UN_NOT, _bad())), "UNARY_OP")
    _found(_project(Expr.cast(_bad(), DType.float32)), "CAST")
    _found(_project(Expr.alias(_bad(), "z")), "ALIAS")
    _found(_project(Expr.string_op(STR_LIKE, _bad(), "p%")), "STRING_OP")
    _found(_project(Expr.regexp(REGEXP_LIKE, _bad(), "p")), "REGEXP")
    _found(_project(Expr.substring(_bad(), 1, 2)), "SUBSTRING")
    _found(_project(Expr.upper(_bad())), "STRING_FN")
    _found(_project(Expr.udf_call("f", None, ArrowType.FLOAT64, ArrowType.FLOAT64, _bad())), "UDF_CALL")
    _found(_project(Expr.extract(EXTRACT_YEAR, _bad())), "EXTRACT")
    _found(_project(Expr.sqrt(_bad())), "MATH_FN")
    _found(_project(Expr.agg_fn(AGG_SUM, _bad())), "AGG_FN")
    var vals = List[ScalarValue]()
    vals.append(ScalarValue.from_int(1))
    _found(_project(Expr.in_list_node(_bad(), vals^)), "IN_LIST")
    _found(_project(Expr.struct_field(_bad(), "f")), "STRUCT_FIELD")
    _found(_project(Expr.struct_field_idx(_bad(), 0)), "STRUCT_FIELD_IDX")
    _found(_project(Expr.json_extract_string(_bad(), "$.a")), "JSON_EXTRACT")


def test_a_call_under_either_child_of_a_two_child_expression_is_found() raises:
    """Defect: a two-child arm that reads only one side."""
    _found(_project(Expr.binary(BIN_ADD, _bad(), _c())), "BINARY_OP left")
    _found(_project(Expr.binary(BIN_ADD, _c(), _bad())), "BINARY_OP right")
    _found(_project(Expr.atan2(_bad(), _c())), "MATH_FN2 left")
    _found(_project(Expr.atan2(_c(), _bad())), "MATH_FN2 right")
    _found(_project(Expr.map_get(_bad(), _c())), "MAP_GET parent")
    _found(_project(Expr.map_get(_c(), _bad())), "MAP_GET key")


def test_a_call_under_every_n_child_expression_is_found() raises:
    """Defect: an N-child arm that reads only its first child."""
    var cargs = List[Expr]()
    cargs.append(_c())
    cargs.append(_c())
    cargs.append(_bad())
    _found(_project(Expr.concat(cargs^)), "STRING_FN_N third argument")
    # The outer call is right: one argument, of the declared float64 type
    # (the nested call's own type). The nested call passes two arguments for
    # one, which is found only if the outer call's arguments are walked.
    var nested_args = List[Expr]()
    nested_args.append(Expr.udf_apply(0, _f64(), _two(_c(), _bad())))
    var ok_outer = Expr.udf_apply(0, _f64(), nested_args^)
    var msg = _gate(_project(ok_outer^))
    assert_true(msg.startswith(OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH), "UDF_APPLY nested argument: " + msg)
    var cond = List[WhenCaseData]()
    cond.append(WhenCaseData(_bad(), _c()))
    _found(_project(Expr.when(cond^, _c())), "WHEN condition")
    var res = List[WhenCaseData]()
    res.append(WhenCaseData(_c(), _bad()))
    _found(_project(Expr.when(res^, _c())), "WHEN result")
    var dflt = List[WhenCaseData]()
    dflt.append(WhenCaseData(_c(), _c()))
    _found(_project(Expr.when(dflt^, _bad())), "WHEN default")


def test_a_call_inside_a_subquery_plan_is_found() raises:
    """Defect: the subquery arm not entering the inner plan, where a call is
    checked against that plan's own inputs."""
    var refs = List[String]()
    refs.append(String("a"))
    var sub = Expr.correlated_subquery(_project(_bad()), refs^, CORR_KIND_EXISTS)
    _found(_project(sub^), "CORRELATED_SUBQUERY inner plan")


def test_leaves_pass_and_an_unknown_tag_is_refused() raises:
    """Defects: a leaf arm that raises, and an unknown tag passed as if it held
    no call."""
    assert_equal(_gate(_project(Expr.col_ref("a"))), "", "COL_REF")
    assert_equal(_gate(_project(Expr.col_idx(0))), "", "COL_IDX")
    assert_equal(_gate(_project(Expr.literal(ScalarValue.from_int(1)))), "", "LITERAL")
    var frame = PartitionFrame(
        FRAME_UNITS_ROWS, FRAME_BOUND_UNBOUNDED_PRECEDING, Int64(0),
        FRAME_BOUND_CURRENT_ROW, Int64(0),
    )
    assert_equal(_gate(_project(Expr.window_fn(PF_ROW_NUMBER, String("a"), 0, frame^))), "", "WINDOW_FN")
    assert_equal(_gate(_project(Expr(EXPR_BETWEEN))), "", "BETWEEN")
    assert_equal(_gate(_project(Expr(EXPR_SORT_KEY))), "", "SORT_KEY")
    var unknown = LogicalPlan.filter(Expr(UInt8(200)), _scan())
    assert_true(_gate(unknown).startswith(OPTIMIZED_UDF_KIND_ARM_MISMATCH), "expression tag 200")
    var shell = LogicalPlan(UInt8(16), _schema())
    assert_true(_gate(shell).startswith(OPTIMIZED_UDF_KIND_ARM_MISMATCH), "plan tag 16")


# ---- plan nodes ------------------------------------------------------------------------


def test_a_call_in_every_expression_slot_of_a_node_is_found() raises:
    """Defect: a node arm that skips one of its expression slots: a filter's
    predicate, an aggregate's key or any of its four measure slots, a join's
    residual, a frame's grouping keys."""
    _found(LogicalPlan.filter(_bad(), _scan()), "FILTER predicate")
    var gb = ExprArray()
    gb.append(_bad())
    _found(LogicalPlan.aggregate(gb^, AggExprArray(), _scan()), "AGGREGATE key")
    for slot in range(4):
        var a = AggExpr(AGG_CORR, Optional(_c()), Optional(_c()), None)
        if slot == 0:
            a.child = Optional(_bad())
        elif slot == 1:
            a.child1 = Optional(_bad())
        elif slot == 2:
            a.child2 = Optional(_bad())
        else:
            a.child3 = Optional(_bad())
        var aggs = AggExprArray()
        aggs.append(a^)
        _found(LogicalPlan.aggregate(ExprArray(), aggs^, _scan()), "AGGREGATE measure slot " + String(slot))
    var res = Optional[OwnedPointer[Expr]](OwnedPointer(_bad()))
    var on = List[String]()
    on.append("a")
    _found(
        LogicalPlan.join(_scan(), _scan(), on.copy(), on.copy(), JOIN_INNER, JOIN_ALGO_AUTO, res^),
        "JOIN residual",
    )
    var keys = List[Expr]()
    keys.append(_bad())
    var fs = _schema()
    _found(LogicalPlan.map_batches(_scan(), 1, keys^, fs^), "MAP_BATCHES group key")


def test_a_call_below_every_node_kind_is_found() raises:
    """Defect: a node arm that does not descend to its child (or children)."""
    var keys = List[String]()
    keys.append("a")
    var desc = List[Bool]()
    desc.append(False)
    _found(LogicalPlan.sort(keys.copy(), desc.copy(), _project(_bad())), "SORT")
    _found(LogicalPlan.limit(3, _project(_bad())), "LIMIT")
    _found(LogicalPlan.distinct(None, _project(_bad())), "DISTINCT")
    _found(LogicalPlan.topn(keys.copy(), desc.copy(), 2, _project(_bad())), "TOPN")
    _found(
        LogicalPlan.partition_by(keys.copy(), keys.copy(), desc.copy(), List[PartitionExpr](), _project(_bad())),
        "PARTITION_BY",
    )
    _found(LogicalPlan.partition_topn(keys.copy(), keys.copy(), desc.copy(), 1, _project(_bad())), "PARTITION_TOPN")
    _found(LogicalPlan.cast_to_varchar(_project(_bad())), "CAST_TO_VARCHAR")
    _found(LogicalPlan.exchange(_project(_bad()), EXCHANGE_KIND_GATHER), "EXCHANGE")
    var on = List[String]()
    on.append("y")
    _found(LogicalPlan.join(_project(_bad()), _project(_c()), on.copy(), on.copy(), JOIN_INNER), "JOIN left")
    _found(LogicalPlan.join(_project(_c()), _project(_bad()), on.copy(), on.copy(), JOIN_INNER), "JOIN right")
    _found(
        LogicalPlan.asof_join(_project(_bad()), _project(_c()), on.copy(), on.copy(), "y", "y", ASOF_BACKWARD, AsofTolerance.none()),
        "ASOF_JOIN left",
    )
    _found(
        LogicalPlan.asof_join(_project(_c()), _project(_bad()), on.copy(), on.copy(), "y", "y", ASOF_BACKWARD, AsofTolerance.none()),
        "ASOF_JOIN right",
    )
    var kids = List[OwnedPointer[LogicalPlan]]()
    kids.append(OwnedPointer(_project(_c())))
    kids.append(OwnedPointer(_project(_bad())))
    var us = _project(_c()).output_schema.copy()
    _found(LogicalPlan.union(kids^, us^), "UNION second child")
    var fs = _schema()
    _found(LogicalPlan.map_batches(_project(_bad()), 1, List[Expr](), fs^), "MAP_BATCHES child")
    assert_equal(_gate(LogicalPlan.view_ref(String("v"), _schema())), "", "VIEW_REF is a leaf")
    assert_equal(_gate(LogicalPlan.cse_ref(UInt64(7), _schema())), "", "CSE_REF is a leaf")


def test_in_process_only_shapes() raises:
    """Defects only an in-process plan can hold, since the decoder refuses
    them earlier: a negative index (the wire's index is unsigned), and an
    AGG_UDF measure with a second argument (the value gate refuses the slot
    first on decode)."""
    var neg = List[Expr]()
    neg.append(Expr.col_ref("b"))
    var msg = _gate(_project(Expr.udf_apply(-1, _f64(), neg^)))
    assert_true(msg.startswith(OPTIMIZED_UDF_UNDECLARED), "index -1: " + msg)
    var a = AggExpr(AGG_UDF, Optional(Expr.udf_apply(0, _f64(), _two(_c(), _c()))), Optional(_c()), None)
    var aggs = AggExprArray()
    aggs.append(a^)
    msg = _gate(LogicalPlan.aggregate(ExprArray(), aggs^, _scan()))
    assert_true(msg.startswith(OPTIMIZED_UDF_AGGREGATE_OUTSIDE_AGGREGATE), "AGG_UDF with two arguments: " + msg)


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_call_under_every_one_child_expression_is_found]()
    suite.test[test_a_call_under_either_child_of_a_two_child_expression_is_found]()
    suite.test[test_a_call_under_every_n_child_expression_is_found]()
    suite.test[test_a_call_inside_a_subquery_plan_is_found]()
    suite.test[test_leaves_pass_and_an_unknown_tag_is_refused]()
    suite.test[test_a_call_in_every_expression_slot_of_a_node_is_found]()
    suite.test[test_a_call_below_every_node_kind_is_found]()
    suite.test[test_in_process_only_shapes]()
    suite^.run()
