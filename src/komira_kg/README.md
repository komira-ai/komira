# `komira_kg`

## Responsibility

The mutable data-graph store and its ingest. This is parts 1 and 2 of the package
described in
[the knowledge graph port](https://github.com/komira-ai/komira/blob/main/docs/design/knowledge_graph_port.md):
bi-temporal edges, entity resolution and the source facet, and the three seams
through which a host supplies a model (`Embedder`, `LlmClient`, `Extractor`),
each with a stub for tests. Later parts add the rule-driven extractor, the
working set and compaction, and ingest.

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

A facet, a source, a predicate and an entity name are opaque strings the host
supplies: the package fixes no vocabulary. Prompts are values the caller passes
in. It names no model, vendor or server and holds no network code: a model is a
trait a host (or a transport package) implements. It calls no model, reads no clock
and reads no environment; a time is always an argument, in whatever unit the
graph stamps. It depends on `komira_kg_format` (the open-interval marker) and
`komira_json` (the facet's `attrs` JSON), and no pointer crosses its API.

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
cands.append(DedupCandidate(42, "acme inc ", "a company"))
var exact = dedup_resolve("Acme, Inc.", cands, 0.7, 0.25, 2.6)
assert_true(exact.is_matched())
assert_equal(exact.tier, 1)
assert_equal(exact.nid, 42)

var fuzzy_cands = List[DedupCandidate]()
fuzzy_cands.append(DedupCandidate(7, "Acme Catalog Model", ""))
var fuzzy = dedup_resolve("Acme Catalog Models", fuzzy_cands, 0.7, 0.25, 2.6)
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
near.append(DedupCandidate(13, "Acme Inc", "a company"))
var res = dedup_resolve("Acme Incorporated", near, 0.7, 0.25, 2.6)
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
    near.append(DedupCandidate(13, "Acme Inc", "a company"))
    var judge = AlwaysSame()
    var res = dedup_resolve_judged(
        "Acme Incorporated", near, 0.7, 0.25, 2.6, judge
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
