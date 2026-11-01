# kci_validator_rows

Positional row accounting for validators that emit a matrix of named result
rows. A validator authors its rows up front as a list of `ExpectedRow(name,
asserts)`, where `asserts` states in one sentence what that row proves.
`row_accounting_fault` compares the row names a run actually emitted against
that list, index by index, and returns an empty string when they agree, or a
message naming the fault: an invalid spec (empty, a blank name, a blank
obligation, a duplicate name), no rows emitted, a count mismatch, or a name
mismatch at equal length, each with the first divergent index and both names.
A count check alone passes a truncated run (`passed == total` over whatever was
emitted); this does not. `validator_exit_code` maps the verdict to the process
exit code, `plan_lines` derives a dry-run listing from the spec, and
`emit_live_row` prints one completed row to stdout, flushed, behind the
`LIVE-ROW <n>:` prefix built by `live_row_line`. The package has no
dependencies.

## Examples

A run that emitted every authored row, in order, has no fault:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from kci_validator_rows import ExpectedRow, expected_row, row_accounting_fault, validator_exit_code

var spec = List[ExpectedRow]()
spec.append(expected_row("livez_200", "the app answers liveness"))
spec.append(expected_row("unauth_401", "a request with no bearer is refused"))
spec.append(expected_row("auth_200", "a valid bearer is admitted"))

var emitted = List[String]()
emitted.append("livez_200")
emitted.append("unauth_401")
emitted.append("auth_200")
var fault = row_accounting_fault("demo", emitted, spec)
assert_equal(fault, "")
assert_equal(validator_exit_code(fault.byte_length() == 0), Int32(0))
```

A truncated run is a fault even though every row it emitted is correct, and the
message names the first missing row:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from kci_validator_rows import ExpectedRow, expected_row, row_accounting_fault, validator_exit_code

var spec2 = List[ExpectedRow]()
spec2.append(expected_row("livez_200", "the app answers liveness"))
spec2.append(expected_row("unauth_401", "a request with no bearer is refused"))
spec2.append(expected_row("auth_200", "a valid bearer is admitted"))

var prefix = List[String]()
prefix.append("livez_200")
var fault2 = row_accounting_fault("demo", prefix, spec2)
assert_true(fault2.startswith("demo: row-count mismatch"))
assert_true("FIRST MISSING at index 1: authored 'unauth_401'" in fault2)
assert_equal(validator_exit_code(fault2.byte_length() == 0), Int32(1))
```

Two rows that swap names keep the count and are still caught:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from kci_validator_rows import first_name_divergence

var authored = List[String]()
authored.append("a")
authored.append("b")
var swapped = List[String]()
swapped.append("b")
swapped.append("a")
assert_equal(
    first_name_divergence(swapped, authored),
    " FIRST DIVERGENCE at index 0: authored 'a', emitted 'b'",
)
assert_equal(first_name_divergence(authored, authored), "")
```

A row that states no obligation makes the spec invalid, and a streamed row
line leads with its marker and ordinal:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from kci_validator_rows import ExpectedRow, expected_row, spec_fault, live_row_line

var bad = List[ExpectedRow]()
bad.append(expected_row("livez_200", ""))
assert_true("states NO OBLIGATION" in spec_fault("demo", bad))
assert_equal(live_row_line(3, "[PASS] livez_200"), "LIVE-ROW 3: [PASS] livez_200")
```

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `kci_validator_rows`, version 0.1.0 (`mopm.toml`). The library is `src/kci_validator_rows/`, its tests are `tests/`. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the dependencies and where the library and its tests are |
| `mopm.lock` | the toolchain pins and the path dependencies (no registry is reached: every dependency is a sibling) |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses |
| `coverage_floor.txt` | `lines NN.NN` and `branches NN.NN`: the least line and branch coverage `:coverage` may measure; `:coverage_floor` fails when either falls below, and above it passes and prints a hint to raise the figure |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above; `buildrules mojo check` fails when they are stale |

`:lib` is the library file and exists only once every test of `tests/` has passed. After any change to a source, a test, or a manifest of this package, run `buildrules mojo sync`, commit what it writes, and build `komira//src/kci_validator_rows:lib` on the farm. A test file that the sync has not listed is not run: run the sync after adding one.

`:conda` is buildrules' `mojo_conda` over `:lib`: the `.conda` of the mopm package (`mojo-kci_validator_rows-0.1.0-mojo1.0.0_0.conda`), which therefore exists only once the tests have passed. Publishing it (`mopm publish`) uploads, so it is a step of a CI job that takes that file, not a build action.

`:kci_validator_rows` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`). It also compiles and runs the README's examples above (`[tests][readme]`) against `:lib`; the tests are not run again.
