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
| Continuous integration: the one job, the runner on the farm, approving a fork's run, farm access | [ci.md](ci.md) |
| The knowledge graph: not here yet, and what replaces it until then | [knowledge_graph.md](knowledge_graph.md) |
| The architecture: the module map of `src/`, how the build welds tests and lints, the layers still to come | [architecture.md](architecture.md) |
| A first build: clone, build a library with its tests, add a library, where docs go | [getting-started.md](getting-started.md) |
| Releases: what komira publishes and how another repository pins it | [releases.md](releases.md) |
| Columnar memory: Arrow buffers, columns, batches, IPC and the C Data Interface | [design/columnar_memory_and_arrow.md](design/columnar_memory_and_arrow.md) |
| Mojo safety: pointers, origins and the Mojo 1.0 spellings | [design/mojo_safety_and_idioms.md](design/mojo_safety_and_idioms.md) |
| The cryptographic primitives over AWS-LC, and certificate chain validation | [design/crypto_and_tls.md](design/crypto_and_tls.md) |
| Packaging: bundles, tarballs and OCI images of a Mojo program | [design/release_train.md](design/release_train.md) |
| Why the Mojo rules and toolchain are built the way they are: pinned tools, the wrapper, the watchdog, vendored C | [design/mojo_rules_and_toolchain.md](design/mojo_rules_and_toolchain.md) |
| Why a test gates a published package, and how the lints and the doc-link check are built | [design/gates_test_welding_and_lints.md](design/gates_test_welding_and_lints.md) |
| The backend-neutral `Database` interface, its SQLite and Postgres drivers, and the Postgres client | [design/databases.md](design/databases.md) |
| The CSV, Avro, ORC and XML readers and writers: schemas, parallel decode, codecs and ORC skipping | [design/text_and_row_formats.md](design/text_and_row_formats.md), [schemas, codecs and skipping](design/text_and_row_formats/schemas_codecs_and_skipping.md) |
| Protobuf, gRPC and code generation: the `.proto`-to-Mojo plugins, the protobuf and proto3-JSON codecs, the gRPC and Connect client and server | [design/protobuf_grpc_and_codegen.md](design/protobuf_grpc_and_codegen.md) |
| HTTP/1.1 and HTTP/2 client and server on one reactor, the middleware chain, routing, client pooling and budgets, and the s2n-tls layer | [design/http.md](design/http.md) |
| Object storage: the store traits, the CAS manifest and the shuffle primitives over conditional writes | [design/object_store.md](design/object_store.md) |
| The async runtime: the reactor, per-worker event loops, fork-join dispatch, spawn and join | [design/async_runtime.md](design/async_runtime.md) |
| Logging, spans and metrics: the record rings, the drains and sinks, and the read seam over a service's own log | [design/logging_and_telemetry.md](design/logging_and_telemetry.md) |

## Design docs

Each design doc covers one subsystem: what it is for, how it works, why it is
built that way, what must always hold, where the code is, how it is tested,
and its limits. A family's doc lands together with the libraries it describes.

| Family | Docs |
|---|---|
| core | [columnar memory and Arrow](design/columnar_memory_and_arrow.md) |
| build | [Mojo rules and toolchain](design/mojo_rules_and_toolchain.md), [build gates, test welding and lints](design/gates_test_welding_and_lints.md) |
| cross-cutting | [Mojo safety and idioms](design/mojo_safety_and_idioms.md) |
| connectors | [crypto](design/crypto_and_tls.md), [databases](design/databases.md), [HTTP](design/http.md), [object stores](design/object_store.md), [protobuf, gRPC and code generation](design/protobuf_grpc_and_codegen.md); file-system discovery: coming with its library |
| storage | [text and row formats](design/text_and_row_formats.md) (CSV, Avro, ORC, XML; JSON lines coming with `komira_jsonl`); compression codecs, Parquet, Iceberg and CDC, serverless Postgres: coming with `komira_parquet`, `komira_iceberg` and `komira_pgstore` |
| execution and operators | pipelines and morsel dispatch, aggregation, joins, sort, top-N and window: coming with the engine libraries |
| plan and optimizer | logical plans and expressions, physical planning, the plan wire format, the query optimizer: coming with `komira_compiler` and `komira_optimizer` |
| SDK and SQL | the plan-carrier surface, UDFs, the Python package, the SQL front ends: coming with `komira_sdk` |
| runtime | [the async runtime](design/async_runtime.md); the job agent and supervisor: coming with `komira_agent` |
| observability | [logging, spans and metrics](design/logging_and_telemetry.md) |
| agents | MCP and local models: coming with `komira_mcp_server` and `komira_localmodel` |
| cloud | AWS clients, cloud credentials, infrastructure providers, secrets and service registry, deploy marks: coming with the cloud SDK libraries |
| CI and deploy | the bundle model, apply, validate and rollout, the `kci` command line: coming with `kci` |
| packaging | [bundles, tarballs and OCI images](design/release_train.md); the shared-library ABI: coming with `komira_so` |
