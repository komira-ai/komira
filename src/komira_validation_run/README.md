# komira_validation_run

The tag/label key shape a validation run stamps on every billable cloud
resource it creates, so an unattended cleanup can act only on resources it can
prove its own run made. A key is `<prefix>-<suffix>`: the caller chooses the
prefix, and the two fixed suffixes are `run-id` (the id of the run that created
the resource) and `retention` (the authored retention of the node that made
it, `delete` or `retain`). Keys and run ids are checked against the
intersection of the AWS tag rules and the GCP label rules (lowercase letters,
digits, `-` and `_`, at most 63 bytes), so one spelling is legal verbatim on
both clouds. The package has no dependencies.

## Examples

Build the two keys from one prefix; a prefix one of the clouds would reject
raises:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from komira_validation_run.validation_run_tag import is_valid_tag_key_prefix, resource_retention_tag_key, validation_run_tag_key

assert_equal(validation_run_tag_key("acme"), "acme-run-id")
assert_equal(resource_retention_tag_key("acme"), "acme-retention")
assert_false(is_valid_tag_key_prefix("Acme"))

var refused = False
try:
    _ = validation_run_tag_key("my.tool")
except:
    refused = True
assert_true(refused)
```

Check a run id before stamping it: empty, uppercase and over-length ids are
refused:

<!-- mojo-hidden from std.testing import assert_false, assert_true -->
```mojo
from komira_validation_run.validation_run_tag import VALIDATION_RUN_ID_MAX_LEN, is_valid_validation_run_id

assert_true(is_valid_validation_run_id("run-20261006-a1b2"))
assert_false(is_valid_validation_run_id(""))
assert_false(is_valid_validation_run_id("Run-1"))
assert_false(is_valid_validation_run_id(String("a") * (VALIDATION_RUN_ID_MAX_LEN + 1)))
```

Project a manifest `Retention` ordinal onto the retention mark; an unknown
ordinal raises instead of picking a side:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from komira_validation_run.validation_run_tag import is_valid_retention_tag_value, retention_tag_value

assert_equal(retention_tag_value(0), "delete")
assert_equal(retention_tag_value(1), "delete")
assert_equal(retention_tag_value(2), "retain")
assert_true(is_valid_retention_tag_value("retain"))
assert_false(is_valid_retention_tag_value("keep"))

var raised = False
try:
    _ = retention_tag_value(3)
except:
    raised = True
assert_true(raised)
```

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_validation_run`, version 0.1.0
(`mopm.toml`). The library is `src/komira_validation_run/` (`validation_run_tag.mojo` and the `__init__.mojo` that
documents the package), its tests are `tests/`. The package has no dependencies, no native archive and calls no
foreign function: it is Mojo over `String` and integers. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, where the library and its tests are |
| `mopm.lock` | what `mopm lock` writes (with no registry reachable); the package has no dependencies, so it pins the toolchain only |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `coverage_floor.txt` | `lines NN.NN`: the line coverage `:coverage` measures, exactly; `:coverage_floor` fails when it falls below and when it rises above, until the figure is changed |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above; `buildrules mojo check` fails when they are stale |

`:lib` is the library file and exists only once every test of `tests/` has passed. After any change to a source,
a test, `mopm.toml`, `mopm.lock` or `mopm-toolchain.toml`, run `buildrules mojo sync`, commit what it
writes, and build `komira//src/komira_validation_run:lib` on the farm. (The sync writes the toolchain pins,
`mojo_pins.bzl` and `mopm_pins.bzl`, to the directory the `[cells] toolchains` line of `.buckconfig` names:
`tools/build/cells/toolchains/` here.) A test file that `buildrules mojo sync` has not listed is not
run: run the sync after adding one.

`:conda` is buildrules' `mojo_conda` over `:lib`: the `.conda` of the mopm package
(`mojo-komira_validation_run-0.1.0-mojo1.0.0_0.conda`), which therefore exists only once the tests have passed.
Publishing it (`mopm publish`) uploads, so it is a step of a CI job that takes that file, not a build action.

`:komira_validation_run` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`). It also compiles and runs
the README's examples above (`[tests][readme]`) against `:lib`, which `:lib` does not do; the tests are not run again.
