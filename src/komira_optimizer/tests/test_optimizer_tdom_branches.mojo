# =============================================================================
# Branch tests for optimizer_tdom.mojo
# =============================================================================
#
# The welded TDOM tests (equivalence classes, composite NDV) cover the main
# shapes. These tests reach the remaining arms:
#   * `EquivalenceClass.tdom()`: the >= 1 floor on both NDV slots and the
#     no-signal floor; a provider that bypasses the ColumnStatsValue clamp.
#   * `build_tdom_graph`: an edge processed after a merge (the drained slot is
#     skipped, and compaction remaps a later class index); the HLL MAX when
#     the larger value comes first; a composite edge with one key on the
#     left and two on the right.
#   * `_compact_classes`: an edge index that names a dropped class or no
#     class at all is left as is.
#   * `build_pair_buckets`: the right-only composite skip.
#   * `composite_ndv_for_relation`: every defensive return, the per-column
#     dedup, the saturation and overflow guards (including a zero NDV after
#     saturation), a zero NDV (the result floors at 1) and a 0-row relation.
#   * `composite_ndv_pk_side`: only the second endpoint qualifies; an
#     endpoint outside chain.relations answers -1.
#   * The hand-written `copy()` of ColumnBinding, EquivalenceClass and
#     PairBucket.
# Each test names the defect it catches.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import LogicalPlan, SOURCE_PARQUET
from komira_plan_stats.table_stats import TableStats
from komira_optimizer.optimizer_reorder import JoinRelation, JoinEdge, JoinChain
from komira_optimizer.optimizer_column_stats_provider import (
    ColumnStatsProvider,
    ColumnStatsValue,
    DefaultColumnStatsProvider,
    SyntheticColumnStatsProvider,
    TIER_PARQUET_METADATA,
)
from komira_optimizer.optimizer_tdom import (
    ColumnBinding,
    EquivalenceClass,
    PairBucket,
    build_tdom_graph,
    build_pair_buckets,
    composite_ndv_for_relation,
    composite_ndv_pk_side,
    _compact_classes,
)


comptime SAT_CAP: Int = 4_611_686_018_427_387_903


struct _ZeroNdvProvider(ColumnStatsProvider, Movable, Deinitable):
    """A provider that returns ndv 0 with from_hll=True, bypassing the
    ColumnStatsValue >= 1 clamp by writing the field after construction."""

    def __init__(out self):
        pass

    def distinct_count_for(
        self, relation_id: Int, column_name: String
    ) -> ColumnStatsValue:
        var v = ColumnStatsValue(1, True, TIER_PARQUET_METADATA)
        v.ndv = 0
        return v


def _rel(id: Int, cardinality: Int) -> JoinRelation:
    var b = SchemaBuilder()
    b.add_field(Field("k", ArrowType.INT64, False))
    var rc: Optional[Int] = cardinality
    var none_proj: Optional[List[String]] = None
    var none_filt: Optional[Expr] = None
    var plan = LogicalPlan.scan(
        "r.parquet", SOURCE_PARQUET, b.build(), none_proj^, none_filt^, rc^
    )
    var ns: Optional[TableStats] = None
    return JoinRelation(id, plan^, cardinality, ns^)


def _edge(lr: Int, rr: Int, lk: String, rk: String) -> JoinEdge:
    var lks = List[String]()
    lks.append(lk)
    var rks = List[String]()
    rks.append(rk)
    return JoinEdge(lr, rr, lks^, rks^)


def _none() -> Optional[Int]:
    var n: Optional[Int] = None
    return n^


def _class(
    var hll: Optional[Int], var no_hll: Optional[Int]
) -> EquivalenceClass:
    var b = List[ColumnBinding]()
    b.append(ColumnBinding(0, "k"))
    return EquivalenceClass(b^, hll^, no_hll^, List[Int]())


def _two_rel_chain(card0: Int, card1: Int) -> JoinChain:
    var chain = JoinChain()
    chain.relations.append(_rel(0, card0))
    chain.relations.append(_rel(1, card1))
    return chain^


# ---- EquivalenceClass.tdom ----


def test_tdom_floors_and_preference() raises:
    """HLL wins over no-HLL; each slot floors at 1; no signal answers 1.
    Catches: a floor removed (a 0 or negative TDOM is a cost-model
    denominator), or the preference order swapped."""
    assert_equal(_class(Optional[Int](3), Optional[Int](9)).tdom(), 3)
    assert_equal(_class(Optional[Int](0), Optional[Int](9)).tdom(), 1)
    assert_equal(_class(Optional[Int](-4), _none()).tdom(), 1)
    assert_equal(_class(_none(), Optional[Int](0)).tdom(), 1)
    assert_equal(_class(_none(), Optional[Int](6)).tdom(), 6)
    assert_equal(_class(_none(), _none()).tdom(), 1)


def test_zero_ndv_provider_tdom_floors_to_one() raises:
    """A provider that answers ndv 0 leaves hll_ndv at 0 and tdom() at 1.
    Catches: the HLL floor in tdom() removed on the path build_tdom_graph
    actually takes."""
    var chain = _two_rel_chain(10, 10)
    chain.edges.append(_edge(0, 1, "a", "b"))
    var tdom = build_tdom_graph(chain, _ZeroNdvProvider())
    assert_equal(tdom.num_classes(), 1)
    assert_equal(tdom.classes[0].hll_ndv.value(), 0)
    assert_equal(tdom.classes[0].tdom(), 1)


# ---- build_tdom_graph ----


def test_edge_after_merge_skips_drained_slot_and_remaps() raises:
    """e0 (0.a=1.b) -> C0; e1 (2.c=3.d) -> C1; e2 (4.e=5.f) -> C2;
    e3 (1.b=2.c) merges C1 into C0 and leaves slot 1 empty; e4 (5.f=6.g)
    then scans past the empty slot and extends C2. Compaction moves C2 to
    index 1, so e2 and e4 must map to class 1.
    Catches: compaction not remapping edge_to_class (e2/e4 would still say
    2, past the end of `classes`); the merge not remapping e1 to the kept
    class; contributing_edges losing the drained class's edges."""
    var chain = JoinChain()
    var cards: List[Int] = [500, 400, 300, 200, 40, 30, 70]
    for i in range(len(cards)):
        chain.relations.append(_rel(i, cards[i]))
    chain.edges.append(_edge(0, 1, "a", "b"))
    chain.edges.append(_edge(2, 3, "c", "d"))
    chain.edges.append(_edge(4, 5, "e", "f"))
    chain.edges.append(_edge(1, 2, "b", "c"))
    chain.edges.append(_edge(5, 6, "f", "g"))

    var provider = DefaultColumnStatsProvider(chain.relations)
    var tdom = build_tdom_graph(chain, provider)

    assert_equal(tdom.num_classes(), 2)
    assert_equal(tdom.class_for_edge(0), 0)
    assert_equal(tdom.class_for_edge(1), 0)
    assert_equal(tdom.class_for_edge(2), 1)
    assert_equal(tdom.class_for_edge(3), 0)
    assert_equal(tdom.class_for_edge(4), 1)
    ref c0 = tdom.classes[0]
    assert_equal(len(c0.bindings), 4)
    assert_equal(len(c0.contributing_edges), 3)
    assert_equal(c0.contributing_edges[0], 0)
    assert_equal(c0.contributing_edges[1], 1)
    assert_equal(c0.contributing_edges[2], 3)
    assert_equal(c0.tdom(), 200)  # MIN(500, 400, 300, 200)
    ref c1 = tdom.classes[1]
    assert_equal(len(c1.bindings), 3)
    assert_equal(len(c1.contributing_edges), 2)
    assert_equal(c1.tdom(), 30)  # MIN(40, 30, 70)


def test_hll_merge_keeps_larger_when_it_comes_first() raises:
    """The first binding ingested has HLL NDV 900, the second 40; the class
    keeps 900. Catches: the HLL merge taking the latest value or the MIN
    (the welded test feeds the larger value last, so it cannot tell)."""
    var chain = _two_rel_chain(1000, 1000)
    chain.edges.append(_edge(0, 1, "x", "y"))
    var p = SyntheticColumnStatsProvider()
    p.inject(0, "x", 900, True, TIER_PARQUET_METADATA)
    p.inject(1, "y", 40, True, TIER_PARQUET_METADATA)
    var tdom = build_tdom_graph(chain, p)
    assert_equal(tdom.classes[0].hll_ndv.value(), 900)
    assert_false(Bool(tdom.classes[0].no_hll_ndv))


def test_right_only_composite_edge_has_no_class_and_no_bucket() raises:
    """An edge with one left key and two right keys is a leftover composite:
    no class, no bucket. Catches: the `len(right_keys) > 1` arm dropped
    from either builder (it would read right_keys[0] and form a class)."""
    var chain = _two_rel_chain(10, 10)
    var lks = List[String]()
    lks.append("a")
    var rks = List[String]()
    rks.append("b")
    rks.append("c")
    chain.edges.append(JoinEdge(0, 1, lks^, rks^))
    var provider = DefaultColumnStatsProvider(chain.relations)
    var tdom = build_tdom_graph(chain, provider)
    assert_equal(tdom.num_classes(), 0)
    assert_equal(tdom.class_for_edge(0), -1)
    assert_equal(len(build_pair_buckets(chain)), 0)


def test_compact_leaves_dangling_indices_unchanged() raises:
    """Classes [live, empty]; edge_to_class [1, 0, 5, -1]. The live class
    stays at 0; the index naming the dropped class (1) and the index past
    the end (5) are left as they are; -1 stays -1.
    Catches: the defensive guard removed (remap[5] reads past the table, or
    remap[1] writes -1 over an index)."""
    var classes = List[EquivalenceClass]()
    classes.append(_class(Optional[Int](2), _none()))
    classes.append(
        EquivalenceClass(List[ColumnBinding](), _none(), _none(), List[Int]())
    )
    var e2c: List[Int] = [1, 0, 5, -1]
    var out = _compact_classes(classes^, e2c)
    assert_equal(len(out), 1)
    assert_equal(e2c[0], 1)
    assert_equal(e2c[1], 0)
    assert_equal(e2c[2], 5)
    assert_equal(e2c[3], -1)


# ---- composite_ndv_for_relation / composite_ndv_pk_side ----


def test_composite_ndv_defensive_returns() raises:
    """Each defensive return answers 1 or skips: an endpoint outside the
    chain (5, and -1), an empty bucket, edge indices outside chain.edges,
    and a bucket edge that does not touch the relation.
    Catches: a missing range check (reads relations[5] or edges[9]); the
    non-touching edge multiplying in the NDV injected for column ""."""
    var chain = _two_rel_chain(1000, 1000)
    chain.relations.append(_rel(2, 1000))
    chain.relations.append(_rel(3, 1000))
    chain.edges.append(_edge(0, 1, "x", "y"))  # e0
    chain.edges.append(_edge(2, 3, "a", "b"))  # e1: touches neither 0 nor 1
    var p = SyntheticColumnStatsProvider()
    p.inject(0, "x", 10, True, TIER_PARQUET_METADATA)
    p.inject(0, "", 7, True, TIER_PARQUET_METADATA)

    var e0: List[Int] = [0]
    var e0b: List[Int] = [0]
    var bad: List[Int] = [9, -1, 0]
    var mixed: List[Int] = [0, 1]
    var past_end = PairBucket(0, 5, e0^)
    var negative = PairBucket(-1, 0, e0b^)
    var empty = PairBucket(0, 1, List[Int]())
    var bad_idx = PairBucket(0, 1, bad^)
    var not_touching = PairBucket(0, 1, mixed^)
    assert_equal(composite_ndv_for_relation(chain, past_end, 5, p), 1)
    assert_equal(composite_ndv_for_relation(chain, negative, -1, p), 1)
    assert_equal(composite_ndv_for_relation(chain, empty, 0, p), 1)
    assert_equal(composite_ndv_for_relation(chain, bad_idx, 0, p), 10)
    assert_equal(composite_ndv_for_relation(chain, not_touching, 0, p), 10)


def test_composite_ndv_dedups_repeated_column() raises:
    """Two bucket edges reuse rel 0's column x (x=p, x=q): x's NDV (10)
    counts once, while rel 1's distinct columns multiply (10*10=100).
    Catches: the dedup removed (rel 0 would answer 100)."""
    var chain = _two_rel_chain(1000, 1000)
    chain.edges.append(_edge(0, 1, "x", "p"))
    chain.edges.append(_edge(0, 1, "x", "q"))
    var p = SyntheticColumnStatsProvider()
    p.inject(0, "x", 10, True, TIER_PARQUET_METADATA)
    p.inject(1, "p", 10, True, TIER_PARQUET_METADATA)
    p.inject(1, "q", 10, True, TIER_PARQUET_METADATA)
    var buckets = build_pair_buckets(chain)
    assert_equal(composite_ndv_for_relation(chain, buckets[0], 0, p), 10)
    assert_equal(composite_ndv_for_relation(chain, buckets[0], 1, p), 100)


def test_composite_ndv_overflow_guard_saturates() raises:
    """NDVs 4e9 * 4e9 overflow Int64; the guard saturates and the result
    clamps to |rel| = 1000. Catches: the overflow guard removed (the product
    wraps negative and is returned as the composite NDV)."""
    var chain = _two_rel_chain(1000, 1000)
    chain.edges.append(_edge(0, 1, "a", "p"))
    chain.edges.append(_edge(0, 1, "b", "q"))
    var p = SyntheticColumnStatsProvider()
    p.inject(0, "a", 4_000_000_000, True, TIER_PARQUET_METADATA)
    p.inject(0, "b", 4_000_000_000, True, TIER_PARQUET_METADATA)
    var buckets = build_pair_buckets(chain)
    assert_equal(composite_ndv_for_relation(chain, buckets[0], 0, p), 1000)


def test_composite_ndv_saturation_cap_sticks() raises:
    """An NDV at the cap saturates the product; a later column keeps it
    saturated; |rel| = SAT_CAP + 1 shows the saturated value itself.
    Catches: the saturated arm writing anything but SAT_CAP (for example the
    incoming NDV: the answer would be 3). With positive NDVs the overflow
    guard below the cap check gives the same answer, so dropping the
    `ndv_product >= SAT_CAP` term is caught by
    test_composite_ndv_saturated_product_ignores_zero_ndv, not here."""
    var chain = _two_rel_chain(SAT_CAP + 1, 10)
    chain.edges.append(_edge(0, 1, "a", "p"))
    chain.edges.append(_edge(0, 1, "b", "q"))
    var p = SyntheticColumnStatsProvider()
    p.inject(0, "a", SAT_CAP, True, TIER_PARQUET_METADATA)
    p.inject(0, "b", 3, True, TIER_PARQUET_METADATA)
    var buckets = build_pair_buckets(chain)
    assert_equal(composite_ndv_for_relation(chain, buckets[0], 0, p), SAT_CAP)


struct _SatThenZeroProvider(ColumnStatsProvider, Movable, Deinitable):
    """Column "a" answers SAT_CAP; every other column answers ndv 0 (written
    after construction, bypassing the ColumnStatsValue >= 1 clamp)."""

    def __init__(out self):
        pass

    def distinct_count_for(
        self, relation_id: Int, column_name: String
    ) -> ColumnStatsValue:
        if column_name == "a":
            return ColumnStatsValue(SAT_CAP, True, TIER_PARQUET_METADATA)
        var v = ColumnStatsValue(1, True, TIER_PARQUET_METADATA)
        v.ndv = 0
        return v


def test_composite_ndv_saturated_product_ignores_zero_ndv() raises:
    """Column a saturates the product at SAT_CAP; column b then answers
    ndv 0. A saturated product stays SAT_CAP, so the result clamps to
    |rel| = 1000.
    Catches: the `ndv_product >= SAT_CAP` term dropped from the cap check
    (the product would be multiplied by 0 and the answer would floor to 1);
    the whole cap check dropped gives the same 1."""
    var chain = _two_rel_chain(1000, 10)
    chain.edges.append(_edge(0, 1, "a", "p"))
    chain.edges.append(_edge(0, 1, "b", "q"))
    var buckets = build_pair_buckets(chain)
    assert_equal(
        composite_ndv_for_relation(
            chain, buckets[0], 0, _SatThenZeroProvider()
        ),
        1000,
    )


def test_composite_ndv_zero_ndv_and_empty_relation() raises:
    """A provider answering ndv 0 makes the product 0 without a division by
    zero, and the result floors at 1; a 0-row relation clamps |rel| to 1.
    Catches: the `v.ndv > 0` guard removed (SAT_CAP // 0); the result floor
    removed (the zero-NDV case would answer 0); the `rel_card < 1` floor
    removed (the 0-row relation would answer 0)."""
    var chain = _two_rel_chain(1000, 0)
    chain.edges.append(_edge(0, 1, "a", "b"))
    var buckets = build_pair_buckets(chain)
    assert_equal(
        composite_ndv_for_relation(chain, buckets[0], 0, _ZeroNdvProvider()), 1
    )
    var p = SyntheticColumnStatsProvider()
    p.inject(1, "b", 50, True, TIER_PARQUET_METADATA)
    assert_equal(composite_ndv_for_relation(chain, buckets[0], 1, p), 1)


def test_pk_side_second_endpoint_only() raises:
    """rel 0: NDV 10 of 1000 rows (not PK); rel 1: NDV 100 of 100 rows (PK).
    The answer is rel 1. Catches: the rel_b arm dropped or answering rel_a
    (the welded tests only ever see rel_a, both, or neither)."""
    var chain = _two_rel_chain(1000, 100)
    chain.edges.append(_edge(0, 1, "x", "y"))
    var p = SyntheticColumnStatsProvider()
    p.inject(0, "x", 10, True, TIER_PARQUET_METADATA)
    p.inject(1, "y", 100, True, TIER_PARQUET_METADATA)
    var buckets = build_pair_buckets(chain)
    assert_equal(composite_ndv_pk_side(chain, buckets[0], p), 1)


def test_pk_side_out_of_range_endpoint_answers_minus_one() raises:
    """A bucket endpoint outside chain.relations is not a PK side: the
    answer is -1, without reading chain.relations at that index.
    Bucket (0, 5): rel 0 is not PK (NDV 10 of 1000), rel 5 does not exist.
    Bucket (-1, 0): rel 0 is PK (NDV 1000 of 1000), rel -1 does not exist.
    Catches: the endpoint range check missing. The read of relations[5] is
    unchecked and its answer depends on memory past the list, so the first
    case can pass without the check; the second case answered 0 (rel 0) instead
    of -1 without it."""
    var chain = _two_rel_chain(1000, 1)
    chain.edges.append(_edge(0, 1, "x", "y"))
    var p = SyntheticColumnStatsProvider()
    p.inject(0, "x", 10, True, TIER_PARQUET_METADATA)
    var e0: List[Int] = [0]
    assert_equal(composite_ndv_pk_side(chain, PairBucket(0, 5, e0^), p), -1)

    var q = SyntheticColumnStatsProvider()
    q.inject(0, "x", 1000, True, TIER_PARQUET_METADATA)
    var e0b: List[Int] = [0]
    assert_equal(composite_ndv_pk_side(chain, PairBucket(-1, 0, e0b^), q), -1)


# ---- copies ----


def test_copies_are_deep_and_complete() raises:
    """The hand-written copies carry every field and share no list.
    Catches: a field dropped from a copy, or a copy aliasing its source's
    list (an append to the source would show in the copy)."""
    var b = ColumnBinding(3, "k")
    var bc = b.copy()
    assert_true(bc.eq(b))
    assert_false(bc.eq(ColumnBinding(3, "j")))
    assert_false(bc.eq(ColumnBinding(4, "k")))

    var seven: List[Int] = [7]
    var pb = PairBucket(1, 2, seven^)
    var pbc = pb.copy()
    pb.edge_indices.append(8)
    assert_equal(pbc.rel_a, 1)
    assert_equal(pbc.rel_b, 2)
    assert_equal(pbc.size(), 1)
    assert_equal(pbc.edge_indices[0], 7)

    var ec_b = List[ColumnBinding]()
    ec_b.append(ColumnBinding(0, "k"))
    var ec_e: List[Int] = [2]
    var ec = EquivalenceClass(ec_b^, Optional[Int](4), Optional[Int](5), ec_e^)
    var ecc = ec.copy()
    ec.bindings.append(ColumnBinding(1, "j"))
    ec.contributing_edges.append(3)
    assert_equal(len(ecc.bindings), 1)
    assert_equal(len(ecc.contributing_edges), 1)
    assert_equal(ecc.hll_ndv.value(), 4)
    assert_equal(ecc.no_hll_ndv.value(), 5)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
