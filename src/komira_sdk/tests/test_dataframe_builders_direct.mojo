# =============================================================================
# The plan builders: with_alias, concat, drop_nulls, rename, with_columns and
# the join helpers, each refusal and each output shape.
# =============================================================================
#
# What each test proves, and the defect it catches:
#   * with_alias: the empty, dotted and re-used prefixes are refused, a frame
#     whose columns only partly carry the prefix is aliased, a zero-column
#     frame gives an empty projection, and every column comes out
#     `prefix.name` (a guard dropped; an alias of the wrong column);
#   * concat: a column-count or a type mismatch raises; equal names keep the
#     bottom plan as it is, other names put it under an aliasing projection
#     (the names of the wrong frame; a projection when none is needed);
#   * drop_nulls: no subset is no predicate, an unknown name raises, one name
#     is `IS NOT NULL`, two are their AND;
#   * rename: an unknown key and a duplicate output raise, an identity
#     mapping keeps the plan, a rename and a swap give the projection;
#   * with_columns: a duplicate output name raises, a derived column that
#     names an input column replaces it in place, the rest are appended;
#   * join: mismatched and missing keys, every algo spelling and an unknown
#     one, the merged registry and row count, and the on=/keys= shape rule.
# =============================================================================

from std.collections import Dict
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from komira_plan_expr.expr import (
    Expr,
    BIN_AND,
    BIN_MUL,
    EXPR_ALIAS,
    EXPR_BINARY_OP,
    EXPR_UNARY_OP,
    UN_IS_NOT_NULL,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    ExprArray,
    LogicalPlan,
    JOIN_ALGO_AUTO,
    JOIN_ALGO_HASH,
    JOIN_ALGO_SORT_MERGE,
    JOIN_INNER,
    PLAN_JOIN,
    PLAN_PROJECT,
    PLAN_SCAN,
    SOURCE_PARQUET,
)
from komira_scan_source.compiler_registry import InMemoryRegistry

from komira_sdk.dataframe_alias import with_alias_impl, _starts_with
from komira_sdk.dataframe_concat import concat_schema_check, concat_align_names
from komira_sdk.dataframe_drop_nulls import drop_nulls_predicate, every_column
from komira_sdk.dataframe_rename import build_rename_plan
from komira_sdk.dataframe_with_columns import build_with_columns_plan
from komira_sdk.join_helpers import (
    _build_join_plan_impl,
    _validate_join_arg_shape_impl,
)


def _schema(names: List[String], types: List[ArrowType]) -> Schema:
    var sb = SchemaBuilder()
    for i in range(len(names)):
        sb.add_field(Field(names[i], types[i], True))
    return sb.build()


def _empty_schema() -> Schema:
    var sb = SchemaBuilder()
    return sb.build()


def _ab() -> Schema:
    var n: List[String] = ["a", "b"]
    var t: List[ArrowType] = [ArrowType.INT64, ArrowType.STRING]
    return _schema(n, t)


def _scan_of(var s: Schema) -> LogicalPlan:
    return LogicalPlan.scan("t.parquet", SOURCE_PARQUET, s^)


def _names(plan: LogicalPlan) -> String:
    var out = String()
    for i in range(plan.output_schema.num_columns()):
        if i > 0:
            out += ","
        out += plan.output_schema.field_name(i)
    return out^


def _expect_raise_alias(var plan: LogicalPlan, name: String, want: String) raises:
    var raised = False
    try:
        _ = with_alias_impl(plan^, InMemoryRegistry(), 0, name)
    except e:
        raised = True
        assert_true(String(e).find(want) != -1, String(e))
    assert_true(raised, "with_alias('" + name + "') raises")


# ---- with_alias -------------------------------------------------------------


def test_with_alias_prefixes_every_column() raises:
    var built = with_alias_impl(_scan_of(_ab()), InMemoryRegistry(), 3, "ns")
    assert_equal(built.cnt, 3)
    var plan = built.take_plan()
    assert_equal(Int(plan.tag), Int(PLAN_PROJECT))
    assert_equal(_names(plan), "ns.a,ns.b")
    var reg = built.take_reg()
    assert_equal(reg.size(), 0)


def test_with_alias_refusals() raises:
    _expect_raise_alias(_scan_of(_ab()), "", "must be non-empty")
    _expect_raise_alias(_scan_of(_ab()), "a.b", "must not contain '.'")
    var n: List[String] = ["ns.a", "ns.b"]
    var t: List[ArrowType] = [ArrowType.INT64, ArrowType.INT64]
    _expect_raise_alias(_scan_of(_schema(n, t)), "ns", "already has the prefix")


def test_with_alias_partial_prefix_and_zero_columns() raises:
    """Only SOME columns carrying the prefix is not a re-alias; a frame with no
    columns is not one either."""
    var n: List[String] = ["ns.a", "b"]
    var t: List[ArrowType] = [ArrowType.INT64, ArrowType.INT64]
    var built = with_alias_impl(_scan_of(_schema(n, t)), InMemoryRegistry(), 0, "ns")
    assert_equal(_names(built.take_plan()), "ns.ns.a,ns.b")
    var empty = with_alias_impl(
        _scan_of(_empty_schema()), InMemoryRegistry(), 0, "ns"
    )
    var p = empty.take_plan()
    assert_equal(Int(p.tag), Int(PLAN_PROJECT))
    assert_equal(p.output_schema.num_columns(), 0)


def test_starts_with() raises:
    assert_true(_starts_with("ns.a", "ns."))
    assert_true(_starts_with("abc", ""))
    assert_false(_starts_with("ns", "ns."), "a prefix longer than the string")
    assert_false(_starts_with("nx.a", "ns."), "a differing byte")


# ---- concat -----------------------------------------------------------------


def test_concat_schema_check() raises:
    concat_schema_check(_ab(), _ab())
    var n1: List[String] = ["a"]
    var t1: List[ArrowType] = [ArrowType.INT64]
    var raised = False
    try:
        concat_schema_check(_ab(), _schema(n1, t1))
    except e:
        raised = True
        assert_true(String(e).find("1 column(s) and the first 2") != -1, String(e))
    assert_true(raised, "a count mismatch raises")
    var n2: List[String] = ["x", "y"]
    var t2: List[ArrowType] = [ArrowType.INT64, ArrowType.INT64]
    raised = False
    try:
        concat_schema_check(_ab(), _schema(n2, t2))
    except e:
        raised = True
        assert_true(String(e).find("column 2 differs in TYPE") != -1, String(e))
    assert_true(raised, "a type mismatch raises")


def test_concat_align_names() raises:
    var same = concat_align_names(_ab(), _scan_of(_ab()))
    assert_equal(Int(same.tag), Int(PLAN_SCAN), "equal names: no projection")
    var n: List[String] = ["a", "z"]
    var t: List[ArrowType] = [ArrowType.INT64, ArrowType.STRING]
    var renamed = concat_align_names(_ab(), _scan_of(_schema(n, t)))
    assert_equal(Int(renamed.tag), Int(PLAN_PROJECT))
    assert_equal(_names(renamed), "a,b", "the bottom takes the top's names")


# ---- drop_nulls -------------------------------------------------------------


def test_drop_nulls_predicate() raises:
    assert_false(Bool(drop_nulls_predicate(_ab(), List[String]())), "none")
    var one: List[String] = ["b"]
    var p1 = drop_nulls_predicate(_ab(), one)
    assert_equal(Int(p1.value().tag), Int(EXPR_UNARY_OP))
    assert_equal(Int(p1.value().unary_op()), Int(UN_IS_NOT_NULL))
    assert_equal(p1.value().unary_child_ref().col_ref_name(), "b")
    var two: List[String] = ["a", "b"]
    var p2 = drop_nulls_predicate(_ab(), two)
    assert_equal(Int(p2.value().tag), Int(EXPR_BINARY_OP))
    assert_equal(Int(p2.value().binary_op()), Int(BIN_AND))
    assert_equal(
        p2.value().binary_left_ref().unary_child_ref().col_ref_name(), "a"
    )
    assert_equal(
        p2.value().binary_right_ref().unary_child_ref().col_ref_name(), "b"
    )
    var bad: List[String] = ["a", "nope"]
    var raised = False
    try:
        _ = drop_nulls_predicate(_ab(), bad)
    except e:
        raised = True
        assert_true(String(e).find("no column named `nope`") != -1, String(e))
    assert_true(raised)


def test_every_column() raises:
    var cols = every_column(_ab())
    assert_equal(len(cols), 2)
    assert_equal(cols[0], "a")
    assert_equal(cols[1], "b")


# ---- rename -----------------------------------------------------------------


def test_rename() raises:
    var m = Dict[String, String]()
    m["b"] = "bee"
    var p = build_rename_plan(_scan_of(_ab()), m)
    assert_equal(Int(p.tag), Int(PLAN_PROJECT))
    assert_equal(_names(p), "a,bee")
    # A swap renames both columns.
    var swap = Dict[String, String]()
    swap["a"] = "b"
    swap["b"] = "a"
    assert_equal(_names(build_rename_plan(_scan_of(_ab()), swap)), "b,a")
    # An identity mapping, and an empty one, keep the plan as it is.
    var same = Dict[String, String]()
    same["a"] = "a"
    assert_equal(Int(build_rename_plan(_scan_of(_ab()), same).tag), Int(PLAN_SCAN))
    var none = Dict[String, String]()
    assert_equal(Int(build_rename_plan(_scan_of(_ab()), none).tag), Int(PLAN_SCAN))


def test_rename_refusals() raises:
    var unknown = Dict[String, String]()
    unknown["nope"] = "x"
    var raised = False
    try:
        _ = build_rename_plan(_scan_of(_ab()), unknown)
    except e:
        raised = True
        assert_true(String(e).find("no column named `nope`") != -1, String(e))
    assert_true(raised, "an unknown key raises")
    var dup = Dict[String, String]()
    dup["b"] = "a"
    raised = False
    try:
        _ = build_rename_plan(_scan_of(_ab()), dup)
    except e:
        raised = True
        assert_true(String(e).find("column `a` would appear twice") != -1, String(e))
    assert_true(raised, "a duplicate output raises")


# ---- with_columns -----------------------------------------------------------


def test_with_columns_replaces_in_place_and_appends() raises:
    var d = ExprArray()
    d.append(Expr.alias(Expr.col_ref("a"), "new"))
    d.append(
        Expr.alias(
            Expr.binary(
                BIN_MUL, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int(2))
            ),
            "a",
        )
    )
    var p = build_with_columns_plan(_scan_of(_ab()), d^)
    assert_equal(Int(p.tag), Int(PLAN_PROJECT))
    assert_equal(_names(p), "a,b,new")
    ref exprs = p.project_data_ref().exprs
    assert_equal(Int(exprs[0].tag), Int(EXPR_ALIAS), "the replacement sits at a's place")
    assert_equal(Int(exprs[0].alias_child_ref().tag), Int(EXPR_BINARY_OP))
    assert_equal(exprs[1].col_ref_name(), "b", "an untouched column passes")
    # No derived columns: every input column passes through.
    var p0 = build_with_columns_plan(_scan_of(_ab()), ExprArray())
    assert_equal(_names(p0), "a,b")


def test_with_columns_refuses_a_duplicate_name() raises:
    var d = ExprArray()
    d.append(Expr.alias(Expr.col_ref("a"), "x"))
    d.append(Expr.alias(Expr.col_ref("b"), "x"))
    var raised = False
    try:
        _ = build_with_columns_plan(_scan_of(_ab()), d^)
    except e:
        raised = True
        assert_true(String(e).find("output name 'x'") != -1, String(e))
    assert_true(raised)


# ---- join -------------------------------------------------------------------


def _join(
    lk: List[String], rk: List[String], algo: String
) raises -> LogicalPlan:
    var built = _build_join_plan_impl(
        _scan_of(_ab()), InMemoryRegistry(), 1,
        _scan_of(_ab()), InMemoryRegistry(), 2,
        lk.copy(), rk.copy(), JOIN_INNER, algo,
    )
    assert_equal(built.cnt, 3, "the row counters add")
    return built.take_plan()


def _join_raises(lk: List[String], rk: List[String], algo: String, want: String) raises:
    var raised = False
    try:
        _ = _join(lk, rk, algo)
    except e:
        raised = True
        assert_true(String(e).find(want) != -1, String(e))
    assert_true(raised, "join raises: " + want)


def test_join_algo_spellings() raises:
    var k: List[String] = ["a"]
    var p = _join(k, k, "")
    assert_equal(Int(p.tag), Int(PLAN_JOIN))
    assert_equal(Int(p.join_data_ref().algo_hint), Int(JOIN_ALGO_AUTO))
    assert_equal(Int(p.join_data_ref().join_type), Int(JOIN_INNER))
    assert_equal(Int(_join(k, k, "auto").join_data_ref().algo_hint), Int(JOIN_ALGO_AUTO))
    assert_equal(Int(_join(k, k, "hash").join_data_ref().algo_hint), Int(JOIN_ALGO_HASH))
    assert_equal(
        Int(_join(k, k, "sort_merge").join_data_ref().algo_hint),
        Int(JOIN_ALGO_SORT_MERGE),
    )
    _join_raises(k, k, "nested", "unknown algo=\"nested\"")


def test_join_key_refusals() raises:
    var one: List[String] = ["a"]
    var two: List[String] = ["a", "b"]
    _join_raises(one, two, "", "length mismatch (left=1, right=2)")
    _join_raises(List[String](), List[String](), "", "at least one join key")


def test_join_merges_the_registries() raises:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    var arr = PrimitiveArray[DType.int64].allocate(1)
    arr._typed_ptr_mut().store[width=1](0, Int64(5))
    var b = RecordBatchBuilder()
    b.add_column(Column.from_primitive[DType.int64](arr))
    var right = InMemoryRegistry()
    right.register("r", b.build(sb.build()))
    var k: List[String] = ["a"]
    var built = _build_join_plan_impl(
        _scan_of(_ab()), InMemoryRegistry(), 0,
        _scan_of(_ab()), right^, 0,
        k.copy(), k.copy(), JOIN_INNER, "",
    )
    var reg = built.take_reg()
    assert_equal(reg.size(), 1, "the right side's batch is in the result")


def test_join_arg_shape() raises:
    _validate_join_arg_shape_impl("join", 0, 0, 1)
    _validate_join_arg_shape_impl("join", 1, 1, 0)
    var cases: List[Int] = [1, 0, 1, 0, 1, 1, 0, 0, 0, 1, 0, 0]
    var wants: List[String] = ["not both", "not both", "at least one", "at least one"]
    for c in range(4):
        var raised = False
        try:
            _validate_join_arg_shape_impl(
                "left_join", cases[3 * c], cases[3 * c + 1], cases[3 * c + 2]
            )
        except e:
            raised = True
            assert_true(String(e).find(wants[c]) != -1, String(e))
            assert_true(String(e).find("DataFrame.left_join") != -1, String(e))
        assert_true(raised, "shape case " + String(c) + " raises")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
