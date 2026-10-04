# =============================================================================
# src/kci_validate/tests/test_conda_install_smoke.mojo
#   A CONDA_INSTALL_SMOKE validation over ScriptedRunner: the pass, and every
#   way it fails closed (VALIDATION_FAILED, never a skip): a solve that
#   fails, a timeout, an installer that cannot start, a sha256 that differs,
#   a record from another channel, a member not installed, a record without
#   sha256 or that does not parse, a smoke program that exits nonzero or does
#   not print its OK line, a name outside the set, a used scratch directory.
#   The child gets exactly the listed environment (no CI token variable).
#   --plan runs nothing and makes no directory.
#
# Hermetic: TEST_TMPDIR, kci_publish's ExampleRelease (komira_alpha,
# komira_beta, the metapackage komira), no pixi, no network.
# =============================================================================

from std.os import getenv, makedirs, setenv
from std.os.path import exists
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_build import ANY_ARG, ScriptedRunner, ScriptedStep
from kci_contract import (
    OUTCOME_SUCCEEDED,
    OUTCOME_VALIDATION_FAILED,
    VALIDATION_KIND_CONDA_INSTALL_SMOKE,
    VALIDATION_VALIDATED,
    VALIDATION_WOULD_VALIDATE,
    ResultValidation,
)
from kci_publish.inputs import LoadedRelease
from kci_publish.release_fixture import ExampleRelease, example_loaded, write_text_file
from kci_release_set.release_manifest import ReleaseEntry
from kci_stage_graph import StageValidation
from kci_validate import (
    install_manifest_text,
    run_install_smoke,
    smoke_child_env,
    smoke_ok_line,
    smoke_stem,
)

comptime CHANNEL: String = "https://conda.example.invalid/example/gamma"
comptime OTHER_CHANNEL: String = "https://conda.example.invalid/conda-forge"
comptime PROGRAM: String = "release/smoke/smoke_example_pkg.mojo"
comptime OK_LINE: String = "example_pkg smoke: OK"
comptime META: String = ".pixi/envs/default/conda-meta/"
comptime CHILD_PATH: String = "/usr/bin:/bin"


def _tmp(sub: String) raises -> String:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/install_smoke/") + sub
    makedirs(d, exist_ok=True)
    return d^


def _release(root: String) raises -> LoadedRelease:
    var r = ExampleRelease()
    var dir = root + String("/release/linux-x86_64")
    r.write(dir)
    return example_loaded(r, dir)


def _validation(install: String = String("komira")) -> StageValidation:
    var v = StageValidation(7)
    v.name = String("install-smoke")
    v.kind = String(VALIDATION_KIND_CONDA_INSTALL_SMOKE)
    v.install = install.copy()
    v.extra_channels.append(String("https://conda.example.invalid/max"))
    v.extra_channels.append(String("conda-forge"))
    v.program = String(PROGRAM)
    return v^


def _entry(rel: LoadedRelease, name: String) raises -> ReleaseEntry:
    for i in range(len(rel.recomputed.entries)):
        if rel.recomputed.entries[i].name == name:
            return rel.recomputed.entries[i].copy()
    raise Error(String("no entry ") + name)


def _record(e: ReleaseEntry, channel: String = String(CHANNEL), sha: String = String("<same>")) -> String:
    var s = sha.copy()
    if s == String("<same>"):
        s = e.sha256_hex.copy()
    var sha_kv = String("")
    if s.byte_length() > 0:
        sha_kv = String(',"sha256":"') + s + String('"')
    return (
        String('{"name":"') + e.name + String('","version":"') + e.version + String('","build":"') + e.build
        + String('"') + sha_kv + String(',"url":"') + channel + String("/") + e.subdir + String("/") + e.name
        + String("-") + e.version + String("-") + e.build + String('.conda","depends":[]}')
    )


def _zeros(n: Int) -> String:
    var s = String("")
    for _ in range(n):
        s += String("0")
    return s^


def _install_argv() -> List[String]:
    var a = List[String]()
    a.append(String("install"))
    a.append(String("--manifest-path"))
    a.append(String(ANY_ARG))
    return a^


def _smoke_argv() -> List[String]:
    var a = List[String]()
    a.append(String("run"))
    a.append(String("--manifest-path"))
    a.append(String(ANY_ARG))
    a.append(String("--frozen"))
    a.append(String("mojo"))
    a.append(String("run"))
    a.append(String("/repo/") + String(PROGRAM))
    return a^


def _install(
    rel: LoadedRelease,
    skip: String = String(""),
    bad_sha: String = String(""),
    other_channel: String = String(""),
    no_sha: String = String(""),
) raises -> ScriptedStep:
    """An install that exits 0 and leaves a record per member, each
    exactly the release's unless a member is named for one defect."""
    var step = ScriptedStep(_install_argv())
    for i in range(len(rel.recomputed.entries)):
        ref e = rel.recomputed.entries[i]
        if e.name == skip:
            continue
        var text: String
        if e.name == bad_sha:
            text = _record(e, sha=_zeros(64))
        elif e.name == other_channel:
            text = _record(e, channel=String(OTHER_CHANNEL))
        elif e.name == no_sha:
            text = _record(e, sha=String(""))
        else:
            text = _record(e)
        step.writes(String(META) + e.name + String("-") + e.version + String("-") + e.build + String(".json"), text^)
    # pixi also writes a history file there; it is not a record
    step.writes(String(META) + String("history"), String("==> 2026-10-04 <==\n"))
    return step^


def _smoke(stdout_text: String = String(OK_LINE) + String("\n"), exit_code: Int32 = Int32(0)) -> ScriptedStep:
    return ScriptedStep(_smoke_argv(), exit_code=exit_code, stdout_text=stdout_text.copy())


def _run(mut runner: ScriptedRunner, rel: LoadedRelease, scratch: String, v: StageValidation, plan: Bool = False) raises -> ResultValidation:
    return run_install_smoke(
        runner, String("publish"), v, String(CHANNEL), rel, String("linux-x86_64"), scratch, String("/repo"),
        String(CHILD_PATH), plan=plan,
    )


def _failed_check(row: ResultValidation) -> String:
    """The name of the first failed check ("" if none)."""
    for i in range(len(row.checks)):
        if not row.checks[i].ok:
            return row.checks[i].check.copy()
    return String("")


def _failed_got(row: ResultValidation) -> String:
    for i in range(len(row.checks)):
        if not row.checks[i].ok:
            return row.checks[i].got.copy()
    return String("")


def test_smoke_line_from_the_program_name() raises:
    assert_equal(smoke_ok_line(String("release/smoke/smoke_komira_encoding.mojo")), String("komira_encoding smoke: OK"))
    assert_equal(smoke_stem(String("a/b/check.mojo")), String("check"))
    assert_equal(smoke_stem(String("smoke_.mojo")), String("smoke_"))


def test_manifest_pins_the_release_to_the_channel() raises:
    assert_equal(
        install_manifest_text(_validation(), String(CHANNEL), String("linux-64"), String("1.0.0"), String("h01234567_3")),
        String(
            "# Written by kci for validation 'install-smoke': installs the release from its channel only.\n"
            "[workspace]\nname = \"kci-install-smoke\"\n"
            "channels = [\"https://conda.example.invalid/example/gamma\", \"https://conda.example.invalid/max\","
            " \"conda-forge\"]\nplatforms = [\"linux-64\"]\n\n[dependencies]\n"
            "komira = { version = \"==1.0.0\", build = \"h01234567_3\","
            " channel = \"https://conda.example.invalid/example/gamma\" }\n"
        ),
    )


def test_pass() raises:
    var root = _tmp(String("pass"))
    var rel = _release(root)
    var runner = ScriptedRunner()
    runner.expect(_install(rel))
    runner.expect(_smoke())
    var row = _run(runner, rel, root + String("/scratch"), _validation())
    assert_equal(row.outcome, String(OUTCOME_SUCCEEDED))
    assert_equal(row.effect, String(VALIDATION_VALIDATED))
    assert_equal(row.name, String("install-smoke"))
    assert_equal(row.step, String("publish"))
    assert_equal(runner.remaining(), 0)
    assert_equal(len(runner.calls), 2)
    assert_equal(_failed_check(row), String(""))
    # every member checked by name, and the smoke line
    var named = 0
    for i in range(len(row.checks)):
        if row.checks[i].check.startswith(String("installed ")):
            named += 1
    assert_equal(named, 3)
    assert_equal(row.checks[len(row.checks) - 1].check, String("smoke output"))
    # the manifest kci wrote is the one it renders, with the release's V and B
    var dir = root + String("/scratch/install-smoke")
    var meta = _entry(rel, String("komira"))
    assert_equal(
        open(dir + String("/pixi.toml"), "r").read(),
        install_manifest_text(_validation(), String(CHANNEL), String("linux-64"), meta.version, meta.build),
    )
    assert_equal(runner.calls[0].argv[2], dir + String("/pixi.toml"))
    assert_equal(runner.calls[0].cwd, dir)
    assert_equal(runner.calls[0].path, String("pixi"))


def test_child_gets_exactly_the_listed_environment() raises:
    setenv(String("ACTIONS_ID_TOKEN_REQUEST_TOKEN"), String("held-by-the-job"), True)
    setenv(String("ACTIONS_ID_TOKEN_REQUEST_URL"), String("https://token.example.invalid/"), True)
    var root = _tmp(String("env"))
    var rel = _release(root)
    var runner = ScriptedRunner()
    runner.expect(_install(rel))
    runner.expect(_smoke())
    var row = _run(runner, rel, root + String("/scratch"), _validation())
    assert_equal(row.outcome, String(OUTCOME_SUCCEEDED))
    var dir = root + String("/scratch/install-smoke")
    var want = smoke_child_env(dir, String(CHILD_PATH))
    assert_equal(len(want), 5)
    for c in range(len(runner.calls)):
        assert_true(Bool(runner.calls[c].env))
        ref got = runner.calls[c].env.value()
        assert_equal(len(got), len(want))
        for i in range(len(want)):
            assert_equal(got[i], want[i])
            assert_false(got[i].startswith(String("ACTIONS_")))
    assert_equal(want[0], String("PATH=") + String(CHILD_PATH))
    assert_equal(want[2], String("PIXI_HOME=") + dir + String("/pixi_home"))


def test_solve_failure_fails() raises:
    var root = _tmp(String("solve"))
    var rel = _release(root)
    var runner = ScriptedRunner()
    runner.expect(ScriptedStep(_install_argv(), exit_code=Int32(1), stderr_text=String("No candidates were found for komira")))
    var row = _run(runner, rel, root + String("/scratch"), _validation())
    assert_equal(row.outcome, String(OUTCOME_VALIDATION_FAILED))
    assert_equal(_failed_check(row), String("install"))
    assert_true(_failed_got(row).startswith(String("exit 1: No candidates")))
    assert_equal(len(runner.calls), 1)


def test_install_timeout_fails() raises:
    var root = _tmp(String("timeout"))
    var rel = _release(root)
    var runner = ScriptedRunner()
    runner.expect(ScriptedStep(_install_argv(), timed_out=True))
    var row = _run(runner, rel, root + String("/scratch"), _validation())
    assert_equal(row.outcome, String(OUTCOME_VALIDATION_FAILED))
    assert_equal(_failed_got(row), String("timed out"))


def test_installer_that_cannot_start_fails_never_skips() raises:
    var root = _tmp(String("nostart"))
    var rel = _release(root)
    var runner = ScriptedRunner()  # no step: the run raises, as a missing pixi does
    var row = _run(runner, rel, root + String("/scratch"), _validation())
    assert_equal(row.outcome, String(OUTCOME_VALIDATION_FAILED))
    assert_equal(_failed_check(row), String("install"))
    assert_true(_failed_got(row).startswith(String("not started: ")))


def test_sha256_that_differs_fails_naming_the_member() raises:
    var root = _tmp(String("sha"))
    var rel = _release(root)
    var runner = ScriptedRunner()
    runner.expect(_install(rel, bad_sha=String("komira_beta")))
    var row = _run(runner, rel, root + String("/scratch"), _validation())
    assert_equal(row.outcome, String(OUTCOME_VALIDATION_FAILED))
    assert_equal(_failed_check(row), String("installed komira_beta"))
    assert_equal(len(runner.calls), 1)  # the smoke program is not run


def test_record_from_another_channel_fails() raises:
    var root = _tmp(String("channel"))
    var rel = _release(root)
    var runner = ScriptedRunner()
    runner.expect(_install(rel, other_channel=String("komira_alpha")))
    var row = _run(runner, rel, root + String("/scratch"), _validation())
    assert_equal(row.outcome, String(OUTCOME_VALIDATION_FAILED))
    assert_equal(_failed_check(row), String("installed komira_alpha"))
    assert_true(String(OTHER_CHANNEL) in _failed_got(row))


def test_member_not_installed_fails() raises:
    var root = _tmp(String("missing"))
    var rel = _release(root)
    var runner = ScriptedRunner()
    runner.expect(_install(rel, skip=String("komira_alpha")))
    var row = _run(runner, rel, root + String("/scratch"), _validation())
    assert_equal(row.outcome, String(OUTCOME_VALIDATION_FAILED))
    assert_equal(_failed_check(row), String("installed komira_alpha"))
    assert_equal(_failed_got(row), String("no record"))


def test_record_without_sha256_fails() raises:
    var root = _tmp(String("nosha"))
    var rel = _release(root)
    var runner = ScriptedRunner()
    runner.expect(_install(rel, no_sha=String("komira")))
    var row = _run(runner, rel, root + String("/scratch"), _validation())
    assert_equal(row.outcome, String(OUTCOME_VALIDATION_FAILED))
    assert_equal(_failed_check(row), String("installed komira"))
    assert_true(String("<no sha256>") in _failed_got(row))


def test_record_that_does_not_parse_fails() raises:
    var root = _tmp(String("unparsable"))
    var rel = _release(root)
    var runner = ScriptedRunner()
    var step = _install(rel)
    step.writes(String(META) + String("broken-0-0.json"), String("{not json"))
    runner.expect(step^)
    var row = _run(runner, rel, root + String("/scratch"), _validation())
    assert_equal(row.outcome, String(OUTCOME_VALIDATION_FAILED))
    assert_equal(_failed_check(row), String("conda-meta broken-0-0.json"))
    assert_equal(len(runner.calls), 1)


def test_no_environment_fails() raises:
    var root = _tmp(String("noenv"))
    var rel = _release(root)
    var runner = ScriptedRunner()
    runner.expect(ScriptedStep(_install_argv()))  # exits 0, installs nothing
    var row = _run(runner, rel, root + String("/scratch"), _validation())
    assert_equal(row.outcome, String(OUTCOME_VALIDATION_FAILED))
    assert_equal(_failed_check(row), String("installed environment"))


def test_smoke_without_its_ok_line_fails() raises:
    var root = _tmp(String("noline"))
    var rel = _release(root)
    var runner = ScriptedRunner()
    runner.expect(_install(rel))
    runner.expect(_smoke(String("example_pkg smoke: OK, nearly\n")))
    var row = _run(runner, rel, root + String("/scratch"), _validation())
    assert_equal(row.outcome, String(OUTCOME_VALIDATION_FAILED))
    assert_equal(_failed_check(row), String("smoke output"))


def test_smoke_that_exits_nonzero_fails() raises:
    var root = _tmp(String("smokeexit"))
    var rel = _release(root)
    var runner = ScriptedRunner()
    runner.expect(_install(rel))
    runner.expect(_smoke(exit_code=Int32(1)))
    var row = _run(runner, rel, root + String("/scratch"), _validation())
    assert_equal(row.outcome, String(OUTCOME_VALIDATION_FAILED))
    assert_equal(_failed_check(row), String("smoke program"))


def test_name_outside_the_set_fails_before_any_run() raises:
    var root = _tmp(String("notmember"))
    var rel = _release(root)
    var runner = ScriptedRunner()
    var row = _run(runner, rel, root + String("/scratch"), _validation(String("komira_gamma")))
    assert_equal(row.outcome, String(OUTCOME_VALIDATION_FAILED))
    assert_equal(_failed_check(row), String("install is a release member"))
    assert_equal(len(runner.calls), 0)
    assert_false(exists(root + String("/scratch/install-smoke")))


def test_used_scratch_directory_is_refused() raises:
    var root = _tmp(String("used"))
    var rel = _release(root)
    makedirs(root + String("/scratch/install-smoke"), exist_ok=True)
    write_text_file(root + String("/scratch/install-smoke/pixi.toml"), String("# an earlier run's\n"))
    var runner = ScriptedRunner()
    var row = _run(runner, rel, root + String("/scratch"), _validation())
    assert_equal(row.outcome, String(OUTCOME_VALIDATION_FAILED))
    assert_equal(_failed_got(row), String("exists and is not empty"))
    assert_equal(len(runner.calls), 0)


def test_plan_runs_nothing() raises:
    var root = _tmp(String("plan"))
    var rel = _release(root)
    var runner = ScriptedRunner()
    var row = _run(runner, rel, root + String("/scratch"), _validation(), plan=True)
    assert_equal(row.effect, String(VALIDATION_WOULD_VALIDATE))
    assert_equal(row.outcome, String(""))
    assert_equal(len(row.checks), 0)
    assert_equal(len(runner.calls), 0)
    assert_false(exists(root + String("/scratch")))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
