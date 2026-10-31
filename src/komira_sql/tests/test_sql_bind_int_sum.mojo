# =============================================================================
# SQL `sum()` over an integer: the bound plan declares DECIMAL(38, 0)
# =============================================================================
#
# DuckDB types the sum of an integer as HUGEINT, which cannot overflow. Arrow
# has no 128-bit integer; DECIMAL(38, 0) is its one type that holds every
# HUGEINT total exactly. The SQL binder states the widening by casting the
# aggregate's argument to DECIMAL(38, 0) and keeping the SUM aggregate, so the
# plan's declared output type is DECIMAL(38, 0) and the DECIMAL fold (which sums
# in 128 bits) answers it. Every query binds against a catalog of parquet
# tables registered with a given schema (no file is opened).
#
# What each test proves, and the defect it would catch:
#   * test_every_integer_width_declares_decimal_38_0: sum over INT8, INT16,
#     INT32, INT64, UINT8, UINT16, UINT32 and UINT64 is a nullable
#     DECIMAL(38, 0) column, with the argument cast under the aggregate. Catches
#     a width that keeps its INT64 / UINT64 promotion (an accumulator that can
#     wrap), and a cast whose scale or precision is not (0, 38).
#   * test_an_expression_a_case_and_a_literal_are_widened_too: sum of an
#     integer expression, of a CASE with integer branches and of an integer
#     literal declare DECIMAL(38, 0). Catches a widening that looks only at a
#     bare column.
#   * test_grouped_and_having_sums_are_widened: GROUP BY, HAVING and an
#     expression over the sum all bind, and the output column is DECIMAL(38, 0).
#     Catches a second aggregate-building site that skips the widening.
#   * test_a_boolean_sum_is_widened_too: DuckDB's sum(BOOLEAN) is HUGEINT, so a
#     BOOL column and a comparison are widened like an integer.
#   * test_sums_of_other_types_keep_their_declared_types: FLOAT64 and DECIMAL(12,
#     2) sums keep FLOAT64 and DECIMAL(38, 2), and avg, min, max and count keep
#     their types. Catches a widening that casts a type it must not.
#   * test_division_over_a_sum_is_double_and_integer_division_is_refused: `/`
#     over an integer sum casts it to DOUBLE (float64 result), a FLOAT or
#     DECIMAL(12, 2) sum keeps the plain division, and `//` over an
#     integer sum is refused by name. Catches a division that falls to the
#     engine's four-place DECIMAL division (3.5000 for 7 / 2) or answers 3.5
#     for 7 // 2.
#   * test_sum_distinct_is_still_refused: unchanged.
#   * test_a_dataframe_door_plan_keeps_int64: the same SUM aggregate built
#     without the SQL binder, over the same scan, keeps the INT64 / UINT64
#     promotion (the DataFrame doors answer like their libraries). Catches the
#     widening moving out of the SQL door into the shared plan type rule.

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, SchemaBuilder
from komira_plan_expr.agg_expr import AGG_SUM, AggExpr
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import AggExprArray, ExprArray, LogicalPlan
from komira_sql.sql_bind_parquet import NoParquetFooters
from komira_sql.sql_binder import bind_statement
from komira_sql.sql_catalog import SqlCatalog
from komira_sql.sql_parser import parse_sql
from komira_sql.sql_token import tokenize


def _catalog() raises -> SqlCatalog:
    """t(k, i8, i16, i32, i64, u8, u16, u32, u64, f, dc, b, s)."""
    var cat = SqlCatalog()
    var t = SchemaBuilder()
    t.add_field(Field(String("k"), ArrowType.INT64, True))
    t.add_field(Field(String("i8"), ArrowType.INT8, True))
    t.add_field(Field(String("i16"), ArrowType.INT16, True))
    t.add_field(Field(String("i32"), ArrowType.INT32, True))
    t.add_field(Field(String("i64"), ArrowType.INT64, True))
    t.add_field(Field(String("u8"), ArrowType.UINT8, True))
    t.add_field(Field(String("u16"), ArrowType.UINT16, True))
    t.add_field(Field(String("u32"), ArrowType.UINT32, True))
    t.add_field(Field(String("u64"), ArrowType.UINT64, True))
    t.add_field(Field(String("f"), ArrowType.FLOAT64, True))
    t.add_field(Field.decimal128(String("dc"), 12, 2, True))
    t.add_field(Field(String("b"), ArrowType.BOOL, True))
    t.add_field(Field(String("s"), ArrowType.STRING, True))
    cat.add_parquet(String("t"), String("t.parquet"), t.build())
    return cat^


def _plan(sql: String) raises -> LogicalPlan:
    var cat = _catalog()
    var bound = bind_statement(parse_sql(tokenize(sql)), cat, NoParquetFooters())
    return bound.take_plan()


def _type_of(ref plan: LogicalPlan, col: Int) -> String:
    """`<arrow type>` plus `(p,s)` for a DECIMAL128, and `?` when nullable."""
    var out = String(plan.output_schema.field_arrow_type(col))
    if plan.output_schema.field_arrow_type(col) == ArrowType.DECIMAL128:
        out += (
            "("
            + String(plan.output_schema.field_decimal_precision(col))
            + ","
            + String(plan.output_schema.field_decimal_scale(col))
            + ")"
        )
    if plan.output_schema.field_nullable(col):
        out += "?"
    return out


def _out_type(sql: String) raises -> String:
    var plan = _plan(sql)
    return _type_of(plan, 0)


def test_every_integer_width_declares_decimal_38_0() raises:
    var cols = List[String]()
    cols.append("i8")
    cols.append("i16")
    cols.append("i32")
    cols.append("i64")
    cols.append("u8")
    cols.append("u16")
    cols.append("u32")
    cols.append("u64")
    for c in range(len(cols)):
        var sql = "SELECT sum(" + cols[c] + ") FROM t"
        var plan = _plan(sql)
        assert_equal(_type_of(plan, 0), "decimal128(38,0)?", sql)
        var text = String(plan)
        assert_true(
            text.find("Cast(ColRef(" + cols[c] + ")") >= 0,
            "the argument is not cast: " + text,
        )
        assert_true(text.find("p=38, s=0") >= 0, "not DECIMAL(38,0): " + text)


def test_an_expression_a_case_and_a_literal_are_widened_too() raises:
    assert_equal(
        _out_type("SELECT sum(i32 + 1) FROM t"), "decimal128(38,0)?"
    )
    assert_equal(
        _out_type("SELECT sum(i64 * 2) FROM t"), "decimal128(38,0)?"
    )
    assert_equal(
        _out_type("SELECT sum(CASE WHEN i32 > 1 THEN i32 ELSE 0 END) FROM t"),
        "decimal128(38,0)?",
    )
    assert_equal(_out_type("SELECT sum(1) FROM t"), "decimal128(38,0)?")
    assert_equal(
        _out_type("SELECT sum(abs(i64)) FROM t"), "decimal128(38,0)?"
    )


def test_grouped_and_having_sums_are_widened() raises:
    var plan = _plan("SELECT k, sum(i32) AS total FROM t GROUP BY k")
    assert_equal(_type_of(plan, 1), "decimal128(38,0)?")
    var having = _plan(
        "SELECT k, sum(i64) FROM t GROUP BY k HAVING sum(i32) > 1"
    )
    assert_equal(_type_of(having, 1), "decimal128(38,0)?")
    var text = String(having)
    # The HAVING-only sum is a hidden aggregate, widened like the selected one.
    assert_true(text.find("Cast(ColRef(i32)") >= 0, text)
    assert_true(text.find("Cast(ColRef(i64)") >= 0, text)
    var ratio = _plan("SELECT k, sum(i64) / count(*) AS r FROM t GROUP BY k")
    assert_equal(ratio.output_schema.num_columns(), 2)


def test_sums_of_other_types_keep_their_declared_types() raises:
    assert_equal(_out_type("SELECT sum(f) FROM t"), "float64?")
    assert_equal(_out_type("SELECT sum(dc) FROM t"), "decimal128(38,2)?")
    # avg, min, max and count are not touched.
    var plan = _plan("SELECT avg(i32), min(i32), max(i64), count(i32) FROM t")
    assert_equal(_type_of(plan, 0), "float64?")
    assert_equal(_type_of(plan, 1), "int32?")
    assert_equal(_type_of(plan, 2), "int64?")


def test_a_boolean_sum_is_widened_too() raises:
    # DuckDB's `sum(BOOLEAN)` is HUGEINT as well.
    assert_equal(_out_type("SELECT sum(b) FROM t"), "decimal128(38,0)?")
    assert_equal(
        _out_type("SELECT sum(i32 > 1) FROM t"), "decimal128(38,0)?"
    )


def _err(sql: String) raises -> String:
    try:
        _ = _plan(sql)
    except e:
        return String(e)
    raise Error("bound, expected a refusal: " + sql)


def test_division_over_a_sum_is_double_and_integer_division_is_refused() raises:
    # DuckDB's `/` over an integer sum is DOUBLE: the DECIMAL(38, 0) sum is cast
    # to DOUBLE, not divided as a DECIMAL (which would round to four places).
    var plan = _plan("SELECT sum(i32) / count(*) AS r FROM t")
    assert_equal(_type_of(plan, 0), "float64?")
    assert_true(
        String(plan).find("DIV, Cast(ColRef(_agg_x0), float64), ColRef(_agg_x1)") >= 0,
        String(plan),
    )
    var right = _plan("SELECT count(*) / sum(i32) AS r FROM t")
    assert_equal(_type_of(right, 0), "float64?")
    assert_true(
        String(right).find("Cast(ColRef(_agg_x1), float64)") >= 0, String(right)
    )
    # A float or DECIMAL(p, s>0) sum keeps the plain division.
    assert_true(String(_plan("SELECT sum(f) / count(*) FROM t")).find("Cast(") < 0)
    assert_true(
        String(_plan("SELECT sum(dc) / count(*) FROM t")).find("float64") < 0
    )
    # `//` over an integer sum has no 128-bit kernel and is
    # refused by name, not answered as a DECIMAL division.
    var want = "SQL not supported: `//` / divide() over the sum of an integer column"
    assert_true(_err("SELECT sum(i32) // count(*) FROM t").startswith(want))
    assert_true(_err("SELECT 7 // sum(i64) FROM t").startswith(want))


def test_sum_distinct_is_still_refused() raises:
    var refused = False
    try:
        _ = _plan("SELECT sum(DISTINCT i32) FROM t")
    except e:
        refused = String(e).find("DISTINCT is only supported on COUNT") >= 0
    assert_true(refused)


def _dataframe_sum_type(col: String) raises -> String:
    """The output type of `SUM(<col>)` built the way a DataFrame door builds it:
    an AggExpr over the bare column, no SQL binder."""
    var scan = _plan("SELECT * FROM t")
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional(Expr.col_ref(col)), None))
    var plan = LogicalPlan.aggregate(ExprArray(), aggs^, scan^)
    return _type_of(plan, 0)


def test_a_dataframe_door_plan_keeps_int64() raises:
    assert_equal(_dataframe_sum_type("i8"), "int64?")
    assert_equal(_dataframe_sum_type("i32"), "int64?")
    assert_equal(_dataframe_sum_type("i64"), "int64?")
    assert_equal(_dataframe_sum_type("u8"), "uint64?")
    assert_equal(_dataframe_sum_type("u32"), "uint64?")
    assert_equal(_dataframe_sum_type("u64"), "uint64?")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
