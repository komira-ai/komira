## Coverage: line 57.14% (4/7), branch 50.00% (1/2); changed lines 0.00% (0/2)

Line coverage counts only the lines the compiler emitted code for: a function that no test reaches may emit no lines at all, so these numbers are upper bounds until declaration reachability lands.

Mode: **neutral**, conclusion **neutral**. Target: 100.00% line and branch coverage per package.

### Packages

| package | line % (hit/found) | branch % (hit/found) | mutants killed/total | floor line / branch | status |
|---|---|---|---|---|---|
| `src/alpha` (touched) | 40.00% (2/5) | 50.00% (1/2) | 1/2 | - | BelowTarget, MissingRow, MutantSurvived |
| `src/beta` | 100.00% (2/2) | n/a | 0/1 (1 timeout, 0 error) | 100.00% / - | ok |
| **total** | 57.14% (4/7) | 50.00% (1/2) | 1/3 (1 timeout, 0 error) | - | - |

### Findings (5)

- **BelowTarget** `src/alpha`: branch 50.00% is below the target 100.00%
- **BelowTarget** `src/alpha`: line 40.00% is below the target 100.00%
- **MissingRow** `src/alpha`: no ratchet row; measured line 40.00%
- **MutantSurvived** `src/alpha` `src/alpha/a.mojo:2`: mutant survived: negate: x > 0 -> x <= 0
- **ExtraRow** `src/gone`: the ratchet has a row for a directory with no BUCK file

### Exemptions (need approval) (1)

- `src/alpha/a.mojo:7` (exempt): x is never in [-5, 0]

### Changed lines (informational)

Covered 0, uncovered 2, not instrumented 1, exempt 1.

Uncovered changed lines:

- `src/alpha/a.mojo`: 3, 6

### Set aside

- 1 report files outside the repository (the Mojo standard library, other code not in the repository)
- 1 test source files (`<package>/tests/`; `--include-tests` counts them)
- 0 mutants outside the repository, 0 in test sources
