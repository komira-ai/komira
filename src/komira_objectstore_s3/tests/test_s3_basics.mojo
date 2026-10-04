# The parts of komira_objectstore_s3 that send nothing: S3Config and the
# ruleset parameters it becomes, the status table (classify_http_status) and
# the message every verb raises, the half-open to closed range conversion
# and the checks a 206 must pass, and the decoding of URL-encoded names.
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_objectstore.types import (
    STORE_ERR_MALFORMED,
    STORE_ERR_NOT_FOUND,
    STORE_ERR_PERMISSION_DENIED,
    STORE_ERR_PRECONDITION,
    STORE_ERR_THROTTLED,
    STORE_ERR_TRANSPORT,
)
from komira_objectstore.cas_manifest import is_precondition
from komira_objectstore_s3 import (
    AddressingStyle,
    S3ByteRange,
    S3Config,
    classify_http_status,
    s3_check_partial,
    s3_offset_range_header,
    s3_parse_content_range,
    s3_standard_retry_policy,
    s3_store_error,
    s3_suffix_range_header,
    s3_url_decode,
    store_error_kind_from_message,
)


def test_config_defaults_and_refusals() raises:
    var c = S3Config.aws("eu-west-1")
    assert_equal(c.region, "eu-west-1")
    assert_equal(c.endpoint, "")
    assert_false(c.addressing.is_path())
    assert_equal(c.max_inflight, 64)
    assert_equal(c.list_page_size, 1000)
    assert_equal(c.retry.max_attempts, 3)
    var p = c.endpoint_config()
    assert_equal(p.region.value(), "eu-west-1")
    assert_false(Bool(p.endpoint))
    assert_false(Bool(p.force_path_style))
    assert_false(Bool(p.use_fips))
    with assert_raises(contains="the region is empty"):
        _ = S3Config("", retry=s3_standard_retry_policy())
    with assert_raises(contains="max_inflight must be >= 1"):
        _ = S3Config("us-east-1", max_inflight=0, retry=s3_standard_retry_policy())
    with assert_raises(contains="list_page_size must be 1 to 1000"):
        _ = S3Config("us-east-1", list_page_size=1001, retry=s3_standard_retry_policy())
    with assert_raises(contains="the endpoint is empty"):
        _ = S3Config.custom_endpoint("us-east-1", "")


def test_config_custom_endpoint_is_path_style() raises:
    # The endpoint, the addressing and the planned concurrency are
    # constructor parameters.
    var c = S3Config(
        "us-east-1",
        endpoint="http://127.0.0.1:9000",
        addressing=AddressingStyle.path(),
        use_fips=True,
        use_dual_stack=True,
        max_inflight=4,
        retry=s3_standard_retry_policy(),
    )
    var p = c.endpoint_config()
    assert_equal(p.endpoint.value(), "http://127.0.0.1:9000")
    assert_true(p.force_path_style.value())
    assert_true(p.use_fips.value())
    assert_true(p.use_dual_stack.value())
    assert_equal(c.max_inflight, 4)
    assert_true(S3Config.custom_endpoint("us-east-1", "http://m:9000").addressing.is_path())


def test_status_table() raises:
    assert_equal(classify_http_status(404, "NoSuchKey", "").kind, STORE_ERR_NOT_FOUND)
    assert_equal(classify_http_status(404, "404", "").kind, STORE_ERR_NOT_FOUND)
    assert_equal(classify_http_status(403, "AccessDenied", "").kind, STORE_ERR_PERMISSION_DENIED)
    assert_equal(classify_http_status(401, "", "").kind, STORE_ERR_PERMISSION_DENIED)
    assert_equal(classify_http_status(412, "PreconditionFailed", "").kind, STORE_ERR_PRECONDITION)
    assert_equal(classify_http_status(304, "", "").kind, STORE_ERR_PRECONDITION)
    # A conditional write that raced another one wrote nothing: the caller
    # reads again and retries, as for a 412.
    assert_equal(
        classify_http_status(409, "ConditionalRequestConflict", "").kind,
        STORE_ERR_PRECONDITION,
    )
    # Any other 409 is not a lost condition.
    assert_equal(classify_http_status(409, "BucketNotEmpty", "").kind, STORE_ERR_MALFORMED)
    assert_equal(classify_http_status(503, "SlowDown", "").kind, STORE_ERR_THROTTLED)
    assert_equal(classify_http_status(429, "", "").kind, STORE_ERR_THROTTLED)
    assert_equal(classify_http_status(400, "SlowDown", "").kind, STORE_ERR_THROTTLED)
    assert_equal(classify_http_status(500, "InternalError", "").kind, STORE_ERR_TRANSPORT)
    assert_equal(classify_http_status(504, "", "").kind, STORE_ERR_TRANSPORT)
    assert_equal(classify_http_status(416, "InvalidRange", "").kind, STORE_ERR_MALFORMED)
    assert_equal(classify_http_status(400, "InvalidArgument", "").kind, STORE_ERR_MALFORMED)
    assert_equal(classify_http_status(200, "", "").kind, STORE_ERR_MALFORMED)
    assert_true(classify_http_status(503, "SlowDown", "").is_retryable())
    assert_false(classify_http_status(412, "", "").is_retryable())


def test_error_message() raises:
    var e = String(s3_store_error("PutObject", "lake", "m/1.json", 412, "PreconditionFailed", "At least one\nof the pre-conditions"))
    assert_equal(
        e,
        "StoreError[PRECONDITION] PutObject s3://lake/m/1.json status=412"
        " s3_code=PreconditionFailed s3_message=At least one of the pre-conditions",
    )
    assert_equal(store_error_kind_from_message(e), STORE_ERR_PRECONDITION)
    assert_true(is_precondition(e))
    # A 409 race reads as a lost precondition to komira_objectstore's CAS
    # retry, whose test is a substring one.
    var c = String(s3_store_error("PutObject", "lake", "k", 409, "ConditionalRequestConflict", "try again"))
    assert_true(c.startswith("StoreError[PRECONDITION] PutObject s3://lake/k status=409"))
    assert_true(is_precondition(c))
    # A HEAD 404 has no body: the code is the status.
    var h = String(s3_store_error("HeadObject", "lake", "k", 404, "404", ""))
    assert_equal(h, "StoreError[NOT_FOUND] HeadObject s3://lake/k status=404 s3_code=404")
    # The kind is the FIRST token; a key holding one changes nothing.
    var k = String(s3_store_error("GetObject", "lake", "StoreError[NOT_FOUND]", 403, "AccessDenied", ""))
    assert_equal(store_error_kind_from_message(k), STORE_ERR_PERMISSION_DENIED)
    assert_equal(store_error_kind_from_message("no token"), UInt8(0))


def test_range_conversion() raises:
    # [10, 14) is bytes 10..13: the closed form's last byte is end - 1.
    var r = S3ByteRange.of_length(10, 4)
    assert_equal(r.start, 10)
    assert_equal(r.end, 14)
    assert_equal(r.last(), 13)
    assert_equal(r.length(), 4)
    assert_equal(r.header(), "bytes=10-13")
    assert_equal(S3ByteRange.of_length(0, 1).header(), "bytes=0-0")
    with assert_raises(contains="at least one byte"):
        _ = S3ByteRange.of_length(0, 0)
    with assert_raises(contains="negative start"):
        _ = S3ByteRange.of_length(-1, 4)
    with assert_raises(contains="overflows"):
        _ = S3ByteRange.of_length(Int64.MAX - 2, 4)
    assert_equal(s3_suffix_range_header(8), "bytes=-8")
    assert_equal(s3_offset_range_header(5), "bytes=5-")
    with assert_raises(contains="at least one byte"):
        _ = s3_suffix_range_header(0)


def test_content_range() raises:
    var cr = s3_parse_content_range("bytes 10-13/100")
    assert_equal(cr.first, 10)
    assert_equal(cr.last, 13)
    assert_equal(cr.total, 100)
    assert_equal(s3_parse_content_range("bytes 0-0/*").total, -1)
    with assert_raises(contains="is not a bytes range"):
        _ = s3_parse_content_range("items 0-1/2")
    with assert_raises(contains="ends before it starts"):
        _ = s3_parse_content_range("bytes 5-4/10")
    with assert_raises(contains="ends past the object"):
        _ = s3_parse_content_range("bytes 0-10/10")
    with assert_raises(contains="has no '/length'"):
        _ = s3_parse_content_range("bytes 0-1")
    var asked = S3ByteRange.of_length(10, 4)
    s3_check_partial(asked, s3_parse_content_range("bytes 10-13/100"), 4)
    # The object ends first: the 206 ends at its last byte.
    s3_check_partial(asked, s3_parse_content_range("bytes 10-11/12"), 2)
    with assert_raises(contains="starts at byte 9"):
        s3_check_partial(asked, s3_parse_content_range("bytes 9-12/100"), 4)
    with assert_raises(contains="ends at byte 12"):
        s3_check_partial(asked, s3_parse_content_range("bytes 10-12/100"), 3)
    with assert_raises(contains="carries 3"):
        s3_check_partial(asked, s3_parse_content_range("bytes 10-13/100"), 3)


def test_url_decode() raises:
    assert_equal(s3_url_decode("a/b%20c+d"), "a/b c d")
    assert_equal(s3_url_decode("x%2By"), "x+y")
    assert_equal(s3_url_decode("%01%0A"), "\x01\n")
    assert_equal(s3_url_decode("caf%C3%A9"), "café")
    with assert_raises(contains="ends inside an escape"):
        _ = s3_url_decode("a%2")
    with assert_raises(contains="bad escape"):
        _ = s3_url_decode("a%zz")


def main() raises:
    test_config_defaults_and_refusals()
    test_config_custom_endpoint_is_path_style()
    test_status_table()
    test_error_message()
    test_range_conversion()
    test_content_range()
    test_url_decode()
    print("OK")
