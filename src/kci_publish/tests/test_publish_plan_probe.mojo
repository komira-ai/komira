# =============================================================================
# src/kci_publish/tests/test_publish_plan_probe.mojo -- a dry run's probe of
#   an OIDC channel's publishing credential: under CI it mints the token and
#   discards it, writing nothing; a refused mint turns the dry run red.
# =============================================================================
#
# ROWS
#   (1) a dry run on the PUBLIC OIDC channel `gamma`, in environment
#       `gamma`, with the runner's handshake given: the OIDC transport is
#       asked exactly twice (the scripted ID token, then the mint; a third
#       call would find no answer and fail the run), the step SUCCEEDS with
#       `credential_probe` MINTED, the channel sees ZERO writes and every
#       channel read is anonymous (the minted token is never presented), and
#       the minted token's text is in no line and nowhere in the result;
#   (2) the mint answers 401 (no trusted publisher matches the job): FAILED,
#       exit 4, KCI-E-CREDENTIAL, zero writes;
#   (3) an ID token whose `environment` claim is `prod` while the stage runs
#       in `gamma`: FAILED (KCI-E-CREDENTIAL) naming both environments, and
#       no exchange (only the ID token is scripted: a mint would find no
#       answer and fail with another message);
#   (4) not under CI (neither handshake variable): NOT_UNDER_CI, exit 0, and
#       no OIDC request at all (the transport has no answer scripted);
#   (5) a broken handshake (the URL without the token): FAILED, naming the
#       missing variable; never NOT_UNDER_CI.
#
# Hermetic: TEST_TMPDIR, ScriptedChannel, ScriptedPkgTransport; no network.
# =============================================================================

from std.ffi import external_call
from std.os import getenv, makedirs
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_encoding import base64_url_encode_nopad
from komira_secret_store import SecretValue

from kci_contract import ERROR_CREDENTIAL, EXIT_FAILED, EXIT_OK, MemoryRecorder, render_result
from kci_contract import RunResult as KciRunResult
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
from kci_publish.release_fixture import EXAMPLE_HOST, ExampleRelease, example_channel_path, write_example_inputs


comptime _URL: String = "https://token.actions.example.invalid/_apis/idtoken?api-version=2.0"
comptime _REQ_TOKEN: String = "request-token-probe-0123456789abcdef"
comptime _MINTED: String = "pfx_minted_probe_0123456789abcdef"


def _root(tag: String) raises -> String:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        base = getenv("TMPDIR")
    if base.byte_length() == 0:
        raise Error("neither TEST_TMPDIR nor TMPDIR is set")
    var d = base + String("/ppp_") + tag + String("_") + String(Int(external_call["getpid", Int32]()))
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


def _id_token_answer(jwt: String) -> PkgResponse:
    var r = PkgResponse(200)
    r.with_body(bytes_of(String('{"count":1,"value":"') + jwt + String('"}')))
    return r^


def _raw(status: Int, body: String) -> PkgResponse:
    var r = PkgResponse(status)
    r.with_body(bytes_of(body))
    return r^


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _gamma_plan(tag: String) raises -> PublishRequest:
    var req = write_example_inputs(ExampleRelease(), _root(tag), String("gamma"), True)
    req.stage = String("publish-gamma")
    req.environment = String("gamma")
    return req^


def _channel() raises -> ScriptedChannel:
    var ch = ScriptedChannel(String(EXAMPLE_HOST), example_channel_path(String("gamma")), String("linux-64"))
    ch.put(String("linux-64"), String("komira_alpha-0.9.0-h00000000_1.conda"), _bytes(String("old a")))
    return ch^


def _handshake() raises -> ActionsOidcEnv:
    return ActionsOidcEnv.given(String(_URL), SecretValue.from_string(String(_REQ_TOKEN)))


struct _Ran(Movable):
    var rep: PublishReport
    var result: KciRunResult
    var reg: RegistrySet[ScriptedChannel, PublishCredential]

    def __init__(
        out self, var rep: PublishReport, var result: KciRunResult, var reg: RegistrySet[ScriptedChannel, PublishCredential]
    ):
        self.rep = rep^
        self.result = result^
        self.reg = reg^


def _run(req: PublishRequest, var oidc: ScriptedPkgTransport, var actions: ActionsOidcEnv) raises -> _Ran:
    var reg = RegistrySet[ScriptedChannel, PublishCredential](_channel(), PublishCredential())
    var store = NoSecretStore()
    var sl = NoWaitSleeper()
    var result = KciRunResult(String("run"), String("publish-gamma"))
    var rec = MemoryRecorder()
    var rep = publish_flow(req, result, rec, reg, oidc^, actions^, store, RunOptions(2, 0, 2, 0, 0, 1, 0), sl)
    return _Ran(rep^, result^, reg^)


def _lines(r: PublishReport) -> String:
    return String("\n").join(r.lines)


def test_a_dry_run_under_ci_mints_and_discards() raises:
    var t = ScriptedPkgTransport()
    t.queue(_id_token_answer(_jwt(String("gamma"))))
    t.queue(_raw(200, String(_MINTED)))
    var ran = _run(_gamma_plan(String("minted")), t^, _handshake())
    assert_equal(ran.rep.exit_code(), EXIT_OK, _lines(ran.rep))
    assert_equal(ran.rep.credential_probe, String("MINTED"))
    assert_equal(ran.result.steps[0].credential_probe, String("MINTED"))
    assert_equal(ran.reg.transport().write_count(), 0)
    assert_true(ran.reg.transport().call_count() > 0, String("a dry run reads"))
    for i in range(ran.reg.transport().call_count()):
        assert_equal(ran.reg.transport().call(i).header_value(String("Authorization")), String(""))
    assert_false(ran.rep.has_line_containing(String(_MINTED)))
    var text = render_result(ran.result.finish_record(ran.rep.outcome(), 1, ran.rep.retry()))
    assert_true(text.find(String(_MINTED)) < 0, text)
    assert_true(text.find(String('"credential_probe":"MINTED"')) >= 0, text)


def test_a_refused_mint_turns_the_dry_run_red() raises:
    var t = ScriptedPkgTransport()
    t.queue(_id_token_answer(_jwt(String("gamma"))))
    t.queue(_raw(401, String("Failed to find OIDC publisher: GitHub publisher not found")))
    var ran = _run(_gamma_plan(String("refused")), t^, _handshake())
    assert_equal(ran.rep.exit_code(), EXIT_FAILED, _lines(ran.rep))
    assert_equal(ran.rep.error_id, String(ERROR_CREDENTIAL))
    assert_true(ran.rep.has_line_containing(String("token exchange answered HTTP 401")), _lines(ran.rep))
    assert_equal(ran.reg.transport().write_count(), 0)


def test_a_token_from_another_environment_is_refused_before_the_exchange() raises:
    var t = ScriptedPkgTransport()
    t.queue(_id_token_answer(_jwt(String("prod"))))
    var ran = _run(_gamma_plan(String("otherenv")), t^, _handshake())
    assert_equal(ran.rep.exit_code(), EXIT_FAILED, _lines(ran.rep))
    assert_equal(ran.rep.error_id, String(ERROR_CREDENTIAL))
    assert_true(
        ran.rep.has_line_containing(String("the job's environment is 'prod', not the required 'gamma'")),
        _lines(ran.rep),
    )
    assert_equal(ran.reg.transport().write_count(), 0)


def test_not_under_ci_is_recorded_never_a_mint() raises:
    var ran = _run(_gamma_plan(String("noci")), ScriptedPkgTransport(), ActionsOidcEnv.absent())
    assert_equal(ran.rep.exit_code(), EXIT_OK, _lines(ran.rep))
    assert_equal(ran.rep.credential_probe, String("NOT_UNDER_CI"))
    assert_equal(ran.result.steps[0].credential_probe, String("NOT_UNDER_CI"))


def test_a_broken_handshake_is_a_failure_not_not_under_ci() raises:
    var half = ActionsOidcEnv.given(String(_URL), SecretValue(Span(List[UInt8]())))
    var ran = _run(_gamma_plan(String("half")), ScriptedPkgTransport(), half^)
    assert_equal(ran.rep.exit_code(), EXIT_FAILED, _lines(ran.rep))
    assert_equal(ran.rep.error_id, String(ERROR_CREDENTIAL))
    assert_true(ran.rep.has_line_containing(String("ACTIONS_ID_TOKEN_REQUEST_TOKEN not set")), _lines(ran.rep))
    assert_equal(ran.rep.credential_probe, String(""))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
