# Build tooling

Everything the build needs besides the project configuration
([`.buckconfig`](../../.buckconfig)) and the pinned buck2
([`tools/buck2`](../buck2)) lives here. Setup and day-to-day use are in
[DEVELOPMENT.md](../../DEVELOPMENT.md).

| directory | Buck2 name | what it holds |
|---|---|---|
| [`mojo/`](mojo/) | package `komira//tools/build/mojo` | the Mojo rules (`mojo_library`, `mojo_binary`, `mojo_test`, `mojo_multi_numa_test`, `mojo_proto_library`), the toolchain rules, and the scripts their actions run. [Reference](mojo/README.md). |
| [`toolchains/`](toolchains/) | package `komira//tools/build/toolchains` | the sha256-pinned downloads and the hermetic Mojo toolchain built from them. [Reference](toolchains/README.md). |
| [`platforms/`](platforms/) | package `komira//tools/build/platforms` | the target platform, the execution constraints and configurations, and `komira_execution_platforms`; [`platforms/remote/`](platforms/remote/) registers a standalone checkout's remote platforms. [Reference](platforms/README.md). |
| [`rust/`](rust/) | package `komira//tools/build/rust` | the Rust rules (`rust_library`, `rust_binary`, `crates_io_library`) and the rustc toolchain rule. [Reference](rust/README.md). |
| [`proto-codegen/`](proto-codegen/) | package `komira//tools/build/proto-codegen` | the `komira_proto_codegen` crate: `protoc-gen-mojo`, the protoc plugin of `mojo_proto_library` (see [Protobuf](mojo/README.md#protobuf-mojo_proto_library)). |
| [`package/`](package/) | package `komira//tools/build/package` | `mojo_bundle`, `bundle_tarball` and `oci_image`. [Reference](package/README.md). |
| [`examples/`](examples/) | package `komira//tools/build/examples` | small targets using each rule; built by `buck2 build //...`. |
| [`cells/toolchains/`](cells/toolchains/) | cell `toolchains` | the Mojo toolchains the rules use, `toolchains//:mojo` and `toolchains//:mojo_multi_numa`, declared by `komira_mojo_toolchains`, the C/C++ toolchain of the prelude's `cxx_library`, `toolchains//:cxx`, declared by `komira_cxx_toolchains`, and the Rust and protobuf toolchains, `toolchains//:rust` and `toolchains//:mojo_proto`, declared by `komira_rust_toolchains` and `komira_proto_toolchains` ([`toolchains/defs.bzl`](toolchains/defs.bzl)). A standalone checkout's only; a consuming repository has its own ([below](#using-komira-from-another-repository)). |
| [`checks/`](checks/) | cell `checks` | end-to-end checks, including fixtures that must fail. A standalone checkout's only, and outside `//...`. [Reference](checks/README.md). |
| [`third_party/`](../../third_party/) | packages `komira//third_party/...` | C and C++ libraries built from pinned source archives (snappy), see [C and C++](mojo/README.md#c-and-c); and the crates.io crates of the Rust rules (`third_party/rust`). |
| [`consumer.buckconfig`](consumer.buckconfig) | | the `.buckconfig` of a repository using komira ([below](#using-komira-from-another-repository)). |

The repository is one cell, `komira`: the rules, toolchains, platforms and
packaging rules are packages of it, so a repository using komira names one
cell. `.buckconfig` adds two cells a standalone checkout needs and a consuming
repository does not take: `toolchains`, which the prelude requires of the
repository at the project root and which the Mojo rules take their toolchain
from, and `checks`, kept apart so that `//...` holds no target that fails by
design. The Mojo toolchains are in the `toolchains` cell rather than in
`komira//tools/build/toolchains` for the same reason: `mojo_multi_numa`
configures only where multi-NUMA workers are registered. `.buckconfig` maps each cell to the target platform
`komira//tools/build/platforms:linux-x86_64`
(`[parser] target_platform_detector_spec`) and registers
`komira//tools/build/platforms/remote:remote` as the execution platforms.

Rules are loaded from one cell: a `.bzl` file's providers are distinct per
loading cell, so a Mojo target in one cell cannot depend on a Mojo library in
another. Every file loads the rules as `@komira//tools/build/mojo:...`, and the
`checks` cell has its own fixtures rather than reusing
[`examples/`](examples/).

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
| `toolchains/BUCK` | [`cells/toolchains/BUCK`](cells/toolchains/BUCK) | the `toolchains` cell. The prelude requires every project to own one, and the Mojo rules take their toolchains from its `mojo` and `mojo_multi_numa` targets, which one call of `komira_mojo_toolchains` declares. The call of `komira_cxx_toolchains` declares `toolchains//:cxx` for C and C++ deps; drop it to keep a C/C++ toolchain of your own. The calls of `komira_rust_toolchains` and `komira_proto_toolchains` declare `toolchains//:rust` (the Rust rules) and `toolchains//:mojo_proto` (`mojo_proto_library`, whose plugin is built with `:rust`). |
| `platforms/BUCK` | [`platforms/remote/BUCK`](platforms/remote/BUCK) | the execution platforms, named by `[build] execution_platforms = app//platforms:remote`. |

Put the remote-execution endpoints and the `[komira_re]` worker property sets
in `.buckconfig.local`, as in a standalone checkout
([`.buckconfig.local.example`](../../.buckconfig.local.example)). Buck2 reads
configuration only from the project root, so the execution platforms and
their properties always belong to the consuming repository. Then build komira
targets by name, e.g. `buck2 build komira//tools/build/examples:hello`, and
load the rules in your own BUCK files with
`load("@komira//tools/build/mojo:defs.bzl", "mojo_binary")`. Do not build
`komira//...` from a consuming repository: every directory of komira with a
BUCK file is a package there, including the standalone-only `checks`.

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
`toolchains//:mojo` (`mojo_multi_numa_test` uses
`toolchains//:mojo_multi_numa`), which is the consuming repository's cell.
Passing an attribute of `mojo_toolchain` to `komira_mojo_toolchains`, e.g.
`komira_mojo_toolchains(compiler = "//third_party/mojo:compiler")`, changes it
for every Mojo target; declaring `mojo_toolchain` targets yourself replaces
the macro altogether. A single target other than a `mojo_multi_numa_test` can
also set `toolchain =` itself. Leaving the call unchanged keeps the digests
of a standalone checkout.

**Your own targets need a target platform too.**
`target_platform_detector_spec` is a single key; `consumer.buckconfig` maps
the root cell (`app`), `komira` and `toolchains` to
`komira//tools/build/platforms:linux-x86_64`. Keep komira's entry unchanged
when you add your own cells to it: a different target platform for komira's
targets is a different configuration, and so different digests. Keep
`[buck2_re_client] max_total_batch_size = 1048576` too, and do not raise it:
a server whose message limit is below buck2's default batch size fails
`BatchReadBlobs`.

What keeps the digests equal:

- **Cell name.** Output paths contain the cell name (`buck-out/v2/.../komira/...`),
  so the consuming repository names the cell `komira`. The mount path, or the
  external cell's fetch directory, never reaches a command: sources enter
  actions through copies under `buck-out`.
- **Execution platform name.** `komira_execution_platforms` names each
  platform after the abstract configuration it realizes
  (`komira//tools/build/platforms:exec-mojo`, ...), not after the target that
  declares it. That name keys the configuration of the toolchain, and so the
  toolchain's output paths. An execution platform declared some other way must
  do the same.
- **Target platform.** The `komira` cell maps to
  `komira//tools/build/platforms:linux-x86_64` in `[parser]`.
  `komira//tools/build/platforms` holds only abstract constraints; the
  standalone remote platform lives in its `remote` subpackage, which the
  consuming repository never loads (it copies the file instead).
- **Toolchains.** `komira_mojo_toolchains` declares the same toolchains in
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
actions. [Check 18](checks/README.md#18-configuration-hashes) fails if the
configuration hashes the platform package keys move, so such a re-key is
always a deliberate, reviewed change.

[`checks/umbrella_cache.sh`](checks/umbrella_cache.sh) builds the examples
in a fresh standalone clone and then in three scratch repositories set up as
above (a submodule at `komira` and at `third_party/komira`, and a git
external cell), each with a fresh daemon, and fails unless every consumer
command is a cache hit and every build reports the same action digests
([check 7](checks/README.md#7-umbrella-cache)).
[Check 19](checks/README.md#19-exported-cells) fails if a file a consuming
repository loads names the `checks` cell or any other it lacks.
