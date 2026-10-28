# tools/build/ci: what a change affects, and the aggregate of every check

Two things live here: the BXL selector, which names the targets a pull
request's change affects, and the aggregate target `//ci:pr`, which builds
every check. `pr.yml` runs the selector and builds what it names through the
`buck2-farm` action; no kci and no Mojo selector is involved.

## The BXL selector: `affected.bxl`

```sh
git diff --name-only <base>...HEAD > changed.txt
git grep -n '' <base> HEAD -- '*coverage_held' > held.txt
./buck2 bxl komira//tools/build/ci/affected.bxl:affected \
    @tools/build/ci/affected_changed.args @changed.txt \
    @tools/build/ci/affected_held.args @held.txt
```

It prints the targets to build and test, one label per line, and nothing else
on stdout. The same list goes to `./buck2 build` and `./buck2 test`; no
`buck2` runs inside another. A BXL script reads no file, so the two lists
come in as arguments: Buck2's client expands `@file` (one argument per line)
before the subcommand but not after `--`, and the two small `.args` files
spell the `--` and the option that take the lines that follow.

| The change | The answer |
|---|---|
| a source file a target lists | its owners and everything that depends on them in the check set |
| a `BUCK` file, or a file that was deleted | every target of the package, and the dependents |
| a `.bzl` file | every target of every package whose `BUCK` file loads it, and the dependents |
| a file under `tools/build/`, `prelude/`, `third_party/`, the pinned buck2, `.buckconfig` | `komira//ci:pr`: the whole check set (`rules.bzl` `WIDEN`) |
| a file no target owns that no rule names | `komira//ci:pr`: a file the rules cannot map is never dropped |
| a change to the aggregate's own list (`ci/`) | `komira//ci:pr` |
| only files that build nothing (`rules.bzl` `INERT`) | fails: `VACUOUS` |
| no changed file | fails: `EMPTY` |
| a coverage hold taken out of a `coverage_held`, or a marker deleted while its package stays | fails: `BROKEN`; a hold is never dropped |
| a query Buck2 cannot answer | fails with Buck2's own error |

**The heavy checks.** `rules.bzl` `HEAVY` lists checks that cost one compile of several GB and are of a frozen program: today `//bin/kci:kci`, with the roots that reach it (its README examples tool, its process test, the base image that bundles it). A row owns paths (`bin/kci/**`, `src/kci_*`, the image's package, and the selector's own files `ci/**` and `tools/build/ci/**`). A change with a file under a row's paths builds the row as before. A change with none leaves it out: an AFFECTED answer loses the row's target and every target that depends on it, and a WIDENED answer (a file under `tools/build/` or `third_party/`, say) is `//ci:pr_default`, the aggregate without the row's roots (`ci/BUCK` declares it from the generated lists), plus the roots of any row the change does own. `default_guard.bxl:check` holds `//ci:pr_default` to that: it reaches no heavy target, and every root a row names reaches it. What it costs: a change outside the paths that breaks the kci binary (a shared library, the Mojo rules) is not found by the pull request check, and the same holds for the base image package's `supervisor_stub` and `supervisor_bundle`, which only `komira_base` reaches, so a change to a shared library the supervisor stub compiles against no longer builds them; no job of the release builds the binary either (`//release:release_set`, `//release:mopm_artifacts` and the README e2e reach none of the roots). `//bin/kci` reaches `//ci:pr` still, so `./buck2 build //ci:pr` builds it.

The AWS conformance drivers (`//tools/build/proto-codegen:aws_conformance_driver_<protocol>`, one generated Mojo program per protocol: ec2, json, query, rest-json, rest-xml; they share no dependency, so they compile in parallel) are not a row: they are welded into `aws-client-gen`'s build through `:aws_conformance_test`, so every generated AWS client library and the tests of `tests//functional/aws_codegen` depend on them, and leaving them out would leave out their builds. They are rebuilt when one of their inputs changes (the generator, `komira_aws_core`, `komira_json`, `komira_xml`, the Mojo rules) and cached otherwise.

The targets the aggregate leaves out on purpose (`rules.bzl` `EXCLUDED`) are dropped from every answer, so a change to a file one of them owns never selects it; an answer left empty by that is `komira//ci:pr`.

The reason for a widening and the warnings go to the log. The rows are
data in `rules.bzl` (a BXL script cannot read a text file), and `cases.bxl`
holds them to the paths that must always widen. The mapping itself is
`affected.bzl`, a pure function over a graph facade, so
`cases.bxl` answers it from tables and from the real graph of
the fixture package (`fixture/`).

## The aggregate: `//ci:pr`

`ci/BUCK` declares one target that builds every check:
`./buck2 build //ci:pr`, and `./buck2 test //ci:pr` for the standalone tests.
A target's `deps` are literal labels and no rule can query the graph, so the
lists are generated and checked in: `ci/targets.bzl` loads eight shards,
`ci/targets/shard_<n>.bzl`, and exposes `TARGETS` and `TESTS` (the sorted union
of theirs). One command regenerates the loader and every shard. It assigns the generator's output and
copies only from a directory that is not `/`: with an empty output (the generator failed) the
bare `cp ... "$(...)"/. ci/` would copy the whole filesystem into `ci/`:

```sh
out=$(./buck2 bxl komira//tools/build/ci/targets.bxl:generate) && [ -d "$out" ] && [ "$out" != / ] && cp -rL --no-preserve=mode "$out"/. ci/
```

The script builds the files into a directory of `buck-out` and prints it, so
the generation is a scratch copy first: if it fails, the checked-in files are
untouched. Never redirect the script's output onto `ci/targets.bzl`: the shell
empties the file before the script, which loads it through the guard, runs.
A package's rows share one shard, chosen by a hash of the package path
(`ci_graph.bzl` `shard_of`), so adding a package changes one shard and no
prefix or top-level directory (`src/` holds most of the rows) can fill one.

`TARGETS` is every check of the scope (`UNIVERSE` in `rules.bzl`: this
repository's targets but the toolchains cell's directory, and the tests
cell's `functional` tree) that no other check depends on; building them builds
the others as dependencies. A check is a target of any kind but a source
(`export_file`, `filegroup`). `TESTS` is the roots Buck2 can run as a test.

`guard.bxl` is the completeness guard:

```sh
./buck2 bxl komira//tools/build/ci/guard.bxl:check
```

It fails when a check target of the scope is not in the closure of `//ci:pr`,
naming the targets and the command that regenerates the list, so a new package
that nobody added to the aggregate cannot go untested. Configuring `//ci:pr`
also fails on a label in the list that no longer exists. It holds the shards to
the graph both ways: a row of `TARGETS` that is no longer a root of the check
set, a root with no row, or a `TESTS` row outside `TARGETS` fails, and so does
a shard that would reach 1000 lines (`LINE_LIMIT`; the failure says to raise
`SHARDS` in `ci_graph.bzl` and regenerate). A BXL script reads no file's text,
so the line count is that of the file the generator makes from the rows the
loader exposes; the cases (`cases.bxl`) hold the placement, the union and each
refusal.

## The lock-graphs check: `lock_graphs.bxl`

```sh
./buck2 bxl komira//tools/build/ci/lock_graphs.bxl:check
```

A package built with buildrules' `mojo_package` commits one unit graph per
platform subdir in `buildrules.mojo.lock.bzl` (`GRAPHS`): linux-64, and
linux-aarch64 and osx-arm64 when the package's `mopm.lock` records a toolchain
for them under the package's Mojo version, which is what `buildrules mojo sync`
plans. The package's `:table` compares each graph the table holds with mopm's
output, but it learns which subdirs to compare from the table itself, so a
graph deleted from `GRAPHS` is noticed only by a build for that platform, and
the pull request check builds on linux. This script finds the `:table` of every
package of the scope, reads the subdirs each holds, and runs `lock_graphs`
(`lock_graphs.zig`, behind its unit tests) over the package's `mopm.lock`. It
fails, naming the package and the subdir, for a subdir the lock records and the
table lacks, and for one the table holds that the lock does not record. A new
package needs no list to edit. A change that deletes the subdir from `mopm.lock`
as well fails `:table` instead: the lock's hash is in the table.

**The aggregate holds no Python.** Python serves only the Python SDK and its
tests (`PYTHON_SURFACE` in `tests/python_closure_allowlist.bzl`, empty until
the SDK lands), so the checks of `EXCLUDED` in `rules.bzl` are left out of
`TARGETS` and of the completeness guard, each with its reason: the pinned
CPython and wheels (`third_party/python`), the py_test of the CI scripts, and
the three TLS interop tests that run a CPython peer. A row whose package is
deleted fails the generator; delete the row with it.

```sh
./buck2 bxl komira//tools/build/ci/python_guard.bxl:check
```

`python_guard.bxl` fails when `//ci:pr` reaches any Python target (a rule kind
holding `python` or starting `py_`, a target of `third_party/python` or
`tools/build/python`, a `.py` source; the prelude's bootstrap helpers and a
`doc_tree`'s data are not) outside the SDK's packages and what their own
targets reach. It walks the configured closure, every kind of dependency, and
names the targets and the way out (a row of `EXCLUDED`, then regenerate).
`cases.bxl` holds its table cases and one case over the real pinned
interpreter.

Because the aggregate depends on every root, three things are different from
an ordinary package:

- The cell's `PACKAGE` file makes `komira//ci:` the default
  visibility of every target that names none (a target that names its own
  visibility keeps it, and lists `komira//ci:` when nothing else depends on
  it). The tests cell has the same file.
- The selector leaves the aggregate out of its reverse-dependency query, or
  every change would select it and build the whole tree; a change to its own
  package widens instead.
- Building it runs every dependency's validations (the lints) and welded tests,
  as building each one does.
