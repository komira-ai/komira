# covcheck: coverage numbers, the PR check run and the build gate

`covcheck` reads coverage reports (kcov's Cobertura XML first, lcov
tracefiles too), maps every file in them to a file of the repository and its
package, and measures each package's line and branch coverage of its whole
source. It holds the numbers to the policy (a target, per-package floors that
may only rise, no surviving mutant) and lists every exemption for a
reviewer's approval (it does not check approval itself), and writes:

- `covcheck report`: a Markdown summary, the request bodies of a GitHub check
  run (annotations included) and a JSON result, for a pull request;
- `covcheck gate`: one package's numbers and findings, for the build gate.

Both commands run the same computation (`covcheck/analyze.mojo`),
so the PR check and the build gate cannot disagree; a welded test holds the
gate's JSON entry for a package equal to the report's.

| target | what it is |
|---|---|
| `:covcheck` | the library (`covcheck/*.mojo`), its tests welded |
| `:covcheck_bin` | the command line (`main.mojo`, dispatching to `covcheck/cli.mojo`) |
| `:ratchet.tsv` | the floors (`ratchet.tsv`) |

## What line coverage means here

Line coverage counts only the lines the compiler emitted code for. A Mojo
function that no test reaches may emit no lines at all (a generic that is
never instantiated is never compiled), so it is absent from the report rather
than uncovered: these numbers are upper bounds until declaration
reachability lands.

## Command line

```text
covcheck report --repo-files F --diff F --head-sha SHA --source-root DIR
                (--cobertura [PKGDIR=]F | --lcov [PKGDIR=]F)... [--mutants [PKGDIR=]F]...
                [--strip-prefix P]... --ratchet F [--mode census|neutral|enforce]
                [--target-bp N] [--include-tests] [--name N]
                --summary-out F --checkrun-dir D --result-out F [--ratchet-out F]

covcheck gate   --package DIR --repo-files F --source-root DIR
                (--cobertura [PKGDIR=]F | --lcov [PKGDIR=]F)... [--mutants [PKGDIR=]F]...
                [--strip-prefix P]... --ratchet F --mode census|neutral|enforce
                [--target-bp N] [--include-tests] --result-out F --summary-out F
```

Every input is a flag; nothing is read from the environment.

| flag | meaning |
|---|---|
| `--repo-files F` | the output of `git ls-files -z` (NUL-terminated paths): the repository's files |
| `--source-root DIR` | the checkout; the sources of measured files are read from it for exemption markers |
| `--cobertura [PKGDIR=]F`, `--lcov [PKGDIR=]F` | a report, repeatable (one per test binary), all of one format: the two formats identify a line's branches differently, so mixing them is bad usage. `PKGDIR` is the package the report's relative paths may be relative to; a file name holding `=` is given as `=F` |
| `--mutants [PKGDIR=]F` | a mutation-testing result, repeatable (format below) |
| `--strip-prefix P` | repeatable; a report path starting with `P` loses it (the longest matching prefix wins) |
| `--ratchet F` | the floors file (format below) |
| `--mode` | `census`, `neutral` (the default of `report`) or `enforce`; `gate` requires it |
| `--target-bp N` | the target, basis points 0 to 10000; default 10000 (100%) |
| `--include-tests` | count test sources (left out by default) |
| `--diff F` | the output of `git diff --no-color --no-ext-diff --src-prefix=a/ --dst-prefix=b/ --unified=0 -M <merge-base> <head>` (the explicit prefixes override a `diff.noprefix` setting) |
| `--head-sha SHA` | the commit the check run is for: 40 lowercase hex digits |
| `--name N` | the check run's name; default `coverage` |
| `--package DIR` | the package `gate` measures: a directory holding a BUCK file |
| `--summary-out F` | the Markdown summary |
| `--checkrun-dir D` | the check-run request bodies (created if absent; must be empty) |
| `--result-out F` | the JSON result |
| `--ratchet-out F` | the proposed floors file |

### Exit codes

| code | meaning |
|---|---|
| 0 | the outputs were written, whatever they conclude (`report` never carries the conclusion in its exit code) |
| 1 | an input is malformed (each reader names the file and line, or the byte's line), a report path is unmapped, a source cannot be read, `--checkrun-dir` is not empty, `--package` holds no BUCK file, or an output cannot be written |
| 2 | bad usage: no or unknown command, an unknown flag, a flag without its value or given twice, a required flag missing, no report, both `--cobertura` and `--lcov` reports, a malformed `--mode`, `--target-bp` or `--head-sha` |
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

A file's package is the nearest directory above it holding a `BUCK` file
(`src/m/x/y.mojo` is in `src/m`); `(root)` when only the top directory holds
one; an error when none does. Files under `tests/` directly inside a package
(`src/m/tests/...`) are test sources: left out of the numbers, the changed-line
coverage and the annotations, and counted in the summary, unless
`--include-tests`.

## Exemptions

A line no test can reach is exempted in the source by an end-of-line comment:
the exact bytes `# cov: unreachable`, at the start of the line or after a
space or tab, then one space and the reason. It exempts the line it is on and
nothing else. Anything else is not a marker: `#cov:`, `# cov:unreachable`,
`# Cov: unreachable`, `# cov: unreachable:`, a marker after a quote or a `#`.
The scan is textual (a string literal holding the marker after a space reads
as one). Only the files measured in the reports are read (`--source-root`).

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

## Numbers and findings

All numbers are integers. A percentage is basis points,
`hit * 10000 / found` rounded down (2 of 3 is 6666, shown `66.66%`); a package
with nothing found is `n/a`. Per package: line (records found, records with
hits > 0), branch (only when the package has a branch record), mutants.

| finding | when |
|---|---|
| `BelowTarget` | line, or branch when measured, below `--target-bp` (labelled `(census)` in census mode) |
| `NotMeasured` | a package in the run (in `gate`, the gated package) has no line record and no exempted line while `--target-bp` is above 0: no report covers it, or none of its paths mapped to it |
| `Regression` | line or branch below its ratchet floor; or a floor above 0 whose value was not measured (no data, `measured_bp` null): in `report` for every row whose directory holds a BUCK file, in `gate` for its package's row |
| `MissingRow` | lines were measured and the ratchet has no row for the package |
| `ExtraRow` | a ratchet row's directory holds no BUCK file (`report` checks every row; `gate` its package's) |
| `BranchFloorMissing` | branches were measured and the row's branch floor is `-` |
| `MutantSurvived` | a surviving mutant |
| `ExemptionWithoutReason`, `StaleExemption` | see Exemptions |

Conclusion: `neutral` in census and neutral mode whatever was found; in
enforce mode `failure` with any finding, else `success`.

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
with no record and breaks at a covered or exempt line), `Branch not covered`
per line some of whose branches were not taken (`k of n branches taken on
this line`), `Mutant survived` per surviving mutant, `Coverage exemption`
(`notice`) per marker. Level `warning` in census and neutral mode, `failure`
in enforce mode.

**Summary** (`covcheck/summary.mojo`): a title line
(total line and branch, changed lines), the caveat above, the mode, a table of
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
0 to 100 annotations make two files, 120 make three. Sorted file order is
send order. The title is cut to 255 bytes.

**Result** (`covcheck/result.mojo`): `conclusion`,
`mode`, `target_bp`, `total`, `diff`, `touched_packages`, `packages`,
`findings`, `exemptions` and the set-aside counts; `gate` writes `package`
in place of `total`, `diff`, `touched_packages` and `packages`. A percentage
or floor that does not apply is `null`.

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

## Tests

Welded in `:covcheck` (see the comment per test in `BUCK`), over
hand-made fixtures in `tests/fixtures/`, including a
trimmed real kcov report (sandbox and content hashes replaced) and an
end-to-end case whose summary is compared byte for byte with
`tests/fixtures/e2e/summary.md`.
