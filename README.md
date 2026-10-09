# komira

komira is written in [Mojo](https://www.modular.com/mojo) and built with
[Buck2](https://buck2.build) and a hermetic toolchain: the Mojo compiler, zig
and the file utilities every action uses are pinned downloads.

> **Supported today: Linux x86_64.** A fresh clone builds on that machine
> with no build service. Native builds on macOS (Apple silicon) and Linux
> arm64 are being added: a Mac will build on its own, with no build service.
> Until then, on a Mac you can install and run `./buck2` and read the code.

The build tooling (Mojo rules, a hermetic toolchain, execution platforms,
examples and end-to-end tests) lives in [`tools/build/`](tools/build/).

## Quickstart

On Linux x86_64, with `curl` and `zstd` installed:

```sh
./buck2 run //tools/build/examples:hello     # build on this machine, run here
./buck2 build //...                          # build every target, welded tests and lints included
```

[`./buck2`](buck2) fetches the buck2 release pinned in [`tools/buck2`](tools/buck2)
once, verifies it, and caches it under `~/.cache/komira/buck2/`.

On one Linux x86_64 workstation, from a clean checkout, `hello` took 23 seconds
including the toolchain download, one library and its tests 5 seconds, and
`//src/...` about 10 minutes; see
[what a local build guarantees](DEVELOPMENT.md#what-a-local-build-guarantees).
Step by step: [getting started](docs/getting-started.md).

[DEVELOPMENT.md](DEVELOPMENT.md) explains each step, what a local build does
and does not guarantee (Buck2 does not sandbox local actions), how to run the checks, an optional section for people who run a
remote-execution service, and what to do when something goes wrong.

## Documentation

| read | for |
|---|---|
| [DEVELOPMENT.md](DEVELOPMENT.md) | developer setup: `./buck2` and the pinned release, local builds and what they guarantee, running the checks, remote execution for those who run a service, the host floor, caching, troubleshooting |
| [tools/build/README.md](tools/build/README.md) | a map of the build tooling, and how another repository uses komira, as a git external cell or a submodule |
| [tools/build/mojo/README.md](tools/build/mojo/README.md) | the Mojo rules: `mojo_library`, `mojo_binary`, `mojo_test` |
| [tools/build/platforms/README.md](tools/build/platforms/README.md) | target platforms, execution platforms and toolchain selection; local or remote execution |
| [tools/build/package/README.md](tools/build/package/README.md) | packaging: `mojo_bundle`, a relocatable bundle with a CPU-level launcher; `bundle_tarball` and `oci_image` |
| [packaging/conda/README.md](packaging/conda/README.md) | the Mojo libraries as conda packages: layout, version scheme, the metapackage; nothing is uploaded and no list of names is kept in the build |
| [tools/build/toolchains/README.md](tools/build/toolchains/README.md) | the hermetic toolchain: what is pinned, the host floor, updating a pin |
| [tools/build/tests/README.md](tools/build/tests/README.md) | the end-to-end tests: what each one proves and how to run it |
| [docs/ci.md](docs/ci.md) | continuous integration: one job on a runner on the build farm, approving a fork's run, what a contributor runs locally |
| [docs/knowledge_graph.md](docs/knowledge_graph.md) | the knowledge graph: not here yet (it returns as a Mojo tool) |
| [docs/index.md](docs/index.md) | the canonical docs, and what each is the authority for |
| [tools/build/examples/](tools/build/examples/) | small targets using each rule |
| [DEVELOPMENT.md#repository-layout](DEVELOPMENT.md#repository-layout) | the repository layout: every Mojo module komira ships directly under `src/`, test-only packages under `src/tests/`, tooling in `tools/` |
| [third_party/](third_party/) | C and C++ libraries built from pinned source archives, for Mojo code to call |

## License

[Apache License 2.0](LICENSE).
