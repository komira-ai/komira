# =============================================================================
# test_search_scan_pushdown_gate.mojo -- `FastFieldPushdownGate`, the
# per-conjunct classifier the `komira.search.index` kind lowers fast-field
# conjuncts with.
#
# One split holds a fast field of every class and encoding the gate tells
# apart: `status` (STRING -> KEYWORD), `price` (INT64 -> NUMERIC, integer
# encoding), `ratio` (FLOAT64 -> NUMERIC, float encoding), `day` (DATE32 ->
# DATE) and `ts` (TIMESTAMP -> DATE).
#
# Pins:
#   * the gate reads every fast field of the split (the five declared and
#     the fieldnorm), and none of the text or `_source` columns;
#   * KEYWORD admits eq/ne only, and only a string literal;
#   * NUMERIC-int and DATE admit every comparison with an int literal (DATE
#     also a date32 or timestamp literal), never a float, string, bool or null
#     literal; NUMERIC-float admits only a float literal;
#   * the literal may stand on either side of the comparison;
#   * AND is pushable iff both sides are, OR and arithmetic never are, and a
#     bare column, a bare literal, a column against a column, two literals, a
#     join-side-qualified column and a column the split has no fast field for
#     are all rejected;
#   * IN is pushable iff its child is a bare fast-field column and every
#     value, not only the first, matches the field's class; an empty list is
#     rejected;
#   * the literal check refuses a name with no fast field on its own.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_plan_expr.expr import (
    Expr,
    BIN_ADD,
    BIN_AND,
    BIN_EQ,
    BIN_GE,
    BIN_GT,
    BIN_LE,
    BIN_LT,
    BIN_NE,
    BIN_OR,
)
from komira_plan_expr.scalar_value import ScalarValue

from komira_search.fast_fields import FIELDNORM_NAME
from komira_search.sink import SearchSink

from komira_search_scan.search_source import FastFieldPushdownGate


def _uuid(seed: UInt8) -> Array[UInt8, 16]:
    var u = Array[UInt8, 16](fill=0)
    for i in range(16):
        u[i] = seed + UInt8(i)
    return u^


def _split() raises -> List[UInt8]:
    """Two documents; one fast field of every class and encoding."""
    var sb = SchemaBuilder()
    sb.add_field(Field("body", ArrowType.STRING, False))
    sb.add_field(Field("_source", ArrowType.STRING, False))
    sb.add_field(Field("status", ArrowType.STRING, True))
    sb.add_field(Field("price", ArrowType.INT64, True))
    sb.add_field(Field("ratio", ArrowType.FLOAT64, True))
    sb.add_field(Field("day", ArrowType.DATE32, True))
    sb.add_field(Field("ts", ArrowType.TIMESTAMP, True))
    var schema = sb.build()
    var rb = RecordBatchBuilder.with_capacity(7)
    rb.add_column(
        Column.from_string(
            StringArray.from_strings([String("alpha"), String("beta")])
        )
    )
    rb.add_column(
        Column.from_string(StringArray.from_strings([String("d0"), String("d1")]))
    )
    rb.add_column(
        Column.from_string(
            StringArray.from_strings([String("active"), String("sold")])
        )
    )
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list([Int64(10), Int64(20)])
        )
    )
    rb.add_column(
        Column.from_primitive[DType.float64](
            PrimitiveArray[DType.float64].from_list([Float64(0.5), Float64(1.5)])
        )
    )
    rb.add_column(
        Column.from_primitive_with_arrow_type[DType.int32](
            PrimitiveArray[DType.int32].from_list([Int32(19000), Int32(19001)]),
            ArrowType.DATE32,
        )
    )
    rb.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](
            PrimitiveArray[DType.int64].from_list([Int64(1), Int64(2)]),
            ArrowType.TIMESTAMP,
        )
    )
    var batch = rb.build(schema.copy())
    var sink = SearchSink(
        String("bucket"), String("prefix"), String("logs"), String("body"),
        _uuid(3),
    )
    sink.init_sink(schema^)
    sink.accept_batch(batch^)
    sink.finish()
    return sink.take_split_bytes()


def _gate() raises -> FastFieldPushdownGate:
    return FastFieldPushdownGate.from_split_bytes(_split())


def _cmp(op: UInt8, col: String, var lit: ScalarValue) -> Expr:
    return Expr.binary(op, Expr.col_ref(col), Expr.literal(lit^))


def _ops() -> List[UInt8]:
    return [BIN_EQ, BIN_NE, BIN_LT, BIN_LE, BIN_GT, BIN_GE]


def _is_range(op: UInt8) -> Bool:
    return op == BIN_LT or op == BIN_LE or op == BIN_GT or op == BIN_GE


def _in(col: String, var values: List[ScalarValue]) -> Expr:
    return Expr.in_list_node(Expr.col_ref(col), values^)


# =============================================================================
# The fast-field set.
# =============================================================================


def test_the_gate_reads_every_fast_field_of_the_split() raises:
    var g = _gate()
    # The five declared fast fields plus the doc-length fieldnorm the sink
    # writes into every split's fast-field region.
    assert_equal(
        g.num_fast_fields(), 6, "status, price, ratio, day, ts, " + FIELDNORM_NAME
    )
    # The text field and `_source` are not fast fields.
    assert_false(
        g.supports_filter_pushdown(
            _cmp(BIN_EQ, String("body"), ScalarValue.from_string("alpha"))
        ),
        "the analyzed text field is not a fast field",
    )
    assert_false(
        g.supports_filter_pushdown(
            _cmp(BIN_EQ, String("_source"), ScalarValue.from_string("d0"))
        ),
        "_source is not a fast field",
    )


# =============================================================================
# The class x operator x literal matrix.
# =============================================================================


def test_a_keyword_field_takes_eq_and_ne_with_a_string_only() raises:
    var g = _gate()
    var ops = _ops()
    for i in range(len(ops)):
        var op = ops[i]
        var got = g.supports_filter_pushdown(
            _cmp(op, String("status"), ScalarValue.from_string("sold"))
        )
        assert_equal(
            got, not _is_range(op), "keyword op " + String(Int(op))
        )
        # An int literal is never a keyword's, on any operator.
        assert_false(
            g.supports_filter_pushdown(
                _cmp(op, String("status"), ScalarValue.from_int(1))
            ),
            "keyword vs int, op " + String(Int(op)),
        )


def test_an_int_numeric_field_takes_every_comparison_with_an_int() raises:
    var g = _gate()
    var ops = _ops()
    for i in range(len(ops)):
        var op = ops[i]
        var what = String("price op ") + String(Int(op))
        assert_true(
            g.supports_filter_pushdown(
                _cmp(op, String("price"), ScalarValue.from_int64(15))
            ),
            what + " int",
        )
        assert_true(
            g.supports_filter_pushdown(
                _cmp(op, String("price"), ScalarValue.from_int32(15))
            ),
            what + " int32",
        )
        assert_false(
            g.supports_filter_pushdown(
                _cmp(op, String("price"), ScalarValue.from_float(15.0))
            ),
            what + " float",
        )
        assert_false(
            g.supports_filter_pushdown(
                _cmp(op, String("price"), ScalarValue.from_string("15"))
            ),
            what + " string",
        )
        assert_false(
            g.supports_filter_pushdown(
                _cmp(op, String("price"), ScalarValue.from_bool(True))
            ),
            what + " bool",
        )
        assert_false(
            g.supports_filter_pushdown(
                _cmp(op, String("price"), ScalarValue.null(DType.int64))
            ),
            what + " null",
        )


def test_a_float_numeric_field_takes_a_float_only() raises:
    var g = _gate()
    var ops = _ops()
    for i in range(len(ops)):
        var op = ops[i]
        var what = String("ratio op ") + String(Int(op))
        assert_true(
            g.supports_filter_pushdown(
                _cmp(op, String("ratio"), ScalarValue.from_float(1.0))
            ),
            what + " float",
        )
        assert_false(
            g.supports_filter_pushdown(
                _cmp(op, String("ratio"), ScalarValue.from_int64(1))
            ),
            what + " int",
        )


def test_a_date_field_takes_an_int_a_date32_or_a_timestamp() raises:
    var g = _gate()
    var ops = _ops()
    var cols: List[String] = [String("day"), String("ts")]
    for c in range(len(cols)):
        for i in range(len(ops)):
            var op = ops[i]
            var what = cols[c] + String(" op ") + String(Int(op))
            assert_true(
                g.supports_filter_pushdown(
                    _cmp(op, cols[c], ScalarValue.from_int64(19000))
                ),
                what + " int",
            )
            assert_true(
                g.supports_filter_pushdown(
                    _cmp(op, cols[c], ScalarValue.date32(Int32(19000)))
                ),
                what + " date32",
            )
            assert_true(
                g.supports_filter_pushdown(
                    _cmp(op, cols[c], ScalarValue.timestamp_micros(Int64(1)))
                ),
                what + " timestamp",
            )
            assert_false(
                g.supports_filter_pushdown(
                    _cmp(op, cols[c], ScalarValue.from_float(1.0))
                ),
                what + " float",
            )
            assert_false(
                g.supports_filter_pushdown(
                    _cmp(op, cols[c], ScalarValue.from_string("2022-01-01"))
                ),
                what + " string",
            )


def test_the_literal_may_stand_on_either_side() raises:
    var g = _gate()
    # 15 < price: the literal on the left.
    assert_true(
        g.supports_filter_pushdown(
            Expr.binary(
                BIN_LT,
                Expr.literal(ScalarValue.from_int64(15)),
                Expr.col_ref(String("price")),
            )
        ),
        "literal on the left",
    )
    # 'sold' = status: still a keyword term.
    assert_true(
        g.supports_filter_pushdown(
            Expr.binary(
                BIN_EQ,
                Expr.literal(ScalarValue.from_string("sold")),
                Expr.col_ref(String("status")),
            )
        ),
        "keyword literal on the left",
    )
    # 'sold' < status: a keyword range, from the left too.
    assert_false(
        g.supports_filter_pushdown(
            Expr.binary(
                BIN_LT,
                Expr.literal(ScalarValue.from_string("sold")),
                Expr.col_ref(String("status")),
            )
        ),
        "keyword range with the literal on the left",
    )


# =============================================================================
# Shapes.
# =============================================================================


def test_and_is_pushable_iff_both_sides_are() raises:
    var g = _gate()
    var good = _cmp(BIN_EQ, String("status"), ScalarValue.from_string("sold"))
    var good2 = _cmp(BIN_GE, String("price"), ScalarValue.from_int64(15))
    var bad = _cmp(BIN_LT, String("status"), ScalarValue.from_string("sold"))
    assert_true(
        g.supports_filter_pushdown(
            Expr.binary(BIN_AND, good.copy(), good2.copy())
        ),
        "both sides pushable",
    )
    assert_false(
        g.supports_filter_pushdown(Expr.binary(BIN_AND, good.copy(), bad.copy())),
        "right side not pushable",
    )
    assert_false(
        g.supports_filter_pushdown(Expr.binary(BIN_AND, bad.copy(), good.copy())),
        "left side not pushable",
    )
    assert_false(
        g.supports_filter_pushdown(
            Expr.binary(BIN_OR, good.copy(), good2.copy())
        ),
        "OR of two pushable comparisons",
    )


def test_every_other_shape_is_rejected() raises:
    var g = _gate()
    assert_false(
        g.supports_filter_pushdown(
            Expr.binary(
                BIN_ADD,
                Expr.col_ref(String("price")),
                Expr.literal(ScalarValue.from_int64(1)),
            )
        ),
        "arithmetic",
    )
    assert_false(
        g.supports_filter_pushdown(Expr.col_ref(String("price"))),
        "a bare column",
    )
    assert_false(
        g.supports_filter_pushdown(Expr.literal(ScalarValue.from_bool(True))),
        "a bare literal",
    )
    assert_false(
        g.supports_filter_pushdown(
            Expr.binary(
                BIN_EQ, Expr.col_ref(String("price")), Expr.col_ref(String("ts"))
            )
        ),
        "a column against a column",
    )
    assert_false(
        g.supports_filter_pushdown(
            Expr.binary(
                BIN_EQ,
                Expr.literal(ScalarValue.from_int64(1)),
                Expr.literal(ScalarValue.from_int64(1)),
            )
        ),
        "two literals",
    )
    assert_false(
        g.supports_filter_pushdown(
            Expr.binary(
                BIN_GT,
                Expr.left(String("price")),
                Expr.literal(ScalarValue.from_int64(1)),
            )
        ),
        "a join-side-qualified column",
    )
    assert_false(
        g.supports_filter_pushdown(
            _cmp(BIN_EQ, String("nope"), ScalarValue.from_int64(1))
        ),
        "a column with no fast field",
    )


# =============================================================================
# IN.
# =============================================================================


def test_in_is_pushable_iff_every_value_matches_the_class() raises:
    var g = _gate()
    assert_true(
        g.supports_filter_pushdown(
            _in(
                String("status"),
                [ScalarValue.from_string("sold"), ScalarValue.from_string("x")],
            )
        ),
        "keyword IN strings",
    )
    assert_true(
        g.supports_filter_pushdown(
            _in(
                String("price"),
                [
                    ScalarValue.from_int64(1),
                    ScalarValue.from_int64(2),
                    ScalarValue.from_int64(3),
                ],
            )
        ),
        "numeric IN ints",
    )
    # A mismatch in the LAST value only: every value is checked.
    assert_false(
        g.supports_filter_pushdown(
            _in(
                String("status"),
                [
                    ScalarValue.from_string("sold"),
                    ScalarValue.from_string("x"),
                    ScalarValue.from_int64(5),
                ],
            )
        ),
        "keyword IN with an int last",
    )
    assert_false(
        g.supports_filter_pushdown(
            _in(
                String("price"),
                [ScalarValue.from_float(1.0), ScalarValue.from_int64(2)],
            )
        ),
        "numeric IN with a float first",
    )
    assert_false(
        g.supports_filter_pushdown(_in(String("status"), List[ScalarValue]())),
        "an empty IN list",
    )
    assert_false(
        g.supports_filter_pushdown(
            _in(String("nope"), [ScalarValue.from_string("sold")])
        ),
        "IN over a column with no fast field",
    )
    assert_false(
        g.supports_filter_pushdown(
            Expr.in_list_node(
                Expr.literal(ScalarValue.from_string("sold")),
                [ScalarValue.from_string("sold")],
            )
        ),
        "IN over a literal",
    )
    assert_false(
        g.supports_filter_pushdown(
            Expr.in_list_node(
                Expr.left(String("status")), [ScalarValue.from_string("sold")]
            )
        ),
        "IN over a join-side-qualified column",
    )


def test_the_literal_check_refuses_a_name_with_no_fast_field() raises:
    # Defence in depth: every caller has already found the name, so a
    # missing name reaches this check only through it directly.
    var g = _gate()
    assert_false(
        g._literal_matches_class(String("nope"), ScalarValue.from_string("x")),
        "no fast field named nope",
    )
    assert_true(
        g._literal_matches_class(String("status"), ScalarValue.from_string("x")),
        "status is the first fast field",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
