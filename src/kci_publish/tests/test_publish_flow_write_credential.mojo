# =============================================================================
# src/kci_publish/tests/test_publish_flow_write_credential.mojo -- a PUBLISH
#   step that writes: which credential each request carries, by channel
#   visibility and credential kind.
# =============================================================================
#
# ROWS
#   (1) a PUBLIC OIDC channel (`gamma`, stage environment `gamma`): step 1's
#       reads are anonymous; the token is minted ONCE, at the first write
#       (the ID token, then the exchange: the OIDC transport holds exactly
#       those two answers), and every upload carries it; SUCCEEDED;
#   (2) a PRIVATE OIDC channel: the token is minted once BEFORE step 1, and
#       every request, reads and uploads, carries it; SUCCEEDED;
#   (3) a PRIVATE API-token channel: the token is resolved by its secret
#       name, and every request, reads and uploads, carries it; no line
#       prints it; SUCCEEDED.
#
# Hermetic: TEST_TMPDIR, ScriptedChannel, ScriptedPkgTransport,
# StaticSecretStore; no network.
# =============================================================================

from std.ffi import external_call
from std.os import makedirs

from komira_libc.posix import _read_env
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_encoding import base64_url_encode_nopad
from komira_http_core.codec.types import HTTP_METHOD_GET, HTTP_METHOD_POST
from komira_secret_store import SecretStore, SecretValue, StaticSecretStore

from kci_api import EXIT_OK, MemoryRecorder
from kci_api import RunResult as KciRunResult
from kci_pkg_upload import RegistrySet, ScriptedPkgTransport
from kci_pkg_upload.transport import PkgResponse
from kci_pkg_upload.wire import bytes_of
from kci_publish import (
    ActionsOidcEnv,
    NoSecretStore,
    NoWaitSleeper,
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
    example_channel_path,
    write_example_inputs,
)


comptime _URL: String = "https://token.actions.example.invalid/_apis/idtoken?api-version=2.0"
comptime _REQ_TOKEN: String = "request-token-write-0123456789abcdef"
comptime _MINTED: String = "pfx_minted_write_0123456789abcdef"
comptime _TOKEN: String = "pfx-write-secret-0123456789abcdef"


def _root(tag: String) raises -> String:
    var base = _read_env("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = _read_env("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/pwc_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
    makedirs(d, exist_ok=True)
    return d^


def _jwt(environment: String) -> String:
    var header = base64_url_encode_nopad(String('{"alg":"RS256","typ":"JWT"}').as_bytes())
    var payload = (
        String('{"repository":"example/release",')
        + String('"job_workflow_ref":"example/release/.github/workflows/kci.yml@refs/heads/main",')
        + String('"ref":"refs/heads/main","environment":"') + environment + String('"}')
    )
    return header + String(".") + base64_url_encode_nopad(payload.as_bytes()) + String(".c2lnbmF0dXJlLW5vdC1jaGVja2Vk")


def _answer(status: Int, body: String) -> PkgResponse:
    var r = PkgResponse(status)
    r.with_body(bytes_of(body))
    return r^


def _oidc(environment: String) -> ScriptedPkgTransport:
    """The ID token for `environment`, then the mint: two answers, so a
    second mint would find none and fail the run."""
    var t = ScriptedPkgTransport()
    t.queue(_answer(200, String('{"count":1,"value":"') + _jwt(environment) + String('"}')))
    t.queue(_answer(200, String(_MINTED)))
    return t^


def _handshake() raises -> ActionsOidcEnv:
    return ActionsOidcEnv.given(String(_URL), SecretValue.from_string(String(_REQ_TOKEN)))


def _run[S: SecretStore](
    req: PublishRequest,
    channel: String,
    var oidc: ScriptedPkgTransport,
    var actions: ActionsOidcEnv,
    mut store: S,
) raises -> RegistrySet[ScriptedChannel, PublishCredential]:
    var ch = ScriptedChannel(String(EXAMPLE_HOST), example_channel_path(channel), String("linux-64"))
    var reg = RegistrySet[ScriptedChannel, PublishCredential](ch^, PublishCredential())
    var sl = NoWaitSleeper()
    var result = KciRunResult(String("run"), req.stage)
    var rec = MemoryRecorder()
    var rep = publish_flow(req, result, rec, reg, oidc^, actions^, store, RunOptions(2, 0, 2, 0, 0, 1, 0), sl)
    var lines = String("\n").join(rep.lines)
    assert_equal(rep.outcome(), String("SUCCEEDED"), lines)
    assert_equal(rep.exit_code(), EXIT_OK, lines)
    assert_equal(len(rec.records), 1, String("one RUNNING record"))
    assert_false(rep.has_line_containing(String(_MINTED)), lines)
    assert_false(rep.has_line_containing(String(_TOKEN)), lines)
    return reg^


def _uploads_carry(reg: RegistrySet[ScriptedChannel, PublishCredential], token: String) raises:
    var posts = 0
    for i in range(reg.transport().call_count()):
        var c = reg.transport().call(i)
        if c.method == HTTP_METHOD_POST:
            posts += 1
            assert_equal(c.header_value(String("Authorization")), String("Bearer ") + token)
    assert_equal(posts, 3, String("one upload per file"))


def _reads_carry(
    reg: RegistrySet[ScriptedChannel, PublishCredential], authorization: String, before_first_write: Bool = False
) raises:
    """Every download carries `authorization`; with `before_first_write`,
    only those of step 1 (once armed, every request carries the write
    value: upload.mojo's file header)."""
    var gets = 0
    for i in range(reg.transport().call_count()):
        var c = reg.transport().call(i)
        if before_first_write and c.method == HTTP_METHOD_POST:
            break
        if c.method == HTTP_METHOD_GET:
            gets += 1
            assert_equal(c.header_value(String("Authorization")), authorization, c.path)
    assert_true(gets > 0, String("the step reads"))


def test_a_public_oidc_channel_reads_anonymously_and_writes_with_the_minted_token() raises:
    var req = write_example_inputs(ExampleRelease(), _root(String("pub_oidc")), String("gamma"), False)
    req.stage = String("publish-gamma")
    req.environment = String("gamma")
    var store = NoSecretStore()
    var reg = _run(req, String("gamma"), _oidc(String("gamma")), _handshake(), store)
    _reads_carry(reg, String(""), True)
    _uploads_carry(reg, String(_MINTED))


def test_a_private_oidc_channel_reads_and_writes_with_the_minted_token() raises:
    var req = write_example_inputs(ExampleRelease(), _root(String("priv_oidc")), String("example-oidc-private"), False)
    var store = NoSecretStore()
    var reg = _run(req, String("example-oidc-private"), _oidc(String("prod")), _handshake(), store)
    _reads_carry(reg, String("Bearer ") + String(_MINTED))
    _uploads_carry(reg, String(_MINTED))


def test_a_private_api_token_channel_reads_and_writes_with_the_token() raises:
    var req = write_example_inputs(ExampleRelease(), _root(String("priv_tok")), String("example-private"), False)
    var store = StaticSecretStore()
    store.put(String(EXAMPLE_TOKEN_SECRET), String(_TOKEN))
    var reg = _run(req, String("example-private"), ScriptedPkgTransport(), ActionsOidcEnv.absent(), store)
    _reads_carry(reg, String("Bearer ") + String(_TOKEN))
    _uploads_carry(reg, String(_TOKEN))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
