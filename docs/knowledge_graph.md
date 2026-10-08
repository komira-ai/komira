# Knowledge graph

There is no knowledge graph in this repository yet. It returns after the core
libraries have moved here, as a Mojo tool built with Buck2 and shipped as a
pinned prebuilt binary, which a git hook then runs; the build and its tooling
use no Python.

Until then, the build graph itself answers what the graph would:

```sh
./buck2 cquery 'rdeps(//..., //tools/build/examples:hellopkg)'   # what depends on a target
./buck2 uquery 'owner(tools/build/examples/hello.mojo)'          # which target lists a file
```

The changes the graph will need from the search index format are proposed in
[design/search_index_format.md](design/search_index_format.md).
