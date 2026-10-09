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
#     REFUSED, the type named;
#   * a service_account file REACHES komira_gcp_core's reader: one whose
#     private key is not a key is refused in the core's own words, which only
#     the core's service-account reader writes;
#   * an authorized_user file never reaches the core: with an https token
#     URI the core would accept it, so its refusal can only be the chooser's;
#   * an external_account file is not handed to the core either.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_gcp_core import FixedWallClock, MapEnv, MapFiles
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.scripted import ScriptedConnector
from komira_retry import ManualClock

from kci_cloud_gcp import deploy_credentials_type, service_account_token_source


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


def test_a_service_account_file_reaches_the_core_reader() raises:
    var text = _source_refusal(String(_SA))
    assert_true(text.find("is not an RSA PKCS#8 PEM key") >= 0, text)


def test_an_authorized_user_file_never_reaches_the_core() raises:
    var text = _source_refusal(String(_USER))
    assert_true(text.startswith("kci: REFUSED:") and text.find("authorized_user") >= 0, text)


def test_an_external_account_file_is_not_the_core_s() raises:
    var text = _source_refusal(String(_EXTERNAL))
    assert_true(text.find("komira_gcp_wif reads") >= 0, text)


def main() raises:
    print("test_the_variable_is_required")
    test_the_variable_is_required()
    print("test_an_unreadable_file_is_refused_without_its_path")
    test_an_unreadable_file_is_refused_without_its_path()
    print("test_the_type_chooses_the_reader")
    test_the_type_chooses_the_reader()
    print("test_a_service_account_file_reaches_the_core_reader")
    test_a_service_account_file_reaches_the_core_reader()
    print("test_an_authorized_user_file_never_reaches_the_core")
    test_an_authorized_user_file_never_reaches_the_core()
    print("test_an_external_account_file_is_not_the_core_s")
    test_an_external_account_file_is_not_the_core_s()
    print("OK")
