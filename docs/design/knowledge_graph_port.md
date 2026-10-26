# The knowledge graph port: packages, seams, engine dependencies and PR order

Status: design, no code. It decides how the existing data-graph library (a property graph built from
documents and records, with a bi-temporal store and a read path) comes into komira as small, separately
tested packages. None of the packages named here is in the tree yet. The code graph
[`komira_kg_code`](../../src/komira_kg_code/) is a different thing and is untouched (see
[knowledge_graph.md](../knowledge_graph.md)).

Related, and authoritative where they overlap:
[data_graph_storage.md](data_graph_storage.md) decides how a graph over data is stored durably and that the
graph has no query API of its own; [storage_stack.md](storage_stack.md) is the layer design;
[optimized_plan_sources.md](optimized_plan_sources.md) section 15 spells the graph operators. This document
does not restate them. It ports a working implementation, says where that implementation differs from them,
and orders the work so that nothing waits on the execution engine until it must.

## What is it for, and what is out of scope?

The graph turns documents and records (mail threads, meeting transcripts, calendar events, files, CRM
rows) into entities, edges and episodes, keeps every fact with four time bounds
(event time and system time, so a later correction does not erase what was believed before), and answers
questions over them: ranked text, embedding similarity, neighbours, a time slice, and fused rankings. Its
purpose in komira is batch inference: a job reads a pinned snapshot of the graph, asks many questions,
and writes answers next to their provenance, so a result can be traced to the episodes it came from.

In scope: the store (lineage of base and delta tables, compaction, erasure of a group), ingest (extract,
resolve, deduplicate, embed, supersede), the read path, the value types, the graph spec, and the seams
through which a host supplies an embedder, an LLM, a clock and a source.

Out of scope here:

- Application adapters that bind the graph to a particular product's tables, servers or hooks. They live
  outside komira and use the seams below.
- The durable table format. That is [data_graph_storage.md](data_graph_storage.md); this port brings the
  lineage layer that exists today and keeps it behind the seam in the open questions.
- Authorization of who may read which graph. The spec names a resource reference from
  [`komira_authz_api`](../../src/komira_authz_api/) and decides nothing about policy.
- Connectors to external services (OAuth, sync, fetchers) are not part of the core and are not scheduled by
  this document (see the last wave).

## What are the packages?

All new packages start as `mojo_library` (the rule every sibling port uses today) and move to
`mojo_package` with the rest of the family. Directory, import name and target name are the same, as for
every package. Sizes are the source implementation's line counts before splitting; every file over 1000
lines is split during the port, because the repository's file limit applies.

| package | what it is | source lines | engine |
|---|---|---:|---|
| `komira_kg_format` | everything below the engine line that the writer and the reader share: the values and on-disk formats (embedding, JSON value tree, triples, schemas, manifest, delta codec, fingerprints, query result, cosine), the snapshot lineage store, and the exact-scan searches and rank fusion over a snapshot | about 5,100 | none |
| `komira_kg` | the mutable store and ingest: bi-temporal edges, alias map, dedup, working set, compaction, ingest, extractors, cursor store, the embedder and LLM seams, the push-capture adapter | about 8,000 | none |
| `komira_kg_mode` | the extraction-mode vocabulary the spec and the extractor selection share | about 170 | none |
| `komira_kg_spec` | the graph spec and its validation (tiers, modes) | about 540 | none |
| `komira_kg_llm` | HTTP transports for an LLM and an embedder, a local LLM client, extraction-mode selection | about 1,700 | none |
| `komira_kg_crm` | CRM-shaped derivation over the graph: model, query, writeback, derivers | about 4,000 | none |
| `komira_kg_capture` | the capture server with its query surface | about 2,650 | none |
| `komira_kg_enrich` | the enrichment queue (item, queue, compare-and-set queue), drain lease, retry scheduler and drain worker | about 1,050 | none |
| `komira_kg_sources` | document and record adapters (mail, calendar, meeting, file) and the brute-force index over them | about 5,100 | none |
| `komira_kg_read` | the three engine-run reads over a snapshot: neighbourhood, between nodes, time slice | about 400 | `sdk_exec` and `sdk` |

The rule that places a function: it is in `komira_kg_format` if it needs no engine and both the writer and a
reader use it (or it is a pure scan of a snapshot); it is in `komira_kg_read` only if it runs a plan through
`EngineContext`. The name `komira_kg_format` is kept for the lineage store it contains because the store is
the format's reader and writer; the source's name for it was worse.

### What does komira_kg_format export?

The source implementation keeps these in a package named `komira_kg_read` and re-exports each from a
second package through 12 shim files. The port drops the shims and splits by engine dependency instead.
Only three functions of the source `read` file run a plan through the engine; the rest of it (the two
exact scans, the out-degree count and rank fusion) read parquet bytes and score them in Mojo. Those move to
`komira_kg_format` as a `search` module; only the three engine functions stay in `komira_kg_read`.

- `embedding`: `pack_embedding`, `pack_embedding_f32`, `unpack_embedding`, `unpack_embedding_bytes`.
- `cosine`: `Hit`, `cosine`, `cosine_topk`.
- `ingest_types`: `Triple`, `EntityMention`, `Extraction`.
- `json_value`: the JSON value tree used for payloads.
- `schemas`: `episodes_schema`, `entities_schema`, `edges_schema`, `edges_tombstone_schema`,
  `entities_embedding_schema`, `communities_schema`, the community-report schema, the schema-version
  constants and `EMB_DIM`.
- `manifest_body`: `KgManifestBody`, `KgTableEntry`, `KG_SNAPSHOT_FORMAT_VERSION`.
- `delta_body`, `delta_codec`: `encode_delta_table_object`, `delta_object_is_framed`,
  `delta_object_parquet_bytes`, `decode_framed_delta_to_batch`.
- `source_fingerprint`: `SourceFingerprint`, `SourceFingerprintSet`, `SourceFingerprintStore`,
  `content_hash_of`, `content_hash_of_extraction`, `fnv1a64_hex`.
- `query_result`: `KgQueryResult`, `ResultNode`, `ResultEdge`, `ResultFinding`, `ProvenanceEntry`, `Locus`,
  `ScoreEntry`, severity constants, `KG_QUERY_RESULT_FORMAT_VERSION`.
- `snapshot_store`: `KgSnapshotStore[Store]`, `SnapshotView[Store]`, `ChainView[Store]`, `KgTable`,
  `CompactionPolicy`, `SnapshotId`.
- `search`: `node_similarity_search`, `edge_fulltext_search`, `edge_out_degree`, `rrf_fuse`. They read a
  snapshot table through the from-bytes reader of PR 0 (bytes in, batch out) and rank in Mojo; the source's
  temp-file materialisation and its clock-based temp-name nonce are not ported.

Dependencies, derived from the imports of the files named here: `komira_arrow`, `komira_buffer`,
`komira_collections`, `komira_json`, `komira_hash`, `komira_objectstore` (CAS manifest, path, store),
`komira_parquet` and `komira_parquet_writer`. Each package's `deps` is the full transitive closure, as the
build rules require, and is re-derived from the imports in its first PR.

### What does komira_kg export?

- Bi-temporal edges: `WorkingEdge`, `open_edge`, `overlapping_contradiction_candidates`,
  `apply_invalidation`.
- Resolution: `normalize_name`, `minhash_signature`, `jaccard_estimate`, `lsh_candidate`, `DedupCandidate`,
  `Resolution`, `dedup_resolve`, `AliasMap`.
- Working set and compaction: `WorkingEntity`, `WorkingEpisode`, `SnapshotWorkingSet`, `WarmMergedCache`,
  `CompactionResult`, `compact_chain`, `maybe_compact_chain`, `erase_kg_group`, `EmbeddingCandidate`.
- Ingest: `IngestConfig`, `EpisodeInput`, `StructuredEpisode`, `ingest_episode`, `ingest_episode_into`,
  `ingest_structured`, `ingest_structured_into`, `resolve_entities`, `apply_edges`, `run_gleaning`.
- Seams: `KgEmbedder` and `StubEmbedder`; `KgLlmClient` and `StubLlmClient` (see the seam table).
- Extraction without a model: `DeterministicExtractor`.
- Sync state: `CursorStore[Store]`, `SurfaceCursor`; the capability facet helpers.
- The push-capture adapter: `CapturedSession` and its lowering to an episode. It lives here, not in
  `komira_kg_capture`, because `SurfaceAdapter` in `komira_kg_sources` imports it; `komira_kg_capture` then
  holds only the server.

Dependencies: `komira_kg_format`, `komira_arrow`, `komira_collections`, `komira_objectstore`,
`komira_parquet`, `komira_parquet_writer`, `komira_fs`. The source `snapshot_mut` imports the async local
file system and a wall-clock nonce only for its temp-file dance; with the from-bytes reader of PR 0 both
go, so `komira_async` and `komira_clock` are not dependencies (re-checked from the imports in PR 9). The
store never reads a wall clock itself; see the testing plan.

### What do the other packages export?

- `komira_kg_mode`: the extraction-mode vocabulary (`extract_mode_vocab`), zero dependencies.
- `komira_kg_spec`: the graph spec value (`graph_spec` only), its validation, the tier and mode types, and a
  scope reference. The source spec takes the host's resource reference, which carries an organisation id and
  an owner and is compared field by field; `komira_authz_api`'s `AuthzResource` has only a kind, an opaque id
  and attributes, so it cannot stand in. The port defines its own small `GraphScopeRef` (organisation id and
  optional owner id, plain strings) and the binding to `AuthzResource` is left to the authorization work.
  Depends on `komira_kg_mode`.
- `komira_kg_llm`: `LlmTransport`, `EmbedTransport`, `HttpEmbedder` (a `KgEmbedder`), `LocalLlmClient` (a
  `KgLlmClient`), `ExtractMode` and its selection. Depends on `komira_kg`, `komira_kg_mode`, `komira_async`,
  `komira_http_client`, `komira_http_core`.
- `komira_kg_crm`: the CRM node and edge model, `crm_query`, `crm_writeback`, the deal deriver and its member
  codec, the incremental and push derivers. Depends on `komira_kg` and `komira_objectstore` (the push
  deriver reads through the store trait), in the direction `komira_kg_crm -> komira_kg`; the CRM entities
  themselves are decided in [contacts_and_crm.md](contacts_and_crm.md) and this package maps onto them, not
  the reverse.
- `komira_kg_capture`: the capture server and its query surface. Depends on `komira_kg`,
  `komira_kg_format`, `komira_objectstore`, `komira_async`, `komira_http_server`, and takes the CRM routes
  through the route seam rather than importing `komira_kg_crm`.
- `komira_kg_enrich`: `EnrichmentItem`, `EnrichmentQueue` (trait), `CasEnrichmentQueue`, the drain lease,
  `RetryScheduler`, the drain worker. The source worker calls a concrete sender that authenticates to a
  cloud identity service; the port gives the worker an `EnrichmentSender` trait and the sender stays outside
  komira. Depends on `komira_objectstore`.
- `komira_kg_sources`: `SurfaceAdapter` (trait), the four adapters, `BIndex`, `RawStore[Store]`,
  `WorkspaceBinding`, the external-task adapter. Depends on `komira_kg` and `komira_objectstore`. `BIndex`
  is ported without its chat branch (chat adapters are not ported, see below).
- `komira_kg_read`: `get_between_nodes`, `Neighborhood`, `neighborhood`, `edges_as_of`. Depends on
  `komira_kg_format`, `komira_sdk`, `komira_sdk_exec`.

## What is not ported?

The rule: an application-coupled piece becomes a seam in komira and the binding lives outside komira, or it
is dropped. Nothing internal is named here; the remainder is "application adapters that live outside
komira".

| piece | decision | seam |
|---|---|---|
| the root re-export file and the 12 shim files | dropped; importers name the real module | none |
| application-bound providers and connectors that store into an application database | dropped | the pure `external_task` value type stays in `komira_kg` |
| the task-to-graph adapter (pure, string based) | moved to `komira_kg_sources` as a generic external-task adapter | `ExternalTask` |
| application-specific importers | dropped | none |
| mail, chat and DAV hooks into a host's servers | not in the core. Each hook is a binding of a trait owned by the server package (mail receive, chat ingest, DAV store); that trait is not defined in this port | `MailReceiveHook`, `ChatIngestHook`, `DavStoreHook`, defined by the mail, chat and calendar packages when those servers need them |
| structural adapters and routers for mail and chat | outside komira until the hook traits above exist | as above |
| iCalendar overlay adapters | not ported in this series; need an iCalendar library first (`komira_calendar_ics` and `komira_content_line` may serve) | `SurfaceAdapter` |
| chat adapters, including the generic one that has no server import (and the chat branch of `BIndex`) | not ported in this series; a ruling that the server-independent adapter is open would add it to `komira_kg_sources` | `SurfaceAdapter` |
| the enrichment sender (it authenticates to a cloud identity service) | outside komira; the host supplies it | `EnrichmentSender` |
| inference-backend re-exports | dropped; a host supplies a `KgLlmClient` | `KgLlmClient` |
| the graph's resource-type registration | outside komira; it binds the spec to a host's resource catalog | `komira_kg_spec` exposes the spec only |
| the mail hook's read of an environment variable | dropped; configuration is flags | a constructor argument |
| the CRM routes inside the capture server | split out of `capture_node` into `komira_kg_crm` | `CaptureRoutes` |
| vendor-specific types pulled into generic modules (the raw store imports the mail adapter, the workspace binding the calendar adapter) | replaced in the generic modules by a `SurfaceKind` enum | `SurfaceKind` |
| the connector framework and sync driver | not scheduled with the core: the driver imports the capture server and every connector imports the driver; they travel with the connectors | none |
| a production call into a parquet test helper (in the store and the read path), and the temp files it forces | replaced by a public from-bytes reader in `komira_parquet` (PR 0 below) | none |
| spike, live and end-to-end tests that need a network, a credential or a local model | not ported; a test that needs a network or a credential does not belong in the build | none |

The seams, with the shape each has today in the source implementation:

| seam | kind | who implements it |
|---|---|---|
| `KgEmbedder` | trait: embed a batch of strings, report its dimension | `StubEmbedder` (tests), `HttpEmbedder` (`komira_kg_llm`), a host |
| `KgLlmClient` | trait: extraction and judgment calls | `StubLlmClient` (tests), `LocalLlmClient`, a host |
| `SurfaceAdapter` | trait: one source record to an `Extraction` or a structured episode | the adapters in `komira_kg_sources`, a host |
| `CaptureRoutes` | trait: register extra routes on the capture server | `komira_kg_crm`, a host |
| `CloneableConditionalWriteStore` | the object-store trait the lineage is written through | `komira_objectstore` (the in-memory and local-file stores in tests) |
| time | an `Int64` milliseconds argument, or the module's existing clock parameter | the caller; `komira_clock` in production, a constant in tests |
| `EnrichmentSender` | trait: deliver one enrichment item to a capture endpoint | a host |

## What does each package need from the engine?

Three functions of the source `read` file touch the engine: `get_between_nodes`, `neighborhood` and
`edges_as_of` read tables through `EngineContext` (`read_parquet`, `materialize_plan`) and build plans with
the plan carrier. The other four (the two exact scans, the out-degree count, rank fusion) read parquet
bytes and rank in Mojo; they are in `komira_kg_format` and need no engine. A search of the source library
for `engine_dispatch`, the operator packages, the compiler and `fs_registry` finds no import of any of
them; five of its tests construct an `EngineContext`. The states are those of the main branch when this was
written; re-check them before each PR.

| dependency | needed by | state on main |
|---|---|---|
| `sdk_exec` (`EngineContext`) | `komira_kg_read`; five of the library's tests | missing: no package, no open PR |
| `sdk` plan carrier (`PlanCarrier`) | `komira_kg_read` | missing: `komira_sdk` has `ParquetReadOptions`, but the carrier type is only named in comments; no open PR |
| plan expression and IR (`komira_plan_expr`, `komira_plan_ir`) | `komira_kg_read` | exist |

`komira_kg_read` is therefore blocked on two absent types, `EngineContext` and `PlanCarrier`, with no open
PR for either; they need an owner and an issue before PR 25. The engine dispatch, operator, compiler and
`fs_registry` packages are not imports of this library and are not listed as its blockers; they matter only
to whatever `EngineContext` runs. A second question is for the `sdk_exec` design: the source reads
through a path (`ctx.read_parquet(path)`), so it writes snapshot bytes to a temp file first. The port does
not carry that. `komira_kg_read` needs either a bytes or store-backed source in `sdk_exec`, or an explicit
decision to write through `komira_fs`; it is settled in `sdk_exec`, not here.

Consequences: every package except `komira_kg_read` needs no engine and can land today. `komira_kg_read`
blocks nothing else.

The source functions already build plans over snapshot parquet. [data_graph_storage.md](data_graph_storage.md)
says the graph has no query API of its own and that its operators are plan nodes. That is a future shape,
not what this port does: the three functions are ported as they are, and when the graph operators of
[optimized_plan_sources.md](optimized_plan_sources.md) section 15 exist, each is replaced by the operator
and its signature stays.

## In what order does it land?

Each PR is one package change, under about 2,000 lines of source (tests excluded), and brings its tests.
Line figures are the sums of the source files named, rounded; a file over 1000 lines is split inside the PR
that brings it, at the seams named. A package's `deps` is stated in its first PR and grown in later ones.

### Wave 0: no engine, no new library

| PR | contents | lines | deps | tests that come with it |
|---|---|---:|---|---|
| 0 | `komira_parquet`: a public from-bytes function that decodes a whole in-memory Parquet file to one batch (the footer, each row group, concatenated in file order). It only adds the API; three private test copies of the same function (two in `komira_telemetry_store` tests, one in `komira_log_index` tests) may be migrated to it later | 150 | `komira_parquet` | round trip through the writer for every column type the graph schemas use; truncated file; empty file; a bad magic |
| 1 | `komira_kg_format` part 1: `embedding`, `ingest_types`, `json_value`, `manifest_body` | 1,100 | arrow, buffer, json | pack and unpack are inverses for f32 and f64; a malformed JSON value is refused; manifest encode and decode round trip with the format version; the manifest carries the embedding dimension |
| 2 | `komira_kg_format` part 2: `schemas`, `cosine`, `query_result` | 1,030 | part 1 | every schema field and version is pinned by name; cosine of equal, orthogonal and zero vectors; top-k ties are ordered; result round trip |
| 3 | `komira_kg_format` part 3: `delta_body`, `delta_codec`, `source_fingerprint` | 1,280 | parts 1-2, parquet writer, objectstore | framed and parquet delta objects both decode; a fingerprint changes when one byte of content changes |
| 4 | `komira_kg_format` part 4: `snapshot_store` (974 lines; split into store, view and chain) | 980 | parts 1-3, objectstore | base then delta chain read back; a lost compare-and-set race is retried and reported; compaction folds and keeps the reader's pinned snapshot readable |
| 5 | `komira_kg_format` part 5: `search` (the two exact scans, `edge_out_degree`, `rrf_fuse`) | 350 | parts 2 and 4, PR 0 | similarity top-k equals `cosine_topk` over the same rows; full-text counts on stated rows; `rrf_fuse` on stated ranks; an empty table |
| 6 | `komira_kg` part 1: `bitemporal`, `alias_map`, `dedup`, `capability_facet`, `external_task` | 1,430 | `komira_kg_format` | an invalidation closes the overlapping edge and keeps the old system-time row; dedup matches, creates, or asks for judgment on stated inputs; alias resolution is stable under reordering |
| 7 | `komira_kg` part 2: `KgEmbedder`, `KgLlmClient`, the stubs | 650 | part 1 | the stubs are deterministic and report their dimension |
| 8 | `komira_kg` part 3: `DeterministicExtractor`, `CursorStore` | 1,170 | PRs 6 and 7 | the extractor on fixed text yields fixed triples; a cursor survives a write-read and a conflicting writer |
| 9 | `komira_kg` part 4: `snapshot_mut` values and working set (the 2,045-line file is split here and in PR 10: values plus the working set, then erase, warm cache, compaction and embedding top-k) | 1,300 | PRs 4 and 6, PR 0 | a mutation reads back identically; a snapshot read sees one consistent set of tables |
| 10 | `komira_kg` part 5: erase, warm cache, compaction, embedding top-k | 620 | PR 9 | a mutation then compaction reads back identically before and after; compaction never deletes an object a pinned snapshot names; erasure of a group removes every row and every embedding of it |
| 11 | `komira_kg` part 6: `ingest` episode path and entity resolution (the 1,717-line file is split here and in PR 12) | 900 | PRs 8 and 10 | one episode produces the expected nodes, edges and provenance; a write with the wrong embedding dimension is refused |
| 12 | `komira_kg` part 7: `ingest` structured path, gleaning, edge application | 800 | PR 11 | re-ingest of an unchanged source is a no-op by fingerprint; a contradiction supersedes |
| 13 | `komira_kg` part 8: `capture_adapter` | 930 | PR 11 | a captured session lowers to the expected episode |
| 14 | `komira_kg_mode` | 170 | none | each mode name round trips; an unknown name is refused |
| 15 | `komira_kg_spec` (`graph_spec` and `GraphScopeRef`; the host resource-type registration is not ported) | 540 | PR 14 | each invalid spec is refused with its own message; a valid spec round trips; a scope of another organisation is refused |
| 16 | `komira_kg_llm`: transports, `HttpEmbedder`, `LocalLlmClient`, extraction mode | 1,700 | PRs 7, 12 and 14, async, http client | against an in-process server: request shape, a non-200, a truncated body; the request-timeout value reaches the connector (the transport takes a timeout value, not a clock, so no test waits) |
| 17 | `komira_kg_crm` part 1: model, query, writeback | 1,530 | PR 12 | a row maps to the node and edge the CRM document names; a writeback is a new bi-temporal row, never an update |
| 18 | `komira_kg_crm` part 2: deal deriver with member codec (one cycle, one PR) | 1,270 | PR 17 | derived deals equal the expected set for fixed rows |
| 19 | `komira_kg_crm` part 3: incremental and push derivers | 1,200 | PR 18, objectstore | the incremental deriver after a change equals a full derive |
| 20 | `komira_kg_sources` part 1: `SurfaceKind`, `SurfaceAdapter`, `RawStore`, `WorkspaceBinding`, the external-task adapter | 2,000 | PRs 12 and 13 | a raw record is stored once per content hash; a workspace binds one store and one lineage |
| 21 | `komira_kg_sources` part 2: mail and calendar adapters | 1,310 | PR 20 | each adapter on a fixed fixture yields the expected episode |
| 22 | `komira_kg_sources` part 3: meeting and file adapters, `BIndex` (without its chat branch) | 1,740 | PR 21 | each adapter on a fixed fixture yields the expected episode; the index returns the same top-k as a plain scan |
| 23 | `komira_kg_capture`: server and `CaptureRoutes` (the CRM routes are split out of the server first) | 2,650 (two PRs) | PRs 12 and 13, http server | a push becomes an episode; the query surface answers from the warm cache and from the snapshot alike; extra routes are only reachable if registered; the server takes its clock as an argument |
| 24 | `komira_kg_enrich` with the `EnrichmentSender` trait | 1,050 | objectstore | an item is delivered once; a failed delivery is retried by the scheduler's stated schedule; a second worker cannot drain while a lease is held |

That is 26 PRs for about 28,000 lines. PRs 1 to 4 are a chain; 5 needs PRs 2 and 4; 6 needs PR 2; 14 needs
nothing. After PR 2 the chain from 6 to 13 and the branches 14, 17 and 24 run in parallel. PRs 9, 11 and 20
have the largest source files; the file split is real work inside the PR and is the reason for the larger
sizes.

### Wave 1: the engine

| PR | contents | lines | waits for | tests that come with it |
|---|---|---:|---|---|
| 25 | `komira_kg_read`: `get_between_nodes`, `neighborhood`, `edges_as_of` | 400 | `EngineContext` in `sdk_exec`; `PlanCarrier` in `komira_sdk`; PR 5 | `neighborhood` and `get_between_nodes` on a fixed snapshot, including a node with no edges and a leaf guard; `edges_as_of` at an open interval's boundaries |
| 26 | the five engine tests of the source library, rewritten against package imports: CSR adjacency, between-nodes leaf guard, query surface, read off a snapshot, storage integration | tests only | PR 25 | these are the end-to-end checks of write then read |

### Unscheduled: connectors

The source library also holds connectors to external services (OAuth, provider and fetcher files, a sync
driver and a framework, about 25,000 lines). Whether they are public is undecided (open question 5), and no
PR is scheduled. If they are taken up, they depend on `komira_http_client`, `komira_crypto` and the capture
server, replace the source's clock import with `komira_clock`, and land after PR 23; files that import each
other in a cycle land in one PR (the CRM deal deriver and its member codec, in PR 18, is one such pair).

## How is it tested?

What each package's tests must prove, and the rules that apply to all of them:

| package | what the tests prove | defect each would catch |
|---|---|---|
| `komira_kg_format` | every encoding round trips; every version constant and schema is pinned; a corrupt or truncated input is refused with an error, never a partial value; the lineage survives a lost compare-and-set race | a format change that strands existing data; a reader that accepts garbage; a compaction that loses a delta |
| `komira_kg` | bi-temporal invariants (a superseded fact keeps its system-time row; no two open edges with the same key); ingest is idempotent per source fingerprint; erasure reaches rows, embeddings and fingerprints | a double-ingest; a contradiction that overwrites history; an erasure that leaves a copy |
| `komira_kg_spec` | each validation rule has a test that fails alone | a rule silently dropped |
| `komira_kg_llm` | request and response shape against an in-process server; failure paths | an unhandled non-200; a retry loop with no bound |
| `komira_kg_crm` | derived rows equal expected for fixed input; incremental equals full | drift between the two derive paths |
| `komira_kg_capture`, `komira_kg_sources`, `komira_kg_enrich` | adapter output for fixed fixtures; routes reachable only when registered; a queue item delivered once, a lease held by one worker | an adapter that drops a field; an unauthenticated route |
| `komira_kg_read` | each engine-run operation on a fixed snapshot; end-to-end write then read | a read that disagrees with what the writer stored |

Rules:

- No timing assertions. Every function that stamps or compares time takes the time as an argument (an
  `Int64` of milliseconds, or the module's clock parameter), so a test passes a constant and a timeout test
  advances an injected clock. A test that sleeps or reads the wall clock is refused in review. The capture
  server and the retry scheduler read time in the source and get a clock argument in their first PR. 11 of
  the 93 source test files read a clock or sleep (found by searching for sleep, monotonic, performance
  counter, wall-clock and `std.time` names); each is rewritten in the PR that brings the code it tests, and
  that PR's description names it.
- Tests use the in-memory and local-file object stores and the stubs; none needs a network, a credential or
  an environment variable. In the source library 16 of 93 test files read the environment and 9 are named live,
  end-to-end or local-model tests; they are rewritten to a fixture or not ported.
- Ten source test files are over 1000 lines (the largest 2,181). A ported test is split by behaviour into
  files under the limit; a test of a connector is not ported with the core.
- The source tests live in the package and 55 of 93 import its root file, so they could only be built last.
  The port removes the root file and rewrites those tests to import the package modules, so each PR's tests
  build in that PR.
- Coverage: komira's target is 99.00% line coverage, and branch coverage where a package holds it, measured
  per touched package by the `coverage` check; a package under its held figure is a regression and shows
  red on the pull request. Library code does not land below the figure the package already holds, so tests
  and code arrive in the same PR. The first PR of each package states its figure in its description.
- Pointer rules apply on arrival: 31 source test files use `UnsafePointer` or `unsafe_ptr`, 6 name an
  any-origin or external origin and 8 call `external_call`; each is rewritten to a safe form, not copied.
  The counts are file counts from a text search, not a count of uses. The library files use none of these.
- A bug found while porting gets a test that failed before the fix, named in `test_srcs`.

## What must always hold?

- `komira_kg_format` imports no engine package and no network package; `komira_kg` imports no HTTP package.
  Each package's `deps` list in its first PR is the check: a forbidden dependency is a build error.
- No komira package imports an application package; application adapters import komira, never the reverse.
These are required properties of the port, each tested in the PR named, not claims about the source today.

- The lineage is append-only until compaction, and compaction never deletes an object a pinned snapshot
  still names (tested in PRs 4 and 10).
- A snapshot read sees one consistent set of tables: the manifest it pinned (PRs 4 and 9).
- The embedding dimension of a graph is written in its manifest (PR 1) and checked on every write (PR 11).
  The source schemas fix 1536; taking the dimension from the manifest is a change made in these PRs.

## What are the limits and open questions?

Each question carries the recommended answer; the maintainers decide.

1. **Which storage does the port bring?** The source stores tables on a CAS manifest with a delta chain;
   [data_graph_storage.md](data_graph_storage.md) withdraws that for durable data in favour of Iceberg
   tables with a delta tail, and withdraws the sentinel for an open interval (`TS_OPEN_SENTINEL` today, a
   null there). Recommended: port the working lineage unchanged as the delta-tail layer (it is the part
   that document keeps), keep schema version 1 with the sentinel, and add the Iceberg table writer and the
   null-bound schema as schema version 2 in a later series once `komira_iceberg` lands (its four parts are open as PRs 1785, 1788, 1789 and 1790). Do not rewrite
   storage and port in one step.
2. **One package or two for the read side?** Recommended: two. `komira_kg_format` (no engine) and
   `komira_kg_read` (engine), because only three functions of the source read file run a plan on the engine and the rest is shared with the writer.
3. **Does `snapshot_mut` need a new parquet API or a private helper?** Recommended: a public from-bytes
   reader in `komira_parquet` (PR 0); two other libraries already carry private copies of it in their tests.
4. **Fixed embedding dimension.** The schemas fix 1536. Recommended: keep it as the default constant, take
   the dimension from the manifest, and test one other dimension.
5. **Are connectors to external services public?** They are not scheduled here. The maintainers decide
   before any connector PR; the core stands without them.
6. **Where does the task-tracker adapter go?** Recommended: `komira_kg_sources`, as a generic
   external-task adapter; the providers that bind it to an application database stay out.
7. **Is the resource reference in `komira_authz_api`?** No: `AuthzResource` has no organisation or owner,
   which the spec compares. Decided here, not left to PR 15: the spec defines `GraphScopeRef` and the
   binding to authorization is added with the authorization resource work.
8. **Naming against the code graph.** `komira_kg_code` and `komira_kg` read alike. Recommended: keep both,
   have each README link the other, and describe `komira_kg_code` as the "code graph" everywhere.
9. **Mail, chat and DAV hooks.** Recommended: leave the hook traits to the server packages and port the
   structural adapters only when a server package defines its trait; until then the adapters live outside.
10. **Welding order and the coverage policy.** Recommended: no PR lands untested code; where a source test
    needs a later package (the engine tests), the code lands with its own unit tests and the end-to-end test
    follows in the engine wave.
11. **Is wave 0 too many PRs?** It is 26 PRs for about 28,000 lines, each reviewable in one sitting.
    Recommended: keep it; the cost of a failed large port is higher than the cost of the count.

Limits: the read path scales with the snapshot (an exact scan, no approximate nearest-neighbour index, as in
[data_graph_storage.md](data_graph_storage.md)); the capture server's warm cache is a single process; the
dedup scheme (MinHash with banded LSH) is tuned for names and short strings, not for long documents.

## Where is the code?

Not yet; every location above is the one the package will have. Source sizes quoted are measured on the
source implementation; re-measure each before its PR, because a count carried in a design drifts.
