# =============================================================================
# src/kci_build/tests/test_build_flow.mojo
#   The whole `kci build` verb over ScriptedRunner: preflight, the one build,
#   farm-fault rebuilds, verification against the manifests, and the output
#   directory. Every file buck2 would have written (packages, manifests, the
#   build report) is written by the scripted step under TEST_TMPDIR.
# =============================================================================

from std.ffi import external_call
from std.os import getenv, listdir, makedirs
from std.os.path import exists, isfile
from std.pathlib import Path

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_crypto import hex_lower_array_32, sha256_string

from kci_artifact_manifest import read_artifact_manifest
from kci_build import (
    ANY_ARG,
    EXIT_CANNOT_TELL,
    EXIT_FAILED,
    EXIT_OK,
    EXIT_REFUSED,
    EXIT_USAGE,
    BuildRequest,
    ScriptedRunner,
    ScriptedStep,
    build_main_with,
    build_publishable,
    write_text_file,
)

comptime _PROBE = "//tools/build/kci:farm_probe"
comptime _FAULT = (
    "Error: Failed to create build directory `/worker/build/abc`: File exists (os error 17)"
)


def _fresh(tag: String) raises -> String:
    """A new directory under TEST_TMPDIR holding a repo with a .buckconfig."""
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/kb_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d + String("/repo"), exist_ok=True)
    write_text_file(d + String("/repo/.buckconfig"), String("[cells]\n"))
    return d


def _request(root: String, publishable: String) raises -> BuildRequest:
    var r = BuildRequest()
    r.buck2_path = String("/bin/sh")
    r.repo_root = root + String("/repo")
    r.publishable_file = root + String("/repo/release/publishable.txt")
    write_text_file(r.publishable_file, publishable)
    r.probe_target = String(_PROBE)
    r.probe_nonce = String("n1")
    r.out_dir = root + String("/out")
    r.log_dir = root + String("/logs")
    return r^


def _two() -> String:
    return String("# test\nCONDA //pkgs:alpha\nCONDA //pkgs:beta\n")


def _args(*items: String) -> List[String]:
    var l = List[String]()
    for s in items:
        l.append(String(s))
    return l^


def _audit(props: String = String("pool=mojo-sized")) -> ScriptedStep:
    var out = String("{}")
    if props.byte_length() > 0:
        out = String('{"komira_re.linux_properties":"') + props + String('"}')
    return ScriptedStep(
        _args("audit", "config", "komira_re.linux_properties", "--style", "json"),
        stdout_text=out,
    )


def _probe(exit_code: Int32 = Int32(0), stderr: String = String(""), timed_out: Bool = False) -> ScriptedStep:
    return ScriptedStep(
        _args("build", "-c", "komira.execution=remote", "-c", "kci.probe_nonce=n1", _PROBE),
        exit_code=exit_code,
        stderr_text=stderr,
        timed_out=timed_out,
    )


def _hash(content: String) -> String:
    return hex_lower_array_32(sha256_string(content))


def _content(name: String) -> String:
    return String("conda bytes of ") + name


def _file(name: String) -> String:
    return name + String("-1.0.0-h0_0.conda")


def _manifest(name: String, file: String, content: String, artifact_type: String = String("CONDA")) -> String:
    return (
        String('{"artifact_type":"')
        + artifact_type
        + String('","name":"')
        + name
        + String('","version":"1.0.0","subdir":"linux-64","file":"')
        + file
        + String('","sha256":"')
        + _hash(content)
        + String('"}')
    )


struct _Built(Copyable, Movable):
    """What one target 'built' in a scripted build step."""

    var name: String
    var success: Bool
    var manifest_text: String
    var with_manifest: Bool

    def __init__(out self, var name: String, success: Bool = True):
        self.manifest_text = _manifest(name, _file(name), _content(name))
        self.name = name^
        self.success = success
        self.with_manifest = True


def _build_step(
    req: BuildRequest,
    report_name: String,
    built: List[_Built],
    exit_code: Int32 = Int32(0),
    stderr: String = String(""),
) -> ScriptedStep:
    var report = req.log_dir + String("/") + report_name + String("_report.json")
    var argv = _args("build", "-c", "komira.execution=remote", "--build-report", report)
    for i in range(len(built)):
        argv.append(String("//pkgs:") + built[i].name)
        argv.append(String("//pkgs:") + built[i].name + String("[manifest]"))
    var step = ScriptedStep(argv^, exit_code=exit_code, stderr_text=stderr)
    var results = String("")
    for i in range(len(built)):
        ref b = built[i]
        var dir = String("buck-out/v2/art/komira/h/pkgs/__") + b.name + String("__/")
        var pkg = dir + _file(b.name)
        var man = dir + b.name + String(".json")
        if i > 0:
            results += String(",")
        results += String('"komira//pkgs:') + b.name + String('":{')
        if b.success:
            step.writes(pkg.copy(), _content(b.name))
            step.writes(man.copy(), b.manifest_text.copy())
            results += String('"success":"SUCCESS","outputs":{"DEFAULT":["') + pkg + String('"]')
            if b.with_manifest:
                results += String(',"manifest":["') + man + String('"]')
            results += String('},"errors":[]}')
        else:
            results += String('"success":"FAIL","outputs":{},"errors":[{"message_content":"Action failed: ')
            results += b.name + String('"}]}')
    step.writes(
        report^,
        String('{"success":')
        + (String("true") if exit_code == Int32(0) else String("false"))
        + String(',"results":{')
        + results
        + String('},"failures":{},"project_root":"')
        + req.repo_root
        + String('"}'),
    )
    return step^


def _ok_pair() -> List[_Built]:
    var l = List[_Built]()
    l.append(_Built(String("alpha")))
    l.append(_Built(String("beta")))
    return l^


def _contains(hay: String, needle: String) raises:
    if hay.find(needle) < 0:
        raise Error(String("expected to find\n  ") + needle + String("\nin\n  ") + hay)


def test_happy_path_lays_out_packages_and_manifests() raises:
    var root = _fresh(String("happy"))
    var req = _request(root, _two())
    var runner = ScriptedRunner()
    runner.expect(_audit())
    runner.expect(_probe())
    runner.expect(_build_step(req, String("build"), _ok_pair()))
    var o = build_publishable(req, runner)
    assert_equal(o.exit_code, EXIT_OK, o.message)
    assert_equal(runner.remaining(), 0)
    assert_equal(len(runner.calls), 3)
    assert_equal(runner.calls[2].cwd, req.repo_root)
    assert_equal(runner.calls[2].path, String("/bin/sh"))
    assert_equal(runner.calls[2].stderr_path, req.log_dir + String("/build.stderr"))
    assert_equal(len(o.manifests), 2)
    assert_equal(o.manifests[0], req.out_dir + String("/alpha-1.0.0-linux-64.json"))
    var m = read_artifact_manifest(o.manifests[1])
    assert_equal(m.name, String("beta"))
    assert_equal(m.file, String("linux-64/beta-1.0.0-h0_0.conda"))
    assert_equal(m.file_path, req.out_dir + String("/linux-64/beta-1.0.0-h0_0.conda"))
    assert_equal(Path(m.file_path).read_text(), _content(String("beta")))
    assert_equal(m.sha256_hex, _hash(_content(String("beta"))))
    assert_true(isfile(req.out_dir + String("/BUILD_SUMMARY.txt")))
    assert_equal(len(listdir(req.out_dir)), 4)  # 2 manifests, linux-64/, summary


def test_a_buckconfig_with_no_farm_is_refused_before_any_build() raises:
    var root = _fresh(String("nofarm"))
    var req = _request(root, _two())
    var runner = ScriptedRunner()
    runner.expect(_audit(String("")))
    var o = build_publishable(req, runner)
    assert_equal(o.exit_code, EXIT_REFUSED)
    assert_equal(
        o.message,
        String(
            "kci build: the buckconfig names no farm ([komira_re] linux_properties is not set):"
            " this run would build locally"
        ),
    )
    assert_equal(len(runner.calls), 1)
    assert_false(exists(req.out_dir))


def test_an_unreachable_farm_is_cannot_tell_and_builds_nothing() raises:
    var root = _fresh(String("probe"))
    var req = _request(root, _two())
    var runner = ScriptedRunner()
    runner.expect(_audit())
    runner.expect(_probe(Int32(3), String("connection refused")))
    var o = build_publishable(req, runner)
    assert_equal(o.exit_code, EXIT_CANNOT_TELL)
    assert_equal(
        o.message,
        String("kci build: farm unreachable: probe //tools/build/kci:farm_probe exit 3; log ")
        + req.log_dir
        + String("/preflight_probe.stderr:\nconnection refused"),
    )
    assert_equal(len(runner.calls), 2)

    var runner2 = ScriptedRunner()
    runner2.expect(_audit())
    runner2.expect(_probe(timed_out=True))
    var o2 = build_publishable(req, runner2)
    assert_equal(o2.exit_code, EXIT_CANNOT_TELL)
    _contains(o2.message, String("farm unreachable: probe //tools/build/kci:farm_probe timed out"))
    assert_equal(len(runner2.calls), 2)


def test_a_farm_fault_rebuilds_the_failed_target_alone() raises:
    var root = _fresh(String("fault"))
    var req = _request(root, _two())
    var first = List[_Built]()
    first.append(_Built(String("alpha")))
    first.append(_Built(String("beta"), success=False))
    var again = List[_Built]()
    again.append(_Built(String("beta")))
    var runner = ScriptedRunner()
    runner.expect(_audit())
    runner.expect(_probe())
    runner.expect(_build_step(req, String("build"), first, Int32(1), String(_FAULT)))
    runner.expect(_build_step(req, String("rebuild_1_attempt_1"), again))
    var o = build_publishable(req, runner)
    assert_equal(o.exit_code, EXIT_OK, o.message)
    assert_equal(runner.remaining(), 0)
    assert_equal(len(o.manifests), 2)
    assert_equal(runner.calls[3].stderr_path, req.log_dir + String("/rebuild_1_attempt_1.stderr"))


def test_a_farm_fault_that_persists_fails_after_three_rebuilds() raises:
    var root = _fresh(String("persist"))
    var req = _request(root, String("CONDA //pkgs:alpha\n"))
    var bad = List[_Built]()
    bad.append(_Built(String("alpha"), success=False))
    var runner = ScriptedRunner()
    runner.expect(_audit())
    runner.expect(_probe())
    runner.expect(_build_step(req, String("build"), bad, Int32(1), String(_FAULT)))
    for a in range(1, 4):
        runner.expect(
            _build_step(req, String("rebuild_0_attempt_") + String(a), bad, Int32(1), String(_FAULT))
        )
    var o = build_publishable(req, runner)
    assert_equal(o.exit_code, EXIT_FAILED)
    _contains(o.message, String("//pkgs:alpha: the farm fault persisted through 3 rebuilds"))
    assert_equal(runner.remaining(), 0)
    assert_equal(len(runner.calls), 6)
    assert_false(exists(req.out_dir))


def test_a_build_failure_that_is_not_a_fault_is_final() raises:
    var root = _fresh(String("final"))
    var req = _request(root, _two())
    var first = List[_Built]()
    first.append(_Built(String("alpha")))
    first.append(_Built(String("beta"), success=False))
    var runner = ScriptedRunner()
    runner.expect(_audit())
    runner.expect(_probe())
    runner.expect(_build_step(req, String("build"), first, Int32(1), String("error: compile failed")))
    var o = build_publishable(req, runner)
    assert_equal(o.exit_code, EXIT_FAILED)
    _contains(o.message, String("kci build: buck2 build exit 1; log ") + req.log_dir + String("/build.stderr"))
    _contains(o.message, String("failed: //pkgs:beta: Action failed: beta"))
    assert_equal(len(runner.calls), 3)
    assert_false(exists(req.out_dir))


def _refused_after_build(tag: String, var built: List[_Built]) raises -> String:
    var root = _fresh(tag)
    var req = _request(root, _two())
    var runner = ScriptedRunner()
    runner.expect(_audit())
    runner.expect(_probe())
    runner.expect(_build_step(req, String("build"), built))
    var o = build_publishable(req, runner)
    assert_equal(o.exit_code, EXIT_REFUSED, o.message)
    assert_equal(runner.remaining(), 0)
    assert_false(exists(req.out_dir))
    return o.message.copy()


def test_a_sha256_mismatch_is_refused_and_nothing_is_copied() raises:
    var b = _ok_pair()
    b[1].manifest_text = _manifest(String("beta"), _file(String("beta")), String("other bytes"))
    var msg = _refused_after_build(String("sha"), b^)
    _contains(msg, String("kci build: //pkgs:beta: sha256 of '"))
    _contains(msg, String("but its manifest says ") + _hash(String("other bytes")))


def test_a_manifest_for_another_file_or_type_is_refused() raises:
    var b = _ok_pair()
    b[0].manifest_text = _manifest(String("alpha"), String("alpha-9.9.9-h0_0.conda"), _content(String("alpha")))
    _contains(
        _refused_after_build(String("file"), b^),
        String(
            "kci build: //pkgs:alpha: its manifest names file 'alpha-9.9.9-h0_0.conda'"
            " but the target built 'alpha-1.0.0-h0_0.conda'"
        ),
    )
    var c = _ok_pair()
    c[0].manifest_text = String('{"artifact_type":"CONDA"}')
    _contains(_refused_after_build(String("bad"), c^), String("missing 'name'"))


def test_a_target_without_a_manifest_sub_target_is_not_publishable() raises:
    var b = _ok_pair()
    b[1].with_manifest = False
    assert_equal(
        _refused_after_build(String("nosub"), b^),
        String("kci build: //pkgs:beta: not publishable: has 0 [manifest] outputs, not one artifact manifest"),
    )


def test_two_targets_building_one_artifact_are_refused() raises:
    var b = _ok_pair()
    b[1].manifest_text = _manifest(String("alpha"), _file(String("beta")), _content(String("beta")))
    assert_equal(
        _refused_after_build(String("dup"), b^),
        String("kci build: //pkgs:beta: builds CONDA alpha 1.0.0 for linux-64, as //pkgs:alpha already does"),
    )


def test_a_non_empty_out_dir_is_refused_before_anything_runs() raises:
    var root = _fresh(String("stale"))
    var req = _request(root, _two())
    write_text_file(req.out_dir + String("/linux-64/old-0.1-h0_0.conda"), String("stale"))
    var runner = ScriptedRunner()
    var o = build_publishable(req, runner)
    assert_equal(o.exit_code, EXIT_REFUSED)
    _contains(o.message, String("' is not empty: a package from an earlier run could ride along"))
    assert_equal(len(runner.calls), 0)


def test_bad_buck2_paths_are_refused_before_anything_runs() raises:
    var root = _fresh(String("paths"))
    var req = _request(root, _two())
    req.buck2_path = String("bin/buck2")
    var runner = ScriptedRunner()
    var o = build_publishable(req, runner)
    assert_equal(o.message, String("kci build: --buck2 'bin/buck2' is not an absolute path"))
    var plain = root + String("/not_executable")
    write_text_file(plain, String("#!/bin/sh\n"))
    req.buck2_path = plain.copy()
    o = build_publishable(req, runner)
    assert_equal(o.message, String("kci build: --buck2 '") + plain + String("' is not executable"))
    req.buck2_path = String("/bin/sh")
    req.repo_root = root.copy()
    o = build_publishable(req, runner)
    assert_equal(o.exit_code, EXIT_REFUSED)
    assert_equal(o.message, String("kci build: --repo-root '") + root + String("' has no .buckconfig"))
    assert_equal(len(runner.calls), 0)


def test_only_builds_just_the_named_target() raises:
    var root = _fresh(String("only"))
    var req = _request(root, _two())
    req.only.append(String("//pkgs:beta"))
    var one = List[_Built]()
    one.append(_Built(String("beta")))
    var runner = ScriptedRunner()
    runner.expect(_audit())
    runner.expect(_probe())
    runner.expect(_build_step(req, String("build"), one))
    var o = build_publishable(req, runner)
    assert_equal(o.exit_code, EXIT_OK, o.message)
    assert_equal(len(o.manifests), 1)


def test_build_main_with_parses_flags_and_sets_a_nonce() raises:
    var empty = ScriptedRunner()
    assert_equal(build_main_with(List[String](), empty), EXIT_USAGE)
    assert_equal(len(empty.calls), 0)

    var root = _fresh(String("main"))
    var req = _request(root, String("CONDA //pkgs:alpha\n"))
    var one = List[_Built]()
    one.append(_Built(String("alpha")))
    var runner = ScriptedRunner()
    runner.expect(_audit())
    runner.expect(
        ScriptedStep(_args("build", "-c", "komira.execution=remote", "-c", ANY_ARG, _PROBE))
    )
    runner.expect(_build_step(req, String("build"), one))
    var code = build_main_with(
        _args(
            "--buck2", "/bin/sh",
            "--repo-root", req.repo_root,
            "--publishable", req.publishable_file,
            "--probe-target", _PROBE,
            "--out-dir", req.out_dir,
            "--log-dir", req.log_dir,
        ),
        runner,
    )
    assert_equal(code, EXIT_OK)
    var nonce = runner.calls[1].argv[4].copy()
    assert_true(nonce.startswith(String("kci.probe_nonce=")))
    assert_true(nonce.byte_length() > String("kci.probe_nonce=").byte_length() + 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
