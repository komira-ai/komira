# =============================================================================
# test_ingest_episode.mojo -- ingest one episode into a snapshot store (an
#   in-memory object store, a stub model and embedder; no network, no wall
#   clock, no environment).
# =============================================================================
#
#   one episode  the nodes, edges and provenance row it produces, read back from
#                the store; the name index and embedding projection a new
#                lineage carries.
#   unchanged    the same body under the same source id is skipped without a
#                model call; another source id with the same body is ingested but
#                adds neither entities nor a repeated edge; a changed body is
#                ingested.
#   partitions   the same names in another partition are other entities.
#   resident     a set held across episodes writes each episode's delta alone.
#   context      the known entities of the partition are given to the extract
#                only when asked, at most the cap, the newest, of its own
#                partition; a triple may name an entity a changed piece does not
#                mention.
#   full base    a closure a delta cannot say (two open edges with one key) is
#                written as a new base with its index; a head that moved
#                meanwhile is refused.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_raises,
    assert_true,
)

from komira_collections.slab import Slab
from komira_kg import (
    CROSS_UNIT_CONTEXT_MAX,
    EpisodeInput,
    IngestConfig,
    LlmClient,
    SnapshotWorkingSet,
    StubEmbedder,
    StubLlmClient,
    WorkingEntity,
    facet_attrs_json,
    ingest_episode,
    ingest_episode_into,
    resolve_embedding_topk,
)
from komira_kg_format import (
    EntityMention,
    Extraction,
    KgNameIndexBody,
    KgSnapshotStore,
    KgTable,
    TS_OPEN_SENTINEL,
    Triple,
    content_hash_of,
)
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

comptime Backend = SharedInMemoryConditionalStore
comptime Kg = KgSnapshotStore[SharedInMemoryConditionalStore]
comptime DIM = 4

comptime TEXT1 = "Ada Lovelace works at Acme Labs."
comptime TEXT2 = "Ada Lovelace hired Bolt Co."
comptime ADA = "Ada Lovelace"
comptime ACME = "Acme Labs"
comptime BOLT = "Bolt Co"


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
    emb.add_vector(BOLT, _vec(0.0, 0.0, 1.0, 0.0))
    return emb^


def _t(s: String, p: String, o: String, fact: String, valid_at: Int64) -> Triple:
    return Triple(s, p, o, fact, valid_at, TS_OPEN_SENTINEL)


def _ext1() -> Extraction:
    var ms = List[EntityMention]()
    ms.append(EntityMention(ADA, "person", "an analyst"))
    ms.append(EntityMention(ACME, "org", ""))
    var ts = List[Triple]()
    ts.append(_t(ADA, "works_at", ACME, "Ada Lovelace works at Acme Labs", Int64(100)))
    return Extraction(ms^, ts^)


def _ext2() -> Extraction:
    var ms = List[EntityMention]()
    ms.append(EntityMention(BOLT, "org", ""))
    var ts = List[Triple]()
    ts.append(_t(ADA, "hired", BOLT, "Ada Lovelace hired Bolt Co", Int64(200)))
    return Extraction(ms^, ts^)


def _llm() -> StubLlmClient:
    var llm = StubLlmClient()
    llm.add_extraction_any_context(TEXT1, _ext1())
    llm.add_extraction_any_context(TEXT2, _ext2())
    return llm^


def _ep(uuid: String, body: String, ts: Int64) -> EpisodeInput:
    return EpisodeInput(uuid, "p1", body, ts, ts - Int64(500))


def _cfg() -> IngestConfig:
    return IngestConfig.default()


def test_an_episode_produces_its_nodes_edges_and_provenance() raises:
    var kg = Kg(Backend(), "g")
    var ep = EpisodeInput("ep-1", "p1", TEXT1, Int64(1000), Int64(500), "chat", "src-1")
    var head = ingest_episode(kg, ep, _llm(), _emb(), _cfg())
    assert_true(head >= 0)
    assert_equal(kg.latest_snapshot_id(), head)

    var ws = SnapshotWorkingSet.load_latest(kg)
    assert_equal(ws.embedding_dim, DIM)
    assert_equal(ws.num_entities(), 2)
    ref ada = ws.entities[0]
    assert_equal(ada.nid, Int64(0))
    assert_equal(ada.uuid, "p1:0")
    assert_equal(ada.partition_id, "p1")
    assert_equal(ada.name, ADA)
    assert_equal(ada.summary, "an analyst")
    assert_equal(ada.attrs, facet_attrs_json("chat", "src-1"))
    assert_equal(ada.name_embedding[0], 1.0)
    assert_equal(len(ada.name_embedding), DIM)
    ref acme = ws.entities[1]
    assert_equal(acme.nid, Int64(1))
    assert_equal(acme.name, ACME)
    assert_equal(acme.summary, "")
    assert_equal(acme.name_embedding[1], 1.0)

    assert_equal(ws.num_edges(), 1)
    ref e = ws.edges[0]
    assert_equal(e.src_nid, Int64(0))
    assert_equal(e.dst_nid, Int64(1))
    assert_equal(e.predicate, "")  # the edges table stores no predicate
    assert_equal(e.fact, "Ada Lovelace works at Acme Labs")
    assert_equal(e.valid_at, Int64(100))
    assert_equal(e.invalid_at, TS_OPEN_SENTINEL)
    assert_equal(e.expired_at, TS_OPEN_SENTINEL)
    assert_equal(e.created_at, Int64(1000))
    assert_equal(e.reference_time, Int64(500))

    assert_equal(ws.num_episodes(), 1)
    ref row = ws.episodes[0]
    assert_equal(row.uuid, "ep-1")
    assert_equal(row.partition_id, "p1")
    assert_equal(row.body, TEXT1)
    assert_equal(row.ts, Int64(1000))
    assert_equal(row.valid_at, Int64(500))
    assert_equal(row.facet, "chat")

    assert_equal(kg.fingerprint_lookup("p1", "ep-1"), content_hash_of(TEXT1))


def test_an_episode_without_a_facet_leaves_the_attrs_and_facet_empty() raises:
    var kg = Kg(Backend(), "g")
    _ = ingest_episode(kg, _ep("ep-1", TEXT1, Int64(1000)), _llm(), _emb(), _cfg())
    var ws = SnapshotWorkingSet.load_latest(kg)
    assert_equal(ws.entities[0].attrs, "{}")
    assert_equal(ws.episodes[0].facet, "")


def test_a_new_lineage_is_indexed_for_the_nearest_entity_read() raises:
    var kg = Kg(Backend(), "g")
    _ = ingest_episode(kg, _ep("ep-1", TEXT1, Int64(1000)), _llm(), _emb(), _cfg())
    var chain = kg.open_latest_chain()
    assert_equal(chain.num_deltas(), 1)
    var near = resolve_embedding_topk(chain, _vec(0.0, 1.0, 0.0, 0.0), 1)
    assert_equal(len(near), 1)
    assert_equal(near[0].nid, Int64(1))


def test_a_second_episode_appends_a_delta_and_joins_the_first() raises:
    var kg = Kg(Backend(), "g")
    var first = ingest_episode(kg, _ep("ep-1", TEXT1, Int64(1000)), _llm(), _emb(), _cfg())
    var second = ingest_episode(kg, _ep("ep-2", TEXT2, Int64(2000)), _llm(), _emb(), _cfg())
    assert_true(second > first)
    var ws = SnapshotWorkingSet.load_latest(kg)
    assert_equal(ws.num_entities(), 3)  # Ada resolved to the first episode's
    assert_equal(ws.entities[2].name, BOLT)
    assert_equal(ws.num_edges(), 2)
    assert_equal(ws.edges[1].src_nid, Int64(0))
    assert_equal(ws.edges[1].dst_nid, Int64(2))
    assert_equal(ws.num_episodes(), 2)
    assert_equal(ws.episodes[1].uuid, "ep-2")


def test_an_unchanged_body_is_skipped_without_a_model_call() raises:
    var kg = Kg(Backend(), "g")
    var head = ingest_episode(kg, _ep("ep-1", TEXT1, Int64(1000)), _llm(), _emb(), _cfg())
    # A model with nothing registered would extract nothing; the head must come
    # back untouched and the graph as it was, with the fingerprint in place.
    var again = ingest_episode(
        kg, _ep("ep-1", TEXT1, Int64(3000)), StubLlmClient(), _emb(), _cfg()
    )
    assert_equal(again, head)
    assert_equal(kg.latest_snapshot_id(), head)
    var ws = SnapshotWorkingSet.load_latest(kg)
    assert_equal(ws.num_episodes(), 1)
    assert_equal(ws.num_edges(), 1)


def test_the_same_body_under_another_source_adds_no_entity_or_repeat_edge() raises:
    var kg = Kg(Backend(), "g")
    var head = ingest_episode(kg, _ep("ep-1", TEXT1, Int64(1000)), _llm(), _emb(), _cfg())
    var llm = _llm()
    var other = ingest_episode(kg, _ep("ep-9", TEXT1, Int64(2000)), llm, _emb(), _cfg())
    assert_true(other > head)
    var ws = SnapshotWorkingSet.load_latest(kg)
    assert_equal(ws.num_entities(), 2)
    assert_equal(ws.num_edges(), 1)
    assert_equal(ws.num_episodes(), 2)
    assert_equal(ws.episodes[1].uuid, "ep-9")
    assert_equal(kg.fingerprint_lookup("p1", "ep-9"), content_hash_of(TEXT1))


def test_a_changed_body_under_the_same_source_is_ingested() raises:
    var kg = Kg(Backend(), "g")
    var head = ingest_episode(kg, _ep("ep-1", TEXT1, Int64(1000)), _llm(), _emb(), _cfg())
    var changed = ingest_episode(kg, _ep("ep-1", TEXT2, Int64(2000)), _llm(), _emb(), _cfg())
    assert_true(changed > head)
    assert_equal(kg.fingerprint_lookup("p1", "ep-1"), content_hash_of(TEXT2))
    var ws = SnapshotWorkingSet.load_latest(kg)
    assert_equal(ws.num_entities(), 3)
    assert_equal(ws.num_episodes(), 2)
    # The first body is a change again now.
    var back = ingest_episode(kg, _ep("ep-1", TEXT1, Int64(3000)), _llm(), _emb(), _cfg())
    assert_true(back > changed)


def test_the_same_names_in_another_partition_are_other_entities() raises:
    var kg = Kg(Backend(), "g")
    _ = ingest_episode(kg, _ep("ep-1", TEXT1, Int64(1000)), _llm(), _emb(), _cfg())
    var elsewhere = EpisodeInput("ep-1", "p2", TEXT1, Int64(2000), Int64(1500))
    _ = ingest_episode(kg, elsewhere, _llm(), _emb(), _cfg())
    var ws = SnapshotWorkingSet.load_latest(kg)
    assert_equal(ws.num_entities(), 4)
    assert_equal(ws.entities[2].partition_id, "p2")
    assert_equal(ws.num_edges(), 2)
    assert_equal(ws.edges[1].src_nid, Int64(2))
    assert_equal(ws.edges[1].dst_nid, Int64(3))


def test_a_resident_set_writes_each_episodes_delta_alone() raises:
    var kg = Kg(Backend(), "g")
    var ws = SnapshotWorkingSet(DIM)
    var llm = _llm()
    var emb = _emb()
    _ = ingest_episode_into(kg, ws, _ep("ep-1", TEXT1, Int64(1000)), llm, emb, _cfg())
    assert_true(not ws.has_delta())
    _ = ingest_episode_into(kg, ws, _ep("ep-2", TEXT2, Int64(2000)), llm, emb, _cfg())
    assert_true(not ws.has_delta())
    assert_equal(ws.num_entities(), 3)
    assert_equal(ws.num_edges(), 2)
    assert_equal(ws.num_episodes(), 2)
    # What the store holds is what the set holds: no row of the first episode was
    # written a second time.
    var reloaded = SnapshotWorkingSet.load_latest(kg)
    assert_equal(reloaded.num_entities(), 3)
    assert_equal(reloaded.num_edges(), 2)
    assert_equal(reloaded.num_episodes(), 2)


def test_the_context_is_given_to_the_extract_only_when_asked() raises:
    var kg = Kg(Backend(), "g")
    _ = ingest_episode(kg, _ep("ep-1", TEXT1, Int64(1000)), _llm(), _emb(), _cfg())
    # The model answers this text only when it is told of the two known entities.
    var llm = StubLlmClient()
    llm.add_extraction(TEXT2, 2, _ext2())

    var plain = ingest_episode(kg, _ep("ep-2", TEXT2, Int64(2000)), llm, _emb(), _cfg())
    assert_equal(SnapshotWorkingSet.load_latest(kg).num_entities(), 2)

    var cfg = _cfg()
    cfg.cross_unit_context = True
    var grounded = ingest_episode(kg, _ep("ep-3", TEXT2, Int64(3000)), llm, _emb(), cfg)
    assert_true(grounded > plain)
    var ws = SnapshotWorkingSet.load_latest(kg)
    # Bolt is new; Ada, which the changed text does not list as a mention, is the
    # existing node, and the known entities were not re-emitted as new ones.
    assert_equal(ws.num_entities(), 3)
    assert_equal(ws.edges[len(ws.edges) - 1].src_nid, Int64(0))
    assert_equal(ws.edges[len(ws.edges) - 1].dst_nid, Int64(2))


struct SeedCheckLlm(LlmClient):
    """Extracts one new mention, and raises unless `already_found` is the 256
    newest entities of partition p1 (E299 down to E44) and none of the others."""

    def __init__(out self):
        pass

    def extract(
        self, text: String, already_found: List[EntityMention]
    ) raises -> Extraction:
        if len(already_found) == CROSS_UNIT_CONTEXT_MAX + 1:
            # The gleaning pass: the seed and the one mention found so far.
            return Extraction()
        if len(already_found) != CROSS_UNIT_CONTEXT_MAX:
            raise Error("seed size " + String(len(already_found)))
        for i in range(len(already_found)):
            var name = already_found[i].name
            if name == "E0" or name == "E43" or name.startswith("Other"):
                raise Error("seed holds " + name)
        var has_newest = False
        for i in range(len(already_found)):
            if already_found[i].name == "E299":
                has_newest = True
        if not has_newest:
            raise Error("seed lacks the newest entity")
        var ms = List[EntityMention]()
        ms.append(EntityMention("Fresh", "", ""))
        return Extraction(ms^, List[Triple]())

    def judge_contradiction(self, new_fact: String, old_fact: String) raises -> Bool:
        return False

    def judge_same_entity(
        self, name_a: String, summary_a: String, name_b: String, summary_b: String
    ) raises -> Bool:
        return False

    def has_synthesis(self) -> Bool:
        return False

    def synthesize(self, system_prompt: String, user_prompt: String) raises -> String:
        raise Error("none")


def test_the_context_is_the_newest_entities_of_the_partition_up_to_the_cap() raises:
    var kg = Kg(Backend(), "g")
    var ws = SnapshotWorkingSet(DIM)
    for i in range(300):
        ws.add_entity(
            WorkingEntity(
                ws.next_nid(), "u" + String(i), "p1", "E" + String(i),
                _vec(0.0, 0.0, 0.0, 1.0), "", "{}",
            )
        )
    for i in range(3):
        ws.add_entity(
            WorkingEntity(
                ws.next_nid(), "o" + String(i), "p2", "Other" + String(i),
                _vec(0.0, 0.0, 0.0, 1.0), "", "{}",
            )
        )
    var cfg = _cfg()
    cfg.cross_unit_context = True
    _ = ingest_episode_into(
        kg, ws, _ep("ep-1", "any text", Int64(1000)), SeedCheckLlm(), _emb(), cfg
    )
    assert_equal(ws.num_entities(), 304)
    assert_equal(ws.entities[303].name, "Fresh")


def _two_open_edges_one_key(mut kg: Kg) raises:
    """Episode 1 states two facts about one pair at one time: two open edges that
    share the key a tombstone closes by."""
    var llm = StubLlmClient()
    var ms = List[EntityMention]()
    ms.append(EntityMention(ADA, "", ""))
    ms.append(EntityMention(ACME, "", ""))
    var ts = List[Triple]()
    ts.append(_t(ADA, "mentors", ACME, "Ada mentors Acme", Int64(10)))
    ts.append(_t(ADA, "manages", ACME, "Ada manages Acme", Int64(10)))
    llm.add_extraction_any_context(TEXT1, Extraction(ms^, ts^))
    _ = ingest_episode(kg, _ep("ep-1", TEXT1, Int64(1000)), llm, _emb(), _cfg())


def _ends_mentoring() -> StubLlmClient:
    var llm = StubLlmClient()
    var ms = List[EntityMention]()
    ms.append(EntityMention(ADA, "", ""))
    ms.append(EntityMention(ACME, "", ""))
    var ts = List[Triple]()
    ts.append(_t(ADA, "mentors", ACME, "Ada no longer mentors Acme", Int64(50)))
    llm.add_extraction_any_context(TEXT2, Extraction(ms^, ts^))
    llm.add_contradiction("Ada no longer mentors Acme", "Ada mentors Acme", True)
    return llm^


def test_a_closure_a_delta_cannot_say_is_written_as_a_new_base_with_its_index() raises:
    var kg = Kg(Backend(), "g")
    _two_open_edges_one_key(kg)
    var base_before = kg.open_latest_chain().base_id()

    _ = ingest_episode(kg, _ep("ep-2", TEXT2, Int64(2000)), _ends_mentoring(), _emb(), _cfg())

    var chain = kg.open_latest_chain()
    assert_true(chain.base_id() != base_before)
    assert_equal(chain.num_deltas(), 1)  # the index bootstrap of the new base
    var ws = SnapshotWorkingSet.load_latest(kg)
    assert_equal(ws.num_edges(), 3)
    assert_equal(ws.edges[0].fact, "Ada mentors Acme")
    assert_equal(ws.edges[0].invalid_at, Int64(50))
    assert_equal(ws.edges[0].expired_at, Int64(2000))
    assert_equal(ws.edges[1].fact, "Ada manages Acme")
    assert_equal(ws.edges[1].invalid_at, TS_OPEN_SENTINEL)
    assert_equal(ws.edges[2].fact, "Ada no longer mentors Acme")
    assert_equal(ws.num_episodes(), 2)
    var near = resolve_embedding_topk(chain, _vec(1.0, 0.0, 0.0, 0.0), 1)
    assert_equal(near[0].nid, Int64(0))


struct MovingHeadLlm(LlmClient):
    """A model whose contradiction judgment lets another writer append a delta,
    so the head moves while the ingest is running."""

    var inner: StubLlmClient
    var backend: Backend

    def __init__(out self, var inner: StubLlmClient, var backend: Backend):
        self.inner = inner^
        self.backend = backend^

    def extract(
        self, text: String, already_found: List[EntityMention]
    ) raises -> Extraction:
        return self.inner.extract(text, already_found)

    def judge_contradiction(self, new_fact: String, old_fact: String) raises -> Bool:
        var other = Kg(self.backend.clone(), "g")
        var names = KgNameIndexBody()
        names.add("ada lovelace", Int64(0))
        _ = other.append_delta(Slab[KgTable](), names^)
        return self.inner.judge_contradiction(new_fact, old_fact)

    def judge_same_entity(
        self, name_a: String, summary_a: String, name_b: String, summary_b: String
    ) raises -> Bool:
        return False

    def has_synthesis(self) -> Bool:
        return False

    def synthesize(self, system_prompt: String, user_prompt: String) raises -> String:
        raise Error("none")


def test_a_head_that_moved_while_a_full_base_was_needed_is_refused() raises:
    var backend = Backend()
    var kg = Kg(backend.clone(), "g")
    _two_open_edges_one_key(kg)
    var head = kg.latest_snapshot_id()
    var llm = MovingHeadLlm(_ends_mentoring(), backend.clone())
    with assert_raises(contains="the head moved"):
        _ = ingest_episode(kg, _ep("ep-2", TEXT2, Int64(2000)), llm, _emb(), _cfg())
    # The other writer's delta is the head; nothing of ours was written.
    assert_true(kg.latest_snapshot_id() > head)
    var ws = SnapshotWorkingSet.load_latest(kg)
    assert_equal(ws.num_edges(), 2)
    assert_equal(ws.num_episodes(), 1)
    assert_equal(kg.fingerprint_lookup("p1", "ep-2"), "")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
