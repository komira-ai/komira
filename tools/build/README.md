# Build tooling

Everything the build needs besides the project configuration
([`.buckconfig`](../../.buckconfig)) and the pinned buck2
([`tools/buck2`](../buck2), run through [`./buck2`](../../buck2)) lives here. Setup and day-to-day use are in
[DEVELOPMENT.md](../../DEVELOPMENT.md).

| directory | Buck2 name | what it holds |
|---|---|---|
| [`mojo/`](mojo/) | package `komira//tools/build/mojo` | the Mojo rules (`mojo_library`, `mojo_binary`, `mojo_test`, `mojo_proto_library`, `mojo_db_proto_library`, `mojo_routes_proto_library`), `proto_fixture_check` and `proto_encode` (protoc reading and writing wire fixtures; their welded self-test is the package `mojo/proto_fixture_testdata`), the toolchain rules, and the scripts their actions run. [Reference](mojo/README.md). |
| [`toolchains/`](toolchains/) | package `komira//tools/build/toolchains` | the sha256-pinned downloads and the hermetic Mojo toolchain built from them. [Reference](toolchains/README.md). |
| [`platforms/`](platforms/) | package `komira//tools/build/platforms` | the target platform, the execution constraints and configurations, and `komira_execution_platforms`; [`platforms/default/`](platforms/default/) registers a standalone checkout's execution platforms: local, or remote when `.buckconfig.local` names a service. [Reference](platforms/README.md). |
| [`rust/`](rust/) | package `komira//tools/build/rust` | the Rust rules (`rust_library`, `rust_binary`, `crates_io_library`) and the rustc toolchain rule. [Reference](rust/README.md). |
| [`proto-codegen/`](proto-codegen/) | package `komira//tools/build/proto-codegen` | the `komira_proto_codegen` crate with `protoc-gen-mojo` and `protoc-gen-mojo-db`, the protoc plugins of `mojo_proto_library` and `mojo_db_proto_library`; `protoc-gen-mojo-routes`, the plugin of `mojo_routes_proto_library`, kept out of that crate so it changes alone ([Reference](proto-codegen/routes/README.md); its fixture and welded tests are in `proto-codegen/routes/`); and `:db_options`, the `(komira.db.*)` options (see [Protobuf](mojo/README.md#protobuf-mojo_proto_library)); `aws-client-gen`, the AWS client generator, published behind `:aws_conformance_test`, which runs botocore's protocol conformance corpus against the generated Mojo and checks the result against `aws_conformance_ledger.txt`. |
| [`lint/`](lint/) | package `komira//tools/build/lint` | lints that are part of the build: `shell_lint`, `workflow_lint`, `action_pins`, `no_endpoint` and `mojo_deps` (the `deps` of a Mojo package name every module its files import) return their verdict as a Buck2 validation, and the pinned shellcheck and actionlint. The Mojo and Rust toolchains depend on the lint of the scripts their rules run; the root [`BUCK`](../../BUCK) lints the top-level scripts and the workflows. |
| [`inspect/`](inspect/) | package `komira//tools/build/inspect` | `buildtools`, a Mojo package of readers the tools share (SHA-256, JSON, tar members, Mach-O load commands, Markdown links; its unit tests are welded), and `inspect`, the Mojo tool the [checks](tests/README.md) run for every structured read ([`inspect.mojo`](inspect/inspect.mojo)). |
| [`coverage/kcov/`](coverage/kcov/) | package `komira//tools/build/coverage/kcov` | the static tools of a coverage build: `debug_relocate` (a directory in a binary overwritten by a placeholder of the same length), `cov_normalize` (a kcov report rewritten to repository paths), `cov_zig` and `cov_link`, the link directory a `mojo_library`'s coverage build links through ([Coverage builds](mojo/README.md#coverage-builds)), each gated by cases run as build actions; and `cov_run.sh` with `cov_run`, which runs one test's coverage binary under kcov through the release gate's runner and writes its report (test 43). [Reference](coverage/kcov/README.md). |
| [`coverage/branch/`](coverage/branch/) | package `komira//tools/build/coverage/branch` | `cov_branch`, the two directories (`[link]`, `[run]`) a `mojo_library`'s branch coverage links and runs from: `cov_branch_link.sh` (a test's LLVM bitcode instrumented with IR profile counters by the Mojo package's lld and linked with the LLVM profile runtime) and `cov_branch_run.sh` (that binary run through the release gate's runner, its raw profiles checked and merged), with the LLVM pieces of [`toolchains/llvm_branch`](toolchains/llvm_branch/README.md) (test 47). [Reference](coverage/branch/README.md). |
| [`ci/`](ci/) | package `komira//tools/build/ci` | `affected`, the Mojo tool that maps the files of a change to the targets it affects (the owners of the files, the packages that load a changed `.bzl`, the reverse dependencies) and to the units of the release template it reaches; what it widens on is the data file [`rules.txt`](ci/rules.txt). It never leaves a target out: a file it cannot map widens the answer to every target, and a change that reaches no target is refused. The mapping, `change_map`, has welded unit tests over table graphs. |
| [`coverage/`](coverage/) | package `komira//tools/build/coverage` | `covcheck`, the Mojo tool that reads coverage reports (kcov's Cobertura, lcov), maps them to repository files and packages, and holds each package's line and branch coverage to the target, the floors in [`ratchet.tsv`](coverage/ratchet.tsv), and surviving mutants, and lists every exemption for approval: `covcheck report` writes a pull request's check-run bodies, summary and JSON result, `covcheck gate` one package's verdict for the build gate, both from one computation. Its unit tests are welded. [Reference](coverage/README.md). |
| [`native/`](native/) | package `komira//tools/build/native` | symbol prefixing of the vendored C libraries: `prefix_header` (the header renaming every global symbol of a library, read from its unprefixed archive), `prefixed_archive_check` (a validation that fails unless every symbol of the prefixed archive carries the prefix), `checked_cxx_library` (the library gated by its check) and `elfsyms`, the static ELF symbol reader they run. [Reference](native/README.md). |
| [`third_party_srcs/`](third_party_srcs/) | package `komira//tools/build/third_party_srcs` | `gen`, which reads a vendored C library's source lists out of its pinned release archive, and `third_party_srcs`, which declares the generated file and the drift test holding the committed copy to it ([`defs.bzl`](third_party_srcs/defs.bzl)); tested on two made-up archives. |
| [`package/`](package/) | package `komira//tools/build/package` | `mojo_bundle`, `bundle_tarball`, `oci_tree`, `oci_image` and `oci_image_check` (an image read back, welded to the target that publishes it, by `komira_oci`, the Zig tool in [`package/oci/`](package/oci/README.md), which also lays out the tree and writes its image). [Reference](package/README.md). |
| [`one_definition/`](one_definition/) | package `komira//tools/build/one_definition` | `one_definition`, the one-definition gate of the C code: a `mojo_shared_lib` that links every `cxx_library` under `src/`, and the vendored C libraries those packages link, with `--whole-archive` (`force_load`), so a C symbol defined twice fails its link with `duplicate symbol` (a Mojo executable links C archives one by one and pulls a member in only for a symbol still undefined, so a second definition is reported only if its object is pulled in for some other symbol; otherwise the first definition wins silently, and two libraries no executable links together are never compared). The list is [`libraries.bzl`](one_definition/libraries.bzl); the BUCK-file global `cxx_library` ([`lint/includes.bzl`](lint/includes.bzl)) refuses to declare a library under `src/` the list does not name. It does not see a library declared another way (a .bzl macro's `native.cxx_library`, or a BUCK file's own `load` of `cxx_library` from the prelude); such a library stays out of the gate. The gate's `exports` are the symbols of [`core_split/c_symbols.tsv`](../core_split/c_symbols.tsv) and one per other library. `tests//negative/shared_lib:duplicate_definition` is its must-fail twin. |
| [`python/`](python/) | package `komira//tools/build/python` | the hermetic Python of the tests: `python_dist` (a pinned CPython archive unpacked, its version checked), `python_wheel` (one pinned wheel installed without pip), `py_test` (a Python script run by that interpreter as a build action, so the target exists only if it passed), `python_oracle` (a script run twice whose output directory, identical in both runs, is test data for other targets; its inputs may not be komira build outputs) and `python_proto` (the pinned protoc's `_pb2.py` for one `.proto`), with `pyrun.py`, `oracle_run.py` and `wheel_install.py`, the scripts their actions run. Test-only; the pins are [`third_party/python`](../../third_party/python/README.md), the tests `src/tests/helpers/komira_test_python`. [Reference](python/README.md). |
| [`node/`](node/) | no package: its rules are loaded as `@komira//tools/build/node:defs.bzl` | the hermetic Node.js of the tests: `node_dist` (a pinned Node.js archive unpacked, its version checked), `npm_package` (one pinned npm tarball, its registry integrity, name and version checked), `node_test` (a script run by that `node` as a build action, so the target exists only if it passed), `esbuild_bundle` (an entry, its sibling JavaScript or TypeScript sources and npm packages bundled by the pinned esbuild) and `c_shared_lib` (C sources linked into a shared library by the pinned zig, undefined symbols left for the loading program: a Node-API addon). Test-only; the pins are [`third_party/node`](../../third_party/node/README.md), the tests `src/tests/helpers/komira_test_node`. [Reference](node/README.md). |
| [`examples/`](examples/) | package `komira//tools/build/examples` | small targets using each rule; built by `buck2 build //...`. |
| `cells/toolchains/` | cell `toolchains` | the Mojo toolchain the rules use, `toolchains//:mojo`, declared by `komira_mojo_toolchains`, the C/C++ toolchain of the prelude's `cxx_library`, `toolchains//:cxx` (and its alias `toolchains//:cxx_no_default_deps`, which unconfigured queries reach), declared by `komira_cxx_toolchains`, and the Rust and protobuf toolchains, `toolchains//:rust` and `toolchains//:mojo_proto`, declared by `komira_rust_toolchains` and `komira_proto_toolchains`; one call of `komira_toolchains` declares them all ([`toolchains/defs.bzl`](toolchains/defs.bzl)). A standalone checkout's only; a consuming repository has its own ([below](#using-komira-from-another-repository)). |
| [`tests/`](tests/) | cell `tests` | end-to-end tests: `functional/` (behaviour that must work) and `negative/` (planted defects that must go red). A standalone checkout's only, and outside `//...`. [Reference](tests/README.md). |
| [`third_party/`](../../third_party/) | packages `komira//third_party/...` | C and C++ libraries built from pinned source archives (snappy, aws-lc, s2n-tls, sqlite, and others), see [C and C++](mojo/README.md#c-and-c); and the crates.io crates of the Rust rules (`third_party/rust`); the interpreter and wheels of the tests' hermetic Python (`third_party/python`); and the runtime and npm packages of the tests' hermetic Node.js (`third_party/node`). |
| [`consumer.buckconfig`](consumer.buckconfig) | | the `.buckconfig` of a repository using komira ([below](#using-komira-from-another-repository)). |

The repository is one cell, `komira`: the rules, toolchains, platforms and
packaging rules are packages of it, so a repository using komira names one
cell. `.buckconfig` adds two cells a standalone checkout needs and a consuming
repository does not take: `toolchains`, which the prelude requires of the
repository at the project root and which the Mojo rules take their toolchain
from, and `tests`, kept apart so that `//...` holds no target that fails by
design. The Mojo toolchain is declared in the `toolchains` cell rather than
in `komira//tools/build/toolchains` so that the repository at the project
root, which owns that cell, can override it. `.buckconfig` maps each cell to the target platform
`komira//tools/build/platforms:host`, the client's own platform
(`[parser] target_platform_detector_spec`; a Linux x86_64 client's is
`linux-x86_64`) and registers
`komira//tools/build/platforms/default:default` as the execution platforms.

Rules are loaded from one cell: a `.bzl` file's providers are distinct per
loading cell, so a Mojo target in one cell cannot depend on a Mojo library in
another. Every file loads the rules as `@komira//tools/build/mojo:...`, and the
`tests` cell has its own fixtures rather than reusing
[`examples/`](examples/).

## Languages for build tools

Every build tool under `tools/build` is written in Zig. Zig is already the
pinned hermetic C compiler and linker (`zig cc`), so a Zig tool needs no
extra toolchain, builds to a small static binary and calls C directly.
Rust is for long-running services, not for build tools.

[`mojo/tools/conda_unpack.zig`](mojo/tools/conda_unpack.zig) must be Zig
regardless: the Rust toolchain's conda libraries are unpacked by it
(`rustc_libs` in [`toolchains/rust/BUCK`](toolchains/rust/BUCK) sets
`unpacker = "komira//tools/build/toolchains:conda_unpack"`), so a Rust
version would be a bootstrap cycle.

The one exception is [`proto-codegen/`](proto-codegen/) (`protoc-gen-mojo`
and its sibling generators), which stays in Rust because it is built on
`prost`, the mature Rust protobuf library; Zig has no equivalent.

The Rust sources under [`tests/negative/`](tests/negative/) and
[`examples/rust/`](examples/rust/) are fixtures and examples that exercise
the Rust rules. They are not tools, and this policy does not cover them.

A new build tool is written in Zig unless it needs a library only Rust has;
that needs a written justification like the one for `proto-codegen` above.

## Using komira from another repository

A repository builds Mojo with komira's rules by naming komira as its `komira`
cell, either fetched by buck2 as a git external cell or mounted as a git
submodule. Either way it shares remote cache entries with standalone
checkouts: the same targets, built at the same revision with the same buck2
release and worker property set, have the same action digests.

Start from [`consumer.buckconfig`](consumer.buckconfig), copied to the
repository's root as `.buckconfig`, and two files copied from komira:

| your file | copied from | what it does |
|---|---|---|
| `toolchains/BUCK` | `cells/toolchains/BUCK` | the `toolchains` cell. The prelude requires every project to own one, and the Mojo rules take their toolchain from its `mojo` target. The file is one call, `komira_toolchains()`, which declares those, `toolchains//:cxx` for C and C++ deps (with `:cxx_no_default_deps`, the alias of it the prelude's C/C++ rules name), `toolchains//:rust` (the Rust rules) and `toolchains//:mojo_proto` (`mojo_proto_library`, whose plugin is built with `:rust`). Because it is one call, a toolchain family komira adds later needs no edit to your copy. `omit = ["cxx"]` keeps a C/C++ toolchain of your own. |
| `platforms/BUCK` | [`platforms/default/BUCK`](platforms/default/BUCK) | the execution platforms, named by `[build] execution_platforms = app//platforms:default`: local, or remote when your `.buckconfig.local` names a service. |

Without a `.buckconfig.local`, every action runs on your machine, as in a
standalone checkout. To use a remote-execution service, put its endpoints and
the `[komira_re]` worker property sets in `.buckconfig.local`
([`.buckconfig.local.example`](../../.buckconfig.local.example)). Buck2 reads
configuration only from the project root, so the execution platforms and
their properties always belong to the consuming repository. Then build komira
targets by name, e.g. `buck2 build komira//tools/build/examples:hello`, and
load the rules in your own BUCK files with
`load("@komira//tools/build/mojo:defs.bzl", "mojo_binary")`. Do not build
`komira//...` from a consuming repository: every directory of komira with a
BUCK file is a package there, including the standalone-only `tests`.

**As a git external cell** (buck2 fetches the commit into
`buck-out/v2/external_cells/git/<sha>/`, once per commit):

```
[cells]
  komira = komira-ext          # no directory; nothing is checked out here
[external_cells]
  komira = git
[external_cell_komira]
  git_origin = <komira url>
  commit_hash = <40-hex commit>
```

Upgrading komira is one change, `commit_hash`. The cell is always the whole
repository: buck2 has no key for a subdirectory, and refuses a cell nested
inside an external cell, which is why komira is one cell. Buck2 runs `git` to
fetch, so a private URL needs the credentials `git fetch` would.

**As a git submodule:**

```sh
git submodule add <komira-url> third_party/komira
```

and in `.buckconfig`, `komira = third_party/komira` in `[cells]`, without the
`komira = git` line and the `[external_cell_komira]` section. The mount path
may be nested.

**Overriding the toolchain.** The rules' `toolchain` attribute defaults to
`toolchains//:mojo`, which is the consuming repository's cell.
Passing an attribute of `mojo_toolchain` to `komira_toolchains`, e.g.
`komira_toolchains(mojo = {"compiler": "//third_party/mojo:compiler"})`,
changes it for every Mojo target; `omit = ["mojo"]` and declaring
`mojo_toolchain` targets yourself replaces them altogether. A single target can
also set `toolchain =` itself. Leaving the call unchanged keeps the digests
of a standalone checkout.

**Your own Mojo packages may depend on komira's.** A `mojo_library`,
`mojo_binary` or `mojo_test` in your cell can name a komira package in `deps`.
buck2 keys a `.bzl` module by the cell of the BUCK file that loads it, so the
rules are loaded once for your cell and once for `komira`, and each load has
its own `MojoPkgTSet`; the rules re-wrap the closure of a dependency built by
the other load (`mojo_pkg_children` in `mojo/providers.bzl`), and pass one
built by the same load through untouched, so komira's own targets are built
by exactly the actions they always were. Test 7 builds such a package, with its
gated test and a binary on it.

**Your own targets need a target platform too.**
`target_platform_detector_spec` is a single key; `consumer.buckconfig` maps
the root cell (`app`), `komira` and `toolchains` to
`komira//tools/build/platforms:host`. Keep komira's entry unchanged
when you add your own cells to it: a different target platform for komira's
targets is a different configuration, and so different digests (`host` is
an alias of the client's own row, so on a Linux x86_64 client it is
`linux-x86_64` itself). Keep
`[buck2_re_client] max_total_batch_size = 1048576` too, and do not raise it:
a server whose message limit is below buck2's default batch size fails
`BatchReadBlobs`.

What keeps the digests equal:

- **Cell name.** Output paths contain the cell name (`buck-out/v2/.../komira/...`),
  so the consuming repository names the cell `komira`. The mount path, or the
  external cell's fetch directory, never reaches a command: sources enter
  actions through copies under `buck-out`.
- **Execution platform name.** `komira_execution_platforms` (and
  `komira_local_execution_platforms`) names each
  platform after the target platform whose configuration it uses
  (`komira//tools/build/platforms:linux-x86_64`, ...), not after the target
  that declares it. That name keys the configuration of the toolchain, and so the
  toolchain's output paths. An execution platform declared some other way must
  do the same.
- **Target platform.** The `komira` cell maps to
  `komira//tools/build/platforms:host` in `[parser]`, an alias of the row of
  the platform table that matches the client (`linux-x86_64` on Linux x86_64).
  `komira//tools/build/platforms` holds only the platforms; the
  standalone checkout's execution platforms live in its `default`
  subpackage, which the consuming repository never loads (it copies the file
  instead).
- **Toolchains.** `komira_toolchains` declares the same toolchains in
  every repository, at the same label: the root package of the `toolchains`
  cell.
- **Worker properties.** They are part of every action digest, so the outer
  repository must give each configuration the same property set as the
  checkouts it wants to share a cache with.

Labels reach digests the same way: the target platform's label keys the
configuration, whose hash appears in the output paths of configured copies
such as the rules' scripts, and a target's package path appears in the paths
of its sources and outputs. Moving `komira//tools/build/platforms` to another
package therefore changes the digest of every configured action in the
repository, product code included, although no command changes meaning;
moving a package of examples changes only the digests of that package's
actions. [Test 18](tests/README.md#18-configuration-hashes) fails if the
configuration hashes the platform package keys move, so such a re-key is
always a deliberate, reviewed change.

[`tests/functional/umbrella_cache.sh`](tests/functional/umbrella_cache.sh) builds the examples
in a fresh standalone clone and then in three scratch repositories set up as
above (a submodule at `komira` and at `third_party/komira`, and a git
external cell), each with a fresh daemon, and fails unless every consumer
command is a cache hit and every build reports the same action digests
([test 7](tests/README.md#7-umbrella-cache)).
[Test 19](tests/README.md#19-exported-cells) fails if a file a consuming
repository loads names the `tests` cell or any other it lacks.
