# =============================================================================
# test_udf_e2e_plan_wire.mojo: a declared UDF crosses komira_plan_wire and
# comes back with its identity and signature; a live closure is refused at
# encode with the codec's exact message.
# =============================================================================
#
# The UDF is declared once, through the typed sugar (`Map1`/`Map2` over plain
# `def`s). Read off that declaration: the input and output column names and
# dtypes, and the operator-factory id (`UDF_ID`). Not read off it: the name
# string, the call-site salt (a test literal), and on the MAP node the
# null mode, stability and parallelism tags, which are `UdfData`'s
# constructor defaults (PROPAGATE / IMMUTABLE / STATELESS; PROPAGATE is also
# `MapFn.null_mode`'s default, but `NullHandling` exposes no public tag to
# read it through). Three carriers:
#   * a SCALAR UDF CALL in a projection (`Expr.udf_call`, wire `WireUdfCall`);
#   * a MAP UDF node on a Project (`UdfData`, wire `WireUdf`);
#   * a FILTER UDF node on a Filter, every tag set to a NON-ZERO value.
# For each: bytes -> plan -> bytes is byte-identical, the decoded UDF has the
# declared name and signature, and the process-local registry handle the
# original carried does not come back (the decoded UDF is unbound; a handle
# that crossed would name a slot in a registry that does not exist here).
#
# Why the third carrier: on the MAP node, kind (MAP = 0), stability
# (IMMUTABLE = 0), parallelism (STATELESS = 0), has_vector_path (False) and
# the empty key lists are the wire's zero values. An encoder that dropped any
# of them would write the same bytes, and the decoder would hand back the
# same default, so the MAP checks of those fields cannot fail. The FILTER
# node sets each one away from zero and asserts it after decode.
#
# A LIVE CLOSURE is a UDF minted in this process with no name a peer could
# resolve: the same plan with the name empty. Encoding it raises, and the
# message is compared whole, so a refusal for some other reason (or with a
# different remedy) fails the test.
#
# What is not here: komira has no builder from a typed `MapFn` to `UdfData`
# (the `udf_plan_builder` the `UdfData` docs name is not in komira), so the
# test copies the declaration's comptime facts into `UdfData` itself; nor a
# registry, so "resolving the name on the far side" is not exercised.
#
# Planted mutants (reverted):
#   * `_expr_to_wire`, EXPR_UDF_CALL arm, the empty-name guard
#     `byte_length() == 0` -> `byte_length() == 0 and not
#     Bool(e.udf_call_handle())` (a call that carries its handle slips
#     through). Only `test_live_closure_call_is_refused_at_encode` went red
#     ("a live closure was encoded"); komira_plan_wire's own tests stayed
#     green.
#   * `plan_wire_codec._udf_to_wire`, `if not u.is_describable():` ->
#     `if not u.is_describable() and not u.has_registered_handle():` (a
#     closure that carries its handle slips through). Only
#     `test_live_closure_map_node_is_refused_at_encode` went red ("a live
#     closure was encoded"): komira_plan_wire's own refusal test builds its
#     closure without a handle, so it stayed green.
#   * `_expr_to_wire`, EXPR_UDF_CALL arm, the in/out type ids swapped: caught
#     first by komira_plan_wire's own `test_a_udf_call_whose_in_and_out_
#     dtypes_DIFFER_round_trips`, so the library did not publish and this
#     package's tests did not run; it proves nothing about this file.
#   * `_udf_from_wire`, `has_vector_path=w.has_vector_path` -> `False`:
#     caught first by komira_plan_wire's own `test_plan_wire_udf_tier`, so
#     this package's tests did not run. A decode mutant on any one tag field
#     is caught there first; the FILTER test's per-field checks have not been
#     seen red from this file.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, SchemaBuilder
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import ExprArray, LogicalPlan, SOURCE_PARQUET
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.udf_data import (
    UDF_KIND_FILTER,
    UDF_KIND_MAP,
    UDF_NULL_PROPAGATE,
    UDF_NULL_SKIP_NULL_FAST_PATH,
    UDF_PAR_MERGEABLE,
    UDF_PAR_STATELESS,
    UDF_STABILITY_IMMUTABLE,
    UDF_STABILITY_VOLATILE,
    UdfData,
    arrow_type_of_dtag,
)

from komira_udf.schema_descriptor import DT_F64, DT_I64
from komira_expr.typed_udf_sugar import Map1, Map2
from komira_plan_wire import plan_from_bytes, plan_to_bytes


def affine(x: Int64) -> Float64:
    return Float64(x) * 2.0 + 1.0


def line_total(p: Float64, q: Int64) -> Float64:
    return p * Float64(q)


comptime Affine = Map1[f=affine, out_name="affine", in0="qty"]
comptime Total = Map2[f=line_total, out_name="total", in0="price", in1="qty"]


comptime NOT_DESCRIBABLE_TAIL = (
    " carries a UdfData with an EMPTY name, i.e. a UDF minted from a live"
    " in-process closure. What crosses the wire is a DESCRIPTION, and the"
    " peer re-mints its own handle by resolving that description against ITS"
    " OWN registry — so a UDF with no resolvable name has nothing for the"
    " peer to resolve. Encoding it would produce a plan that decodes cleanly"
    " and then cannot run, which is strictly worse than this refusal."
    " REMEDY: register the UDF under a stable name both processes know."
    " (This is the `InMemorySource` rule applied to live CODE: refused at the"
    " wire, fully usable in-process.)"
)


def _scan() raises -> LogicalPlan:
    var sb = SchemaBuilder()
    sb.add_field(Field("price", ArrowType.FLOAT64, True))
    sb.add_field(Field("qty", ArrowType.INT64, True))
    return LogicalPlan.scan(
        String("/nonexistent/udf_e2e.parquet"),
        SOURCE_PARQUET,
        sb.build(),
        Optional[List[String]](None),
        Optional[Expr](None),
        Optional[Int](None),
    )


def _arrow(dtag: Int) -> ArrowType:
    return arrow_type_of_dtag(UInt8(dtag))


def _affine_call(var name: String, handle: Optional[Int]) -> Expr:
    """`affine(qty)` as the plan carries it: both types come from the
    declaration (`Affine`'s input and output schema)."""
    var ins = materialize[Affine.InputSchema]()
    var outs = materialize[Affine.OutputSchema]()
    return Expr.udf_call(
        name^,
        handle,
        _arrow(ins.cols[0].dtype),
        _arrow(outs.cols[0].dtype),
        Expr.col_ref(ins.cols[0].name),
    )


def _project_call(var call: Expr) raises -> LogicalPlan:
    var exprs = ExprArray()
    exprs.append(call^)
    return LogicalPlan.project(exprs^, _scan())


def _total_udf(var name: String, handle: Optional[Int]) -> UdfData:
    """The `UdfData` of `Total`: columns and factory id read off the
    declaration, salt a literal, the tags left at `UdfData`'s defaults."""
    var si = materialize[Total.InputSchema]()
    var so = materialize[Total.OutputSchema]()
    var ins = List[Tuple[String, UInt8]]()
    for i in range(si.num_cols()):
        ins.append((si.cols[i].name, UInt8(si.cols[i].dtype)))
    var outs = List[Tuple[String, UInt8]]()
    outs.append((so.cols[0].name, UInt8(so.cols[0].dtype)))
    return UdfData(
        kind=UDF_KIND_MAP,
        name=name^,
        input_columns=ins^,
        output_columns=outs^,
        operator_factory_id=Total.UDF_ID,
        call_site_salt=UInt32(1),
        registered_handle_id=handle,
    )


def _project_udf(var udf: UdfData) raises -> LogicalPlan:
    var exprs = ExprArray()
    exprs.append(Expr.col_ref(String("price")))
    return LogicalPlan.project_with_udf(
        exprs^, _scan(), OwnedPointer[UdfData](udf^)
    )


def _tagged_filter_udf(handle: Optional[Int]) -> UdfData:
    """`Total`'s columns and factory id on a FILTER node, with every tag the
    wire carries set away from its zero value."""
    var si = materialize[Total.InputSchema]()
    var so = materialize[Total.OutputSchema]()
    var ins = List[Tuple[String, UInt8]]()
    for i in range(si.num_cols()):
        ins.append((si.cols[i].name, UInt8(si.cols[i].dtype)))
    var outs = List[Tuple[String, UInt8]]()
    outs.append((so.cols[0].name, UInt8(so.cols[0].dtype)))
    var pk: List[String] = ["price"]
    var ok: List[String] = ["qty", "price"]
    return UdfData(
        kind=UDF_KIND_FILTER,
        name=String("big_line"),
        input_columns=ins^,
        output_columns=outs^,
        operator_factory_id=Total.UDF_ID,
        call_site_salt=UInt32(3),
        null_mode=UDF_NULL_SKIP_NULL_FAST_PATH,
        stability=UDF_STABILITY_VOLATILE,
        parallelism_tag=UDF_PAR_MERGEABLE,
        partition_keys=pk^,
        order_keys=ok^,
        has_vector_path=True,
        registered_handle_id=handle,
    )


def _filter_udf(var udf: UdfData) raises -> LogicalPlan:
    return LogicalPlan.filter_with_udf(
        Expr.literal(ScalarValue.from_bool(True)),
        _scan(),
        OwnedPointer[UdfData](udf^),
    )


def _assert_refused(plan: LogicalPlan, want: String) raises:
    var refused = False
    try:
        var b = plan_to_bytes(plan)
        _ = b^
    except e:
        refused = True
        # The whole message, as komira_plan_wire's plan_wire_codec.mojo
        # `_udf_not_describable_message(where)` builds it.
        assert_equal(String(e), want)
    assert_true(refused, "a live closure was encoded")


def test_scalar_udf_call_round_trip() raises:
    var plan = _project_call(_affine_call(String("affine"), Optional(Int(5))))
    var b1 = plan_to_bytes(plan)
    assert_true(len(b1) > 0)
    var back = plan_from_bytes(b1.copy())
    var b2 = plan_to_bytes(back)
    assert_true(b1 == b2, "bytes -> plan -> bytes changed the bytes")

    ref e = back.project_data_ref().exprs[0]
    assert_true(e.is_udf_call(), "the decoded projection is not a UDF call")
    assert_equal(e.udf_call_name(), "affine")
    assert_true(e.udf_call_in_type() == ArrowType.INT64, "decoded input type")
    assert_true(e.udf_call_out_type() == ArrowType.FLOAT64, "decoded output type")
    assert_false(Bool(e.udf_call_handle()), "the registry handle crossed the wire")
    assert_equal(e.udf_call_child_ref().col_ref_name(), "qty")
    # The plan's own output column is typed by the declaration's output type.
    assert_true(back.output_schema.field_arrow_type(0) == ArrowType.FLOAT64)

    # The handle is not on the wire at all: the same call with no handle
    # encodes to the same bytes.
    var unbound = _project_call(_affine_call(String("affine"), None))
    assert_true(plan_to_bytes(unbound) == b1, "the handle changed the bytes")


def test_map_udf_node_round_trip() raises:
    var plan = _project_udf(_total_udf(String("line_total"), Optional(Int(9))))
    var b1 = plan_to_bytes(plan)
    var back = plan_from_bytes(b1.copy())
    assert_true(plan_to_bytes(back) == b1, "bytes -> plan -> bytes changed the bytes")
    assert_true(back.has_udf(), "the decoded Project lost its UDF")

    ref u = back.project_data_ref().udf.value()[]
    # `kind`, `stability` and `parallelism_tag` are zero values here (see the
    # header): these three checks cannot fail on a dropped field; the FILTER
    # test is the one that can.
    assert_equal(u.kind, UDF_KIND_MAP)
    assert_equal(u.stability, UDF_STABILITY_IMMUTABLE)
    assert_equal(u.parallelism_tag, UDF_PAR_STATELESS)
    assert_equal(u.null_mode, UDF_NULL_PROPAGATE)
    assert_equal(u.call_site_salt, UInt32(1))
    assert_equal(u.name, "line_total")
    assert_equal(u.operator_factory_id, Total.UDF_ID)
    assert_equal(len(u.input_columns), 2)
    assert_equal(u.input_columns[0][0], "price")
    assert_equal(Int(u.input_columns[0][1]), DT_F64)
    assert_equal(u.input_columns[1][0], "qty")
    assert_equal(Int(u.input_columns[1][1]), DT_I64)
    assert_equal(len(u.output_columns), 1)
    assert_equal(u.output_columns[0][0], "total")
    assert_equal(Int(u.output_columns[0][1]), DT_F64)
    assert_false(u.has_registered_handle(), "the registry handle crossed the wire")
    assert_equal(
        u.structural_hash(),
        _total_udf(String("line_total"), None).structural_hash(),
        "the decoded UDF describes a different UDF",
    )


def test_every_non_zero_tag_crosses_on_a_filter_node() raises:
    var plan = _filter_udf(_tagged_filter_udf(Optional(Int(4))))
    var b1 = plan_to_bytes(plan)
    var back = plan_from_bytes(b1.copy())
    assert_true(plan_to_bytes(back) == b1, "bytes -> plan -> bytes changed the bytes")
    assert_true(back.has_udf(), "the decoded Filter lost its UDF")

    ref u = back.filter_data_ref().udf.value()[]
    assert_equal(u.kind, UDF_KIND_FILTER, "kind")
    assert_equal(u.name, "big_line")
    assert_equal(u.null_mode, UDF_NULL_SKIP_NULL_FAST_PATH, "null_mode")
    assert_equal(u.stability, UDF_STABILITY_VOLATILE, "stability")
    assert_equal(u.parallelism_tag, UDF_PAR_MERGEABLE, "parallelism_tag")
    assert_false(u.is_restartable, "a MERGEABLE UDF decoded as restartable")
    assert_true(u.has_vector_path, "has_vector_path")
    assert_equal(len(u.partition_keys), 1, "partition key count")
    assert_equal(u.partition_keys[0], "price")
    assert_equal(len(u.order_keys), 2, "order key count")
    assert_equal(u.order_keys[0], "qty")
    assert_equal(u.order_keys[1], "price")
    assert_equal(u.call_site_salt, UInt32(3), "call_site_salt")
    assert_equal(u.operator_factory_id, Total.UDF_ID)
    assert_equal(len(u.input_columns), 2)
    assert_equal(u.input_columns[1][0], "qty")
    assert_equal(Int(u.input_columns[1][1]), DT_I64)
    assert_equal(u.output_columns[0][0], "total")
    assert_false(u.has_registered_handle(), "the registry handle crossed the wire")
    assert_equal(
        u.structural_hash(),
        _tagged_filter_udf(None).structural_hash(),
        "the decoded UDF describes a different UDF",
    )


def test_live_closure_call_is_refused_at_encode() raises:
    """The `affine` call of the round-trip test with its name removed: a
    closure this process minted (it has a handle) and no peer could resolve."""
    var plan = _project_call(_affine_call(String(""), Optional(Int(7))))
    _assert_refused(
        plan,
        "PLAN_WIRE_UDF_NOT_DESCRIBABLE: EXPR_UDF_CALL (`WireUdfCall`)"
        + NOT_DESCRIBABLE_TAIL,
    )


def test_live_closure_map_node_is_refused_at_encode() raises:
    var plan = _project_udf(_total_udf(String(""), Optional(Int(9))))
    _assert_refused(
        plan, "PLAN_WIRE_UDF_NOT_DESCRIBABLE: ProjectData" + NOT_DESCRIBABLE_TAIL
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_scalar_udf_call_round_trip]()
    suite.test[test_map_udf_node_round_trip]()
    suite.test[test_every_non_zero_tag_crosses_on_a_filter_node]()
    suite.test[test_live_closure_call_is_refused_at_encode]()
    suite.test[test_live_closure_map_node_is_refused_at_encode]()
    suite^.run()
