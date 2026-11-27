# =============================================================================
# test_optimized_golden.mojo
# =============================================================================
#
# One produced plan frozen as bytes: tests/fixtures/optimized_plan_join_aggregate.hex
# is `produce_optimized_plan` of an aggregate (group estimate 7) over a filter
# over a join that builds LEFT, stamped by the build whose first byte is 0xAB.
# Whoever reads the fixture with a protobuf decoder sees the plan that was
# written. What each test proves:
#
#   test_producer_writes_the_golden_bytes: the producer's output is byte-equal
#     to the fixture. A mismatch prints the bytes the producer wrote, in the
#     fixture's format, and the fixture changes only with a reason: it is a
#     published encoding (docs/design/optimized_plan.md §9.2).
#   test_golden_is_admitted: the fixture is admitted, and the admitted plan
#     renders as the plan it was produced from.
#   test_golden_reads_with_the_generic_decoder: the generated decoder reads the
#     fixture into header fields 1-8 (format 1, the stamp, a 32-byte digest, a
#     bounded `needs`, no write target, no advice), the body into one plan with
#     no shared subplans, pins or groups, and the plan back to the same
#     `LogicalPlan` through the OPTIMIZED decoder; encoding the decoded header
#     canonically gives the fixture again.
# =============================================================================

from std.pathlib import Path
from std.testing import assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from optimized_plan import (
    admit_optimized_plan,
    encode_canonical,
    header_plan_digest,
    produce_optimized_plan,
)
from plan_expr.agg_expr import AGG_SUM, AggExpr
from plan_expr.expr import BIN_GT, Expr
from plan_expr.scalar_value import ScalarValue
from plan_ir.logical_plan import (
    JOIN_ALGO_AUTO,
    JOIN_BUILD_SIDE_LEFT,
    JOIN_INNER,
    SOURCE_PARQUET,
    AggExprArray,
    ExprArray,
    LogicalPlan,
)
from plan_ir.udf_ref import UdfRef
from plan_proto.optimized_plan import OptimizedPlan, OptimizedPlanBody, ProducerStamp
from proto_codec import decode_proto
from plan_wire import optimized_plan_from_wire

comptime _FIXTURE = "src/optimized_plan/tests/fixtures/optimized_plan_join_aggregate.hex"


def _bytes(n: Int, v: UInt8) -> List[UInt8]:
    var b = List[UInt8]()
    for _ in range(n):
        b.append(v)
    return b^


def _stamp() -> ProducerStamp:
    return ProducerStamp(_bytes(32, 0xAB), 1, _bytes(32, 0x11), "komira/mojo-sdk")


def _schema(a: String, b: String) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(a, ArrowType.INT64, True))
    sb.add_field(Field(b, ArrowType.FLOAT64, True))
    return sb.build()


def _scan(path: String, a: String, b: String) -> LogicalPlan:
    return LogicalPlan.scan(path, SOURCE_PARQUET, _schema(a, b))


def _plan() -> LogicalPlan:
    var lon: List[String] = ["a"]
    var ron: List[String] = ["c"]
    var join = LogicalPlan.join(
        _scan("/d/l.parquet", "a", "b"), _scan("/d/r.parquet", "c", "d"),
        lon^, ron^, JOIN_INNER, JOIN_ALGO_AUTO, None, JOIN_BUILD_SIDE_LEFT, False,
    )
    var filtered = LogicalPlan.filter(
        Expr.binary(BIN_GT, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int64(Int64(1)))), join^
    )
    var gb = ExprArray()
    gb.append(Expr.col_ref("a"))
    var ax = AggExprArray()
    ax.append(AggExpr(AGG_SUM, Optional(Expr.col_ref("d")), Optional(String("t"))))
    var agg = LogicalPlan.aggregate(gb^, ax^, filtered^)
    agg.set_estimated_groups(Optional(7))
    return agg^


def _nibble(c: Int) raises -> Int:
    if c >= 48 and c <= 57:
        return c - 48
    if c >= 97 and c <= 102:
        return c - 87
    raise Error("not a lower-case hex digit: " + chr(c))


def _read(path: String) raises -> List[UInt8]:
    """The fixture hex format: two digits a byte, whitespace ignored."""
    var out = List[UInt8]()
    var high = -1
    for b in Path(path).read_text().as_bytes():
        var c = Int(b)
        if c == 32 or c == 10 or c == 13 or c == 9:
            continue
        if high < 0:
            high = _nibble(c)
        else:
            out.append(UInt8(high * 16 + _nibble(c)))
            high = -1
    return out^


def _hex_lines(b: List[UInt8]) -> String:
    comptime digits = "0123456789abcdef"
    var out = String("")
    for i in range(len(b)):
        var v = Int(b[i])
        out += String(digits[byte = v >> 4]) + String(digits[byte = v & 15])
        if i % 32 == 31 or i == len(b) - 1:
            out += "\n"
    return out^


def test_producer_writes_the_golden_bytes() raises:
    var produced = produce_optimized_plan(_plan(), _stamp())
    var golden = _read(_FIXTURE)
    assert_equal(_hex_lines(produced), _hex_lines(golden), "the producer's bytes against " + _FIXTURE)


def test_golden_is_admitted() raises:
    var admitted = admit_optimized_plan(_read(_FIXTURE), List[List[UInt8]]())
    assert_equal(String(admitted.plan), String(_plan()))
    assert_true(admitted.header.plan_digest == header_plan_digest(admitted.header))


def test_golden_reads_with_the_generic_decoder() raises:
    var golden = _read(_FIXTURE)
    var header = decode_proto[OptimizedPlan](golden.copy())
    assert_equal(header.format_version, 1)
    assert_equal(header.producer.value().optimizer_contract_version, 1)
    assert_true(header.producer.value().engine_build == _bytes(32, 0xAB))
    assert_equal(header.producer.value().kind, "komira/mojo-sdk")
    assert_equal(len(header.plan_digest), 32)
    assert_equal(len(header.recurring_signature), 0)
    assert_true(Bool(header.needs))
    assert_true(not header.needs.value().unbounded)
    assert_true(not header.write_target)
    assert_true(not header.advice)
    var body = decode_proto[OptimizedPlanBody](header.body.copy())
    assert_true(Bool(body.plan))
    assert_equal(len(body.shared), 0)
    assert_equal(len(body.scan_pins), 0)
    assert_equal(len(body.pin_groups), 0)
    var plan = optimized_plan_from_wire(body.plan.value(), List[UdfRef]())
    assert_equal(String(plan), String(_plan()))
    assert_true(encode_canonical(header) == golden)


def main() raises:
    test_producer_writes_the_golden_bytes()
    test_golden_is_admitted()
    test_golden_reads_with_the_generic_decoder()
    print("test_optimized_golden: 3 passed")
