# =============================================================================
# test_plan_wire_udf_position_sweeps.mojo — the frame read-set checks and the
# runtime-id length bound at every position (optimized_plan_udfs.md §10.2,
# §10.4; udf_runtime_interface.md §3.1)
# =============================================================================
#
# Each rule here is a loop over a list (read-set names, group keys) or a check
# applied to two parts (namespace, name). A check that looks at one position
# only passes a test that plants its defect at that position, so each test
# plants the defect at every position in turn and requires the refusal to
# name it, beside a control that differs only in the defect and is admitted.
#
#   test_a_duplicated_read_set_column_is_refused_at_every_position: over a
#     read set {a, b, c}, a child that outputs a second column named a, then
#     b, then c, is refused OPTIMIZED_UDF_READ_SET_INVALID naming that
#     column. Catches a duplicate check on names[0] only (or on any one).
#   test_a_read_set_type_mismatch_is_refused_at_every_position: over a child
#     (a, b, c), all INT64, a read set {a, b, c} that declares FLOAT64 for a,
#     then b, then c, is refused OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH naming
#     that column. Catches a type check on names[0] only (or on any one).
#   test_an_empty_read_set_cannot_group: a grouped frame whose read set is
#     set and empty reads no column, so a group key that reads a column is
#     refused OPTIMIZED_UDF_READ_SET_GROUP_KEY, with the column-reading key
#     first, middle and last among literal keys, and with every key reading
#     a column. Catches a group-key check skipped when the read set is
#     empty, and one that looks at one key position only.
#   test_the_64_byte_bound_holds_on_both_parts: a 63-byte namespace and a
#     63-byte name are admitted, a 64-byte namespace and a 64-byte name are
#     refused OPTIMIZED_UDF_RUNTIME_MALFORMED. Catches a bound applied to one
#     part only, and `>=` for `>` on either part.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.expr import Expr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.udf_data import UDF_NULL_PROPAGATE, UDF_STABILITY_STABLE
from komira_plan_expr.udf_type import UdfType
from komira_plan_ir.logical_plan import LogicalPlan
from komira_plan_ir.udf_ref import (
    CodeDigest,
    UdfCode,
    UdfRef,
    UDF_REF_KIND_SCALAR,
    UDF_REF_KIND_MAP_BATCHES_FRAME,
    CODE_FORM_VALUE,
)

from komira_plan_wire import (
    plan_to_bytes_with_udfs,
    plan_envelope_from_bytes,
    udf_ref_from_bytes,
    udf_ref_to_bytes,
    udf_runtime_id_is_valid,
    OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH,
    OPTIMIZED_UDF_READ_SET_GROUP_KEY,
    OPTIMIZED_UDF_READ_SET_INVALID,
    OPTIMIZED_UDF_RUNTIME_MALFORMED,
)


# ---- fixtures -----------------------------------------------------------------------


def _leaf(name: String, t: ArrowType) -> UdfType:
    return UdfType(name, t, Field(name, t, True).dtype, True)


def _code(runtime: String = "komira/python") -> UdfCode:
    var d = List[CodeDigest]()
    var sha = List[UInt8]()
    for _ in range(32):
        sha.append(0x5A)
    d.append(CodeDigest("payload", sha^))
    return UdfCode(runtime, CODE_FORM_VALUE, "", d^)


def _frame_out() -> UdfType:
    var kids = List[UdfType]()
    kids.append(_leaf("k", ArrowType.INT64))
    kids.append(_leaf("v", ArrowType.FLOAT64))
    return UdfType("out", ArrowType.STRUCT, Field("out", ArrowType.STRUCT, True).dtype, True, kids^)


def _frame_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    sb.add_field(Field("v", ArrowType.FLOAT64, True))
    return sb.build()


def _frame_ref(var args: List[UdfType], var read_set: List[String]) -> UdfRef:
    """A MAP_BATCHES_FRAME entry whose read set is set to `read_set`."""
    return UdfRef(
        UDF_REF_KIND_MAP_BATCHES_FRAME, _code(), args^, Optional(_frame_out()),
        UDF_STABILITY_STABLE, UDF_NULL_PROPAGATE, Optional(read_set^),
    )


def _int_cols(names: List[String]) -> Schema:
    var sb = SchemaBuilder()
    for i in range(len(names)):
        sb.add_field(Field(names[i], ArrowType.INT64, True))
    return sb.build()


def _frame_over(var child: Schema, var group_by: List[Expr]) raises -> LogicalPlan:
    var scan = LogicalPlan.scan(
        String("/nonexistent/sweeps.parquet"), 0, child^,
        Optional[List[String]](None), Optional[Expr](None), Optional[Int](None),
    )
    return LogicalPlan.map_batches(scan^, 0, group_by^, _frame_schema())


def _list(var u: UdfRef) -> List[UdfRef]:
    var out = List[UdfRef]()
    out.append(u^)
    return out^


def _refusal(p: LogicalPlan, udfs: List[UdfRef]) raises -> String:
    """The RAW decoder's refusal of `p` with `udfs`, or "" when it decodes."""
    var bytes = plan_to_bytes_with_udfs(p, udfs)
    try:
        _ = plan_envelope_from_bytes(bytes^)
    except e:
        return String(e)
    return String("")


def _refused(msg: String, token: String, names: String, what: String) raises:
    """`msg` begins with `token` and quotes the column `names`."""
    assert_true(msg.startswith(token), what + ": want " + token + ", got: " + msg)
    assert_true("'" + names + "'" in msg, what + ": the refusal does not name '" + names + "': " + msg)


def _abc() -> List[String]:
    var out: List[String] = ["a", "b", "c"]
    return out^


def _int_args(names: List[String]) -> List[UdfType]:
    var out = List[UdfType]()
    for i in range(len(names)):
        out.append(_leaf(names[i], ArrowType.INT64))
    return out^


# ---- the read set, name by name ---------------------------------------------------------


def test_a_duplicated_read_set_column_is_refused_at_every_position() raises:
    """Defect: a duplicate-name check that looks at one read-set position only
    (names[0], or any one). Over the read set {a, b, c}, a child of
    (a, b, c, a), then (a, b, c, b), then (a, b, c, c), is refused naming the
    duplicated column; the child (a, b, c) is admitted."""
    var names = _abc()
    var ok = _frame_over(_int_cols(names), List[Expr]())
    assert_equal(_refusal(ok, _list(_frame_ref(_int_args(names), names.copy()))), "", "child (a, b, c)")
    for i in range(len(names)):
        var cols = names.copy()
        cols.append(names[i].copy())
        var p = _frame_over(_int_cols(cols), List[Expr]())
        var what = "read set {a, b, c} over a child with two '" + names[i] + "' (position " + String(i) + ")"
        _refused(_refusal(p, _list(_frame_ref(_int_args(names), names.copy()))), OPTIMIZED_UDF_READ_SET_INVALID, names[i], what)


def test_a_read_set_type_mismatch_is_refused_at_every_position() raises:
    """Defect: a type check that compares one read-set position only
    (names[0], or any one) with the child's column. Over a child (a, b, c),
    all INT64, the read set {a, b, c} declaring FLOAT64 for a, then b, then
    c, is refused naming that column; all INT64 is admitted."""
    var names = _abc()
    var ok = _frame_over(_int_cols(names), List[Expr]())
    assert_equal(_refusal(ok, _list(_frame_ref(_int_args(names), names.copy()))), "", "all INT64")
    for i in range(len(names)):
        var args = List[UdfType]()
        for j in range(len(names)):
            args.append(_leaf(names[j], ArrowType.FLOAT64 if j == i else ArrowType.INT64))
        var p = _frame_over(_int_cols(names), List[Expr]())
        var what = "read set {a, b, c} declaring '" + names[i] + "' FLOAT64 (position " + String(i) + ")"
        _refused(_refusal(p, _list(_frame_ref(args^, names.copy()))), OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH, names[i], what)


# ---- an empty read set and the group keys ------------------------------------------------


def _lit(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int64(Int64(v)))


def _one_reading_key(names: List[String], i: Int) -> List[Expr]:
    """One group key per name: key `i` reads column `names[i]`, the others
    are literals and read no column."""
    var keys = List[Expr]()
    for j in range(len(names)):
        if j == i:
            keys.append(Expr.col_ref(names[j]))
        else:
            keys.append(_lit(j))
    return keys^


def test_an_empty_read_set_cannot_group() raises:
    """Defect: a group-key check skipped when the read set is set and empty
    (it reads no column, so it names no key's column), or one that looks at
    one key position only. Over a child (a, b, c), three group keys of which
    one reads a column (first, middle, last) and the others are literals: an
    empty read set is refused naming that column, and the read set {a, b, c}
    is admitted. Every key reading a column is refused too, and an ungrouped
    frame with an empty read set is admitted."""
    var names = _abc()
    var empty = List[String]()
    var ungrouped = _frame_over(_int_cols(names), List[Expr]())
    assert_equal(_refusal(ungrouped, _list(_frame_ref(List[UdfType](), empty.copy()))), "", "ungrouped, empty read set")
    for i in range(len(names)):
        var what = "empty read set, group by key " + String(i) + " reading '" + names[i] + "'"
        var p = _frame_over(_int_cols(names), _one_reading_key(names, i))
        _refused(_refusal(p, _list(_frame_ref(List[UdfType](), empty.copy()))), OPTIMIZED_UDF_READ_SET_GROUP_KEY, names[i], what)
        var q = _frame_over(_int_cols(names), _one_reading_key(names, i))
        assert_equal(_refusal(q, _list(_frame_ref(_int_args(names), names.copy()))), "", what + " with read set {a, b, c}")
    var all_keys = List[Expr]()
    for j in range(len(names)):
        all_keys.append(Expr.col_ref(names[j]))
    var r = _frame_over(_int_cols(names), all_keys^)
    _refused(_refusal(r, _list(_frame_ref(List[UdfType](), empty^))), OPTIMIZED_UDF_READ_SET_GROUP_KEY, "a", "empty read set, group by (a, b, c)")


# ---- the runtime id's two parts ---------------------------------------------------------


def _part(n: Int) -> String:
    """A part of `n` bytes: 'a' then 'b's."""
    var s = String("a")
    for _ in range(n - 1):
        s += "b"
    return s^


def _scalar(runtime: String) -> UdfRef:
    var args = List[UdfType]()
    args.append(_leaf("x", ArrowType.FLOAT64))
    return UdfRef(
        UDF_REF_KIND_SCALAR, _code(runtime), args^, Optional(_leaf("y", ArrowType.FLOAT64)),
        UDF_STABILITY_STABLE, UDF_NULL_PROPAGATE,
    )


def _decode_refusal(runtime: String) raises -> String:
    var bytes = udf_ref_to_bytes(_scalar(runtime))
    try:
        _ = udf_ref_from_bytes(bytes^)
    except e:
        return String(e)
    return String("")


def test_the_64_byte_bound_holds_on_both_parts() raises:
    """Defect: the `{0,62}` length bound applied to one part only (a 64-byte
    namespace admitted), or `>=` for `>` (a 63-byte part refused). Each part
    at 63 bytes is admitted and at 64 bytes refused, the other part short,
    both through `udf_runtime_id_is_valid` and through the decoder."""
    var ids: List[String] = [_part(63) + "/python", "komira/" + _part(63)]
    var parts: List[String] = ["namespace", "name"]
    for i in range(len(ids)):
        var what = "a 63-byte " + parts[i]
        assert_true(udf_runtime_id_is_valid(ids[i]), what + " refused")
        assert_equal(_decode_refusal(ids[i]), "", what + ": the decoder refused it")
    var long_ids: List[String] = [_part(64) + "/python", "komira/" + _part(64)]
    for i in range(len(long_ids)):
        var what = "a 64-byte " + parts[i]
        assert_false(udf_runtime_id_is_valid(long_ids[i]), what + " admitted")
        var msg = _decode_refusal(long_ids[i])
        assert_true(msg.startswith(OPTIMIZED_UDF_RUNTIME_MALFORMED), what + ": want " + OPTIMIZED_UDF_RUNTIME_MALFORMED + ", got: " + msg)
    # Both parts at the bound together: the bound is per part, not on the id.
    assert_true(udf_runtime_id_is_valid(_part(63) + "/" + _part(63)), "two 63-byte parts refused")


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_duplicated_read_set_column_is_refused_at_every_position]()
    suite.test[test_a_read_set_type_mismatch_is_refused_at_every_position]()
    suite.test[test_an_empty_read_set_cannot_group]()
    suite.test[test_the_64_byte_bound_holds_on_both_parts]()
    suite^.run()
