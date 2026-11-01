# =============================================================================
# test_plan_wire_udf_plans.mojo — the UDF arms through both contexts: round
# trips, the legacy named forms in OPTIMIZED, index, kind and aggregate
# refusals (optimized_plan_udfs.md §10.2, §10.4; optimized_plan.md §6.1)
# =============================================================================
#
# Every arm round-trips in RAW (`plan_to_bytes_with_udfs` ->
# `plan_envelope_from_bytes`) and in OPTIMIZED (`optimized_plan_to_bytes` ->
# `optimized_plan_from_bytes`), checked on plan identity (`structural_hash`)
# and on the output schema, which the render does not carry. The refusal tests
# encode a plan whose calls disagree with the list they index (the RAW encoder
# writes what it is given) and require the decoder to refuse by token; each
# has a control that decodes. The argument, read-set and schema refusals are
# test_plan_wire_udf_args.mojo.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_UDF, AGG_SUM
from komira_plan_expr.expr import Expr, EXPR_UDF_APPLY
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.udf_data import (
    UdfData,
    UDF_KIND_AGG,
    UDF_KIND_FILTER,
    UDF_KIND_MAP,
    UDF_NULL_MANUAL,
    UDF_NULL_PROPAGATE,
    UDF_STABILITY_STABLE,
    UDF_STABILITY_VOLATILE,
)
from komira_plan_expr.udf_type import UdfType, udf_type_same
from komira_plan_ir.logical_plan import LogicalPlan, ExprArray, AggExprArray
from komira_plan_ir.udf_ref import (
    CodeDigest,
    UdfCode,
    UdfRef,
    UDF_REF_KIND_SCALAR,
    UDF_REF_KIND_MAP_BATCHES_COLUMN,
    UDF_REF_KIND_AGGREGATE,
    UDF_REF_KIND_STEP,
    UDF_REF_KIND_MAP_BATCHES_FRAME,
    UDF_REF_KIND_ROW,
    CODE_FORM_VALUE,
)
from komira_proto_codec import decode_proto, encode_proto
from komira_plan_proto.plan import WirePlanEnvelope

from komira_plan_wire import (
    plan_to_bytes,
    plan_to_bytes_with_udfs,
    plan_envelope_from_bytes,
    optimized_plan_from_bytes,
    optimized_plan_to_bytes,
    plan_wire_check_udfs,
    OPTIMIZED_UDF_UNDECLARED,
    OPTIMIZED_UDF_KIND_ARM_MISMATCH,
    OPTIMIZED_UDF_AGGREGATE_OUTSIDE_AGGREGATE,
    OPTIMIZED_UDF_LEGACY_FORM,
    PLAN_WIRE_AGG_ARG_DROPPED,
)


# ---- fixtures -----------------------------------------------------------------------


def _leaf(name: String, t: ArrowType, nullable: Bool = True) -> UdfType:
    return UdfType(name, t, Field(name, t, nullable).dtype, nullable)


def _struct(var kids: List[UdfType]) -> UdfType:
    return UdfType("out", ArrowType.STRUCT, Field("out", ArrowType.STRUCT, True).dtype, True, kids^)


def _cols(a: String, ta: ArrowType, b: String, tb: ArrowType) -> List[UdfType]:
    var out = List[UdfType]()
    out.append(_leaf(a, ta))
    out.append(_leaf(b, tb))
    return out^


def _code() -> UdfCode:
    var d = List[CodeDigest]()
    var sha = List[UInt8]()
    for _ in range(32):
        sha.append(0x5A)
    d.append(CodeDigest("payload", sha^))
    return UdfCode("komira/python", CODE_FORM_VALUE, "", d^)


def _ref(
    kind: UInt8,
    var args: List[UdfType],
    var ret: UdfType,
    stability: UInt8 = UDF_STABILITY_STABLE,
    null_mode: UInt8 = UDF_NULL_PROPAGATE,
    var read_set: Optional[List[String]] = None,
) -> UdfRef:
    return UdfRef(kind, _code(), args^, Optional(ret^), stability, null_mode, read_set^)


def _one(t: ArrowType) -> List[UdfType]:
    var out = List[UdfType]()
    out.append(_leaf("x", t))
    return out^


def _scalar(ret: ArrowType = ArrowType.FLOAT64) -> UdfRef:
    """SCALAR float64 -> `ret`."""
    return _ref(UDF_REF_KIND_SCALAR, _one(ArrowType.FLOAT64), _leaf("y", ret))


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    sb.add_field(Field("b", ArrowType.FLOAT64, True))
    return sb.build()


def _scan() -> LogicalPlan:
    return LogicalPlan.scan(
        String("/nonexistent/udf.parquet"), 0, _schema(),
        Optional[List[String]](None), Optional[Expr](None), Optional[Int](None),
    )


def _call(index: Int, ret: UdfType, var args: List[Expr]) -> Expr:
    return Expr.udf_apply(index, ret.copy(), args^)


def _col_b() -> List[Expr]:
    var out = List[Expr]()
    out.append(Expr.col_ref("b"))
    return out^


def _project(var e: Expr) raises -> LogicalPlan:
    var exprs = ExprArray()
    exprs.append(Expr.alias(e^, "y2"))
    return LogicalPlan.project(exprs^, _scan())


def _list(var u: UdfRef) -> List[UdfRef]:
    var out = List[UdfRef]()
    out.append(u^)
    return out^


def _raw_decode(p: LogicalPlan, udfs: List[UdfRef]) raises -> LogicalPlan:
    var d = plan_envelope_from_bytes(plan_to_bytes_with_udfs(p, udfs))
    return d.take_plan()


def _raw_refusal(p: LogicalPlan, udfs: List[UdfRef]) raises -> String:
    var bytes = plan_to_bytes_with_udfs(p, udfs)
    try:
        _ = plan_envelope_from_bytes(bytes^)
    except e:
        return String(e)
    return String("")


def _bare(p: LogicalPlan) raises -> List[UInt8]:
    """The `WirePlan` of `p`, written by the RAW encoder, which checks nothing:
    bytes the OPTIMIZED decoder alone judges."""
    var env = decode_proto[WirePlanEnvelope](plan_to_bytes(p))
    return encode_proto(env.plan.value())


def _optimized_refusal(var bytes: List[UInt8], udfs: List[UdfRef]) raises -> String:
    try:
        _ = optimized_plan_from_bytes(bytes^, udfs)
    except e:
        return String(e)
    return String("")


def _schema_text(s: Schema) raises -> String:
    var out = String("")
    for i in range(s.num_columns()):
        var f = s.field_at(i)
        out += f.name + ":" + String(Int(f.arrow_type.type_id)) + ("?" if f.nullable else "!") + ","
    return out^


def _same_plan(back: LogicalPlan, p: LogicalPlan, what: String) raises:
    assert_equal(back.structural_hash(), p.structural_hash(), what + ": plan identity")
    assert_equal(_schema_text(back.output_schema), _schema_text(p.output_schema), what + ": output schema")


def _both_ways(p: LogicalPlan, udfs: List[UdfRef], what: String) raises:
    _same_plan(_raw_decode(p, udfs), p, what + " (RAW)")
    var back = optimized_plan_from_bytes(optimized_plan_to_bytes(p, udfs), udfs)
    _same_plan(back, p, what + " (OPTIMIZED)")


def _starts(msg: String, token: String, what: String) raises:
    assert_true(msg.startswith(token), what + ": want " + token + ", got: " + msg)


# ---- round trips ----------------------------------------------------------------------


def test_a_scalar_call_round_trips_in_both_contexts() raises:
    """Defect: an arm dropped or misread in either context, or a call whose
    type the decoder does not take from its entry."""
    var u = _scalar()
    var p = _project(_call(0, u.return_type.value(), _col_b()))
    _both_ways(p, _list(u^), "SCALAR in a project")


def test_udf_index_is_kept_exactly() raises:
    """Defect: a `udf_index` off by one on either side. Two entries with
    different return types: a call of entry 1 must come back typed by entry 1
    and still name index 1, and an index past the list is refused."""
    var udfs = List[UdfRef]()
    udfs.append(_scalar(ArrowType.FLOAT64))
    udfs.append(_scalar(ArrowType.FLOAT32))
    var p = _project(_call(1, udfs[1].return_type.value(), _col_b()))
    var back = _raw_decode(p, udfs)
    ref e = back.project_data_ref().exprs[0].alias_child_ref()
    assert_equal(Int(e.tag), Int(EXPR_UDF_APPLY), "the call survived")
    assert_equal(e.udf_apply_index(), 1, "the index moved")
    assert_equal(Int(back.output_schema.field_at(0).arrow_type.type_id), Int(ArrowType.FLOAT32.type_id), "typed by the wrong entry")
    var past = _project(_call(2, udfs[1].return_type.value(), _col_b()))
    _starts(_raw_refusal(past, udfs), OPTIMIZED_UDF_UNDECLARED, "a call of entry 2 of 2")
    var one = _list(_scalar())
    _starts(_raw_refusal(p, one), OPTIMIZED_UDF_UNDECLARED, "a call of entry 1 of 1")


def test_a_map_batches_node_round_trips() raises:
    """Defect: the frame arm dropping its child, index, keys or schema. A
    grouped frame with a read set naming its key."""
    var rs = List[String]()
    rs.append("a")
    rs.append("b")
    var u = _ref(
        UDF_REF_KIND_MAP_BATCHES_FRAME,
        _cols("a", ArrowType.INT64, "b", ArrowType.FLOAT64),
        _struct(_cols("k", ArrowType.INT64, "v", ArrowType.FLOAT64)),
        read_set=Optional(rs^),
    )
    var gb = List[Expr]()
    gb.append(Expr.col_ref("a"))
    var p = LogicalPlan.map_batches(_scan(), 0, gb^, _out_schema())
    _both_ways(p, _list(u^), "MAP_BATCHES_FRAME")


def _out_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    sb.add_field(Field("v", ArrowType.FLOAT64, True))
    return sb.build()


def _step_ref(stability: UInt8 = UDF_STABILITY_VOLATILE) -> UdfRef:
    """A STEP taking one int64 literal; a literal's type is not nullable."""
    var args = List[UdfType]()
    args.append(_leaf("x", ArrowType.INT64, False))
    return _ref(
        UDF_REF_KIND_STEP, args^,
        _struct(_cols("k", ArrowType.INT64, "v", ArrowType.FLOAT64)), stability,
    )


def _step_plan(index: Int) raises -> LogicalPlan:
    var args = List[ScalarValue]()
    args.append(ScalarValue.from_int(7))
    return LogicalPlan.step(index, args^, _out_schema())


def test_a_step_node_round_trips() raises:
    """Defect: the step arm dropping its index, its literals or its schema."""
    _both_ways(_step_plan(0), _list(_step_ref()), "STEP")


def test_an_agg_udf_measure_round_trips() raises:
    """Defect: AGG_UDF dropped from the vocabulary, or its measure's call not
    decoded against its entry."""
    var u = _ref(UDF_REF_KIND_AGGREGATE, _one(ArrowType.FLOAT64), _leaf("p95", ArrowType.FLOAT64))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_UDF, Optional(_call(0, u.return_type.value(), _col_b())), Optional(String("q"))))
    var gb = ExprArray()
    gb.append(Expr.col_ref("a"))
    var p = LogicalPlan.aggregate(gb^, aggs^, _scan())
    _both_ways(p, _list(u^), "AGG_UDF")


def test_a_row_call_with_a_read_set_round_trips() raises:
    """Defect: the ROW kind or its read set lost on the way."""
    var rs = List[String]()
    rs.append("b")
    var u = _ref(
        UDF_REF_KIND_ROW, _one(ArrowType.FLOAT64), _leaf("r", ArrowType.FLOAT64),
        null_mode=UDF_NULL_MANUAL, read_set=Optional(rs^),
    )
    u.arg_types[0].name = "b"
    var p = _project(_call(0, u.return_type.value(), _col_b()))
    _both_ways(p, _list(u^), "ROW")


# ---- the legacy named forms -------------------------------------------------------------


def _named_udf(kind: UInt8) -> UdfData:
    var ic = List[Tuple[String, UInt8]]()
    ic.append(("b", UInt8(4)))
    var oc = List[Tuple[String, UInt8]]()
    oc.append(("y", UInt8(4)))
    return UdfData(
        kind=kind,
        name=String("margin"),
        input_columns=ic^,
        output_columns=oc^,
        operator_factory_id=UInt32(7001),
        call_site_salt=UInt32(3),
    )


def test_the_named_forms_are_refused_in_optimized_only() raises:
    """Defect: a decoder that accepts `WireUdfCall`, or a node-level `WireUdf`
    on a filter, project or aggregate, in OPTIMIZED. Each is a separate
    decoder arm; each control decodes in RAW."""
    var no_udfs = List[UdfRef]()
    var call = _project(Expr.udf_call("margin", None, ArrowType.FLOAT64, ArrowType.FLOAT64, Expr.col_ref("b")))
    _ = _raw_decode(call, no_udfs)
    _starts(_optimized_refusal(_bare(call), no_udfs), OPTIMIZED_UDF_LEGACY_FORM, "WireUdfCall")

    var filt = LogicalPlan.filter_with_udf(
        Expr.literal(ScalarValue.from_bool(True)), _scan(),
        OwnedPointer[UdfData](_named_udf(UDF_KIND_FILTER)),
    )
    _ = _raw_decode(filt, no_udfs)
    _starts(_optimized_refusal(_bare(filt), no_udfs), OPTIMIZED_UDF_LEGACY_FORM, "a filter's WireUdf")

    var exprs = ExprArray()
    exprs.append(Expr.col_ref("a"))
    var proj = LogicalPlan.project_with_udf(exprs^, _scan(), OwnedPointer[UdfData](_named_udf(UDF_KIND_MAP)))
    _ = _raw_decode(proj, no_udfs)
    _starts(_optimized_refusal(_bare(proj), no_udfs), OPTIMIZED_UDF_LEGACY_FORM, "a project's WireUdf")

    var gb = ExprArray()
    gb.append(Expr.col_ref("a"))
    var ax = AggExprArray()
    ax.append(AggExpr(AGG_SUM, Optional(Expr.col_ref("b")), Optional(String("t"))))
    var agg = LogicalPlan.aggregate_with_udf(gb^, ax^, _scan(), OwnedPointer[UdfData](_named_udf(UDF_KIND_AGG)))
    _ = _raw_decode(agg, no_udfs)
    _starts(_optimized_refusal(_bare(agg), no_udfs), OPTIMIZED_UDF_LEGACY_FORM, "an aggregate's WireUdf")


def test_the_optimized_encoder_refuses_what_the_decoder_would() raises:
    """Defect: a producer that emits a named UDF into an optimized plan and
    learns of it only on the host."""
    var no_udfs = List[UdfRef]()
    var call = _project(Expr.udf_call("margin", None, ArrowType.FLOAT64, ArrowType.FLOAT64, Expr.col_ref("b")))
    var msg = String("")
    try:
        _ = optimized_plan_to_bytes(call, no_udfs)
    except e:
        msg = String(e)
    _starts(msg, OPTIMIZED_UDF_LEGACY_FORM, "the encoder")


# ---- kinds -----------------------------------------------------------------------------


def _of_kind(kind: UInt8) -> UdfRef:
    """An entry of `kind` that is valid on its own: a STEP is VOLATILE, a ROW
    MANUAL; the struct return type is the one the arm tests' nodes output."""
    var stability = UDF_STABILITY_VOLATILE if kind == UDF_REF_KIND_STEP else UDF_STABILITY_STABLE
    var null_mode = UDF_NULL_MANUAL if kind == UDF_REF_KIND_ROW else UDF_NULL_PROPAGATE
    return _ref(
        kind, _one(ArrowType.FLOAT64),
        _struct(_cols("k", ArrowType.INT64, "v", ArrowType.FLOAT64)),
        stability, null_mode,
    )


def _kind_text(kind: UInt8) -> String:
    if kind == UDF_REF_KIND_SCALAR:
        return "SCALAR"
    if kind == UDF_REF_KIND_ROW:
        return "ROW"
    if kind == UDF_REF_KIND_MAP_BATCHES_COLUMN:
        return "MAP_BATCHES_COLUMN"
    if kind == UDF_REF_KIND_AGGREGATE:
        return "AGGREGATE"
    if kind == UDF_REF_KIND_MAP_BATCHES_FRAME:
        return "MAP_BATCHES_FRAME"
    return "STEP"


def test_every_arm_refuses_every_kind_outside_its_set() raises:
    """Defect: an arm whose allowed set holds one kind too many. A sweep of
    every (arm, kind) pair the design refuses (§10.2): a WireUdfApply naming
    a MAP_BATCHES_FRAME or a STEP; a WireMapBatchesNode naming anything but a
    MAP_BATCHES_FRAME; a WireStepNode naming anything but a STEP. The
    admitted pairs are the round trips above (SCALAR, ROW and
    MAP_BATCHES_COLUMN calls, a frame node, a step node, an AGGREGATE as an
    AGG_UDF measure); an AGGREGATE in a WireUdfApply outside a measure has
    its own refusal (test_an_aggregate_entry_only_as_an_agg_udf_measure)."""
    var kinds: List[UInt8] = [
        UDF_REF_KIND_SCALAR, UDF_REF_KIND_ROW, UDF_REF_KIND_MAP_BATCHES_COLUMN,
        UDF_REF_KIND_AGGREGATE, UDF_REF_KIND_MAP_BATCHES_FRAME, UDF_REF_KIND_STEP,
    ]
    for i in range(len(kinds)):
        var k = kinds[i]
        var u = _of_kind(k)
        if k == UDF_REF_KIND_MAP_BATCHES_FRAME or k == UDF_REF_KIND_STEP:
            var p = _project(_call(0, u.return_type.value(), _col_b()))
            _starts(_raw_refusal(p, _list(u.copy())), OPTIMIZED_UDF_KIND_ARM_MISMATCH, "a WireUdfApply naming a " + _kind_text(k))
        if k != UDF_REF_KIND_MAP_BATCHES_FRAME:
            var mb = LogicalPlan.map_batches(_scan(), 0, List[Expr](), _out_schema())
            _starts(_raw_refusal(mb, _list(u.copy())), OPTIMIZED_UDF_KIND_ARM_MISMATCH, "a WireMapBatchesNode naming a " + _kind_text(k))
        if k != UDF_REF_KIND_STEP:
            _starts(_raw_refusal(_step_plan(0), _list(u.copy())), OPTIMIZED_UDF_KIND_ARM_MISMATCH, "a WireStepNode naming a " + _kind_text(k))


def test_each_arm_names_only_its_kinds() raises:
    """Defect: an arm that accepts an entry of another call shape (one entry
    would then be bound to two argument schemas)."""
    var frame = _ref(
        UDF_REF_KIND_MAP_BATCHES_FRAME,
        _cols("a", ArrowType.INT64, "b", ArrowType.FLOAT64),
        _struct(_cols("k", ArrowType.INT64, "v", ArrowType.FLOAT64)),
    )
    var p = _project(_call(0, frame.return_type.value(), _col_b()))
    _starts(_raw_refusal(p, _list(frame^)), OPTIMIZED_UDF_KIND_ARM_MISMATCH, "a WireUdfApply naming a frame")

    var scalar_struct = _ref(UDF_REF_KIND_SCALAR, _one(ArrowType.FLOAT64), _struct(_cols("k", ArrowType.INT64, "v", ArrowType.FLOAT64)))
    var mb = LogicalPlan.map_batches(_scan(), 0, List[Expr](), _out_schema())
    _starts(_raw_refusal(mb, _list(scalar_struct.copy())), OPTIMIZED_UDF_KIND_ARM_MISMATCH, "a WireMapBatchesNode naming a SCALAR")
    _starts(_raw_refusal(_step_plan(0), _list(scalar_struct^)), OPTIMIZED_UDF_KIND_ARM_MISMATCH, "a WireStepNode naming a SCALAR")

    var mbc = _ref(UDF_REF_KIND_MAP_BATCHES_COLUMN, _one(ArrowType.FLOAT64), _leaf("y", ArrowType.FLOAT64))
    var ok = _project(_call(0, mbc.return_type.value(), _col_b()))
    _ = _raw_decode(ok, _list(mbc^))


def test_an_aggregate_entry_only_as_an_agg_udf_measure() raises:
    """Defects: an AGGREGATE entry called outside an AGG_UDF measure, an
    AGG_UDF measure naming a non-AGGREGATE entry, and one whose argument is
    not a call at all."""
    var aggregate = _ref(UDF_REF_KIND_AGGREGATE, _one(ArrowType.FLOAT64), _leaf("p95", ArrowType.FLOAT64))
    var outside = _project(_call(0, aggregate.return_type.value(), _col_b()))
    _starts(_raw_refusal(outside, _list(aggregate^)), OPTIMIZED_UDF_AGGREGATE_OUTSIDE_AGGREGATE, "an AGGREGATE in a project")

    var s = _scalar()
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_UDF, Optional(_call(0, s.return_type.value(), _col_b())), Optional(String("q"))))
    var m = LogicalPlan.aggregate(ExprArray(), aggs^, _scan())
    _starts(_raw_refusal(m, _list(s.copy())), OPTIMIZED_UDF_AGGREGATE_OUTSIDE_AGGREGATE, "an AGG_UDF measure naming a SCALAR")

    var bare = AggExprArray()
    bare.append(AggExpr(AGG_UDF, Optional(Expr.col_ref("b")), Optional(String("q"))))
    var n = LogicalPlan.aggregate(ExprArray(), bare^, _scan())
    _starts(_raw_refusal(n, _list(s^)), OPTIMIZED_UDF_AGGREGATE_OUTSIDE_AGGREGATE, "an AGG_UDF measure that is not a call")


def _udf_measure_with_extra(slot: Int) -> AggExpr:
    """An AGG_UDF measure whose argument is a valid call of entry 0, an
    AGGREGATE, plus column b in argument slot `slot` (1, 2 or 3)."""
    var u = _ref(UDF_REF_KIND_AGGREGATE, _one(ArrowType.FLOAT64), _leaf("p95", ArrowType.FLOAT64))
    var a = AggExpr(AGG_UDF, Optional(_call(0, u.return_type.value(), _col_b())), Optional(String("q")))
    if slot == 1:
        a.child1 = Optional(Expr.col_ref("b"))
    elif slot == 2:
        a.child2 = Optional(Expr.col_ref("b"))
    else:
        a.child3 = Optional(Expr.col_ref("b"))
    return a^


def test_an_agg_udf_measure_carries_one_argument() raises:
    """Defect: an AGG_UDF measure with a second argument beside its call
    admitted (§10.4: it carries one argument, child0). The value gate runs
    first on the wire and refuses the populated slot by its own token
    (PLAN_WIRE_AGG_ARG_DROPPED: AGG_UDF reads one slot), so the UDF check's
    own refusal is reached by a plan built in process
    (`plan_wire_check_udfs`). Each of slots 1, 2 and 3 is refused on its
    own, and the measure without the extra slot is admitted."""
    var u = _ref(UDF_REF_KIND_AGGREGATE, _one(ArrowType.FLOAT64), _leaf("p95", ArrowType.FLOAT64))
    var ok = AggExprArray()
    ok.append(AggExpr(AGG_UDF, Optional(_call(0, u.return_type.value(), _col_b())), Optional(String("q"))))
    plan_wire_check_udfs(LogicalPlan.aggregate(ExprArray(), ok^, _scan()), _list(u.copy()))
    for slot in range(1, 4):
        var aggs = AggExprArray()
        aggs.append(_udf_measure_with_extra(slot))
        var p = LogicalPlan.aggregate(ExprArray(), aggs^, _scan())
        var msg = String("")
        try:
            plan_wire_check_udfs(p, _list(u.copy()))
        except e:
            msg = String(e)
        _starts(msg, OPTIMIZED_UDF_AGGREGATE_OUTSIDE_AGGREGATE, "in process, slot " + String(slot) + " set")
        msg = String("")
        try:
            _ = plan_envelope_from_bytes(plan_to_bytes_with_udfs(p, _list(u.copy())))
        except e:
            msg = String(e)
        _starts(msg, PLAN_WIRE_AGG_ARG_DROPPED, "on the wire, slot " + String(slot) + " set")


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_scalar_call_round_trips_in_both_contexts]()
    suite.test[test_udf_index_is_kept_exactly]()
    suite.test[test_a_map_batches_node_round_trips]()
    suite.test[test_a_step_node_round_trips]()
    suite.test[test_an_agg_udf_measure_round_trips]()
    suite.test[test_a_row_call_with_a_read_set_round_trips]()
    suite.test[test_the_named_forms_are_refused_in_optimized_only]()
    suite.test[test_the_optimized_encoder_refuses_what_the_decoder_would]()
    suite.test[test_each_arm_names_only_its_kinds]()
    suite.test[test_every_arm_refuses_every_kind_outside_its_set]()
    suite.test[test_an_aggregate_entry_only_as_an_agg_udf_measure]()
    suite.test[test_an_agg_udf_measure_carries_one_argument]()
    suite^.run()
