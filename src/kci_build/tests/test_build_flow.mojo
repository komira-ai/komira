# =============================================================================
# src/kci_build/tests/test_build_flow.mojo
#   The whole `kci build` verb over ScriptedRunner: one build per declared
#   artifact, in file order, each into its own empty directory; every stop
#   (exit, signal, timeout, not startable, every verify_member refusal) with
#   later artifacts not run and no release.json; release.json last on
#   success, with the set hash printed.
# =============================================================================
#
# Every file a build would have left (package, manifest.json, metadata.json)
# is written by the scripted step under TEST_TMPDIR. The two golden set
# hashes were computed outside Mojo (python3 hashlib over the sorted lines
# `<name>\t1.0.0\th01234567_7\t<sha256 of "conda bytes of <name>">\n`), so
# the printed SET_HASH is checked against an independent computation.
# =============================================================================

from std.ffi import external_call
from std.os import getenv, listdir, makedirs
from std.os.path import exists, isdir, realpath
from std.pathlib import Path

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_crypto import hex_lower_array_32, sha256_string

from kci_artifact_declaration import read_artifact_declarations, render_build_argv
from kci_build import (
    EXIT_CANNOT_TELL,
    EXIT_FAILED,
    EXIT_OK,
    EXIT_REFUSED,
    EXIT_USAGE,
    BuildRequest,
    ProcessRunner,
    RunResult,
    RunSpec,
    ScriptedRunner,
    ScriptedStep,
    build_main_with,
    build_release,
    write_text_file,
)
from kci_release_set import read_release_manifest

comptime _EXAMPLE = "src/kci_artifact_declaration/example.textproto"
comptime _SET_THREE = "b315a610a30db7464869bebf2c622dc99e377d12ed248389f62d855283e1b9c0"
comptime _SET_EXAMPLE = "d2ee84f534bbede2d5de6ae4a70aa0f04a8b0ea27c750a99996a5a992bd37f42"
comptime _BUILD = "h01234567_7"
comptime _HEX = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
comptime _PACK = "/opt/pack/komira_pack"

# Two build systems, three artifacts: two libraries built by buck2 and the
# metapackage by the packer, in that order.
comptime _THREE = """
build_systems {
  name: "buck2"
  executable: "buck2"
  args: "build"
  args: "--config-file"
  args: "/etc/kci/remote.buckconfig"
}
build_systems {
  name: "pack"
  executable: "/opt/pack/komira_pack"
  args: "conda-meta"
}
artifacts {
  name: "komira_hash"
  build_system: "buck2"
  args: "//src/komira_hash:komira_hash_conda[release]"
  args: "--out"
  args: "{out_dir}"
}
artifacts {
  name: "komira_name_registry"
  build_system: "buck2"
  args: "//src/komira_name_registry:komira_name_registry_conda[release]"
  args: "--out"
  args: "{out_dir}"
}
artifacts {
  name: "komira"
  build_system: "pack"
  args: "--name"
  args: "komira"
  args: "--out-dir={out_dir}"
}
"""


def _fresh(tag: String) raises -> String:
    """A new, real-path directory under TEST_TMPDIR holding `repo/`."""
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/kb_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d + String("/repo"), exist_ok=True)
    return realpath(d)


def _request(root: String, decls_text: String = String(_THREE)) raises -> BuildRequest:
    var r = BuildRequest()
    r.declarations_file = root + String("/decls.textproto")
    write_text_file(r.declarations_file, decls_text)
    r.work_dir = root + String("/repo")
    r.out_dir = root + String("/out")
    r.log_dir = root + String("/logs")
    r.build_timeout_s = 99
    return r^


def _hash(text: String) -> String:
    return hex_lower_array_32(sha256_string(text))


def _content(name: String) -> String:
    return String("conda bytes of ") + name


def _file(name: String) -> String:
    return name + String("-1.0.0-") + String(_BUILD) + String(".conda")


def _manifest(name: String, file: String, sha: String) -> String:
    return (
        String('{"artifact_type":"CONDA","name":"') + name
        + String('","version":"1.0.0","subdir":"linux-64","file":"') + file
        + String('","sha256":"') + sha + String('","metadata":"metadata.json"}\n')
    )


def _metadata(
    name: String,
    file: String,
    size: Int,
    version: String = String("1.0.0"),
    stamped: String = String("true"),
) -> String:
    var kind = String("metapackage") if name == "komira" else String("library")
    var own: String
    if kind == "library":
        own = (
            String(',"import_name":"') + name + String('","mojo_pin":"1.0.0","payload_path":"lib/mojo/')
            + name + String('.mojoc","payload_sha256":"') + String(_HEX) + String('"')
        )
    else:
        own = (
            String(',"members":[{"build":"') + String(_BUILD)
            + String('","name":"komira_hash","sha256":"') + String(_HEX)
            + String('","version":"1.0.0"}]')
        )
    return (
        String('{"build":"') + String(_BUILD) + String('","build_number":7,"depends":["__linux"],')
        + String('"file_name":"') + file + String('","kind":"') + kind
        + String('","label":"test","name":"') + name + String('","schema":1,"size":')
        + String(size) + String(',"source_commit":"0123456789abcdef0123456789abcdef01234567",')
        + String('"stamped":') + stamped + String(',"subdir":"linux-64","timestamp_ms":86400000,')
        + String('"version":"') + version + String('"') + own + String("}")
    )


def _expected_argv(req: BuildRequest, name: String) raises -> List[String]:
    """argv[1:] of `render_build_argv` for `name` into `<out>/<name>`."""
    var decls = read_artifact_declarations(req.declarations_file)
    var argv = render_build_argv(decls, name, req.out_dir + String("/") + name)
    var rest = List[String]()
    for i in range(1, len(argv)):
        rest.append(argv[i].copy())
    return rest^


def _good_step(req: BuildRequest, name: String) raises -> ScriptedStep:
    """A step whose build leaves a good member directory for `name`."""
    var d = req.out_dir + String("/") + name + String("/")
    var step = ScriptedStep(_expected_argv(req, name))
    var content = _content(name)
    step.writes(d + _file(name), content.copy())
    step.writes(d + String("manifest.json"), _manifest(name, _file(name), _hash(content)))
    step.writes(d + String("metadata.json"), _metadata(name, _file(name), content.byte_length()))
    return step^


def _names() -> List[String]:
    var l = List[String]()
    l.append(String("komira_hash"))
    l.append(String("komira_name_registry"))
    l.append(String("komira"))
    return l^


struct _Observed(ProcessRunner):
    """ScriptedRunner, plus: for each run, whether the artifact's out dir
    existed and was empty when the run started."""

    var inner: ScriptedRunner
    var dirs: List[String]
    var empty_at_start: List[Bool]

    def __init__(out self, var inner: ScriptedRunner, var dirs: List[String]):
        self.inner = inner^
        self.dirs = dirs^
        self.empty_at_start = List[Bool]()

    def run(mut self, spec: RunSpec) raises -> RunResult:
        var i = len(self.empty_at_start)
        var d = self.dirs[i].copy()
        self.empty_at_start.append(isdir(d) and len(listdir(d)) == 0)
        return self.inner.run(spec)


struct _Unstartable(ProcessRunner):
    """Every run fails to start, as a missing executable would."""

    var calls: Int

    def __init__(out self):
        self.calls = 0

    def run(mut self, spec: RunSpec) raises -> RunResult:
        self.calls += 1
        raise Error(String("cannot start '") + spec.path + String("': errno 2"))


def _release_json(req: BuildRequest) -> String:
    return req.out_dir + String("/release.json")


# ---- success -----------------------------------------------------------------


def test_example_file_builds_its_one_artifact() raises:
    var root = _fresh(String("example"))
    var req = _request(root, Path(String(_EXAMPLE)).read_text())
    var runner = ScriptedRunner()
    var step = _good_step(req, String("komira_encoding"))
    runner.expect(step^)
    var outcome = build_release(req, runner)
    assert_equal(outcome.exit_code, EXIT_OK, outcome.message)
    assert_equal(len(runner.calls), 1)
    ref spec = runner.calls[0]
    assert_equal(spec.path, String("buck2"))
    var want = List[String]()
    for a in [
        "build", "--config-file", "/etc/kci/remote.buckconfig",
        "//src/komira_encoding:komira_encoding_conda[release]", "--out",
    ]:
        want.append(String(a))
    want.append(req.out_dir + String("/komira_encoding"))
    assert_equal(len(spec.argv), len(want))
    for i in range(len(want)):
        assert_equal(spec.argv[i], want[i])
    assert_equal(spec.cwd, req.work_dir)
    assert_equal(spec.timeout_s, 99)
    assert_equal(spec.stdout_path, req.log_dir + String("/komira_encoding.stdout"))
    assert_equal(spec.stderr_path, req.log_dir + String("/komira_encoding.stderr"))
    assert_equal(outcome.set_hash, String(_SET_EXAMPLE))
    assert_equal(outcome.lines[len(outcome.lines) - 1], String("SET_HASH ") + String(_SET_EXAMPLE))
    assert_equal(
        outcome.lines[0],
        String("komira_encoding  1.0.0  ") + String(_BUILD) + String("  ")
        + _hash(_content(String("komira_encoding"))),
    )


def test_three_artifacts_two_build_systems_in_file_order() raises:
    var root = _fresh(String("three"))
    var req = _request(root)
    var inner = ScriptedRunner()
    var dirs = List[String]()
    var names = _names()
    for i in range(len(names)):
        var step = _good_step(req, names[i])
        inner.expect(step^)
        dirs.append(req.out_dir + String("/") + names[i])
    var runner = _Observed(inner^, dirs^)
    var outcome = build_release(req, runner)
    assert_equal(outcome.exit_code, EXIT_OK, outcome.message)
    assert_equal(runner.inner.remaining(), 0)
    assert_equal(len(runner.inner.calls), 3)
    # declaration-file order, each with its own build system's program
    assert_equal(runner.inner.calls[0].path, String("buck2"))
    assert_equal(runner.inner.calls[1].path, String("buck2"))
    assert_equal(runner.inner.calls[2].path, String(_PACK))
    for i in range(3):
        var want = _expected_argv(req, names[i])
        ref got = runner.inner.calls[i].argv
        assert_equal(len(got), len(want))
        for k in range(len(want)):
            assert_equal(got[k], want[k])
        assert_true(runner.empty_at_start[i], String("out dir not empty at start: ") + names[i])
    assert_equal(runner.inner.calls[2].argv[2], String("komira"))
    assert_equal(
        runner.inner.calls[2].argv[3], String("--out-dir=") + req.out_dir + String("/komira")
    )
    # the printed set hash is the independently computed one, and release.json carries it
    assert_equal(outcome.lines[3], String("SET_HASH ") + String(_SET_THREE))
    var r = read_release_manifest(_release_json(req))
    assert_equal(r.set_hash, String(_SET_THREE))
    assert_equal(len(r.entries), 3)
    assert_equal(r.entries[0].name, String("komira"))
    assert_equal(r.entries[0].kind, String("metapackage"))
    assert_equal(r.entries[1].name, String("komira_hash"))
    assert_equal(r.entries[2].dir, String("komira_name_registry"))
    # the release directory is exactly the member dirs and release.json
    assert_equal(len(listdir(req.out_dir)), 4)


def test_build_main_with_prints_and_returns_ok() raises:
    var root = _fresh(String("main"))
    var req = _request(root)
    var runner = ScriptedRunner()
    var names = _names()
    for i in range(len(names)):
        var step = _good_step(req, names[i])
        runner.expect(step^)
    var args = List[String]()
    args.append(String("--declarations=") + req.declarations_file)
    args.append(String("--work-dir=") + req.work_dir)
    args.append(String("--out-dir=") + req.out_dir)
    args.append(String("--log-dir=") + req.log_dir)
    assert_equal(build_main_with(args, runner), EXIT_OK)
    assert_equal(runner.calls[0].timeout_s, 3600)
    assert_true(exists(_release_json(req)))


# ---- stops before anything runs -----------------------------------------------


def test_usage_errors_run_nothing() raises:
    var runner = ScriptedRunner()
    var args = List[String]()
    args.append(String("--buck2=/usr/bin/buck2"))
    assert_equal(build_main_with(args, runner), EXIT_USAGE)
    assert_equal(len(runner.calls), 0)


def test_non_empty_out_dir_is_refused_with_zero_runs() raises:
    var root = _fresh(String("nonempty"))
    var req = _request(root)
    makedirs(req.out_dir, exist_ok=True)
    write_text_file(req.out_dir + String("/stale.conda"), String("x"))
    var runner = ScriptedRunner()
    var outcome = build_release(req, runner)
    assert_equal(outcome.exit_code, EXIT_REFUSED)
    assert_true(outcome.message.find(String("is not empty")) >= 0, outcome.message)
    assert_equal(len(runner.calls), 0)


def test_out_dir_that_is_a_file_is_refused_with_zero_runs() raises:
    var root = _fresh(String("outfile"))
    var req = _request(root)
    write_text_file(req.out_dir, String("x"))
    var runner = ScriptedRunner()
    var outcome = build_release(req, runner)
    assert_equal(outcome.exit_code, EXIT_REFUSED)
    assert_equal(
        outcome.message, String("kci build: --out-dir '") + req.out_dir + String("' is not a directory")
    )
    assert_equal(len(runner.calls), 0)


def test_missing_work_dir_is_refused_with_zero_runs() raises:
    var root = _fresh(String("nowork"))
    var req = _request(root)
    req.work_dir = root + String("/absent")
    var runner = ScriptedRunner()
    var outcome = build_release(req, runner)
    assert_equal(outcome.exit_code, EXIT_REFUSED)
    assert_equal(
        outcome.message,
        String("kci build: --work-dir '") + req.work_dir + String("' is not a directory"),
    )
    assert_equal(len(runner.calls), 0)


def test_invalid_declarations_are_refused_with_zero_runs() raises:
    var root = _fresh(String("baddecl"))
    var req = _request(root, String('build_systems { name: "buck2" executable: "buck2" }\n'))
    var runner = ScriptedRunner()
    var outcome = build_release(req, runner)
    assert_equal(outcome.exit_code, EXIT_REFUSED)
    assert_true(outcome.message.startswith(String("kci build: ")), outcome.message)
    assert_equal(len(runner.calls), 0)
    assert_false(exists(req.out_dir))


# ---- a build that fails: FAILED, later artifacts not run, no release.json ---------


struct _Run(Movable):
    """What one scripted run ended with."""

    var req: BuildRequest
    var code: Int
    var message: String
    var remaining: Int

    def __init__(out self, var req: BuildRequest, code: Int, var message: String, remaining: Int):
        self.req = req^
        self.code = code
        self.message = message^
        self.remaining = remaining


def _second_fails(tag: String, var bad: ScriptedStep) raises -> _Run:
    var root = _fresh(tag)
    var req = _request(root)
    var runner = ScriptedRunner()
    var first = _good_step(req, String("komira_hash"))
    runner.expect(first^)
    runner.expect(bad^)
    var third = _good_step(req, String("komira"))
    runner.expect(third^)
    var outcome = build_release(req, runner)
    return _Run(req^, outcome.exit_code, outcome.message.copy(), runner.remaining())


def _bad_second(req_root_tag: String) raises -> List[String]:
    var req = _request(_fresh(req_root_tag))
    return _expected_argv(req, String("komira_name_registry"))


def test_non_zero_exit_is_failed_naming_the_artifact() raises:
    var step = ScriptedStep(
        _bad_second(String("exit")), exit_code=Int32(2), stderr_text=String("Error: action failed")
    )
    var r = _second_fails(String("exit"), step^)
    ref req = r.req
    assert_equal(r.code, EXIT_FAILED)
    var msg = r.message.copy()
    assert_true(msg.startswith(String("kci build: artifact 'komira_name_registry': `buck2 build ")), msg)
    assert_true(msg.find(String("` exit 2 (stderr: ") + req.log_dir + String("/komira_name_registry.stderr)")) >= 0, msg)
    assert_true(msg.endswith(String("\nError: action failed")), msg)
    assert_equal(r.remaining, 1)
    assert_false(exists(_release_json(req)))
    assert_true(isdir(req.out_dir + String("/komira_hash")))


def test_signal_is_failed() raises:
    var step = ScriptedStep(_bad_second(String("signal")))
    step.result.signaled = True
    var r = _second_fails(String("signal"), step^)
    assert_equal(r.code, EXIT_FAILED)
    assert_true(r.message.find(String("` killed by a signal (stderr: ")) >= 0, r.message)
    assert_equal(r.remaining, 1)
    assert_false(exists(_release_json(r.req)))


def test_timeout_is_failed() raises:
    var step = ScriptedStep(_bad_second(String("timeout")), timed_out=True)
    var r = _second_fails(String("timeout"), step^)
    assert_equal(r.code, EXIT_FAILED)
    assert_true(r.message.find(String("` timed out (stderr: ")) >= 0, r.message)
    assert_equal(r.remaining, 1)
    assert_false(exists(_release_json(r.req)))


def test_a_build_that_cannot_start_is_cannot_tell() raises:
    var root = _fresh(String("nostart"))
    var req = _request(root)
    var runner = _Unstartable()
    var outcome = build_release(req, runner)
    assert_equal(outcome.exit_code, EXIT_CANNOT_TELL)
    assert_equal(
        outcome.message,
        String("kci build: artifact 'komira_hash': the build could not be started:")
        + String(" cannot start 'buck2': errno 2"),
    )
    assert_equal(runner.calls, 1)
    assert_false(exists(_release_json(req)))


# ---- a build that left the wrong thing: REFUSED, later not run, no release.json ---


def _first_refused(tag: String, which: Int) raises -> _Run:
    """The first artifact (komira_hash) leaves a directory broken in way
    `which`; the other two are good but must not run."""
    var root = _fresh(tag)
    var req = _request(root)
    var name = String("komira_hash")
    var d = req.out_dir + String("/") + name + String("/")
    var content = _content(name)
    var file = _file(name)
    var step = ScriptedStep(_expected_argv(req, name))
    if which != 0:  # 0: the build left nothing
        var man_file = file.copy()
        var sha = _hash(content)
        var man_name = name.copy()
        if which == 2:
            man_name = String("komira_hash2")
        if which == 3:
            man_file = String("linux-64/") + file
        if which == 5:
            sha = _hash(content + String("!"))
        step.writes(d + file, content.copy())
        step.writes(d + String("manifest.json"), _manifest(man_name, man_file, sha))
        var version = String("1.0.1") if which == 6 else String("1.0.0")
        var stamped = String("false") if which == 7 else String("true")
        step.writes(
            d + String("metadata.json"),
            _metadata(name, file, content.byte_length(), version=version, stamped=stamped),
        )
        if which == 4:
            step.writes(d + String("BUILD_SUMMARY.txt"), String("x"))
        if which == 8:
            step.writes(d + String("linux-64/manifest.json"), _manifest(name, file, sha))
    var runner = ScriptedRunner()
    runner.expect(step^)
    var second = _good_step(req, String("komira_name_registry"))
    runner.expect(second^)
    var third = _good_step(req, String("komira"))
    runner.expect(third^)
    var outcome = build_release(req, runner)
    return _Run(req^, outcome.exit_code, outcome.message.copy(), runner.remaining())


def _expect_refused(tag: String, which: Int, why: String) raises:
    var r = _first_refused(tag, which)
    assert_equal(r.code, EXIT_REFUSED, r.message)
    assert_equal(r.message, String("kci build: artifact 'komira_hash': ") + why)
    assert_equal(r.remaining, 2)
    assert_false(exists(_release_json(r.req)))


def test_no_manifest_is_refused() raises:
    _expect_refused(
        String("r0"), 0, String("the build left no manifest.json at the top of its output directory")
    )


def test_name_mismatch_is_refused() raises:
    _expect_refused(
        String("r2"),
        2,
        String("the built manifest's name 'komira_hash2' is not the declaration's name (compared exactly)"),
    )


def test_non_bare_file_is_refused() raises:
    _expect_refused(
        String("r3"),
        3,
        String("the manifest's 'file' is 'linux-64/") + _file(String("komira_hash"))
        + String("', not a file name in the artifact's directory"),
    )


def test_stray_top_level_file_is_refused() raises:
    _expect_refused(
        String("r4"),
        4,
        String("the directory holds 'BUILD_SUMMARY.txt', which its manifest does not name;")
        + String(" it holds exactly manifest.json, the file and the metadata"),
    )


def test_a_second_manifest_below_the_top_is_refused() raises:
    _expect_refused(
        String("r8"),
        8,
        String("the directory holds 'linux-64', which its manifest does not name;")
        + String(" it holds exactly manifest.json, the file and the metadata"),
    )


def test_sha_mismatch_is_refused() raises:
    var name = String("komira_hash")
    _expect_refused(
        String("r5"),
        5,
        String("the sha256 of '") + _file(name) + String("' is ") + _hash(_content(name))
        + String(" but its manifest says ") + _hash(_content(name) + String("!")),
    )


def test_metadata_disagreement_is_refused() raises:
    _expect_refused(
        String("r6"), 6, String("its metadata says version '1.0.1' but its manifest says '1.0.0'")
    )


def test_unstamped_is_refused() raises:
    _expect_refused(
        String("r7"),
        7,
        String("its metadata says stamped: false; an unstamped package is never released"),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
