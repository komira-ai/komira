# =============================================================================
# optimizer_reorder: RelationSet, the owning-column lookups, the cost
# functions, edge lookup and the smallest-relation pick
# =============================================================================
#
# The welded reorder tests drive `extract_join_chain` and
# `collect_connecting_keys` on the forward direction. This file calls the
# building blocks directly: every RelationSet method, both lookup helpers
# with their empty and missing cases, `estimate_join_cardinality_for_reorder`,
# `_max_ndv_across_keys`, every arm of `estimate_join_cardinality_with_ndv`
# (no stats, one side, clamp, saturation, sub-1 result),
# `find_connecting_edge` in both directions, `collect_connecting_keys` on a
# reversed edge, and the id tie-break of `_take_smallest_relation`.
#
# Each test names the defect it catches.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_collections.slab import Slab
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import LogicalPlan, SOURCE_PARQUET
from komira_plan_stats.table_stats import (
    TableStats,
    ColumnStats,
    STATS_SOURCE_PARQUET_METADATA,
)
from komira_optimizer.optimizer_reorder import (
    RelationSet,
    JoinRelation,
    JoinEdge,
    REORDER_CARDINALITY_MAX,
    _schema_has_all_columns,
    find_relation_owning_columns,
    estimate_join_cardinality_for_reorder,
    _max_ndv_across_keys,
    estimate_join_cardinality_with_ndv,
    find_connecting_edge,
    collect_connecting_keys,
    _take_smallest_relation,
)


# =============================================================================
# Helpers
# =============================================================================


def _schema(c1: String, c2: String) -> Schema:
    var b = SchemaBuilder()
    b.add_field(Field(c1, ArrowType.INT64, False))
    b.add_field(Field(c2, ArrowType.INT64, False))
    return b.build()


def _scan(c1: String, c2: String) -> LogicalPlan:
    return LogicalPlan.scan(c1 + ".parquet", SOURCE_PARQUET, _schema(c1, c2))


def _names(a: String) -> List[String]:
    var l = List[String]()
    l.append(a)
    return l^


def _names2(a: String, b: String) -> List[String]:
    var l = List[String]()
    l.append(a)
    l.append(b)
    return l^


def _stats(var names: List[String], var ndvs: List[Int]) -> TableStats:
    """One ColumnStats per name; a negative entry leaves distinct_count unset."""
    var cols = List[ColumnStats]()
    for i in range(len(ndvs)):
        if ndvs[i] < 0:
            cols.append(ColumnStats())
        else:
            cols.append(ColumnStats(Optional[Int](ndvs[i])))
    return TableStats(1000, names^, cols^, STATS_SOURCE_PARQUET_METADATA)


def _ints(a: Int) -> List[Int]:
    var l = List[Int]()
    l.append(a)
    return l^


def _ints2(a: Int, b: Int) -> List[Int]:
    var l = List[Int]()
    l.append(a)
    l.append(b)
    return l^


def _opt_stats(name: String, ndv: Int) -> Optional[TableStats]:
    return Optional[TableStats](_stats(_names(name), _ints(ndv)))


def _edge(l: Int, r: Int, lk: String, rk: String) -> JoinEdge:
    return JoinEdge(l, r, _names(lk), _names(rk))


# =============================================================================
# RelationSet
# =============================================================================


def test_relation_set_construction_and_membership() raises:
    """Catches: the no-arg constructor or `empty` leaving bits set, a
    singleton setting the wrong bit, and `contains` testing the wrong bit."""
    var e1 = RelationSet()
    var e2 = RelationSet.empty()
    assert_true(e1.is_empty())
    assert_true(e2.is_empty())
    var s = RelationSet.singleton(3)
    assert_false(s.is_empty())
    assert_true(s.contains(3))
    assert_false(s.contains(2))
    assert_equal(s.bits, UInt64(8))


def test_relation_set_union_intersects_count_remove() raises:
    """Catches: union as intersection, `intersects` always true, `count`
    off by one, and `remove` clearing the wrong bit."""
    var a = RelationSet.singleton(0).union(RelationSet.singleton(5))
    var b = RelationSet.singleton(5)
    var c = RelationSet.singleton(1)
    assert_equal(a.count(), 2)
    assert_true(a.intersects(b))
    assert_false(a.intersects(c))
    var r = a.remove(5)
    assert_equal(r.count(), 1)
    assert_true(r.contains(0))
    assert_false(r.contains(5))
    assert_equal(RelationSet.empty().count(), 0)


def test_relation_set_iter_is_sorted_ids() raises:
    """Catches: `iter` skipping bit 0, stopping early, or emitting bit
    positions out of order."""
    var s = RelationSet.singleton(63).union(RelationSet.singleton(0)).union(
        RelationSet.singleton(7)
    )
    var ids = s.iter()
    assert_equal(len(ids), 3)
    assert_equal(ids[0], 0)
    assert_equal(ids[1], 7)
    assert_equal(ids[2], 63)
    assert_equal(len(RelationSet.empty().iter()), 0)


# =============================================================================
# Owning-column lookups
# =============================================================================


def test_schema_has_all_columns() raises:
    """An empty request is False; every name must be present. Catches:
    an empty list answering True (any relation would own it) and a
    partial match answering True."""
    var s = _schema("a", "b")
    assert_false(_schema_has_all_columns(s, List[String]()))
    assert_true(_schema_has_all_columns(s, _names2("b", "a")))
    assert_false(_schema_has_all_columns(s, _names2("a", "z")))


def test_find_relation_owning_columns_offsets_and_misses() raises:
    """The offset is relative to `start`. Catches: an absolute index
    returned, the empty-columns and empty-range guards removed, and a
    miss returning 0."""
    var rels = Slab[JoinRelation]()
    rels.append(JoinRelation(0, _scan("a", "x"), 10))
    rels.append(JoinRelation(1, _scan("b", "y"), 10))
    rels.append(JoinRelation(2, _scan("c", "z"), 10))
    assert_equal(find_relation_owning_columns(rels, 1, 3, _names("c")), 1)
    assert_equal(find_relation_owning_columns(rels, 0, 3, _names2("b", "y")), 1)
    assert_equal(find_relation_owning_columns(rels, 1, 3, _names("a")), -1)
    assert_equal(find_relation_owning_columns(rels, 0, 3, List[String]()), -1)
    assert_equal(find_relation_owning_columns(rels, 2, 2, _names("c")), -1)


# =============================================================================
# Cost functions
# =============================================================================


def test_fallback_join_cardinality_is_max_clamped() raises:
    """Catches: min instead of max, one side ignored, and the clamp
    removed for two empty sides."""
    assert_equal(estimate_join_cardinality_for_reorder(10, 20), 20)
    assert_equal(estimate_join_cardinality_for_reorder(20, 10), 20)
    assert_equal(estimate_join_cardinality_for_reorder(0, 0), 1)


def test_max_ndv_across_keys() raises:
    """Max over keys when every key has a positive NDV; None otherwise.
    Catches: min instead of max, a missing key skipped instead of
    answering None, an NDV of 0 accepted, and an empty key list
    answering Some."""
    var st = _stats(_names2("a", "b"), _ints2(5, 9))
    assert_equal(_max_ndv_across_keys(st, _names2("a", "b")).value(), 9)
    assert_equal(_max_ndv_across_keys(st, _names2("b", "a")).value(), 9)
    assert_equal(_max_ndv_across_keys(st, _names("a")).value(), 5)
    assert_false(Bool(_max_ndv_across_keys(st, _names2("a", "zz"))))
    assert_false(Bool(_max_ndv_across_keys(st, List[String]())))
    var zero = _stats(_names2("a", "b"), _ints2(0, 9))
    assert_false(Bool(_max_ndv_across_keys(zero, _names2("a", "b"))))


def test_ndv_estimate_without_stats_falls_back() raises:
    """No stats on either side, or stats without the key: max(l, r).
    Catches: a divisor of 0 used, or the fallback skipped."""
    var none_l = Optional[TableStats]()
    var none_r = Optional[TableStats]()
    var e1 = estimate_join_cardinality_with_ndv(
        150, 20, none_l, none_r, _names("a"), _names("b")
    )
    assert_equal(e1, 150)
    var e2 = estimate_join_cardinality_with_ndv(
        150, 20, _opt_stats("other", 5), _opt_stats("other", 5),
        _names("a"), _names("b"),
    )
    assert_equal(e2, 150)


def test_ndv_estimate_fk_pk_formula_left_stats() raises:
    """(150000 * 2000) / 25 with stats only on the left. Catches: the
    left NDV ignored (fallback 150000)."""
    var e = estimate_join_cardinality_with_ndv(
        150000, 2000, _opt_stats("a", 25), Optional[TableStats](),
        _names("a"), _names("b"),
    )
    assert_equal(e, 12_000_000)


def test_ndv_estimate_uses_larger_ndv_right_stats() raises:
    """Left NDV 10, right NDV 40: divisor 40. Catches: the right side
    ignored, or min taken over the two sides (divisor 10)."""
    var e = estimate_join_cardinality_with_ndv(
        100, 400, _opt_stats("a", 10), _opt_stats("b", 40),
        _names("a"), _names("b"),
    )
    assert_equal(e, 1000)


def test_ndv_estimate_clamps_ndv_to_side_card() raises:
    """Left NDV 500 over 100 rows is clamped to 100; right NDV 900 over
    300 rows to 300: divisor 300, (100 * 300) / 300 = 100. Catches:
    either clamp removed (divisor 900 gives 33)."""
    var e = estimate_join_cardinality_with_ndv(
        100, 300, _opt_stats("a", 500), _opt_stats("b", 900),
        _names("a"), _names("b"),
    )
    assert_equal(e, 100)


def test_ndv_estimate_saturates_the_product() raises:
    """2^40 * 2^40 overflows Int; the product saturates to 2^62, and
    2^62 / 2^30 = 2^32. Catches: the saturation guard removed (the
    wrapped product is 0, estimate 1)."""
    var big = 1 << 40
    var e = estimate_join_cardinality_with_ndv(
        big, big, _opt_stats("a", 1 << 30), Optional[TableStats](),
        _names("a"), _names("b"),
    )
    assert_equal(e, REORDER_CARDINALITY_MAX // (1 << 30))
    assert_equal(e, 1 << 32)


def test_ndv_estimate_of_empty_sides_is_one() raises:
    """Both cards 0 (the clamp to card is skipped for card 0), NDV 1000:
    1 * 1 // 1000 = 0 is lifted to 1. Catches: the sub-1 clamp removed
    and the `lc < 1` / `rc < 1` lifts removed (0 // 1000 = 0)."""
    var e = estimate_join_cardinality_with_ndv(
        0, 0, _opt_stats("a", 1000), _opt_stats("b", 1000),
        _names("a"), _names("b"),
    )
    assert_equal(e, 1)


# =============================================================================
# Edge lookup and key collection
# =============================================================================


def test_find_connecting_edge_both_directions() raises:
    """Edge 0 is 0-1, edge 1 is 2-1. Catches: only the forward direction
    checked (the reversed query would miss edge 1) and a miss returning 0."""
    var edges = Slab[JoinEdge]()
    edges.append(_edge(0, 1, "a", "b"))
    edges.append(_edge(2, 1, "c", "b"))
    var s0 = RelationSet.singleton(0)
    var s1 = RelationSet.singleton(1)
    var s2 = RelationSet.singleton(2)
    assert_equal(find_connecting_edge(s0, s1, edges), 0)
    assert_equal(find_connecting_edge(s1, s0, edges), 0)
    assert_equal(find_connecting_edge(s1, s2, edges), 1)
    assert_equal(find_connecting_edge(s0, s2, edges), -1)


def test_collect_connecting_keys_flips_reversed_edges() raises:
    """Edge (2 -> 1, c = b) asked as {1} x {2} comes back as b = c, and
    an edge outside the two sets is skipped. Catches: the flip removed
    (keys would pair c with b on the wrong sides) and unrelated edges
    collected."""
    var edges = Slab[JoinEdge]()
    edges.append(_edge(0, 3, "a", "d"))
    edges.append(_edge(2, 1, "c", "b"))
    var keys = collect_connecting_keys(
        RelationSet.singleton(1), RelationSet.singleton(2), edges
    )
    assert_equal(len(keys.left), 1)
    assert_equal(keys.left[0], String("b"))
    assert_equal(keys.right[0], String("c"))


# =============================================================================
# _take_smallest_relation
# =============================================================================


def test_take_smallest_relation_prefers_smaller_card() raises:
    """Catches: the comparison inverted (would take the 30-row one)."""
    var rels = Slab[JoinRelation]()
    rels.append(JoinRelation(0, _scan("a", "x"), 30))
    rels.append(JoinRelation(1, _scan("b", "y"), 10))
    rels.append(JoinRelation(2, _scan("c", "z"), 20))
    var r = _take_smallest_relation(rels)
    assert_equal(r.id, 1)
    assert_equal(len(rels), 2)


def test_take_smallest_relation_breaks_ties_by_id() raises:
    """Equal cards held out of id order (as swap_remove leaves them):
    the lower id wins. Catches: ties broken by position."""
    var rels = Slab[JoinRelation]()
    rels.append(JoinRelation(5, _scan("a", "x"), 10))
    rels.append(JoinRelation(2, _scan("b", "y"), 10))
    rels.append(JoinRelation(7, _scan("c", "z"), 10))
    var r = _take_smallest_relation(rels)
    assert_equal(r.id, 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
