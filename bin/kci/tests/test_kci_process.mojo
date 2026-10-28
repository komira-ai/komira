# =============================================================================
# bin/kci/tests/test_kci_process.mojo -- the kci binary run as a PROCESS.
# =============================================================================
#
# kci_cli's welded tests call `kci_main_with` in-process. This test starts the
# built //bin/kci:kci (its runnable directory, staged as data at `kci/`, so it
# loads its runtime libraries through its own run path, with no library path
# set) through kci_build's SupervisorRunner, and reads what a shell or a CI job
# reads: the exit status, stderr, and the bytes of --result-file and
# --summary-file. Each case runs in its own directory under TEST_TMPDIR, with
# an explicit environment (PATH, HOME, TMPDIR and the case's own variables).
#
# Error ids: today kci prints no KCI-E-* id on stderr (whether it should is
# open). Stderr carries the message, `kci: <OUTCOME> (exit N) stage S` and the
# evidence line. The id is asserted in the result document's `error.id` (a, b,
# c) and in the summary's `- error:` line (c, d); a refused command line's
# summary carries the message and no id line. Every result document's `retry`
# is asserted to be kci_api's default_retry of its exit number, which is what
# a driver acts on.
#
# git and buck2 are FAKES: shell scripts the test writes first on the child's
# PATH. Each appends its argv to `git.calls` / `buck2.calls`. The fake git
# answers what kci asks (the release stamp's read-only commands, `merge-base
# --is-ancestor` yes, `git show <sha>:<path>` prints the staged drifted
# workflow); the fake buck2 builds nothing and exits 1. No real git, no
# network, no nested buck2.
#
#   (a) an unknown flag: exit 2 (EXIT_USAGE), the usage text, the flag named
#       and `kci: REFUSED (exit 2)` on stderr; the result file FINISHED
#       REFUSED KCI-E-USAGE with the refusal as its message, exactly; the
#       summary block of a refused command line, byte for byte.
#   (b) `--plan` of a PUBLISH to a PRIVATE API-token channel, no token
#       (--secret-store none): exit 4 (EXIT_FAILED); the result file FINISHED
#       FAILED KCI-E-CREDENTIAL, no artifact row; stderr names the secret.
#   (c) a push to main under GitHub Actions (every variable the ref check
#       needs is valid, so the drift is the only refusal) with the committed
#       workflow drifted from the machine file: exit 3 (EXIT_REFUSED),
#       KCI-E-WORKFLOW-MISMATCH, the `workflow` record naming the path and
#       sha read and why it did not pass, no step run, the --log-dir still empty, git asked only `show`.
#   (d) a --result-file kci cannot write (its parent is a regular file:
#       ENOTDIR, which a root runner cannot bypass): exit 4 (EXIT_FAILED)
#       before any step and any git command; the id KCI-E-RESULT-FILE reaches
#       the summary file.
#   (e) a successful BUILD `--plan`: exit 0; the --summary-file block appended
#       byte for byte after what the file held; no --release-dir created, buck2
#       never started, git asked only read-only commands.
#
# Encapsulation: owned values; no pointer, no wildcard origin, no FFI.
# =============================================================================

from std.os import listdir, makedirs
from std.os.path import exists, realpath
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_libc.posix import _read_env

from kci_api import (
    ERROR_CREDENTIAL,
    ERROR_RESULT_FILE,
    ERROR_USAGE,
    ERROR_WORKFLOW_MISMATCH,
    EXIT_FAILED,
    EXIT_OK,
    EXIT_REFUSED,
    EXIT_USAGE,
    OUTCOME_FAILED,
    STATUS_FINISHED,
    default_retry,
    parse_result,
    release_platform_dir,
)
from kci_api import RunResult as KciRunResult
from kci_build import RunSpec, SupervisorRunner
from kci_publish.release_fixture import ExampleRelease

comptime _WORKFLOW_SHA: String = "0123456789abcdef0123456789abcdef01234567"
comptime _STAMP: String = "fedcba9876543210fedcba9876543210fedcba98"
comptime _REPOSITORY: String = "example/release"
comptime _WORKFLOW_PATH: String = ".github/workflows/kci.yml"


def _share() raises -> String:
    """The test's share/ (its declared data): the directory it starts in."""
    return realpath(String("."))


def _revision() -> String:
    return ExampleRelease().revision.copy()


def _fake_git(root: String) -> String:
    """The fake git (file header): `case` on its first words, shell builtins
    only, so it needs nothing on PATH."""
    var calls = root + String("/git.calls")
    var workflow = root + String("/kci_drifted.yml")
    return (
        String("#!/bin/sh\n")
        + String("printf '%s\\n' \"$*\" >> '") + calls + String("'\n")
        + String("case \"$1 $2 $3\" in\n")
        + String("  'rev-parse --is-shallow-repository '*) echo false ;;\n")
        + String("  'rev-parse --verify HEAD'*) echo ") + _revision() + String(" ;;\n")
        + String("  'status --porcelain '*) ;;\n")
        + String("  'log -1 --first-parent'*) echo ") + String(_STAMP) + String(" ;;\n")
        + String("  'rev-list --count '*) echo 7 ;;\n")
        + String("  'log -1 --format=%ct'*) echo 1790000000 ;;\n")
        + String("  'merge-base --is-ancestor '*) exit 0 ;;\n")
        + String("  'show '*) while IFS= read -r l || [ -n \"$l\" ]; do printf '%s\\n' \"$l\"; done < '")
        + workflow + String("' ;;\n")
        + String("  *) echo \"fake git: unexpected: $*\" >&2; exit 1 ;;\n")
        + String("esac\n")
    )


def _fake_buck2(root: String) -> String:
    """The fake buck2 (file header): logs its argv and builds nothing."""
    return (
        String("#!/bin/sh\n")
        + String("printf '%s\\n' \"$*\" >> '") + root + String("/buck2.calls'\n")
        + String("echo 'fake buck2: builds nothing' >&2\nexit 1\n")
    )


def _sh(root: String, script: String) raises:
    """`/bin/sh -c script` in `root`, which must exit 0."""
    var argv = List[String]()
    argv.append(String("-c"))
    argv.append(script)
    var spec = RunSpec(
        String("/bin/sh"), argv^, root.copy(), 30, root + String("/sh.stdout"), root + String("/sh.stderr")
    )
    var runner = SupervisorRunner()
    var r = runner.run(spec)
    assert_true(r.ok(), String("setup `") + script + String("`: ") + r.describe() + String(": ") + r.stderr_tail)


def _case(tag: String) raises -> String:
    """A fresh directory for one case: the staged fixtures copied in, the
    example release written under `release/` with its `--release-version`
    file, and the fake git and buck2 in `bin/`."""
    var base = _read_env("TEST_TMPDIR")
    assert_true(base.byte_length() > 0, String("TEST_TMPDIR is not set"))
    var root = base + String("/kci_process_") + tag
    makedirs(root + String("/bin"), exist_ok=False)
    var share = _share()
    for f in ["machine.textproto", "artifacts.textproto", "channels.textproto", "kci_drifted.yml"]:
        var name = String(f)
        Path(root + String("/") + name).write_text(Path(share + String("/fixtures/") + name).read_text())
    var r = ExampleRelease()
    r.write(release_platform_dir(root + String("/release"), r.platform))
    Path(root + String("/rv.txt")).write_text(r.release_version_text())
    Path(root + String("/bin/git")).write_text(_fake_git(root))
    Path(root + String("/bin/buck2")).write_text(_fake_buck2(root))
    _sh(root, String("chmod 755 bin/git bin/buck2"))
    return root^


struct KciRun(Movable):
    """How one run of the kci binary ended. Layout: owned values only."""

    var code: Int
    var stderr: String

    def __init__(out self, code: Int, var stderr: String):
        self.code = code
        self.stderr = stderr^


def _kci(root: String, var args: List[String], var env: List[String]) raises -> KciRun:
    """The kci binary with `args`, started in `root` with exactly `env` plus
    PATH (the fake git first), HOME and TMPDIR."""
    var exe = _share() + String("/kci/kci")
    assert_true(exists(exe), exe + String(" is not staged"))
    env.append(String("PATH=") + root + String("/bin:") + _read_env("PATH"))
    env.append(String("HOME=") + _read_env("HOME"))
    env.append(String("TMPDIR=") + _read_env("TMPDIR"))
    var spec = RunSpec(exe, args^, root.copy(), 120, root + String("/kci.stdout"), root + String("/kci.stderr"))
    spec.set_env(env^)
    var runner = SupervisorRunner()
    var r = runner.run(spec)
    var err = Path(spec.stderr_path).read_text()
    assert_false(r.signaled, String("kci was killed by a signal:\n") + err)
    assert_false(r.timed_out, String("kci timed out:\n") + err)
    return KciRun(Int(r.exit_code), err^)


def _args(stage: String, *extra: String) -> List[String]:
    var a = List[String]()
    for s in ["run", "--machine", "machine.textproto", "--stage"]:
        a.append(String(s))
    a.append(stage.copy())
    a.append(String("--revision-id"))
    a.append(_revision())
    for s in ["--run-id", "gh-9", "--attempt", "1"]:
        a.append(String(s))
    for s in extra:
        a.append(String(s))
    return a^


def _build_args(root: String, *extra: String) -> List[String]:
    var a = _args(String("build"))
    # absolute: a BUILD step renders {out_dir} under it, and refuses a relative one
    a.append(String("--release-dir"))
    a.append(root + String("/build-release"))
    a.append(String("--work-dir"))
    a.append(root.copy())
    a.append(String("--log-dir"))
    a.append(root + String("/logs"))
    for s in extra:
        a.append(String(s))
    return a^


def _result(path: String) raises -> KciRunResult:
    return parse_result(Path(path).read_text(), path)


def _has(text: String, part: String) raises:
    assert_true(text.find(part) >= 0, String("missing `") + part + String("` in:\n") + text)


def _lacks(text: String, part: String) raises:
    assert_true(text.find(part) < 0, String("unexpected `") + part + String("` in:\n") + text)


def _retry_is_default(res: KciRunResult) raises:
    """`retry` is the exit table's default for the exit number."""
    assert_equal(res.retry, default_retry(res.exit_code))


def _exit_line(outcome: String, code: Int) -> String:
    return String("kci: ") + outcome + String(" (exit ") + String(code) + String(")")


def test_staged_artifacts_are_the_example_release() raises:
    # The publish case loads the example release against the staged
    # artifacts file: the two must not drift apart.
    assert_equal(
        Path(_share() + String("/fixtures/artifacts.textproto")).read_text(), ExampleRelease().artifacts_text()
    )


def test_a_bad_command_line_is_exit_2() raises:
    var root = _case(String("usage"))
    var a = List[String]()
    for s in ["run", "--result-file", "result.json", "--summary-file", "summary.md", "--no-such-flag"]:
        a.append(String(s))
    var run = _kci(root, a^, List[String]())
    assert_equal(run.code, EXIT_USAGE, run.stderr)
    _has(run.stderr, String("usage:\n  kci run"))
    var said = String("unknown flag '--no-such-flag' for kci run")
    # the message on a line of its own after ONE `kci: `
    _has(run.stderr, String("\nkci: ") + said + String("\n"))
    _lacks(run.stderr, String("kci: kci:"))
    _has(run.stderr, _exit_line(String("REFUSED"), EXIT_USAGE))
    var res = _result(root + String("/result.json"))
    assert_equal(res.status, String(STATUS_FINISHED))
    assert_equal(res.outcome, String("REFUSED"))
    assert_equal(res.exit_code, EXIT_USAGE)
    assert_equal(res.error.id, String(ERROR_USAGE))
    # the stored message is the refusal as is: the one `kci: ` is stderr's
    assert_equal(res.error.message, said)
    _retry_is_default(res)
    # the whole block, byte for byte: no `kci: ` before the refusal
    assert_equal(
        Path(root + String("/summary.md")).read_text(),
        String("## kci: REFUSED (exit ") + String(EXIT_USAGE) + String(")\n\nThe command line was refused: ") + said
        + String("\n\n"),
    )
    assert_false(exists(root + String("/git.calls")))


def test_a_plan_without_the_private_channel_token_is_exit_4() raises:
    # the child's environment is explicit (_kci): it holds no token
    var root = _case(String("credential"))
    var a = _args(String("publish-prod"), "--plan", "--release-dir", "release", "--release-version", "rv.txt")
    for s in ["--secret-store", "none", "--result-file", "result.json"]:
        a.append(String(s))
    var run = _kci(root, a^, List[String]())
    assert_equal(run.code, EXIT_FAILED, run.stderr)
    _has(run.stderr, String("kci: stage publish-prod, step publish (PUBLISH)"))
    _has(run.stderr, String("the secret 'EXAMPLE_CONDA_TOKEN' cannot be resolved"))
    _has(run.stderr, _exit_line(String("FAILED"), EXIT_FAILED) + String(" stage publish-prod"))
    _has(run.stderr, String("kci: FULL run of stage publish-prod: FAILED"))
    var res = _result(root + String("/result.json"))
    assert_equal(res.status, String(STATUS_FINISHED))
    assert_equal(res.outcome, String("FAILED"))
    assert_equal(res.exit_code, EXIT_FAILED)
    assert_equal(res.error.id, String(ERROR_CREDENTIAL))
    _retry_is_default(res)
    assert_true(res.plan)
    assert_equal(len(res.artifacts), 0)
    assert_equal(len(res.steps), 1)
    assert_equal(res.steps[0].name, String("publish"))
    assert_equal(res.steps[0].kind, String("PUBLISH"))
    assert_equal(res.steps[0].outcome, String(OUTCOME_FAILED))
    assert_false(exists(root + String("/git.calls")))


def test_a_drifted_workflow_under_actions_is_exit_3_and_runs_nothing() raises:
    var root = _case(String("drift"))
    makedirs(root + String("/logs"), exist_ok=False)
    makedirs(root + String("/runner_temp"), exist_ok=False)
    var env = List[String]()
    env.append(String("GITHUB_ACTIONS=true"))
    # a valid push to main of the revision, so the ref check (4a) would let
    # the run through: the drifted workflow is the only refusal
    env.append(String("GITHUB_REF=refs/heads/main"))
    env.append(String("GITHUB_EVENT_NAME=push"))
    env.append(String("GITHUB_SHA=") + _revision())
    env.append(String("GITHUB_REPOSITORY=") + String(_REPOSITORY))
    env.append(
        String("GITHUB_WORKFLOW_REF=") + String(_REPOSITORY) + String("/") + String(_WORKFLOW_PATH)
        + String("@refs/heads/main")
    )
    env.append(String("GITHUB_WORKFLOW_SHA=") + String(_WORKFLOW_SHA))
    env.append(String("RUNNER_TEMP=") + root + String("/runner_temp"))
    var run = _kci(root, _build_args(root, "--result-file", "result.json", "--summary-file", "summary.md"), env^)
    assert_equal(run.code, EXIT_REFUSED, run.stderr)
    var said = String(_WORKFLOW_PATH) + String(" (at ") + String(_WORKFLOW_SHA) + String(") disagrees with machine.textproto")
    _has(run.stderr, said)
    _has(run.stderr, String("R1: job 'publish-build'"))
    _has(run.stderr, _exit_line(String("REFUSED"), EXIT_REFUSED) + String(" stage build"))
    _lacks(run.stderr, String("kci: stage build, step"))
    var res = _result(root + String("/result.json"))
    assert_equal(res.status, String(STATUS_FINISHED))
    assert_equal(res.outcome, String("REFUSED"))
    assert_equal(res.error.id, String(ERROR_WORKFLOW_MISMATCH))
    _retry_is_default(res)
    # the record names what was read; `checked` is true only for a workflow
    # that passed, and the reason says why this one did not
    assert_false(res.workflow_checked)
    assert_equal(res.workflow_reason, String("the workflow does not match the machine file"))
    assert_equal(res.workflow_path, String(_WORKFLOW_PATH))
    assert_equal(res.workflow_sha, String(_WORKFLOW_SHA))
    assert_equal(len(res.steps), 0)
    _has(Path(root + String("/summary.md")).read_text(), String("- error: `") + String(ERROR_WORKFLOW_MISMATCH) + String("`"))
    # git was asked for the committed workflow and nothing else
    assert_equal(
        Path(root + String("/git.calls")).read_text(),
        String("show ") + String(_WORKFLOW_SHA) + String(":") + String(_WORKFLOW_PATH) + String("\n"),
    )
    assert_equal(len(listdir(root + String("/logs"))), 0)
    assert_false(exists(root + String("/build-release")))
    assert_false(exists(root + String("/buck2.calls")))


def test_an_unwritable_result_file_stops_the_run_before_any_step() raises:
    var root = _case(String("result_file"))
    var blocker = String("a file, so blocker/ is no directory\n")
    Path(root + String("/blocker")).write_text(blocker)
    var run = _kci(root, _build_args(root, "--result-file", "blocker/result.json", "--summary-file", "summary.md"), List[String]())
    assert_equal(run.code, EXIT_FAILED, run.stderr)
    _has(run.stderr, String("kci: the RUNNING record could not be written, so nothing was run"))
    _has(run.stderr, _exit_line(String("FAILED"), EXIT_FAILED) + String(" stage build"))
    _lacks(run.stderr, String("kci: stage build, step"))
    _has(
        Path(root + String("/summary.md")).read_text(),
        String("- error: `") + String(ERROR_RESULT_FILE)
        + String("`: the RUNNING record could not be written, so nothing was run"),
    )
    # kci left the blocking file as it was (it did not make a directory of it)
    assert_equal(Path(root + String("/blocker")).read_text(), blocker)
    assert_false(exists(root + String("/buck2.calls")))
    assert_false(exists(root + String("/git.calls")))
    assert_false(exists(root + String("/logs")))
    assert_false(exists(root + String("/build-release")))


def test_a_successful_plan_appends_its_summary() raises:
    var root = _case(String("plan"))
    var earlier = String("an earlier block, kept\n")
    Path(root + String("/summary.md")).write_text(earlier)
    var run = _kci(root, _build_args(root, "--plan", "--result-file", "result.json", "--summary-file", "summary.md"), List[String]())
    assert_equal(run.code, EXIT_OK, run.stderr)
    assert_true(
        run.stderr.endswith(String("kci: FULL run of stage build: SUCCEEDED\n")), run.stderr
    )
    var rev = _revision()
    assert_equal(
        Path(root + String("/summary.md")).read_text(),
        earlier
        + String("## kci run --stage build: SUCCEEDED (exit 0)\n\n")
        + String("FULL run. Dry run (--plan): nothing built, nothing written to a channel or a cell.\n\n")
        + String("- revision: `") + rev + String("`\n")
        + String("- workflow: not checked (not under GitHub Actions)\n")
        + String("\n| step | kind | outcome |\n|---|---|---|\n| build | BUILD | SUCCEEDED |\n\n"),
    )
    var res = _result(root + String("/result.json"))
    assert_equal(res.status, String(STATUS_FINISHED))
    assert_equal(res.outcome, String("SUCCEEDED"))
    assert_equal(res.exit_code, EXIT_OK)
    assert_true(res.plan)
    assert_equal(len(res.artifacts), 3)
    _retry_is_default(res)
    # git was asked only read-only questions (the release stamp's; its exact
    # argv is kci_build's to test), buck2 never started, nothing written
    var calls = Path(root + String("/git.calls")).read_text()
    var lines = calls.splitlines()
    assert_true(len(lines) > 0, String("kci asked git nothing"))
    for line in lines:
        var l = String(line)
        var read_only = False
        for verb in ["rev-parse ", "status ", "log ", "rev-list "]:
            if l.startswith(String(verb)):
                read_only = True
        assert_true(read_only, String("git asked to `") + l + String("` in a --plan:\n") + calls)
    assert_false(exists(root + String("/buck2.calls")))
    assert_false(exists(root + String("/build-release")))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
