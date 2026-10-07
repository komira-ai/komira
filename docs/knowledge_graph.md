# Knowledge graph

There is no knowledge graph in this repository yet. It returns after the core
libraries have moved here, as a Mojo tool built with Buck2 and shipped as a
pinned prebuilt binary, which a git hook then runs; the build and its tooling
use no Python.

Its source of a library's declarations is in place: the build rule
[`mojo_doc_json`](../tools/build/mojo/README.md#api-json-mojo_doc_json) runs
the pinned compiler's `mojo doc` on a library and makes the JSON a build
output. That JSON holds no source locations.

Until then, the build graph itself answers what the graph would:

```sh
./buck2 cquery 'rdeps(//..., //tools/build/examples:hellopkg)'   # what depends on a target
./buck2 uquery 'owner(tools/build/examples/hello.mojo)'          # which target lists a file
```
