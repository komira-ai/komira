# The search index format: what a graph store needs from it

Status: proposed, not built. Nothing in this document is in the code yet except what "The format
today" describes. It records four decisions about `komira_search`'s split format (multi-field
documents, per-document deletes with compaction, a vector region, and adjacency) so that the
maintainers of `komira_search` can accept, change or refuse each one before any code changes the
format. Each decision gives the options, a recommendation, and the proof its change must ship with.

## What is it for, and what is out of scope?

A knowledge graph is coming to komira (see [knowledge_graph.md](../knowledge_graph.md)): a labelled
property graph of nodes, edges and episodes, kept as `komira_search` splits, queried by typed
primitives (`search`, `knn`, `neighbors`, `k_hop`, `as_of`, and rank fusion of their results). This
document says what the split format and its catalog must hold for that, measured against the code
as it is.

What the graph stores, per document kind:

| kind | text fields (ranked) | keyword fields (exact) | fast fields (filter, sort, read) | vector |
|---|---|---|---|---|
| node | name, summary | node id, label, aliases (several), subjects (several) | the four bi-temporal bounds, label | one embedding |
| edge | fact | source id, destination id, predicate, subjects (several) | the four bi-temporal bounds, source id, destination id, predicate | one embedding |
| episode | content | episode id, source, subjects (several) | the four bi-temporal bounds | optional |

From that table come four needs:

1. **Several fields per document**: more than one ranked text field, and exact keyword fields with
   postings, some of them holding several values per document.
2. **Per-document deletes and compaction**: erasing every document that names a subject, first
   hidden from every query, then physically gone from the store.
3. **A vector region**: exact nearest-neighbour search over one embedding per document, filtered by
   the same predicates and deletes as text search.
4. **Adjacency**: the edges incident to a node, fast enough for a few hops.

Out of scope:

- The graph model, its schemas and its query primitives (they belong to the graph library).
- Approximate nearest-neighbour indexes (decision 3 leaves room for them behind the same query).
- Phrase queries, positions and a query language.
- Where splits are stored and who runs ingest and compaction.

A graph over code needs none of this: one text field (name plus docstring) with kind, label, path and
line as fast fields fits today's format, and its edges can be read with a keyword fast-field filter.
It does not wait on these decisions.

## The format today

Three libraries: `komira_search` (analysis, the in-memory index, the split file and the searcher),
`komira_search_catalog` (which splits are live, on an object store) and `komira_search_scan` (an index
read as the `komira.search.index` scan kind).

**The split file** (`split.mojo`) is one immutable byte image:

```
"THSPLIT" version=1 | header: field name, split uuid, doc count, min and max doc id
| term dictionary | postings | doc store | [fast fields] | [block-max] | [L0 postings]
| footer: "THSF" footer version=1, the header again, offset and length of every region,
  two reserved bloom slots, then an additive chain: [total token count] [block-max pair] [L0 pair]
| footer length u32 | "THSF"
```

- **One field per split.** The header and the footer each carry one field name; the inverted index
  builder, the term dictionary and the searcher are all "one text field" (`inverted.mojo`,
  `term_dict.mojo`, `QueryIR`).
- **Keyword fields have no postings.** The analyzer refuses to analyze a keyword field; a string
  column the sink does not index as its text field becomes a keyword fast field: a sorted dictionary
  plus one code per document, one value per document (`fast_fields.mojo`).
- **The sink drops what it cannot classify.** `SearchSink.init_sink` skips boolean, binary, nested and
  dictionary columns without an error, so a fixed-size list of floats (an embedding) is dropped.
- **The footer grows by an additive chain.** A writer may append footer slots; a reader takes a slot
  if bytes remain and ignores anything after the slots it knows. A later slot is readable only if
  every earlier slot is present, so the writer fills absent earlier slots with 0/0.
- **Document ids are split-local.** The sink numbers each split from 0; the result merge breaks ties
  on (score, doc id, split publish order) because ids collide across splits (`merge.mojo`).
- **Scores are per split.** BM25 takes the document count and document frequency from the split
  being searched.
- **A query's field is not checked against the split's.** `QueryIR.field_name` selects nothing in
  `SearchCore`: the search runs over the split's one dictionary whatever field the query names. The
  in-memory scan catalog can declare a second field on an index (`add_field`), and a scan on that
  field would then read every split of the index with its query.
- **Fast-field filters** accept conjunctions of comparisons and `IN` lists; a null cell fails every
  comparison; there is no `OR` and no null test.

**The catalog** (`komira_search_catalog`) is an append-only manifest lineage per index (or per
writer shard) on `komira_objectstore`'s CAS manifest. Each chunk is one encoded `SplitSummary`; an
empty chunk is a seal and a one-byte zero chunk is a reaped stub. `retire` tombstones a chunk and
`reap_chunk` removes it after a grace period. A merged split's summary lists the splits it absorbed,
and readers hide those while it is live. `generation()` changes on every catalog change and never
goes down. `SplitSummary` has a reserved `delete_gen_ref` slot that nothing writes or reads, and
`decode_split_summary` reads the version byte without checking it.

**What is not in komira.** No code merges splits into one: the catalog can record a merged split,
but nothing writes one. The producer of the L0-postings region is not in komira either; the split
format only carries its slot.

## Decision 1: several fields per document

**Need.** Several ranked text fields, each with its own analyzer, dictionary, postings and length
norms; keyword fields with postings (exact terms, not analyzed), possibly several values per
document; fast fields as today.

**Options.**

- (a) An additive footer slot pointing at a field directory, keeping `SPLIT_VERSION` 1.
- (b) `SPLIT_VERSION` 2 with a field directory.

**Recommendation: (b).** The additive chain is sound for what a reader may ignore: the total token
count and the block-max region change speed, never answers. A field directory changes answers. A
reader that predates it would ignore the directory and, since it never compares the query's field
with the split's, would answer a query on the second field from the first field's dictionary,
without an error. Under (b) that reader refuses the split by name ("unsupported version 2").

The version 2 layout:

- A **field directory** region. One entry per field: name, kind (text, keyword or vector), analyzer
  fingerprint (text) or embedder fingerprint (vector), and the offset and length of its term
  dictionary, postings and block-max regions (text and keyword) or of its vector region (vector).
  Text entries also carry the field's total token count and the name of the fast field holding its
  per-document token counts.
- One doc store and one fast-field region, shared by every field, as in version 1.
- A footer with the region table of version 1, the directory's offset and length, and a
  `required_features` bit set. A reader refuses a split with a bit it does not know. Later changes
  that alter answers set a bit; later changes a reader may ignore stay on the additive chain. Then
  the next such change needs no version bump.
- The L0-postings slot is kept.

A version 2 reader reads a version 1 split as a split with one text field, so no stored index needs
rewriting. The writer keeps writing version 1 when it is given exactly one text field and nothing
else, until the maintainers choose to retire it.

**Query surface.** `QueryIR` names its field and `SearchCore` refuses a field the split lacks, by name
(a new code next to `SEARCH_FIELD_AMBIGUOUS`; the same fix closes the unchecked-field gap above for
version 1). A `term` query over a keyword field matches exact values without analysis. Searching
several text fields at once is left to the caller, which fuses ranked lists.

**Several values per document.** A keyword field may come from a list of strings; each value is a
posting for the document. Fast fields stay one value per document, so a multi-valued keyword field
has postings only.

**Proof.** Before the writer changes, commit a golden of today's split bytes for a fixed corpus;
afterwards the version 2 reader must read it byte for byte as before, and a new golden pins the
version 2 bytes. Mutant: swap two field ordinals in the directory writer; the version 2 golden and a
per-field query test go red. A version 1 reader given a version 2 split must refuse it with the
exact "unsupported version" message.

## Decision 2: per-document deletes and compaction

**Need.** Delete documents by an exact key (a node id, or every document naming a subject); hide them
from every query at once; later remove their bytes from every object in the store.

A split is immutable, so a delete is a record next to it, not a change to it.

**Options for the record.**

- (a) A new manifest chunk kind, a delete set: the split's UUID and a bitmap of its deleted doc ids
  (inline when small, or the key of a bitmap object), in the same lineage as the split summaries.
- (b) Fill `SplitSummary.delete_gen_ref` by republishing the split's summary with a reference to a
  bitmap object, and have readers keep only the newest chunk per split UUID.
- (c) A separate delete lineage per index.

**Recommendation: (a).** It commits a chunk, so the generation moves with it, and a scan pinned to a
generation sees exactly the deletes committed by then: a pinned scan stays repeatable. (b) cannot
work with today's replay: the old and new summaries of one split are both live, and the merge-input
rule would hide both. (c) puts deletes outside the generation, so a pinned scan would change as
deletes land, and a reader that predates it would silently show deleted documents.

The rules for (a):

- **Union.** The deleted set of a split is the union of every live delete set for it, across writer
  shards. A deleted bit is never cleared; re-adding a document writes it to a new split. Order across
  shards then does not matter.
- **One place applies it.** `SearchCore` takes the deleted set when it is built, and every path
  consults it before a document can count: ranked matches, `match_all`, fast-field filters, sorts,
  aggregations, `knn` and adjacency reads. `total_matches` and the live document count exclude
  deleted documents.
- **Scores.** Until compaction, a deleted document still counts in BM25's document frequency and
  document count, as in Lucene. Tests compare scores only after compaction, or compare hit sets.
- **Finding the documents.** The writer of a delete looks the key up in each live split's keyword
  postings (decision 1) and writes a delete set for each split with a hit. Without decision 1 it must
  scan a keyword fast field.
- **Readers that predate it must refuse it.** Today a chunk longer than one byte is decoded as a split
  summary and its version byte is not checked. A first, separate change makes
  `decode_split_summary` refuse an unknown version by name; it ships before any writer of delete sets.
  The delete-set chunk then starts with a byte that is not `SPLIT_SUMMARY_VERSION`.
- **The scan seam.** `SearchIndexCatalog.split_at` returns split bytes only; it must also return the
  split's deleted set at the generation.

**Compaction.** A compactor merges live splits into one new split without their deleted documents,
publishes it as a merged split (the existing `merge_input_uuids` mechanism hides the inputs at once),
then retires the inputs' chunks and their delete sets, which are reaped after the grace period. It
fits `komira_objectstore`'s compaction envelope (`compact_once` over a `CompactionSource`). For
erasure the merge must drop, not just skip:

- dictionary terms left with no live posting (a term can be a name);
- keyword fast-field dictionary values no live document uses;
- doc-store blobs and vectors of deleted documents.

**The guarantee.** A delete is hidden from every query from the generation its delete set commits.
It is gone from the store once the compaction that absorbs its split has been published and the
inputs have been reaped after the grace period. Documents written after the delete are new data; a
caller that must keep a subject out has to stop writing it.

**Proof.** The test written to fail first: index documents naming subject X among others, delete by
X, assert no query returns them, compact, reap, then read every object left in the store and assert
none contains X's bytes. Mutants: skip the deleted set in one query path (each path has a test that
goes red); keep an empty term in the merged dictionary (the byte scan goes red).

## Decision 3: a vector region

**Need.** Exact k-nearest-neighbour search over one embedding per document, under the same filters
and deletes as text search, merged across splits like text hits.

**Recommendation.** One region per vector field of the field directory:

- **Fixed per field:** dimension, element type (32-bit float, little-endian), metric (cosine, dot
  product or squared Euclidean distance) and an embedder fingerprint (model, dimension, metric),
  recorded in the directory entry and in the index's catalog entry. A split whose field disagrees
  with the index, or a query vector from another embedder, is refused by name, as an analyzer
  mismatch is today.
- **Layout:** a presence bitmap (a document may have no vector), the vectors row-major and not
  normalized, and one precomputed norm per vector. Storing raw vectors keeps dot product and distance
  exact and lets cosine use the stored norms. The region starts on a 64-byte boundary of the file;
  readers still use unaligned loads, because the split bytes are not held in an aligned buffer today.
- **Search:** per split, every live document that passes the filter and has a vector is scored and
  kept in the existing bounded top-k heap; splits merge through `merge.mojo`'s score mode, with its
  tie order (score, doc id, split publish order). No approximate index in this decision; a per-split
  graph index can be added later behind the same `knn`, as an optional region, when one graph exceeds
  about a million vectors (an estimate, not a measurement).
- **Exactness:** the kernel fixes its reduction order (fixed-width lanes, then a fixed pairwise sum),
  and the test oracle repeats that order in scalar code, so scores are bit-identical and recall is 1.0
  by construction. A second test checks scores against a plain double-precision sum within a stated
  tolerance.
- **Ingest:** the sink indexes a fixed-size list of 32-bit floats as a vector field instead of
  skipping it, and refuses a vector of the wrong length.

**Size.** 1,536 dimensions take 6 KiB per document: a million documents take about 6.1 GB. Today a
scan fetches and parses a whole split, so a text query would also fetch every vector. The reader has
to fetch regions by byte range after reading the footer (the footer-first layout already allows it,
and `komira_objectstore` has ranged reads), reading the vector region only for `knn`.

**Proof.** `knn` equals a brute-force oracle over the same corpus: the same documents in the same
order. The fixtures use vectors that are not normalized and differ in norm, so the mutant that drops
the norm from cosine changes the top k and goes red. A filtered and a deleted document never appear.

## Decision 4: adjacency

**Need.** `neighbors(node)` (incident edges, both directions) and `k_hop(node, k)`.

**Options.**

- (a) Keyword postings on the edge's source and destination fields. A posting list is an adjacency
  list: the postings of term `n` in the source field are the edges leaving `n`. The other end is read
  from the edge's fast field.
- (b) A CSR region per split: for each source term ordinal, the destination ordinals and edge doc ids,
  and the same for the reverse direction.
- (c) Engine joins only.

**Recommendation: (a)** as the default, with (b) as the fallback if (a) misses the budget below, and
(c) always available for ad-hoc SQL over the `komira.search.index` scan. (a) needs nothing beyond
decision 1. (b) is an optional region a reader may ignore (postings still answer), so it would need
no version bump. One hop is a batch: the frontier is sorted, each split's dictionary is walked once
per hop, and deletes apply. Each hop costs lookups in every live split, so compaction keeps the
split count small.

**Budget, stated before the measurement.** The benchmark runs on the build farm as a Buck2 target,
single-threaded, splits in memory, from seeds of median degree, and reports p50 and p95 for (a) next
to an in-memory CSR over the same edges in the same binary:

| graph | splits | query | (a) must reach |
|---|---|---|---|
| 5,000 nodes, 50,000 edges | 1 | 3 hops | p50 at most 10 ms |
| 1,000,000 nodes, 10,000,000 edges | at most 16 | 2 hops | p50 at most 25 ms |
| 1,000,000 nodes, 10,000,000 edges | at most 16 | 3 hops, frontier capped at 10,000 nodes | p50 at most 500 ms |

These numbers are proposals derived from per-lookup estimates, not measurements; the maintainers fix
them before the run. If (a) misses a row, (b) is built and measured against the same table.

## What must always hold

- A reader refuses what it cannot answer correctly: an unknown split version, an unknown required
  feature bit, an unknown summary version, a field the split lacks, an analyzer or embedder mismatch.
  Each refusal has a test asserting its exact message.
- Ignorable additions stay on the additive footer chain, with no holes.
- A deleted document never contributes to any result from the generation its delete set commits.
- After compaction and reaping, no object holds a deleted document's bytes.
- `generation()` moves on every catalog change, delete sets included, and never goes down.
- Every version 1 split written before these changes still reads with the same results.

## Where the code will change

| decision | libraries |
|---|---|
| 1 | `komira_search` (directory, builders, writer, reader, `SearchCore`), `komira_search_scan` (field binding) |
| 2 | `komira_search_catalog` (version check first, then the delete-set chunk), `komira_search` (the deleted set in `SearchCore`; the split merger), `komira_search_scan` (`split_at`) |
| 3 | `komira_search` (region, kernel, `knn`, sink), `komira_search_scan` (ranged region reads) |
| 4 | none for (a) beyond decision 1; a benchmark target |

`split.mojo`, `fast_fields.mojo` and `source.mojo` are each over 1,000 lines; each is split by
concern before it grows.

## Order of work

1. This document, accepted or changed.
2. The summary version check (decision 2's prerequisite), and the version 1 byte golden.
3. Several fields per document (decision 1).
4. Delete sets, then the split merger and compaction (decision 2).
5. The vector region and `knn` (decision 3), with ranged reads.
6. The adjacency benchmark against the budget (decision 4).

## Open questions for the maintainers (recommendation first)

1. Version 2 with a field directory and a `required_features` set, or an additive directory slot?
   Recommend version 2.
2. Keep writing version 1 for single-field splits, or always write version 2? Recommend version 1
   until every reader of stored indexes reads version 2.
3. Where the index's field schema lives: today `SplitSummary` holds one field name and the scan
   catalog holds a field list. Recommend the field list (with analyzer and embedder fingerprints) in
   the index's catalog entry, and `SplitSummary.field_name` as the first text field.
4. Delete sets as a new chunk kind with union semantics, inline bitmap up to a size, object above it?
   Recommend yes, inline up to 64 KiB.
5. Does `delete_gen_ref` stay reserved, or is it removed? Recommend it stays reserved and unused.
6. Who builds the split merger and compactor on `compact_once`, and with which merge policy?
7. Ranged region reads in the scan reader, or a sibling vector object per split? Recommend ranged
   reads: a sibling object doubles the catalog, reap and erasure bookkeeping.
8. The adjacency budget table: confirm or change the numbers before the benchmark runs.
9. The unchecked query field: fix it now for version 1 with a failing test first, or with decision 1?
   Recommend now; it is a wrong answer, not a missing feature.
