# =============================================================================
# test_plan_wire_udf_args.mojo — a UDF call's arguments, inputs and output
# against its `UdfRef` (optimized_plan_udfs.md §10.2, §10.4)
# =============================================================================
#
# One test per refusal token; each builds a plan whose calls disagree with the
# list in exactly one way, encodes it with the RAW encoder (which checks
# nothing), and requires the decoder to refuse by name, beside a control that
# differs in that one way and decodes. The rule this file holds above all:
# an UNSET read set means every input column, never "whatever `arg_types`
# lists" (test_an_unset_read_set_means_every_input_column).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.expr import Expr, BIN_ADD, BIN_AND
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.udf_data import (
    UDF_NULL_MANUAL,
    UDF_NULL_PROPAGATE,
    UDF_STABILITY_STABLE,
    UDF_STABILITY_VOLATILE,
)
from komira_plan_expr.udf_type import UdfType
from komira_plan_ir.logical_plan import LogicalPlan, ExprArray, AggExprArray
from komira_plan_expr.agg_expr import AggExpr, AGG_UDF
from komira_plan_ir.udf_ref import (
    CodeDigest,
    UdfCode,
    UdfRef,
    UDF_REF_KIND_SCALAR,
    UDF_REF_KIND_AGGREGATE,
    UDF_REF_KIND_STEP,
    UDF_REF_KIND_MAP_BATCHES_FRAME,
    UDF_REF_KIND_ROW,
    CODE_FORM_VALUE,
)
from komira_proto_codec import decode_proto, encode_proto
from komira_plan_proto.plan import WireField, WirePlanEnvelope

from komira_plan_wire import (
    optimized_plan_from_bytes,
    plan_from_bytes,
    plan_to_bytes_with_udfs,
    plan_envelope_from_bytes,
    plan_wire_check_udfs,
    OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH,
    OPTIMIZED_UDF_READ_SET_COLUMN_UNKNOWN,
    OPTIMIZED_UDF_READ_SET_GROUP_KEY,
    OPTIMIZED_UDF_READ_SET_INVALID,
    OPTIMIZED_UDF_SCHEMA_DISAGREES,
    OPTIMIZED_UDF_IN_SCAN_FILTER,
    PLAN_WIRE_FIELD_CHILDREN_BOTH,
    PLAN_WIRE_FIELD_TOO_DEEP,
    PLAN_WIRE_UDFS_DROPPED,
    PLAN_WIRE_MAX_BYTES,
    PLAN_WIRE_TOO_LARGE,
    PLAN_WIRE_OUTPUT_SCHEMA_DIVERGED,
)


# ---- fixtures -----------------------------------------------------------------------


def _leaf(name: String, t: ArrowType, nullable: Bool = True) -> UdfType:
    return UdfType(name, t, Field(name, t, nullable).dtype, nullable)


def _struct(name: String, var kids: List[UdfType]) -> UdfType:
    return UdfType(name, ArrowType.STRUCT, Field(name, ArrowType.STRUCT, True).dtype, True, kids^)


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
    null_mode: UInt8 = UDF_NULL_PROPAGATE,
    var read_set: Optional[List[String]] = None,
) -> UdfRef:
    var stability = UDF_STABILITY_VOLATILE if kind == UDF_REF_KIND_STEP else UDF_STABILITY_STABLE
    return UdfRef(kind, _code(), args^, Optional(ret^), stability, null_mode, read_set^)


def _schema2(a: String, ta: ArrowType, b: String, tb: ArrowType) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(a, ta, True))
    sb.add_field(Field(b, tb, True))
    return sb.build()


def _scan_of(var s: Schema, var filter: Optional[Expr] = None) -> LogicalPlan:
    return LogicalPlan.scan(
        String("/nonexistent/args.parquet"), 0, s^,
        Optional[List[String]](None), filter^, Optional[Int](None),
    )


def _scan() -> LogicalPlan:
    return _scan_of(_schema2("a", ArrowType.INT64, "b", ArrowType.FLOAT64))


def _types(a: String, ta: ArrowType, b: String, tb: ArrowType) -> List[UdfType]:
    var out = List[UdfType]()
    out.append(_leaf(a, ta))
    out.append(_leaf(b, tb))
    return out^


def _one(name: String, t: ArrowType, nullable: Bool = True) -> List[UdfType]:
    var out = List[UdfType]()
    out.append(_leaf(name, t, nullable))
    return out^


def _list(var u: UdfRef) -> List[UdfRef]:
    var out = List[UdfRef]()
    out.append(u^)
    return out^


def _cols(*names: String) -> List[Expr]:
    var out = List[Expr]()
    for n in names:
        out.append(Expr.col_ref(n))
    return out^


def _project(var e: Expr, var child: LogicalPlan) raises -> LogicalPlan:
    var exprs = ExprArray()
    exprs.append(Expr.alias(e^, "y"))
    return LogicalPlan.project(exprs^, child^)


def _refusal(p: LogicalPlan, udfs: List[UdfRef]) raises -> String:
    var bytes = plan_to_bytes_with_udfs(p, udfs)
    try:
        _ = plan_envelope_from_bytes(bytes^)
    except e:
        return String(e)
    return String("")


def _starts(msg: String, token: String, what: String) raises:
    assert_true(msg.startswith(token), what + ": want " + token + ", got: " + msg)


def _decodes(p: LogicalPlan, udfs: List[UdfRef], what: String) raises:
    var msg = _refusal(p, udfs)
    assert_equal(msg, "", what + ": the control was refused")


def _empty() -> Schema:
    var b = SchemaBuilder()
    return b.build()


def _frame_schema() -> Schema:
    return _schema2("k", ArrowType.INT64, "v", ArrowType.FLOAT64)


def _frame_ref(var args: List[UdfType], var read_set: Optional[List[String]]) -> UdfRef:
    return _ref(
        UDF_REF_KIND_MAP_BATCHES_FRAME, args^,
        _struct("out", _types("k", ArrowType.INT64, "v", ArrowType.FLOAT64)),
        read_set=read_set^,
    )


def _frame(var group_by: List[Expr]) raises -> LogicalPlan:
    return LogicalPlan.map_batches(_scan(), 0, group_by^, _frame_schema())


def _names(*ns: String) -> List[String]:
    var out = List[String]()
    for n in ns:
        out.append(n)
    return out^


# ---- argument types ------------------------------------------------------------------


def test_scalar_argument_types_are_exact() raises:
    """Defects: an argument whose type differs from `arg_types` (an int64
    column passed where float64 is declared), and a call with an extra
    argument."""
    var u = _ref(UDF_REF_KIND_SCALAR, _one("x", ArrowType.FLOAT64), _leaf("y", ArrowType.FLOAT64))
    var ok = _project(Expr.udf_apply(0, u.return_type.value().copy(), _cols("b")), _scan())
    _decodes(ok, _list(u.copy()), "float64 into float64")
    var wrong = _project(Expr.udf_apply(0, u.return_type.value().copy(), _cols("a")), _scan())
    _starts(_refusal(wrong, _list(u.copy())), OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH, "int64 into float64")
    var extra = _project(Expr.udf_apply(0, u.return_type.value().copy(), _cols("b", "b")), _scan())
    _starts(_refusal(extra, _list(u.copy())), OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH, "two arguments for one")
    var none = _project(Expr.udf_apply(0, u.return_type.value().copy(), List[Expr]()), _scan())
    _starts(_refusal(none, _list(u^)), OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH, "no argument for one")


def test_an_unset_read_set_means_every_input_column() raises:
    """Defect: an unset read set read as "whatever `arg_types` says". A frame
    with no read set over a 2-column child whose `arg_types` lists 1 column
    is refused; one listing both, in order, decodes; a reordered list is
    refused, and so is one with the input's types in order under other
    names. The same for a ROW call."""
    var gb = List[Expr]()
    _decodes(_frame(List[Expr]()), _list(_frame_ref(_types("a", ArrowType.INT64, "b", ArrowType.FLOAT64), None)), "a frame receiving both columns")
    _starts(
        _refusal(_frame(List[Expr]()), _list(_frame_ref(_one("a", ArrowType.INT64), None))),
        OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH, "a frame listing one of two columns",
    )
    _starts(
        _refusal(_frame(List[Expr]()), _list(_frame_ref(_types("b", ArrowType.FLOAT64, "a", ArrowType.INT64), None))),
        OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH, "a frame listing the columns out of order",
    )
    var row = _ref(UDF_REF_KIND_ROW, _types("a", ArrowType.INT64, "b", ArrowType.FLOAT64), _leaf("r", ArrowType.FLOAT64), null_mode=UDF_NULL_MANUAL)
    var p = _project(Expr.udf_apply(0, row.return_type.value().copy(), _cols("a", "b")), _scan())
    _decodes(p, _list(row.copy()), "a ROW receiving both columns")
    var short = _ref(UDF_REF_KIND_ROW, _one("a", ArrowType.INT64), _leaf("r", ArrowType.FLOAT64), null_mode=UDF_NULL_MANUAL)
    var q = _project(Expr.udf_apply(0, short.return_type.value().copy(), _cols("a")), _scan())
    _starts(_refusal(q, _list(short^)), OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH, "a ROW listing one of two columns")
    # Same types in the same order, other names: the names are part of
    # "exactly" (a check comparing types alone admits both of these).
    _starts(
        _refusal(_frame(List[Expr]()), _list(_frame_ref(_types("x", ArrowType.INT64, "y", ArrowType.FLOAT64), None))),
        OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH, "a frame naming (x, y) over (a, b)",
    )
    var renamed = _ref(UDF_REF_KIND_ROW, _types("x", ArrowType.INT64, "y", ArrowType.FLOAT64), _leaf("r", ArrowType.FLOAT64), null_mode=UDF_NULL_MANUAL)
    var r = _project(Expr.udf_apply(0, renamed.return_type.value().copy(), _cols("a", "b")), _scan())
    _starts(_refusal(r, _list(renamed^)), OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH, "a ROW naming (x, y) over (a, b)")


def test_step_literal_types_are_exact() raises:
    """Defect: a step literal whose type differs from `arg_types`, or a literal
    count that differs."""
    var u = _ref(UDF_REF_KIND_STEP, _one("x", ArrowType.FLOAT64, False), _struct("out", List[UdfType]()))
    var args = List[ScalarValue]()
    args.append(ScalarValue.from_int(7))
    var p = LogicalPlan.step(0, args^, _empty())
    _starts(_refusal(p, _list(u.copy())), OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH, "an int64 literal for a float64")
    var none = LogicalPlan.step(0, List[ScalarValue](), _empty())
    _starts(_refusal(none, _list(u^)), OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH, "no literal for one")
    var nothing = _ref(UDF_REF_KIND_STEP, List[UdfType](), _struct("out", List[UdfType]()))
    _decodes(LogicalPlan.step(0, List[ScalarValue](), _empty()), _list(nothing^), "a step of no arguments returning nothing")


# ---- read sets -----------------------------------------------------------------------


def test_a_frame_read_set_names_child_columns() raises:
    """Defect: a frame read set naming a column the child does not output, or
    declaring a type the child's column does not have."""
    var gb = List[Expr]()
    _decodes(_frame(List[Expr]()), _list(_frame_ref(_one("b", ArrowType.FLOAT64), Optional(_names("b")))), "read set {b}")
    _starts(
        _refusal(_frame(List[Expr]()), _list(_frame_ref(_one("zz", ArrowType.FLOAT64), Optional(_names("zz"))))),
        OPTIMIZED_UDF_READ_SET_COLUMN_UNKNOWN, "read set {zz}",
    )
    _starts(
        _refusal(_frame(List[Expr]()), _list(_frame_ref(_one("b", ArrowType.INT64), Optional(_names("b"))))),
        OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH, "read set {b} declared int64",
    )


def _int_frame(var key: Expr) raises -> LogicalPlan:
    """A frame over (a INT64, b INT64) grouped by the one key `key`."""
    var gb = List[Expr]()
    gb.append(key^)
    return LogicalPlan.map_batches(
        _scan_of(_schema2("a", ArrowType.INT64, "b", ArrowType.INT64)), 0, gb^,
        _frame_schema(),
    )


def _a_plus_b() -> Expr:
    return Expr.binary(BIN_ADD, Expr.col_ref("a"), Expr.col_ref("b"))


def test_a_grouped_frame_reads_its_keys() raises:
    """Defects: a grouped frame whose read set omits a column its `group_by`
    reads; a check that looks at the first key only (group by (b, a) with
    read set {b} omits the second key's column); and one that looks at the
    first column of a key only (the key a + b, with either column named
    alone)."""
    _decodes(_frame(_cols("a")), _list(_frame_ref(_types("a", ArrowType.INT64, "b", ArrowType.FLOAT64), Optional(_names("a", "b")))), "read set {a, b}, group by a")
    _starts(
        _refusal(_frame(_cols("a")), _list(_frame_ref(_one("b", ArrowType.FLOAT64), Optional(_names("b"))))),
        OPTIMIZED_UDF_READ_SET_GROUP_KEY, "read set {b}, group by a",
    )
    _decodes(_frame(_cols("b", "a")), _list(_frame_ref(_types("a", ArrowType.INT64, "b", ArrowType.FLOAT64), Optional(_names("a", "b")))), "read set {a, b}, group by (b, a)")
    _starts(
        _refusal(_frame(_cols("b", "a")), _list(_frame_ref(_one("b", ArrowType.FLOAT64), Optional(_names("b"))))),
        OPTIMIZED_UDF_READ_SET_GROUP_KEY, "read set {b}, group by (b, a)",
    )
    _decodes(_int_frame(_a_plus_b()), _list(_frame_ref(_types("a", ArrowType.INT64, "b", ArrowType.INT64), Optional(_names("a", "b")))), "read set {a, b}, group by a + b")
    _starts(
        _refusal(_int_frame(_a_plus_b()), _list(_frame_ref(_one("a", ArrowType.INT64), Optional(_names("a"))))),
        OPTIMIZED_UDF_READ_SET_GROUP_KEY, "read set {a}, group by a + b",
    )
    _starts(
        _refusal(_int_frame(_a_plus_b()), _list(_frame_ref(_one("b", ArrowType.INT64), Optional(_names("b"))))),
        OPTIMIZED_UDF_READ_SET_GROUP_KEY, "read set {b}, group by a + b",
    )


def test_an_ambiguous_input_is_refused() raises:
    """Defect: a ROW call, or a frame read set, over an input with two columns
    of one name: a field read by name would be ambiguous."""
    var dup = _scan_of(_schema2("a", ArrowType.INT64, "a", ArrowType.INT64))
    var row = _ref(UDF_REF_KIND_ROW, _one("a", ArrowType.INT64), _leaf("r", ArrowType.FLOAT64), null_mode=UDF_NULL_MANUAL, read_set=Optional(_names("a")))
    var p = _project(Expr.udf_apply(0, row.return_type.value().copy(), _cols("a")), dup^)
    _starts(_refusal(p, _list(row^)), OPTIMIZED_UDF_READ_SET_INVALID, "a ROW over (a, a)")
    var dup2 = _scan_of(_schema2("a", ArrowType.INT64, "a", ArrowType.INT64))
    var mb = LogicalPlan.map_batches(dup2^, 0, List[Expr](), _frame_schema())
    _starts(
        _refusal(mb, _list(_frame_ref(_one("a", ArrowType.INT64), Optional(_names("a"))))),
        OPTIMIZED_UDF_READ_SET_INVALID, "a frame reading a of (a, a)",
    )


# ---- output schema ---------------------------------------------------------------------


def _envelope(p: LogicalPlan, udfs: List[UdfRef]) raises -> WirePlanEnvelope:
    return decode_proto[WirePlanEnvelope](plan_to_bytes_with_udfs(p, udfs))


def _refusal_of(env: WirePlanEnvelope) raises -> String:
    try:
        _ = plan_envelope_from_bytes(encode_proto(env))
    except e:
        return String(e)
    return String("")


def test_a_node_schema_follows_its_return_type() raises:
    """Defect: a frame node, or a project column that is a UDF call, whose
    wire output schema disagrees with the `return_type` it derives from, and
    a frame entry whose return type is not a struct."""
    var gb = List[Expr]()
    var frame = _frame_ref(_types("a", ArrowType.INT64, "b", ArrowType.FLOAT64), None)
    var env = _envelope(_frame(List[Expr]()), _list(frame.copy()))
    env.plan.value().output_schema.value().fields[1].arrow_type_id = UInt32(ArrowType.FLOAT32.type_id)
    _starts(_refusal_of(env), OPTIMIZED_UDF_SCHEMA_DISAGREES, "a frame column retyped on the wire")

    var u = _ref(UDF_REF_KIND_SCALAR, _one("x", ArrowType.FLOAT64), _leaf("y", ArrowType.FLOAT64))
    var p = _project(Expr.udf_apply(0, u.return_type.value().copy(), _cols("b")), _scan())
    var env2 = _envelope(p, _list(u^))
    env2.plan.value().output_schema.value().fields[0].nullable = False
    _starts(_refusal_of(env2), OPTIMIZED_UDF_SCHEMA_DISAGREES, "a UDF column made non-nullable on the wire")

    var not_struct = _ref(UDF_REF_KIND_MAP_BATCHES_FRAME, _types("a", ArrowType.INT64, "b", ArrowType.FLOAT64), _leaf("y", ArrowType.FLOAT64))
    var not_struct_msg = _refusal(_frame(List[Expr]()), _list(not_struct^))
    _starts(not_struct_msg, OPTIMIZED_UDF_SCHEMA_DISAGREES, "a frame returning a float64")
    assert_true("is not a struct" in not_struct_msg, "refused for its return type, not for a schema it never derived: " + not_struct_msg)


def _deep() -> UdfType:
    var inner = List[UdfType]()
    inner.append(_leaf("item", ArrowType.FLOAT32))
    var fsl = UdfType("item", ArrowType.FIXED_SIZE_LIST, Field("item", ArrowType.FIXED_SIZE_LIST, True).dtype, True, inner^)
    var mid = List[UdfType]()
    mid.append(fsl^)
    return UdfType("e", ArrowType.LARGE_LIST, Field("e", ArrowType.LARGE_LIST, True).dtype, True, mid^)


def test_a_column_holds_one_level_of_children() raises:
    """Defects: a call whose return type is deeper than an output column holds
    passing a truncated comparison, a wire column whose child has children of
    its own read as flat, and a column stating its children both ways."""
    var u = _ref(UDF_REF_KIND_SCALAR, _one("x", ArrowType.FLOAT64), _deep())
    var p = _project(Expr.udf_apply(0, u.return_type.value().copy(), _cols("b")), _scan())
    _starts(_refusal(p, _list(u^)), PLAN_WIRE_FIELD_TOO_DEEP, "a three-level return type as a column")

    var no_udfs = List[UdfRef]()
    var env = _envelope(_scan(), no_udfs)
    var gchild = env.plan.value().output_schema.value().fields[0].copy()
    gchild.name = "g"
    var child = gchild.copy()
    child.name = "c"
    child.children.append(gchild.copy())
    env.plan.value().output_schema.value().fields[0].children.append(child^)
    _starts(_refusal_of(env), PLAN_WIRE_FIELD_TOO_DEEP, "a wire column with a grandchild")

    var env2 = _envelope(_struct_scan(), no_udfs)
    env2.plan.value().output_schema.value().fields[0].children.append(gchild^)
    _starts(_refusal_of(env2), PLAN_WIRE_FIELD_CHILDREN_BOTH, "a wire column with children both ways")


def _struct_scan() -> LogicalPlan:
    """A scan of one struct column `s {c: int64}`, its child in the flat lists."""
    var f = Field("s", ArrowType.STRUCT, True)
    f._child_names = ["c"]
    f._child_types = [ArrowType.INT64.type_id]
    f._child_nullables = [False]
    var sb = SchemaBuilder()
    sb.add_field(f^)
    return _scan_of(sb.build())


def test_a_column_may_state_its_children_recursively() raises:
    """Defect: a decoder that refuses the recursive form for a one-level
    column (it is admitted in both contexts, §10.3), or reads it differently
    from the flat form. The scan's struct column is rewritten from the flat
    lists into `children` on the wire, in its schema and its node schema, and
    must decode to the same plan."""
    var no_udfs = List[UdfRef]()
    var flat = _envelope(_struct_scan(), no_udfs)
    var rec = flat.copy()
    ref nf = rec.plan.value().output_schema.value().fields[0]
    var kid = nf.copy()
    kid.name = nf.child_names[0]
    kid.arrow_type_id = nf.child_type_ids[0]
    kid.nullable = nf.child_nullables[0]
    kid.child_names = List[String]()
    kid.child_type_ids = List[UInt32]()
    kid.child_nullables = List[Bool]()
    nf.child_names = List[String]()
    nf.child_type_ids = List[UInt32]()
    nf.child_nullables = List[Bool]()
    nf.children.append(kid^)
    var da = plan_envelope_from_bytes(encode_proto(flat))
    var db = plan_envelope_from_bytes(encode_proto(rec))
    var a = da.take_plan()
    var b = db.take_plan()
    var fa = a.output_schema.field_at(0)
    var fb = b.output_schema.field_at(0)
    assert_equal(len(fb._child_names), 1, "the recursive child")
    assert_equal(fb._child_names[0], fa._child_names[0], "child name")
    assert_equal(Int(fb._child_types[0]), Int(fa._child_types[0]), "child type")
    assert_equal(fb._child_nullables[0], fa._child_nullables[0], "child nullability")


# ---- placement and the list ------------------------------------------------------------


def test_a_call_in_a_pushed_scan_filter_is_refused() raises:
    """Defect: a UDF admitted into a scan's pushed filter, where the scan
    would evaluate it."""
    var u = _ref(UDF_REF_KIND_SCALAR, _one("x", ArrowType.FLOAT64), _leaf("p", ArrowType.BOOL))
    var call = Expr.udf_apply(0, u.return_type.value().copy(), _cols("b"))
    var pred = Expr.binary(BIN_AND, call^, Expr.literal(ScalarValue.from_bool(True)))
    var s = _scan_of(_schema2("a", ArrowType.INT64, "b", ArrowType.FLOAT64), Optional(pred^))
    _starts(_refusal(s, _list(u.copy())), OPTIMIZED_UDF_IN_SCAN_FILTER, "a call in a pushed filter")
    var plain = _scan_of(_schema2("a", ArrowType.INT64, "b", ArrowType.FLOAT64), Optional(Expr.literal(ScalarValue.from_bool(True))))
    _decodes(plain, _list(u^), "a pushed filter with no call")


def test_an_agg_udf_column_follows_its_return_type() raises:
    """Defect: an AGG_UDF measure's wire column that disagrees with its call's
    `return_type` refused generically, or not at all; and a project whose wire
    schema drops the UDF column, which the generic check must still catch."""
    var u = _ref(UDF_REF_KIND_AGGREGATE, _one("x", ArrowType.FLOAT64), _leaf("p95", ArrowType.FLOAT64))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_UDF, Optional(Expr.udf_apply(0, u.return_type.value().copy(), _cols("b"))), Optional(String("q"))))
    var gb = ExprArray()
    gb.append(Expr.col_ref("a"))
    var p = LogicalPlan.aggregate(gb^, aggs^, _scan())
    var env = _envelope(p, _list(u.copy()))
    env.plan.value().output_schema.value().fields[1].arrow_type_id = UInt32(ArrowType.INT64.type_id)
    _starts(_refusal_of(env), OPTIMIZED_UDF_SCHEMA_DISAGREES, "an AGG_UDF column retyped on the wire")

    var s = _ref(UDF_REF_KIND_SCALAR, _one("x", ArrowType.FLOAT64), _leaf("y", ArrowType.FLOAT64))
    var q = _project(Expr.udf_apply(0, s.return_type.value().copy(), _cols("b")), _scan())
    var env2 = _envelope(q, _list(s^))
    _ = env2.plan.value().output_schema.value().fields.pop()
    _starts(_refusal_of(env2), PLAN_WIRE_OUTPUT_SCHEMA_DIVERGED, "a wire schema with no UDF column")


def test_an_oversized_optimized_plan_is_refused_before_parsing() raises:
    """Defect: a size cap that is not applied to a bare optimized plan."""
    var big = List[UInt8](length=PLAN_WIRE_MAX_BYTES + 1, fill=UInt8(0))
    var msg = String("")
    try:
        _ = optimized_plan_from_bytes(big^, List[UdfRef]())
    except e:
        msg = String(e)
    _starts(msg, PLAN_WIRE_TOO_LARGE, "16 MiB and one byte")


def test_plan_from_bytes_refuses_a_list_it_cannot_return() raises:
    """Defect: `plan_from_bytes` returning a plan and dropping the `UdfRef`
    list its calls index."""
    var u = _ref(UDF_REF_KIND_SCALAR, _one("x", ArrowType.FLOAT64), _leaf("y", ArrowType.FLOAT64))
    var p = _project(Expr.udf_apply(0, u.return_type.value().copy(), _cols("b")), _scan())
    var msg = String("")
    try:
        _ = plan_from_bytes(plan_to_bytes_with_udfs(p, _list(u^)))
    except e:
        msg = String(e)
    _starts(msg, PLAN_WIRE_UDFS_DROPPED, "plan_from_bytes")


def test_the_gate_runs_on_a_plan_built_in_process() raises:
    """Defect: a check that only the decoders reach. `plan_wire_check_udfs`
    refuses the in-process plan the decoder would, and checks each entry on
    its own first."""
    var u = _ref(UDF_REF_KIND_SCALAR, _one("x", ArrowType.FLOAT64), _leaf("y", ArrowType.FLOAT64))
    var wrong = _project(Expr.udf_apply(0, u.return_type.value().copy(), _cols("a")), _scan())
    var msg = String("")
    try:
        plan_wire_check_udfs(wrong, _list(u.copy()))
    except e:
        msg = String(e)
    _starts(msg, OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH, "in process")
    # A call whose carried type is not its entry's: only an in-process plan
    # can hold one, since the decoder fills the type from the entry.
    var stale = _project(Expr.udf_apply(0, _leaf("y", ArrowType.INT32), _cols("b")), _scan())
    msg = String("")
    try:
        plan_wire_check_udfs(stale, _list(u^))
    except e:
        msg = String(e)
    _starts(msg, OPTIMIZED_UDF_SCHEMA_DISAGREES, "a carried type that is not the entry's")


def main() raises:
    var suite = TestSuite()
    suite.test[test_scalar_argument_types_are_exact]()
    suite.test[test_an_unset_read_set_means_every_input_column]()
    suite.test[test_step_literal_types_are_exact]()
    suite.test[test_a_frame_read_set_names_child_columns]()
    suite.test[test_a_grouped_frame_reads_its_keys]()
    suite.test[test_an_ambiguous_input_is_refused]()
    suite.test[test_a_node_schema_follows_its_return_type]()
    suite.test[test_a_column_holds_one_level_of_children]()
    suite.test[test_a_column_may_state_its_children_recursively]()
    suite.test[test_a_call_in_a_pushed_scan_filter_is_refused]()
    suite.test[test_an_agg_udf_column_follows_its_return_type]()
    suite.test[test_an_oversized_optimized_plan_is_refused_before_parsing]()
    suite.test[test_plan_from_bytes_refuses_a_list_it_cannot_return]()
    suite.test[test_the_gate_runs_on_a_plan_built_in_process]()
    suite^.run()
