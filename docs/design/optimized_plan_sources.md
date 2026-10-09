# Design: sources, index operators and graph operators in an `OptimizedPlan`

Status: proposed, not built. This is §15 of [`optimized_plan.md`](optimized_plan.md), kept in its own file so each
file stays under 1,000 lines. Section numbers continue that document's: `§15.x` is here, `§10.x` is in
[`optimized_plan_udfs.md`](optimized_plan_udfs.md), and every other `§n` is in `optimized_plan.md`.

Citations are to komira `main` as of 2026-10-09 unless marked otherwise. The storage rules cited as
"storage stack" are `storage_stack.md` revision 2 (komira-ai/komira#1134, at the head of branch
`docs/storage-stack`); the graph rules cited as "graph storage" are `data_graph_storage.md`
(komira-ai/komira#833, at the head of branch `docs/search-format-kg`). Statements marked *(inferred)* are my reading, not facts taken from the code. Nothing was built or run
to write this document.

---

## 15.1 Requirement and what exists

**Requirement.** Full-text search, broker topics, vector search and the knowledge graph are part of the same
logical plan, and so of the same `OptimizedPlan`, as every relational operator, and every SDK (Python, TypeScript and
Mojo now; more later) builds them with the same verbs and the same plan nodes. A search result joins a table, feeds a
UDF, fuses with a vector result and seeds a graph traversal inside one plan, under one digest, one set of snapshot
pins and one admission.

**What exists.**

- A scan source is a `oneof` of `WireParquetSource parquet = 1` and `WireScanBinding binding = 2`
  (`src/komira_plan_proto/plan.proto:456-461`). Every other source is a binding: a kind name, its FNV-1a/32 hash
  (`src/komira_scan_source/scan_binding.mojo:166-186`), typed `WireParam`s and a schema (`plan.proto:372-416`).
- Two product kinds live outside core, `komira.broker.topic` (`src/komira_broker/broker_scan_binding.mojo:77`) and
  `komira.search.index` (`src/komira_search_scan/search_scan_kind.mojo:128`). Both are `SNAPSHOT_LIVE`: the token is
  excluded from identity and re-resolved when execution starts. A pinned search read is a `generation` **param**,
  because `ScanKindRegistry.validate` allows one policy per kind (`scan_kind_registry.mojo:202`); the golden
  `src/komira_plan_wire/tests/fixtures/golden/index_pinned.txtpb` freezes that spelling.
- The search kind returns `_score, _id, _source`; `_id` is **split-local** (`search_scan_kind.mojo:63-64`), and the
  kind has no `k`.
- There is no Iceberg, Delta, row-store, vector or graph kind (`komira_iceberg_catalog` registers none), no search,
  vector or graph operator among `WirePlan`'s 16 arms (`plan.proto:1558-1582`), and no distance function among
  `WireExpr`'s (`plan.proto:1063-1110`). The only SDK in `src/` is the plan-building half of the Mojo SDK, with no
  search, topic or graph verb (`src/komira_sdk/README.md`).
- `WireScalar` cannot hold a list (`plan.proto:285-334`), though a schema can declare `ARROW_TYPE_FIXED_SIZE_LIST`
  (`plan_vocabulary.proto:618`): a query vector has no typed spelling.
- `PARAM_BYTES` travels in `WireParam`'s `string s = 3` (`plan_wire_codec.mojo:2487`, `:2524`). A proto3 `string`
  must be valid UTF-8, which other languages' protobuf runtimes enforce on parse *(inferred from the proto3
  specification; not tried per runtime)*, so a Python or TypeScript client cannot round-trip a bytes param.
- §6.2's `ScanPin { binding_key, data_fingerprint }` is opaque, so the host cannot check it against the storage
  stack's read rule, and its "neither re-optimizes nor reads newer data" contradicts the LIVE policy of both kinds.

### 15.1.1 Principles

1. **A source stays a scan kind,** registered outside core with no core edit (`broker_scan_binding.mojo:9-26`).
   Search over a table is an **access path** over the table, as the search kind describes itself
   (`search_scan_kind.mojo:6-10`).
2. **Params say what to read; the pin says which version.** Both are in the digest; only the pin is checked against
   storage.
3. **Every choice that changes rows is a node field** (§5.1): access path, generation, consistency, `k`, metric,
   filter placement, approximate-search parameters, hops, path mode. A host never re-chooses any of them.
4. **An index may lag, but it cannot lie** (storage stack, "The read rule"): every row an index returns is checked
   against the scan's pin (§15.5.4).
5. **The same pinned data gives the same result** (§9.1): every new operator fixes its order or its ties, and every
   floating-point reduction its order.

## 15.2 Wire summary

Field and tag numbers are the next free numbers after `optimized_plan.md` §5.2 and `optimized_plan_udfs.md` §10.4,
which take `WirePlan` fields 20-22, engine plan tags 18-20 and `WireExpr` field 27. None of these numbers was ever
released. If they ship before the first release of `OptimizedPlan`, they are part of `format_version` 1; otherwise
each is added under a new `format_version` (§9.2).

| Message | Change | Context |
|---|---|---|
| `ScanPin` | typed arms 3-9 in `oneof resolved`; `repeated IndexPin indexes = 10`; `has_pin_group = 11`, `pin_group = 12` | OPTIMIZED |
| `OptimizedPlanBody` | `repeated PinGroup pin_groups = 4` | OPTIMIZED |
| `OptimizedSegment` | `repeated PinGroup pin_groups = 12` (the parent's list, unchanged) | segment |
| `DeclaredNeeds` | `repeated DataScope scopes = 10`; added to the `DigestTrailer` (§7.1) | header |
| `PlanAdvice` | `repeated IndexCoverage index_coverage = 4` | header, advisory |
| `WireScanNode` | `WireAccessPath access_path = 14` | required in OPTIMIZED; admitted in RAW |
| `WirePlan` | arm `WireIndexLookupNode index_lookup = 23`: engine tag `PLAN_INDEX_LOOKUP = 21`, `PlanTag` 22 | both |
| `WirePlan` | arm `WireExpandNode expand = 24`: engine tag `PLAN_EXPAND = 22`, `PlanTag` 23; `PLAN_TAG_COUNT` becomes 23 | both |
| `WireExpr` | arm `WireVectorDistance vector_distance = 28`: engine tag `EXPR_VECTOR_DISTANCE = 28`, `ExprTag` 29; `EXPR_TAG_COUNT` becomes 29 | both |
| `WireScalar` | `WireVector vector_val = 21`; `ScalarKind` `SCALAR_KIND_VECTOR = 12` (11 stays reserved) | both |
| `WireParam` | `bytes b = 6`; `PARAM_BYTES` moves to it; `s` carrying bytes is refused in OPTIMIZED | both |

Arms admitted in both contexts follow §5.2's rule for UDF arms: a stored bound plan holds them too. The two new
`WirePlan` arms are arms 20 and 21 if the §5.2 and §10.4 arms land first (field number is not arm ordinal,
`plan.proto:1569-1570`); the enum-number tests and the census (`src/komira_plan_proto/tests/`) change in the same
stage. New enums go in `plan_vocabulary.proto` with `*_WIRE_UNSPECIFIED = 0`, refused wherever a value is required.

## 15.3 Typed snapshot pins

### 15.3.1 Messages

```proto
message ScanPin {
  string binding_key      = 1;   // unchanged
  bytes  data_fingerprint = 2;   // unchanged; now ONLY the file-listing form (sha256 over sorted path, size, etag)
  oneof resolved {               // at most one; the arms a kind accepts are in its descriptor (§15.4.6)
    IcebergPin          iceberg    = 3;
    TopicPin            topic      = 4;
    RowStorePin         row_store  = 5;
    DeltaPin            delta      = 6;
    StreamPin           stream     = 7;  // UNBOUNDED scans
    SearchGenerationPin search     = 8;  // komira.search.index: an index that is its own source of truth
    TablePlusTailPin    table_tail = 9;  // komira.iceberg.table with a tail
  }
  repeated IndexPin indexes       = 10;  // generations this scan's access path reads (§15.5)
  bool              has_pin_group = 11;
  uint32            pin_group     = 12;  // index into OptimizedPlanBody.pin_groups (§15.3.4)
}

message IcebergTableRef {
  string          catalog   = 1;  // a catalog NAME the deployment maps to an endpoint and credentials; never either
  repeated string namespace = 2;  // one entry per level
  string          name      = 3;
}

message IcebergPin {
  IcebergTableRef table             = 1;
  bytes           table_uuid        = 2;  // 16 bytes; a dropped and recreated table has a new uuid
  int64           snapshot_id       = 3;  // the snapshot S every read of this scan is consistent with
  int64           sequence_number   = 4;  // S's sequence number; a cross-check
  string          metadata_location = 5;  // the immutable metadata file the producer loaded; lists S
  int32           schema_id         = 6;  // the schema the plan was bound against
  uint32          table_format      = 7;  // 1, 2 or 3; selects the delete rules the host applies
}

message PartitionSpan { uint32 partition = 1; int64 start_offset = 2; int64 end_offset = 3; }  // [start, end)

message TopicPin {
  string                 topic        = 1;
  string                 tail_lineage = 2;  // the topic's L1 lineage
  repeated PartitionSpan spans        = 3;  // sorted by partition; end = the offset resolved at optimize time
  bool                   has_table    = 4;
  IcebergPin             table        = 5;  // the rolled body, when the read includes it (§15.4.3)
}

message TablePlusTailPin { IcebergPin table = 1; string tail_lineage = 2; repeated PartitionSpan spans = 3; }
message RowStorePin { IcebergPin table = 1; string log_lineage = 2; uint64 log_seq = 3; }  // pinned log first
message DeltaPin { string table_id = 1; int64 version = 2; }        // table_id: Delta metaData.id
message StreamPin { string identity = 1; bytes schema_digest = 2; }  // §6.2: the stream, not its contents
message SearchGenerationPin { string index = 1; uint64 generation = 2; bytes analyzer_fp = 3; }
```

### 15.3.2 What a pin means, per arm

The host resolves every pin before lowering (§7.2 step 9). Each arm has one check that can fail:

| Arm | The host checks | Refusal |
|---|---|---|
| `iceberg` | the catalog's load of `table` returns `table_uuid`; `metadata_location` is readable and lists `snapshot_id` with `sequence_number` | `OPTIMIZED_PIN_TABLE_UUID_CHANGED`, `OPTIMIZED_PIN_SNAPSHOT_EXPIRED` |
| `table_tail`, `topic` with a table | the `iceberg` checks; then the gap rule of §15.4.3 | `OPTIMIZED_PIN_TAIL_GAP` |
| `topic` without a table | every span's `start_offset` is still at or above the partition's log start | `OPTIMIZED_PIN_OFFSETS_RETIRED` |
| `row_store` | the log lineage retains `log_seq`; the base pin passes the `iceberg` checks | `OPTIMIZED_PIN_SNAPSHOT_EXPIRED` |
| `delta` | the log at the table's location has `version`, and its `metaData.id` is `table_id` | `OPTIMIZED_PIN_TABLE_UUID_CHANGED`, `OPTIMIZED_PIN_SNAPSHOT_EXPIRED` |
| `stream` | identity and schema digest unchanged (§6.2) | `OPTIMIZED_PLAN_SNAPSHOT_STALE` |
| `search` | the index's catalog still has `generation`, with `analyzer_fp` | `OPTIMIZED_PIN_SNAPSHOT_EXPIRED`, `OPTIMIZED_INDEX_BUILDER_MISMATCH` |
| `data_fingerprint` (listing) | sha256 over the listed (path, size, etag) equals the pin; every read carries the etag as a precondition | `OPTIMIZED_PLAN_SNAPSHOT_STALE` |

**Why `metadata_location` is binding.** An Iceberg metadata file is never rewritten. Table properties, including
the tail watermarks of §15.4.3, live in it and not in the snapshot, so the file the producer loaded is the only place
a host can read "the watermarks as of S" without trusting a producer number. If metadata cleanup deleted it, the pin
is expired. The catalog is still called, for authorization, credentials and the uuid check. The refusals are split
because their remedies differ (re-plan; re-bind; re-plan with a table; re-plan later), and a scheduler acts on names.

### 15.3.3 `SNAPSHOT_LIVE` in an `OptimizedPlan`

- **The producer resolves every LIVE binding into its pin at optimize time.** The binding keeps `SNAPSHOT_LIVE` and
  token 0, and the `ScanPin` carries the resolution; a LIVE binding whose pin has neither a `resolved` arm nor a
  `data_fingerprint` is refused (`OPTIMIZED_SCAN_LIVE_UNRESOLVED`). A PINNED binding must agree with its pin: the
  Iceberg `snapshot_token` equals `snapshot_id`, the search `generation` param equals `search.generation`
  (`OPTIMIZED_PIN_TOKEN_DISAGREES`).
- **A source that should keep moving is `UNBOUNDED`, not LIVE.** It pins a `stream`; its position is run state.
- **A bounded topic scan reads to the offsets resolved at optimize time,** not at execution start: §6.2's rule
  applied to a moving source. RAW keeps today's LIVE meaning, and `index_pinned.txtpb` and `topic_live.txtpb` stay
  valid.
- **Recurring work re-optimizes:** a `komira/server` producer optimizes the stored bound plan each run (§2). A stored
  `OptimizedPlan` reads the same data forever, or is refused by name once that data is gone. Erasure is the one
  exception (§15.3.5).

### 15.3.4 Pin groups: one consistent set across tables

```proto
message PinGroup {
  string          group      = 1;  // e.g. the graph's name
  string          lineage    = 2;  // the komira lineage that records multi-table commits
  uint64          commit_seq = 3;  // the recorded commit whose snapshot set this group reads
  repeated uint32 members    = 4;  // indexes into scan_pins, ascending; each an iceberg or table_tail pin
}
```

The storage stack forbids designing on multi-table atomicity; "komira's reader pins a recorded set of snapshot ids".
A pin group is that set. The host reads record `commit_seq` from `lineage` and requires each member's
`(table_uuid, snapshot_id)` to equal it (`OPTIMIZED_PIN_GROUP_INCONSISTENT`); a member must name its group and appear
once (`OPTIMIZED_PIN_GROUP_MALFORMED`). Any multi-table write that records its snapshot set can be read this way.

**The members' tails are cut at one position.** The graph's three tables share one delta tail: one lineage, where a
write is one delta holding its rows for every table, and the record at `commit_seq` names the tail position the roll
covered as well as the snapshot set (graph storage, "The write path"). A pin group therefore holds the tails
consistent the same way it holds the snapshots: in a group whose lineage carries a tail, every member is a
`table_tail` pin whose `tail_lineage` equals the group's `lineage`, and every member's `spans` is the same single
span, from the record's covered position plus one to the tail end the producer pinned. Because a delta is
all-or-nothing across the tables, cutting every member at the same delta gives each table the same writes: no edge
is read without its endpoints' delta, and no supersession in one table is read without its counterpart in another. A
member whose lineage or span differs, or whose span does not start right after the record's covered position, is
`OPTIMIZED_PIN_GROUP_INCONSISTENT`. The producer resolves in graph storage's order: it pins the tail first (the
latest record and the deltas above it), then loads each table at the snapshot the record names. The roll-after-pin
rule of §15.4.3 applies to the group as a whole: a newer record may serve reaped deltas only if every member
qualifies under it, and otherwise the run is refused (`OPTIMIZED_PIN_TAIL_GAP`). A roll that carries a supersession
or a tombstone is an upsert, which writes position deletes, so in practice only a roll of added rows alone qualifies
*(inferred from graph storage's roll)*.

### 15.3.5 Erasure and pins

Erasure is the one change a pin does not hold off: the storage stack erases a subject from tables, tails and
indexes within a deadline, and a pinned plan never returns an erased subject.

- **Tables.** Erasure expires every snapshot that still holds the subject, so a pin to one of them is refused
  (`OPTIMIZED_PIN_SNAPSHOT_EXPIRED`) and the producer plans again.
- **Tails** (topic segments, graph delta objects, and the row store's log above its base watermark). Erasure rewrites
  each affected object without the subject, or drops it when nothing else remains, before the roll or at it. The
  host reads a pinned span through the tail lineage's current record of its objects, never through object keys
  remembered from the pin, so it reads the rewritten objects. The run then returns the pinned data less the erased
  subject. A dropped graph delta or row-store chunk reads as empty, and offsets erased from a topic segment read as
  the gaps key compaction leaves; neither is `OPTIMIZED_PIN_OFFSETS_RETIRED` or `OPTIMIZED_PIN_TAIL_GAP`, which
  stay for spans the roll reaped. A graph delta is rewritten as one object, so the members of a pin group lose the
  subject together.
- **Indexes.** Every generation that covered a rewritten or deleted file is rebuilt and the old one reaped, so a pin
  to it is refused once it is gone (`OPTIMIZED_INDEX_GENERATION_MISSING`, §15.8.1).

So a replay of a pinned plan after an erasure is either refused by name (an expired snapshot or a reaped generation)
or returns the original result less the erased subject (a rewritten tail); it never returns the subject.

## 15.4 Source kinds

### 15.4.1 `komira.iceberg.table`

| Param | Tag | Meaning |
|---|---|---|
| `catalog` | STR | the catalog name (`IcebergTableRef.catalog`) |
| `namespace` | STR | levels joined by the unit separator `0x1F`, as the Iceberg REST protocol encodes a multi-level namespace |
| `name` | STR | the table name |
| `as_of_snapshot` | I64 | optional; time travel by snapshot id |
| `as_of_timestamp_ms` | I64 | optional; time travel by timestamp; the producer resolves it to a snapshot id |
| `tail` | STR | optional; the komira tail lineage that rolls into this table |
| `tail_merge` | STR | `append` or `upsert`; required with `tail` |

- **Pin:** `iceberg`, or `table_tail` with `tail`.
- **Delete handling is not an option.** The host applies every delete that applies at S: v2 position deletes,
  equality deletes under the data-sequence-number rule, and v3 deletion vectors (storage stack, "What komira reads").
  A plan cannot ask to skip deletes, because that is a different relation. A host whose build lacks a reader for a
  delete form or file format present at S refuses by name (`OPTIMIZED_SOURCE_FEATURE_UNSUPPORTED`, naming the
  feature) before any data is read; it never returns rows with the deletes unapplied.
- **Metadata columns.** The scan may project Iceberg's `_file` (STRING) and `_pos` (INT64), and `_row_id` (INT64)
  on a v3 table with row lineage. Tail rows report `_file` as the tail object key and `_pos` as the offset or log seq.
  These are the row identity of §15.5.4 and the join key for rank fusion when the table has no key.
- **Statistics** from manifests go to `advice.stats_basis` (§6.3), never into the scan node.

### 15.4.2 `komira.delta.table` and Hive-style Parquet

- **`komira.delta.table`**, params `location` (STR) or `catalog`, `namespace`, `name`; optional `as_of_version`
  (I64). Pin: `delta`. The host reads the log at `version` through the Delta kernel module the storage stack
  recommends; a reader feature the host does not implement is refused by name, as the Delta protocol requires
  (`OPTIMIZED_SOURCE_FEATURE_UNSUPPORTED`).
- **Hive-style Parquet** is the existing `parquet` arm (`plan.proto:429-443`) with `hive_dir_scan`, pinned by
  `data_fingerprint` over the listing (a manifest object when large, §6.2). The source has no snapshot isolation; the
  pin gives the plan some: files added after the pin are not read, and a changed or deleted file fails its etag
  precondition and the run.

### 15.4.3 Topics: the tail and the rolled table as one scan

`komira.broker.topic` keeps its params (`topic`, `partitions`, `start_offset`, `start_offsets`, `isolation`;
`broker_scan_binding.mojo:82-103`) and gains three optional ones: `table_catalog`, `table_namespace`, `table_name`.
With them, the scan reads the topic's Iceberg table (written with `mode="append"`) and its tail as **one relation**,
ordered and de-duplicated by offset. It is one scan, never a union of two: a union lets the optimizer reorder or
prune the two inputs independently, and the read order (tail first, then table) is what makes the gap check sound.

**Resolution, in the storage stack's order.** The producer pins the tail (each partition's end offset), then loads
the table (`IcebergPin`, with `metadata_location`), then reads each partition's watermark `wm(p)` from that metadata.
If `wm(p) + 1 < log_start(p)` after one reload, it refuses to plan (`TOPIC_TAIL_GAP`). The host reads offsets
`≤ wm(p)` from the table at S, filtered on the offset column, and offsets above `wm(p)` from the tail.

A roll between optimize and execution may reap tail chunks above `wm(p)`. The host may then read those offsets from
a newer snapshot S′ of the same table **only if** every snapshot between S and S′ is an `append` or a `replace`
(storage stack, "Detecting new snapshots"): neither changes which records exist, so the span's rows are the same. If
any is a `delete` or `overwrite`, or S′ does not descend from S, the run is refused before it reads
(`OPTIMIZED_PIN_TAIL_GAP`) and the producer plans again. This is a named host-local rule (§15.8.3), and the S′ it
used is recorded in the run record.

A `mode="upsert"` topic table is a keyed table, not a log. It is read as `komira.iceberg.table` with
`tail_merge = upsert`: the table at S, then the tail above each watermark, last write per key wins, tombstones
remove. The row store is the same shape with its own pin (§15.4.4).

**Unbounded topics.** `boundedness = UNBOUNDED` on a topic scan makes the plan a streaming plan (§5.2). It pins a
`stream`. With the table params, the first run reads the table, then the tail, then follows the tail; the position
is checkpointed run state. A bounded scan of the same topic in the same plan pins its own spans.

### 15.4.4 `komira.rowstore.table`

Params `store` and `table`; pin `row_store`, resolved log first. The host reads the base at S, then replays the log
from the base's watermark to `log_seq` under MVCC visibility at `log_seq` (storage stack, "The row store"). The scan
is `BOUNDED`; a change feed is a separate `UNBOUNDED` kind, not specified here.

### 15.4.5 `komira.search.index` in OPTIMIZED

This kind stays for an index that is its own source of truth (log search, storage stack "L4"). In OPTIMIZED its pin
is `search`; its `query` param must be empty, the "every live document" relation it already supports
(`search_scan_kind.mojo:53-58`), and the query moves to a `TEXT` access path, so table and log search carry a query in
one place (`OPTIMIZED_ACCESS_QUERY_IN_PARAMS`). Its row identity is (`_split`, `_id`), since `_id` is split-local;
`_split` is a new STRING column, emitted when projected.

### 15.4.6 Kind descriptors are published data

Kind names and param keys are strings, so a generated Python or TypeScript builder can drift from the Mojo kind
unnoticed. Each kind commits its descriptor as data beside the kind: `ScanKindSpec { kind_name; params (key,
ParamTag, required, in_identity, allowed values); added output columns; accepted ScanPin.resolved arms; boundedness;
access kinds (§15.5) }`. Every SDK generates its builders from these files, and a test welded into each kind's
library compares the registry's descriptor with the committed file (mutant: add a param to the Mojo kind only).

## 15.5 Index access paths on the scan

### 15.5.1 The access path

```proto
message WireAccessPath {
  AccessKind          kind              = 1;   // FULL | TEXT | VECTOR
  bool                has_index         = 2;
  uint32              index             = 3;   // into this scan's ScanPin.indexes; absent = no index
  WireTextQuery       text              = 4;   // kind = TEXT
  WireVectorQuery     vector            = 5;   // kind = VECTOR
  Consistency         consistency       = 6;   // INDEX | EXACT; required for TEXT and VECTOR (§15.5.2)
  uint64              exact_budget_bytes = 7;  // EXACT VECTOR: uncovered embedding bytes it may compute or read
  uint32              k                 = 8;   // top-k; 0 = every match (TEXT only)
  FilterPlacement     filter_placement  = 9;   // PRE | POST; VECTOR with a pushed filter
  uint32              post_overfetch    = 10;  // POST only: candidates fetched before the filter, >= k
}

message WireTextQuery {
  string          query       = 1;  // raw text, analyzed with the index's analyzer
  repeated string fields      = 2;  // sorted; each an analyzed text column
  TextOperator    op          = 3;  // OR | AND over analyzed terms
  TextScoring     scoring     = 4;  // BM25 (k1, b given below)
  double          bm25_k1     = 5;
  double          bm25_b      = 6;
  bytes           analyzer_fp = 7;  // must equal the index generation's builder fingerprint
  WireExpr        query_expr  = 8;  // index lookup only (§15.6): a probe column, in place of `query`
}

message WireVectorQuery {
  string        column      = 1;    // a vector column (below), or a text column the index embeds
  WireExpr      query       = 2;    // a constant: a vector literal, or a probe column inside an index lookup (§15.6)
  VectorMetric  metric      = 3;    // L2 | COSINE | DOT
  bytes         model_fp    = 4;    // embedding model fingerprint; equals the index's when the index embeds
  AnnMode       ann         = 5;    // EXACT_ONLY | APPROXIMATE_ALLOWED
  repeated AnnParam ann_params = 6; // closed enum key + typed value (ef_search, nprobe); refused if unknown
}

message IndexPin {
  IndexKind kind               = 1;  // TEXT | VECTOR | CSR
  string    index              = 2;  // the index's name; the host maps it to its prefix
  bytes     generation         = 3;  // the generation's commit id on the index's L1 lineage
  bytes     source_table_uuid  = 4;
  int64     built_at_snapshot  = 5;
  bytes     builder_fp         = 6;  // analyzer, embedding model and field ids, as the generation records them
}
```

**Vector columns.** Iceberg has no fixed-size list type. A VECTOR access path therefore accepts an Iceberg
`list<float32>`, `list<float16>` or `list<int8>` column whose table property declares its dimension (graph storage,
komira-ai/komira#833, keeps the column as `list<float>` plus that declared dimension). The dimension is validated on
read: a row whose list length differs from it fails the scan rather than being skipped. The scan
presents the column as an Arrow `FIXED_SIZE_LIST<element, dim>`, so the query vector's `dim`, the distance kernels
and the result schema all see a fixed size. A column with no declared dimension cannot be a VECTOR access path's
`column`.

**Meaning.** A scan with `kind = FULL` is today's scan. A scan with `TEXT` or `VECTOR` is the same relation (the
table at its pin, with the pushed `filter`), restricted to its top `k` matches and extended with one column:
`_score FLOAT64` (TEXT, higher is better) or `_distance FLOAT64` (VECTOR, lower is better; for DOT the negated
product). Rows come out ordered by that column, ties broken by row identity (§15.5.4) ascending, so the order is
part of the result and a `TopN` above the scan is redundant; the producer removes it.

### 15.5.2 The consistency mode and the read rule

These restate the storage stack's read rule as admission and lowering rules. Let S be the scan's snapshot and G the
generation `indexes[index]`.

1. **G is S or an ancestor of S.** The host walks parent ids in the pinned metadata. If the chain from S cannot reach
   `built_at_snapshot` (the snapshots between were expired), ancestry is unproven and the plan is refused
   (`OPTIMIZED_INDEX_NOT_ANCESTOR`): an index built after S may lack rows that were live at S.
2. **G indexes this table:** `source_table_uuid` equals the pin's `table_uuid` (`OPTIMIZED_INDEX_SOURCE_MISMATCH`),
   and `builder_fp` matches `analyzer_fp` or `model_fp` (`OPTIMIZED_INDEX_BUILDER_MISMATCH`).
3. **`consistency = INDEX`:** the result is computed over the rows of files that G covers and that are live at S.
   Rows in uncovered files, and tail rows, are omitted. Because the plan names G, the omission is the same on every
   replay; that meets §9.1's "same pinned data, same result".
4. **`consistency = EXACT`:** the result is computed over every live row at S, tail included. Uncovered rows are
   scanned; for VECTOR their embeddings come from the content cache or are computed under `exact_budget_bytes`, and
   past the budget the run fails (`INDEX_EXACT_BUDGET_EXCEEDED`), never answering partially. For TEXT, BM25 term
   statistics are merged over the index and the scanned rows, so scores are comparable (storage stack, "The read
   rule"; *inferred cost*). EXACT governs **coverage**, not recall: with `ann = APPROXIMATE_ALLOWED` the covered part
   is still an approximate search. A true k-nearest result is `EXACT` plus `EXACT_ONLY`.
5. **No index at all** (`has_index = false`) is legal for both kinds: TEXT scores every live row; VECTOR computes
   every distance. That is the EXACT result by definition, so `consistency` must be `EXACT`. A bound (RAW) access
   path carries the user's requested mode; the producer rewrites `INDEX` to `EXACT` when it finds no generation.

**Results the SDK reports.** `hits.snapshot_id` is the pin's `snapshot_id`, known before the run. `hits.lag` (rows
and files live at S that G does not cover) follows from G and S: the producer records it in `advice.index_coverage`
(`{pin_index, index, uncovered_files, uncovered_rows}`) and the host reports it in its run record. No column, no
result envelope.

### 15.5.3 Vectors in expressions

```proto
message WireVector { ArrowType element_type = 1; uint32 dim = 2; bytes values_le = 3; }  // FLOAT32|FLOAT16|INT8
message WireVectorDistance { WireExpr left = 1; WireExpr right = 2; VectorMetric metric = 3; }  // WireExpr arm 28
```

- A vector literal is a `WireScalar` with `kind = SCALAR_KIND_VECTOR` and `vector_val` set. Its byte length must be
  `dim` times the element width, and a NaN element is refused (`OPTIMIZED_VECTOR_LITERAL_MALFORMED`); its `dim` must
  equal the column's declared dimension (`OPTIMIZED_VECTOR_DIM_MISMATCH`).
- `vector_distance` is an ordinary expression returning FLOAT64. It makes the exact, index-free form of a k-nearest
  query plain relational algebra: `TopN(k, by distance(col, q))` over a scan, or `PartitionTopN` per probe row over
  a cross join. That form is the definition the VECTOR access path must agree with when `ann = EXACT_ONLY`.
- Summation order is fixed: element order, in FLOAT64, one accumulator *(a SIMD kernel must reproduce that order or
  use a reduction tree fixed by `dim`, documented in the kernel; graph storage asks for "a fixed reduction order")*.

**The query vector is computed at optimize time.** `km.embed("refund not received", model=...)` with a literal
argument is evaluated by the producer, and the plan carries the vector literal and `model_fp`. A replay then uses
the same vector, whatever the model service returns later. An embedding computed per row at run time is a UDF
(§10) feeding an index lookup (§15.6).

### 15.5.4 Every hit is checked against the pin

Before a row leaves a scan with a TEXT or VECTOR access path, the host checks it against the scan's pin:

1. its data file is live at S;
2. its position is not deleted at S (position delete or deletion vector), and no equality delete that applies to it
   (by data sequence number) matches its row;
3. for a pin with a tail, no tail write in the pinned spans supersedes it (`tail_merge = upsert`, row store);
4. it passes the scan's pushed `filter`, evaluated on the row whatever the filter placement (the graph's `as_of` is
   such a filter, §15.7.3).

Row identity is `(_file, _pos)` on v2, `_row_id` on v3 with row lineage (storage stack: "A hit is stored as (data
file, position) on v2, and as `_row_id` on v3"), and `(_split, _id)` for `komira.search.index`. The check is part of
the lowering, not a rule a host may skip; the §7.3 post-condition requires it (§15.8.3).

### 15.5.5 Filters: pre or post

A pushed `filter` with a VECTOR access path has one meaning, the `k` nearest rows **that pass the filter**, under
`PRE`. `POST` is an approximation the plan must state: the index returns `post_overfetch` candidates, the filter and
the hit check run, and the first `k` survivors are returned, possibly fewer than `k`. `POST` with
`post_overfetch < k` is refused (`OPTIMIZED_ACCESS_POST_OVERFETCH_INVALID`). A TEXT access path always applies its
filter before ranking. A UDF in a pushed filter is already refused (`OPTIMIZED_UDF_IN_SCAN_FILTER`, §7.2); a UDF in
an access path's query is refused likewise (`OPTIMIZED_UDF_IN_ACCESS_PATH`).

## 15.6 `WireIndexLookupNode`: a query per input row

A scan's query is a constant. Many plans take their query from rows: one search per question, the nearest tickets
to each new ticket, the entities nearest to each extracted mention. That is a lateral join whose inner side is an
index scan.

```proto
// WirePlan arm 23. Engine tag PLAN_INDEX_LOOKUP = 21; PlanTag 22.
message WireIndexLookupNode {
  WirePlan       probe     = 1;   // any plan; bounded or unbounded
  WirePlan       target    = 2;   // exactly a WireScanNode with a TEXT or VECTOR access path
  LookupJoinType join_type = 3;   // INNER | LEFT (a probe row with no hit is kept, target columns null)
}
```

- The target's query refers to probe columns: `WireTextQuery.query_expr` (with `query` empty) or
  `WireVectorQuery.query` is a `WireColRef` naming a probe column. A reference that resolves anywhere else, or a
  `query_expr` outside an index lookup, is refused (`OPTIMIZED_LOOKUP_TARGET_INVALID`).
- **Output:** probe columns, then the target's projected columns and `_score` or `_distance`, hits in the target's
  order within each probe row, probe order kept.
- **Exact form:** `INNER` with no index equals `PartitionTopN(k, partition by probe row id, order by distance)` over
  `probe CROSS JOIN target`. A test compares the two on corpus data (§15.10.3).
- **Streaming:** an unbounded probe is admitted (each row looks up the pinned generation); an unbounded target is
  refused (`OPTIMIZED_UNBOUNDED_INPUT_UNSUPPORTED`).

## 15.7 Graph operators

### 15.7.1 The graph is tables

The graph's facts are the tables `episodes`, `entities` and `edges` (later `communities`): graph storage chose tables
as the source of truth, and the storage stack makes them Iceberg tables at L3 with a graph delta tail. The graph
itself is a layer above L4, not an index and not a store of its own (storage stack, "The stack, revised"): it
consumes the text, vector and adjacency indexes built over those tables. A graph read is three
`komira.iceberg.table` scans (with `tail`) in one **pin group** (§15.3.4): one recorded snapshot set, with every
tail cut at one position. Text search over entities and episodes, and similarity over their embeddings, are §15.5
access paths on those scans. The CSR adjacency is an index over `edges` (`IndexPin.kind = CSR`), and the read rule
applies to it unchanged.

### 15.7.2 `WireExpandNode`

```proto
// WirePlan arm 24. Engine tag PLAN_EXPAND = 22; PlanTag 23.
message WireExpandNode {
  WirePlan        seeds        = 1;   // rows holding start node ids
  WirePlan        edges        = 2;   // a scan of the edge relation; its pushed filter and projection apply per edge
  string          seed_column  = 3;
  string          src_column   = 4;
  string          dst_column   = 5;
  ExpandDirection direction    = 6;   // OUT | IN | BOTH
  uint32          min_hops     = 7;   // 0 includes the seed itself
  uint32          max_hops     = 8;   // >= min_hops, <= 16
  ExpandMode      mode         = 9;   // NEIGHBORS | EDGES | PATHS | SHORTEST_PATHS
  PathMode        path_mode    = 10;  // WALK | TRAIL | ACYCLIC | SIMPLE (SQL/PGQ names); PATHS and SHORTEST_PATHS
  bool            has_hop_filter = 11;
  WireExpr        hop_filter   = 12;  // over the edge's columns and the seed row's columns
  WirePlan        targets      = 13;  // SHORTEST_PATHS only: target node ids
  string          target_column = 14;
  uint64          max_rows     = 15;  // the run fails (EXPAND_ROW_LIMIT_EXCEEDED) past it; never truncates
  ExpandAccess    access       = 16;  // CSR | HASH
  uint32          csr_index    = 17;  // CSR: into the edges scan's ScanPin.indexes
  Consistency     consistency  = 18;  // CSR: INDEX | EXACT, as in §15.5.2
}
```

**Output per mode** (every mode keeps the seed row's columns):

| Mode | Adds | One row per |
|---|---|---|
| `NEIGHBORS` | `_node`, `_hops` (the least hop count) | (seed, reached node) |
| `EDGES` | the edge scan's projected columns, `_hops` | (seed, edge traversed within `max_hops`): the neighbourhood subgraph |
| `PATHS` | `_path LIST<node id>`, `_edge_path LIST<row identity>`, `_hops` | (seed, path) under `path_mode` |
| `SHORTEST_PATHS` | as `PATHS`, plus the target's columns | (seed, target): one shortest path; ties broken by the lexicographically least `_path` |

**Semantics are those of iterated joins.** `NEIGHBORS` with `max_hops = k` equals `k` rounds of an inner join of the
frontier with `edges`, a union, and a `MIN(_hops)` group by `(seed, node)`. That is the earlier implementation's
"one-hop inner join … iterated breadth-first" (graph storage), and the corpus checks the node against it. A node
rather than a join chain because the bound is a decision (`min_hops`, `max_hops`), `ACYCLIC` and shortest paths
cannot be written as a fixed join chain, and the access choice (below) needs one place to live.

**Access.** `CSR` reads generation `csr_index` of the edges scan's pin under the node's `consistency`: `INDEX`
traverses the edges G covers; `EXACT` also overlays edges from uncovered files and the tail. Each
traversed edge is checked against the pin as in §15.5.4, and the edges scan's pushed filter applies to it. `HASH`
builds adjacency from the edges child at run time. The producer chooses; the host obeys
(`OPTIMIZED_EXPAND_ACCESS_INVALID`: `CSR` naming no CSR pin of the edges scan, or `HASH` with either field set).

### 15.7.3 Time slices and fusion

- **`as_of`** is a filter on each graph scan over the four bi-temporal bounds (graph storage), built by the SDK:
  `valid_from <= t AND (valid_to IS NULL OR valid_to > t)` for event time and the same over system time. As a pushed
  filter it is in the digest, and §15.5.4 applies it to every hit and every traversed edge.
- **Rank fusion needs no node:** `km.rrf` builds a row-number window per input, a full join on row identity or key
  columns, and `sum(1 / (c + rank))` with `c` a literal.

### 15.7.4 A knowledge-graph query, as one plan

"Entities matching 'Acme', their 2-hop neighbourhood as of a time, ranked by text and by similarity to a question":

```
Project
└─ Join(entity_id)                                       # fuse text and vector ranks (km.rrf)
   ├─ Window(rank by _score)
   │  └─ Scan entities  access=TEXT(index=G1, k=20, INDEX)   pin_group=kg
   └─ Window(rank by _distance)
      └─ Expand NEIGHBORS hops 1..2 access=CSR(G3, EXACT)
         ├─ Scan entities access=VECTOR(index=G2, k=5, EXACT, budget=64 MiB)  pin_group=kg
         └─ Scan edges    access=FULL filter=as_of(t)  indexes=[CSR G3]        pin_group=kg
```
Three pins in one group, three generations, one digest; a UDF reranker would be a `WireMapBatchesNode` on top.

## 15.8 How the optimizer chooses, and how it composes

### 15.8.1 Index or scan

The SDK and the SQL binder produce one canonical **bound** form for each query shape, with no index named:

| Query | Bound form |
|---|---|
| `search` | `Scan(table, access=TEXT(query, fields, k, consistency), has_index=false)` |
| `knn` | `Scan(table, filter, access=VECTOR(column, q, k, metric, consistency, ann), has_index=false)` |
| `search_lookup`, `knn_lookup` | `IndexLookup(probe, Scan(access=TEXT or VECTOR, query from a probe column))` |
| SQL `ORDER BY vector_distance(col, q) LIMIT k` | `TopN(k) ← Scan(table, filter)`: exact by definition |
| SQL lateral `… ORDER BY vector_distance … LIMIT k` | `PartitionTopN(k) ← CrossJoin(probe, Scan(table))` |
| traversal | `Expand(..., access unset)` |

The producer then:

1. lists index generations bound to the pinned `table_uuid` (from each index's lineage under its prefix), keeps those
   that pass §15.5.2 rules 1-2 for S, and picks the newest;
2. for `consistency = INDEX` (the SDK default), uses that generation when one exists; with none, it records
   `has_index = false` and `consistency = EXACT`, which is the result the user would get from a fully covered index;
3. for `consistency = EXACT` (text) or `ann = EXACT_ONLY` (vector), compares index-plus-uncovered against a full
   scan and records the cheaper; both give the same rows;
4. rewrites the SQL forms (`TopN ← distance`, `PartitionTopN ← CrossJoin`) into a VECTOR access path or an index
   lookup only with `EXACT` and `EXACT_ONLY`, so the rows do not change: SQL means the true nearest rows, and only an
   SDK `knn` consents to an approximate search;
5. sets `Expand.access = CSR` when a CSR generation passes the read rule, else `HASH`.

Every outcome is a node field or an `IndexPin`, inside the digest. A host never re-derives it, and a host with a newer
generation available uses the pinned one. If the pinned generation has been reaped, the run is refused
(`OPTIMIZED_INDEX_GENERATION_MISSING`) and the producer plans again; the host does not fall back to a scan, because in
`INDEX` mode that changes the rows.

### 15.8.2 Composition

| With | Rule |
|---|---|
| filters | A filter over an access-path scan's table columns is pushed into the scan (`filter`) and obeys §15.5.5. A filter on `_score` or `_distance` stays above the scan. |
| projections | Pushed as usual; `_score`, `_distance`, `_file`, `_pos`, `_row_id` are projected only when used. |
| joins | Hits join tables on key columns, or on row identity when both sides read the same pinned table. The join's build side and algorithm are recorded as §5.2 requires. |
| UDFs | A `SCALAR` UDF may compute a probe column (a per-row embedding) feeding an index lookup; a `MAP_BATCHES` UDF may rerank hits. A UDF never appears in a scan's filter or access-path query. |
| aggregates, windows | Ordinary operators above hits; fusion uses windows. |
| exchanges, segments | An access-path scan with `k > 0` runs in one segment; within a host, `k` per split and a merge is the host-local rule `ACCESS_PER_SPLIT_TOPK`, with the same rows because ties break by row identity. Spreading one top-k scan across hosts needs a partial and final top-k pair, as aggregates have; a later addition. |
| streaming | An `UNBOUNDED` topic scan makes the plan streaming (§5.2). An index lookup or an expand with an unbounded probe or seed side is streaming-compatible; their indexed side is bounded and pinned. An access path on an unbounded scan is refused (`OPTIMIZED_ACCESS_ON_UNBOUNDED`): a standing query over new documents is a different operator, not specified here. |

**Bounded sides of a streaming plan stay pinned for the plan's life;** a long-running enrichment reads its pinned
table until the plan is re-optimized and restarted from its checkpoint (§15.12, decision 4).

### 15.8.3 Host-local rules added

The list in §5.3 gains three entries, each a named difference in the §7.3 rewrite set:

10. `TAIL_GAP_FROM_DESCENDANT`: read a reaped topic span from an append-or-replace descendant (§15.4.3);
11. `ACCESS_PER_SPLIT_TOPK`: evaluate an access path's `k` per split and merge (§15.8.2);
12. `INDEX_EXACT_OVERLAY`: the scan of uncovered files and tail rows in `EXACT` mode, and the CSR overlay.

The hit check (§15.5.4) is not optional: the post-condition requires it on every access-path scan, index lookup
and `CSR` expand.

## 15.9 The SDK surface

Verb names are the same words in every language; TypeScript writes multi-word names in camelCase and options as an
object. Each verb emits one bound form (§15.8.1), so one program yields one canonical bound plan in every SDK.

| Verb | Emits |
|---|---|
| `read_table(catalog, name, as_of=, include_tail=)`, `read_delta(location, version=)`, `read_parquet(prefix, hive_partitioning=)`, `read_rowstore(store, table)` | the §15.4 kinds |
| `topic(name).read(include_table=)`, `topic(name).stream(include_table=)` | `komira.broker.topic`, bounded or unbounded |
| `frame.search(query, fields=, k=, consistency=)` | TEXT access path |
| `frame.knn(column, query, k=, metric=, where=, filter_mode=, consistency=, approximate=)` | VECTOR access path |
| `probe.search_lookup(frame, query=, k=)`, `probe.knn_lookup(frame, column, query=, k=)` | index lookup |
| `graph(catalog, name)` with `.entities`, `.edges`, `.episodes` | three scans in one pin group |
| `g.neighbors(seeds, on=, hops=, direction=, where=, as_of=)`, `g.subgraph`, `g.paths`, `g.shortest_path(seeds, targets, max_hops=)` | `Expand` in each mode |
| `rrf(frames, on=, c=60)`; `embed(text, model=)` | windows and joins; a vector literal computed at optimize time |

```python
import komira as km                                   # Python
cat = km.catalog("lake")                              # a name the deployment maps to a catalog
tickets = km.read_table(cat, "support.tickets")
text = tickets.search("refund not received", fields=["subject", "body"], k=20)
near = tickets.knn("body_vec", km.embed("refund not received", model="m"), k=20, where=km.col("status") == "open")
best = km.rrf([text, near], on=["ticket_id"])
g = km.graph(cat, "kg")
hood = g.neighbors(g.entities.search("Acme", fields=["name"], k=5), on="entity_id", hops=2, as_of="2026-10-01")
```

```ts
const tickets = km.readTable(km.catalog("lake"), "support.tickets");               // TypeScript
const text = tickets.search("refund not received", { fields: ["subject", "body"], k: 20 });
const near = tickets.knn("body_vec", km.embed("refund not received", { model: "m" }),
  { k: 20, where: km.col("status").eq("open") });
```

```mojo
var tickets = km.read_table(km.catalog("lake"), "support.tickets")                 # Mojo
var text = tickets.search("refund not received", fields=["subject", "body"], k=20)
var near = tickets.knn("body_vec", km.embed("refund not received", model="m"), k=20,
                       where=km.col("status") == "open")
```

**Refused on the user's machine, by name:** `knn` with no `k` (`SDK_KNN_K_REQUIRED`); an exact vector read with no
budget and no default (`SDK_EXACT_BUDGET_REQUIRED`); a query embedded with a model other than the index's
(`SDK_INDEX_MODEL_MISMATCH`); more than 16 hops (`SDK_EXPAND_HOPS_OVER_LIMIT`).

**Cross-language test.** A conformance corpus of programs, one per verb and option, is written in each SDK; each
SDK's test emits the canonical bound plan, and the bytes must be equal across SDKs. Mutants: a TypeScript `knn` that
writes `metric` as a param string instead of the enum; a Python `search` that does not sort `fields`.

## 15.10 Admission

### 15.10.1 Refusal tokens

Step 8 (structure) of §7.2 adds `OPTIMIZED_SCAN_LIVE_UNRESOLVED`, `OPTIMIZED_PIN_TOKEN_DISAGREES`,
`OPTIMIZED_PIN_FORM_MISMATCH` (an arm the kind's descriptor does not list, or `data_fingerprint` beside a `resolved`
arm), `OPTIMIZED_PIN_GROUP_MALFORMED`, `OPTIMIZED_INDEX_PIN_UNDECLARED`, `OPTIMIZED_INDEX_PIN_UNREFERENCED`,
`OPTIMIZED_PARAM_BYTES_IN_STRING`, `OPTIMIZED_ACCESS_PATH_MISSING`, `OPTIMIZED_ACCESS_PATH_UNSUPPORTED`,
`OPTIMIZED_ACCESS_QUERY_IN_PARAMS`, `OPTIMIZED_ACCESS_K_MISSING`, `OPTIMIZED_ACCESS_POST_OVERFETCH_INVALID`,
`OPTIMIZED_ACCESS_CONSISTENCY_INVALID` (unset, or `INDEX` with no index), `OPTIMIZED_EXACT_BUDGET_MISSING`,
`OPTIMIZED_ACCESS_ON_UNBOUNDED`, `OPTIMIZED_UDF_IN_ACCESS_PATH`, `OPTIMIZED_VECTOR_LITERAL_MALFORMED`,
`OPTIMIZED_VECTOR_DIM_MISMATCH`, `OPTIMIZED_LOOKUP_TARGET_INVALID`, `OPTIMIZED_EXPAND_HOPS_INVALID`,
`OPTIMIZED_EXPAND_MODE_FIELDS` (`targets` without `SHORTEST_PATHS`, or the reverse),
`OPTIMIZED_EXPAND_ACCESS_INVALID`.

Step 9 (pins) adds `OPTIMIZED_PIN_TABLE_UUID_CHANGED`, `OPTIMIZED_PIN_SNAPSHOT_EXPIRED`, `OPTIMIZED_PIN_TAIL_GAP`,
`OPTIMIZED_PIN_OFFSETS_RETIRED`, `OPTIMIZED_PIN_GROUP_INCONSISTENT`, `OPTIMIZED_INDEX_GENERATION_MISSING`,
`OPTIMIZED_INDEX_NOT_ANCESTOR`, `OPTIMIZED_INDEX_SOURCE_MISMATCH`, `OPTIMIZED_INDEX_BUILDER_MISMATCH`,
`OPTIMIZED_SOURCE_FEATURE_UNSUPPORTED` and, for a pinned resource missing from `needs.scopes`, the existing
`OPTIMIZED_SCOPE_UNDECLARED`; all before any data is read. Run-time errors: `INDEX_EXACT_BUDGET_EXCEEDED`,
`EXPAND_ROW_LIMIT_EXCEEDED`.

### 15.10.2 What a scheduler authorizes

`DataScope { ScopeKind kind = 1 (CATALOG_TABLE | KOMIRA_TAIL | KOMIRA_INDEX | OBJECT_PREFIX | TOPIC);
string catalog = 2; repeated string namespace = 3; string name = 4; string prefix = 5 }`. `needs.scopes` lists every
resource the pins name, sorted and de-duplicated. A scheduler reads it from the header without decoding the body,
so it can authorize a catalog read and a komira-artifact read separately (a user may grant a table and not its
index). The host checks that every pinned resource is listed and every entry is used.

### 15.10.3 Corpus and mutants

The golden corpus (§9.4) adds, each with pinned fixture data and expected output: an Iceberg v2 table with a position
and an equality delete, and a v3 table with a deletion vector, each read `FULL`, `TEXT` and `VECTOR` in `INDEX` and
`EXACT` with a generation covering half the files; a topic with a rolled table and a tail, with a span across the
watermark; a row store with a base and a log; a three-table graph in one pin group with a CSR generation, read in
every `ExpandMode` and `PathMode`; an index lookup over an unbounded fixture that delivers a fixed sequence and then
reports `Closed`. The §9.4 coverage assertion covers every new enum value and every `resolved` arm.

Named mutants, each of which must turn a test red: the hit check skips position deletes; a generation built after
S is accepted; a host falls back from a reaped generation to a full scan in `INDEX` mode; the tail is pinned after the
table is loaded, with a roll in between (duplicated offsets); table and tail read as a union (a missing range);
`POST` lowered as `PRE`; a distance accumulated in FLOAT32; `NEIGHBORS` reporting the last rather than the least hop
count; a pin-group member read at the table's current snapshot instead of the recorded one; a pin-group member
whose tail span ends one delta later than the others; a host that reads a tail object erasure rewrote by the key
remembered at pin time.

## 15.11 Compatibility

- **Everything is additive:** new fields, arms, enum values and messages. `data_fingerprint` is narrowed to the
  listing form before `OptimizedPlan` is first released; after that its meaning is frozen.
- **RAW is unchanged.** LIVE, the search kind's `generation` and `query` params, and the goldens `index_pinned.txtpb`
  and `topic_live.txtpb` keep their meaning. The new arms are admitted in RAW, so a stored bound plan can hold them.
- **Kind names and param keys are permanent:** params are added only, a key is never reused with a new meaning or tag,
  a retired key stays in the descriptor marked retired, and descriptor files (§15.4.6) are append-only.
- **Pin meanings, the hit check, the read rule, the consistency modes and each `ExpandMode`** belong to
  `optimizer_contract_version` (§9.3 lists "the meaning of a snapshot pin"); changing one is a contract bump.
- **Storage evolution is not plan evolution.** A new Iceberg format version, delete form or Delta reader feature is a
  host capability; meeting a host without it gives `OPTIMIZED_SOURCE_FEATURE_UNSUPPORTED`, never a refusal for age.
- **`WireParam.b`:** encoders write bytes only there; RAW decoders accept both forms forever; OPTIMIZED refuses `s`.

## 15.12 Decisions for the maintainers (recommendation first)

1. **Traversal as a node, defined as iterated joins.** Yes. Joins with the CSR as a host rule need no arm, but cannot
   express `ACYCLIC` or shortest paths, and leave an access choice worth orders of magnitude to the host.
2. **Table text search as an access path, not a relation kind.** Yes; log search keeps its kind, its query moved.
3. **Embed literal queries at optimize time.** Yes: replay is exact and hosts need no model; the producer does.
4. **Advancing bounded pins in a streaming plan.** Not in the first version; a refresh is a re-optimization and a
   restart from the checkpoint, recorded as an adaptive change is (§8.3) if it is ever added.
5. **`metadata_location` binding.** Yes; trusting producer watermarks would make a producer number decide
   correctness, which §5.3 forbids.

## 15.13 Comparison

- **DataFusion.** A source is a `TableProvider` that negotiates filter pushdown and holds its snapshot in the provider
  instance, not the plan; custom operators are `UserDefinedLogicalNode`s, which `datafusion-proto` carries as opaque
  bytes through an extension codec every client must link *(my reading)*. Typed arms let a Python or TypeScript
  client build and check every node without engine code. Lance's ANN search on DataFusion prefilters, our `PRE`.
- **DuckDB.** `vss` rewrites `ORDER BY array_distance(...) LIMIT k` into an HNSW scan (§15.8.1 step 4), even for an
  exact query, and has no plan wire to pin the choice. DuckPGQ adds SQL/PGQ matching; `PathMode` uses its names.
- **Search engines.** Elasticsearch and OpenSearch filter kNN before or after search with a candidate count
  (§15.5.5); their results are consistent with a refresh point, not a table snapshot, and no hit is checked.
