# =============================================================================
# test_ingest_failure.mojo -- what an ingest refuses, and that a refusal or a
#   model failure leaves the store as it was (an in-memory object store; no
#   network, no wall clock, no environment).
# =============================================================================
#
#   dimension  an embedder of another dimension than the graph's is refused
#              before the model is asked; so is one that reports the right
#              dimension and returns vectors of another length, or ones that are
#              not finite.
#   config     a knob no ingest can run with is refused, including a similarity
#              floor or an entropy floor that is not a finite number in range.
#   delta      a set that cannot be written as a delta for a reason other than a
#              closure ambiguity (a shrunk edge or episode list, a dropped loaded
#              entity, an embedding beyond f32) is an error and writes nothing,
#              not a new base.
#   failure    an extractor, a same-entity judge, a contradiction judge or an
#              embedder that raises leaves the head, the graph and the change
#              gate's hash as they were, on a new lineage and on an existing one.
# =============================================================================

from std.math import inf, nan
from std.testing import (
    TestSuite,
    assert_equal,
    assert_raises,
    assert_true,
)

from komira_kg import (
    Embedder,
    EpisodeInput,
    IngestConfig,
    LlmClient,
    SnapshotWorkingSet,
    StubEmbedder,
    StubLlmClient,
    ingest_episode,
    ingest_episode_into,
)
from komira_kg_format import (
    EntityMention,
    Extraction,
    KgSnapshotStore,
    TS_OPEN_SENTINEL,
    Triple,
)
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

comptime Backend = SharedInMemoryConditionalStore
comptime Kg = KgSnapshotStore[SharedInMemoryConditionalStore]
comptime DIM = 4

comptime TEXT1 = "Ada Lovelace works at Acme Labs."
comptime TEXT2 = "Ada Lovelace now mentors Acme Labs."
comptime TEXT3 = "Ada Lovelace gave a talk."
comptime ADA = "Ada Lovelace"
comptime ACME = "Acme Labs"


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


struct BrokenEmbedder(Embedder):
    """Reports DIM; `embed` raises, or returns a vector of `width` components
    (one of which is `big` when `big` is not zero)."""

    var mode: Int  # 0 raises, 1 returns the wrong width, 2 returns a huge value

    def __init__(out self, mode: Int):
        self.mode = mode

    def dimension(self) -> Int:
        return DIM

    def embed(self, text: String) raises -> List[Float64]:
        if self.mode == 0:
            raise Error("embedder down")
        var v = List[Float64]()
        v.append(1.0)
        v.append(0.0)
        v.append(0.0)
        if self.mode == 2:
            v.append(1.0e300)
        return v^

    def embed_batch(self, texts: List[String]) raises -> List[List[Float64]]:
        var out = List[List[Float64]]()
        for _ in range(len(texts)):
            out.append(self.embed(""))
        return out^


def _t(s: String, p: String, o: String, fact: String, valid_at: Int64) -> Triple:
    return Triple(s, p, o, fact, valid_at, TS_OPEN_SENTINEL)


def _ext(fact: String, valid_at: Int64) -> Extraction:
    var ms = List[EntityMention]()
    ms.append(EntityMention(ADA, "", ""))
    ms.append(EntityMention(ACME, "", ""))
    var ts = List[Triple]()
    ts.append(_t(ADA, "rel", ACME, fact, valid_at))
    return Extraction(ms^, ts^)


def _llm() -> StubLlmClient:
    var llm = StubLlmClient()
    llm.add_extraction_any_context(TEXT1, _ext("Ada works at Acme", Int64(10)))
    llm.add_extraction_any_context(TEXT2, _ext("Ada mentors Acme", Int64(50)))
    llm.add_contradiction("Ada mentors Acme", "Ada works at Acme", True)
    return llm^


def _flaky(extract: Bool, same: Bool, contradiction: Bool) -> FlakyLlm:
    return FlakyLlm(_llm(), extract, same, contradiction)


def _vec(a: Float64, b: Float64, c: Float64, d: Float64) -> List[Float64]:
    var v = List[Float64]()
    v.append(a)
    v.append(b)
    v.append(c)
    v.append(d)
    return v^


def _emb() raises -> StubEmbedder:
    var emb = StubEmbedder(DIM)
    emb.add_vector(ADA, _vec(1.0, 0.0, 0.0, 0.0))
    emb.add_vector(ACME, _vec(0.0, 1.0, 0.0, 0.0))
    return emb^


def _ep(uuid: String, body: String, ts: Int64) -> EpisodeInput:
    return EpisodeInput(uuid, "p1", body, ts, ts - Int64(500))


def _seeded() raises -> Kg:
    var kg = Kg(Backend(), "g")
    _ = ingest_episode(
        kg, _ep("ep-1", TEXT1, Int64(1000)), _llm(), _emb(), IngestConfig.default()
    )
    return kg^


def _assert_unchanged(
    kg: Kg, head: Int64, edges: Int, episodes: Int, entities: Int
) raises:
    assert_equal(kg.latest_snapshot_id(), head)
    assert_equal(kg.fingerprint_lookup("p1", "ep-2"), "")
    if head >= 0:
        var ws = SnapshotWorkingSet.load_latest(kg)
        assert_equal(ws.num_edges(), edges)
        assert_equal(ws.num_episodes(), episodes)
        assert_equal(ws.num_entities(), entities)


def test_an_embedder_of_another_dimension_is_refused_before_the_model() raises:
    var kg = _seeded()
    var head = kg.latest_snapshot_id()
    var narrow = StubEmbedder(3)
    # A model that raises on any call: the dimension is checked first.
    with assert_raises(contains="embedder's dimension is 3 but the graph's is 4"):
        _ = ingest_episode(
            kg, _ep("ep-2", TEXT2, Int64(2000)), _flaky(True, True, True),
            narrow, IngestConfig.default(),
        )
    _assert_unchanged(kg, head, 1, 1, 2)


def test_a_write_to_an_empty_set_of_another_dimension_is_refused() raises:
    var kg = Kg(Backend(), "g")
    var ws = SnapshotWorkingSet(DIM)
    with assert_raises(contains="embedder's dimension is 3 but the graph's is 4"):
        _ = ingest_episode_into(
            kg, ws, _ep("ep-2", TEXT2, Int64(2000)), _llm(), StubEmbedder(3),
            IngestConfig.default(),
        )
    _assert_unchanged(kg, Int64(-1), 0, 0, 0)


def test_vectors_of_another_length_are_refused() raises:
    var kg = _seeded()
    var head = kg.latest_snapshot_id()
    with assert_raises(contains="3 components but the graph's dimension is 4"):
        _ = ingest_episode(
            kg, _ep("ep-2", TEXT2, Int64(2000)), _llm(), BrokenEmbedder(1),
            IngestConfig.default(),
        )
    _assert_unchanged(kg, head, 1, 1, 2)
    var fresh = Kg(Backend(), "g")
    with assert_raises(contains="3 components but the graph's dimension is 4"):
        _ = ingest_episode(
            fresh, _ep("ep-2", TEXT2, Int64(2000)), _llm(), BrokenEmbedder(1),
            IngestConfig.default(),
        )
    _assert_unchanged(fresh, Int64(-1), 0, 0, 0)


def _seeded_twice() raises -> Kg:
    var kg = _seeded()
    _ = ingest_episode(
        kg, _ep("ep-2", TEXT2, Int64(2000)), _llm(), _emb(), IngestConfig.default()
    )
    return kg^


def _quiet_llm() -> StubLlmClient:
    # A third text that names a known entity and relates nothing.
    var llm = _llm()
    var ms = List[EntityMention]()
    ms.append(EntityMention(ADA, "", ""))
    llm.add_extraction_any_context(TEXT3, Extraction(ms^, List[Triple]()))
    return llm^


def _assert_untouched(kg: Kg, head: Int64) raises:
    assert_equal(kg.latest_snapshot_id(), head)
    assert_equal(kg.fingerprint_lookup("p1", "ep-3"), "")
    var ws = SnapshotWorkingSet.load_latest(kg)
    assert_equal(ws.num_edges(), 2)
    assert_equal(ws.num_episodes(), 2)
    assert_equal(ws.num_entities(), 2)


def test_a_set_whose_episode_list_shrank_is_an_error_and_writes_nothing() raises:
    var kg = _seeded_twice()
    var head = kg.latest_snapshot_id()
    var ws = SnapshotWorkingSet.load_latest(kg)
    _ = ws.episodes.pop()
    _ = ws.episodes.pop()
    with assert_raises(contains="the episode list shrank"):
        _ = ingest_episode_into(
            kg, ws, _ep("ep-3", TEXT3, Int64(3000)), _quiet_llm(), _emb(),
            IngestConfig.default(),
        )
    _assert_untouched(kg, head)


def test_a_set_whose_edge_list_shrank_is_an_error_and_writes_nothing() raises:
    var kg = _seeded_twice()
    var head = kg.latest_snapshot_id()
    var ws = SnapshotWorkingSet.load_latest(kg)
    _ = ws.edges.pop()
    with assert_raises(contains="the edge list shrank"):
        _ = ingest_episode_into(
            kg, ws, _ep("ep-3", TEXT3, Int64(3000)), _quiet_llm(), _emb(),
            IngestConfig.default(),
        )
    _assert_untouched(kg, head)


def test_a_set_that_lost_a_loaded_entity_is_an_error_and_writes_nothing() raises:
    var kg = _seeded_twice()
    var head = kg.latest_snapshot_id()
    var ws = SnapshotWorkingSet.load_latest(kg)
    _ = ws.entities.pop()
    with assert_raises(contains="was removed since the load"):
        _ = ingest_episode_into(
            kg, ws, _ep("ep-3", TEXT3, Int64(3000)), _quiet_llm(), _emb(),
            IngestConfig.default(),
        )
    _assert_untouched(kg, head)


def test_a_vector_beyond_f32_is_an_error_and_writes_nothing() raises:
    var kg = _seeded_twice()
    var head = kg.latest_snapshot_id()
    # A name nothing in the graph matches, so a new entity gets the vector.
    var llm = _llm()
    var ms = List[EntityMention]()
    ms.append(EntityMention("Zed Quill", "", ""))
    llm.add_extraction_any_context(TEXT3, Extraction(ms^, List[Triple]()))
    with assert_raises(contains="is not a finite f32"):
        _ = ingest_episode(
            kg, _ep("ep-3", TEXT3, Int64(3000)), llm, BrokenEmbedder(2),
            IngestConfig.default(),
        )
    _assert_untouched(kg, head)


def test_a_knob_that_is_not_a_finite_number_in_range_is_refused() raises:
    var kg = _seeded()
    var head = kg.latest_snapshot_id()
    var not_a_number = nan[DType.float64]()
    var infinity = inf[DType.float64]()
    var bad_merge = List[Float64]()
    bad_merge.append(not_a_number)
    bad_merge.append(infinity)
    bad_merge.append(-0.1)
    bad_merge.append(1.5)
    for i in range(len(bad_merge)):
        var cfg = IngestConfig.default()
        cfg.jaccard_merge = bad_merge[i]
        with assert_raises(contains="jaccard_merge must be a finite number"):
            cfg.check()
        cfg = IngestConfig.default()
        cfg.jaccard_escalate = bad_merge[i]
        with assert_raises(contains="jaccard_escalate must be a finite number"):
            cfg.check()
    var bad_entropy = List[Float64]()
    bad_entropy.append(not_a_number)
    bad_entropy.append(infinity)
    bad_entropy.append(-0.5)
    for i in range(len(bad_entropy)):
        var cfg = IngestConfig.default()
        cfg.min_entropy = bad_entropy[i]
        with assert_raises(contains="min_entropy must be a finite number"):
            cfg.check()
    var edge = IngestConfig.default()
    edge.jaccard_merge = 1.0
    edge.jaccard_escalate = 0.0
    edge.min_entropy = 0.0
    edge.check()
    var cfg = IngestConfig.default()
    cfg.jaccard_merge = not_a_number
    with assert_raises(contains="jaccard_merge must be a finite number"):
        _ = ingest_episode(kg, _ep("ep-2", TEXT2, Int64(2000)), _llm(), _emb(), cfg)
    _assert_unchanged(kg, head, 1, 1, 2)


def test_a_knob_no_ingest_can_run_with_is_refused() raises:
    var kg = _seeded()
    var head = kg.latest_snapshot_id()
    var cfg = IngestConfig.default()
    cfg.cosine_k = 0
    with assert_raises(contains="cosine_k must be at least 1"):
        _ = ingest_episode(kg, _ep("ep-2", TEXT2, Int64(2000)), _llm(), _emb(), cfg)
    _assert_unchanged(kg, head, 1, 1, 2)


def test_a_failing_extractor_leaves_the_store_unchanged() raises:
    var kg = _seeded()
    var head = kg.latest_snapshot_id()
    with assert_raises(contains="model down: extract"):
        _ = ingest_episode(
            kg, _ep("ep-2", TEXT2, Int64(2000)), _flaky(True, False, False),
            _emb(), IngestConfig.default(),
        )
    _assert_unchanged(kg, head, 1, 1, 2)
    var fresh = Kg(Backend(), "g")
    with assert_raises(contains="model down: extract"):
        _ = ingest_episode(
            fresh, _ep("ep-2", TEXT2, Int64(2000)), _flaky(True, False, False),
            _emb(), IngestConfig.default(),
        )
    _assert_unchanged(fresh, Int64(-1), 0, 0, 0)


def test_a_failing_embedder_leaves_the_store_unchanged() raises:
    var kg = _seeded()
    var head = kg.latest_snapshot_id()
    with assert_raises(contains="embedder down"):
        _ = ingest_episode(
            kg, _ep("ep-2", TEXT2, Int64(2000)), _llm(), BrokenEmbedder(0),
            IngestConfig.default(),
        )
    _assert_unchanged(kg, head, 1, 1, 2)
    var fresh = Kg(Backend(), "g")
    with assert_raises(contains="embedder down"):
        _ = ingest_episode(
            fresh, _ep("ep-2", TEXT2, Int64(2000)), _llm(), BrokenEmbedder(0),
            IngestConfig.default(),
        )
    _assert_unchanged(fresh, Int64(-1), 0, 0, 0)


def test_a_failing_contradiction_judge_leaves_the_store_unchanged() raises:
    var kg = _seeded()
    var head = kg.latest_snapshot_id()
    with assert_raises(contains="model down: contradiction"):
        _ = ingest_episode(
            kg, _ep("ep-2", TEXT2, Int64(2000)), _flaky(False, False, True),
            _emb(), IngestConfig.default(),
        )
    _assert_unchanged(kg, head, 1, 1, 2)


def test_a_failing_same_entity_judge_leaves_the_store_unchanged() raises:
    # A borderline variant of an existing name goes to the judge, which raises.
    var emb = _emb()
    emb.add_vector("Harbor Alpha Meadow", _vec(0.0, 0.0, 1.0, 0.0))
    emb.add_vector("harbor aypha meadow", _vec(0.0, 0.0, 1.0, 0.0))
    var llm = StubLlmClient()
    var first = List[EntityMention]()
    first.append(EntityMention("Harbor Alpha Meadow", "", ""))
    llm.add_extraction_any_context(TEXT1, Extraction(first^, List[Triple]()))
    var second = List[EntityMention]()
    second.append(EntityMention("harbor aypha meadow", "", ""))
    llm.add_extraction_any_context(TEXT2, Extraction(second^, List[Triple]()))
    var kg = Kg(Backend(), "g")
    _ = ingest_episode(
        kg, _ep("ep-1", TEXT1, Int64(1000)), llm, emb, IngestConfig.default()
    )
    var head = kg.latest_snapshot_id()
    with assert_raises(contains="model down: same entity"):
        _ = ingest_episode(
            kg, _ep("ep-2", TEXT2, Int64(2000)), FlakyLlm(llm^, False, True, False),
            emb, IngestConfig.default(),
        )
    _assert_unchanged(kg, head, 0, 1, 1)


def test_after_a_failure_the_same_episode_ingests_when_the_model_recovers() raises:
    var kg = _seeded()
    var head = kg.latest_snapshot_id()
    with assert_raises(contains="model down: extract"):
        _ = ingest_episode(
            kg, _ep("ep-2", TEXT2, Int64(2000)), _flaky(True, False, False),
            _emb(), IngestConfig.default(),
        )
    var done = ingest_episode(
        kg, _ep("ep-2", TEXT2, Int64(2000)), _llm(), _emb(), IngestConfig.default()
    )
    assert_true(done > head)
    var ws = SnapshotWorkingSet.load_latest(kg)
    assert_equal(ws.num_edges(), 2)
    assert_equal(ws.edges[0].invalid_at, Int64(50))  # the contradiction applied


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
