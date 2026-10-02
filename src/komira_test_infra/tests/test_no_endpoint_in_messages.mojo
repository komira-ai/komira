# No refusal, raised error or verdict text carries the configured endpoint
# (or the bucket, or the credentials-file path), even when the client itself
# quotes the endpoint in its errors. Test output can land in a public log.

from std.testing import assert_equal, assert_false, assert_true

from komira_test_infra import (
    FakeObjectStore,
    FixedWallClock,
    MapFiles,
    NoProcess,
    RunId,
    TestBucket,
    TestInfraFlags,
    Verdict,
    leak_check,
    open_test_bucket,
    parse_test_infra_config,
    select_backend,
)

comptime _HOST: String = "endpoint-sentinel.invalid"
comptime _BUCKET: String = "bucket-sentinel"
comptime _CREDS: String = "/mnt/creds-sentinel/credentials"

comptime _CFG: String = """
object_store {
  endpoint: "https://endpoint-sentinel.invalid:9443/"
  region: "r1"
  bucket: "bucket-sentinel"
  run_prefix: "runs/"
  credentials_file: "/mnt/creds-sentinel/credentials"
}
max_lease_seconds: 600
teardown_budget_seconds: 60
"""

comptime _ID: String = "1790000000-00000000000000ee"


def _assert_no_value(text: String) raises:
    assert_false(_HOST in text, "message carries the endpoint: " + text)
    assert_false("endpoint-sentinel" in text, "message carries the endpoint host: " + text)
    assert_false(_BUCKET in text, "message carries the bucket: " + text)
    assert_false("creds-sentinel" in text, "message carries the credentials path: " + text)


def _leaky_store() -> FakeObjectStore:
    var s = FakeObjectStore()
    s.echo_endpoint_in_errors = True
    return s^


def _open(var s: FakeObjectStore) raises -> TestBucket[FakeObjectStore, NoProcess]:
    var clock = FixedWallClock(1790000000)
    return open_test_bucket(
        RunId(String(_ID), 1790000000), parse_test_infra_config(_CFG), "//p:t", s^, clock
    )


def test_the_fake_really_leaks() raises:
    # The fixture must quote the endpoint, or the checks below prove nothing.
    var s = _leaky_store()
    s.fail_puts = True
    var b = _open(FakeObjectStore())
    _ = b.close()
    var raised = String("")
    try:
        var b2 = _open(s^)
        _ = b2.close()
    except e:
        raised = String(e)
    assert_true(raised.byte_length() > 0)
    assert_true("<object_store.endpoint>" in raised, raised)


def test_teardown_verdicts_are_scrubbed() raises:
    var s = _leaky_store()
    s.fail_list_calls.append(0)
    s.fail_list_calls.append(1)
    var b = _open(s^)
    var v = b.close()
    _assert_no_value(String(v))
    assert_true(len(v.reasons) == 2)

    var s2 = _leaky_store()
    s2.fail_delete_request = True
    var b2 = _open(s2^)
    var body = String("x")
    b2.client().put(b2.key("a"), body.as_bytes())
    var v2 = b2.close()
    _assert_no_value(String(v2))

    var s3 = _leaky_store()
    s3.fail_list_calls.append(0)
    var v3 = leak_check(_ID, parse_test_infra_config(_CFG), s3)
    _assert_no_value(String(v3))
    var raised = False
    try:
        v.require_clean()
    except e:
        raised = True
        _assert_no_value(String(e))
    assert_true(raised)


def test_open_failure_is_scrubbed() raises:
    var s = _leaky_store()
    s.fail_puts = True
    var raised = False
    try:
        var b = _open(s^)
        _ = b.close()
    except e:
        raised = True
        _assert_no_value(String(e))
    assert_true(raised)


def _config_error(text: String) -> String:
    try:
        _ = parse_test_infra_config(text)
    except e:
        return String(e)
    return String("")


def test_config_and_flag_refusals_are_value_free() raises:
    var cases: List[String] = [
        _CFG.replace("\"https://endpoint-sentinel.invalid:9443/\"", "endpoint-sentinel.invalid"),
        _CFG.replace("\"https://endpoint-sentinel.invalid:9443/\"", "\"endpoint-sentinel.invalid\""),
        _CFG.replace("\"https://endpoint-sentinel.invalid:9443/\"", "\"https://endpoint-sentinel.invalid:9443/\" ["),
        _CFG.replace("\"bucket-sentinel\"", "\"bucket-sentinel"),
        _CFG.replace("\"/mnt/creds-sentinel/credentials\"", "\"creds-sentinel/credentials\""),
        _CFG + "endpoint-sentinel.invalid: 1\n",
        _CFG.replace("teardown_budget_seconds: 60", "teardown_budget_seconds: 600"),
    ]
    for c in cases:
        var msg = _config_error(c)
        assert_true(msg.byte_length() > 0, "expected a refusal for: " + c)
        _assert_no_value(msg)
    var files = MapFiles()
    files.put("/cfg/bad.textproto", cases[0])
    var args: List[String] = ["--testinfra-s3-config=/cfg/bad.textproto"]
    var choice = select_backend(TestInfraFlags.parse(args), files)
    assert_equal(choice.exit_code(), 3)
    _assert_no_value(choice.reason)


def main() raises:
    test_the_fake_really_leaks()
    test_teardown_verdicts_are_scrubbed()
    test_open_failure_is_scrubbed()
    test_config_and_flag_refusals_are_value_free()
    print("test_no_endpoint_in_messages: OK")
