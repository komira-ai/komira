# =============================================================================
# komira_aws_core/tests/test_process_creds.mojo
# =============================================================================
#
# The process's default credential source (process_creds.mojo) and the
# process seams under it (sources.mojo's ProcessEnv and ProcessFiles):
#
#   * `process_creds_source` with stated keys answers them, from every
#     clone, without reading the environment or the network (a stated
#     credential wins over every provider);
#   * `process_credential_transport` builds both halves (plain TCP and TLS)
#     from the caller's HTTP config, and refuses a scheme that is neither;
#   * ProcessEnv reads the process environment (a variable this test sets,
#     and an unset one as ""); ProcessFiles reads a staged fixture, says an
#     absent path does not exist, and refuses it naming the path.
# =============================================================================

from std.os import setenv
from std.testing import assert_equal, assert_false, assert_true

from komira_http_client.client import HttpClientConfig

from komira_aws_core import (
    AwsCredential,
    AwsCredentialParams,
    CredentialHttpRequest,
    ProcessEnv,
    ProcessFiles,
    process_credential_transport,
    process_creds_source,
)


comptime _FIX = "src/komira_aws_core/tests/fixtures/"


def test_stated_keys() raises:
    # Should the stated keys be lost, the chain must fail here rather than
    # read this host's files or dial instance metadata.
    _ = setenv("AWS_EC2_METADATA_DISABLED", "true", True)
    _ = setenv("AWS_CONFIG_FILE", String(_FIX) + "no-such-config", True)
    _ = setenv("AWS_SHARED_CREDENTIALS_FILE", String(_FIX) + "no-such-credentials", True)
    var params = AwsCredentialParams()
    params.credential = Optional[AwsCredential](
        AwsCredential(String("AKIDPROCESS"), String("FAKEprocessSecret"), String("tok"))
    )
    var src = process_creds_source(params, HttpClientConfig.defaults())
    var c = src.credentials()
    assert_equal(c.access_key_id, "AKIDPROCESS")
    assert_equal(c.secret_access_key, "FAKEprocessSecret")
    assert_equal(c.session_token, "tok")
    var clone = src.copy()
    assert_equal(clone.credentials().access_key_id, "AKIDPROCESS")


def test_transport_scheme_split() raises:
    var t = process_credential_transport(HttpClientConfig.defaults())
    try:
        _ = t.send(CredentialHttpRequest("GET", "ftp", "example.com", 21, "/"))
        raise Error("an ftp credential request was sent")
    except e:
        assert_equal(
            String(e),
            "a credential request names a scheme that is neither http nor https",
        )


def test_process_env() raises:
    _ = setenv("KOMIRA_AWS_CORE_TEST_VARIABLE", "set-by-test", True)
    var env = ProcessEnv()
    assert_equal(env.get("KOMIRA_AWS_CORE_TEST_VARIABLE"), "set-by-test")
    assert_equal(env.get("KOMIRA_AWS_CORE_TEST_VARIABLE_NEVER_SET"), "")


def test_process_files() raises:
    var files = ProcessFiles()
    var path = String(_FIX) + "container.response.json"
    assert_true(files.exists(path))
    assert_true(files.read(path).find('"AccessKeyId": "ASIACONTAINEREXAMPLE"') >= 0)
    # A directory is not a file.
    assert_false(files.exists(String(_FIX)))
    var absent = String(_FIX) + "no-such-file"
    assert_false(files.exists(absent))
    try:
        _ = files.read(absent)
        raise Error("an absent file was read")
    except e:
        assert_equal(String(e), "cannot read the file " + absent)


def main() raises:
    var failed = 0
    try:
        test_stated_keys()
    except e:
        print("FAIL test_stated_keys:", e)
        failed += 1
    try:
        test_transport_scheme_split()
    except e:
        print("FAIL test_transport_scheme_split:", e)
        failed += 1
    try:
        test_process_env()
    except e:
        print("FAIL test_process_env:", e)
        failed += 1
    try:
        test_process_files()
    except e:
        print("FAIL test_process_files:", e)
        failed += 1
    if failed > 0:
        raise Error(String(failed) + " test(s) failed")
    print("OK")
