# =============================================================================
# src/kci_publish/tests/test_publish_set_hash.mojo -- contract 0.5: the set
#   hash publish recomputes from the member directories is the approved one.
# =============================================================================
#
# ROWS
#   (1) GOLDEN: the example release's set hash is a fixed value, computed
#       outside Mojo from the rule (sha256 of the bytewise-sorted lines
#       `<name>\t<version>\t<build>\t<sha256>\n`, the metapackage included);
#       `load_release` recomputes it and release.json records it;
#   (2) one member's bytes changed (and its manifest and metadata with it,
#       so the member verifies): the recomputed hash is another, and the
#       approved one is refused;
#   (3) the whole verb with a wrong `--expect-set-hash`: exit 3, the line
#       names both hashes, and the channel saw ZERO requests (no read, no
#       write) and the credential was never asked.
#
# Hermetic: TEST_TMPDIR and ScriptedChannel; no network.
# =============================================================================

from std.ffi import external_call
from std.os import makedirs

from komira_libc.posix import _read_env
from std.testing import assert_equal, assert_true

from kci_pkg_upload import RegistrySet
from kci_publish import (
    NoWaitSleeper,
    EXIT_REFUSED,
    NoSecretStore,
    PublishCredential,
    PublishFlags,
    RunOptions,
    ScriptedChannel,
    publish_flow,
)
from kci_publish.release_fixture import (
    EXAMPLE_CHANNELS,
    EXAMPLE_HOST,
    ExampleRelease,
    example_loaded,
    write_text_file,
)
from kci_publish.verify import require_set_hash
from kci_pkg_upload import ScriptedPkgTransport


comptime _WRONG: String = "abababababababababababababababababababababababababababababababab"
comptime _GOLDEN: String = "99973435ee59ab963403d51d045fdd3b57dada20f3c47ca1077030e0c98029b6"


def _root(tag: String) raises -> String:
    var base = _read_env("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = _read_env("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/psh_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d, exist_ok=True)
    return d^


def test_golden() raises:
    var r = ExampleRelease()
    var d = _root(String("golden"))
    r.write(d + String("/release"))
    var loaded = example_loaded(r, d + String("/release"))
    assert_equal(loaded.set_hash(), String(_GOLDEN))
    assert_equal(r.set_hash(d + String("/release")), String(_GOLDEN))
    require_set_hash(loaded, String(_GOLDEN))
    print("  test_golden: PASS")


def test_other_bytes_other_hash() raises:
    var r = ExampleRelease()
    r.members[1].content = String("beta conda bytes, rebuilt")
    var d = _root(String("other"))
    r.write(d)
    var loaded = example_loaded(r, d)
    assert_true(loaded.set_hash() != String(_GOLDEN))
    var raised = False
    try:
        require_set_hash(loaded, String(_GOLDEN))
    except e:
        raised = True
        assert_true(String(e).find(String("--expect-set-hash is ") + String(_GOLDEN)) >= 0, String(e))
        assert_true(String(e).find(loaded.set_hash()) >= 0, String(e))
    assert_true(raised)
    print("  test_other_bytes_other_hash: PASS")


def test_a_wrong_expectation_sends_nothing() raises:
    var r = ExampleRelease()
    var d = _root(String("flow"))
    r.write(d + String("/release"))
    write_text_file(d + String("/decls.textproto"), r.declarations_text())
    write_text_file(d + String("/channels.textproto"), String(EXAMPLE_CHANNELS))
    write_text_file(d + String("/rv.txt"), r.release_version_text())
    var f = PublishFlags()
    f.declarations_file = d + String("/decls.textproto")
    f.artifacts_dir = d + String("/release")
    f.channels_file = d + String("/channels.textproto")
    f.channel = String("example-stable")
    f.release_version_file = d + String("/rv.txt")
    f.expect_set_hash = String(_WRONG)
    f.report_file = d + String("/report.json")
    var reg = RegistrySet[ScriptedChannel, PublishCredential](
        ScriptedChannel(String(EXAMPLE_HOST), String("example-stable"), String("linux-64")),
        PublishCredential(),
    )
    var store = NoSecretStore()
    var sleeper = NoWaitSleeper()
    var rep = publish_flow(f, reg, ScriptedPkgTransport(), store, RunOptions(), sleeper)
    assert_equal(rep.exit_code, EXIT_REFUSED)
    assert_true(rep.has_line_containing(String("--expect-set-hash is ") + String(_WRONG)))
    assert_true(rep.has_line_containing(String(_GOLDEN)))
    assert_equal(reg.transport().call_count(), 0)
    print("  test_a_wrong_expectation_sends_nothing: PASS")


def main() raises:
    test_golden()
    test_other_bytes_other_hash()
    test_a_wrong_expectation_sends_nothing()
    print("test_publish_set_hash: ALL PASS")
