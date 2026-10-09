# Storing a graph over data: Iceberg tables, a delta tail and derived indexes

Status: proposed, second revision, not built. No graph over data is in komira.

The first revision put two ways of storing such a graph side by side (tables on a CAS manifest, or
`komira_search` splits) and recommended a hybrid: tables as the source of truth, search splits as a
derived index. That comparison is kept below as the rationale. This revision moves the tables onto
the storage stack of [storage_stack.md](storage_stack.md) (PR #1134, second revision):

- **The graph's tables are Iceberg tables in the user's catalog.** The CAS-manifest base, its
  delta chain and its fold are withdrawn for durable data.
- **komira keeps a graph-delta tail** (Arrow IPC deltas on a komira lineage) for sub-second writes,
  and it rolls into the Iceberg tables.
- **CSR adjacency, the text index and the vector index are derived,** each bound to pinned snapshots
  of the graph's tables, under that document's read rule.
- **The graph has no query API of its own.** Its operators are spelled in the same optimized plan as
  search, topics and vectors ([optimized_plan_sources.md](optimized_plan_sources.md) §15, PR #1094):
  the tables are `komira.iceberg.table` scans in one pin group, text search and similarity are
  access paths on those scans, and traversal is the plan's Expand node. Every SDK that builds plans
  can query the graph.
- **An open interval is a null,** with the bound columns named as that document's time slice names
  them (`valid_from`, `valid_to`); the first revision's sentinel is withdrawn.

This document does not change [search_index_format.md](search_index_format.md); it says which of
that document's decisions the graph depends on.

## What is being decided?

A graph over data is a labelled property graph of entities (nodes), edges (facts between two
entities) and episodes (the raw records the facts were extracted from), later with communities
(clusters of entities and their summaries). Every fact carries four bi-temporal bounds: when it
became true and stopped being true (event time), and when the system learned it and learned it was
superseded (system time). It is queried by `search` (ranked text), `knn` (embedding similarity),
`neighbors` and `k_hop` (traversal), `as_of` (a time slice) and rank fusion of those results.

Decided here: where each part of the graph is stored, how a write becomes durable, how readers see
a consistent set of tables, how erasure reaches every copy, and what the query side needs from the
plan. Out of scope: the graph model's schemas and its extraction, who runs ingest, and approximate
nearest-neighbour indexes (similarity starts exact).

## What changed from the first revision

| first revision | this revision | why |
|---|---|---|
| tables as immutable objects on a `komira_objectstore` CAS manifest lineage | four Iceberg tables committed through the user's catalog | storage_stack.md decision 1: durable tables are native Iceberg tables, readable by the user's other tools with no export |
| a base plus a chain of IPC deltas, folded at 32 deltas or half the base's bytes | a graph-delta tail that rolls into the tables within `target_lag`; Iceberg maintenance compacts the tables | storage_stack.md decision 6 and [the roll](storage_stack.md#the-roll); "IPC remains the tail format, and a graph table is in IPC only until its first roll" |
| Arrow IPC as the table format until a Parquet writer exists, with a format tag per table entry | Parquet data files in Iceberg; IPC only in the tail | storage_stack.md withdraws IPC as a durable table format and the per-entry format tag |
| embeddings as their own object per table | an embedding column in the tables; Parquet projection keeps it out of traversal and text reads | a columnar file already gives what a separate object gave |
| one snapshot is one manifest chunk listing every table | a graph snapshot is a recorded set of Iceberg snapshot ids, one per table, plus a tail position | most catalogs do not commit several tables atomically (storage_stack.md, "do not design on multi-table atomicity") |
| erasure as a fold plus reaping | the five Iceberg erasure steps, then indexes, tail and content cache, with a per-owner report | [Erasure](storage_stack.md#erasure) |
| index splits record the snapshot they were built from | every index generation is bound to (catalog, table uuid, Iceberg snapshot id, covered files) and read under the read rule | [L4: derived indexes](storage_stack.md#l4-derived-indexes) |
| the query API out of scope | the graph's operators are scans, access paths and the Expand node of the optimized plan | one logical plan for search, topics, vectors and the graph |
| bounds `valid_at`, `invalid_at` (and two system-time bounds), an open interval a sentinel timestamp | bounds `valid_from`, `valid_to`, `recorded_from`, `recorded_to`; an open interval is a null | the plan's `as_of` filter (optimized_plan_sources.md §15.7.3) tests `valid_to IS NULL`; a sentinel depends on the readers (see [The tables](#the-tables)) |

Kept from the first revision: the tables are the source of truth, history lives in the rows, a
superseded fact is closed and never deleted, traversal can read a resident CSR, ranked text is a
derived index whose hits are checked against the snapshot, similarity is exact until a graph needs
an approximate index, and the budgets.

## The design

### The tables

Four Iceberg tables per graph, in a namespace the user names, created by komira (so komira is their
maintainer unless an active optimizer is detected, storage_stack.md decision 4):

| table | key | other columns |
|---|---|---|
| `episodes` | `episode_id` | `group_id`, source, content, the four bounds, `embedding` |
| `entities` | `entity_id` | `group_id`, name, labels, summary, the four bounds, `embedding` |
| `edges` | `edge_id` | `group_id`, `src_id`, `dst_id`, label, fact text, the episode ids it came from, the four bounds, `embedding` |
| `communities` (later) | `community_id` | `group_id`, member ids, summary, the four bounds, `embedding` |

- **Keys are Iceberg `identifier-field-ids`,** so every derived index stores key columns and can
  remap its entries by key after another tool compacts a table (the `replace` row of
  [Detecting new snapshots](storage_stack.md#detecting-new-snapshots)).
- **The four bounds are timestamps, and an open interval is a null.** Event time is `valid_from`,
  `valid_to`; system time is `recorded_from`, `recorded_to`. `as_of(t)` is the filter
  [optimized_plan_sources.md](optimized_plan_sources.md) §15.7.3 builds,
  `valid_from <= t AND (valid_to IS NULL OR valid_to > t)`, and the same over system time. That
  section names only the event-time columns; the system-time names are this document's. Rejected:
  the first revision's sentinel (the largest timestamp every reader accepts). That timestamp is a
  property of the reader set, not of the data: Iceberg's microsecond timestamps reach far past the
  nanosecond timestamps some dataframe libraries use, so adding a reader can change the sentinel and
  rewrite every open row; and another tool's SQL would have to know the sentinel to tell an open
  fact from one that ends in the distant future. The null costs one `IS NULL` clause, which the plan
  builds, and Iceberg manifests record null counts, so pruning still works.
- **The embedding is a `list<float>` column.** Iceberg has no fixed-size list, so the dimension and
  the embedding model are table properties (`komira.graph.embedding.dim`,
  `komira.graph.embedding.model`) and the writer refuses a row of another length. A vector read
  (a VECTOR access path, optimized_plan_sources.md §15.5.1) accepts a `list<float32>`, `list<float16>`
  or `list<int8>` column only when that property declares its dimension, checks every row's length
  against it on read, and presents the column as an Arrow `FIXED_SIZE_LIST`. Traversal and text
  reads project the column away, so they never fetch it. Rejected: an opaque binary column (other
  tools cannot compute on it, and the first revision's earlier implementation had to read such bytes
  by length because they contain zeros); embeddings only in the index's content cache (a retired
  model would make the graph's similarity unrebuildable, and ingest needs them to find
  near-duplicate entities anyway).
- **Partitioned by `bucket(N, group_id)`,** with `group_id` among the erasure `subject_keys`, so its
  manifest metrics are counts only and an erasure rewrites the files of one bucket. storage_stack.md
  refuses identity and truncate partitioning on a subject key; a bucket transform is allowed.

### The write path: a graph-delta tail that rolls

A write (one ingest of an episode and the facts extracted from it) is one delta on the graph's tail,
a komira L1 lineage. A delta is an Arrow IPC object holding, per table:

- added rows;
- narrow supersession rows: the key, the new `valid_to` and the new `recorded_to`;
- tombstones: the key of a row hidden by an erasure request.

A delta is visible to komira readers when its append commits. The roll ([the
roll](storage_stack.md#the-roll)) moves a contiguous span of deltas into the tables:

- **Added rows are appended.** A supersession row becomes an upsert of the fact's row with its two
  end bounds closed: a position delete of the old row and an append of the closed one, the upsert
  mode of the roll keyed on `edge_id` (or the table's key). The fact is never removed; its closed
  version replaces its open version in the current snapshot, and the open version stays readable in
  older snapshots until they expire.
- **Tables commit in a fixed order: `episodes`, `entities`, `edges`, `communities`.** An edge then
  never becomes visible to another tool before its endpoints and its episode. A roll that carries
  tombstones deletes in the reverse order, so no tool sees an edge whose endpoint is gone. Where the
  catalog advertises `commit_transaction` (Polaris, Nessie, komira's own catalog), the roll uses it
  instead, and the order no longer matters.
- **Each table carries the tail watermark** as the table property
  `komira.tail.<lineage>.watermarks`, set in the same commit as its rows.
- **After the last table commits, the roll appends a graph snapshot record** to the tail lineage:
  per table (table uuid, Iceberg snapshot id), and the tail position the roll covered. That record
  is what a komira reader, an index generation and an optimized plan pin.

`target_lag` defaults to 60 seconds, as for topics (storage_stack.md decision 7). Ingest that
resolves "does this entity exist" reads through a resident reader pinned like any other (the
first revision's earlier implementation showed that loading the whole graph per write was the real
cost); its name-to-id map is a derived index, rebuilt from the tables.

### The read path

A komira reader of the graph:

1. pins the tail (its latest graph snapshot record and the deltas above it);
2. loads each table at the snapshot id the record names. If another tool has compacted the table
   since, and every snapshot after the recorded one is a `replace` (same rows, new files), the
   reader may read the current snapshot instead. Otherwise, if the recorded snapshot has expired,
   it fails with a named error rather than read a set of tables that do not belong together
   *(inferred; the prototype must cover it)*;
3. checks each table's watermark against the pinned tail and never reads across a gap, as for
   topics;
4. applies the deltas above the watermark: appends added rows, closes superseded bounds, hides
   tombstoned keys.

Other tools see the tables as plain Iceberg tables. Between two table commits of one roll, they may
see skew between the tables (storage_stack.md says so); the commit order above bounds that skew to
"newer facts missing", never "an edge without its endpoint".

### Derived indexes

Three derived indexes, each an L4 artifact under a prefix outside every table location, each with a
generation bound to a graph snapshot record (the table uuid and snapshot id of each table it reads,
and the files it covers), and each rebuildable from the tables:

- **CSR adjacency** over the `edges` projection (ids, label and the four bounds, about 56 bytes per
  edge: about 0.6 GB at 10M edges), forward and backward. A long-lived reader keeps it resident and
  applies each delta and each new graph snapshot record; a cold reader loads the persisted
  generation instead of rebuilding it from Parquet.
- **The text index:** `komira_search` splits over entity names and summaries, fact text and episode
  content, one index per kind and text field (today's one-field split format suffices).
- **The vector index:** over the `embedding` columns. Exact (a scan of the column with a fixed
  reduction order) until a graph needs an approximate index; the builder fingerprint names the
  embedding model from the table properties.

Every index follows [the read rule](storage_stack.md#the-read-rule): a query at a graph snapshot uses
a generation only if each of its table snapshots is the query's or an ancestor of it; with
`consistency="index"` (the default) uncovered rows are omitted and reported as lag, with
`consistency="exact"` they are scanned (for vectors, under a byte budget that fails by name); and
every hit is checked against the pinned snapshot, the `as_of` filter, and the tail's supersession
rows and tombstones. So an index may lag the tail and the tables, but no superseded, deleted or
erased row is ever returned. The tail is small by construction (at most `target_lag` of writes), so
its rows are always read exactly: scanned for text, brute-forced for vectors, and overlaid on the
CSR.

### Erasure

`km.erase` on the graph's tables follows [Erasure](storage_stack.md#erasure) with the graph's
cascade:

1. **Hide at once:** a delta with tombstones for the subject's entities and episodes and for every
   edge with an erased endpoint. Readers filter them, and index hits are checked against them.
2. **Remove from the tables,** where komira is their maintainer: row deletes in the reverse commit
   order, the fold (a rewrite of the affected data files, one bucket of `group_id` when the subject
   is a group), the manifest rewrite, expiry of every snapshot that still references the old files
   or manifests, and deletion of unreferenced files. Where another tool maintains the tables (a
   catalog that forces `external`, such as S3 Tables, or a detected active optimizer), komira
   commits the row deletes and the report says the rest is awaiting the table's maintainer, as
   storage_stack.md's erasure report does.
3. **Remove from komira's artifacts:** every index generation (CSR, text, vector, name-to-id) whose
   coverage includes a rewritten or deleted file is rebuilt and the old one purged; the subject's
   tail deltas are rewritten without its rows; the content cache entries of its values are purged.
4. **Report** per artifact, as storage_stack.md journey 5 says, within one deadline per graph.

The history of other subjects survives, because it is in the rows. Snapshots older than the
erasure stop being readable, through komira and through Iceberg time travel in any tool, and the
graph's documentation must say so. An optimized plan pinned to such a snapshot is refused as stale
when it next runs; it never returns the erased rows.

### The query side: one plan for every source

The graph's operators are not a graph API beside the plan. They are spelled with the source kind,
access paths and plan nodes that [optimized_plan_sources.md](optimized_plan_sources.md) §15 defines
(§15.7 for the graph), so the Python, TypeScript and Mojo SDKs build the same plan bytes and a
query can join graph results with any other relation. That document is the authority; this table
says how each graph operator maps onto it:

| graph operator | in the plan |
|---|---|
| reading a table | a `komira.iceberg.table` scan per table, with its `tail`, all in one pin group (§15.3.4, §15.7.1). The group's `lineage` and `commit_seq` name this document's graph snapshot record, and the host refuses a member whose (table uuid, snapshot id) differs from it. There is no graph scan kind |
| `search` | a `TEXT` access path (§15.5.1) on the scan of `entities`, `episodes` or `edges`, naming the text index generation among the scan's pinned indexes; the scan returns the table's own rows with a score, so no join back to the table is needed. `komira.search.index` remains the kind for log search only |
| `knn` | a `VECTOR` access path on the same scans, over the `embedding` column; the literal query is embedded when the plan is optimized (§15.12 decision 3). There is no vector scan kind |
| `neighbors`, `k_hop` | the Expand node (`WireExpandNode`, §15.7.2) over a seed relation (often `search` or `knn` hits) and a scan of `edges`. Its semantics are those of iterated joins: `NEIGHBORS` with `max_hops = k` equals `k` rounds of an inner join of the frontier with `edges`, a union and a least hop count per node. Its `access` (`CSR`, reading this document's CSR generation pinned on the `edges` scan, or `HASH`, adjacency built from the scan at run time) is chosen by the optimizer, and the host obeys it |
| `as_of` | the filter of [The tables](#the-tables) on the four bounds, built by the SDK and pushed into each graph scan (§15.7.3); it is part of the plan's digest and is applied to every index hit and every traversed edge (§15.5.4) |
| rank fusion | `km.rrf`: a row-number window per input, a full join on the key and `sum(1 / (c + rank))`; no new node |
| consistency mode, exact-mode budget | the `consistency` of each access path and of the Expand node's `CSR` access, and `exact_budget_bytes`: part of the plan, not advice, because they change the answer |

## How others store knowledge graphs

Sources were read when this revision was written; products change, so re-check a row before
relying on it.

| system | how the graph is stored | adjacency | what it is built for |
|---|---|---|---|
| [Neo4j](https://neo4j.com/docs/operations-manual/current/database-internals/store-formats/) | a native store of fixed-size node and relationship records; a relationship record points to its two endpoints and to the next relationship of each. The block format, the Enterprise default, places a node's properties and first relationships in one 128-byte block "drastically reducing the amount of pointer chasing" | pointers between records ("index-free adjacency"): a hop costs the degree of the node, not the size of the graph | many small transactions that read and change topology; deep and variable-length traversal from a few starting nodes |
| [Amazon Neptune](https://docs.aws.amazon.com/neptune/latest/userguide/feature-overview-storage-indexing.html) | every vertex label, edge and property is a quad (subject, predicate, object, graph); three statement indexes by default (SPOG, POGS, GPSO), a fourth (OSGP) optional | range scans on an index key prefix | RDF with SPARQL, and property graphs with Gremlin and openCypher, on one quad store |
| [Kùzu](https://www.cidrdb.org/cidr2023/papers/p48-jin.pdf) ([code](https://github.com/kuzudb/kuzu)) | embedded and columnar: "structured node properties are stored in vanilla column files"; edges are "double indexed and stored in CSR-based adjacency list indices" | CSR as a join index, forward and backward; factorized intermediate results and worst-case-optimal joins | analytic many-to-many and recursive joins in one process. The repository is archived, and Graphiti marks its Kùzu backend deprecated because upstream is unmaintained |
| [Apache GraphAr](https://graphar.apache.org/docs/specification/format) (incubating) | a file format, not an engine: vertex and edge chunks in Parquet, ORC, CSV or JSON, with property groups so a read fetches only the columns it needs | edges ordered by source or destination with offset files (CSR or CSC), or unordered (COO) | graph data at rest in a data lake, readable by any engine |
| [PuppyGraph](https://docs.puppygraph.com/) | no copy: a schema maps existing lake and warehouse tables (Iceberg, Delta, Hudi and others) to vertices and edges | computed by its engine at query time | Cypher and Gremlin over data that already lives in tables |
| [Microsoft GraphRAG](https://microsoft.github.io/graphrag/index/outputs/) | an indexing pipeline writes Parquet tables: documents, text units, entities, relationships (an edge list with source, target and weight), communities and community reports | none stored: an edge list | offline extraction and summarization for retrieval |
| [Graphiti](https://github.com/getzep/graphiti) ([Zep paper](https://arxiv.org/abs/2501.13956)) | a bi-temporal model: episodes (the raw input), entities, fact edges with valid and invalid times and created and expired times, and communities; "old facts are invalidated — not deleted"; retrieval combines embeddings, BM25 and traversal. Stored in a graph database: Neo4j, FalkorDB or Neptune | the backend's | incremental agent memory, one episode at a time |

**What komira takes from them.** The model is Graphiti's: episodes, entities, edges and
communities, four bounds, invalidate rather than delete. The storage is the GraphAr and GraphRAG
idea, a graph as columnar tables in a lake, held where PuppyGraph reads it (the user's own tables,
with no copy). Traversal is Kùzu's: a CSR over columnar edges, used as a join index, because, in
that paper's words, "at their cores, GDBMSs are relational": they map traversal to joins.

**When columnar tables with a CSR index are the right store** *(inferred from the sources above
and the budgets below)*:

- writes arrive as batches: an episode is extracted by a model in seconds, so a tail with a
  `target_lag` roll keeps up, and sub-second visibility comes from the tail, not the table;
- queries are a few hops (1 to 3) from seeds that come from text or similarity search, followed by
  filters, ranking and aggregation, which are relational work;
- the whole graph is also analysed (degrees, communities, exports), which are scans;
- other tools must read the same data, history is kept in rows, and erasure, permissions and
  backup follow the user's lake;
- the `edges` projection of the graph, or of one partition, fits a reader's memory: about 56 bytes
  per edge, 0.6 GB at 10M edges.

**When a native graph store is the better choice:**

- many small concurrent transactions each read and change topology and must see each other's
  writes at once (live fraud rings, network inventory);
- queries are deep or unbounded (shortest paths, variable-length patterns, reachability) over a
  graph larger than one reader's memory, where pointer chasing through a buffer pool beats
  rebuilding or paging a CSR;
- the data is open-world RDF with inference, which a triple store serves;
- the application wants Cypher, Gremlin or SPARQL and a graph database's tools more than SQL and
  lake interoperability.

komira's graph is the first kind: built by batch extraction and read by hybrid retrieval with short
hops. komira does not try to be a transactional graph database; a workload of the second kind can
read the same tables into one.

## What can komira do today?

Checked against `src/` on `main` when this revision was written:

| capability | in komira | consequence |
|---|---|---|
| an Iceberg catalog client | read-only: `IcebergCatalog.load_table` with a storage-based and a REST implementation (`src/komira_iceberg_catalog/`); no commit, no writer | the tables need storage_stack.md's order of work, steps 1 and 2 |
| Parquet | a reader (`src/komira_parquet/file_reader.mojo`, the decoders and gathers); no writer | the tables need the Parquet writer, step 1 |
| Arrow IPC | record-batch, schema and footer encoders and decoders, fixed-size lists included (`src/komira_arrow_ipc/`) | the tail's delta format exists |
| CAS manifest, conditional writes | yes (`src/komira_objectstore/cas_manifest.mojo`, `compact_window.mojo`) | the tail lineage's substrate exists |
| search splits | one text field per split, keyword fast fields single-valued, no deletes, no vectors (`src/komira_search/`) | enough for the derived text index |
| scan kinds | `komira.search.index` (`src/komira_search_scan/search_scan_kind.mojo`) and `komira.broker.topic` (`src/komira_broker/broker_scan_binding.mojo`); no Iceberg kind, no access paths | the graph needs the `komira.iceberg.table` kind, pin groups and the `TEXT` and `VECTOR` access paths that optimized_plan_sources.md specifies |
| joins and SQL | join kernels and join assembly (`src/komira_dispatch_join_kernels/`, `src/komira_join_assembly/`) and a SQL parser (`src/komira_sql/sql_parser.mojo`); this revision did not check that a whole plan runs end to end | the Expand node is new; its iterated-join definition is what tests check it against, and its `HASH` access can build on the join kernels |

## Revision 1: tables on a CAS manifest compared with search splits (rationale)

The first revision compared two options. Its conclusion, tables as the source of truth with search
as a derived index, stands; this revision only replaces Option A's CAS manifest with Iceberg tables
and a tail. The record is kept because it is why the graph is tables and not splits.

- **Option A: tables plus a snapshot manifest.** The graph as columnar tables (`episodes`,
  `entities`, `edges`, later `communities`), each an immutable, content-addressed object; a snapshot
  is one chunk on a CAS manifest listing the table objects. Traversal is a join or a breadth-first
  search over `edges`; similarity is an exact scan over an embedding column.
- **Option B: search splits.** Nodes, edges and episodes as documents in `komira_search` splits.
  Adjacency is keyword postings on an edge's source and destination fields; similarity is a vector
  region in the split; deletes are delete sets in the split catalog.

### What did an earlier implementation learn?

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
  not a null, so the filter needed no null handling (this revision uses nulls; see
  [The tables](#the-tables)).
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
index over facts, and its erasure did not say what happens to snapshots older than the erasure. The
design above keeps its working parts (tables, history in rows, narrow supersession deltas, a
resident merged reader, the name-to-id index) and replaces its manifest and fold with Iceberg and
the roll.

### How the options compared

The scale is the one [search_index_format.md](search_index_format.md#decision-4-adjacency) states:
5,000 nodes and 50,000 edges, and 1,000,000 nodes and 10,000,000 edges, with 1,536-dimension
embeddings. The budgets are proposals, not measurements; every latency figure below is an estimate
from byte counts, and the benchmark settles it. Under this revision, read "snapshot manifest" in
column A as "Iceberg tables plus the tail"; the rows on erasure are superseded by
[Erasure](#erasure) above.

| | Option A: tables plus snapshot manifest | Option B: search splits |
|---|---|---|
| 1 to 2 hops, warm | the reader holds an `edges` projection (ids and the four bounds, about 56 bytes per edge: about 0.6 GB at 10M edges) as an in-memory CSR; a 2-hop expansion from a median-degree seed touches thousands of edges: well under the 25 ms budget | posting lookups in every live split per hop, deletes applied; the 25 ms budget for 2 hops at 16 splits is unmeasured, with a CSR region as the fallback |
| 1 to 2 hops, cold | load the projection first: about 0.6 GB if it is read on its own, tens of GB if embeddings are read with it (10M edges at 6 KiB); seconds either way | fetch the splits; today a split is fetched whole, vectors included, so ranged region reads are needed |
| similarity (`knn`, exact) | same cost in both: 1M vectors at 6 KiB is 6.1 GB scanned, roughly 0.3 to 0.6 s on one core at 10 to 20 GB/s; 5,000 vectors is 30 MB, a few ms. Neither meets an interactive budget at 1M without an approximate index | same as A |
| ranked text | none: the earlier implementation scanned for substrings | BM25 over postings, today's strength of the format |
| update (supersede a fact) | a narrow supersession row; no table rewrite at write time | a split is immutable, so changing an edge's event-time end is a delete set plus a re-added document: the delete machinery of decision 2 is on every ingest, not only on erasure |
| erasure | hide by a tombstone, remove by a rewrite of the affected files, then reap | hide by a delete set per split; remove by a merge policy that selects every split a delete set resolves to, with the input-map rules for a delete that races a merge (decision 2) |
| bi-temporal history | in the rows; `as_of` is a filter on one table | the four bounds as fast fields; history depends on superseded documents being re-added, not hidden |
| engine and SQL reuse | tables are what a scan reads: SQL over the graph is a scan of its tables, joins included | the `komira.search.index` scan kind reads splits as hit rows; traversal and history live in search-specific code |
| operational complexity | one tail per graph, one roll, the tables' maintenance | split catalog, delete sets, a ported merger and compactor whose merge policy drives erasure, input maps composed across merges |

Neither option alone served every query: A had no ranked text, and B made every supersession a
delete and put the race rules of decision 2 under both ingest and erasure. Hence the hybrid, which
this revision keeps.

## Proof the design must ship with

Run as graph steps of storage_stack.md's interop prototype, on a fixed corpus with a superseded
fact:

1. Ingest, roll, and read: `as_of` before and after the supersession; DuckDB reads the four tables
   through the REST catalog and sees the closed fact once.
2. Stall a roll between the `entities` and `edges` commits: a komira reader still reads the previous
   graph snapshot record; DuckDB sees no edge without its endpoints.
3. Another tool compacts `edges` and expires old snapshots: the komira reader and every index still
   answer, and the CSR remaps by key.
4. Erase a subject: before the fold, no query (text, `knn`, traversal, `as_of`) returns it; after
   the fold, rebuild, expiry and orphan removal, a byte scan of every object under the warehouse,
   index and tail prefixes finds no copy, and time travel to the pre-erasure snapshot fails as
   expired.

Mutants that must turn a test red: skip the live-row check on index hits (step 4, before the
rebuild); omit the index rebuild from erasure (step 4's byte scan); drop the system-time bound from
the supersession row (step 1, `as_of` over system time); roll a supersession as an append without
the position delete (step 1, the fact appears twice); read each table at its current snapshot
instead of the recorded set (step 2, a dangling edge); not apply a tail delta to the resident CSR
(step 1, `neighbors` misses the new edge).

## What it means for the search format decisions

| [search_index_format.md](search_index_format.md) | for the graph |
|---|---|
| the summary version check, the L0 refusal, the unchecked query field | still needed now: each is a wrong answer or a silent misread in today's format, graph or not |
| decision 1, several fields per document | not a graph prerequisite: one index per kind and text field fits today's format |
| decision 2, deletes and compaction | not a graph prerequisite: the graph's text index is derived and is rebuilt on erasure; needed by log search, which storage_stack.md keeps as its own source of truth |
| decision 3, a vector region | not used: the vector index is derived over the tables' embedding columns; revisit with an approximate index |
| decision 4, adjacency by postings | not used: adjacency is the CSR; the budget table is reused for it |

## Decisions to make (recommendation first)

1. **Where the graph lives:** four Iceberg tables in the user's catalog (`episodes`, `entities`,
   `edges`, later `communities`), a komira graph-delta tail that rolls into them, and derived
   indexes. Recommend yes. Rejected: tables on a CAS manifest (the first revision's choice, withdrawn
   with komira's own table layer); search splits as the store.
2. **Writes:** Arrow IPC deltas on the tail (added rows, narrow supersession rows, tombstones),
   rolled within `target_lag` (60 s default); a supersession rolls as an upsert of the fact's row.
   Recommend yes.
3. **Embeddings:** a `list<float>` column in each table, with the dimension and model as table
   properties; the vector index is derived from it, and a vector read validates the length on read
   and sees an Arrow `FIXED_SIZE_LIST` (optimized_plan_sources.md §15.5.1). Recommend yes. Rejected: a separate object per
   table, an opaque binary column, embeddings only in a cache.
4. **History:** a superseded fact has its two end bounds closed and is never deleted (kept). The
   bounds are `valid_from`, `valid_to`, `recorded_from`, `recorded_to`, and an open interval is a
   null, so `as_of` is the filter optimized_plan_sources.md §15.7.3 builds. Recommend yes.
   Rejected: the first revision's sentinel timestamp, which depends on the reader set.
5. **Consistency across tables:** commit in the order `episodes`, `entities`, `edges`,
   `communities` (deletes in reverse), or by `commit_transaction` where the catalog advertises it,
   then append a graph snapshot record that komira readers, index generations and plans pin.
   Recommend yes.
6. **Erasure:** tombstones at once, then storage_stack.md's five steps, index rebuilds, tail
   rewrite and cache purge, one deadline per graph, with snapshots older than the erasure
   unreadable; tables partitioned by `bucket(N, group_id)` with `group_id` a subject key. Recommend
   yes; `N` is fixed with the benchmark.
7. **Indexes:** CSR, text and vector indexes bound to a graph snapshot record, read under
   storage_stack.md's read rule, every hit checked against the snapshot, `as_of` and the tail.
   Recommend yes.
8. **Traversal:** the plan's Expand node (optimized_plan_sources.md §15.7.2), defined as iterated
   joins, with its access (`CSR` or `HASH`) chosen by the optimizer and obeyed by the host. The
   graph supplies the CSR as a derived index over the `edges` projection, pinned on the `edges`
   scan, which a long-lived reader keeps resident. Recommend yes. Rejected: the CSR as a host's
   private lowering of a join chain (it cannot express acyclic or shortest paths, and it leaves an
   access choice worth orders of magnitude to the host); postings adjacency.
9. **Query side:** no graph API beside the plan. A graph read is `komira.iceberg.table` scans in
   one pin group named by the graph snapshot record; `search` and `knn` are `TEXT` and `VECTOR`
   access paths on those scans, not scan kinds; `as_of` is a pushed filter; rank fusion is
   `km.rrf`. All of it is in [optimized_plan_sources.md](optimized_plan_sources.md) §15, built the
   same way by every SDK. Recommend yes.
10. **Search format changes:** the three correctness fixes and the version 1 byte golden now;
    decision 1 when a text index needs several fields; decision 2 for log search; decisions 3 and 4
    not for the graph. Recommend yes.
11. **Budgets:** as proposed, 3 hops p50 at most 10 ms on the small graph and 2 hops at most 25 ms
    on the large one; exact `knn` p50 at most 10 ms at 5,000 vectors; at 1,000,000 vectors, either
    accept a budget in the hundreds of milliseconds or require an approximate index. Recommend the
    approximate index before a graph that size is served interactively.
12. **Proof first:** run the graph steps above inside storage_stack.md's interop prototype before
    the graph's code lands. Recommend yes.
