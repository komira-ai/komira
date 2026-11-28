# =============================================================================
# test_plan_wire_round_digits.mojo — EXPR_ROUND_DIGITS on the plan wire.
# =============================================================================
#
# `Expr.round_digits(op, child, digits)` is carried as a `WireRoundDigits`:
# the rule (wire = engine + 1), the child and the digit count. This file holds
# the codec to that shape in both decode contexts (raw and optimized):
#
#   * every rule at negative, zero and positive digit counts, and at the ends
#     of the int32 range, decodes to a plan with the same text and hash;
#   * the message carries the rule as engine + 1, the count unchanged, and one
#     child;
#   * an absent rule (0), an undeclared rule (99), an absent child and a
#     doubled child are refused by name, and an engine rule the vocabulary does not declare is
#     refused at encode;
#   * the value gate reaches the child (an unknown column under the node is
#     refused) and the one-argument UN_ROUND stays a `WireUnaryOp`.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from plan_expr.expr import (
    Expr,
    BIN_GT,
    EXPR_ROUND_DIGITS,
    RDG_ROUND,
    RDG_TRUNC,
    RDG_ROUND_HALF_EVEN,
    UN_ROUND,
)
from plan_expr.scalar_value import ScalarValue
from plan_ir.logical_plan import LogicalPlan, ExprArray, SOURCE_PARQUET
from plan_ir.udf_ref import UdfRef
from proto_codec import encode_proto, decode_proto
from plan_proto.plan import WireExpr, WirePlan, WirePlanEnvelope, WireRoundDigits
from plan_proto.plan_vocabulary import RoundDigitsOp

from plan_wire import (
    plan_to_bytes,
    plan_from_bytes,
    optimized_plan_to_bytes,
    optimized_plan_from_bytes,
    PLAN_WIRE_UNRESOLVED_COLUMN,
)
from plan_wire.plan_wire_codec import PLAN_WIRE_MALFORMED


# ---- fixtures ---------------------------------------------------------------


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    sb.add_field(Field("b", ArrowType.FLOAT64, True))
    return sb.build()


def _scan() -> LogicalPlan:
    return LogicalPlan.scan(String("/d/t.parquet"), SOURCE_PARQUET, _schema())


def _project(var e: Expr) raises -> LogicalPlan:
    var xs = ExprArray()
    xs.append(e^)
    return LogicalPlan.project(xs^, _scan())


def _filter(var pred: Expr) -> LogicalPlan:
    return LogicalPlan.filter(pred^, _scan())


def _round(op: UInt8, digits: Int32) -> Expr:
    return Expr.round_digits(op, Expr.col_ref(String("b")), digits)


def _text(p: LogicalPlan) -> String:
    var out = String()
    p.write_to(out)
    return out^


def _no_udfs() -> List[UdfRef]:
    return List[UdfRef]()


def _digit_counts() -> List[Int32]:
    return [
        Int32(-2147483648), Int32(-400), Int32(-3), Int32(-1), Int32(0),
        Int32(1), Int32(2), Int32(400), Int32(2147483647),
    ]


def _ops() -> List[UInt8]:
    return [RDG_ROUND, RDG_TRUNC, RDG_ROUND_HALF_EVEN]


def _round_expr(p: WirePlan) raises -> WireExpr:
    if not p.project or len(p.project[0].exprs) != 1:
        raise Error("fixture: the root is not a PROJECT of one expression")
    return p.project[0].exprs[0].copy()


def _decode_error(var wire_bytes: List[UInt8]) -> String:
    try:
        _ = plan_from_bytes(wire_bytes^)
    except e:
        return String(e)
    return String()


def _optimized_decode_error(var wire_bytes: List[UInt8]) -> String:
    try:
        _ = optimized_plan_from_bytes(wire_bytes^, _no_udfs())
    except e:
        return String(e)
    return String()


comptime _OP_ZERO = 0
comptime _OP_NINETY_NINE = 1
comptime _NO_CHILD = 2
comptime _TWO_CHILDREN = 3


def _edited_plan(p: LogicalPlan, edit: Int) raises -> WirePlan:
    """`p`'s `WirePlan` with its one projected `WireRoundDigits` edited: the
    rule set to 0 or to 99, the child removed, or the child doubled."""
    var env = decode_proto[WirePlanEnvelope](plan_to_bytes(p))
    var w = env.plan.value().copy()
    var node = w.project[0].copy()
    var e = node.exprs[0].copy()
    var rd = e.round_digits[0].copy()
    if edit == _OP_ZERO:
        rd.op = RoundDigitsOp(0)
    elif edit == _OP_NINETY_NINE:
        rd.op = RoundDigitsOp(99)
    elif edit == _NO_CHILD:
        rd.child = List[WireExpr]()
    else:
        var c = rd.child[0].copy()
        rd.child.append(c^)
    e.round_digits[0] = rd^
    node.exprs[0] = e^
    w.project[0] = node^
    return w^


def _with_round_digits(p: LogicalPlan, edit: Int) raises -> List[UInt8]:
    """The raw-context bytes (a `WirePlanEnvelope`) of `_edited_plan`."""
    var env = decode_proto[WirePlanEnvelope](plan_to_bytes(p))
    env.plan = Optional(_edited_plan(p, edit))
    return encode_proto[WirePlanEnvelope](env)


def _optimized_with_round_digits(p: LogicalPlan, edit: Int) raises -> List[UInt8]:
    """The optimized-context bytes (a bare `WirePlan`) of `_edited_plan`."""
    return encode_proto[WirePlan](_edited_plan(p, edit))


# ---- round trips ------------------------------------------------------------


def test_every_rule_and_digit_count_round_trips_through_the_raw_wire() raises:
    var ops = _ops()
    var counts = _digit_counts()
    for i in range(len(ops)):
        for j in range(len(counts)):
            var p = _project(_round(ops[i], counts[j]))
            var back = plan_from_bytes(plan_to_bytes(p))
            var where = "op " + String(Int(ops[i])) + " digits " + String(counts[j])
            assert_equal(_text(back), _text(p), where + ": plan text")
            assert_equal(back.structural_hash(), p.structural_hash(), where)
            ref e = back.project_data_ref().exprs[0]
            assert_equal(Int(e.tag), Int(EXPR_ROUND_DIGITS), where + ": tag")
            assert_equal(Int(e.round_digits_op()), Int(ops[i]), where + ": op")
            assert_equal(e.round_digits_count(), counts[j], where + ": digits")


def test_every_rule_and_digit_count_round_trips_through_the_optimized_wire() raises:
    var ops = _ops()
    var counts = _digit_counts()
    for i in range(len(ops)):
        for j in range(len(counts)):
            var p = _project(_round(ops[i], counts[j]))
            var back = optimized_plan_from_bytes(
                optimized_plan_to_bytes(p, _no_udfs()), _no_udfs()
            )
            var where = "op " + String(Int(ops[i])) + " digits " + String(counts[j])
            assert_equal(_text(back), _text(p), where + ": plan text")
            assert_equal(back.structural_hash(), p.structural_hash(), where)


def test_rounds_nested_in_other_expressions_round_trip() raises:
    """A round over a round, and a round under an alias and a comparison, keep
    their own rule and count at each depth."""
    var inner = Expr.round_digits(RDG_TRUNC, Expr.col_ref(String("b")), Int32(3))
    var nested = Expr.round_digits(RDG_ROUND, inner^, Int32(-1))
    var p = _project(Expr.alias(nested^, String("r")))
    var back = plan_from_bytes(plan_to_bytes(p))
    assert_equal(_text(back), _text(p))
    assert_equal(back.structural_hash(), p.structural_hash())
    var pred = Expr.binary(
        BIN_GT,
        _round(RDG_ROUND_HALF_EVEN, Int32(2)),
        Expr.literal(ScalarValue.from_float(0.5)),
    )
    var f = _filter(pred^)
    var fback = plan_from_bytes(plan_to_bytes(f))
    assert_equal(_text(fback), _text(f))
    assert_equal(fback.structural_hash(), f.structural_hash())


def test_the_rule_digits_and_child_are_each_part_of_plan_identity() raises:
    """Two plans that differ in only the rule, only the count or only the
    child decode to different hashes, so none of the three is dropped."""
    var base = _project(_round(RDG_ROUND, Int32(2)))
    var other_op = _project(_round(RDG_TRUNC, Int32(2)))
    var other_digits = _project(_round(RDG_ROUND, Int32(3)))
    var other_child = _project(
        Expr.round_digits(RDG_ROUND, Expr.col_ref(String("a")), Int32(2))
    )
    var h = plan_from_bytes(plan_to_bytes(base)).structural_hash()
    assert_true(h != plan_from_bytes(plan_to_bytes(other_op)).structural_hash())
    assert_true(h != plan_from_bytes(plan_to_bytes(other_digits)).structural_hash())
    assert_true(h != plan_from_bytes(plan_to_bytes(other_child)).structural_hash())


def test_one_argument_round_stays_a_unary_op() raises:
    var p = _project(Expr.unary(UN_ROUND, Expr.col_ref(String("b"))))
    var env = decode_proto[WirePlanEnvelope](plan_to_bytes(p))
    var e = _round_expr(env.plan.value())
    assert_equal(len(e.unary_op), 1)
    assert_equal(len(e.round_digits), 0)
    var back = plan_from_bytes(plan_to_bytes(p))
    assert_equal(_text(back), _text(p))


# ---- the message ------------------------------------------------------------


def test_the_message_carries_the_rule_plus_one_the_digits_and_one_child() raises:
    var ops = _ops()
    var counts = _digit_counts()
    for i in range(len(ops)):
        for j in range(len(counts)):
            var p = _project(_round(ops[i], counts[j]))
            var env = decode_proto[WirePlanEnvelope](plan_to_bytes(p))
            var e = _round_expr(env.plan.value())
            var where = "op " + String(Int(ops[i])) + " digits " + String(counts[j])
            assert_equal(e._oneof0_case, 27, where + ": arm ordinal")
            assert_equal(len(e.round_digits), 1, where)
            ref rd = e.round_digits[0]
            assert_equal(rd.op.number(), Int(ops[i]) + 1, where + ": op")
            assert_equal(rd.digits, counts[j], where + ": digits")
            assert_equal(len(rd.child), 1, where + ": child")
            assert_equal(rd.child[0].col_ref.value().name, "b", where)


def test_the_wire_numbers_of_the_rules_are_pinned() raises:
    assert_equal(RoundDigitsOp.RDG_WIRE_UNSPECIFIED, 0)
    assert_equal(RoundDigitsOp.RDG_ROUND, 1)
    assert_equal(RoundDigitsOp.RDG_TRUNC, 2)
    assert_equal(RoundDigitsOp.RDG_ROUND_HALF_EVEN, 3)


# ---- refusals ---------------------------------------------------------------


def test_an_unspecified_rule_is_refused_by_name_in_both_contexts() raises:
    var p = _project(_round(RDG_ROUND, Int32(2)))
    var bytes = _with_round_digits(p, _OP_ZERO)
    var opt_bytes = _optimized_with_round_digits(p, _OP_ZERO)
    var needle = "RoundDigitsOp: wire 0 is RDG_WIRE_UNSPECIFIED"
    var raw = _decode_error(bytes^)
    assert_true(needle in raw, "raw: " + raw)
    var opt = _optimized_decode_error(opt_bytes^)
    assert_true(needle in opt, "optimized: " + opt)


def test_an_undeclared_rule_is_refused_by_name_in_both_contexts() raises:
    var p = _project(_round(RDG_TRUNC, Int32(-2)))
    var bytes = _with_round_digits(p, _OP_NINETY_NINE)
    var opt_bytes = _optimized_with_round_digits(p, _OP_NINETY_NINE)
    var needle = "RoundDigitsOp: wire value 99 is unknown to this reader"
    var raw = _decode_error(bytes^)
    assert_true(needle in raw, "raw: " + raw)
    var opt = _optimized_decode_error(opt_bytes^)
    assert_true(needle in opt, "optimized: " + opt)


def test_a_round_with_no_child_is_refused() raises:
    var p = _project(_round(RDG_ROUND, Int32(2)))
    var raw = _decode_error(_with_round_digits(p, _NO_CHILD))
    assert_true(raw.startswith(PLAN_WIRE_MALFORMED), "token: " + raw)
    assert_true("WireRoundDigits.child carries 0" in raw, raw)


def test_a_round_with_two_children_is_refused() raises:
    var p = _project(_round(RDG_ROUND, Int32(2)))
    var raw = _decode_error(_with_round_digits(p, _TWO_CHILDREN))
    assert_equal(
        raw,
        "WireRoundDigits.child: a singular recursive field appeared more"
        " than once on the wire; the message is malformed",
    )


def test_an_engine_rule_the_vocabulary_does_not_declare_is_refused_at_encode() raises:
    var p = _project(_round(UInt8(3), Int32(2)))
    var text = String()
    try:
        _ = plan_to_bytes(p)
    except e:
        text = String(e)
    assert_equal(
        text, "RoundDigitsOp: engine tag 3 is not in the plan wire vocabulary"
    )


def test_the_value_gate_reaches_the_child_of_a_round() raises:
    """An unknown column under the node is refused; the same plan over a
    column the scan has decodes."""
    var good = _filter(
        Expr.binary(
            BIN_GT,
            _round(RDG_ROUND, Int32(1)),
            Expr.literal(ScalarValue.from_float(0.5)),
        )
    )
    var back = plan_from_bytes(plan_to_bytes(good))
    assert_equal(back.structural_hash(), good.structural_hash())
    var bad = _filter(
        Expr.binary(
            BIN_GT,
            Expr.round_digits(
                RDG_ROUND, Expr.col_ref(String("missing")), Int32(1)
            ),
            Expr.literal(ScalarValue.from_float(0.5)),
        )
    )
    var text = _decode_error(plan_to_bytes(bad))
    assert_true(text.startswith(PLAN_WIRE_UNRESOLVED_COLUMN), "got: " + text)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
