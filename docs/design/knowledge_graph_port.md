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
rows, support tickets) into entities, edges and episodes, keeps every fact with four time bounds
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
- Vendor connectors (OAuth, sync, fetchers) are a later wave with their own packages (see the port order);
  they are not part of the core.

## What are the packages?

All new packages start as `mojo_library` (the rule every sibling port uses today) and move to
`mojo_package` with the rest of the family. Directory, import name and target name are the same, as for
every package. Sizes are the source implementation's line counts before splitting; every file over 1000
lines is split during the port, because the repository's file limit applies.

| package | what it is | source lines | engine |
|---|---|---:|---|
| `komira_kg_format` | the values and on-disk formats: embedding, JSON value tree, triples, schemas, manifest, delta codec, fingerprints, query result, cosine, snapshot lineage | about 4,800 | none |
| `komira_kg` | the mutable store and ingest: bi-temporal edges, alias map, dedup, working set, compaction, ingest, extractors, cursor store, the embedder and LLM seams | about 7,000 | none |
| `komira_kg_spec` | the graph spec and its validation (tiers, modes) | about 600 | none |
| `komira_kg_llm` | HTTP transports for an LLM and an embedder, a local LLM client, extraction-mode selection | about 1,750 | none |
| `komira_kg_crm` | CRM-shaped derivation over the graph: model, query, writeback, derivers | about 4,000 | none |
| `komira_kg_capture` | push-capture adapter and the capture server with its query surface | about 3,600 | none |
| `komira_kg_sources` | document and record adapters (mail, calendar, chat, meeting, file) and the brute-force index over them | about 5,000 | none |
| `komira_kg_read` | the read path over a snapshot: node similarity, edge full text, neighbourhood, between nodes, time slice, rank fusion | about 900 | `sdk_exec` and `sdk` |
| `komira_kg_connectors_<vendor>` | OAuth, provider and fetchers per vendor (later wave) | about 25,000 | none directly |

### What does komira_kg_format export?

The source implementation keeps these in a package named `komira_kg_read` and re-exports each from a
second package through 12 shim files. The port drops the shims and splits by engine dependency instead:
the one file that needs the engine (`read`) is the only file in `komira_kg_read`; everything it shares with
the writer is in `komira_kg_format`, which needs no engine.

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

Dependencies: `komira_arrow`, `komira_buffer`, `komira_collections`, `komira_json`, `komira_hash`,
`komira_objectstore` (CAS manifest, path, store), `komira_parquet` and `komira_parquet_writer`,
`komira_fs`. Dependencies are the full transitive closure in `deps`, as the build rules require.

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

Dependencies: `komira_kg_format`, `komira_arrow`, `komira_collections`, `komira_objectstore`,
`komira_parquet`, `komira_fs`, `komira_clock`. The store never reads a wall clock itself; see the testing
plan.

### What do the other packages export?

- `komira_kg_spec`: the graph spec value, its validation, the tier and mode types, and a resource reference
  taken from `komira_authz_api` (see the open questions: the reference type must be confirmed there).
- `komira_kg_llm`: `LlmTransport`, `EmbedTransport`, `HttpEmbedder` (a `KgEmbedder`), `LocalLlmClient` (a
  `KgLlmClient`), `ExtractMode` and its selection. Depends on `komira_kg`, `komira_async`,
  `komira_http_client`, `komira_http_core`.
- `komira_kg_crm`: the CRM node and edge model, `crm_query`, `crm_writeback`, the deal deriver and its member
  codec, the incremental and push derivers. Depends on `komira_kg` only, in the direction
  `komira_kg_crm -> komira_kg`; the CRM entities themselves are decided in
  [contacts_and_crm.md](contacts_and_crm.md) and this package maps onto them, not the reverse.
- `komira_kg_capture`: the push-capture adapter, the capture server and its query surface. Depends on
  `komira_kg`, `komira_kg_format`, `komira_async`, `komira_http_server`, and takes the CRM routes through the
  route seam rather than importing `komira_kg_crm`.
- `komira_kg_sources`: `SurfaceAdapter` (trait), the five adapters, `BIndex`, `RawStore[Store]`,
  `WorkspaceBinding`. Depends on `komira_kg`.
- `komira_kg_read`: `node_similarity_search`, `edge_fulltext_search`, `get_between_nodes`, `Neighborhood`,
  `neighborhood`, `edges_as_of`, `rrf_fuse`. Depends on `komira_kg_format`, `komira_sdk`,
  `komira_sdk_exec` and the plan packages.

## What is not ported?

The rule: an application-coupled piece becomes a seam in komira and the binding lives outside komira, or it
is dropped. Nothing internal is named here; the remainder is "application adapters that live outside
komira".

| piece | decision | seam |
|---|---|---|
| the root re-export file and the 12 shim files | dropped; importers name the real module | none |
| task-tracker providers and the connector that stores tasks in an application database | dropped | the pure `external_task` value type stays in `komira_kg` |
| the task-to-graph adapter (pure, string based) | moved to `komira_kg_sources` as a generic external-task adapter | `ExternalTask` |
| HR-system import into a people and identity store | dropped | none; the fetch half is a connector candidate with a local worker-type enum |
| mail, chat and DAV hooks into a host's servers | not in the core. Each hook is a binding of a trait owned by the server package (mail receive, chat ingest, DAV store); that trait is not defined in this port | `MailReceiveHook`, `ChatIngestHook`, `DavStoreHook`, defined by the mail, chat and calendar packages when those servers need them |
| structural adapters and routers for mail and chat | outside komira until the hook traits above exist | as above |
| CalDAV and iCalendar overlay adapters | on hold; need an iCalendar library first (`komira_calendar_ics` and `komira_content_line` may serve) | `SurfaceAdapter` |
| chat adapters bound to a chat server | on hold | `SurfaceAdapter` |
| inference-backend re-exports | dropped; a host supplies a `KgLlmClient` | `KgLlmClient` |
| the graph's resource-type registration | outside komira; it binds the spec to a host's resource catalog | `komira_kg_spec` exposes the spec only |
| the mail hook's read of an environment variable | dropped; configuration is flags | a constructor argument |
| the CRM routes inside the capture server | split out of `capture_node` into `komira_kg_crm` | `CaptureRoutes` |
| Google-specific types pulled into generic modules (`raw_store` imports the Gmail adapter, `workspace_binding` the calendar adapter, every connector the sync driver) | moved into generic modules: a `SurfaceKind` enum in `RawStore`, and the sync driver (misnamed as a spike) becomes `komira_kg_sources.sync_driver` | `SurfaceKind`, `SyncDriver` |
| a production call into a parquet test helper (in the store and the read path) | replaced by a public whole-file reader in `komira_parquet` (PR 0 below) | none |
| spike and live tests (live sync, live tail, MLX end to end) | not ported; a test that needs a network or a credential does not belong in the build | none |

The seams, with the shape each has today in the source implementation:

| seam | kind | who implements it |
|---|---|---|
| `KgEmbedder` | trait: embed a batch of strings, report its dimension | `StubEmbedder` (tests), `HttpEmbedder` (`komira_kg_llm`), a host |
| `KgLlmClient` | trait: extraction and judgment calls | `StubLlmClient` (tests), `LocalLlmClient`, a host |
| `SurfaceAdapter` | trait: one source record to an `Extraction` or a structured episode | the adapters in `komira_kg_sources`, a host |
| `CaptureRoutes` | trait: register extra routes on the capture server | `komira_kg_crm`, a host |
| `CloneableConditionalWriteStore` | the object-store trait the lineage is written through | `komira_objectstore` (the in-memory and local-file stores in tests) |
| time | an `Int64` milliseconds argument, or the module's existing clock parameter | the caller; `komira_clock` in production, a constant in tests |

## What does each package need from the engine?

The engine surface of the whole library is one file. Only `read` imports an engine type
(`EngineContext` from `sdk_exec`, the plan carrier and `ParquetReadOptions` from `sdk`, and the plan
expression types). A search of the source implementation for `engine_dispatch`, the operator packages, the
compiler and `fs_registry` finds no import of any of them in the library; five of its tests construct an
`EngineContext`. Those four are therefore reached only through `sdk_exec`, and the table says what
`komira_kg_read` inherits, not what it imports. The states are those of the main branch when this was
written; re-check them before each PR.

| dependency | needed by | state on main |
|---|---|---|
| `sdk_exec` (`EngineContext`) | `komira_kg_read`; five of the library's tests | missing: no package, no open PR |
| `sdk` (plan carrier, `ParquetReadOptions`) | `komira_kg_read` | partly there: `komira_sdk` has `ParquetReadOptions` and the carrier verbs' helpers; the carrier type itself is not in the tree |
| plan expression and IR (`komira_plan_expr`, `komira_plan_ir`) | `komira_kg_read` | exist |
| `engine_dispatch` | transitively, through `sdk_exec` | missing as one package; the `dispatch_*` pieces are in (aggregate, join kernels, scan), `dispatch_sources` and `dispatch_project` are in flight |
| operators | transitively | partly in: aggregate (state, hash, slab, distinct), join build, sort and sources are in; join probe, join sinks and stage, aggregate stage, window, as-of, spill rows and fused kernels are in flight |
| `compiler` | transitively | missing: the plan, optimizer and SQL front end are in, the binder is a draft |
| `fs_registry` | transitively | missing; `komira_fs` is in. This library uses `komira_fs` directly and never needs the registry itself |

Consequences: `komira_kg_format`, `komira_kg`, `komira_kg_spec`, `komira_kg_llm`, `komira_kg_crm`,
`komira_kg_capture` and `komira_kg_sources` need no engine and can land today. `komira_kg_read` is blocked
on `sdk_exec` and does not block anything else. The one connector file that imports `read` (the Google sync
daemon) moves to the engine wave with it.

How the read path stays honest about the engine: [data_graph_storage.md](data_graph_storage.md) says the
graph has no query API of its own and that its operators are plan nodes. The source `read` already builds
plans over snapshot parquet and runs them through `EngineContext`. The port keeps those functions as thin
plan builders with no scanning logic of their own, so that when the graph operators of
[optimized_plan_sources.md](optimized_plan_sources.md) section 15 exist, each function is replaced by the
operator and the signature stays.

## In what order does it land?

Each PR is one package change, under about 1,500 lines of source (tests excluded), and brings its tests.
Every file over the limit is split inside the PR that brings it. A package's `deps` is stated in its first
PR and grown in later ones.

### Wave 0: no engine, no new library

| PR | contents | lines | deps | tests that come with it |
|---|---|---:|---|---|
| 0 | `komira_parquet`: a public read-whole-file-to-batch function over `ParquetFileReader`, so no production code calls a test helper | 150 | `komira_parquet`, `komira_fs` | round trip through the writer for every column type the graph schemas use; truncated file; empty file |
| 1 | `komira_kg_format` part 1: `embedding`, `ingest_types`, `json_value`, `manifest_body` | 1,100 | arrow, buffer, json | pack and unpack are inverses for f32 and f64; a malformed JSON value is refused; manifest encode and decode round trip with the format version |
| 2 | `komira_kg_format` part 2: `schemas`, `cosine`, `query_result` | 1,030 | part 1 | every schema field and version is pinned by name; cosine of equal, orthogonal and zero vectors; top-k ties are ordered; result round trip |
| 3 | `komira_kg_format` part 3: `delta_body`, `delta_codec`, `source_fingerprint` | 1,280 | parts 1-2, parquet writer, objectstore | framed and parquet delta objects both decode; a fingerprint changes when one byte of content changes |
| 4 | `komira_kg_format` part 4: `snapshot_store` (split into store, view and chain) | 980 | parts 1-3, objectstore, PR 0 | base then delta chain read back; a lost compare-and-set race is retried and reported; compaction folds and keeps the reader's pinned snapshot readable |
| 5 | `komira_kg` part 1: `bitemporal`, `alias_map`, `dedup`, `capability_facet`, `external_task` | 1,430 | `komira_kg_format` | an invalidation closes the overlapping edge and keeps the old system-time row; dedup matches, creates, or asks for judgment on stated inputs; alias resolution is stable under reordering |
| 6 | `komira_kg` part 2: `KgEmbedder`, `KgLlmClient`, the stubs, `DeterministicExtractor`, `CursorStore` | 1,500 | part 1 | the stubs are deterministic; the extractor on fixed text yields fixed triples; a cursor survives a write-read and a conflicting writer |
| 7 | `komira_kg` part 3: `snapshot_mut`, split into working set, warm cache and compaction | 2,050 | parts 1-2, PR 4 | a mutation then compaction reads back identically before and after; erasure of a group removes every row and every embedding of it |
| 8 | `komira_kg` part 4: `ingest`, split into episode, structured and gleaning | 1,700 | part 3 | one episode produces the expected nodes, edges and provenance; re-ingest of an unchanged source is a no-op by fingerprint; a contradiction supersedes |
| 9 | `komira_kg_spec` | 600 | `komira_authz_api` | each invalid spec is refused with its own message; a valid spec round trips |
| 10 | `komira_kg_llm`: transports, `HttpEmbedder`, `LocalLlmClient`, extraction mode | 1,750 | `komira_kg`, async, http client | against an in-process server: request shape, a non-200, a truncated body, a timeout driven by an injected clock |
| 11 | `komira_kg_crm` part 1: model, query, writeback | 1,530 | `komira_kg` | a row maps to the node and edge the CRM document names; a writeback is a new bi-temporal row, never an update |
| 12 | `komira_kg_crm` part 2: deal deriver with member codec (one cycle, one PR), then incremental and push derivers | 2,450 (two PRs) | part 1 | derived deals equal the expected set for fixed rows; the incremental deriver after a change equals a full derive |
| 13 | `komira_kg_sources` part 1: `SurfaceKind`, `SurfaceAdapter`, `RawStore`, `WorkspaceBinding`, the external-task adapter | 1,700 | `komira_kg` | a raw record is stored once per content hash; a workspace binds one store and one lineage |
| 14 | `komira_kg_sources` part 2: the five adapters and `BIndex` | 3,200 (two PRs) | part 1 | each adapter on a fixed fixture yields the expected episode; the index returns the same top-k as a plain scan |
| 15 | `komira_kg_capture`: capture adapter, server and `CaptureRoutes` | 3,600 (two or three PRs) | `komira_kg`, http server | a push becomes an episode; the query surface answers from the warm cache and from the snapshot alike; extra routes are only reachable if registered |

PRs 1 to 4 are a chain; 5 needs PR 2; 9 needs nothing from the format; 10 needs PR 6. After PR 2 the chain from 5 to 8 and the
branches 9, 10 and 11 run in parallel.

### Wave 1: the engine

| PR | contents | lines | waits for | tests that come with it |
|---|---|---:|---|---|
| 16 | `komira_kg_read`: `read` split into search, traversal and fusion | 900 | `sdk_exec` with `EngineContext`; the plan carrier in `komira_sdk` | `rrf_fuse` on stated ranks; `neighborhood` and `get_between_nodes` on a fixed snapshot, including a node with no edges and a leaf guard; `edges_as_of` at an open interval's boundaries; similarity top-k equals `cosine_topk` over the same rows |
| 17 | the five engine tests of the source library, rewritten against package imports: CSR adjacency, between-nodes leaf guard, query surface, read off a snapshot, storage integration | tests only | PR 16 | these are the end-to-end checks of write then read |

### Wave 2: connectors (visibility to be confirmed, see the open questions)

| PR | contents | lines | deps |
|---|---|---:|---|
| 18 | `komira_kg_sources.sync_driver` and the connector framework | 2,000 (two PRs) | wave 0 |
| 19 | OAuth and HTTP client for one vendor family at a time (Google, then Microsoft Graph, Slack, Zoom) | 1,000 to 2,500 each | `komira_crypto`, `komira_http_client`, framework |
| 20 | each vendor's provider and fetchers, one PR per vendor; a cycle of provider and fetcher files lands together | 1,800 to 3,100 each | PR 19 |
| 21 | the Google daemon (reads the graph through `komira_kg_read`) | 3,400, split in three | PR 16 |

Four groups of files form import cycles and must each land in one PR: the Zoom provider and its fetcher,
the CRM deal deriver and its member codec, the Microsoft calendar and drive fetchers with the provider, and
the Slack files fetcher with the provider.

## How is it tested?

What each package's tests must prove, and the rules that apply to all of them:

| package | what the tests prove | defect each would catch |
|---|---|---|
| `komira_kg_format` | every encoding round trips; every version constant and schema is pinned; a corrupt or truncated input is refused with an error, never a partial value; the lineage survives a lost compare-and-set race | a format change that strands existing data; a reader that accepts garbage; a compaction that loses a delta |
| `komira_kg` | bi-temporal invariants (a superseded fact keeps its system-time row; no two open edges with the same key); ingest is idempotent per source fingerprint; erasure reaches rows, embeddings and fingerprints | a double-ingest; a contradiction that overwrites history; an erasure that leaves a copy |
| `komira_kg_spec` | each validation rule has a test that fails alone | a rule silently dropped |
| `komira_kg_llm` | request and response shape against an in-process server; failure paths | an unhandled non-200; a retry loop with no bound |
| `komira_kg_crm` | derived rows equal expected for fixed input; incremental equals full | drift between the two derive paths |
| `komira_kg_capture`, `komira_kg_sources` | adapter output for fixed fixtures; routes reachable only when registered | an adapter that drops a field; an unauthenticated route |
| `komira_kg_read` | each operation on a fixed snapshot; end-to-end write then read | a read that disagrees with what the writer stored |

Rules:

- No timing assertions. Every function that stamps or compares time takes the time as an argument (an
  `Int64` of milliseconds, or the module's clock parameter), so a test passes a constant and a timeout test
  advances an injected clock. A test that sleeps or reads the wall clock is refused in review.
- Tests use the in-memory and local-file object stores and the stubs; none needs a network, a credential or
  an environment variable. The source library has 21 test files that read the environment and 6 live or
  end-to-end tests; they are rewritten to a fixture or not ported.
- The source tests live in the package and 55 of 93 import its root file, so they could only be built last.
  The port removes the root file and rewrites those tests to import the package modules, so each PR's tests
  build in that PR.
- Coverage: komira's target is 99.00% line coverage, and branch coverage where a package holds it, measured
  per touched package by the `coverage` check; a package under its held figure is a regression and shows
  red on the pull request. Library code does not land below the figure the package already holds, so tests
  and code arrive in the same PR. The first PR of each package states its figure in its description.
- Pointer rules apply on arrival: ten source test files use `UnsafePointer`, six use wildcard origins and
  eight call `external_call`; each is rewritten to a safe form, not copied. The library files use none of
  these.
- A bug found while porting gets a test that failed before the fix, named in `test_srcs`.

## What must always hold?

- `komira_kg_format` imports no engine package and no network package; `komira_kg` imports no HTTP package.
  Each package's `deps` list in its first PR is the check: a forbidden dependency is a build error.
- No komira package imports an application package; application adapters import komira, never the reverse.
- The lineage is append-only until compaction, and compaction never deletes an object a pinned snapshot
  still names.
- A snapshot read sees one consistent set of tables: the manifest it pinned.
- The embedding dimension of a graph is written in its manifest and checked on every write.

## What are the limits and open questions?

Each question carries the recommended answer; the maintainers decide.

1. **Which storage does the port bring?** The source stores tables on a CAS manifest with a delta chain;
   [data_graph_storage.md](data_graph_storage.md) withdraws that for durable data in favour of Iceberg
   tables with a delta tail, and withdraws the sentinel for an open interval (`TS_OPEN_SENTINEL` today, a
   null there). Recommended: port the working lineage unchanged as the delta-tail layer (it is the part
   that document keeps), keep schema version 1 with the sentinel, and add the Iceberg table writer and the
   null-bound schema as schema version 2 in a later series once `komira_iceberg` lands. Do not rewrite
   storage and port in one step.
2. **One package or two for the read side?** Recommended: two. `komira_kg_format` (no engine) and
   `komira_kg_read` (engine), because 12 of 13 source read files need no engine and the writer needs them.
3. **Does `snapshot_mut` need a new parquet API or a private helper?** Recommended: a public whole-file
   reader in `komira_parquet` (PR 0); two other libraries already carry private copies of it in their tests.
4. **Fixed embedding dimension.** The schemas fix 1536. Recommended: keep it as the default constant, take
   the dimension from the manifest, and test one other dimension.
5. **Are vendor connectors public?** They depend only on HTTP, OAuth and crypto, and contain no secrets.
   Recommended: yes, one package per vendor, after the core; if the maintainers prefer, wave 2 is dropped
   and the core still stands.
6. **Where does the task-tracker adapter go?** Recommended: `komira_kg_sources`, as a generic
   external-task adapter; the providers that bind it to an application database stay out.
7. **Is the resource reference in `komira_authz_api`?** The spec needs one. Recommended: confirm in PR 9; if
   absent, the spec takes the `{kind, id}` pair as plain strings and the binding to authorization is added
   with the authorization resource work.
8. **Naming against the code graph.** `komira_kg_code` and `komira_kg` read alike. Recommended: keep both,
   have each README link the other, and describe `komira_kg_code` as the "code graph" everywhere.
9. **Mail, chat and DAV hooks.** Recommended: leave the hook traits to the server packages and port the
   structural adapters only when a server package defines its trait; until then the adapters live outside.
10. **Welding order and the coverage policy.** Recommended: no PR lands untested code; where a source test
    needs a later package (the engine tests), the code lands with its own unit tests and the end-to-end test
    follows in the engine wave.
11. **Is wave 0 too many PRs?** It is about 20 PRs for about 26,000 lines, each reviewable in one sitting.
    Recommended: keep it; the cost of a failed large port is higher than the cost of the count.

Limits: the read path scales with the snapshot (an exact scan, no approximate nearest-neighbour index, as in
[data_graph_storage.md](data_graph_storage.md)); the capture server's warm cache is a single process; the
dedup scheme (MinHash with banded LSH) is tuned for names and short strings, not for long documents.

## Where is the code?

Not yet; every location above is the one the package will have. Source sizes quoted are measured on the
source implementation; re-measure each before its PR, because a count carried in a design drifts.
