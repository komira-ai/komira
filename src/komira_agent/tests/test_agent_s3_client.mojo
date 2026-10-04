# =============================================================================
# komira_agent/tests/test_agent_s3_client.mojo
#   The agent's S3 verbs, the binary download and the signing clock, over a
#   scripted connector: no socket, no S3, no cloud.
# =============================================================================
#
# `AgentS3Client` (s3_client.mojo) is the agent's one S3 surface: the boot
# download, the live log stream and the terminal upload all go through its
# `get_object` / `put_object`. These arms drive it over komira_http_core's
# `ScriptedConnector`, which answers each request with a fixed HTTP response,
# so what is tested is the agent's side: the bytes it hands back, the
# SHA-256 refusal before anything is written, the raise on an error status,
# and the `MINIO_E2E_*` clock override.
#
# Credentials come from the default chain's environment arm (static, worthless
# values set below), so the chain never reaches the network.
#
# EVERY ARM HAS A CONTROL: a GET that returns the body is paired with a
# download whose digest does not match, a PUT that succeeds with one that is
# refused, and the override that is set with one that is not.
# =============================================================================

from std.ffi import external_call
from std.os.path import exists
from std.testing import assert_equal, assert_false, assert_true

from komira_crypto.hex import hex_lower_array_32
from komira_crypto.sha256 import sha256
from komira_core_ffi.posix import _read_env
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

from komira_agent.agent_config import AgentConfig
from komira_agent.boot import download_binary
from komira_agent.clock_helper import (
    amz_override_unix_seconds,
    amz_stamps_from_unix_ms,
    unix_seconds_from_amz_date,
)
from komira_agent.s3_client import AgentS3Client


comptime _BODY = "#!/bin/sh\necho agent-s3-client\n"
comptime _ENDPOINT = "http://127.0.0.1:9000"


# =============================================================================
# helpers
# =============================================================================
def _setenv(name: String, value: String):
    var name_str = name
    var value_str = value
    var name_ptr = name_str.as_c_string_slice().unsafe_ptr()
    var value_ptr = value_str.as_c_string_slice().unsafe_ptr()
    var _rc = external_call["setenv", Int32](name_ptr, value_ptr, Int32(1))


def _unsetenv(name: String):
    var name_str = name
    var name_ptr = name_str.as_c_string_slice().unsafe_ptr()
    var _rc = external_call["unsetenv", Int32](name_ptr)


def _stub_aws_credentials():
    """Static credentials on the environment: the chain's first arm."""
    _setenv(String("AWS_ACCESS_KEY_ID"), String("AKIAIOSFODNN7EXAMPLE"))
    _setenv(
        String("AWS_SECRET_ACCESS_KEY"),
        String("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"),
    )


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(s.as_bytes())
    return out^


def _response(status_line: String, etag: String, body: String) -> List[UInt8]:
    var head = String("HTTP/1.1 ") + status_line + "\r\n"
    if etag.byte_length() > 0:
        head += "ETag: " + etag + "\r\n"
    head += "Content-Length: " + String(body.byte_length()) + "\r\n\r\n"
    return _bytes(head + body)


def _mk_get_ok() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        ScriptedStream.from_read_script(
            _response(String("200 OK"), String('"e-1"'), String(_BODY))
        )
    )


def _mk_put_ok() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        ScriptedStream.from_read_script(
            _response(String("200 OK"), String('"e-2"'), String(""))
        )
    )


def _mk_put_denied() raises -> ScriptedConnector:
    var body = String(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Error><Code>AccessDenied"
        "</Code><Message>Access Denied</Message></Error>"
    )
    return ScriptedConnector.with_stream(
        ScriptedStream.from_read_script(
            _response(String("403 Forbidden"), String(""), body)
        )
    )


def _tmp_path(name: String) raises -> String:
    var tmp = _read_env("TEST_TMPDIR")
    assert_true(tmp.byte_length() > 0, "TEST_TMPDIR is unset")
    return tmp + "/" + name


def _download_config(var uri: String, var sha: Optional[String], var path: String) -> AgentConfig:
    var argv = List[String]()
    return AgentConfig(
        String("11111111-2222-3333-4444-555555555555"),
        String("pod-s3"),
        String("/bin/true"),
        argv^,
        String("jm.example.com"),
        UInt16(8081),
        5,
        100,
        8 * 1024 * 1024,
        Optional[String](uri^),      # binary_s3_uri
        sha^,                        # binary_sha256
        path^,                       # binary_download_path
        Optional[String](),          # log_bucket
        Optional[String](String(_ENDPOINT)),
        String("us-east-1"),
    )


def _read_file(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


# =============================================================================
# ARM 1: GET hands back the object's bytes, and the endpoint is kept.
# =============================================================================
def test_get_object_returns_the_body() raises:
    _stub_aws_credentials()
    var client = AgentS3Client[ScriptedConnector](
        _mk_get_ok, String("us-east-1"), Optional[String](String(_ENDPOINT))
    )
    assert_equal(client.endpoint().value(), String(_ENDPOINT))
    var got = client.get_object(String("bin"), String("job/binary"))
    assert_equal(len(got), String(_BODY).byte_length())
    assert_true(got == _bytes(String(_BODY)), "GET must return the body as sent")
    print("  test_get_object_returns_the_body: PASS")


# =============================================================================
# ARM 2: the download verifies the key's SHA-256, writes and chmods; a
# mismatch refuses before anything is written.
# =============================================================================
def test_download_binary_verifies_then_writes() raises:
    _stub_aws_credentials()
    var sha = hex_lower_array_32(sha256(String(_BODY).as_bytes()))
    var path = _tmp_path(String("dl-ok/job/job_binary"))
    var config = _download_config(
        String("s3://bin/") + sha + "/binary", Optional[String](), path
    )
    var client = AgentS3Client[ScriptedConnector](
        _mk_get_ok, String("us-east-1"), Optional[String](String(_ENDPOINT))
    )
    var written = download_binary[ScriptedConnector](config, client)
    assert_equal(written, path)
    assert_equal(_read_file(path), String(_BODY))

    # CONTROL: an explicit digest that does not match is refused, and the
    # file is never created.
    var bad_path = _tmp_path(String("dl-bad/job_binary"))
    var bad = _download_config(
        String("s3://bin/job/binary"),
        Optional[String](String("0" * 64)),
        bad_path,
    )
    var bad_client = AgentS3Client[ScriptedConnector](
        _mk_get_ok, String("us-east-1"), Optional[String](String(_ENDPOINT))
    )
    var refused = False
    try:
        _ = download_binary[ScriptedConnector](bad, bad_client)
    except e:
        refused = "SHA-256 mismatch" in String(e)
    assert_true(refused, "a digest mismatch must raise naming the mismatch")
    assert_false(exists(bad_path), "a refused binary must not be written")
    print("  test_download_binary_verifies_then_writes: PASS")


# =============================================================================
# ARM 3: PUT succeeds on a 200 and raises on an error status.
# =============================================================================
def test_put_object_raises_on_an_error_status() raises:
    _stub_aws_credentials()
    var ok = AgentS3Client[ScriptedConnector](
        _mk_put_ok, String("us-east-1"), Optional[String](String(_ENDPOINT))
    )
    ok.put_object(String("logs"), String("job/logs.txt"), _bytes(String("hello")))

    # CONTROL: a 403 is an error the caller sees.
    var denied = AgentS3Client[ScriptedConnector](
        _mk_put_denied, String("us-east-1"), Optional[String](String(_ENDPOINT))
    )
    var raised = False
    try:
        denied.put_object(
            String("logs"), String("job/logs.txt"), _bytes(String("hello"))
        )
    except:
        raised = True
    assert_true(raised, "a 403 PutObject must raise")
    print("  test_put_object_raises_on_an_error_status: PASS")


# =============================================================================
# ARM 4: the signing clock's override parses the SigV4 stamp it is given.
# =============================================================================
def test_amz_date_parse_inverts_the_stamp() raises:
    var samples = List[Int64]()
    samples.append(Int64(0))
    samples.append(Int64(951_782_400_000))
    samples.append(Int64(1_789_826_399_000))
    samples.append(Int64(4_102_444_800_000))
    for ms in samples:
        var stamps = amz_stamps_from_unix_ms(ms)
        assert_equal(
            unix_seconds_from_amz_date(stamps.amz_date), Int(ms // 1000)
        )
    var refused = False
    try:
        _ = unix_seconds_from_amz_date(String("2026-09-19T13:59:59Z"))
    except:
        refused = True
    assert_true(refused, "a stamp of another shape must be refused")
    print("  test_amz_date_parse_inverts_the_stamp: PASS")


def test_override_needs_both_variables() raises:
    _unsetenv(String("MINIO_E2E_AMZ_DATE"))
    _unsetenv(String("MINIO_E2E_SHORT_DATE"))
    assert_false(amz_override_unix_seconds().__bool__(), "no override: live clock")

    # CONTROL: one variable alone is not an override (amz_stamps_now's rule).
    _setenv(String("MINIO_E2E_AMZ_DATE"), String("20260919T135959Z"))
    assert_false(
        amz_override_unix_seconds().__bool__(),
        "MINIO_E2E_AMZ_DATE alone must not stop the clock",
    )
    _setenv(String("MINIO_E2E_SHORT_DATE"), String("20260919"))
    var fixed = amz_override_unix_seconds()
    assert_true(fixed.__bool__(), "both variables stop the clock")
    assert_equal(fixed.value(), 1_789_826_399)
    _unsetenv(String("MINIO_E2E_AMZ_DATE"))
    _unsetenv(String("MINIO_E2E_SHORT_DATE"))
    print("  test_override_needs_both_variables: PASS")


def main() raises:
    print("test_agent_s3_client:")
    test_get_object_returns_the_body()
    test_download_binary_verifies_then_writes()
    test_put_object_raises_on_an_error_status()
    test_amz_date_parse_inverts_the_stamp()
    test_override_needs_both_variables()
    print("test_agent_s3_client: ALL PASS")
