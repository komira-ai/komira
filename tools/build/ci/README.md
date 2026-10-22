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
lists are generated and checked in (`ci/targets.bzl`):

```sh
./buck2 bxl komira//tools/build/ci/targets.bxl:generate > ci/targets.bzl
```

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
also fails on a label in the list that no longer exists.

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
