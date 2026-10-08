# =============================================================================
# src/kci_validate/tests/test_deploy_probe.mojo
#   A DEPLOY_PROBE validation over kci_build's ScriptedRunner as a fake docker
#   (it writes what the image would leave in /work/out): every row of the
#   verdict table (deploy_probe.mojo), the pre-flight before the probe and
#   its exit mapping, and `docker rm -f kci-probe-<id>` after a timeout.
#   Each case id is one checks[] entry of the probe's one row. Where a check
#   runs over a list (the expect ids, the results lines), the bad item is the
#   SECOND one, so a check that reads only the first goes red.
# =============================================================================

from std.os import getenv, makedirs
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_api import (
    OUTCOME_INDETERMINATE,
    OUTCOME_SUCCEEDED,
    OUTCOME_VALIDATION_FAILED,
    VALIDATION_ENVIRONMENT_CONTAINER,
    VALIDATION_KIND_DEPLOY_PROBE,
    VALIDATION_NOT_REACHED,
    VALIDATION_VALIDATED,
    VALIDATION_WOULD_VALIDATE,
    ResultValidation,
)
from kci_build.runner import ProcessRunner, RunResult, RunSpec
from kci_build.scripted_runner import ScriptedRunner, ScriptedStep
from kci_release_machine import StageValidation
from kci_validate import (
    CHECK_CONTAINER,
    CHECK_IMAGE,
    CHECK_PREFLIGHT,
    CHECK_RESULTS,
    CHECK_SCRATCH,
    ContainerHost,
    ProbeRequest,
    preflight_run_argv,
    probe_run_argv,
    pull_argv,
    remove_argv,
    run_deploy_probe,
)

comptime IMAGE: String = "registry.example.invalid/probe@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
comptime PRE: String = "registry.example.invalid/busybox@sha256:fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
comptime ID: String = "gh-42-1-probe-9eff98f29188"
"""probe_run_id("gh-42", 1, "probe"); pinned in test_probe_argv_golden."""
comptime USER: String = "1001:118"
comptime RESULTS: String = "work/out/results.jsonl"
comptime URL: String = "https://api.example.invalid"


def _tmp(sub: String) raises -> String:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/deploy_probe/") + sub
    makedirs(d, exist_ok=True)
    return d^


def _validation() -> StageValidation:
    var v = StageValidation(9)
    v.name = String("probe")
    v.kind = String(VALIDATION_KIND_DEPLOY_PROBE)
    v.image = String(IMAGE)
    v.args.append(String("--checks=smoke"))
    v.target_resource = String("api")
    v.target_output = String("url")
    v.timeout_seconds = 300
    v.expects.append(String("health"))
    v.expects.append(String("login"))
    return v^


def _req(sub: String) raises -> ProbeRequest:
    var r = ProbeRequest(_validation())
    r.step_name = String("deploy")
    r.run_id = String("gh-42")
    r.attempt = 1
    r.target_url = String(URL)
    r.scratch_dir = _tmp(sub)
    r.preflight_image = String(PRE)
    return r^


def _host() -> ContainerHost:
    return ContainerHost(String("/usr/bin/docker"), String("/usr/bin:/bin"), String(USER))


def _work(req: ProbeRequest) -> String:
    return req.scratch_dir + String("/probe/work")


def _probe_argv(req: ProbeRequest) -> List[String]:
    var args = List[String]()
    args.append(String("--checks=smoke"))
    return probe_run_argv(String(IMAGE), _work(req), String(USER), String(ID), 300, args, String(URL))


def _preflight(mut fake: ScriptedRunner, exit_code: Int32 = Int32(1), timed_out: Bool = False):
    fake.expect(ScriptedStep(pull_argv(String(PRE))))
    fake.expect(ScriptedStep(preflight_run_argv(String(PRE), String(USER), String(ID)), exit_code, timed_out=timed_out))


def _scripted(req: ProbeRequest, results: String, exit_code: Int32 = Int32(0), timed_out: Bool = False) -> ScriptedRunner:
    """The pre-flight passes (exit 1), the pull succeeds, the probe writes
    `results` (no file when "<none>") and exits `exit_code`."""
    var fake = ScriptedRunner()
    _preflight(fake)
    fake.expect(ScriptedStep(pull_argv(String(IMAGE))))
    var run = ScriptedStep(_probe_argv(req), exit_code, timed_out=timed_out)
    if results != String("<none>"):
        run.writes(String(RESULTS), results.copy())
    fake.expect(run^)
    return fake^


def _line(id: String, outcome: String) -> String:
    return String("{\"id\": \"") + id + String("\", \"outcome\": \"") + outcome + String("\", \"detail\": \"d\"}\n")


def _check(row: ResultValidation, name: String) raises -> Int:
    for i in range(len(row.checks)):
        if row.checks[i].check == name:
            return i
    raise Error(String("no check '") + name + String("'"))


def _assert_failed_on(row: ResultValidation, name: String) raises:
    assert_equal(row.effect, String(VALIDATION_VALIDATED))
    assert_equal(row.outcome, String(OUTCOME_VALIDATION_FAILED))
    assert_false(row.checks[_check(row, name)].ok, name)
    assert_equal(row.skip_reason, String(""))


def _assert_indeterminate(row: ResultValidation, check: String, needle: String) raises:
    assert_equal(row.effect, String(VALIDATION_VALIDATED))
    assert_equal(row.outcome, String(OUTCOME_INDETERMINATE))
    assert_equal(row.environment, String(VALIDATION_ENVIRONMENT_CONTAINER))
    assert_true(row.skip_reason.find(needle) >= 0, row.skip_reason)
    assert_false(row.checks[_check(row, check)].ok)


def _ran_probe(fake: ScriptedRunner) -> Bool:
    """Whether any recorded call is the probe's `docker run` or its pull."""
    for i in range(len(fake.calls)):
        ref a = fake.calls[i].argv
        for k in range(len(a)):
            if a[k] == String(IMAGE):
                return True
    return False


# ---- VALIDATED, SUCCEEDED ------------------------------------------------------


def test_every_expect_passing_once_with_exit_0_is_succeeded() raises:
    var req = _req(String("pass"))
    var fake = _scripted(req, _line(String("health"), String("pass")) + _line(String("login"), String("pass")))
    var row = run_deploy_probe(fake, req, _host())
    assert_equal(fake.remaining(), 0)
    assert_equal(row.name, String("probe"))
    assert_equal(row.step, String("deploy"))
    assert_equal(row.kind, String(VALIDATION_KIND_DEPLOY_PROBE))
    assert_equal(row.effect, String(VALIDATION_VALIDATED))
    assert_equal(row.environment, String(VALIDATION_ENVIRONMENT_CONTAINER))
    assert_equal(row.outcome, String(OUTCOME_SUCCEEDED))
    # one row; each case is one check, then kci's own
    assert_equal(len(row.checks), 5)
    assert_equal(row.checks[0].check, String(CHECK_PREFLIGHT))
    assert_equal(row.checks[1].check, String(CHECK_IMAGE))
    assert_equal(row.checks[2].check, String("health"))
    assert_equal(row.checks[2].expected, String("pass"))
    assert_equal(row.checks[2].got, String("pass"))
    assert_equal(row.checks[3].check, String("login"))
    assert_equal(row.checks[4].check, String(CHECK_CONTAINER))
    for i in range(len(row.checks)):
        assert_true(row.checks[i].ok, row.checks[i].check)
    # the pre-flight ran before the probe: its pull, its container, then the
    # probe's pull and run
    assert_equal(len(fake.calls), 4)
    assert_equal(fake.calls[0].argv[1], String(PRE))
    assert_equal(fake.calls[1].argv[len(fake.calls[1].argv) - 6], String("nc"))
    assert_equal(fake.calls[2].argv[1], String(IMAGE))
    assert_equal(fake.calls[3].argv[0], String("run"))
    # the docker CLI gets PATH, HOME and DOCKER_CONFIG only
    var env = fake.calls[3].env.value().copy()
    assert_equal(len(env), 3)
    assert_equal(fake.calls[3].timeout_s, 300)


# ---- VALIDATED, VALIDATION_FAILED ----------------------------------------------


def test_a_missing_expect_row_fails() raises:
    # the SECOND expect id has no row
    var req = _req(String("missing"))
    var fake = _scripted(req, _line(String("health"), String("pass")))
    var row = run_deploy_probe(fake, req, _host())
    _assert_failed_on(row, String("login"))
    assert_equal(row.checks[_check(row, String("login"))].got, String(""))
    assert_true(row.checks[_check(row, String("health"))].ok)


def test_an_id_not_in_expect_fails() raises:
    var req = _req(String("unexpected"))
    var fake = _scripted(
        req, _line(String("health"), String("pass")) + _line(String("login"), String("pass")) + _line(String("extra"), String("pass"))
    )
    var row = run_deploy_probe(fake, req, _host())
    _assert_failed_on(row, String("extra"))
    assert_true(row.checks[_check(row, String("extra"))].got.find(String("no expect names this case")) >= 0)


def test_an_id_written_twice_fails() raises:
    var req = _req(String("twice"))
    var fake = _scripted(
        req, _line(String("health"), String("pass")) + _line(String("login"), String("pass")) + _line(String("login"), String("pass"))
    )
    var row = run_deploy_probe(fake, req, _host())
    _assert_failed_on(row, String("login"))
    assert_equal(row.checks[_check(row, String("login"))].got, String("written 2 times: pass, pass"))


def test_a_row_that_is_not_pass_fails() raises:
    var req = _req(String("notpass"))
    var fake = _scripted(req, _line(String("health"), String("pass")) + _line(String("login"), String("fail")))
    var row = run_deploy_probe(fake, req, _host())
    _assert_failed_on(row, String("login"))
    assert_equal(row.checks[_check(row, String("login"))].got, String("fail"))


def test_a_malformed_line_fails() raises:
    # the SECOND line is malformed; the first is fine
    var bad = List[String]()
    bad.append(String("not json\n"))
    bad.append(String("[1, 2]\n"))
    bad.append(String("{\"id\": \"login\"}\n"))
    bad.append(String("{\"id\": \"login\", \"outcome\": 1}\n"))
    bad.append(String("{\"id\": \"Login!\", \"outcome\": \"pass\"}\n"))
    bad.append(String("{\"id\": \"login\", \"outcome\": \"pass\", \"verdict\": \"pass\"}\n"))
    bad.append(String("\n"))
    for i in range(len(bad)):
        var req = _req(String("malformed") + String(i))
        var fake = _scripted(req, _line(String("health"), String("pass")) + bad[i] + _line(String("login"), String("pass")))
        var row = run_deploy_probe(fake, req, _host())
        _assert_failed_on(row, String(CHECK_RESULTS))
        assert_true(row.checks[_check(row, String(CHECK_RESULTS))].got.find(String("line 2 ")) >= 0, bad[i])


def test_a_non_zero_exit_fails() raises:
    var req = _req(String("exit3"))
    var fake = _scripted(req, _line(String("health"), String("pass")) + _line(String("login"), String("pass")), Int32(3))
    var row = run_deploy_probe(fake, req, _host())
    _assert_failed_on(row, String(CHECK_CONTAINER))
    assert_equal(row.checks[_check(row, String(CHECK_CONTAINER))].got, String("exit 3"))
    # the cases themselves read as written
    assert_true(row.checks[_check(row, String("login"))].ok)


def test_an_image_that_writes_nothing_fails() raises:
    var req = _req(String("nothing"))
    var fake = _scripted(req, String("<none>"))
    var row = run_deploy_probe(fake, req, _host())
    _assert_failed_on(row, String("health"))
    _assert_failed_on(row, String("login"))


def test_the_timeout_removes_the_container_by_name() raises:
    var req = _req(String("timeout"))
    var fake = _scripted(req, _line(String("health"), String("pass")) + _line(String("login"), String("pass")), timed_out=True)
    fake.expect(ScriptedStep(remove_argv(String("kci-probe-") + String(ID))))
    var row = run_deploy_probe(fake, req, _host())
    assert_equal(fake.remaining(), 0)
    # the recorded calls end at the removal, after the run, with the same
    # docker environment
    assert_equal(len(fake.calls), 5)
    assert_equal(fake.calls[4].argv[0], String("rm"))
    assert_equal(fake.calls[4].argv[1], String("-f"))
    assert_equal(fake.calls[4].argv[2], String("kci-probe-") + String(ID))
    var rm_env = fake.calls[4].env.value().copy()
    var run_env = fake.calls[3].env.value().copy()
    assert_equal(len(rm_env), len(run_env))
    for i in range(len(run_env)):
        assert_equal(rm_env[i], run_env[i])
    _assert_failed_on(row, String(CHECK_CONTAINER))
    assert_equal(
        row.checks[_check(row, String(CHECK_CONTAINER))].got,
        String("timed out; docker rm -f kci-probe-") + String(ID) + String(": exit 0"),
    )


def test_a_failed_removal_is_said_in_the_row() raises:
    var req = _req(String("rmfail"))
    var fake = _scripted(req, String("<none>"), timed_out=True)
    fake.expect(ScriptedStep(remove_argv(String("kci-probe-") + String(ID)), Int32(1), stderr_text=String("no such container")))
    var row = run_deploy_probe(fake, req, _host())
    _assert_failed_on(row, String(CHECK_CONTAINER))
    assert_true(row.checks[_check(row, String(CHECK_CONTAINER))].got.find(String(": exit 1: no such container")) >= 0)


# ---- INDETERMINATE: the probe never runs after a failed pre-flight -------------


def test_the_preflight_connect_succeeding_is_indeterminate() raises:
    var req = _req(String("reachable"))
    var fake = ScriptedRunner()
    _preflight(fake, Int32(0))
    var row = run_deploy_probe(fake, req, _host())
    _assert_indeterminate(row, String(CHECK_PREFLIGHT), String("answered"))
    assert_false(_ran_probe(fake))
    assert_equal(len(fake.calls), 2)


def test_a_preflight_that_cannot_run_is_indeterminate() raises:
    # docker's own exits, and an exit nc does not give
    var codes = List[Int]()
    for c in [125, 126, 127, 2]:
        codes.append(Int(c))
    for i in range(len(codes)):
        var req = _req(String("preflight") + String(codes[i]))
        var fake = ScriptedRunner()
        _preflight(fake, Int32(codes[i]))
        var row = run_deploy_probe(fake, req, _host())
        _assert_indeterminate(row, String(CHECK_PREFLIGHT), String("the pre-flight cannot run: exit ") + String(codes[i]))
        assert_false(_ran_probe(fake))


def test_a_preflight_timeout_is_indeterminate() raises:
    var req = _req(String("preflight_timeout"))
    var fake = ScriptedRunner()
    _preflight(fake, Int32(0), timed_out=True)
    fake.expect(ScriptedStep(remove_argv(String("kci-preflight-") + String(ID))))
    var row = run_deploy_probe(fake, req, _host())
    _assert_indeterminate(row, String(CHECK_PREFLIGHT), String("the pre-flight cannot run: timed out"))
    assert_false(_ran_probe(fake))
    assert_equal(fake.remaining(), 0)


def test_a_failed_preflight_pull_is_indeterminate() raises:
    var req = _req(String("preflight_pull"))
    var fake = ScriptedRunner()
    fake.expect(ScriptedStep(pull_argv(String(PRE)), Int32(1), stderr_text=String("manifest unknown")))
    var row = run_deploy_probe(fake, req, _host())
    _assert_indeterminate(row, String(CHECK_PREFLIGHT), String("docker pull ") + String(PRE) + String(": exit 1"))
    assert_false(_ran_probe(fake))


def test_a_failed_probe_pull_is_indeterminate() raises:
    var req = _req(String("pull"))
    var fake = ScriptedRunner()
    _preflight(fake)
    fake.expect(ScriptedStep(pull_argv(String(IMAGE)), Int32(1)))
    var row = run_deploy_probe(fake, req, _host())
    _assert_indeterminate(row, String(CHECK_IMAGE), String("the probe cannot run: exit 1"))
    assert_equal(len(fake.calls), 3)


def test_a_container_that_cannot_start_is_indeterminate() raises:
    var req = _req(String("cannot_start"))
    var fake = _scripted(req, String("<none>"), Int32(125))
    var row = run_deploy_probe(fake, req, _host())
    _assert_indeterminate(row, String(CHECK_CONTAINER), String("the container cannot start: exit 125"))


struct _NoDocker(ProcessRunner):
    """docker is missing: nothing can be started."""

    var calls: Int

    def __init__(out self):
        self.calls = 0

    def run(mut self, spec: RunSpec) raises -> RunResult:
        self.calls += 1
        raise Error(spec.path + String(": No such file or directory"))


def test_missing_docker_is_indeterminate() raises:
    var req = _req(String("no_docker"))
    var fake = _NoDocker()
    var row = run_deploy_probe(fake, req, _host())
    _assert_indeterminate(row, String(CHECK_PREFLIGHT), String("not started"))
    assert_equal(fake.calls, 1)


def test_a_scratch_directory_in_use_is_indeterminate() raises:
    var req = _req(String("used"))
    makedirs(req.scratch_dir + String("/probe/left"), exist_ok=True)
    var fake = ScriptedRunner()
    var row = run_deploy_probe(fake, req, _host())
    _assert_indeterminate(row, String(CHECK_SCRATCH), String("exists and is not empty"))
    assert_equal(len(fake.calls), 0)


# ---- NOT_REACHED, WOULD_VALIDATE, the caller's errors ---------------------------


def test_a_deploy_step_that_did_not_succeed_is_not_reached() raises:
    var req = _req(String("not_reached"))
    req.step_succeeded = False
    var fake = ScriptedRunner()
    var row = run_deploy_probe(fake, req, _host())
    assert_equal(row.effect, String(VALIDATION_NOT_REACHED))
    assert_equal(row.outcome, String(""))
    assert_equal(len(row.checks), 0)
    assert_equal(row.environment, String(""))
    assert_equal(len(fake.calls), 0)


def test_plan_runs_nothing() raises:
    var req = _req(String("plan"))
    req.plan = True
    var fake = ScriptedRunner()
    var row = run_deploy_probe(fake, req, _host())
    assert_equal(row.effect, String(VALIDATION_WOULD_VALIDATE))
    assert_equal(row.outcome, String(""))
    assert_equal(len(row.checks), 0)
    assert_equal(len(fake.calls), 0)


def _raises(req: ProbeRequest, needle: String) raises:
    var fake = ScriptedRunner()
    try:
        _ = run_deploy_probe(fake, req, _host())
    except e:
        assert_true(String(e).find(needle) >= 0, String(e))
        assert_equal(len(fake.calls), 0)
        return
    raise Error(String("not refused: ") + needle)


def test_the_callers_errors_raise() raises:
    var tag = _req(String("tag"))
    tag.preflight_image = String("busybox:1.37")
    _raises(tag, String("--preflight-image 'busybox:1.37' is not pinned by digest"))
    var placeholder = _req(String("placeholder"))
    placeholder.preflight_image = String("docker.io/library/busybox@sha256:0000000000000000000000000000000000000000000000000000000000000000")
    _raises(placeholder, String("the platform table's placeholder"))
    var no_url = _req(String("no_url"))
    no_url.target_url = String("")
    _raises(no_url, String("has a target and was given no target URL"))
    var other = _req(String("other"))
    other.validation.kind = String("CONDA_INSTALL_SMOKE")
    _raises(other, String("is CONDA_INSTALL_SMOKE, not DEPLOY_PROBE"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
