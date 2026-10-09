# =============================================================================
# The NULL-supplying side of an outer join is nullable in the output schema.
# =============================================================================
#
# A LEFT join emits every left row; a left row with no match carries NULL in
# every right-side column. RIGHT is the mirror image and FULL does both. The
# `join` factory and `infer_schema` copied each side's fields verbatim, so a
# non-nullable right column stayed `nullable=False` after a LEFT join while the
# executor emits NULLs in it. A consumer that trusts the flag (a rule that only
# fires on non-nullable columns, a kernel that skips the validity bitmap, a
# typed reader) reads garbage under the NULL slots. `asof_join` already forced
# its right side nullable for the same reason.
#
# Each test checks BOTH the factory's stored `output_schema` and the
# re-derived `infer_schema`, since the two are separate code paths. INNER,
# SEMI, ANTI and CROSS are the controls: they supply no NULLs and keep the
# flags as they are.
# =============================================================================

from std.testing import TestSuite, assert_true, assert_false, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    SOURCE_PARQUET,
    JOIN_INNER,
    JOIN_LEFT,
    JOIN_RIGHT,
    JOIN_FULL,
    JOIN_SEMI,
    JOIN_ANTI,
    JOIN_CROSS,
)
from komira_plan_ir.schema_propagation import infer_schema


def _side(path: String, a: String, b: String) -> LogicalPlan:
    var sb = SchemaBuilder()
    sb.add_field(Field(a, ArrowType.INT64, False))
    sb.add_field(Field(b, ArrowType.STRING, False))
    return LogicalPlan.scan(path, SOURCE_PARQUET, sb.build())


def _join(jt: UInt8) -> LogicalPlan:
    var lon: List[String] = ["lk"]
    var ron: List[String] = ["rk"]
    if jt == JOIN_CROSS:
        lon = List[String]()
        ron = List[String]()
    # Left columns are named `l*`, right columns `r*`: `_check` reads the
    # side off the first letter.
    return LogicalPlan.join(
        _side("l.parquet", "lk", "lv"), _side("r.parquet", "rk", "rv"), lon^, ron^, jt
    )


def _check(plan: LogicalPlan, left_nullable: Bool, right_nullable: Bool, what: String) raises:
    var inferred = infer_schema(plan)
    for which in range(2):
        var n: Int
        if which == 0:
            n = plan.output_schema.num_columns()
        else:
            n = inferred.num_columns()
        for i in range(n):
            var name: String
            var nullable: Bool
            if which == 0:
                name = plan.output_schema.field_name(i)
                nullable = plan.output_schema.field_at_unchecked(i).nullable
            else:
                name = inferred.field_name(i)
                nullable = inferred.field_at_unchecked(i).nullable
            var src = "factory" if which == 0 else "infer_schema"
            var want = left_nullable if name.startswith("l") else right_nullable
            assert_equal(
                nullable,
                want,
                what + " (" + src + "): column " + name + " nullable",
            )


def test_left_join_right_columns_are_nullable() raises:
    _check(_join(JOIN_LEFT), False, True, "LEFT")


def test_right_join_left_columns_are_nullable() raises:
    _check(_join(JOIN_RIGHT), True, False, "RIGHT")


def test_full_join_both_sides_are_nullable() raises:
    _check(_join(JOIN_FULL), True, True, "FULL")


def test_inner_and_cross_keep_the_flags() raises:
    _check(_join(JOIN_INNER), False, False, "INNER")
    _check(_join(JOIN_CROSS), False, False, "CROSS")


def test_semi_and_anti_keep_the_left_flags() raises:
    var semi = _join(JOIN_SEMI)
    var anti = _join(JOIN_ANTI)
    assert_equal(semi.output_schema.num_columns(), 2)
    assert_equal(anti.output_schema.num_columns(), 2)
    _check(semi, False, False, "SEMI")
    _check(anti, False, False, "ANTI")


def test_a_renamed_collision_column_is_nullable_too() raises:
    # A right column that collides with a left name is renamed `<name>_right`;
    # the rename must not lose the nullability.
    var lon: List[String] = ["k"]
    var ron: List[String] = ["k"]
    var plan = LogicalPlan.join(
        _side("l.parquet", "k", "v"), _side("r.parquet", "k", "w"), lon^, ron^, JOIN_LEFT
    )
    assert_equal(plan.output_schema.field_name(2), String("k_right"))
    assert_true(plan.output_schema.field_at_unchecked(2).nullable, "k_right")
    assert_true(plan.output_schema.field_at_unchecked(3).nullable, "w")
    assert_false(plan.output_schema.field_at_unchecked(0).nullable, "left k")
    var inferred = infer_schema(plan)
    assert_true(inferred.field_at_unchecked(2).nullable, "k_right (infer_schema)")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
