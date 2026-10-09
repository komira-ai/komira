# =============================================================================
# kci_cloud_gcp/tests/test_gcp_credentials.mojo
# =============================================================================
#
# The credential choice of a deploy (credentials.mojo), over komira_gcp_core's
# MapEnv and MapFiles (no process environment, no file system, no network):
#   * GOOGLE_APPLICATION_CREDENTIALS unset, or empty, is REFUSED: no fallback;
#   * an unreadable file is REFUSED, naming the variable and not the path;
#   * a service_account file and an external_account file are each told
#     apart by their `type`;
#   * an authorized_user file (a person's own login) and any other type are
#     REFUSED, the type named only when it is a plain word (an oversized or
#     binary type is never repeated);
#   * a service_account file REACHES komira_gcp_core's reader: one whose
#     private key is not a key is refused in the core's own words, which only
#     the core's service-account reader writes;
#   * an authorized_user file never reaches the core: with an https token
#     URI the core would accept it, so its refusal can only be the chooser's;
#   * an external_account file is not handed to the core either: it REACHES
#     komira_gcp_wif's reader. One missing its audience is refused in wif's
#     own words, and a whole one fetches its token on the wire: the
#     file-sourced subject token is exchanged at the file's token URL (an IP
#     literal here, served by a ScriptedConnector), and the source answers
#     the federated token STS returned;
#   * a service_account file never reaches wif.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_true

from komira_gcp_core import FixedWallClock, MapEnv, MapFiles
from komira_http_client.client import HttpClient, HttpClientConfig
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_retry import ManualClock

from kci_cloud_gcp import deploy_credentials_type, external_account_token_source, service_account_token_source


comptime _VAR = "GOOGLE_APPLICATION_CREDENTIALS"
comptime _PATH = "/run/secrets/deploy.json"


def _env(path: String) -> MapEnv:
    var env = MapEnv()
    env.set(String(_VAR), path)
    return env^


def _files(text: String) -> MapFiles:
    var f = MapFiles()
    f.put(String(_PATH), text)
    return f^


def _type_or_refusal(path: String, text: String) -> String:
    var env = _env(path)
    var files = _files(text)
    try:
        return deploy_credentials_type(env, files)
    except e:
        return String(e)


def _plain() raises -> ScriptedConnector:
    return ScriptedConnector()


def _source_refusal(text: String) -> String:
    var env = _env(String(_PATH))
    var files = _files(text)
    try:
        _ = service_account_token_source(
            env, files, HttpClientConfig.defaults(), _plain, _plain, FixedWallClock(1_790_000_000), ManualClock()
        )
    except e:
        return String(e)
    return String("(accepted)")


comptime _SA = '{"type":"service_account","client_email":"deployer@demo-project.example","private_key":"not a key","token_uri":"https://oauth2.googleapis.com/token"}'
comptime _EXTERNAL = '{"type":"external_account","audience":"//iam.googleapis.com/projects/1/locations/global/workloadIdentityPools/p/providers/q","subject_token_type":"urn:ietf:params:oauth:token-type:jwt","token_url":"https://sts.googleapis.com/v1/token","credential_source":{"file":"/run/oidc"}}'
comptime _USER = '{"type":"authorized_user","client_id":"1","client_secret":"s","refresh_token":"r","token_uri":"https://oauth2.googleapis.com/token"}'


def test_the_variable_is_required() raises:
    var empty = MapEnv()
    var files = _files(String(_SA))
    var refused = String("")
    try:
        _ = deploy_credentials_type(empty, files)
    except e:
        refused = String(e)
    assert_true(refused.startswith("kci: REFUSED: a GCP deploy needs GOOGLE_APPLICATION_CREDENTIALS"), refused)
    assert_true(_type_or_refusal(String(""), String(_SA)).find("needs GOOGLE_APPLICATION_CREDENTIALS") >= 0, "empty is unset")


def test_an_unreadable_file_is_refused_without_its_path() raises:
    var text = _type_or_refusal(String("/elsewhere/creds.json"), String(_SA))
    assert_true(text.find("cannot be read") >= 0, text)
    assert_true(text.find("/elsewhere") < 0, "the path is not repeated")


def test_the_type_chooses_the_reader() raises:
    assert_equal(_type_or_refusal(String(_PATH), String(_SA)), "service_account")
    assert_equal(_type_or_refusal(String(_PATH), String(_EXTERNAL)), "external_account")
    var user = _type_or_refusal(String(_PATH), String(_USER))
    assert_true(user.startswith("kci: REFUSED:") and user.find("authorized_user") >= 0, user)
    var other = _type_or_refusal(String(_PATH), String('{"type":"impersonated_service_account"}'))
    assert_true(other.startswith("kci: REFUSED:") and other.find("impersonated_service_account") >= 0, other)


def test_a_type_that_is_not_a_word_is_not_repeated() raises:
    var long_type = String("")
    for _ in range(100):
        long_type += String("x")
    var oversized = _type_or_refusal(String(_PATH), String('{"type":"') + long_type + String('"}'))
    assert_true(oversized.find("not a credentials type word") >= 0, oversized)
    assert_true(oversized.find("xxxxxxxx") < 0, "an oversized type is not repeated")
    var binary = _type_or_refusal(String(_PATH), String('{"type":"bearer \\u0001ya29.SECRET"}'))
    assert_true(binary.find("not a credentials type word") >= 0, binary)
    assert_true(binary.find("SECRET") < 0, "a type holding bytes outside [a-z_] is not repeated")


def test_a_service_account_file_reaches_the_core_reader() raises:
    var text = _source_refusal(String(_SA))
    assert_true(text.find("is not an RSA PKCS#8 PEM key") >= 0, text)


def test_an_authorized_user_file_never_reaches_the_core() raises:
    var text = _source_refusal(String(_USER))
    assert_true(text.startswith("kci: REFUSED:") and text.find("authorized_user") >= 0, text)


def test_an_external_account_file_is_not_the_core_s() raises:
    var text = _source_refusal(String(_EXTERNAL))
    assert_true(text.find("komira_gcp_wif reads") >= 0, text)


comptime _OIDC_FILE = "/run/ci/oidc"
comptime _OIDC = "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJjaSJ9.OIDC-FAKE"
comptime _FEDERATED = "ya29.FEDERATED-FAKE"


def _external(with_audience: Bool) -> String:
    var out = String('{"type":"external_account",')
    if with_audience:
        out += String('"audience":"//iam.googleapis.com/projects/1/locations/global/workloadIdentityPools/p/providers/q",')
    out += String('"subject_token_type":"urn:ietf:params:oauth:token-type:jwt",')
    out += String('"token_url":"https://127.0.0.1/v1/token",')
    out += String('"credential_source":{"file":"') + _OIDC_FILE + String('"}}')
    return out^


def _sts_answer() -> List[UInt8]:
    var body = (
        String('{"access_token":"') + _FEDERATED
        + '","issued_token_type":"urn:ietf:params:oauth:token-type:access_token","token_type":"Bearer","expires_in":3599}'
    )
    var http = String("HTTP/1.1 200 OK\r\nContent-Length: ") + String(body.byte_length()) + "\r\nConnection: close\r\n\r\n" + body
    var out = List[UInt8]()
    out.extend(Span(http.as_bytes()))
    return out^


def _external_source(text: String, capture: ArcPointer[List[UInt8]]) raises -> String:
    """The token an external_account source over `text` answers."""
    var env = _env(String(_PATH))
    var files = _files(text)
    files.put(String(_OIDC_FILE), String(_OIDC))
    var source = external_account_token_source(
        env,
        files^,
        HttpClient[ScriptedConnector].with_defaults(ScriptedConnector()),
        HttpClient[ScriptedConnector].with_defaults(
            ScriptedConnector.with_stream_tls(ScriptedStream.from_read_script_with_capture(_sts_answer(), capture))
        ),
        HttpClient[ScriptedConnector].with_defaults(ScriptedConnector()),
        FixedWallClock(1_790_000_000),
        ManualClock(),
    )
    return source.access_token()


def test_an_external_account_file_reaches_wif_s_reader() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var refused = String("")
    try:
        _ = _external_source(_external(False), capture)
    except e:
        refused = String(e)
    assert_true(refused.startswith("komira_gcp_wif: the external_account file") and refused.find("audience") >= 0, refused)
    var token = _external_source(_external(True), capture)
    assert_equal(token, _FEDERATED, "the token STS returned")
    var wire = String(unsafe_from_utf8=Span(capture[]))
    assert_true(wire.startswith("POST /v1/token HTTP/1.1"), wire)
    assert_true(wire.find(String("subject_token=") + _OIDC) >= 0, "the file-sourced subject token went to STS")


def test_a_service_account_file_never_reaches_wif() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var refused = String("")
    try:
        _ = _external_source(String(_SA), capture)
    except e:
        refused = String(e)
    assert_true(refused.find("komira_gcp_core reads, not komira_gcp_wif") >= 0, refused)
    assert_equal(len(capture[]), 0, "nothing was sent")


def main() raises:
    print("test_the_variable_is_required")
    test_the_variable_is_required()
    print("test_an_unreadable_file_is_refused_without_its_path")
    test_an_unreadable_file_is_refused_without_its_path()
    print("test_the_type_chooses_the_reader")
    test_the_type_chooses_the_reader()
    print("test_a_type_that_is_not_a_word_is_not_repeated")
    test_a_type_that_is_not_a_word_is_not_repeated()
    print("test_a_service_account_file_reaches_the_core_reader")
    test_a_service_account_file_reaches_the_core_reader()
    print("test_an_authorized_user_file_never_reaches_the_core")
    test_an_authorized_user_file_never_reaches_the_core()
    print("test_an_external_account_file_is_not_the_core_s")
    test_an_external_account_file_is_not_the_core_s()
    print("test_an_external_account_file_reaches_wif_s_reader")
    test_an_external_account_file_reaches_wif_s_reader()
    print("test_a_service_account_file_never_reaches_wif")
    test_a_service_account_file_never_reaches_wif()
    print("OK")
