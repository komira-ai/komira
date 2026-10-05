# =============================================================================
# komira_gcp_wif/tests/test_aws_subject.mojo — the `aws1` subject token,
#   pure: no connector, no client, a fixed signing time.
# =============================================================================
#
# Every claim is an EQUALITY: the canonical request byte for byte, the header
# list in order, the JSON text whole. A substring check cannot see an extra
# header, and Google forwards the header list to AWS verbatim, so one extra or
# one missing is a `SignatureDoesNotMatch` that Google reports as a generic
# subject-token failure.
#
# The expected values are written from the reference implementation's source
# (`google/auth/aws.py`): what is signed, the header order, sorted JSON keys,
# `quote()` keeping `/`. The signature itself is komira_aws_core's SigV4,
# which that package checks against AWS's own signing test suite; here the
# claim is what goes INTO it (the canonical request) and around it.
#
# No real credential: AWS's published documentation key pair, and a made-up
# session token holding `+`, `/` and `=` so the encoding has work to do.
# =============================================================================

from std.testing import assert_equal, assert_raises, assert_true

from komira_aws_core import AwsCredential

from komira_gcp_wif import (
    aws1_signed_request,
    aws1_subject_token,
    aws_sts_host,
)


comptime AKID = "AKIAIOSFODNN7EXAMPLE"
comptime SECRET = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
comptime SESSION = "FwoGZXIvYXdzEXAMPLE+SESSION/TOKEN=="
comptime REGION = "us-east-1"
comptime AMZ_DATE = "20261001T120000Z"
comptime AUDIENCE = (
    "//iam.googleapis.com/projects/1234567890/locations/global/"
    "workloadIdentityPools/example-pool/providers/example-aws"
)
comptime EMPTY_SHA256 = (
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
)


def _cred(session: String) -> AwsCredential:
    return AwsCredential(String(AKID), String(SECRET), session)


def _hex(c: UInt8) raises -> Int:
    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
        return Int(c) - ord("0")
    if c >= UInt8(ord("A")) and c <= UInt8(ord("F")):
        return Int(c) - ord("A") + 10
    raise Error("not an uppercase hex digit: " + String(Int(c)))


def _percent_decode(s: String) raises -> String:
    """Strict inverse of the encoder: every `%` starts two UPPERCASE hex
    digits, and every other byte must be one the encoder may leave alone."""
    var b = s.as_bytes()
    var out = List[UInt8]()
    var i = 0
    while i < len(b):
        if b[i] == UInt8(ord("%")):
            if i + 2 >= len(b):
                raise Error("truncated escape")
            out.append(UInt8(_hex(b[i + 1]) * 16 + _hex(b[i + 2])))
            i += 3
        else:
            var c = b[i]
            var ok = (
                (c >= UInt8(ord("A")) and c <= UInt8(ord("Z")))
                or (c >= UInt8(ord("a")) and c <= UInt8(ord("z")))
                or (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
                or c == UInt8(ord("-"))
                or c == UInt8(ord("."))
                or c == UInt8(ord("_"))
                or c == UInt8(ord("~"))
                or c == UInt8(ord("/"))
            )
            if not ok:
                raise Error("a byte the encoder must escape: " + String(Int(c)))
            out.append(c)
            i += 1
    return String(unsafe_from_utf8=Span(out))


def test_the_canonical_request_signs_host_date_and_session_token() raises:
    """What AWS verifies, byte for byte: the empty-body POST to `/` with the
    two GetCallerIdentity parameters, signed over `host`, `x-amz-date` and
    `x-amz-security-token`, and NOT over `x-goog-cloud-target-resource`.

    ⛔ Do not "harden" the request by signing the audience header: Google does
    not forward it to AWS, so a signature over it names a header AWS never
    receives."""
    var r = aws1_signed_request(
        _cred(String(SESSION)), String(REGION), String(AUDIENCE), String(AMZ_DATE)
    )
    assert_equal(
        r.canonical_request,
        String("POST\n/\nAction=GetCallerIdentity&Version=2011-06-15\n")
        + "host:sts.us-east-1.amazonaws.com\n"
        + "x-amz-date:20261001T120000Z\n"
        + "x-amz-security-token:" + SESSION + "\n"
        + "\n"
        + "host;x-amz-date;x-amz-security-token\n"
        + EMPTY_SHA256,
    )
    assert_equal(r.signed_headers, "host;x-amz-date;x-amz-security-token")


def test_the_header_list_is_the_references_in_order() raises:
    """Five headers, in `google/auth/aws.py`'s order, and the Authorization
    names the `sts` scope for the signing date."""
    var r = aws1_signed_request(
        _cred(String(SESSION)), String(REGION), String(AUDIENCE), String(AMZ_DATE)
    )
    assert_equal(len(r.headers), 5)
    assert_equal(r.headers[0].name, "Authorization")
    assert_equal(r.headers[1].name, "host")
    assert_equal(r.headers[2].name, "x-amz-date")
    assert_equal(r.headers[3].name, "x-amz-security-token")
    assert_equal(r.headers[4].name, "x-goog-cloud-target-resource")
    assert_equal(r.headers[1].value, "sts.us-east-1.amazonaws.com")
    assert_equal(r.headers[2].value, AMZ_DATE)
    assert_equal(r.headers[3].value, SESSION)
    assert_equal(r.headers[4].value, AUDIENCE)
    var auth = r.headers[0].value.copy()
    var prefix = String(
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20261001/us-east-1/"
        "sts/aws4_request, SignedHeaders=host;x-amz-date;x-amz-security-token,"
        " Signature="
    )
    assert_true(auth.startswith(prefix), auth)
    # A lowercase hex SHA-256 HMAC, and nothing after it.
    assert_equal(auth.byte_length() - prefix.byte_length(), 64)
    assert_equal(
        r.url,
        "https://sts.us-east-1.amazonaws.com?Action=GetCallerIdentity&Version=2011-06-15",
    )


def test_a_permanent_credential_sends_and_signs_no_session_token() raises:
    """No session token: `x-amz-security-token` in NEITHER the signed set nor
    the header list. The two lists are built in different places (the signer
    and this package), so each is checked."""
    var r = aws1_signed_request(
        _cred(String("")), String(REGION), String(AUDIENCE), String(AMZ_DATE)
    )
    assert_equal(r.signed_headers, "host;x-amz-date")
    assert_equal(len(r.headers), 4)
    assert_equal(r.headers[3].name, "x-goog-cloud-target-resource")


def test_the_json_is_compact_with_sorted_keys() raises:
    """The whole serialized request, against text written by hand: keys
    `headers`, `method`, `url` (Python's `sort_keys=True`), each header a
    `{"key","value"}` pair, no whitespace."""
    var r = aws1_signed_request(
        _cred(String(SESSION)), String(REGION), String(AUDIENCE), String(AMZ_DATE)
    )
    var want = (
        String('{"headers":[{"key":"Authorization","value":"')
        + r.headers[0].value
        + '"},{"key":"host","value":"sts.us-east-1.amazonaws.com"},'
        + '{"key":"x-amz-date","value":"20261001T120000Z"},'
        + '{"key":"x-amz-security-token","value":"' + SESSION + '"},'
        + '{"key":"x-goog-cloud-target-resource","value":"' + AUDIENCE + '"}],'
        + '"method":"POST",'
        + '"url":"https://sts.us-east-1.amazonaws.com?Action=GetCallerIdentity&Version=2011-06-15"}'
    )
    assert_equal(r.to_json(), want)


def test_the_token_is_the_json_percent_encoded_keeping_slash() raises:
    """`quote(json)`: every byte but the unreserved ones and `/` escaped,
    uppercase hex. So `"` `:` `{` `+` `=` `?` `&` are escaped and `/` is not,
    and decoding gives back the JSON exactly."""
    var r = aws1_signed_request(
        _cred(String(SESSION)), String(REGION), String(AUDIENCE), String(AMZ_DATE)
    )
    var tok = r.subject_token()
    assert_equal(_percent_decode(tok), r.to_json())
    assert_true(tok.startswith("%7B%22headers%22%3A%5B%7B%22key%22%3A%22Authorization%22"))
    assert_true("https%3A//sts.us-east-1.amazonaws.com%3FAction%3DGetCallerIdentity%26Version%3D2011-06-15" in tok)
    assert_true("FwoGZXIvYXdzEXAMPLE%2BSESSION/TOKEN%3D%3D" in tok)
    assert_equal(
        aws1_subject_token(
            _cred(String(SESSION)), String(REGION), String(AUDIENCE), String(AMZ_DATE)
        ),
        tok,
    )


def test_a_bad_region_or_an_empty_audience_is_refused() raises:
    """The region becomes the host Google calls, so only `[a-z0-9-]` passes;
    an empty audience can never be accepted by a provider."""
    assert_equal(aws_sts_host(String("eu-west-3")), "sts.eu-west-3.amazonaws.com")
    var bad: List[String] = [
        String(""),
        String("us-east-1.evil.example"),
        String("us-east-1/x"),
        String("us-east-1#"),
        String("us@east"),
        String("US-EAST-1"),
    ]
    for i in range(len(bad)):
        with assert_raises():
            _ = aws_sts_host(bad[i])
    with assert_raises(contains="audience is empty"):
        _ = aws1_signed_request(
            _cred(String(SESSION)), String(REGION), String(""), String(AMZ_DATE)
        )


def main() raises:
    test_the_canonical_request_signs_host_date_and_session_token()
    test_the_header_list_is_the_references_in_order()
    test_a_permanent_credential_sends_and_signs_no_session_token()
    test_the_json_is_compact_with_sorted_keys()
    test_the_token_is_the_json_percent_encoded_keeping_slash()
    test_a_bad_region_or_an_empty_audience_is_refused()
    print("test_aws_subject: OK")
