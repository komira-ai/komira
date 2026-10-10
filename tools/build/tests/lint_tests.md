# Repository lint tests

The sections of [the tests](README.md) for the lints that hold the
repository's own tree: test welding, README API coverage, the layout of
`src/`, the surface capability matrix and refused imports. Each keeps its number; [`run_tests.sh`](run_tests.sh) runs them with
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
ledger row by its path, `src/tests/helpers/komira_e`) whose ledger
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
(named `*_e2e` or `*_loopback`), `conformance` (`*_conformance`) or `helpers`
(neither). An `*_e2e`, `*_loopback` or `*_conformance` package directly under
`src/` is a finding, and so is a `komira_test_*` one its `shipped` list does
not name, a `shipped` name that is no package there, and any package not at
one of the two places. `//:src_layout` in the root [`BUCK`](../../../BUCK)
reads the packages from the build graph (the root package's subpackages, the
nearest directories holding a BUCK file), so it is declared in every checkout
and a new package is checked with no edit to a BUCK file. Given a `map` (the
root target names [docs/architecture.md](../../../docs/architecture.md#the-module-map)),
it also reads the module map's table rows, so a new package needs its row
there: every package under `src/` has
exactly one row whose link is its directory and whose name is the
directory's, and no row links a directory under `src/` that is not a
package. The root call must name `map`: without it the
macro fails at load, so the map check cannot be dropped silently.
[`functional/src_layout:ok`](functional/src_layout/BUCK) is a planted list
([`fixture.bzl`](functional/src_layout/fixture.bzl): a package of each kind,
a `*_loopback` under `e2e`, a shipped `komira_test_*`, a name holding `e2e`
without ending in it, and an `*_e2e` package outside `src/`) that must pass;
each target of [`negative/src_layout`](negative/src_layout/BUCK) adds one
defect to it and must fail naming it; the `map_*` ones plant a defect in the
map ([`map.txt`](functional/src_layout/map.txt)): a package with no row, a
row for a package that is gone, two rows for one package, a misnamed row.

```sh
./buck2 build //:src_layout tests//functional/src_layout:ok
./buck2 build tests//negative/src_layout:top_e2e   # must fail: //src/komira_foo_e2e: a test-only package directly under src/
./buck2 build tests//negative/src_layout:map_missing_row   # must fail: //src/komira_new: no row in ...
```

## 53. The surface capability matrix

Product coverage is every capability of the plan exercised through every
surface by an end-to-end test of that surface.
[`surface_capability_matrix`](../lint/surface_capability_matrix.bzl) is a
validation over its ledger, one row per (surface, capability) naming the test
target that exercises the capability, or `-`. It writes the census
(`[matrix]`, `[report]`) and never fails on a missing cell. It fails on a row
that is malformed or lies: an unknown surface or capability, a pair with two
rows or none, an empty field, a target outside its surface's own package
exactly (`src/tests/e2e/<surface>_e2e`, read from where Buck2 puts the
target, not from the label's text: not a subpackage, not a longer name), a
target whose default outputs another package's target made (an alias of a
test elsewhere), a target that is no test (no `ExternalRunnerTestInfo`, no
welded `test_srcs`), one test filling two cells of a surface, and a target
that does not exist (the macro makes every named target a dependency, so
Buck2 refuses the graph; a target incompatible with the lint's platform fails
it too, even under a pattern). It also fails when the vocabulary is not
grounded in the plan: a capability naming a constant no grounding file
declares (as `comptime <ID>: UInt8 = <n>` or `comptime <ID> = UInt8(<n>)`),
a constant of a grounding family (a prefix such as `PLAN_` or `EXPR_`) that
no capability and no `NOT_CAPABILITIES` row names or that is written in
another form, a capability listed twice; and when fewer cells are filled than
its `floor` (that the floor only rises is a review rule). The ledger is
[`tests/surface_capability_matrix.bzl`](../../../tests/surface_capability_matrix.bzl);
the rules and today's census are in
[`docs/surface_capability_matrix.md`](../../../docs/surface_capability_matrix.md).
[`functional/surface_capability_matrix:ok`](functional/surface_capability_matrix/BUCK)
holds a planted matrix ([`fixture.bzl`](functional/surface_capability_matrix/fixture.bzl):
two surfaces, five capabilities, two grounding files with near misses (a
constant of type `Int`, a commented-out one, an indented one) and an
unannotated `UInt8(16)` constant that must be read, and three cells filled by
real `mojo_library` and `mojo_test` targets in planted `pandas_e2e` and
`polars_e2e` packages, one named by a cell-relative label), whose census must
equal
[`expect_matrix.tsv`](functional/surface_capability_matrix/expect_matrix.tsv)
and [`expect_report.txt`](functional/surface_capability_matrix/expect_report.txt)
byte for byte. Each target of
[`negative/surface_capability_matrix`](negative/surface_capability_matrix/BUCK)
plants one defect in the same lists and must fail naming it (five of them
must name exactly one finding); the planted targets they name are a
test-less library, an alias of a test outside `src/tests/e2e`, a
subpackage and a longer-named package of the pandas package, and a macOS-only
test, which
[`negative/surface_capability_matrix/incompatible.BUCK`](negative/surface_capability_matrix/incompatible.BUCK)
names and which is built by its package pattern. That file and
[`dangling.BUCK`](negative/surface_capability_matrix/dangling.BUCK) (a row
naming a target that does not exist) are no BUCK files: either, loadable,
fails every cquery over `tests//...`, so run_tests.sh copies each into its
directory for its one build and deletes it. The lint only analyses the
e2e targets; `tests//functional/...` builds them.

```sh
./buck2 build //:surface_capability_matrix tests//functional/surface_capability_matrix:ok
./buck2 build tests//negative/surface_capability_matrix:alias           # must fail: ... stands for a target of tests//functional/surface_capability_matrix
# after run_tests.sh's copy of incompatible.BUCK to incompatible/BUCK:
./buck2 build tests//negative/surface_capability_matrix/incompatible:   # must fail: ... because its transitive dep .../pandas_e2e:test_mac
```

## 55. Refused imports

A package's `mojo_deps` lint ([`defs.bzl`](../lint/defs.bzl)) can name
`refused_imports`: dotted modules (`komira_x.y`) that no file of the package
may import, nor any module under them, while the package that holds them
stays a dep (komira_optimizer refuses the physical-plan modules of
komira_plan_ir). The reader is
[`refused_imports.awk`](../lint/refused_imports.awk), which says the import
forms it reads and what it misreads (it reads characters, not Mojo tokens).
[`functional/refused_imports:ok`](functional/refused_imports/BUCK) builds over
[`near.mojo`](functional/refused_imports/near.mojo), which spells each refused
module where it is not an import of it: in comments (one with a parenthesis
inside an open import list), docstrings, string literals, longer module names
(`physical_planner`, `physical_plan_x`, `x.<module>`), a name imported
from another module, `x .method()` and calls over lines on other names, and
aliases of modules that hold no refused one. Each target of
[`negative/refused_imports`](negative/refused_imports/BUCK) holds one import
form and must fail naming exactly its one finding: `from M`, `from M.sub`,
`from P import N`, an import list over lines in parentheses (plain, with a
parenthesis in the comment of its first line, with one in a name's comment),
`import M`, `import M as p`, `import M.sub`, `import a, M`, statements split by
`;`, a `\` continuation, an indented import, an import after a docstring
that spells one, after a `"""` docstring holding `'''`, after `'"""'` (a triple
quote inside a one-line string), `from`/`import` with spaces around the
dot, and a dotted reference with no import of the module: plain
(`komira_x.y.Z()`), spaced, continued by `\`, over lines inside
parentheses, through an `as` alias of its parent and through a name a
from-import bound (`alias_from`, whose refused module is one level deeper). `bad_entry` names an entry that is not a dotted komira_*
module name and is refused at analysis.

```sh
./buck2 build tests//functional/refused_imports:ok
./buck2 build tests//negative/refused_imports:paren_comment_open   # must fail: paren_comment_open.mojo:3: imports komira_plan_ir.physical_plan
```
