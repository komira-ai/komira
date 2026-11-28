# =============================================================================
# test_lower_udf_refusals: what a user-function call is refused for, by name
# =============================================================================
#
# Every refusal is asserted by its whole message, beside a plan that differs
# only in the refused part and lowers.
#
# Tests, and the behaviour each asserts:
#   test_a_row_call_reading_a_column_outside_its_read_set_is_refused_by_name
#       a ROW call whose argument reads `k` with a read set [v] is refused
#       with LOWERING_UDF_UNDECLARED_READ naming the node, the UdfRef, `k` and
#       the set; reading `v` lowers. Catches a read set that is recorded but
#       never compared with what the call passes.
#   test_an_empty_read_set_declares_no_column
#       a ROW call reading `v` with a read set that is set and empty is
#       refused the same way: empty reads none, it is not "every column".
#   test_a_function_with_no_read_set_is_refused_not_widened
#       a ROW function and a frame function whose read set is unset are each
#       refused with LOWERING_UDF_UNDECLARED_READ; there is no every-column
#       path.
#   test_a_frame_group_key_reading_a_column_outside_its_read_set_is_refused
#       a frame grouped by `k` with a read set [v] is refused with
#       LOWERING_UDF_UNDECLARED_READ naming `k`; grouped by `v` the read set
#       check passes and the grouped frame is refused as not served.
#   test_a_read_set_naming_a_column_its_input_lacks_or_repeats_is_refused
#       a read set naming `zz`, or a column the input outputs twice, is
#       LOWERING_UDF_UNSERVED naming the column.
#   test_an_index_with_no_udf_ref_is_refused_before_the_child_is_walked
#       a frame, a step and a call naming an index past the list are refused
#       by name; the frame's refusal comes before its child (a view reference
#       the walk would refuse) is reached.
#   test_a_function_of_the_wrong_kind_is_refused_by_name
#       a frame node calling a SCALAR, a step node calling a frame, and a call
#       in an expression calling a STEP are each LOWERING_UDF_UNSERVED naming
#       both kinds.
#   test_an_argument_or_literal_count_other_than_declared_is_refused
#       a call passing two arguments to a one-argument function, and a step
#       passing one literal to a two-argument function, are refused.
#   test_a_call_anywhere_but_a_whole_projection_column_is_refused
#       a call inside an operator of a projection column, inside another
#       call's argument, in a filter's predicate, an aggregation's group key
#       and argument, and a frame's group key are each refused by name.
#   test_a_projection_whose_input_holds_the_appended_name_is_refused
#       an input column named `__udf_apply:0` refuses the call at column 0;
#       the same call at column 1 lowers.
#   test_a_call_is_found_under_every_expression_container
#       a call hidden under each container the walk descends (unary, cast,
#       string op, regexp, substring, string fn, registered call, extract,
#       math fn, aggregate fn, IN list, struct field, struct field index,
#       JSON extract, n-ary string fn, binary, binary math, map get, the three
#       slots of a CASE) refuses the filter that holds it, and the same
#       expressions with no call lower; a tag the walk does not model is
#       refused by name.
#   test_the_refusal_tokens_are_seven_distinct_names
#       the two UDF tokens are distinct from each other and from the five
#       earlier tokens, and all start with LOWERING_.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from host_profile.host_profile import reference_host_profile
from lowering.lower import lower
from lowering.lowered_plan import (
    LoweringInputs,
    LOWERING_INPUTS_SCAN_COUNT,
    LOWERING_JOIN_UNSERVED,
    LOWERING_SCAN_NOT_TOTAL,
    LOWERING_SINK_UNSERVED,
    LOWERING_UDF_UNDECLARED_READ,
    LOWERING_UDF_UNSERVED,
    LOWERING_UNCUTTABLE_NODE,
)
from plan_expr.agg_expr import AggExpr, AGG_COUNT, AGG_SUM
from plan_expr.expr import (
    Expr,
    WhenCaseData,
    BIN_ADD,
    BIN_GT,
    EXPR_TAG_COUNT,
    EXTRACT_YEAR,
    MATH2_POW,
    MATH_SQRT,
    RDG_ROUND,
    STRFN_UPPER,
    STRFNN_CONCAT,
    STR_LIKE,
    UN_NOT,
    expr_tag_name,
)
from plan_expr.scalar_value import ScalarValue
from plan_expr.udf_data import UDF_NULL_MANUAL, UDF_STABILITY_STABLE
from plan_expr.udf_type import UdfType
from plan_ir.logical_plan import (
    AggExprArray,
    ExprArray,
    LogicalPlan,
    SOURCE_PARQUET,
)
from plan_ir.udf_ref import (
    CODE_FORM_VALUE,
    UdfCode,
    UdfRef,
    UDF_REF_KIND_MAP_BATCHES_FRAME,
    UDF_REF_KIND_ROW,
    UDF_REF_KIND_SCALAR,
    UDF_REF_KIND_STEP,
)


# ---------------------------------------------------------------------------
# Fixtures.
# ---------------------------------------------------------------------------


def _schema(var names: List[String]) -> Schema:
    """INT64 columns of `names`, in order."""
    var sb = SchemaBuilder()
    for i in range(len(names)):
        sb.add_field(Field(names[i], ArrowType.INT64, True))
    return sb.build()


def _names(a: String, b: String = "", c: String = "") -> List[String]:
    var out = List[String]()
    out.append(a)
    if b != "":
        out.append(b)
    if c != "":
        out.append(c)
    return out^


def _scan_of(var names: List[String]) -> LogicalPlan:
    return LogicalPlan.scan(String("t.parquet"), SOURCE_PARQUET, _schema(names^))


def _scan() -> LogicalPlan:
    """k, v and m, all INT64."""
    return _scan_of(_names("k", "v", "m"))


def _int(name: String) -> UdfType:
    return UdfType(name, ArrowType.INT64, Field(name, ArrowType.INT64, True).dtype, True)


def _ints(var names: List[String]) -> List[UdfType]:
    var out = List[UdfType]()
    for i in range(len(names)):
        out.append(_int(names[i]))
    return out^


def _struct(var names: List[String]) -> UdfType:
    return UdfType(
        "out", ArrowType.STRUCT, Field("out", ArrowType.STRUCT, True).dtype, True,
        _ints(names^),
    )


def _ref(
    kind: UInt8, var args: List[UdfType], var ret: UdfType,
    var read_set: Optional[List[String]] = None,
) -> UdfRef:
    return UdfRef(
        kind, UdfCode("komira/python", CODE_FORM_VALUE, "m:f"), args^,
        Optional(ret^), UDF_STABILITY_STABLE, UDF_NULL_MANUAL, read_set^,
    )


def _row(var read_set: Optional[List[String]], var args: List[String]) -> UdfRef:
    return _ref(UDF_REF_KIND_ROW, _ints(args^), _int("r"), read_set^)


def _scalar(arity: Int) -> UdfRef:
    var args = List[UdfType]()
    for i in range(arity):
        args.append(_int("a" + String(i)))
    return _ref(UDF_REF_KIND_SCALAR, args^, _int("r"))


def _frame_ref(var read_set: Optional[List[String]]) -> UdfRef:
    var args = List[UdfType]()
    if read_set:
        args = _ints(read_set.value().copy())
    return _ref(UDF_REF_KIND_MAP_BATCHES_FRAME, args^, _struct(_names("n")), read_set^)


def _step_ref(arity: Int) -> UdfRef:
    var args = List[UdfType]()
    for i in range(arity):
        args.append(_int("x" + String(i)))
    return _ref(UDF_REF_KIND_STEP, args^, _struct(_names("n")))


def _inputs(var udf: UdfRef, scans: Int = 1) -> LoweringInputs:
    var inputs = LoweringInputs()
    for _ in range(scans):
        inputs.add_scan()
    inputs.add_udf(udf^)
    return inputs^


def _cols(a: String, b: String = "") -> List[Expr]:
    var out = List[Expr]()
    out.append(Expr.col_ref(a))
    if b != "":
        out.append(Expr.col_ref(b))
    return out^


def _call(index: Int, var args: List[Expr]) -> Expr:
    return Expr.udf_apply(index, _int("r"), args^)


def _project(var e: Expr, var child: LogicalPlan) -> LogicalPlan:
    var exprs = ExprArray()
    exprs.append(Expr.alias(e^, "y"))
    return LogicalPlan.project(exprs^, child^)


def _frame(
    var child: LogicalPlan, index: Int, var group_by: List[Expr] = List[Expr]()
) raises -> LogicalPlan:
    return LogicalPlan.map_batches(child^, index, group_by^, _schema(_names("n")))


def _message(plan: LogicalPlan, inputs: LoweringInputs) raises -> String:
    """The refusal `lower` raises, or "" when it lowers."""
    try:
        _ = lower(plan, reference_host_profile("test-build"), inputs)
    except e:
        return String(e)
    return String("")


def _unserved(tag: String, why: String) -> String:
    return String(LOWERING_UDF_UNSERVED) + ": " + tag + " (" + why + ") is not cut"


# ---------------------------------------------------------------------------
# The read set.
# ---------------------------------------------------------------------------


def test_a_row_call_reading_a_column_outside_its_read_set_is_refused_by_name() raises:
    var refused = _project(_call(0, _cols("k")), _scan())
    assert_equal(
        _message(refused, _inputs(_row(Optional(_names("v")), _names("v")))),
        "LOWERING_UDF_UNDECLARED_READ: Project UdfRef 0 (ROW) reads 'k' through"
        " argument 0, which its read set [v] does not declare",
    )
    var declared = _project(_call(0, _cols("v")), _scan())
    assert_equal(
        _message(declared, _inputs(_row(Optional(_names("v")), _names("v")))), ""
    )
    var two = _project(_call(0, _cols("v", "m")), _scan())
    assert_equal(
        _message(two, _inputs(_row(Optional(_names("m", "v")), _names("m", "v")))),
        "",
    )
    assert_equal(
        _message(two, _inputs(_row(Optional(_names("k", "v")), _names("k", "v")))),
        "LOWERING_UDF_UNDECLARED_READ: Project UdfRef 0 (ROW) reads 'm' through"
        " argument 1, which its read set [k, v] does not declare",
    )


def test_an_empty_read_set_declares_no_column() raises:
    var plan = _project(_call(0, _cols("v")), _scan())
    assert_equal(
        _message(plan, _inputs(_row(Optional(List[String]()), _names("v")))),
        "LOWERING_UDF_UNDECLARED_READ: Project UdfRef 0 (ROW) reads 'v' through"
        " argument 0, which its read set [] does not declare",
    )
    var literal = List[Expr]()
    literal.append(Expr.literal(ScalarValue.from_int64(1)))
    assert_equal(
        _message(
            _project(_call(0, literal^), _scan()),
            _inputs(_row(Optional(List[String]()), _names("c"))),
        ),
        "",
    )


def test_a_function_with_no_read_set_is_refused_not_widened() raises:
    var why = String(
        " declares no read set, so every column it would receive is"
        " undeclared; the producer names the columns it reads"
    )
    assert_equal(
        _message(
            _project(_call(0, _cols("v")), _scan()),
            _inputs(_row(None, _names("v"))),
        ),
        "LOWERING_UDF_UNDECLARED_READ: Project UdfRef 0 (ROW)" + why,
    )
    assert_equal(
        _message(_frame(_scan(), 0), _inputs(_frame_ref(None))),
        "LOWERING_UDF_UNDECLARED_READ: MapBatches UdfRef 0 (MAP_BATCHES_FRAME)" + why,
    )
    assert_equal(
        _message(_frame(_scan(), 0), _inputs(_frame_ref(Optional(_names("k", "v", "m"))))),
        "",
    )


def test_a_frame_group_key_reading_a_column_outside_its_read_set_is_refused() raises:
    var by_k = List[Expr]()
    by_k.append(Expr.binary(BIN_ADD, Expr.col_ref("v"), Expr.col_ref("k")))
    assert_equal(
        _message(_frame(_scan(), 0, by_k^), _inputs(_frame_ref(Optional(_names("v"))))),
        "LOWERING_UDF_UNDECLARED_READ: MapBatches UdfRef 0 (MAP_BATCHES_FRAME)"
        " reads 'k' through group key 0, which its read set [v] does not"
        " declare",
    )
    assert_equal(
        _message(_frame(_scan(), 0, _cols("v")), _inputs(_frame_ref(Optional(_names("v"))))),
        _unserved(
            "MapBatches",
            "a grouped frame: no segment gathers each group's rows for one"
            " call yet",
        ),
    )
    assert_equal(
        _message(_frame(_scan(), 0), _inputs(_frame_ref(Optional(_names("v"))))), ""
    )


def test_a_read_set_naming_a_column_its_input_lacks_or_repeats_is_refused() raises:
    assert_equal(
        _message(_frame(_scan(), 0), _inputs(_frame_ref(Optional(_names("zz"))))),
        _unserved(
            "MapBatches",
            "UdfRef 0 declares 'zz' in its read set, which its input does not"
            " output",
        ),
    )
    var twice = _scan_of(_names("k", "v", "k"))
    assert_equal(
        _message(_frame(twice^, 0), _inputs(_frame_ref(Optional(_names("k"))))),
        _unserved(
            "MapBatches",
            "UdfRef 0 declares 'k' in its read set, which its input outputs 2"
            " times",
        ),
    )
    assert_equal(
        _message(
            _project(_call(0, _cols("v", "zz")), _scan()),
            _inputs(_row(Optional(_names("v", "zz")), _names("v", "zz"))),
        ),
        _unserved(
            "Project",
            "UdfRef 0 declares 'zz' in its read set, which its input does not"
            " output",
        ),
    )
    var once = _scan_of(_names("k", "v", "q"))
    assert_equal(
        _message(_frame(once^, 0), _inputs(_frame_ref(Optional(_names("k"))))), ""
    )


# ---------------------------------------------------------------------------
# The entry, its kind and its counts.
# ---------------------------------------------------------------------------


def test_an_index_with_no_udf_ref_is_refused_before_the_child_is_walked() raises:
    var why = String("UdfRef 3 is not in the plan's list, which holds 1")
    var view = LogicalPlan.view_ref(String("v"), _schema(_names("k")))
    assert_equal(
        _message(_frame(view^, 3), _inputs(_frame_ref(Optional(_names("k"))), 0)),
        _unserved("MapBatches", why),
    )
    assert_equal(
        _message(
            LogicalPlan.step(3, List[ScalarValue](), _schema(_names("n"))),
            _inputs(_step_ref(0), 0),
        ),
        _unserved("Step", why),
    )
    assert_equal(
        _message(_project(_call(3, _cols("v")), _scan()), _inputs(_scalar(1))),
        _unserved("Project", why),
    )
    var view2 = LogicalPlan.view_ref(String("v"), _schema(_names("k")))
    assert_true(
        _message(_frame(view2^, 0), _inputs(_frame_ref(Optional(_names("k"))), 0))
        .startswith(String(LOWERING_UNCUTTABLE_NODE) + ": ViewRef")
    )


def test_a_function_of_the_wrong_kind_is_refused_by_name() raises:
    assert_equal(
        _message(_frame(_scan(), 0), _inputs(_scalar(1))),
        _unserved(
            "MapBatches",
            "UdfRef 0 is a SCALAR function, and a MapBatches node calls a"
            " MAP_BATCHES_FRAME one",
        ),
    )
    assert_equal(
        _message(
            LogicalPlan.step(0, List[ScalarValue](), _schema(_names("n"))),
            _inputs(_frame_ref(Optional(_names("k"))), 0),
        ),
        _unserved(
            "Step",
            "UdfRef 0 is a MAP_BATCHES_FRAME function, and a Step node calls a"
            " STEP one",
        ),
    )
    assert_equal(
        _message(_project(_call(0, List[Expr]()), _scan()), _inputs(_step_ref(0))),
        _unserved(
            "Project",
            "UdfRef 0 is a STEP function, and a call in an expression calls a"
            " SCALAR, ROW or MAP_BATCHES_COLUMN one",
        ),
    )
    assert_equal(
        _message(
            LogicalPlan.step(0, List[ScalarValue](), _schema(_names("n"))),
            _inputs(_step_ref(0), 0),
        ),
        "",
    )


def test_an_argument_or_literal_count_other_than_declared_is_refused() raises:
    assert_equal(
        _message(_project(_call(0, _cols("k", "v")), _scan()), _inputs(_scalar(1))),
        _unserved(
            "Project",
            "a call of UdfRef 0 passes 2 arguments, and it declares 1",
        ),
    )
    assert_equal(
        _message(_project(_call(0, _cols("k", "v")), _scan()), _inputs(_scalar(2))),
        "",
    )
    var one = List[ScalarValue]()
    one.append(ScalarValue.from_int(1))
    assert_equal(
        _message(LogicalPlan.step(0, one^, _schema(_names("n"))), _inputs(_step_ref(2), 0)),
        _unserved(
            "Step",
            "a Step node passes 1 literals to UdfRef 0, which declares 2",
        ),
    )


# ---------------------------------------------------------------------------
# Where a call may stand.
# ---------------------------------------------------------------------------


def _count() -> AggExprArray:
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_COUNT, Optional[Expr](), Optional[String]("n")))
    return aggs^


def test_a_call_anywhere_but_a_whole_projection_column_is_refused() raises:
    var inside = Expr.binary(BIN_ADD, _call(0, _cols("v")), Expr.col_ref("k"))
    assert_equal(
        _message(_project(inside^, _scan()), _inputs(_scalar(1))),
        _unserved(
            "Project",
            "a call of a user function inside the expression of column 0",
        ),
    )
    var nested = List[Expr]()
    nested.append(_call(0, _cols("v")))
    assert_equal(
        _message(_project(_call(0, nested^), _scan()), _inputs(_scalar(1))),
        _unserved(
            "Project", "a call of a user function in the argument of another"
        ),
    )
    var predicate = Expr.binary(BIN_GT, _call(0, _cols("v")), Expr.col_ref("k"))
    assert_equal(
        _message(LogicalPlan.filter(predicate^, _scan()), _inputs(_scalar(1))),
        _unserved("Filter", "a call of a user function in a predicate"),
    )
    var keys = ExprArray()
    keys.append(_call(0, _cols("v")))
    assert_equal(
        _message(LogicalPlan.aggregate(keys^, _count(), _scan()), _inputs(_scalar(1))),
        _unserved("Aggregate", "a call of a user function in a group key"),
    )
    var sums = AggExprArray()
    sums.append(AggExpr(AGG_SUM, Optional[Expr](_call(0, _cols("v"))), Optional[String]("t")))
    assert_equal(
        _message(LogicalPlan.aggregate(ExprArray(), sums^, _scan()), _inputs(_scalar(1))),
        _unserved(
            "Aggregate", "a call of a user function in an aggregate's argument"
        ),
    )
    var call_key = List[Expr]()
    call_key.append(_call(0, _cols("v")))
    assert_equal(
        _message(_frame(_scan(), 0, call_key^), _inputs(_frame_ref(Optional(_names("v"))))),
        _unserved("MapBatches", "a call of a user function in a group key"),
    )
    var plain = Expr.binary(BIN_GT, Expr.col_ref("v"), Expr.col_ref("k"))
    assert_equal(_message(LogicalPlan.filter(plain^, _scan()), _inputs(_scalar(1))), "")


def test_a_projection_whose_input_holds_the_appended_name_is_refused() raises:
    var input = _names("__udf_apply:0", "v")
    assert_equal(
        _message(_project(_call(0, _cols("v")), _scan_of(input.copy())), _inputs(_scalar(1))),
        _unserved(
            "Project", "its input already has a column named '__udf_apply:0'"
        ),
    )
    var exprs = ExprArray()
    exprs.append(Expr.col_ref("v"))
    exprs.append(Expr.alias(_call(0, _cols("v")), "y"))
    assert_equal(
        _message(LogicalPlan.project(exprs^, _scan_of(input^)), _inputs(_scalar(1))),
        "",
    )


def _hidden_in(var call: Expr) raises -> List[Expr]:
    """`call` under each container the walk descends, in the module's order."""
    var out = List[Expr]()
    out.append(Expr.unary(UN_NOT, call.copy()))
    out.append(Expr.cast(call.copy(), DType.int64))
    out.append(Expr.string_op(STR_LIKE, call.copy(), String("a%")))
    out.append(Expr.regexp_like(call.copy(), String("^a")))
    out.append(Expr.substring(call.copy(), 1, 2))
    out.append(Expr.string_fn(STRFN_UPPER, call.copy()))
    out.append(Expr.udf_call(String("affine"), Optional[Int](7), ArrowType.INT64, ArrowType.INT64, call.copy()))
    out.append(Expr.extract(EXTRACT_YEAR, call.copy()))
    out.append(Expr.math_fn(MATH_SQRT, call.copy()))
    out.append(Expr.round_digits(RDG_ROUND, call.copy(), 2))
    out.append(Expr.agg_fn(AGG_SUM, call.copy()))
    var values = List[ScalarValue]()
    values.append(ScalarValue.from_int64(1))
    out.append(Expr.in_list_node(call.copy(), values^))
    out.append(Expr.struct_field(call.copy(), String("f")))
    out.append(Expr.struct_field_idx(call.copy(), 0))
    out.append(Expr.json_extract_json(call.copy(), String("$.a")))
    var n_args = List[Expr]()
    n_args.append(Expr.col_ref("k"))
    n_args.append(Expr.col_ref("v"))
    n_args.append(call.copy())
    out.append(Expr.string_fn_n(STRFNN_CONCAT, n_args^))
    out.append(Expr.binary(BIN_GT, call.copy(), Expr.col_ref("k")))
    out.append(Expr.binary(BIN_GT, Expr.col_ref("k"), call.copy()))
    out.append(Expr.math_fn2(MATH2_POW, call.copy(), Expr.col_ref("k")))
    out.append(Expr.math_fn2(MATH2_POW, Expr.col_ref("k"), call.copy()))
    out.append(Expr.map_get(call.copy(), Expr.col_ref("k")))
    out.append(Expr.map_get(Expr.col_ref("m"), call.copy()))
    var c1 = List[WhenCaseData]()
    c1.append(WhenCaseData(call.copy(), Expr.col_ref("k")))
    out.append(Expr.when(c1^, Expr.col_ref("v")))
    var c2 = List[WhenCaseData]()
    c2.append(WhenCaseData(Expr.col_ref("k"), call.copy()))
    out.append(Expr.when(c2^, Expr.col_ref("v")))
    var c3 = List[WhenCaseData]()
    c3.append(WhenCaseData(Expr.col_ref("k"), Expr.col_ref("v")))
    out.append(Expr.when(c3^, call.copy()))
    out.append(Expr.alias(call.copy(), String("a")))
    return out^


def test_a_call_is_found_under_every_expression_container() raises:
    var with_call = _hidden_in(_call(0, _cols("v")))
    var without = _hidden_in(Expr.col_ref("v"))
    var refused = _unserved("Filter", "a call of a user function in a predicate")
    for i in range(len(with_call)):
        assert_equal(
            _message(LogicalPlan.filter(with_call[i].copy(), _scan()), _inputs(_scalar(1))),
            refused,
            "container " + String(i),
        )
        var got = _message(LogicalPlan.filter(without[i].copy(), _scan()), _inputs(_scalar(1)))
        assert_true(
            not got.startswith(String(LOWERING_UDF_UNSERVED)),
            "container " + String(i) + " with no call: " + got,
        )
    var leaves = List[Expr]()
    leaves.append(Expr.col_idx(0))
    leaves.append(Expr.literal(ScalarValue.from_int64(1)))
    leaves.append(Expr(UInt8(10)))
    leaves.append(Expr(UInt8(11)))
    for i in range(len(leaves)):
        var got = _message(LogicalPlan.filter(leaves[i].copy(), _scan()), _inputs(_scalar(1)))
        assert_true(not got.startswith(String(LOWERING_UDF_UNSERVED)), got)
    var unknown = Expr(UInt8(EXPR_TAG_COUNT))
    assert_equal(
        _message(LogicalPlan.filter(unknown^, _scan()), _inputs(_scalar(1))),
        String(LOWERING_UDF_UNSERVED) + ": expression tag "
        + expr_tag_name(UInt8(EXPR_TAG_COUNT))
        + " has no arm in the walk that finds user-function calls",
    )


def test_the_refusal_tokens_are_seven_distinct_names() raises:
    var tokens = List[String]()
    tokens.append(String(LOWERING_UNCUTTABLE_NODE))
    tokens.append(String(LOWERING_SINK_UNSERVED))
    tokens.append(String(LOWERING_SCAN_NOT_TOTAL))
    tokens.append(String(LOWERING_INPUTS_SCAN_COUNT))
    tokens.append(String(LOWERING_JOIN_UNSERVED))
    tokens.append(String(LOWERING_UDF_UNDECLARED_READ))
    tokens.append(String(LOWERING_UDF_UNSERVED))
    assert_equal(len(tokens), 7)
    for i in range(len(tokens)):
        for j in range(i + 1, len(tokens)):
            assert_true(tokens[i] != tokens[j])
        assert_true(tokens[i].startswith("LOWERING_"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
