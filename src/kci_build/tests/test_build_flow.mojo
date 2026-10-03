# =============================================================================
# src/kci_build/tests/test_build_flow.mojo
#   The whole `kci build` verb over ScriptedRunner: one build per declared
#   artifact, in file order, each into its own empty directory; every stop
#   (exit, signal, timeout, not startable, every verify_member refusal, a
#   symlinked entry) with later artifacts not run and no release.json; a
#   --log-dir that is --out-dir or under it refused with zero runs; a stray
#   sibling in the out dir and a later build rewriting an earlier member
#   refused before release.json; release.json last on success, with the set
#   hash printed.
# =============================================================================
#
# Every file a build would have left (package, manifest.json, metadata.json)
# is written by the scripted step under TEST_TMPDIR. The two golden set
# hashes were computed outside Mojo (python3 hashlib over the sorted lines
# `<name>\t1.0.0\th01234567_7\t<sha256 of "conda bytes of <name>">\n`), so
# the printed SET_HASH is checked against an independent computation.
# =============================================================================

from std.ffi import external_call
from std.os import getenv, listdir, makedirs, remove, rmdir
from std.os.path import exists, isdir, realpath
from std.pathlib import Path

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_crypto import hex_lower_array_32, sha256_string

from kci_artifact_declaration import ReleaseStamp, read_artifact_declarations, render_build_argv
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
comptime _SET_EXAMPLE = "988a850fd15a324976688400ea9996f6c27b369466aea33e1c28ea0eb002fab6"
comptime _REV = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
comptime _SRC = "f0e1d2c3b4a5968778695a4b3c2d1e0f12345678"
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
  args: "--member-manifest"
  args: "{release_dir}/komira_hash/manifest.json"
  args: "--member-manifest"
  args: "{release_dir}/komira_name_registry/manifest.json"
  args: "--label=kci {revision_id} {source_commit} {build_number} {timestamp_ms}"
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
    r.revision_id = String(_REV)
    r.build_timeout_s = 99
    return r^


def _stamp() raises -> ReleaseStamp:
    return ReleaseStamp(String(_REV), String(_SRC), 154, 1790994309000)


def _git_argv(*xs: String) -> List[String]:
    var out = List[String]()
    for x in xs:
        out.append(String(x))
    return out^


def _git_ok() -> ScriptedRunner:
    """The six git commands of revision.mojo answering a clean, full-history
    checkout of _REV whose stamp commit is _SRC (an older commit: the newest
    ones changed only documentation)."""
    var g = ScriptedRunner()
    g.expect(ScriptedStep(_git_argv("rev-parse", "--is-shallow-repository"), stdout_text=String("false\n")))
    g.expect(ScriptedStep(_git_argv("rev-parse", "--verify", "HEAD"), stdout_text=String(_REV) + String("\n")))
    g.expect(ScriptedStep(_git_argv("status", "--porcelain", "--untracked-files=no")))
    g.expect(
        ScriptedStep(
            _git_argv(
                "log", "-1", "--first-parent", "--format=%H", _REV, "--", ".",
                ":(exclude)docs", ":(exclude)*.md", ":(exclude).github",
            ),
            stdout_text=String(_SRC) + String("\n"),
        )
    )
    g.expect(ScriptedStep(_git_argv("rev-list", "--count", "--first-parent", _SRC), stdout_text=String("154\n")))
    g.expect(ScriptedStep(_git_argv("log", "-1", "--format=%ct", _SRC), stdout_text=String("1790994309\n")))
    return g^


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
    var kind = String("metapackage") if (name == "komira" or name == "komira_all") else String("library")
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
    var argv = render_build_argv(decls, name, req.out_dir, _stamp())
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
    existed and was empty when the run started, and whether every
    `.../manifest.json` its argv names existed then (a metapackage reads its
    members' manifests under `{release_dir}`)."""

    var inner: ScriptedRunner
    var dirs: List[String]
    var empty_at_start: List[Bool]
    var manifests_at_start: List[Bool]

    def __init__(out self, var inner: ScriptedRunner, var dirs: List[String]):
        self.inner = inner^
        self.dirs = dirs^
        self.empty_at_start = List[Bool]()
        self.manifests_at_start = List[Bool]()

    def run(mut self, spec: RunSpec) raises -> RunResult:
        var i = len(self.empty_at_start)
        var d = self.dirs[i].copy()
        self.empty_at_start.append(isdir(d) and len(listdir(d)) == 0)
        var present = True
        for k in range(len(spec.argv)):
            if spec.argv[k].endswith(String("/manifest.json")) and not exists(spec.argv[k]):
                present = False
        self.manifests_at_start.append(present)
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


def test_example_file_builds_the_stamped_library_then_the_metapackage() raises:
    var root = _fresh(String("example"))
    var req = _request(root, Path(String(_EXAMPLE)).read_text())
    var runner = ScriptedRunner()
    runner.expect(_good_step(req, String("komira_encoding")))
    runner.expect(_good_step(req, String("komira_all")))
    var git = _git_ok()
    var outcome = build_release(req, runner, git)
    assert_equal(outcome.exit_code, EXIT_OK, outcome.message)
    assert_equal(git.remaining(), 0)
    assert_equal(len(runner.calls), 2)
    ref spec = runner.calls[0]
    assert_equal(spec.path, String("buck2"))
    var want = List[String]()
    for a in [
        "build", "-c", "komira.package_stamp=154",
        "-c", "komira.package_commit=f0e1d2c3b4a5968778695a4b3c2d1e0f12345678",
        "-c", "komira.package_timestamp_ms=1790994309000",
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
    # the metapackage, last, through `buck2 run`, reading the library's manifest
    ref meta = runner.calls[1]
    assert_equal(meta.path, String("buck2"))
    assert_equal(meta.argv[0], String("run"))
    assert_equal(meta.argv[1], String("//tools/build/package:komira_pack"))
    assert_equal(meta.argv[3], String("conda-meta"))
    assert_equal(meta.argv[7], req.out_dir + String("/komira_encoding/manifest.json"))
    assert_equal(meta.argv[len(meta.argv) - 1], req.out_dir + String("/komira_all"))
    # the git commands ran in the work dir, logged where no artifact can be
    assert_equal(git.calls[0].cwd, req.work_dir)
    assert_equal(git.calls[0].stdout_path, req.log_dir + String("/_git_1.stdout"))
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
    var git = _git_ok()
    var outcome = build_release(req, runner, git)
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
    # the metapackage, last, names its members under {release_dir} (the out
    # dir), and both manifests were there when it started; the stamp reached it
    assert_equal(
        runner.inner.calls[2].argv[5], req.out_dir + String("/komira_hash/manifest.json")
    )
    assert_equal(
        runner.inner.calls[2].argv[7], req.out_dir + String("/komira_name_registry/manifest.json")
    )
    assert_equal(
        runner.inner.calls[2].argv[8],
        String("--label=kci ") + String(_REV) + String(" ") + String(_SRC) + String(" 154 1790994309000"),
    )
    assert_true(runner.manifests_at_start[2], String("member manifests missing when the metapackage ran"))
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
    args.append(String("--revision-id=") + String(_REV))
    var git = _git_ok()
    assert_equal(build_main_with(args, runner, git), EXIT_OK)
    assert_equal(git.remaining(), 0)
    assert_equal(runner.calls[0].timeout_s, 3600)
    assert_true(exists(_release_json(req)))


# ---- stops before anything runs -----------------------------------------------


def test_usage_errors_run_nothing() raises:
    var runner = ScriptedRunner()
    var args = List[String]()
    args.append(String("--buck2=/usr/bin/buck2"))
    var git = _git_ok()
    assert_equal(build_main_with(args, runner, git), EXIT_USAGE)
    assert_equal(len(runner.calls), 0)


def test_non_empty_out_dir_is_refused_with_zero_runs() raises:
    var root = _fresh(String("nonempty"))
    var req = _request(root)
    makedirs(req.out_dir, exist_ok=True)
    write_text_file(req.out_dir + String("/stale.conda"), String("x"))
    var runner = ScriptedRunner()
    var git = _git_ok()
    var outcome = build_release(req, runner, git)
    assert_equal(outcome.exit_code, EXIT_REFUSED)
    assert_true(outcome.message.find(String("is not empty")) >= 0, outcome.message)
    assert_equal(len(runner.calls), 0)


def test_out_dir_that_is_a_file_is_refused_with_zero_runs() raises:
    var root = _fresh(String("outfile"))
    var req = _request(root)
    write_text_file(req.out_dir, String("x"))
    var runner = ScriptedRunner()
    var git = _git_ok()
    var outcome = build_release(req, runner, git)
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
    var git = _git_ok()
    var outcome = build_release(req, runner, git)
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
    var git = _git_ok()
    var outcome = build_release(req, runner, git)
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
    var git = _git_ok()
    var outcome = build_release(req, runner, git)
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
    var git = _git_ok()
    var outcome = build_release(req, runner, git)
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
    var git = _git_ok()
    var outcome = build_release(req, runner, git)
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


# ---- --log-dir is --out-dir or under it: REFUSED, nothing runs, nothing made -----


def _log_dir_refused(tag: String, log_dir: String, shown: String) raises:
    """`log_dir` (relative to the fresh root) resolves to `shown` (relative
    to the root), which is the out dir or under it."""
    var root = _fresh(tag)
    var req = _request(root)
    req.log_dir = root + String("/") + log_dir
    var runner = ScriptedRunner()
    var git = _git_ok()
    var outcome = build_release(req, runner, git)
    assert_equal(outcome.exit_code, EXIT_REFUSED, outcome.message)
    assert_equal(
        outcome.message,
        String("kci build: --log-dir '") + req.log_dir + String("' is --out-dir '") + req.out_dir
        + String("' or lies under it ('") + root + String("/") + shown + String("' in '")
        + req.out_dir
        + String("'): the out dir becomes the release directory, which holds only the")
        + String(" member directories and release.json"),
    )
    assert_equal(len(runner.calls), 0)
    assert_false(exists(req.out_dir))
    assert_false(exists(req.log_dir))


def test_log_dir_that_is_the_out_dir_is_refused_with_zero_runs() raises:
    _log_dir_refused(String("log_eq"), String("out"), String("out"))
    _log_dir_refused(String("log_eq2"), String("repo/../out/."), String("out"))


def test_log_dir_under_the_out_dir_is_refused_with_zero_runs() raises:
    _log_dir_refused(String("log_under"), String("out/logs"), String("out/logs"))
    # named like an artifact: it would have collided with that member's dir
    _log_dir_refused(String("log_member"), String("out/komira"), String("out/komira"))


def test_log_dir_under_the_out_dir_through_a_symlink_is_refused() raises:
    var root = _fresh(String("log_link"))
    var req = _request(root)
    makedirs(req.out_dir, exist_ok=True)
    _symlink(req.out_dir, root + String("/alias"))
    req.log_dir = root + String("/alias/logs")
    var runner = ScriptedRunner()
    var git = _git_ok()
    var outcome = build_release(req, runner, git)
    assert_equal(outcome.exit_code, EXIT_REFUSED, outcome.message)
    assert_true(outcome.message.find(String("' or lies under it ('") + req.out_dir + String("/logs' in '")) >= 0, outcome.message)
    assert_equal(len(runner.calls), 0)


def test_log_dir_beside_the_out_dir_is_accepted() raises:
    var root = _fresh(String("log_beside"))
    var req = _request(root)
    req.log_dir = root + String("/out-logs")  # shares a prefix, not a directory
    var runner = ScriptedRunner()
    var names = _names()
    for i in range(len(names)):
        runner.expect(_good_step(req, names[i]))
    var git = _git_ok()
    var outcome = build_release(req, runner, git)
    assert_equal(outcome.exit_code, EXIT_OK, outcome.message)


# ---- after every build: the out dir must hold exactly the final members ------------


def _symlink(target: String, link: String) raises:
    """`ln -s target link`, through libc (test-only FFI)."""
    var t = target.copy()
    var l = link.copy()
    var rc = external_call["symlink", Int32](
        t.as_c_string_slice().unsafe_ptr(), l.as_c_string_slice().unsafe_ptr()
    )
    if rc != 0:
        raise Error(String("symlink(") + target + String(", ") + link + String(") failed"))


def _three_with(tag: String, which: Int) raises -> _Run:
    """All three builds succeed; the LAST one (komira) also does `which`:
    1 writes a stray sibling into the out dir, 2 rewrites the first member
    consistently (it still verifies, with other bytes), 3 leaves a stray
    file inside the first member."""
    var root = _fresh(tag)
    var req = _request(root)
    var runner = ScriptedRunner()
    runner.expect(_good_step(req, String("komira_hash")))
    runner.expect(_good_step(req, String("komira_name_registry")))
    var last = _good_step(req, String("komira"))
    var first = req.out_dir + String("/komira_hash/")
    if which == 1:
        last.writes(req.out_dir + String("/BUILD_SUMMARY.txt"), String("x"))
    if which == 2:
        var other = _content(String("komira_hash")) + String(" v2")
        var file = _file(String("komira_hash"))
        last.writes(first + file, other.copy())
        last.writes(first + String("manifest.json"), _manifest(String("komira_hash"), file, _hash(other)))
        last.writes(
            first + String("metadata.json"),
            _metadata(String("komira_hash"), file, other.byte_length()),
        )
    if which == 3:
        last.writes(first + String("stray.txt"), String("x"))
    runner.expect(last^)
    var git = _git_ok()
    var outcome = build_release(req, runner, git)
    return _Run(req^, outcome.exit_code, outcome.message.copy(), runner.remaining())


def test_a_stray_sibling_in_the_out_dir_is_refused() raises:
    var r = _three_with(String("sibling"), 1)
    assert_equal(r.code, EXIT_REFUSED, r.message)
    assert_equal(
        r.message,
        String("kci build: --out-dir '") + r.req.out_dir
        + String("' holds 'BUILD_SUMMARY.txt', which no declaration names: the release")
        + String(" directory holds only the member directories and release.json (a build wrote")
        + String(" outside its own directory)"),
    )
    assert_equal(r.remaining, 0)
    assert_false(exists(_release_json(r.req)))


def test_a_later_build_rewriting_an_earlier_member_is_refused() raises:
    var r = _three_with(String("rewrite"), 2)
    assert_equal(r.code, EXIT_REFUSED, r.message)
    var was = _hash(_content(String("komira_hash")))
    var now = _hash(_content(String("komira_hash")) + String(" v2"))
    assert_equal(
        r.message,
        String("kci build: artifact 'komira_hash': its directory changed after it was verified")
        + String(" (a later build wrote into it): was `komira_hash  1.0.0  ") + String(_BUILD)
        + String("  ") + was + String("`, now `komira_hash  1.0.0  ") + String(_BUILD)
        + String("  ") + now + String("`"),
    )
    assert_equal(r.remaining, 0)
    assert_false(exists(_release_json(r.req)))


def test_a_later_build_breaking_an_earlier_member_is_refused() raises:
    var r = _three_with(String("break"), 3)
    assert_equal(r.code, EXIT_REFUSED, r.message)
    assert_equal(
        r.message,
        String("kci build: after every build ran, artifact 'komira_hash': the directory holds")
        + String(" 'stray.txt', which its manifest does not name; it holds exactly manifest.json,")
        + String(" the file and the metadata"),
    )
    assert_false(exists(_release_json(r.req)))


# ---- a member entry that is a symlink: REFUSED, later not run, no release.json ----


struct _LinksFirstFile(ProcessRunner):
    """ScriptedRunner; after the FIRST run, replaces `entry` of that run's out
    dir with a symlink to an identical-bytes file outside the out dir. An
    EMPTY `entry` replaces the member dir itself, its files moved to
    `outside`."""

    var inner: ScriptedRunner
    var member_dir: String
    var entry: String
    var outside: String

    def __init__(
        out self, var inner: ScriptedRunner, var member_dir: String, var entry: String, var outside: String
    ):
        self.inner = inner^
        self.member_dir = member_dir^
        self.entry = entry^
        self.outside = outside^

    def run(mut self, spec: RunSpec) raises -> RunResult:
        var r = self.inner.run(spec)
        if self.inner.next_step == 1 and self.entry.byte_length() == 0:
            var listing = listdir(self.member_dir)
            for i in range(len(listing)):
                var name = String(listing[i])
                var p = self.member_dir + String("/") + name
                write_text_file(self.outside + String("/") + name, Path(p).read_text())
                remove(p)
            rmdir(self.member_dir)
            _symlink(self.outside, self.member_dir)
        elif self.inner.next_step == 1:
            var p = self.member_dir + String("/") + self.entry
            write_text_file(self.outside, Path(p).read_text())
            remove(p)
            _symlink(self.outside, p)
        return r^


def _linked_first(tag: String, entry: String, why: String = String("")) raises:
    var root = _fresh(tag)
    var req = _request(root)
    var inner = ScriptedRunner()
    var names = _names()
    for i in range(len(names)):
        inner.expect(_good_step(req, names[i]))
    var runner = _LinksFirstFile(
        inner^, req.out_dir + String("/komira_hash"), entry.copy(), root + String("/elsewhere/") + entry
    )
    var git = _git_ok()
    var outcome = build_release(req, runner, git)
    assert_equal(outcome.exit_code, EXIT_REFUSED, outcome.message)
    var expected = why.copy()
    if expected.byte_length() == 0:
        expected = (
            String("the directory's '") + entry
            + String("' is a symlink: the directory holds regular files only, and a link can name")
            + String(" bytes outside the release directory")
        )
    assert_equal(outcome.message, String("kci build: artifact 'komira_hash': ") + expected)
    assert_equal(runner.inner.remaining(), 2)
    assert_false(exists(_release_json(req)))


def test_a_symlinked_file_is_refused() raises:
    _linked_first(String("lnfile"), _file(String("komira_hash")))


def test_a_symlinked_metadata_is_refused() raises:
    _linked_first(String("lnmeta"), String("metadata.json"))


def test_a_symlinked_manifest_is_refused() raises:
    _linked_first(String("lnman"), String("manifest.json"))


def test_a_symlinked_member_dir_is_refused() raises:
    var root = _fresh(String("lndir"))
    _linked_first(
        String("lndir"),
        String(""),
        String("'") + root + String("/out/komira_hash' is a symlink, not a directory: a link can")
        + String(" name bytes outside the release directory"),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
