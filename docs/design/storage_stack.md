# Storage stack: komira tables are Iceberg tables

Status: proposed, second revision. Nothing in this document is built, and no prototype of it has been run. The first revision proposed komira's own table layer (L3), with Iceberg metadata exported on request. This revision reverses that: **a durable komira table is a native Iceberg table, committed through the user's catalog.** komira keeps its own formats only where Iceberg cannot serve: sub-second hot tails, derived indexes, and a default catalog for users who have none. [Decisions](#decisions-for-the-maintainers-recommendation-first) lists what is withdrawn.

Code citations are to `main` as this pull request (#1134) was written. Citations to PR #833 (`docs/design/data_graph_storage.md`, `docs/design/search_index_format.md`) are to its branch `docs/search-format-kg` at the same time. Statements marked *(inferred)* are reasoning, not something read in code or documentation. Statements marked *(to confirm)* are vendor behaviour this document has not verified. Reader and catalog behaviour comes from vendor documentation, linked inline; it changes quickly, so re-check a row before relying on it.

"Iceberg v4" below means the v4 draft: the spec says version 4 "is under active development and has not been formally adopted".

## Why the revision

Users adopt komira one workload at a time. A team that tries it already has:

- a bucket;
- a catalog: AWS Glue, Unity Catalog, Apache Polaris (or Snowflake Open Catalog), Nessie, Hive Metastore, BigLake metastore, or S3 Tables;
- tools that read from that catalog: Athena, Snowflake, Spark, Trino, DuckDB, BigQuery;
- jobs that already write tables those tools read.

The first workload succeeds only if three things hold:

- Those tools can read what komira writes, with no export step and no second catalog.
- komira can read what those tools already wrote.
- komira can take over one job's writes to a table that dashboards already read, without moving the table.

Products that win workloads this way all do the same four things ([Confluent Tableflow](https://docs.confluent.io/cloud/current/topics/tableflow/overview.html), [Redpanda Iceberg topics](https://docs.redpanda.com/current/manage/iceberg/about-iceberg-topics/), [Fivetran managed data lake](https://fivetran.com/docs/destinations/managed-data-lake-service), [Estuary](https://docs.estuary.dev/reference/Connectors/materialization-connectors/apache-iceberg/)):

1. They write plain Iceberg into the user's bucket.
2. They register it in the user's catalog.
3. They state a freshness number, about 1 to 5 minutes.
4. They maintain the tables they write, and only those.

Where a product's own format or catalog sits underneath, users see it as a cost:

- DuckLake's interop with other engines is a copy of its metadata into Iceberg ([DuckLake](https://ducklake.select/)).
- UniForm's Iceberg view is read-only ([UniForm](https://docs.databricks.com/aws/en/delta/uniform)).
- Tableflow's managed storage can be reached only through Confluent's catalog.

The first revision's model was "our manifest is authoritative, Iceberg is an export". It has the same shape, and it breaks as soon as the catalog belongs to the user, because their compaction and snapshot expiry change the table under us.

## What the user sees

The snippets below use a Python SDK that does not exist yet. What exists today:

- `komira_sdk` is the plan-building half of a Mojo SDK. It has no sinks (`src/komira_sdk/README.md`).
- `komira_iceberg_catalog` resolves a table name to its metadata location and per-table `config`, and does nothing else: no create, no commit (`src/komira_iceberg_catalog/README.md`).

The snippets fix the shape of the product, not an API.

### 0. Permissions the user grants

Before any journey, komira needs a principal and credentials. It gets them in one of three ways, chosen per catalog:

- **Vended by the catalog.** A REST catalog returns per-table credentials or remote signing when asked (`X-Iceberg-Access-Delegation`); they arrive in `load_table`'s `config`, which `komira_iceberg_catalog` already returns. Unity, Polaris, S3 Tables and BigLake work this way *(to confirm per catalog)*.
- **An assumed role** (or a service account on GCP, a managed identity on Azure) with read and write access to the table locations and the catalog API.
- **Ambient credentials** where komira runs, for local and test use.

On Glue tables governed by Lake Formation, the principal also needs Lake Formation grants on the database, the table and the data location; without them commits fail, and the failure is reported as a missing grant by name *(to confirm the exact grant set against a Glue account)*.

### 1. Write a table and query it from Athena, Snowflake and Spark

```python
import komira as km

cat = km.catalog("glue", region="us-east-1")   # or "rest", "unity", "polaris", "nessie", "hms", "s3tables", "biglake"
df = km.read_parquet("s3://acme-raw/orders/*.parquet").filter(km.col("status") != "test")
df.write_table(cat, "sales.orders", mode="append", partition_by=[km.days("order_ts")])
```

- komira writes Parquet data files (with Iceberg field ids) and Iceberg metadata into the table's location in the user's bucket. It then commits one snapshot through Glue.
- **Athena and Spark** (on the Glue catalog) see the rows on their next table load after the commit returns. Spark's catalog caches tables for 30 s by default (`cache-enabled`); Trino caches metadata too.
- **Snowflake** sees them through its catalog integration with Glue, on that integration's refresh schedule. komira documents this and does not promise a number for it.
- komira holds no state for this table. If komira is removed, it remains an ordinary Glue Iceberg table.

The write modes, and how each commits (all under [the commit client](#the-commit-client)):

| mode | commits as | conflict check |
|---|---|---|
| `append` | `append` snapshot | rebase on a moved ref; never fails validation after a rebase; a streaming sink's append from an older generation is refused instead (the commit client, step 3) |
| `overwrite` (a filter) | `overwrite` snapshot | no new data files match the filter since the base |
| `overwrite_partitions` (dynamic) | `overwrite` of the partitions written | no new data files in those partitions since the base |
| `merge` (upsert on key columns) | position deletes plus new files (merge-on-read) by default; on a table komira does not maintain, the owner's `write.merge.mode` | target files still live; no new files matching the merge keys' partitions |
| `create_or_replace` | Iceberg's replace-table transaction (new schema and spec, same table uuid) | none on create; `assert-table-uuid` on replace |

The table can be one komira created, or one that already exists in the catalog: taking over a Spark job's writes to `sales.orders` is `write_table` on that table. What komira does *not* do to a table it did not create is maintain it or change its properties (see [one maintainer per table](#maintenance-one-maintainer-per-table)).

### 2. Read a table another tool owns

```python
orders = km.read_table(km.catalog("unity", ...), "main.sales.orders")    # Iceberg, or a UniForm table's Iceberg view
events = km.read_delta("s3://acme-lake/events")                         # Delta Lake, by path or through the catalog
clicks = km.read_parquet("s3://acme-raw/clicks/", hive_partitioning=True)
```

- **Iceberg:** komira reads the snapshot that is current when the query plans. `as_of=` gives time travel, while the snapshot is retained.
- **Delta:** komira reads the latest log version.
- **Hive-style Parquet:** komira reads a file listing. There is no snapshot isolation, and the result says so.
- komira never writes Delta or Hive-style Parquet. To write a Hive-style dataset as a table, the user adopts it:

```python
km.adopt(cat, "raw.clicks", source="s3://acme-raw/clicks/", how="in_place")   # Iceberg add_files with a name mapping
km.adopt(cat, "raw.clicks", cutover=True)                                     # later: the old readers and writers are gone
```

- An in-place adoption creates an Iceberg table whose data files are the existing files. Every file's footer is checked against the table's declared readers first; a file that fails is rewritten (see [adoption](#adoption)).
- Until `cutover=True`, the table carries `gc.enabled=false` and komira does not maintain it. Iceberg operations can delete files that `add_files` registered, and the old Hive table and its writers still use them. Before cutover, the old Hive table keeps working unchanged, and new files a legacy job writes under the prefix are not in the Iceberg table until the next `adopt` refresh.

### 3. A broker topic persisted as an Iceberg table

```python
topic = km.topic("orders", partitions=12)
topic.persist_as(cat, "streams.orders", mode="append", target_lag="60s")   # or mode="upsert" (key = message key)
```

- komira consumers, and `km.read_table(cat, "streams.orders", include_tail=True)`, see a record as soon as it is acknowledged.
- Athena, Snowflake and Spark see it within `target_lag` plus the roll time plus their own catalog cache. That puts komira level with Redpanda (default 1 minute).
- The table records, as a table property, the last offset of each partition that it holds. komira's reader uses that to join the table and the hot tail with no gap and no duplicate, even after other tools compact the table and expire old snapshots.

### 4. A search or vector index over a table komira did not write

```python
idx = km.index(cat, "support.tickets", text=["subject", "body"],
               vector=km.embed("body", model="..."), refresh="on_commit")   # or "every:5m"
hits = idx.search("refund not received", k=20)                              # consistency="index" by default
hits.snapshot_id    # the Iceberg snapshot the answer is consistent with
hits.lag            # files and rows not yet indexed at that snapshot
```

- The index lives under a prefix the user chooses, outside every table location. komira writes nothing to the source table and registers nothing in the user's catalog.
- When another tool appends to the table, deletes from it or compacts it, the index catches up from the new snapshot. A compaction costs I/O, not model calls: embeddings are cached by content.
- Until it has caught up, no answer contains a row the snapshot does not hold: deleted and removed rows are filtered out, and the lag is reported. `consistency="exact"` also scans what the index does not cover yet (see [the read rule](#the-read-rule)).
- The user can check an answer in Snowflake or Spark at `hits.snapshot_id` while the table still retains that snapshot. On S3 Tables, or under another tool's expiry, it may not; `hits` reports when the snapshot has been expired.

### 5. Erasure across the table, its indexes and its history

```python
job = km.erase(cat, "crm.customers", where=km.col("customer_id") == 4711,
               cascade=["indexes", "topics"], deadline="30d")
job.report()   # per artifact: done, awaiting the table's maintainer, or outside komira's reach
```

The report separates three things:

- **What komira erased:** rows, rewritten files, rewritten manifests, expired snapshots, purged index generations, rewritten tail segments, rewritten or dropped graph delta objects, rewritten or dropped row-store log chunks.
- **What waits on someone else:** steps on a table that another tool maintains (see [Erasure](#erasure)).
- **What komira cannot reach:** copies that other tools made.

### 6. A user with no catalog

```python
cat = km.catalog("komira", warehouse="s3://acme-lake/")   # komira's Iceberg REST catalog
```

- komira serves a standard Iceberg REST endpoint. Spark, Trino, DuckDB, PyIceberg and Snowflake connect to it like any other REST catalog.
- The catalog's state lives in the user's bucket.
- Leaving is `km.export_catalog(to=km.catalog("glue", ...))`. For each table, it runs `register_table` at the current metadata location in the target catalog, then marks the table as moved in komira's catalog in one L1 commit. After that, komira's catalog answers loads and commits for the table with a redirect error naming the new catalog, and never purges its files. No data moves, and the table never has two live pointers that both accept commits.
- S3 Tables manages its own table locations and is not an export target *(to confirm)*; moving to it is a copy.

### Who sees what, and when

| reader | batch table (journey 1) | topic table (journey 3) | index (journey 4) | erasure (journey 5) |
|---|---|---|---|---|
| komira SDK | at commit | at acknowledgement (tail plus table) | at `snapshot_id`, with the lag reported | when the erasure job completes |
| Athena, Spark, Trino, DuckDB through the same catalog | at their next table load after the commit | at the last roll (`target_lag`), plus their next load | not visible (a komira-only artifact) | at the delete commit; old snapshots until they expire |
| Snowflake, BigQuery through a catalog integration or metadata URI | at the integration's next refresh (BigQuery external tables: when the URI is updated) | the same, after the roll | not visible | the same, plus the integration's refresh |

## Out of scope

- The byte layout of any one komira format. See [object_store.md](object_store.md), [shuffle.md](shuffle.md), [columnar_memory_and_arrow.md](columnar_memory_and_arrow.md), and PR #833's `search_index_format.md`.
- Query planning, and cloud-specific stores.
- The Python SDK's API. The snippets above are the product shape it must support.
- Where komira's compute runs. Every journey assumes only that it runs with the credentials of journey 0.

## The stack, revised

```
 L5  products        batch table    topic               row store          search / vector index     knowledge graph
                     (Iceberg)      (komira IPC tail    (komira row log    (komira, derived)         (see KG below)
                                     -> Iceberg table)   -> Iceberg base)          |                       |
                          |               |                   |                    |                       |
 KG  graph layer          |               |                   |                    |    data model: entities, edges, episodes,
     (above L4; consumes  |               |                   |                    |    communities; bi-temporal.
     search, vector and   |               |                   |                    |    query: entity lookup (search, vector),
     adjacency)           |               |                   |                    |    neighborhood and path traversal
                          |               |                   |                    |    (adjacency), retrieval for AI
                          |               |                   |                    v                       v
 L4  derived indexes      |               |                   |        full-text search | vector | graph adjacency (CSR)
     (komira formats)     |               |                   |        statistics; each bound to (catalog, table uuid,
                          |               |                   |        snapshot id, covered files); rebuildable
                          v               v                   v                    v
 L3  tables         ICEBERG TABLE (v2 by default), committed through a Catalog:      komira TAIL (sub-second):
                    REST | Glue | Unity | Polaris | Nessie | HMS | S3 Tables |        topic segments, row-store log,
                    BigLake | komira's own REST catalog (default when none)           graph deltas; rolls into Iceberg
                    + read-only: Delta Lake, Hive-style Parquet
                    includes the graph's own tables: its facts live here, not in an index
                          |                                                                  |
 L2  immutable files     Parquet (Iceberg data and position-delete files) | Avro manifests | Arrow IPC (tails) |
                         search splits | vector files | blobs
                          |                                                                  |
 L1  commit              the user's catalog commits Iceberg tables.         CasManifestStore lineages commit tails,
                                                                            indexes and komira's catalog state
                          |                                                                  |
 L0  bytes               ConditionalWriteStore: conditional_put, compare_and_swap, get_range (S3 | GCS | Azure | fs | memory)

 outside the stack:  shuffle (L0 + L1 only; ephemeral)
 beside L5:          maintenance service (Iceberg maintenance on tables komira maintains; komira jobs on tails and indexes)
```

What changed from the first revision:

- **L3 is no longer a komira format.** For a durable table, L3 is the Iceberg table. Its `metadata.json`, manifest lists and manifests are the one authoritative record, and komira's scan reads them directly. komira keeps no second manifest for the table.
- **L1 has two committers.** An Iceberg table commits through its catalog. A komira tail, index or catalog commits by a `CasManifestStore` append, as before.
- **L4 binds to Iceberg snapshots.** An index over an Iceberg table no longer binds to komira row-id spans.
- **The tail is the one komira table shape left.** It exists only because Iceberg commits a few times a minute at best (see [Freshness](#freshness)).
- **The graph is a layer above L4, not an L4 index and not its own store.** It is the graph data model (entities, edges, episodes and communities, bi-temporal) plus graph query semantics: entity lookup through the search and vector indexes, neighborhood and path traversal through the adjacency index, and retrieval for AI. Its facts are rows in its own Iceberg tables at L3, with a delta tail. The indexes it uses are derived from those tables and bound to their snapshots like any other L4 index.

### Why the graph sits on the indexes but stores its facts in tables

As a capability stack, the graph consumes what L4 provides: it finds entities by text and by vector, and walks relationships through the adjacency index. That does not make an index its store. A graph fact is superseded rather than overwritten (bi-temporal: the old version is kept with the times it was valid and recorded). A search index used as the store would have to delete and re-add the document on every superseded fact, and a fact would be erased only when index compaction physically drops it, so erasure would depend on compaction timing. Keeping the facts in tables gives the graph the table's commit, history and erasure rules (see [Erasure](#erasure)); each index over them can be dropped and rebuilt from the tables at any snapshot.

## L0 and L1: unchanged, now with a narrower scope

L0 (`ConditionalWriteStore`, `object_store.md:29-37`) and L1 (`CasManifestStore`, `src/komira_objectstore/cas_manifest.mojo`) stay as the first revision described them:

- one creator per key;
- append by create-if-absent of the next slot;
- deletion by tombstone, then a grace period, then reap;
- `ShardedLineage` for writer shards.

What changes is their scope. They commit komira's own artifacts: tails, roll records, index generations, the default catalog's state, and the shuffle. They never commit an Iceberg table that lives in a user's catalog.

The L1 work the first revision proposed still applies to those artifacts:

1. **One body framing.**
   - Every chunk body starts with `[kind u16][version u16]`.
   - A decoder rejects an unknown kind or version.
   - Existing bodies are grandfathered by kind.
   - This includes the search summary version check that PR #833 lists as a correctness fix (`src/komira_search_catalog/split_summary.mojo:309` reads the version byte without checking it).
2. **One snapshot type for komira lineages.** `SnapshotRef = (lineage key, chunk_seq)`, plus a shard vector when the lineage is sharded. Offsets are a view of it. **Pins are leases**, and a read under an erased lease fails with a distinct "snapshot erased" error.
3. **Known gaps:**
   - orphaned broker segments (komira#488);
   - the table store deletes log chunks but never advances `_LOG_START`: nothing under `src/komira_table_store` calls `advance_log_start` (`git grep advance_log_start -- src/komira_table_store` is empty);
   - `cas_manifest.mojo` is 4,148 lines and needs to be split.

**Can conditional writes alone serve as an Iceberg catalog for other engines?** No:

- The spec deprecates the file-system commit scheme (`version-hint.text` plus rename) as unsafe on object stores, and the v4 draft removes it ([Iceberg spec](https://iceberg.apache.org/spec/)).
- Engines find tables through a catalog API.

Conditional writes are the right storage *under* komira's REST catalog, and that is what L1 becomes for it.

## L3: Iceberg tables through a catalog

### The catalog seam

`komira_iceberg_catalog` has one seam today: `IcebergCatalog.load_table(namespace, table) -> ResolvedTable`, with a storage-based implementation and a REST implementation. It grows to these verbs:

| verb | what it does |
|---|---|
| `load_table` | returns the metadata location, the metadata, and the per-table `config` (exists today; returns the metadata as text). Vended credentials arrive in `config` |
| `create_table`, `register_table`, `drop_table` | create a table with a schema, partition spec and properties; register an existing metadata location (used by adoption and export) |
| `commit_table(requirements, updates, idempotency_key)` | an optimistic commit; see [the commit client](#the-commit-client) |
| `commit_transaction` | a multi-table commit, only where the catalog advertises it |
| `credentials(table, mode)` | vended credentials or a remote signer for a table's location, where the catalog offers them |
| `capabilities` | what this catalog supports: multi-table commits, namespace depth, credential vending, change events, and whether an optimizer maintains its tables |

Each catalog is an adapter behind that seam. Iceberg REST comes first, because most catalogs now serve it.

| catalog | how komira commits | limits that shape the design |
|---|---|---|
| Iceberg REST (generic) | `POST .../tables/{table}` with requirements and updates ([OpenAPI](https://github.com/apache/iceberg/blob/main/open-api/rest-catalog-open-api.yaml)) | 409 means a requirement failed: reload, then retry. 500, 502 or 504 means the **commit state is unknown**. `Idempotency-Key` is optional. `transactions/commit` is optional |
| Polaris / Snowflake Open Catalog | REST | implements `transactions/commit`; vends credentials |
| Nessie | REST | commits can span tables; supports branches and merges ([Nessie](https://iceberg.apache.org/docs/latest/nessie/)) |
| Unity Catalog | REST, with vended credentials, on managed Iceberg tables | the documented write clients are Spark, Flink, Trino and Snowflake ([credential vending](https://docs.databricks.com/aws/en/external-access/credential-vending)). *To confirm:* that a third-party writer is accepted. UniForm Delta tables are read-only to Iceberg clients |
| S3 Tables | REST ([S3 Tables and open-source engines](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-tables-integrating-open-source.html)) | no `transactions/commit`; single-level namespaces only; operations fail once `metadata.json` passes 50 MB *(to confirm)*; maintenance is run by AWS and is always on (see below) |
| AWS Glue | Glue `UpdateTable` with `VersionId` (optimistic) and `SkipArchive=true`, or Glue's REST endpoint with SigV4 ([Glue REST](https://docs.aws.amazon.com/glue/latest/dg/iceberg-rest-apis.html)) | Iceberg's own Glue catalog skips archiving old table versions by default (`glue.skip-archive`, [Iceberg on AWS](https://iceberg.apache.org/docs/latest/aws/)), so commits do not accumulate Glue table versions. *To confirm:* whether the REST endpoint archives, and its namespace depth. Glue's API throttling limits how often a table may be polled |
| Hive Metastore | `alter_table` under an HMS lock | lock-free commits need a server with HIVE-26882, *and* every other committer on Iceberg 1.3 or later with locks off ([catalog properties](https://iceberg.apache.org/docs/nightly/catalog-properties/)). Default to the lock |
| BigLake metastore | REST ([BigLake REST catalog](https://cloud.google.com/bigquery/docs/blms-rest-catalog)) | BigQuery *external* Iceberg tables do not use it; they read a metadata URI that is updated by hand ([BigQuery external](https://docs.cloud.google.com/bigquery/docs/iceberg-external-tables)) |
| komira's catalog | REST, served by komira, with its state on an L1 lineage in the user's bucket | none of the above; commits shard per table |

**Rule: commit into the user's catalog.** komira's own catalog is the default only when the user has none. Leaving it is a `register_table` into another catalog plus a redirect (journey 6).

**Rule: do not design on multi-table atomicity.**

- S3 Tables does not list `transactions/commit`, and Glue and Unity do not document it.
- Use it where `capabilities` advertises it: Polaris, Nessie, and komira's own catalog.
- Elsewhere, a multi-table write (such as the graph's three tables) commits in a fixed order. komira's reader pins a recorded set of snapshot ids, so it sees a consistent set. Other tools may see skew between those tables, and the documentation says so.

### The commit client

Every adapter follows the same rules, taken from the REST spec and from Iceberg Java's `UpdateRequirements` and conflict checks:

1. **Write files first, then commit.** A data file that no snapshot names is an orphan, never state.
2. **Put requirements on every commit.** A snapshot's manifest list is the table's whole file set, not a diff, so a commit built on parent P that lands after the ref moved to Q would drop Q's files. The requirements stop that:
   - `assert-table-uuid` always, because a dropped and recreated table is a different table;
   - `assert-ref-snapshot-id` on **every** commit that sets a ref, appends included (Iceberg Java does the same for every `SetSnapshotRef`);
   - `assert-current-schema-id` and, with `add-schema`, `assert-last-assigned-field-id`;
   - with a partition-spec change, `assert-default-spec-id` and `assert-last-assigned-partition-id`.
3. **On 409, reload, revalidate, rebuild, then retry.**
   - An append rebuilds its manifest list on the new snapshot and retries. Appends never fail validation after a rebase.
   - Exception, the generation fence for streaming sinks (`plan_models.md`, "The roll v1 → v2, and its fence"): after the reload, an append from a run whose generation is older than the latest `komira.generation` on the table is refused, never rebased, and that committer stops.
   - An overwrite, merge or row delete revalidates against the snapshots added since it started: there must be no new data files matching its filter, and its target files must still be live.
   - A rewrite (compaction or fold) checks that every source file is still live and has gained no new delete files. If not, it fails cleanly and is replanned.
4. **On a 5xx or a timeout, treat the state as unknown, not failed.**
   - Reload the table and look for the commit three ways: the snapshot by its id (komira generates it); a `komira.commit-id` summary property in the ancestry; and, on tables komira created, the `komira.writer.<writer-id>.last-commit` table property, which each commit sets in the same `commit_table` and which survives snapshot expiry.
   - Only if all three are absent may komira retry or reclaim its files.
   - Never delete written files on an unknown outcome.
   - On a table komira did not create, there is no table property; a snapshot that lands and is expired before the reload is indistinguishable from a lost commit. The window is seconds, and the client reloads immediately *(inferred)*.
5. **Send an `Idempotency-Key`** (a UUIDv7) where the catalog supports it.
6. **Poll gently.** Table loads for index refresh and readers back off on throttling, and use the catalog's change events where `capabilities` lists them.

### What komira writes into an Iceberg table

**Parquet data files**, written to these rules (each one is an interop bug when missed):

- Iceberg field ids in every `SchemaElement`, including list elements and map keys and values; lists named `element`, maps `key_value`.
- `timestamp` and `timestamptz` as INT64 microseconds with `isAdjustedToUTC` false and true respectively; nanosecond timestamps only on v3. Never INT96.
- UUID as `FIXED_LEN_BYTE_ARRAY(16)`; decimals in INT32, INT64 or fixed-length bytes chosen by precision, as the spec requires.
- Column statistics go in the manifests; NaN is kept out of lower and upper bounds and counted in `nan_value_counts`.
- Partition values come from Iceberg's transforms.

**Format version 2 by default,** with **merge-on-read position-delete files, file-scoped**: one delete file per data file, with `referenced_data_file` set (optional on v2 in the spec) **and** untruncated, equal `file_path` lower and upper bounds. A v2 reader that predates `referenced_data_file` scopes a delete file to one data file only through those bounds; without them it applies the file across the partition. See [Interop rules](#interop-rules).

**Never equality deletes.** komira resolves its keys to file positions before they reach an Iceberg table (see [Tails](#tails-the-komira-tables-that-remain)).

**Snapshot summary properties:** `komira.commit-id` on every commit; for a rolled tail, `komira.tail.lineage` and the per-partition span it covers.

**Table properties, only on tables komira created or adopted:**

- `komira.maintenance`: who maintains the table;
- `komira.readers`: the readers the user named, which gate opt-ins;
- `komira.subject-keys`: columns that erasure targets (see [Erasure](#erasure));
- `komira.writer.<writer-id>.last-commit`;
- for a topic or row-store table, `komira.tail.<lineage>.rolled-offsets` (see [the roll](#tails-the-komira-tables-that-remain)).

On a table komira did not create, komira writes data and delete files and snapshot summaries, and nothing else: no property, schema-incompatible change, format upgrade, tag or branch.

### What komira reads

| format | how komira reads it | what komira refuses, with a named error |
|---|---|---|
| Iceberg v1, v2, v3 | metadata, manifest list, manifests, Parquet data, position deletes, equality deletes (under the data-sequence-number rule), v3 deletion vectors; time travel by snapshot id or timestamp | ORC and Avro data files until those readers exist; v4 |
| Delta Lake | log replay, checkpoints, deletion vectors, column mapping ([Delta protocol](https://github.com/delta-io/delta/blob/master/PROTOCOL.md)). For `catalogManaged` tables the log is read through the catalog, because the protocol forbids file-system access to them | any `readerFeatures` name it does not implement (for example `variantType` or `typeWidening`), as the protocol requires |
| Hive-style Parquet | a file listing. Partition columns come from `k=v/` directories (`__HIVE_DEFAULT_PARTITION__` is null). Columns are matched by name and schemas are merged by name. Handles INT96 timestamps, legacy decimals and 2-level lists | nothing; the result is marked "no snapshot isolation" |

**How to read Delta.** The reference reader is [delta-kernel](https://github.com/delta-io/delta-kernel-rs), and DuckDB's Delta reader is built on it (Polars reads through the `deltalake` package, which is moving onto the kernel). The kernel has a C FFI, and komira's build already has a Rust toolchain (`tools/build/rust`). The recommendation ([decision 10](#decisions-for-the-maintainers-recommendation-first)) is to read Delta through the kernel's FFI behind one safe module that owns it, not to reimplement log replay in Mojo. UniForm is not enough on its own:

- UniForm exists only for tables registered in Unity.
- It generates Iceberg metadata asynchronously, so it can lag behind Delta and can batch several Delta commits into one.
- It is read-only.
- UniForm serves deletion vectors through IcebergCompatV3; IcebergCompatV2 cannot coexist with them ([UniForm](https://docs.databricks.com/aws/en/delta/uniform)).

**Parquet pieces that exist already:**

- `komira_parquet` reads files: `file_reader.mojo` (`ParquetFileReader`), `nested.mojo` (Dremel reconstruction), and INT96 to nanoseconds (`decode_plain_int96_to_int64`, `plain.mojo:929`).
- `komira_sdk`'s `ParquetReadOptions` carries Hive partitioning and a partition filter.

What does not exist yet: a Parquet file writer, the Iceberg metadata parser and writer, and a Delta reader.

### Adoption

`km.adopt` creates an Iceberg table that komira owns from Hive-style Parquet it did not write:

1. **Check every file** before registering it: physical types against Iceberg's type mapping (a BYTE_ARRAY decimal is not in it), INT96 timestamps, 2-level legacy lists, and missing field ids (which then depend on `schema.name-mapping.default`). Each check runs against the table's `komira.readers`; with none named, against the default reader set (Athena, Spark, Trino, Snowflake, DuckDB).
2. **Register the files that pass** with Iceberg's `add_files` and a name mapping. No rewrite.
3. **Rewrite, per file, the files that fail** into conforming Parquet ([Iceberg procedures](https://iceberg.apache.org/docs/latest/spark-procedures/)). The result lists each rejected encoding and file.
4. **Protect the source.** `add_files` registers files that Iceberg operations can later delete. Until `cutover=True`, the table has `gc.enabled=false` and `komira.maintenance=external`, so no expiry, fold or orphan removal touches the source files. Orphan removal never runs on a location prefix that the table does not own exclusively.

## Interop rules

### Format version and delete encoding

| reader | v2 position / equality deletes | v3 |
|---|---|---|
| Athena | yes / yes ([Athena](https://docs.aws.amazon.com/athena/latest/ug/querying-iceberg-delete.html)) | **cannot read v3** ([AWS v3](https://docs.aws.amazon.com/AmazonS3/latest/userguide/working-with-apache-iceberg-v3.html)) |
| Trino | yes / yes | experimental: no row-level updates, deletes or OPTIMIZE; no column defaults ([Trino](https://trino.io/docs/current/connector/iceberg.html)) |
| Spark with a recent Iceberg runtime | yes / yes | reads and writes; v3 types and row lineage need Iceberg 1.10 or later *(to confirm)* |
| Snowflake | yes / **no equality deletes** ([Snowflake](https://docs.snowflake.com/en/user-guide/tables-iceberg)) | supported; still no equality deletes |
| Redshift | yes | reads and writes, but on v3: no equality deletes, and no nested, binary, uuid or nanosecond types ([Redshift v3](https://docs.aws.amazon.com/redshift/latest/dg/iceberg-v3-features.html)) |
| Databricks | yes | deletion vectors, variant, row lineage; no `initial-default` ([Databricks v3](https://docs.databricks.com/gcp/en/iceberg/iceberg-v3)) |
| BigQuery (external tables) | merge-on-read, capped at 10,000 delete files and 100,000 equality deletes per data file | read-only preview ([BigQuery v3](https://docs.cloud.google.com/lakehouse/docs/use-iceberg-v3-binary-deletion-vectors)) |
| DuckDB 1.5.3 or later | reads all forms; writes position deletes on v2 ([DuckDB](https://duckdb.org/docs/current/core_extensions/iceberg/writing_to_iceberg)) | reads and writes deletion vectors |
| ClickHouse | position deletes; equality deletes from 25.8 | reads deletion vectors; does not write them ([ClickHouse](https://clickhouse.com/docs/reference/functions/table-functions/iceberg)) |

Two facts decide the default:

- **v3 is a one-way upgrade.** AWS and Redshift both say so. A table created as v3 shuts out every Athena reader for good.
- **Equality deletes are the least portable delete form.** Snowflake cannot read them, Redshift rejects them on v3, BigQuery caps them, and the v4 draft forbids writing them.

Iceberg's reference implementation defaults to format version 2 (since 1.4.0) and copy-on-write ([configuration](https://iceberg.apache.org/docs/latest/configuration/)).

**Defaults:**

- **Format version 2** for every table komira creates.
- **Row deletes as file-scoped position-delete files** (merge-on-read). Every reader in the table above reads them. They also map one-to-one onto a v3 deletion vector, so a later upgrade merges them cleanly.
- **A scheduled fold** (a copy-on-write rewrite) folds position deletes into the data files on tables komira maintains. This keeps tables well under BigQuery's per-file cap, and it is the second step of erasure.
- **No equality deletes, ever.**
- **On a table komira did not create,** the table's own format version and `write.delete.mode`, `write.update.mode` and `write.merge.mode` decide. komira writes position-delete files only on v2. On a v3 table it must write deletion vectors, and it refuses row-level writes there until the deletion-vector writer exists (order of work, step 9); the spec forbids adding position-delete files to v3 tables.

**Opt-ins.** Each is set per table, and each is one-way.

- `format_version=3` (deletion vectors, row lineage): available once the deletion-vector writer exists, and only when the user names the table's readers in `komira.readers` and none of them is Athena. With no readers named, the answer is no.
- `delete_mode="copy_on_write"`, for the strictest reader sets: no delete files at all. Refused on upsert topics, where every roll would rewrite whole data files.
- Variant, geo and nanosecond timestamps: only on v3, under the same reader check.
- `initial-default`: never on a required field, because it breaks older readers.

### Maintenance: one maintainer per table

Two maintainers on one table is a known way to corrupt it:

- Compaction running against a streaming writer fails with non-retriable conflicts unless it avoids the partitions being written ([Ryft](https://www.ryft.io/blog/handling-commit-conflicts-in-apache-iceberg-patterns-and-fixes)).
- Glue's orphan-file optimizer can delete a file whose commit was late ([Glue optimizer notes](https://docs.aws.amazon.com/glue/latest/dg/optimizer-notes.html)).

No maintainer is as bad: a 60 s roll producing 64 MB files with nobody compacting or expiring grows small files, delete files and snapshots without bound.

The rules:

- **Every table komira creates carries `komira.maintenance = komira | external`.** On create, komira detects whether something else maintains the catalog's tables and records what it found:
  - S3 Tables: always `external` (AWS maintenance is always on).
  - Glue: `external` if `GetTableOptimizer` shows compaction enabled for the table, otherwise `komira`.
  - Unity managed tables: `external` when predictive optimization is on *(to confirm the API)*.
  - Every other catalog (Hive Metastore, Nessie, Polaris, REST, komira's own): `komira`.
  - The user can override. komira warns when a table is `external` and the detection found no active optimizer.
- **With `komira`,** the maintenance service runs Iceberg's own operations:
  - rewrite data files, in partial-progress mode, never on partitions written during the last roll interval;
  - rewrite position deletes (the fold);
  - rewrite manifests;
  - expire snapshots;
  - remove orphan files, only those at least three days old (Iceberg's default threshold), only under a prefix the table owns exclusively.

  It also sets `write.metadata.delete-after-commit.enabled=true` (with a bounded `write.metadata.previous-versions-max`), so old `metadata.json` files do not accumulate. Fold, manifest rewrite, expiry and orphan removal are the steps erasure needs.
- **With `external`, and on every table komira did not create or adopt,** komira never rewrites, expires or removes orphans.
- **S3 Tables forces `external`** ([S3 Tables maintenance](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-tables-maintenance.html)):
  - Compaction (512 MB target) and snapshot expiry are on by default. Expiry keeps 1 snapshot, expires after 120 hours, and then deletes unreferenced files.
  - A user-defined tag or branch, or Iceberg's own retention properties, makes snapshot management fail for the whole table.
  - References from outside the table do not stop deletion.

  So komira never creates tags or branches on an S3 Tables table, and no komira artifact may rely on an old snapshot's files surviving there.
- **No komira artifact lives under a table location.** komira refuses an index or tail prefix under any table location it knows, because whoever removes that table's orphans would delete it.

### Concurrent writers

Every write is an optimistic commit through the catalog (see [the commit client](#the-commit-client)). What the user sees:

- **komira and another tool both append:** both appends land. The loser rebuilds on the new snapshot and retries.
- **komira deletes, overwrites or merges while another tool writes the same files:** one commit fails cleanly with a named conflict and is replanned. Nothing is lost and nothing is applied twice, **provided the other writer also validates** that the files its deletes target are still live. Iceberg Java does. A writer that does not, and commits after komira's fold, leaves deletes pointing at removed files, and those rows come back. komira cannot prevent this; the prototype tests a second, non-Java writer to find out which ones validate.
- **Another tool compacts while komira's append-mode roll appends:** no conflict, because an append and a rewrite do not collide.
- **Another tool compacts while komira's upsert-mode roll or a fold runs:** these write position deletes against live files, so they are not appends. One of the two fails and is replanned. Under always-on compaction (S3 Tables), upsert rolls on hot partitions are replanned repeatedly; the roll retries with a fresh plan and reports the retry count.
- **Another tool writes a topic or row-store table:** a snapshot that carries no `komira.commit-id` and is not a `replace` (for example a Spark `DELETE`) breaks record fidelity and the row store's key-to-position view. komira pauses the roll and alerts.

### Freshness

An Iceberg commit is one pointer swap per table. So the ecosystem commits every 1 to 10 minutes, with target files of hundreds of megabytes:

- Iceberg's Kafka Connect sink commits every 5 minutes by default ([kafka-connect](https://iceberg.apache.org/docs/latest/kafka-connect/)).
- `write.target-file-size-bytes` defaults to 512 MB.

komira states two freshness numbers for each table:

| who reads | sees data | default |
|---|---|---|
| komira's SDK and consumers | at acknowledgement: the Iceberg snapshot plus the tail above its rolled offsets | sub-second |
| any other tool | at the last roll into Iceberg, plus that tool's catalog cache or refresh | `target_lag` = 60 s on every catalog (komira's own allows down to 10 s) |

The measured lag is published both as a metric and on the topic.

### Schema evolution

- **komira writes by field id.** Add, rename, reorder, widen (int to long, float to double, decimal precision) and drop are Iceberg schema updates that every reader understands. komira never rewrites a table to change its schema.
- **An incompatible change is refused** with a named error. Examples: a narrowing, or a type change outside Iceberg's promotion rules.
- **Another tool may change the schema.** Every komira commit carries `assert-current-schema-id`. On a mismatch, komira reloads the table:
  - If the change is compatible with what komira writes (a new optional column, a rename), it retries under the new schema.
  - If a column komira writes was dropped or narrowed, the write fails with a named error.
  - A topic roll in that case pauses and alerts. The tail keeps the data within its retention; it never drops records.
- **Topics in schema-registry mode** evolve the Iceberg schema with the registry's compatible changes. A record that fits neither schema goes to a dead-letter table `<table>_dlq`, as Redpanda does.

### Erasure

Erasing a row from an Iceberg table takes five steps ([Iceberg table maintenance](https://iceberg.apache.org/docs/latest/maintenance/)):

1. **A row delete** (a position-delete file). This is logical: the bytes are still in the data file.
2. **A rewrite of the affected data files** without the row (the fold). The current snapshot now holds no copy of the row.
3. **A rewrite of the manifests** that still carry entries for the removed files. A rewrite leaves DELETED entries, with the old files' column bounds, in current manifests until they are rewritten.
4. **Expiry of every snapshot** that still references the old files or manifests.
5. **Deletion of the files** that nothing references, including old `metadata.json` files.

The subject also lives in metadata, not only in rows:

- **Column statistics.** Under the default `write.metadata.metrics.default = truncate(16)`, manifests store lower and upper bounds of the subject column. On tables komira creates, the columns named in `subject_keys=` get `write.metadata.metrics.column.<c> = counts`.
- **Partition values.** An identity- or truncate-partitioned subject column puts the value in file paths, manifest partition tuples and manifest-list partition summaries. komira refuses identity and truncate partitioning on a subject key (a bucket transform is allowed).

komira's own artifacts follow within the same deadline:

- Every derived index generation that covered a removed file is rebuilt or purged (see [L4](#l4-derived-indexes)), and cached embeddings of the erased values are purged.
- The topic's tail segments that hold the subject: compacted on the key when the subject is the message key; otherwise the affected segments are rewritten without the matching records, leaving offset gaps as key compaction does.
- The graph's delta objects that hold the subject and have not rolled into the graph's Iceberg tables yet, superseded fact versions included: each affected delta object is rewritten without the matching facts, or dropped when no other fact remains in it, within the same deadline and before the roll or at the roll at the latest, so the roll never carries the subject into the tables. A delta that rolled before the erasure is already rows in the graph's tables and goes through the five steps above.
- The row store's log above its base's rolled offset, which has not rolled into the row store's Iceberg base yet: each commit chunk that holds the subject's `WriteOp`s is rewritten without them, or dropped when no other op remains in it, within the same deadline and before the roll or at the roll at the latest, so the roll never carries the subject into the base. Rows that rolled before the erasure are already in the base table and go through the five steps above.

Who does what depends on who maintains the table:

| the table | komira does | the report says |
|---|---|---|
| maintained by komira | all five steps, then indexes and tails | done, with evidence for each step: files rewritten, manifests rewritten, snapshots expired, objects deleted, index generations purged |
| maintained by another tool or the catalog, v2 | step 1 (a write the user requested, in the table's own delete mode); step 2 only with `rewrite=True` on the `erase` call, recorded in the erasure job; indexes and tails in full | "awaiting the maintainer" for steps 3 to 5, with the oldest snapshot that still holds the subject; re-checked on each poll |
| maintained by another tool or the catalog, v3 | indexes and tails only, until the deletion-vector writer exists | "awaiting the owner's delete" for steps 1 to 5 |

**Limits that komira states plainly:**

- **Snapshots that another tool keeps** hold the old files: a tag or branch it created, or a long retention setting. komira lists them and does not remove another owner's refs.
- **Metadata on tables komira did not create** keeps whatever statistics and partition values the owner configured.
- **Copies that other tools made** are outside komira's reach: a Snowflake `CREATE TABLE AS`, an extract, a BigQuery copy.
- **Bucket versioning keeps deleted objects** as noncurrent versions. Erasure is complete only with a lifecycle rule that expires noncurrent versions within the deadline. The documentation says so; an automated check is deferred.

## Tails: the komira tables that remain

A tail exists where data must be visible faster than Iceberg can commit. There are three:

| tail | format | rolls into |
|---|---|---|
| topic partition | Arrow IPC stream `.seg` with a `TSG1` footer (`src/komira_broker/broker_core.mojo:66-90`); one PUT plus one append per acknowledgement | the topic's Iceberg table |
| row store | commit chunks of `WriteOp[]` PUT and TOMBSTONE (`src/komira_table_store/table_store_codec.mojo:153-166`) | the row store's Iceberg base table |
| graph deltas | IPC delta objects (PR #833, `data_graph_storage.md`, "What changed from the first revision") | the graph's Iceberg tables |

### The roll

The roll replaces the first revision's "tier move". It is a maintenance job, never part of the broker:

1. **Plan** against a pinned tail snapshot: for each partition, a contiguous span of offsets (or log seqs) above the table's rolled offset for that partition.
2. **Record the intent** on the tail's own L1 lineage: (commit id, per-partition spans). This is komira's lineage, not a write to anyone else's table.
3. **Write Parquet** sized for the table: 64 MB or more per file. A roll waits until it has that much data or until `target_lag` passes, whichever comes first.
4. **Resolve keys to positions** in the Iceberg table's live files, and write position-delete files:
   - in both modes, the span's key tombstones;
   - in `mode="upsert"`, also the previous row of every key the span PUTs, after last-wins deduplication inside the span.

   This is the key-to-position lookup that the first revision kept off the write path. It now runs in the roll, which is maintenance. Its cost is bounded by partitioning upsert tables on a key bucket *(inferred)*. Because these deletes target live files, an upsert roll can conflict with a concurrent compaction (see [Concurrent writers](#concurrent-writers)).
5. **Commit one snapshot** through the catalog, with `assert-ref-snapshot-id`, carrying in the same `commit_table`:
   - `add-snapshot`, with `komira.commit-id`, `komira.tail.lineage` and the spans in the summary;
   - `set-properties` for `komira.tail.<lineage>.rolled-offsets` (the last rolled offset of **every** partition, not only those in this roll) and `komira.writer.<writer-id>.last-commit`.

   Table properties survive snapshot expiry and other tools' compaction; summaries do not carry forward. On an unknown outcome, the reload compares the rolled-offsets property with the recorded intent, so the span is never committed twice.
6. **Record the result** on the tail lineage: (commit id, Iceberg snapshot id).
7. **Advance the tail's `_LOG_START`** past the span. Tombstone the rolled tail objects and reap them after the grace period.

Once the tail is reaped, the Iceberg table is the only copy of those offsets, and it is a source of truth.

**Reading a table together with its tail.** komira's reader:

1. pins the tail;
2. loads the Iceberg table;
3. reads the per-partition rolled offsets from the loaded metadata's table properties (the summary copy is a cross-check);
4. for each partition, if `rolled_offset + 1 < log_start` of the pinned tail, the catalog served stale metadata: reload, and if the gap persists, fail with a named error. It never reads across a gap;
5. reads the tail strictly above each rolled offset.

Pinning the tail first means that any tail chunk reaped after the pin is covered by a snapshot the reader can see, provided the catalog's load reflects the commit; step 4 catches a catalog that does not *(inferred)*.

**Rollback by another tool.** If another tool sets the current snapshot to one before a roll, the rolled-offsets property still names offsets that the current snapshot does not hold, and their tail was reaped. The maintenance service checks on each cycle that the last rolled snapshot id (from the tail lineage) is an ancestor of the current snapshot. If not, it raises a named alert: those offsets are lost for every reader, and the roll pauses until an operator decides.

**Record fidelity.** The topic's Iceberg table keeps every record field that a live read returns: offset, timestamp, key, headers, producer id and epoch, sequence, and transaction markers. A consumer read served from the table then equals one served from the tail *(inferred; the transcoder is not in komira)*.

An analytic table keyed by business data is a separate table materialized from the topic. It never shares bytes with the log: a zero-copy log-as-table forces one sort order on both, and puts Parquet encoding on the produce path.

**Key-compacted ranges** still cannot roll through today's `append_compacted` check, which requires `last == base + record_count - 1` (`src/komira_broker/compacted_index.mojo:337`). The fix: the roll records a span and a row count, and checks the span. Until that lands, key compaction runs on the tail only.

**The row store:**

- Its log stays the commit path and the snapshot allocator. Row MVCC (snapshot isolation on `snapshot_lsn`, first committer wins) is unchanged.
- Its base is an Iceberg table, rolled in upsert mode with the same rolled-offsets property.
- A snapshot is the pair (Iceberg snapshot id, log seq), pinned log first.
- Recovery loads the base and replays the log above its rolled offset.
- The roll advances `_LOG_START` when it deletes log chunks, which the current table store does not (see [L1 known gaps](#l0-and-l1-unchanged-now-with-a-narrower-scope)).

## L4: derived indexes

A derived index is any artifact that can be rebuilt from tables that outlive it: a search split, a vector index, CSR adjacency, statistics, or a re-sorted copy. The one exception is log search, where documents go straight into splits and no table holds them. It is its own source of truth and needs per-document delete sets (`search_index_format.md`, decision 2).

### What every index generation records

- **The source:** catalog, table identifier and **table uuid**.
- **The Iceberg snapshot id** it was built at.
- **Coverage:** the set of data files it indexed, each with the delete files it applied. On a v3 table with row lineage, also the `_row_id` ranges.
- **A builder fingerprint:** the analyzer, the embedding model, and the field ids of the indexed columns.
- **Key columns,** when the table has `identifier-field-ids` or the user names a key: the key value of each indexed row.

A hit is stored as (data file, position) on v2, and as `_row_id` on v3.

The generation is committed on a komira L1 lineage under the index's prefix, which must lie outside every table location. Nothing is written to the source table or its catalog, and no tag or branch pins the source snapshot.

**The content cache.** Embeddings and analyzed term lists are cached by (builder fingerprint, hash of the indexed column values). A file rewritten by another tool's compaction holds the same values, so re-indexing it costs reading it, not calling the model again. Erasure purges the erased values' entries.

### Detecting new snapshots

1. **Notice a new snapshot.** Use the catalog's change events where `capabilities` lists them (for Glue, its table-change events). Otherwise poll `load_table` on the refresh interval, backing off on throttling. Compare the current snapshot id with the index's.
2. **If the table uuid changed** (the table was dropped and recreated), rebuild from scratch.
3. **If the new snapshot descends from the indexed one,** walk the snapshots between them and apply each operation:

| snapshot operation | the index does |
|---|---|
| `append` | index the added data files |
| `delete` / `overwrite` with new position-delete files or deletion vectors | mask the deleted positions immediately; purge them from the index's files within the erasure deadline |
| `delete` / `overwrite` with new equality-delete files (Flink upserts, CDC tools) | no positions exist to mask: evaluate the delete predicates on the stored key columns (or on fetched rows), for data files whose data sequence number is lower than the delete file's |
| `overwrite` that removes files | drop those files' entries; index any added files |
| `replace` (another tool compacted) | on v3 with row lineage: entries keyed by `_row_id` survive; only the file map changes. On v2 with key columns: remap entries by key (the default whenever keys exist). On v2 without keys: drop the removed files' entries and re-index the added files through the content cache |

4. **If the indexed snapshot has expired, or the current snapshot does not descend from it** (a rollback, or a branch made current): diff the index's own covered-file set against the live files of the current snapshot. Because the index keeps its own file set, it never needs the expired snapshot's metadata.

### The read rule

A query against snapshot S:

1. **Uses an index generation only if its snapshot is S or an ancestor of S.** An index built later may lack rows deleted since S.
2. **Covers the gap according to the query's consistency mode:**
   - `consistency="index"` (default): read the index for files covered and live at S; rows in files the index does not cover yet are not returned, and `hits.lag` counts them.
   - `consistency="exact"`: also scan the live files of S that the index does not cover. For text this is a scan. For vectors it is a brute-force distance computation that needs embeddings of the uncovered rows: served from the content cache where present, otherwise computed under a byte budget; past the budget the query fails with a named error rather than answer partially.
3. **Checks every hit against S before returning it.** The hit's file must be live at S, its position must not be deleted at S by a position delete or deletion vector, and its row must not match an equality delete that applies to it. For the graph, the hit must also pass the `as_of` filter. A hit from a file another tool removed, or from a row another tool deleted, is dropped even while the index lags.

So an index may lag, but it cannot lie.

- After another tool compacts a v2 table without keys, most files are briefly uncovered.
- The index's lag bound (in files or bytes) triggers a catch-up build.
- Ranked text has one more cost in exact mode *(inferred)*: BM25 scores from the index and from scanned files are comparable only if term statistics are merged across both.

**Invariants:**

- An index never returns a row that its reader's snapshot does not hold.
- A reader never uses an index built after its snapshot.
- After an erasure, every generation whose coverage includes a rewritten or deleted file is rebuilt, and the old one is reaped, within the dataset's deadline.
- Dropping every index loses no data.

## Source of truth and derived

The first revision's rule stands: every stored artifact is either a source of truth or derived, never both.

- **Sources of truth:** Iceberg tables (whoever wrote them), komira tails for the spans not yet rolled, the row store's log above its base's rolled offset, blobs, and log-search splits.
- **Derived:** every index, the content cache, statistics that komira keeps outside the table, and materialized copies.

A roll transfers ownership; it does not derive.

**Backup:** the user's bucket and catalog hold the Iceberg tables; komira's L1 lineages hold the tails and roll records. Indexes are rebuilt on restore.

**Blobs** keep the first revision's rules:

- A blob is written with `If-None-Match` under its sha256 and referenced from table rows.
- It is reaped when no retained snapshot references it.
- When a write gets a 412 because the blob exists but is tombstoned, the writer clears the tombstone with `compare_and_swap` before committing its reference.
- The reaper deletes only by `If-Match` on the tombstone version it read.

## Maintenance operations

"Compaction" named seven different mechanisms. On the revised stack they split by who commits:

| operation | applies to | runs when | ends in |
|---|---|---|---|
| rewrite data files, rewrite position deletes (the fold), rewrite manifests, expire snapshots, remove orphans | Iceberg tables | only when `komira.maintenance = komira` | the catalog's commit; file deletion after expiry |
| roll | tails | always (komira owns tails) | an Iceberg commit, then tail reap |
| fold manifest | komira lineages | always | reap (`SubLineageBaseFold`, "ZERO byte copy") |
| fold deletes (key compaction), erasure rewrite | topic tails | always | reap |
| erasure rewrite or drop | graph delta tails | always, before or at the roll | reap |
| erasure rewrite or drop | row-store log chunks above the base's rolled offset | always, before or at the roll | reap |
| re-partition | topic tails | on request; renumbers offsets into child lineages, so indexes over the parent are rebuilt | reap |
| merge index | index generations | always | a visible new generation, then reap of its inputs |

- **komira-lineage operations** run through the `compact_once` envelope (`src/komira_objectstore/compact_window.mojo`, which has no caller outside its own test today). The envelope gains a second mode for operations whose output is visible (merge index), and the ported split merger gets its own name.
- **Iceberg operations** follow Iceberg's procedures and conflict rules, not `compact_once`.
- **One maintenance service runs all of them** as typed jobs, outside the broker and the query paths, with one erasure deadline per dataset.

## What komira still owns, what it no longer builds, and the order of work

**komira still owns:**

- L0 and L1 (`ConditionalWriteStore`, `CasManifestStore`, `ShardedLineage`), for tails, roll records, indexes, the default catalog and the shuffle.
- The tail formats (topic segments, row-store log, graph deltas) and the roll.
- The derived index formats (`THSPLIT` search splits, vector files, CSR), the content cache, and their binding to snapshots.
- The Parquet writer, the Iceberg writer and reader, the catalog adapters, and the default Iceberg REST catalog.
- The maintenance service, for tables komira maintains and for everything on L1.

**komira no longer builds:**

- The custom L3 table-commit body, its format tag per file entry, and the komira table snapshot for durable tables.
- komira row ids for durable tables. Offsets and log seqs stay inside tails. Durable tables use Iceberg file positions, or `_row_id` on v3.
- An Iceberg *export*, and "exported snapshots as reap pins".
- IPC as a durable table format. IPC remains the tail format, and a graph table is in IPC only until its first roll.
- A Delta log reader of its own, if decision 10 is accepted.

**Order of work.** Each step is usable on its own. Steps 1 to 3 win the first workload.

1. **The Parquet writer**, to the rules in [What komira writes](#what-komira-writes-into-an-iceberg-table). Extend the existing reader for the shapes the gather paths do not handle yet.
2. **The Iceberg writer and reader, and the catalog clients.**
   - Metadata, manifest lists and manifests: v2 for writing, v3 for reading.
   - Position-delete files with `referenced_data_file` and exact `file_path` bounds.
   - The commit client, with its requirements and its rules for 409s, unknown outcomes and idempotency; the write modes of journey 1.
   - Credentials: vended, assumed role, ambient.
   - Adapters, in this order: REST (which also covers Polaris, Nessie, Unity, S3 Tables and BigLake), then Glue, then Hive Metastore.

   Journeys 1 and 2 (for Iceberg) work after this step.
3. **Reading what users already have:**
   - Delta through the kernel's FFI, including deletion vectors, column mapping and catalog-managed tables read through the catalog;
   - Hive-style Parquet with schema merging;
   - `adopt`, with footer checks, per-file rewrite and source protection.
4. **The default catalog:** an Iceberg REST server over an L1 lineage, with `register_table` export and the moved-table redirect. Until a user needs it, the prototype's in-test REST server is enough, and teams on AWS or GCP have Glue, S3 Tables or BigLake.
5. **L1 framing, `SnapshotRef` and pins as leases** for komira lineages, before any new body kind lands.
6. **The hot-tail roll**, journey 3:
   - topic and row store into Iceberg;
   - intent and result records on the tail lineage;
   - the rolled-offsets table property and the gap check;
   - tombstones and upserted keys resolved to position deletes;
   - the span-plus-count check;
   - record fidelity;
   - rollback and foreign-snapshot alerts.
7. **Index snapshot binding**, journey 4:
   - generations bound to (table uuid, snapshot id, covered files), with key columns;
   - the content cache;
   - snapshot detection, including equality deletes;
   - the read rule and its consistency modes;
   - the CAS split catalog wired into `komira_search_scan` (whose `BUCK` does not depend on `komira_search_catalog` today).
8. **The maintenance service** for Iceberg tables komira maintains (fold, manifest rewrite, expiry, orphans), maintainer detection, and erasure with its per-owner report. Journey 5.
9. **The deletion-vector writer**, which unlocks the `format_version=3` opt-in and row-level writes to other owners' v3 tables.
10. **The blob store**, before any table references blobs.

**Duplications still to remove:**

- 11 private little-endian helper copies (`git grep -lE 'def _[a-z_]*put_i64_le'`), in step 5.
- Two `.seg` formats under one name. Rename the shuffle's.
- Two functions named `compact_once`.
- Search's own shard reaper beside `ShardedLineage`.
- FNV-keyed or plain-`put` content objects.
- Unswept broker segments (komira#488).

## What must always hold

- **The catalog is the commit point for Iceberg tables; an L1 append is the commit point for everything else.** A file that no commit names is garbage.
- **Every commit asserts the ref it was built on.** No commit can drop another writer's files.
- **komira maintains, changes properties of, or upgrades only tables it created or adopted,** and never one whose `komira.maintenance` names another maintainer. It writes rows to other tables only when the user asks, in the owner's delete mode and format version.
- **An unknown commit outcome is never treated as a failure.**
- **Whatever komira writes is readable in every tool in the table's reader set:** v2 unless the table opted in, no equality deletes, field ids everywhere.
- **The table-to-tail boundary survives other tools' maintenance.** The rolled offsets live in a table property; a reader never reads across a gap.
- **Derived artifacts never lead their source.** No index returns a row that its reader's snapshot does not hold.
- **Erasure has a deadline and an honest report.** It covers tables, their metadata, tails, indexes and old snapshots, and names what is outside komira's reach.
- **Decoding is strict.** An unknown komira body kind or version, or an unimplemented Delta reader feature, is an error, never a default.

## How would a prototype prove it?

The prototype is proposed and has not been run. It tests interop: komira writes and other engines read, and other engines write underneath komira's tables and indexes.

**Setup:**

- It builds as Buck2 targets with welded tests on the farm.
- It uses the local-filesystem store, a REST catalog served inside the test, the Parquet and Iceberg writers, and `komira_search`.
- The outside engines are DuckDB (1.5.3 or later, with its Iceberg extension), Spark with the Iceberg runtime, and PyIceberg, all as pinned build tools. If Spark is too heavy for the farm, PyIceberg replaces it as a reader; it stays as the second, non-Java writer either way.

**Steps:**

1. **Write and read back.** Create a table through the SDK (v2, partitioned by day) and append two batches. DuckDB and Spark read it through the REST catalog. Rows, types and field ids match what was written, and partition pruning works in both.
2. **Another writer.** Spark appends between komira's plan and its commit. komira's commit gets a 409, rebuilds and lands. Both appends are present exactly once. Then the same with a merge: komira's merge and a PyIceberg delete on the same file; one fails and is replanned, and the result equals a serial order.
3. **Unknown outcome.** The catalog commits and then answers 502. komira reloads, finds its commit, and does not commit again. Repeat with the snapshot expired before the reload, on a table komira created: the writer property still finds it.
4. **Deletes.** komira deletes rows. The manifests hold position-delete files with `referenced_data_file` set and equal `file_path` bounds, and no equality-delete file. DuckDB and Spark return the same rows as komira.
5. **Schema change by another tool.** Spark adds one column and renames another. komira's next append carries the new schema id and writes by field id. DuckDB reads the old and new files together.
6. **Topic roll.** Produce to a 3-partition topic and roll twice, the second roll covering only two partitions. komira's reader, with the tail, sees every offset exactly once across the boundary. DuckDB sees exactly the offsets each partition has rolled.
7. **Roll under foreign maintenance.** After step 6, Spark runs `rewrite_data_files` and `expire_snapshots(retain_last=1)`. komira's reader with the tail still sees every offset exactly once, and a third roll lands. Then an upsert-mode roll runs against a concurrent `rewrite_data_files`: one is replanned, and every key has exactly one live row.
8. **Index over a table another tool changes.**
   - Build a search index at snapshot S1.
   - Spark appends, deletes a matching row, and runs `rewrite_data_files`. The test then commits an equality-delete file for another matching row, as a Flink upsert would.
   - At the new snapshot, `consistency="exact"` returns the appended row, and neither deleted row, with no duplicates, before and after the index catches up. `consistency="index"` returns no deleted row and reports the lag.
   - The catch-up after the rewrite makes no embedding-model calls (counted).
   - A query at S1 still answers at S1.
9. **Erasure.**
   - Create the table with `subject_keys=["customer_id"]`. Erase a subject: delete, fold, rewrite manifests, expire, remove orphans, rebuild the index.
   - Byte-scan every object under the warehouse and index prefixes for the subject, metadata included.
   - Spark time travel to the pre-erasure snapshot fails as expired.
10. **Adoption.** Adopt a Hive-style directory in place with one INT96 file and one BYTE_ARRAY decimal file. The decimal file is rewritten and listed. Fold and expire on the adopted table before cutover; every source file still exists.
11. **Foreign formats.** Read committed fixtures:
    - a Delta table with deletion vectors and column mapping;
    - a Delta table with an unknown reader feature, which is refused by name;
    - Hive-style Parquet with an INT96 column and a null partition.

Each planted mutant below must turn a test red:

| mutant | red test |
|---|---|
| write format version 3 by default | step 1's check that `format-version` is 2 |
| write a key tombstone as an equality delete | step 4's manifest check |
| truncate the `file_path` bounds on position-delete files | step 4's bounds check |
| omit field ids in the Parquet writer | step 5: DuckDB reads the renamed column as null |
| treat a 5xx as a failure and retry | step 3: the rows appear twice |
| drop `assert-ref-snapshot-id` on append | step 2: Spark's append is lost |
| skip the merge revalidation | step 2: the deleted row returns |
| keep the rolled offsets only in the snapshot summary | step 7: duplicate or missing offsets after expiry |
| write the rolled offset only for partitions in the roll | step 6: duplicate offsets in the partition left out |
| upsert roll without deleting the previous row of a PUT key | step 7: a key with two live rows |
| drop the live-row check | step 8: the deleted row is returned |
| ignore equality deletes in the live-row check | step 8: the equality-deleted row is returned |
| treat a `replace` as a no-op in the index | step 8: hits point at removed files and rows go missing |
| skip the index rebuild on erasure | step 9: the byte scan finds the subject |
| keep `truncate(16)` metrics on a subject key | step 9: the byte scan finds the subject in a manifest |
| skip the manifest rewrite in erasure | step 9: the byte scan finds the subject in a manifest |
| skip snapshot expiry in erasure | step 9: time travel still returns the subject |
| adopt without `gc.enabled=false` | step 10: source files deleted |
| accept an unknown Delta reader feature | step 11's refusal test |

One more run belongs against a real Glue or S3 Tables account (optional, and it costs money): a single append and a single delete, read from Athena. It confirms the v2 and position-delete defaults, `SkipArchive`, and the Lake Formation grants, where the readers are not open source.

## Decisions for the maintainers (recommendation first)

**Withdrawn from the first revision:**

- decision 1 (komira's own L3 table layer);
- decision 6 (komira's lineage as the commit point, with Iceberg as an export);
- the parts of decisions 4, 5 and 10 that assumed a komira table format.

Decisions 2, 3, 7, 8 and 9 are kept, revised as noted below.

1. **Durable tables are native Iceberg tables, committed through the user's catalog.** *Replaces old 1 and 6.*
   - **Recommend yes.**
   - Rejected: komira's own table format with Iceberg exported. Other tools cannot read the table until the export runs, the user's own maintenance breaks it, and it is a second metadata dialect to keep in step.
   - Rejected: no Iceberg writing at all.
2. **A catalog seam with adapters (REST first, then Glue and Hive Metastore); komira's log-backed REST catalog only when the user has none, built after reading users' existing data.** *New.*
   - **Recommend yes.**
   - Rejected: requiring komira's catalog. That is the lock-in a first workload trips over.
   - Rejected: object-store conditional writes as the catalog other engines use. The spec calls that scheme deprecated and unsafe, and other engines cannot discover tables through it.
3. **Format version 2 and file-scoped position deletes by default; v3 per table, only after the deletion-vector writer exists and only when the named readers all read it; never equality deletes.** *Replaces old 5.*
   - **Recommend yes.**
   - Rejected: v3 deletion vectors by default. Athena cannot read v3, the upgrade is one-way, and Trino has no DML on v3.
   - Rejected: equality deletes for key tombstones. Snowflake cannot read them, Redshift rejects them on v3, and the v4 draft forbids them.
4. **One maintainer per table, named in `komira.maintenance`, defaulting to komira unless an active optimizer is detected.** *New.*
   - **Recommend yes.**
   - Rejected: komira always maintains what it writes. That collides with S3 Tables and with catalog optimizers.
   - Rejected: `external` wherever the catalog could maintain tables. On Glue with optimizers off, Hive Metastore, Nessie and Polaris, nobody would.
5. **komira writes rows to any Iceberg table the user names, but maintains, changes properties of, or upgrades only tables it created or adopted.** *New.*
   - **Recommend yes.** Taking over one job's writes to an existing table is the most likely first workload.
   - Rejected: writing only tables komira created or adopted. It leaves that workload no path, since `adopt` covers only Hive-style Parquet, while the commit client already handles concurrent writers.
   - Rejected: maintaining any table komira writes. komira would share maintenance with a tool it cannot see.
6. **A topic is a komira IPC tail plus an Iceberg table it rolls into, with per-partition rolled offsets as a table property. The row store is its log plus an Iceberg base, pinned log first. The broker never writes Parquet.** *Replaces old 4 and 10.*
   - **Recommend yes.**
   - Rejected: zero-copy log-equals-table. It forces one sort order and puts Parquet CPU on the produce path.
   - Rejected: a topic committing straight to Iceberg on every flush. A few commits a minute is the ceiling.
   - Rejected: rolled offsets only in snapshot summaries. Other tools' compaction and expiry lose them.
7. **`target_lag` defaults to 60 s on every catalog (komira's own allows down to 10 s); Glue commits use `SkipArchive=true`.** *New; revised in review.*
   - **Recommend yes.**
   - Rejected: a 5-minute Glue default. It rested on Glue's table-version cap, which applies only when archiving is on, and Iceberg's own Glue catalog turns it off.
8. **Derived indexes bind to (table uuid, snapshot id, covered files), keep their own file set and key columns, cache embeddings by content, and never pin the source table.** *Revises old 2.*
   - **Recommend yes.**
   - Rejected: coverage by komira row-id span, because durable tables no longer have komira row ids.
   - Rejected: pinning the source snapshot with a tag. It breaks S3 Tables' snapshot management, and it is a write to a table komira does not own.
   - Rejected: re-embedding after every external compaction. Under always-on compaction the index would re-embed the table continuously.
9. **Search is derived by default; only log search is its own source of truth.** *Old 3, kept.*
   - **Recommend yes.**
10. **Read Delta through delta-kernel's FFI, behind one safe module, rather than a native Mojo reader or UniForm alone.** *New.*
    - **Recommend yes**, subject to pinning a kernel release as a third-party source in the build.
    - Rejected: a native Mojo Delta reader. It reimplements the reference reader and must track every new protocol feature.
    - Rejected: UniForm only. It covers only Unity-registered tables, it lags, and it is read-only.
    - Deferred: writing Delta metadata beside Iceberg, as Fivetran does. Unity reads Iceberg directly.
11. **Strict body framing, `SnapshotRef` and pins as leases for komira lineages, before any new body kind lands.** *Old 8, scoped to L1.*
    - **Recommend yes.**
12. **komira-lineage maintenance on the `compact_once` envelope, with a visible-output mode; Iceberg maintenance on Iceberg's procedures; one service runs both.** *Old 7, revised.*
    - **Recommend yes.**
13. **Run the interop prototype above before PR #833 is accepted.** *Old 9, re-aimed.* PR #833's graph tables become Iceberg tables with an IPC delta tail, and its budgets are "proposals, not measurements" (`data_graph_storage.md`, "How the options compared").
    - **Recommend yes.**
14. **The journeys are written against a Python SDK.** *New; a product question.* komira's SDK today is Mojo and builds plans only. dbt and Airflow users will also ask how to call komira.
    - **Recommend** that the maintainers confirm the Python surface, and whether a dbt adapter is in scope, before step 2's API is fixed.

## Corrections to the first revision

- **v3 deletes.** The first revision said v3 "deprecates only position-delete *files*". In fact v3 prohibits adding new position-delete files (existing ones stay valid), and the v4 draft prohibits new equality deletes.
- **Row lineage.** It said v3 row lineage "requires a rewrite to write `_row_id` physically". It does not. `_row_id` is inherited at read time as `first_row_id + _pos`, and is written physically only when a row moves to a new file, as in compaction.
- **UniForm and deletion vectors.** It said UniForm "historically could not serve tables that used deletion vectors". IcebergCompatV3 now serves them; IcebergCompatV2 still cannot.
- **`version-hint.text` compare-and-swap** is not a valid commit option. The spec calls that scheme unsafe on object stores.
- **"Exported snapshots are reap pins"** assumed that komira controls how long the files live. In a user's catalog it does not: the user's expiry and compaction decide, and komira's artifacts must tolerate that.

## Corrections made in review of this revision

- Appends now carry `assert-ref-snapshot-id`; without it a server that does not check sequence numbers installs a manifest list that drops another writer's files.
- The Glue table-version cap is not a constraint with `SkipArchive=true`; the 5-minute Glue default and its arithmetic are gone.
- The tail's rolled offsets moved from snapshot summaries, which other tools' compaction and expiry lose, to a per-partition table property.
- The per-partition boundary between rolled Iceberg data and the tail is called the *rolled offset* (property `komira.tail.<lineage>.rolled-offsets`), not a watermark: in komira's specs "watermark" means only the event-time watermark of the streaming plan model.
- Upsert rolls resolve every overwritten key, not only tombstones, and are not conflict-free appends.
- Erasure now covers manifest statistics, partition values and manifest rewrite; the erasure table no longer contradicts the write rules; v3 tables of other owners wait for the deletion-vector writer.
- In-place adoption no longer lets maintenance delete the source files.
- Exporting from komira's catalog leaves a redirect, not a second live pointer.
- komira writes rows to existing tables the user names; ownership gates maintenance and properties, not writes.
- The Parquet reader exists in `komira_parquet`; the gap is the writer. The `table_store.mojo:52` citation was a to-do comment; the claim now cites the missing `advance_log_start` call.

## Where is the code?

| area | paths |
|---|---|
| L0, L1 | `src/komira_objectstore/` (`store.mojo`, `cas_manifest.mojo`, `compact_window.mojo`, `sharded_lineage.mojo`, `sublineage_base_fold.mojo`) |
| Iceberg catalog (read-only today) | `src/komira_iceberg_catalog/` |
| Parquet | `src/komira_parquet/` (`file_reader.mojo`, `nested.mojo`, `plain.mojo`), `src/komira_parquet_api/`, `src/komira_parquet_codec/` |
| SDK (plan building) | `src/komira_sdk/` (`parquet_read_options.mojo` for Hive partitioning) |
| topic tail | `src/komira_broker/` (`broker_core.mojo`, `compacted_index.mojo`, `log_compaction.mojo`, `partition_compaction.mojo`, `retention.mojo`) |
| row store | `src/komira_table_store/` |
| search | `src/komira_search/`, `src/komira_search_catalog/`, `src/komira_search_scan/` |
| IPC | `src/komira_arrow_ipc/`, `src/komira_scan_source/arrow_source.mojo` |
| graph | proposal on branch `docs/search-format-kg` |
| Rust toolchain (for the Delta kernel) | `tools/build/rust/` |

External references: [Iceberg spec](https://iceberg.apache.org/spec/) · [Iceberg REST OpenAPI](https://github.com/apache/iceberg/blob/main/open-api/rest-catalog-open-api.yaml) · [Iceberg configuration](https://iceberg.apache.org/docs/latest/configuration/) · [Iceberg on AWS](https://iceberg.apache.org/docs/latest/aws/) · [Iceberg Spark procedures](https://iceberg.apache.org/docs/latest/spark-procedures/) · [Puffin spec](https://iceberg.apache.org/puffin-spec/) · [Delta protocol](https://github.com/delta-io/delta/blob/master/PROTOCOL.md) · [delta-kernel](https://github.com/delta-io/delta-kernel-rs) · [Spark Parquet options](https://spark.apache.org/docs/latest/sql-data-sources-parquet.html) · [Confluent Tableflow](https://docs.confluent.io/cloud/current/topics/tableflow/overview.html) · [Redpanda Iceberg topics](https://docs.redpanda.com/current/manage/iceberg/about-iceberg-topics/) · [S3 Tables](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-tables.html) · [Dremio on Iceberg v3 deletion vectors](https://www.dremio.com/blog/dremio-iceberg-v3-deletion-vectors/) · [Lance index format](https://lance.org/format/index/) · [Turbopuffer architecture](https://turbopuffer.com/docs/architecture)
