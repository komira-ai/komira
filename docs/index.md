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
| Logging, spans and metrics: the record rings, the drains and sinks, and the read seam over a service's own log | [design/logging_and_telemetry.md](design/logging_and_telemetry.md) |
