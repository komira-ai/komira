# =============================================================================
# src/kci_validate/tests/test_conda_install_smoke.mojo
#   A CONDA_INSTALL_SMOKE validation over a fake docker (kci_build's
#   ScriptedRunner, which plays the container by writing what it would leave
#   in the mount) and a scripted channel (kci_pkg_upload's
#   ScriptedPkgTransport): the pass, and every way it fails closed
#   (VALIDATION_FAILED, never a skip):
#     0 release   a name outside the set, another revision
#     1 channel   another build listed, other bytes listed, other bytes
#                 served, 401 at once, 404 and absence waited for then
#                 FAIL, 404 then listed passes after one wait
#     scratch     a used directory, a relative one
#     image/container  docker cannot start, a pull that fails, a run that fails
#     2 install   the install fails; a member not installed, another build,
#                 another channel, other bytes, no mojo-compiler, another
#                 compiler, a record from an undeclared channel, a record
#                 that does not parse
#     3 payload   the installed payload differs
#     4 program   a failing count (59 of 61), a vacuous count (0 of 0), no
#                 count line
#   The reads carry no Authorization header; docker gets exactly PATH, HOME
#   and DOCKER_CONFIG; --plan runs nothing and makes no directory.
#
# Hermetic: TEST_TMPDIR, kci_publish's ExampleRelease (komira_alpha,
# komira_beta, the metapackage komira) and its channels file (gamma on
# conda.example.invalid), no docker, no network.
# =============================================================================

from std.os import getenv, makedirs, setenv
from std.os.path import exists
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_build import ScriptedRunner, ScriptedStep
from kci_contract import (
    OUTCOME_SUCCEEDED,
    OUTCOME_VALIDATION_FAILED,
    VALIDATION_KIND_CONDA_INSTALL_SMOKE,
    VALIDATION_VALIDATED,
    VALIDATION_WOULD_VALIDATE,
    ResultValidation,
)
from kci_pkg_upload import PkgResponse, ScriptedPkgTransport, content_identity_of
from kci_publish import NoWaitSleeper
from kci_publish.release_fixture import ExampleRelease, write_example_inputs, write_text_file
from kci_stage_graph import StageValidation
from kci_validate import (
    ContainerHost,
    ValidateRequest,
    container_script,
    install_pins,
    load_validated_release,
    pull_argv,
    run_argv,
    run_install_smoke,
)

comptime CHANNEL: String = "https://conda.example.invalid/example/gamma"
comptime CHANNEL_PATH: String = "/example/gamma"
comptime COMPILER: String = "https://conda.example.invalid/max"
comptime IMAGE: String = (
    "registry.example.invalid/pixi:1-slim@sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
)
comptime PROGRAM: String = "release/smoke/smoke_example.mojo"
comptime COUNT_OK: String = "example validation: 61 of 61 checks passed"
comptime META: String = "work/.pixi/envs/default/conda-meta/"
comptime OUT: String = "work/out/"
comptime USER: String = "1001:118"
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


def _validation() -> StageValidation:
    var v = StageValidation(7)
    v.name = String("install")
    v.kind = String(VALIDATION_KIND_CONDA_INSTALL_SMOKE)
    v.image = String(IMAGE)
    v.installs.append(String("komira_alpha"))
    v.installs.append(String("komira"))
    v.compiler_channel = String(COMPILER)
    v.extra_channels.append(String("conda-forge"))
    v.program = String(PROGRAM)
    v.wait_for_index_seconds = 600
    return v^


struct Fixture(Movable):
    """A written release, the request that validates it, and its pieces."""

    var root: String
    var release: ExampleRelease
    var req: ValidateRequest

    def __init__(out self, sub: String) raises:
        var root = _tmp(sub)
        var release = ExampleRelease()
        var p = write_example_inputs(release, root, String("gamma"))
        write_text_file_mk(root + String("/repo/") + String(PROGRAM), String("def main():\n    pass\n"))
        var req = ValidateRequest(_validation())
        req.stage = String("gamma")
        req.step_name = String("publish")
        req.declarations_file = p.declarations_file.copy()
        req.channels_file = p.channels_file.copy()
        req.channel = String("gamma")
        req.release_dir = p.release_dir.copy()
        req.platform = p.platform.copy()
        req.revision_id = p.revision_id.copy()
        req.scratch_dir = root + String("/scratch")
        req.repo_root = root + String("/repo")
        self.root = root^
        self.release = release^
        self.req = req^

    def dir(self) -> String:
        return self.req.scratch_dir + String("/install")

    def file(self, name: String) -> String:
        return self.release.file_name(name)

    def sha(self, name: String) -> String:
        return self.release.sha256_of(name)


def _rep(c: String, n: Int) -> String:
    var s = String("")
    for _ in range(n):
        s += c
    return s^


def write_text_file_mk(path: String, text: String) raises:
    var slash = path.rfind(String("/"))
    makedirs(String(path[byte=0:slash]), exist_ok=True)
    write_text_file(path, text)


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


def _good_channel(fx: Fixture) -> ScriptedPkgTransport:
    """The index, then each install file served (pins order: komira_alpha,
    komira)."""
    var t = ScriptedPkgTransport()
    t.queue(_resp(200, _good_index(fx)))
    t.queue(_resp(200, _content(fx, String("komira_alpha"))))
    t.queue(_resp(200, _content(fx, String("komira"))))
    return t^


def _record(fx: Fixture, name: String, channel: String = String(CHANNEL), sha: String = String("<same>"), build: String = String("")) -> String:
    var s = sha.copy()
    if s == String("<same>"):
        s = fx.sha(name)
    var b = build.copy()
    if b.byte_length() == 0:
        b = fx.release.build()
    return (
        String('{"name":"') + name + String('","version":"') + fx.release.version + String('","build":"') + b
        + String('","sha256":"') + s + String('","url":"') + channel + String("/linux-64/") + name + String("-")
        + fx.release.version + String("-") + b + String('.conda"}')
    )


def _compiler_record(version: String = String("1.0.0"), channel: String = String(COMPILER)) -> String:
    return (
        String('{"name":"mojo-compiler","version":"') + version + String('","build":"release","sha256":"')
        + _rep(String("4"), 64) + String('","url":"') + channel + String("/linux-64/mojo-compiler-") + version
        + String('-release.conda"}')
    )


def _python_record(url: String = String("https://conda.anaconda.org/conda-forge/linux-64/python-3.12.0-h1_0.conda")) -> String:
    return String('{"name":"python","version":"3.12.0","build":"h1_0","sha256":"') + _rep(String("5"), 64) + String('","url":"') + url + String('"}')


def _payload(name: String) -> String:
    """What sha256sum prints for the fixture's payload of `name` (its sha256
    is the sha256 of the name's bytes)."""
    return content_identity_of(name.as_bytes()).sha256_hex + String("  /work/.pixi/envs/default/lib/mojo/") + name + String(".mojoc\n")


struct Container(Copyable, Movable):
    """What the fake container leaves in the mount."""

    var install_exit: String
    var install_log: String
    var records: List[String]
    var record_texts: List[String]
    var payload_alpha: String
    var smoke_exit: String
    var smoke_out: String
    var smoke_err: String

    def __init__(out self, fx: Fixture):
        self.install_exit = String("0\n")
        self.install_log = String("installed\n")
        self.records = List[String]()
        self.record_texts = List[String]()
        self.records.append(String("komira_alpha.json"))
        self.record_texts.append(_record(fx, String("komira_alpha")))
        self.records.append(String("komira_beta.json"))
        self.record_texts.append(_record(fx, String("komira_beta")))
        self.records.append(String("komira.json"))
        self.record_texts.append(_record(fx, String("komira")))
        self.records.append(String("mojo-compiler.json"))
        self.record_texts.append(_compiler_record())
        self.records.append(String("python.json"))
        self.record_texts.append(_python_record())
        self.payload_alpha = _payload(String("komira_alpha"))
        self.smoke_exit = String("0\n")
        self.smoke_out = String(COUNT_OK) + String("\n")
        self.smoke_err = String("")

    def set_record(mut self, file: String, var text: String):
        for i in range(len(self.records)):
            if self.records[i] == file:
                self.record_texts[i] = text^
                return
        self.records.append(file.copy())
        self.record_texts.append(text^)

    def drop_record(mut self, file: String):
        var names = List[String]()
        var texts = List[String]()
        for i in range(len(self.records)):
            if self.records[i] != file:
                names.append(self.records[i].copy())
                texts.append(self.record_texts[i].copy())
        self.records = names^
        self.record_texts = texts^


def _expect_container(mut runner: ScriptedRunner, fx: Fixture, c: Container, run_exit: Int32 = Int32(0)) raises:
    runner.expect(ScriptedStep(pull_argv(String(IMAGE))))
    var rel = load_validated_release(fx.req)
    var pins = install_pins(rel.loaded, fx.req.validation.installs)
    var step = ScriptedStep(
        run_argv(String(IMAGE), fx.dir() + String("/work"), String(USER), container_script(pins)), exit_code=run_exit
    )
    step.writes(String(OUT) + String("install.exit"), c.install_exit.copy())
    step.writes(String(OUT) + String("install.log"), c.install_log.copy())
    step.writes(String(OUT) + String("payload.komira_alpha"), c.payload_alpha.copy())
    step.writes(String(OUT) + String("smoke.exit"), c.smoke_exit.copy())
    step.writes(String(OUT) + String("smoke.out"), c.smoke_out.copy())
    step.writes(String(OUT) + String("smoke.err"), c.smoke_err.copy())
    for i in range(len(c.records)):
        step.writes(String(META) + c.records[i], c.record_texts[i])
    step.writes(String(META) + String("history"), String("==> a pixi history file, not a record <==\n"))
    runner.expect(step^)


def _host() -> ContainerHost:
    return ContainerHost(String("docker"), String(CHILD_PATH), String(USER))


def _run(mut runner: ScriptedRunner, mut t: ScriptedPkgTransport, mut sl: NoWaitSleeper, fx: Fixture) raises -> ResultValidation:
    return run_install_smoke(runner, t, sl, fx.req, _host())


def _failed(row: ResultValidation) -> String:
    """`check: got` of every failed row, `|`-joined."""
    var s = String("")
    for i in range(len(row.checks)):
        if not row.checks[i].ok:
            if s.byte_length() > 0:
                s += String("|")
            s += row.checks[i].check + String(": ") + row.checks[i].got
    return s^


def _has(row: ResultValidation, needle: String) -> Bool:
    return _failed(row).find(needle) >= 0


def _assert_fails_with(row: ResultValidation, needle: String) raises:
    assert_equal(row.outcome, String(OUTCOME_VALIDATION_FAILED))
    assert_true(_has(row, needle), String("no failed row holds '") + needle + String("': ") + _failed(row))


# ---- the pass ------------------------------------------------------------------


def test_pass() raises:
    var fx = Fixture(String("pass"))
    var runner = ScriptedRunner()
    _expect_container(runner, fx, Container(fx))
    var t = _good_channel(fx)
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    assert_equal(_failed(row), String(""))
    assert_equal(row.outcome, String(OUTCOME_SUCCEEDED))
    assert_equal(row.effect, String(VALIDATION_VALIDATED))
    assert_equal(row.name, String("install"))
    assert_equal(row.step, String("publish"))
    assert_equal(runner.remaining(), 0)
    assert_equal(t.unconsumed(), 0)
    assert_equal(sl.waits, 0)
    # the rows, in the reference's order
    var order = List[String]()
    for i in range(len(row.checks)):
        if len(order) == 0 or order[len(order) - 1] != row.checks[i].check:
            order.append(row.checks[i].check.copy())
    var want = String("release channel scratch image container install payload program")
    var got = String("")
    for i in range(len(order)):
        if i > 0:
            got += String(" ")
        got += order[i]
    assert_equal(got, want)
    assert_equal(
        row.checks[len(row.checks) - 1].got,
        String("program: mojo run of an import of example ran 61 checks, all passed"),
    )
    # the channel rows say the bytes were served
    assert_true(row.checks[1].got.startswith(String("channel: ") + fx.file(String("komira_alpha")) + String(" is listed and served")))
    # what kci wrote into the mount: the manifest and a copy of the program
    var toml = open(fx.dir() + String("/work/pixi.toml"), "r").read()
    assert_true(toml.find(String("komira_alpha = { version = \"==1.0.0\", build = \"") + fx.release.build()) >= 0, toml)
    assert_true(toml.find(String("mojo-compiler = { version = \"==1.0.0\", channel = \"") + String(COMPILER)) >= 0, toml)
    assert_equal(open(fx.dir() + String("/work/smoke.mojo"), "r").read(), String("def main():\n    pass\n"))
    # docker starts in the validation's directory; the mount is work/ only
    assert_equal(runner.calls[1].cwd, fx.dir())
    assert_equal(runner.calls[1].path, String("docker"))


def test_reads_are_anonymous_and_name_the_files() raises:
    var fx = Fixture(String("anon"))
    var runner = ScriptedRunner()
    _expect_container(runner, fx, Container(fx))
    var t = _good_channel(fx)
    var sl = NoWaitSleeper()
    _ = _run(runner, t, sl, fx)
    assert_equal(t.call_count(), 3)
    assert_equal(t.call(0).host, String("conda.example.invalid"))
    assert_equal(t.call(0).path, String(CHANNEL_PATH) + String("/linux-64/repodata.json"))
    assert_equal(t.call(1).path, String(CHANNEL_PATH) + String("/linux-64/") + fx.file(String("komira_alpha")))
    assert_equal(t.call(2).path, String(CHANNEL_PATH) + String("/linux-64/") + fx.file(String("komira")))
    for i in range(t.call_count()):
        assert_equal(t.call(i).header_value(String("Authorization")), String(""))


def test_docker_gets_exactly_path_home_and_docker_config() raises:
    setenv(String("ACTIONS_ID_TOKEN_REQUEST_TOKEN"), String("held-by-the-job"), True)
    setenv(String("ACTIONS_ID_TOKEN_REQUEST_URL"), String("https://token.example.invalid/"), True)
    var fx = Fixture(String("env"))
    var runner = ScriptedRunner()
    _expect_container(runner, fx, Container(fx))
    var t = _good_channel(fx)
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    assert_equal(row.outcome, String(OUTCOME_SUCCEEDED))
    for c in range(len(runner.calls)):
        assert_true(Bool(runner.calls[c].env))
        ref got = runner.calls[c].env.value()
        assert_equal(len(got), 3)
        assert_equal(got[0], String("PATH=") + String(CHILD_PATH))
        assert_equal(got[1], String("HOME=") + fx.dir() + String("/docker"))
        assert_equal(got[2], String("DOCKER_CONFIG=") + fx.dir() + String("/docker"))


# ---- 0 release -------------------------------------------------------------------


def test_name_outside_the_set_fails_before_any_read() raises:
    var fx = Fixture(String("notmember"))
    fx.req.validation.installs.append(String("komira_gamma"))
    var runner = ScriptedRunner()
    var t = ScriptedPkgTransport()
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(row, String("release: 'komira_gamma' is not a member of the release set (komira komira_alpha komira_beta)"))
    assert_equal(t.call_count(), 0)
    assert_equal(len(runner.calls), 0)
    assert_false(exists(fx.dir()))


def test_another_revision_fails() raises:
    var fx = Fixture(String("revision"))
    fx.req.revision_id = _rep(String("f"), 40)
    var runner = ScriptedRunner()
    var t = ScriptedPkgTransport()
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(row, String("was built from revision ") + fx.release.revision)
    assert_equal(t.call_count(), 0)


# ---- 1 channel ---------------------------------------------------------------------


def _index_only(body: String) -> ScriptedPkgTransport:
    var t = ScriptedPkgTransport()
    t.queue(_resp(200, body))
    return t^


def test_channel_serving_another_build_fails_and_installs_nothing() raises:
    var fx = Fixture(String("otherbuild"))
    fx.req.validation.wait_for_index_seconds = 0
    var files = List[String]()
    var shas = List[String]()
    files.append(String("komira_alpha-1.0.0-hdeadbeef_999.conda"))
    shas.append(_rep(String("9"), 64))
    files.append(fx.file(String("komira")))
    shas.append(fx.sha(String("komira")))
    var t = _index_only(_repodata(files, shas))
    t.queue(_resp(200, _content(fx, String("komira"))))
    var runner = ScriptedRunner()
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(
        row,
        String("channel: channel: the index does not list ") + fx.file(String("komira_alpha"))
        + String(" (it lists of that name: komira_alpha-1.0.0-hdeadbeef_999.conda)"),
    )
    assert_equal(len(runner.calls), 0)


def test_listed_with_other_bytes_fails_without_waiting() raises:
    var fx = Fixture(String("otherbytes"))
    var files = List[String]()
    var shas = List[String]()
    files.append(fx.file(String("komira_alpha")))
    shas.append(String("2953") + _rep(String("0"), 60))
    files.append(fx.file(String("komira")))
    shas.append(fx.sha(String("komira")))
    var t = _index_only(_repodata(files, shas))
    t.queue(_resp(200, _content(fx, String("komira"))))
    var runner = ScriptedRunner()
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(
        row,
        String("channel: the index lists ") + fx.file(String("komira_alpha")) + String(" with sha256 2953") + _rep(String("0"), 60)
        + String(", the build made ") + fx.sha(String("komira_alpha")),
    )
    # another sha256 is never waited for, even with a budget of 600 s
    assert_equal(sl.waits, 0)
    assert_equal(len(runner.calls), 0)


def test_served_bytes_that_differ_fail() raises:
    var fx = Fixture(String("served"))
    var t = _index_only(_good_index(fx))
    t.queue(_resp(200, String("not the build's bytes")))
    t.queue(_resp(200, _content(fx, String("komira"))))
    var runner = ScriptedRunner()
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(row, String("channel: the channel serves ") + fx.file(String("komira_alpha")) + String(" with sha256 "))
    assert_equal(len(runner.calls), 0)


def test_a_file_get_that_fails_fails() raises:
    var fx = Fixture(String("get404"))
    var t = _index_only(_good_index(fx))
    t.queue(_resp(404))
    t.queue(_resp(200, _content(fx, String("komira"))))
    var runner = ScriptedRunner()
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(row, String("channel: GET ") + fx.file(String("komira_alpha")) + String(" answered '404'"))


def test_not_readable_anonymously_fails_at_once() raises:
    var fx = Fixture(String("anon401"))
    var t = ScriptedPkgTransport()
    t.queue(_resp(401, String("Authentication required")))
    var runner = ScriptedRunner()
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(
        row,
        String("channel: ") + String(CHANNEL) + String("/linux-64/repodata.json answered 401: the channel is not")
        + String(" readable anonymously (a consumer cannot install from it)"),
    )
    assert_equal(sl.waits, 0)
    assert_equal(t.call_count(), 1)


def test_404_then_listed_passes_after_one_wait() raises:
    var fx = Fixture(String("waitok"))
    var t = ScriptedPkgTransport()
    t.queue(_resp(404))
    t.queue(_resp(200, _good_index(fx)))
    t.queue(_resp(200, _content(fx, String("komira_alpha"))))
    t.queue(_resp(200, _content(fx, String("komira"))))
    var runner = ScriptedRunner()
    _expect_container(runner, fx, Container(fx))
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    assert_equal(_failed(row), String(""))
    assert_equal(sl.waits, 1)
    assert_true(row.checks[1].expected.find(String("waited 15 of 600 s")) >= 0, row.checks[1].expected)
    assert_equal(t.unconsumed(), 0)


def test_404_until_the_budget_is_spent_fails_closed() raises:
    var fx = Fixture(String("wait404"))
    fx.req.validation.wait_for_index_seconds = 30
    var t = ScriptedPkgTransport()
    for _ in range(3):
        t.queue(_resp(404))
    var runner = ScriptedRunner()
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(
        row, String("channel: ") + String(CHANNEL) + String("/linux-64/repodata.json answered 404: no such channel, or nothing published to it")
    )
    # read at 0, 15 and 30 s
    assert_equal(t.call_count(), 3)
    assert_equal(sl.waits, 2)
    assert_equal(len(runner.calls), 0)


def test_absent_until_the_budget_is_spent_fails_closed() raises:
    var fx = Fixture(String("waitabsent"))
    fx.req.validation.wait_for_index_seconds = 20
    var files = List[String]()
    var shas = List[String]()
    files.append(fx.file(String("komira")))
    shas.append(fx.sha(String("komira")))
    var t = ScriptedPkgTransport()
    for _ in range(3):
        t.queue(_resp(200, _repodata(files, shas)))
    t.queue(_resp(200, _content(fx, String("komira"))))
    var runner = ScriptedRunner()
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(
        row, String("channel: the index does not list ") + fx.file(String("komira_alpha")) + String(" (it lists of that name: nothing)")
    )
    # read at 0, 15 and 20 s: the last wait is what is left of the budget
    assert_equal(sl.waits, 2)
    assert_equal(len(runner.calls), 0)


def test_unreachable_index_fails_after_the_wait() raises:
    var fx = Fixture(String("fault"))
    fx.req.validation.wait_for_index_seconds = 0
    var t = ScriptedPkgTransport()
    t.queue_fault(String("connection refused"))
    var runner = ScriptedRunner()
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(row, String("channel: reading the index answered 'transport fault on GET conda.example.invalid"))


# ---- scratch, image, container -------------------------------------------------------


def test_used_scratch_directory_is_refused() raises:
    var fx = Fixture(String("used"))
    write_text_file_mk(fx.dir() + String("/work/pixi.toml"), String("# an earlier run's\n"))
    var runner = ScriptedRunner()
    var t = _good_channel(fx)
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(row, String("scratch: exists and is not empty"))
    assert_equal(len(runner.calls), 0)


def test_relative_scratch_directory_is_refused() raises:
    var fx = Fixture(String("relative"))
    fx.req.scratch_dir = String("scratch")
    var runner = ScriptedRunner()
    var t = _good_channel(fx)
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(row, String("--scratch-dir 'scratch' is not an absolute path (docker mounts it)"))


def test_docker_that_cannot_start_fails_never_skips() raises:
    var fx = Fixture(String("nodocker"))
    var runner = ScriptedRunner()  # no step: the run raises, as a missing docker does
    var t = _good_channel(fx)
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(row, String("image: docker pull: not started: "))


def test_a_pull_that_fails_fails() raises:
    var fx = Fixture(String("pullfail"))
    var runner = ScriptedRunner()
    runner.expect(ScriptedStep(pull_argv(String(IMAGE)), exit_code=Int32(1), stderr_text=String("manifest unknown")))
    var t = _good_channel(fx)
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(row, String("image: docker pull: exit 1: manifest unknown"))
    assert_equal(len(runner.calls), 1)


def test_a_run_that_fails_fails() raises:
    var fx = Fixture(String("runfail"))
    var runner = ScriptedRunner()
    _expect_container(runner, fx, Container(fx), run_exit=Int32(125))
    var t = _good_channel(fx)
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    _assert_fails_with(row, String("container: docker run: exit 125"))


# ---- 2 install --------------------------------------------------------------------------


def _with(fx: Fixture, c: Container) raises -> ResultValidation:
    var runner = ScriptedRunner()
    _expect_container(runner, fx, c)
    var t = _good_channel(fx)
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    assert_equal(runner.remaining(), 0)
    return row^


def test_install_that_fails_reads_nothing_else() raises:
    var fx = Fixture(String("installfail"))
    var c = Container(fx)
    c.install_exit = String("1\n")
    c.install_log = String("a\nb\nc\nd\ne\nNo candidates were found for komira_alpha ==1.0.0\n")
    var row = _with(fx, c)
    _assert_fails_with(
        row, String("install: pixi could not resolve the pinned packages from the channels: b c d e No candidates were found")
    )
    assert_equal(row.checks[len(row.checks) - 1].check, String("install"))


def test_member_not_installed_fails() raises:
    var fx = Fixture(String("norecord"))
    var c = Container(fx)
    c.drop_record(String("komira_alpha.json"))
    _assert_fails_with(_with(fx, c), String("install: the environment holds no record of komira_alpha"))


def test_another_build_installed_fails() raises:
    var fx = Fixture(String("recbuild"))
    var c = Container(fx)
    c.set_record(String("komira.json"), _record(fx, String("komira"), build=String("h00000000_1")))
    _assert_fails_with(
        _with(fx, c),
        String("install: installed komira 1.0.0 h00000000_1, expected 1.0.0 ") + fx.release.build(),
    )


def test_install_from_another_channel_fails() raises:
    var fx = Fixture(String("recchannel"))
    var c = Container(fx)
    c.set_record(String("komira_alpha.json"), _record(fx, String("komira_alpha"), channel=String("https://conda.anaconda.org/conda-forge")))
    _assert_fails_with(
        _with(fx, c), String("install: komira_alpha came from 'https://conda.anaconda.org/conda-forge/linux-64/")
    )


def test_installed_bytes_that_differ_fail() raises:
    var fx = Fixture(String("recsha"))
    var c = Container(fx)
    c.set_record(String("komira_alpha.json"), _record(fx, String("komira_alpha"), sha=_rep(String("0"), 64)))
    _assert_fails_with(
        _with(fx, c),
        String("install: the installed package's sha256 is '") + _rep(String("0"), 64) + String("', the build made ")
        + fx.sha(String("komira_alpha")),
    )
    var fy = Fixture(String("recnosha"))
    var d = Container(fy)
    d.set_record(String("komira_alpha.json"), _record(fy, String("komira_alpha"), sha=String("")))
    _assert_fails_with(_with(fy, d), String("install: the installed package's sha256 is 'none'"))


def test_compiler_missing_or_other_fails() raises:
    var fx = Fixture(String("nocompiler"))
    var c = Container(fx)
    c.drop_record(String("mojo-compiler.json"))
    _assert_fails_with(_with(fx, c), String("install: no mojo-compiler in the environment"))
    var fy = Fixture(String("othercompiler"))
    var d = Container(fy)
    d.set_record(String("mojo-compiler.json"), _compiler_record(version=String("1.1.0")))
    _assert_fails_with(_with(fy, d), String("install: installed mojo-compiler 1.1.0, the libraries were built with 1.0.0"))
    var fz = Fixture(String("compilerchannel"))
    var e = Container(fz)
    e.set_record(String("mojo-compiler.json"), _compiler_record(channel=String("https://conda.anaconda.org/conda-forge")))
    _assert_fails_with(_with(fz, e), String("install: mojo-compiler came from 'https://conda.anaconda.org/conda-forge/"))


def test_a_record_from_an_undeclared_channel_fails() raises:
    var fx = Fixture(String("undeclared"))
    var c = Container(fx)
    c.set_record(String("python.json"), _python_record(String("https://mirror.example.invalid/conda-forge/linux-64/python-3.12.0-h1_0.conda")))
    _assert_fails_with(
        _with(fx, c),
        String("install: python came from 'https://mirror.example.invalid/conda-forge/linux-64/python-3.12.0-h1_0.conda',")
        + String(" which is none of the declared channels"),
    )


def test_a_record_that_does_not_parse_fails() raises:
    var fx = Fixture(String("unparsable"))
    var c = Container(fx)
    c.set_record(String("broken-0-0.json"), String("{not json"))
    _assert_fails_with(_with(fx, c), String("install: conda-meta/broken-0-0.json is not a package record"))


# ---- 3 payload, 4 program ------------------------------------------------------------------


def test_payload_that_differs_fails() raises:
    var fx = Fixture(String("payload"))
    var c = Container(fx)
    c.payload_alpha = _rep(String("0"), 64) + String("  /work/.pixi/envs/default/lib/mojo/komira_alpha.mojoc\n")
    _assert_fails_with(
        _with(fx, c),
        String("payload: the installed lib/mojo/komira_alpha.mojoc is missing or differs from the one in the package the build made"),
    )
    var fy = Fixture(String("nopayload"))
    var d = Container(fy)
    d.payload_alpha = String("sha256sum: /work/.pixi/envs/default/lib/mojo/komira_alpha.mojoc: No such file or directory\n")
    _assert_fails_with(_with(fy, d), String("payload: the installed lib/mojo/komira_alpha.mojoc is missing"))


def test_a_failing_count_fails() raises:
    var fx = Fixture(String("count59"))
    var c = Container(fx)
    c.smoke_exit = String("1\n")
    c.smoke_out = String("FAILED: base64_encode 'foobar': got 'Zm9vYmFy', want 'Zm9vYmFz'\nFAILED: x\nexample validation: 59 of 61 checks passed\n")
    c.smoke_err = String("Unhandled exception caught during execution: example validation failed\n")
    _assert_fails_with(
        _with(fx, c),
        String("program: mojo run failed: FAILED: base64_encode 'foobar': got 'Zm9vYmFy', want 'Zm9vYmFz';FAILED: x;")
        + String("example validation: 59 of 61 checks passed; Unhandled exception"),
    )


def test_a_vacuous_or_missing_count_fails() raises:
    var fx = Fixture(String("count0"))
    var c = Container(fx)
    c.smoke_out = String("example validation: 0 of 0 checks passed\n")
    _assert_fails_with(
        _with(fx, c), String("program: it exited 0 but printed no complete count (got: 'example validation: 0 of 0 checks passed')")
    )
    var fy = Fixture(String("countnone"))
    var d = Container(fy)
    d.smoke_out = String("example smoke: OK\n")
    _assert_fails_with(_with(fy, d), String("program: it exited 0 but printed no complete count (got: 'example smoke: OK')"))
    var fz = Fixture(String("countother"))
    var e = Container(fz)
    e.smoke_out = String("other validation: 61 of 61 checks passed\n")
    _assert_fails_with(_with(fz, e), String("program: it exited 0 but printed no complete count"))


# ---- --plan ----------------------------------------------------------------------------------


def test_plan_runs_nothing() raises:
    var fx = Fixture(String("plan"))
    fx.req.plan = True
    var runner = ScriptedRunner()
    var t = ScriptedPkgTransport()
    var sl = NoWaitSleeper()
    var row = _run(runner, t, sl, fx)
    assert_equal(row.effect, String(VALIDATION_WOULD_VALIDATE))
    assert_equal(row.outcome, String(""))
    assert_equal(len(row.checks), 0)
    assert_equal(len(runner.calls), 0)
    assert_equal(t.call_count(), 0)
    assert_false(exists(fx.req.scratch_dir))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
