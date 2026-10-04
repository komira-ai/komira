# =============================================================================
# src/kci_publish/tests/test_publish_flow.mojo -- the whole step: the dry
#   run reads and never writes, the credential is the channel's own, an OIDC
#   channel publishes only from its stage, and the RUNNING record comes
#   before the first request.
# =============================================================================
#
# ROWS
#   (1) dry run, PUBLIC channel with an API token: steps 0 and 1 only --
#       reads, ZERO write requests, every read anonymous, the secret store
#       never asked (NoSecretStore would refuse), SUCCEEDED (exit 0), WOULD
#       UPLOAD lines and WOULD_UPLOAD artifact rows;
#   (2) dry run, PUBLIC OIDC channel: no OIDC exchange (the OIDC transport
#       has no scripted answer and the job environment is unset: either
#       would fail the run), exit 0;
#   (3) dry run, PRIVATE OIDC-only channel: REFUSED (exit 3,
#       KCI-E-CREDENTIAL), naming why, with ZERO channel requests and no
#       RUNNING record;
#   (4) dry run, PRIVATE API-token channel: the token is resolved by secret
#       name and carried on the reads; still ZERO writes;
#   (5) an OIDC channel whose push identity names environment `prod`, run
#       from stage `build`: REFUSED (KCI-E-STAGE-ENVIRONMENT), zero requests;
#       an API-token channel has no such binding and runs from any stage;
#   (6) an API-token channel and a store that cannot resolve the name:
#       FAILED (exit 4, KCI-E-CREDENTIAL), naming the secret, and ZERO
#       writes (the token is resolved before the first write), after the
#       RUNNING record;
#   (7) a recorder that cannot record: FAILED (KCI-E-RESULT-FILE) with zero
#       requests and the secret store never asked.
#
# Hermetic: TEST_TMPDIR, ScriptedChannel, ScriptedPkgTransport (no script),
# StaticSecretStore / NoSecretStore; no network.
# =============================================================================

from std.ffi import external_call
from std.os import makedirs

from komira_libc.posix import _read_env
from std.testing import assert_equal, assert_false, assert_true

from komira_secret_store import SecretStore, StaticSecretStore

from kci_contract import (
    ARTIFACT_WOULD_UPLOAD,
    ERROR_CREDENTIAL,
    ERROR_RESULT_FILE,
    ERROR_STAGE_ENVIRONMENT,
    EXIT_FAILED,
    EXIT_OK,
    EXIT_REFUSED,
    STATUS_RUNNING,
    MemoryRecorder,
)
from kci_contract import RunResult as KciRunResult
from kci_pkg_upload import RegistrySet, ScriptedPkgTransport
from kci_publish import (
    NoWaitSleeper,
    NoSecretStore,
    PublishCredential,
    PublishReport,
    PublishRequest,
    RunOptions,
    ScriptedChannel,
    publish_flow,
)
from kci_publish.release_fixture import (
    EXAMPLE_HOST,
    EXAMPLE_TOKEN_SECRET,
    ExampleRelease,
    write_example_inputs,
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


def _flags(tag: String, channel: String, plan: Bool) raises -> PublishRequest:
    return write_example_inputs(ExampleRelease(), _root(tag), channel, plan)


struct _Rec(Movable):
    """The result and the recorder one step wrote into."""

    var result: KciRunResult
    var rec: MemoryRecorder

    def __init__(out self):
        self.result = KciRunResult(String("run"), String("publish"))
        self.rec = MemoryRecorder()


def _flow[S: SecretStore](
    f: PublishRequest, mut reg: RegistrySet[ScriptedChannel, PublishCredential], mut store: S, mut got: _Rec
) -> PublishReport:
    var sl = NoWaitSleeper()
    return publish_flow(f, got.result, got.rec, reg, ScriptedPkgTransport(), store, _opts(), sl)


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
    var got = _Rec()
    var rep = _flow(f, reg, store, got)
    assert_equal(rep.exit_code(), EXIT_OK, String("\n").join(rep.lines))
    assert_equal(rep.outcome(), String("SUCCEEDED"))
    assert_true(rep.has_line_containing(String("DRY RUN: nothing was uploaded; 3 file(s) would be")))
    assert_true(rep.has_line_containing(String("WOULD UPLOAD linux-64/komira-1.0.0-h01234567_3.conda")))
    assert_true(reg.transport().call_count() > 0, String("a dry run reads"))
    assert_equal(reg.transport().write_count(), 0)
    _all_anonymous(reg)
    assert_true(got.result.plan)
    assert_equal(len(got.result.artifacts), 3)
    for i in range(3):
        assert_equal(got.result.artifacts[i].effect, String(ARTIFACT_WOULD_UPLOAD))
    print("  test_dry_run_public_api_token: PASS")


def test_dry_run_public_oidc_mints_nothing() raises:
    var f = _flags(String("dry_oidc"), String("example-oidc"), True)
    var reg = RegistrySet[ScriptedChannel, PublishCredential](_channel(String("example-oidc")), PublishCredential())
    var store = NoSecretStore()
    var got = _Rec()
    var rep = _flow(f, reg, store, got)
    assert_equal(rep.exit_code(), EXIT_OK, String("\n").join(rep.lines))
    assert_equal(reg.transport().write_count(), 0)
    _all_anonymous(reg)
    print("  test_dry_run_public_oidc_mints_nothing: PASS")


def test_dry_run_private_oidc_is_refused() raises:
    var f = _flags(String("dry_poidc"), String("example-oidc-private"), True)
    var reg = RegistrySet[ScriptedChannel, PublishCredential](_channel(String("example-oidc-private")), PublishCredential())
    var store = NoSecretStore()
    var got = _Rec()
    var rep = _flow(f, reg, store, got)
    assert_equal(rep.exit_code(), EXIT_REFUSED)
    assert_equal(rep.error_id, String(ERROR_CREDENTIAL))
    assert_true(rep.has_line_containing(String("is PRIVATE and publishes with OIDC only")))
    assert_equal(reg.transport().call_count(), 0)
    assert_equal(len(got.rec.records), 0)
    print("  test_dry_run_private_oidc_is_refused: PASS")


def test_dry_run_private_api_token_reads_with_the_token() raises:
    var f = _flags(String("dry_priv"), String("example-private"), True)
    var reg = RegistrySet[ScriptedChannel, PublishCredential](_channel(String("example-private")), PublishCredential())
    var store = StaticSecretStore()
    store.put(String(EXAMPLE_TOKEN_SECRET), String(_TOKEN))
    var got = _Rec()
    var rep = _flow(f, reg, store, got)
    assert_equal(rep.exit_code(), EXIT_OK, String("\n").join(rep.lines))
    assert_equal(reg.transport().write_count(), 0)
    assert_true(reg.transport().call_count() > 0)
    for i in range(reg.transport().call_count()):
        assert_equal(reg.transport().call(i).header_value(String("Authorization")), String("Bearer ") + String(_TOKEN))
    assert_false(rep.has_line_containing(String(_TOKEN)))
    print("  test_dry_run_private_api_token_reads_with_the_token: PASS")


def test_an_oidc_channel_publishes_only_from_its_stage() raises:
    # the push identity names environment `prod`; this step runs in `build`
    var f = _flags(String("stage"), String("example-oidc"), False)
    f.stage = String("build")
    var reg = RegistrySet[ScriptedChannel, PublishCredential](_channel(String("example-oidc")), PublishCredential())
    var store = NoSecretStore()
    var got = _Rec()
    var rep = _flow(f, reg, store, got)
    assert_equal(rep.exit_code(), EXIT_REFUSED, String("\n").join(rep.lines))
    assert_equal(rep.error_id, String(ERROR_STAGE_ENVIRONMENT))
    assert_true(rep.has_line_containing(String("names environment 'prod'; this PUBLISH step runs in stage 'build'")))
    assert_equal(reg.transport().call_count(), 0)
    assert_equal(len(got.rec.records), 0)
    assert_equal(got.result.error.id, String(ERROR_STAGE_ENVIRONMENT))
    # an API-token channel names no environment: any stage may run it
    var g = _flags(String("stage_tok"), String("example-stable"), True)
    g.stage = String("build")
    var reg2 = RegistrySet[ScriptedChannel, PublishCredential](_channel(String("example-stable")), PublishCredential())
    var got2 = _Rec()
    var rep2 = _flow(g, reg2, store, got2)
    assert_equal(rep2.exit_code(), EXIT_OK, String("\n").join(rep2.lines))
    print("  test_an_oidc_channel_publishes_only_from_its_stage: PASS")


def test_an_unresolvable_secret_fails_before_any_write() raises:
    var f = _flags(String("nosecret"), String("example-stable"), False)
    var reg = RegistrySet[ScriptedChannel, PublishCredential](_channel(String("example-stable")), PublishCredential())
    var store = NoSecretStore()
    var got = _Rec()
    var rep = _flow(f, reg, store, got)
    assert_equal(rep.exit_code(), EXIT_FAILED, String("\n").join(rep.lines))
    assert_equal(rep.error_id, String(ERROR_CREDENTIAL))
    assert_true(rep.has_line_containing(String(EXAMPLE_TOKEN_SECRET)))
    assert_equal(reg.transport().write_count(), 0)
    # the RUNNING record came first: resolving the credential is an effect
    assert_equal(len(got.rec.statuses), 1)
    assert_equal(got.rec.statuses[0], String(STATUS_RUNNING))
    print("  test_an_unresolvable_secret_fails_before_any_write: PASS")


def test_a_recorder_that_cannot_record_sends_nothing() raises:
    var f = _flags(String("norec"), String("example-private"), False)
    var reg = RegistrySet[ScriptedChannel, PublishCredential](_channel(String("example-private")), PublishCredential())
    var store = NoSecretStore()  # would refuse loudly if it were asked
    var got = _Rec()
    got.rec.fail_begin = True
    var rep = _flow(f, reg, store, got)
    assert_equal(rep.exit_code(), EXIT_FAILED, String("\n").join(rep.lines))
    assert_equal(rep.error_id, String(ERROR_RESULT_FILE))
    assert_false(rep.has_line_containing(String(EXAMPLE_TOKEN_SECRET)))
    assert_equal(reg.transport().call_count(), 0)
    print("  test_a_recorder_that_cannot_record_sends_nothing: PASS")


def main() raises:
    test_dry_run_public_api_token()
    test_dry_run_public_oidc_mints_nothing()
    test_dry_run_private_oidc_is_refused()
    test_dry_run_private_api_token_reads_with_the_token()
    test_an_oidc_channel_publishes_only_from_its_stage()
    test_an_unresolvable_secret_fails_before_any_write()
    test_a_recorder_that_cannot_record_sends_nothing()
    print("test_publish_flow: ALL PASS")
