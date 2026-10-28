# =============================================================================
# test_ingest_structured.mojo -- ingest of known facts: no extraction, the
#   change gate, supersession, end times, and failures (an in-memory object
#   store, stub model and embedder; no network, no wall clock, no environment).
# =============================================================================
#
#   facts        known entities and triples become nodes, edges and a provenance
#                row; the extractor is never asked; the envelope (note, facet,
#                undated triples) is stamped as stated.
#   gate         the same facts again (under the source id, or the uuid when
#                there is no source) are a no-op that embeds and asks nothing,
#                whatever the envelope says; changed facts are ingested.
#   supersede    a contradiction judged on the structured path closes the old
#                edge; an unjudged pair leaves both open.
#   end times    a triple's end time is stored (the edge is ended, the graph
#                still believes it); it is judged over its own interval; an end
#                at or before the start is refused with the store unchanged.
#   failure      an embedder, a same-entity judge or a contradiction judge that
#                raises, a wrong dimension and a spent episode leave the head, the
#                graph and the gate as they were.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_raises,
    assert_true,
)

from komira_kg import (
    Embedder,
    IngestConfig,
    LlmClient,
    SnapshotWorkingSet,
    StructuredEpisode,
    StubEmbedder,
    StubLlmClient,
    facet_attrs_json,
    ingest_structured,
    ingest_structured_into,
)
from komira_kg_format import (
    EntityMention,
    Extraction,
    KgSnapshotStore,
    TS_OPEN_SENTINEL,
    Triple,
    content_hash_of_extraction,
)
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

comptime Backend = SharedInMemoryConditionalStore
comptime Kg = KgSnapshotStore[SharedInMemoryConditionalStore]
comptime DIM = 6

comptime ALDER = "Alder"
comptime BIRCH = "Birch"
comptime CEDAR = "Cedar"
comptime BORDERS = "Alder borders Birch"
comptime FACES = "Alder faces Birch"
comptime NEAR = "Alder is near Cedar"


struct FlakyLlm(LlmClient):
    """A stub model whose chosen calls raise."""

    var inner: StubLlmClient
    var fail_extract: Bool
    var fail_same: Bool
    var fail_contradiction: Bool

    def __init__(
        out self,
        var inner: StubLlmClient,
        fail_extract: Bool,
        fail_same: Bool,
        fail_contradiction: Bool,
    ):
        self.inner = inner^
        self.fail_extract = fail_extract
        self.fail_same = fail_same
        self.fail_contradiction = fail_contradiction

    def extract(
        self, text: String, already_found: List[EntityMention]
    ) raises -> Extraction:
        if self.fail_extract:
            raise Error("model down: extract")
        return self.inner.extract(text, already_found)

    def judge_contradiction(self, new_fact: String, old_fact: String) raises -> Bool:
        if self.fail_contradiction:
            raise Error("model down: contradiction")
        return self.inner.judge_contradiction(new_fact, old_fact)

    def judge_same_entity(
        self, name_a: String, summary_a: String, name_b: String, summary_b: String
    ) raises -> Bool:
        if self.fail_same:
            raise Error("model down: same entity")
        return self.inner.judge_same_entity(name_a, summary_a, name_b, summary_b)

    def has_synthesis(self) -> Bool:
        return False

    def synthesize(self, system_prompt: String, user_prompt: String) raises -> String:
        raise Error("none")


struct DeadEmbedder(Embedder):
    """Reports DIM; every `embed` raises."""

    def __init__(out self):
        pass

    def dimension(self) -> Int:
        return DIM

    def embed(self, text: String) raises -> List[Float64]:
        raise Error("embedder down: " + text)

    def embed_batch(self, texts: List[String]) raises -> List[List[Float64]]:
        raise Error("embedder down")


def _unit(i: Int) -> List[Float64]:
    var v = List[Float64]()
    for k in range(DIM):
        v.append(1.0 if k == i else 0.0)
    return v^


def _emb() raises -> StubEmbedder:
    var emb = StubEmbedder(DIM)
    emb.add_vector(ALDER, _unit(0))
    emb.add_vector(BIRCH, _unit(1))
    emb.add_vector(CEDAR, _unit(2))
    return emb^


def _t(
    s: String, o: String, fact: String, valid_at: Int64,
    invalid_at: Int64 = TS_OPEN_SENTINEL,
) -> Triple:
    return Triple(s, "rel", o, fact, valid_at, invalid_at)


def _ext(names: List[String], var triples: List[Triple]) -> Extraction:
    var ms = List[EntityMention]()
    for i in range(len(names)):
        ms.append(EntityMention(names[i], "", ""))
    return Extraction(ms^, triples^)


def _ab(fact: String, valid_at: Int64, invalid_at: Int64 = TS_OPEN_SENTINEL) -> Extraction:
    var names: List[String] = [ALDER, BIRCH]
    var ts = List[Triple]()
    ts.append(_t(ALDER, BIRCH, fact, valid_at, invalid_at))
    return _ext(names, ts^)


def _ac(valid_at: Int64) -> Extraction:
    var names: List[String] = [ALDER, CEDAR]
    var ts = List[Triple]()
    ts.append(_t(ALDER, CEDAR, NEAR, valid_at))
    return _ext(names, ts^)


def _ep(
    uuid: String, var extraction: Extraction, ts: Int64, source: String = ""
) -> StructuredEpisode:
    return StructuredEpisode(
        uuid, "p1", extraction^, ts, ts - Int64(500), "", source
    )


def _quiet() -> FlakyLlm:
    """A model that raises on `extract`: the structured path must not call it."""
    var llm = StubLlmClient()
    llm.add_contradiction(FACES, BORDERS, True)
    return FlakyLlm(llm^, True, False, False)


def _cfg() -> IngestConfig:
    return IngestConfig.default()


def _assert_unchanged(kg: Kg, head: Int64, edges: Int, episodes: Int) raises:
    assert_equal(kg.latest_snapshot_id(), head)
    assert_equal(kg.fingerprint_lookup("p1", "s-2"), "")
    if head >= 0:
        var ws = SnapshotWorkingSet.load_latest(kg)
        assert_equal(ws.num_edges(), edges)
        assert_equal(ws.num_episodes(), episodes)


def test_known_facts_become_nodes_edges_and_provenance_without_the_extractor() raises:
    var kg = Kg(Backend(), "g")
    var names: List[String] = [ALDER, BIRCH]
    var ts = List[Triple]()
    ts.append(Triple(ALDER, "rel", BIRCH, BORDERS, TS_OPEN_SENTINEL, TS_OPEN_SENTINEL))
    var ep = StructuredEpisode(
        "s-1", "p1", _ext(names, ts^), Int64(1000), Int64(700), "from a list",
        "", "listing", "lists",
    )
    var head = ingest_structured(kg, ep^, _quiet(), _emb(), _cfg())
    assert_equal(kg.latest_snapshot_id(), head)

    var ws = SnapshotWorkingSet.load_latest(kg)
    assert_equal(ws.num_entities(), 2)
    assert_equal(ws.entities[0].name, ALDER)
    assert_equal(ws.entities[0].partition_id, "p1")
    assert_equal(ws.entities[0].name_embedding[0], 1.0)
    assert_equal(ws.entities[0].attrs, facet_attrs_json("listing", "lists"))
    assert_equal(ws.entities[1].name_embedding[1], 1.0)
    assert_equal(ws.num_edges(), 1)
    ref e = ws.edges[0]
    assert_equal(e.fact, BORDERS)
    assert_equal(e.valid_at, Int64(700))  # undated: the episode's event time
    assert_equal(e.invalid_at, TS_OPEN_SENTINEL)
    assert_equal(e.created_at, Int64(1000))
    assert_equal(e.reference_time, Int64(700))
    assert_equal(e.source, "")
    assert_equal(ws.num_episodes(), 1)
    ref row = ws.episodes[0]
    assert_equal(row.uuid, "s-1")
    assert_equal(row.body, "from a list")
    assert_equal(row.facet, "listing")
    assert_equal(row.valid_at, Int64(700))


def test_the_gate_key_is_the_uuid_without_a_source_and_the_source_with_one() raises:
    var kg = Kg(Backend(), "g")
    var hash = content_hash_of_extraction(_ab(BORDERS, Int64(10)))
    _ = ingest_structured(kg, _ep("s-1", _ab(BORDERS, Int64(10)), Int64(1000)), _quiet(), _emb(), _cfg())
    assert_equal(kg.fingerprint_lookup("p1", "s-1"), hash)
    _ = ingest_structured(
        kg, _ep("s-2", _ab(BORDERS, Int64(10)), Int64(2000), "doc-9"), _quiet(), _emb(), _cfg()
    )
    assert_equal(kg.fingerprint_lookup("p1", "doc-9"), hash)
    assert_equal(kg.fingerprint_lookup("p1", "s-2"), "")


def test_the_same_facts_again_are_a_no_op_that_embeds_and_asks_nothing() raises:
    var kg = Kg(Backend(), "g")
    var head = ingest_structured(
        kg, _ep("s-1", _ab(BORDERS, Int64(10)), Int64(1000), "doc-9"), _quiet(), _emb(), _cfg()
    )
    # A dead embedder and a model that raises on every call: neither may be used.
    var again = ingest_structured(
        kg,
        StructuredEpisode(
            "s-other", "p1", _ab(BORDERS, Int64(10)), Int64(9000), Int64(8000),
            "another note", "doc-9", "f", "fs",
        ),
        FlakyLlm(StubLlmClient(), True, True, True),
        DeadEmbedder(),
        _cfg(),
    )
    assert_equal(again, head)
    assert_equal(kg.latest_snapshot_id(), head)
    assert_equal(SnapshotWorkingSet.load_latest(kg).num_episodes(), 1)

    # Without a source the uuid is the key.
    var head2 = ingest_structured(
        kg, _ep("s-2", _ab(FACES, Int64(20)), Int64(2000)), _quiet(), _emb(), _cfg()
    )
    var again2 = ingest_structured(
        kg, _ep("s-2", _ab(FACES, Int64(20)), Int64(3000)),
        FlakyLlm(StubLlmClient(), True, True, True), DeadEmbedder(), _cfg(),
    )
    assert_equal(again2, head2)


def test_changed_facts_under_the_same_key_are_ingested() raises:
    var kg = Kg(Backend(), "g")
    var head = ingest_structured(
        kg, _ep("s-1", _ab(BORDERS, Int64(10)), Int64(1000), "doc-9"), _quiet(), _emb(), _cfg()
    )
    var changed = ingest_structured(
        kg, _ep("s-1", _ab(BORDERS, Int64(15)), Int64(2000), "doc-9"), _quiet(), _emb(), _cfg()
    )
    assert_true(changed > head)
    assert_equal(
        kg.fingerprint_lookup("p1", "doc-9"),
        content_hash_of_extraction(_ab(BORDERS, Int64(15))),
    )
    assert_equal(SnapshotWorkingSet.load_latest(kg).num_episodes(), 2)


def test_a_judged_contradiction_closes_the_old_edge_on_the_structured_path() raises:
    var kg = Kg(Backend(), "g")
    _ = ingest_structured(kg, _ep("s-1", _ab(BORDERS, Int64(10)), Int64(1000)), _quiet(), _emb(), _cfg())
    _ = ingest_structured(kg, _ep("s-2", _ab(FACES, Int64(50)), Int64(2000)), _quiet(), _emb(), _cfg())
    var ws = SnapshotWorkingSet.load_latest(kg)
    assert_equal(ws.num_edges(), 2)
    assert_equal(ws.edges[0].fact, BORDERS)
    assert_equal(ws.edges[0].invalid_at, Int64(50))
    assert_equal(ws.edges[0].expired_at, Int64(2000))
    assert_equal(ws.edges[1].fact, FACES)
    assert_equal(ws.edges[1].invalid_at, TS_OPEN_SENTINEL)
    assert_equal(ws.edges[1].expired_at, TS_OPEN_SENTINEL)


def test_an_unjudged_pair_leaves_both_edges_open() raises:
    var kg = Kg(Backend(), "g")
    var plain = FlakyLlm(StubLlmClient(), True, False, False)  # every verdict False
    _ = ingest_structured(kg, _ep("s-1", _ab(BORDERS, Int64(10)), Int64(1000)), plain, _emb(), _cfg())
    _ = ingest_structured(kg, _ep("s-2", _ab(FACES, Int64(50)), Int64(2000)), plain, _emb(), _cfg())
    var ws = SnapshotWorkingSet.load_latest(kg)
    assert_equal(ws.num_edges(), 2)
    assert_equal(ws.edges[0].invalid_at, TS_OPEN_SENTINEL)
    assert_equal(ws.edges[1].invalid_at, TS_OPEN_SENTINEL)


def test_a_triple_with_an_end_time_is_stored_ended_and_still_believed() raises:
    var kg = Kg(Backend(), "g")
    _ = ingest_structured(
        kg, _ep("s-1", _ab(BORDERS, Int64(10), Int64(90)), Int64(1000)), _quiet(), _emb(), _cfg()
    )
    var ws = SnapshotWorkingSet.load_latest(kg)
    assert_equal(ws.num_edges(), 1)
    assert_equal(ws.edges[0].valid_at, Int64(10))
    assert_equal(ws.edges[0].invalid_at, Int64(90))
    assert_equal(ws.edges[0].expired_at, TS_OPEN_SENTINEL)


def test_an_ended_fact_is_judged_over_its_own_interval_only() raises:
    var kg = Kg(Backend(), "g")
    # A live edge from 100; then a fact that held on [10, 50) and was over before
    # it began. The judge would say "contradicts" if asked, but the two never
    # overlapped, so it must not be asked and the live edge stays open from 100.
    _ = ingest_structured(kg, _ep("s-1", _ab(FACES, Int64(100)), Int64(1000)), _quiet(), _emb(), _cfg())
    var llm = StubLlmClient()
    llm.add_contradiction(BORDERS, FACES, True)
    _ = ingest_structured(
        kg, _ep("s-2", _ab(BORDERS, Int64(10), Int64(50)), Int64(2000)),
        FlakyLlm(llm^, True, False, False), _emb(), _cfg(),
    )
    var ws = SnapshotWorkingSet.load_latest(kg)
    assert_equal(ws.num_edges(), 2)
    assert_equal(ws.edges[0].fact, FACES)
    assert_equal(ws.edges[0].valid_at, Int64(100))
    assert_equal(ws.edges[0].invalid_at, TS_OPEN_SENTINEL)
    assert_equal(ws.edges[0].expired_at, TS_OPEN_SENTINEL)
    assert_equal(ws.edges[1].invalid_at, Int64(50))


def test_an_ended_fact_that_overlaps_is_judged_and_can_supersede() raises:
    var kg = Kg(Backend(), "g")
    _ = ingest_structured(kg, _ep("s-1", _ab(FACES, Int64(20)), Int64(1000)), _quiet(), _emb(), _cfg())
    var llm = StubLlmClient()
    llm.add_contradiction(BORDERS, FACES, True)
    _ = ingest_structured(
        kg, _ep("s-2", _ab(BORDERS, Int64(10), Int64(50)), Int64(2000)),
        FlakyLlm(llm^, True, False, False), _emb(), _cfg(),
    )
    var ws = SnapshotWorkingSet.load_latest(kg)
    # The live edge cannot be closed before it began: it is clamped to its start.
    assert_equal(ws.edges[0].invalid_at, Int64(20))
    assert_equal(ws.edges[0].expired_at, Int64(2000))
    assert_equal(ws.edges[1].invalid_at, Int64(50))


def test_an_end_at_or_before_the_start_is_refused_and_the_store_is_unchanged() raises:
    var fresh = Kg(Backend(), "g")
    with assert_raises(contains="ends at 10, not after its start 10"):
        _ = ingest_structured(
            fresh, _ep("s-2", _ab(BORDERS, Int64(10), Int64(10)), Int64(2000)), _quiet(), _emb(), _cfg()
        )
    _assert_unchanged(fresh, Int64(-1), 0, 0)

    var kg = Kg(Backend(), "g")
    var head = ingest_structured(kg, _ep("s-1", _ab(BORDERS, Int64(10)), Int64(1000)), _quiet(), _emb(), _cfg())
    with assert_raises(contains="ends at 5, not after its start 10"):
        _ = ingest_structured(
            kg, _ep("s-2", _ab(FACES, Int64(10), Int64(5)), Int64(2000)), _quiet(), _emb(), _cfg()
        )
    _assert_unchanged(kg, head, 1, 1)


def test_an_embedder_that_raises_leaves_the_store_unchanged() raises:
    var fresh = Kg(Backend(), "g")
    with assert_raises(contains="embedder down"):
        _ = ingest_structured(
            fresh, _ep("s-2", _ab(BORDERS, Int64(10)), Int64(2000)), _quiet(), DeadEmbedder(), _cfg()
        )
    _assert_unchanged(fresh, Int64(-1), 0, 0)

    var kg = Kg(Backend(), "g")
    var head = ingest_structured(kg, _ep("s-1", _ab(BORDERS, Int64(10)), Int64(1000)), _quiet(), _emb(), _cfg())
    with assert_raises(contains="embedder down"):
        _ = ingest_structured(
            kg, _ep("s-2", _ac(Int64(20)), Int64(2000)), _quiet(), DeadEmbedder(), _cfg()
        )
    _assert_unchanged(kg, head, 1, 1)


def test_a_same_entity_judge_that_raises_leaves_the_store_unchanged() raises:
    # A borderline variant of an existing name goes to the judge, which raises.
    var emb = _emb()
    emb.add_vector("Harbor Alpha Meadow", _unit(3))
    emb.add_vector("harbor aypha meadow", _unit(3))
    var kg = Kg(Backend(), "g")
    var first: List[String] = ["Harbor Alpha Meadow"]
    var head = ingest_structured(
        kg, _ep("s-1", _ext(first, List[Triple]()), Int64(1000)), _quiet(), emb, _cfg()
    )
    var second: List[String] = ["harbor aypha meadow"]
    with assert_raises(contains="model down: same entity"):
        _ = ingest_structured(
            kg, _ep("s-2", _ext(second, List[Triple]()), Int64(2000)),
            FlakyLlm(StubLlmClient(), False, True, False), emb, _cfg(),
        )
    _assert_unchanged(kg, head, 0, 1)
    assert_equal(SnapshotWorkingSet.load_latest(kg).num_entities(), 1)


def test_a_contradiction_judge_that_raises_leaves_the_store_unchanged() raises:
    var kg = Kg(Backend(), "g")
    var head = ingest_structured(kg, _ep("s-1", _ab(BORDERS, Int64(10)), Int64(1000)), _quiet(), _emb(), _cfg())
    with assert_raises(contains="model down: contradiction"):
        _ = ingest_structured(
            kg, _ep("s-2", _ab(FACES, Int64(50)), Int64(2000)),
            FlakyLlm(StubLlmClient(), True, False, True), _emb(), _cfg(),
        )
    _assert_unchanged(kg, head, 1, 1)
    assert_equal(SnapshotWorkingSet.load_latest(kg).edges[0].invalid_at, TS_OPEN_SENTINEL)


def test_the_extractor_failing_cannot_matter_because_it_is_never_asked() raises:
    # `_quiet()` raises on every extract; every ingest above succeeded with it.
    var kg = Kg(Backend(), "g")
    var head = ingest_structured(
        kg, _ep("s-1", _ab(BORDERS, Int64(10)), Int64(1000)),
        FlakyLlm(StubLlmClient(), True, False, False), _emb(), _cfg(),
    )
    assert_true(head >= 0)


def test_an_embedder_of_another_dimension_is_refused() raises:
    var kg = Kg(Backend(), "g")
    var head = ingest_structured(kg, _ep("s-1", _ab(BORDERS, Int64(10)), Int64(1000)), _quiet(), _emb(), _cfg())
    with assert_raises(contains="embedder's dimension is 3 but the graph's is 6"):
        _ = ingest_structured(
            kg, _ep("s-2", _ac(Int64(20)), Int64(2000)), _quiet(), StubEmbedder(3), _cfg()
        )
    _assert_unchanged(kg, head, 1, 1)


def test_a_knob_out_of_range_is_refused() raises:
    var kg = Kg(Backend(), "g")
    var cfg = _cfg()
    cfg.cosine_k = 0
    with assert_raises(contains="cosine_k must be at least 1"):
        _ = ingest_structured(
            kg, _ep("s-2", _ab(BORDERS, Int64(10)), Int64(2000)), _quiet(), _emb(), cfg
        )
    _assert_unchanged(kg, Int64(-1), 0, 0)


def test_a_spent_episode_is_refused_and_writes_nothing() raises:
    var kg = Kg(Backend(), "g")
    var ep = _ep("s-2", _ab(BORDERS, Int64(10)), Int64(2000))
    _ = ep.take_extraction()
    with assert_raises(contains="the extraction was already taken"):
        _ = ep.take_extraction()
    with assert_raises(contains="the extraction was already taken"):
        _ = ingest_structured(kg, ep^, _quiet(), _emb(), _cfg())
    _assert_unchanged(kg, Int64(-1), 0, 0)


def test_a_resident_set_writes_each_structured_deltas_alone() raises:
    var kg = Kg(Backend(), "g")
    var ws = SnapshotWorkingSet(DIM)
    var llm = _quiet()
    var emb = _emb()
    _ = ingest_structured_into(kg, ws, _ep("s-1", _ab(BORDERS, Int64(10)), Int64(1000)), llm, emb, _cfg())
    assert_true(not ws.has_delta())
    _ = ingest_structured_into(kg, ws, _ep("s-2", _ac(Int64(20)), Int64(2000)), llm, emb, _cfg())
    assert_true(not ws.has_delta())
    assert_equal(ws.num_entities(), 3)
    assert_equal(ws.num_edges(), 2)
    var reloaded = SnapshotWorkingSet.load_latest(kg)
    assert_equal(reloaded.num_entities(), 3)
    assert_equal(reloaded.num_edges(), 2)
    assert_equal(reloaded.num_episodes(), 2)
    assert_equal(kg.open_latest_chain().num_deltas(), 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
