# Storage stack: how komira's storage formats stack

Status: proposed. Nothing in this document is built, and no prototype of it has been run. It describes how komira's stores already share one base, and what it would take for them to share one table layer above it. It ends with decisions for the maintainers. [How would a prototype prove it?](#how-would-a-prototype-prove-it) proposes the prototype that would test the claim before any of it is adopted.

Code citations are to `origin/main` at `2745b3096d` unless they name a branch. Citations to PR #833 (`docs/design/data_graph_storage.md` and `docs/design/search_index_format.md`) are to branch `docs/search-format-kg` at `8f3e266b42`; that PR proposes the data graph's storage and the search format, and this document pairs with it. Statements marked *(inferred)* are reasoning, not something read in code.

## What is it for, and what is out of scope?

komira keeps durable state in a bucket in six shapes:

- the broker's topics;
- the table store;
- analytic tables (Parquet);
- search indexes;
- blobs;
- the proposed data graph.

The shuffle adds a seventh shape, which is ephemeral.

All six durable shapes already sit on the same coordination layer. Above it, each one has its own body codec, data format, reader pin, delete model and meaning of "compaction". This document says how they should stack instead: one table layer, and products built either as tables or as indexes derived from tables.

Out of scope:

- The byte layout of any one format. Those are in the format's own document: [object_store.md](object_store.md), [shuffle.md](shuffle.md), [columnar_memory_and_arrow.md](columnar_memory_and_arrow.md), and PR #833's `search_index_format.md`.
- Query planning over the stack.
- Cloud-specific stores.

## The stack

```
 L5  products          batch table   topic            graph               search index   vector index
                       (table)       (live IPC tail   (tables: episodes,  (derived)      (derived)
                                     + cold table)    entities, edges;
                                                      + derived CSR,
                                                      search, vector)
                         \              |               |                  |              |
 L4  derived indexes      \             |               |   each records (source lineage, snapshot,
                           \            |               |   covered row-id ranges); rebuildable from L3
                            v           v               v                  v              v
 L3  TABLE              schema . snapshot . partitions . data files . row ids . deletes
                        (key tombstones in the tail, deletion vectors on base files)
                        = one lineage of table-commit entries (or a ShardedLineage of them)
                                         |
 L2  immutable files    Parquet | Arrow IPC (.seg stream; IPC file for tables) | search splits | blobs
                                         |                          (format tag per file entry)
 L1  commit             CasManifestStore lineage: create-if-absent chunk append, tombstone/grace/reap;
                        snapshot = (lineage, chunk_seq); ShardedLineage; _LOG_START, _CATALOG pointers
                                         |
 L0  bytes              ConditionalWriteStore: conditional_put, compare_and_swap, get_range
                        (S3 | GCS | Azure | local fs | in-memory)

 outside the stack:  shuffle (L0 + L1 only; ephemeral; never a table, never indexed)
 beside L5:          maintenance (one envelope, typed jobs; see "Compaction")
```

Read the stack bottom to top:

- **L0 and L1 exist and are shared today** (`object_store.md:17-25`).
- **L2 exists format by format.**
- **L3 does not exist.** Each product holds its own fragment of it. The rest of this document argues for building it.
- **L4 and L5** are what the products become once L3 exists.

## Layer by layer

### L0: bytes

**What is shared.** Every store writes through `ConditionalWriteStore`:

- `conditional_put` with `If-None-Match: *` or `If-Match`;
- `compare_and_swap`;
- `get_range`.

The traits are in `object_store.md:29-37`. The version handle is an opaque string (`:124-134`).

**What a product adds.** Nothing. A product that needs a verb this layer lacks gets that verb added here, not in the product. `RangeFetchStore` (ranged fan-out) has no conformer yet (`:35`).

**Invariant.** There is exactly one creator per key (`object_store.md:175`). Every commit in the stack reduces to that.

### L1: commit (one mechanism)

**What is shared.** `CasManifestStore` is an append-only chain of chunks. Its parts:

- **Layout.** Chunks are stored as `<prefix>/manifest/<seq>.chunk`. Next to them are `tombstones/`, `moved_tombstones/`, `_LOG_START`, `_CATALOG` and a `_HEAD` hint (`object_store.md:69-86`).
- **Append.** An append is a create-if-absent of slot K+1, so the chain has no gaps.
- **Envelope.** Each chunk is `[record_count i64][body_len i64][body]`, and the body is opaque (`src/komira_objectstore/cas_manifest.mojo`).
- **Deletes.** A delete is a tombstone, then a grace period, then a reap. A MOVED marker hands a chunk's objects to another lineage.
- **Sharding.** `ShardedLineage` mints writer shards and pins a cross-shard snapshot (`object_store.md:103`).
- **Folding.** `compact_once` (`:102`) is the fold envelope.

The file header states the intent: one manifest "conformed to by BOTH the ... message broker ... AND the search engine ... coordination shared by contract, not by copy".

**What each product adds today, and should not.** Each product has its own pin type and its own chunk-body codec:

| product | pin a reader by | body codec | body evolution rule |
|---|---|---|---|
| broker | offset: the running sum of `record_count` (in sub-lineage mode, `plan_assignment` at serve and fold time); high watermark and last stable offset | `ManifestBody` (`src/komira_broker/manifest_body.mojo`) | additive trailers, no version |
| broker cold tier | offset | `CompactedEntry` (`src/komira_broker/compacted_index.mojo:110-132`) | fixed fields |
| table store | `snapshot_lsn` = chunk seq | `CommitChunk`, magic `PGC1/2/3` (`src/komira_table_store/table_store_codec.mojo:36-50`) | versioned magic; unknown versions rejected |
| search | a *generation*, "not a slot number" (`src/komira_search_catalog/metastore.mojo:423`) | `SplitSummary` (`src/komira_search_catalog/split_summary.mojo:97-145`) | appended slots; the version byte is read (`:309`) and not checked (PR #833 lists this as a correctness fix) |
| shuffle | the seal's producer set | `ShuffleEntry` | fixed fields |

There are 11 files under `src/` that each define a private little-endian `put_i64` helper. That was measured with `git grep -lE 'def _[a-z_]*put_i64_le'`, and it counts helper copies, not formats; a looser pattern (`def _?[a-z_]*put_i64`) matches 17 files.

**What this layer should own instead.**

1. **One snapshot type.** `SnapshotRef = (lineage key, chunk_seq)`, plus a shard vector when the lineage is sharded.
   - Offsets stay a *view* of a snapshot. For a single lineage the view is the running sum of `record_count` up to a seq; for a sharded topic it is the `plan_assignment` function that serve and fold already share (`src/komira_broker/sublineage_segment_fold.mojo`).
   - A read across lineages pins a `SnapshotSet`, a vector of `SnapshotRef`s. It is consistent per lineage and **not transactional** across them: a join of a topic, a table and an index can see read skew. Nothing in this document provides an atomic multi-lineage pin, and nothing should promise one.
   - Search's generation stays, as a *cache key*, not a snapshot. It is `_next_slot()` plus `_GENERATION_BUMPS`, bumped by both `retire` and `reap_chunk`, and a scan reads it before and after reading the catalog to detect a stale view (`metastore.mojo:412-428`). Under L3 a retire is an appended entry, so visibility is the seq; a reap appends nothing but changes the bytes behind a cached plan. The plan-cache key is therefore `(seq, reap floor)`, which is what the generation already encodes *(inferred)*.
2. **One body framing.** Every body starts with `[kind u16][version u16]`.
   - A decoder rejects an unknown kind or version.
   - New fields are appended within a version only when that version's documented rule allows it.
   - The framing helpers live once in `komira_objectstore`.
   - Existing bodies are grandfathered by kind, and are read by their current rules until rewritten.

**Invariants.**

- **Conditional-write commit.** A state change is visible only when its chunk append lands. Data objects are written first; an unreferenced object is garbage, never state.
- **Pins are leases.** A reader that pins a seq sees exactly the chunks at or below it, for as long as its lease lasts. Reap never deletes an object that a live lease at or above `_LOG_START` can reach, and the grace period covers readers still in flight. A lease is bounded: it ends by release, by the grace period, or by an erasure (below).
- **Erasure wins over pins.** Reap runs on a schedule, and "tombstoned" becomes "deleted" within a stated deadline per dataset. An erasure may reap objects that an older lease still reaches. A read under such a lease fails with a distinct error ("snapshot erased"); it never returns a partial result and never silently read-repairs to a newer snapshot. PR #833 says the same for the graph: "snapshots older than the erasure are no longer readable" (`data_graph_storage.md:145`).

**Known gaps at this layer.**

- **Orphaned broker segments.** A PUT whose append then fails leaks its `.seg`, and no sweep exists (`src/komira_broker/broker_core.mojo:56-64`, komira#488).
- **No log truncation in the table store.** The table store never advances `_LOG_START` (`advance_log_start` does not appear in `src/komira_table_store/`). Its deferred list includes a "`snapshot >= log_start` compaction guard" (`src/komira_table_store/table_store.mojo:52`).
- **File size.** `cas_manifest.mojo` is 4,148 lines and should be split before more is added to it.

### L2: immutable file formats

**What is shared.** Every file is written once and then referenced by an L1 entry. No file is overwritten, and no file is live unless an entry names it.

**What each format adds.**

| format | written by today | role |
|---|---|---|
| Arrow IPC *stream* plus 40-byte `TSG1` footer (`.seg`) | broker live tier (`src/komira_broker/broker_core.mojo:66-90,187`) | hot tail of a topic |
| Arrow IPC *file* (footer with record-batch block offsets) | encoders exist (`src/komira_arrow_ipc/`); no store writes tables with them yet | interim table format (PR #833) |
| Parquet | no writer in komira; reader parts only (`docs/architecture.md`, "Layers still to come") | table base; topic cold tier |
| `THSPLIT` search split, version 1 (`src/komira_search/split.mojo`) | `komira_search` | derived index file |
| blob, named by sha256 | no store in komira yet (an earlier implementation had one) | opaque large values |
| shuffle `.seg` (partition bodies, dense trailer; `src/komira_shuffle/segment.mojo`) | `komira_shuffle` | ephemeral, outside the stack |

**Rules this layer should hold.**

1. **Format tag per file entry.** Every L3 file entry records its format (`ipc`, `parquet`, `split`, `blob`) next to its schema version. A table can then move from IPC to Parquet without rewriting old snapshots, as PR #833 proposes for graph tables (`data_graph_storage.md:122-124`).
2. **IPC tables use the IPC file format, with statistics in the entry.** The broker's `.seg` is an IPC stream (`broker_core.mojo:34-37`), which has no block index, so a ranged read can only walk it from the start. An L3 IPC table file is read through an object-store source by range, so it uses the IPC file format. IPC carries no column statistics, so the min/max values in the table-commit entry are the only pruning an IPC table has; the writer must compute them.
3. **One content address.** Content-addressed objects use sha256 and `If-None-Match`. The earlier implementation keyed graph objects by FNV-1a-64 and wrote them with a plain `put`; do not port that. FNV etags in `LocalFsConditionalStore` are a store detail, not an identity.
4. **One extension per format.** The broker's `.seg` and the shuffle's `.seg` (`src/komira_shuffle/entry.mojo:10,15`) are unrelated formats under one name. Rename the shuffle's (for example `.shuf`) so that no tool can open one as the other.
5. **Arrow-native where the data is rows.**
   - IPC and Parquet are the only formats a generic scan reads.
   - Search splits and blobs are opaque by design.
   - The table store's row payloads (opaque key and value bytes inside commit chunks) are not a file format at all. See [The table store](#the-table-store-a-table-with-a-row-tail).

### L3: the table

This layer does not exist yet. A **table** is one L1 lineage, or a `ShardedLineage`, whose bodies are *table-commit entries*. One commit entry carries:

- **Add files.** For each file: key, format tag, schema version, the id span `[first_id, last_id]`, the row count, partition values, and min/max statistics.
- **Remove files.** By key. The objects are then tombstoned and reaped.
- **Deletes.** Key tombstones for tail files, deletion vectors for base files (see [Deletes](#deletes-two-representations)).
- **Schema change.** The new schema with stable field ids.
- **Derived-index attach and detach.** See [L4](#l4-derived-indexes).

A table's **snapshot** is a `SnapshotRef`: the set of live files plus their deletes at that seq. Folding the chain into a `_base` chunk keeps the listing bounded; `SubLineageBaseFold` already does this for the broker's sub-lineages. (`compact_once` is the envelope meant for it, but has no caller outside its own test: `git grep -ln compact_once`.)

**What is shared by every table-shaped product:**

- schema and field ids;
- snapshot = seq;
- partitions;
- row ids (below);
- one pair of delete representations;
- one scan path: an object-store `ArrowSource` for IPC, and the Parquet reader once it lands.

#### Row ids

Every row has a stable id, allocated in order by the lineage that first commits it (an offset, for a topic). Ids are **never renumbered within a lineage**, but they need not stay dense:

- An id span is allocated contiguously by an L1 append.
- After a delete is folded, the rows inside a span may be absent. The broker already works this way: key compaction keeps survivors' original offsets and leaves gaps, with `record_count` meaning the span, not the rows (`src/komira_broker/log_compaction.mojo:26-38`).
- A file entry therefore carries `first_id`, `last_id` and `row_count`, and a file materialises an id column whenever its ids are sparse. Iceberg v3 row lineage likewise requires a rewrite to write `_row_id` physically.
- **Re-partition is the one operation that renumbers.** It re-appends rows into new child lineages (`src/komira_broker/partition_compaction.mojo:20-30`; `log_compaction.mojo:36-38` calls this "the split-lineage rewrite (which renumbers into fresh children)"). Ids are stable within a lineage, not across a re-partition, and every derived index over the parent is rebuilt after one.

An index stores row ids, and a read resolves an id to (file, position) through the per-file `[first_id, last_id]` spans and, for sparse files, the id column. *(Rejected: storing row addresses and emitting a remap on every rewrite, as Lance's fragment-reuse index does, <https://lance.org/format/index/system/frag_reuse/>. It makes every rewrite produce a second artifact that every index must apply.)*

#### Deletes: two representations

A deletion vector is a positional delete: writing one requires knowing which file and position hold the row. Three tails delete or update **by key** at write time and do not know the position:

- the table store's PUT and TOMBSTONE operations (`table_store_codec.mojo:153-166`);
- broker null-value records (latest value per key, settled at fold time);
- the graph's delta tombstones and narrow supersession rows (`data_graph_storage.md:46-50`, `:142`).

Producing a deletion vector at write time would need a key-to-position lookup on the write path, which is exactly the load that PR #833 says made changing the old graph expensive (`data_graph_storage.md:53-55`). So L3 has two representations:

- **Key tombstones** (equality semantics) in tail files, written at commit time.
- **Deletion vectors** on base files only, produced by a fold that already knows positions. They are Iceberg v3 compatible: a roaring bitmap in a Puffin `deletion-vector-v1` blob ([Iceberg spec](https://iceberg.apache.org/spec/), [Puffin spec](https://iceberg.apache.org/puffin-spec/)). Iceberg v3 keeps equality deletes for the same reason; it deprecates only position-delete *files*.

**Graph supersession is not a delete.** A superseded fact stays in the rows with its interval closed (`data_graph_storage.md:41-45`). The check that keeps it out of a current-time query is the `as_of` filter, not a liveness test; only an erasure is a delete.

#### The general shape: a base plus a tail

Every table-shaped product in komira already has, or proposes, a columnar *base* and an append-optimised *tail*:

| product | tail (hot) | base (cold) | today |
|---|---|---|---|
| topic | IPC `.seg` in the partition lineage | Parquet in `<partition>/compacted` | two lineages; dual-tier resolve (`compacted_index.mojo:40-48`) |
| table store | row commit chunks (`PGCn`) | columnar files folded from the log | base not built (see [The table store](#the-table-store-a-table-with-a-row-tail)) |
| graph tables | IPC delta objects | IPC (later Parquet) base | proposed (`data_graph_storage.md:118-124`) |
| batch table | small IPC or Parquet appends | merged Parquet files | not built |

L3 names this shape once:

- **A tail is a range of commit entries whose files are in the tail format.**
- **A tier move** writes base files that cover a contiguous id span of the tail, commits "add base" and then retires the tail. Ownership of the span passes from tail to base: once the tail is reaped, **the base is the only copy and is a source of truth**, not a derived artifact. The broker's cold tier is already this: a compacted live segment "is tombstoned in the LIVE manifest ... and reaped by the grace-gated ReapWorker" (`compacted_index.mojo:49-53`).

**Invariants.**

- A file is live at seq S exactly when an entry at or below S adds it and none at or below S removes it.
- A deletion vector applies to exactly one base file.
- A fold's output holds exactly the rows of its inputs, minus folded deletes, with the same ids.

### L4: derived indexes

A derived index is any artifact that can be rebuilt from L3 tables whose sources outlive it:

- a search split;
- a vector index;
- a CSR adjacency;
- statistics;
- a re-sorted copy.

A tier move's output is *not* in this list: its source is reaped.

**What is shared: one derived-artifact record.** It holds:

- the source lineage key;
- the source snapshot seq it was built at;
- **coverage: the set of row-id spans it indexes** (offset spans for a topic);
- a builder fingerprint (analyzer, embedder model, schema version).

Coverage is by id span, not by seq range or by file. A file rewrite (merge, tier move, delete fold) adds files at a new seq and renames every file, but it keeps ids, so coverage survives it. A coverage by seq would scan a merged file as "uncovered" and return its rows twice; a coverage by file would point at removed files.

The broker cold tier already records an id span: `CompactedEntry.supersedes_lo/hi` (`compacted_index.mojo:110-123`). Search does not. `SplitSummary` has no source field, and its `delete_gen_ref` slot is reserved and always empty (`split_summary.mojo:114,140`).

**The read rule (union read).** A query against snapshot S:

1. **Chooses only eligible indexes.** An index is eligible for S only if its source seq is at or below S. An index built at T > S lacks rows deleted or superseded between S and T; a live-row check can drop extra rows but cannot bring back missing ones. If no eligible index exists, the query uses an older one or scans.
2. **Reads the index for the covered spans** and **scans the rest**: the live rows of S whose ids are outside coverage.
3. **Checks every index hit against S** before returning it: the row is live at S (no tombstone, no deletion vector), and for the graph it passes the `as_of` filter. That check stops an erased row from surfacing while the index lags. PR #833 requires the same check for the graph (`data_graph_storage.md:128-133`).

Outside precedents:

- Lance records `dataset_version` and a fragment bitmap per index, and splits a query into indexed and unindexed subplans (<https://lance.org/format/index/>).
- Turbopuffer searches the index and the unindexed write-ahead tail together (<https://turbopuffer.com/docs/architecture>).

**Freshness bound.** The union read's cost grows with the uncovered part. Each derived index states a maximum lag, in rows or bytes, that triggers an incremental build; a query that finds the lag exceeded still answers (by scan) and reports it. Ranked text has one more cost *(inferred)*: BM25 scores from a split's term statistics and from the scanned tail are not comparable unless the term statistics are merged across both.

**What each index adds.**

| index | file | built from | kept current by |
|---|---|---|---|
| search | `THSPLIT` splits on a split-catalog lineage | a table's text columns | new splits over uncovered spans; split merge; rebuild after erasure |
| vector | none yet; exact scan over an embedding column first (`data_graph_storage.md:134-135`) | an embedding column | an approximate index once a dataset needs it, recorded the same way |
| CSR adjacency | none (resident in memory) | the `edges` projection | applying each delta (`data_graph_storage.md:125-127`) |
| statistics | in the table-commit entry, or Puffin-style blobs | data files | written with the file |

**The exception: an index that is its own source of truth.** Log search, where documents are ingested straight into splits and no table holds them, has no table to rebuild from. That index needs per-document delete sets and split merge with input maps (`search_index_format.md`, decision 2). It is the only product that does. PR #833 reaches the same conclusion (`data_graph_storage.md:163`).

**Invariants.**

- An index never holds a row its source snapshot does not.
- A reader never uses an index built after its own snapshot.
- After an erasure, every index whose coverage includes an erased id is rebuilt and the old one reaped, within the dataset's erasure deadline.
- Dropping every derived index loses no data.

### L5: products

| product | built as | notes |
|---|---|---|
| **batch table** | an L3 table, Parquet base | needs the Parquet writer; Iceberg interop is covered in [Iceberg](#iceberg-where-we-align-and-where-we-do-not) |
| **broker topic** | a live IPC tail lineage (the offset allocator) plus a cold L3 table in offset order; the source of truth is the cold table up to its last span plus the live chunks above it | see [Topic as table](#topic-as-table) |
| **table store** | a row-commit log plus a columnar base | see [The table store](#the-table-store-a-table-with-a-row-tail) |
| **search index** | an L4 index over a table or topic; L3-less only for log search | the scan reads splits plus the uncovered spans |
| **vector index** | an L4 index over an embedding column | exact first, approximate when a budget needs it |
| **data graph** | L3 tables `episodes`, `entities`, `edges` (later `communities`) plus an embedding object per table; L4 CSR, search and vector | PR #833's hybrid; this document adds the row-id coverage and eligibility rules |
| **blobs** | content-addressed objects referenced by sha256 from table rows | not a table; reaped when no live row references them (see [Blobs](#blobs)) |
| **shuffle** | L0 and L1 only | ephemeral, reaped by epoch (`reap_epochs_below`); never indexed, never a table |

#### Topic as table

The live `.seg` tier stays the produce path, so the broker's ack still costs one PUT plus one append (`broker_core.mojo:31-53`). The cold tier is a tier move of the live tier into an L3 table in offset order. After the moved live segments are reaped, the cold Parquet is the only copy of those offsets: it is backed up, and erasure folds deletes into it directly.

**Pin order.** A topic snapshot is the pair (cold seq, live seq), pinned **live first, then cold** *(inferred)*. The transcoder appends the cold entry before it tombstones the live chunks it covers, so any live chunk at or below the live pin that is later reaped is covered by a cold entry the reader can see; `dual_tier_resolve`'s read-repair relies on this (`compacted_index.mojo:40-47`). Pinning cold first leaves a window where a reaped live chunk has no visible cold entry.

**Key compaction and the cold tier.** `append_compacted` raises unless `last == base + record_count - 1` (`compacted_index.mojo:337`), and key compaction leaves spans whose `record_count` is the span, not the rows. So a key-compacted range cannot be moved to the cold tier through today's check, and "merge, fold deletes and transcode in one pass" is not possible for topics until two changes land: the cold entry records a span *and* a row count, with the check on the span; and the cold Parquet carries an explicit offset column. Until then key compaction runs only on the live tier, where it runs today.

**Record fidelity** *(inferred; the transcoder is not in komira)*. A consumer read served from the cold tier must return what a live read returns: producer id and epoch, sequence numbers, transaction markers, headers and timestamps. The cold schema must keep these fields, or cold reads are not equivalent to live reads. This is a requirement on the transcoder port.

Two cautions from systems that tried other shapes:

- **Do not make the log and an analytic table the same bytes.** A log is ordered by offset. An analytic table wants to be partitioned and sorted by a business key, and a table cannot be sorted or clustered two ways without a copy. Writing Parquet costs far more CPU than copying a segment, and a broker is the wrong place to spend it (the essay "Why I'm not a fan of zero-copy Apache Kafka-Apache Iceberg" makes both points). An analytic table keyed by business data is therefore a *separate*, derived L3 table, materialized from the topic by a maintenance job, never by the broker.
- **komira's cold tier is Parquet as tiered log storage**, which is the shape that essay criticises. komira avoids the CPU objection by transcoding outside the broker. It answers the fidelity objection only if the cold schema keeps every record field (above).

The cold tier's file header calls it "topic-as-queryable-table" (`compacted_index.mojo:14-24`). *(Inferred:)* it is queryable, but in offset order. Range scans by offset or time are cheap; key lookups are not.

#### The table store: a table with a row tail

The table store's write-ahead log *is* its data: commit chunks hold `WriteOp[]` of PUT and TOMBSTONE, and recovery replays `[log_start..head]` (`table_store.mojo:817`). Nothing truncates the log, so the replay cost grows without bound.

Under L3 the log becomes a tail, and a tier move folds `[log_start..K]` into a columnar base, after which `_LOG_START` advances past K. Recovery loads the base and replays only the tail. Row MVCC (snapshot isolation on `snapshot_lsn`, first committer wins) is unchanged, because the log's seq stays the snapshot.

What exists to start from is an envelope, not a working fold. `compact_window.mojo:12-26` records three open-coded variants of the fold shape: a comms index's `compact`, which is not in this repository (fold into a base chunk on the *same* lineage, then an `If-Match` advance of `_LOG_START`); the table store's earlier columnar adapter, outside this repository (fold the log to one Parquet object, append a `ColumnarFileEntry` to *another* lineage, and `schedule_for_delete` the folded log chunks, without advancing `_LOG_START`); and the broker's sub-lineage fold, which stays bespoke. `compact_once` factors the shared steps of the first two.

That leaves one choice, decision 10: one lineage or two. This document recommends two, matching the topic: the log lineage stays the commit path and the snapshot allocator, and the base is an L3 table on a second lineage whose entries record the log span they cover. A table-store snapshot is (base seq, log seq), pinned log first. The earlier adapter's mistake to avoid is deleting log chunks without advancing `_LOG_START`, which leaves recovery replaying into reaped chunks *(inferred)*.

#### Blobs

A blob is written with `If-None-Match` under its sha256 and referenced from table rows; it is reaped when no row of any leased snapshot of any table references it. Deduplication has a race *(inferred)*: writer A's `If-None-Match` PUT gets 412 because the blob exists but is tombstoned; A commits a reference; the reaper deletes the blob. The fix: on 412, the writer reads the blob's tombstone and, if present, clears it by `compare_and_swap` before committing its reference, and the reaper deletes only by `If-Match` on the tombstone version it read, so one of the two loses.

## Source of truth and derived

**The rule.** Every stored artifact is either a source of truth or derived, never both.

- **Sources of truth:** the topic's live tail and its cold table (each for the spans it owns), L3 table files and their deletes, the table store's log and its base, blobs, and log-search splits (the one exception).
- **Derived:** search splits over a table, vector indexes, CSR, statistics, and re-sorted or re-keyed copies (including an analytic table materialized from a topic).

A tier move transfers ownership; it does not derive. Every derived artifact records its source snapshot and coverage and can be rebuilt from its sources.

**What the rule buys.**

1. **Erasure has one place to start.**
   - Erase from the sources: tombstone, fold, reap. For a tier-moved range, fold the deletes into the base directly.
   - Then rebuild or drop every derived artifact whose coverage includes an erased id.
   - The coverage record makes "which artifacts must be rebuilt" a query instead of a guess.
   - Systems that skipped this step leak erased rows through downstream copies that do not read deletion vectors (<https://securitydataworks.com/writing/lakehouse/deletion-vectors-gdpr/>).
2. **Consistency without coordination.**
   - An index may lag; it can never lie.
   - Eligibility, the union read and the live-row check give snapshot-consistent results at any index lag.
   - Index builds never sit on the write path.
3. **One backup story.**
   - Back up L1 lineages and the files they name. Derived artifacts are rebuilt on restore and never backed up.
   - Restore cost equals rebuild cost, which is measurable.
4. **One test of erasure.** PR #833's byte-scan test (`data_graph_storage.md:149-155`) generalises into a harness that runs against every product: delete a subject, fold, rebuild, reap, then read every object left in the store and assert that none contains the subject's bytes.

## Compaction: six named operations and reap

"Compaction" names seven different mechanisms in komira and in the earlier implementation, and two different functions are both called `compact_once`. Replace the word with six operations, each owned by one layer, each ending in reap, and each run through one envelope:

> plan against a pinned snapshot → write outputs → conditional commit → retire inputs → reap after the grace period

That envelope is `compact_once` (`src/komira_objectstore/compact_window.mojo`). Its RESUME, PLAN, FOLD, MATERIALIZE, ADVANCE and RETIRE steps already exist, but nothing in `src/` calls it outside its own test.

| operation | layer | what it does | drops rows? | renumbers? | today's mechanisms it absorbs |
|---|---|---|---|---|---|
| **fold manifest** | L1 | re-records a range of chunks into a dense base chunk; no data bytes copied | no | no | sub-lineage `_base` fold (`src/komira_broker/sublineage_segment_fold.mojo`, "ZERO byte copy") |
| **merge files** | L3 | rewrites many small files of a table into fewer, larger files; same format | no | no | graph base-plus-delta fold (earlier implementation; `data_graph_storage.md:46-52`) |
| **fold deletes** | L3 | rewrites a file without its tombstoned or superseded-by-key rows; may leave id gaps | **yes** | no | broker key compaction (`src/komira_broker/log_compaction.mojo`); graph erasure fold |
| **tier move** | L3 | rewrites tail files into the base format (IPC or row log to Parquet), recording the span, then retires the tail | no | no | broker tier compaction (transcoder in the earlier implementation; komira has the index only); table-store log fold (earlier implementation) |
| **re-partition** | L3 | re-routes rows by key into child lineages | no | **yes** | partition compaction (`src/komira_broker/partition_compaction.mojo`) |
| **merge index** | L4 | merges search splits, or rebuilds them from a newer snapshot | only deleted documents, and only for log search | no | search split merge (the earlier implementation's other `compact_once`) |

**Reap** (`ReapWorker` in `src/komira_broker/retention.mojo`, search's `reap_chunk`, the shuffle's epoch reap) is the shared last step of all six, at L1, not a seventh operation.

Notes:

- **Merge files, fold deletes and tier move are one L3 job with three settings:** output format, whether to apply deletes, and target file size. A single pass may do all three, except for topic ranges with id gaps until the cold entry carries a span and a row count (see [Topic as table](#topic-as-table)).
- **Merge index commits a *visible* output.** The merged split is published before its inputs retire. That is why PR #833 rejected `compact_once` for it (`search_index_format.md:225-228`). Add this as a second mode of the same envelope (commit output, then retire inputs by exact seq), not as a second compactor. When the split merger is ported, give it a name other than `compact_once`.
- **Re-partition renumbers.** Every derived index over the parent is rebuilt after it, and it is the only operation that may not run while a reader holds ids from the parent across the move.
- **Retention is not compaction.** Advancing `_LOG_START` by time or bytes is an L1 policy that feeds reap.
- **One maintenance service runs every operation as a typed job**, outside the broker and outside query paths, with one erasure-deadline policy per dataset. Every lakehouse system surveyed ends at the same shape:
  - Iceberg's rewrite and expire procedures;
  - Hudi's table services (<https://hudi.apache.org/docs/indexes/>);
  - Fluss's tiering service (<https://fluss.apache.org/blog/unified-streaming-lakehouse/>).

## Iceberg: where we align and where we do not

**Align on the data layer and the vocabulary:**

- **Data files are Parquet** with Iceberg field ids: the Parquet writer emits `field_id` in every `SchemaElement`.
- **Partition values are computed by Iceberg's partition transforms,** not stored as free-form values.
- **Base-file deletes are Iceberg-v3-compatible deletion vectors:** one roaring bitmap per data file, in Puffin. Delta and Iceberg v3 share the roaring payload; the containers differ (a Puffin blob versus a Delta `.bin` file). A store that invents its own delete format has to convert at every export. Delta UniForm historically could not serve tables that used deletion vectors (<https://docs.databricks.com/aws/en/delta/uniform>).
- **Row lineage** (`_row_id`, last-updated sequence number) matches Iceberg v3. These are the row ids L3 already needs; a rewrite writes them physically.
- **Statistics and derived blobs record the snapshot they were computed from**, as Puffin blobs do.

**Read Iceberg tables.** `komira_iceberg_catalog` resolves a name to a metadata location and stops there (`docs/architecture.md`, "Layers still to come"). Reading metadata, manifests and Parquet data is a planned layer, and it reuses the L3 scan path.

**Write Iceberg as an export, not as our commit.** komira's L1 lineage stays the commit point for every komira table. On request, a maintenance job emits Iceberg metadata (`metadata.json`, the manifest list, manifests) after each L3 commit, pointing at the *same* Parquet files and deletion vectors. That gives one data layer and two metadata dialects, with ours authoritative. UniForm is the precedent. The export has three preconditions:

- **Only all-Parquet tables export.** Iceberg data files are Parquet, ORC or Avro, so a table with any live IPC file (graph tables today, any tail) cannot be exported until a tier move clears it. A topic exports its cold table only.
- **Exported snapshots are reap pins.** An external reader time-travelling through an exported snapshot holds a pin komira cannot see. Reap must not delete a file while an exported snapshot that references it is retained; the oldest retained exported snapshot is a reap floor, and an erasure expires the exported snapshots that hold the subject within the same deadline.
- **The writer requirements above** (field ids, transforms, physical row lineage) are part of the Parquet writer step, not added later.

Why our manifest stays our own:

- **Commit rate and coordination on the tail.** An Iceberg commit is one pointer swap per table: a catalog update, or a `version-hint.text` compare-and-swap in the earlier implementation. Every writer serializes on that pointer. A komira lineage commits by create-if-absent of the next slot, shards across writers (`ShardedLineage`) and needs no catalog service. *(Inferred: a topic flushing every 250 ms per partition would rewrite Iceberg's metadata tree at that rate.)* This argues against Iceberg for tails; a cold table commits once per tier-move batch and is not the reason.
- **One mechanism across products.** The topic tail, the table store log and the search catalog are not Iceberg tables and never will be. If base tables alone used Iceberg's pointer swap, komira would have two commit mechanisms for one table (tail and base). The earlier implementation had exactly that split.
- **Erasure.** Iceberg erasure needs a rewrite *and* snapshot expiry, because older snapshots still hold the data. Our reap-by-reference with a deadline covers it, with the exported snapshots as a reap floor.

**Rejected:**

- Iceberg as komira's table manifest: the second commit mechanism, the catalog dependency and the serialized commit described above.
- No Iceberg interop at all: komira tables would be unreadable by every other engine.

## What exists and what must be built

**Exists (on `main`):**

- L0 conformers.
- `CasManifestStore` with tombstone/grace/reap, `ShardedLineage`, `SubLineageBaseFold` and `compact_once` (no caller outside its test).
- The broker live tier and its scan kind.
- The broker compaction index and its dual-tier resolve (no transcoder).
- The table store (no fold).
- Search splits, the split catalog, and the `komira.search.index` scan kind. The scan ships only an in-memory catalog; `komira_search_scan`'s `BUCK` does not depend on `komira_search_catalog`.
- Arrow IPC encoders and decoders.
- Parquet value decoders, footer and page-header readers, and page compression.
- The Iceberg catalog client (name to metadata location).
- The shuffle.

**Must be built, in order.** Each step is usable on its own.

1. **L1 framing, `SnapshotRef` and `SnapshotSet`.** `[kind][version]` body framing with strict rejection; one set of little-endian helpers; the snapshot types; pins as leases with the "snapshot erased" error. Includes the search summary version check that PR #833 already lists as a correctness fix.
2. **An object-store `ArrowSource`** over the IPC *file* format, reading from bytes or a ranged object, not a path. `src/komira_scan_source/arrow_source.mojo:2` reads "Arrow IPC files on disk". The earlier graph store worked around the same gap by copying each object to a temporary file (`data_graph_storage.md:61-62`).
3. **The L3 table-commit body, row ids and key tombstones, and a table scan kind,** over IPC files with a format tag and per-file id spans and min/max statistics. Graph tables (PR #833) are its first user; they delete by key tombstone.
4. **Index binding.**
   - Source lineage, seq and id-span coverage on `SplitSummary`.
   - The CAS split catalog wired into `komira_search_scan`.
   - The union read: eligibility, uncovered-span scan and the live-row check; a stated freshness bound per index.
5. **The Parquet column reader, then the Parquet writer,** with field ids, an explicit id column for sparse files, and Iceberg row lineage on rewrite. This step gates the topic cold tier, batch tables and graph tables moving from IPC to Parquet.
6. **The maintenance service.** Tier move (port the earlier transcoder as a job, not into the broker, keeping every record field; the table-store log fold with its `_LOG_START` advance), merge files, fold deletes, re-partition, and merge index. The cold entry gains a span plus a row count.
7. **Deletion vectors** on base files, produced by fold deletes.
8. **Iceberg read, then Iceberg export** of all-Parquet tables, with exported snapshots as reap pins.
9. **The blob store** (sha256, `If-None-Match`, resurrect on 412) with reap-by-reference, before any table references blobs.
10. **The erasure harness** across every product and derived artifact.

**Duplications to remove:**

- **11 private little-endian helper copies.** Replace them with one set (step 1).
- **Two `compact_once`s.** Keep the envelope; give the ported split merger its own name as the envelope's second mode.
- **Two `.seg` formats.** Rename the shuffle's extension.
- **Search's own shard reaper beside `ShardedLineage`** (`src/komira_search_catalog/generation.mojo`, `shard_reaper.mojo`). Converge on `ShardedLineage` and `SnapshotRef` once step 1 lands; the generation survives as the plan-cache key.
- **Content identities.** Use sha256 everywhere identity is content; do not port FNV-keyed objects or plain-`put` creates.
- **Row-delete models.** Four exist: broker null values, table-store row tombstones, graph delta tombstones, and the proposed search delete sets. Converge on two: key tombstones in tails (the first three are already this shape) and deletion vectors on bases. Search delete sets remain only for log search.
- **Unswept broker segments** (komira#488). Add the sweep as a reap job.

## What must always hold

- **One commit point.** A product's visible state changes only by an L1 append. A data object with no entry naming it is garbage.
- **Never renumbered within a lineage.** Ids are allocated contiguously; rows within a span may be absent after fold deletes; only re-partition renumbers, into new lineages.
- **Pinned reads are stable for the lease, or fail loudly.** A reader leased at seq S reads the same rows until it releases the lease, the lease expires, or an erasure invalidates it, and then it gets "snapshot erased", never a partial result.
- **Derived never leads.** No derived artifact returns a row that its reader's snapshot does not hold, and no reader uses an index built after its snapshot.
- **Erasure has a deadline.** It spans the sources, every derived artifact, every older snapshot and every exported Iceberg snapshot, and one harness tests it for every product.
- **Strict decoding.** An unknown body kind or version is an error, never a default.

## How would a prototype prove it?

The prototype is proposed and has not been run. It would build as Buck2 targets with welded tests, using the in-memory store, `CasManifestStore`, the IPC encoders and `komira_search`. It defers the Iceberg export and deletion vectors until a Parquet writer exists; erasure goes through key tombstones and fold.

1. Write a three-table graph over two snapshots as L3 table-commit entries over IPC files, with row ids.
2. Build a search split that records its source seq and id-span coverage.
3. Append a delta with a supersession and an erasure tombstone.
4. Merge files between building the split and querying.
5. Query text, `as_of` and two-hop CSR traversal through the union read, at the current snapshot and at an older one.
6. Hold a lease at the older snapshot, then fold, rebuild the split, and reap.
7. Byte-scan every remaining object for the erased subject; read under the old lease.

Planted mutants, each of which must turn a test red:

| mutant | test that goes red |
|---|---|
| drop the live-row check | the text query returns the erased subject |
| skip the split rebuild | the byte scan finds the subject |
| ignore the uncovered spans | a fresh write is missing from the results |
| coverage by seq instead of id span | after the file merge, results hold duplicate rows |
| merge files drops the id column of a sparse file | an id lookup after the merge resolves to the wrong row |
| use an index built after the reader's snapshot | the query at the older snapshot misses a row deleted later |
| reap ignores the lease and returns what remains | the read under the old lease returns a partial result instead of "snapshot erased" |
| accept an unknown body version | the strict-decode test |

A separate broker test covers the topic: key-compact a live range, then tier-move it; with today's `append_compacted` check it must fail loudly, and with the span-plus-count entry it must preserve every surviving offset.

Record latencies against the budgets in PR #833.

## Decisions for the maintainers (recommendation first)

1. **Adopt the L3 table as the shared layer:** one table-commit body, a format tag per file entry, row ids, base plus tail.
   - **Recommend yes.**
   - Rejected: keep per-product bodies and add products as silos. Each new product would add another codec, pin type, delete model and compactor.
2. **Adopt the source-of-truth/derived rule,** with source snapshot and id-span coverage on every derived artifact, written into [object_store.md](object_store.md); a tier move transfers ownership and is not a derivation.
   - **Recommend yes.**
   - Rejected: indexes as independent stores. Erasure and consistency then need per-index delete machinery, and the backup story doubles.
3. **Search is derived by default;** only log search is its own source of truth and needs delete sets.
   - **Recommend yes.**
   - Rejected: build `search_index_format.md` decision 2 for every index. Its race rules would sit under ingest and erasure for every product.
4. **A topic is a live IPC tail plus a cold Parquet L3 table in offset order; after the tier move the cold table is the source of truth for its spans and is backed up. An analytic table keyed by business data is a separate, derived materialization. The broker never writes Parquet.**
   - **Recommend yes.**
   - Rejected: zero-copy log-equals-table, which forces one sort order and puts Parquet encoding CPU on the produce path.
5. **Two row-delete representations: key tombstones in tails, Iceberg-v3-compatible deletion vectors on base files, produced by fold.**
   - **Recommend yes.**
   - Rejected: deletion vectors only, which needs a key-to-position lookup on every write path. Also rejected: tombstone rows per product with no shared form, which forces a conversion at every export and in every derived index.
6. **The komira lineage stays the commit point; Iceberg is read, and written as an export of all-Parquet tables over the same files, with exported snapshots as reap pins.**
   - **Recommend yes.**
   - Rejected: Iceberg metadata as komira's table manifest (a second commit mechanism, a serialized pointer, a catalog dependency).
7. **Six named compaction operations, each ending in reap, in one maintenance service on one envelope with a second "visible output" mode; re-partition marked as the one that renumbers.**
   - **Recommend yes.**
   - Rejected: per-product compactors, the status quo of seven mechanisms.
8. **Strict body framing, `SnapshotRef`, `SnapshotSet` and pins as leases first, before any new body kind lands.**
   - **Recommend yes.**
   - Rejected: let each new body choose its own evolution rule, which is how today's four rules arose.
9. **Run the prototype above before PR #833 is accepted.**
   - **Recommend yes.**
   - Rejected: accept #833 on its estimates. Its budgets are "proposals, not measurements" (`data_graph_storage.md:95`).
10. **The table store's base lives on a second lineage, as the topic's does,** with the snapshot a (base seq, log seq) pair pinned log first, and the fold advancing `_LOG_START`.
    - **Recommend yes.**
    - Rejected: fold into a base chunk on the log's own lineage (the comms index's shape), which puts maintenance appends on the commit path's slot sequence; and the earlier adapter's shape, which deleted log chunks without advancing `_LOG_START`.

## Where is the code?

| layer | paths |
|---|---|
| L0, L1 | `src/komira_objectstore/` (`store.mojo`, `cas_manifest.mojo`, `compact_window.mojo`, `sharded_lineage.mojo`, `sublineage_base_fold.mojo`) |
| topic | `src/komira_broker/` (`broker_core.mojo`, `manifest_body.mojo`, `compacted_index.mojo`, `log_compaction.mojo`, `partition_compaction.mojo`, `retention.mojo`, `broker_split_reader.mojo`, `sublineage_segment_fold.mojo`) |
| table store | `src/komira_table_store/` (`table_store.mojo`, `table_store_codec.mojo`) |
| search | `src/komira_search/`, `src/komira_search_catalog/`, `src/komira_search_scan/` |
| tables and formats | `src/komira_arrow_ipc/`, `src/komira_parquet*/`, `src/komira_iceberg_catalog/`, `src/komira_scan_source/arrow_source.mojo` |
| shuffle | `src/komira_shuffle/` ([shuffle.md](shuffle.md)) |
| graph | `src/komira_kg_code/` (derives batches; nothing stores them); proposal on branch `docs/search-format-kg`: `docs/design/data_graph_storage.md`, `docs/design/search_index_format.md` |

External references: [Iceberg spec](https://iceberg.apache.org/spec/) · [Puffin spec](https://iceberg.apache.org/puffin-spec/) · [Delta UniForm](https://docs.databricks.com/aws/en/delta/uniform) · [Hudi indexes](https://hudi.apache.org/docs/indexes/) · [Lance index format](https://lance.org/format/index/) · [Lance fragment reuse](https://lance.org/format/index/system/frag_reuse/) · [Fluss unified lakehouse](https://fluss.apache.org/blog/unified-streaming-lakehouse/) · [Turbopuffer architecture](https://turbopuffer.com/docs/architecture) · [Deletion vectors and erasure](https://securitydataworks.com/writing/lakehouse/deletion-vectors-gdpr/) · the essay "Why I'm not a fan of zero-copy Apache Kafka-Apache Iceberg"
