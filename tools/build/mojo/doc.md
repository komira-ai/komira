# API JSON: mojo_doc_json

The rule is in [`doc.bzl`](doc.bzl); the other Mojo rules are in [README.md](README.md).

```python
load("@komira//tools/build/mojo:doc.bzl", "mojo_doc_json")

mojo_doc_json(
    name = "hellopkg_doc",
    lib = ":hellopkg",
    golden = "hellopkg_doc.json",      # optional
    symbols = ["greet.greeting"],      # optional
)
```

- **What runs.** The pinned compiler's `mojo doc`, through
  [`mojo_wrapper.sh`](mojo_wrapper.sh) like every compile (the same
  environment, the watchdog, and the refusal of an empty output or one
  holding the action's working directory), on the library's staged sources
  (its `[src]`), with the packages of its `deps` on `-I`. The library's own
  package is not an input, so the JSON does not wait for its welded tests. A
  source that does not compile fails the target: `mojo doc` exits 1 with
  `could not generate documentation` after the compiler's error.
- **What the JSON holds** (mojo 1.0.0): the package, its modules (a
  package's `__init__.mojo` is the module `__init__`) and subpackages, and
  per module its functions, structs, traits and aliases, with signatures,
  parameters, argument lists and doc strings. It holds **no source
  location**, and no declaration whose name starts with `_` (a struct's
  dunder methods excepted). [`hellopkg_doc.json`](../examples/hellopkg_doc.json)
  is a whole one.
- **`golden`**: the JSON must equal this file byte for byte, else
  `mojo_doc_json: <target>: the JSON differs from its golden <file>` and the
  first differences. The golden pins the bytes: an output that varied by
  worker or run would differ from it whenever the action runs again. A
  compiler bump that changes the JSON changes the golden in the same commit.
- **`symbols`**: each entry is a declaration's dotted path inside the
  package: `<module>.<name>`, `<module>.<struct or trait>.<method>`, a
  subpackage's name first (`sub.leaf.leaf_value`). The check reads the JSON
  with [`//tools/build/inspect`](../inspect/BUCK) (`inspect json`), not by
  matching text; a missing one fails with
  ``mojo_doc_json: <target>: the JSON declares no `<path>` ``, one line per
  path.
- With either check, `[raw]` is the unchecked JSON.

Test 52 ([`tests/README.md`](../tests/README.md#52-api-json-mojo_doc_json))
covers both checks and a source that does not compile:
[`functional/mojo_doc_json`](../tests/functional/mojo_doc_json/BUCK) must build
and each target of [`negative/mojo_doc_json`](../tests/negative/mojo_doc_json/BUCK)
must fail naming its defect. Test 1 builds `hellopkg_doc`, so the example's JSON
equals its golden.

```sh
./buck2 build tests//functional/mojo_doc_json:docpkg_doc
./buck2 build tests//negative/mojo_doc_json:compile_error    # must fail: could not generate documentation
./buck2 build tests//negative/mojo_doc_json:golden_differs   # must fail: the JSON differs from its golden
./buck2 build tests//negative/mojo_doc_json:missing_symbol   # must fail: the JSON declares no `shout`
```
