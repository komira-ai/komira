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
#       another build or another version, or in another shape (another
#       operator, a fourth word, no build, a tab, a leading space, the
#       name in another case, a bracket glued to the name, a channel
#       prefix, also after a non-token occurrence); a requirement whose
#       name is a glob or regex pattern; a metapackage that does not
#       require komira_native. A package whose name only starts with
#       komira_native is another package, not checked as it
#     ENV, komira_native alone: no library, so no README runs: a FAIL, never
#       a pass (and never "not a metapackage")
#     ENV, a library also requiring the conda-forge system library
#       `zstd >=1.5.2,<2`: pixi.toml lists the conda-forge extra channel and
#       names no zstd; its record from conda-forge reads back as a pass, one
#       from an undeclared channel FAILS
#     ENV refusals of the native package's link name, before anything runs:
#       none (no lib/lib<x>.so row), `<x>` in another case, `<x>` holding a
#       path separator
#     every README run (ENV) and the program run (SMOKE) links komira_native
#       from the environment: `-Xlinker -L<env>/lib -Xlinker -lkomira_native`
#       (tools/build/native/README.md), pinned argv and script text
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
    with_native,
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


def _native_link(env: String) -> List[String]:
    """What tools/build/native/README.md says a consumer of komira_native
    links, spelled out here rather than taken from kci_validate."""
    var out = List[String]()
    out.append(String("-Xlinker"))
    out.append(String("-L") + env + String("/.pixi/envs/default/lib"))
    out.append(String("-Xlinker"))
    out.append(String("-lkomira_native"))
    return out^


def _expect_readme_run(mut runner: ScriptedRunner, fx: Fixture, name: String):
    # every environment of this file holds komira_native, so every README
    # run links it (JIT symbols of libkomira_native.so.1 are not found
    # otherwise)
    runner.expect(
        ScriptedStep(
            run_program_argv(fx.work(), String("readme_") + name + String(".mojo"), _native_link(fx.work())),
            stdout_text=_count(name),
        )
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


def test_env_a_native_package_with_no_link_name_is_refused() raises:
    # lib_files holds the shared object but not lib/libkomira_native.so: a
    # README run could not link it, so nothing runs
    var fx = Fixture(
        String("nolink"), String(VALIDATION_KIND_CONDA_INSTALL_ENV), _names(String("komira_alpha")),
        String("komira_alpha"), String(NATIVE), String("lib_files"),
        String('[{"path":"lib/libkomira_native.so.1","sha256":"') + _sha(String(NATIVE)) + String('"}]'),
    )
    var runner = ScriptedRunner()
    var t = ScriptedPkgTransport()
    var row = _env(runner, t, fx)
    _assert_fails_with(
        row,
        String("native package 'komira_native' ships no lib/lib<name>.so in its lib_files: a program cannot link it"),
    )
    assert_equal(len(runner.calls), 0)
    assert_equal(t.call_count(), 0)


def _refused_link_name(sub: String, bad: String) raises:
    """komira_native's lib_files hold the shared object and a file row at
    `bad`, its only `lib/lib<x>.so` (the metadata parser accepts it: under
    lib/, bytes in [A-Za-z0-9_.+-/]; a file row, so no link target need
    resolve): refused naming it, before anything runs."""
    var fx = Fixture(
        sub, String(VALIDATION_KIND_CONDA_INSTALL_ENV), _names(String("komira_alpha")),
        String("komira_alpha"), String(NATIVE), String("lib_files"),
        String('[{"path":"') + bad + String('","sha256":"') + _sha(bad) + String('"},')
        + String('{"path":"lib/libkomira_native.so.1","sha256":"') + _sha(String(NATIVE)) + String('"}]'),
    )
    var runner = ScriptedRunner()
    var t = ScriptedPkgTransport()
    var row = _env(runner, t, fx)
    _assert_fails_with(
        row,
        String("'komira_native' ships '") + bad
        + String("', whose link name is not lowercase letters, digits and `_`: kci will not write it into a link line"),
    )
    assert_equal(len(runner.calls), 0)
    assert_equal(t.call_count(), 0)


def test_env_a_native_link_name_in_another_case_is_refused() raises:
    _refused_link_name(String("link_upper"), String("lib/libKomira.so"))


def test_env_a_native_link_name_holding_a_path_separator_is_refused() raises:
    _refused_link_name(String("link_slash"), String("lib/libsub/libx.so"))


# ---- ENV: a library requiring a system library from conda-forge ---------------


comptime CONDA_FORGE_ZSTD: String = "https://conda.anaconda.org/conda-forge/linux-64/zstd-1.5.6-ha6fb4c9_0.conda"


def _zstd_record(url: String) -> String:
    return (
        String('{"name":"zstd","version":"1.5.6","build":"ha6fb4c9_0","sha256":"')
        + String("5555555555555555555555555555555555555555555555555555555555555555")
        + String('","url":"') + url + String('"}')
    )


def _zstd_fixture(sub: String) raises -> Fixture:
    var depends = (
        String('["__linux","mojo-compiler ==1.0.0","') + String(NATIVE) + String(" ==1.0.0 ")
        + ExampleRelease().build() + String('","zstd >=1.5.2,<2"]')
    )
    return Fixture(
        sub, String(VALIDATION_KIND_CONDA_INSTALL_ENV), _names(String("komira_alpha")), String("komira_alpha"),
        String("komira_alpha"), String("depends"), depends,
    )


def test_env_a_system_library_comes_from_the_conda_forge_extra_channel() raises:
    # komira_alpha requires `zstd >=1.5.2,<2` (tools/build/package/system_libs.bzl's
    # row for libzstd.so.1): pixi.toml lists conda-forge (the machine file's
    # extra_channel) among the channels and names no zstd, so the solver
    # brings it through the library's requirement; its record, from
    # conda-forge, reads back as a pass
    var fx = _zstd_fixture(String("syslib"))
    var pins = _names(String("komira_alpha"), String(NATIVE))
    var runner = ScriptedRunner()
    var step = _env_install(fx, pins, _names(String("komira_alpha")))
    step.writes(String(ENV_META) + String("zstd.json"), _zstd_record(String(CONDA_FORGE_ZSTD)))
    runner.expect(step^)
    _expect_readme_run(runner, fx, String("komira_alpha"))
    var t = _channel(fx, pins, True)
    var row = _env(runner, t, fx)
    assert_equal(_failed(row), String(""))
    assert_equal(row.outcome, String(OUTCOME_SUCCEEDED))
    var toml = open(fx.work() + String("/pixi.toml"), "r").read()
    assert_true(toml.find(String('"conda-forge"]')) >= 0, toml)
    assert_true(toml.find(String("zstd")) < 0, toml)


def test_env_a_system_library_from_an_undeclared_channel_fails() raises:
    var fx = _zstd_fixture(String("syslib_elsewhere"))
    var pins = _names(String("komira_alpha"), String(NATIVE))
    var runner = ScriptedRunner()
    var step = _env_install(fx, pins, _names(String("komira_alpha")))
    step.writes(
        String(ENV_META) + String("zstd.json"),
        _zstd_record(String("https://conda.example.invalid/other/linux-64/zstd-1.5.6-ha6fb4c9_0.conda")),
    )
    runner.expect(step^)
    _expect_readme_run(runner, fx, String("komira_alpha"))
    var t = _channel(fx, pins, True)
    var row = _env(runner, t, fx)
    _assert_fails_with(
        row,
        String("install: zstd came from 'https://conda.example.invalid/other/linux-64/zstd-1.5.6-ha6fb4c9_0.conda'")
        + String(", which is none of the declared channels"),
    )


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


def _refused_requirement(sub: String, json_req: String, needle: String) raises:
    """komira_alpha's `depends` holds `json_req` (a JSON string body, so a
    tab is spelled `\\t`) for komira_native: refused, naming the library,
    before anything runs."""
    var depends = String('["__linux","mojo-compiler ==1.0.0","') + json_req + String('"]')
    var fx = Fixture(
        sub, String(VALIDATION_KIND_CONDA_INSTALL_ENV), _names(String("komira_alpha")), String("komira_alpha"),
        String("komira_alpha"), String("depends"), depends,
    )
    var runner = ScriptedRunner()
    var t = ScriptedPkgTransport()
    var row = _env(runner, t, fx)
    _assert_fails_with(row, String("release: library 'komira_alpha' requires ") + needle)
    assert_equal(len(runner.calls), 0)
    assert_equal(t.call_count(), 0)


def _shape(req: String) -> String:
    return (
        String("'") + req
        + String("', which is not `<native> ==<version> <build>`: kci cannot tell what it installs")
    )


def _pattern(req: String) -> String:
    return (
        String("'") + req
        + String("', whose name is a pattern (`*`, `?`, `^` or `$`): kci cannot tell what it installs")
    )


def test_env_a_native_requirement_of_another_shape_is_refused() raises:
    # each row would reach the version and build check, or pass it, if the
    # shape were not read first
    var b = ExampleRelease().build()
    var n = String(NATIVE)
    # an operator other than ==
    _refused_requirement(String("shape_ge"), n + String(" >=1.0.0 ") + b, _shape(n + String(" >=1.0.0 ") + b))
    # a fourth word
    _refused_requirement(
        String("shape_four"), n + String(" ==1.0.0 ") + b + String(" x"), _shape(n + String(" ==1.0.0 ") + b + String(" x"))
    )
    # no build: any build of 1.0.0 would do
    _refused_requirement(String("shape_nobuild"), n + String(" ==1.0.0"), _shape(n + String(" ==1.0.0")))


def test_env_a_native_requirement_with_a_tab_is_refused() raises:
    # split on single spaces, the first word would be `komira_native\t==1.0.0`
    # and the requirement taken for another package's, never checked
    var b = ExampleRelease().build()
    var n = String(NATIVE)
    _refused_requirement(
        String("shape_tab"), n + String("\\t==1.0.0 ") + b, _shape(n + String("\t==1.0.0 ") + b)
    )


def test_env_a_native_requirement_with_a_leading_space_is_refused() raises:
    # split on single spaces, the first word would be empty
    var b = ExampleRelease().build()
    var n = String(NATIVE)
    _refused_requirement(
        String("shape_lead"), String(" ") + n + String(" ==1.0.0 ") + b, _shape(String(" ") + n + String(" ==1.0.0 ") + b)
    )


def test_env_a_native_requirement_in_another_case_is_refused() raises:
    # the solver lowercases a package name before matching it (CEP 29), so
    # `KOMIRA_NATIVE` brings komira_native: never taken for another package
    var b = ExampleRelease().build()
    _refused_requirement(
        String("case_upper"), String("KOMIRA_NATIVE ==1.0.0 ") + b, _shape(String("KOMIRA_NATIVE ==1.0.0 ") + b)
    )
    _refused_requirement(
        String("case_mixed"), String("Komira_Native ==1.0.0 ") + b, _shape(String("Komira_Native ==1.0.0 ") + b)
    )


def test_env_a_native_requirement_with_bytes_glued_to_the_name_is_refused() raises:
    # a MatchSpec bracket after the name: the version and build words would
    # pass, so only the first word being the bare name refuses it
    var b = ExampleRelease().build()
    var n = String(NATIVE)
    _refused_requirement(
        String("glued_bracket"), n + String("[build=x] ==1.0.0 ") + b, _shape(n + String("[build=x] ==1.0.0 ") + b)
    )


def test_env_a_native_requirement_behind_a_channel_prefix_is_refused() raises:
    # MatchSpec's `<channel>::<name>`: the solver reads komira_native, so a
    # name read up to the first `:` would take the requirement for `chan`'s
    var b = ExampleRelease().build()
    var n = String(NATIVE)
    _refused_requirement(
        String("chan_prefix"), String("chan::") + n + String(" ==1.0.0 ") + b,
        _shape(String("chan::") + n + String(" ==1.0.0 ") + b),
    )
    _refused_requirement(
        String("chan_subdir_prefix"), String("conda-forge/linux-64::") + n + String(" ==1.0.0 ") + b,
        _shape(String("conda-forge/linux-64::") + n + String(" ==1.0.0 ") + b),
    )
    # a non-token occurrence first: every occurrence is read, not the first
    _refused_requirement(
        String("chan_nontoken_first"), n + String("_x::") + n + String(" ==1.0.0 ") + b,
        _shape(n + String("_x::") + n + String(" ==1.0.0 ") + b),
    )


def test_env_a_requirement_whose_name_is_a_pattern_is_refused() raises:
    # a glob or regex name holds no token of komira_native, yet a solver
    # matching names by pattern could bring it: kci cannot tell what it
    # installs, so any pattern name is refused
    var b = ExampleRelease().build()
    _refused_requirement(
        String("pattern_glob"), String("komira_nativ* ==1.0.0 ") + b,
        _pattern(String("komira_nativ* ==1.0.0 ") + b),
    )
    _refused_requirement(
        String("pattern_regex"), String("^komira_nat.*$ ==1.0.0 ") + b,
        _pattern(String("^komira_nat.*$ ==1.0.0 ") + b),
    )
    # the first word is found past leading whitespace, and runs through a
    # `<channel>::` prefix to the next space
    _refused_requirement(
        String("pattern_lead"), String(" komira_nativ* ==1.0.0 ") + b,
        _pattern(String(" komira_nativ* ==1.0.0 ") + b),
    )
    _refused_requirement(
        String("pattern_tab"), String("\\tkomira_nativ* ==1.0.0 ") + b,
        _pattern(String("\tkomira_nativ* ==1.0.0 ") + b),
    )
    _refused_requirement(
        String("pattern_chan"), String("chan::komira_nativ* ==1.0.0 ") + b,
        _pattern(String("chan::komira_nativ* ==1.0.0 ") + b),
    )


def test_env_another_package_named_like_the_native_one_is_not_checked_as_it() raises:
    # `komira_native_extra` is another package: the name is a token only
    # between bytes no package name holds, so this library still validates
    var b = ExampleRelease().build()
    var depends = (
        String('["__linux","mojo-compiler ==1.0.0","') + String(NATIVE) + String(" ==1.0.0 ") + b
        + String('","komira_native_extra >=2"]')
    )
    var fx = Fixture(
        String("extraname"), String(VALIDATION_KIND_CONDA_INSTALL_ENV), _names(String("komira_alpha")),
        String("komira_alpha"), String("komira_alpha"), String("depends"), depends,
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


def test_env_a_native_requirement_at_another_version_is_refused() raises:
    var b = ExampleRelease().build()
    var n = String(NATIVE)
    _refused_requirement(
        String("otherversion"), n + String(" ==1.0.1 ") + b,
        n + String(" 1.0.1 ") + b + String(", but the release has ") + n + String(" 1.0.0 ") + b,
    )


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
    var pins = with_native(rel.loaded, install_pins(rel.loaded, fx.req.validation.installs))
    var script = container_script(pins)
    # the program run links komira_native from the environment
    assert_true(
        script.find(
            String(" --frozen mojo run -Xlinker -L/work/.pixi/envs/default/lib -Xlinker -lkomira_native /work/smoke.mojo")
        )
        >= 0,
        script,
    )
    var step = ScriptedStep(run_argv(String(IMAGE), fx.work(), String(USER), script))
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
