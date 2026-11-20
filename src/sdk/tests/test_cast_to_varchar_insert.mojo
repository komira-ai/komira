# =============================================================================
# cast_to_varchar_insert: one cast-to-string node above a plan a text sink
# writes
# =============================================================================
#
# What each test proves:
#   * test_a_text_sink_gets_one_cast_at_the_root: for a text sink the root
#     becomes a PLAN_CAST_TO_VARCHAR whose child is the plan as given, and
#     whose schema keeps every name and nullability with every type STRING
#     (a DECIMAL, a BOOL and a STRING column included).
#   * test_applying_the_rule_twice_gives_one_cast: a plan whose root already
#     is the cast comes back as it is, for a text and an Arrow-typed sink.
#   * test_an_arrow_typed_sink_leaves_the_plan_as_it_is: a scan, a project
#     and an aggregate root come back unchanged, schema included.
#   * test_a_cast_lower_in_the_plan_is_not_the_root: a cast under a project is
#     not the root, so a text sink still gets its cast at the top.
#   * test_a_plan_with_no_column: a zero-column plan gets a zero-column cast.

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from plan_expr.agg_expr import count
from plan_expr.expr import Expr
from plan_ir.logical_plan import (
    AggExprArray,
    ExprArray,
    LogicalPlan,
    PLAN_AGGREGATE,
    PLAN_CAST_TO_VARCHAR,
    PLAN_PROJECT,
    PLAN_SCAN,
    SOURCE_PARQUET,
)

from sdk.cast_to_varchar_insert import insert_cast_if_text_output


def _schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    sb.add_field(Field.decimal128(String("d"), 12, 2, True))
    sb.add_field(Field(String("b"), ArrowType.BOOL, True))
    sb.add_field(Field(String("s"), ArrowType.STRING, False))
    return sb.build()


def _scan() raises -> LogicalPlan:
    return LogicalPlan.scan("t.parquet", SOURCE_PARQUET, _schema())


def _render(schema: Schema) -> String:
    """`name:type` per column, `?` when nullable, joined by `, `."""
    var out = String("")
    for c in range(schema.num_columns()):
        if c > 0:
            out += ", "
        out += schema.field_name(c) + ":" + String(schema.field_arrow_type(c))
        if schema.field_nullable(c):
            out += "?"
    return out


def _project() raises -> LogicalPlan:
    var exprs = ExprArray()
    exprs.append(Expr.col_ref(String("s")))
    exprs.append(Expr.col_ref(String("k")))
    return LogicalPlan.project(exprs^, _scan())


def _aggregate() raises -> LogicalPlan:
    var keys = ExprArray()
    keys.append(Expr.col_ref(String("s")))
    var aggs = AggExprArray()
    aggs.append(count())
    return LogicalPlan.aggregate(keys^, aggs^, _scan())


def test_a_text_sink_gets_one_cast_at_the_root() raises:
    var before = String(_scan())
    var plan = insert_cast_if_text_output(_scan(), True)
    assert_equal(Int(plan.tag), Int(PLAN_CAST_TO_VARCHAR))
    assert_equal(
        _render(plan.output_schema),
        "k:string, d:string?, b:string?, s:string",
    )
    ref child = plan.cast_to_varchar_data_ref().child[]
    assert_equal(Int(child.tag), Int(PLAN_SCAN))
    assert_equal(String(child), before)
    assert_equal(
        _render(child.output_schema),
        "k:int64, d:decimal128?, b:bool?, s:string",
    )


def test_applying_the_rule_twice_gives_one_cast() raises:
    var once = insert_cast_if_text_output(_project(), True)
    var once_text = String(once)
    var twice = insert_cast_if_text_output(once^, True)
    assert_equal(String(twice), once_text)
    assert_equal(Int(twice.tag), Int(PLAN_CAST_TO_VARCHAR))
    assert_equal(
        Int(twice.cast_to_varchar_data_ref().child[].tag), Int(PLAN_PROJECT)
    )
    var kept = insert_cast_if_text_output(twice^, False)
    assert_equal(String(kept), once_text)
    assert_equal(Int(kept.tag), Int(PLAN_CAST_TO_VARCHAR))


def test_an_arrow_typed_sink_leaves_the_plan_as_it_is() raises:
    var scan_text = String(_scan())
    var scan = insert_cast_if_text_output(_scan(), False)
    assert_equal(Int(scan.tag), Int(PLAN_SCAN))
    assert_equal(String(scan), scan_text)
    assert_equal(_render(scan.output_schema), _render(_schema()))

    var project_text = String(_project())
    var project = insert_cast_if_text_output(_project(), False)
    assert_equal(Int(project.tag), Int(PLAN_PROJECT))
    assert_equal(String(project), project_text)
    assert_equal(_render(project.output_schema), "s:string, k:int64")

    var aggregate_text = String(_aggregate())
    var aggregate = insert_cast_if_text_output(_aggregate(), False)
    assert_equal(Int(aggregate.tag), Int(PLAN_AGGREGATE))
    assert_equal(String(aggregate), aggregate_text)


def test_a_cast_lower_in_the_plan_is_not_the_root() raises:
    var exprs = ExprArray()
    exprs.append(Expr.col_ref(String("k")))
    var inner = LogicalPlan.project(
        exprs^, LogicalPlan.cast_to_varchar(_scan())
    )
    assert_equal(Int(inner.tag), Int(PLAN_PROJECT))
    var plan = insert_cast_if_text_output(inner^, True)
    assert_equal(Int(plan.tag), Int(PLAN_CAST_TO_VARCHAR))
    assert_equal(
        Int(plan.cast_to_varchar_data_ref().child[].tag), Int(PLAN_PROJECT)
    )
    assert_equal(_render(plan.output_schema), "k:string")


def test_a_plan_with_no_column() raises:
    var none = SchemaBuilder()
    var empty = LogicalPlan.scan("e.parquet", SOURCE_PARQUET, none.build())
    var plan = insert_cast_if_text_output(empty^, True)
    assert_equal(Int(plan.tag), Int(PLAN_CAST_TO_VARCHAR))
    assert_equal(plan.output_schema.num_columns(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
