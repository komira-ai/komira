# =============================================================================
# test_plan_wire_codec_tampered_wire.mojo — the DECODER's refusals for
# well-framed messages that break the wire contract.
# =============================================================================
#
# Each test encodes a valid plan, decodes it into the generated message types,
# breaks ONE part the codec documents as required, re-encodes it, and requires
# `plan_from_bytes` to refuse by name. The broken parts are the codec's own
# documented refusal cases (`plan_wire_codec.mojo`): an absent required
# message (schema, window frame, as-of tolerance, scan source, pushdown gate,
# partition default), a recursion box that must hold exactly one entry but
# holds none, a half-written WHEN pair, an argument count off the engine's own
# arity table, an empty UDF name, a UDF tag outside its dense range, parallel
# lists of different lengths, an empty parquet path list, and an unset oneof.
#
# These bytes are what a version-skewed or foreign producer can send: the
# generated encoder writes every one of them, so `decode_proto` parses them and
# only the codec's checks stand between them and a plan. A check that is
# missing turns each into a plan the writer never wrote (a dropped child, a
# defaulted frame, an unbounded as-of match) or a process abort.
#
# Every tamper is checked to have changed the bytes, so a message-shape change
# that turned a tamper into a no-op is red here rather than vacuously green.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM
from komira_plan_expr.expr import (
    Expr,
    WhenCaseData,
    BIN_GT,
    UN_NOT,
    STRFNN_REPLACE,
)
from komira_plan_expr.partition_expr import PartitionExpr, PF_LAG, PF_LEAD
from komira_plan_expr.partition_frame import PartitionFrame
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.udf_data import (
    UdfData,
    UDF_KIND_AGG,
    UDF_NULL_SKIP_NULL_FAST_PATH,
    UDF_STABILITY_VOLATILE,
    UDF_PAR_PARTITION_LOCAL,
)
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    AsofTolerance,
    ASOF_BACKWARD,
    CORR_KIND_EXISTS,
    SOURCE_PARQUET,
)
from komira_scan_source.pushdown_gate import PushdownGate
from komira_scan_source.scan_binding import ScanBinding, scan_kind_id
from komira_scan_source.scan_params import ScanParams
from komira_scan_source.source_variant import SourceVariant, SOURCE_VARIANT_ORC

from komira_proto_codec import encode_proto, decode_proto
from komira_plan_proto.plan import (
    WireExpr,
    WirePlan,
    WirePlanEnvelope,
    WireSchema,
)

from komira_plan_wire import plan_to_bytes, plan_from_bytes
from komira_plan_wire.plan_wire_codec import PLAN_WIRE_MALFORMED


# =============================================================================
# Fixtures
# =============================================================================


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    sb.add_field(Field("b", ArrowType.INT64, True))
    sb.add_field(Field("s", ArrowType.STRING, True))
    sb.add_field(Field("ts", ArrowType.INT64, True))
    return sb.build()


def _i(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int64(Int64(v)))


def _scan() raises -> LogicalPlan:
    return LogicalPlan.scan(String("/d/t.parquet"), SOURCE_PARQUET, _schema())


def _orc_scan() raises -> LogicalPlan:
    var b = ScanBinding(
        kind_id=scan_kind_id(String("komira.orc")),
        kind_name=String("komira.orc"),
        name=String("t"),
        params=ScanParams(),
        schema=_schema(),
        fingerprint=UInt64(21),
        structural_id=UInt64(22),
        gate=PushdownGate.conjunctive_comparison(),
    )
    return LogicalPlan.scan_from_source(
        SourceVariant(tag=SOURCE_VARIANT_ORC, binding=b^), _schema()
    )


def _filter(var pred: Expr) raises -> LogicalPlan:
    return LogicalPlan.filter(pred^, _scan())


def _project(var e: Expr) raises -> LogicalPlan:
    var xs = ExprArray()
    xs.append(e^)
    return LogicalPlan.project(xs^, _scan())


def _top_of_range_udf() -> UdfData:
    """kind, null_mode, stability and parallelism_tag at the TOP of their
    ranges (2, 2, 2, 3): the untampered decode is the boundary control for the
    range tests. kind is AGG on a project node; the codec does not check kind
    against the node that carries the UDF."""
    var ic = List[Tuple[String, UInt8]]()
    ic.append(("a", UInt8(2)))
    var oc = List[Tuple[String, UInt8]]()
    oc.append(("y", UInt8(2)))
    return UdfData(
        kind=UDF_KIND_AGG,
        name=String("margin"),
        input_columns=ic^,
        output_columns=oc^,
        operator_factory_id=UInt32(17),
        call_site_salt=UInt32(3),
        null_mode=UDF_NULL_SKIP_NULL_FAST_PATH,
        stability=UDF_STABILITY_VOLATILE,
        parallelism_tag=UDF_PAR_PARTITION_LOCAL,
    )


def _udf_project() raises -> LogicalPlan:
    var xs = ExprArray()
    xs.append(Expr.col_ref(String("a")))
    return LogicalPlan.project_with_udf(
        xs^, _scan(), OwnedPointer[UdfData](_top_of_range_udf())
    )


# =============================================================================
# Envelope plumbing. Each `_root` / `_set_root` pair copies out, and the caller
# writes the edited copy back: the generated types are values. A recursion box
# is replaced at slot 0, never appended to (the encoder writes slot 0 only).
# =============================================================================


def _env(p: LogicalPlan) raises -> WirePlanEnvelope:
    return decode_proto[WirePlanEnvelope](plan_to_bytes(p))


def _root(env: WirePlanEnvelope) raises -> WirePlan:
    if not env.plan:
        raise Error("fixture: the envelope carries no plan")
    return env.plan.value().copy()


def _with_root(var env: WirePlanEnvelope, var w: WirePlan) -> WirePlanEnvelope:
    env.plan = Optional(w^)
    return env^


def _filter_pred(w: WirePlan) raises -> WireExpr:
    if not w.filter or len(w.filter[0].predicate) != 1:
        raise Error("fixture: the root is not a FILTER with one predicate")
    return w.filter[0].predicate[0].copy()


def _with_filter_pred(var w: WirePlan, var e: WireExpr) -> WirePlan:
    var node = w.filter[0].copy()
    node.predicate[0] = e^
    w.filter[0] = node^
    return w^


def _project_expr(w: WirePlan) raises -> WireExpr:
    if not w.project or len(w.project[0].exprs) != 1:
        raise Error("fixture: the root is not a PROJECT of one expression")
    return w.project[0].exprs[0].copy()


def _with_project_expr(var w: WirePlan, var e: WireExpr) -> WirePlan:
    var node = w.project[0].copy()
    node.exprs[0] = e^
    w.project[0] = node^
    return w^


def _assert_refused(
    what: String, good: LogicalPlan, var env: WirePlanEnvelope, detail: String
) raises:
    """`env` re-encoded must differ from `good`'s bytes, and `plan_from_bytes`
    must refuse it with PLAN_WIRE_MALFORMED naming `detail`."""
    var good_bytes = plan_to_bytes(good)
    var bad = encode_proto[WirePlanEnvelope](env)
    assert_true(
        bad != good_bytes,
        what + ": the tamper left the bytes unchanged, so this test tests"
        + " nothing. The message shape moved.",
    )
    var text = String("")
    try:
        var p = plan_from_bytes(bad^)
        _ = p.structural_hash()
    except e:
        text = String(e)
    assert_true(
        text != "",
        what + ": the decoder ACCEPTED a message the codec documents as"
        + " malformed.",
    )
    assert_true(
        text.startswith(PLAN_WIRE_MALFORMED),
        what + ": refused, but not as " + PLAN_WIRE_MALFORMED + ". Got: " + text,
    )
    assert_true(
        detail in text,
        what + ": the refusal does not say `" + detail + "`. Got: " + text,
    )


def _assert_decodes(what: String, p: LogicalPlan) raises:
    var back = plan_from_bytes(plan_to_bytes(p))
    assert_equal(back.structural_hash(), p.structural_hash(), what)


# =============================================================================
# Schemas
# =============================================================================


def test_field_metadata_lists_of_different_lengths_are_refused() raises:
    var plan = _scan()
    var env = _env(plan)
    var w = _root(env)
    var sch = w.output_schema.value().copy()
    var f = sch.fields[0].copy()
    f.metadata_keys = [String("unit")]
    f.metadata_values = List[String]()
    sch.fields[0] = f^
    w.output_schema = Optional(sch^)
    _assert_refused(
        String("field metadata 1 key / 0 values"), plan,
        _with_root(env^, w^), String("metadata keys/values differ in length (1 vs 0)"),
    )


def test_field_child_names_and_type_ids_of_different_lengths_are_refused() raises:
    var plan = _scan()
    var env = _env(plan)
    var w = _root(env)
    var sch = w.output_schema.value().copy()
    var f = sch.fields[0].copy()
    f.child_names = [String("k")]
    f.child_type_ids = List[UInt32]()
    f.child_nullables = [True]
    sch.fields[0] = f^
    w.output_schema = Optional(sch^)
    _assert_refused(
        String("child names 1 / type ids 0"), plan, _with_root(env^, w^),
        String("the three child lists differ in length"),
    )


def test_field_child_nullables_alone_of_a_different_length_are_refused() raises:
    """Names and type ids agree; only the nullable list is short. The second
    operand of the length check must refuse on its own."""
    var plan = _scan()
    var env = _env(plan)
    var w = _root(env)
    var sch = w.output_schema.value().copy()
    var f = sch.fields[0].copy()
    f.child_names = [String("k")]
    f.child_type_ids = [UInt32(ArrowType.INT32.type_id)]
    f.child_nullables = List[Bool]()
    sch.fields[0] = f^
    w.output_schema = Optional(sch^)
    _assert_refused(
        String("child nullables 0 of 1"), plan, _with_root(env^, w^),
        String("the three child lists differ in length"),
    )


def test_an_absent_output_schema_is_refused() raises:
    var plan = _scan()
    var env = _env(plan)
    var w = _root(env)
    w.output_schema = Optional[WireSchema](None)
    _assert_refused(
        String("no output_schema"), plan, _with_root(env^, w^),
        String("the schema message is absent"),
    )


# =============================================================================
# Required messages inside nodes
# =============================================================================


def test_an_absent_window_frame_is_refused_not_defaulted() raises:
    var plan = _filter(
        Expr.window_fn(PF_LAG, String("a"), 1, PartitionFrame.default_ordered())
    )
    var env = _env(plan)
    var w = _root(env)
    var e = _filter_pred(w)
    var wf = e.window_fn.value().copy()
    wf.frame = None
    e.window_fn = Optional(wf^)
    _assert_refused(
        String("window_fn.frame absent"), plan,
        _with_root(env^, _with_filter_pred(w^, e^)),
        String("a window frame is not optional"),
    )


def _asof() raises -> LogicalPlan:
    var lk: List[String] = [String("s")]
    var rk: List[String] = [String("s")]
    return LogicalPlan.asof_join(
        _scan(), _scan(), lk^, rk^, String("ts"), String("ts"),
        ASOF_BACKWARD, AsofTolerance.int64(Int64(5)),
    )


def test_an_absent_asof_tolerance_is_refused_not_unbounded() raises:
    var plan = _asof()
    var env = _env(plan)
    var w = _root(env)
    var node = w.asof_join[0].copy()
    node.tolerance = None
    w.asof_join[0] = node^
    _assert_refused(
        String("asof tolerance absent"), plan, _with_root(env^, w^),
        String("AsofJoinData.tolerance is not optional"),
    )


def test_an_absent_partition_default_value_is_refused() raises:
    var pk: List[String] = [String("a")]
    var ok: List[String] = [String("ts")]
    var desc: List[Bool] = [False]
    var xs = List[PartitionExpr]()
    xs.append(
        PartitionExpr(
            PF_LEAD, String("b"), 1, ScalarValue.from_int64(Int64(0)), True,
            PartitionFrame.default_ordered(), String("next_b"),
        )
    )
    var plan = LogicalPlan.partition_by(pk^, ok^, desc^, xs^, _scan())
    var env = _env(plan)
    var w = _root(env)
    var node = w.partition_by[0].copy()
    var px = node.partition_exprs[0].copy()
    px.default_value = None
    node.partition_exprs[0] = px^
    w.partition_by[0] = node^
    _assert_refused(
        String("partition default absent"), plan, _with_root(env^, w^),
        String("WirePartitionExpr.default_value is absent"),
    )


def test_an_absent_pushdown_gate_is_refused() raises:
    var plan = _orc_scan()
    var env = _env(plan)
    var w = _root(env)
    var node = w.scan[0].copy()
    var src = node.source.value().copy()
    var b = src.binding.value().copy()
    b.pushdown_gate = None
    src.binding = Optional(b^)
    node.source = Optional(src^)
    w.scan[0] = node^
    _assert_refused(
        String("pushdown_gate absent"), plan, _with_root(env^, w^),
        String("the pushdown_gate message is absent"),
    )


def test_an_absent_scan_source_is_refused() raises:
    var plan = _scan()
    var env = _env(plan)
    var w = _root(env)
    var node = w.scan[0].copy()
    node.source = None
    w.scan[0] = node^
    _assert_refused(
        String("scan source absent"), plan, _with_root(env^, w^),
        String("WireScanNode: the source message is absent"),
    )


def test_a_scan_source_with_no_arm_set_is_refused() raises:
    """The source message is present and empty: neither parquet nor binding."""
    var plan = _scan()
    var env = _env(plan)
    var w = _root(env)
    var node = w.scan[0].copy()
    var src = node.source.value().copy()
    src._oneof0_case = 0
    node.source = Optional(src^)
    w.scan[0] = node^
    _assert_refused(
        String("scan source, no arm"), plan, _with_root(env^, w^),
        String("WireScanSource with no oneof arm set (case=0)"),
    )


def test_a_parquet_source_with_no_paths_is_refused() raises:
    var plan = _scan()
    var env = _env(plan)
    var w = _root(env)
    var node = w.scan[0].copy()
    var src = node.source.value().copy()
    var pq = src.parquet.value().copy()
    pq.paths = List[String]()
    src.parquet = Optional(pq^)
    node.source = Optional(src^)
    w.scan[0] = node^
    _assert_refused(
        String("parquet paths empty"), plan, _with_root(env^, w^),
        String("WireParquetSource with an empty path list"),
    )


# =============================================================================
# Recursion boxes that must hold exactly one entry
# =============================================================================


def test_a_filter_with_no_child_is_refused() raises:
    var plan = _filter(Expr.binary(BIN_GT, Expr.col_ref(String("a")), _i(1)))
    var env = _env(plan)
    var w = _root(env)
    var node = w.filter[0].copy()
    node.child = List[WirePlan]()
    w.filter[0] = node^
    _assert_refused(
        String("filter child box empty"), plan, _with_root(env^, w^),
        String("carries 0 children in its recursion box"),
    )


def test_an_expr_with_no_node_arm_is_refused() raises:
    """An empty `WireExpr` message: the arm IS the node kind, so there is no
    node to build."""
    var plan = _filter(Expr.binary(BIN_GT, Expr.col_ref(String("a")), _i(1)))
    var env = _env(plan)
    var w = _root(env)
    var e = _filter_pred(w)
    e._oneof0_case = 0
    _assert_refused(
        String("expr with no arm"), plan,
        _with_root(env^, _with_filter_pred(w^, e^)),
        String("a WireExpr with NO `node` arm set"),
    )


def test_a_unary_op_with_no_child_is_refused() raises:
    var plan = _filter(
        Expr.unary(UN_NOT, Expr.binary(BIN_GT, Expr.col_ref(String("a")), _i(1)))
    )
    var env = _env(plan)
    var w = _root(env)
    var e = _filter_pred(w)
    var u = e.unary_op[0].copy()
    u.child = List[WireExpr]()
    e.unary_op[0] = u^
    _assert_refused(
        String("unary no child"), plan,
        _with_root(env^, _with_filter_pred(w^, e^)),
        String("EXPR_UNARY_OP carries 0 children"),
    )


def test_an_in_list_with_no_child_is_refused() raises:
    var vals: List[ScalarValue] = [ScalarValue.from_int64(Int64(1))]
    var plan = _filter(Expr.in_list_node(Expr.col_ref(String("a")), vals^))
    var env = _env(plan)
    var w = _root(env)
    var e = _filter_pred(w)
    var l = e.in_list[0].copy()
    l.child = List[WireExpr]()
    e.in_list[0] = l^
    _assert_refused(
        String("in_list no child"), plan,
        _with_root(env^, _with_filter_pred(w^, e^)),
        String("EXPR_IN_LIST carries 0 children"),
    )


def test_an_alias_with_no_child_is_refused() raises:
    var plan = _project(Expr.alias(Expr.col_ref(String("a")), String("x")))
    var env = _env(plan)
    var w = _root(env)
    var e = _project_expr(w)
    var a = e.alias_[0].copy()
    a.child = List[WireExpr]()
    e.alias_[0] = a^
    _assert_refused(
        String("alias no child"), plan,
        _with_root(env^, _with_project_expr(w^, e^)),
        String("EXPR_ALIAS carries 0 children"),
    )


def test_a_cast_with_no_child_is_refused() raises:
    var plan = _project(Expr.cast(Expr.col_ref(String("a")), DType.int32))
    var env = _env(plan)
    var w = _root(env)
    var e = _project_expr(w)
    var c = e.cast[0].copy()
    c.child = List[WireExpr]()
    e.cast[0] = c^
    _assert_refused(
        String("cast no child"), plan,
        _with_root(env^, _with_project_expr(w^, e^)),
        String("EXPR_CAST carries 0 children"),
    )


def test_a_correlated_subquery_with_no_inner_plan_is_refused() raises:
    var refs: List[String] = [String("a")]
    var plan = _filter(Expr.correlated_subquery(_scan(), refs^, CORR_KIND_EXISTS))
    var env = _env(plan)
    var w = _root(env)
    var e = _filter_pred(w)
    var cs = e.correlated_subquery[0].copy()
    cs.inner_plan = List[WirePlan]()
    e.correlated_subquery[0] = cs^
    _assert_refused(
        String("subquery no inner plan"), plan,
        _with_root(env^, _with_filter_pred(w^, e^)),
        String("EXPR_CORRELATED_SUBQUERY carries no inner_plan"),
    )


def test_an_agg_expr_claiming_a_child_it_does_not_carry_is_refused() raises:
    var gb = ExprArray()
    gb.append(Expr.col_ref(String("a")))
    var ax = AggExprArray()
    ax.append(
        AggExpr(AGG_SUM, Optional(Expr.col_ref(String("b"))), Optional(String("t")))
    )
    var plan = LogicalPlan.aggregate(gb^, ax^, _scan())
    var env = _env(plan)
    var w = _root(env)
    var node = w.aggregate[0].copy()
    var ae = node.agg_exprs[0].copy()
    assert_true(ae.has_child0, "fixture: SUM(b) does not set has_child0")
    ae.child0 = List[WireExpr]()
    node.agg_exprs[0] = ae^
    w.aggregate[0] = node^
    _assert_refused(
        String("has_child0 with no child0"), plan, _with_root(env^, w^),
        String("WireAggExpr.has_child0 set with no child0"),
    )


# =============================================================================
# Half-written or mis-sized payloads
# =============================================================================


def _when_plan() raises -> LogicalPlan:
    var cases = List[WhenCaseData]()
    cases.append(
        WhenCaseData(
            Expr.binary(BIN_GT, Expr.col_ref("a"), _i(3)),
            _i(100),
        )
    )
    return _project(Expr.when(cases^, _i(300)))


def test_a_when_case_with_no_result_is_refused() raises:
    var plan = _when_plan()
    var env = _env(plan)
    var w = _root(env)
    var e = _project_expr(w)
    var wh = e.when[0].copy()
    var c = wh.cases[0].copy()
    c.result = List[WireExpr]()
    wh.cases[0] = c^
    e.when[0] = wh^
    _assert_refused(
        String("WHEN with no THEN"), plan,
        _with_root(env^, _with_project_expr(w^, e^)),
        String("WireWhen.cases[0] carries condition=True result=False"),
    )


def test_a_when_case_with_no_condition_is_refused() raises:
    var plan = _when_plan()
    var env = _env(plan)
    var w = _root(env)
    var e = _project_expr(w)
    var wh = e.when[0].copy()
    var c = wh.cases[0].copy()
    c.condition = List[WireExpr]()
    wh.cases[0] = c^
    e.when[0] = wh^
    _assert_refused(
        String("THEN with no WHEN"), plan,
        _with_root(env^, _with_project_expr(w^, e^)),
        String("WireWhen.cases[0] carries condition=False result=True"),
    )


def test_a_string_fn_n_off_its_arity_is_refused() raises:
    """REPLACE takes exactly three arguments (`string_fn_n_arity`); two arrive."""
    var args = List[Expr]()
    args.append(Expr.col_ref(String("s")))
    args.append(Expr.col_ref(String("s")))
    args.append(Expr.col_ref(String("s")))
    var plan = _project(
        Expr.alias(Expr.string_fn_n(STRFNN_REPLACE, args^), String("o"))
    )
    var env = _env(plan)
    var w = _root(env)
    var e = _project_expr(w)
    var a = e.alias_[0].copy()
    var inner = a.child[0].copy()
    var sf = inner.string_fn_n[0].copy()
    assert_equal(len(sf.args), 3, "fixture: REPLACE was not encoded with 3 args")
    _ = sf.args.pop()
    inner.string_fn_n[0] = sf^
    a.child[0] = inner^
    e.alias_[0] = a^
    _assert_refused(
        String("REPLACE with 2 args"), plan,
        _with_root(env^, _with_project_expr(w^, e^)),
        String("arrived with 2 argument(s); string_fn_n_arity says 3"),
    )


def test_a_udf_call_with_an_empty_name_is_refused() raises:
    var plan = _filter(
        Expr.udf_call(
            String("affine"), Optional[Int](None), ArrowType.INT64,
            ArrowType.INT64, Expr.col_ref(String("a")),
        )
    )
    var env = _env(plan)
    var w = _root(env)
    var e = _filter_pred(w)
    var uc = e.udf_call[0].copy()
    uc.name = String("")
    e.udf_call[0] = uc^
    _assert_refused(
        String("udf_call empty name"), plan,
        _with_root(env^, _with_filter_pred(w^, e^)),
        String("EXPR_UDF_CALL carries an EMPTY name"),
    )


# =============================================================================
# UDF tags outside their dense ranges
# =============================================================================


def _udf_tag_refused(field: String, value: UInt32) raises:
    var plan = _udf_project()
    var env = _env(plan)
    var w = _root(env)
    var node = w.project[0].copy()
    var u = node.udf.value().copy()
    if field == "kind":
        u.kind = value
    elif field == "null_mode":
        u.null_mode = value
    elif field == "stability":
        u.stability = value
    else:
        u.parallelism_tag = value
    node.udf = Optional(u^)
    w.project[0] = node^
    _assert_refused(
        String("WireUdf.") + field + " = " + String(value), plan,
        _with_root(env^, w^),
        String(".") + field + " = " + String(value)
        + " is outside the declared range",
    )


def test_every_udf_tag_one_past_its_range_is_refused() raises:
    """Each tag at the first value past its range is refused and named; the
    untampered plan, whose kind, null_mode, stability and parallelism_tag sit
    AT the top of their ranges, decodes. Together they hold each bound exactly: a
    bound moved down refuses the control, a bound moved up admits the tamper."""
    _assert_decodes(String("udf at the top of every range"), _udf_project())
    _udf_tag_refused(String("kind"), UInt32(3))
    _udf_tag_refused(String("null_mode"), UInt32(3))
    _udf_tag_refused(String("stability"), UInt32(3))
    _udf_tag_refused(String("parallelism_tag"), UInt32(4))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
