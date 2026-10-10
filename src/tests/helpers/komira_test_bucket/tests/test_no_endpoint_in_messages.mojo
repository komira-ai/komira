# No refusal, raised error or verdict text carries the configured endpoint
# (or the bucket, or the credentials-file path), even when the client itself
# quotes the endpoint in its errors. Test output can land in a public log.

from std.testing import assert_equal, assert_false, assert_true

from komira_test_bucket import (
    FakeObjectStore,
    StoreScope,
    StoreTarget,
    TestBucket,
    TestStoreFlags,
    leak_check,
    open_test_bucket,
    select_backend,
)
from komira_test_run_id import FixedWallClock, RunId

comptime _HOST: String = "endpoint-sentinel.invalid"
comptime _BUCKET: String = "bucket-sentinel"
comptime _CREDS: String = "/mnt/creds-sentinel/credentials"

comptime _ENDPOINT: String = "https://endpoint-sentinel.invalid:9443/"


def _scope() -> StoreScope:
    return StoreScope(StoreTarget(_ENDPOINT, "r1", _BUCKET, _CREDS), 600, 60)


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


def _open(var s: FakeObjectStore) raises -> TestBucket[FakeObjectStore]:
    var clock = FixedWallClock(1790000000)
    return open_test_bucket(
        RunId(String(_ID), 1790000000), _scope(), "//p:t", s^, clock
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
    var v3 = leak_check(_ID, _scope().target, s3)
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


def _parse_error(args: List[String]) -> String:
    try:
        _ = TestStoreFlags.parse(args)
    except e:
        return String(e)
    return String("")


def _s3(endpoint: String, creds: String) -> List[String]:
    return [
        "--test-s3-endpoint=" + endpoint,
        "--test-s3-region=r1",
        "--test-s3-bucket=" + String(_BUCKET),
        "--test-s3-credentials-file=" + creds,
    ]


def test_flag_refusals_are_value_free() raises:
    # Parse refusals: a value glued onto a flag name without `=`, a retired
    # spelling and a misspelling carrying a value, a repeat, a bad number.
    var parse_cases = List[List[String]]()
    parse_cases.append(["--test-s3-endpointendpoint-sentinel.invalid"])
    parse_cases.append(["--test-s3-endpoint" + String(_ENDPOINT)])
    parse_cases.append(["--testinfra-s3-config=/mnt/creds-sentinel/cfg"])
    parse_cases.append(["--test-s3-endpont=" + String(_ENDPOINT)])
    parse_cases.append(["--test-s3-bucket=" + String(_BUCKET), "--test-s3-bucket=" + String(_BUCKET)])
    parse_cases.append(["--test-max-lease-seconds=endpoint-sentinel.invalid"])
    for c in parse_cases:
        var msg = _parse_error(c)
        assert_true(msg.byte_length() > 0, "expected a refusal for: " + c[0])
        _assert_no_value(msg)
    # Choice refusals: each one is CANNOT_TELL and names flags only.
    var choice_cases = List[List[String]]()
    choice_cases.append(_s3("endpoint-sentinel.invalid", _CREDS))
    choice_cases.append(_s3(_ENDPOINT, "creds-sentinel/credentials"))
    var partial: List[String] = ["--test-s3-endpoint=" + String(_ENDPOINT), "--test-s3-bucket=" + String(_BUCKET)]
    choice_cases.append(partial^)
    var both = _s3(_ENDPOINT, _CREDS)
    both.append("--test-minio-binary=/mnt/creds-sentinel/minio")
    choice_cases.append(both^)
    var lease = _s3(_ENDPOINT, _CREDS)
    lease.append("--test-teardown-budget-seconds=6000")
    choice_cases.append(lease^)
    for c in choice_cases:
        var choice = select_backend(TestStoreFlags.parse(c))
        assert_equal(choice.exit_code(), 3)
        assert_true(choice.reason.byte_length() > 0)
        _assert_no_value(choice.reason)


def main() raises:
    test_the_fake_really_leaks()
    test_teardown_verdicts_are_scrubbed()
    test_open_failure_is_scrubbed()
    test_flag_refusals_are_value_free()
    print("test_no_endpoint_in_messages: OK")
