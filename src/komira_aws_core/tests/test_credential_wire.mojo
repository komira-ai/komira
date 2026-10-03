# =============================================================================
# komira_aws_core/tests/test_credential_wire.mojo
# =============================================================================
#
# Each network-backed provider's request builder, byte for byte against a
# golden request under tests/fixtures/*.request, and each response parser
# against a fixture answer, one error shape each.
#
# The goldens are scrubbed: AWS's documented example key pair, account
# 123456789012, fake tokens. The AssumeRole golden's signature was computed
# independently of this package (openssl HMAC-SHA256 over the canonical
# request), so the test is not this package agreeing with itself.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_aws_core import (
    AwsCredential,
    amz_date_from_unix,
    CredentialHttpRequest,
    CredentialHttpResponse,
    build_assume_role,
    build_assume_role_with_web_identity,
    build_container_request,
    build_imds_credentials_request,
    build_imds_role_request,
    build_imds_token_request,
    container_endpoint_full,
    container_endpoint_relative,
    imds_endpoint,
    parse_container_credentials,
    parse_imds_credentials,
    parse_imds_role,
    parse_imds_token,
    parse_sts_credentials,
)


comptime _FIX = "src/komira_aws_core/tests/fixtures/"
comptime _KEY = "AKIAIOSFODNN7EXAMPLE"
comptime _SECRET = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
comptime _IMDS_TOKEN = "AQAEAFAKE-IMDS-SESSION-TOKEN=="


def _read(name: String) raises -> String:
    with open(String(_FIX) + name, "r") as f:
        return f.read()


def _wire(req: CredentialHttpRequest) -> String:
    """The request bytes as text (every request here has a text body)."""
    return String(unsafe_from_utf8=Span(req.to_wire()))


def _golden(req: CredentialHttpRequest, name: String) raises:
    var want = _read(name)
    # The goldens are CRLF on disk; nothing normalizes line ends.
    assert_true(want.find("\r\n") >= 0, name + " lost its CRLF line ends")
    var got = _wire(req)
    if got != want:
        raise Error(
            "request differs from " + name + "\n--- got ---\n" + got
            + "\n--- want ---\n" + want
        )


def _refused_parse_sts(action: String, status: Int, body: String, needle: String) raises:
    try:
        _ = parse_sts_credentials(action, CredentialHttpResponse(status, body))
    except e:
        var msg = String(e)
        assert_true(msg.find(needle) >= 0, msg)
        return
    raise Error("expected an STS refusal containing: " + needle)


def test_sts_web_identity() raises:
    var req = build_assume_role_with_web_identity(
        String("arn:aws:iam::123456789012:role/example-web-role"),
        String("komira-test"),
        String("eyJFAKE.eyJFAKE-TOKEN.c2lnbmF0dXJl"),
        String("us-west-2"),
    )
    assert_equal(req.scheme, "https")
    assert_equal(req.host, "sts.us-west-2.amazonaws.com")
    assert_equal(req.port, 443)
    _golden(req, "sts_assume_role_with_web_identity.request")
    # No region: the global endpoint.
    var g = build_assume_role_with_web_identity(
        String("arn:aws:iam::123456789012:role/r"),
        String("komira-test"),
        String("tok"),
        String(""),
    )
    assert_equal(g.host, "sts.amazonaws.com")

    var t = parse_sts_credentials(
        String("AssumeRoleWithWebIdentity"),
        CredentialHttpResponse(
            200, _read("sts_assume_role_with_web_identity.response.xml")
        ),
    )
    assert_equal(t.credential.access_key_id, "ASIAWEBIDENTITYEXAMPL")
    assert_equal(
        t.credential.secret_access_key, "FAKEwebIdentitySecretKeyEXAMPLEKEY000000"
    )
    assert_equal(t.credential.session_token, "FAKE-WEB-IDENTITY-SESSION-TOKEN")
    assert_equal(t.expiration, "2026-09-15T13:00:00Z")

    # The error shape: code and message named.
    _refused_parse_sts(
        String("AssumeRoleWithWebIdentity"),
        403,
        _read("sts_error.response.xml"),
        "AccessDenied: Not authorized to perform sts:AssumeRoleWithWebIdentity",
    )
    # A 200 for the wrong action, a non-XML body.
    _refused_parse_sts(
        String("AssumeRole"),
        200,
        _read("sts_assume_role_with_web_identity.response.xml"),
        "answered with a AssumeRoleWithWebIdentityResponse",
    )
    _refused_parse_sts(
        String("AssumeRole"), 502, String("<html"), "HTTP 502 with a body that is not XML"
    )


def test_sts_assume_role_signed() raises:
    var req = build_assume_role(
        String("arn:aws:iam::123456789012:role/example-role"),
        String("komira-test"),
        String("example-external-id"),
        String("1800"),
        String("us-west-2"),
        AwsCredential(String(_KEY), String(_SECRET), String("")),
        String("20260915T120000Z"),
    )
    _golden(req, "sts_assume_role.request")
    assert_true(_wire(req).find(_SECRET) < 0, "the secret is on the wire")

    var t = parse_sts_credentials(
        String("AssumeRole"),
        CredentialHttpResponse(200, _read("sts_assume_role.response.xml")),
    )
    assert_equal(t.credential.access_key_id, "ASIAASSUMEDROLEEXAMPL")
    assert_equal(t.credential.session_token, "FAKE-ASSUME-ROLE-SESSION-TOKEN")
    assert_equal(t.expiration, "2026-09-15T12:30:00Z")

    # Builder refusals name the setting.
    try:
        _ = build_assume_role(
            String("arn:aws:iam::123456789012:role/r"),
            String("x"),
            String(""),
            String(""),
            String("us-west-2"),
            AwsCredential(String(_KEY), String(_SECRET), String("")),
            String("20260915T120000Z"),
        )
        raise Error("a one-character session name was accepted")
    except e:
        assert_true(String(e).find("role session name") >= 0, String(e))
    try:
        _ = build_assume_role(
            String("arn:aws:iam::123456789012:role/r"),
            String("komira-test"),
            String(""),
            String("12h"),
            String("us-west-2"),
            AwsCredential(String(_KEY), String(_SECRET), String("")),
            String("20260915T120000Z"),
        )
        raise Error("a non-numeric duration was accepted")
    except e:
        assert_true(String(e).find("duration_seconds") >= 0, String(e))
    try:
        _ = build_assume_role_with_web_identity(
            String("arn:aws:iam::123456789012:role/r"),
            String("komira-test"),
            String("tok"),
            String("evil.example.com/"),
        )
        raise Error("a region with a dot and slash was accepted")
    except e:
        assert_true(String(e).find("not a valid AWS region") >= 0, String(e))


def test_container() raises:
    var rel = build_container_request(
        container_endpoint_relative(String("/v2/credentials/example-task-id")),
        String(""),
    )
    assert_equal(rel.scheme, "http")
    assert_equal(rel.port, 80)
    _golden(rel, "container_relative.request")

    var full = build_container_request(
        container_endpoint_full(String("http://169.254.170.23/v1/credentials")),
        String("example-eks-pod-identity-token"),
    )
    _golden(full, "container_full_uri.request")

    # https to any host, with a port.
    var ep = container_endpoint_full(String("https://creds.example.com:8443/x?y=1"))
    assert_equal(ep.host, "creds.example.com")
    assert_equal(ep.port, 8443)
    assert_equal(ep.target, "/x?y=1")
    # http only to loopback, the ECS and the EKS endpoints.
    _ = container_endpoint_full(String("http://127.0.0.1:9911/creds"))
    _ = container_endpoint_full(String("http://localhost/creds"))
    _ = container_endpoint_full(String("http://[::1]:80/creds"))
    _ = container_endpoint_full(String("http://[fd00:ec2::23]/v1/credentials"))
    var bads: List[String] = [
        "http://creds.example.com/x",
        "http://128.0.0.1/x",
        "http://127.0.0.1.example.com/x",
        "ftp://127.0.0.1/x",
        "http://user@127.0.0.1/x",
        "http://127.0.0.1:99999/x",
    ]
    for bad in bads:
        try:
            _ = container_endpoint_full(String(bad))
            raise Error("accepted " + String(bad))
        except e:
            assert_true(
                String(e).find("AWS_CONTAINER_CREDENTIALS_FULL_URI") >= 0,
                String(e),
            )
    try:
        _ = container_endpoint_relative(String("v2/no-slash"))
        raise Error("accepted a relative URI without '/'")
    except e:
        assert_true(
            String(e).find("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI") >= 0, String(e)
        )
    try:
        _ = build_container_request(
            container_endpoint_relative(String("/v2/x")),
            String("tok\r\nX-Injected: 1"),
        )
        raise Error("accepted a token with CRLF")
    except e:
        assert_true(String(e).find("control bytes") >= 0, String(e))
        assert_true(String(e).find("X-Injected") < 0, String(e))

    var t = parse_container_credentials(
        CredentialHttpResponse(200, _read("container.response.json"))
    )
    assert_equal(t.credential.access_key_id, "ASIACONTAINEREXAMPLE")
    # "\/" in the JSON is a '/'.
    assert_equal(
        t.credential.secret_access_key, "FAKEcontainerSecretKey/EXAMPLEKEY00000000"
    )
    assert_equal(t.credential.session_token, "FAKE-CONTAINER-SESSION-TOKEN")
    assert_equal(t.expiration, "2026-09-15T18:00:00Z")
    try:
        _ = parse_container_credentials(
            CredentialHttpResponse(403, _read("container_error.response.json"))
        )
        raise Error("accepted a 403")
    except e:
        assert_true(String(e).find("HTTP 403: AccessDenied") >= 0, String(e))
    try:
        _ = parse_container_credentials(
            CredentialHttpResponse(200, String('{"AccessKeyId": {"nested": 1}}'))
        )
        raise Error("accepted a nested document")
    except e:
        assert_true(String(e).find("not a flat JSON object") >= 0, String(e))


def test_imds() raises:
    var ep = imds_endpoint(String(""), String(""))
    _golden(build_imds_token_request(ep), "imds_token.request")
    _golden(
        build_imds_role_request(ep, String(_IMDS_TOKEN)), "imds_role.request"
    )
    _golden(
        build_imds_credentials_request(
            ep, String(_IMDS_TOKEN), String("example-instance-role")
        ),
        "imds_credentials.request",
    )
    var v6 = imds_endpoint(String(""), String("IPv6"))
    assert_equal(v6.host, "[fd00:ec2::254]")
    assert_equal(build_imds_token_request(v6).header("Host"), "[fd00:ec2::254]")
    var custom = imds_endpoint(String("http://127.0.0.1:1338/"), String("IPv6"))
    assert_equal(custom.host, "127.0.0.1")
    assert_equal(custom.port, 1338)
    assert_equal(build_imds_token_request(custom).header("Host"), "127.0.0.1:1338")
    assert_equal(build_imds_token_request(custom).target, "/latest/api/token")
    try:
        _ = imds_endpoint(String(""), String("IPv5"))
        raise Error("accepted mode IPv5")
    except e:
        assert_true(
            String(e).find("AWS_EC2_METADATA_SERVICE_ENDPOINT_MODE") >= 0, String(e)
        )

    assert_equal(
        parse_imds_token(CredentialHttpResponse(200, String(_IMDS_TOKEN) + "\n")),
        _IMDS_TOKEN,
    )
    assert_equal(
        parse_imds_role(
            CredentialHttpResponse(200, String("example-instance-role\n"))
        ),
        "example-instance-role",
    )
    try:
        _ = parse_imds_role(CredentialHttpResponse(404, String("")))
        raise Error("accepted a 404 role list")
    except e:
        assert_true(String(e).find("no IAM role attached") >= 0, String(e))
    var t = parse_imds_credentials(
        CredentialHttpResponse(200, _read("imds_credentials.response.json"))
    )
    assert_equal(t.credential.access_key_id, "ASIAINSTANCEEXAMPLE0")
    assert_equal(t.credential.session_token, "FAKE-INSTANCE-SESSION-TOKEN")
    assert_equal(t.expiration, "2026-09-15T18:10:00Z")
    try:
        _ = parse_imds_credentials(
            CredentialHttpResponse(200, _read("imds_credentials_error.response.json"))
        )
        raise Error("accepted a non-Success Code")
    except e:
        assert_true(
            String(e).find("Code 'AssumeRoleUnauthorizedAccess'") >= 0, String(e)
        )
    try:
        _ = build_imds_credentials_request(
            ep, String(_IMDS_TOKEN), String("../../user-data")
        )
        raise Error("accepted a role name with a path")
    except e:
        assert_true(String(e).find("not an IAM role name") >= 0, String(e))



def _date_refused(unix_seconds: Int) raises:
    try:
        _ = amz_date_from_unix(unix_seconds)
    except e:
        assert_true(String(e).find("outside 1970..9999") >= 0, String(e))
        return
    raise Error("amz_date_from_unix accepted " + String(unix_seconds))


def test_amz_date_from_unix() raises:
    """Direct vectors, checked against `date -u -d @<n>` (the 9999 end is
    253402300800, 10000-01-01, minus one second): every field of
    YYYYMMDDTHHMMSSZ non-zero somewhere, the January/February year carry, a
    leap day, a year rollover, both ends of the range and both refusals."""
    assert_equal(amz_date_from_unix(0), "19700101T000000Z")
    # Leap day, last second: Feb (the m <= 2 year carry) of a leap year.
    assert_equal(amz_date_from_unix(1709251199), "20240229T235959Z")
    # 2000 is a leap year (divisible by 400): Feb 29, then Mar 1.
    assert_equal(amz_date_from_unix(951782400), "20000229T000000Z")
    assert_equal(amz_date_from_unix(951868800), "20000301T000000Z")
    # Dec 31 -> Jan 1 rollover; Jan 1 also takes the year carry.
    assert_equal(amz_date_from_unix(1767225599), "20251231T235959Z")
    assert_equal(amz_date_from_unix(1767225600), "20260101T000000Z")
    # Hour, minute and second all non-zero and all different.
    assert_equal(amz_date_from_unix(1789456089), "20260915T070809Z")
    assert_equal(amz_date_from_unix(1789473600), "20260915T120000Z")
    # The last representable second.
    assert_equal(amz_date_from_unix(253402300799), "99991231T235959Z")
    _date_refused(-1)
    _date_refused(253402300800)


def _sts_region_refused(region: String) raises:
    try:
        _ = build_assume_role_with_web_identity(
            String("arn:aws:iam::123456789012:role/r"),
            String("komira-test"),
            String("tok"),
            region,
        )
    except e:
        var msg = String(e)
        assert_true(msg.find(region) >= 0, msg)
        assert_true(msg.find("partition") >= 0, msg)
        return
    raise Error("an STS request was built for " + region)


def test_sts_partition() raises:
    """sts.<region>.amazonaws.com is the STS host only in the 'aws' and
    'aws-us-gov' partitions; any other partition is refused by name, not
    sent to a host that does not exist (or to the wrong partition)."""
    var gov = build_assume_role_with_web_identity(
        String("arn:aws-us-gov:iam::123456789012:role/r"),
        String("komira-test"),
        String("tok"),
        String("us-gov-west-1"),
    )
    assert_equal(gov.host, "sts.us-gov-west-1.amazonaws.com")
    var std_region = build_assume_role_with_web_identity(
        String("arn:aws:iam::123456789012:role/r"),
        String("komira-test"),
        String("tok"),
        String("ap-southeast-2"),
    )
    assert_equal(std_region.host, "sts.ap-southeast-2.amazonaws.com")
    _sts_region_refused(String("cn-north-1"))
    _sts_region_refused(String("cn-northwest-1"))
    _sts_region_refused(String("us-iso-east-1"))
    _sts_region_refused(String("us-isob-east-1"))
    _sts_region_refused(String("eu-isoe-west-1"))


def main() raises:
    test_sts_web_identity()
    test_sts_assume_role_signed()
    test_container()
    test_imds()
    test_amz_date_from_unix()
    test_sts_partition()
    print("OK")
