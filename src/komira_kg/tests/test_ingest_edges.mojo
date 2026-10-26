# =============================================================================
# test_ingest_edges.mojo -- apply extracted triples to the working set as
#   bi-temporal edges (stub model and embedder; no network, clock or
#   environment).
# =============================================================================
#
#   edges       a triple becomes an open edge with the stated endpoints,
#               predicate, fact, times and source; an undated triple takes the
#               episode's time; the triple's own end time is not read.
#   endpoints   a mention, then an existing entity, then a new entity; and the
#               alias map is applied last.
#   supersede   a confirmed contradiction closes the overlapping edge between
#               the pair (valid end, expiry now, row kept) and the new edge is
#               appended; a denied one leaves both open; an edge that ended
#               before the new one starts, an edge of another pair and, when
#               asked, an edge of another predicate are never put to the model.
#   repeats     a live edge with the same endpoints, fact and source (the
#               predicate is not stored, so not part of it) is not added again; another source's, or one that was closed,
#               does not stop the new edge.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_raises,
    assert_true,
)

from komira_kg import (
    AliasMap,
    IngestConfig,
    SnapshotWorkingSet,
    StubEmbedder,
    StubLlmClient,
    WorkingEntity,
    apply_edges,
    facet_attrs_json,
    open_edge,
)
from komira_kg_format import TS_OPEN_SENTINEL, Triple

comptime DIM = 4
comptime NOW = Int64(1000)
comptime EPISODE_AT = Int64(500)


def _vec(a: Float64, b: Float64) -> List[Float64]:
    var v = List[Float64]()
    v.append(a)
    v.append(b)
    v.append(0.0)
    v.append(0.0)
    return v^


def _graph() raises -> SnapshotWorkingSet:
    """Entities 0 = A, 1 = B, 2 = C of partition p1."""
    var ws = SnapshotWorkingSet(DIM)
    ws.add_entity(WorkingEntity(ws.next_nid(), "u0", "p1", "A", _vec(1.0, 0.0), "", "{}"))
    ws.add_entity(WorkingEntity(ws.next_nid(), "u1", "p1", "B", _vec(0.0, 1.0), "", "{}"))
    ws.add_entity(WorkingEntity(ws.next_nid(), "u2", "p1", "C", _vec(0.5, 0.5), "", "{}"))
    return ws^


def _t(
    subject: String,
    object: String,
    fact: String,
    valid_at: Int64 = TS_OPEN_SENTINEL,
    predicate: String = "rel",
) -> Triple:
    return Triple(subject, predicate, object, fact, valid_at, TS_OPEN_SENTINEL)


def _one(t: Triple) -> List[Triple]:
    var out = List[Triple]()
    out.append(t.copy())
    return out^


def _mentions() -> List[String]:
    var out = List[String]()
    out.append("A")
    out.append("B")
    return out^


def _mention_nids() -> List[Int64]:
    var out = List[Int64]()
    out.append(Int64(0))
    out.append(Int64(1))
    return out^


def _apply(
    mut ws: SnapshotWorkingSet,
    triples: List[Triple],
    llm: StubLlmClient,
    cfg: IngestConfig = IngestConfig.default(),
    source: String = "",
) raises:
    var emb = StubEmbedder(DIM)
    var aliases = AliasMap()
    apply_edges(
        ws, triples, _mentions(), _mention_nids(), llm, emb, "p1", NOW,
        EPISODE_AT, aliases, cfg, source,
    )


def test_a_triple_becomes_an_open_edge_with_its_stated_fields() raises:
    var ws = _graph()
    _apply(ws, _one(_t("A", "B", "A rel B", Int64(100))), StubLlmClient(), source="s1")
    assert_equal(ws.num_edges(), 1)
    ref e = ws.edges[0]
    assert_equal(e.src_nid, Int64(0))
    assert_equal(e.dst_nid, Int64(1))
    assert_equal(e.predicate, "rel")
    assert_equal(e.fact, "A rel B")
    assert_equal(e.valid_at, Int64(100))
    assert_equal(e.invalid_at, TS_OPEN_SENTINEL)
    assert_equal(e.expired_at, TS_OPEN_SENTINEL)
    assert_equal(e.created_at, NOW)
    assert_equal(e.reference_time, EPISODE_AT)
    assert_equal(e.source, "s1")


def test_an_undated_triple_takes_the_episode_time() raises:
    var ws = _graph()
    _apply(ws, _one(_t("A", "B", "A rel B")), StubLlmClient())
    assert_equal(ws.edges[0].valid_at, EPISODE_AT)


def test_the_triples_own_end_time_is_not_read() raises:
    var ws = _graph()
    var t = _t("A", "B", "A rel B", Int64(100))
    t.invalid_at = Int64(200)
    _apply(ws, _one(t), StubLlmClient())
    assert_equal(ws.edges[0].invalid_at, TS_OPEN_SENTINEL)


def test_an_endpoint_that_is_no_mention_links_to_an_existing_entity() raises:
    var ws = _graph()
    _apply(ws, _one(_t("A", "C", "A rel C")), StubLlmClient())
    assert_equal(ws.edges[0].dst_nid, Int64(2))
    assert_equal(ws.num_entities(), 3)


def test_an_unknown_endpoint_is_minted_so_the_edge_never_dangles() raises:
    var ws = _graph()
    var emb = StubEmbedder(DIM)
    var aliases = AliasMap()
    var llm = StubLlmClient()
    apply_edges(
        ws, _one(_t("A", "Zed", "A rel Zed")), _mentions(), _mention_nids(),
        llm, emb, "p1", NOW, EPISODE_AT, aliases, IngestConfig.default(),
        "", "chat", "src-1",
    )
    assert_equal(ws.num_entities(), 4)
    assert_equal(ws.edges[0].dst_nid, Int64(3))
    ref z = ws.entities[3]
    assert_equal(z.name, "Zed")
    assert_equal(z.partition_id, "p1")
    assert_equal(z.attrs, facet_attrs_json("chat", "src-1"))
    assert_equal(len(z.name_embedding), DIM)


def test_an_endpoint_is_resolved_through_the_alias_map() raises:
    var ws = _graph()
    var aliases = AliasMap()
    aliases.union(Int64(1), Int64(2))  # B is C
    var emb = StubEmbedder(DIM)
    var llm = StubLlmClient()
    apply_edges(
        ws, _one(_t("A", "B", "A rel B")), _mentions(), _mention_nids(),
        llm, emb, "p1", NOW, EPISODE_AT, aliases, IngestConfig.default(),
    )
    assert_equal(ws.edges[0].dst_nid, Int64(2))


def _seed_edge(mut ws: SnapshotWorkingSet, fact: String, valid_at: Int64):
    ws.add_edge(open_edge(Int64(0), Int64(1), "rel", fact, valid_at, Int64(100), Int64(100)))


def test_a_confirmed_contradiction_closes_the_old_edge_and_keeps_it() raises:
    var ws = _graph()
    _seed_edge(ws, "A is at X", Int64(10))
    var llm = StubLlmClient()
    llm.add_contradiction("A is at Y", "A is at X", True)
    _apply(ws, _one(_t("A", "B", "A is at Y", Int64(50))), llm)
    assert_equal(ws.num_edges(), 2)
    ref old = ws.edges[0]
    assert_equal(old.fact, "A is at X")
    assert_equal(old.invalid_at, Int64(50))
    assert_equal(old.expired_at, NOW)
    assert_equal(old.valid_at, Int64(10))
    assert_equal(old.created_at, Int64(100))
    ref new = ws.edges[1]
    assert_equal(new.fact, "A is at Y")
    assert_equal(new.invalid_at, TS_OPEN_SENTINEL)
    assert_equal(new.expired_at, TS_OPEN_SENTINEL)


def test_a_denied_contradiction_leaves_both_edges_open() raises:
    var ws = _graph()
    _seed_edge(ws, "A is at X", Int64(10))
    var llm = StubLlmClient()
    llm.add_contradiction("A is at Y", "A is at X", False)
    _apply(ws, _one(_t("A", "B", "A is at Y", Int64(50))), llm)
    assert_equal(ws.num_edges(), 2)
    assert_equal(ws.edges[0].invalid_at, TS_OPEN_SENTINEL)
    assert_equal(ws.edges[0].expired_at, TS_OPEN_SENTINEL)


def test_edges_that_cannot_overlap_are_not_put_to_the_model() raises:
    var ws = _graph()
    # An edge that ended before the new one starts, and one of another pair.
    var ended = open_edge(Int64(0), Int64(1), "rel", "A was at X", Int64(10), Int64(100), Int64(100))
    ended.invalid_at = Int64(20)
    ws.add_edge(ended^)
    ws.add_edge(open_edge(Int64(1), Int64(0), "rel", "B is at X", Int64(10), Int64(100), Int64(100)))
    ws.add_edge(open_edge(Int64(0), Int64(2), "rel", "A is near C", Int64(10), Int64(100), Int64(100)))
    var llm = StubLlmClient()
    llm.add_contradiction("A is at Y", "A was at X", True)
    llm.add_contradiction("A is at Y", "B is at X", True)
    llm.add_contradiction("A is at Y", "A is near C", True)
    _apply(ws, _one(_t("A", "B", "A is at Y", Int64(50))), llm)
    assert_equal(ws.num_edges(), 4)
    assert_equal(ws.edges[0].invalid_at, Int64(20))
    assert_equal(ws.edges[0].expired_at, TS_OPEN_SENTINEL)
    assert_equal(ws.edges[1].invalid_at, TS_OPEN_SENTINEL)
    assert_equal(ws.edges[2].invalid_at, TS_OPEN_SENTINEL)


def test_the_predicate_matters_only_when_asked() raises:
    var llm = StubLlmClient()
    llm.add_contradiction("A is at Y", "A is at X", True)
    var other = _t("A", "B", "A is at Y", Int64(50), "other")

    var loose = _graph()
    _seed_edge(loose, "A is at X", Int64(10))
    _apply(loose, _one(other), llm)
    assert_equal(loose.edges[0].invalid_at, Int64(50))

    var strict_cfg = IngestConfig.default()
    strict_cfg.match_predicate = True
    var strict = _graph()
    _seed_edge(strict, "A is at X", Int64(10))
    _apply(strict, _one(other), llm, strict_cfg)
    assert_equal(strict.edges[0].invalid_at, TS_OPEN_SENTINEL)
    assert_equal(strict.num_edges(), 2)


def test_a_live_repeat_adds_nothing() raises:
    var ws = _graph()
    var t = _one(_t("A", "B", "A rel B", Int64(100)))
    _apply(ws, t, StubLlmClient(), source="s1")
    _apply(ws, t, StubLlmClient(), source="s1")
    assert_equal(ws.num_edges(), 1)


def test_a_repeat_from_another_source_is_its_own_edge() raises:
    var ws = _graph()
    var t = _one(_t("A", "B", "A rel B", Int64(100)))
    _apply(ws, t, StubLlmClient(), source="s1")
    _apply(ws, t, StubLlmClient(), source="s2")
    assert_equal(ws.num_edges(), 2)
    assert_equal(ws.edges[1].source, "s2")


def test_a_repeat_of_a_closed_or_expired_edge_is_added() raises:
    var closed = _graph()
    closed.add_edge(open_edge(Int64(0), Int64(1), "rel", "A rel B", Int64(10), Int64(100), Int64(100)))
    closed.edges[0].invalid_at = Int64(300)
    _apply(closed, _one(_t("A", "B", "A rel B", Int64(400))), StubLlmClient())
    assert_equal(closed.num_edges(), 2)

    var expired = _graph()
    expired.add_edge(open_edge(Int64(0), Int64(1), "rel", "A rel B", Int64(10), Int64(100), Int64(100)))
    expired.edges[0].expired_at = Int64(300)
    _apply(expired, _one(_t("A", "B", "A rel B", Int64(400))), StubLlmClient())
    assert_equal(expired.num_edges(), 2)


def test_a_repeat_with_another_fact_is_added() raises:
    var ws = _graph()
    _apply(ws, _one(_t("A", "B", "A rel B", Int64(100))), StubLlmClient())
    _apply(ws, _one(_t("A", "B", "a different fact", Int64(100))), StubLlmClient())
    assert_equal(ws.num_edges(), 2)


def test_the_predicate_is_not_part_of_a_facts_identity() raises:
    # A stored edge has no predicate, so the same fact under another label is
    # the same fact.
    var ws = _graph()
    _apply(ws, _one(_t("A", "B", "A rel B", Int64(100))), StubLlmClient())
    _apply(ws, _one(_t("A", "B", "A rel B", Int64(100), "other")), StubLlmClient())
    assert_equal(ws.num_edges(), 1)


def test_a_repeat_with_other_endpoints_is_added() raises:
    var ws = _graph()
    _apply(ws, _one(_t("A", "B", "A rel B", Int64(100))), StubLlmClient())
    _apply(ws, _one(_t("A", "C", "A rel B", Int64(100))), StubLlmClient())
    _apply(ws, _one(_t("C", "B", "A rel B", Int64(100))), StubLlmClient())
    assert_equal(ws.num_edges(), 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
