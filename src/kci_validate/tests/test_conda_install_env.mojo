# =============================================================================
# src/kci_validate/tests/test_conda_install_env.mojo
#   A CONDA_INSTALL_ENV validation over a fake pixi (kci_build's
#   ScriptedRunner, which plays `pixi install` by writing what it would leave
#   in the scratch work dir, and `pixi run` by its output) and a scripted
#   network (kci_pkg_upload's ScriptedPkgTransport): the pass, and each way
#   it fails or cannot run:
#     the channel lists another build, or nothing of that name        FAIL
#     the channel serves other bytes                                   FAIL
#     a README example fails: the row names the README line            FAIL
#     a vacuous count (0 of 0)                                         FAIL
#     401: the host answered, so it is a FAIL, never a skip            FAIL
#     a record from an undeclared channel                              FAIL
#     no network at all: INDETERMINATE + skip_reason, nothing run
#     (an image on an ENV validation: kci_release_machine's tests)
#   and what is ENV's own: some hosts not answering is a FAIL; every child
#   runs with RunSpec.cwd = the scratch work dir, the cleared environment
#   and the pixi link; a scratch dir inside the checkout (also through a
#   link) and a system-wide pixi config are refused; the pixi pin; the
#   environment must be under the scratch dir (absent, or reached
#   through a linked .pixi/envs); the README refusals (no
#   README, other bytes, no example, no library); --plan runs nothing.
#   The SET (install the metapackage only): pixi.toml names only it, and
#   every member its own depends requires is checked and its README run; a
#   member required at another build, a metapackage requiring no member,
#   one that omits a library of the set, and a member without a README are
#   each refused by name.
#   A LOCAL channel (`file:///<dir>`, kci run --channel): its index and
#   files read from the directory (only the declared hosts over the
#   network), pixi.toml and every record's url on it, a record from the
#   published channel refused, an empty directory a FAIL, only a plain
#   absolute file:/// location accepted; the file transport's refusals.
#
# Hermetic: TEST_TMPDIR, kci_publish's ExampleRelease (komira_alpha with a
# README in its doc_files, komira_beta, the metapackage komira), no pixi, no
# network.
# =============================================================================

from std.os import getenv, makedirs, setenv, symlink
from std.os.path import exists
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_build import ProcessRunner, RunResult, RunSpec, ScriptedRunner, ScriptedStep
from kci_api import (
    OUTCOME_INDETERMINATE,
    OUTCOME_SUCCEEDED,
    OUTCOME_VALIDATION_FAILED,
    VALIDATION_KIND_CONDA_INSTALL_ENV,
    VALIDATION_VALIDATED,
    VALIDATION_WOULD_VALIDATE,
    ResultValidation,
)
from komira_http_core.codec.types import HTTP_METHOD_GET, HTTP_METHOD_PUT

from kci_pkg_upload import PkgRequest, PkgResponse, ScriptedPkgTransport, content_identity_of
from kci_publish import NoWaitSleeper
from kci_publish.release_fixture import ExampleRelease, write_example_inputs, write_text_file
from kci_release_machine import StageValidation
from kci_validate import (
    EnvHost,
    FileChannelTransport,
    RecordingIndexPollLog,
    ValidateRequest,
    install_env_argv,
    readme_program_of,
    run_install_env,
    run_program_argv,
)

comptime CHANNEL: String = "https://conda.example.invalid/example/gamma"
comptime COMPILER: String = "https://conda.example.invalid/max"
comptime META: String = ".pixi/envs/default/conda-meta/"
comptime DOC: String = ".pixi/envs/default/share/doc/komira_alpha/README.md"
comptime PROGRAM: String = "readme_komira_alpha.mojo"
comptime COUNT_OK: String = "readme_komira_alpha validation: 2 of 2 checks passed"
comptime DOC_BETA: String = ".pixi/envs/default/share/doc/komira_beta/README.md"
comptime PROGRAM_BETA: String = "readme_komira_beta.mojo"
comptime COUNT_BETA_OK: String = "readme_komira_beta validation: 1 of 1 checks passed"
comptime README_BETA: String = (
    "# komira_beta\n"
    "\n"
    "```mojo\n"
    "from std.testing import assert_equal\n"
    "from komira_beta import beta\n"
    "\n"
    "assert_equal(beta(1), 3)\n"
    "```\n"
)
comptime PIXI_BYTES: String = "#!/bin/false\nthe pinned pixi, played\n"
comptime README: String = (
    "# komira_alpha\n"
    "\n"
    "Alpha does one thing.\n"
    "\n"
    "```mojo\n"
    "from std.testing import assert_equal\n"
    "from komira_alpha import alpha\n"
    "\n"
    "assert_equal(alpha(1), 2)\n"
    "```\n"
    "\n"
    "```mojo\n"
    "assert_equal(alpha(2), 4)\n"
    "```\n"
)


def _tmp(sub: String) raises -> String:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/install_env/") + sub
    makedirs(d, exist_ok=True)
    return d^


def _sha(text: String) -> String:
    return content_identity_of(text.as_bytes()).sha256_hex


def _validation() -> StageValidation:
    var v = StageValidation(7)
    v.name = String("install-env")
    v.kind = String(VALIDATION_KIND_CONDA_INSTALL_ENV)
    # the library alone (the set is installed by the tests of the SET)
    v.installs.append(String("komira_alpha"))
    v.compiler_channel = String(COMPILER)
    v.extra_channels.append(String("conda-forge"))
    v.wait_for_index_seconds = 0
    return v^


def _doc_files(sha: String, name: String = String("komira_alpha")) -> String:
    return String('[{"path":"share/doc/') + name + String('/README.md","sha256":"') + sha + String('"}]')


struct Fixture(Movable):
    """A written release with komira_alpha's README recorded, the request
    that validates it, a played pixi, and the host's (absent) system config
    directory."""

    var root: String
    var release: ExampleRelease
    var req: ValidateRequest
    var host: EnvHost

    def __init__(
        out self, sub: String, doc_files: String = String("<readme>"), beta_doc_files: String = String(""),
        meta_depends: String = String(""),
    ) raises:
        var root = _tmp(sub)
        var release = ExampleRelease()
        var docs = doc_files.copy()
        if docs == String("<readme>"):
            docs = _doc_files(_sha(String(README)))
        if docs.byte_length() > 0:
            release.set_meta(String("komira_alpha"), String("doc_files"), docs^)
        if beta_doc_files.byte_length() > 0:
            release.set_meta(String("komira_beta"), String("doc_files"), beta_doc_files.copy())
        if meta_depends.byte_length() > 0:
            release.set_meta(String("komira"), String("depends"), meta_depends.copy())
        var p = write_example_inputs(release, root, String("gamma"))
        makedirs(root + String("/repo"), exist_ok=True)
        makedirs(root + String("/tools"), exist_ok=True)
        write_text_file(root + String("/tools/pixi"), String(PIXI_BYTES))
        var req = ValidateRequest(_validation())
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
        self.host = EnvHost(root + String("/etc_pixi"))
        self.root = root^
        self.release = release^
        self.req = req^

    def dir(self) -> String:
        return self.req.scratch_dir + String("/install-env")

    def work(self) -> String:
        return self.dir() + String("/work")

    def file(self, name: String) -> String:
        return self.release.file_name(name)

    def sha(self, name: String) -> String:
        return self.release.sha256_of(name)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _resp(status: Int, body: String = String("")) -> PkgResponse:
    var r = PkgResponse(status)
    r.with_body(_bytes(body))
    return r^


def _repodata(files: List[String], shas: List[String]) -> String:
    var s = String('{"info":{"subdir":"linux-64"},"packages":{},"packages.conda":{')
    for i in range(len(files)):
        if i > 0:
            s += String(",")
        s += String('"') + files[i] + String('":{"sha256":"') + shas[i] + String('","size":1}')
    return s + String("}}")


def _good_index(fx: Fixture) -> String:
    var files = List[String]()
    var shas = List[String]()
    for name in [String("komira_alpha"), String("komira_beta"), String("komira")]:
        files.append(fx.file(name))
        shas.append(fx.sha(name))
    return _repodata(files, shas)


def _content(fx: Fixture, name: String) -> String:
    for i in range(len(fx.release.members)):
        if fx.release.members[i].name == name:
            return fx.release.members[i].content.copy()
    return String("")


def _network_up(mut t: ScriptedPkgTransport):
    """The two declared hosts (conda.example.invalid for the channel and the
    compiler, conda.anaconda.org for conda-forge) answer."""
    t.queue(_resp(200))
    t.queue(_resp(404))


def _good_channel(fx: Fixture) -> ScriptedPkgTransport:
    var t = ScriptedPkgTransport()
    _network_up(t)
    t.queue(_resp(200, _good_index(fx)))
    t.queue(_resp(200, _content(fx, String("komira_alpha"))))
    return t^


def _record(fx: Fixture, name: String, channel: String = String(CHANNEL)) -> String:
    var b = fx.release.build()
    return (
        String('{"name":"') + name + String('","version":"') + fx.release.version + String('","build":"') + b
        + String('","sha256":"') + fx.sha(name) + String('","url":"') + channel + String("/linux-64/") + name + String("-")
        + fx.release.version + String("-") + b + String('.conda"}')
    )


def _compiler_record() -> String:
    return (
        String('{"name":"mojo-compiler","version":"1.0.0","build":"release","sha256":"')
        + String("4444444444444444444444444444444444444444444444444444444444444444")
        + String('","url":"') + String(COMPILER) + String('/linux-64/mojo-compiler-1.0.0-release.conda"}')
    )


struct Install(Copyable, Movable):
    """What the played `pixi install` leaves in the work dir."""

    var exit_code: Int32
    var records: List[String]
    var record_texts: List[String]
    var readme: String
    var payload: String
    var write_env: Bool

    def __init__(out self, fx: Fixture):
        self.exit_code = Int32(0)
        self.records = List[String]()
        self.record_texts = List[String]()
        for name in [String("komira_alpha"), String("komira_beta"), String("komira")]:
            self.records.append(name + String(".json"))
            self.record_texts.append(_record(fx, name))
        self.records.append(String("mojo-compiler.json"))
        self.record_texts.append(_compiler_record())
        self.readme = String(README)
        self.payload = String("komira_alpha")
        self.write_env = True


def _expect_install(mut runner: ScriptedRunner, fx: Fixture, i: Install):
    var step = ScriptedStep(install_env_argv(fx.work()), exit_code=i.exit_code, stderr_text=String("installed\n"))
    if i.write_env:
        for k in range(len(i.records)):
            step.writes(String(META) + i.records[k], i.record_texts[k])
        step.writes(String(DOC), i.readme.copy())
        step.writes(String(".pixi/envs/default/lib/mojo/komira_alpha.mojoc"), i.payload.copy())
    runner.expect(step^)


def _expect_run(
    mut runner: ScriptedRunner, fx: Fixture, said: String = String(COUNT_OK) + String("\n"), err: String = String(""),
    exit_code: Int32 = Int32(0),
):
    runner.expect(ScriptedStep(run_program_argv(fx.work(), String(PROGRAM)), exit_code=exit_code, stdout_text=said.copy(), stderr_text=err.copy()))


def _run(mut runner: ScriptedRunner, mut t: ScriptedPkgTransport, mut sl: NoWaitSleeper, fx: Fixture) raises -> ResultValidation:
    var log = RecordingIndexPollLog()
    return run_install_env(runner, t, sl, log, fx.req, fx.host)


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
    assert_equal(row.skip_reason, String(""))
    assert_true(_failed(row).find(needle) >= 0, String("no failed row holds '") + needle + String("': ") + _failed(row))


def _order(row: ResultValidation) -> String:
    var out = String("")
    var last = String("")
    for i in range(len(row.checks)):
        if row.checks[i].check != last:
            if out.byte_length() > 0:
                out += String(" ")
            out += row.checks[i].check
            last = row.checks[i].check.copy()
    return out^


# ---- the pass ------------------------------------------------------------------


def _pollute_parent_env():
    """Set what a CI job's process holds: tokens, conda/pixi/rattler config,
    TLS and proxy settings. A child environment holding any of them leaked."""
    for kv in [
        ("ACTIONS_ID_TOKEN_REQUEST_TOKEN", "held-by-the-job"),
        ("ACTIONS_ID_TOKEN_REQUEST_URL", "https://token.example.invalid/"),
        ("ACTIONS_RUNTIME_TOKEN", "held-by-the-job"),
        ("GITHUB_TOKEN", "held-by-the-job"),
        ("CONDA_OVERRIDE_GLIBC", "2.99"),
        ("CONDA_PREFIX", "/parent/conda"),
        ("PIXI_HOME", "/parent/pixi_home"),
        ("PIXI_CACHE_DIR", "/parent/pixi_cache"),
        ("RATTLER_AUTH_FILE", "/parent/auth.json"),
        ("SSL_CERT_FILE", "/parent/cert.pem"),
        ("HTTPS_PROXY", "http://proxy.example.invalid:3128"),
    ]:
        _ = setenv(String(kv[0]), String(kv[1]), True)


def _join_env(xs: List[String]) -> String:
    var s = String("")
    for i in range(len(xs)):
        s += String("[") + xs[i] + String("]")
    return s^


def test_pass() raises:
    # this process holds what a CI job holds; none of it may reach a child
    _pollute_parent_env()
    var fx = Fixture(String("pass"))
    var runner = ScriptedRunner()
    _expect_install(runner, fx, Install(fx))
    _expect_run(runner, fx)
    var t = _good_channel(fx)
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    assert_equal(_failed(row), String(""))
    assert_equal(row.outcome, String(OUTCOME_SUCCEEDED))
    assert_equal(row.effect, String(VALIDATION_VALIDATED))
    assert_equal(row.environment, String("ENV"))
    assert_equal(row.pixi_sha256, _sha(String(PIXI_BYTES)))
    assert_equal(row.channel_url, String(CHANNEL))
    assert_equal(row.skip_reason, String(""))
    assert_equal(_order(row), String("release network channel host scratch pixi install readme payload program"))
    assert_equal(runner.remaining(), 0)
    assert_equal(t.unconsumed(), 0)
    assert_equal(
        row.checks[len(row.checks) - 1].got,
        String("program: mojo run of an import of readme_komira_alpha ran 2 checks, all passed"),
    )
    # every request anonymous; the first two ask the declared hosts once
    assert_equal(t.call(0).host, String("conda.example.invalid"))
    assert_equal(t.call(0).path, String("/"))
    assert_equal(t.call(1).host, String("conda.anaconda.org"))
    for i in range(t.call_count()):
        assert_equal(t.call(i).header_value(String("Authorization")), String(""))
    # every child: the pixi link, cwd = the work dir, the cleared environment
    assert_equal(len(runner.calls), 2)
    for c in range(len(runner.calls)):
        assert_equal(runner.calls[c].path, fx.dir() + String("/bin/pixi"))
        assert_equal(runner.calls[c].cwd, fx.work())
        assert_true(Bool(runner.calls[c].env))
        ref got = runner.calls[c].env.value()
        # a LITERAL list: env_child_env runs in this polluted process, so
        # comparing against it would carry a leak onto both sides
        var want = List[String]()
        want.append(String("PATH=") + fx.dir() + String("/bin:/usr/bin:/bin"))
        want.append(String("HOME=") + fx.work() + String("/home"))
        want.append(String("PIXI_HOME=") + fx.work() + String("/pixi_home"))
        want.append(String("PIXI_CACHE_DIR=") + fx.work() + String("/cache"))
        want.append(String("TMPDIR=") + fx.work() + String("/tmp"))
        want.append(String("LANG=C.UTF-8"))
        assert_equal(_join_env(got), _join_env(want))
    # what kci wrote: the manifest pins the build, the auth file, the program
    var toml = open(fx.work() + String("/pixi.toml"), "r").read()
    assert_true(toml.find(String("komira_alpha = { version = \"==1.0.0\", build = \"") + fx.release.build()) >= 0, toml)
    assert_equal(open(fx.work() + String("/auth.json"), "r").read(), String("{}"))
    var program = open(fx.work() + String("/") + String(PROGRAM), "r").read()
    assert_true(program.find(String("src/komira_alpha/README.md")) >= 0, program)
    assert_false(exists(fx.work() + String("/komira_alpha.mojo")))
    # the records readback reads
    assert_equal(open(fx.work() + String("/out/install.exit"), "r").read(), String("0\n"))
    assert_equal(open(fx.work() + String("/out/readme_komira_alpha.exit"), "r").read(), String("0\n"))
    assert_true(open(fx.work() + String("/out/payload.komira_alpha"), "r").read().startswith(_sha(String("komira_alpha"))))


# ---- the network --------------------------------------------------------------------


def test_no_network_is_indeterminate_with_a_skip_reason() raises:
    var fx = Fixture(String("case8"))
    var runner = ScriptedRunner()
    var t = ScriptedPkgTransport()
    t.queue_fault(String("dns error: failed to lookup address information"))
    t.queue_fault(String("connect: network is unreachable"))
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    assert_equal(row.outcome, String(OUTCOME_INDETERMINATE))
    assert_true(row.outcome != String(OUTCOME_SUCCEEDED))
    assert_true(row.skip_reason.startswith(String("no network: none of the declared hosts answered")), row.skip_reason)
    assert_true(row.skip_reason.find(String("conda.example.invalid did not answer (dns error")) >= 0, row.skip_reason)
    assert_true(row.skip_reason.find(String("conda.anaconda.org did not answer (connect")) >= 0, row.skip_reason)
    assert_equal(_order(row), String("release network"))
    assert_false(row.checks[1].ok)
    # nothing else ran: no channel read, no wait, no directory, no pixi
    assert_equal(t.call_count(), 2)
    assert_equal(sl.waits, 0)
    assert_equal(len(runner.calls), 0)
    assert_false(exists(fx.dir()))


def test_some_hosts_not_answering_is_a_fail() raises:
    var fx = Fixture(String("halfnet"))
    var runner = ScriptedRunner()
    var t = ScriptedPkgTransport()
    t.queue(_resp(200))
    t.queue_fault(String("connect: connection refused"))
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(row, String("network: the network is up but a declared host did not answer"))
    assert_equal(len(runner.calls), 0)


def test_a_401_is_an_answer_so_a_fail_never_a_skip() raises:
    var fx = Fixture(String("case5"))
    var runner = ScriptedRunner()
    var t = ScriptedPkgTransport()
    t.queue(_resp(401))
    t.queue(_resp(401))
    t.queue(_resp(401))
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(row, String("answered 401: the channel is not readable anonymously"))
    assert_true(row.checks[1].ok, row.checks[1].got)
    assert_equal(row.checks[1].got, String("network: conda.example.invalid answered 401; conda.anaconda.org answered 401"))
    assert_equal(len(runner.calls), 0)


# ---- 1 channel ----------------------------------------------------------------------


def test_another_build_listed_fails_closed() raises:
    var fx = Fixture(String("case1"))
    var runner = ScriptedRunner()
    var t = ScriptedPkgTransport()
    _network_up(t)
    var files = List[String]()
    var shas = List[String]()
    files.append(String("komira_alpha-1.0.0-hdeadbeef_999.conda"))
    shas.append(fx.sha(String("komira_alpha")))
    t.queue(_resp(200, _repodata(files, shas)))
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(
        row,
        String("channel: the index does not list ") + fx.file(String("komira_alpha"))
        + String(" (it lists of that name: komira_alpha-1.0.0-hdeadbeef_999.conda)"),
    )
    assert_equal(len(runner.calls), 0)


def test_a_build_the_channel_never_had() raises:
    var fx = Fixture(String("case6"))
    var runner = ScriptedRunner()
    var t = ScriptedPkgTransport()
    _network_up(t)
    t.queue(_resp(200, _repodata(List[String](), List[String]())))
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(row, String("(it lists of that name: nothing)"))
    assert_equal(len(runner.calls), 0)


def test_other_bytes_served() raises:
    var fx = Fixture(String("case2"))
    var runner = ScriptedRunner()
    var t = ScriptedPkgTransport()
    _network_up(t)
    t.queue(_resp(200, _good_index(fx)))
    t.queue(_resp(200, String("not the build's bytes")))
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(row, String("channel: the channel serves ") + fx.file(String("komira_alpha")) + String(" with sha256 "))
    assert_equal(len(runner.calls), 0)


# ---- this machine ---------------------------------------------------------------


def test_a_system_wide_pixi_config_is_refused_by_name() raises:
    var fx = Fixture(String("sysconf"))
    makedirs(fx.host.system_config_dir, exist_ok=True)
    write_text_file(fx.host.system_config_dir + String("/config.toml"), String("[mirrors]\n"))
    var runner = ScriptedRunner()
    var t = _good_channel(fx)
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(row, String("kci will not install under ") + fx.host.system_config_dir + String("/config.toml"))
    assert_equal(len(runner.calls), 0)
    assert_false(exists(fx.dir()))


def test_a_scratch_dir_inside_the_checkout_is_refused() raises:
    var fx = Fixture(String("incheckout"))
    fx.req.scratch_dir = fx.req.repo_root + String("/buck-out/v")
    var runner = ScriptedRunner()
    var t = _good_channel(fx)
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(row, String("' is inside the checkout "))
    assert_equal(len(runner.calls), 0)
    assert_false(exists(fx.req.scratch_dir))


def test_a_scratch_dir_reaching_the_checkout_through_a_link_is_refused() raises:
    var fx = Fixture(String("linked"))
    symlink(fx.req.repo_root, fx.root + String("/to_repo"))
    fx.req.scratch_dir = fx.root + String("/to_repo/s")
    var runner = ScriptedRunner()
    var t = _good_channel(fx)
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(row, String("' is inside the checkout "))
    assert_equal(len(runner.calls), 0)


def test_a_used_scratch_dir_is_refused() raises:
    var fx = Fixture(String("used"))
    makedirs(fx.dir(), exist_ok=True)
    write_text_file(fx.dir() + String("/left"), String("x"))
    var runner = ScriptedRunner()
    var t = _good_channel(fx)
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(row, String("exists and is not empty"))
    assert_equal(len(runner.calls), 0)


def test_a_pixi_that_is_not_the_pin_never_runs() raises:
    var fx = Fixture(String("pin"))
    write_text_file(fx.req.pixi, String("another pixi\n"))
    var runner = ScriptedRunner()
    var t = _good_channel(fx)
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(row, String(", not the pin ") + _sha(String(PIXI_BYTES)))
    assert_equal(row.pixi_sha256, _sha(String("another pixi\n")))
    assert_equal(len(runner.calls), 0)


# ---- 2 install ------------------------------------------------------------------------


def test_a_failed_install_reads_nothing_else() raises:
    var fx = Fixture(String("installfail"))
    var runner = ScriptedRunner()
    var i = Install(fx)
    i.exit_code = Int32(1)
    i.write_env = False
    _expect_install(runner, fx, i)
    var t = _good_channel(fx)
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(row, String("install: pixi could not resolve the pinned packages from the channels: installed"))
    assert_equal(runner.remaining(), 0)


def test_an_environment_outside_the_work_dir_is_refused() raises:
    var fx = Fixture(String("envaway"))
    var runner = ScriptedRunner()
    var i = Install(fx)
    i.write_env = False
    _expect_install(runner, fx, i)
    var t = _good_channel(fx)
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(row, String("install: the environment is not ") + fx.work() + String("/.pixi/envs/default itself"))
    assert_equal(runner.remaining(), 0)


struct _EnvsLinkedAway(ProcessRunner):
    """Plays a system `detached-environments`: after the scripted install,
    `<w>/.pixi/envs` is a symlink to a directory outside `<w>`, as pixi
    leaves it. Every run is otherwise the ScriptedRunner's.

    Layout: owned values only. No pointer field."""

    var inner: ScriptedRunner
    var away: String
    var linked: Bool

    def __init__(out self, var inner: ScriptedRunner, var away: String):
        self.inner = inner^
        self.away = away^
        self.linked = False

    def run(mut self, spec: RunSpec) raises -> RunResult:
        var r = self.inner.run(spec)
        if not self.linked:
            self.linked = True
            makedirs(spec.cwd + String("/.pixi"), exist_ok=True)
            symlink(self.away, spec.cwd + String("/.pixi/envs"))
        return r^


def test_an_environment_reached_through_a_linked_envs_dir_is_refused() raises:
    # A complete, valid environment, but in a directory outside <w> that
    # <w>/.pixi/envs links to: read-back would follow the link, so it is
    # refused before anything is read.
    var fx = Fixture(String("envlinked"))
    var away = fx.root + String("/detached")
    var i = Install(fx)
    var step = ScriptedStep(install_env_argv(fx.work()), stderr_text=String("installed\n"))
    for k in range(len(i.records)):
        step.writes(away + String("/default/conda-meta/") + i.records[k], i.record_texts[k])
    step.writes(away + String("/default/share/doc/komira_alpha/README.md"), i.readme.copy())
    step.writes(away + String("/default/lib/mojo/komira_alpha.mojoc"), i.payload.copy())
    var scripted = ScriptedRunner()
    scripted.expect(step^)
    _expect_run(scripted, fx)
    var runner = _EnvsLinkedAway(scripted^, away.copy())
    var t = _good_channel(fx)
    var sl = NoWaitSleeper()
    var log = RecordingIndexPollLog()
    var row = run_install_env(runner, t, sl, log, fx.req, fx.host)
    assert_true(runner.linked)
    _assert_fails_with(row, String("install: the environment is not ") + fx.work() + String("/.pixi/envs/default itself"))
    assert_equal(len(runner.inner.calls), 1)
    assert_false(exists(fx.work() + String("/out/payload.komira_alpha")))

def test_a_record_from_an_undeclared_channel() raises:
    var fx = Fixture(String("case7"))
    var runner = ScriptedRunner()
    var i = Install(fx)
    i.record_texts[0] = _record(fx, String("komira_alpha"), String("https://conda.anaconda.org/conda-forge"))
    _expect_install(runner, fx, i)
    _expect_run(runner, fx)
    var t = _good_channel(fx)
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(
        row,
        String("install: komira_alpha came from 'https://conda.anaconda.org/conda-forge/linux-64/") + fx.file(String("komira_alpha"))
        + String("', not from ") + String(CHANNEL),
    )


# ---- the README ----------------------------------------------------------------------


def test_a_library_without_a_readme_is_refused_by_name() raises:
    var fx = Fixture(String("noreadme"), String(""))
    var runner = ScriptedRunner()
    _expect_install(runner, fx, Install(fx))
    var t = _good_channel(fx)
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(
        row,
        String("readme: komira_alpha ships no share/doc/komira_alpha/README.md: a release needs a README;")
        + String(" add src/komira_alpha/README.md"),
    )
    # no program runs
    assert_equal(runner.remaining(), 0)


def test_an_installed_readme_with_other_bytes_is_refused() raises:
    var fx = Fixture(String("readmesha"))
    var runner = ScriptedRunner()
    var i = Install(fx)
    i.readme = String(README).replace(String("alpha(2), 4"), String("alpha(2), 5"))
    _expect_install(runner, fx, i)
    var t = _good_channel(fx)
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(
        row,
        String("readme: the installed share/doc/komira_alpha/README.md has sha256 ") + _sha(i.readme)
        + String(", its metadata.json doc_files records ") + _sha(String(README)),
    )
    assert_equal(runner.remaining(), 0)


def test_a_readme_without_an_example_is_refused() raises:
    var empty = String("# komira_alpha\n\nNo example yet.\n")
    var fx = Fixture(String("noexample"), _doc_files(_sha(empty)))
    var runner = ScriptedRunner()
    var i = Install(fx)
    i.readme = empty^
    _expect_install(runner, fx, i)
    var t = _good_channel(fx)
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(row, String("readme: src/komira_alpha/README.md holds no ```mojo example, so the validation would run nothing"))
    assert_equal(runner.remaining(), 0)


# ---- the SET: the metapackage alone ---------------------------------------------------


def _set_fixture(sub: String, beta_readme: Bool = True, meta_depends: String = String("")) raises -> Fixture:
    """A release whose validation installs ONLY the metapackage `komira`;
    komira_beta ships README_BETA when `beta_readme`."""
    var beta = _doc_files(_sha(String(README_BETA)), String("komira_beta")) if beta_readme else String("")
    var fx = Fixture(sub, String("<readme>"), beta, meta_depends)
    var installs = List[String]()
    installs.append(String("komira"))
    fx.req.validation.installs = installs^
    return fx^


def _set_channel(fx: Fixture) -> ScriptedPkgTransport:
    """The index, then the bytes of every pin: the metapackage, then each
    member it requires."""
    var t = ScriptedPkgTransport()
    _network_up(t)
    t.queue(_resp(200, _good_index(fx)))
    for name in [String("komira"), String("komira_alpha"), String("komira_beta")]:
        t.queue(_resp(200, _content(fx, name)))
    return t^


def _expect_set_install(mut runner: ScriptedRunner, fx: Fixture, beta_readme: Bool = True):
    var i = Install(fx)
    var step = ScriptedStep(install_env_argv(fx.work()), stderr_text=String("installed\n"))
    for k in range(len(i.records)):
        step.writes(String(META) + i.records[k], i.record_texts[k])
    step.writes(String(DOC), String(README))
    step.writes(String(".pixi/envs/default/lib/mojo/komira_alpha.mojoc"), String("komira_alpha"))
    if beta_readme:
        step.writes(String(DOC_BETA), String(README_BETA))
    step.writes(String(".pixi/envs/default/lib/mojo/komira_beta.mojoc"), String("komira_beta"))
    runner.expect(step^)


def _meta_depends(v: String, alpha_build: String, beta_build: String) -> String:
    return (
        String('["__linux","komira_alpha ==') + v + String(" ") + alpha_build + String('","komira_beta ==') + v
        + String(" ") + beta_build + String('"]')
    )


def test_the_set_installs_the_metapackage_alone_and_checks_every_member() raises:
    var fx = _set_fixture(String("set"))
    var runner = ScriptedRunner()
    _expect_set_install(runner, fx)
    _expect_run(runner, fx)
    runner.expect(
        ScriptedStep(
            run_program_argv(fx.work(), String(PROGRAM_BETA)), stdout_text=String(COUNT_BETA_OK) + String("\n")
        )
    )
    var t = _set_channel(fx)
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    assert_equal(_failed(row), String(""))
    assert_equal(row.outcome, String(OUTCOME_SUCCEEDED))
    assert_equal(runner.remaining(), 0)
    assert_equal(t.unconsumed(), 0)
    # every member is pinned, and named in the release row
    assert_equal(
        row.checks[0].got,
        String("release: ") + fx.file(String("komira")) + String(", ") + fx.file(String("komira_alpha")) + String(", ")
        + fx.file(String("komira_beta")) + String(" with mojo-compiler 1.0.0"),
    )
    # pixi.toml names the metapackage ONLY: the solver must bring each member
    var toml = open(fx.work() + String("/pixi.toml"), "r").read()
    assert_true(toml.find(String("\nkomira = { version = \"==1.0.0\", build = \"") + fx.release.build()) >= 0, toml)
    assert_true(toml.find(String("komira_alpha =")) < 0, toml)
    assert_true(toml.find(String("komira_beta =")) < 0, toml)
    # each member's payload hashed, each member's README run
    assert_true(open(fx.work() + String("/out/payload.komira_beta"), "r").read().startswith(_sha(String("komira_beta"))))
    assert_equal(open(fx.work() + String("/out/readme_komira_alpha.exit"), "r").read(), String("0\n"))
    assert_equal(open(fx.work() + String("/out/readme_komira_beta.exit"), "r").read(), String("0\n"))
    assert_equal(
        row.checks[len(row.checks) - 1].got,
        String("program: mojo run of an import of readme_komira_beta ran 1 checks, all passed"),
    )


def test_a_member_installed_at_another_build_is_refused() raises:
    # the built metapackage requires komira_beta at build _2; release.json
    # has build _3: the solver would bring a build nobody validated
    var probe = ExampleRelease()
    var other = String("h") + String(probe.commit[byte=0:8]) + String("_2")
    var fx = _set_fixture(String("setotherbuild"), True, _meta_depends(probe.version, probe.build(), other))
    var runner = ScriptedRunner()
    var t = ScriptedPkgTransport()
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(
        row,
        String("release: metapackage 'komira' requires komira_beta 1.0.0 ") + other
        + String(", but the release has komira_beta 1.0.0 ") + probe.build(),
    )
    assert_equal(len(runner.calls), 0)
    assert_equal(t.call_count(), 0)


def test_a_metapackage_requiring_no_member_is_refused() raises:
    var fx = _set_fixture(String("setempty"), True, String('["__linux"]'))
    var runner = ScriptedRunner()
    var t = ScriptedPkgTransport()
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(row, String("release: metapackage 'komira' requires no member, so installing it would check nothing"))
    assert_equal(len(runner.calls), 0)


def test_a_library_the_metapackage_does_not_require_is_refused() raises:
    var probe = ExampleRelease()
    var only_alpha = String('["__linux","komira_alpha ==1.0.0 ') + probe.build() + String('"]')
    var fx = _set_fixture(String("setomits"), True, only_alpha)
    var runner = ScriptedRunner()
    var t = ScriptedPkgTransport()
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(
        row, String("release: library 'komira_beta' of the release set is not required by metapackage 'komira'")
    )
    assert_equal(len(runner.calls), 0)


def test_a_member_without_a_readme_is_refused_by_name() raises:
    var fx = _set_fixture(String("setnoreadme"), False)
    var runner = ScriptedRunner()
    _expect_set_install(runner, fx, False)
    var t = _set_channel(fx)
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(
        row,
        String("readme: komira_beta ships no share/doc/komira_beta/README.md: a release needs a README;")
        + String(" add src/komira_beta/README.md"),
    )
    # no program runs, komira_alpha's neither
    assert_equal(runner.remaining(), 0)


# ---- 4 program ---------------------------------------------------------------------------


def test_a_failing_example_names_the_readme_line() raises:
    var fx = Fixture(String("case3"))
    var runner = ScriptedRunner()
    _expect_install(runner, fx, Install(fx))
    # the second example (fence on README line 12) fails; the assertion
    # names its program's line 13, which is README line 13 and which kci
    # rewrites to the README, as a real `mojo run` prints it
    var said = (
        String("src/komira_alpha/README.md:12: FAILED: At ") + fx.work() + String("/readme_komira_alpha_12.mojo:")
        + String("13:17: AssertionError: `left == right` comparison failed\n")
        + String("readme_komira_alpha validation: 1 of 2 checks passed\n")
    )
    _expect_run(runner, fx, said, String("played\n"), Int32(1))
    var t = _good_channel(fx)
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(
        row,
        String("program: mojo run failed: src/komira_alpha/README.md:12: FAILED: At src/komira_alpha/README.md:13:17:")
        + String(" AssertionError"),
    )
    _assert_fails_with(row, String("readme_komira_alpha validation: 1 of 2 checks passed;"))
    _assert_fails_with(
        row,
        String("(share/doc/komira_alpha/README.md is the installed copy of src/komira_alpha/README.md: the same bytes, so the same lines)"),
    )


def test_a_compile_error_is_mapped_to_the_readme_line() raises:
    var fx = Fixture(String("compile"))
    # README line 13 is `assert_equal(alpha(2), 4)`; the played compiler
    # names line 13 of the second example's program, where it was copied
    var p = readme_program_of(String(README), String("komira_alpha"), String("src/komira_alpha/README.md"))
    assert_equal(len(p.modules), 2)
    assert_equal(p.modules[1].name, String("readme_komira_alpha_12.mojo"))
    assert_equal(String(p.modules[1].text.split(String("\n"))[12]), String("    assert_equal(alpha(2), 4)"))
    var runner = ScriptedRunner()
    _expect_install(runner, fx, Install(fx))
    _expect_run(
        runner, fx, String(""),
        fx.work() + String("/readme_komira_alpha_12.mojo:13:5: error: use of unknown declaration 'alpha'\n"),
        Int32(1),
    )
    var t = _good_channel(fx)
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(row, String("src/komira_alpha/README.md:13:5: error: use of unknown declaration 'alpha'"))
    # the programs kci ran are the ones it reports against
    assert_equal(open(fx.work() + String("/") + String(PROGRAM), "r").read(), p.text)
    for m in range(len(p.modules)):
        assert_equal(open(fx.work() + String("/") + p.modules[m].name, "r").read(), p.modules[m].text)


def test_a_vacuous_count_is_a_fail() raises:
    var fx = Fixture(String("case4"))
    var runner = ScriptedRunner()
    _expect_install(runner, fx, Install(fx))
    _expect_run(runner, fx, String("readme_komira_alpha validation: 0 of 0 checks passed\n"))
    var t = _good_channel(fx)
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(row, String("program: it exited 0 but printed no complete count (got: 'readme_komira_alpha validation: 0 of 0 checks passed')"))


def test_the_payload_is_hashed_by_kci() raises:
    var fx = Fixture(String("payload"))
    var runner = ScriptedRunner()
    var i = Install(fx)
    i.payload = String("other bytes")
    _expect_install(runner, fx, i)
    _expect_run(runner, fx)
    var t = _good_channel(fx)
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(row, String("payload: the installed lib/mojo/komira_alpha.mojoc is missing or differs"))


# ---- a LOCAL channel (kci run --channel file:///<dir>) -----------------------------


def _local_channel(fx: Fixture, with_files: Bool = True) raises -> String:
    """`<root>/channel`, laid out as `komira_pack conda-index` writes it:
    linux-64/repodata.json listing the three files, and the files."""
    var dir = fx.root + String("/channel")
    makedirs(dir + String("/linux-64"), exist_ok=True)
    makedirs(dir + String("/noarch"), exist_ok=True)
    write_text_file(dir + String("/noarch/repodata.json"), String('{"packages":{},"packages.conda":{}}'))
    if with_files:
        write_text_file(dir + String("/linux-64/repodata.json"), _good_index(fx))
        for name in [String("komira_alpha"), String("komira_beta"), String("komira")]:
            write_text_file(dir + String("/linux-64/") + fx.file(name), _content(fx, name))
    return dir^


def _local_install(fx: Fixture, url: String) -> Install:
    var i = Install(fx)
    for k in range(3):
        var name = String("komira_alpha") if k == 0 else (String("komira_beta") if k == 1 else String("komira"))
        i.record_texts[k] = _record(fx, name, url)
    return i^


def test_a_local_channel_is_read_from_its_directory_and_installed_from() raises:
    var fx = Fixture(String("local"))
    var dir = _local_channel(fx)
    var url = String("file://") + dir
    # a trailing `/` is the same directory
    fx.req.channel_override = url + String("/")
    var runner = ScriptedRunner()
    _expect_install(runner, fx, _local_install(fx, url))
    _expect_run(runner, fx)
    # only the declared HOSTS are asked over the network: the channel's
    # index and file are read from the directory
    var net = ScriptedPkgTransport()
    _network_up(net)
    var t = FileChannelTransport(net^)
    var sl = NoWaitSleeper()
    var log = RecordingIndexPollLog()
    var row = run_install_env(runner, t, sl, log, fx.req, fx.host)
    assert_equal(_failed(row), String(""))
    assert_equal(row.outcome, String(OUTCOME_SUCCEEDED))
    assert_equal(row.channel_url, url)
    assert_equal(_order(row), String("release network channel host scratch pixi install readme payload program"))
    assert_equal(t.inner.call_count(), 2)
    assert_equal(t.inner.unconsumed(), 0)
    assert_equal(t.inner.call(0).host, String("conda.example.invalid"))
    assert_equal(t.inner.call(1).host, String("conda.anaconda.org"))
    # check 1 read the directory's index, and the bytes it serves
    assert_equal(log.lines[0], String("kci: channel index poll 1: ") + url + String("/linux-64/repodata.json answered 200, lists 1 of 1 pinned files; waited 0 of 0 s"))
    var served = False
    for i in range(len(row.checks)):
        if row.checks[i].got.find(fx.file(String("komira_alpha")) + String(" is listed and served")) >= 0:
            served = True
    assert_true(served, _failed(row))
    # pixi installs from the directory
    var toml = open(fx.work() + String("/pixi.toml"), "r").read()
    assert_true(toml.find(String("channel = \"") + url + String("\"")) >= 0, toml)
    assert_true(toml.find(String(CHANNEL)) < 0, toml)


def test_a_local_channel_record_from_the_published_channel_is_refused() raises:
    # the local run must install what the directory holds, never the
    # published channel's file of the same name
    var fx = Fixture(String("local_pub"))
    var dir = _local_channel(fx)
    fx.req.channel_override = String("file://") + dir
    var runner = ScriptedRunner()
    _expect_install(runner, fx, Install(fx))
    _expect_run(runner, fx)
    var net = ScriptedPkgTransport()
    _network_up(net)
    var t = FileChannelTransport(net^)
    var sl = NoWaitSleeper()
    var log = RecordingIndexPollLog()
    var row = run_install_env(runner, t, sl, log, fx.req, fx.host)
    _assert_fails_with(
        row,
        String("install: komira_alpha came from '") + String(CHANNEL) + String("/linux-64/") + fx.file(String("komira_alpha"))
        + String("', not from file://") + dir,
    )


def test_a_local_channel_without_the_index_fails_closed() raises:
    var fx = Fixture(String("local_empty"))
    var dir = _local_channel(fx, with_files=False)
    fx.req.channel_override = String("file://") + dir
    var runner = ScriptedRunner()
    var net = ScriptedPkgTransport()
    _network_up(net)
    var t = FileChannelTransport(net^)
    var sl = NoWaitSleeper()
    var log = RecordingIndexPollLog()
    var row = run_install_env(runner, t, sl, log, fx.req, fx.host)
    _assert_fails_with(row, String("channel: file://") + dir + String("/linux-64/repodata.json answered 404 at poll 1"))
    assert_equal(len(runner.calls), 0)


def test_only_a_file_channel_replaces_the_steps() raises:
    var fx = Fixture(String("local_https"))
    fx.req.channel_override = String("https://conda.example.invalid/elsewhere")
    var runner = ScriptedRunner()
    var t = ScriptedPkgTransport()
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(row, String("is not a file:/// directory: only a local channel replaces the step's"))
    assert_equal(t.call_count(), 0)
    var bads = [String("file:///"), String("file:///a/../b"), String("file:///a//b"), String("file://host/a")]
    for k in range(len(bads)):
        ref bad = bads[k]
        var fb = Fixture(String("local_bad") + String(k))
        fb.req.channel_override = bad.copy()
        var r2 = ScriptedRunner()
        var t2 = ScriptedPkgTransport()
        var row2 = _run(r2, t2, sl, fb)
        assert_equal(row2.outcome, String(OUTCOME_VALIDATION_FAILED), bad)
        assert_equal(t2.call_count(), 0)


def test_the_file_transport_reads_only_plain_absolute_paths() raises:
    var fx = Fixture(String("local_transport"))
    var dir = _local_channel(fx)
    var net = ScriptedPkgTransport()
    net.queue(_resp(204))
    var t = FileChannelTransport(net^)
    # a host goes over the network, untouched
    assert_equal(t.exchange(PkgRequest(HTTP_METHOD_GET, String("conda.example.invalid"), String("/x"))).status, 204)
    assert_equal(t.inner.call_count(), 1)
    # no host: the file, or 404
    var got = t.exchange(PkgRequest(HTTP_METHOD_GET, String(""), dir + String("/linux-64/repodata.json")))
    assert_equal(got.status, 200)
    assert_equal(len(got.body), _good_index(fx).byte_length())
    assert_equal(t.exchange(PkgRequest(HTTP_METHOD_GET, String(""), dir + String("/linux-64/absent.conda"))).status, 404)
    # never a directory, a relative path, a dot segment or another method
    for path in [dir + String("/linux-64"), String("linux-64/repodata.json"), dir + String("/linux-64/../linux-64/repodata.json")]:
        var raised = False
        try:
            _ = t.exchange(PkgRequest(HTTP_METHOD_GET, String(""), path.copy()))
        except:
            raised = True
        assert_true(raised, path)
    var put_raised = False
    try:
        _ = t.exchange(PkgRequest(HTTP_METHOD_PUT, String(""), dir + String("/linux-64/repodata.json")))
    except:
        put_raised = True
    assert_true(put_raised)
    assert_equal(t.inner.call_count(), 1)


# ---- --plan ---------------------------------------------------------------------------------


def test_plan_runs_nothing() raises:
    var fx = Fixture(String("plan"))
    fx.req.plan = True
    var runner = ScriptedRunner()
    var t = ScriptedPkgTransport()
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    assert_equal(row.effect, String(VALIDATION_WOULD_VALIDATE))
    assert_equal(row.outcome, String(""))
    assert_equal(row.environment, String(""))
    assert_equal(len(row.checks), 0)
    assert_equal(len(runner.calls), 0)
    assert_equal(t.call_count(), 0)
    assert_false(exists(fx.req.scratch_dir))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
