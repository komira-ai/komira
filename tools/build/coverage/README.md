# covcheck: coverage numbers, the PR check run and the build gate

`covcheck` reads coverage reports (kcov's Cobertura XML first, lcov
tracefiles too, and the branch records of `branch/`), maps every file in them to a file of the repository and its
package, and measures each package's line and branch coverage of its whole
source. It holds the numbers to the policy (a target, per-package floors that
may only rise, and no surviving mutant among the mutation results it is
given: no build action gives it any today) and lists every exemption for a
reviewer's approval (it does not check approval itself), and writes:

- `covcheck report`: a Markdown summary, the request bodies of a GitHub check
  run (annotations included) and a JSON result, for a pull request;
- `covcheck gate`: one package's numbers and findings, for the build gate
  ([The build gate](#the-build-gate)).

Both commands run the same computation (`covcheck/analyze.mojo`),
so the PR check and the build gate cannot disagree on the same reports; a
welded test holds the gate's JSON entry for a package equal to the
report's. The PR check reads the same reports, a library's `coverage_tests`
runs included ([The coverage workflow](#the-coverage-workflow), step 4).

| target | what it is |
|---|---|
| `:covcheck` | the library (`covcheck/*.mojo`), its tests welded |
| `:covcheck_bin` | the command line (`main.mojo`, dispatching to `covcheck/cli.mojo`) |
| `:ratchet.tsv` | the floors (`ratchet.tsv`) |
| `:cov_gate` | the directory every mojo_library's coverage gate runs from: `cov_gate.sh`, `covcheck_bin`, `ratchet.tsv` ([The build gate](#the-build-gate)) |
| `policy.bzl` | the gate's mode and target, and the ledger of libraries that cannot have a gate of their own |
| `no_gate.bxl` | the check that holds that ledger equal to the libraries the gate depends on |
| `branch_gate.bxl` | the check that every row of `COVERAGE_BRANCH_GATE` (`policy.bzl`) names a library: a row naming none is read by nothing (test 46) |
| `mutate/` | the mutation tool: `:mutate` (the library, its tests welded), `:mutate_bin`, `:mut_dir` (what every library's `[mutation]` runs from) ([Mutation score](#mutation-score)) |

## What line coverage means here

The denominator is each measured package's full source. A line counts when
the compiler emitted code for it in some test binary (its report record),
and every executable line of a source file that no test binary compiled
counts too, uncovered (see "Files no test compiled"), so a file nobody
tests cannot leave a package reading 100%.

What is still missing: inside a file some test compiled, a function no test
reaches emits no lines at all (Mojo compiles a function only when something
the test reaches calls it, a generic once per instantiation), so it is
absent from the report rather than uncovered. covcheck lists the functions
none of whose lines has a record (see "Functions with no recorded line"),
which holds those and some a test does call, and counts none of them yet,
so these numbers are upper bounds.

## Command line

```text
covcheck report --repo-files F --diff F --head-sha SHA --source-root DIR
                (--cobertura [PKGDIR=]F | --lcov [PKGDIR=]F)... [--branch-lcov [PKGDIR=]F]...
                [--mutants [PKGDIR=]F]...
                [--strip-prefix P]... --ratchet F [--mode census|neutral|enforce]
                [--target-bp N] [--include-tests] [--info-package DIR]... [--name N]
                [--max-annotations N] --summary-out F --checkrun-dir D --result-out F
                [--annotations-out F] [--ratchet-out F]

covcheck gate   --package DIR --repo-files F --source-root DIR
                [--cobertura [PKGDIR=]F | --lcov [PKGDIR=]F]... [--branch-lcov [PKGDIR=]F]...
                [--mutants [PKGDIR=]F]...
                [--strip-prefix P]... --ratchet F --mode census|neutral|enforce
                [--target-bp N] [--include-tests] [--test-source P]... [--info-package DIR]...
                --result-out F --summary-out F
```

Every input is a flag; nothing is read from the environment.

| flag | meaning |
|---|---|
| `--repo-files F` | the output of `git ls-files -z` (NUL-terminated paths): the repository's files |
| `--source-root DIR` | the checkout; the sources of measured files are read from it for exemption markers, and the files no test compiled for their executable lines |
| `--cobertura [PKGDIR=]F`, `--lcov [PKGDIR=]F` | a report, repeatable (one per test binary), all of one format: the two formats identify a line's branches differently, so mixing them is bad usage. `PKGDIR` is the package the report's relative paths may be relative to; a file name holding `=` is given as `=F`. `report` needs at least one; `gate` takes none for a library with no test, whose package is then `NotMeasured` |
| `--branch-lcov [PKGDIR=]F` | a branch record file (`branch/README.md`, cov_branch_classify: one per test binary), repeatable, read with either line format: branches only, never lines (see Reading the reports). It is no line report: `report` still needs a `--cobertura` or `--lcov` |
| `--mutants [PKGDIR=]F` | a mutation-testing result, repeatable (format below) |
| `--strip-prefix P` | repeatable; a report path starting with `P` loses it (the longest matching prefix wins) |
| `--ratchet F` | the floors file (format below) |
| `--mode` | `census`, `neutral` (the default of `report`) or `enforce`; `gate` requires it |
| `--target-bp N` | the target, basis points 0 to 10000; default 10000 (100%) |
| `--include-tests` | count test sources (left out by default) |
| `--test-source P` | `gate`: repeatable; the repository path of a test source of `--package` outside its `tests/` (a welded test elsewhere), left out like those; a path that is not a file of `--repo-files` or not in `--package` is an error (exit 1) |
| `--info-package DIR` | repeatable; `DIR` (a trailing `/` dropped; an absolute path, `.` or one holding `//` is bad usage) and every package under it, at a path-segment boundary, are test-only: see Test-only packages |
| `--diff F` | the output of `git diff --no-color --no-ext-diff --src-prefix=a/ --dst-prefix=b/ --unified=0 -M <merge-base> <head>` (the explicit prefixes override a `diff.noprefix` setting) |
| `--head-sha SHA` | the commit the check run is for: 40 lowercase hex digits |
| `--name N` | the check run's name; default `coverage` |
| `--max-annotations N` | `report`: at most `N` annotations go into the check run (1 or more; default 1000); see Annotations |
| `--annotations-out F` | `report`: every annotation, uncapped, as a JSON array of GitHub annotation objects (for upload as a build artifact) |
| `--package DIR` | the package `gate` measures: a directory holding a BUCK file |
| `--summary-out F` | the Markdown summary |
| `--checkrun-dir D` | the check-run request bodies (created if absent; must be empty) |
| `--result-out F` | the JSON result |
| `--ratchet-out F` | the proposed floors file |

### Exit codes

`report` exits 0 whenever it wrote its outputs, whatever they conclude: in
enforce mode a failing package fails the PR through the check run's
`conclusion: "failure"`, never through the exit code. `gate` exits 3 in
enforce mode when the package has a finding, so the build fails.

| code | meaning |
|---|---|
| 0 | the outputs were written, whatever they conclude (`report` never carries the conclusion in its exit code) |
| 1 | an input is malformed (each reader names the file and line, or the byte's line), branch record files disagree on a location's decisions, a file has branch data from both a line report and a branch record file, a report path is unmapped, a source cannot be read, `--checkrun-dir` is not empty, `--package` holds no BUCK file, or an output cannot be written |
| 2 | bad usage: no or unknown command, an unknown flag, a flag without its value or given twice, a required flag missing, no report (`report`), both `--cobertura` and `--lcov` reports, a malformed `--mode`, `--target-bp` or `--head-sha`, a `--max-annotations` that is not a number of 1 or more |
| 3 | `gate` only: `--mode enforce` and the package has at least one finding |

## Reading the reports

**Cobertura** (`covcheck/cobertura.mojo`) accepts
kcov's shape: an `<?xml ...?>` declaration, a `<!DOCTYPE coverage SYSTEM ...>`,
tab indentation, `<coverage>` / `<sources>` / `<packages>` / `<package>` /
`<classes>` / `<class filename=...>` / `<lines>` / `<line number= hits=>`.
Attributes come in any order with `"` or `'` quotes, `<line>` may be
self-closing or closed by `</line>`, and `&amp; &lt; &gt; &quot; &apos;` are
decoded in attribute values. Only `filename`, `number`, `hits`, `branch` and
`condition-coverage` carry data: every `*-rate`, `*-covered`, `*-valid`,
`complexity`, `timestamp` and `version` attribute is ignored (kcov writes
`branch-rate="1.0"` with no branch data, and that is no branch coverage).
A line `branch="true"` with `condition-coverage="NN% (k/n)"` has `n` branches,
`k` taken. `<source>` elements are ignored: they are the absolute paths of
the sandbox the tests ran in, so a class's `filename` is mapped as written.
The `<lines>` of a `<method>` repeat the class's and are not read. Refused,
naming the line: non-blank text outside the root element (a UTF-8 byte order
mark included), a tag never closed, a mismatched end tag, an unquoted or
valueless attribute, an attribute given twice in one tag, an unknown entity
(numeric character references included), CDATA or any other `<!` markup, a
DOCTYPE with an internal subset, a root that is not `<coverage>`, a second
root, a `<class>` inside a `<class>`, a `<class>` with no `filename`, a
`<line>` with no `number` or `hits`, a value that is not a decimal number, a
`<line>` number of 0 or above 10^9, a `branch` value other than
`true`/`false`, a branch line without a well-formed `condition-coverage`, or
one claiming more than 4096 branches.

**lcov** (`covcheck/lcov.mojo`) reads `TN`, `SF`, `FN`,
`FNDA`, `FNF`, `FNH`, lcov 2.2's `FNL:<index>,<line>[,<end line>]` and
`FNA:<index>,<count>,<name>`, `DA:<line>,<hits>[,<checksum>]`,
`BRDA:<line>,[e]<block>,<branch>,<taken|->`, `BRF`, `BRH`, `LF`, `LH` and
`end_of_record`. Counts come from `DA` and `BRDA` only; the summary and
function records are checked to be numbers and otherwise ignored. `-` means
the branch's block never ran: the branch counts, not taken. lcov 2's `e`
before a block marks an exception branch, counted as a branch of its own. A
branch id may hold commas (lcov 2 writes an expression). Refused, naming
`<file>:<line>`: a carriage return, a line that is not a record, an unknown
record type, a malformed number, a line number of 0 or above 10^9, a `DA`
with fewer than 2 or more than 3 fields, a `BRDA` with fewer than 4 fields or
an empty branch id, a data record outside `SF` .. `end_of_record`, an `SF`
or `TN` inside a record, an `SF` naming no file, an `end_of_record` outside a
record, and a last record without `end_of_record`.

A path named in several records or reports (one report per test binary) is
merged by summing hits per line (and per branch), so a line any test reached
is covered. Cobertura gives no branch identity, so two reports' `k of n` on
one line merge as the first `k` of `n` taken in each.

**Branch record files** (`--branch-lcov`, `covcheck/branch_lcov.mojo`) are
what `cov_branch_classify` writes per test (`branch/README.md`,
"cov_branch_classify"): `SF:<path>`, then
`BRDA:<line>,<col>:<kind>:<n>/<N>,<arm>,<taken|->` lines, then
`end_of_record`; an empty file is a test that ran none of the library's
code. `<kind>` is `br`, `select`, `switch` or `rhs`; `<N>` is how many
decisions of that kind one copy of the code holds at that line and column
and `<n>` which one; arms are numbered from 0. Only these three records
are read: a `DA` (line data comes from the line reports alone), `LF`,
`BRF`, `FN`, `TN` or any other is refused, naming `<file>:<line>`, as is a
blank line, a carriage return, a record outside `SF` .. `end_of_record`, an
`SF` naming no file or a file named twice, a `BRDA` without exactly four
fields, a block that is not `<col>:<kind>:<n>/<N>`, another kind, a line or
column of 0, `<n>` not below `<N>`, a malformed arm or count, the same arm
twice, and a last record without `end_of_record`; at each `end_of_record`,
a decision whose arms are not 0 to k-1 (two for `br`, `select` and `rhs`,
two or more for `switch`) and a location missing one of its `N` decisions.
A branch is identified by `<line>,<col>:<kind>:<n>/<N>,<arm>` (numbers
without leading zeros), and an arm's counts are summed across files by that
id; `-` (the decision's code never ran) is counted and not taken, so it
adds nothing: `-` and `n` give `n`, two `-` an arm not taken. One test's
classifier cannot see another's copies of the code, so two files that give
one location (line, column, kind) a different `N`, or one decision a
different number of arms, are refused, naming the file, the line and both
files: their records cannot be summed by id. (Two copies holding the same
number of decisions but different ones cannot be told apart here; see
`branch/README.md`, "Known shapes".) The branches join the file of the same
repository path from the line reports; a file whose line report gives
branch data too (Cobertura `condition-coverage`, lcov `BRDA`) is refused:
one source of branch data per file. A file only branch record files name
(no line record) is counted as a file no test compiled (its lines from its
source, `UnmeasuredFile`), with its branches.

## From a report path to a repository file

Each path (`covcheck/paths.mojo`), in this order:

1. The longest `--strip-prefix` it starts with (at a `/` boundary) is removed.
2. A Buck2 output path, holding a segment `__<name>__` followed by a segment of
   16 or more hex digits (`buck-out/v2/art/komira/src/m/__m__/fedcba9876543210/src/m/x.mojo`),
   becomes what follows the hex segment (`src/m/x.mojo`).
3. A relative path that is a repository file is that file.
4. With `PKGDIR=`, a relative path that is not a repository file is tried as
   `PKGDIR/path` (kcov writes a test's own sources package-relative:
   `tests/test_decide.mojo`). If that is not a file either, the path is
   unmapped when `PKGDIR/<first segment>` is a repository directory, or when
   it has no `/` (a source directly in the package) and `PKGDIR` is a
   repository directory.
5. What is left: an absolute path is outside the repository; a relative path
   whose first segment is a top-level directory of the repository
   (`src/...`) is **unmapped**, an error (exit 1) naming every such path; any
   other relative path (`oss/modular/mojo/stdlib/...`, the Mojo standard
   library) is outside. Outside files are ignored and counted in the summary.
6. One exception to unmapped: a welded test's generated main (the layout
   probe a `mojo_aws_client` or `mojo_gcp_client` generates) is named by its
   output path in the package (`src/m/gen/<name>/_layout_probe.mojo`), which
   the gate stages and the checkout lacks. In a test's own report
   (`.../cov/tests/<stem>.xml`, or `.../cov/branch/<stem>.info`), a path
   named `<stem>.mojo`, in a package, whose directory is none of the
   repository's, is that test: counted as a test source and left out (with
   `--include-tests` too: it has no source). Any other unmapped path stays
   an error.

A file's package is the nearest directory above it holding a `BUCK` file
(`src/m/x/y.mojo` is in `src/m`); `(root)` when only the top directory holds
one; an error when none does. Files under `tests/` directly inside a package
(`src/m/tests/...`) are test sources: left out of the numbers, the changed-line
coverage and the annotations, and counted in the summary, unless
`--include-tests`. Only that directory is, and for `gate` each
`--test-source` (the build gate names every test the library welds, so a
test elsewhere in its package is left out too): any other test file or test
helper in the package (`src/m/testing.mojo`, `src/m/x/tests/t.mojo`) is
source, measured and held to the target like any other file.

## Files no test compiled

A package is measured when a report names one of its files, with or
without a record for it (a test source left out does not count), and the
package `gate` checks always is. Every `.mojo` file of a measured package
in `--repo-files` (its package is the nearest directory with a BUCK file)
that no report gives a line or branch record, and that is not a left-out
test source, is read from `--source-root` and counted: each of its
executable lines is a line found with 0 hits. A file a report names with
no record (an lcov `SF:` followed straight by `end_of_record`, a Cobertura
class with no line) is counted this way too: it measured nothing.
Exemption markers apply to those lines as to any other. Such a file with a
line left counted is an `UnmeasuredFile` finding (its path, `line` 0, and
`count`, the lines it counts) and, in a touched package, annotated `File
not compiled into any test`, one annotation per run of consecutive
executable lines not exempted (an exempted line ends a run). A file with
no line left counted (an `__init__.mojo` of re-exports, a file whose every
executable line is exempted) raises no `UnmeasuredFile` and is not in
`unmeasured_files`; its markers are listed like any other.

The executable lines are a heuristic over a lexed source
(`covcheck/lexer.mojo`): no test binary holds any code of such a file,
so nothing the compiler wrote can say which lines would have code. A line
is executable unless it is:

- blank (spaces, tabs, form feeds);
- a comment only (its first non-blank byte outside a string is `#`);
- inside, or made only of, string literals: a docstring, a line of a
  triple-quoted string spanning lines, the line that closes one, or a line
  holding nothing but a string (`"..."`, `r"""..."""`);
- part of an import statement: a line whose first word is `import` or
  `from` followed by a space or tab, and the lines after it while its
  parentheses are open (`from x import (` .. `)`) or a line ends with a
  backslash. A `;` outside every string ends the statement, so
  `import os; os.abort()` is executable (and `import a; import b` is not).

A UTF-8 byte-order mark at the start of the file and a carriage return at
the end of a line (CRLF) are not part of the line.

Everything else counts, declarations included (`def`, `struct`,
`comptime`, a decorator, a lone `)`), except a trait's header and its
requirements, which emit no code: a requirement is a `def` inside a
`trait` block whose body is only `...` (after an optional docstring), or a
`def` line ending in `: ...`, and its decorators, signature lines and `...`
line are not executable. A trait method with a default body counts. A
`trait` block runs from its header (with the lines its open brackets
carry) to the next line holding code at the header's indent or less. So a
file of traits only, such as a package's interface declarations, has no
executable line.

Except in a **declaration-only** file (`declaration_only` in
`covcheck/decls.mojo`, whose declaration reader is the one authority on
which declarations are functions and which are requirements, with a body of
`...` alone): one in which that reader finds no function, every declaration
it finds is a requirement inside a trait's block, and every other statement
outside the
imports is, at the top level, a `trait` header or a `comptime`
declaration, and in a trait's block a `comptime` declaration, a decorator
or `...`. Such a file, if it has no exemption marker and no branch record,
counts no line and is not counted as a file; it raises
`DeclarationOnlyFile`, information in every package (`info_findings`, its
`count` the lines it would have counted), never a failure. The test is
conservative: a free function, a struct, a default method body with code
(even `pass`), a statement, a `;` outside an import, a tab in the
indentation, a statement still open at the end of the file, a file the
lexer ends inside a string, a carriage return not followed by a line feed
all keep the file counted. It assumes (and does not check) that a
`comptime` initialiser and a requirement's default-argument expressions
are computed at compile time and emit no code to run. A known limit: the
lexer reads a backslash before a quote as an escape in a raw string too, so
contrived text that puts it out of step with the compiler and back in step
before the end of the file can hide a line of code from the heuristic and
from this test alike.

## Functions with no recorded line

Report only: these lists change no number and raise no finding.

A report holds the lines the compiler emitted code for in a test binary:
kcov lists exactly the DWARF line rows of the measured sources. A function
no test reaches has no row, so in a file some test compiled it is not
uncovered but absent. For each kept file with a line record, covcheck reads
the functions the source declares (`covcheck/decls.mojo`) and lists every
function none of whose lines has a record in any report: package, path,
`def` line, name, `class`, and `lines`, its executable lines (the heuristic
above) that carry no exemption marker with a reason. A function whose every
line is so marked is not listed. A file with branch records and no line
record lists none.

No record is not the same as no test calling it. Each function has a class,
and the result JSON splits them:

| class | when | JSON | trust |
|---|---|---|---|
| `plain` | neither below | `unrecorded_functions` | evidence no test reaches it; the class a census counts |
| `always_inline` | a decorator line right above it starts with `@always_inline` | `unrecorded_functions_unreliable` | none: the body is inlined into its callers and what is left may be attributed to the caller's lines or folded away |
| `comptime_if` | its body (a nested function's lines included) holds a `comptime if` or `@parameter` line, wherever: one such line moves the whole function, and a closure holding one moves the function around it | `unrecorded_functions_unreliable` | none: a body folded to a constant, or wholly in an arm dropped on this platform or build, emits no line though tests call it |

Known false positives, all seen on real reports: an `@always_inline` body
whose code the compiler attributed to the caller (a test calls it, its
caller's lines are hit, its own `return` line has no record); a
comptime-branched constant folded at the call site; a body that is
entirely a dropped `comptime if` arm (an instrument compiled in only with a
build flag); and, in the `plain` class too, a function only another
operating system compiles (a macOS-only kqueue backend's functions read as
unrecorded on linux) and a function reached only through such a dropped
arm (its only caller is never compiled here). So the `plain` list of a
library with platform-gated code is not yet a list of untested functions.

- A declaration is a `def` or `fn` line (code, not in a string). The
  signature runs until its `(` `)` and `[` `]` close; code after its `:` on
  that line is a one-line body; otherwise the body runs until the first
  code line indented no deeper than the `def` (a docstring line further
  left, or a line that starts inside a string, does not end it).
- A body of only `...` (a trait's requirement), or none, is no function;
  `pass` is.
- A nested function owns its lines, and is recorded or not on its own: a
  recorded closure does not make the function around it recorded.
- A file no test compiled lists no function: its lines are already counted
  ("Files no test compiled").

It cannot see a `comptime if` arm the compiler dropped inside a recorded
function (the unit is the whole function), nor a function the compiler
emits without line rows (a `nodebug` function may be one; not measured).
Why the line records and not the DWARF subprograms: in a coverage test
binary the library's functions (compiled from its precompiled package)
have no named `DW_TAG_subprogram` at all, only a compile unit named
`<unknown>` with a line table, and a line-tables-only subprogram carries no
`decl_file` or `decl_line` anyway; the line rows are the one place a
library function shows up.

## Exemptions

A line no test can reach is exempted in the source by an end-of-line comment:
the line's comment (its first `#` outside every string literal), at the
start of the line or after a space or tab, is exactly the bytes
`# cov: unreachable`, then one space and the reason. It exempts the line it
is on and nothing else. Anything else is not a marker: `#cov:`,
`# cov:unreachable`, `# Cov: unreachable`, `# cov: unreachable:`, a `#`
right after code, a marker after a quote, inside a string literal or a
docstring (on one line or several), or after another comment's text
(`# see # cov: unreachable`). The source is lexed (`covcheck/lexer.mojo`):
`"..."` and `'...'` strings, triple-quoted strings spanning lines, a
backslash keeping the next quote from closing any string (raw strings
included, as in Python), string prefixes such as `r`; a trailing carriage
return (CRLF) is dropped first. The files measured in the reports and the
files no test compiled are read (`--source-root`).

| marker on | status | effect |
|---|---|---|
| a line recorded with 0 hits | `exempt` | the line leaves the line count, its branches the branch count |
| a line that was hit (or has no line record) with a branch never taken | `exempt branches` | the line stays counted (covered); its branches leave the branch count |
| a line that was hit, every branch on it taken | `stale` | none; a `StaleExemption` finding |
| a line with no record and no untaken branch | `no record` | none |
| any line, with no reason | `no reason` | none; an `ExemptionWithoutReason` finding |

Every marker is listed in the summary under "Exemptions (need approval)" and
in the result JSON, and is a `notice` annotation in touched packages. The
tool does not check approval: a marker with a reason takes its line out of
the counts as soon as it is in the source, and approving it is the
reviewer's part.

## The mutants file

The contract a mutation tool writes to (`covcheck/mutants.mojo`):
lines starting with `#` are comments; every other line is exactly five
tab-separated fields:

```text
<path>	<line>	<status>	<operator>	<description>
```

`<path>` is mapped like a report path; `<line>` is a number from 1 to 10^9;
`<status>` is `killed`, `survived`, `timeout` or `error`; `<operator>` is not
empty; `<description>` may be. Only `killed` kills: `timeout` and `error` are
counted apart and are neither killed nor survived. The mutation score is
`killed * 10000 / total` basis points. Each surviving mutant is a
`MutantSurvived` finding and an annotation. Refused, naming `<file>:<line>`:
a carriage return, an empty line, another number of fields, a malformed line
number, an unknown status, an empty path or operator.

The decision (`policy.bzl`, `COVERAGE_BRANCH_GATE`): once a package's
branch coverage is enforced, mutation testing is not its enforced gate;
its branch arms are. Today no build action passes `--mutants`, so
mutation never gates a package. covcheck itself does not treat mutants
apart: given `--mutants`, a surviving mutant is a `MutantSurvived`
finding, and in enforce mode any finding fails `gate` (exit 3).
Making mutation results report-only there is future work.

## Numbers and findings

All numbers are integers. A percentage is basis points,
`hit * 10000 / found` rounded down (2 of 3 is 6666, shown `66.66%`); a package
with nothing found is `n/a`. Per package: line (records found, records with
hits > 0), branch (only when the package has a branch record), mutants.

| finding | when |
|---|---|
| `BelowTarget` | line, or branch when measured, below `--target-bp` (labelled `(census)` in census mode) |
| `BranchNotMeasured` | a package (not a file: one branch record anywhere in the package clears it) with a line record has no branch record in any report (before exemptions), and no branch record file names one of its kept files, while `--target-bp` is above 0: its branch coverage cannot be shown to meet the target, so it is not passing. kcov's Cobertura has no branch data, so with kcov alone every measured package has it, and enforce mode cannot pass on line coverage alone; the summary shows the branch column `not measured`. A branch record file names every measured file its test holds code of, one with no decision with no `BRDA` (`SF:` then `end_of_record`), so a package with no decision at all whose gate reads the records does not have it: its branches are measured, with none to take (test 46's `covfull`; `covfull_unread`, whose gate does not read them, has it) |
| `NotMeasured` | a package in the run (in `gate`, the gated package) has no line record from a report and no exempted recorded line while `--target-bp` is above 0: no report covers it, or none of its paths mapped to it (the lines of files no test compiled do not make it measured) |
| `Regression` | line or branch below its ratchet floor; or a floor above 0 whose value was not measured (no data, `measured_bp` null): in `report` for every row whose directory holds a BUCK file, in `gate` for its package's row |
| `MissingRow` | lines were measured and the ratchet has no row for the package |
| `ExtraRow` | a ratchet row's directory holds no BUCK file (`report` checks every row; `gate` its package's) |
| `BranchFloorMissing` | branches were measured and the row's branch floor is `-` |
| `MutantSurvived` | a surviving mutant |
| `UnmeasuredFile` | a source file of a measured package that no report names still has lines counted (see Files no test compiled) |
| `DeclarationOnlyFile` | information, never counted: a file no report names is declaration-only and counts no line (see Files no test compiled) |
| `BranchUnmeasuredFile` | a file with a line record, in a package one of whose kept files a branch record file names, that no branch record file names and whose line report gives no branch record of its own: cov_branch_classify names every measured file its test holds code of (a decision-free one with no `BRDA`), so this file's branches were not read, and counting them as none would lift the package's branch number. A failure in enforce mode, listed in census mode, as `UnmeasuredFile` is |
| `ExemptionWithoutReason`, `StaleExemption` | see Exemptions |

Conclusion: `neutral` in census and neutral mode whatever was found; in
enforce mode `failure` with any finding, else `success`.

### Test-only packages

A package that is an `--info-package DIR` or under one (`src/tests` covers
`src/tests/e2e/x`, not `src/testsuite`) is measured, counted in the totals
and shown as every package is, but held to no target: whatever the policy
would find in it (every kind above, `BelowTarget` and the ratchet's
included, so a `Regression` below a row the package has) is information.
Those findings move from `findings` to `info_findings` in the result
(which also lists the measured test-only packages, `info_packages`), so
they count for no conclusion and no `gate` exit 3: a test-only package's
gate never fails on a finding, in any mode. An input covcheck refuses
(exit 1 or 2) still fails it. `--ratchet-out` proposes no row for a
test-only package (a row it has is kept as it was), so test-only packages
have no floor. The summary's status
column says `info` (with the kinds, `info: BelowTarget, MissingRow`), its
findings are listed under `### Info: test-only packages, declaration-only
files (N)` (with every `DeclarationOnlyFile`), the target
line names the directories, the title counts them (`N info`), and the
annotations of its files are `notice` in every mode. The policy names the
directories (`COVERAGE_INFO_ONLY_DIRS`, The build gate).

## The build gate

With `-c komira.coverage=true`, every `mojo_library` on linux-x86_64 has a
coverage build (`tools/build/mojo/README.md`, "Coverage builds"):
each test's -O0 binary is run under kcov and gives a Cobertura report in
repository paths (`kcov/README.md`, "cov_run"). The gate is one more
action per library, `mojo_cov_gate` (`cov_gate.sh`, run from
`:cov_gate`):

1. The library's sources are staged at their repository paths: every
   `srcs` file that is a source (a generated one is not measured), every
   test source (a generated one at its output path in the package), and a
   BUCK file at the package's directory, so covcheck's nearest-BUCK rule
   names the package. A tests-cell package is under
   `tools/build/tests/`. Each test source is also named to covcheck
   (`--test-source`), so a welded test outside the package's `tests/`
   (`wire/tests/test_x.mojo`, a test at the package's top) is set aside as
   those under it are, not measured as the library's source.
2. `--repo-files` is every file of that tree (sorted, NUL-separated): the
   gate sees each source of the library, so a source no test compiled is an
   `UnmeasuredFile` (its executable lines count, uncovered) and a library
   with no test is `NotMeasured`; the test sources are left out of the
   numbers.
3. `covcheck gate --package <dir> --mode <M> --target-bp <N> --ratchet
   ratchet.tsv --test-source <test>... --cobertura <report>...
   [--branch-lcov <records>...]`, one report per test (none for a library
   with no test), and for a library of `COVERAGE_BRANCH_GATE`
   (`policy.bzl`) or a fixture of the tests cell (unless it passes
   `coverage_branch_gate = False`) each test's branch records
   (`[coverage][branch_info][<test>]`, `branch/README.md`); they are in
   repository paths, so no `PKGDIR=` is given; and `--info-package
   <dir>` for a test-only package (`COVERAGE_INFO_ONLY_DIRS` below). Its `result.json` and
   `summary.md` are the library's `[coverage][gate]`
   (`[coverage][gate][result]`, `[coverage][gate][summary]`).

**The README's examples and the `mojo_test` targets a library names** are
its tests too (`tools/build/mojo/README.md`, "Coverage builds"; line
coverage only). The README's run is one more report, `[coverage][tests][readme]`,
which names the program it ran under `buck-out/readme/`: not a repository
file, so covcheck counts it outside the repository and only the library's
lines it reached count. A library naming `coverage_tests` cannot depend on
those tests (they depend on it), so its gate is the target
`<name>_cov_gate` (as a library of the ledger's, below): it runs each
named test's -O0 binary under kcov against the library's sources
(`<name>_cov_gate[tests][<test>]`, through the same `cov_run.sh`) and runs
the same gate over the library's reports and those
(`<name>_cov_gate[gate]`). A named test's source is staged at its
repository path: in the library's package it is a `--test-source`; in
another package it is staged with a BUCK file at that package, so its
lines are another package's, which the gate does not measure. The
library's conda package waits for that gate and those runs. A named test
must depend on the library directly and have a source main and no `args`
(a coverage run passes none), or `<name>_cov_gate` fails at analysis
(test 46's `covmt_stray_cov_gate`, `covmt_args_cov_gate`).

Exit 0 writes the gate's marker. Exit 3 (enforce mode, a finding) fails the
action with `COVERAGE GATE FAILED (enforce): <package> (<label> [coverage
gate]): covcheck gate exited 3`, `The conda package (<name>_conda) is not
produced until its coverage meets the policy; the library and its
dependents still build.` and the summary; exits 1 and 2 (an input
covcheck refuses, bad usage) fail it in every mode with `COVERAGE GATE ERROR`
and covcheck's message: a malformed ratchet fails a census gate too (test
46). Census and neutral mode never fail on a finding.

**What the gate blocks: the shipped package, nothing else.** The library's
conda package (`<name>_conda`, `tools/build/package/conda.bzl`: both its
`conda_join` and its `conda_release_join`, the `[release]` an uploader
reads) waits for the gate's marker and every coverage run's, which the
library hands it in its `MojoCoverageGateInfo`: a test failing at -O0 or
under kcov leaves the conda package unbuilt with coverage on, and so does a
gate failing in enforce mode. A gate that reads branch records waits for
every branch coverage action of the library's tests, so for such a library
a test failing instrumented, or a branch the classifier refuses, leaves the
conda package unbuilt as well, in every mode. A library with no test has a
gate too (`NotMeasured`), and its conda package (a refused one, since it
has no test) waits for it as well.

The library itself does not wait: its package (`mojo_gate_join`) waits for
its tests alone, as with the switch off, so the library builds, and every
dependent compiles and runs its tests against it, whatever the library's
coverage. A red coverage run or gate keeps the package it measures from
shipping and is on no other target's path (test 46: `covlow_user` builds
against `covlow`, whose gate is red). With the switch off nothing waits for
them. Bundles and OCI images (`tools/build/package/defs.bzl`) do not wait
for the gates of the libraries their program is built from: a program's
libraries are not packages it ships.

**Platforms.** Coverage is measured on linux-x86_64 and never on another
platform (decided: `coverage-linux-x86-64` in
`tools/build/platforms/limits.tsv`; kcov and the LLVM pieces of
branch coverage are pinned for linux-x86_64 only). On another target
platform `-c komira.coverage=true` is a no-op, not an error: the coverage
attributes are None (a `select` in `tools/build/mojo/coverage.bzl`), so a
library and a shared library have the actions they have with the switch
off, and no `[coverage]` (test 41's `coverage_platforms.sh`, on
darwin-arm64).

**Shared libraries.** A `mojo_shared_lib` has a gate too, over its
drivers' reports (each driver run under kcov measuring the library it
loads; `tools/build/mojo/README.md`, "Coverage builds") and its own
sources, in `COVERAGE_SHARED_LIB_MODE` (`policy.bzl`), census: its line
coverage is reported, never enforced. That is its own constant, so moving
`COVERAGE_MODE` to enforce moves no shared library; `enforce` there, or as
any `mojo_shared_lib`'s `coverage_mode` (a fixture of the tests cell
included), is refused in analysis (test 46). Nothing waits for
a shared library's coverage runs or gate: it ships no conda package, and
its published file waits for its release gate alone. Its gate is reported
when its `[coverage]` is built by name: the coverage workflow
(`.github/ci/coverage_measure.sh`) selects `mojo_library` targets only, so
no workflow reports a shared library's gate yet. A shared library's report
counts its own sources (its C ABI layer), not the code compiled into it
from its Mojo dependencies (an engine's), which their own tests measure in
their own gates.

**Policy** (`policy.bzl`): `COVERAGE_MODE = "census"` and
`COVERAGE_TARGET_BP = 10000`, and `COVERAGE_INFO_ONLY_DIRS = ["src/tests"]`:
test-only packages (`src/` holds what komira ships, and its test-only
packages are under `src/tests/<kind>/`: e2e tests, conformance suites, test
helpers). A library whose package's directory, relative to its cell's root,
is one of these or under one is held to no target: the rule passes its
package to covcheck as `--info-package`, so it is measured and shown (the
gate's summary and result, and the pull request's check run) and what
covcheck finds is information, never a finding (Test-only packages): its
gate never fails on a finding, in any mode, so its conda package is never
held back by a finding (a test failing at -O0 or under kcov, or an input
covcheck refuses, still holds it back), and it gets no ratchet floor. An
entry must be a relative directory (no empty, `.` or `..` segment, no
trailing `/`): `tools/build/mojo/coverage.bzl` fails at load otherwise,
and `coverage_measure.sh` refuses the line. The rule is a path prefix, not a list of packages: a new
package under `src/tests/` is test-only with no edit here, and one
anywhere else is held to the target (`src/testsuite` included: the match
is at a path-segment boundary). Test 46 builds a library of
`tests//src/tests/coverage` (the tests cell's `src/tests`) below the target
green in enforce mode, beside the same library red elsewhere. A fixture of the `tests` cell may name another mode
(`coverage_mode`), and with it its own gate directory (`coverage_gate`, a
`cov_gate_dir` with another ratchet or script); anywhere else both are
refused at load, and at analysis (a BUCK file calling the rule itself) a
mode other than the policy's, a link, run, branch or gate directory other
than komira's, a gate reading branch records (`coverage_branch_gate`) for a
library not in `COVERAGE_BRANCH_GATE` or not reading them for one in it, or
coverage runs with no gate for a library not in the ledger is refused.
These refusals are outside the
tests cell, so test 46 cannot plant them there: test 7
(`tests/functional/umbrella_cache.sh`) plants each in a consumer
repository's own cell.

**Before enforce.** Enforce mode is not reachable with kcov alone, so it
is not a one-line change today:
- kcov reports no branch, so every measured package whose gate reads no
  branch records (every library but those of `COVERAGE_BRANCH_GATE`;
  `coverage_branch_gate` in `tools/build/mojo/coverage.bzl`) has
  `BranchNotMeasured` (below) and fails in enforce mode whatever its line
  coverage. Enforce needs that list to hold the libraries (the classifier
  refuses shapes most libraries have today; `branch/README.md`), or a
  decided split of the target into a line target and a branch target that
  stays 0 until then.
- A library whose sources are all generated (a `mojo_aws_client` or
  `mojo_gcp_client`: its hand-written sources pass through the generator
  too) stages no source, so its gate is `NotMeasured` and fails in enforce
  mode; its hand-written code is never measured. It needs measuring (by
  its repository path) or a documented exemption.
- **Open decision: files only a README or a `coverage_tests` run reaches,
  in a library whose gate reads branch records.** Those runs give line
  coverage only, so such a file has line records and no branch record:
  `BranchUnmeasuredFile` (listed in census mode, failing in enforce mode).
  `komira_scalar_arithmetic` has four such files (its README reaches them,
  its one test does not). Before enforce, decide between branch records for
  those runs, a test that reaches the files, or accepting the finding; the
  gate does not change this today.

**The ledger** (`COVERAGE_NO_GATE` in `policy.bzl`): the gate
runs `covcheck_bin`, so the Mojo libraries `covcheck_bin` depends on
(`covcheck`, `komira_json`, and `readme_examples`, whose tool runs the
examples of their README) cannot have the gate as an action of their own:
the library would depend on the gate's directory, which depends on
`covcheck_bin`, which depends on the library. That is a cycle of configured
targets (a dependency of the rule, whatever waits for the gate's output),
so it stays with the gate blocking only what ships. Each has a row with its
reason; their gate is the target `<name>_cov_gate`, the same action over
the library's `MojoCoverageGateInfo`, which their conda package waits for
(with their coverage runs, as every library's does). `no_gate.bxl` fails
unless the ledger names exactly the Mojo libraries `:cov_gate` depends on,
the ledger is within the frozen list `_CEILING` in the same file (so it
only shrinks: a new row also needs a reviewed edit of that list), and each
one's conda package waits for its gate (test 46).

```sh
./buck2 bxl //tools/build/coverage/no_gate.bxl:check -c komira.coverage=true
```

A check that builds only the libraries a change affects sees no coverage
failure unless it also builds their conda packages (`<name>_conda`, an
rdep of the library in its own package), which wait for every gate,
`<name>_cov_gate` included:

```sh
./buck2 build komira//src/komira_retry:komira_retry_conda -c komira.coverage=true
```

**Branch coverage**: kcov reports none; the branch records of `branch/`
are the source, read by the gate of a library of `COVERAGE_BRANCH_GATE`
(`policy.bzl`, each row with its evidence: every library whose tests'
branches all classify and hold an arm, as the sweep of every library found
them, among them `komira_retry`, whose census gate reads 73 of 74 arms,
and `komira_json`, whose `komira_json_cov_gate` reads them) and of every
fixture of the tests cell
but those passing `coverage_branch_gate = False` (test 46's
`covfull_unread`).
Every other measured package has `BranchNotMeasured`; in census mode it is
listed, in enforce mode it fails. Line coverage alone is never read as
meeting a line-and-branch target. The finding is per package: a package
one of whose files has a branch record does not have it; a package with no
decision at all, whose records name its files with no arm, has its
branches measured with none to take. In a package whose branch records are
read, a file with line records that no branch record file names is
`BranchUnmeasuredFile`: its branches were not read, so the package's
branch number would leave it out. The
pull request's check run (`coverage_measure.sh`, [The coverage
workflow](#the-coverage-workflow)) reads the same branch records for the
same libraries, so for a library of `COVERAGE_BRANCH_GATE` its summary
shows the branch number the gate measures (unless the records or the gate
failed to build: then it lists the library as branch not measured).

```sh
./buck2 build 'komira//src/komira_retry:komira_retry[coverage][gate]' -c komira.coverage=true
```

## The ratchet

`ratchet.tsv`: comment lines start with `#`; a row is
`<package>\t<line floor>\t<branch floor>`, floors in basis points, the branch
floor `-` when there is none, rows sorted by package in byte order, each
package once; anything else is refused naming the line. The shipped file
has no rows: the floors arrive with the first coverage runs, as the file
`--ratchet-out` proposes: every floor raised to what was measured
(`max(floor, measured)`), a row added for each measured package without one,
the rows of directories without a BUCK file dropped, the comment lines kept
first. A value above its floor is never a finding; copying the proposal in is
how a floor rises. Every package in the reports and every row is compared,
not only the packages a change touches: `report` expects the reports of
every package, and a row whose package has no data is a `Regression`, so a
floor cannot be escaped by dropping a package's tests or report.

## Outputs of `report`

**Changed lines** (`covcheck/annotate.mojo`), informational
only (no threshold): the added or modified new-side lines of the diff, keyed
by new path (a rename moves lines to the new path; a pure rename, a deletion,
a binary file and a mode change add none; git's C-quoted paths are
unquoted), in files of measured packages whose extension is one of the
measured files'. Each is covered, uncovered, exempt, or not instrumented (no
record, including a file absent from the reports), never counted as covered.
A carriage return inside a hunk body is file content (a CRLF file's changed
line) and is kept. The diff reader (`covcheck/diff.mojo`) refuses, naming
`<diff file>:<line>`: text before the first `diff --git`, a line that is no
diff header or hunk line, a carriage return outside a hunk body, a hunk
before `+++`, a hunk body that disagrees with its counts, a hunk line number
above 10^9, a path without the `a/`/`b/` prefix, a malformed quoted path.

**Touched packages**: the package of every path the diff names, old and new:
the `---`/`+++` paths, `rename from`/`rename to`, `copy to`, and the paths of
the `diff --git` line when they can be told apart (each quoted, or the same
path twice), so a binary file, a mode change and an empty new or deleted file
touch their package too. A copy's source is unchanged and touches nothing.

**Annotations** (one list, sent 50 per request): for every measured file of
every touched package, changed files first, each group by path then line:
`Line not covered` per run of uncovered lines (a run continues over lines
with no record and breaks at a covered or exempt line), `File not compiled
into any test` per run of consecutive executable lines not exempted of a
file no test compiled, `Branch not covered`
per line some of whose branches were not taken (`k of n branches taken on
this line`), `Mutant survived` per surviving mutant, `Coverage exemption`
(`notice`) per marker. Level `warning` in census and neutral mode, `failure`
in enforce mode; `notice` in every mode for a test-only package's files.

The check run carries the first `--max-annotations` (default 1000) of that
list, in that order, and the summary then says
`N annotations omitted (cap M); the full list is in the annotations file`
(or, without `--annotations-out`, that the full list was not written).
The order is what makes the cap safe: the changed files come first, so the
"Files changed" view, where a reviewer reads them, keeps its annotations
when a large package's other files are cut. `--annotations-out` writes the
whole list, uncapped.

**Summary** (`covcheck/summary.mojo`): a title line
(total line and branch, changed lines), the caveat above, the mode, the
annotations the cap left out (only when it left some out), a table of
every measured package (touched first: line, branch, mutants, floor, status)
and a total row,
the findings, the exemptions, the changed lines with at most 200 uncovered
ranges listed (the rest counted), and what was set aside (files outside the
repository, test sources, mutants). The check run carries it cut at a line
end to GitHub's 65535 with a closing line saying how many bytes were left
out and that the `--summary-out` file has it whole (the result JSON holds
every number, not the summary text).

**Check run** (`covcheck/checkrun.mojo`): `000.json` is
the body of `POST /repos/{owner}/{repo}/check-runs`
(`name`, `head_sha`, `status: "in_progress"`, `output` with `title`,
`summary` and the first 50 annotations); `001.json`, ... are the bodies of
the PATCHes that follow (`output` with the next 50), the last one also
`status: "completed"` and `conclusion`. There is always at least one PATCH:
0 to 100 annotations make two files, 120 make three, 1000 (the default cap)
make 20. Sorted file order is send order. The title is cut to 255 bytes.

For the poster: GitHub's secondary rate limits apply to these
content-creating requests. Send the files one at a time, in order (never
in parallel), at no more than about 80 per minute; the default cap bounds a
run at 20 requests (1 POST and 19 PATCHes).

**Result** (`covcheck/result.mojo`): `conclusion`,
`mode`, `target_bp`, `total`, `diff`, `touched_packages`, `packages`,
`findings`, `exemptions`, `unrecorded_functions` and
`unrecorded_functions_unreliable` (report only: see "Functions with no
recorded line") and the set-aside counts; `gate` writes `package`
in place of `total`, `diff`, `touched_packages` and `packages`. A percentage
or floor that does not apply is `null`. A package's `files` counts every
file in its numbers and `unmeasured_files` those that raised
`UnmeasuredFile` (no report gave them a record, and a line is left counted); a
finding about a whole file has `line` 0, and `count` is the lines an
`UnmeasuredFile` counts (`null` for every other finding).

## The coverage workflow

`.github/workflows/coverage.yml` (workflow `coverage`) shows a pull
request's line coverage, and the branch coverage of the libraries whose
gate reads branch records, as the check run `coverage`: covcheck's summary and
its annotations on the lines of the "Files changed" view. It is
informational. It is not `pr / check`, it is not a required check, and its
result cannot make `pr / check` red; its conclusion is `neutral` in census
mode (the policy's today). Making it required, or switching coverage on in
`pr / check` itself, waits for the tree-wide sweep of tests that fail at
`-O0` or under kcov: today such a library's conda package is unbuilt in a
coverage build (its dependents build). Like `pr / check` it runs only for a
pull request from a branch of this repository, and only for one whose base
is `main` (`pull_request: branches: [main]` filters on the base): a pull
request stacked on another branch gets no coverage run until it is
retargeted to `main` and then pushed to (a retarget alone is an `edited`
event, which the workflow does not listen for). A pull request whose head
commit predates the workflow (it has no `.github/ci/coverage_measure.sh`)
is not measured: `measure` prints a notice to merge `main` into the branch
and skips its later steps and the `post` job: `measure` is green with the
notice, `post` is skipped, and no `coverage` check run is posted.

Job `measure` (`contents: read`, and `id-token: write` for the farm
connection) checks out the pull request's head commit with its history and
runs `.github/ci/coverage_measure.sh` (its header has the details):

1. the diff from the merge base of the base and head commits to the head,
   as `--diff` above;
2. the packages of the changed paths (old and new), each the nearest
   directory holding a BUCK file, leaving out the paths of the other cells'
   directories (the `tests` cell's libraries are fixtures, some failing by
   design);
3. the `mojo_library` targets of those packages, each with its
   `coverage_branch_gate` (`buck2 uquery -c komira.coverage=true
   "kind('^mojo_library_rule$', set(//<package>: ...))" --output-attribute
   '^coverage_branch_gate$'`): whether its gate reads its tests' branch
   records. The attribute is what mojo_library sets from
   `COVERAGE_BRANCH_GATE` and the gate reads, so the script's list is the
   gate's own rather than a second parse of `policy.bzl`;
4. one `buck2 build -c komira.coverage=true --keep-going --build-report F
   '<library>[coverage][tests]'...` of all of them, with
   `'<library>[coverage][branch_info]'` beside each library whose gate reads
   branch records (the farm builds them in parallel; that gate already
   waits for those records): their tests' reports, their gates and those
   branch records. Each library's verdict is its entry in the build report
   (one per library, both sub-targets' outputs in it): `SUCCESS`, or `FAIL`
   with only errors of its own gate's action (`mojo_cov_gate` owned by the
   library: an enforce finding or a gate error) or of its own branch
   coverage actions (`mojo_emit_cov_bc`, `mojo_cov_pgo_link`,
   `mojo_cov_branch_run`, `mojo_cov_branch_annotate`,
   `mojo_cov_branch_classify`; the cases hold this list equal to
   `coverage_branch.bzl`'s), every run built, is measured, from the entry's
   `cov/tests/*.xml` paths (`--show-output` prints no path for a sub-target
   with several outputs; buck2 lists what did build for a failed target
   too). Any other failure lists the library as `not measured (coverage
   build failed)`, in the summary and in the check run's summary, and none
   of its reports is used; the job stays green. A dependency's failed run
   or gate does not reach the library's runs (nothing of a library waits
   for coverage, only its conda package does), so a library is measured
   whatever its dependencies' coverage. A measured library whose records are
   read gives its entry's `cov/branch/*.info` paths when the entry is
   `SUCCESS` (one per report of a test, the README's `cov/tests/readme.xml`
   left out: its run has no branch records; another count fails the job,
   as a tool error). The README's report is read like a test's. For a
   library naming `coverage_tests` (a second query,
   `attrregexfilter(coverage_tests, '.', ...)`), the same build also asks
   for `<name>_cov_gate[tests]`, the runs of those tests: that entry must
   be `SUCCESS` (else the library is not measured) and its
   `cov/tests/*.xml` are the library's reports too, so the check run reads
   what its gate reads. When its branch coverage actions failed, or its gate did (which
   reads the same records with covcheck, so `report` could refuse them
   too), none of its records is read and it is listed as `branch not
   measured`, with the reason, in both summaries; the job stays green;
5. `covcheck report` over the reports of the libraries measured and their
   branch records (`--branch-lcov`), with the
   policy's mode and target, each directory of its
   `COVERAGE_INFO_ONLY_DIRS` as an `--info-package` (the root cell's root
   is the repository's, so a directory relative to it is a repository
   directory; a test-only package's findings are information, so they
   neither fail the check run in enforce mode nor annotate above `notice`),
   `git ls-files -z` as `--repo-files`, the head
   as `--head-sha`, and the ratchet's comment lines and the rows of the
   measured libraries' packages only (`report` compares every row it is
   given, and a row of a package not measured here would read as a
   `Regression`). With no report at all (no library touched, none
   measured, none has a test, or the query failed), the script writes the
   summary and a neutral two-body check run itself, in covcheck's shape.

It writes the summary to the job's step summary and uploads the bodies,
`summary.md`, `result.json`, `annotations.json` (every annotation) and the
lists of libraries (touched, reading branch records, not measured, branch
not measured) as an artifact, and no build log (a job log is masked for
the farm's address; an artifact is not).

Job `post` has `checks: write` and nothing else. It checks nothing out and
runs no file of the pull request: it downloads the artifact and sends the
bodies with `gh api`, `000.json` as the POST for the head commit and every
later body as a PATCH, in file order, one second apart. The poster is
written in the workflow (between its `# post_checkrun:` marker lines) and
first checks the bodies' shape: numbered from `000.json` with no gap,
`000.json` naming the check `coverage` and the head commit, the last body
completing the run. This is a check of shape, not a trust boundary: the
bodies come from the pull request's code, which can edit the workflow too. A
failed POST sends nothing more; a failed PATCH fails the job. The poster
keeps the created run's id in a file until its last PATCH; the job's last
step (`if: failure() || cancelled()`, its function between the
`# complete_checkrun:` markers) PATCHes a run that file still names to
completed, `neutral` with the title `coverage: posting failed`, or
`cancelled` when the job was cancelled (a newer push cancels the older
run), so that no run stays in progress on the head commit. A cancel that
ends the job before that step's PATCH is sent still leaves the run in
progress. The artifact has one name in every attempt of the run
(`coverage-<head sha>`, uploaded with `overwrite`), so "Re-run failed jobs"
on `post` alone finds what the first attempt's `measure` uploaded.

What only a run on GitHub shows: the welded cases (`//:coverage_ci_cases`,
`.github/ci/tests/coverage_ci_cases.sh`) run the poster and the completing
function against a stand-in `gh` over bodies the real covcheck wrote for 0,
1, 51 and 120 annotations; the measure script against stand-ins for git
and buck2 (whose query answers and build reports have buck2's shape; two
reports are ones buck2 wrote, for a library failing in its gate alone and
for one whose branch records failed to build beside its built runs) with
the real covcheck, a listed library's branch records included; and they hold the workflow's text for the calls and the artifact
name. First seen on a real pull request: GitHub's API answers, the
artifact's round trip and a re-run of `post` alone, whether the `if:`
conditions run the completing step after a failure, a cancel or a
timeout, the farm build of real coverage targets from the runner, how GitHub
draws the annotations, and which check suite the run is drawn under (a run
created with the workflow's token joins a GitHub Actions suite of the head
commit, possibly shown beside `pr / check`). The cases run under busybox
`sh` and `awk`; on the runner the measure script runs under dash and mawk
and the poster under bash. The first such run is that of the first pull
request to `main` after the workflow exists there, or of the one adding it
once it is retargeted to `main` and pushed to.

Welded tests outside a package's `tests/`
(named to `gate` with `--test-source`) have no `report` flag yet, so the
check run counts them as that package's source where its gate does not.

## Example

```mojo
from std.testing import assert_equal, assert_true
from covcheck.exempt import marker_in
from covcheck.text import basis_points, render_bp

var m = marker_in("    abort()  # cov: unreachable the caller checked n > 0")
assert_true(m.found)
assert_equal(m.reason, "the caller checked n > 0")
assert_true(not marker_in("    abort()  #cov: unreachable no").found)
assert_equal(render_bp(basis_points(2, 3)), "66.66%")
```

## Mutation score

The branch-strength measure where branch coverage is not enforced
(report-only): what a mutant is, how they are sampled and built, and the
score are in `tools/build/coverage/mutation.md` in the repository.

## Tests

Welded in `:covcheck` (see the comment per test in `BUCK`), over
hand-made fixtures in `tests/fixtures/`, including a
trimmed real kcov report (sandbox and content hashes replaced) and an
end-to-end case whose summary is compared byte for byte with
`tests/fixtures/e2e/summary.md`.
