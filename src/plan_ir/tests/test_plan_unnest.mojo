# =============================================================================
# PLAN_UNNEST: the node, its output schema, and the walks over it
# =============================================================================
#
# `LogicalPlan.unnest(child, column, keep_empty)` replaces the LIST column
# `column` of the child, in place and under the same name, by its element
# type; it is nullable when the element is or when `keep_empty` is set. A
# column that is not there, is not a list, or holds an element type with
# parameters or children, is refused by name. The render
# is the structural hash, so the two `keep_empty` values must differ in it.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_UNNEST,
    SOURCE_PARQUET,
    plan_tag_name,
)
from plan_ir.plan_helpers import (
    _copy_plan,
    _count_nodes,
    _plan_depth,
    _plan_has_any_tag,
    _plan_has_consecutive_filters,
    _plan_has_sort_above_limit,
    _plan_has_tag,
    explain_plan,
    validate_plan_integrity,
)
from plan_ir.schema_propagation import infer_schema


comptime SCAN_LINE = 'Scan(path="t.parquet", type=PARQUET, source_kind=COLUMNAR)\n'


def _scan_of(var tags: Field) -> LogicalPlan:
    """A scan of (id: INT64 not null, `tags`, n: FLOAT64 nullable)."""
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(tags^)
    sb.add_field(Field("n", ArrowType.FLOAT64, True))
    return LogicalPlan.scan("t.parquet", SOURCE_PARQUET, sb.build())


def _string_lists() -> LogicalPlan:
    return _scan_of(Field.list_of_string("tags", False, item_nullable=False))


def _refusal(var child: LogicalPlan, column: String) -> String:
    try:
        _ = LogicalPlan.unnest(child^, column, False)
    except e:
        return String(e)
    return String("")


def test_the_output_schema_replaces_a_string_list_in_place() raises:
    var p = LogicalPlan.unnest(_string_lists(), "tags", False)
    var s = p.output_schema.copy()
    assert_equal(s.num_columns(), 3)
    assert_equal(s.field_name(0), "id")
    assert_equal(s.field_name(1), "tags")
    assert_equal(s.field_name(2), "n")
    assert_true(s.field_arrow_type(1) == ArrowType.STRING)
    assert_equal(s.field_num_children(1), 0)
    assert_true(s.field_arrow_type(0) == ArrowType.INT64)
    assert_false(s.field_nullable(0))
    assert_true(s.field_arrow_type(2) == ArrowType.FLOAT64)
    assert_true(s.field_nullable(2))


def test_the_output_schema_replaces_an_int_list_in_place() raises:
    var child = _scan_of(
        Field.list_of("tags", ArrowType.INT64, True, item_nullable=True)
    )
    var p = LogicalPlan.unnest(child^, "tags", False)
    assert_equal(p.output_schema.field_name(1), "tags")
    assert_true(p.output_schema.field_arrow_type(1) == ArrowType.INT64)
    assert_true(p.output_schema.field_nullable(1))


def test_nullability_follows_the_element_and_keep_empty() raises:
    var strict_drop = LogicalPlan.unnest(_string_lists(), "tags", False)
    assert_false(strict_drop.output_schema.field_nullable(1))
    var strict_keep = LogicalPlan.unnest(_string_lists(), "tags", True)
    assert_true(strict_keep.output_schema.field_nullable(1))
    var loose_child = _scan_of(
        Field.list_of_string("tags", False, item_nullable=True)
    )
    var loose_drop = LogicalPlan.unnest(loose_child^, "tags", False)
    assert_true(loose_drop.output_schema.field_nullable(1))


def test_an_unknown_column_is_refused_by_name() raises:
    assert_equal(
        _refusal(_string_lists(), "nope"),
        "unnest: no column 'nope' in its input",
    )


def test_a_non_list_column_is_refused_by_name() raises:
    var msg = _refusal(_string_lists(), "id")
    assert_equal(msg, "unnest: column 'id' is " + String(ArrowType.INT64) + ", not a list")
    assert_true("not a list" in _refusal(_string_lists(), "n"))


def test_a_list_without_one_element_type_is_refused() raises:
    var child = _scan_of(Field("tags", ArrowType.LIST, True))
    assert_equal(
        _refusal(child^, "tags"),
        "unnest: column 'tags' is " + String(ArrowType.LIST) + ", not a list",
    )


def test_an_element_type_with_parameters_is_refused() raises:
    var decimals = _scan_of(
        Field.list_of("tags", ArrowType.DECIMAL128, True)
    )
    assert_equal(
        _refusal(decimals^, "tags"),
        "unnest: column 'tags' holds " + String(ArrowType.DECIMAL128)
        + " elements, which unnest does not serve: only an element type with"
        " no parameters and no children is",
    )
    var nested = _scan_of(Field.list_of("tags", ArrowType.LIST, True))
    assert_true("does not serve" in _refusal(nested^, "tags"))


def test_tag_accessors_and_name() raises:
    var p = LogicalPlan.unnest(_string_lists(), "tags", True)
    assert_equal(Int(PLAN_UNNEST), 21)
    assert_equal(plan_tag_name(PLAN_UNNEST), "Unnest")
    assert_true(p.is_unnest())
    assert_false(_string_lists().is_unnest())
    assert_equal(p.unnest_data_ref().column, "tags")
    assert_true(p.unnest_data_ref().keep_empty)
    assert_true(p.unnest_data_ref().child[].is_scan())


def test_render_shows_both_fields_and_the_child() raises:
    var drop = String(LogicalPlan.unnest(_string_lists(), "tags", False))
    var keep = String(LogicalPlan.unnest(_string_lists(), "tags", True))
    assert_equal(drop, "Unnest(column=tags, keep_empty=false)\n  " + String(SCAN_LINE))
    assert_equal(keep, "Unnest(column=tags, keep_empty=true)\n  " + String(SCAN_LINE))


def test_keep_empty_and_column_enter_the_structural_hash() raises:
    var drop = LogicalPlan.unnest(_string_lists(), "tags", False)
    var keep = LogicalPlan.unnest(_string_lists(), "tags", True)
    var again = LogicalPlan.unnest(_string_lists(), "tags", False)
    assert_true(drop.structural_hash() != keep.structural_hash())
    assert_equal(drop.structural_hash(), again.structural_hash())
    var sb = SchemaBuilder()
    sb.add_field(Field.list_of_string("a", False, item_nullable=False))
    sb.add_field(Field.list_of_string("b", False, item_nullable=False))
    var two = LogicalPlan.scan("t.parquet", SOURCE_PARQUET, sb.build())
    var on_a = LogicalPlan.unnest(two.copy(), "a", False)
    var on_b = LogicalPlan.unnest(two^, "b", False)
    assert_true(on_a.structural_hash() != on_b.structural_hash())


def test_copy_keeps_the_payload() raises:
    var p = LogicalPlan.unnest(_string_lists(), "tags", True)
    var c = p.copy()
    assert_true(c.is_unnest())
    assert_equal(c.unnest_data_ref().column, "tags")
    assert_true(c.unnest_data_ref().keep_empty)
    assert_equal(String(c), String(p))
    var r = _copy_plan(p)
    assert_equal(String(r), String(p))
    assert_equal(r.structural_hash(), p.structural_hash())


def test_integrity_accepts_a_node_and_refuses_a_missing_payload() raises:
    assert_true(validate_plan_integrity(LogicalPlan.unnest(_string_lists(), "tags", False)))
    assert_false(validate_plan_integrity(LogicalPlan(PLAN_UNNEST, _string_lists().output_schema.copy())))


def test_infer_schema_rederives_the_stored_schema() raises:
    var p = LogicalPlan.unnest(_string_lists(), "tags", True)
    var inferred = infer_schema(p)
    assert_equal(inferred.num_columns(), 3)
    for i in range(3):
        assert_equal(inferred.field_name(i), p.output_schema.field_name(i))
        assert_true(inferred.field_arrow_type(i) == p.output_schema.field_arrow_type(i))
        assert_equal(inferred.field_nullable(i), p.output_schema.field_nullable(i))


def test_the_tree_walks_descend_through_the_node() raises:
    var p = LogicalPlan.unnest(_string_lists(), "tags", False)
    assert_true(_plan_has_tag(p, PLAN_UNNEST))
    assert_true(_plan_has_tag(p, UInt8(0)))
    assert_true(_plan_has_any_tag(p, UInt8(0), UInt8(200)))
    assert_false(_plan_has_consecutive_filters(p))
    assert_false(_plan_has_sort_above_limit(p))
    assert_equal(_count_nodes(p), 2)
    assert_equal(_plan_depth(p), 2)
    assert_equal(
        explain_plan(p),
        "Unnest [column=tags, keep_empty=false]\n  Scan path=t.parquet\n",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
