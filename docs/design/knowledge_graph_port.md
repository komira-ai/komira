# The knowledge graph port: packages, seams, engine dependencies and PR order

Status: design; PRs 1, 2, 6, 13 and 18 are in the tree. It decides how the existing data-graph library (a property graph built from
documents and records, with a bi-temporal store and a read path) comes into komira as small, separately
tested packages. Of the packages named here only parts 1 and 2 of [`komira_kg_format`](../../src/komira_kg_format/)
(its `embedding`, `ingest_types`, `manifest_body`, `schemas`, `cosine` and `query_result` modules) and part 1 of
[`komira_kg`](../../src/komira_kg/) (`bitemporal`, `name_similarity`, `dedup`, `alias_map` and `source_facet`), [`komira_kg_mode`](../../src/komira_kg_mode/) and [`komira_kg_enrich`](../../src/komira_kg_enrich/) are in the tree yet. The code graph
[`komira_kg_code`](../../src/komira_kg_code/) is a different thing and is untouched (see
[knowledge_graph.md](../knowledge_graph.md)).

Related, and authoritative where they overlap:
[data_graph_storage.md](data_graph_storage.md) decides how a graph over data is stored durably and that the
graph has no query API of its own; [storage_stack.md](storage_stack.md) is the layer design;
[optimized_plan_sources.md](optimized_plan_sources.md) section 15 spells the graph operators. This document
does not restate them. It ports a working implementation, says where that implementation differs from them,
and orders the work so that nothing waits on the execution engine until it must.

## What is it for, and what is out of scope?

The graph turns documents and records (any text or structured record a host can lower to an episode) into
entities, edges and episodes, keeps every fact with four time bounds
(event time and system time, so a later correction does not erase what was believed before), and answers
questions over them: ranked text, embedding similarity, neighbours, a time slice, and fused rankings. Its
purpose in komira is batch inference: a job reads a pinned snapshot of the graph, asks many questions,
and writes answers next to their provenance, so a result can be traced to the episodes it came from.

## What is generic?

Every public knowledge-graph package is generic. Public here means: a graph store, a query surface, a spec,
formats, snapshot reads, and extraction or enrichment machinery whose models are pluggable. Specifically:

- No package knows a product, an application domain or a vendor. Entity types, predicates, facets, source
  kinds and surfaces are opaque strings supplied by the host; no package fixes a vocabulary.
- A model is always behind a trait (`LlmClient`, `Embedder`, `Extractor`), and prompts are values the caller
  passes in. A network client is named for the wire it speaks (a chat-completions wire, an embeddings wire),
  never for a vendor, a server or a model, and takes its address, model id, dimension and credentials as
  arguments.
- Domain models and derivations built on the graph (rows mapped to typed nodes, derived business objects,
  writebacks), and adapters for a particular document kind, service or capture format, live outside komira.
  The packages below expose the seams those need (`SurfaceAdapter`, `CaptureRoutes`, `EnrichmentSender`,
  `Extractor`, `AuthHeaderProvider`) and nothing more.
- Configuration is flags and constructor arguments, never environment variables.

Each package section below says what it keeps and what it leaves to the host.

In scope: the store (lineage of base and delta tables, compaction, erasure of a partition), ingest (extract,
resolve, deduplicate, embed, supersede), the read path, the value types, the graph spec, and the seams
through which a host supplies an embedder, an LLM, an extractor, a clock and a source.

Out of scope here:

- Application adapters that bind the graph to a particular product's tables, servers or hooks, and domain
  models or derivations over the graph. They live outside komira and use the seams below.
- The durable table format. That is [data_graph_storage.md](data_graph_storage.md); this port brings the
  lineage layer that exists today and keeps it behind the seam in the open questions.
- Authorization of who may read which graph. The spec defines its own `GraphScopeRef` (a scope id plus an optional owner id) and decides nothing about
  policy; open question 7 says why it does not reuse an authorization type.
- Connectors to external services (OAuth, sync, fetchers) and the source adapters that read them are not
  part of komira and are not scheduled by this document.

## What are the packages?

All new packages start as `mojo_library` (the rule every sibling port uses today) and move to
`mojo_package` with the rest of the family. Directory, import name and target name are the same, as for
every package. Every file over 1000 lines is split during the port, because the repository's file limit applies.

| package | what it is | lines (estimate after the changes below) | engine |
|---|---|---:|---|
| `komira_kg_format` | everything below the engine line that the writer and the reader share: the values and on-disk formats (embedding, triples, schemas, manifest, delta codec, fingerprints, query result, cosine), the snapshot lineage store, and the exact-scan searches and rank fusion over a snapshot | about 4,700 | none |
| `komira_kg` | the mutable store and ingest: bi-temporal edges, alias map, dedup, working set, compaction, ingest, the rule-driven extractor, cursor store, the `Embedder`, `LlmClient`, `Extractor` and `SurfaceAdapter` seams | about 6,700 | none |
| `komira_kg_mode` | the extraction-mode vocabulary the spec and the extractor selection share | about 140 | none |
| `komira_kg_spec` | the graph spec and its validation (scopes, modes) | about 540 | none |
| `komira_kg_llm` | HTTP transports for a chat-completions wire and an embeddings wire, a client and an embedder over them, extraction-mode selection | about 1,700 | none |
| `komira_kg_capture` | the capture server with its query surface, extra routes through `CaptureRoutes` | about 2,000 | none |
| `komira_kg_enrich` | the enrichment queue (item, queue, compare-and-set queue), drain lease, retry scheduler, drain worker and the `EnrichmentSender` trait | about 1,150 | none |
| `komira_kg_sources` | the host-neutral half of source handling: the raw record store, the partition binding store, an adapter registry and the brute-force index over registered adapters | about 1,300 | none |
| `komira_kg_read` | the three engine-run reads over a snapshot: neighbourhood, between nodes, time slice | about 400 | `sdk_exec` and `sdk` |

Line figures are for the generalised packages. Where a module is rewritten rather than copied (the
rule-driven extractor, the registry-based index, the server without its domain routes) the figure is an
estimate and is re-measured in the PR that brings it.

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

- `embedding`: `pack_embedding`, `pack_embedding_f32`, `unpack_embedding`, `unpack_embedding_bytes`,
  `unpack_embedding_checked`.
- `cosine`: `Hit`, `cosine`, `cosine_topk`.
- `ingest_types`: `Triple`, `EntityMention`, `Extraction`. The entity type and the predicate are free strings.
- JSON payloads use `komira_json`; this package has no JSON reader of its own.
- `schemas`: `episodes_schema`, `entities_schema`, `edges_schema`, `edges_tombstone_schema`,
  `entities_embedding_schema`, `communities_schema`, the community-report schema and the schema-version
  constants. There is no fixed embedding dimension: the writer takes the dimension as an argument and the
  manifest records it. The episode table carries an opaque `facet` string column (not an enumerated
  vocabulary), and the partition of a row is a `partition_id`. Nothing is published yet, so the schema
  versions are pinned fresh in PR 2.
- `manifest_body`: `KgManifestBody` (with the embedding dimension), `KgTableEntry`,
  `KG_SNAPSHOT_FORMAT_VERSION`.
- `delta_body`, `delta_codec`: `encode_delta_table_object`, `delta_object_is_framed`,
  `delta_object_parquet_bytes`, `decode_framed_delta_to_batch`.
- `source_fingerprint`: `SourceFingerprint`, `SourceFingerprintSet`, `SourceFingerprintStore`,
  `content_hash_of`, `content_hash_of_extraction`, `fnv1a64_hex`. Keyed by partition id and an opaque source
  key.
- `query_result`: `KgQueryResult`, `ResultNode`, `ResultEdge`, `ResultAnnotation` (an opaque kind, an integer
  severity rank and a rationale), `ProvenanceEntry`, `Locus` (a source id and an opaque anchor within it),
  `ScoreEntry`, `KG_QUERY_RESULT_FORMAT_VERSION`. The result mode is an opaque label.
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
  `CompactionResult`, `compact_chain`, `maybe_compact_chain`, `erase_kg_partition`, `EmbeddingCandidate`.
- Ingest: `IngestConfig`, `EpisodeInput`, `StructuredEpisode`, `ingest_episode`, `ingest_episode_into`,
  `ingest_structured`, `ingest_structured_into`, `resolve_entities`, `apply_edges`, `run_gleaning`. An
  episode carries an opaque `facet` and `facet_source`, and a partition id.
- Seams: `Embedder` and `StubEmbedder`; `LlmClient` and `StubLlmClient`; `Extractor`; `SurfaceAdapter` (see
  the seam table).
- Extraction without a model: `RuleExtractor`, an `Extractor` driven by a list of type rules (a type label
  and a matcher: a regex-lite pattern, a verb-prefix list, or a delimited span), with co-occurrence edges,
  the idempotent gleaning contract and the false-judgment policy. Only neutral built-in matchers ship (email
  address, URL, quoted span); a rule set for a domain is data the host passes in.
- Sync state: `CursorStore[Store]`, `SurfaceCursor` (the key is an opaque caller string; no per-service
  constants); the source-facet helpers and the tombstone set, keyed by source and facet.

Dependencies: `komira_kg_format`, `komira_arrow`, `komira_collections`, `komira_objectstore`,
`komira_parquet`, `komira_parquet_writer`, `komira_fs`. The source `snapshot_mut` imports the async local
file system and a wall-clock nonce only for its temp-file dance; with the from-bytes reader of PR 0 both
go, so `komira_async` and `komira_clock` are not dependencies (re-checked from the imports in PR 9). The
store never reads a wall clock itself; see the testing plan.

### What do the other packages export?

- `komira_kg_mode`: the extraction-mode vocabulary (`extract_mode_vocab`), zero dependencies. Two modes:
  rules (no inference, the default) and model. The parse takes a string the host got from a flag and falls
  back to rules on anything unknown; a normalisation step never resolves to model unless the host asked for
  it. The integer values are stored in the spec, so they are fixed in PR 13.
- `komira_kg_spec`: the graph spec value (`graph_spec` only), its validation, the scope and mode types, and
  a scope reference. The source spec takes the host's resource reference, which carries an organisation id
  and an owner and is compared field by field; `komira_authz_api`'s `AuthzResource` has only a kind, an
  opaque id and attributes, so it cannot stand in. The port defines its own small `GraphScopeRef` (a scope
  id and an optional owner id, plain strings) with two ranks, shared and owner, described as scope
  containment and not as authorization. Inference bindings keep the transport label, endpoint and model id
  as opaque values; the rule that an endpoint must belong to the graph's organisation becomes an injected
  `EndpointPolicy` that allows everything by default. A source binding names an opaque source id. The
  host's resource-type registration is not ported. Depends on `komira_kg_mode`.
- `komira_kg_llm`: `ChatTransport` and `EmbedTransport` (post a body, return the body; the address, the
  request path, the timeout value and an optional `AuthHeaderProvider` are configuration values),
  `EmbeddingsWireEmbedder` (an `Embedder`; model id and dimension are constructor arguments and the
  response is checked against the dimension), `ChatCompletionsLlmClient` (an `LlmClient`),
  `ExtractionPrompt` (the system text, the user template, an optional entity-type list and the response
  schema, all passed in by the caller; there is no built-in domain prompt, only a neutral default that asks
  for named entities and the relations between them), `KgExtractClient` (routes a call by mode between any
  `Extractor` and any `LlmClient`; it imports neither concrete type) and the `AuthHeaderProvider` trait.
  The judgment prompts are domain-neutral and stay. Depends on `komira_kg`, `komira_kg_mode`,
  `komira_async`, `komira_http_client`, `komira_http_core`.
- `komira_kg_capture`: the capture server and its query surface. Routes: capture (dispatched to a registered
  `SurfaceAdapter` by a surface tag in the request), structured ingest, query, federated query and health.
  Everything a host would add (routes over a loaded working set) goes through `CaptureRoutes`. The
  synthesis prompt (a neutral text by default) and the default partition are constructor arguments; the facet filter is a plain
  string compared for equality. Depends on `komira_kg`, `komira_kg_format`, `komira_kg_sources`, `komira_objectstore`,
  `komira_async`, `komira_http_server`.
- `komira_kg_enrich`: `EnrichmentItem` (a partition id, an opaque source key and an opaque body),
  `EnrichmentQueue` (trait), `CasEnrichmentQueue`, `DrainLease`, `RetryScheduler`, the drain worker, the
  `EnrichmentSender` trait and an in-memory `FakeEnrichmentSender`. A sender that talks to a particular
  network or identity service is the host's. Depends on `komira_objectstore`.
- `komira_kg_sources`: `RawStore[Store]` (a content-hash-keyed record store over the conditional-write
  store trait, with the surface as an opaque tag on each record), `PartitionBindingStore` (a partition binds
  one raw store and one lineage; source system, source kind and facet are opaque strings, validated against
  a set the host passes in), `AdapterRegistry` (a surface tag to a `SurfaceAdapter`) and `BIndex` (cosine
  over embeddings, top-k, raw key to episode, through the registry). No adapter for a particular document
  kind or service ships; those are conformers of `SurfaceAdapter` outside komira. Depends on `komira_kg`
  and `komira_objectstore`.
- `komira_kg_read`: `get_between_nodes`, `Neighborhood`, `neighborhood`, `edges_as_of`. Depends on
  `komira_kg_format`, `komira_sdk`, `komira_sdk_exec`.

## What is not ported?

The rule: a piece that is domain-specific or product-specific is not in komira. It becomes a seam in komira
and the binding lives outside, or it is dropped. The remainder is "application adapters and domain
derivations that live outside komira".

| piece | decision | seam |
|---|---|---|
| the root re-export file and the 12 shim files | dropped; importers name the real module | none |
| domain models and derivations over the graph (typed node and edge models, derived business objects, query helpers and writeback for them, incremental and push derivers) | outside komira; they are consumers of the public graph | `Extractor`, `SurfaceAdapter`, `CaptureRoutes`, the working set and ingest API |
| the domain routes inside the capture server | split out of `capture_node` and kept outside | `CaptureRoutes` |
| adapters for particular document kinds or services (each reads one kind of document or one service) and their raw-store, binding and index glue | outside komira; each is a conformer of `SurfaceAdapter` | `SurfaceAdapter`, `AdapterRegistry` |
| the push-capture adapter for one terminal-session format, and its conformer | outside komira; a host lowers its own capture format | `SurfaceAdapter` |
| the typed-pattern extractor whose entity vocabulary and verb list are fixed in code | outside komira; the machinery is public as `RuleExtractor`, the rule set is host data | `Extractor` |
| application-bound providers and connectors that store into an application database | dropped | none |
| application-specific importers | dropped | none |
| hooks into a host's own servers, and structural routers for them | outside komira | `SurfaceAdapter` |
| the connector framework, sync driver and OAuth flows | outside komira; not scheduled | none |
| the enrichment sender (it authenticates to a cloud identity service) | outside komira; the host supplies it | `EnrichmentSender`, `AuthHeaderProvider` |
| inference-backend re-exports and process-spawning backends for particular servers | dropped; a host supplies an `LlmClient` or an `Embedder`. A generic start/stop/base-address backend trait is a later question | `LlmClient`, `Embedder` |
| the hard-wired extraction prompt | replaced by a caller-supplied `ExtractionPrompt` | `ExtractionPrompt` |
| the "comms-only" third extraction mode | dropped from the vocabulary; a host that wants a metadata-only path registers its own `Extractor` | `Extractor` |
| the graph's resource-type registration | outside komira; it binds the spec to a host's resource catalog | `komira_kg_spec` exposes the spec only |
| reads of an environment variable (extraction mode, mail hook) | dropped; configuration is flags | a constructor argument or a string parsed from a flag |
| vendor-specific types pulled into generic modules (the raw store imports one adapter, the binding store another) | replaced by opaque strings and a registry | `AdapterRegistry` |
| a production call into a parquet test helper (in the store and the read path), and the temp files it forces | replaced by a public from-bytes reader in `komira_parquet` (PR 0 below) | none |
| spike, live and end-to-end tests that need a network, a credential or a local model | not ported; a test that needs a network or a credential does not belong in the build | none |

The seams, with the shape each has today in the source implementation (names in the first column are the
ported names):

| seam | kind | who implements it |
|---|---|---|
| `Embedder` | trait: embed a batch of strings, report its dimension | `StubEmbedder` (tests), `EmbeddingsWireEmbedder` (`komira_kg_llm`), a host |
| `LlmClient` | trait: extraction, contradiction and same-entity judgment, optional synthesis | `StubLlmClient` (tests), `ChatCompletionsLlmClient`, a host |
| `Extractor` | trait: text to an `Extraction` without inference | `RuleExtractor`, a host |
| `ExtractionPrompt` | value: system text, user template, optional type list, response schema | the caller |
| `ChatTransport`, `EmbedTransport` | traits: post a JSON body, return the body | scripted doubles (tests), the HTTP conformers in `komira_kg_llm`, a host |
| `AuthHeaderProvider` | trait: the authorization header for one outbound request | a host |
| `SurfaceAdapter` | trait: one source record to a list of `EpisodeInput`, carrying verbatim source text | a host; selected by an opaque surface tag through `AdapterRegistry` |
| `CaptureRoutes` | trait: register extra routes on the capture server over a loaded working set | a host |
| `CloneableConditionalWriteStore` | the object-store trait the lineage is written through | `komira_objectstore` (the in-memory and local-file stores in tests) |
| time | an `Int64` milliseconds argument, or the module's existing clock parameter | the caller; `komira_clock` in production, a constant in tests |
| `EnrichmentSender` | trait: deliver one enrichment item | `FakeEnrichmentSender` (tests), a host |
| `EndpointPolicy` | trait: may this inference endpoint be bound; allows everything by default | a host |

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
PR for either; they need an owner and an issue before PR 19. The engine dispatch, operator, compiler and
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
| 1 | `komira_kg_format` part 1: `embedding`, `ingest_types`, `manifest_body` | 1,100 | none (standard library only) | pack and unpack are inverses for f32 and f64; a corrupt manifest is refused; manifest encode and decode round trip with the format version (2, the only layout) and carry the embedding dimension |
| 2 | `komira_kg_format` part 2: `schemas`, `cosine`, `query_result` | 1,030 | part 1, `komira_arrow` and `komira_json` with their closure | every schema field and version is pinned by name; the embedding column takes its width from the dimension argument (two widths tested); the facet column holds any string; cosine of equal, orthogonal and zero vectors; top-k ties are ordered; result round trip with an arbitrary annotation kind and anchor |
| 3 | `komira_kg_format` part 3: `delta_body`, `delta_codec`, `source_fingerprint` | 1,280 | parts 1-2, parquet writer, objectstore | framed and parquet delta objects both decode; a fingerprint changes when one byte of content changes |
| 4 | `komira_kg_format` part 4: `snapshot_store` (974 lines; split into store, view and chain) | 980 | parts 1-3, objectstore | base then delta chain read back; a lost compare-and-set race is retried and reported; compaction folds and keeps the reader's pinned snapshot readable |
| 5 | `komira_kg_format` part 5: `search` (the two exact scans, `edge_out_degree`, `rrf_fuse`) | 350 | parts 2 and 4, PR 0 | similarity top-k equals `cosine_topk` over the same rows; full-text counts on stated rows; `rrf_fuse` on stated ranks; an empty table |
| 6 | `komira_kg` part 1: `bitemporal`, `alias_map`, `dedup`, source-facet helpers | 1,300 | `komira_kg_format` | an invalidation closes the overlapping edge and keeps the old system-time row; dedup matches, creates, or asks for judgment on stated inputs; alias resolution is stable under reordering; a tombstone for one source and facet leaves other facets of that source alone |
| 7 | `komira_kg` part 2: `Embedder`, `LlmClient`, `Extractor`, the stubs | 700 | part 1 | the stubs are deterministic and report their dimension; the stub extractor satisfies the trait |
| 8 | `komira_kg` part 3: `RuleExtractor`, `CursorStore` | 1,000 | PRs 6 and 7 | a rule set on fixed text yields fixed triples; a rule set is data (two sets give two vocabularies from the same code); a cursor survives a write-read and a conflicting writer |
| 9 | `komira_kg` part 4: `snapshot_mut` values and working set (the 2,045-line file is split here and in PR 10: values plus the working set, then erase, warm cache, compaction and embedding top-k) | 1,300 | PRs 4 and 6, PR 0 | a mutation reads back identically; a snapshot read sees one consistent set of tables |
| 10 | `komira_kg` part 5: erase, warm cache, compaction, embedding top-k | 620 | PR 9 | a mutation then compaction reads back identically before and after; compaction never deletes an object a pinned snapshot names; erasure of a partition removes every row and every embedding of it |
| 11 | `komira_kg` part 6: `ingest` episode path and entity resolution (the 1,717-line file is split here and in PR 12) | 900 | PRs 8 and 10 | one episode produces the expected nodes, edges and provenance; a write with the wrong embedding dimension is refused |
| 12 | `komira_kg` part 7: `ingest` structured path, gleaning, edge application, and the `SurfaceAdapter` trait | 900 | PR 11 | re-ingest of an unchanged source is a no-op by fingerprint; a contradiction supersedes; a test adapter for a made-up record type lowers to the expected episodes |
| 13 | `komira_kg_mode` | 140 | none | each mode name round trips; an unknown name falls back to rules; normalisation never yields model unless asked |
| 14 | `komira_kg_spec` (`graph_spec` and `GraphScopeRef`; the host resource-type registration is not ported) | 540 | PR 13 | each invalid spec is refused with its own message; a valid spec round trips; a scope of another owner is refused; the default endpoint policy allows and an injected one refuses |
| 15 | `komira_kg_llm`: transports, `EmbeddingsWireEmbedder`, `ChatCompletionsLlmClient` with `ExtractionPrompt`, `KgExtractClient` | 1,700 | PRs 7, 12 and 13, async, http client | against an in-process server: request shape, a non-200, a truncated body, the configured path and auth header; a response of the wrong dimension is refused; two different prompts reach the wire unchanged; the request-timeout value reaches the connector (the transport takes a timeout value, not a clock, so no test waits) |
| 16 | `komira_kg_sources`: `RawStore`, `PartitionBindingStore`, `AdapterRegistry`, `BIndex` | 1,300 | PR 12 | a raw record is stored once per content hash whatever its surface tag; a partition binds one store and one lineage; an unknown source system is refused against the host's set; the index returns the same top-k as a plain scan through two registered test adapters |
| 17 | `komira_kg_capture`: server and `CaptureRoutes` (the domain routes are split out of the server first) | 2,000 (two PRs) | PR 12 and PR 16, http server | a push to a registered surface becomes an episode and an unregistered surface is refused; the query surface answers from the warm cache and from the snapshot alike; extra routes are only reachable if registered; the server takes its clock as an argument |
| 18 | `komira_kg_enrich` with the `EnrichmentSender` trait | 1,150 | objectstore | an item is delivered at least once, and by one worker at a time only while that worker's lease holds; a failed delivery is retried by the scheduler's stated schedule; a second worker cannot drain while a lease is held |

That is 19 PRs for about 18,500 lines in this wave. PRs 1 to 4 are a chain; 5 needs PRs 2 and 4; 6 needs
PR 2; 13 needs nothing. After PR 2 the chain from 6 to 12 and the branches 13 and 18 run in parallel. The
core to land first is PRs 0 to 12 (format, store and ingest with their seams); the model clients, the
sources glue and the server follow. PRs 9, 11 and 17 have the largest source files (the capture server is 2,646 lines in the source, which is
why PR 17 is two PRs); the file split is real work inside the PR and is the reason for the larger sizes.

### Wave 1: the engine

| PR | contents | lines | waits for | tests that come with it |
|---|---|---:|---|---|
| 19 | `komira_kg_read`: `get_between_nodes`, `neighborhood`, `edges_as_of` | 400 | `EngineContext` in `sdk_exec`; `PlanCarrier` in `komira_sdk`; PR 5 | `neighborhood` and `get_between_nodes` on a fixed snapshot, including a node with no edges and a leaf guard; `edges_as_of` at an open interval's boundaries |
| 20 | the five engine tests of the source library, rewritten against package imports: CSR adjacency, between-nodes leaf guard, query surface, read off a snapshot, storage integration | tests only | PR 19 | these are the end-to-end checks of write then read |

### Not scheduled: connectors and adapters

The source library also holds connectors to external services (OAuth, provider and fetcher files, a sync
driver and a framework, about 25,000 lines) and adapters for particular document kinds and services. They
are application code and live outside komira (see the table above); no PR is scheduled. They use the seams
named in this document and depend on komira, never the reverse.

## How is it tested?

What each package's tests must prove, and the rules that apply to all of them:

| package | what the tests prove | defect each would catch |
|---|---|---|
| `komira_kg_format` | every encoding round trips; every version constant and schema is pinned; a corrupt or truncated input is refused with an error, never a partial value; the lineage survives a lost compare-and-set race | a format change that strands existing data; a reader that accepts garbage; a compaction that loses a delta |
| `komira_kg` | bi-temporal invariants (a superseded fact keeps its system-time row; no two open edges with the same key); ingest is idempotent per source fingerprint; erasure reaches rows, embeddings and fingerprints | a double-ingest; a contradiction that overwrites history; an erasure that leaves a copy |
| `komira_kg_mode`, `komira_kg_spec` | each validation rule has a test that fails alone; an unknown mode falls back to rules | a rule silently dropped; a mode that turns inference on by accident |
| `komira_kg_llm` | request and response shape against an in-process server; the prompt reaches the wire as given; failure paths | an unhandled non-200; a retry loop with no bound; a prompt baked into the client |
| `komira_kg_capture`, `komira_kg_sources`, `komira_kg_enrich` | output of test adapters for made-up record types; routes reachable only when registered; a queue item delivered and acked, a lease held by one worker, a pass that loses its lease stopping before the next delivery | an adapter that drops a field; an unauthenticated route; a surface tag that dispatches to the wrong adapter |
| `komira_kg_read` | each engine-run operation on a fixed snapshot; end-to-end write then read | a read that disagrees with what the writer stored |

Rules:

- No timing assertions. Every function that stamps or compares time takes the time as an argument (an
  `Int64` of milliseconds, or the module's clock parameter), so a test passes a constant and a timeout test
  advances an injected clock. A test that sleeps or reads the wall clock is refused in review. The capture
  server and the retry scheduler read time in the source and get a clock argument in their first PR. 11 of
  the 93 source test files read a clock or sleep (found by searching for sleep, monotonic, performance
  counter, wall-clock and `std.time` names); each is rewritten in the PR that brings the code it tests, and
  that PR's description names it.
- Test data is made up and domain-neutral (records of an invented kind); a test never needs a particular
  product's payload. A test that checks genericity uses two different vocabularies through the same code.
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
- No public knowledge-graph package names a vendor, a product, a model or a domain vocabulary in its code,
  its types or its docs. Entity types, predicates, facets and surface tags are opaque strings.

These are required properties of the port, each tested in the PR named, not claims about the source today.

- The lineage is append-only until compaction, and compaction never deletes an object a pinned snapshot
  still names (tested in PRs 4 and 10).
- A snapshot read sees one consistent set of tables: the manifest it pinned (PRs 4 and 9).
- The embedding dimension of a graph is written in its manifest (PR 1) and checked on every write (PR 11).
  The source schemas fix one dimension; taking the dimension from the manifest is a change made in these PRs.

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
4. **Fixed embedding dimension.** The source schemas fix one dimension. Recommended: no default; the writer
   takes the dimension, the manifest records it, and tests cover two dimensions.
5. **Are connectors and document adapters public?** No: they are application code and live outside komira.
   The core stands without them, and a small plain-transcript adapter may be added as an example of
   `SurfaceAdapter` if the maintainers want one.
6. **Task-tracker adapter.** Not ported: a ticket field set is a domain model. A host lowers its tasks to
   `EpisodeInput`.
7. **Is the resource reference in `komira_authz_api`?** No: `AuthzResource` has no organisation or owner,
   which the spec compares. Decided here, not left to PR 14: the spec defines `GraphScopeRef` and the
   binding to authorization is added with the authorization resource work.
8. **Naming against the code graph.** `komira_kg_code` and `komira_kg` read alike. Recommended: keep both,
   have each README link the other, and describe `komira_kg_code` as the "code graph" everywhere.
9. **Hooks into servers.** Recommended: leave hook traits to the server packages; adapters for them live
   outside komira.
10. **Welding order and the coverage policy.** Recommended: no PR lands untested code; where a source test
    needs a later package (the engine tests), the code lands with its own unit tests and the end-to-end test
    follows in the engine wave.
11. **Is the wave too many PRs?** It is 19 PRs for about 18,500 lines, each reviewable in one sitting.
    Recommended: keep it; the cost of a failed large port is higher than the cost of the count.
12. **Rule-driven extractor.** The source extractor fixes its entity vocabulary in code; `RuleExtractor` is
    a rewrite around a rule table, so PR 8 is new design and not a copy. Recommended: ship the neutral
    matchers only and let the first host's rule set live with the host.
13. **Process-spawning inference backends.** Not ported. Recommended: if a host needs one in komira, define
    a generic start, stop and base-address trait first and let the host bind engines to it.
14. **Capture format.** The server's capture route dispatches by surface tag to a registered adapter.
    Recommended: no built-in adapter beyond a plain transcript example.

Limits: the read path scales with the snapshot (an exact scan, no approximate nearest-neighbour index, as in
[data_graph_storage.md](data_graph_storage.md)); the capture server's warm cache is a single process; the
dedup scheme (MinHash with banded LSH) is tuned for names and short strings, not for long documents.

## Where is the code?

Parts 1 and 2 of `komira_kg_format` are in [`src/komira_kg_format/`](../../src/komira_kg_format/), part 1 of `komira_kg` is in [`src/komira_kg/`](../../src/komira_kg/) , `komira_kg_mode` is in [`src/komira_kg_mode/`](../../src/komira_kg_mode/) and `komira_kg_enrich` is in [`src/komira_kg_enrich/`](../../src/komira_kg_enrich/); every other location above is the one the package will have. Source sizes quoted are measured on the
source implementation; re-measure each before its PR, because a count carried in a design drifts.
