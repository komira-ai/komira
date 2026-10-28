# =============================================================================
# test_b_index.mojo -- BIndex over a raw store, through two registered adapters
#   for made-up record types (a journal of dated lines and a card of free text),
#   an in-memory object store and a stub embedder. No network, no wall clock, no
#   environment.
# =============================================================================
#
#   same top-k    over eight episodes lowered from five raw records of the two
#                 kinds, the index returns the same episodes in the same order as
#                 a plain scan (a score for every episode, a full selection) for
#                 four queries (one with negative scores) at several k, k larger
#                 than the corpus included, and the same through `search`; each
#                 hit names its raw record, position, uuid, tag, time and score.
#   ties          equal scores come back raw key ascending, then position, whatever
#                 order the records were put in.
#   build         a first build indexes every record and embeds each episode once;
#                 a second embeds nothing; a record added later is indexed alone; a
#                 record under a tag with no adapter, and one that lowers to no
#                 episode, are skipped and counted; bytes put under two tags are
#                 one record, indexed under the first tag; an adapter that cannot
#                 read a record stops the build and keeps what was indexed.
#   embedder      a dimension other than the index's, a wrong number of vectors, a
#                 vector of the wrong width and a non-finite component (including
#                 one that overflows f32) are refused and nothing is written.
#   query         k below one, a query of the wrong size or with a non-finite
#                 component are refused; an empty index answers with no hit.
#   race          a builder that loses to another writer of the same record leaves
#                 the winner's rows and counts the record as existing; a store
#                 failure is raised.
#   episode_of    a hit maps back to the episode the registry lowers its record
#                 to; a gone record, a tag with no adapter, a position past the end
#                 and a uuid that no longer matches are refused.
#   shape         a prefix that is not acceptable and a dimension below one are
#                 refused; an index opened with another dimension refuses the
#                 stored rows; a stray object in the index directory is reported.
# =============================================================================

from std.math import sqrt
from std.memory import ArcPointer
from std.testing import (
    TestSuite,
    assert_almost_equal,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from komira_kg import Embedder, EpisodeInput, StubEmbedder
from komira_kg_sources import (
    BIndex,
    EmptyAdapterRegistry,
    IndexRecord,
    IndexRow,
    RawStore,
    RawSurfaceAdapter,
    RegisteredAdapter,
    encode_index_record,
    episode_of,
    register,
)
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.store import ConditionalWriteStore, ObjectStore
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)

comptime Mem = SharedInMemoryConditionalStore
comptime DIM = 4


@fieldwise_init
struct JournalEntry(Copyable, Movable):
    """One line of a made-up journal: the time it describes and its text."""

    var time: Int64
    var text: String


@fieldwise_init
struct Journal(Movable):
    """A made-up record: an id and dated entries."""

    var id: String
    var entries: List[JournalEntry]


@fieldwise_init
struct Card(Movable):
    """A second made-up record: a title and free text."""

    var title: String
    var text: String


def _utf8(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _lines(raw: List[UInt8]) -> List[String]:
    var out = List[String]()
    var cur = List[UInt8]()
    for i in range(len(raw)):
        if raw[i] == UInt8(10):
            out.append(String(unsafe_from_utf8=Span(cur)))
            cur.clear()
        else:
            cur.append(raw[i])
    out.append(String(unsafe_from_utf8=Span(cur)))
    return out^


def _entry(line: String) raises -> JournalEntry:
    var b = line.as_bytes()
    var time = Int64(0)
    var at = 0
    while at < len(b) and b[at] != UInt8(124):
        var d = Int(b[at]) - 48
        if d < 0 or d > 9:
            raise Error("journal entry '" + line + "' has no numeric time")
        time = time * Int64(10) + Int64(d)
        at += 1
    if at == len(b) or at == 0:
        raise Error("journal entry '" + line + "' is not time|text")
    var text = List[UInt8]()
    for i in range(at + 1, len(b)):
        text.append(b[i])
    return JournalEntry(time, String(unsafe_from_utf8=Span(text)))


struct JournalAdapter(RawSurfaceAdapter):
    """Reads `id`, then one `time|text` line per entry; one episode per entry."""

    comptime Source = Journal

    def __init__(out self):
        pass

    def surface_tag(self) -> String:
        return "test.journal"

    def parse(self, raw: List[UInt8]) raises -> Journal:
        var lines = _lines(raw)
        if len(lines[0].as_bytes()) == 0:
            raise Error("journal has no id")
        var entries = List[JournalEntry]()
        for i in range(1, len(lines)):
            entries.append(_entry(lines[i]))
        return Journal(lines[0].copy(), entries^)

    def lower(
        self, var source: Journal, partition_id: String
    ) raises -> List[EpisodeInput]:
        var out = List[EpisodeInput]()
        for i in range(len(source.entries)):
            out.append(
                EpisodeInput(
                    source.id + "#" + String(i),
                    partition_id,
                    source.entries[i].text.copy(),
                    Int64(1000),
                    source.entries[i].time,
                    "journal",
                    source.id,
                )
            )
        return out^


struct CardAdapter(RawSurfaceAdapter):
    """Reads a title line and then the text; one episode holding the text."""

    comptime Source = Card

    def __init__(out self):
        pass

    def surface_tag(self) -> String:
        return "test.card"

    def parse(self, raw: List[UInt8]) raises -> Card:
        var lines = _lines(raw)
        if len(lines) < 2:
            raise Error("card has no text")
        var text = String("")
        for i in range(1, len(lines)):
            if i > 1:
                text += "\n"
            text += lines[i]
        return Card(lines[0].copy(), text^)

    def lower(
        self, var source: Card, partition_id: String
    ) raises -> List[EpisodeInput]:
        var out = List[EpisodeInput]()
        out.append(
            EpisodeInput("card:" + source.title, partition_id, source.text.copy(), Int64(1000), Int64(7))
        )
        return out^

def _infinity() -> Float64:
    var big = Float64(1.0e300)
    return big * big


def _v(a: Float64, b: Float64, c: Float64, d: Float64) -> List[Float64]:
    var out = List[Float64]()
    out.append(a)
    out.append(b)
    out.append(c)
    out.append(d)
    return out^


struct _Faults(Movable):
    """What the double does wrong; shared so a test can arm it after the move."""

    var races: Int
    var rival_body: List[UInt8]
    var head_fails: Bool
    var get_fails: Bool
    var put_fails: Bool

    def __init__(out self):
        self.races = 0
        self.rival_body = List[UInt8]()
        self.head_fails = False
        self.get_fails = False
        self.put_fails = False


struct _FaultyStore(ConditionalWriteStore):
    """An in-memory store that can lose a race on purpose: before a conditional
    write it commits `rival_body` at the same path, so the write finds the object
    there. It can also fail `head`, `get` and `conditional_put` outright."""

    var inner: Mem
    var faults: ArcPointer[_Faults]

    def __init__(out self, var inner: Mem, var faults: ArcPointer[_Faults]):
        self.inner = inner^
        self.faults = faults^

    def head(self, path: Path) raises -> ObjectMeta:
        if self.faults[].head_fails:
            raise Error("transport reset by peer")
        return self.inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self.inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self.inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        if self.faults[].put_fails:
            raise Error("disk full")
        if self.faults[].races > 0:
            self.faults[].races -= 1
            _ = self.inner.put(path, self.faults[].rival_body.copy())
        return self.inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        return self.conditional_put(
            path, bytes, WritePrecondition.if_match(expected_version)
        )

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self.conditional_put(path, bytes, WritePrecondition.none())

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self.inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        if self.faults[].get_fails:
            raise Error("connection refused")
        return self.inner.get(path)

    def delete(self, path: Path) raises -> None:
        self.inner.delete(path)




struct _Count(Movable):
    var calls: Int
    var texts: Int

    def __init__(out self):
        self.calls = 0
        self.texts = 0


struct CountingEmbedder(Embedder):
    """A stub embedder that counts the batches and texts it is asked for."""

    var inner: StubEmbedder
    var count: ArcPointer[_Count]

    def __init__(out self, var inner: StubEmbedder, var count: ArcPointer[_Count]):
        self.inner = inner^
        self.count = count^

    def dimension(self) -> Int:
        return self.inner.dimension()

    def embed(self, text: String) raises -> List[Float64]:
        return self.inner.embed(text)

    def embed_batch(self, texts: List[String]) raises -> List[List[Float64]]:
        self.count[].calls += 1
        self.count[].texts += len(texts)
        return self.inner.embed_batch(texts)


struct BadEmbedder(Embedder):
    """An embedder that reports 4 components and then breaks its promise.
    Mode 0: one vector too few. 1: vectors of 3 components. 2: a NaN component.
    3: a component that overflows f32."""

    var mode: Int

    def __init__(out self, mode: Int):
        self.mode = mode

    def dimension(self) -> Int:
        return 4

    def embed(self, text: String) raises -> List[Float64]:
        return _v(1, 0, 0, 0)

    def embed_batch(self, texts: List[String]) raises -> List[List[Float64]]:
        var out = List[List[Float64]]()
        for i in range(len(texts)):
            if self.mode == 0 and i == len(texts) - 1:
                break
            if self.mode == 1:
                var short = List[Float64]()
                short.append(1.0)
                short.append(0.0)
                short.append(0.0)
                out.append(short^)
                continue
            var v = _v(1, 0, 0, 0)
            if self.mode == 2:
                v[1] = _infinity() - _infinity()
            if self.mode == 3:
                v[1] = 1.0e300
            out.append(v^)
        return out^


comptime Registry = RegisteredAdapter[CardAdapter, RegisteredAdapter[JournalAdapter, EmptyAdapterRegistry]]


def _registry() raises -> Registry:
    return register(register(EmptyAdapterRegistry(), JournalAdapter()), CardAdapter())


# ---- the corpus: eight episodes and their vectors ----------------------------


def _texts() -> List[String]:
    var t = List[String]()
    t.append("e1 river")
    t.append("e2 stone")
    t.append("e3 cloud")
    t.append("e4 field")
    t.append("e5 wind")
    t.append("e6 lamp")
    t.append("e7 harbor")
    t.append("e8 dust")
    return t^


def _vectors() -> List[List[Float64]]:
    var v = List[List[Float64]]()
    v.append(_v(1, 0, 0, 0))
    v.append(_v(0, 1, 0, 0))
    v.append(_v(1, 1, 0, 0))
    v.append(_v(0, 0, 1, 0))
    v.append(_v(1, 0, 1, 0))
    v.append(_v(0, 0, 0, 1))
    v.append(_v(1, 1, 1, 1))
    v.append(_v(2, 1, 0, 1))
    return v^


def _uuids() -> List[String]:
    var u = List[String]()
    u.append("ja#0")
    u.append("ja#1")
    u.append("ja#2")
    u.append("jb#0")
    u.append("jb#1")
    u.append("card:ca")
    u.append("card:cb")
    u.append("card:cc")
    return u^


def _queries() -> List[List[Float64]]:
    var q = List[List[Float64]]()
    q.append(_v(1, 0.5, 0.25, 0.125))
    q.append(_v(0.5, 0.25, 1, 0.75))
    q.append(_v(0.125, 0.875, 0.375, 0.625))
    q.append(_v(-1, 0.5, 0.25, 1))
    return q^


def _embedder() raises -> StubEmbedder:
    var emb = StubEmbedder(DIM)
    var texts = _texts()
    var vecs = _vectors()
    for i in range(len(texts)):
        emb.add_vector(texts[i], vecs[i].copy())
    var qs = _queries()
    for i in range(len(qs)):
        emb.add_vector("query " + String(i), qs[i].copy())
    return emb^


def _fill(mut raw: RawStore[Mem]) raises -> List[String]:
    """Five raw records: two journals and three cards. Returns their keys in the
    order they were put."""
    var keys = List[String]()
    keys.append(raw.put("test.journal", _utf8("ja\n10|e1 river\n20|e2 stone\n30|e3 cloud"), Int64(1)).content_hash)
    keys.append(raw.put("test.journal", _utf8("jb\n40|e4 field\n50|e5 wind"), Int64(2)).content_hash)
    keys.append(raw.put("test.card", _utf8("ca\ne6 lamp"), Int64(3)).content_hash)
    keys.append(raw.put("test.card", _utf8("cb\ne7 harbor"), Int64(4)).content_hash)
    keys.append(raw.put("test.card", _utf8("cc\ne8 dust"), Int64(5)).content_hash)
    return keys^


def _raw() raises -> RawStore[Mem]:
    return RawStore[Mem](Mem(), String("lake"))


def _index() raises -> BIndex[Mem]:
    return BIndex[Mem](Mem(), String("idx"), DIM)


def _cos(a: List[Float64], b: List[Float64]) -> Float64:
    var dot = 0.0
    var na = 0.0
    var nb = 0.0
    for i in range(len(a)):
        dot += a[i] * b[i]
        na += a[i] * a[i]
        nb += b[i] * b[i]
    return dot / (sqrt(na) * sqrt(nb))


def _plain_scan(query: List[Float64], vecs: List[List[Float64]], k: Int) -> List[Int]:
    """The episodes' positions best first: score every one, then repeatedly take
    the best remaining one, the lower position first on a tie."""
    var scores = List[Float64]()
    var left = List[Int]()
    for i in range(len(vecs)):
        scores.append(_cos(query, vecs[i]))
        left.append(i)
    var out = List[Int]()
    while len(left) > 0 and len(out) < k:
        var best = 0
        for j in range(1, len(left)):
            if scores[left[j]] > scores[left[best]]:
                best = j
        out.append(left[best])
        _ = left.pop(best)
    return out^


struct _Built(Movable):
    var raw: RawStore[Mem]
    var idx: BIndex[Mem]
    var keys: List[String]

    def __init__(
        out self,
        var raw: RawStore[Mem],
        var idx: BIndex[Mem],
        var keys: List[String],
    ):
        self.raw = raw^
        self.idx = idx^
        self.keys = keys^


def _built() raises -> _Built:
    var raw = _raw()
    var keys = _fill(raw)
    var idx = _index()
    var emb = _embedder()
    _ = idx.build(raw, _registry(), emb, "part-1")
    return _Built(raw^, idx^, keys^)


def test_the_index_returns_the_same_top_k_as_a_plain_scan() raises:
    var built = _built()
    ref idx = built.idx
    var vecs = _vectors()
    var uuids = _uuids()
    var qs = _queries()
    var ks = [1, 2, 3, 5, 8, 20]
    for qi in range(len(qs)):
        for ki in range(len(ks)):
            var k = ks[ki]
            var want = _plain_scan(qs[qi], vecs, k)
            var got = idx.top_k(qs[qi], k)
            assert_equal(len(got), len(want))
            for i in range(len(want)):
                assert_equal(got[i].episode_uuid, uuids[want[i]])
                assert_almost_equal(got[i].score, _cos(qs[qi], vecs[want[i]]))


def test_a_search_embeds_the_text_and_ranks_like_the_plain_scan() raises:
    var built = _built()
    ref idx = built.idx
    var emb = _embedder()
    var vecs = _vectors()
    var uuids = _uuids()
    var qs = _queries()
    for qi in range(len(qs)):
        var want = _plain_scan(qs[qi], vecs, 4)
        var got = idx.search(emb, "query " + String(qi), 4)
        assert_equal(len(got), 4)
        for i in range(4):
            assert_equal(got[i].episode_uuid, uuids[want[i]])


def test_a_hit_names_its_record_position_tag_and_time() raises:
    var built = _built()
    ref idx = built.idx
    ref keys = built.keys
    var hits = idx.top_k(_queries()[0], 3)
    # Best first for query 0: e8 (card cc), e3 (journal ja, position 2), e1 (ja, 0).
    assert_equal(hits[0].episode_uuid, "card:cc")
    assert_equal(hits[0].raw_key, keys[4])
    assert_equal(hits[0].ordinal, 0)
    assert_equal(hits[0].surface_tag, "test.card")
    assert_equal(hits[0].valid_at, Int64(7))
    assert_equal(hits[1].episode_uuid, "ja#2")
    assert_equal(hits[1].raw_key, keys[0])
    assert_equal(hits[1].ordinal, 2)
    assert_equal(hits[1].surface_tag, "test.journal")
    assert_equal(hits[1].valid_at, Int64(30))
    assert_equal(hits[2].episode_uuid, "ja#0")
    assert_equal(hits[2].valid_at, Int64(10))
    assert_true(hits[0].score > hits[1].score)
    assert_true(hits[1].score > hits[2].score)


def test_equal_scores_come_back_raw_key_then_position() raises:
    var raw = _raw()
    # Two records with one text and one record with the same text twice: every
    # episode has the one vector, so every score is equal.
    var a = raw.put("test.journal", _utf8("ja\n1|e1 river\n2|e1 river"), Int64(1)).content_hash
    var b = raw.put("test.journal", _utf8("jb\n3|e1 river"), Int64(1)).content_hash
    var c = raw.put("test.card", _utf8("cc\ne1 river"), Int64(1)).content_hash
    var idx = _index()
    var emb = _embedder()
    _ = idx.build(raw, _registry(), emb, "p")
    var hits = idx.top_k(_v(1, 0, 0, 0), 10)
    assert_equal(len(hits), 4)
    var keys = List[String]()
    keys.append(a.copy())
    keys.append(b.copy())
    keys.append(c.copy())
    for i in range(3):
        for j in range(2 - i):
            if keys[j] > keys[j + 1]:
                var t = keys[j].copy()
                keys[j] = keys[j + 1].copy()
                keys[j + 1] = t^
    var seen = List[String]()
    for i in range(len(hits)):
        assert_almost_equal(hits[i].score, 1.0)
        seen.append(hits[i].raw_key.copy())
    # Grouped by raw key in ascending order, positions ascending within a key.
    var at = 0
    for i in range(3):
        var count = 0
        while at < len(hits) and hits[at].raw_key == keys[i]:
            assert_equal(hits[at].ordinal, count)
            count += 1
            at += 1
        assert_true(count > 0)
    assert_equal(at, 4)
    # Cutting at k keeps the head of the same order.
    var two = idx.top_k(_v(1, 0, 0, 0), 2)
    assert_equal(two[0].raw_key, hits[0].raw_key)
    assert_equal(two[0].ordinal, hits[0].ordinal)
    assert_equal(two[1].raw_key, hits[1].raw_key)
    assert_equal(two[1].ordinal, hits[1].ordinal)


def test_an_empty_index_answers_with_no_hit() raises:
    var idx = _index()
    assert_equal(len(idx.top_k(_v(1, 0, 0, 0), 5)), 0)
    assert_equal(len(idx.list_keys()), 0)
    assert_equal(idx.dimension(), DIM)
    assert_equal(idx.prefix(), "idx")


def test_a_query_that_cannot_be_ranked_is_refused() raises:
    var built = _built()
    ref idx = built.idx
    with assert_raises(contains="k must be positive, got 0"):
        _ = idx.top_k(_v(1, 0, 0, 0), 0)
    with assert_raises(contains="k must be positive, got -3"):
        _ = idx.top_k(_v(1, 0, 0, 0), -3)
    with assert_raises(contains="the query has 3 components, the index's dimension is 4"):
        var short = List[Float64]()
        short.append(1.0)
        short.append(0.0)
        short.append(0.0)
        _ = idx.top_k(short, 3)
    var bad = _v(1, 0, 0, 0)
    bad[2] = _infinity()
    with assert_raises(contains="the query has a non-finite component"):
        _ = idx.top_k(bad, 3)


def test_a_first_build_indexes_every_record_and_a_second_embeds_nothing() raises:
    var raw = _raw()
    var keys = _fill(raw)
    var idx = _index()
    var counter = ArcPointer[_Count](_Count())
    var emb = CountingEmbedder(_embedder(), counter.copy())
    var first = idx.build(raw, _registry(), emb, "part-1")
    assert_equal(first.records_indexed, 5)
    assert_equal(first.rows_added, 8)
    assert_equal(first.skipped_existing, 0)
    assert_equal(first.skipped_unregistered, 0)
    assert_equal(first.skipped_empty, 0)
    assert_equal(counter[].calls, 5)
    assert_equal(counter[].texts, 8)
    assert_equal(len(idx.list_keys()), 5)
    for i in range(5):
        assert_true(idx.has_record(keys[i]))
    var second = idx.build(raw, _registry(), emb, "part-1")
    assert_equal(second.records_indexed, 0)
    assert_equal(second.rows_added, 0)
    assert_equal(second.skipped_existing, 5)
    assert_equal(counter[].calls, 5)
    assert_equal(counter[].texts, 8)


def test_a_record_added_later_is_indexed_alone() raises:
    var built = _built()
    ref raw = built.raw
    ref idx = built.idx
    var late = raw.put("test.card", _utf8("cd\ne1 river"), Int64(9)).content_hash
    var emb = _embedder()
    var report = idx.build(raw, _registry(), emb, "part-1")
    assert_equal(report.records_indexed, 1)
    assert_equal(report.rows_added, 1)
    assert_equal(report.skipped_existing, 5)
    assert_true(idx.has_record(late))
    assert_equal(idx.read_record(late).rows[0].episode_uuid, "card:cd")


def test_a_record_with_no_adapter_or_no_episode_is_skipped_and_counted() raises:
    var raw = _raw()
    _ = _fill(raw)
    var other = raw.put("test.other", _utf8("whatever"), Int64(1)).content_hash
    var nothing = raw.put("test.journal", _utf8("jz"), Int64(1)).content_hash
    var idx = _index()
    var emb = _embedder()
    var report = idx.build(raw, _registry(), emb, "part-1")
    assert_equal(report.records_indexed, 5)
    assert_equal(report.skipped_unregistered, 1)
    assert_equal(report.skipped_empty, 1)
    assert_false(idx.has_record(other))
    assert_false(idx.has_record(nothing))
    # The empty record leaves no trace, so the next build visits it again.
    var again = idx.build(raw, _registry(), emb, "part-1")
    assert_equal(again.skipped_empty, 1)
    assert_equal(again.skipped_unregistered, 1)
    assert_equal(again.skipped_existing, 5)


def test_bytes_put_under_two_tags_are_indexed_once_under_the_first() raises:
    var raw = _raw()
    var bytes = _utf8("k\ne1 river")
    var first = raw.put("test.card", bytes, Int64(1))
    var second = raw.put("test.journal", bytes, Int64(2))
    assert_false(second.created)
    var idx = _index()
    var emb = _embedder()
    var report = idx.build(raw, _registry(), emb, "p")
    assert_equal(report.records_indexed, 1)
    var hits = idx.top_k(_v(1, 0, 0, 0), 5)
    assert_equal(len(hits), 1)
    assert_equal(hits[0].surface_tag, "test.card")
    assert_equal(hits[0].raw_key, first.content_hash)


def test_an_adapter_that_cannot_read_a_record_stops_the_build_and_keeps_the_rest() raises:
    var raw = _raw()
    var good = raw.put("test.card", _utf8("ca\ne6 lamp"), Int64(1)).content_hash
    var idx = _index()
    var emb = _embedder()
    _ = idx.build(raw, _registry(), emb, "p")
    assert_true(idx.has_record(good))
    _ = raw.put("test.journal", _utf8("jx\nnot-a-time|text"), Int64(2))
    with assert_raises(contains="has no numeric time"):
        _ = idx.build(raw, _registry(), emb, "p")
    assert_true(idx.has_record(good))
    assert_equal(len(idx.list_keys()), 1)


def test_an_embedder_of_another_dimension_is_refused() raises:
    var raw = _raw()
    _ = _fill(raw)
    var idx = _index()
    var wrong = StubEmbedder(3)
    with assert_raises(contains="the embedder's dimension is 3, the index's is 4"):
        _ = idx.build(raw, _registry(), wrong, "p")
    with assert_raises(contains="the embedder's dimension is 3, the index's is 4"):
        _ = idx.search(wrong, "query 0", 2)
    assert_equal(len(idx.list_keys()), 0)


def test_an_embedder_that_answers_wrongly_is_refused_and_nothing_is_written() raises:
    var raw = _raw()
    _ = raw.put("test.journal", _utf8("ja\n1|e1 river\n2|e2 stone"), Int64(1))
    var idx = _index()
    with assert_raises(contains="returned 1 vectors for 2 texts"):
        _ = idx.build(raw, _registry(), BadEmbedder(0), "p")
    with assert_raises(contains="returned 3 components, the index's dimension is 4"):
        _ = idx.build(raw, _registry(), BadEmbedder(1), "p")
    with assert_raises(contains="returned a non-finite component"):
        _ = idx.build(raw, _registry(), BadEmbedder(2), "p")
    with assert_raises(contains="returned a non-finite component"):
        _ = idx.build(raw, _registry(), BadEmbedder(3), "p")
    assert_equal(len(idx.list_keys()), 0)


def test_a_builder_that_loses_the_race_leaves_the_winners_rows() raises:
    var data = Mem()
    var faults = ArcPointer[_Faults](_Faults())
    var raw = _raw()
    var key = raw.put("test.card", _utf8("ca\ne6 lamp"), Int64(1)).content_hash
    var idx = BIndex[_FaultyStore](_FaultyStore(data.clone(), faults.copy()), String("idx"), DIM)
    var rows = List[IndexRow]()
    rows.append(IndexRow("rival#0", Int64(99), _v(0, 0, 0, 1)))
    faults[].races = 1
    faults[].rival_body = encode_index_record(IndexRecord("rival-tag", rows^))
    var emb = _embedder()
    var report = idx.build(raw, _registry(), emb, "p")
    assert_equal(report.records_indexed, 0)
    assert_equal(report.rows_added, 0)
    assert_equal(report.skipped_existing, 1)
    var stored = idx.read_record(key)
    assert_equal(stored.surface_tag, "rival-tag")
    assert_equal(stored.rows[0].episode_uuid, "rival#0")


def test_a_store_failure_is_raised() raises:
    var faults = ArcPointer[_Faults](_Faults())
    var raw = _raw()
    var key = raw.put("test.card", _utf8("ca\ne6 lamp"), Int64(1)).content_hash
    var idx = BIndex[_FaultyStore](_FaultyStore(Mem(), faults.copy()), String("idx"), DIM)
    var emb = _embedder()
    faults[].put_fails = True
    with assert_raises(contains="disk full"):
        _ = idx.build(raw, _registry(), emb, "p")
    faults[].put_fails = False
    faults[].head_fails = True
    with assert_raises(contains="transport reset by peer"):
        _ = idx.has_record(key)
    with assert_raises(contains="transport reset by peer"):
        _ = idx.build(raw, _registry(), emb, "p")
    faults[].head_fails = False
    assert_false(idx.has_record(key))


def test_a_hit_maps_back_to_its_episode_through_the_registry() raises:
    var built = _built()
    ref raw = built.raw
    ref idx = built.idx
    var hits = idx.top_k(_queries()[0], 8)
    var registry = _registry()
    for i in range(len(hits)):
        var ep = episode_of(hits[i], raw, registry, "part-1")
        assert_equal(ep.uuid, hits[i].episode_uuid)
        assert_equal(ep.valid_at, hits[i].valid_at)
        assert_equal(ep.partition_id, "part-1")
    var best = episode_of(hits[0], raw, registry, "part-1")
    assert_equal(best.body, "e8 dust")
    var second = episode_of(hits[1], raw, registry, "part-1")
    assert_equal(second.body, "e3 cloud")
    assert_equal(second.facet_source, "ja")


def test_a_hit_that_no_longer_maps_to_an_episode_is_refused() raises:
    var built = _built()
    ref raw = built.raw
    ref idx = built.idx
    ref keys = built.keys
    var registry = _registry()
    var hit = idx.top_k(_queries()[0], 1)[0].copy()
    with assert_raises(contains="no adapter is registered for tag 'test.card'"):
        _ = episode_of(hit, raw, EmptyAdapterRegistry(), "p")
    var gone = hit.copy()
    gone.raw_key = "0123456789abcdef"
    with assert_raises(contains="no record is stored under 0123456789abcdef"):
        _ = episode_of(gone, raw, registry, "p")
    var past = hit.copy()
    past.ordinal = 1
    with assert_raises(contains="lowers to 1 episodes, the hit names position 1"):
        _ = episode_of(past, raw, registry, "p")
    var before = hit.copy()
    before.ordinal = -1
    with assert_raises(contains="the hit names position -1"):
        _ = episode_of(before, raw, registry, "p")
    var changed = hit.copy()
    changed.episode_uuid = "card:zz"
    with assert_raises(contains="is episode 'card:cc', the hit names 'card:zz'"):
        _ = episode_of(changed, raw, registry, "p")


def test_an_index_that_cannot_be_opened_is_refused() raises:
    with assert_raises(contains="index prefix must not be empty"):
        _ = BIndex[Mem](Mem(), String(""), DIM)
    with assert_raises(contains="index prefix must not hold '//'"):
        _ = BIndex[Mem](Mem(), String("a//b"), DIM)
    with assert_raises(contains="dimension must be positive, got 0"):
        _ = BIndex[Mem](Mem(), String("idx"), 0)
    with assert_raises(contains="dimension must be positive, got -2"):
        _ = BIndex[Mem](Mem(), String("idx"), -2)


def test_an_index_opened_with_another_dimension_refuses_the_stored_rows() raises:
    var data = Mem()
    var raw = _raw()
    _ = _fill(raw)
    var idx = BIndex[Mem](data.clone(), String("idx"), DIM)
    var emb = _embedder()
    _ = idx.build(raw, _registry(), emb, "p")
    var other = BIndex[Mem](data.clone(), String("idx"), 3)
    var q = List[Float64]()
    q.append(1.0)
    q.append(0.0)
    q.append(0.0)
    with assert_raises(contains="embedding cell is 16 bytes, which is not a dimension of 3"):
        _ = other.top_k(q, 3)


def test_keys_must_be_hashes_and_a_stray_object_is_reported() raises:
    var data = Mem()
    var idx = BIndex[Mem](data.clone(), String("idx"), DIM)
    with assert_raises(contains="'nope' is not a raw key"):
        _ = idx.has_record("nope")
    with assert_raises(contains="'nope' is not a raw key"):
        _ = idx.read_record("nope")
    _ = data.put(Path.parse("idx/index/stray.txt"), _utf8("x"))
    with assert_raises(contains="'idx/index/stray.txt' is not an index record name"):
        _ = idx.list_keys()
    with assert_raises(contains="is not an index record name"):
        _ = idx.top_k(_v(1, 0, 0, 0), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
