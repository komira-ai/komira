# kci_release_machine

The machine file (format `kci.machine`, a textproto): a release machine's
stages, in order, and the steps of each. `parse_machine_file` reads the text
it is given (it opens no file) into a `ReleaseMachine`: each `Stage` has a
name, the GitHub environment its job runs in (its name by default), the one
earlier stage it runs `after`, whether it is farm-connected, its trigger
(`PUSH` or `PULL_REQUEST`) and its `StageStep`s (`BUILD`, `PUBLISH` to a
channel or into a cell, and `DEPLOY` into a cell), and their
`StageValidation`s: `CONDA_INSTALL_SMOKE` and `CONDA_INSTALL_ENV` on a `PUBLISH`
step, `DEPLOY_PROBE` (a digest-pinned image, its args, an optional target,
a timeout and the case ids it must report) on a `DEPLOY` step. A `DEPLOY`
step in a stage another stage runs `after` must carry a `DEPLOY_PROBE`. A machine that writes into a cell has a `name`; a cell is
picked from a cells file, and `require_cells_declared` checks the pick against
the names that file declares (this package opens no file).
Every malformed or inconsistent file is refused with an error naming the
source and line. `resolve_selection` resolves `kci run --only ...` selectors
against one stage into the steps and validations that run.

## Examples

Read a two-stage machine back:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from kci_release_machine import parse_machine_file

var text = String(
    'schema_version: 1\n'
    + 'stage { name: "build"\n'
    + '  step { name: "build" kind: BUILD platform: "linux-x86_64" artifacts: "release/artifacts.textproto" }\n'
    + '}\n'
    + 'stage { name: "prod" after: "build"\n'
    + '  step { name: "publish" kind: PUBLISH platform: "linux-x86_64"\n'
    + '         artifacts: "release/artifacts.textproto" channels: "release/channels.textproto" channel: "prod" }\n'
    + '}\n'
)
var machine = parse_machine_file(text, "machine file")
assert_equal(len(machine.stages), 2)
var prod = machine.stage("prod")
assert_equal(prod.after, "build")
assert_equal(prod.environment, "prod")
assert_true(prod.steps[0].is_publish())
assert_equal(prod.steps[0].channel, "prod")
```

A stage that runs after itself is refused, naming the line:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from kci_release_machine import parse_machine_file

var message = String()
try:
    _ = parse_machine_file(
        String('schema_version: 1\nstage {\n name: "b" after: "b"\n')
        + 'step { name: "s" kind: BUILD platform: "linux-x86_64" artifacts: "d" }\n}\n',
        "machine file",
    )
except e:
    message = String(e)
assert_equal(message, "machine file: line 2: stage 'b' runs after itself")
```

Select one step of a stage, as `kci run --only step:publish` does:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from kci_api import SCOPE_SELECTIVE, parse_selectors
from kci_release_machine import parse_machine_file, resolve_selection

var machine = parse_machine_file(
    String('schema_version: 1\nstage { name: "release"\n')
    + '  step { name: "build" kind: BUILD platform: "linux-x86_64" artifacts: "d.textproto" }\n'
    + '  step { name: "publish" kind: PUBLISH platform: "linux-x86_64" artifacts: "d.textproto"\n'
    + '         channels: "c.textproto" channel: "beta" }\n}\n',
    "machine file",
)
var only = List[String]()
only.append("step:publish")
var selection = resolve_selection(machine.stage("release"), parse_selectors(only))
assert_equal(selection.scope, SCOPE_SELECTIVE)
assert_false(selection.steps[0])
assert_true(selection.steps[1])
assert_equal(selection.selected_count(), 1)
```

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `kci_release_machine`, version 0.1.0 (`mopm.toml`). The library is `src/kci_release_machine/`, its tests are `tests/`. It depends on kci_api and komira_textproto, sibling directories (`[dependencies]` of `mopm.toml`), so the `.conda` of this package records `mojo-kci_api >=0.1,<0.2` and `mojo-komira_textproto >=0.1,<0.2` as dependencies and holds none of those packages' files: installing `kci_release_machine` installs them with it. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the dependencies and where the library and its tests are |
| `mopm.lock` | the toolchain pins and the path dependencies (no registry is reached: every dependency is a sibling) |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses |
| `coverage_floor.txt` | `lines NN.NN` and `branches NN.NN`: the least line and branch coverage `:coverage` may measure; `:coverage_floor` fails when either falls below, and above it passes and prints a hint to raise the figure |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above and from the manifests of the dependencies; `buildrules mojo check` fails when they are stale |

`:lib` is the library file and exists only once every test of `tests/` has passed. After any change to a source, a test, or a manifest of this package or of a dependency, run `buildrules mojo sync`, commit what it writes, and build `komira//src/kci_release_machine:lib` on the farm. A test file that the sync has not listed is not run: run the sync after adding one.

`:conda` is buildrules' `mojo_conda` over `:lib`: the `.conda` of the mopm package (`mojo-kci_release_machine-0.1.0-mojo1.0.0_0.conda`), which therefore exists only once the tests have passed. Publishing it (`mopm publish`) uploads, so it is a step of a CI job that takes that file, not a build action.

`:kci_release_machine` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`). Its `deps` are the adopted target of each package in `[dependencies]`, and the rule refuses a list that is not the closure `:lib` was built from. It also compiles and runs the README's examples above (`[tests][readme]`) against `:lib`; the tests are not run again.
