# Knowledge graph

There is no knowledge graph in this repository yet. It returns after the core
libraries have moved here, as a Mojo tool built with Buck2 and shipped as a
pinned prebuilt binary, which a git hook then runs; the build and its tooling
use no Python.

Its source of a library's declarations is in place: the build rule
[`mojo_doc_json`](../tools/build/mojo/doc.md) runs
the pinned compiler's `mojo doc` on a library and makes the JSON a build
output. That JSON holds no source locations.

The library [`komira_kg_code`](../src/komira_kg_code/) derives the graph's nodes
and edges from that JSON, `buck2 uquery` JSON, the import lines of the
sources and the `governs:` front matter of documents. Nothing stores or
queries them yet.

Until then, the build graph itself answers what the graph would:

```sh
./buck2 cquery 'rdeps(//..., //tools/build/examples:hellopkg)'   # what depends on a target
./buck2 uquery 'owner(tools/build/examples/hello.mojo)'          # which target lists a file
```

The code graph described above needs no change to the search index format. How
a graph over data (nodes, edges and episodes) would be stored, as Iceberg tables
with a delta tail and derived indexes rather than as `komira_search` splits, is
proposed in [design/data_graph_storage.md](design/data_graph_storage.md);
the search format changes it could need are proposed in
[design/search_index_format.md](design/search_index_format.md).
