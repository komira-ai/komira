# Storing a graph over data: tables with a snapshot manifest, or search splits

Status: proposed, not built. No graph over data is in komira. This document puts two ways of storing
one side by side so that the choice is made before any code is written, and recommends a third that
combines them. It does not change [search_index_format.md](search_index_format.md); it says which of
that document's decisions such a graph depends on under each choice.

## What is being decided?

A graph over data is a labelled property graph of nodes (entities), edges (facts between two nodes)
and episodes (the raw records the facts were extracted from), each with the four bi-temporal bounds:
when a fact became true and stopped being true (event time), and when the system learned it and
learned it was superseded (system time). It is queried by `search` (ranked text), `knn` (embedding
similarity), `neighbors` and `k_hop` (traversal), `as_of` (a time slice) and rank fusion of those
results.

The two options:

- **Option A: tables plus a snapshot manifest.** The graph is a set of columnar tables (`episodes`,
  `entities`, `edges`, later `communities`), each written as an immutable, content-addressed object.
  A snapshot is one chunk on a `komira_objectstore` CAS manifest that lists the table objects; a
  query opens a snapshot and reads tables. Traversal is a join or a breadth-first search over the
  `edges` table; similarity is an exact scan over an embedding column.
- **Option B: search splits.** Nodes, edges and episodes are documents in `komira_search` splits
  (the per-kind table in [search_index_format.md](search_index_format.md)). Adjacency is keyword
  postings on an edge's source and destination fields; similarity is a vector region in the split;
  deletes are delete sets in the split catalog.

Out of scope: the graph model and its extraction, the query API, approximate nearest-neighbour
indexes (both options start exact), and who runs ingest.

## What did an earlier implementation learn?

An earlier internal implementation of a graph over data, not in this repository, used Option A. It
is the only design of this kind that has been run, so its record is evidence for both options. Its
library header stated the principle: "The KG is *files*, not a database." Its design:

- **Snapshots on the CAS manifest, no new coordination code.** Each table was serialized to Parquet
  in memory, keyed by a hash of its bytes (an unchanged table was not uploaded again), and listed
  with its schema version and row count in one manifest chunk. Old snapshots stayed readable.
- **History in the rows, never deleted.** A superseded fact was not removed: its event-time end was
  set to the new fact's start and its system-time end to the time of the supersession, so `as_of(T)`
  is the filter `valid_at <= T and invalid_at > T` over one table. Its rule was "never delete, always
  retain"; in its own words, "History is the whole point." An open interval was a sentinel value,
  not a null, so the filter needed no null handling.
- **Whole-table rewrites did not scale, so it moved to a base plus deltas.** Rewriting a changed table
  in full made one small ingest a rewrite of the whole table, and embeddings dominated the bytes
  (1,536 32-bit floats, about 6 KiB, per entity). It moved to a chain on the same manifest: a head
  chunk naming a base snapshot and an ordered list of delta chunks, each delta holding only added
  rows and narrow supersession rows (the edge's key, its new event-time end, its new system-time end).
  A read applies the deltas to the base in order. A fold rewrote the base when there were 32 deltas
  or the deltas reached half the base's bytes.
- **Loading the graph to change it was the real cost.** Resolving whether an entity already existed
  loaded the full tables. The fix was a small exact name-to-id index that rode on each delta, and a
  projection of only ids and embeddings for near-duplicate search.
- **Long-lived readers kept the merged graph in memory.** A process loaded base and deltas once and
  then applied each new delta; a cold start paid the full load.
- **Reads went through the engine, with workarounds.** Traversal was a one-hop inner join of `edges`
  with `entities`, iterated breadth-first for `k` hops; `as_of` was a filter; similarity was an exact
  SIMD cosine over the embedding column with a bounded top-k; text search over facts was a substring
  scan, not a ranked search. With no Parquet reader over bytes, each read wrote the table's bytes to a
  temporary file and read that. With no writer for fixed-size lists, embeddings were stored as packed
  bytes in a string column, which then had to be read by length because the bytes contain zeros.
- **Erasure rewrote the snapshot.** Many groups shared one lineage with the group as a column, so
  deleting objects by prefix would have deleted other groups. Erasing a group filtered its entities
  and episodes out, dropped every edge with an erased endpoint, wrote a new snapshot and left the old
  objects to be reaped once nothing live referenced them. A later design made an entity delete a
  tombstone row in a delta, hidden on read and dropped at the next fold.
- **It chose not to build on the search engine.** Its embedding-only search layer, written later
  against the same raw corpus, records the decision at the top of its source file: "the verdict:
  REUSE the [graph library's] embedder primitives — NOT komira_search, NOT a greenfield build". The
  record gives the reasons as reuse (the same embedder, so its similarity scores were comparable with
  the graph's; the same packed embedding column and cosine kernel; the same result format) and gives
  no measurement against the search engine.

What it did not settle: it never measured traversal at the scale below, it never had a ranked text
index over facts, and its erasure did not say what happens to snapshots older than the erasure.

## What can komira write today?

Checked against `src/` and [architecture.md](../architecture.md#layers-still-to-come):

| capability | in komira | consequence |
|---|---|---|
| CAS manifest, conditional writes, `compact_once` | yes (`src/komira_objectstore/cas_manifest.mojo`, `compact_window.mojo`) | both options have their catalog substrate |
| Parquet writer | **no**; and no Parquet column reader or scan either (`komira_parquet` has the value decoders and the footer and page-header readers) | Option A cannot store Parquet tables yet |
| Arrow IPC | yes: record-batch, schema and footer message encoders and decoders, fixed-size lists included (`src/komira_arrow_ipc/ipc_encoder_dispatch.mojo`, `ipc_encoder_nested.mojo`) | Option A can store tables as Arrow IPC objects today |
| search splits | yes, one text field per split, keyword fast fields single-valued, no deletes, no vectors (`src/komira_search/split.mojo`, `sink.mojo`) | Option B needs decisions 1 to 4 of [search_index_format.md](search_index_format.md) first |
| engine execution (joins, sort, top-N) and the SQL parser and binder | **no** (plan types, optimizer rules and the SQL tokenizer and syntax tree are here) | neither option can serve traversal through SQL yet; "reuse the engine" is a future benefit |

## How do the options compare?

The scale is the one [search_index_format.md](search_index_format.md#decision-4-adjacency) states:
5,000 nodes and 50,000 edges, and 1,000,000 nodes and 10,000,000 edges, with 1,536-dimension
embeddings. The budgets are proposals, not measurements; every latency figure below is an estimate
from byte counts, and the benchmark settles it.

| | Option A: tables plus snapshot manifest | Option B: search splits |
|---|---|---|
| 1 to 2 hops, warm | the reader holds an `edges` projection (ids and the four bounds, about 56 bytes per edge: about 0.6 GB at 10M edges) as an in-memory CSR; a 2-hop expansion from a median-degree seed touches thousands of edges: well under the 25 ms budget | posting lookups in every live split per hop, deletes applied; the 25 ms budget for 2 hops at 16 splits is unmeasured, with a CSR region as the fallback |
| 1 to 2 hops, cold | load base plus deltas first: about 0.6 GB for the projection if it is its own object, tens of GB if embeddings sit in the same object (10M edges at 6 KiB); seconds either way | fetch the splits; today a split is fetched whole, vectors included, so ranged region reads are needed |
| similarity (`knn`, exact) | same cost in both: 1M vectors at 6 KiB is 6.1 GB scanned, roughly 0.3 to 0.6 s on one core at 10 to 20 GB/s; 5,000 vectors is 30 MB, a few ms. Neither meets an interactive budget at 1M without an approximate index | same as A |
| ranked text | none: the earlier implementation scanned for substrings | BM25 over postings, today's strength of the format |
| update (supersede a fact) | a delta with a narrow supersession row; no rewrite until the fold | a split is immutable, so changing an edge's event-time end is a delete set plus a re-added document: the delete machinery of decision 2 is on every ingest, not only on erasure |
| erasure and its deadline | hide: a tombstone row in a delta, filtered on read. Remove: a fold that writes the base without the subject's rows, then reaping every older base and delta object after the grace period; the deadline is the fold interval plus the grace period plus one reap pass. Rewrites a whole table, or one partition if tables are partitioned by subject group | hide: a delete set per split. Remove: the merge policy must select every split a delete set resolves to, with the input-map rules for a delete that races a merge (decision 2): several new mechanisms, each with its own test |
| bi-temporal history | in the rows; `as_of` is a filter on one table; old snapshots also stay readable until reaped | the four bounds as fast fields; `as_of` is a fast-field range filter; history depends on superseded documents being re-added, not hidden |
| what komira can write today | Arrow IPC objects and the manifest: yes; Parquet: no | splits with one text field: yes; everything a graph needs: no |
| engine and SQL reuse | tables are what a scan reads: once the Parquet reader and the engine land, SQL over the graph is a scan of its tables, joins included | the `komira.search.index` scan kind reads splits as hit rows; ad-hoc SQL works, but traversal and history live in search-specific code |
| operational complexity | one lineage per graph (or per partition); one fold per lineage, which is the contiguous-range fold `compact_once` already implements; reaping by reference | split catalog, delete sets, a ported merger and compactor whose merge policy drives erasure, input maps composed across merges; `compact_once` does not fit (decision 2 says why) |

## Recommendation: tables as the source of truth, search splits as an index

Neither option alone serves every query. Option A stores and updates the graph simply, keeps history
in the rows, erases by rewriting, and is what the engine will scan; it has no ranked text. Option B
ranks text well, but makes every supersession a delete and puts the race rules of decision 2 under
both ingest and erasure. So:

1. **The tables are the graph.** `episodes`, `entities`, `edges` (later `communities`) as immutable
   objects on a CAS manifest lineage, a base plus a chain of deltas, folded by a policy of the
   earlier kind. History lives in the rows. Embeddings are their own object per table (key plus a
   fixed-size list of 32-bit floats), so a traversal or text load never fetches them.
2. **The object format is Arrow IPC until komira has a Parquet writer and reader,** recorded per table
   entry in the manifest next to the schema version, so Parquet can follow without rewriting old
   snapshots.
3. **Traversal reads a resident CSR** built from the `edges` projection and kept current by applying
   each delta, as the earlier implementation did with its merged graph. It is measured against the
   budget table of [search_index_format.md](search_index_format.md#decision-4-adjacency).
4. **Ranked text is a derived search index.** Splits are built from a snapshot and record the
   snapshot they were built from. Every hit is checked against that snapshot's live rows (and the
   newer deltas the reader holds) before it is returned, so a superseded or erased row never
   surfaces even while the index lags. The index holds nothing the tables do not: after an erasure
   fold, the affected splits are rebuilt from the new base, and the old ones retired and reaped,
   within the same deadline.
5. **Similarity is exact over the embedding objects** with a fixed reduction order, until one graph
   needs an approximate index; that index is then derived from the tables like the text index.

This keeps the earlier design's working parts (files, the manifest, history in rows, deltas and
folds) and adds what it lacked (ranked text, embeddings outside the hot tables, a bytes reader
instead of a temporary file, an erasure that states what happens to old snapshots).

**Erasure under the recommendation.** A delete hides the subject from the delta that records it:
the reader filters tombstoned rows, and index hits are checked against the live rows. The next fold
writes a base without the subject's rows; every older base and delta object, and every index split
built from them, is retired and reaped after the grace period. History of other subjects survives
because it is in the rows of the new base; snapshots older than the erasure are no longer readable,
which the graph's documentation must say. Tables partitioned by subject group bound the rewrite to
one partition.

**Proof the recommendation must ship with.** A graph of a fixed corpus with a superseded fact; the
test asserts `as_of` before and after the supersession, deletes a subject, asserts no query (text,
`knn`, traversal, `as_of`) returns it, folds, reaps, and reads every object left in the store,
asserting none contains the subject's bytes. Mutants: skip the live-row check on index hits (the text
query returns the subject before the rebuild, so the test goes red); omit the index rebuild from the
erasure fold (the byte scan goes red); drop the system-time bound from the supersession row (`as_of`
over system time goes red).

## What it means for the search format decisions

| [search_index_format.md](search_index_format.md) | under the recommendation |
|---|---|
| the summary version check, the L0 refusal, the unchecked query field | still needed now: each is a wrong answer or a silent misread in today's format, graph or not |
| decision 1, several fields per document | not a graph prerequisite: one index per document kind and text field fits today's format, with ids as keyword fast fields; still the right design when a text index needs several fields |
| decision 2, deletes and compaction | not a graph prerequisite: the graph hides through its tables and erases by rebuilding derived splits; still needed by any index that is its own source of truth |
| decision 3, a vector region | deferred: vectors live in the tables' embedding objects; revisit with an approximate index |
| decision 4, adjacency by postings | not used by the graph; the budget table is reused for the CSR |

## Decisions to make (recommendation first)

1. Where the graph lives: tables plus a snapshot manifest, search splits, or tables as the source of
   truth with a derived search index? Recommend the hybrid.
2. The table object format before a Parquet writer exists: Arrow IPC now with a per-table format tag,
   or wait for Parquet? Recommend Arrow IPC now.
3. Embeddings in their own object per table, as a fixed-size list? Recommend yes.
4. Supersession as narrow delta rows that set the two end bounds, never a delete? Recommend yes.
5. Erasure as a fold that writes a base without the subject, then reaps every older object and
   derived split after the grace period, with old snapshots unreadable after it; deadline set per
   graph? Recommend yes.
6. Partition the tables by subject group so an erasure rewrites one partition? Recommend yes; the
   number of partitions is fixed with the benchmark.
7. Index hits checked against the snapshot's live rows, with each split recording its source
   snapshot? Recommend yes.
8. Traversal by a resident CSR over the `edges` projection, measured against the existing budget
   table, with postings adjacency only if the CSR misses it? Recommend yes.
9. Which search format changes go ahead now? Recommend the three correctness fixes (summary version
   check, L0 refusal, unchecked query field) and the version 1 byte golden now; decision 1 when a
   text index needs several fields; decision 2 when an index is its own source of truth; decisions 3
   and 4 not for the graph.
10. The budgets: as proposed, 3 hops p50 at most 10 ms on the small graph and 2 hops at most 25 ms
    on the large one;
    exact `knn` p50 at most 10 ms at 5,000 vectors; and at 1,000,000 vectors, either accept a
    budget in the hundreds of milliseconds or require an approximate index. Recommend the
    approximate index before a graph that size is served interactively.
