# =============================================================================
# Schema re-derivation: `schema_propagation.infer_schema` and friends
# =============================================================================
#
# `infer_schema` re-derives a node's output schema from the plan structure,
# so a validator can compare it with the schema the factory stored. Each case
# asserts the derived schema field by field, as `_fields` spells it:
# `name:type_id:nullable:tz` per field, worked out from the propagation rules
# in the module header and the inputs below. Where the stored schema is right
# for the shape, it is asserted equal too: the two must agree.
#
# THE TIMEZONE. Column `t` is a TIMESTAMP_US in "UTC". A copy that rebuilt
# each field from (name, type, nullable) alone would drop the zone; every
# pass-through case carries `t` so that shows.
#
# Shapes where the derived schema and the stored one disagree are NOT
# asserted here; they are reported as findings (a partition top-n with a rank
# column, an aggregate with two same-named outputs, and the tags with no arm).
#
# Test groups:
#   1. infer_schema per node kind, and the refusal of a tag with no arm.
#   2. The column accessors.
#   3. schema_from_project_exprs: inference, and the top-level missing
#      column refusal (direct and through one alias).
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_raises

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_collections.slab import Slab
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT, AGG_MEAN
from komira_plan_expr.expr import Expr
from komira_plan_expr.partition_expr import PartitionExpr, PF_ROW_NUMBER
from komira_plan_expr.partition_frame import PartitionFrame
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    JOIN_ANTI,
    JOIN_INNER,
    JOIN_LEFT,
    JOIN_SEMI,
    SOURCE_PARQUET,
)
from komira_plan_ir.schema_propagation import (
    infer_schema,
    schema_column_name,
    schema_column_type,
    schema_from_project_exprs,
    schema_num_columns,
)


# =============================================================================
# Fixtures
# =============================================================================


comptime AT = "a:5:0:,t:24:1:UTC"
"""`_fields` of `_schema()`."""


def _schema() raises -> Schema:
    """a INT64 not null, t TIMESTAMP_US nullable in UTC."""
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field.timestamp("t", ArrowType.TIMESTAMP_US, "UTC", True))
    return sb.build()


def _right_schema() raises -> Schema:
    """a FLOAT64 nullable (collides with the left `a`), b INT64 not null."""
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.FLOAT64, True))
    sb.add_field(Field("b", ArrowType.INT64, False))
    return sb.build()


def _fields(s: Schema) -> String:
    var out = String()
    for i in range(s.num_columns()):
        if i > 0:
            out += ","
        out += s.field_name(i) + ":" + String(Int(s.field_arrow_type(i).type_id))
        out += ":" + ("1" if s.field_nullable(i) else "0")
        out += ":" + s.field_tz(i)
    return out^


def _scan() raises -> LogicalPlan:
    return LogicalPlan.scan(String("l.parquet"), SOURCE_PARQUET, _schema())


def _rscan() raises -> LogicalPlan:
    return LogicalPlan.scan(String("r.parquet"), SOURCE_PARQUET, _right_schema())


def _agrees(plan: LogicalPlan, expected: String) raises:
    """`infer_schema(plan)` is `expected`, and so is the stored schema."""
    assert_equal(_fields(infer_schema(plan)), expected)
    assert_equal(_fields(plan.output_schema), expected)


def _keys() -> List[String]:
    var k = List[String]()
    k.append(String("a"))
    return k^


def _desc() -> List[Bool]:
    var d = List[Bool]()
    d.append(True)
    return d^


# =============================================================================
# 1. infer_schema per node kind
# =============================================================================


def test_scan_is_its_stored_projected_schema() raises:
    _agrees(_scan(), AT)
    var proj = List[String]()
    proj.append(String("t"))
    var p = LogicalPlan.scan(
        String("l.parquet"),
        SOURCE_PARQUET,
        _schema(),
        projection=Optional[List[String]](proj^),
    )
    _agrees(p, "t:24:1:UTC")


def test_filter_is_its_childs_schema() raises:
    _agrees(LogicalPlan.filter(Expr.col_ref(String("a")), _scan()), AT)


def test_project_is_derived_from_its_expressions() raises:
    var exprs = Slab[Expr].create(3)
    exprs.append(Expr.col_ref(String("t")))
    exprs.append(Expr.alias(Expr.col_ref(String("a")), String("x")))
    exprs.append(Expr.col_ref(String("a")))
    _agrees(LogicalPlan.project(exprs^, _scan()), "t:24:1:UTC,x:5:0:,a:5:0:")


def test_aggregate_is_group_keys_then_aggregate_outputs() raises:
    var gb = Slab[Expr].create(1)
    gb.append(Expr.col_ref(String("a")))
    var aggs = Slab[AggExpr].create(2)
    aggs.append(AggExpr(AGG_COUNT, Optional[Expr](), Optional[String]()))
    aggs.append(
        AggExpr(
            AGG_MEAN, Optional[Expr](Expr.col_ref(String("a"))), Optional[String]("m")
        )
    )
    _agrees(LogicalPlan.aggregate(gb^, aggs^, _scan()), "a:5:0:,count:5:0:,m:12:1:")
    # No group key: the aggregate outputs alone.
    var none = Slab[Expr].create(0)
    var one = Slab[AggExpr].create(1)
    one.append(AggExpr(AGG_COUNT, Optional[Expr](), Optional[String]("n")))
    _agrees(LogicalPlan.aggregate(none^, one^, _scan()), "n:5:0:")


def test_join_merges_both_sides_and_suffixes_a_colliding_right_name() raises:
    var on = _keys()
    var inner = LogicalPlan.join(_scan(), _rscan(), on.copy(), on.copy(), JOIN_INNER)
    # The right `a` collides and keeps its own type; `b` does not collide.
    _agrees(inner, "a:5:0:,t:24:1:UTC,a_right:12:1:,b:5:0:")
    # A LEFT join: an unmatched left row has NULL in every right column, so
    # the right side is nullable whatever it declared (`a_right` was not
    # null on its own side); the left side keeps its flags
    # (komira-ai/komira#960).
    var left = LogicalPlan.join(_rscan(), _scan(), on.copy(), on.copy(), JOIN_LEFT)
    _agrees(left, "a:12:1:,b:5:0:,a_right:5:1:,t:24:1:UTC")


def test_semi_and_anti_joins_keep_the_left_side_only() raises:
    var on = _keys()
    _agrees(
        LogicalPlan.join(_scan(), _rscan(), on.copy(), on.copy(), JOIN_SEMI), AT
    )
    _agrees(
        LogicalPlan.join(_rscan(), _scan(), on.copy(), on.copy(), JOIN_ANTI),
        "a:12:1:,b:5:0:",
    )


def test_pass_through_nodes_keep_their_childs_schema() raises:
    _agrees(LogicalPlan.sort(_keys(), _desc(), _scan()), AT)
    _agrees(LogicalPlan.limit(5, _scan()), AT)
    _agrees(LogicalPlan.distinct(None, _scan()), AT)
    _agrees(LogicalPlan.topn(_keys(), _desc(), 3, _scan()), AT)
    # Without a rank column a partition top-n selects rows and adds none.
    _agrees(
        LogicalPlan.partition_topn(_keys(), _keys(), _desc(), 1, _scan()), AT
    )


def test_pass_through_reads_the_direct_child() raises:
    """Over a projection, a sort's schema is the projection's, not the scan's."""
    var exprs = Slab[Expr].create(1)
    exprs.append(Expr.alias(Expr.col_ref(String("t")), String("u")))
    var plan = LogicalPlan.limit(2, LogicalPlan.project(exprs^, _scan()))
    _agrees(plan, "u:24:1:UTC")


def test_partition_by_and_cast_to_varchar_return_their_stored_schema() raises:
    var fs = List[PartitionExpr]()
    fs.append(
        PartitionExpr(
            PF_ROW_NUMBER,
            String("a"),
            0,
            ScalarValue.from_int(0),
            False,
            PartitionFrame(0, 0, 0, 0, 0),
            String("rn"),
        )
    )
    var pb = LogicalPlan.partition_by(List[String](), _keys(), _desc(), fs^, _scan())
    var pb_text = _fields(pb.output_schema)
    # The child's columns, then one more: the window function's.
    assert_equal(pb.output_schema.num_columns(), 3)
    assert_equal(pb.output_schema.field_name(2), "rn")
    assert_equal(_fields(infer_schema(pb)), pb_text)
    # Every column is given its STRING mirror at construction.
    var cv = LogicalPlan.cast_to_varchar(_scan())
    assert_equal(_fields(infer_schema(cv)), _fields(cv.output_schema))
    assert_equal(infer_schema(cv).num_columns(), 2)
    assert_equal(infer_schema(cv).field_arrow_type(0), ArrowType.STRING)


def test_a_tag_with_no_arm_is_refused() raises:
    var plan = LogicalPlan(UInt8(200), _schema())
    with assert_raises(contains="infer_schema: unknown plan tag 200"):
        _ = infer_schema(plan)


# =============================================================================
# 2. The column accessors
# =============================================================================


def test_column_accessors_read_the_stored_schema() raises:
    var j = LogicalPlan.join(_scan(), _rscan(), _keys(), _keys(), JOIN_INNER)
    assert_equal(schema_num_columns(j), 4)
    assert_equal(schema_column_name(j, 2), "a_right")
    assert_equal(schema_column_type(j, 1), ArrowType.TIMESTAMP_US)
    assert_equal(schema_column_type(j, 2), ArrowType.FLOAT64)


# =============================================================================
# 3. schema_from_project_exprs
# =============================================================================


def test_project_exprs_are_inferred_like_a_project_node() raises:
    var exprs = Slab[Expr].create(3)
    exprs.append(Expr.col_ref(String("t")))
    exprs.append(Expr.alias(Expr.col_ref(String("a")), String("x")))
    # An alias over something that is not a column reference: no probe.
    exprs.append(
        Expr.alias(Expr.literal(ScalarValue.from_float(1.5)), String("f"))
    )
    assert_equal(
        _fields(schema_from_project_exprs(_schema(), exprs)),
        "t:24:1:UTC,x:5:0:,f:12:0:",
    )
    # A bare literal is not probed either.
    var lit = Slab[Expr].create(1)
    lit.append(Expr.literal(ScalarValue.from_bool(True)))
    assert_equal(schema_from_project_exprs(_schema(), lit).num_columns(), 1)


def test_a_missing_top_level_column_is_refused_with_index_and_columns() raises:
    var exprs = Slab[Expr].create(2)
    exprs.append(Expr.col_ref(String("a")))
    exprs.append(Expr.col_ref(String("zz")))
    with assert_raises(
        contains="schema_from_project_exprs: cannot resolve dtype for Expr at"
        " projection index 1: column 'zz' not in source schema [a, t]"
    ):
        _ = schema_from_project_exprs(_schema(), exprs)


def test_a_missing_column_under_one_alias_is_refused() raises:
    var exprs = Slab[Expr].create(1)
    exprs.append(Expr.alias(Expr.col_ref(String("q")), String("x")))
    with assert_raises(
        contains="projection index 0: column 'q' not in source schema [a, t]"
    ):
        _ = schema_from_project_exprs(_schema(), exprs)


def test_a_missing_column_against_an_empty_schema() raises:
    var eb = SchemaBuilder()
    var empty = eb.build()
    var exprs = Slab[Expr].create(1)
    exprs.append(Expr.col_ref(String("a")))
    with assert_raises(contains="column 'a' not in source schema []"):
        _ = schema_from_project_exprs(empty, exprs)
    # One column: no separator.
    var sb = SchemaBuilder()
    sb.add_field(Field("b", ArrowType.INT64, False))
    with assert_raises(contains="column 'a' not in source schema [b]"):
        _ = schema_from_project_exprs(sb.build(), exprs)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
