# =============================================================================
# src/kci_validate/tests/test_native_member.mojo
#   A release set holding the native package `komira_native` (kci_publish's
#   ExampleRelease `add_native`: the package of libkomira_native.so.1, no
#   Mojo, a member of the metapackage, required by one library at the set's
#   version and build), validated by CONDA_INSTALL_ENV over a fake pixi and
#   by CONDA_INSTALL_SMOKE over a fake docker:
#     ENV, the metapackage alone: komira_native is a member like a library,
#       pinned, served by the channel and read back from the environment; it
#       has no README to run and no payload to hash
#     ENV, a library requiring komira_native: komira_native is pinned and
#       read back although pixi.toml names only the library; an environment
#       without it FAILS by name
#     ENV refusals, before anything runs: a library pinning komira_native at
#       another build; a metapackage that does not require komira_native
#     ENV, komira_native alone: no library, so no README runs: a FAIL, never
#       a pass (and never "not a metapackage")
#     SMOKE, a library requiring komira_native: pinned, served, read back,
#       not named in pixi.toml; an environment without it FAILS by name
#
# Hermetic: TEST_TMPDIR, kci_publish's ExampleRelease, no pixi, no docker,
# no network.
# =============================================================================

from std.os import getenv, makedirs
from std.os.path import exists
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_build import ScriptedRunner, ScriptedStep
from kci_api import (
    OUTCOME_SUCCEEDED,
    OUTCOME_VALIDATION_FAILED,
    VALIDATION_KIND_CONDA_INSTALL_ENV,
    VALIDATION_KIND_CONDA_INSTALL_SMOKE,
    ResultValidation,
)
from kci_pkg_upload import PkgResponse, ScriptedPkgTransport, content_identity_of
from kci_publish import NoWaitSleeper
from kci_publish.release_fixture import ExampleRelease, write_example_inputs, write_text_file
from kci_release_machine import StageValidation
from kci_validate import (
    ContainerHost,
    EnvHost,
    RecordingIndexPollLog,
    ValidateRequest,
    container_script,
    install_env_argv,
    install_pins,
    load_validated_release,
    pull_argv,
    run_argv,
    run_install_env,
    run_install_smoke,
    run_program_argv,
)

comptime NATIVE: String = "komira_native"
comptime CHANNEL: String = "https://conda.example.invalid/example/gamma"
comptime COMPILER: String = "https://conda.example.invalid/max"
comptime ENV_META: String = ".pixi/envs/default/conda-meta/"
comptime PIXI_BYTES: String = "#!/bin/false\nthe pinned pixi, played\n"
comptime IMAGE: String = (
    "registry.example.invalid/pixi:1-slim@sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
)
comptime SMOKE_PROGRAM: String = "release/smoke/smoke_example.mojo"
comptime USER: String = "1001:118"


def _tmp(sub: String) raises -> String:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/native_member/") + sub
    makedirs(d, exist_ok=True)
    return d^


def _sha(text: String) -> String:
    return content_identity_of(text.as_bytes()).sha256_hex


def _readme(name: String) -> String:
    return String("# ") + name + String("\n\n```mojo\nfrom ") + name + String(" import *\n```\n")


def _doc_files(name: String) -> String:
    return (
        String('[{"path":"share/doc/') + name + String('/README.md","sha256":"') + _sha(_readme(name))
        + String('"}]')
    )


def _count(name: String) -> String:
    return String("readme_") + name + String(" validation: 1 of 1 checks passed\n")


def _validation(kind: String, installs: List[String]) -> StageValidation:
    var v = StageValidation(7)
    v.name = String("install")
    v.kind = kind.copy()
    v.installs = installs.copy()
    v.compiler_channel = String(COMPILER)
    v.extra_channels.append(String("conda-forge"))
    v.wait_for_index_seconds = 0
    if kind == String(VALIDATION_KIND_CONDA_INSTALL_SMOKE):
        v.image = String(IMAGE)
        v.program = String(SMOKE_PROGRAM)
    return v^


def _names(a: String, b: String = String("")) -> List[String]:
    var out = List[String]()
    out.append(a.copy())
    if b.byte_length() > 0:
        out.append(b.copy())
    return out^


struct Fixture(Movable):
    """A written release holding komira_native, required by `requiring`;
    komira_alpha and komira_beta each ship a README with one example."""

    var root: String
    var release: ExampleRelease
    var req: ValidateRequest

    def __init__(
        out self, sub: String, kind: String, installs: List[String], requiring: String = String("komira_beta"),
        edit_member: String = String(""), edit_key: String = String(""), edit_raw: String = String(""),
    ) raises:
        var root = _tmp(sub)
        var release = ExampleRelease()
        release.add_native(requiring)
        release.set_meta(String("komira_alpha"), String("doc_files"), _doc_files(String("komira_alpha")))
        release.set_meta(String("komira_beta"), String("doc_files"), _doc_files(String("komira_beta")))
        if edit_member.byte_length() > 0:
            release.set_meta(edit_member.copy(), edit_key.copy(), edit_raw.copy())
        var p = write_example_inputs(release, root, String("gamma"))
        makedirs(root + String("/repo/release/smoke"), exist_ok=True)
        write_text_file(root + String("/repo/") + String(SMOKE_PROGRAM), String("def main():\n    pass\n"))
        makedirs(root + String("/tools"), exist_ok=True)
        write_text_file(root + String("/tools/pixi"), String(PIXI_BYTES))
        var req = ValidateRequest(_validation(kind, installs))
        req.stage = String("gamma")
        req.step_name = String("publish")
        req.artifacts_file = p.artifacts_file.copy()
        req.channels_file = p.channels_file.copy()
        req.channel = String("gamma")
        req.release_dir = p.release_dir.copy()
        req.platform = p.platform.copy()
        req.revision_id = p.revision_id.copy()
        req.scratch_dir = root + String("/scratch")
        req.repo_root = root + String("/repo")
        req.pixi = root + String("/tools/pixi")
        req.pixi_sha256 = _sha(String(PIXI_BYTES))
        self.root = root^
        self.release = release^
        self.req = req^

    def work(self) -> String:
        return self.req.scratch_dir + String("/install/work")

    def file(self, name: String) -> String:
        return self.release.file_name(name)

    def build(self) -> String:
        return self.release.build()

    def content(self, name: String) -> String:
        for i in range(len(self.release.members)):
            if self.release.members[i].name == name:
                return self.release.members[i].content.copy()
        return String("")

    def record(self, name: String) -> String:
        var b = self.release.build()
        return (
            String('{"name":"') + name + String('","version":"') + self.release.version + String('","build":"') + b
            + String('","sha256":"') + self.release.sha256_of(name) + String('","url":"') + String(CHANNEL)
            + String("/linux-64/") + self.file(name) + String('"}')
        )


def _resp(status: Int, body: String = String("")) -> PkgResponse:
    var r = PkgResponse(status)
    var out = List[UInt8]()
    var b = body.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    r.with_body(out^)
    return r^


def _index(fx: Fixture) -> String:
    var s = String('{"info":{"subdir":"linux-64"},"packages":{},"packages.conda":{')
    var first = True
    for name in [String("komira_alpha"), String("komira_beta"), String(NATIVE), String("komira")]:
        if not first:
            s += String(",")
        first = False
        s += String('"') + fx.file(name) + String('":{"sha256":"') + fx.release.sha256_of(name) + String('","size":1}')
    return s + String("}}")


def _channel(fx: Fixture, served: List[String], network: Bool) -> ScriptedPkgTransport:
    """The declared hosts answering (ENV only), the index, then the bytes of
    each pin in `served`, in pin order."""
    var t = ScriptedPkgTransport()
    if network:
        t.queue(_resp(200))
        t.queue(_resp(404))
    t.queue(_resp(200, _index(fx)))
    for i in range(len(served)):
        t.queue(_resp(200, fx.content(served[i])))
    return t^


def _compiler_record() -> String:
    return (
        String('{"name":"mojo-compiler","version":"1.0.0","build":"release","sha256":"')
        + String("4444444444444444444444444444444444444444444444444444444444444444")
        + String('","url":"') + String(COMPILER) + String('/linux-64/mojo-compiler-1.0.0-release.conda"}')
    )


def _env_install(fx: Fixture, records: List[String], libraries: List[String]) -> ScriptedStep:
    """The played `pixi install`: a record of each name of `records` and the
    compiler; each name of `libraries` its README and payload."""
    var step = ScriptedStep(install_env_argv(fx.work()), stderr_text=String("installed\n"))
    for i in range(len(records)):
        step.writes(String(ENV_META) + records[i] + String(".json"), fx.record(records[i]))
    step.writes(String(ENV_META) + String("mojo-compiler.json"), _compiler_record())
    for i in range(len(libraries)):
        ref n = libraries[i]
        step.writes(String(".pixi/envs/default/share/doc/") + n + String("/README.md"), _readme(n))
        step.writes(String(".pixi/envs/default/lib/mojo/") + n + String(".mojoc"), n.copy())
    return step^


def _expect_readme_run(mut runner: ScriptedRunner, fx: Fixture, name: String):
    runner.expect(
        ScriptedStep(run_program_argv(fx.work(), String("readme_") + name + String(".mojo")), stdout_text=_count(name))
    )


def _env(mut runner: ScriptedRunner, mut t: ScriptedPkgTransport, fx: Fixture) raises -> ResultValidation:
    var sl = NoWaitSleeper()
    var log = RecordingIndexPollLog()
    return run_install_env(runner, t, sl, log, fx.req, EnvHost(fx.root + String("/etc_pixi")))


def _failed(row: ResultValidation) -> String:
    var s = String("")
    for i in range(len(row.checks)):
        if not row.checks[i].ok:
            if s.byte_length() > 0:
                s += String("|")
            s += row.checks[i].check + String(": ") + row.checks[i].got
    return s^


def _assert_fails_with(row: ResultValidation, needle: String) raises:
    assert_equal(row.outcome, String(OUTCOME_VALIDATION_FAILED))
    assert_true(_failed(row).find(needle) >= 0, String("no failed row holds '") + needle + String("': ") + _failed(row))


def _release_row(fx: Fixture, pins: List[String]) -> String:
    var s = String("release: ")
    for i in range(len(pins)):
        if i > 0:
            s += String(", ")
        s += fx.file(pins[i])
    return s + String(" with mojo-compiler 1.0.0")


# ---- ENV: the metapackage alone -------------------------------------------------


def test_env_the_metapackage_brings_the_native_package_as_a_member() raises:
    var fx = Fixture(String("meta"), String(VALIDATION_KIND_CONDA_INSTALL_ENV), _names(String("komira")))
    var pins = List[String]()
    for n in [String("komira"), String("komira_alpha"), String("komira_beta"), String(NATIVE)]:
        pins.append(n.copy())
    var runner = ScriptedRunner()
    runner.expect(_env_install(fx, pins, _names(String("komira_alpha"), String("komira_beta"))))
    _expect_readme_run(runner, fx, String("komira_alpha"))
    _expect_readme_run(runner, fx, String("komira_beta"))
    var t = _channel(fx, pins, True)
    var row = _env(runner, t, fx)
    assert_equal(_failed(row), String(""))
    assert_equal(row.outcome, String(OUTCOME_SUCCEEDED))
    # komira_native is pinned like every member, its file served and read
    assert_equal(row.checks[0].got, _release_row(fx, pins))
    assert_equal(runner.remaining(), 0)
    assert_equal(t.unconsumed(), 0)
    # pixi.toml names the metapackage only
    var toml = open(fx.work() + String("/pixi.toml"), "r").read()
    assert_true(toml.find(String(NATIVE) + String(" =")) < 0, toml)
    # no README of komira_native, no payload: it holds no Mojo
    assert_false(exists(fx.work() + String("/out/payload.komira_native")))
    assert_false(exists(fx.work() + String("/readme_komira_native.mojo")))
    var payload_rows = 0
    for i in range(len(row.checks)):
        if row.checks[i].check == String("payload"):
            payload_rows += 1
            assert_true(row.checks[i].got.find(String(NATIVE)) < 0, row.checks[i].got)
    assert_equal(payload_rows, 2)


# ---- ENV: a library requiring komira_native -----------------------------------


def test_env_a_library_requiring_the_native_package_installs_it_alongside() raises:
    var fx = Fixture(
        String("lib"), String(VALIDATION_KIND_CONDA_INSTALL_ENV), _names(String("komira_alpha")), String("komira_alpha")
    )
    var pins = _names(String("komira_alpha"), String(NATIVE))
    var runner = ScriptedRunner()
    runner.expect(_env_install(fx, pins, _names(String("komira_alpha"))))
    _expect_readme_run(runner, fx, String("komira_alpha"))
    var t = _channel(fx, pins, True)
    var row = _env(runner, t, fx)
    assert_equal(_failed(row), String(""))
    assert_equal(row.outcome, String(OUTCOME_SUCCEEDED))
    assert_equal(row.checks[0].got, _release_row(fx, pins))
    assert_equal(t.unconsumed(), 0)
    var toml = open(fx.work() + String("/pixi.toml"), "r").read()
    assert_true(toml.find(String("komira_alpha = { version = \"==1.0.0\", build = \"") + fx.build()) >= 0, toml)
    assert_true(toml.find(String(NATIVE) + String(" =")) < 0, toml)


def test_env_an_environment_without_the_required_native_package_fails() raises:
    var fx = Fixture(
        String("libnonative"), String(VALIDATION_KIND_CONDA_INSTALL_ENV), _names(String("komira_alpha")),
        String("komira_alpha"),
    )
    var runner = ScriptedRunner()
    # the solver left komira_native out: only the library's record
    runner.expect(_env_install(fx, _names(String("komira_alpha")), _names(String("komira_alpha"))))
    _expect_readme_run(runner, fx, String("komira_alpha"))
    var t = _channel(fx, _names(String("komira_alpha"), String(NATIVE)), True)
    var row = _env(runner, t, fx)
    _assert_fails_with(row, String("install: the environment holds no record of komira_native"))


# ---- ENV: refused before anything runs ----------------------------------------------


def test_env_a_library_pinning_another_native_build_is_refused() raises:
    var probe = ExampleRelease()
    var other = String("h") + String(probe.commit[byte=0:8]) + String("_2")
    var depends = (
        String('["__linux","mojo-compiler ==1.0.0","') + String(NATIVE) + String(" ==1.0.0 ") + other + String('"]')
    )
    var fx = Fixture(
        String("libotherbuild"), String(VALIDATION_KIND_CONDA_INSTALL_ENV), _names(String("komira_alpha")),
        String("komira_alpha"), String("komira_alpha"), String("depends"), depends,
    )
    var runner = ScriptedRunner()
    var t = ScriptedPkgTransport()
    var row = _env(runner, t, fx)
    _assert_fails_with(
        row,
        String("release: library 'komira_alpha' requires komira_native 1.0.0 ") + other
        + String(", but the release has komira_native 1.0.0 ") + probe.build(),
    )
    assert_equal(len(runner.calls), 0)
    assert_equal(t.call_count(), 0)


def test_env_a_metapackage_not_requiring_the_native_package_is_refused() raises:
    var probe = ExampleRelease()
    var depends = (
        String('["__linux","komira_alpha ==1.0.0 ') + probe.build() + String('","komira_beta ==1.0.0 ') + probe.build()
        + String('"]')
    )
    var fx = Fixture(
        String("metaomits"), String(VALIDATION_KIND_CONDA_INSTALL_ENV), _names(String("komira")), String("komira_beta"),
        String("komira"), String("depends"), depends,
    )
    var runner = ScriptedRunner()
    var t = ScriptedPkgTransport()
    var row = _env(runner, t, fx)
    _assert_fails_with(
        row,
        String("release: native package 'komira_native' of the release set is not required by metapackage 'komira'"),
    )
    assert_equal(len(runner.calls), 0)


def test_env_the_native_package_alone_runs_no_readme_so_it_fails() raises:
    var fx = Fixture(String("nativealone"), String(VALIDATION_KIND_CONDA_INSTALL_ENV), _names(String(NATIVE)))
    var runner = ScriptedRunner()
    runner.expect(_env_install(fx, _names(String(NATIVE)), List[String]()))
    var t = _channel(fx, _names(String(NATIVE)), True)
    var row = _env(runner, t, fx)
    # pinned and read back (not taken for a metapackage), then refused: no
    # library among the installs, so nothing would run
    assert_equal(row.checks[0].got, _release_row(fx, _names(String(NATIVE))))
    _assert_fails_with(
        row, String("readme: no library among the installs (") + fx.file(String(NATIVE)) + String(")")
    )
    assert_equal(runner.remaining(), 0)


# ---- SMOKE: a library requiring komira_native ------------------------------------


def _smoke_container(mut runner: ScriptedRunner, fx: Fixture, records: List[String]) raises:
    runner.expect(ScriptedStep(pull_argv(String(IMAGE))))
    var rel = load_validated_release(fx.req)
    var pins = install_pins(rel.loaded, fx.req.validation.installs)
    var step = ScriptedStep(run_argv(String(IMAGE), fx.work(), String(USER), container_script(pins)))
    step.writes(String("work/out/install.exit"), String("0\n"))
    step.writes(String("work/out/install.log"), String("installed\n"))
    step.writes(
        String("work/out/payload.komira_alpha"),
        _sha(String("komira_alpha")) + String("  /work/.pixi/envs/default/lib/mojo/komira_alpha.mojoc\n"),
    )
    step.writes(String("work/out/smoke.exit"), String("0\n"))
    step.writes(String("work/out/smoke.out"), String("example validation: 3 of 3 checks passed\n"))
    step.writes(String("work/out/smoke.err"), String(""))
    for i in range(len(records)):
        step.writes(String("work/") + String(ENV_META) + records[i] + String(".json"), fx.record(records[i]))
    step.writes(String("work/") + String(ENV_META) + String("mojo-compiler.json"), _compiler_record())
    runner.expect(step^)


def _smoke(mut runner: ScriptedRunner, mut t: ScriptedPkgTransport, fx: Fixture) raises -> ResultValidation:
    var sl = NoWaitSleeper()
    var log = RecordingIndexPollLog()
    return run_install_smoke(runner, t, sl, log, fx.req, ContainerHost(String("docker"), String("/usr/bin:/bin"), String(USER)))


def test_smoke_a_library_requiring_the_native_package_reads_it_back() raises:
    var fx = Fixture(
        String("smoke"), String(VALIDATION_KIND_CONDA_INSTALL_SMOKE), _names(String("komira_alpha")),
        String("komira_alpha"),
    )
    var pins = _names(String("komira_alpha"), String(NATIVE))
    var runner = ScriptedRunner()
    _smoke_container(runner, fx, pins)
    var t = _channel(fx, pins, False)
    var row = _smoke(runner, t, fx)
    assert_equal(_failed(row), String(""))
    assert_equal(row.outcome, String(OUTCOME_SUCCEEDED))
    assert_equal(row.checks[0].got, _release_row(fx, pins))
    assert_equal(runner.remaining(), 0)
    assert_equal(t.unconsumed(), 0)
    # pixi.toml names the install names only: the library must bring it
    var toml = open(fx.work() + String("/pixi.toml"), "r").read()
    assert_true(toml.find(String("komira_alpha = { version = \"==1.0.0\", build = \"") + fx.build()) >= 0, toml)
    assert_true(toml.find(String(NATIVE) + String(" =")) < 0, toml)


def test_smoke_an_environment_without_the_required_native_package_fails() raises:
    var fx = Fixture(
        String("smokenonative"), String(VALIDATION_KIND_CONDA_INSTALL_SMOKE), _names(String("komira_alpha")),
        String("komira_alpha"),
    )
    var runner = ScriptedRunner()
    _smoke_container(runner, fx, _names(String("komira_alpha")))
    var t = _channel(fx, _names(String("komira_alpha"), String(NATIVE)), False)
    var row = _smoke(runner, t, fx)
    _assert_fails_with(row, String("install: the environment holds no record of komira_native"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
