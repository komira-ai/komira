# Repository lint tests

The sections of [the tests](README.md) for the lints that hold the
repository's own tree: test welding, README API coverage and the layout of
`src/`. Each keeps its number; [`run_tests.sh`](run_tests.sh) runs them with
the rest.

## 39. Test welding

A test file that no target welds never runs, and nothing else notices.
[`test_weld`](../lint/test_weld.bzl) is a lint over the packages under
`src/` (each directory directly under it, and each `src/tests/<kind>/<name>`:
`src/tests` holds the test-only packages and is not one itself). It requires every `test_*.mojo`
under a `tests/` directory to be welded, and every package with a `.mojo`
source to weld a test. What is welded is read from the build graph, not from
the text of a BUCK file: the `test_srcs` of every `mojo_library` and the
`main` of every `mojo_test` under `src/` (its binary runs `main` only), as the
rules received them. A query of the graph gives the targets; each rule gives
its test files in a `WeldedTestsInfo` ([`providers.bzl`](../mojo/providers.bzl)),
and Buck2 says where each file is. So a list a BUCK file computes counts entry
by entry, an entry left in a comment does not, and an entry naming another
package's file by label welds that file, not a same-named one.
The exceptions are the rows of
[`tests/known_untested.tsv`](../../../tests/known_untested.tsv), each with its
reason, and that ledger only shrinks: a row whose test is welded, or whose
package welds a test, is a finding, as is a row naming nothing. `//:test_weld`
in the root [`BUCK`](../../../BUCK) holds the repository to them.

[`functional/test_weld:ok`](functional/test_weld/BUCK) is a planted tree
([`fixture.bzl`](functional/test_weld/fixture.bzl): a computed `test_srcs`
list holding an entry in a comment, a helper under `tests/`, a nested test, a
test welded by a target of its own, a package with no `.mojo`, and under
`src/tests/` a test-only package that welds its test and one that has a
ledger row by its path, `src/tests/support/komira_e`) whose ledger
holds it exactly, and each target of
[`negative/test_weld`](negative/test_weld/BUCK) plants one defect in the same
tree and must fail naming it; `shrink_computed` is a ledger row for a test
welded only by the computed list. That tree's welds come from a stand-in rule;
[`negative/test_weld/real`](negative/test_weld/real/BUCK) runs the lint over a
real `mojo_library` (a computed `test_srcs` with an entry in a comment and an
entry naming another package's file by label) and a real `mojo_test` (a
second `srcs` beside its `main`): `real:ok` holds the three unwelded files in
its ledger and must pass, `real:red` has no row and must name exactly those
three. Neither is built: the lint only analyses them.

A rule cannot query the targets of `//src/...` (a query attribute takes
labels only), so building a `test_weld` target checks nothing: it declares the
lint, and [`test_weld.bxl`](../lint/test_weld.bxl) checks it, running the
check as a build action whose inputs are the list of `.mojo` paths, the list
of welded paths and the ledger. The pull request's check runs it for each
`test_weld` target of a unit it builds
([`build_targets.sh`](../../../release/ci/build_targets.sh)); this test runs it
for each target above.

```sh
./buck2 bxl //tools/build/lint/test_weld.bxl:check -- --lint //:test_weld
./buck2 bxl //tools/build/lint/test_weld.bxl:check -- --lint tests//functional/test_weld:ok
./buck2 bxl //tools/build/lint/test_weld.bxl:check -- --lint tests//negative/test_weld:untested   # must fail: .../src/komira_b: 1 .mojo source(s) and no welded test
```

## 40. README API coverage

A package's README examples are its smoke tests (test 38), so a public name
no example uses is a public name nothing smoke-tests.
[`readme_api_coverage`](../lint/readme_api_coverage.bzl) is a validation
that counts, per package under `src/` (not the test-only ones under
`src/tests/`, which publish no API), the public API its `__init__.mojo`
exports (and the public methods of the structs among it) and which of it the
README's examples use, reading each README through the tool the gate runs, so
hidden lines count and prose does not. It writes the census (`[packages]`,
`[symbols]`, `[report]`) and is report-only today; it fails on its ledger,
[`tests/readme_api_exceptions.tsv`](../../../tests/readme_api_exceptions.tsv),
when a row is malformed, repeated, or names a symbol that is not exported or
that the README now uses (the ledger only shrinks). The rules and today's
numbers are in [`docs/readme_api_coverage.md`](../../../docs/readme_api_coverage.md).
[`functional/readme_api_coverage:ok`](functional/readme_api_coverage/BUCK)
builds a planted tree ([`fixture.bzl`](functional/readme_api_coverage/fixture.bzl):
an alias, a parenthesised and a backslash-continued import, a self-qualified
import, a module export, declarations in `__init__.mojo`, overloads, a
docstring `def`, a struct in `tests/`, a struct header over three lines, a
same-named struct outside the imported module, a `write_to`, hidden lines, a
name only in a comment, a string, an import line, a README declaration, a
`text` fence or prose, a package with no README, one with no example, one
the readme tool refuses, a `from .x import *`, one with no `__init__.mojo`)
whose census must equal
[`expect_packages.tsv`](functional/readme_api_coverage/expect_packages.tsv),
[`expect_symbols.tsv`](functional/readme_api_coverage/expect_symbols.tsv)
and [`expect_report.txt`](functional/readme_api_coverage/expect_report.txt)
byte for byte; each target of
[`negative/readme_api_coverage`](negative/readme_api_coverage/BUCK) plants one
defect in the same tree and must fail naming it, `enforce = True` included.

```sh
./buck2 build //:readme_api_coverage tests//functional/readme_api_coverage:ok
./buck2 build tests//negative/readme_api_coverage:stale_used   # must fail: komira_a bye: src/komira_a/README.md uses it now
```

## 45. The layout of src/

`src/` holds what komira ships, one package per directory; a package that
exists only to test others is under `src/tests/`, by kind
([architecture](../../../docs/architecture.md#end-to-end-tests)).
[`src_layout`](../lint/defs.bzl) is a validation over the packages under
`src/`: each is `src/<name>`, or `src/tests/<kind>/<name>` with kind `e2e`
(named `*_e2e` or `*_loopback`), `conformance` (`*_conformance`) or `support`
(neither). An `*_e2e`, `*_loopback` or `*_conformance` package directly under
`src/` is a finding, and so is a `komira_test_*` one its `shipped` list does
not name, a `shipped` name that is no package there, and any package not at
one of the two places. `//:src_layout` in the root [`BUCK`](../../../BUCK)
reads the packages from the build graph (the root package's subpackages, the
nearest directories holding a BUCK file), so it is declared in every checkout
and a new package is checked with no edit.
[`functional/src_layout:ok`](functional/src_layout/BUCK) is a planted list
([`fixture.bzl`](functional/src_layout/fixture.bzl): a package of each kind,
a `*_loopback` under `e2e`, a shipped `komira_test_*`, a name holding `e2e`
without ending in it, and an `*_e2e` package outside `src/`) that must pass;
each target of [`negative/src_layout`](negative/src_layout/BUCK) adds one
defect to it and must fail naming it.

```sh
./buck2 build //:src_layout tests//functional/src_layout:ok
./buck2 build tests//negative/src_layout:top_e2e   # must fail: //src/komira_foo_e2e: a test-only package directly under src/
```
