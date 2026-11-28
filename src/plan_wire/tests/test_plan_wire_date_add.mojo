# =============================================================================
# test_plan_wire_date_add.mojo - the `date_add` expression arm on the wire.
# =============================================================================
#
# `EXPR_DATE_ADD` crosses the wire as `WireExpr.date_add` (field 28): a child,
# a signed month count and a signed day count. This file holds:
#
#   - the round trip of the arm, with negative and extreme counts and with a
#     `date_add` nested in another one and under a cast;
#   - the frozen bytes of one plan (`tests/fixtures/golden/date_add.hex`), the
#     same bytes protoc re-serialized (`date_add.canonical.hex`), and the
#     refusal of a `WireDateAdd` that has no child;
#   - what a reader that does not know field 28 does with it: proto3 skips an
#     unknown field, so the expression has no `node` arm and is refused by name.
#
# Regolding: the golden case prints a `GOLDEN-BEGIN`/`GOLDEN-END` block holding
# the bytes it encoded, on pass as well as on fail. Copy the block into
# `tests/fixtures/golden/date_add.hex`, then re-derive `date_add.txtpb` and
# `date_add.canonical.hex` with protoc as the BUCK file describes.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from plan_expr.expr import Expr, EXPR_DATE_ADD
from plan_ir.logical_plan import ExprArray, LogicalPlan
from proto_codec import decode_proto, encode_proto
from plan_proto.plan import WireExpr, WirePlanEnvelope
from scan_source.parquet_source import ParquetSource
from scan_source.source_variant import SourceVariant

from plan_wire import plan_from_bytes, plan_to_bytes
from plan_wire.plan_wire_codec import PLAN_WIRE_MALFORMED


comptime _FIXTURE_DIR: String = "src/plan_wire/tests/fixtures/golden/"
comptime _HEX_BYTES_PER_LINE: Int = 32


def _schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("d", ArrowType.DATE32, True))
    sb.add_field(Field("n", ArrowType.INT64, True))
    return sb.build()


def _scan() raises -> LogicalPlan:
    var schema = _schema()
    return LogicalPlan.scan_from_source(
        SourceVariant(
            ParquetSource(String("/data/dates.parquet"), schema.copy(), None)
        ),
        schema^,
    )


def _d() -> Expr:
    return Expr.col_ref(String("d"))


def _named(name: String, var e: Expr) -> Expr:
    return Expr.alias(e^, name)


def _project(var xs: ExprArray) raises -> LogicalPlan:
    return LogicalPlan.project(xs^, _scan())


def _golden_plan() raises -> LogicalPlan:
    """Four projections over one DATE32 column: a month step, a negative day
    step, a negative month and day step under the cast the SQL binder wraps an
    interval sum in, and a date_add nested in a date_add."""
    var xs = ExprArray()
    xs.append(_d())
    xs.append(_named(String("plus_month"), Expr.date_add(1, 0, _d())))
    xs.append(_named(String("minus_week"), Expr.date_add(0, -7, _d())))
    xs.append(
        _named(
            String("as_timestamp"),
            Expr.cast_to_arrow(
                Expr.date_add(-14, -3, _d()), ArrowType.TIMESTAMP_US
            ),
        )
    )
    xs.append(
        _named(
            String("nested"),
            Expr.date_add(12, 5, Expr.date_add(0, -30, _d())),
        )
    )
    return _project(xs^)


# --- hex fixtures -----------------------------------------------------------


def _hex_nibble(v: UInt8) -> String:
    comptime DIGITS = String("0123456789abcdef")
    return String(DIGITS[byte=Int(v)])


def _to_hex_lines(bytes: List[UInt8]) -> String:
    var out = String("")
    for i in range(len(bytes)):
        out += _hex_nibble(bytes[i] >> 4)
        out += _hex_nibble(bytes[i] & 0xF)
        if (i % _HEX_BYTES_PER_LINE) == (_HEX_BYTES_PER_LINE - 1):
            out += "\n"
    if len(bytes) % _HEX_BYTES_PER_LINE != 0:
        out += "\n"
    return out^


def _hex_value(c: UInt8) raises -> UInt8:
    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
        return c - UInt8(ord("0"))
    if c >= UInt8(ord("a")) and c <= UInt8(ord("f")):
        return c - UInt8(ord("a")) + UInt8(10)
    raise Error("date_add golden: a `.hex` fixture holds a non-hex byte")


def _from_hex(text: String) raises -> List[UInt8]:
    var nibbles = List[UInt8]()
    var b = text.as_bytes()
    for i in range(len(b)):
        var c = b[i]
        if c == UInt8(ord("\n")) or c == UInt8(ord(" ")):
            continue
        nibbles.append(_hex_value(c))
    if len(nibbles) % 2 != 0:
        raise Error("date_add golden: a `.hex` fixture has an odd digit count")
    var out = List[UInt8]()
    for i in range(0, len(nibbles), 2):
        out.append((nibbles[i] << 4) | nibbles[i + 1])
    return out^


def _read_fixture(name: String) raises -> List[UInt8]:
    var path = _FIXTURE_DIR + name
    with open(path, "r") as f:
        return _from_hex(f.read())


def _schema_text(s: Schema) raises -> String:
    var out = String("[")
    for i in range(s.num_columns()):
        if i > 0:
            out += ", "
        out += String(s.field_at_unchecked(i))
    out += "]"
    return out^


# --- tests ------------------------------------------------------------------


def _assert_round_trips(what: String, var plan: LogicalPlan) raises:
    var text = String(plan)
    var h = plan.structural_hash()
    var sch = _schema_text(plan.output_schema)
    var back = plan_from_bytes(plan_to_bytes(plan))
    assert_equal(String(back), text, what + ": the decoded plan renders differently")
    assert_equal(
        String(back.structural_hash()), String(h), what + ": structural_hash"
    )
    assert_equal(
        _schema_text(back.output_schema), sch, what + ": output schema"
    )


def _date_add_plan(m: Int32, dd: Int32) raises -> LogicalPlan:
    var xs = ExprArray()
    xs.append(_named(String("x"), Expr.date_add(m, dd, _d())))
    return _project(xs^)


def test_date_add_round_trips_with_signed_and_extreme_counts() raises:
    """A `date_add` keeps its months and days through the wire at zero,
    negative, positive and Int32-extreme values, and keeps its child."""
    var counts: List[Int32] = [
        0, 1, -1, 12, -13, 9999 * 12, -9999 * 12,
        Int32(2147483647), Int32(-2147483647) - 1,
    ]
    for i in range(len(counts)):
        for j in range(len(counts)):
            var m = counts[i]
            var dd = counts[j]
            var what = String("date_add(") + String(m) + ", " + String(dd) + ")"
            _assert_round_trips(what, _date_add_plan(m, dd))
            var back = plan_from_bytes(plan_to_bytes(_date_add_plan(m, dd)))
            ref d = back.project_data_ref()
            ref inner = d.exprs[0].alias_child_ref()
            assert_equal(Int(inner.tag), Int(EXPR_DATE_ADD), what + ": arm")
            assert_equal(inner.date_add_months(), m, what + ": months")
            assert_equal(inner.date_add_days(), dd, what + ": days")
            assert_equal(
                inner.date_add_child_ref().col_ref_name(),
                String("d"),
                what + ": child",
            )


def test_a_nested_date_add_under_a_cast_round_trips() raises:
    """A date_add inside a date_add, and one under the cast to TIMESTAMP_US
    that an interval sum is bound to, both come back as the plan that went in,
    with the cast's DATE32-to-timestamp output type."""
    var xs = ExprArray()
    xs.append(
        _named(
            String("nested"),
            Expr.date_add(1, -2, Expr.date_add(-3, 4, _d())),
        )
    )
    xs.append(
        _named(
            String("ts"),
            Expr.cast_to_arrow(Expr.date_add(2, 0, _d()), ArrowType.TIMESTAMP_US),
        )
    )
    _assert_round_trips(String("nested and cast"), _project(xs^))


def test_date_add_bytes_are_frozen() raises:
    """The encoder's bytes for the golden plan equal `date_add.hex`; the frozen
    bytes and protoc's re-serialization (`date_add.canonical.hex`) both decode
    to the golden plan, its hash and its output schema."""
    var plan = _golden_plan()
    var text = String(plan)
    var h = plan.structural_hash()
    var sch = _schema_text(plan.output_schema)
    var bytes = plan_to_bytes(plan)
    print("GOLDEN-BEGIN date_add")
    print(_to_hex_lines(bytes), end="")
    print("GOLDEN-END date_add")
    var want = _read_fixture(String("date_add.hex"))
    assert_equal(len(bytes), len(want), "the encoded length moved")
    var first_diff = -1
    for i in range(len(want)):
        if bytes[i] != want[i]:
            first_diff = i
            break
    assert_equal(first_diff, -1, "the encoder's bytes diverge from the fixture")
    var names = [String("date_add.hex"), String("date_add.canonical.hex")]
    for k in range(len(names)):
        var back = plan_from_bytes(_read_fixture(names[k]))
        assert_equal(String(back), text, names[k] + ": decoded plan")
        assert_equal(
            String(back.structural_hash()), String(h), names[k] + ": hash"
        )
        assert_equal(
            _schema_text(back.output_schema), sch, names[k] + ": schema"
        )


def _refusal(var bytes: List[UInt8]) -> String:
    try:
        var p = plan_from_bytes(bytes^)
        _ = p.structural_hash()
    except e:
        return String(e)
    return String("")


def test_a_date_add_with_no_child_is_refused() raises:
    """A `WireDateAdd` whose child box is empty is refused as malformed, naming
    the field; it is not read as a date_add of nothing."""
    var env = decode_proto[WirePlanEnvelope](plan_to_bytes(_date_add_plan(1, 2)))
    var w = env.plan.value().copy()
    var node = w.project[0].copy()
    var ae = node.exprs[0].copy()
    var a = ae.alias_[0].copy()
    var inner = a.child[0].copy()
    var da = inner.date_add[0].copy()
    da.child = List[WireExpr]()
    inner.date_add[0] = da^
    a.child[0] = inner^
    ae.alias_[0] = a^
    node.exprs[0] = ae^
    w.project[0] = node^
    env.plan = Optional(w^)
    var text = _refusal(encode_proto[WirePlanEnvelope](env))
    assert_true(text != "", "a WireDateAdd with no child was accepted")
    assert_true(text.startswith(PLAN_WIRE_MALFORMED), "not refused as malformed: " + text)
    assert_true(
        String("WireDateAdd.child") in text, "the refusal does not name the field: " + text
    )


def test_a_reader_without_field_28_refuses_the_expression_by_name() raises:
    """The bytes of a plan with a date_add, with that arm's field number
    rewritten to 29 (a number no arm declares, as field 28 is to a reader
    built before it), decode with the arm skipped as an unknown field; the
    expression then has no `node` arm and the plan is refused as malformed."""
    var bytes = plan_to_bytes(_date_add_plan(1, 2))
    # Field 28, wire type 2: tag byte 0xE2 0x01. Field 29: 0xEA 0x01.
    var at = -1
    var hits = 0
    for i in range(len(bytes) - 1):
        if bytes[i] == 0xE2 and bytes[i + 1] == 0x01:
            at = i
            hits += 1
    assert_equal(hits, 1, "the plan holds exactly one field-28 tag")
    bytes[at] = 0xEA
    var text = _refusal(bytes^)
    assert_true(text != "", "a plan with an unknown expression arm was accepted")
    assert_true(text.startswith(PLAN_WIRE_MALFORMED), "not refused as malformed: " + text)
    assert_true(
        String("a WireExpr with NO `node` arm set") in text,
        "the refusal does not say the arm is missing: " + text,
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_date_add_round_trips_with_signed_and_extreme_counts]()
    suite.test[test_a_nested_date_add_under_a_cast_round_trips]()
    suite.test[test_date_add_bytes_are_frozen]()
    suite.test[test_a_date_add_with_no_child_is_refused]()
    suite.test[test_a_reader_without_field_28_refuses_the_expression_by_name]()
    suite^.run()
