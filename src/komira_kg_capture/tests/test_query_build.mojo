# =============================================================================
# test_query_build.mojo -- the subgraph a query matches in a working set.
# =============================================================================
#
# `build_query_result` over a working set built by hand, with a stub embedder
# whose vectors the test names. No store, no server.
#
#   seeds       semantic seeds rank by score, equal scores by node id; surface
#               seeds follow; the text match ignores ASCII case.
#   scope       a query reads the partitions it names and no others, neighbours
#               included; a federated node carries its partition as provenance.
#   merge       a federated result does not depend on the order of the
#               partitions; the per-partition cap bounds each partition's seeds.
#   facet       an entity passes only if its facet equals the filter exactly.
#   as_of       an edge not live then is not returned and brings in no neighbour.
#   cap         `k` cuts the nodes, not the semantic scores.
#   embedder    a failing, short or non-finite embedding leaves the text match.
# =============================================================================

from std.math import nan
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_kg import (
    Embedder,
    SnapshotWorkingSet,
    StubEmbedder,
    WorkingEdge,
    WorkingEntity,
    facet_attrs_json,
)
from komira_kg_capture import QueryConfig, QuerySpec, build_query_result
from komira_kg_format import KgQueryResult, TS_OPEN_SENTINEL

comptime DIM = 4


def _vec(a: Float64, b: Float64, c: Float64, d: Float64) -> List[Float64]:
    var v = List[Float64]()
    v.append(a)
    v.append(b)
    v.append(c)
    v.append(d)
    return v^


def _entity(
    nid: Int64, name: String, partition: String, facet: String, var vec: List[Float64]
) -> WorkingEntity:
    return WorkingEntity(
        nid,
        "u" + String(nid),
        partition.copy(),
        name.copy(),
        vec^,
        String(""),
        facet_attrs_json(facet, String("")),
    )


def _edge(
    src: Int64, dst: Int64, predicate: String, fact: String, valid_at: Int64, invalid_at: Int64
) -> WorkingEdge:
    return WorkingEdge(
        src,
        dst,
        predicate.copy(),
        fact.copy(),
        valid_at,
        invalid_at,
        TS_OPEN_SENTINEL,
        Int64(1),
        Int64(1),
        String(""),
    )


def _ws() raises -> SnapshotWorkingSet:
    """Entities (nid, partition, facet, vector):
    1 Ada Lovelace  p1 fa (1,0,0,0)     5 Casey  p3 none (0,0,0,1)
    2 Acme Labs     p1 fa (0,1,0,0)     6 Dana   p1 fa (0.8,0.6,0,0)
    3 Bolt Co       p2 fb (0,0,1,0)     7 Twin   p1 fa (1,0,0,0)
    4 Ada Byron     p2 fb (0.9,0.1,0,0) 8 NoVec  p1 fa (none)
    """
    var ws = SnapshotWorkingSet(DIM)
    ws.add_entity(_entity(1, "Ada Lovelace", "p1", "fa", _vec(1.0, 0.0, 0.0, 0.0)))
    ws.add_entity(_entity(2, "Acme Labs", "p1", "fa", _vec(0.0, 1.0, 0.0, 0.0)))
    ws.add_entity(_entity(3, "Bolt Co", "p2", "fb", _vec(0.0, 0.0, 1.0, 0.0)))
    ws.add_entity(_entity(4, "Ada Byron", "p2", "fb", _vec(0.9, 0.1, 0.0, 0.0)))
    ws.add_entity(_entity(5, "Casey", "p3", "", _vec(0.0, 0.0, 0.0, 1.0)))
    ws.add_entity(_entity(6, "Dana", "p1", "fa", _vec(0.8, 0.6, 0.0, 0.0)))
    ws.add_entity(_entity(7, "Twin", "p1", "fa", _vec(1.0, 0.0, 0.0, 0.0)))
    ws.add_entity(_entity(9, "Loner", "p4", "fl", _vec(0.0, 0.0, 0.0, -1.0)))
    # A row with no vector (a table written past the working set's checks).
    ws.entities.append(_entity(8, "NoVec", "p1", "fa", List[Float64]()))
    ws.add_edge(_edge(1, 2, "works_at", "Ada works at Acme", Int64(100), TS_OPEN_SENTINEL))
    ws.add_edge(_edge(1, 3, "hired", "Ada hired Bolt", Int64(200), Int64(300)))
    ws.add_edge(_edge(4, 3, "knows", "Byron knows Bolt", Int64(0), TS_OPEN_SENTINEL))
    ws.add_edge(_edge(2, 5, "", "Acme sponsors Casey", Int64(50), TS_OPEN_SENTINEL))
    ws.add_edge(_edge(6, 7, "mentors", "", Int64(0), TS_OPEN_SENTINEL))
    ws.add_edge(_edge(1, 99, "ghost", "points at no entity", Int64(0), TS_OPEN_SENTINEL))
    return ws^


def _emb() raises -> StubEmbedder:
    var emb = StubEmbedder(DIM)
    emb.add_vector("alpha", _vec(1.0, 0.0, 0.0, 0.0))
    # Pointing away from every entity: only the text match can seed.
    emb.add_vector("ada", _vec(0.0, 0.0, 0.0, -1.0))
    emb.add_vector("ADA", _vec(0.0, 0.0, 0.0, -1.0))
    emb.add_vector("a", _vec(0.0, 0.0, 0.0, -1.0))
    emb.add_vector("acme", _vec(0.0, 0.0, 0.0, -1.0))
    emb.add_vector("casey", _vec(0.0, 0.0, 0.0, -1.0))
    emb.add_vector("lovelace", _vec(0.0, 0.0, 0.0, -1.0))
    emb.add_vector("Ada", _vec(1.0, 0.0, 0.0, 0.0))
    emb.add_vector("loner", _vec(0.0, 0.0, 0.0, -1.0))
    emb.add_vector("nothing here", _vec(0.0, 0.0, 0.0, -1.0))
    return emb^


def _strings(*items: String) -> List[String]:
    var out = List[String]()
    for i in range(len(items)):
        out.append(items[i].copy())
    return out^


def _spec(
    text: String,
    var partitions: List[String],
    federated: Bool = False,
    k: Int = 100,
    facet: String = "",
    as_of: Optional[Int64] = Optional[Int64](),
) -> QuerySpec:
    return QuerySpec(
        text.copy(), k, partitions^, facet.copy(), as_of, Optional[Bool](), federated
    )


def _ids(r: KgQueryResult) -> List[Int64]:
    var out = List[Int64]()
    for i in range(len(r.nodes)):
        out.append(r.nodes[i].id)
    return out^


def _assert_ids(r: KgQueryResult, var want: List[Int64]) raises:
    var got = _ids(r)
    assert_equal(len(got), len(want), "node count")
    for i in range(len(want)):
        assert_equal(got[i], want[i], "node " + String(i))


def _nodes(*ids: Int) -> List[Int64]:
    var out = List[Int64]()
    for i in range(len(ids)):
        out.append(Int64(ids[i]))
    return out^


def _build(spec: QuerySpec, config: QueryConfig = QueryConfig.default()) raises -> KgQueryResult:
    return build_query_result(_emb(), _ws(), spec, config)


# --- seeds -------------------------------------------------------------------


def test_semantic_seeds_rank_by_score_then_node_id() raises:
    var r = _build(_spec("alpha", _strings("p1")))
    # 1 and 7 tie at 1.0 (lower id first); Dana at 0.8 clears the 0.5 floor;
    # Acme (0) does not. Neighbours follow: Acme through 1's edge; Bolt (p2) and
    # Casey (p3) are outside a single query's scope.
    _assert_ids(r, _nodes(1, 7, 6, 2))
    assert_equal(r.nodes[0].score, 1.0)
    assert_equal(r.nodes[2].score, 1.0)
    assert_equal(r.nodes[3].score, 0.5)
    assert_equal(r.mode, "query")
    assert_equal(r.query_label, "query: alpha")
    assert_equal(r.answer, "")
    assert_equal(len(r.provenance), 0)
    var semantic = List[Int64]()
    for i in range(len(r.scores)):
        if r.scores[i].name == "semantic":
            semantic.append(r.scores[i].target_id)
    assert_equal(len(semantic), 3)
    assert_equal(semantic[0], Int64(1))
    assert_equal(semantic[1], Int64(7))
    assert_equal(semantic[2], Int64(6))
    assert_equal(r.nodes[0].type, "entity")


def test_a_floor_decides_which_cosines_count() raises:
    var strict = QueryConfig("p", 16, 100, 4096, 32, 64, 0.9)
    var r = _build(_spec("alpha", _strings("p1")), strict)
    # Only the two exact matches clear 0.9; Dana (0.8) is not a seed, and is in
    # the result only as Twin's neighbour (the "mentors" edge).
    assert_true(len(r.nodes) >= 2)
    assert_equal(r.nodes[0].id, Int64(1))
    assert_equal(r.nodes[1].id, Int64(7))
    for i in range(len(r.nodes)):
        if r.nodes[i].id == Int64(6):
            assert_equal(r.nodes[i].score, 0.5)
    for i in range(len(r.scores)):
        if r.scores[i].name == "semantic":
            assert_true(r.scores[i].target_id != Int64(6))


def test_the_text_match_ignores_ascii_case_and_follows_semantic_seeds() raises:
    var r = _build(_spec("ADA", _strings("p1")))
    # Ada Lovelace by its text; Acme Labs is its neighbour. Ada Byron is p2.
    _assert_ids(r, _nodes(1, 2))
    assert_equal(r.nodes[0].score, 1.0)
    assert_equal(r.nodes[1].score, 0.5)
    assert_equal(len(r.edges), 1)
    assert_equal(r.edges[0].src, Int64(1))
    assert_equal(r.edges[0].dst, Int64(2))
    assert_equal(r.edges[0].predicate, "Ada works at Acme")
    assert_equal(r.edges[0].valid_at, Int64(100))
    # A text seed has no semantic score, only the node's own.
    for i in range(len(r.scores)):
        assert_true(r.scores[i].name != "semantic")


def test_a_semantic_seed_is_not_listed_twice_by_the_text_match() raises:
    # "Ada" is both a semantic match for node 1 and a part of its name.
    var r = _build(_spec("Ada", _strings("p1")))
    _assert_ids(r, _nodes(1, 7, 6, 2))
    assert_equal(r.nodes[0].score, 1.0)


def test_a_seed_with_no_edge_stands_alone() raises:
    var r = _build(_spec("loner", _strings("p4")))
    _assert_ids(r, _nodes(9))
    assert_equal(len(r.edges), 0)
    # The text match alone finds it too, under a vector that points elsewhere.
    var by_text = _build(_spec("one", _strings("p4")))
    _assert_ids(by_text, _nodes(9))


def test_no_match_and_an_empty_graph_give_an_empty_result() raises:
    var r = _build(_spec("nothing here", _strings("p1")))
    assert_equal(len(r.nodes), 0)
    assert_equal(len(r.edges), 0)
    var empty = SnapshotWorkingSet(DIM)
    var e = build_query_result(_emb(), empty, _spec("alpha", _strings("p1")), QueryConfig.default())
    assert_equal(len(e.nodes), 0)
    assert_equal(e.mode, "query")


# --- scope -------------------------------------------------------------------


def test_a_single_query_reads_its_partition_and_its_neighbours_stay_in_it() raises:
    var r = _build(_spec("ada", _strings("p2")))
    # Ada Byron (p2); its neighbour Bolt Co is p2 too.
    _assert_ids(r, _nodes(4, 3))
    assert_equal(len(r.edges), 1)
    assert_equal(r.edges[0].predicate, "Byron knows Bolt")
    var none = _build(_spec("ada", _strings("p3")))
    assert_equal(len(none.nodes), 0)
    var other = _build(_spec("ada", _strings("p-missing")))
    assert_equal(len(other.nodes), 0)


def test_a_federated_query_keeps_its_neighbours_in_the_partitions_it_names() raises:
    var r = _build(_spec("ada", _strings("p1"), federated=True))
    # Seed 1 (p1); its neighbour 2 (p1). Bolt (3, p2) is across the edge 1 -> 3
    # but p2 is not named, so it and that edge stay out.
    _assert_ids(r, _nodes(1, 2))
    assert_equal(r.mode, "federated_query")
    assert_equal(r.query_label, "federated query (1 partitions): ada")
    assert_equal(len(r.provenance), 2)
    assert_equal(r.provenance[0].source_id, "1")
    assert_equal(r.provenance[0].source, "partition:p1")
    assert_equal(r.provenance[1].source_id, "2")
    assert_equal(r.provenance[1].source, "partition:p1")
    assert_equal(len(r.edges), 1)
    # Naming both partitions admits the neighbour across the edge, with its own
    # partition as provenance.
    var both = _build(_spec("ada", _strings("p1", "p2"), federated=True))
    var ids = _ids(both)
    var has_bolt = False
    for i in range(len(ids)):
        if ids[i] == Int64(3):
            has_bolt = True
            assert_equal(both.provenance[i].source, "partition:p2")
    assert_true(has_bolt)


def test_a_federated_query_returns_no_node_or_edge_of_an_unnamed_partition() raises:
    for text in _strings("ada", "alpha", "a", "acme"):
        var r = _build(_spec(text, _strings("p1"), federated=True))
        for i in range(len(r.nodes)):
            assert_equal(r.provenance[i].source, "partition:p1", text)
        for i in range(len(r.edges)):
            assert_true(r.edges[i].src != Int64(3) and r.edges[i].src != Int64(4), text)
            assert_true(r.edges[i].dst != Int64(3) and r.edges[i].dst != Int64(4), text)


def test_a_federated_result_does_not_depend_on_the_order_of_partitions() raises:
    var ab = _build(_spec("alpha", _strings("p1", "p2"), federated=True)).serialize()
    var ba = _build(_spec("alpha", _strings("p2", "p1"), federated=True)).serialize()
    assert_equal(ab, ba)
    var text = _build(_spec("ada", _strings("p1", "p2"), federated=True)).serialize()
    assert_equal(text, _build(_spec("ada", _strings("p2", "p1"), federated=True)).serialize())
    # Both partitions contributed: Byron (0.994) ranks between 1/7 (1.0) and Dana.
    var r = _build(_spec("alpha", _strings("p1", "p2"), federated=True))
    assert_equal(r.nodes[0].id, Int64(1))
    assert_equal(r.nodes[1].id, Int64(7))
    assert_equal(r.nodes[2].id, Int64(4))
    assert_equal(r.nodes[3].id, Int64(6))


def test_the_per_partition_cap_bounds_each_partitions_seeds() raises:
    var capped = QueryConfig("p", 16, 100, 4096, 32, 1, 0.5)
    var r = _build(_spec("alpha", _strings("p1", "p2"), federated=True), capped)
    # One semantic seed per partition: 1 from p1 and 4 from p2. Twin (7) and
    # Dana (6) are cut; Bolt (3) joins as a neighbour.
    var seeds = List[Int64]()
    for i in range(len(r.nodes)):
        if r.nodes[i].score == 1.0:
            seeds.append(r.nodes[i].id)
    assert_equal(len(seeds), 2)
    assert_equal(seeds[0], Int64(1))
    assert_equal(seeds[1], Int64(4))
    for i in range(len(r.nodes)):
        assert_true(r.nodes[i].id != Int64(7) and r.nodes[i].id != Int64(6))
    # The same cap bounds the text match: "a" is in three p1 names, one seeds.
    var text = _build(_spec("a", _strings("p1"), federated=True), capped)
    assert_equal(text.nodes[0].id, Int64(1))
    assert_equal(text.nodes[0].score, 1.0)
    for i in range(1, len(text.nodes)):
        assert_equal(text.nodes[i].score, 0.5)
    # Without the cap each name that contains the text seeds.
    var open = _build(_spec("a", _strings("p1"), federated=True))
    var n_seed = 0
    for i in range(len(open.nodes)):
        if open.nodes[i].score == 1.0:
            n_seed += 1
    assert_true(n_seed >= 3)


# --- facet -------------------------------------------------------------------


def test_the_facet_filter_is_an_exact_string_comparison() raises:
    var fa = _build(_spec("alpha", _strings("p1"), facet="fa"))
    _assert_ids(fa, _nodes(1, 7, 6, 2))
    var misses = _strings("f", "FA", "fa ", "fb", "fa,fb")
    for i in range(len(misses)):
        var none = _build(_spec("alpha", _strings("p1"), facet=misses[i].copy()))
        assert_equal(len(none.nodes), 0, "facet '" + misses[i] + "'")
    # p2's entities carry fb, so fa finds none there.
    var cross = _build(_spec("alpha", _strings("p2"), facet="fa"))
    assert_equal(len(cross.nodes), 0)


def test_the_facet_filter_applies_to_neighbours_and_to_unfaceted_entities() raises:
    # Acme (fa) is next to Casey, who has no facet.
    var plain = _build(_spec("acme", _strings("p1", "p3"), federated=True))
    var plain_ids = _ids(plain)
    assert_equal(len(plain_ids), 3)
    assert_equal(plain_ids[0], Int64(2))
    assert_equal(plain_ids[1], Int64(1))
    assert_equal(plain_ids[2], Int64(5))
    var faceted = _build(_spec("acme", _strings("p1", "p3"), federated=True, facet="fa"))
    _assert_ids(faceted, _nodes(2, 1))
    # An entity with no facet is never matched by a non-empty filter.
    var casey = _build(_spec("casey", _strings("p3"), federated=True, facet="fa"))
    assert_equal(len(casey.nodes), 0)
    var unfiltered = _build(_spec("casey", _strings("p1", "p3"), federated=True))
    _assert_ids(unfiltered, _nodes(5, 2))


# --- as_of -------------------------------------------------------------------


def test_as_of_keeps_only_edges_live_then_and_their_neighbours() raises:
    var before = _build(_spec("ada", _strings("p1"), as_of=Optional[Int64](Int64(50))))
    _assert_ids(before, _nodes(1))
    assert_equal(len(before.edges), 0)
    var at_start = _build(_spec("ada", _strings("p1"), as_of=Optional[Int64](Int64(100))))
    _assert_ids(at_start, _nodes(1, 2))
    assert_equal(len(at_start.edges), 1)

    var live = _build(_spec("lovelace", _strings("p1", "p2"), federated=True, as_of=Optional[Int64](Int64(250))))
    _assert_ids(live, _nodes(1, 2, 3))
    assert_equal(len(live.edges), 2)
    # The edge to Bolt Co ended at 300 (exclusive).
    var ended = _build(_spec("lovelace", _strings("p1", "p2"), federated=True, as_of=Optional[Int64](Int64(300))))
    _assert_ids(ended, _nodes(1, 2))
    assert_equal(len(ended.edges), 1)


# --- k -----------------------------------------------------------------------


def test_k_cuts_the_nodes_but_not_the_semantic_scores() raises:
    var r = _build(_spec("alpha", _strings("p1"), k=1))
    _assert_ids(r, _nodes(1))
    var semantic = 0
    for i in range(len(r.scores)):
        if r.scores[i].name == "semantic":
            semantic += 1
    assert_equal(semantic, 3)
    var two = _build(_spec("ada", _strings("p1"), k=2))
    _assert_ids(two, _nodes(1, 2))
    assert_equal(len(two.edges), 1)
    # k reaches into the neighbours only as far as it has room.
    var seeds_only = _build(_spec("alpha", _strings("p1"), k=3))
    _assert_ids(seeds_only, _nodes(1, 7, 6))


# --- the embedder -------------------------------------------------------------


struct OddEmbedder(Embedder):
    """An embedder that fails in one way: 0 raises, 1 returns too few
    components, 2 returns a NaN."""

    var how: Int

    def __init__(out self, how: Int):
        self.how = how

    def dimension(self) -> Int:
        return DIM

    def embed(self, text: String) raises -> List[Float64]:
        if self.how == 0:
            raise Error("the embedder is down")
        var v = List[Float64]()
        v.append(1.0)
        v.append(0.0)
        v.append(0.0)
        if self.how == 2:
            v.append(nan[DType.float64]())
        return v^

    def embed_batch(self, texts: List[String]) raises -> List[List[Float64]]:
        var out = List[List[Float64]]()
        for i in range(len(texts)):
            out.append(self.embed(texts[i]))
        return out^


def test_an_embedder_that_fails_leaves_the_text_match() raises:
    for how in range(3):
        var r = build_query_result(
            OddEmbedder(how), _ws(), _spec("ada", _strings("p1")), QueryConfig.default()
        )
        _assert_ids(r, _nodes(1, 2))
        for i in range(len(r.scores)):
            assert_true(r.scores[i].name != "semantic", "embedder mode " + String(how))


def test_an_edge_shows_its_fact_alone() raises:
    var r = _build(_spec("casey", _strings("p1", "p3"), federated=True))
    assert_equal(len(r.edges), 1)
    assert_equal(r.edges[0].predicate, "Acme sponsors Casey")
    assert_equal(r.edges[0].source_id, "")
    # An edge with no fact has an empty label, whatever its predicate holds.
    var both = _build(_spec("alpha", _strings("p1")))
    var labels = List[String]()
    for i in range(len(both.edges)):
        labels.append(both.edges[i].predicate.copy())
    assert_equal(len(labels), 2)
    assert_equal(labels[0], "Ada works at Acme")
    assert_equal(labels[1], "")


def _pair_ws(predicate: String) raises -> SnapshotWorkingSet:
    var ws = SnapshotWorkingSet(DIM)
    ws.add_entity(_entity(1, "Ada Lovelace", "p1", "fa", _vec(1.0, 0.0, 0.0, 0.0)))
    ws.add_entity(_entity(2, "Acme Labs", "p1", "fa", _vec(0.0, 1.0, 0.0, 0.0)))
    ws.add_edge(_edge(1, 2, predicate, "", Int64(0), TS_OPEN_SENTINEL))
    return ws^


def test_a_set_that_kept_the_predicate_answers_like_one_that_lost_it() raises:
    # A loaded set reads an edge's predicate as ""; the warm set it was written
    # from still holds it. With no fact, both must give the same bytes.
    var warm = build_query_result(
        _emb(), _pair_ws("works_at"), _spec("alpha", _strings("p1")), QueryConfig.default()
    )
    var loaded = build_query_result(
        _emb(), _pair_ws(""), _spec("alpha", _strings("p1")), QueryConfig.default()
    )
    assert_equal(len(warm.edges), 1)
    assert_equal(warm.serialize(), loaded.serialize())


# --- guards on the query vector ------------------------------------------------


def test_a_query_vector_of_another_dimension_than_the_graph_seeds_nothing() raises:
    # Entities whose vectors are as short as the embedder's (a table written
    # past the working set's checks): only the graph-wide dimension refuses them.
    var ws = SnapshotWorkingSet(DIM)
    for i in range(3):
        ws.entities.append(
            WorkingEntity(
                Int64(10 + i), "u", String("p1"), "Zed " + String(i), _short_vec(),
                String(""), facet_attrs_json(String("fa"), String("")),
            )
        )
    var r = build_query_result(
        OddEmbedder(1), ws, _spec("ada", _strings("p1")), QueryConfig.default()
    )
    assert_equal(len(r.nodes), 0)
    assert_equal(len(r.scores), 0)


def _short_vec() -> List[Float64]:
    var v = List[Float64]()
    v.append(1.0)
    v.append(0.0)
    v.append(0.0)
    return v^


def test_a_non_finite_query_vector_seeds_nothing_even_at_a_zero_floor() raises:
    # `cosine` scores a non-finite vector 0.0, which a floor of 0.0 accepts:
    # only the finite check keeps every entity from seeding.
    var open_floor = QueryConfig("p", 16, 100, 4096, 32, 64, 0.0)
    var r = build_query_result(
        OddEmbedder(2), _ws(), _spec("zzz", _strings("p1")), open_floor
    )
    assert_equal(len(r.nodes), 0)
    assert_equal(len(r.scores), 0)
    # The same floor with a finite vector does seed, so the empty result above
    # is the guard's doing.
    var finite = build_query_result(
        _emb(), _ws(), _spec("alpha", _strings("p1")), open_floor
    )
    assert_true(len(finite.nodes) > 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
