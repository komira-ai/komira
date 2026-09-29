# Build tooling

Everything the build needs besides the project configuration
([`.buckconfig`](../../.buckconfig)) and the pinned buck2
([`tools/buck2`](../buck2)) lives here. Setup and day-to-day use are in
[DEVELOPMENT.md](../../DEVELOPMENT.md).

| directory | Buck2 name | what it holds |
|---|---|---|
| [`mojo/`](mojo/) | cell `mojo` | the Mojo rules (`mojo_library`, `mojo_binary`, `mojo_test`, `mojo_multi_numa_test`), the toolchain rules, and the scripts their actions run. [Reference](mojo/README.md). |
| [`toolchains/`](toolchains/) | cell `toolchains` | the sha256-pinned downloads and the hermetic Mojo toolchain built from them. [Reference](toolchains/README.md). |
| [`platforms/`](platforms/) | package `komira//tools/build/platforms` | the target platform, the execution constraints and configurations, and `komira_execution_platforms`; [`platforms/remote/`](platforms/remote/) registers a standalone checkout's remote platforms. [Reference](platforms/README.md). |
| [`checks/`](checks/) | cell `checks` | end-to-end checks, including fixtures that must fail. Outside `//...`. [Reference](checks/README.md). |
| [`examples/`](examples/) | package `komira//tools/build/examples` | small targets using each rule; built by `buck2 build //...`. |
| [`umbrella_buckconfig.sh`](umbrella_buckconfig.sh) | | prints the `.buckconfig` block a repository needs to mount komira ([below](#mounting-komira-in-another-repository)). |

The root cell is `komira` (the repository root). `mojo`, `toolchains` and
`checks` are cells of their own, declared in `[cells]` of `.buckconfig`; the
platforms and examples are packages of the root cell. `.buckconfig` maps every
one of these to the target platform `komira//tools/build/platforms:linux-x86_64`
(`[parser] target_platform_detector_spec`) and registers
`komira//tools/build/platforms/remote:remote` as the execution platforms.

Rules are loaded from one cell: a `.bzl` file's providers are distinct per
loading cell, so a Mojo target in one cell cannot depend on a Mojo library in
another. The `checks` cell therefore has its own fixtures rather than reusing
[`examples/`](examples/).

## Mounting komira in another repository

A larger repository can include komira as a git submodule and build it as a
set of cells, sharing remote cache entries with standalone checkouts: the same
targets, built at the same revision with the same buck2 release and worker
property set, have the same action digests in both.

```sh
git submodule add <komira-url> komira
komira/tools/build/umbrella_buckconfig.sh komira > .buckconfig
```

[`umbrella_buckconfig.sh`](umbrella_buckconfig.sh) prints the cells komira
declares, moved under the mount point with their names unchanged, and copies
`[cell_aliases]`, `[external_cells]`, `[buildfile]`, `[parser]` and
`[buck2_re_client]`. Buck2 registers cells only from the project root's
`.buckconfig` (and does not follow `<file:...>` includes there), so the outer
repository has to restate them; regenerate the output whenever the submodule
moves. The mount path may be nested
([`checks/umbrella_cache.sh`](checks/umbrella_cache.sh) builds at `komira`
and at `third_party/komira`). Then add the outer repository's own root cell
and execution platform. Buck2 merges repeated sections, so these can follow
the generated block in the same file as a second `[cells]` (the recipe above
overwrites `.buckconfig`; keep the outer repository's own part in a file you
append, or paste the generated block into a hand-maintained `.buckconfig`):

```
[cells]
  umbrella = .

[build]
  execution_platforms = umbrella//platforms:remote
```

```python
# platforms/BUCK in the outer repository
load("@komira//tools/build/platforms:defs.bzl", "komira_execution_platforms")

komira_execution_platforms(
    name = "remote",
    light = {...},         # property set of the workers for `exec-light`
    mojo_compile = {...},  # ... for `exec-mojo`
    # mojo_compile_multi_numa = {...},  # only for workers spanning >1 NUMA node
    visibility = ["PUBLIC"],
)
```

The property sets may be written inline or read with
`re_properties("<key>")` from a `[komira_re]` section, as
[`platforms/remote/BUCK`](platforms/remote/BUCK) does
([platforms/README.md](platforms/README.md#your-own-worker-pools) explains the
classes). The generated `[buck2_re_client]` already carries
`max_total_batch_size = 1048576`; the outer repository adds only its
endpoints (in `.buckconfig` or `.buckconfig.local`) and must not raise that
value, since a server whose message limit is below buck2's default batch size
then fails `BatchReadBlobs`. Build komira targets as
`buck2 build komira//tools/build/examples/...`.

**The outer repository's own targets need a target platform too.**
`target_platform_detector_spec` is a single key: an outer `[parser]` section
that sets it replaces komira's value, dropping komira's mappings, which
changes the configurations and so the action digests. Append the outer
repository's cells to the one generated line instead, leaving komira's
entries unchanged, e.g.
`... target:umbrella//...->komira//tools/build/platforms:linux-x86_64`.

What keeps the digests equal:

- **Cell names.** Output paths contain the cell name (`buck-out/v2/.../komira/...`),
  so every komira cell keeps its name in the outer repository. The mount path
  itself never reaches a command: sources enter actions through copies under
  `buck-out`.
- **Execution platform name.** `komira_execution_platforms` names each
  platform after the abstract configuration it realizes
  (`komira//tools/build/platforms:exec-mojo`, ...), not after the target that
  declares it. That name keys the configuration of the toolchain, and so the
  toolchain's output paths. An execution platform declared some other way must
  do the same.
- **Target platform.** Every komira cell maps to
  `komira//tools/build/platforms:linux-x86_64` in `[parser]`, copied
  unchanged. `komira//tools/build/platforms` holds only abstract constraints;
  the standalone remote platform lives in its `remote` subpackage, which the
  outer repository never loads.
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
in a fresh standalone clone and then in scratch umbrella repositories mounting
the working tree as a submodule, each with a fresh daemon, and fails unless
every umbrella command is a cache hit and both builds report the same action
digests ([check 7](checks/README.md#7-umbrella-cache)).
