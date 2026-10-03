# =============================================================================
# src/kci_build/tests/test_revision.mojo
#   `--revision-id` against the checkout, and the stamp derived from git:
#   the six git commands exactly, in order, in the work dir; the values of
#   `{revision_id}`, `{source_commit}`, `{build_number}`, `{timestamp_ms}`;
#   every refusal (shallow clone, HEAD not the revision, modified tracked
#   files, no non-documentation commit, git exiting non-zero, output not of
#   the expected shape) with the commands after it not run; git that cannot
#   start or times out is INDETERMINATE; and through `run_build`, a refused
#   stamp (after the RUNNING record) runs no build and creates no platform
#   release directory.
# =============================================================================
#
# git is a ScriptedRunner: its argv must match each step exactly, so the
# argvs below are asserted by construction.
# =============================================================================

from std.ffi import external_call
from std.os import getenv, makedirs
from std.os.path import exists, realpath

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_contract import (
    ERROR_CANNOT_TELL,
    ERROR_REVISION,
    OUTCOME_INDETERMINATE,
    OUTCOME_REFUSED,
    OUTCOME_SUCCEEDED,
    STATUS_RUNNING,
    MemoryRecorder,
    RunIdentity,
    exit_code_of,
)
from kci_contract import RunResult as KciRunResult
from kci_build import (
    BuildRequest,
    ProcessRunner,
    RunResult,
    RunSpec,
    ScriptedRunner,
    ScriptedStep,
    derive_release_stamp,
    run_build,
    write_text_file,
)

comptime _REV = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
comptime _SRC = "f0e1d2c3b4a5968778695a4b3c2d1e0f12345678"
comptime _PREFIX = "BUILD step: --revision-id: "


def _fresh(tag: String) raises -> String:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/kr_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d + String("/repo"), exist_ok=True)
    makedirs(d + String("/logs"), exist_ok=True)
    return realpath(d)


def _request(root: String) raises -> BuildRequest:
    var r = BuildRequest(RunIdentity(String("gh-1"), 1))
    r.declarations_file = root + String("/decls.textproto")
    r.work_dir = root + String("/repo")
    r.release_dir = root + String("/release")
    r.log_dir = root + String("/logs")
    r.revision_id = String(_REV)
    r.platform = String("linux-x86_64")
    return r^


def _a(*xs: String) -> List[String]:
    var out = List[String]()
    for x in xs:
        out.append(String(x))
    return out^


def _shallow() -> List[String]:
    return _a("rev-parse", "--is-shallow-repository")


def _head() -> List[String]:
    return _a("rev-parse", "--verify", "HEAD")


def _status() -> List[String]:
    return _a("status", "--porcelain", "--untracked-files=no")


def _source() -> List[String]:
    return _a(
        "log", "-1", "--first-parent", "--format=%H", _REV, "--", ".",
        ":(exclude)docs", ":(exclude)*.md", ":(exclude).github",
    )


def _count() -> List[String]:
    return _a("rev-list", "--count", "--first-parent", _SRC)


def _time() -> List[String]:
    return _a("log", "-1", "--format=%ct", _SRC)


def _ok(var argv: List[String], text: String) -> ScriptedStep:
    return ScriptedStep(argv^, stdout_text=text)


def _git(
    shallow: String = String("false\n"),
    head: String = String(_REV) + String("\n"),
    status: String = String(""),
    source: String = String(_SRC) + String("\n"),
    count: String = String("154\n"),
    time: String = String("1790994309\n"),
) -> ScriptedRunner:
    var g = ScriptedRunner()
    g.expect(_ok(_shallow(), shallow))
    g.expect(_ok(_head(), head))
    g.expect(_ok(_status(), status))
    g.expect(_ok(_source(), source))
    g.expect(_ok(_count(), count))
    g.expect(_ok(_time(), time))
    return g^


def _refused(mut g: ScriptedRunner, ran: Int, why: String) raises:
    var root = _fresh(String("ref"))
    var r = derive_release_stamp(_request(root), g)
    assert_equal(r.outcome, String(OUTCOME_REFUSED), r.message)
    assert_equal(r.error_id, String(ERROR_REVISION))
    assert_equal(r.message, String(_PREFIX) + why)
    assert_false(Bool(r.stamp))
    # the commands after the refusal did not run
    assert_equal(len(g.calls), ran)


# ---- the stamp ---------------------------------------------------------------


def test_clean_full_history_checkout_gives_the_stamp() raises:
    var root = _fresh(String("ok"))
    var req = _request(root)
    var g = _git()
    var r = derive_release_stamp(req, g)
    assert_equal(r.outcome, String(OUTCOME_SUCCEEDED), r.message)
    assert_equal(g.remaining(), 0)
    var s = r.stamp.value().copy()
    assert_equal(s.revision_id, String(_REV))
    # the stamp commit is git's answer, not the revision: the newest commits
    # changed only documentation
    assert_equal(s.source_commit, String(_SRC))
    assert_equal(s.build_number, 154)
    assert_equal(s.timestamp_ms, 1790994309000)
    for i in range(len(g.calls)):
        assert_equal(g.calls[i].path, String("git"))
        assert_equal(g.calls[i].cwd, req.work_dir)
        assert_equal(g.calls[i].stdout_path, req.log_dir + String("/_git_") + String(i + 1) + String(".stdout"))
        assert_equal(g.calls[i].stderr_path, req.log_dir + String("/_git_") + String(i + 1) + String(".stderr"))


def test_the_stamp_commit_may_be_the_revision() raises:
    var root = _fresh(String("same"))
    var g = ScriptedRunner()
    g.expect(_ok(_shallow(), String("false\n")))
    g.expect(_ok(_head(), String(_REV) + String("\n")))
    g.expect(_ok(_status(), String("")))
    g.expect(_ok(_source(), String(_REV) + String("\n")))
    g.expect(_ok(_a("rev-list", "--count", "--first-parent", _REV), String("1\n")))
    g.expect(_ok(_a("log", "-1", "--format=%ct", _REV), String("1\n")))
    var r = derive_release_stamp(_request(root), g)
    assert_equal(r.outcome, String(OUTCOME_SUCCEEDED), r.message)
    assert_equal(r.stamp.value().source_commit, String(_REV))
    assert_equal(r.stamp.value().build_number, 1)
    assert_equal(r.stamp.value().timestamp_ms, 1000)


# ---- refusals ----------------------------------------------------------------


def test_a_shallow_clone_is_refused() raises:
    var root = _fresh(String("shallow"))
    var g = _git(shallow = String("true\n"))
    var r = derive_release_stamp(_request(root), g)
    assert_equal(r.outcome, String(OUTCOME_REFUSED))
    assert_equal(
        r.message,
        String(_PREFIX) + String("--work-dir '") + root
        + String("/repo' is a SHALLOW clone: the first-parent commit count there is the clone's")
        + String(" depth, not the history's, so the build number would be wrong; check out")
        + String(" with full history (actions/checkout fetch-depth: 0, or")
        + String(" `git fetch --unshallow`) and run `kci run --stage <stage>` again"),
    )
    assert_equal(len(g.calls), 1)


def test_an_unexpected_shallow_answer_is_refused() raises:
    var g = _git(shallow = String("maybe\n"))
    _refused(
        g, 1,
        String("`git rev-parse --is-shallow-repository` printed 'maybe', neither 'true' nor 'false'"),
    )


def test_head_not_the_revision_is_refused() raises:
    var root = _fresh(String("head"))
    var g = _git(head = String(_SRC) + String("\n"))
    var r = derive_release_stamp(_request(root), g)
    assert_equal(r.outcome, String(OUTCOME_REFUSED))
    assert_equal(
        r.message,
        String(_PREFIX) + String("'") + String(_REV)
        + String("' is not the commit checked out in --work-dir '") + root
        + String("/repo' (HEAD is '") + String(_SRC)
        + String("'): the stamp would name a commit whose bytes are not the ones built"),
    )
    assert_equal(len(g.calls), 2)


def test_modified_tracked_files_are_refused() raises:
    var root = _fresh(String("dirty"))
    var g = _git(status = String(" M src/komira_encoding/BUCK\n"))
    var r = derive_release_stamp(_request(root), g)
    assert_equal(r.outcome, String(OUTCOME_REFUSED))
    assert_equal(
        r.message,
        String(_PREFIX) + String("--work-dir '") + root
        + String("/repo' has modified tracked files ( M src/komira_encoding/BUCK): the stamp")
        + String(" would name a commit whose bytes are not the ones built"),
    )
    assert_equal(len(g.calls), 3)


def test_no_non_documentation_commit_is_refused() raises:
    var g = _git(source = String(""))
    _refused(
        g, 4,
        String("no first-parent commit at or below '") + String(_REV)
        + String("' touches anything but documentation: there is nothing to release"),
    )


def test_a_stamp_commit_that_is_not_a_full_id_is_refused() raises:
    var g = _git(source = String("f0e1d2c\n"))
    _refused(g, 4, String("`git log` printed 'f0e1d2c', not a full commit id"))


def test_a_count_that_is_not_positive_is_refused() raises:
    for c in ["0\n", "x\n", "\n", "-3\n"]:
        var g = _git(count = String(c))
        var shown = String(String(c)[byte = : String(c).byte_length() - 1])
        _refused(
            g, 5,
            String("`git rev-list --count` printed '") + shown + String("', not a positive count"),
        )


def test_a_commit_time_that_is_not_positive_is_refused() raises:
    var g = _git(time = String("0\n"))
    _refused(g, 6, String("`git log --format=%ct` printed '0', not a commit time"))


def test_more_than_one_line_is_refused() raises:
    var g = _git(head = String(_REV) + String("\n") + String(_REV) + String("\n"))
    _refused(
        g, 2,
        String("`git rev-parse --verify HEAD` printed more than one line: '") + String(_REV)
        + String("\n") + String(_REV) + String("'"),
    )


def test_git_exiting_non_zero_is_refused_with_its_stderr() raises:
    var g = ScriptedRunner()
    g.expect(
        ScriptedStep(
            _shallow(),
            exit_code=Int32(128),
            stderr_text=String("fatal: not a git repository (or any of the parent directories): .git\n"),
        )
    )
    _refused(
        g, 1,
        String("`git rev-parse --is-shallow-repository` exit 128: fatal: not a git repository")
        + String(" (or any of the parent directories): .git"),
    )


# ---- no verdict ----------------------------------------------------------------


struct _Unstartable(ProcessRunner):
    var calls: Int

    def __init__(out self):
        self.calls = 0

    def run(mut self, spec: RunSpec) raises -> RunResult:
        self.calls += 1
        raise Error(String("cannot start '") + spec.path + String("': errno 2"))


def test_git_that_cannot_start_is_cannot_tell() raises:
    var root = _fresh(String("nogit"))
    var g = _Unstartable()
    var r = derive_release_stamp(_request(root), g)
    assert_equal(r.outcome, String(OUTCOME_INDETERMINATE))
    assert_equal(r.error_id, String(ERROR_CANNOT_TELL))
    assert_equal(
        r.message,
        String(_PREFIX)
        + String("`git rev-parse --is-shallow-repository` could not be started: cannot start 'git': errno 2"),
    )
    assert_equal(g.calls, 1)


def test_git_that_times_out_is_cannot_tell() raises:
    var root = _fresh(String("slow"))
    var g = ScriptedRunner()
    g.expect(_ok(_shallow(), String("false\n")))
    g.expect(ScriptedStep(_head(), timed_out=True))
    var r = derive_release_stamp(_request(root), g)
    assert_equal(r.outcome, String(OUTCOME_INDETERMINATE))
    assert_equal(r.error_id, String(ERROR_CANNOT_TELL))
    assert_equal(r.message, String(_PREFIX) + String("`git rev-parse --verify HEAD` timed out"))


# ---- through run_build ---------------------------------------------------


def test_a_refused_stamp_runs_no_build_and_creates_no_release_dir() raises:
    var root = _fresh(String("flow"))
    var req = _request(root)
    write_text_file(
        req.declarations_file,
        String(
            'schema_version: 1\n'
            'build_systems { name: "b" executable: "b" }\n'
            'artifacts { name: "a" build_system: "b" args: "--out={out_dir}" }\n'
        ),
    )
    var builds = ScriptedRunner()
    var g = _git(shallow = String("true\n"))
    var result = KciRunResult(String("run"), String("build"))
    var rec = MemoryRecorder()
    var outcome = run_build(req, result, rec, builds, g)
    assert_equal(outcome.outcome, String(OUTCOME_REFUSED))
    assert_equal(outcome.error_id, String(ERROR_REVISION))
    assert_equal(outcome.exit_code(), exit_code_of(String(OUTCOME_REFUSED)))
    assert_true(outcome.message.startswith(String(_PREFIX) + String("--work-dir '")))
    assert_equal(len(builds.calls), 0)
    assert_false(exists(req.platform_dir()))
    # the RUNNING record came first: git reading the checkout is the first effect
    assert_equal(len(rec.statuses), 1)
    assert_equal(rec.statuses[0], String(STATUS_RUNNING))
    assert_equal(result.error.id, String(ERROR_REVISION))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
