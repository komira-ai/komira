# =============================================================================
# CteScope: statement-scoped CTE bindings.
# =============================================================================
#
# What each test proves, and the defect it catches:
#   * an empty scope is empty and binds nothing (a scope that starts with a
#     binding, or `has` that answers True by default);
#   * `add` refuses an empty name and a duplicate (dropping either guard);
#   * `get_copy` returns an independent deep copy and refuses an unbound name
#     (returning the master, or the wrong index);
#   * `names_ref` / `plans_ref` / `name_at` expose the bindings in order;
#   * `merge_from` absorbs every outer binding with deep copies and refuses a
#     collision (shadowing instead of raising).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_plan_ir.logical_plan import LogicalPlan, SOURCE_PARQUET

from komira_sdk.cte_binding import CteScope


def _scan(path: String) -> LogicalPlan:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    return LogicalPlan.scan(path, SOURCE_PARQUET, sb.build())


def _path_of(plan: LogicalPlan) -> String:
    return plan.scan_data_ref().source_path


def _raises_with(mut scope: CteScope, name: String, want: String) raises:
    var raised = False
    try:
        scope.add(name, _scan("x.parquet"))
    except e:
        raised = True
        assert_true(String(e).find(want) != -1, String(e))
    assert_true(raised, "add('" + name + "') raises")


def test_empty_scope() raises:
    var s = CteScope()
    assert_equal(len(s), 0)
    assert_true(s.is_empty())
    assert_false(s.has("a"))


def test_add_has_get_copy() raises:
    var s = CteScope()
    s.add("first", _scan("one.parquet"))
    s.add("second", _scan("two.parquet"))
    assert_equal(len(s), 2)
    assert_false(s.is_empty())
    assert_true(s.has("first"))
    assert_true(s.has("second"))
    assert_false(s.has("third"))
    assert_equal(s.name_at(0), "first")
    assert_equal(s.name_at(1), "second")
    assert_equal(_path_of(s.get_copy("second")), "two.parquet")
    assert_equal(_path_of(s.get_copy("first")), "one.parquet")
    # The copy is independent: changing it leaves the bound plan alone.
    var c = s.get_copy("first")
    c._scan.value()[].source_path = "changed.parquet"
    assert_equal(_path_of(s.get_copy("first")), "one.parquet")
    # The ref accessors see the same bindings, in order.
    assert_equal(len(s.names_ref()), 2)
    assert_equal(s.names_ref()[1], "second")
    assert_equal(len(s.plans_ref()), 2)
    assert_equal(_path_of(s.plans_ref()[1]), "two.parquet")


def test_add_refuses_empty_and_duplicate_names() raises:
    var s = CteScope()
    _raises_with(s, "", "cannot be empty")
    s.add("a", _scan("a.parquet"))
    _raises_with(s, "a", "already bound")
    assert_equal(len(s), 1)


def test_get_copy_refuses_unbound_name() raises:
    var s = CteScope()
    s.add("a", _scan("a.parquet"))
    var raised = False
    try:
        _ = s.get_copy("b")
    except e:
        raised = True
        assert_true(String(e).find("no CTE named 'b'") != -1, String(e))
    assert_true(raised)


def test_merge_from() raises:
    var outer = CteScope()
    outer.add("a", _scan("a.parquet"))
    var inner = CteScope()
    inner.add("b", _scan("b.parquet"))
    inner.add("c", _scan("c.parquet"))
    outer.merge_from(inner)
    assert_equal(len(outer), 3)
    assert_equal(outer.name_at(2), "c")
    assert_equal(_path_of(outer.get_copy("b")), "b.parquet")
    # `inner` keeps its own bindings: the merge copied them.
    assert_equal(len(inner), 2)
    assert_equal(_path_of(inner.get_copy("c")), "c.parquet")
    # An empty merge changes nothing.
    outer.merge_from(CteScope())
    assert_equal(len(outer), 3)


def test_merge_from_refuses_a_collision() raises:
    var outer = CteScope()
    outer.add("a", _scan("a.parquet"))
    var inner = CteScope()
    inner.add("z", _scan("z.parquet"))
    inner.add("a", _scan("other.parquet"))
    var raised = False
    try:
        outer.merge_from(inner)
    except e:
        raised = True
        assert_true(String(e).find("nested CTE name 'a'") != -1, String(e))
    assert_true(raised, "a collision raises")
    # The bindings absorbed before the collision stay; the outer `a` is kept.
    assert_true(outer.has("z"))
    assert_equal(_path_of(outer.get_copy("a")), "a.parquet")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
