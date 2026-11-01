# kci_workflow_check

The workflow consistency check: a hand-written CI workflow (the release
workflow `kci.yml`, or the pull request's check `pr.yml`) held to the release
machine of a machine file. `check_workflow` returns every disagreement between
the two (one job per stage, its environment, `needs`, `id-token` permissions,
one `kci run --stage <id>` per job, the pull request and auto-promotion rules,
pinned `uses:`), and `check_running_workflow` is the check `kci run` makes at
start-up. The workflow is read by `read_workflow`, a fail-closed reader of a
strict YAML subset: any line outside the subset raises an error starting with
`CANNOT_TELL` ("cannot tell: "), never a pass. `kci_run_calls` finds every
`kci run` in a `run:` script and the flags it passes, and
`excludes_pull_request` says whether a job's `if:` keeps a pull request out.
The package checks text it is given; it opens no file.

## Examples

Read a workflow into a tree of maps, lists and scalars:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from kci_workflow_check import NODE_LIST, read_workflow

var doc = read_workflow(
    "on:\n"
    "  push:\n"
    "    branches: [main]\n"
    "jobs:\n"
    "  build:\n"
    "    environment: build\n"
    "    steps:\n"
    "      - run: kci run --stage build\n"
)
var jobs = doc.child(0, "jobs")
assert_equal(len(doc.keys(jobs)), 1)
var build = doc.child(jobs, "build")
assert_equal(doc.text(doc.child(build, "environment")), "build")
var branches = doc.child(doc.child(doc.child(0, "on"), "push"), "branches")
assert_equal(doc.kind(branches), NODE_LIST)
assert_equal(doc.scalar_or_list(branches)[0], "main")
var steps = doc.items(doc.child(build, "steps"))
assert_equal(doc.text(doc.child(steps[0], "run")), "kci run --stage build")
```

A construct outside the subset (here a YAML anchor) is "cannot tell":

<!-- mojo-hidden from std.testing import assert_true -->
```mojo
from kci_workflow_check import CANNOT_TELL, read_workflow

var message = String()
try:
    _ = read_workflow("a: &x 1\nb: *x\n")
except e:
    message = String(e)
assert_true(message.startswith(CANNOT_TELL))
```

Find the `kci run` calls of a script and their flags:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from kci_workflow_check import kci_run_calls

var calls = kci_run_calls(
    "echo start\n"
    "kci run --stage publish --summary-file out.md --only step:wheel\n"
)
assert_equal(len(calls), 1)
assert_equal(calls[0].stage, "publish")
assert_true(calls[0].has_summary_file)
assert_true(calls[0].has_only)
assert_equal(calls[0].only[0], "step:wheel")
assert_false(calls[0].has_machine)
```

Which job conditions keep a pull request out:

<!-- mojo-hidden from std.testing import assert_false, assert_true -->
```mojo
from kci_workflow_check import excludes_pull_request

assert_true(excludes_pull_request("${{ github.event_name != 'pull_request' }}"))
assert_true(excludes_pull_request("needs.build.outputs.release == 'true' && github.event_name == 'push'"))
assert_false(excludes_pull_request("always() || github.event_name != 'pull_request'"))
assert_false(excludes_pull_request("github.event_name == 'pull_request'"))
```

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `kci_workflow_check`, version 0.1.0 (`mopm.toml`). The library is `src/kci_workflow_check/`, its tests are `tests/`. It depends on kci_api, kci_release_channel and kci_release_machine, sibling directories (`[dependencies]` of `mopm.toml`), so the `.conda` of this package records `mojo-kci_api >=0.1,<0.2`, `mojo-kci_release_channel >=0.1,<0.2` and `mojo-kci_release_machine >=0.1,<0.2` as dependencies and holds none of those packages' files: installing `kci_workflow_check` installs them with it. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the dependencies and where the library and its tests are |
| `mopm.lock` | the toolchain pins and the path dependencies (no registry is reached: every dependency is a sibling) |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses |
| `coverage_floor.txt` | `lines NN.NN` and `branches NN.NN`: the least line and branch coverage `:coverage` may measure; `:coverage_floor` fails when either falls below, and above it passes and prints a hint to raise the figure |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above and from the manifests of the dependencies; `buildrules mojo check` fails when they are stale |

`:lib` is the library file and exists only once every test of `tests/` has passed. After any change to a source, a test, or a manifest of this package or of a dependency, run `buildrules mojo sync`, commit what it writes, and build `komira//src/kci_workflow_check:lib` on the farm. A test file that the sync has not listed is not run: run the sync after adding one.

`:conda` is buildrules' `mojo_conda` over `:lib`: the `.conda` of the mopm package (`mojo-kci_workflow_check-0.1.0-mojo1.0.0_0.conda`), which therefore exists only once the tests have passed. Publishing it (`mopm publish`) uploads, so it is a step of a CI job that takes that file, not a build action.

`:kci_workflow_check` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`). Its `deps` are the adopted target of each package in `[dependencies]`, and the rule refuses a list that is not the closure `:lib` was built from. It also compiles and runs the README's examples above (`[tests][readme]`) against `:lib`; the tests are not run again.
