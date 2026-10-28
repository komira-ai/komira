# =============================================================================
# test_surface_adapter.mojo -- the SurfaceAdapter seam, against made-up record
#   types (an in-memory object store, stub model and embedder; no network, no
#   wall clock, no environment). The package ships no adapter; the two here live
#   in the test.
# =============================================================================
#
#   lowering   a record lowers to the expected episodes: ids, partition, times,
#              facet and order; the same record lowers to the same episodes;
#              a record that cannot be lowered is refused.
#   verbatim   the text a record carries reaches the episode body byte for byte
#              (tabs, trailing spaces, non-ASCII), is what the model is asked
#              about, and is what the provenance row stores.
#   gate       lowering a record again and ingesting its episodes is a no-op.
#   seam       two adapters of different record types satisfy the one trait and
#              are used through one generic function.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_raises,
    assert_true,
)

from komira_kg import (
    EpisodeInput,
    IngestConfig,
    SnapshotWorkingSet,
    StubEmbedder,
    StubLlmClient,
    SurfaceAdapter,
    ingest_episode,
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


@fieldwise_init
struct Ledger(Movable):
    """A made-up record: an id, the day it describes, when it arrived and its
    lines of text."""

    var id: String
    var day: Int64
    var received_at: Int64
    var lines: List[String]


@fieldwise_init
struct LedgerAdapter(SurfaceAdapter):
    """Lowers a `Ledger` to episodes of at most `max_lines` lines. Each body is
    a header line and then the lines, joined by newlines, unaltered."""

    var max_lines: Int

    comptime Source = Ledger

    def lower(
        self, var source: Ledger, partition_id: String
    ) raises -> List[EpisodeInput]:
        if len(source.lines) == 0:
            raise Error("ledger " + source.id + " has no lines")
        var out = List[EpisodeInput]()
        var at = 0
        var n = 0
        while at < len(source.lines):
            var body = "ledger " + source.id + "\n"
            var stop = min(at + self.max_lines, len(source.lines))
            for i in range(at, stop):
                if i > at:
                    body += "\n"
                body += source.lines[i]
            out.append(
                EpisodeInput(
                    source.id + "#" + String(n),
                    partition_id,
                    body^,
                    source.received_at,
                    source.day,
                    "ledger",
                    source.id,
                )
            )
            at = stop
            n += 1
        return out^


@fieldwise_init
struct Note(Movable):
    """A second made-up record: one piece of text."""

    var text: String


@fieldwise_init
struct NoteAdapter(SurfaceAdapter):
    """Lowers a `Note` to its one episode."""

    comptime Source = Note

    def lower(
        self, var source: Note, partition_id: String
    ) raises -> List[EpisodeInput]:
        var out = List[EpisodeInput]()
        out.append(EpisodeInput("note", partition_id, source.text.copy(), Int64(7), Int64(6)))
        return out^


def _lower_with[
    A: SurfaceAdapter
](adapter: A, var source: A.Source, partition_id: String) raises -> List[EpisodeInput]:
    return adapter.lower(source^, partition_id)


def _ledger(lines: List[String]) -> Ledger:
    return Ledger("L1", Int64(40), Int64(900), lines.copy())


def _five() -> List[String]:
    return ["Alder borders Birch", "Birch\tfaces Cedar ", "Cedar is near Dogwood", "Dogwood is café-side", "Elm"]


def test_a_record_lowers_to_the_expected_episodes() raises:
    var eps = LedgerAdapter(2).lower(_ledger(_five()), "p9")
    assert_equal(len(eps), 3)
    assert_equal(eps[0].uuid, "L1#0")
    assert_equal(eps[1].uuid, "L1#1")
    assert_equal(eps[2].uuid, "L1#2")
    assert_equal(eps[0].body, "ledger L1\nAlder borders Birch\nBirch\tfaces Cedar ")
    assert_equal(eps[1].body, "ledger L1\nCedar is near Dogwood\nDogwood is café-side")
    assert_equal(eps[2].body, "ledger L1\nElm")
    for i in range(3):
        assert_equal(eps[i].partition_id, "p9")
        assert_equal(eps[i].ts, Int64(900))
        assert_equal(eps[i].valid_at, Int64(40))
        assert_equal(eps[i].facet, "ledger")
        assert_equal(eps[i].facet_source, "L1")


def test_the_same_record_lowers_to_the_same_episodes() raises:
    var a = LedgerAdapter(2).lower(_ledger(_five()), "p1")
    var b = LedgerAdapter(2).lower(_ledger(_five()), "p1")
    assert_equal(len(a), len(b))
    for i in range(len(a)):
        assert_equal(a[i].uuid, b[i].uuid)
        assert_equal(a[i].body, b[i].body)


def test_a_record_that_cannot_be_lowered_is_refused() raises:
    with assert_raises(contains="ledger L1 has no lines"):
        _ = LedgerAdapter(2).lower(_ledger(List[String]()), "p1")


def test_two_adapters_of_different_records_satisfy_the_one_trait() raises:
    var ledger = _lower_with(LedgerAdapter(10), _ledger(_five()), "p1")
    var note = _lower_with(NoteAdapter(), Note("a plain note"), "p1")
    assert_equal(len(ledger), 1)
    assert_equal(len(note), 1)
    assert_equal(note[0].body, "a plain note")
    assert_equal(note[0].partition_id, "p1")


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
    return emb^


def _answers(eps: List[EpisodeInput]) raises -> StubLlmClient:
    """A model that answers the exact text of the first two episodes only."""
    var llm = StubLlmClient()
    var first = List[EntityMention]()
    first.append(EntityMention("Alder", "", ""))
    first.append(EntityMention("Birch", "", ""))
    var t1 = List[Triple]()
    t1.append(Triple("Alder", "rel", "Birch", "Alder borders Birch", Int64(40), TS_OPEN_SENTINEL))
    llm.add_extraction_any_context(eps[0].body, Extraction(first^, t1^))
    var second = List[EntityMention]()
    second.append(EntityMention("Cedar", "", ""))
    second.append(EntityMention("Dogwood", "", ""))
    var t2 = List[Triple]()
    t2.append(Triple("Cedar", "rel", "Dogwood", "Cedar is near Dogwood", Int64(40), TS_OPEN_SENTINEL))
    llm.add_extraction_any_context(eps[1].body, Extraction(second^, t2^))
    return llm^


def test_the_verbatim_text_reaches_the_model_and_the_episode_row_unchanged() raises:
    var eps = LedgerAdapter(2).lower(_ledger(_five()), "p1")
    var kg = Kg(Backend(), "g")
    var llm = _answers(eps)
    for i in range(len(eps)):
        _ = ingest_episode(kg, eps[i], llm, _emb(), IngestConfig.default())
    var ws = SnapshotWorkingSet.load_latest(kg)
    # The model answers only the exact bodies: both of its facts are in the graph.
    assert_equal(ws.num_edges(), 2)
    assert_equal(ws.num_episodes(), 3)
    for i in range(3):
        assert_equal(ws.episodes[i].uuid, eps[i].uuid)
        assert_equal(ws.episodes[i].body, eps[i].body)
        assert_equal(ws.episodes[i].facet, "ledger")
    assert_equal(ws.episodes[0].body, "ledger L1\nAlder borders Birch\nBirch\tfaces Cedar ")


def test_lowering_a_record_again_and_ingesting_it_is_a_no_op() raises:
    var eps = LedgerAdapter(2).lower(_ledger(_five()), "p1")
    var kg = Kg(Backend(), "g")
    var llm = _answers(eps)
    for i in range(len(eps)):
        _ = ingest_episode(kg, eps[i], llm, _emb(), IngestConfig.default())
    var head = kg.latest_snapshot_id()
    var again = LedgerAdapter(2).lower(_ledger(_five()), "p1")
    for i in range(len(again)):
        _ = ingest_episode(kg, again[i], StubLlmClient(), _emb(), IngestConfig.default())
    assert_equal(kg.latest_snapshot_id(), head)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
