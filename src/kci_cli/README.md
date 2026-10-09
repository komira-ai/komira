# kci_cli

The `kci` command line. There is one command, `kci run --stage S`:
`parse_kci_args` reads it (and `--help`), refusing anything else as a usage
error before anything is read. `kci_main` then reads the machine file
(`kci_release_machine`; `--machine`, default `release/machine.textproto`),
resolves stage `S` and runs each of its steps in order through `kci_build`
(BUILD), `kci_publish` (PUBLISH) or `kci_cloud` (DEPLOY: a plan or an apply
of a resource list into one cell of a cells file), with each step's
validations (`kci_validate`) after it. The `kci` binary is built with no
cloud adapter yet, so it refuses every DEPLOY step ("this kci was not built
with that cloud"). Under GitHub Actions it first checks the workflow
it runs under against the machine file, the ref it runs on (a stage that is
neither the pull-request stage nor `break_glass` runs only on `main`) and the
release set it was handed. Every
run writes `kci_api`'s result document to `--result-file` (RUNNING before
the first effect, FINISHED on every exit path), appends a markdown summary
to `--summary-file` when given, and exits with `kci_api`'s exit numbers.

`kci_main_with` and `run_stage_with` take the steps as a `StageSteps`
value, so a test can run a stage over a recording fake; `LibrarySteps` is
the one that reaches the real libraries. Their four-argument forms also take
the clouds a DEPLOY step may use as a `CellDeploys` value:
`CloudDeploys[S, St]` holds one built-in cloud adapter, its state store and
its credentials, and `NoCloudBuilt` holds none. The `kci` program itself is a
separate binary whose `main` calls `kci_main`.

## Examples

Parse a command line (argv without the program name). `--only` selectors
are parsed by `selectors_of`:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from kci_cli import CLI_VERB_HELP, CLI_VERB_RUN, parse_kci_args, selectors_of

var cmd = parse_kci_args([
    "run", "--stage", "build",
    "--revision-id", "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678",
    "--run-id", "gh-1", "--attempt", "1",
    "--release-dir", "/r", "--work-dir", "/w", "--log-dir", "/l",
    "--only", "step:build-wheels", "--build-timeout-s=600",
])
assert_equal(cmd.verb, CLI_VERB_RUN)
assert_equal(cmd.stage, "build")
assert_equal(cmd.machine, "release/machine.textproto")  # the default
assert_equal(cmd.build_timeout_s, 600)
assert_equal(cmd.run_identity().run_id, "gh-1")
var only = selectors_of(cmd)
assert_true(only[0].is_step())
assert_equal(only[0].name, "build-wheels")

assert_equal(parse_kci_args(["--help"]).verb, CLI_VERB_HELP)
```

A usage error names what is wrong and carries no `kci: ` prefix (the
dispatcher prints one):

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from kci_cli import parse_kci_args

def usage_error_of(args: List[String]) -> String:
    try:
        _ = parse_kci_args(args)
    except e:
        return String(e)
    return "<accepted>"

assert_equal(usage_error_of(List[String]()), "no command: there is one, kci run --stage <S>")
assert_equal(
    usage_error_of([
        "run", "--stage", "build",
        "--revision-id", "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678",
        "--run-id", "gh-1", "--attempt", "1", "--release-dir", "/r",
        "--no-such-flag",
    ]),
    "unknown flag '--no-such-flag' for kci run",
)
```

Which flags a run needs follows from the step kinds of the stage it runs: a
stage with a BUILD step needs `--work-dir` and `--log-dir`, and a PUBLISH
step's flag is refused on a stage that has none:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from kci_api import Selector
from kci_cli import parse_kci_args, require_stage_flags
from kci_release_machine import parse_machine_file, resolve_selection

var machine = parse_machine_file(
    "schema_version: 1\n"
    "stage { name: \"build\" step { name: \"b\" kind: BUILD platform: \"linux-x86_64\" artifacts: \"d\" } }\n",
    "machine.textproto",
)
var stage = machine.stage("build")
var everything = resolve_selection(stage, List[Selector]())

var base: List[String] = [
    "run", "--stage", "build",
    "--revision-id", "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678",
    "--run-id", "gh-1", "--attempt", "1", "--release-dir", "/r",
    "--work-dir", "/w", "--log-dir", "/l",
]
require_stage_flags(parse_kci_args(base), stage, everything)  # accepted

var with_publish_flag = base.copy()
with_publish_flag.append("--release-version")
with_publish_flag.append("1.0.0")
var refused = String()
try:
    require_stage_flags(parse_kci_args(with_publish_flag), stage, everything)
except e:
    refused = String(e)
assert_equal(
    refused,
    "--release-version is a PUBLISH step's flag, and stage 'build' has no PUBLISH step",
)
```
