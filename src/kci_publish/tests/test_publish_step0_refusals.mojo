# =============================================================================
# src/kci_publish/tests/test_publish_step0_refusals.mojo -- step 0's
#   refusals of the files a PUBLISH step reads, each with its own error id,
#   before any request; and the `--release-version` file's own refusals.
# =============================================================================
#
# ROWS
#   (1) an EMPTY --release-dir is KCI-E-USAGE (exit 2), naming the flag;
#   (2) an artifacts file that cannot be read is KCI-E-ARTIFACT;
#   (3) a release.json that is not JSON is KCI-E-FORMAT;
#   (4) a --release-version file that cannot be read is KCI-E-FORMAT,
#       naming the file;
#   (5) a --release-version of another build number than the members' is
#       a lockstep refusal, KCI-E-MEMBER;
#   (6) a channels file that cannot be read is KCI-E-CHANNEL, naming it;
#   each with ZERO channel requests and no RUNNING record;
#   (7) `prepare_release` (what a later stage's lookahead reads through)
#       raises a refusal of several lines as those lines, one per line,
#       without the RESULT line;
#   (8) `parse_release_version`: a commit of 40 hex digits with an
#       uppercase one is refused, and a missing `version` or `commit` key is
#       named.
#
# Hermetic: TEST_TMPDIR, ScriptedChannel; no network.
# =============================================================================

from std.ffi import external_call
from std.os import makedirs

from komira_libc.posix import _read_env
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from kci_api import (
    ERROR_ARTIFACT,
    ERROR_CHANNEL,
    ERROR_FORMAT,
    ERROR_MEMBER,
    ERROR_USAGE,
    EXIT_REFUSED,
    EXIT_USAGE,
    MemoryRecorder,
)
from kci_api import RunResult as KciRunResult
from kci_pkg_upload import RegistrySet, ScriptedPkgTransport
from kci_publish import (
    ActionsOidcEnv,
    NoSecretStore,
    NoWaitSleeper,
    PublishCredential,
    PublishRequest,
    RunOptions,
    ScriptedChannel,
    parse_release_version,
    publish_flow,
)
from kci_publish.flow import prepare_release
from kci_publish.release_fixture import (
    EXAMPLE_HOST,
    ExampleRelease,
    example_channel_path,
    write_example_inputs,
    write_text_file,
)


comptime _COMMIT: String = "0123456789abcdef0123456789abcdef01234567"


def _root(tag: String) raises -> String:
    var base = _read_env("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = _read_env("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/ps0_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d, exist_ok=True)
    return d^


def _req(tag: String) raises -> PublishRequest:
    return write_example_inputs(ExampleRelease(), _root(tag), String("example-stable"), True)


def _refused(req: PublishRequest, error_id: String, needle: String, exit_code: Int = EXIT_REFUSED) raises:
    """`req` is refused at step 0 with `error_id`, a line holding `needle`,
    nothing sent and nothing recorded."""
    var ch = ScriptedChannel(String(EXAMPLE_HOST), example_channel_path(String("example-stable")), String("linux-64"))
    var reg = RegistrySet[ScriptedChannel, PublishCredential](ch^, PublishCredential())
    var store = NoSecretStore()
    var sl = NoWaitSleeper()
    var result = KciRunResult(String("run"), String("publish"))
    var rec = MemoryRecorder()
    var rep = publish_flow(req, result, rec, reg, ScriptedPkgTransport(), ActionsOidcEnv.absent(), store, RunOptions(), sl)
    var lines = String("\n").join(rep.lines)
    assert_equal(rep.outcome(), String("REFUSED"), lines)
    assert_equal(rep.error_id, error_id, lines)
    assert_equal(rep.exit_code(), exit_code, lines)
    assert_true(rep.has_line_containing(needle), String("no line says '") + needle + String("':\n") + lines)
    assert_equal(reg.transport().call_count(), 0)
    assert_equal(len(rec.records), 0)


def test_an_empty_release_dir_is_usage() raises:
    var req = _req(String("nodir"))
    req.release_dir = String("")
    _refused(req, String(ERROR_USAGE), String("--release-dir: the release directory is EMPTY"), EXIT_USAGE)


def test_an_unreadable_artifacts_file_is_artifact() raises:
    var req = _req(String("noarts"))
    req.artifacts_file = req.artifacts_file + String(".missing")
    _refused(req, String(ERROR_ARTIFACT), String(".missing"))


def test_a_release_json_that_is_not_json_is_format() raises:
    var req = _req(String("badjson"))
    write_text_file(req.platform_dir() + String("/release.json"), String("{"))
    _refused(req, String(ERROR_FORMAT), String("release.json"))


def test_an_unreadable_release_version_is_format() raises:
    var req = _req(String("norv"))
    req.release_version_file = req.release_version_file + String(".missing")
    _refused(req, String(ERROR_FORMAT), String(".missing' cannot be read: "))


def test_a_release_version_of_another_build_is_a_lockstep_refusal() raises:
    var req = _req(String("rvbuild"))
    var other = ExampleRelease()
    other.build_number = 4
    write_text_file(req.release_version_file, other.release_version_text())
    _refused(req, String(ERROR_MEMBER), String("lockstep refused:"))


def test_an_unreadable_channels_file_is_channel() raises:
    var req = _req(String("nochan"))
    req.channels_file = req.channels_file + String(".missing")
    _refused(req, String(ERROR_CHANNEL), String("channels file '") + req.channels_file + String("' cannot be read: "))


def test_prepare_release_raises_every_line_of_a_refusal() raises:
    var req = _req(String("prep"))
    var other = ExampleRelease()
    other.build_number = 4
    write_text_file(req.release_version_file, other.release_version_text())
    var text = String("")
    try:
        _ = prepare_release(req)
    except e:
        text = String(e)
    assert_true(text.startswith(String("PUBLISH step: lockstep refused:\n  artifact 'komira_alpha': ")), text)
    # every member's line is there, each on its own line
    assert_true(text.find(String("\n  artifact 'komira_beta': ")) > 0, text)
    assert_true(text.find(String("\n  artifact 'komira': ")) > 0, text)
    assert_false(text.find(String("RESULT ")) >= 0, text)


def _rv(version: Bool, commit: String) -> String:
    var t = String("build_number=3\nbuild=h01234567_3\n")
    if version:
        t += String("version=1.0.0\n")
    if commit.byte_length() > 0:
        t += String("commit=") + commit + String("\n")
    return t^


def test_a_release_version_commit_must_be_lowercase_hex() raises:
    var upper = String("0123456789ABCDEF0123456789abcdef01234567")
    var text = String("")
    try:
        _ = parse_release_version(_rv(True, upper), String("rv.txt"))
    except e:
        text = String(e)
    assert_equal(
        text,
        String("release version 'rv.txt': commit is not 40 or 64 lowercase hex characters: '") + upper + String("'"),
    )
    var ok = parse_release_version(_rv(True, String(_COMMIT)), String("rv.txt"))
    assert_equal(ok.commit, String(_COMMIT))


def test_a_release_version_names_each_missing_key() raises:
    var text = String("")
    try:
        _ = parse_release_version(_rv(False, String(_COMMIT)), String("rv.txt"))
    except e:
        text = String(e)
    assert_equal(text, String("release version 'rv.txt': missing key(s): version"))
    text = String("")
    try:
        _ = parse_release_version(_rv(True, String("")), String("rv.txt"))
    except e:
        text = String(e)
    assert_equal(text, String("release version 'rv.txt': missing key(s): commit"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
