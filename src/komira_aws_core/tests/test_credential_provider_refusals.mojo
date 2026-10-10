# =============================================================================
# komira_aws_core/tests/test_credential_provider_refusals.mojo
# =============================================================================
#
# The network credential providers' request builders and response parsers
# on the inputs they refuse, each refusal by its exact message: the
# container endpoint's URL rules (the SDKs' loopback rule for plain http,
# IPv6 literals, ports, an empty host), the instance metadata service's
# non-200 answers and empty role list, the STS builders' and parser's
# refusals, and the region shapes the STS partition check accepts (the
# partitions' regionRegex, as in sts_credentials.mojo's docstring). Then a
# chain expiration that is not a time, and the shared-file parser's
# skipping of an indented line before any section.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_aws_core import (
    AwsCredential,
    AwsProfileSet,
    CredentialHttpResponse,
    build_assume_role,
    build_assume_role_with_web_identity,
    build_imds_credentials_request,
    build_imds_role_request,
    container_endpoint_full,
    expiration_unix_seconds,
    imds_endpoint,
    parse_container_credentials,
    parse_imds_credentials,
    parse_imds_role,
    parse_imds_token,
    parse_profile_file,
    parse_sts_credentials,
)
from komira_aws_core.sts_credentials import (
    check_region,
    sts_region_in_supported_partition,
)


def _resp(status: Int, body: String) -> CredentialHttpResponse:
    return CredentialHttpResponse(status, body)


comptime _FULL = "AWS_CONTAINER_CREDENTIALS_FULL_URI"


def _full_refused(url: String, want: String) raises:
    try:
        _ = container_endpoint_full(url)
    except e:
        assert_equal(String(e), want, url)
        return
    raise Error("container URL accepted: " + url)


def test_container_full_uri() raises:
    # Plain http only to loopback (any 127.x.y.z with four decimal octets
    # of at most 255), the ECS and EKS endpoints.
    var ok = container_endpoint_full("http://127.1.2.3:8080/x")
    assert_equal(ok.host, "127.1.2.3")
    assert_equal(ok.port, 8080)
    assert_equal(ok.target, "/x")
    var plain = String(_FULL) + (
        " uses plain http to a host that is not loopback, the ECS"
        " endpoint or the EKS Pod Identity endpoint; use https"
    )
    _full_refused("http://127.a.0.1/", plain)
    _full_refused("http://127..0.1/", plain)
    _full_refused("http://127.0.0.1a/", plain)
    _full_refused("http://127.0.0.1000/", plain)
    # Four digits whose value is at most 255: refused by the length rule
    # alone (Python's ipaddress refuses an octet over 3 characters).
    _full_refused("http://127.0.0.0001/", plain)
    _full_refused("http://127.0.0.256/", plain)
    _full_refused("http://128.0.0.1/", plain)
    # The URL's own shape.
    _full_refused("http://127.0.0.1:/", _FULL + " has an invalid port")
    _full_refused("http://a b/", _FULL + " holds whitespace or control bytes")
    _full_refused("https://[::1/x", _FULL + " has an unterminated IPv6 literal")
    _full_refused("https://[::1]x/", _FULL + " has text after its IPv6 literal")
    _full_refused("https://[::1]x", _FULL + " has text after its IPv6 literal")
    _full_refused("https:///x", _FULL + " has no host")
    _full_refused("https://:443/x", _FULL + " has no host")
    var v6 = container_endpoint_full("https://[fd00::1]:8443/c")
    assert_equal(v6.host, "[fd00::1]")
    assert_equal(v6.port, 8443)


def test_container_response() raises:
    try:
        _ = parse_container_credentials(_resp(200, '{"AccessKeyId":"A"}'))
        raise Error("a response without a secret was accepted")
    except e:
        assert_equal(
            String(e),
            "the container credentials response lacks AccessKeyId or SecretAccessKey",
        )
    try:
        _ = parse_container_credentials(_resp(200, '{"SecretAccessKey":"S"}'))
        raise Error("a response without a key id was accepted")
    except e:
        assert_equal(
            String(e),
            "the container credentials response lacks AccessKeyId or SecretAccessKey",
        )


def _refused_with(msg: String, want: String) raises:
    assert_equal(msg, want)


def test_imds() raises:
    var ep = imds_endpoint("", "")
    try:
        _ = build_imds_role_request(ep, "")
        raise Error("an empty session token was accepted")
    except e:
        _refused_with(
            String(e), "the instance metadata session token is empty or malformed"
        )
    try:
        _ = build_imds_role_request(ep, "tok" + chr(1))
        raise Error("a control byte in the session token was accepted")
    except e:
        _refused_with(
            String(e), "the instance metadata session token is empty or malformed"
        )
    try:
        _ = build_imds_credentials_request(ep, "tok", "")
        raise Error("an empty role name was accepted")
    except e:
        _refused_with(String(e), "the instance has no IAM role attached")
    try:
        _ = parse_imds_token(_resp(403, ""))
        raise Error("a 403 token answer was accepted")
    except e:
        _refused_with(
            String(e), "the instance metadata token request answered HTTP 403"
        )
    try:
        _ = parse_imds_role(_resp(500, "role"))
        raise Error("a 500 role list was accepted")
    except e:
        _refused_with(
            String(e), "the instance metadata role list answered HTTP 500"
        )
    # The first non-blank line is the role; none is no role.
    assert_equal(parse_imds_role(_resp(200, "\n  \nr1\nr2\n")), "r1")
    try:
        _ = parse_imds_role(_resp(200, "\n   \n"))
        raise Error("a blank role list was accepted")
    except e:
        _refused_with(String(e), "the instance has no IAM role attached")
    try:
        _ = parse_imds_credentials(_resp(401, ""))
        raise Error("a 401 credentials answer was accepted")
    except e:
        _refused_with(
            String(e),
            "the instance metadata credentials request answered HTTP 401",
        )
    for body in [
        '{"Code":"Success","AccessKeyId":"A"}',
        '{"Code":"Success","SecretAccessKey":"S"}',
    ]:
        try:
            _ = parse_imds_credentials(_resp(200, body))
            raise Error("credentials with a missing key were accepted")
        except e:
            _refused_with(
                String(e),
                "the instance metadata credentials lack AccessKeyId or"
                " SecretAccessKey",
            )


def test_sts_regions() raises:
    var max64 = String("")
    for _ in range(64):
        max64 += "a"
    var long = max64 + "a"
    for bad in [String(""), long, String("us-East-1"), String("us_east-1")]:
        try:
            check_region(bad, "S")
            raise Error("region accepted: " + bad)
        except e:
            assert_equal(String(e), "the region from S is not a valid AWS region name")
    check_region(max64, "S")
    # aws: ^(us|eu|ap|sa|ca|me|af|il|mx)-\w+-\d+$; aws-us-gov:
    # ^us-gov-\w+-\d+$. A digit inside the middle word (us-ea5t-1) is not
    # asserted: \w admits it, this check does not (komira-ai/komira#1141).
    assert_true(sts_region_in_supported_partition("eu-west-1"))
    assert_true(sts_region_in_supported_partition("mx-central-1"))
    assert_true(sts_region_in_supported_partition("us-gov-west-1"))
    assert_false(sts_region_in_supported_partition("us--1"))
    assert_false(sts_region_in_supported_partition("us-east-"))
    assert_false(sts_region_in_supported_partition("us-east-1a"))
    assert_false(sts_region_in_supported_partition("zz-east-1"))
    assert_false(sts_region_in_supported_partition("cn-north-1"))
    assert_false(sts_region_in_supported_partition("us-gov-west-x"))
    assert_false(sts_region_in_supported_partition("us-iso-east-1"))


comptime _ARN = "arn:aws:iam::123456789012:role/r"


def test_sts_builders() raises:
    try:
        _ = build_assume_role_with_web_identity("", "sess", "tok", "us-east-1")
        raise Error("an empty role ARN was accepted")
    except e:
        assert_equal(
            String(e),
            "the role ARN from the web identity role ARN setting is empty or"
            " malformed",
        )
    try:
        _ = build_assume_role_with_web_identity(_ARN, "sess", "", "us-east-1")
        raise Error("an empty web identity token was accepted")
    except e:
        assert_equal(
            String(e), "the web identity token file is empty or holds control bytes"
        )
    try:
        _ = build_assume_role_with_web_identity(_ARN, "sess", "a" + chr(10) + "b", "us-east-1")
        raise Error("a web identity token with LF was accepted")
    except e:
        assert_equal(
            String(e), "the web identity token file is empty or holds control bytes"
        )
    try:
        _ = build_assume_role(
            _ARN, "sess", "ext" + chr(1), "", "us-east-1",
            AwsCredential(String("AKID"), String("s"), String("")),
            "20260915T120000Z",
        )
        raise Error("an external id with a control byte was accepted")
    except e:
        assert_equal(String(e), "the profile's external_id holds control bytes")


def _sts_body(creds: String) -> String:
    return (
        '<AssumeRoleResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/">'
        "<AssumeRoleResult>" + creds + "</AssumeRoleResult></AssumeRoleResponse>"
    )


def _sts_refused(creds: String, want: String) raises:
    try:
        _ = parse_sts_credentials("AssumeRole", _resp(200, _sts_body(creds)))
    except e:
        assert_equal(String(e), want)
        return
    raise Error("STS answer accepted: " + creds)


def test_sts_parser() raises:
    var t = parse_sts_credentials(
        "AssumeRole",
        _resp(
            200,
            _sts_body(
                "<Credentials><AccessKeyId>ASIA1</AccessKeyId>"
                "<SecretAccessKey>s</SecretAccessKey><SessionToken>t</SessionToken>"
                "<Expiration>2026-09-15T13:00:00Z</Expiration></Credentials>"
            ),
        ),
    )
    assert_equal(t.credential.access_key_id, "ASIA1")
    assert_equal(t.expiration, "2026-09-15T13:00:00Z")
    _sts_refused("", "the STS AssumeRole response has no Credentials")
    for missing in ["AccessKeyId", "SecretAccessKey", "SessionToken", "Expiration"]:
        var c = String("<Credentials>")
        for name in ["AccessKeyId", "SecretAccessKey", "SessionToken", "Expiration"]:
            if name != missing:
                c += "<" + name + ">x</" + name + ">"
        c += "</Credentials>"
        _sts_refused(c, "the STS AssumeRole response has no " + missing)
    _sts_refused(
        "<Credentials><AccessKeyId></AccessKeyId><SecretAccessKey>s</SecretAccessKey>"
        "<SessionToken>t</SessionToken><Expiration>e</Expiration></Credentials>",
        "the STS AssumeRole response has an empty key",
    )
    _sts_refused(
        "<Credentials><AccessKeyId>A</AccessKeyId><SecretAccessKey></SecretAccessKey>"
        "<SessionToken>t</SessionToken><Expiration>e</Expiration></Credentials>",
        "the STS AssumeRole response has an empty key",
    )


def test_expiration_and_profiles() raises:
    assert_equal(expiration_unix_seconds(""), -1)
    assert_equal(expiration_unix_seconds("2026-09-15T12:00:00Z"), 1789473600)
    try:
        _ = expiration_unix_seconds("tomorrow")
        raise Error("an expiration that is not a time was accepted")
    except e:
        assert_equal(String(e), "a credential expiration is not an ISO 8601 time")
    try:
        _ = AwsProfileSet().profile("x")
        raise Error("an absent profile was returned")
    except e:
        assert_equal(String(e), "the AWS profile 'x' is in neither shared file")
    # An indented line before the first section belongs to no profile and
    # is skipped (no property to continue), as an unindented one is.
    var pset = parse_profile_file(
        "  indented = 1\nloose = 2\n[default]\nregion = us-west-2\n", True, "/c"
    )
    assert_equal(len(pset.profiles), 1)
    assert_equal(pset.profile("default").get("region"), "us-west-2")
    assert_false(pset.profile("default").has("indented"))
    assert_false(pset.profile("default").has("loose"))


def main() raises:
    var failed = 0
    try:
        test_container_full_uri()
    except e:
        print("FAIL test_container_full_uri:", e)
        failed += 1
    try:
        test_container_response()
    except e:
        print("FAIL test_container_response:", e)
        failed += 1
    try:
        test_imds()
    except e:
        print("FAIL test_imds:", e)
        failed += 1
    try:
        test_sts_regions()
    except e:
        print("FAIL test_sts_regions:", e)
        failed += 1
    try:
        test_sts_builders()
    except e:
        print("FAIL test_sts_builders:", e)
        failed += 1
    try:
        test_sts_parser()
    except e:
        print("FAIL test_sts_parser:", e)
        failed += 1
    try:
        test_expiration_and_profiles()
    except e:
        print("FAIL test_expiration_and_profiles:", e)
        failed += 1
    if failed > 0:
        raise Error(String(failed) + " test(s) failed")
    print("OK")
