# =============================================================================
# test_plan_wire_udf_ref.mojo — one `UdfRef` to bytes and back, and every
# refusal an entry earns on its own (optimized_plan_udfs.md §10.3, §10.4)
# =============================================================================
#
# Each test names the defect it catches. The refusal tests build a `UdfRef`
# that is wrong in exactly one way, encode it (the encoder writes what it is
# given), and require `udf_ref_from_bytes` to refuse it with the design's
# token; every refusal has a control that differs in that one field and is
# admitted, so a decoder that refused everything would fail the controls.
#
# PRESENCE. An unset `read_set` reads every input column and an empty one
# reads none; they must decode to different IR values and encode to different
# bytes. `test_unset_and_empty_read_set_differ` holds both directions, and
# `test_two_plans_differing_only_in_an_empty_read_set_encode_apart` holds it
# at the plan level, through a RAW envelope.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, SchemaBuilder
from komira_plan_expr.expr import Expr
from komira_plan_expr.udf_data import (
    UDF_NULL_MANUAL,
    UDF_NULL_PROPAGATE,
    UDF_NULL_SKIP_NULL_FAST_PATH,
    UDF_STABILITY_STABLE,
    UDF_STABILITY_VOLATILE,
)
from komira_plan_expr.udf_type import UdfType, udf_type_same
from komira_plan_ir.logical_plan import LogicalPlan, ExprArray
from komira_plan_ir.udf_ref import (
    CodeDigest,
    UdfCode,
    UdfRef,
    UdfResources,
    UDF_REF_KIND_SCALAR,
    UDF_REF_KIND_ROW,
    UDF_REF_KIND_STEP,
    UDF_REF_KIND_MAP_BATCHES_FRAME,
    CODE_FORM_PACKAGE,
    CODE_FORM_VALUE,
)
from komira_proto_codec import decode_proto, encode_proto
from komira_plan_proto.plan import UdfRef as WireUdfRef, UdfKind, UdfStability, CodeForm

from komira_plan_wire import (
    plan_to_bytes_with_udfs,
    plan_envelope_from_bytes,
    udf_ref_from_bytes,
    udf_ref_to_bytes,
    udf_runtime_id_is_valid,
    OPTIMIZED_UDF_RETURN_TYPE_MISSING,
    OPTIMIZED_UDF_RUNTIME_MALFORMED,
    OPTIMIZED_UDF_ROW_NULL_MODE,
    OPTIMIZED_UDF_STEP_NOT_VOLATILE,
    OPTIMIZED_UDF_READ_SET_KIND,
    OPTIMIZED_UDF_READ_SET_INVALID,
    OPTIMIZED_UDF_READ_SET_ARG_MISMATCH,
    PLAN_WIRE_FIELD_CHILDREN_BOTH,
    PLAN_WIRE_MALFORMED,
    PLAN_WIRE_MAX_BYTES,
    PLAN_WIRE_TOO_LARGE,
)


# ---- fixtures -----------------------------------------------------------------------


def _leaf(name: String, t: ArrowType, nullable: Bool = True) -> UdfType:
    """A type with no children, its DType the one `Field` derives."""
    return UdfType(name, t, Field(name, t, nullable).dtype, nullable)


def _struct(name: String, var kids: List[UdfType]) -> UdfType:
    return UdfType(
        name, ArrowType.STRUCT, Field(name, ArrowType.STRUCT, True).dtype,
        True, kids^,
    )


def _deep() -> UdfType:
    """list<fixed_size_list<float32>>: three levels, so a codec that carried
    one level of children (the flat lists 13-15) loses the grandchild."""
    var inner = List[UdfType]()
    inner.append(_leaf("item", ArrowType.FLOAT32))
    var fsl = UdfType(
        "item", ArrowType.FIXED_SIZE_LIST,
        Field("item", ArrowType.FIXED_SIZE_LIST, True).dtype, True, inner^,
    )
    var mid = List[UdfType]()
    mid.append(fsl^)
    return UdfType(
        "embedding", ArrowType.LARGE_LIST,
        Field("embedding", ArrowType.LARGE_LIST, True).dtype, True, mid^,
    )


def _sha(fill: UInt8, n: Int = 32) -> List[UInt8]:
    var b = List[UInt8]()
    for _ in range(n):
        b.append(fill)
    return b^


def _code(runtime: String = "komira/python") -> UdfCode:
    var digests = List[CodeDigest]()
    digests.append(CodeDigest("payload", _sha(0xAB)))
    var desc: List[UInt8] = [7, 8, 9]
    return UdfCode(runtime, CODE_FORM_VALUE, "", digests^, UInt32(2), desc^)


def _scalar(ret: UdfType) -> UdfRef:
    """A SCALAR float64 -> `ret` UdfRef with no read set."""
    var args = List[UdfType]()
    args.append(_leaf("x", ArrowType.FLOAT64))
    return UdfRef(
        UDF_REF_KIND_SCALAR, _code(), args^, Optional(ret.copy()),
        UDF_STABILITY_STABLE, UDF_NULL_PROPAGATE,
    )


def _row(var read_set: Optional[List[String]]) -> UdfRef:
    """A MANUAL ROW over (a: int64, b: float64), with `read_set`; `arg_types`
    are the read set's columns when it is set, both columns when it is not."""
    var args = List[UdfType]()
    if read_set:
        for i in range(len(read_set.value())):
            var n = read_set.value()[i]
            args.append(_leaf(n, ArrowType.INT64 if n == "a" else ArrowType.FLOAT64))
    else:
        args.append(_leaf("a", ArrowType.INT64))
        args.append(_leaf("b", ArrowType.FLOAT64))
    return UdfRef(
        UDF_REF_KIND_ROW, _code(), args^, Optional(_leaf("r", ArrowType.FLOAT64)),
        UDF_STABILITY_STABLE, UDF_NULL_MANUAL, read_set^,
    )


def _names(a: String, b: String) -> List[String]:
    var out = List[String]()
    out.append(a)
    out.append(b)
    return out^


def _refused(u: UdfRef, token: String, what: String) raises:
    """`u` encodes, and decoding it refuses with `token`."""
    var bytes = udf_ref_to_bytes(u)
    var msg = String("")
    try:
        _ = udf_ref_from_bytes(bytes^)
    except e:
        msg = String(e)
    assert_true(msg.startswith(token), what + ": want " + token + ", got: " + msg)


def _admitted(u: UdfRef, what: String) raises -> UdfRef:
    var bytes = udf_ref_to_bytes(u)
    try:
        return udf_ref_from_bytes(bytes^)
    except e:
        raise Error(what + ": the control was refused: " + String(e))


def _refused_bytes(var bytes: List[UInt8], token: String, what: String) raises:
    var msg = String("")
    try:
        _ = udf_ref_from_bytes(bytes^)
    except e:
        msg = String(e)
    assert_true(msg.startswith(token), what + ": want " + token + ", got: " + msg)


def _same_bytes(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


# ---- the round trip ------------------------------------------------------------------


def test_every_field_survives_and_a_grandchild_too() raises:
    """Defect: a field the codec drops, or a `WireField` that carries one level
    of children and drops a grandchild (`list<fixed_size_list<float32>>`
    loses its float32). Every field is set to a value other than its default
    and read back; the nested types are compared whole."""
    var args = List[UdfType]()
    args.append(_deep())
    var kids = List[UdfType]()
    kids.append(_leaf("score", ArrowType.FLOAT64, False))
    kids.append(_deep())
    var blobs = List[List[UInt8]]()
    blobs.append(_sha(0x11))
    var u = UdfRef(
        UDF_REF_KIND_MAP_BATCHES_FRAME,
        _code(),
        args^,
        Optional(_struct("out", kids^)),
        UDF_STABILITY_STABLE,
        UDF_NULL_PROPAGATE,
        None,
        Optional(_leaf("state", ArrowType.BINARY)),
        blobs^,
        UdfResources(UInt64(1 << 30), UInt32(3), UInt32(256), UInt64(9000), UInt32(4)),
        True,
    )
    var back = _admitted(u, "full UdfRef")
    assert_equal(Int(back.kind), Int(UDF_REF_KIND_MAP_BATCHES_FRAME), "kind")
    assert_equal(back.code.runtime, "komira/python", "code.runtime")
    assert_equal(Int(back.code.form), Int(CODE_FORM_VALUE), "code.form")
    assert_equal(len(back.code.code), 1, "code.code")
    assert_equal(back.code.code[0].role, "payload", "code.code[0].role")
    assert_equal(len(back.code.code[0].sha256), 32, "code.code[0].sha256")
    assert_equal(Int(back.code.descriptor_version), 2, "descriptor_version")
    assert_equal(len(back.code.descriptor), 3, "descriptor")
    assert_equal(len(back.arg_types), 1, "arg_types")
    assert_true(udf_type_same(back.arg_types[0], _deep(), True), "arg_types[0], with its grandchild")
    assert_equal(back.arg_types[0].depth(), 3, "the argument type is three levels deep")
    assert_true(udf_type_same(back.return_type.value(), u.return_type.value(), True), "return_type")
    assert_true(udf_type_same(back.state_type.value(), u.state_type.value(), True), "state_type")
    assert_equal(len(back.data_blobs), 1, "data_blobs")
    assert_equal(Int(back.data_blobs[0][31]), 0x11, "data_blobs[0]")
    assert_equal(Int(back.stability), Int(UDF_STABILITY_STABLE), "stability")
    assert_equal(Int(back.null_mode), Int(UDF_NULL_PROPAGATE), "null_mode")
    assert_equal(back.resources.worker_mem_bytes, UInt64(1 << 30), "worker_mem_bytes")
    assert_equal(back.resources.max_workers, UInt32(3), "max_workers")
    assert_equal(back.resources.max_batch_rows, UInt32(256), "max_batch_rows")
    assert_equal(back.resources.max_runtime_ms, UInt64(9000), "max_runtime_ms")
    assert_equal(back.resources.max_concurrent_calls, UInt32(4), "max_concurrent_calls")
    assert_true(back.preserves_event_time, "preserves_event_time")
    assert_false(Bool(back.read_set), "read_set stays unset")


def test_unset_and_empty_read_set_differ() raises:
    """Defects: a decoder that maps an empty read set to unset, and an encoder
    that drops an empty read set (so the two get one encoding, one identity).
    Both directions: the bytes differ, and each decodes to its own value."""
    var unset = _row(None)
    var empty = UdfRef(
        UDF_REF_KIND_ROW, _code(), List[UdfType](), Optional(_leaf("r", ArrowType.FLOAT64)),
        UDF_STABILITY_STABLE, UDF_NULL_MANUAL, Optional(List[String]()),
    )
    # The empty read set receives no column, so its arg_types are empty too.
    var b_unset = udf_ref_to_bytes(unset)
    var b_empty = udf_ref_to_bytes(empty)
    assert_false(_same_bytes(b_unset, b_empty), "unset and empty read sets encode to the same bytes")
    var w = decode_proto[WireUdfRef](b_empty.copy())
    assert_true(Bool(w.read_set), "the empty read set is not on the wire at all")
    var back_empty = udf_ref_from_bytes(b_empty^)
    assert_true(Bool(back_empty.read_set), "an empty read set decoded as unset")
    assert_equal(len(back_empty.read_set.value()), 0, "the empty read set gained names")
    var back_unset = udf_ref_from_bytes(b_unset^)
    assert_false(Bool(back_unset.read_set), "an unset read set decoded as set")


def _row_plan() raises -> LogicalPlan:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    var schema = sb.build()
    return LogicalPlan.scan(
        String("/nonexistent/udf_ref.parquet"), 0, schema^,
        Optional[List[String]](None), Optional[Expr](None), Optional[Int](None),
    )


def test_two_plans_differing_only_in_an_empty_read_set_encode_apart() raises:
    """Defect: an encoder that drops an empty `read_set`, so a plan whose UDF
    reads no column and one whose UDF reads every column hash the same. The
    two envelopes differ only in that one `UdfRef`, and their bytes must
    differ; each decodes back to its own presence."""
    var unset_list = List[UdfRef]()
    var u = _row(None)
    u.arg_types = List[UdfType]()
    unset_list.append(u^)
    var empty_list = List[UdfRef]()
    var e = _row(Optional(List[String]()))
    empty_list.append(e^)
    var a = plan_to_bytes_with_udfs(_row_plan(), unset_list)
    var b = plan_to_bytes_with_udfs(_row_plan(), empty_list)
    assert_false(_same_bytes(a, b), "two plans that differ in an empty read set encode the same")
    var da = plan_envelope_from_bytes(a^)
    var db = plan_envelope_from_bytes(b^)
    assert_false(Bool(da.udfs[0].read_set), "the unset read set came back set")
    assert_true(Bool(db.udfs[0].read_set), "the empty read set came back unset")


# ---- one test per refusal --------------------------------------------------------------


def test_return_type_missing() raises:
    """Defect: an admission that accepts a `UdfRef` with no `return_type`."""
    var u = _scalar(_leaf("y", ArrowType.FLOAT64))
    _ = _admitted(u, "a UdfRef with a return_type")
    u.return_type = None
    _refused(u, OPTIMIZED_UDF_RETURN_TYPE_MISSING, "no return_type")


def test_runtime_malformed() raises:
    """Defects: a grammar check that admits an id outside
    `<namespace>/<name>`, a missing form, an empty PACKAGE entry, a digest that
    is not 32 bytes, or no `code` at all. Each control shape is admitted."""
    var ok = _scalar(_leaf("y", ArrowType.FLOAT64))
    _ = _admitted(ok, "komira/python")
    assert_true(udf_runtime_id_is_valid("example.org/go"), "a DNS namespace")
    assert_true(udf_runtime_id_is_valid("komira-test/x_1.2"), "the part alphabet")
    var bad_ids = List[String]()
    bad_ids.append("Komira/python")
    bad_ids.append("komira")
    bad_ids.append("komira/python/3")
    bad_ids.append("/python")
    bad_ids.append("komira/")
    bad_ids.append("komira/.python")
    bad_ids.append("komira/py thon")
    var long_part = String("a")
    for _ in range(63):
        long_part += "b"
    bad_ids.append("komira/" + long_part)
    for i in range(len(bad_ids)):
        assert_false(udf_runtime_id_is_valid(bad_ids[i]), "admitted '" + bad_ids[i] + "'")
        var u = _scalar(_leaf("y", ArrowType.FLOAT64))
        u.code.runtime = bad_ids[i]
        _refused(u, OPTIMIZED_UDF_RUNTIME_MALFORMED, "runtime '" + bad_ids[i] + "'")
    var max_part = String("a")
    for _ in range(62):
        max_part += "b"
    assert_true(udf_runtime_id_is_valid("komira/" + max_part), "a 63-byte part")

    var pkg = _scalar(_leaf("y", ArrowType.FLOAT64))
    pkg.code.form = CODE_FORM_PACKAGE
    pkg.code.entry = "pkg.mod:score"
    _ = _admitted(pkg, "a PACKAGE with an entry")
    pkg.code.entry = ""
    _refused(pkg, OPTIMIZED_UDF_RUNTIME_MALFORMED, "a PACKAGE with no entry")

    var short = _scalar(_leaf("y", ArrowType.FLOAT64))
    short.code.code[0].sha256 = _sha(0xAB, 31)
    _refused(short, OPTIMIZED_UDF_RUNTIME_MALFORMED, "a 31-byte digest")

    var w = decode_proto[WireUdfRef](udf_ref_to_bytes(_scalar(_leaf("y", ArrowType.FLOAT64))))
    w.code.value().form = CodeForm(0)
    _refused_bytes(encode_proto(w), OPTIMIZED_UDF_RUNTIME_MALFORMED, "form unset")
    var w2 = decode_proto[WireUdfRef](udf_ref_to_bytes(_scalar(_leaf("y", ArrowType.FLOAT64))))
    w2.code = None
    _refused_bytes(encode_proto(w2), OPTIMIZED_UDF_RUNTIME_MALFORMED, "no code")


def test_row_null_mode() raises:
    """Defect: an admission that accepts a ROW under PROPAGATE."""
    var u = _row(None)
    _ = _admitted(u, "a MANUAL ROW")
    u.null_mode = UDF_NULL_PROPAGATE
    _refused(u, OPTIMIZED_UDF_ROW_NULL_MODE, "a PROPAGATE ROW")


def test_step_not_volatile() raises:
    """Defect: a STEP admitted as STABLE; a step runs once and every call
    counts."""
    var u = UdfRef(
        UDF_REF_KIND_STEP, _code(), List[UdfType](),
        Optional(_struct("out", List[UdfType]())),
        UDF_STABILITY_VOLATILE, UDF_NULL_MANUAL,
    )
    _ = _admitted(u, "a VOLATILE STEP")
    u.stability = UDF_STABILITY_STABLE
    _refused(u, OPTIMIZED_UDF_STEP_NOT_VOLATILE, "a STABLE STEP")


def test_read_set_kind() raises:
    """Defect: an admission that accepts a read set on a SCALAR or a STEP."""
    var s = _scalar(_leaf("y", ArrowType.FLOAT64))
    s.read_set = Optional(List[String]())
    _refused(s, OPTIMIZED_UDF_READ_SET_KIND, "a read set on a SCALAR")
    var st = UdfRef(
        UDF_REF_KIND_STEP, _code(), List[UdfType](),
        Optional(_struct("out", List[UdfType]())),
        UDF_STABILITY_VOLATILE, UDF_NULL_MANUAL, Optional(List[String]()),
    )
    _refused(st, OPTIMIZED_UDF_READ_SET_KIND, "a read set on a STEP")


def test_read_set_invalid() raises:
    """Defect: an admission that accepts a read set with a repeated, an empty
    or an unsorted name. The control, ascending ("a", "b"), is admitted."""
    _ = _admitted(_row(Optional(_names("a", "b"))), "read set [a, b]")
    _refused(_row(Optional(_names("a", "a"))), OPTIMIZED_UDF_READ_SET_INVALID, "a repeated name")
    _refused(_row(Optional(_names("b", "a"))), OPTIMIZED_UDF_READ_SET_INVALID, "an unsorted read set")
    _refused(_row(Optional(_names("", "a"))), OPTIMIZED_UDF_READ_SET_INVALID, "an empty name")


def test_read_set_arg_mismatch() raises:
    """Defect: an admission that accepts `arg_types` whose names or count
    differ from the read set's."""
    var renamed = _row(Optional(_names("a", "b")))
    renamed.arg_types[1].name = "c"
    _refused(renamed, OPTIMIZED_UDF_READ_SET_ARG_MISMATCH, "arg_types names a column the read set does not")
    var short = _row(Optional(_names("a", "b")))
    _ = short.arg_types.pop()
    _refused(short, OPTIMIZED_UDF_READ_SET_ARG_MISMATCH, "one arg_types entry for two names")


def test_enums_outside_their_values_are_malformed() raises:
    """Defect: a decoder that reads UNSPECIFIED (wire 0) or an unknown enum
    number as a value, or that admits SKIP_NULL_FAST_PATH in a UdfRef."""
    var w = decode_proto[WireUdfRef](udf_ref_to_bytes(_scalar(_leaf("y", ArrowType.FLOAT64))))
    w.kind = UdfKind(0)
    _refused_bytes(encode_proto(w), PLAN_WIRE_MALFORMED, "kind UNSPECIFIED")
    var w2 = decode_proto[WireUdfRef](udf_ref_to_bytes(_scalar(_leaf("y", ArrowType.FLOAT64))))
    w2.kind = UdfKind(7)
    _refused_bytes(encode_proto(w2), PLAN_WIRE_MALFORMED, "kind 7")
    var w3 = decode_proto[WireUdfRef](udf_ref_to_bytes(_scalar(_leaf("y", ArrowType.FLOAT64))))
    w3.stability = UdfStability(0)
    _refused_bytes(encode_proto(w3), PLAN_WIRE_MALFORMED, "stability UNSPECIFIED")
    var skip = _scalar(_leaf("y", ArrowType.FLOAT64))
    skip.null_mode = UDF_NULL_SKIP_NULL_FAST_PATH
    _refused(skip, PLAN_WIRE_MALFORMED, "SKIP_NULL_FAST_PATH")


def test_children_both() raises:
    """Defect: a decoder that reads a `WireField` carrying `children` and the
    flat child lists together as either one."""
    var w = decode_proto[WireUdfRef](udf_ref_to_bytes(_scalar(_deep())))
    w.return_type.value().child_names.append("x")
    w.return_type.value().child_type_ids.append(UInt32(ArrowType.INT64.type_id))
    w.return_type.value().child_nullables.append(True)
    _refused_bytes(encode_proto(w), PLAN_WIRE_FIELD_CHILDREN_BOTH, "children and the flat lists")


def test_a_udf_type_may_state_one_level_flat() raises:
    """Defect: a decoder that refuses, or misreads, a UDF type whose one level
    of children arrives in the flat lists (13-15) instead of `children`; and
    one that admits flat lists of different lengths or unpaired metadata."""
    var w = decode_proto[WireUdfRef](udf_ref_to_bytes(_scalar(_leaf("y", ArrowType.FLOAT64))))
    w.return_type.value().arrow_type_id = UInt32(ArrowType.STRUCT.type_id)
    w.return_type.value().child_names.append("k")
    w.return_type.value().child_type_ids.append(UInt32(ArrowType.INT64.type_id))
    w.return_type.value().child_nullables.append(False)
    var back = udf_ref_from_bytes(encode_proto(w))
    ref t = back.return_type.value()
    assert_equal(len(t.children), 1, "the flat child")
    assert_equal(t.children[0].name, "k", "its name")
    assert_equal(Int(t.children[0].arrow_type.type_id), Int(ArrowType.INT64.type_id), "its type")
    assert_false(t.children[0].nullable, "its nullability")
    assert_equal(t.children[0].dtype, Field("k", ArrowType.INT64, False).dtype, "its DType, as a Field derives it")

    var uneven = w.copy()
    uneven.return_type.value().child_nullables.append(True)
    _refused_bytes(encode_proto(uneven), PLAN_WIRE_MALFORMED, "flat child lists of different lengths")
    var meta = w.copy()
    meta.return_type.value().metadata_keys.append("unit")
    _refused_bytes(encode_proto(meta), PLAN_WIRE_MALFORMED, "a metadata key with no value")


def test_absent_resources_decode_as_the_host_defaults() raises:
    """Defect: a decoder that refuses a `UdfRef` with no `resources` message
    (every field of it means "the host chooses" at 0), or invents values."""
    var w = decode_proto[WireUdfRef](udf_ref_to_bytes(_scalar(_leaf("y", ArrowType.FLOAT64))))
    w.resources = None
    var back = udf_ref_from_bytes(encode_proto(w))
    assert_equal(back.resources.worker_mem_bytes, UInt64(0), "worker_mem_bytes")
    assert_equal(back.resources.max_workers, UInt32(0), "max_workers")


def test_an_oversized_udf_ref_is_refused_before_parsing() raises:
    """Defect: a size cap that is not applied to one entry's bytes."""
    var big = List[UInt8](length=PLAN_WIRE_MAX_BYTES + 1, fill=UInt8(0))
    _refused_bytes(big^, PLAN_WIRE_TOO_LARGE, "16 MiB and one byte")


def main() raises:
    var suite = TestSuite()
    suite.test[test_every_field_survives_and_a_grandchild_too]()
    suite.test[test_unset_and_empty_read_set_differ]()
    suite.test[test_two_plans_differing_only_in_an_empty_read_set_encode_apart]()
    suite.test[test_return_type_missing]()
    suite.test[test_runtime_malformed]()
    suite.test[test_row_null_mode]()
    suite.test[test_step_not_volatile]()
    suite.test[test_read_set_kind]()
    suite.test[test_read_set_invalid]()
    suite.test[test_read_set_arg_mismatch]()
    suite.test[test_enums_outside_their_values_are_malformed]()
    suite.test[test_children_both]()
    suite.test[test_a_udf_type_may_state_one_level_flat]()
    suite.test[test_absent_resources_decode_as_the_host_defaults]()
    suite.test[test_an_oversized_udf_ref_is_refused_before_parsing]()
    suite^.run()
