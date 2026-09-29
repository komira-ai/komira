# Documentation index

The canonical docs: each row names what one doc is the authority FOR. When a doc and the code
disagree, the code is what runs; when two docs disagree, the one listed here wins for its row.
`tools/kg` indexes this table into `docs/kg/docs_graph.json` and refuses a row whose link is
dead.

| Authority for | Doc |
|---|---|
| What komira is, and the map of its docs | [README.md](../README.md) |
| Developer setup: buck2, the build farm, running the checks | [DEVELOPMENT.md](../DEVELOPMENT.md) |
| The build tooling, and using komira from another repository | [tools/build/README.md](../tools/build/README.md) |
| The Mojo rules | [tools/build/mojo/README.md](../tools/build/mojo/README.md) |
| The end-to-end checks | [tools/build/checks/README.md](../tools/build/checks/README.md) |
| Continuous integration: the workflows, farm access, secrets | [ci.md](ci.md) |
| The knowledge graph: what is indexed, the hooks, the CI check | [knowledge_graph.md](knowledge_graph.md) |
| The `kg` command and the library-page contract | [tools/kg/README.md](../tools/kg/README.md) |
