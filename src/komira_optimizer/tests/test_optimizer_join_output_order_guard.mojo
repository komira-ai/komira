# =============================================================================
# The join-reorder output-order guard: `join_reorder_output_names`,
# `restore_join_reorder_output_columns`,
# `narrow_reordered_join_to_declared_columns` and
# `join_operands_share_column_name`.
# =============================================================================
#
# A join reorder exchanges operands, which permutes an INNER join's output
# (`left ++ right`), and a flattened projection can widen it. The guard puts
# back a pure permutation and narrows a pure widening, and declines everything
# else: fabricating a projection over names that no longer mean what they did
# would turn an ordering defect into a wrong answer. Each test names the
# defect it catches.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_PROJECT,
    PLAN_JOIN,
    PLAN_SCAN,
    SOURCE_PARQUET,
    JOIN_INNER,
)
from komira_optimizer.optimizer_join import (
    join_reorder_output_names,
    restore_join_reorder_output_columns,
    narrow_reordered_join_to_declared_columns,
    join_operands_share_column_name,
)


def _scan(path: String, names: List[String]) -> LogicalPlan:
    var sb = SchemaBuilder()
    for i in range(len(names)):
        sb.add_field(Field(names[i], ArrowType.INT64, True))
    return LogicalPlan.scan(path, SOURCE_PARQUET, sb.build())


def _join(ln: List[String], rn: List[String]) -> LogicalPlan:
    var lo: List[String] = [ln[0]]
    var ro: List[String] = [rn[0]]
    return LogicalPlan.join(_scan("l", ln), _scan("r", rn), lo^, ro^, JOIN_INNER)


def _names(p: LogicalPlan) -> List[String]:
    var out = List[String]()
    for i in range(p.output_schema.num_columns()):
        out.append(p.output_schema.field_name(i))
    return out^


def _abcd() -> LogicalPlan:
    """INNER([a, b], [c, d]): output [a, b, c, d]."""
    var ln: List[String] = ["a", "b"]
    var rn: List[String] = ["c", "d"]
    return _join(ln, rn)


def test_output_names_are_the_schema_names_in_order() raises:
    """Catches a capture that loses or reorders a name."""
    var got = join_reorder_output_names(_abcd())
    assert_equal(len(got), 4)
    assert_equal(got[0], "a")
    assert_equal(got[1], "b")
    assert_equal(got[2], "c")
    assert_equal(got[3], "d")


def test_restore_returns_the_plan_untouched_when_the_order_is_unchanged() raises:
    """No swap (or two that cancelled): no node is added. Catches a guard that
    always wraps the plan in a Project."""
    var want: List[String] = ["a", "b", "c", "d"]
    var out = restore_join_reorder_output_columns(_abcd(), want^)
    assert_equal(Int(out.tag), Int(PLAN_JOIN))


def test_restore_puts_back_a_permutation() raises:
    """The reordered plan emits [a, b, c, d] but the query declared
    [c, d, a, b]: a Project of col-refs in the declared order is added. Catches
    the restore never firing (the user sees the reorder's column order)."""
    var want: List[String] = ["c", "d", "a", "b"]
    var out = restore_join_reorder_output_columns(_abcd(), want^)
    assert_equal(Int(out.tag), Int(PLAN_PROJECT))
    var got = _names(out)
    assert_equal(got[0], "c")
    assert_equal(got[1], "d")
    assert_equal(got[2], "a")
    assert_equal(got[3], "b")
    assert_equal(Int(out._project.value()[].child[].tag), Int(PLAN_JOIN))


def test_restore_declines_an_arity_change() raises:
    """Three declared names against four output columns: not a permutation,
    not this function's to repair. Catches the arity check dropped."""
    var want: List[String] = ["c", "a", "b"]
    var out = restore_join_reorder_output_columns(_abcd(), want^)
    assert_equal(Int(out.tag), Int(PLAN_JOIN))


def test_restore_declines_a_missing_or_duplicated_name() raises:
    """`e` names no column; `a` twice would make a by-name Project ambiguous.
    Catches the exactly-one-hit check weakened to at-least-one."""
    var missing: List[String] = ["e", "b", "c", "d"]
    var out = restore_join_reorder_output_columns(_abcd(), missing^)
    assert_equal(Int(out.tag), Int(PLAN_JOIN))
    var ln: List[String] = ["a", "x"]
    var rn: List[String] = ["a", "y"]
    var collide = _join(ln, rn)
    # Output [a, x, a_right, y]; force a duplicate name into the cached schema.
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    sb.add_field(Field("x", ArrowType.INT64, True))
    sb.add_field(Field("a", ArrowType.INT64, True))
    sb.add_field(Field("y", ArrowType.INT64, True))
    collide.output_schema = sb.build()
    var dup: List[String] = ["x", "a", "a", "y"]
    var out2 = restore_join_reorder_output_columns(collide^, dup^)
    assert_equal(Int(out2.tag), Int(PLAN_JOIN))


def test_narrow_leaves_an_equal_or_narrower_plan_untouched() raises:
    """Strictly widening only: an equal-arity plan (even permuted) is the
    restore's job. Catches `<=` weakened to `<`."""
    var same: List[String] = ["d", "c", "b", "a"]
    var out = narrow_reordered_join_to_declared_columns(_abcd(), same^)
    assert_equal(Int(out.tag), Int(PLAN_JOIN))
    var wider: List[String] = ["a", "b", "c", "d", "e"]
    var out2 = narrow_reordered_join_to_declared_columns(_abcd(), wider^)
    assert_equal(Int(out2.tag), Int(PLAN_JOIN))


def test_narrow_projects_a_widened_join_to_the_declared_columns() raises:
    """The reorder emits [a, b, c, d] where the node declared [b, d]: a Project
    of exactly those, in that order. Catches the widening repair dropped (the
    flattened columns reach the result)."""
    var declared: List[String] = ["b", "d"]
    var out = narrow_reordered_join_to_declared_columns(_abcd(), declared^)
    assert_equal(Int(out.tag), Int(PLAN_PROJECT))
    var got = _names(out)
    assert_equal(len(got), 2)
    assert_equal(got[0], "b")
    assert_equal(got[1], "d")


def test_narrow_declines_a_missing_or_ambiguous_declared_name() raises:
    """A declared name that resolves to no column, or to two, is declined
    rather than reinterpreted. Catches the exactly-one-hit check dropped."""
    var missing: List[String] = ["b", "z"]
    var out = narrow_reordered_join_to_declared_columns(_abcd(), missing^)
    assert_equal(Int(out.tag), Int(PLAN_JOIN))
    var j = _abcd()
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    sb.add_field(Field("b", ArrowType.INT64, True))
    sb.add_field(Field("b", ArrowType.INT64, True))
    sb.add_field(Field("d", ArrowType.INT64, True))
    j.output_schema = sb.build()
    var amb: List[String] = ["b", "d"]
    var out2 = narrow_reordered_join_to_declared_columns(j^, amb^)
    assert_equal(Int(out2.tag), Int(PLAN_JOIN))


def test_share_column_name() raises:
    """Operands sharing `a` share a name; disjoint operands do not; a non-join
    is never a sharing join. Catches the set lookup inverted and the tag check
    dropped."""
    var ln: List[String] = ["a", "x"]
    var rn: List[String] = ["a", "y"]
    assert_true(join_operands_share_column_name(_join(ln, rn)))
    assert_false(join_operands_share_column_name(_abcd()))
    var n: List[String] = ["a"]
    assert_false(join_operands_share_column_name(_scan("s", n)))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
