# Documentation index

The canonical docs: each row names what one doc is the authority FOR. When a doc and the code
disagree, the code is what runs; when two docs disagree, the one listed here wins for its row.

| Authority for | Doc |
|---|---|
| What komira is, and the map of its docs | [README.md](../README.md) |
| Developer setup: buck2, the build farm, running the tests | [DEVELOPMENT.md](../DEVELOPMENT.md) |
| The build tooling, and using komira from another repository | [tools/build/README.md](../tools/build/README.md) |
| The Mojo rules | [tools/build/mojo/README.md](../tools/build/mojo/README.md) |
| The end-to-end tests | [tools/build/tests/README.md](../tools/build/tests/README.md) |
| README API coverage: which public symbols the README examples use, its ledger, and the census | [readme_api_coverage.md](readme_api_coverage.md) |
| Product coverage: which plan capability each surface's end-to-end tests exercise, the matrix ledger, and the census | [surface_capability_matrix.md](surface_capability_matrix.md) |
| Continuous integration: the one job, the runner on the farm, approving a fork's run, farm access | [ci.md](ci.md) |
| The knowledge graph: not here yet, and what replaces it until then | [knowledge_graph.md](knowledge_graph.md) |
| Columnar memory: Arrow buffers, columns, batches, IPC and the C Data Interface | [design/columnar_memory_and_arrow.md](design/columnar_memory_and_arrow.md) |
| Mojo safety: pointers, origins and the Mojo 1.0 spellings | [design/mojo_safety_and_idioms.md](design/mojo_safety_and_idioms.md) |
| The cryptographic primitives over AWS-LC, and certificate chain validation | [design/crypto_and_tls.md](design/crypto_and_tls.md) |
| The async runtime: the reactor, per-worker event loops and wakes, fork-join dispatch, spawned tasks and join handles, waiting on I/O as explicit state machines, cooperative cancellation, and the Runtime trait and its conformers | [design/async_runtime.md](design/async_runtime.md) |
| Databases: the backend-neutral Database trait and its operations, row types, SQL rendering, pools, migrations, and the SQLite and Postgres drivers | [design/databases.md](design/databases.md) |
| HTTP: the HTTP/1.1 and HTTP/2 client and server on one reactor, request parsing and response framing, middleware and routing, gRPC serving, connection pooling and reuse, outbound time budgets, and TLS over s2n-tls | [design/http.md](design/http.md) |
| HTTP authentication and authorization: bearer-JWT verification and trust anchors, JWK Set fetching, the `Principal`, client credentials, the remote decision point (AuthZEN) contract and its safety conditions, the decision cache, the flags and the 401/403/503 failure modes | [design/http_auth.md](design/http_auth.md) |
| Object storage: store traits and conditional writes, local and in-memory stores, the CAS manifest and the primitives built on it, the presigned-URL seam | [design/object_store.md](design/object_store.md) |
| Protobuf and gRPC: .proto-to-Mojo code generation, protobuf wire primitives and proto3 JSON codecs, well-known types, the gRPC and Connect client and its retries, the Connect server | [design/protobuf_grpc_and_codegen.md](design/protobuf_grpc_and_codegen.md) |
| Text and row formats: reading and writing CSV, Avro and ORC files (CSV dialects and schema inference, parallel decode, per-format compression framing, ORC skipping) and the XML codec | [design/text_and_row_formats.md](design/text_and_row_formats.md), [schemas, codecs and skipping](design/text_and_row_formats/schemas_codecs_and_skipping.md) |
| The search index format and the changes a graph store needs (proposed, not built): several fields per document, per-document deletes and compaction, a vector region, adjacency | [design/search_index_format.md](design/search_index_format.md) |
| Storing a graph over data (proposed, not built): Iceberg tables with a delta tail and derived CSR, text and vector indexes, the earlier comparison with search splits, and how other systems store knowledge graphs | [design/data_graph_storage.md](design/data_graph_storage.md) |
| Shuffle through an object store: hash partitioning, map segments, the seal that closes the map phase, claiming and reading reduce partitions exactly once, and reaping epochs below the slowest consumer | [design/shuffle.md](design/shuffle.md) |
| Logging, spans and metrics: record rings and drains, log levels, sinks, EXPLAIN ANALYZE and series metrics, and the access-gated log and metrics read routes | [design/logging_and_telemetry.md](design/logging_and_telemetry.md) |
| Why the build is shaped this way: pinned tools as action inputs, the compiler wrapper and its watchdog, the fixed target CPU, whole-closure deps, vendored C and C++ libraries, one execution platform per OS | [design/mojo_rules_and_toolchain.md](design/mojo_rules_and_toolchain.md) |
| Why the build is the gate: a library's test_srcs gate its published package, the staged test environment, and the build lints as validations (shell, workflows, action pins, endpoints, doc links) | [design/gates_test_welding_and_lints.md](design/gates_test_welding_and_lints.md) |
| Release machines: bundles, tarballs and OCI images of a program, the CPU-level launcher, reproducible outputs, komira's release stages and validations | [design/release_machine.md](design/release_machine.md) |
| The staged pipeline (design, not built): build once, then beta (end-to-end suites and installs of the built files), gamma and prod, each stage one run at a time with the latest commit winning, never backward at any stage; supersedes continuous publish's per-merge trigger, its release-duration arithmetic and the placement of its S10c and S12 gates | [design/staged_pipeline.md](design/staged_pipeline.md) |
| Gamma validation per package family: what checks a release before prod, where each check runs (in-process, loopback, per-test service, the installed package), what it catches and misses, and its gaps | [design/gamma_validation.md](design/gamma_validation.md) |
| What kci must add before gamma can run a service validation, and the open decisions on gamma validation, each with a recommendation | [design/gamma_validation_decisions.md](design/gamma_validation_decisions.md) |
| kci resource-model decision notes: an encryption key as a resource; importing and changing a network on any cloud; overrides, the escape hatch for what is cloud-specific | [design/kci_encryption_keys.md](design/kci_encryption_keys.md), [design/kci_networks_import_and_change.md](design/kci_networks_import_and_change.md), [design/kci_overrides.md](design/kci_overrides.md) |
| Continuous publish (design, not built): every package built, published to the beta channel, tested there and promoted to prod (the words as the staged pipeline's glossary defines them); the release ledger, the emulator test tier and synthetic fixture tests for the cloud SDK at no cloud cost, the safety rules, yank, and the rollout | [design/continuous_publish.md](design/continuous_publish.md) |
| The DEPLOY step (design, not built): cells, plan and apply from `kci run`, the GCP adapter, images published into a cell and promoted by digest, the `DEPLOY_PROBE` validation, one run at a time per cell | [design/deploy_step.md](design/deploy_step.md) |
| Contacts and CRM (design, not built): address books, cards and contact groups modelled after Outlook and Apple Contacts, the CRM entities, the stored rows, keys and uniqueness, the change feed, erasure, and the authorization resource kinds | [design/contacts_and_crm.md](design/contacts_and_crm.md) |

## Design docs

Each design doc covers one subsystem: what it is for, how it works, why it is
built that way, what must always hold, where the code is, how it is tested,
and its limits. A family's doc lands together with the libraries it describes;
"no design doc yet" marks a subsystem whose libraries are here and whose doc is not.

| Family | Docs |
|---|---|
| core | [columnar memory and Arrow](design/columnar_memory_and_arrow.md) |
| cross-cutting | [Mojo safety and idioms](design/mojo_safety_and_idioms.md) |
| build | [the Mojo rules and toolchain](design/mojo_rules_and_toolchain.md), [build gates, test welding and lints](design/gates_test_welding_and_lints.md) |
| connectors | [crypto](design/crypto_and_tls.md), [databases](design/databases.md), [HTTP](design/http.md), [HTTP authentication and authorization](design/http_auth.md), [object stores](design/object_store.md), [protobuf, gRPC and code generation](design/protobuf_grpc_and_codegen.md); file-system discovery: no design doc yet |
| storage | [text and row formats](design/text_and_row_formats.md) (CSV, Avro, ORC, XML); compression codecs, Parquet, Iceberg, an MVCC table store: no design doc yet; CDC: coming with its library |
| execution and operators | [shuffle through an object store](design/shuffle.md); pipelines and morsel dispatch, aggregation, joins, top-N and the kernels: no design doc yet; sort and window: coming with the engine libraries |
| search | [the search index format](design/search_index_format.md) (the format today, and proposed changes; not built); [storing a graph over data](design/data_graph_storage.md) (proposed, not built) |
| plan and optimizer | logical plans and expressions, physical planning, the plan wire format: no design doc yet; the query optimizer: coming with `komira_optimizer` |
| SDK and SQL | UDFs, the SQL lexer and syntax tree (`komira_sql`): no design doc yet; the plan-carrier surface, the Python package: coming with `komira_sdk`; the SQL parser and binder: coming with `komira_sql` |
| runtime | [the async runtime](design/async_runtime.md); the job supervisor and its job report wire: no design doc yet |
| observability | [logging and telemetry](design/logging_and_telemetry.md) |
| agents | MCP and local models: coming with `komira_mcp_server` and `komira_localmodel` |
| cloud | the AWS, GCP and Azure clients and their credentials and secrets: no design doc yet; deploy marks: coming with the cloud SDK libraries |
| CI and deploy | [the DEPLOY step](design/deploy_step.md) (cells, plan and apply, the GCP adapter, images into a cell, deploy probes; design, not built); the resource model's open decisions: [encryption keys](design/kci_encryption_keys.md), [importing and changing networks](design/kci_networks_import_and_change.md), [overrides](design/kci_overrides.md); the `kci` command line, the resource model and its cloud providers, apply, validate and rollout: no design doc yet ([release machines](design/release_machine.md) covers komira's own release stages; [continuous publish](design/continuous_publish.md) how every package reaches prod; [gamma validation](design/gamma_validation.md) what gamma checks per package family) |
| packaging | [release machines: bundles, tarballs and OCI images](design/release_machine.md); the shared-library ABI: coming with `komira_so` |
| applications | [contacts and CRM](design/contacts_and_crm.md) (design, not built) |
