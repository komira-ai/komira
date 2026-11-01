# =============================================================================
# test_ingest_source_diff.mojo -- a source that replaces its facts: what it
#   closes, what it leaves, and what it need not embed (an in-memory object
#   store, stub model and embedder; no network, no wall clock, no environment).
# =============================================================================
#
#   removal    a source that no longer states a fact closes exactly that source's
#              edge (its end and expiry are the ingest's time, the row stays);
#              another source's identical edge, an untagged ingest's edges and
#              the entities stay; a fact stated again is a new edge; an emptied
#              source closes every edge it held.
#   partition  the same source id in another partition is another source.
#   diff       a re-ingest adds, changes and removes per fact: an unchanged fact
#              keeps its row and its entities are not embedded again, a changed
#              fact is a new edge and its old one is closed, an added fact brings
#              its new entities, a removed one is closed.
#   end times  an end time added to a stated fact replaces the open edge; an ended
#              fact is neither duplicated nor closed again, and keeps its end
#              when the source drops it.
#   supersede  an edge a contradiction closed in the same ingest keeps the end
#              that contradiction gave it.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
)

from komira_kg import (
    Embedder,
    IngestConfig,
    SnapshotWorkingSet,
    StructuredEpisode,
    StubEmbedder,
    StubLlmClient,
    ingest_structured,
    ingest_structured_into,
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
comptime DIM = 6
comptime OPEN = TS_OPEN_SENTINEL

# The facts a test picks from, by number: (subject, object, fact).
#   0 Alder-Birch    1 Alder-Cedar    2 Dogwood-Elm    3 Cedar-Elm
#   4 Alder-Cedar, stated otherwise (the same pair as 1)


def _subject(i: Int) -> String:
    if i == 0 or i == 1 or i == 4:
        return "Alder"
    if i == 2:
        return "Dogwood"
    return "Cedar"


def _object(i: Int) -> String:
    if i == 0:
        return "Birch"
    if i == 1 or i == 4:
        return "Cedar"
    return "Elm"


def _fact(i: Int) -> String:
    if i == 0:
        return "Alder borders Birch"
    if i == 1:
        return "Alder is near Cedar"
    if i == 2:
        return "Dogwood borders Elm"
    if i == 3:
        return "Cedar borders Elm"
    return "Alder is far from Cedar"


struct SelectiveEmbedder(Embedder):
    """A stub embedder that refuses to embed the names it was told to."""

    var inner: StubEmbedder
    var refused: List[String]

    def __init__(out self, var inner: StubEmbedder, var refused: List[String]):
        self.inner = inner^
        self.refused = refused^

    def dimension(self) -> Int:
        return self.inner.dimension()

    def embed(self, text: String) raises -> List[Float64]:
        for i in range(len(self.refused)):
            if self.refused[i] == text:
                raise Error("refused to embed " + text)
        return self.inner.embed(text)

    def embed_batch(self, texts: List[String]) raises -> List[List[Float64]]:
        var out = List[List[Float64]]()
        for i in range(len(texts)):
            out.append(self.embed(texts[i]))
        return out^


def _unit(i: Int) -> List[Float64]:
    var v = List[Float64]()
    for k in range(DIM):
        v.append(1.0 if k == i else 0.0)
    return v^


def _emb() raises -> StubEmbedder:
    var emb = StubEmbedder(DIM)
    emb.add_vector("Alder", _unit(0))
    emb.add_vector("Birch", _unit(1))
    emb.add_vector("Cedar", _unit(2))
    emb.add_vector("Dogwood", _unit(3))
    emb.add_vector("Elm", _unit(4))
    emb.add_vector("Fir", _unit(5))
    return emb^


def _has(names: List[String], name: String) -> Bool:
    for i in range(len(names)):
        if names[i] == name:
            return True
    return False


def _ext(
    facts: List[Int], invalid_at: Int64 = OPEN, extra: String = ""
) -> Extraction:
    var names = List[String]()
    var ts = List[Triple]()
    for k in range(len(facts)):
        var i = facts[k]
        if not _has(names, _subject(i)):
            names.append(_subject(i))
        if not _has(names, _object(i)):
            names.append(_object(i))
        ts.append(Triple(_subject(i), "rel", _object(i), _fact(i), Int64(10), invalid_at))
    if len(extra.as_bytes()) > 0:
        names.append(extra)
    var ms = List[EntityMention]()
    for i in range(len(names)):
        ms.append(EntityMention(names[i], "", ""))
    return Extraction(ms^, ts^)


def _of(*facts: Int) -> List[Int]:
    var out = List[Int]()
    for i in range(len(facts)):
        out.append(facts[i])
    return out^


def _ep(
    uuid: String, source: String, var extraction: Extraction, ts: Int64,
    partition: String = "p1",
) -> StructuredEpisode:
    return StructuredEpisode(
        uuid, partition, extraction^, ts, Int64(0), "", source
    )


def _cfg() -> IngestConfig:
    return IngestConfig.default()


def _ingest(
    mut kg: Kg, var ep: StructuredEpisode, llm: StubLlmClient = StubLlmClient()
) raises:
    _ = ingest_structured(kg, ep^, llm, _emb(), _cfg())


def test_a_source_that_drops_a_fact_closes_exactly_its_edge() raises:
    var kg = Kg(Backend(), "g")
    _ingest(kg, _ep("u1", "doc-1", _ext(_of(0, 1)), Int64(1000)))
    _ingest(kg, _ep("u2", "doc-2", _ext(_of(0)), Int64(2000)))
    _ingest(kg, _ep("u3", "doc-1", _ext(_of(1)), Int64(3000)))
    var ws = SnapshotWorkingSet.load_latest(kg)
    assert_equal(ws.num_entities(), 3)
    assert_equal(ws.num_edges(), 3)
    # doc-1's Alder-Birch: closed, kept, ended and expired at the ingest's time.
    assert_equal(ws.edges[0].source, "doc-1")
    assert_equal(ws.edges[0].fact, _fact(0))
    assert_equal(ws.edges[0].invalid_at, Int64(3000))
    assert_equal(ws.edges[0].expired_at, Int64(3000))
    # doc-1's Alder-Cedar, still stated: untouched.
    assert_equal(ws.edges[1].source, "doc-1")
    assert_equal(ws.edges[1].invalid_at, OPEN)
    assert_equal(ws.edges[1].expired_at, OPEN)
    # doc-2's identical Alder-Birch edge: another source, still open.
    assert_equal(ws.edges[2].source, "doc-2")
    assert_equal(ws.edges[2].fact, _fact(0))
    assert_equal(ws.edges[2].invalid_at, OPEN)
    assert_equal(ws.edges[2].expired_at, OPEN)


def test_no_entity_is_closed_or_removed_by_a_source_dropping_it() raises:
    var kg = Kg(Backend(), "g")
    _ingest(kg, _ep("u1", "doc-1", _ext(_of(0, 1)), Int64(1000)))
    _ingest(kg, _ep("u2", "doc-1", _ext(_of(1)), Int64(2000)))
    var ws = SnapshotWorkingSet.load_latest(kg)
    assert_equal(ws.num_entities(), 3)
    assert_equal(ws.entities[1].name, "Birch")


def test_a_fact_stated_again_after_its_removal_is_a_new_edge_and_history_stays() raises:
    var kg = Kg(Backend(), "g")
    _ingest(kg, _ep("u1", "doc-1", _ext(_of(0, 1)), Int64(1000)))
    _ingest(kg, _ep("u2", "doc-1", _ext(_of(1)), Int64(2000)))
    _ingest(kg, _ep("u3", "doc-1", _ext(_of(0, 1)), Int64(3000)))
    var ws = SnapshotWorkingSet.load_latest(kg)
    assert_equal(ws.num_edges(), 3)
    assert_equal(ws.edges[0].invalid_at, Int64(2000))  # the first, closed
    assert_equal(ws.edges[2].fact, _fact(0))
    assert_equal(ws.edges[2].created_at, Int64(3000))
    assert_equal(ws.edges[2].invalid_at, OPEN)
    assert_equal(ws.edges[1].invalid_at, OPEN)


def test_an_untagged_ingest_never_removes() raises:
    var kg = Kg(Backend(), "g")
    _ingest(kg, _ep("u1", "", _ext(_of(0, 1)), Int64(1000)))
    _ingest(kg, _ep("u2", "", _ext(_of(1)), Int64(2000)))
    var ws = SnapshotWorkingSet.load_latest(kg)
    assert_equal(ws.num_edges(), 2)
    assert_equal(ws.edges[0].invalid_at, OPEN)
    assert_equal(ws.edges[0].source, "")


def test_an_untagged_ingest_leaves_a_sources_edges_alone() raises:
    var kg = Kg(Backend(), "g")
    _ingest(kg, _ep("u1", "doc-1", _ext(_of(0)), Int64(1000)))
    _ingest(kg, _ep("u2", "", _ext(_of(1)), Int64(2000)))
    var ws = SnapshotWorkingSet.load_latest(kg)
    assert_equal(ws.edges[0].invalid_at, OPEN)
    assert_equal(ws.edges[0].expired_at, OPEN)


def test_an_emptied_source_closes_every_edge_it_held() raises:
    var kg = Kg(Backend(), "g")
    _ingest(kg, _ep("u1", "doc-1", _ext(_of(0, 1)), Int64(1000)))
    _ingest(kg, _ep("u2", "doc-1", _ext(_of()), Int64(2000)))
    var ws = SnapshotWorkingSet.load_latest(kg)
    assert_equal(ws.num_edges(), 2)
    for i in range(2):
        assert_equal(ws.edges[i].invalid_at, Int64(2000))
        assert_equal(ws.edges[i].expired_at, Int64(2000))


def test_the_same_source_id_in_another_partition_is_another_source() raises:
    var kg = Kg(Backend(), "g")
    _ingest(kg, _ep("u1", "doc-1", _ext(_of(0)), Int64(1000), "p1"))
    _ingest(kg, _ep("u2", "doc-1", _ext(_of(0)), Int64(2000), "p2"))
    _ingest(kg, _ep("u3", "doc-1", _ext(_of(1)), Int64(3000), "p1"))
    var ws = SnapshotWorkingSet.load_latest(kg)
    assert_equal(ws.num_entities(), 5)  # Alder and Birch in p2 are their own
    assert_equal(ws.num_edges(), 3)
    assert_equal(ws.edges[0].invalid_at, Int64(3000))  # p1's: dropped
    assert_equal(ws.edges[1].invalid_at, OPEN)  # p2's: untouched
    assert_equal(ws.edges[1].expired_at, OPEN)
    assert_equal(ws.edges[2].invalid_at, OPEN)


def test_an_empty_partition_id_sees_the_sources_edges_in_every_partition() raises:
    var kg = Kg(Backend(), "g")
    _ingest(kg, _ep("u1", "doc-1", _ext(_of(0)), Int64(1000), "p1"))
    _ingest(kg, _ep("u2", "doc-1", _ext(_of(1)), Int64(2000), ""))
    var ws = SnapshotWorkingSet.load_latest(kg)
    assert_equal(ws.edges[0].invalid_at, Int64(2000))
    assert_equal(ws.edges[0].expired_at, Int64(2000))


def test_a_reingest_adds_changes_and_removes_per_fact() raises:
    var kg = Kg(Backend(), "g")
    _ingest(kg, _ep("u1", "doc-1", _ext(_of(0, 1, 2)), Int64(1000)))
    # Unchanged: 0. Changed: 1 becomes 4. Added: 3 and a new standalone Fir.
    # Removed: 2. Birch appears only in the unchanged fact, so it must not be
    # embedded again.
    var refused: List[String] = ["Birch"]
    var head = ingest_structured(
        kg,
        _ep("u2", "doc-1", _ext(_of(0, 4, 3), OPEN, "Fir"), Int64(2000)),
        StubLlmClient(),
        SelectiveEmbedder(_emb(), refused^),
        _cfg(),
    )
    assert_equal(kg.latest_snapshot_id(), head)
    var ws = SnapshotWorkingSet.load_latest(kg)
    assert_equal(ws.num_entities(), 6)  # Alder, Birch, Cedar, Dogwood, Elm, Fir
    assert_equal(ws.entities[5].name, "Fir")
    assert_equal(ws.entities[5].name_embedding[5], 1.0)
    assert_equal(ws.num_edges(), 5)
    # 0: unchanged, the very row of the first ingest.
    assert_equal(ws.edges[0].fact, _fact(0))
    assert_equal(ws.edges[0].created_at, Int64(1000))
    assert_equal(ws.edges[0].invalid_at, OPEN)
    # 1: changed away, closed.
    assert_equal(ws.edges[1].fact, _fact(1))
    assert_equal(ws.edges[1].invalid_at, Int64(2000))
    assert_equal(ws.edges[1].expired_at, Int64(2000))
    # 2: removed, closed.
    assert_equal(ws.edges[2].fact, _fact(2))
    assert_equal(ws.edges[2].invalid_at, Int64(2000))
    # 4 (the change) and 3 (the addition): new open edges of this source.
    assert_equal(ws.edges[3].fact, _fact(4))
    assert_equal(ws.edges[3].created_at, Int64(2000))
    assert_equal(ws.edges[3].invalid_at, OPEN)
    assert_equal(ws.edges[3].source, "doc-1")
    assert_equal(ws.edges[4].fact, _fact(3))
    assert_equal(ws.edges[4].invalid_at, OPEN)


def test_an_unchanged_fact_whose_entities_are_new_is_not_skipped() raises:
    # Same fact text, but the graph has no such entities (another partition):
    # it is a change there, so its entities are embedded and its edge added.
    var kg = Kg(Backend(), "g")
    _ingest(kg, _ep("u1", "doc-1", _ext(_of(0)), Int64(1000), "p1"))
    _ingest(kg, _ep("u2", "doc-1", _ext(_of(0, 1)), Int64(2000), "p2"))
    var ws = SnapshotWorkingSet.load_latest(kg)
    assert_equal(ws.num_entities(), 5)
    assert_equal(ws.num_edges(), 3)
    assert_equal(ws.edges[0].invalid_at, OPEN)


def test_a_resident_set_carries_the_closures_in_its_delta() raises:
    var kg = Kg(Backend(), "g")
    var ws = SnapshotWorkingSet(DIM)
    var llm = StubLlmClient()
    var emb = _emb()
    _ = ingest_structured_into(kg, ws, _ep("u1", "doc-1", _ext(_of(0, 1)), Int64(1000)), llm, emb, _cfg())
    _ = ingest_structured_into(kg, ws, _ep("u2", "doc-1", _ext(_of(1)), Int64(2000)), llm, emb, _cfg())
    assert_true(not ws.has_delta())
    assert_equal(ws.edges[0].invalid_at, Int64(2000))
    var reloaded = SnapshotWorkingSet.load_latest(kg)
    assert_equal(reloaded.edges[0].invalid_at, Int64(2000))
    assert_equal(reloaded.edges[0].expired_at, Int64(2000))
    assert_equal(reloaded.edges[1].invalid_at, OPEN)
    assert_equal(kg.open_latest_chain().num_deltas(), 2)


def test_an_end_time_added_to_a_stated_fact_replaces_the_open_edge() raises:
    var kg = Kg(Backend(), "g")
    _ingest(kg, _ep("u1", "doc-1", _ext(_of(0)), Int64(1000)))
    _ingest(kg, _ep("u2", "doc-1", _ext(_of(0), Int64(90)), Int64(2000)))
    var ws = SnapshotWorkingSet.load_latest(kg)
    assert_equal(ws.num_edges(), 2)
    assert_equal(ws.edges[0].invalid_at, Int64(2000))  # no longer stated open
    assert_equal(ws.edges[0].expired_at, Int64(2000))
    assert_equal(ws.edges[1].valid_at, Int64(10))
    assert_equal(ws.edges[1].invalid_at, Int64(90))
    assert_equal(ws.edges[1].expired_at, OPEN)


def test_an_ended_fact_is_not_duplicated_and_keeps_its_end_when_dropped() raises:
    var kg = Kg(Backend(), "g")
    _ingest(kg, _ep("u1", "doc-1", _ext(_of(0), Int64(90)), Int64(1000)))
    # Another fact is added; the ended one is stated as before.
    var both = _ext(_of(0), Int64(90))
    both.triples.append(Triple("Alder", "rel", "Cedar", _fact(1), Int64(10), OPEN))
    both.entities.append(EntityMention("Cedar", "", ""))
    _ingest(kg, _ep("u2", "doc-1", both^, Int64(2000)))
    var ws = SnapshotWorkingSet.load_latest(kg)
    assert_equal(ws.num_edges(), 2)
    assert_equal(ws.edges[0].invalid_at, Int64(90))
    assert_equal(ws.edges[0].expired_at, OPEN)
    # The source drops the ended fact: it keeps its end and is expired.
    _ingest(kg, _ep("u3", "doc-1", _ext(_of(1)), Int64(3000)))
    var after = SnapshotWorkingSet.load_latest(kg)
    assert_equal(after.num_edges(), 2)
    assert_equal(after.edges[0].invalid_at, Int64(90))
    assert_equal(after.edges[0].expired_at, Int64(3000))
    assert_equal(after.edges[1].expired_at, OPEN)


def test_an_edge_a_contradiction_closed_keeps_the_end_it_was_given() raises:
    var kg = Kg(Backend(), "g")
    _ingest(kg, _ep("u1", "doc-1", _ext(_of(1)), Int64(1000)))
    var llm = StubLlmClient()
    llm.add_contradiction(_fact(4), _fact(1), True)
    var changed = _ext(_of(4))
    changed.triples[0].valid_at = Int64(50)
    _ingest(kg, _ep("u2", "doc-1", changed^, Int64(2000)), llm^)
    var ws = SnapshotWorkingSet.load_latest(kg)
    assert_equal(ws.num_edges(), 2)
    # Closed by the contradiction at the new fact's start, not by the removal.
    assert_equal(ws.edges[0].invalid_at, Int64(50))
    assert_equal(ws.edges[0].expired_at, Int64(2000))
    assert_equal(ws.edges[1].invalid_at, OPEN)


def test_a_fact_restated_under_a_judged_variant_name_is_kept_not_closed() raises:
    # The variant is not an exact name, so the per-symbol diff cannot call the
    # fact unchanged; the resolver judges it to be the same entity, the fact is
    # the source's open edge again, and the removal must leave that edge be.
    var kg = Kg(Backend(), "g")
    var emb = _emb()
    emb.add_vector("Harbor Alpha Meadow", _unit(0))
    emb.add_vector("harbor aypha meadow", _unit(0))
    var llm = StubLlmClient()
    llm.add_same_entity("harbor aypha meadow", "Harbor Alpha Meadow", True)
    var first = List[EntityMention]()
    first.append(EntityMention("Harbor Alpha Meadow", "", ""))
    first.append(EntityMention("Birch", "", ""))
    var first_ts = List[Triple]()
    first_ts.append(Triple("Harbor Alpha Meadow", "rel", "Birch", "Harbor borders Birch", Int64(10), OPEN))
    _ = ingest_structured(kg, _ep("u1", "doc-1", Extraction(first^, first_ts^), Int64(1000)), llm, emb, _cfg())
    var again = List[EntityMention]()
    again.append(EntityMention("harbor aypha meadow", "", ""))
    again.append(EntityMention("Birch", "", ""))
    var again_ts = List[Triple]()
    again_ts.append(Triple("harbor aypha meadow", "rel", "Birch", "Harbor borders Birch", Int64(10), OPEN))
    _ = ingest_structured(kg, _ep("u2", "doc-1", Extraction(again^, again_ts^), Int64(2000)), llm, emb, _cfg())
    var ws = SnapshotWorkingSet.load_latest(kg)
    assert_equal(ws.num_entities(), 2)
    assert_equal(ws.num_edges(), 1)
    assert_equal(ws.edges[0].invalid_at, OPEN)
    assert_equal(ws.edges[0].expired_at, OPEN)


def test_a_fact_stated_open_and_ended_is_two_edges_and_both_stay_on_a_repeat() raises:
    var kg = Kg(Backend(), "g")
    var both = _ext(_of(0))
    both.triples.append(
        Triple(_subject(0), "rel", _object(0), _fact(0), Int64(10), Int64(90))
    )
    var again = _ext(_of(0))
    again.triples.append(
        Triple(_subject(0), "rel", _object(0), _fact(0), Int64(10), Int64(90))
    )
    _ingest(kg, _ep("u1", "doc-1", both^, Int64(1000)))
    var ws = SnapshotWorkingSet.load_latest(kg)
    assert_equal(ws.num_edges(), 2)
    # The same two assertions again: nothing is added, nothing is closed.
    _ingest(kg, _ep("u2", "doc-1", again^, Int64(2000)))
    var after = SnapshotWorkingSet.load_latest(kg)
    assert_equal(after.num_edges(), 2)
    assert_equal(after.edges[0].expired_at, OPEN)
    assert_equal(after.edges[1].expired_at, OPEN)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
