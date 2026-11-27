# tools/build/ci: what a change affects, and the aggregate of every check

Two things live here: the BXL selector, which names the targets a pull
request's change affects, and the aggregate target `//ci:pr`, which builds
every check. `pr.yml` runs the selector and builds what it names through the
`buck2-farm` action.

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

**The heavy checks.** `rules.bzl` `HEAVY` lists checks that cost one compile of several GB and are of a frozen program, with the roots that reach each. It is empty today, so `//ci:pr_default` equals `//ci:pr`. The mechanism stays, and `heavy_cases.bzl` holds it over rows written there. A row owns paths (and the selector's own files `ci/**`, `tools/build/ci/**` and `.buckconfig`, which pins the selector's library). A change with a file under a row's paths builds the row. A change with none leaves it out: an AFFECTED answer loses the row's target and every target that depends on it, and a WIDENED answer (a file under `tools/build/` or `third_party/`, say) is `//ci:pr_default`, the aggregate without the row's roots (`ci/BUCK` declares it from the generated lists), plus the roots of any row the change does own. `default_guard.bxl:check` holds `//ci:pr_default` to that: it reaches no heavy target, and every root a row names reaches it. What a row costs: a change outside its paths that breaks the heavy target is not found by the pull request check.

The AWS conformance drivers (`//tools/build/proto-codegen:aws_conformance_driver_<protocol>`, one generated Mojo program per protocol: ec2, json, query, rest-json, rest-xml; they share no dependency, so they compile in parallel) are not a row: they are welded into `aws-client-gen`'s build through `:aws_conformance_test`, so every generated AWS client library and the tests of `tests//functional/aws_codegen` depend on them, and leaving them out would leave out their builds. They are rebuilt when one of their inputs changes (the generator, `aws_core`, `json`, `xml`, the Mojo rules) and cached otherwise.

The targets the aggregate leaves out on purpose (`rules.bzl` `EXCLUDED`) are dropped from every answer, so a change to a file one of them owns never selects it; an answer left empty by that is `komira//ci:pr`.

The reason for a widening and the warnings go to the log. The rows are
data in `rules.bzl` (a BXL script cannot read a text file), and `cases.bxl`
holds them to the paths that must always widen. The mapping itself is
buildrules' selector library, `rules/affected` of the commit `.buckconfig`
pins (its `README.md` is the reference: the configuration, the command line,
the output and the failures); `affected.bxl` passes it the rows of `rules.bzl`
as one configuration value and keeps the command line above. The library
holds its own cases over table graphs; `cases.bxl` runs it from this cell over
the real graph of the fixture package (`fixture/`), and holds the log and
failure text of `affected.bxl`'s configuration.

`--format json` prints one line instead of the labels: the verdict
(`AFFECTED` or `WIDENED`), its reason, the labels, the notes, the warnings
and the number of files. `pr.yml` reads the labels, the default.

## The macOS targets: `darwin.bxl`

```sh
./buck2 bxl komira//tools/build/ci/darwin.bxl:select @tools/build/ci/darwin_affected.args @targets.txt
```

`targets.txt` is what `affected.bxl` printed. It prints the targets of `pr.yml`'s macOS part
([docs/ci.md](../../../docs/ci.md#the-macos-part-of-the-check)), which builds them with
`--target-platforms komira//tools/build/platforms:darwin-arm64` on the farm's macOS workers;
[`darwin.bzl`](darwin.bzl) is the rule and `darwin_cases.bzl` its cases (run by `cases.bxl`):
`darwin_answer` is everything the command prints and its failure, and its cases hold those lines for
the lists of the recorded runs in `darwin_targets/fixtures`. The self-test scenario
[`darwin_select`](../selftest/darwin_select.zig) runs the command itself over five lists and checks
its exit status, stdout and verdict line. The step after it, `the macOS targets to
build`, runs `//tools/build/ci:darwin_targets` over the run's log
([`darwin_targets.zig`](darwin_targets/darwin_targets.zig)): the labels go to `darwin_targets.txt`,
`any=true` to the step's output when there is one, and a log with no verdict, two, or a verdict that
disagrees with the labels fails the step.

| The selector's answer | The macOS targets |
|---|---|
| `komira//ci:pr` or `komira//ci:pr_default` | `komira//release:mopm_darwin_libs`, the whole macOS set |
| labels that hold the `:lib` of packages of the set (`DARWIN_PACKAGES` of `release/darwin_libs.bzl`) | those `:lib`s, in the order of the list |
| labels that hold no such `:lib` (another target of a set package, a package outside the set, the tests cell) | nothing: the build step is skipped |
| a line that is not a target label | fails: `BROKEN` |

## The aggregate: `//ci:pr`

`ci/BUCK` declares one target that builds every check:
`./buck2 build //ci:pr`, and `./buck2 test //ci:pr` for the standalone tests.
A target's `deps` are literal labels and no rule can query the graph, so the
roots are committed: one empty file per root, named by the root's label with its
`//` written as `/` ([`roots.bzl`](roots.bzl)):

| The root | Its file |
|---|---|
| `komira//src/avro:avro_conda`, not a test | `ci/roots/komira/src/avro:avro_conda` |
| `komira//:top`, a root of the root package | `ci/roots/komira/:top` |
| `komira//src/proto_codec:test_copy_hazard`, a test | `ci/test_roots/komira/src/proto_codec:test_copy_hazard` |

`ci/BUCK` globs the two trees: `TARGETS` is every file's label, `TESTS` the
labels of `ci/test_roots/`. Nothing lists the files, so adding a root adds a
file and edits none, and a new target that depends on an old root deletes the
old root's file. Two pull requests that add targets therefore change different
paths and merge with no conflict in either order, in one package or two; where
both change one path they make the same change (both delete a root their new
targets depend on), which git merges too. A file never stands where another's
directory would, since only a path's last part holds a `:`. A path that names
no label builds nothing, and the guard names it.

A change that adds one root can add its file by hand (the guard's failure names
the path). One command writes every file from the graph. It assigns the
generator's output and copies only from a directory that is not `/` (with an
empty output, the generator having failed, a bare `cp ... "$(...)"/. ci/` would
copy the whole filesystem into `ci/`), and only then deletes the old files of
both trees, committed or not, copies the new ones in and stages them:

```sh
out=$(./buck2 bxl komira//tools/build/ci/targets.bxl:generate) && [ -d "$out" ] && [ "$out" != / ] && git rm -rqf --ignore-unmatch ci/roots ci/test_roots && git clean -fdq -- ci/roots ci/test_roots && cp -rL --no-preserve=mode "$out"/. ci/ && git add ci/roots ci/test_roots
```

The script builds the files into a directory of `buck-out` and prints it, so
the generation is a scratch copy first: if it fails, the committed files are
untouched.

`TARGETS` is every check of the scope (`UNIVERSE` in `rules.bzl`: this
repository's targets but the toolchains cell's directory, and the tests
cell's `functional` tree) that no other check depends on; building them builds
the others as dependencies. A check is a target of any kind but a source
(`export_file`, `filegroup`). `TESTS` is the roots Buck2 can run as a test.
Two kinds of edge do not count (`ci_graph.bzl` `roots`): those of an
execution-platform registration, whose platforms depend on the checkout's
configuration, and those of the surface capability matrix
(`//:surface_capability_matrix`), which names a test for each filled cell
and only analyses it. A test a cell names therefore stays a root, built by
`//ci:pr` and run by `buck2 test`.

A package whose targets come and go with its files declares an aggregate of
them, so that the list names the aggregate and not each target: the common
tasks' examples are `//python/docs/tasks:examples` (`task_examples` of
`python/task_examples.bzl`), and a pull request that adds a task directory
changes no generated file. `tasks_cases.bzl` (run by `cases.bxl`) holds that
over two fixture trees, `python/docs/task_tree_fixture/before` and `after`,
which differ by one task directory: their roots render the same shards byte
for byte.

`guard.bxl` is the completeness guard:

```sh
./buck2 bxl komira//tools/build/ci/guard.bxl:check
```

It holds the committed files to the graph both ways, before anything
configures `//ci:pr`: it lists the two trees from the source tree (`ctx.fs`)
and fails, naming each path, for a root with no file (a new target nothing
depends on, or a test whose file is under `ci/roots/`: the `ci/test_roots/` one
is wanted) and for a file no root needs (its target is gone or now has a
dependent, it is in the wrong tree, or its path names no label). The failure
names the files to add and to delete, and the command above. Then it fails when
a check target of the scope is not in the closure of `//ci:pr`, naming the
targets, so a new package that nobody added to the aggregate cannot go
untested. The cases (`cases.bxl`) hold the encoding both ways, the two trees,
merges of two branches that each add targets (in two packages, in one, a new
test beside a new package, two new dependents of one old root: no conflict in
either order, and the guard green over the merged tree), and each refusal.

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

The same run holds a package's system libraries to its lock. A package whose
`mopm.toml`, or a path dependency's, declares `[native-dependencies] <name> = { ...,
mode = "load" }` opens that library by its bare name, and its tests run against the
file the lock pins: `system_libs` of `mopm.lock`, written by `mopm lock` of mopm
0.0.83 or later, which makes the committed graph unit graph format 3. The check
fails, naming the package, for a declared load whose lock has no `system_libs`
(a lock an older mopm wrote), for a platform subdir the lock records a toolchain for
and `system_libs` has no library for, and for a package whose sources call
`OwnedDLHandle(`, `DLHandle(` or `dlopen(` in code while no manifest
declares a load (the pins would be missing without the declaration saying so). A
comment, a string literal and a docstring that name a call are skipped; the source
reading is lexical and tracks only those. The manifest reading accepts every
spelling mopm's reader accepts for `mode = "load"` of a native dependency (inline
table, `[native-dependencies.<name>]` table, dotted key, quoted key, literal string). The
reading is in `lock_graphs.zig` (`declaresLoad`, `opensLibrary`, `checkSystemLibs`),
behind unit tests that call each with a clean and a defective input.

**The aggregate holds no Python.** Python serves only the Python SDK and its
tests (`PYTHON_SURFACE` in `tests/python_closure_allowlist.bzl`: the binding
tests and `python/`), so the checks of `EXCLUDED` in `rules.bzl` are left out of
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
names the targets and the way out (a row of `EXCLUDED`, then write the roots again).
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
