# `komira_kg`

## Responsibility

The mutable data-graph store and its ingest. This is parts 1 to 5 of the package
described in
[the knowledge graph port](https://github.com/komira-ai/komira/blob/main/docs/design/knowledge_graph_port.md):
bi-temporal edges, entity resolution and the source facet, the three seams
through which a host supplies a model (`Embedder`, `LlmClient`, `Extractor`),
each with a stub for tests, an extractor driven by rules the host supplies, and
the cursor that records how far an incremental read of a source got. The
working set loads and rewrites snapshots, and erasure of a partition, the warm
cache, compaction and embedding top-k work on a snapshot store; a later part adds
ingest.

The graph keeps every fact on two time axes: event time (when it held in the
world) and system time (when the graph learned it and when it learned it no
longer held). A correction closes the old edge and adds a new one; no row is
deleted, so "what did we believe at time T" stays answerable.

- `bitemporal`: `WorkingEdge`, `open_edge`,
  `overlapping_contradiction_candidates` and `apply_invalidation`. The package
  names which existing edges a new edge might contradict and stamps a verdict
  onto one; it never decides whether two facts contradict. That judgment is the
  caller's.
- `name_similarity`: `normalize_name`, `shannon_entropy`, `minhash_signature`,
  `jaccard_estimate`, `lsh_candidate` and `pair_decision`, the deterministic
  string math under deduplication.
- `dedup`: `dedup_resolve` resolves one mention against candidate entities to
  matched, new or needs-judgment, and `dedup_resolve_judged` settles a
  needs-judgment decision with a `SameEntityJudge` the caller implements.
- `alias_map`: `AliasMap`, a directed union-find over node ids, so no edge points
  at an id that was merged away.
- `source_facet`: the facet an entity carries in its `attrs` JSON
  (`facet_attrs_json`, `facet_from_attrs`, `facet_source_from_attrs`) and
  `FacetTombstoneSet`, the (source, facet) pairs a query excludes.
- `embedder`: the `Embedder` trait (`dimension`, `embed`, `embed_batch`) and
  `StubEmbedder`. An embedder reports its dimension; there is no default, and
  every vector it returns has exactly that many components.
- `extractor`: the `Extractor` trait (text and the entities already found to an
  `Extraction`, without inference), `StubExtractor` and `copy_extraction`.
- `llm_client`: the `LlmClient` trait (`extract`, `judge_contradiction`,
  `judge_same_entity`, and optional `has_synthesis` and `synthesize`) and
  `StubLlmClient`.
- `rule`, `rule_pattern`, `rule_scan`, `rule_extractor`: `RuleExtractor`, an
  `Extractor` with no model. Its rule set is data the host passes in: each `Rule`
  is a type label (an opaque string) and a matcher: a word list, a verb prefix
  (a listed verb and the word after it), a token `Pattern`, a delimited span,
  an email address or a URL. The extractor also takes the names to refuse and
  the predicate of its co-occurrence edges. The package ships no rule set.
- `cursor_store`: `SurfaceCursor` (an opaque token, a watermark and the time of
  the last advance, for one source of one partition) and `CursorStore`, which
  keeps one cursor object per partition id and source key on a
  `ConditionalWriteStore` and writes it with compare-and-set. A writer that loses
  a race is reported (`try_save` returns False), `save` retries a bounded number
  of times, and a stored cursor that does not decode is refused.
- `working_rows`, `working_codec`, `working_set`: the in-memory working set of
  one ingest. `WorkingEntity` and `WorkingEpisode` are plain value rows (with
  `WorkingEdge`), and `SnapshotWorkingSet` holds the three lists and the node-id
  high-water mark. It loads a base snapshot (`load_from`) or the live head, the
  base merged with its deltas (`load_latest`, `load_merged`); the writer mints
  ids (`next_nid`), adds entities, edges and episodes and closes edges in place;
  `to_tables` writes the whole graph as a base snapshot and `delta_tables` only
  what changed since the load, with `name_index_delta` for the exact-name index
  that rides the same delta. The set carries the graph's embedding dimension
  (given when it is made empty, the manifest's when loaded): an embedding of
  another length is refused when it is added, when it is written and when it is
  read. Tables come back through the Parquet reader and the delta codec from
  bytes, and what is read from storage is checked: the schema version, the
  columns and their types, null cells, UTF-8, the node-id range and repeats, and
  a tombstone that matches no edge or that cannot tell its edge from another.
  A tombstone names an edge by `(src, dst, created_at)`, so a delta cannot close
  one of two open edges that share that key: `delta_tables` refuses it, and the
  writer writes a base with `to_tables` instead, which keeps every edge's end
  times in its own row. `mark_committed` declares the set's state persisted (a
  writer that keeps its set after appending its own delta calls it), narrowing
  the new embeddings to f32 as the table stores them, so the resident vectors
  equal a reload's.
- `erase`: `erase_partition` removes a partition's entities and episodes from a
  working set, and every edge with one of those entities as an endpoint (an edge
  has no partition column). `erase_kg_partition` does it to a store's live graph
  and writes the rest as a new base, never a delta, followed by an index delta
  of the surviving entities only; the head then holds no row, embedding or
  name-index entry of the partition. Other partitions are untouched, and
  erasing an absent partition writes no base (it appends a missing index delta,
  as `compact_chain` does). A delta a writer appended meanwhile is carried onto
  the new head and examined: if it holds rows, edges, tombstones, names or
  projection rows of the partition the head is folded again, up to
  `MAX_ERASE_ROUNDS` commits, and a writer that keeps adding them makes the call
  raise, naming the partition and the count of rows left. `erase_kg_partition_at`
  and `erase_commit_at` hold an erasure open for a test.
- `compaction`: `compact_chain` folds the head chain into a new base,
  `compact_chain_at` folds a stated head (a delta appended since is carried onto
  the new head, never lost) and `maybe_compact_chain` does so when a
  `CompactionPolicy` trips. The new base is written as a pending base, made the
  head by `commit_compacted_head`, followed by an index delta, and only then are
  the folded deltas retired: stamped with the caller's `now_ms`. Nothing is
  deleted, so a reader that pinned an earlier head keeps reading it. A head whose
  base has no index delta (a fold stopped after the commit, or a base written by
  `write_snapshot`) gets one when `compact_chain` runs, so a retry finishes the
  fold; the deltas the stopped fold had not retired stay unmarked. The index
  delta leaves out the names and node ids of the deltas on the chain when it is
  appended; a delta whose head lands between that read and the append is still
  overridden for a name or node id both speak for (the store has no
  append-if-head verb).
- `warm_cache`: `WarmMergedCache` keeps the merged graph in memory keyed by the
  head chunk, read fresh by `refresh`; `get` lends the resident set as an
  immutable `ref`, `take_current` and `commit` are the single writer's loop.
- `embedding_topk`: `resolve_embedding_topk` ranks the entities of a chain's
  `entities_embedding` projections (later rows replace earlier ones by node id)
  by cosine against a query: score descending, equal scores by ascending node
  id, keeping the best k in a bounded heap. It refuses `k <= 0`, a query of
  another dimension than the graph's and a query with a non-finite component; a
  stored row with a non-finite component is skipped, never ranked.

A facet, a source, a predicate and an entity name are opaque strings the host
supplies: the package fixes no vocabulary. Prompts are values the caller passes
in. It names no model, vendor or server and holds no network code: a model is a
trait a host (or a transport package) implements. It calls no model, reads no clock
and reads no environment; a time is always an argument, in whatever unit the
graph stamps. It depends on `komira_kg_format` (the open-interval marker, the
snapshot store, the schemas and the delta codec), `komira_json` (the facet's
`attrs` JSON) and `komira_objectstore` (the cursor store and the snapshot
objects), and no pointer crosses its API.

## Examples

A new fact starts open on both axes. The existing edges it might contradict are
the ones with the same node pair whose interval overlaps; once the caller
confirms a contradiction, `apply_invalidation` closes the old edge at the new
edge's start and records the system time it was learned. The old row stays:

<!-- mojo-hidden
from std.testing import assert_equal, assert_false, assert_true
-->
```mojo
from komira_kg import (
    WorkingEdge,
    apply_invalidation,
    open_edge,
    overlapping_contradiction_candidates,
)
from komira_kg_format import TS_OPEN_SENTINEL

var existing = List[WorkingEdge]()
existing.append(open_edge(1, 3, "", "method A", valid_at=100, now=100, reference_time=100))

var incoming = open_edge(1, 3, "", "method B", valid_at=300, now=500, reference_time=300)
var candidates = overlapping_contradiction_candidates(incoming, existing)
assert_equal(len(candidates), 1)

# The caller judged index 0 a contradiction.
apply_invalidation(existing[candidates[0]], incoming, now=500)
assert_equal(existing[0].invalid_at, 300)
assert_equal(existing[0].expired_at, 500)
assert_equal(existing[0].valid_at, 100)
assert_equal(existing[0].created_at, 100)
assert_true(incoming.invalid_at == TS_OPEN_SENTINEL)
assert_false(existing[0].is_open())
```

An edge that ended exactly when the new one begins is a hand-off, not a
contradiction, and neither is an edge between another pair of nodes:

<!-- mojo-hidden
from std.testing import assert_equal
-->
```mojo
from komira_kg import WorkingEdge, open_edge, overlapping_contradiction_candidates

var existing = List[WorkingEdge]()
existing.append(WorkingEdge(1, 3, "", "ended at 300", 100, 300, 300, 100, 100, ""))
existing.append(open_edge(4, 1, "", "other pair", 100, 100, 100))
var incoming = open_edge(1, 3, "", "starts at 300", valid_at=300, now=500, reference_time=300)
assert_equal(len(overlapping_contradiction_candidates(incoming, existing)), 0)
```

`dedup_resolve` takes the mention, the candidates (existing entities, best
first), the Jaccard floor for merging without a judgment, the floor for asking
for one, and the entropy floor below which a name is too generic to merge on
similarity. An exact normalized match wins at tier 1, a near-duplicate at tier 2:

<!-- mojo-hidden
from std.testing import assert_equal, assert_true
-->
```mojo
from komira_kg import DedupCandidate, dedup_resolve

var cands = List[DedupCandidate]()
cands.append(DedupCandidate(42, "alpha inc ", "a group"))
var exact = dedup_resolve("Alpha, Inc.", cands, 0.7, 0.25, 2.6)
assert_true(exact.is_matched())
assert_equal(exact.tier, 1)
assert_equal(exact.nid, 42)

var fuzzy_cands = List[DedupCandidate]()
fuzzy_cands.append(DedupCandidate(7, "Alpha Catalog Model", ""))
var fuzzy = dedup_resolve("Alpha Catalog Models", fuzzy_cands, 0.7, 0.25, 2.6)
assert_true(fuzzy.is_matched())
assert_equal(fuzzy.tier, 2)
assert_equal(fuzzy.nid, 7)
```

A generic mention is new rather than merged into a more specific name, and a
borderline candidate is returned for judgment with its index:

<!-- mojo-hidden
from std.testing import assert_equal, assert_true
-->
```mojo
from komira_kg import DedupCandidate, dedup_resolve

var specific = List[DedupCandidate]()
specific.append(DedupCandidate(99, "Catalog Tier Change", ""))
assert_true(dedup_resolve("Catalog", specific, 0.7, 0.25, 2.6).is_new())

var near = List[DedupCandidate]()
near.append(DedupCandidate(13, "Alpha Inc", "a group"))
var res = dedup_resolve("Alpha Incorporated", near, 0.7, 0.25, 2.6)
assert_true(res.is_needs_judgment())
assert_equal(res.candidate_index, 0)
assert_equal(res.nid, 13)
```

The package holds no model. To settle a borderline candidate, implement
`SameEntityJudge` (with a model, a rule or a person) and call
`dedup_resolve_judged`; the judge is asked only for a borderline candidate:

<!-- mojo-hidden
from std.testing import assert_equal, assert_true
-->
```mojo module
from komira_kg import DedupCandidate, SameEntityJudge, dedup_resolve_judged


struct AlwaysSame(SameEntityJudge):
    var asked: Int

    def __init__(out self):
        self.asked = 0

    def same_entity(
        mut self, mention_name: String, candidate: DedupCandidate
    ) raises -> Bool:
        self.asked += 1
        return True


def main() raises:
    var near = List[DedupCandidate]()
    near.append(DedupCandidate(13, "Alpha Inc", "a group"))
    var judge = AlwaysSame()
    var res = dedup_resolve_judged(
        "Alpha Incorporated", near, 0.7, 0.25, 2.6, judge
    )
    assert_true(res.is_matched())
    assert_equal(res.tier, 3)
    assert_equal(res.nid, 13)
    assert_equal(judge.asked, 1)
```

`union(alias, canonical)` records that one id is another; chains collapse toward
the last canonical id, and an id never named resolves to itself:

<!-- mojo-hidden
from std.testing import assert_equal, assert_false, assert_true
-->
```mojo
from komira_kg import AliasMap

var aliases = AliasMap()
aliases.union(1, 2)
aliases.union(2, 3)
assert_equal(aliases.resolve(1), 3)
assert_true(aliases.is_alias(2))
assert_false(aliases.is_alias(3))
assert_equal(aliases.resolve(99), 99)
```

An entity's facet and the source it came from ride in its `attrs` JSON. A
tombstone excludes one facet of one source and leaves the others alone; a
tombstone with an empty source excludes the facet for every source:

<!-- mojo-hidden
from std.testing import assert_equal, assert_false, assert_true
-->
```mojo
from komira_kg import (
    FacetTombstoneSet,
    facet_attrs_json,
    facet_from_attrs,
    facet_source_from_attrs,
)

var attrs = facet_attrs_json("kind-a", "src-1")
assert_equal(attrs, '{"facet":"kind-a","facet_source":"src-1"}')
assert_equal(facet_from_attrs(attrs), "kind-a")
assert_equal(facet_source_from_attrs(attrs), "src-1")
assert_equal(facet_from_attrs("{}"), "")

var tombstones = FacetTombstoneSet()
tombstones.disable("src-1", "kind-a")
assert_true(tombstones.is_disabled("src-1", "kind-a"))
assert_false(tombstones.is_disabled("src-1", "kind-b"))
assert_false(tombstones.is_disabled("src-2", "kind-a"))
tombstones.disable("", "kind-b")
assert_true(tombstones.is_disabled("src-2", "kind-b"))
```

An embedder reports its dimension, and a graph's manifest records the dimension
its columns were written with, so a vector is checked against that number where
it is read. `StubEmbedder(dimension)` is deterministic (the same text gives the
same vector) and texts with similar characters give a high cosine, so the dedup
read can be tested without a model:

<!-- mojo-hidden
from std.testing import assert_equal, assert_true
-->
```mojo
from komira_kg import StubEmbedder
from komira_kg_format import cosine, pack_embedding, unpack_embedding_checked

var embedder = StubEmbedder(28)
assert_equal(embedder.dimension(), 28)

var name = embedder.embed("Alpha Corporation")
assert_equal(len(name), embedder.dimension())
var cell = pack_embedding(name)
assert_equal(len(unpack_embedding_checked(cell.as_bytes(), 28)), 28)

var near = embedder.embed("Alpha Corporaton")
var far = embedder.embed("Zenith Logistics Group")
assert_true(cosine(name, near) > cosine(name, far))
```

A test of ingest registers what the "model" says. `StubExtractor` answers by the
text and by how many entities are already found, so a gleaning loop sees a first
pass, then a delta, then nothing; `StubLlmClient` does the same for `extract` and
adds verdicts for the two judgments:

<!-- mojo-hidden
from std.testing import assert_equal, assert_false, assert_true
-->
```mojo
from komira_kg import StubExtractor, StubLlmClient
from komira_kg_format import EntityMention, Extraction, Triple

var first = List[EntityMention]()
first.append(EntityMention("Service A", "component", ""))
var extractor = StubExtractor()
extractor.add_extraction("text", 0, Extraction(first^, List[Triple]()))

var found = List[EntityMention]()
var pass_one = extractor.extract("text", found)
assert_equal(pass_one.num_entities(), 1)
found.append(pass_one.entities[0].copy())
assert_equal(extractor.extract("text", found).num_entities(), 0)

var llm = StubLlmClient()
llm.add_contradiction("method B", "method A", True)
llm.add_same_entity("Alpha Corp", "Alpha Corporation", True)
assert_true(llm.judge_contradiction("method B", "method A"))
assert_false(llm.judge_contradiction("method A", "method B"))
assert_true(llm.judge_same_entity("Alpha Corp", "", "Alpha Corporation", ""))
assert_false(llm.has_synthesis())
```

A rule set is data. This one reads tags, code words and email addresses; the
type labels and the predicate are whatever the host chose, and a different rule
set over the same code gives a different vocabulary. An entity is returned once,
under the first rule that found it, and a pair of entities in one text gets an
edge:

<!-- mojo-hidden
from std.testing import assert_equal
-->
```mojo
from komira_kg import Rule, RuleExtractor
from komira_kg_format import EntityMention

var words = List[String]()
words.append("alpha")
words.append("beta")
var rules = List[Rule]()
rules.append(Rule.token_pattern("tag", "#[a-z]+"))
rules.append(Rule.word_list("code", words))
rules.append(Rule.email("handle"))
var extractor = RuleExtractor(rules^, List[String](), "co_occurs_with", 12)

var found = List[EntityMention]()
var ex = extractor.extract("alpha uses #red; note ann@x.example", found)
assert_equal(ex.num_entities(), 3)
assert_equal(ex.entities[0].name, "#red")
assert_equal(ex.entities[0].entity_type, "tag")
assert_equal(ex.entities[1].name, "alpha")
assert_equal(ex.entities[2].entity_type, "handle")
assert_equal(ex.num_triples(), 3)
assert_equal(ex.triples[0].fact, "#red co_occurs_with alpha")

# Given what the first pass found, a second pass finds nothing new.
for i in range(ex.num_entities()):
    found.append(ex.entities[i].copy())
assert_equal(extractor.extract("alpha uses #red; note ann@x.example", found).num_entities(), 0)
```

A token pattern is a small whole-token language: literals, `.`, classes such as
`[A-Z0-9]`, the escapes `\d` and `\w`, and the quantifiers `?`, `*` and `+`. A
delimited rule takes the text between two strings on one line, and a verb-prefix
rule takes a listed verb with the word after it:

<!-- mojo-hidden
from std.testing import assert_equal
-->
```mojo
from komira_kg import Rule, RuleExtractor
from komira_kg_format import EntityMention

var verbs = List[String]()
verbs.append("open")
var rules = List[Rule]()
rules.append(Rule.token_pattern("ref", "[A-Z]+-\\d+"))
rules.append(Rule.verb_prefix("action", verbs))
rules.append(Rule.delimited("span", "<<", ">>"))
var extractor = RuleExtractor(rules^, List[String](), "", 0)
var ex = extractor.extract("open note AB-12 and <<two words>>", List[EntityMention]())
assert_equal(ex.num_entities(), 3)
assert_equal(ex.entities[0].name, "AB-12")
assert_equal(ex.entities[1].name, "open note")
assert_equal(ex.entities[2].name, "two words")
assert_equal(ex.num_triples(), 0)
```

A cursor records where an incremental read of one source of one partition
stopped. `try_save` is one compare-and-set against the version `read` returned,
so of two writers that read the same version only the first lands; the other is
told it lost and can read again:

<!-- mojo-hidden
from std.testing import assert_equal, assert_false, assert_true
-->
```mojo
from komira_kg import CursorStore, SurfaceCursor
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

var data = SharedInMemoryConditionalStore()
var a = CursorStore[SharedInMemoryConditionalStore](data.clone(), "state")
var b = CursorStore[SharedInMemoryConditionalStore](data.clone(), "state")

assert_false(a.load("part-1", "feed").is_seeded())
a.save(SurfaceCursor("part-1", "feed", "page-1", 100, 110), 3)

var seen_by_a = a.read("part-1", "feed")
var seen_by_b = b.read("part-1", "feed")
assert_true(a.try_save(SurfaceCursor("part-1", "feed", "page-2", 200, 210), seen_by_a.version))
assert_false(b.try_save(SurfaceCursor("part-1", "feed", "other", 300, 310), seen_by_b.version))
assert_equal(b.load("part-1", "feed").token, "page-2")
```

A working set is loaded from the store's head, changed in memory, and written
back as a delta of only the rows that changed. Reloading the head merges the
base with the delta, so a reader sees the rows a full rewrite would hold. The
dimension is the graph's, written once in the manifest:

<!-- mojo-hidden
from std.testing import assert_equal, assert_false, assert_true
-->
```mojo
from komira_kg import SnapshotWorkingSet, WorkingEntity, open_edge
from komira_kg_format import KgSnapshotStore, TS_OPEN_SENTINEL
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

var store = KgSnapshotStore[SharedInMemoryConditionalStore](
    SharedInMemoryConditionalStore(), "graph"
)

# First ingest: an empty set of a stated dimension, written as the base.
var first = SnapshotWorkingSet(2)
var a = first.next_nid()
var b = first.next_nid()
var v = List[Float64]()
v.append(0.5)
v.append(0.25)
first.add_entity(WorkingEntity(a, "ent-a", "part-1", "alpha", v.copy(), "", "{}"))
first.add_entity(WorkingEntity(b, "ent-b", "part-1", "beta", v.copy(), "", "{}"))
first.add_edge(open_edge(a, b, "", "alpha relates to beta", 10, 20, 10))
_ = store.write_snapshot(first.to_tables(), first.embedding_dim)

# A later ingest: load the head, change it, append only the difference.
var ws = SnapshotWorkingSet.load_latest(store)
assert_false(ws.has_delta())
ws.edges[0].invalid_at = 30  # the fact stopped holding at event time 30
ws.edges[0].expired_at = 40  # and the graph learned that at system time 40
ws.add_entity(WorkingEntity(ws.next_nid(), "ent-c", "part-1", "gamma", v.copy(), "", "{}"))
assert_true(ws.has_delta())
_ = store.append_delta(ws.delta_tables(), ws.name_index_delta())

var head = SnapshotWorkingSet.load_latest(store)
assert_equal(len(head.entities), 3)
assert_equal(head.edges[0].invalid_at, 30)
assert_equal(head.edges[0].expired_at, 40)
assert_equal(store.open_latest_chain().num_deltas(), 1)

# An embedding of another dimension is refused.
var wrong = List[Float64]()
wrong.append(1.0)
var refused = False
try:
    head.add_entity(WorkingEntity(head.next_nid(), "x", "p", "x", wrong^, "", "{}"))
except:
    refused = True
assert_true(refused)
```

A compaction folds a chain into a base, reads back the same graph, and leaves
the old chain readable to whoever pinned it. An erasure removes a partition from
the head. Top-k then ranks what is left. The times (5000, 7000) are the caller's
clock, passed in:

<!-- mojo-hidden
from std.testing import assert_equal, assert_false, assert_true
-->
```mojo
from komira_kg import (
    SnapshotWorkingSet,
    WorkingEntity,
    compact_chain,
    erase_kg_partition,
    resolve_embedding_topk,
)
from komira_kg_format import KgSnapshotStore
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

var store = KgSnapshotStore[SharedInMemoryConditionalStore](
    SharedInMemoryConditionalStore(), "graph"
)

var along_x = List[Float64]()
along_x.append(1.0)
along_x.append(0.0)
var along_y = List[Float64]()
along_y.append(0.0)
along_y.append(1.0)

var first = SnapshotWorkingSet(2)
first.add_entity(WorkingEntity(first.next_nid(), "e0", "part-1", "alpha", along_x.copy(), "", "{}"))
_ = store.write_snapshot(first.to_tables(), first.embedding_dim)

# Two deltas: a second entity of part-1 and one of part-2.
for i in range(2):
    var ws = SnapshotWorkingSet.load_latest(store)
    var part = String("part-1")
    if i == 1:
        part = String("part-2")
    ws.add_entity(WorkingEntity(ws.next_nid(), "e" + String(i + 1), part, "name " + String(i), along_y.copy(), "", "{}"))
    _ = store.append_delta(ws.delta_tables(), ws.name_index_delta())
assert_equal(store.open_latest_chain().num_deltas(), 2)

var pinned = store.open_latest_chain()
var result = compact_chain(store, 5000)
assert_true(result.compacted)
assert_equal(result.num_folded, 2)
assert_equal(len(SnapshotWorkingSet.load_latest(store).entities), 3)
assert_equal(len(SnapshotWorkingSet.load_merged(pinned).entities), 3)  # still readable
assert_equal(store.retired_age_ms(1, 6500), 1500)

# part-2 is erased; its entity is no longer a candidate.
var report = erase_kg_partition(store, "part-2", 7000)
assert_equal(report.entities, 1)
var near = resolve_embedding_topk(store.open_latest_chain(), along_y.copy(), 5)
assert_equal(len(near), 2)
assert_equal(near[0].nid, 1)
assert_equal(near[1].nid, 0)
```

## Limits

`dedup_resolve` is pure and stateless: it tests the candidates it is given, so
the caller finds them (for example by `cosine_topk` over the entity name
embeddings). Its MinHash and banding scheme is tuned for names and short
strings, not for long documents. `normalize_name` lowercases ASCII only: a name
in another script is kept byte for byte, and Unicode punctuation and case
differences are not folded.

`AliasMap` looks an id up by a linear scan and is for the mentions of one
ingest, not a whole graph. If one id is claimed as an alias of two different
canonical ids the answer depends on the order of the calls; consistent claims
give the same answer in every order.

`SnapshotWorkingSet` is for one ingest of one graph: it holds the whole graph
in memory, finds an entity by node id with a linear scan (`entity_index_of_nid`),
and expects ingest of a lineage to be serialized. `delta_tables` reads the loaded
edges and episodes by position, so it refuses a set whose edges or episodes were
removed since the load (write `to_tables` instead); an entity edited in place is
carried by the delta, found by comparing it with the row that was loaded. A
working edge carries no embedding, so the `fact_embedding` cell of every edge is
written empty. Row counts recorded in manifests are diagnostics and are not
checked against the objects. The table layouts are those of
`komira_kg_format.schemas` at version 1; a table with fewer columns is refused,
and one with more is read as the layout.

`erase_kg_partition` and `compact_chain` rewrite the whole graph in memory and
expect the lineage's ingest to be quiet; a delta a writer appends while they run
is carried onto the new head, not folded (erasure then examines it, see above).
Erasure removes the partition from the head only: earlier chunks and objects stay
(the store has no delete verb), so the erased rows remain in those objects until
the host reaps them; the old chain's deltas are retired for the host's retention
policy, and the change gate's fingerprints are not touched. The node ids of an
erased partition may be minted again once the graph is reloaded, because the
high-water mark is not stored. Between the commit that carries a tombstone of an
erased edge and the fold that drops it, a reader that merges the head fails.
`resolve_embedding_topk` scans every projection row, O(rows log k); a chain whose
deltas carry no projection (a base alone) gives no candidates, and the caller
scans the base's entities.

`apply_invalidation` only shortens an interval (never below its start) and keeps
the first system time an edge expired at, so applying a verdict twice is
harmless; it still must be called only for edges the caller confirmed.
`FacetTombstoneSet` shapes results; it does not delete rows and is not access
control. A host that must withhold data enforces that where it authenticates.

The stubs look rows up by a linear scan: they are for the handful of rows a test
registers. `StubEmbedder`'s fallback vector counts 28 character classes (ASCII
letters, digits, anything else) and folds them into the dimension it was given,
so a very small dimension discriminates less; it is a test vector, not a model.
`LlmClient` and `Extractor` both have an `extract` of the same shape; neither
trait extends the other, so a host that implements both writes it once and
passes whichever the caller asks for.

`RuleExtractor` matches ASCII case only, and a token pattern works on bytes, so
`.` stands for one byte of a multi-byte character. A token is a run of
non-whitespace with a fixed set of brackets, quotes and sentence marks trimmed
from its ends, so a rule for a shape that starts or ends with one of those marks
should use a delimited span. A name is kept once per text under its first rule,
and edges are limited to the first `max_cooccurrence_entities` findings. It
deduplicates names within one text only; resolving them against the graph is the
dedup step's job.

A cursor's object key is a 64-bit hash of its partition id and source key. The
object records both strings and a read that finds different ones raises, so a
collision is an error and never a wrong cursor. `CursorStore.list_cursors` reads
every cursor object under the prefix; it is for small sets of sources.
