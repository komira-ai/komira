# =============================================================================
# src/kci_publish/tests/test_publish_flow.mojo -- the whole verb: the dry run
#   reads and never writes, and the credential is the channel's own.
# =============================================================================
#
# ROWS
#   (1) dry run, PUBLIC channel with an API token: steps 0 and 1 only --
#       reads, ZERO write requests, every read anonymous, the secret store
#       never asked (the standalone NoSecretStore would refuse), exit 0,
#       WOULD UPLOAD lines;
#   (2) dry run, PUBLIC OIDC channel: no OIDC exchange (the OIDC transport
#       has no scripted answer and the job environment is unset: either
#       would fail the run), exit 0;
#   (3) dry run, PRIVATE OIDC-only channel: refused (3), naming why, with
#       ZERO channel requests;
#   (4) dry run, PRIVATE API-token channel: the token is resolved by secret
#       name and carried on the reads; still ZERO writes;
#   (5) --require-environment on a channel that is not OIDC: 3, zero
#       requests;
#   (6) an API-token channel and a store that cannot resolve the name: 4,
#       naming the secret, and ZERO writes (the token is resolved before the
#       first write).
#
# Hermetic: TEST_TMPDIR, ScriptedChannel, ScriptedPkgTransport (no script),
# StaticSecretStore / NoSecretStore; no network.
# =============================================================================

from std.ffi import external_call
from std.os import makedirs

from komira_libc.posix import _read_env
from std.testing import assert_equal, assert_false, assert_true

from komira_secret_store import StaticSecretStore

from kci_pkg_upload import RegistrySet, ScriptedPkgTransport
from kci_publish import (
    NoWaitSleeper,
    EXIT_FAILED,
    EXIT_PUBLISHED,
    EXIT_REFUSED,
    NoSecretStore,
    PublishCredential,
    PublishFlags,
    PublishReport,
    RunOptions,
    ScriptedChannel,
    publish_flow,
)
from kci_publish.release_fixture import (
    EXAMPLE_CHANNELS,
    EXAMPLE_HOST,
    EXAMPLE_TOKEN_SECRET,
    ExampleRelease,
    write_text_file,
)


comptime _TOKEN: String = "pfx-flow-secret-0123456789abcdef"


def _root(tag: String) raises -> String:
    var base = _read_env("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = _read_env("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/pfl_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d, exist_ok=True)
    return d^


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _flags(tag: String, channel: String, dry_run: Bool) raises -> PublishFlags:
    var r = ExampleRelease()
    var d = _root(tag)
    r.write(d + String("/release"))
    write_text_file(d + String("/decls.textproto"), r.declarations_text())
    write_text_file(d + String("/channels.textproto"), String(EXAMPLE_CHANNELS))
    write_text_file(d + String("/rv.txt"), r.release_version_text())
    var f = PublishFlags()
    f.declarations_file = d + String("/decls.textproto")
    f.artifacts_dir = d + String("/release")
    f.channels_file = d + String("/channels.textproto")
    f.channel = channel.copy()
    f.release_version_file = d + String("/rv.txt")
    f.expect_set_hash = r.set_hash(d + String("/release"))
    f.report_file = d + String("/report.json")
    f.dry_run = dry_run
    return f^


def _channel(name: String) -> ScriptedChannel:
    var ch = ScriptedChannel(String(EXAMPLE_HOST), name.copy(), String("linux-64"))
    ch.put(String("linux-64"), String("komira_alpha-0.9.0-h00000000_1.conda"), _bytes(String("old a")))
    ch.put(String("linux-64"), String("komira_beta-0.9.0-h00000000_1.conda"), _bytes(String("old b")))
    ch.put(String("linux-64"), String("komira-0.9.0-h00000000_1.conda"), _bytes(String("old m")))
    return ch^


def _opts() -> RunOptions:
    return RunOptions(2, 0, 2, 0, 0, 1, 0)


def _all_anonymous(reg: RegistrySet[ScriptedChannel, PublishCredential]) raises:
    for i in range(reg.transport().call_count()):
        assert_equal(reg.transport().call(i).header_value(String("Authorization")), String(""))


def test_dry_run_public_api_token() raises:
    var f = _flags(String("dry_pub"), String("example-stable"), True)
    var reg = RegistrySet[ScriptedChannel, PublishCredential](_channel(String("example-stable")), PublishCredential())
    var store = NoSecretStore()
    var sl = NoWaitSleeper()
    var rep = publish_flow(f, reg, ScriptedPkgTransport(), store, _opts(), sl)
    assert_equal(rep.exit_code, EXIT_PUBLISHED, String("\n").join(rep.lines))
    assert_true(rep.has_line_containing(String("DRY RUN: nothing was uploaded; 3 file(s) would be")))
    assert_true(rep.has_line_containing(String("WOULD UPLOAD linux-64/komira-1.0.0-h01234567_3.conda")))
    assert_true(reg.transport().call_count() > 0, String("a dry run reads"))
    assert_equal(reg.transport().write_count(), 0)
    _all_anonymous(reg)
    print("  test_dry_run_public_api_token: PASS")


def test_dry_run_public_oidc_mints_nothing() raises:
    var f = _flags(String("dry_oidc"), String("example-oidc"), True)
    var reg = RegistrySet[ScriptedChannel, PublishCredential](_channel(String("example-oidc")), PublishCredential())
    var store = NoSecretStore()
    var sl = NoWaitSleeper()
    var rep = publish_flow(f, reg, ScriptedPkgTransport(), store, _opts(), sl)
    assert_equal(rep.exit_code, EXIT_PUBLISHED, String("\n").join(rep.lines))
    assert_equal(reg.transport().write_count(), 0)
    _all_anonymous(reg)
    print("  test_dry_run_public_oidc_mints_nothing: PASS")


def test_dry_run_private_oidc_is_refused() raises:
    var f = _flags(String("dry_poidc"), String("example-oidc-private"), True)
    var reg = RegistrySet[ScriptedChannel, PublishCredential](_channel(String("example-oidc-private")), PublishCredential())
    var store = NoSecretStore()
    var sl = NoWaitSleeper()
    var rep = publish_flow(f, reg, ScriptedPkgTransport(), store, _opts(), sl)
    assert_equal(rep.exit_code, EXIT_REFUSED)
    assert_true(rep.has_line_containing(String("is PRIVATE and publishes with OIDC only")))
    assert_equal(reg.transport().call_count(), 0)
    print("  test_dry_run_private_oidc_is_refused: PASS")


def test_dry_run_private_api_token_reads_with_the_token() raises:
    var f = _flags(String("dry_priv"), String("example-private"), True)
    var reg = RegistrySet[ScriptedChannel, PublishCredential](_channel(String("example-private")), PublishCredential())
    var store = StaticSecretStore()
    store.put(String(EXAMPLE_TOKEN_SECRET), String(_TOKEN))
    var sl = NoWaitSleeper()
    var rep = publish_flow(f, reg, ScriptedPkgTransport(), store, _opts(), sl)
    assert_equal(rep.exit_code, EXIT_PUBLISHED, String("\n").join(rep.lines))
    assert_equal(reg.transport().write_count(), 0)
    assert_true(reg.transport().call_count() > 0)
    for i in range(reg.transport().call_count()):
        assert_equal(reg.transport().call(i).header_value(String("Authorization")), String("Bearer ") + String(_TOKEN))
    assert_false(rep.has_line_containing(String(_TOKEN)))
    print("  test_dry_run_private_api_token_reads_with_the_token: PASS")


def test_require_environment_needs_an_oidc_channel() raises:
    var f = _flags(String("reqenv"), String("example-stable"), False)
    f.require_environment = String("release")
    var reg = RegistrySet[ScriptedChannel, PublishCredential](_channel(String("example-stable")), PublishCredential())
    var store = NoSecretStore()
    var sl = NoWaitSleeper()
    var rep = publish_flow(f, reg, ScriptedPkgTransport(), store, _opts(), sl)
    assert_equal(rep.exit_code, EXIT_REFUSED)
    assert_true(rep.has_line_containing(String("does not publish with OIDC trusted publishing")))
    assert_equal(reg.transport().call_count(), 0)
    print("  test_require_environment_needs_an_oidc_channel: PASS")


def test_an_unresolvable_secret_fails_before_any_write() raises:
    var f = _flags(String("nosecret"), String("example-stable"), False)
    var reg = RegistrySet[ScriptedChannel, PublishCredential](_channel(String("example-stable")), PublishCredential())
    var store = NoSecretStore()
    var sl = NoWaitSleeper()
    var rep = publish_flow(f, reg, ScriptedPkgTransport(), store, _opts(), sl)
    assert_equal(rep.exit_code, EXIT_FAILED, String("\n").join(rep.lines))
    assert_true(rep.has_line_containing(String(EXAMPLE_TOKEN_SECRET)))
    assert_equal(reg.transport().write_count(), 0)
    print("  test_an_unresolvable_secret_fails_before_any_write: PASS")


def main() raises:
    test_dry_run_public_api_token()
    test_dry_run_public_oidc_mints_nothing()
    test_dry_run_private_oidc_is_refused()
    test_dry_run_private_api_token_reads_with_the_token()
    test_require_environment_needs_an_oidc_channel()
    test_an_unresolvable_secret_fails_before_any_write()
    print("test_publish_flow: ALL PASS")
