## Coverage: line 40.00% (4/10), branch 50.00% (1/2); changed lines 0.00% (0/2)

Line coverage counts the lines the compiler emitted code for, and every executable line of a package's source file that no test binary compiled (`UnmeasuredFile`). Still missing: a function no test reaches inside a compiled file emits no lines at all, so these numbers are upper bounds; the result JSON lists the functions none of whose lines has a record (`unrecorded_functions`) without counting them.

Mode: **neutral**, conclusion **neutral**. Target: 100.00% line and branch coverage per package.

### Packages

| package | line % (hit/found) | branch % (hit/found) | mutants killed/total | floor line / branch | status |
|---|---|---|---|---|---|
| `src/alpha` (touched) | 25.00% (2/8) | 50.00% (1/2) | 1/2 | - | BelowTarget, MissingRow, MutantSurvived, UnmeasuredFile |
| `src/beta` | 100.00% (2/2) | not measured | 0/1 (1 timeout, 0 error) | 100.00% / - | BranchNotMeasured |
| **total** | 40.00% (4/10) | 50.00% (1/2) | 1/3 (1 timeout, 0 error) | - | - |

### Findings (7)

- **BelowTarget** `src/alpha`: branch 50.00% is below the target 100.00%
- **BelowTarget** `src/alpha`: line 25.00% is below the target 100.00%
- **MissingRow** `src/alpha`: no ratchet row; measured line 25.00%
- **MutantSurvived** `src/alpha` `src/alpha/a.mojo:2`: mutant survived: negate: x > 0 -> x <= 0
- **UnmeasuredFile** `src/alpha` `src/alpha/z.mojo`: no test binary compiled this file: its 3 executable lines count as not covered
- **BranchNotMeasured** `src/beta`: no branch of this package was measured (no report names a file of it with branch records: kcov's Cobertura holds none, and a gate reads its tests' branch records only for a library of COVERAGE_BRANCH_GATE, tools/build/coverage/policy.bzl): its branch coverage cannot be shown to meet the target
- **ExtraRow** `src/gone`: the ratchet has a row for a directory with no BUCK file

### Exemptions (need approval) (2)

- `src/alpha/a.mojo:7` (exempt): x is never in [-5, 0]
- `src/alpha/z.mojo:6` (exempt): callers pass x >= 0

### Changed lines (informational)

Covered 0, uncovered 2, not instrumented 1, exempt 1.

Uncovered changed lines:

- `src/alpha/a.mojo`: 3, 6

### Set aside

- 1 report files outside the repository (the Mojo standard library, other code not in the repository)
- 1 test source files (`<package>/tests/` and each `--test-source`; `--include-tests` counts them)
- 0 mutants outside the repository, 0 in test sources
