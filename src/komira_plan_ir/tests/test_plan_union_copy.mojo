# =============================================================================
# Tests for the PLAN_UNION / UnionData LogicalPlan variant
# =============================================================================
#
# Covers:
#   - LogicalPlan.union(children, schema) factory + tag/schema wiring.
#   - UnionData.copy() recurses into every child (deep, independent).
#   - LogicalPlan.copy() PLAN_UNION arm.
#   - write_to / structural_hash round-trip stability (same tree -> same hash;
#     a different branch count -> different hash).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false
from std.memory import OwnedPointer

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType

from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_UNION,
    PLAN_SCAN,
    SOURCE_PARQUET,
)


def _schema2() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.INT64, False))
    return sb.build()


def _scan(path: String) -> LogicalPlan:
    return LogicalPlan.scan(path, SOURCE_PARQUET, _schema2())


def _two_branch_union() -> LogicalPlan:
    var children = List[OwnedPointer[LogicalPlan]]()
    children.append(OwnedPointer(_scan("a.parquet")))
    children.append(OwnedPointer(_scan("b.parquet")))
    return LogicalPlan.union(children^, _schema2())


def _three_branch_union() -> LogicalPlan:
    var children = List[OwnedPointer[LogicalPlan]]()
    children.append(OwnedPointer(_scan("a.parquet")))
    children.append(OwnedPointer(_scan("b.parquet")))
    children.append(OwnedPointer(_scan("c.parquet")))
    return LogicalPlan.union(children^, _schema2())


def test_union_factory_basic() raises:
    var u = _two_branch_union()
    assert_equal(Int(u.tag), Int(PLAN_UNION))
    assert_true(u.is_union(), "is_union() should be True for a PLAN_UNION node")
    assert_equal(u.union_data_ref().num_children(), 2)
    # Output schema mirrors what we passed.
    assert_equal(u.output_schema.num_columns(), 2)
    assert_equal(String(u.output_schema.field_name(0)), "a")
    assert_equal(String(u.output_schema.field_name(1)), "b")
    # Children are PLAN_SCAN nodes with the expected paths.
    assert_equal(Int(u.union_data_ref().children[0][].tag), Int(PLAN_SCAN))
    assert_true(u.union_data_ref().children[0][].is_scan(), "branch 0 is a scan")
    assert_true(u.union_data_ref().children[1][].is_scan(), "branch 1 is a scan")


def test_union_copy_deep_and_independent() raises:
    var u = _three_branch_union()
    var u2 = u.copy()
    assert_equal(Int(u2.tag), Int(PLAN_UNION))
    assert_equal(u2.union_data_ref().num_children(), 3)
    # The copy carries the same structure.
    assert_equal(u2.output_schema.num_columns(), 2)
    assert_true(u2.union_data_ref().children[2][].is_scan(), "copy branch 2 is a scan")
    # Both trees still printable + structurally hashable (no UAF / dangling
    # OwnedPointer after the copy).
    var s1 = String(u)
    var s2 = String(u2)
    assert_equal(s1, s2)
    assert_equal(u.structural_hash(), u2.structural_hash())
    # Original still intact after the copy (copy is non-destructive).
    assert_equal(u.union_data_ref().num_children(), 3)


def test_union_write_to_renders_branch_count() raises:
    var u = _two_branch_union()
    var rendered = String(u)
    assert_true(
        "Union(branches=2)" in rendered,
        "write_to should render the branch count; got: " + rendered,
    )
    # Children are indented under the Union line.
    assert_true("Scan(path=\"a.parquet\"" in rendered, "branch 0 rendered")
    assert_true("Scan(path=\"b.parquet\"" in rendered, "branch 1 rendered")


def test_union_structural_hash_distinguishes_branch_count() raises:
    var two = _two_branch_union()
    var three = _three_branch_union()
    assert_true(
        two.structural_hash() != three.structural_hash(),
        "a 2-branch union and a 3-branch union must hash differently",
    )


def test_union_single_branch_degenerate() raises:
    # A 1-branch union is the degenerate single-file case (the union
    # lowering never emits empty unions, but a 1-elem list is legal).
    var children = List[OwnedPointer[LogicalPlan]]()
    children.append(OwnedPointer(_scan("only.parquet")))
    var u = LogicalPlan.union(children^, _schema2())
    assert_equal(u.union_data_ref().num_children(), 1)
    var u2 = u.copy()
    assert_equal(u2.union_data_ref().num_children(), 1)
    assert_equal(u.structural_hash(), u2.structural_hash())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
