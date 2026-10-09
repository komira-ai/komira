# kci_build

One BUILD step of a kci stage (`kci run --stage S`). `run_build` first
checks, reading only, that the platform is one kci releases, that
`--revision-id` is a full commit id, the path flags and the artifacts file;
it then records the run's RUNNING result before the first effect, and
derives the release stamp from git, refusing a shallow clone, a `HEAD` that
is not the revision, or modified tracked files (that refusal comes after the
RUNNING record); then it builds each
artifact of the artifacts file (read by `kci_artifact`) in file order, one at
a time, into an EMPTY directory under `<release_dir>/<platform>/`, and checks
what each build left. When every artifact passed it writes `release.json`
last, as the commit marker. With `BuildRequest.plan` it resolves and renders
each artifact's argv and builds nothing; with `BuildRequest.affected_by` it
is the per-change check (`run_affected`): the artifacts file's `affected`
command decides which units a change reaches, and only those are built.

Every process (git and the build systems) starts through the
`ProcessRunner` trait: `SupervisorRunner` runs real processes,
`ScriptedRunner` answers from a script, for tests. kci names no build tool:
the program, its args and where it builds are the artifacts file's. The
outcome is a `kci_api` outcome word and error id; this package spells no
exit number. The Buck2 target is `//src/kci_build:kci_build_lib`; the import
name is `kci_build`.

## Examples

A `RunSpec` is one process to run. Its child inherits the environment
unless `set_env` gives an explicit one, which must hold `PATH` and name each
variable once:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from kci_build import RunResult, RunSpec, check_child_env, env_entry_name

var spec = RunSpec("buck2", ["build", "//src/komira_hash:komira_hash"], "/work", 600, "/logs/out", "/logs/err")
assert_equal(spec.command_line(), "buck2 build //src/komira_hash:komira_hash")
assert_false(Bool(spec.env))  # inherits
spec.set_env(["PATH=/usr/bin:/bin", "TMPDIR=/var/tmp"])
assert_equal(len(spec.env.value()), 2)
assert_equal(env_entry_name("TMPDIR=/var/tmp"), "TMPDIR")

var message = String()
try:
    check_child_env(["TMPDIR=/var/tmp"])
except e:
    message = String(e)
assert_equal(message, "an explicit child environment holds no PATH")

assert_true(RunResult(Int32(0)).ok())
assert_equal(RunResult(Int32(2)).describe(), "exit 2")
assert_equal(RunResult(Int32(0), timed_out=True).describe(), "timed out")
```

The per-change check's runs (its derive and affected commands, then a
batch, a unit alone, a retry) can share a budget,
`BuildRequest.build_budget_s` (`kci run --build-budget-s`), which ends at
`BuildRequest.build_deadline_ns`: kci's start plus the budget, on the
runner's monotonic clock (`ProcessRunner.now_ns`, CLOCK_MONOTONIC by
default). Each run's timeout is the smaller of `--build-timeout-s` and the
whole seconds left until the deadline. With less than one second left the run
is not started: a unit is reported as not built (time ran out: INDETERMINATE,
like a batch that timed out; FAILED only when a unit failed), a derive or affected
command as not started (INDETERMINATE). Without a budget every run gets
`--build-timeout-s`:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from kci_build import NO_BUILD_BUDGET, run_timeout_s

# run_timeout_s(--build-timeout-s, --build-budget-s, deadline_ns, now_ns)
assert_equal(run_timeout_s(3600, NO_BUILD_BUDGET, 0, 9_000_000_000_000), 3600)
assert_equal(run_timeout_s(3600, 6000, 6_000_000_000_000, 0), 3600)
assert_equal(run_timeout_s(3600, 6000, 6_000_000_000_000, 4_000_000_000_000), 2000)
assert_equal(run_timeout_s(3600, 6000, 6_000_000_000_000, 6_000_000_000_000), 0)  # not started
```

The release stamp comes from six git commands run through the
`ProcessRunner`. Here a `ScriptedRunner` stands in for git (each step must
match the argv kci runs exactly, and writes the step's stdout to the run's
log file, under a temporary directory):

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from std.tempfile import TemporaryDirectory
from kci_api import OUTCOME_REFUSED, RunIdentity
from kci_build import BuildRequest, ScriptedRunner, ScriptedStep, derive_release_stamp

comptime REV = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
comptime SRC = "f0e1d2c3b4a5968778695a4b3c2d1e0f12345678"

def git_answers(shallow: String) -> ScriptedRunner:
    var g = ScriptedRunner()
    g.expect(ScriptedStep(["rev-parse", "--is-shallow-repository"], stdout_text=shallow))
    g.expect(ScriptedStep(["rev-parse", "--verify", "HEAD"], stdout_text=String(REV) + "\n"))
    g.expect(ScriptedStep(["status", "--porcelain", "--untracked-files=no"]))
    g.expect(ScriptedStep(
        ["log", "-1", "--first-parent", "--format=%H", REV, "--", ".",
         ":(exclude)docs", ":(exclude)*.md", ":(exclude).github"],
        stdout_text=String(SRC) + "\n",
    ))
    g.expect(ScriptedStep(["rev-list", "--count", "--first-parent", SRC], stdout_text="154\n"))
    g.expect(ScriptedStep(["log", "-1", "--format=%ct", SRC], stdout_text="1790994309\n"))
    return g^

# TemporaryDirectory.__exit__ swallows an error raised in its body, so the
# block only collects results; the checks run after it closes.
var outcome = String()
var message = String()
var left = -1
var source_commit = String()
var build_number = -1
var timestamp_ms = -1
var refused_outcome = String()
var refused_error = String()
var shallow_calls = -1
with TemporaryDirectory() as tmp:
    var req = BuildRequest(RunIdentity("gh-1", 1))
    req.work_dir = tmp
    req.log_dir = tmp
    req.revision_id = REV
    req.platform = "linux-x86_64"

    var git = git_answers("false\n")
    var r = derive_release_stamp(req, git)
    outcome = r.outcome
    message = r.message
    left = git.remaining()
    if r.stamp:
        var stamp = r.stamp.value().copy()
        source_commit = stamp.source_commit
        build_number = stamp.build_number
        timestamp_ms = stamp.timestamp_ms

    # A shallow clone would count the clone's depth: refused, and git is
    # asked nothing more.
    var shallow = git_answers("true\n")
    var refused = derive_release_stamp(req, shallow)
    refused_outcome = refused.outcome
    refused_error = refused.error_id
    shallow_calls = len(shallow.calls)

assert_equal(outcome, "SUCCEEDED", message)
assert_equal(left, 0)
assert_equal(source_commit, SRC)  # the newest non-documentation commit
assert_equal(build_number, 154)
assert_equal(timestamp_ms, 1790994309000)
assert_equal(refused_outcome, OUTCOME_REFUSED)
assert_equal(refused_error, "KCI-E-REVISION")
assert_equal(shallow_calls, 1)
```
