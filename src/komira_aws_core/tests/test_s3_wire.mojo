# The S3 header values no model states.
#
# x-amz-copy-source (s3_copy_source): `<bucket>/<key>` percent-encoded as
# UTF-8, every byte but the RFC 3986 section 2.3 unreserved set and '/'
# encoded with upper-case hex (RFC 3986 section 2.1), `?versionId=` appended
# unencoded; an access point ARN bucket names its objects under `object/`.
# This is botocore's `_quote_source_header_from_dict`
# (botocore/handlers.py); the CopyObject API reference states the
# `<bucket>/<key>` and access point `.../object/<key>` forms and that the
# value is URL-encoded.
#
# Content-Range (s3_content_range_total): RFC 9110 section 14.4,
# `bytes first-last/complete-length`, `bytes first-last/*` and the
# unsatisfied form `bytes */complete-length`.
#
# The request checksum (s3_apply_request_checksum): CRC-32/ISO-HDLC, whose
# published check value is CRC("123456789") = 0xCBF43926; the other vectors
# were computed with zlib's crc32, an independent implementation, and
# base64-encoded big-endian as the S3 API reference's `x-amz-checksum-crc32`
# is. The header rules are botocore's `resolve_request_checksum_algorithm`
# (botocore/httpchecksum.py) under `when_supported`.

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_aws_core import (
    AwsRequest,
    s3_apply_request_checksum,
    s3_checksum_crc32,
    s3_content_range_total,
    s3_copy_source,
    s3_crc32,
)


def test_copy_source_plain() raises:
    assert_equal(s3_copy_source("bucket", "key"), "bucket/key")
    # '/' in a key is kept: S3 keys are paths by convention.
    assert_equal(s3_copy_source("bucket", "a/b/c.txt"), "bucket/a/b/c.txt")
    # Unreserved bytes are kept as they are.
    assert_equal(s3_copy_source("bucket", "A-z_0.9~"), "bucket/A-z_0.9~")


def test_copy_source_escapes() raises:
    # A space is %20, never '+'.
    assert_equal(s3_copy_source("bucket", "my key"), "bucket/my%20key")
    # '?' would start a query: encoded.
    assert_equal(s3_copy_source("bucket", "a?b"), "bucket/a%3Fb")
    # The other reserved and unsafe bytes.
    assert_equal(
        s3_copy_source("bucket", "+=&%#:@!$'()*,;"),
        "bucket/%2B%3D%26%25%23%3A%40%21%24%27%28%29%2A%2C%3B",
    )
    # UTF-8, byte by byte: e-acute is C3 A9, u-umlaut C3 BC.
    assert_equal(
        s3_copy_source("bucket", "café/ü"), "bucket/caf%C3%A9/%C3%BC"
    )
    # Dot segments are not normalized: they are part of the key.
    assert_equal(s3_copy_source("bucket", "../a/./b"), "bucket/../a/./b")


def test_copy_source_version() raises:
    assert_equal(
        s3_copy_source("bucket", "my key", String("3HL4kqtJlcpXroDTDmJ.rmSpXd3dIbrHY")),
        "bucket/my%20key?versionId=3HL4kqtJlcpXroDTDmJ.rmSpXd3dIbrHY",
    )


def test_copy_source_access_points() raises:
    # An access point ARN: its objects are under `object/`, and the ARN is
    # encoded like any bucket (':' is reserved).
    assert_equal(
        s3_copy_source(
            "arn:aws:s3:us-west-2:123456789012:accesspoint/my-ap", "k y"
        ),
        "arn%3Aaws%3As3%3Aus-west-2%3A123456789012%3Aaccesspoint/my-ap/object/k%20y",
    )
    assert_equal(
        s3_copy_source(
            "arn:aws-cn:s3:cn-north-1:123456789012:accesspoint:my-ap", "k"
        ),
        "arn%3Aaws-cn%3As3%3Acn-north-1%3A123456789012%3Aaccesspoint%3Amy-ap/object/k",
    )
    # An Outposts access point ARN.
    assert_equal(
        s3_copy_source(
            "arn:aws:s3-outposts:us-west-2:123456789012:outpost/op-01234567890123456/accesspoint/my-ap",
            "k",
        ),
        "arn%3Aaws%3As3-outposts%3Aus-west-2%3A123456789012%3Aoutpost/op-01234567890123456/accesspoint/my-ap/object/k",
    )
    # Not an access point ARN (an account id of 11 digits): a bucket.
    assert_equal(
        s3_copy_source("arn:aws:s3:us-west-2:12345678901:accesspoint/my-ap", "k"),
        "arn%3Aaws%3As3%3Aus-west-2%3A12345678901%3Aaccesspoint/my-ap/k",
    )


def _total(v: String) raises -> Int:
    var t = s3_content_range_total(v)
    assert_true(Bool(t), v)
    return t.value()


def _refused(v: String, want: String) raises:
    try:
        _ = s3_content_range_total(v)
    except e:
        assert_true(String(e).find(want) >= 0, String(e))
        return
    raise Error("not refused: '" + v + "'")


def test_content_range() raises:
    assert_equal(_total("bytes 0-99/1234"), 1234)
    assert_equal(_total("bytes 1233-1233/1234"), 1234)
    assert_equal(_total("bytes 0-0/1"), 1)
    # The range unit is case-insensitive (RFC 9110 section 14.1).
    assert_equal(_total("Bytes 0-9/10"), 10)
    # An unsatisfied range (a 416) still states the length.
    assert_equal(_total("bytes */1234"), 1234)
    assert_equal(_total("bytes */0"), 0)
    # An unknown length.
    assert_false(Bool(s3_content_range_total("bytes 0-99/*")))


def test_content_range_refusals() raises:
    _refused("bytes 0-1234/1234", "ends past the length")
    _refused("bytes 10-5/100", "ends before it starts")
    _refused("items 0-1/2", "not a bytes range")
    _refused("bytes 0-1", "no '/length'")
    _refused("bytes */*", "neither range nor length")
    _refused("bytes a-b/3", "the first byte is not a byte count")
    _refused("bytes 0-1/x", "the length is not a byte count")
    _refused("bytes -1/3", "the first byte is not a byte count")
    _refused("bytes 0-/3", "the last byte is not a byte count")
    _refused("", "not a bytes range")


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


comptime _ALG = "x-amz-sdk-checksum-algorithm"


def test_crc32_vectors() raises:
    assert_equal(s3_crc32(Span(_bytes(String("123456789")))), UInt32(0xCBF43926))
    assert_equal(s3_crc32(Span(_bytes(String("")))), UInt32(0))
    var rows: List[List[String]] = [
        ["", "AAAAAA=="],
        ["123456789", "y/Q5Jg=="],
        ["part three", "L8IwAg=="],
        ['{"v":1}', "hNvnPQ=="],
        ["Welcome to Amazon S3.", "Ox7nCg=="],
    ]
    for i in range(len(rows)):
        assert_equal(
            s3_checksum_crc32(Span(_bytes(rows[i][0]))), rows[i][1], rows[i][0]
        )


def test_checksum_default_is_crc32() raises:
    var req = AwsRequest(String("PUT"), String("/k"))
    req.body = _bytes(String("part three"))
    s3_apply_request_checksum(req, String(_ALG))
    assert_equal(req.header(String(_ALG)), "CRC32")
    assert_equal(req.header(String("x-amz-checksum-crc32")), "L8IwAg==")
    assert_equal(len(req.header_names), 2)
    # An empty body has a checksum too.
    var empty = AwsRequest(String("PUT"), String("/k"))
    s3_apply_request_checksum(empty, String(_ALG))
    assert_equal(empty.header(String("x-amz-checksum-crc32")), "AAAAAA==")


def test_checksum_crc32_chosen() raises:
    var req = AwsRequest(String("PUT"), String("/k"))
    req.body = _bytes(String("x"))
    req.set_header(String(_ALG), String("crc32"))
    s3_apply_request_checksum(req, String(_ALG))
    # The caller's value is kept as given.
    assert_equal(req.header(String(_ALG)), "crc32")
    assert_equal(req.header(String("x-amz-checksum-crc32")), "jNwWgw==")


def test_checksum_supplied_by_the_caller() raises:
    # A checksum header already set: nothing is added or replaced.
    var req = AwsRequest(String("PUT"), String("/k"))
    req.body = _bytes(String("x"))
    req.set_header(String("X-Amz-Checksum-SHA256"), String("abc="))
    s3_apply_request_checksum(req, String(_ALG))
    assert_false(req.has_header(String(_ALG)))
    assert_false(req.has_header(String("x-amz-checksum-crc32")))
    assert_equal(len(req.header_names), 1)


def test_checksum_other_algorithm_refused() raises:
    var req = AwsRequest(String("PUT"), String("/k"))
    req.set_header(String(_ALG), String("SHA256"))
    with assert_raises(contains="'SHA256' is not computed by this client"):
        s3_apply_request_checksum(req, String(_ALG))


def main() raises:
    test_copy_source_plain()
    test_copy_source_escapes()
    test_copy_source_version()
    test_copy_source_access_points()
    test_content_range()
    test_content_range_refusals()
    test_crc32_vectors()
    test_checksum_default_is_crc32()
    test_checksum_crc32_chosen()
    test_checksum_supplied_by_the_caller()
    test_checksum_other_algorithm_refused()
    print("OK")
