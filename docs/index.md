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
| Columnar memory: Arrow buffers, columns, batches, IPC and the C Data Interface | [design/columnar_memory_and_arrow.md](design/columnar_memory_and_arrow.md) |
| Mojo safety: pointers, origins and the Mojo 1.0 spellings | [design/mojo_safety_and_idioms.md](design/mojo_safety_and_idioms.md) |
| The cryptographic primitives over AWS-LC, and certificate chain validation | [design/crypto_and_tls.md](design/crypto_and_tls.md) |

## Design docs

Each design doc covers one subsystem: what it is for, how it works, why it is
built that way, what must always hold, where the code is, how it is tested,
and its limits. A family's doc lands together with the libraries it describes.

| Family | Docs |
|---|---|
| core | [columnar memory and Arrow](design/columnar_memory_and_arrow.md) |
| cross-cutting | [Mojo safety and idioms](design/mojo_safety_and_idioms.md) |
| connectors | [crypto](design/crypto_and_tls.md); HTTP, databases, object stores, file-system discovery, and protobuf and gRPC: coming with `komira_http`, `komira_db`, `komira_objectstore` and `komira_grpc` |
| storage | compression codecs, Parquet, text and row formats, Iceberg and CDC, an MVCC table store: coming with `komira_parquet`, `komira_csv`, `komira_iceberg` and `komira_table_store` |
| execution and operators | pipelines and morsel dispatch, aggregation, joins, sort, top-N and window: coming with the engine libraries |
| plan and optimizer | logical plans and expressions, physical planning, the plan wire format, the query optimizer: coming with `komira_compiler` and `komira_optimizer` |
| SDK and SQL | the plan-carrier surface, UDFs, the Python package, the SQL front ends: coming with `komira_sdk` |
| runtime | the async runtime, the job agent and supervisor: coming with `komira_async` and `komira_agent` |
| observability | logging and telemetry: coming with `komira_log` |
| agents | MCP and local models: coming with `komira_mcp_server` and `komira_localmodel` |
| cloud | AWS clients, cloud credentials, infrastructure providers, secrets and service registry, deploy marks: coming with the cloud SDK libraries |
| CI and deploy | the bundle model, apply, validate and rollout, the `kci` command line: coming with `kci` |
| packaging | the shared-library ABI, the release train: coming with `komira_so` and the packaging rules |
