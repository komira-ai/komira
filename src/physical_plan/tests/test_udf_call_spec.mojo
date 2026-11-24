# =============================================================================
# test_udf_call_spec: the user-function arms of the IR (version 17)
# =============================================================================
#
# Tests, and the behaviour each asserts:
#   test_the_udf_tags_are_new_and_reuse_no_retired_or_live_tag
#       OP_UDF_APPLY, OP_UDF_FRAME and SOURCE_UDF_STEP take tags no other kind
#       holds, and none of the retired MorselOp tags 4-13.
#   test_an_operator_call_records_its_spec_and_no_other_arm
#       `MorselOp.udf_call` keeps the tag and every field of the spec, and
#       leaves the filter, project, limit and probe fields at their defaults.
#   test_a_step_source_records_its_call_and_no_other_arm
#       `SourceSpecPod.step` keeps the literals and output names, and leaves
#       the Parquet, batch and dependency fields empty; another arm's spec
#       carries no step.
#   test_a_copy_is_deep_and_equal
#       `UdfCallSpec.copy` gives equal fields, and changing the copy leaves
#       the original as it was.
#   test_the_purity_gate_counts_and_checks_each_udf_argument
#       every argument of an OP_UDF_APPLY is one expression site the purity
#       gate inspects, and a subquery in one is refused naming that site.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, SchemaBuilder
from containers.slab import Slab
from plan_expr.expr import Expr
from plan_expr.scalar_value import ScalarValue
from plan_ir.logical_plan import CORR_KIND_EXISTS, LogicalPlan, SOURCE_PARQUET
from plan_ir.udf_ref import (
    UDF_REF_KIND_MAP_BATCHES_FRAME,
    UDF_REF_KIND_ROW,
    UDF_REF_KIND_STEP,
)
from physical_plan.physical_plan import (
    KEY_DTYPE_NONE,
    MorselOp,
    OP_FILTER,
    OP_JOIN_PROBE,
    OP_LIMIT,
    OP_PROJECT,
    OP_UDF_APPLY,
    OP_UDF_FRAME,
    SINK_COLLECT,
    SINK_ORIENT_COLUMNAR,
    SOURCE_BATCH,
    SOURCE_CONCAT,
    SOURCE_CSV,
    SOURCE_PARQUET as SOURCE_PARQUET_KIND,
    SOURCE_SINK_OUTPUT,
    SOURCE_UDF_STEP,
    SegmentDescPod,
    SourceSpecPod,
)
from physical_plan.physical_plan_purity_gate import (
    assert_physical_plan_carries_no_logical_plan,
)
from physical_plan.udf_call_spec import UdfCallSpec


def _names(a: String, b: String = "") -> List[String]:
    var out = List[String]()
    out.append(a)
    if b != "":
        out.append(b)
    return out^


def _text(items: List[String]) -> String:
    var out = String("[")
    for i in range(len(items)):
        if i > 0:
            out += ","
        out += items[i]
    return out + "]"


def _args(var a: Expr) -> List[Expr]:
    var out = List[Expr]()
    out.append(a^)
    return out^


def _row_spec() -> UdfCallSpec:
    return UdfCallSpec(
        3,
        UDF_REF_KIND_ROW,
        _names("a", "b"),
        _args(Expr.col_ref("a")),
        _names("__udf_apply:0"),
    )


def _seg(var ops: Slab[MorselOp]) raises -> SegmentDescPod:
    return SegmentDescPod(
        seg_id=0,
        source_kind=SOURCE_BATCH,
        source_spec=SourceSpecPod.batch(-1),
        ops=ops^,
        sink_kind=SINK_COLLECT,
        sink_key_dtype=KEY_DTYPE_NONE,
        sink_orientation=SINK_ORIENT_COLUMNAR,
        sink_param_id=-1,
        sink_state_id=0,
        deps=List[Int](),
        edge_tags=List[UInt8](),
    )


def test_the_udf_tags_are_new_and_reuse_no_retired_or_live_tag() raises:
    var ops = List[Int]()
    ops.append(Int(OP_FILTER))
    ops.append(Int(OP_PROJECT))
    ops.append(Int(OP_LIMIT))
    ops.append(Int(OP_JOIN_PROBE))
    for i in range(len(ops)):
        assert_true(ops[i] != Int(OP_UDF_APPLY) and ops[i] != Int(OP_UDF_FRAME))
    assert_true(OP_UDF_APPLY != OP_UDF_FRAME)
    for retired in range(4, 14):
        assert_true(retired != Int(OP_UDF_APPLY) and retired != Int(OP_UDF_FRAME))
    var sources = List[Int]()
    sources.append(Int(SOURCE_PARQUET_KIND))
    sources.append(Int(SOURCE_BATCH))
    sources.append(Int(SOURCE_SINK_OUTPUT))
    sources.append(Int(SOURCE_CONCAT))
    sources.append(Int(SOURCE_CSV))
    for i in range(len(sources)):
        assert_true(sources[i] != Int(SOURCE_UDF_STEP))


def test_an_operator_call_records_its_spec_and_no_other_arm() raises:
    var op = MorselOp.udf_call(OP_UDF_APPLY, _row_spec())
    assert_equal(Int(op.tag), Int(OP_UDF_APPLY))
    assert_true(Bool(op.udf))
    ref spec = op.udf.value()
    assert_equal(spec.udf_index, 3)
    assert_equal(Int(spec.kind), Int(UDF_REF_KIND_ROW))
    assert_equal(_text(spec.reads), _text(_names("a", "b")))
    assert_equal(len(spec.args), 1)
    assert_equal(spec.args[0].col_ref_name(), "a")
    assert_equal(_text(spec.out_names), _text(_names("__udf_apply:0")))
    assert_equal(len(spec.literals), 0)
    assert_false(Bool(op.filter_predicate))
    assert_false(Bool(op.project_exprs))
    assert_equal(op.limit_count, -1)
    assert_equal(op.probe_build_seg, -1)
    var frame = MorselOp.udf_call(
        OP_UDF_FRAME,
        UdfCallSpec(
            0, UDF_REF_KIND_MAP_BATCHES_FRAME, _names("v"), List[Expr](),
            _names("k", "s"),
        ),
    )
    assert_equal(Int(frame.tag), Int(OP_UDF_FRAME))
    assert_equal(_text(frame.udf.value().out_names), _text(_names("k", "s")))
    assert_false(Bool(MorselOp.limit(1).udf))


def test_a_step_source_records_its_call_and_no_other_arm() raises:
    var lits = List[ScalarValue]()
    lits.append(ScalarValue.from_int(7))
    var s = SourceSpecPod.step(
        UdfCallSpec(
            2, UDF_REF_KIND_STEP, List[String](), List[Expr](),
            _names("k", "v"), lits^,
        )
    )
    assert_true(Bool(s.udf_step))
    ref spec = s.udf_step.value()
    assert_equal(spec.udf_index, 2)
    assert_equal(Int(spec.kind), Int(UDF_REF_KIND_STEP))
    assert_equal(len(spec.literals), 1)
    assert_equal(String(spec.literals[0]), String(ScalarValue.from_int(7)))
    assert_equal(_text(spec.out_names), _text(_names("k", "v")))
    assert_equal(len(spec.reads), 0)
    assert_equal(s.parquet_path, "")
    assert_equal(s.batch_handle_id, -1)
    assert_equal(len(s.dep_seg_ids), 0)
    assert_false(Bool(SourceSpecPod.batch(0).udf_step))
    assert_false(Bool(SourceSpecPod.from_sink_output(1).udf_step))


def test_a_copy_is_deep_and_equal() raises:
    var lits = List[ScalarValue]()
    lits.append(ScalarValue.from_string("x"))
    var original = UdfCallSpec(
        1, UDF_REF_KIND_ROW, _names("a"), _args(Expr.col_ref("a")),
        _names("y"), lits^,
    )
    var c = original.copy()
    assert_equal(c.udf_index, 1)
    assert_equal(Int(c.kind), Int(UDF_REF_KIND_ROW))
    assert_equal(_text(c.reads), _text(_names("a")))
    assert_equal(c.args[0].col_ref_name(), "a")
    assert_equal(_text(c.out_names), _text(_names("y")))
    assert_equal(String(c.literals[0]), String(ScalarValue.from_string("x")))
    c.reads.append("b")
    c.out_names[0] = "z"
    c.args[0] = Expr.col_ref("q")
    assert_equal(_text(original.reads), _text(_names("a")))
    assert_equal(_text(original.out_names), _text(_names("y")))
    assert_equal(original.args[0].col_ref_name(), "a")


def _subquery() raises -> Expr:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("x"), ArrowType.INT64, True))
    var inner = LogicalPlan.scan(String("inner.parquet"), SOURCE_PARQUET, sb.build())
    return Expr.correlated_subquery(inner^, _names("outer_k"), CORR_KIND_EXISTS)


def test_the_purity_gate_counts_and_checks_each_udf_argument() raises:
    var args = List[Expr]()
    args.append(Expr.col_ref("a"))
    args.append(Expr.col_ref("b"))
    var ops = Slab[MorselOp]()
    ops.append(
        MorselOp.udf_call(
            OP_UDF_APPLY,
            UdfCallSpec(0, UDF_REF_KIND_ROW, _names("a", "b"), args^, _names("y")),
        )
    )
    ops.append(MorselOp.udf_call(OP_UDF_FRAME, UdfCallSpec(
        1, UDF_REF_KIND_MAP_BATCHES_FRAME, _names("y"), List[Expr](), _names("z"),
    )))
    var clean = List[SegmentDescPod]()
    clean.append(_seg(ops^))
    assert_equal(assert_physical_plan_carries_no_logical_plan(clean), 2)

    var bad_args = List[Expr]()
    bad_args.append(Expr.col_ref("a"))
    bad_args.append(_subquery())
    var bad = Slab[MorselOp]()
    bad.append(
        MorselOp.udf_call(
            OP_UDF_APPLY,
            UdfCallSpec(0, UDF_REF_KIND_ROW, _names("a"), bad_args^, _names("y")),
        )
    )
    var segs = List[SegmentDescPod]()
    segs.append(_seg(bad^))
    var msg = String("")
    try:
        _ = assert_physical_plan_carries_no_logical_plan(segs)
    except e:
        msg = String(e)
    assert_true(msg.startswith("PHYSICAL_PLAN_CARRIES_LOGICAL_PLAN"), msg)
    assert_true(String("ops[i].udf.args") in msg, msg)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
