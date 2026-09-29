# komira

komira is written in [Mojo](https://www.modular.com/mojo) and built with
[Buck2](https://buck2.build) and a hermetic toolchain: the Mojo compiler, zig
and the file utilities every action uses are pinned downloads. A fresh clone
builds on your own Linux x86_64 machine by default (see
[DEVELOPMENT.md](DEVELOPMENT.md#what-a-local-build-guarantees) for what has
been checked locally so far).
If you have a remote-execution service that speaks the Bazel Remote Execution
API, such as Buildbarn, you can opt in to building there instead.

The build tooling (Mojo rules, a hermetic toolchain, execution platforms,
examples and end-to-end checks) lives in [`tools/build/`](tools/build/).

## Quickstart

On Linux x86_64, with [dotslash](https://dotslash-cli.com) installed:

```sh
tools/buck2 run //tools/build/examples:hello     # build on this machine, run here
tools/buck2 build //...                          # build every target, on this machine
```

A local Mojo compile has not yet been measured: so far these commands have
run only against a remote-execution service
([DEVELOPMENT.md](DEVELOPMENT.md#what-a-local-build-guarantees)).

To build on a remote-execution service instead (from any machine buck2 runs
on), copy `.buckconfig.local.example` to `.buckconfig.local` and fill in your
service and its worker properties; the same commands then run every action
there.

[DEVELOPMENT.md](DEVELOPMENT.md) explains each step, what a local build does
and does not guarantee (Buck2 does not sandbox local actions), what to put in
`.buckconfig.local`, and what to do when something goes wrong.

## Documentation

| read | for |
|---|---|
| [DEVELOPMENT.md](DEVELOPMENT.md) | developer setup: the pinned buck2, local builds and what they guarantee, `.buckconfig.local` and a remote-execution service, running the checks, the host floor, caching, troubleshooting |
| [tools/build/README.md](tools/build/README.md) | a map of the build tooling, and how another repository uses komira, as a git external cell or a submodule |
| [tools/build/mojo/README.md](tools/build/mojo/README.md) | the Mojo rules: `mojo_library`, `mojo_binary`, `mojo_test`, `mojo_multi_numa_test` |
| [tools/build/platforms/README.md](tools/build/platforms/README.md) | execution classes, single- and multi-NUMA workers, mapping them to your own worker pools |
| [tools/build/package/README.md](tools/build/package/README.md) | packaging: `mojo_bundle`, a relocatable bundle with a CPU-level launcher; `bundle_tarball` and `oci_image` |
| [tools/build/toolchains/README.md](tools/build/toolchains/README.md) | the hermetic toolchain: what is pinned, the host floor, updating a pin |
| [tools/build/checks/README.md](tools/build/checks/README.md) | the end-to-end checks: what each one proves and how to run it |
| [docs/ci.md](docs/ci.md) | continuous integration: the static and farm jobs, how CI reaches the farm, secrets and log redaction |
| [docs/knowledge_graph.md](docs/knowledge_graph.md) | the committed knowledge graph (library pages, docs graph, Buck2 graph), its git hooks and CI check |
| [docs/index.md](docs/index.md) | the canonical docs, and what each is the authority for |
| [tools/build/examples/](tools/build/examples/) | small targets using each rule |
| [third_party/](third_party/) | C and C++ libraries built from pinned source archives, for Mojo code to call |

## License

[Apache License 2.0](LICENSE).
