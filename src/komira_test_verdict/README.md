# komira_test_verdict

The exit-code vocabulary of a test that can do more than pass or fail. A
`Verdict` records what a teardown or a leak check found: CLEAN (0),
CANNOT_TELL (3) or LEAK (6). When findings disagree the worst wins, LEAK
ranking above CANNOT_TELL, and every residue key and reason is kept.
`exit_skip` (77) and `exit_cannot_tell` (3) print one marker line naming why a
test could not run and end the process; neither ever exits 0. The package
imports only the standard library.

## Examples

Fold findings together; the worst kind wins and nothing is dropped:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_test_verdict import Verdict, VERDICT_LEAK

var teardown = Verdict()
teardown.add_cannot_tell("list: HTTP 503")
var check = Verdict()
check.add_residue("run-1/part-0")
teardown.merge(check)
assert_equal(teardown.kind, VERDICT_LEAK)
assert_equal(teardown.exit_code(), 6)
assert_equal(String(teardown), "LEAK residue=[run-1/part-0] reasons=[list: HTTP 503]")
```

`require_clean` raises with the whole verdict unless it is CLEAN:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_test_verdict import Verdict

Verdict().require_clean()
var v = Verdict()
v.add_cannot_tell("stop not confirmed")
var message = String()
try:
    v.require_clean()
except e:
    message = String(e)
assert_true(not v.is_clean())
assert_equal(message, "komira_test_verdict: teardown verdict CANNOT_TELL reasons=[stop not confirmed]")
```

The marker lines a skipped or undecided test prints, kept on one line (calling
`exit_skip` or `exit_cannot_tell` itself would end the process):

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_test_verdict import CANNOT_TELL_EXIT_CODE, SKIP_EXIT_CODE
from komira_test_verdict import cannot_tell_line, skip_line

assert_equal(skip_line("nothing configured"), "KOMIRA-TEST: SKIP reason=nothing configured")
assert_equal(cannot_tell_line("a\nb"), "KOMIRA-TEST: CANNOT_TELL reason=a b")
assert_equal(skip_line(""), "KOMIRA-TEST: SKIP reason=unspecified")
assert_equal(SKIP_EXIT_CODE, 77)
assert_equal(CANNOT_TELL_EXIT_CODE, 3)
```

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_test_verdict`, version 0.1.0
(`mopm.toml`). The library is `src/komira_test_verdict/`, its tests are `tests/`. The package has no native archive
and calls no foreign function: it is Mojo over the standard library, and `exit_skip` and `exit_cannot_tell` end the
process through `std.sys.exit`. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, where the library and its tests are |
| `mopm.lock` | what `mopm lock` writes (with no registry reachable); the package has no dependencies, so it pins the toolchain only |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `coverage_floor.txt` | `lines NN.NN` and `branches NN.NN`: the least line and branch coverage `:coverage` may measure (the branches are the compiler's IR decisions of the library's sources, `:coverage[branches]`); `:coverage_floor` fails when either falls below, and above it passes and prints a hint to raise the figure |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above; `buildrules mojo check` fails when they are stale |

`:lib` is the library file and exists only once every test of `tests/` has passed. After any change to a source,
a test, `mopm.toml`, `mopm.lock` or `mopm-toolchain.toml`, run `buildrules mojo sync`, commit what it
writes, and build `komira//src/komira_test_verdict:lib` on the farm. (The sync writes the toolchain pins,
`mojo_pins.bzl` and `mopm_pins.bzl`, to the directory the `[cells] toolchains` line of `.buckconfig` names:
`tools/build/cells/toolchains/` here.) A test file that `buildrules mojo sync` has not listed is not
run: run the sync after adding one.

`:conda` is buildrules' `mojo_conda` over `:lib`: the `.conda` of the mopm package
(`mojo-komira_test_verdict-0.1.0-mojo1.0.0_0.conda`), which therefore exists only once the tests have passed.
Publishing it (`mopm publish`) uploads, so it is a step of a CI job that takes that file, not a build action.

`:komira_test_verdict` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`). It also compiles and runs the
README's examples above (`[tests][readme]`) against `:lib`, which `:lib` does not do; the tests are not run again.
