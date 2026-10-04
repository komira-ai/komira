# =============================================================================
# src/kci_publish/tests/test_publish_set_hash.mojo -- contract 0.5: the set
#   hash publish recomputes from the member directories is the one
#   release.json records, and the result carries it.
# =============================================================================
#
# ROWS
#   (1) GOLDEN: the example release's set hash is a fixed value, computed
#       outside Mojo from the rule (python3 hashlib: sha256 of the header
#       line `release_set\t2\t<revision>\tlinux-x86_64\n` and then the
#       bytewise-sorted lines `<name>\tlinux-x86_64\t<version>\t<build>\t
#       linux-64\tCONDA\t<sha256>\n`, the metapackage included);
#       `load_release` recomputes it and release.json records it;
#   (2) one member's bytes changed (and its manifest and metadata with it,
#       so the member verifies): the recomputed hash is another;
#   (3) the whole step over a release.json that records another set hash
#       than the members recompute to: REFUSED (exit 3, KCI-E-MEMBER), the
#       line names both hashes, nothing was recorded as RUNNING, and the
#       channel saw ZERO requests (no read, no write). There is no
#       approved-hash input: the set a release publishes is the one its
#       declarations and its build produced, and the result records the
#       recomputed hash for each channel it reaches.
#
# Hermetic: TEST_TMPDIR and ScriptedChannel; no network.
# =============================================================================

from std.ffi import external_call
from std.os import getenv, makedirs
from std.testing import assert_equal, assert_true

from kci_contract import ERROR_MEMBER, EXIT_REFUSED, MemoryRecorder
from kci_contract import RunResult as KciRunResult
from kci_pkg_upload import RegistrySet
from kci_publish import (
    ActionsOidcEnv,
    NoWaitSleeper,
    NoSecretStore,
    PublishCredential,
    RunOptions,
    ScriptedChannel,
    publish_flow,
)
from kci_publish.release_fixture import (
    example_channel_path,
    EXAMPLE_HOST,
    ExampleRelease,
    example_loaded,
    write_example_inputs,
)
from kci_pkg_upload import ScriptedPkgTransport


comptime _GOLDEN: String = "551855805f860054f4024e7ad1c219c54f0c30da078ff0ea273f9d19806292ef"


def _root(tag: String) raises -> String:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
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
    print("  test_golden: PASS")


def test_other_bytes_other_hash() raises:
    var r = ExampleRelease()
    r.members[1].content = String("beta conda bytes, rebuilt")
    var d = _root(String("other"))
    r.write(d)
    var loaded = example_loaded(r, d)
    assert_true(loaded.set_hash() != String(_GOLDEN))
    assert_equal(loaded.set_hash(), r.set_hash(d))
    print("  test_other_bytes_other_hash: PASS")


def test_a_release_json_of_another_set_sends_nothing() raises:
    var r = ExampleRelease()
    var d = _root(String("flow"))
    var req = write_example_inputs(r, d, String("example-stable"))
    # release.json now is another build's: self-consistent, but not what
    # these members recompute to
    var other = ExampleRelease()
    other.members[1].content = String("beta conda bytes, rebuilt")
    var od = _root(String("flow_other"))
    other.write(od)
    var other_hash = other.set_hash(od)
    var f = open(req.platform_dir() + String("/release.json"), "w")
    f.write(open(od + String("/release.json"), "r").read())
    f.close()
    var reg = RegistrySet[ScriptedChannel, PublishCredential](
        ScriptedChannel(String(EXAMPLE_HOST), example_channel_path(String("example-stable")), String("linux-64")),
        PublishCredential(),
    )
    var store = NoSecretStore()
    var sleeper = NoWaitSleeper()
    var result = KciRunResult(String("run"), String("publish"))
    var rec = MemoryRecorder()
    var rep = publish_flow(req, result, rec, reg, ScriptedPkgTransport(), ActionsOidcEnv.absent(), store, RunOptions(), sleeper)
    assert_equal(rep.exit_code(), EXIT_REFUSED, String("\n").join(rep.lines))
    assert_equal(rep.error_id, String(ERROR_MEMBER))
    assert_equal(result.error.id, String(ERROR_MEMBER))
    assert_equal(len(rec.records), 0)
    assert_true(rep.has_line_containing(String("it says set hash ") + other_hash), String("\n").join(rep.lines))
    assert_true(rep.has_line_containing(String(_GOLDEN)))
    assert_equal(reg.transport().call_count(), 0)
    print("  test_a_release_json_of_another_set_sends_nothing: PASS")


def main() raises:
    test_golden()
    test_other_bytes_other_hash()
    test_a_release_json_of_another_set_sends_nothing()
    print("test_publish_set_hash: ALL PASS")
