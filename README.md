# komira

komira is written in [Mojo](https://www.modular.com/mojo) and built with
[Buck2](https://buck2.build) on remote execution: every action (unpacking the
toolchain, compiling, running tests) runs on a remote-execution service that
speaks the Bazel Remote Execution API, such as Buildbarn. Nothing is compiled
on your machine. The build tooling (Mojo rules, a hermetic toolchain, execution
platforms, examples and end-to-end checks) lives in [`tools/build/`](tools/build/).

## Quickstart

On Linux x86_64, with [dotslash](https://dotslash-cli.com) installed and a
remote-execution service to point at:

```sh
cp .buckconfig.local.example .buckconfig.local   # then fill in your service and worker properties
tools/buck2 build //...                          # build every target, remotely
tools/buck2 run //tools/build/examples:hello     # build remotely, run here
```

[DEVELOPMENT.md](DEVELOPMENT.md) explains each step, what to put in
`.buckconfig.local`, and what to do when something goes wrong.

## Documentation

| read | for |
|---|---|
| [DEVELOPMENT.md](DEVELOPMENT.md) | developer setup: the pinned buck2, `.buckconfig.local` and your build farm, running the checks, the host floor, caching, troubleshooting |
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
