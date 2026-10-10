# =============================================================================
# src/kci_build/tests/test_build_closure.mojo
#   The BUILD step refuses a release set whose libraries require a package
#   the set does not declare, after every build and before release.json.
# =============================================================================
#
# ROWS
#   (0) control: komira_name_registry requires the platform guard, the
#       compiler pin and komira_hash (declared); the metapackage requires its
#       two members: BUILT, release.json written;
#   (1) komira_hash requires komira_atomic_alias, which no artifact declares
#       (the shape of a dependency the packer refused, or one nobody
#       declared): REFUSED (exit 3, KCI-E-MEMBER) naming the artifact and the
#       requirement; every build ran; no release.json;
#   (2) a library requiring the metapackage, and (3) one requiring itself:
#       REFUSED the same way (neither is ANOTHER library of the set);
#   (4) two open requirements in two libraries: both named, in member order;
#   (5) komira_hash requires `zstd >=1.5.2,<2`, the conda-forge requirement
#       tools/build/package/system_libs.bzl names for libzstd.so.1: BUILT,
#       release.json written; at `>=1.0`, with no range, behind
#       `conda-forge::`, as `ZSTD`, or `notalib >=1`: REFUSED naming the
#       library and the requirement.
#
# Every file a build would have left is written by the scripted step under
# TEST_TMPDIR (the fixture of test_build_flow.mojo, with each member's
# `depends` chosen per row). Each row is ONE change to the control.
# =============================================================================

from std.ffi import external_call
from std.os import getenv, makedirs
from std.os.path import exists, realpath

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_crypto import hex_lower_array_32, sha256_string

from kci_artifact import ReleaseStamp, read_artifacts, render_build_argv
from kci_api import (
    ERROR_MEMBER,
    EXIT_OK,
    EXIT_REFUSED,
    MemoryRecorder,
    RunIdentity,
)
from kci_api import RunResult as KciRunResult
from kci_build import (
    BuildOutcome,
    BuildRequest,
    ScriptedRunner,
    ScriptedStep,
    run_build,
    write_text_file,
)

comptime _REV = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
comptime _SRC = "f0e1d2c3b4a5968778695a4b3c2d1e0f12345678"
comptime _BUILD = "h01234567_7"
comptime _HEX = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
comptime _PLATFORM = "linux-x86_64"
comptime _GUARD = "__linux"
comptime _PIN = "mojo-compiler ==1.0.0"

comptime _THREE = """schema_version: 1
build_systems {
  name: "buck2"
  executable: "buck2"
  args: "build"
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
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/kbc_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d + String("/repo"), exist_ok=True)
    return realpath(d)


def _request(root: String) raises -> BuildRequest:
    var run = RunIdentity(String("gh-7"), 2)
    var r = BuildRequest(run^)
    r.artifacts_file = root + String("/artifacts.textproto")
    write_text_file(r.artifacts_file, String(_THREE))
    r.work_dir = root + String("/repo")
    r.release_dir = root + String("/release")
    r.log_dir = root + String("/logs")
    r.revision_id = String(_REV)
    r.platform = String(_PLATFORM)
    r.build_timeout_s = 99
    r.step_name = String("build-linux")
    return r^


def _git_argv(*xs: String) -> List[String]:
    var out = List[String]()
    for x in xs:
        out.append(String(x))
    return out^


def _git_ok() -> ScriptedRunner:
    """revision.mojo's six git commands answering a clean checkout of _REV."""
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


def _file(name: String) -> String:
    return name + String("-1.0.0-") + String(_BUILD) + String(".conda")


def _manifest(name: String, file: String, sha: String) -> String:
    return (
        String('{"format":"kci.artifact_manifest","schema_version":1,"artifact_type":"CONDA","name":"')
        + name + String('","version":"1.0.0","platform":"linux-x86_64","subdir":"linux-64","file":"') + file
        + String('","sha256":"') + sha + String('","metadata":"metadata.json"}\n')
    )


def _pin(name: String) -> String:
    return name + String(" ==1.0.0 ") + String(_BUILD)


def _json_list(items: List[String]) -> String:
    var s = String("[")
    for i in range(len(items)):
        if i > 0:
            s += String(",")
        s += String('"') + items[i] + String('"')
    return s + String("]")


def _metadata(name: String, file: String, size: Int, depends: List[String]) -> String:
    var own: String
    if name == "komira":
        own = (
            String(',"kind":"metapackage","members":[{"build":"') + String(_BUILD)
            + String('","name":"komira_hash","sha256":"') + String(_HEX)
            + String('","version":"1.0.0"}]')
        )
    else:
        own = (
            String(',"kind":"library","import_name":"') + name
            + String('","mojo_pin":"1.0.0","payload_path":"lib/mojo/') + name
            + String('.mojoc","payload_sha256":"') + String(_HEX) + String('"')
        )
    return (
        String('{"build":"') + String(_BUILD) + String('","build_number":7,"depends":') + _json_list(depends)
        + String(',"file_name":"') + file + String('","format":"kci.conda_metadata"')
        + String(',"label":"test","name":"') + name + String('","schema_version":1,"size":')
        + String(size) + String(',"source_commit":"0123456789abcdef0123456789abcdef01234567",')
        + String('"stamped":true,"subdir":"linux-64","timestamp_ms":86400000,')
        + String('"version":"1.0.0"') + own + String("}")
    )


def _base(*extra: String) -> List[String]:
    var l = List[String]()
    l.append(String(_GUARD))
    l.append(String(_PIN))
    for x in extra:
        l.append(String(x))
    return l^


def _step(req: BuildRequest, name: String, depends: List[String]) raises -> ScriptedStep:
    var arts = read_artifacts(req.artifacts_file)
    var stamp = ReleaseStamp(String(_REV), String(_SRC), 154, 1790994309000)
    var argv = render_build_argv(arts, name, req.platform_dir(), req.platform, stamp)
    var rest = List[String]()
    for i in range(1, len(argv)):
        rest.append(argv[i].copy())
    var d = req.platform_dir() + String("/") + name + String("/")
    var step = ScriptedStep(rest^)
    var content = String("conda bytes of ") + name
    step.writes(d + _file(name), content.copy())
    step.writes(d + String("manifest.json"), _manifest(name, _file(name), hex_lower_array_32(sha256_string(content))))
    step.writes(d + String("metadata.json"), _metadata(name, _file(name), content.byte_length(), depends))
    return step^


struct _Run(Movable):
    var code: Int
    var error_id: String
    var message: String
    var remaining: Int
    var release_json: Bool

    def __init__(out self, outcome: BuildOutcome, remaining: Int, release_json: Bool) raises:
        self.code = outcome.exit_code()
        self.error_id = outcome.error_id.copy()
        self.message = outcome.message.copy()
        self.remaining = remaining
        self.release_json = release_json


def _build(tag: String, hash_deps: List[String], registry_deps: List[String]) raises -> _Run:
    """The three builds; komira_hash and komira_name_registry leave the given
    `depends`, the metapackage requires the guard and its two members."""
    var req = _request(_fresh(tag))
    var runner = ScriptedRunner()
    runner.expect(_step(req, String("komira_hash"), hash_deps))
    runner.expect(_step(req, String("komira_name_registry"), registry_deps))
    runner.expect(
        _step(req, String("komira"), _base(_pin(String("komira_hash")), _pin(String("komira_name_registry"))))
    )
    var git = _git_ok()
    var result = KciRunResult(String("run"), String("build"))
    var rec = MemoryRecorder()
    var outcome = run_build(req, result, rec, runner, git)
    return _Run(outcome, runner.remaining(), exists(req.platform_dir() + String("/release.json")))


comptime _HEAD = (
    "BUILD step: the release set does not declare every package its libraries require;"
    " declare each in the artifacts file:"
)


def _refused(r: _Run, lines: List[String]) raises:
    assert_equal(r.code, EXIT_REFUSED, r.message)
    assert_equal(r.error_id, String(ERROR_MEMBER))
    var want = String(_HEAD)
    for i in range(len(lines)):
        want += String("\n  ") + lines[i]
    assert_equal(r.message, want)
    assert_equal(r.remaining, 0, "every build ran before the set-level check")
    assert_false(r.release_json, "no release.json for a refused set")


def _open(artifact: String, requirement: String) -> String:
    var sp = requirement.find(String(" "))
    var name = requirement.copy() if sp < 0 else String(requirement[byte=:sp])
    return (
        String("artifact '") + artifact + String("' requires '") + requirement + String("', and '")
        + name + String("' is not another library of this release set")
        + String(" (nor a system library requirement of tools/build/package/system_libs.bzl)")
    )


def test_a_closed_set_builds() raises:
    var r = _build(String("closed"), _base(), _base(_pin(String("komira_hash"))))
    assert_equal(r.code, EXIT_OK, r.message)
    assert_true(r.release_json)


def test_an_undeclared_requirement_is_refused() raises:
    var dep = _pin(String("komira_atomic_alias"))
    var r = _build(String("undeclared"), _base(dep), _base(_pin(String("komira_hash"))))
    var lines = List[String]()
    lines.append(_open(String("komira_hash"), dep))
    _refused(r, lines)


def test_requiring_the_metapackage_is_refused() raises:
    var dep = _pin(String("komira"))
    var r = _build(String("meta"), _base(), _base(_pin(String("komira_hash")), dep))
    var lines = List[String]()
    lines.append(_open(String("komira_name_registry"), dep))
    _refused(r, lines)


def test_requiring_itself_is_refused() raises:
    var dep = _pin(String("komira_hash"))
    var r = _build(String("self"), _base(dep), _base(_pin(String("komira_hash"))))
    var lines = List[String]()
    lines.append(_open(String("komira_hash"), dep))
    _refused(r, lines)


def test_every_open_requirement_is_named() raises:
    var a = _pin(String("komira_atomic_alias"))
    var b = String("komira_json")
    var r = _build(String("two"), _base(a), _base(_pin(String("komira_hash")), b))
    var lines = List[String]()
    lines.append(_open(String("komira_hash"), a))
    lines.append(_open(String("komira_name_registry"), b))
    _refused(r, lines)


def test_a_system_library_requirement_builds() raises:
    var r = _build(String("syslib"), _base(String("zstd >=1.5.2,<2")), _base(_pin(String("komira_hash"))))
    assert_equal(r.code, EXIT_OK, r.message)
    assert_true(r.release_json)


def test_a_system_library_at_another_shape_is_refused() raises:
    var n = 0
    for bad in [
        String("zstd >=1.0"),
        String("zstd"),
        String("conda-forge::zstd >=1.5.2,<2"),
        String("ZSTD >=1.5.2,<2"),
        String("notalib >=1"),
    ]:
        var r = _build(String("syslib_bad_") + String(n), _base(bad), _base(_pin(String("komira_hash"))))
        var lines = List[String]()
        lines.append(_open(String("komira_hash"), bad))
        _refused(r, lines)
        n += 1


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
