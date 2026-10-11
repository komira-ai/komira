# =============================================================================
# `Expr.write_to` renders every literal VALUE, and renders a quoted string so
# its quotes cannot be forged.
# =============================================================================
#
# `LogicalPlan.structural_hash` is FNV-1a over the plan render, and the render
# of an expression is `Expr.write_to`. That hash is the plan-compile cache key
# and the scalar-subquery dedup key, so two expressions that render alike
# share a compiled plan (the second query answers with the first one's
# values). Each test is a pair that must render differently:
#
#   * BINARY literals rendered only their LENGTH (`ScalarValue(binary, 2
#     bytes)`), so `b = X'0102'` and `b = X'0304'` rendered alike.
#   * a typed NULL rendered `ScalarValue(null)` whatever its type, so
#     `null(int64)` and `null(utf8)` -- different output column types --
#     rendered alike.
#   * quoted strings were written raw between `"` quotes, so a value that
#     contains `"` can close its own quote and spell the next list element:
#     `x IN ('a"), ScalarValue(utf8, "b')` rendered exactly like
#     `x IN ('a', 'b')`. The same holds for an alias name (expression and
#     aggregate), a string-op pattern and the regexp fields.
#   * JSON path segments were joined with `.`, so the ONE key `a.b`
#     (`$."a.b"`) rendered like the TWO keys `a`, `b` (`$.a.b`).
#   * an escape that skips the escape character `\` is not one-to-one: the
#     JSON segments [`a\`, `b`] and [`a.b`] would both render `$.a\.b`.
#
# Controls: an ordinary value renders as before (EXPLAIN text and existing
# goldens do not move), and equal expressions render equal.
#
# The comptime join-schema mirror (`typed_schema.join_out_schema`) is checked
# here too: it must agree with `LogicalPlan.join` that the NULL-supplying side
# of an outer join is nullable.
# =============================================================================

from std.testing import TestSuite, assert_true, assert_equal, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import Expr, BIN_EQ
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.agg_expr import AggExpr, sum as agg_sum
from komira_plan_expr.col_expr import col
from komira_plan_expr.typed_schema import (
    SchemaDescriptor,
    ColDescriptor,
    join_out_schema,
    _NN,
    TYPE_INT64,
)


def _r(e: Expr) -> String:
    var s = String("")
    e.write_to(s)
    return s


def _lit(var v: ScalarValue) -> Expr:
    return Expr.literal(v^)


def _differ(a: Expr, b: Expr, what: String) raises:
    var ra = _r(a)
    assert_true(ra != _r(b), what + ": both rendered " + ra)


def _in(var vals: List[ScalarValue]) -> Expr:
    return Expr.in_list_node(Expr.col_ref("x"), vals^)


def test_binary_literals_render_their_bytes() raises:
    _differ(
        _lit(ScalarValue.from_binary(String("\x01\x02"))),
        _lit(ScalarValue.from_binary(String("\x03\x04"))),
        "X'0102' vs X'0304'",
    )


def test_a_binary_literal_renders_exact_hex() raises:
    # High nibble first, lowercase, two digits per byte; empty is `0x`.
    assert_equal(
        _r(_lit(ScalarValue.from_binary(String("\x0f\x10\x7f")))),
        String("Literal(ScalarValue(binary, 3 bytes, 0x0f107f))"),
    )
    assert_equal(
        _r(_lit(ScalarValue.from_binary(String("")))),
        String("Literal(ScalarValue(binary, 0 bytes, 0x))"),
    )


def test_typed_nulls_render_their_type() raises:
    _differ(
        _lit(ScalarValue.null(DType.int64)),
        _lit(ScalarValue.null(DType.float64)),
        "null(int64) vs null(float64)",
    )


def test_an_in_list_value_cannot_close_its_own_quote() raises:
    var one = List[ScalarValue]()
    one.append(ScalarValue.from_string('a"), ScalarValue(utf8, "b'))
    var two = List[ScalarValue]()
    two.append(ScalarValue.from_string("a"))
    two.append(ScalarValue.from_string("b"))
    _differ(_in(one^), _in(two^), "IN ('a\"), ScalarValue(utf8, \"b') vs IN ('a', 'b')")


def test_a_backslash_cannot_hide_a_quote() raises:
    # The escape must cover the escape character itself. A JSON path escapes
    # `.` as well, and an escape that skipped `\` rendered the two segments
    # [`a\`, `b`] and the one segment [`a.b`] both as `$.a\.b`. With `\`
    # escaped they render `$.a\\.b` and `$.a\.b`.
    var two: List[String] = ["a\\", "b"]
    var one: List[String] = ["a.b"]
    _differ(
        Expr.json_extract_from_parts(Expr.col_ref("j"), two^, ArrowType.STRING, False),
        Expr.json_extract_from_parts(Expr.col_ref("j"), one^, ArrowType.STRING, False),
        "JSON path [a\\, b] vs [a.b]",
    )
    # And the exact bytes: `a\` renders `"a\\"`, `a"` renders `"a\""`.
    assert_equal(
        _r(_lit(ScalarValue.from_string("a\\"))),
        String('Literal(ScalarValue(utf8, "a\\\\"))'),
    )
    assert_equal(
        _r(_lit(ScalarValue.from_string('a"'))),
        String('Literal(ScalarValue(utf8, "a\\""))'),
    )


def test_an_alias_name_cannot_close_its_own_quote() raises:
    # `Alias(<child>, "<name>")` inside an equality. Pre-fix both render
    # `BinaryOp(==, Alias(ColRef(a), "n"), ColRef(Y"), ColRef(c))`.
    _differ(
        Expr.binary(BIN_EQ, Expr.alias(Expr.col_ref("a"), 'n"), ColRef(Y'), Expr.col_ref("c")),
        Expr.binary(BIN_EQ, Expr.alias(Expr.col_ref("a"), "n"), Expr.col_ref('Y"), ColRef(c')),
        "alias name forging the second operand",
    )


def test_a_string_op_pattern_cannot_close_its_own_quote() raises:
    _differ(
        Expr.binary(BIN_EQ, Expr.string_op(UInt8(1), Expr.col_ref("s"), 'p"), ColRef(Y'), Expr.col_ref("u")),
        Expr.binary(BIN_EQ, Expr.string_op(UInt8(1), Expr.col_ref("s"), "p"), Expr.col_ref('Y"), ColRef(u')),
        "string-op pattern forging the second operand",
    )


def _ra(a: AggExpr) -> String:
    var s = String("")
    a.write_to(s)
    return s


def test_an_aggregate_alias_cannot_close_its_own_quote() raises:
    # An Aggregate node renders its aggregates joined by `, `. Pre-fix the ONE
    # aggregate below rendered exactly like the TWO after it, joined.
    var one = _ra(agg_sum(col("v")).alias('n"), SUM(ColRef(w)).alias("m'))
    var two = (
        _ra(agg_sum(col("v")).alias("n")) + ", " + _ra(agg_sum(col("w")).alias("m"))
    )
    assert_true(one != two, "aggregate alias forging a second aggregate: " + one)


def test_a_dotted_json_key_is_not_a_nested_path() raises:
    _differ(
        Expr.json_extract_string(Expr.col_ref("j"), '$."a.b"'),
        Expr.json_extract_string(Expr.col_ref("j"), "$.a.b"),
        "$.\"a.b\" (one key) vs $.a.b (two keys)",
    )


def test_ordinary_values_render_as_before() raises:
    # Control: escaping only touches strings that need it.
    assert_equal(
        _r(_lit(ScalarValue.from_string("hello world"))),
        String('Literal(ScalarValue(utf8, "hello world"))'),
    )
    assert_equal(
        _r(Expr.json_extract_string(Expr.col_ref("j"), "$.a.b")),
        String('JsonExtract(ColRef(j), path="$.a.b", mode=->>)'),
    )
    assert_equal(
        _r(_lit(ScalarValue.from_string('a"b'))),
        _r(_lit(ScalarValue.from_string('a"b'))),
    )


def _desc(name: String, nullable: Bool) -> ColDescriptor:
    var c = _NN(name, TYPE_INT64)
    c.nullable = nullable
    return c^


def _two(a: String, b: String) -> SchemaDescriptor:
    var cols = List[ColDescriptor]()
    cols.append(_desc(a, False))
    cols.append(_desc(b, False))
    return SchemaDescriptor(cols^, False)


def test_typed_join_mirror_marks_the_null_supplying_side() raises:
    # join_type tags: INNER=0, LEFT=1, RIGHT=2, FULL=3, SEMI=4, ANTI=5, CROSS=6.
    var left = join_out_schema(_two("lk", "lv"), _two("rk", "rv"), 1)
    assert_false(left.cols[0].nullable, "LEFT: left column")
    assert_true(left.cols[2].nullable, "LEFT: right column")
    assert_true(left.cols[3].nullable, "LEFT: right column")
    var right = join_out_schema(_two("lk", "lv"), _two("rk", "rv"), 2)
    assert_true(right.cols[0].nullable, "RIGHT: left column")
    assert_false(right.cols[2].nullable, "RIGHT: right column")
    var full = join_out_schema(_two("lk", "lv"), _two("rk", "rv"), 3)
    assert_true(full.cols[1].nullable, "FULL: left column")
    assert_true(full.cols[3].nullable, "FULL: right column")
    var inner = join_out_schema(_two("lk", "lv"), _two("rk", "rv"), 0)
    assert_false(inner.cols[1].nullable, "INNER: left column")
    assert_false(inner.cols[3].nullable, "INNER: right column")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
