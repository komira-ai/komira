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
`base_for_event` and `condition_for_event` evaluate pr.yml's `--affected-by`
and its job's `if:` for one event (`pull_request` or `merge_group`).
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

The base commit pr.yml's `kci run --affected-by` passes on each event it runs
on (`pull_request`, and the merge queue's `merge_group`), as GitHub evaluates
the expression; one outside the grammar reads as nothing:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from kci_workflow_check import BASE_EXPRESSION, base_for_event

assert_equal(base_for_event(BASE_EXPRESSION, "pull_request"), "github.event.pull_request.base.sha")
assert_equal(base_for_event(BASE_EXPRESSION, "merge_group"), "github.event.merge_group.base_sha")
assert_equal(base_for_event("github.event.pull_request.base.sha", "merge_group"), "github.event.pull_request.base.sha")
assert_equal(base_for_event("github.event.pull_request.head.sha", "pull_request"), "")
```
