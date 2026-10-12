# =============================================================================
# test_plan_udf_nodes.mojo — the user-code plan nodes, the `UdfRef` IR, and
# the plan-IR sites that read them (optimized_plan_udfs.md §10.2-§10.4)
# =============================================================================
#
# `PLAN_MAP_BATCHES` and `PLAN_STEP` name a user function by its index in the
# `UdfRef` list beside the plan. Copy, integrity and the payload-missing
# refusals of both nodes are test_plan_every_kind_copies_and_validates.mojo's;
# the scan-binding walks are those files'. This file holds what is left: the
# factories' refusals, plan identity, schema propagation, the AGG_UDF output
# field, the registered-UDF collector's descent through a call, and the
# `UdfRef` IR's own copy. Each test names the defect it catches.
# =============================================================================

from std.collections import Optional
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_UDF
from komira_plan_expr.expr import Expr, EXPR_UDF_CALL
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.udf_type import UdfType, udf_type_same
from komira_plan_ir.expr_udf_sites import collect_udf_calls
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    PLAN_MAP_BATCHES,
    PLAN_STEP,
    SOURCE_PARQUET,
    plan_tag_name,
)
from komira_plan_ir.schema_propagation import infer_schema
from komira_plan_ir.udf_ref import (
    CodeDigest,
    UdfCode,
    UdfRef,
    UdfResources,
    UDF_REF_KIND_SCALAR,
    UDF_REF_KIND_MAP_BATCHES_COLUMN,
    UDF_REF_KIND_AGGREGATE,
    UDF_REF_KIND_STEP,
    UDF_REF_KIND_MAP_BATCHES_FRAME,
    UDF_REF_KIND_ROW,
    CODE_FORM_BUNDLE,
    udf_ref_kind_name,
)
from komira_plan_expr.udf_data import UDF_NULL_MANUAL, UDF_STABILITY_VOLATILE


def _schema(a: String, b: String) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(a, ArrowType.INT64, True))
    sb.add_field(Field(b, ArrowType.FLOAT64, True))
    return sb.build()


def _scan() -> LogicalPlan:
    return LogicalPlan.scan("t.parquet", SOURCE_PARQUET, _schema("a", "b"))


def _frame(index: Int, key: String) raises -> LogicalPlan:
    var gb = List[Expr]()
    gb.append(Expr.col_ref(key))
    return LogicalPlan.map_batches(_scan(), index, gb^, _schema("k", "v"))


def _step(index: Int, arg: Int) raises -> LogicalPlan:
    var args = List[ScalarValue]()
    args.append(ScalarValue.from_int(arg))
    return LogicalPlan.step(index, args^, _schema("k", "v"))


def _render(p: LogicalPlan) -> String:
    var s = String("")
    p.write_to(s)
    return s^


def test_tags_and_names() raises:
    """Defect: the UDF nodes on ids other than the design's (19, 20), or
    without names."""
    assert_equal(Int(PLAN_MAP_BATCHES), 19, "PLAN_MAP_BATCHES")
    assert_equal(Int(PLAN_STEP), 20, "PLAN_STEP")
    assert_equal(plan_tag_name(PLAN_MAP_BATCHES), "MapBatches", "name")
    assert_equal(plan_tag_name(PLAN_STEP), "Step", "name")


def test_factories_refuse_a_negative_index_and_store_every_field() raises:
    """Defects: a factory that admits an index no list has, or that drops the
    index, the keys, the arguments or the schema it is given."""
    var gb = List[Expr]()
    var refused = False
    try:
        _ = LogicalPlan.map_batches(_scan(), -1, gb^, _schema("k", "v"))
    except e:
        refused = "udf_index -1 is negative" in String(e)
    assert_true(refused, "map_batches admitted index -1")
    refused = False
    try:
        _ = LogicalPlan.step(-2, List[ScalarValue](), _schema("k", "v"))
    except e:
        refused = "udf_index -2 is negative" in String(e)
    assert_true(refused, "step admitted index -2")
    var f = _frame(3, "a")
    assert_true(f.is_map_batches(), "is_map_batches")
    assert_false(f.is_step(), "a frame is not a step")
    assert_equal(f.map_batches_data_ref().udf_index, 3, "frame index")
    assert_equal(len(f.map_batches_data_ref().group_by), 1, "frame keys")
    assert_equal(f.output_schema.field_name(0), "k", "frame schema")
    var s = _step(4, 9)
    assert_true(s.is_step(), "is_step")
    assert_equal(s.step_data_ref().udf_index, 4, "step index")
    assert_equal(len(s.step_data_ref().args), 1, "step args")
    assert_equal(s.output_schema.field_name(1), "v", "step schema")


def test_every_field_enters_plan_identity() raises:
    """Defect: a render that leaves out the index, a key or an argument, so
    two nodes calling different functions, or one function differently,
    share a compiled plan."""
    var base = _frame(3, "a").structural_hash()
    assert_true(_frame(4, "a").structural_hash() != base, "frame index")
    assert_true(_frame(3, "b").structural_hash() != base, "frame key")
    var sbase = _step(4, 9).structural_hash()
    assert_true(_step(5, 9).structural_hash() != sbase, "step index")
    assert_true(_step(4, 8).structural_hash() != sbase, "step argument")
    assert_true("MapBatches(udf=3, group_by=[" in _render(_frame(3, "a")), _render(_frame(3, "a")))
    assert_true("Step(udf=4, args=[" in _render(_step(4, 9)), _render(_step(4, 9)))


def test_schema_propagation_returns_the_stated_schema() raises:
    """Defect: `infer_schema` re-deriving a UDF node's schema from its child
    (a frame may return any columns) or raising on the tags."""
    var f = infer_schema(_frame(0, "a"))
    assert_equal(f.num_columns(), 2, "frame columns")
    assert_equal(f.field_name(0), "k", "frame column 0")
    var s = infer_schema(_step(0, 1))
    assert_equal(s.field_name(1), "v", "step column 1")


def _p95() -> UdfType:
    return UdfType("p95", ArrowType.FLOAT32, DType.float32, False)


def test_agg_udf_output_field_is_the_call_type() raises:
    """Defects: an AGG_UDF measure typed by a SUM-like rule (the input's
    type) instead of its call's `return_type`, an alias that does not name
    it, and a malformed measure that is typed instead of placeholdered."""
    var args = List[Expr]()
    args.append(Expr.col_ref("b"))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_UDF, Optional(Expr.udf_apply(0, _p95(), args^)), Optional(String("q"))))
    var p = LogicalPlan.aggregate(ExprArray(), aggs^, _scan())
    var f = p.output_schema.field_at(0)
    assert_equal(f.name, "q", "the alias names the measure")
    assert_equal(Int(f.arrow_type.type_id), Int(ArrowType.FLOAT32.type_id), "the call's type")
    assert_false(f.nullable, "the call's nullability")
    var bad = AggExprArray()
    bad.append(AggExpr(AGG_UDF, Optional(Expr.col_ref("b")), None))
    var q = LogicalPlan.aggregate(ExprArray(), bad^, _scan())
    var g = q.output_schema.field_at(0)
    assert_equal(g.name, "agg_udf", "the base name")
    assert_equal(Int(g.arrow_type.type_id), Int(ArrowType.NULL.type_id), "a malformed measure")


def test_registered_calls_inside_a_udf_apply_are_collected() raises:
    """Defect: the registered-UDF collector raising on a call of a `UdfRef`
    (its walk is total), or not entering the call's arguments, so a
    registered call inside one is never materialized."""
    var args = List[Expr]()
    args.append(Expr.udf_call("double", Optional(1), ArrowType.INT64, ArrowType.INT64, Expr.col_ref("a")))
    var e = Expr.udf_apply(0, _p95(), args^)
    var sites = List[Expr]()
    collect_udf_calls(e, sites)
    assert_equal(len(sites), 1, "the registered call inside the argument")
    assert_equal(Int(sites[0].tag), Int(EXPR_UDF_CALL), "it is the registered call")


def test_udf_ref_copy_is_deep() raises:
    """Defect: a `UdfRef.copy()` that drops a field, or keeps `None` and
    `Some([])` apart in the original and not in the copy."""
    var digests = List[CodeDigest]()
    var sha: List[UInt8] = [1, 2]
    digests.append(CodeDigest("bundle", sha^))
    var desc: List[UInt8] = [5]
    var args = List[UdfType]()
    args.append(_p95())
    var blobs = List[List[UInt8]]()
    var blob: List[UInt8] = [9]
    blobs.append(blob^)
    var u = UdfRef(
        UDF_REF_KIND_ROW,
        UdfCode("komira/node", CODE_FORM_BUNDLE, "m.js#f", digests^, UInt32(3), desc^),
        args^,
        Optional(_p95()),
        UDF_STABILITY_VOLATILE,
        UDF_NULL_MANUAL,
        Optional(List[String]()),
        Optional(_p95()),
        blobs^,
        UdfResources(UInt64(1), UInt32(2), UInt32(3), UInt64(4), UInt32(5)),
        True,
    )
    var c = u.copy()
    assert_equal(Int(c.kind), Int(UDF_REF_KIND_ROW), "kind")
    assert_equal(c.code.runtime, "komira/node", "runtime")
    assert_equal(Int(c.code.form), Int(CODE_FORM_BUNDLE), "form")
    assert_equal(c.code.entry, "m.js#f", "entry")
    assert_equal(c.code.code[0].role, "bundle", "digest role")
    assert_equal(len(c.code.code[0].sha256), 2, "digest bytes")
    assert_equal(Int(c.code.descriptor_version), 3, "descriptor version")
    assert_equal(len(c.code.descriptor), 1, "descriptor")
    assert_equal(len(c.arg_types), 1, "arg types")
    assert_true(udf_type_same(c.return_type.value(), _p95(), True), "return type")
    assert_true(udf_type_same(c.state_type.value(), _p95(), True), "state type")
    assert_equal(len(c.data_blobs), 1, "data blobs")
    assert_equal(Int(c.stability), Int(UDF_STABILITY_VOLATILE), "stability")
    assert_equal(Int(c.null_mode), Int(UDF_NULL_MANUAL), "null mode")
    assert_equal(c.resources.max_concurrent_calls, UInt32(5), "resources")
    assert_true(c.preserves_event_time, "preserves_event_time")
    assert_true(Bool(c.read_set), "an empty read set became unset in the copy")
    assert_equal(len(c.read_set.value()), 0, "the empty read set gained names")
    var n = UdfRef(
        UDF_REF_KIND_SCALAR, UdfCode("komira/node", CODE_FORM_BUNDLE, "e"),
        List[UdfType](), None, UDF_STABILITY_VOLATILE, UDF_NULL_MANUAL,
    )
    var nc = n.copy()
    assert_false(Bool(nc.read_set), "an unset read set became set in the copy")
    assert_false(Bool(nc.return_type), "an absent return type appeared")
    assert_false(Bool(nc.state_type), "an absent state type appeared")


def test_kind_names() raises:
    """Defect: a kind with no name, or two kinds sharing one."""
    assert_equal(udf_ref_kind_name(UDF_REF_KIND_SCALAR), "SCALAR", "SCALAR")
    assert_equal(udf_ref_kind_name(UDF_REF_KIND_MAP_BATCHES_COLUMN), "MAP_BATCHES_COLUMN", "MBC")
    assert_equal(udf_ref_kind_name(UDF_REF_KIND_AGGREGATE), "AGGREGATE", "AGGREGATE")
    assert_equal(udf_ref_kind_name(UDF_REF_KIND_STEP), "STEP", "STEP")
    assert_equal(udf_ref_kind_name(UDF_REF_KIND_MAP_BATCHES_FRAME), "MAP_BATCHES_FRAME", "MBF")
    assert_equal(udf_ref_kind_name(UDF_REF_KIND_ROW), "ROW", "ROW")
    assert_equal(udf_ref_kind_name(UInt8(9)), "kind#9", "an unknown kind")


def main() raises:
    var suite = TestSuite()
    suite.test[test_tags_and_names]()
    suite.test[test_factories_refuse_a_negative_index_and_store_every_field]()
    suite.test[test_every_field_enters_plan_identity]()
    suite.test[test_schema_propagation_returns_the_stated_schema]()
    suite.test[test_agg_udf_output_field_is_the_call_type]()
    suite.test[test_registered_calls_inside_a_udf_apply_are_collected]()
    suite.test[test_udf_ref_copy_is_deep]()
    suite.test[test_kind_names]()
    suite^.run()
