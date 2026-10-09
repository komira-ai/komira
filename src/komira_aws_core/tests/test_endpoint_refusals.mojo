# =============================================================================
# komira_aws_core/tests/test_endpoint_refusals.mojo
# =============================================================================
#
# Endpoint values on the inputs the resolution tests do not reach: the host
# rules of AwsEndpoint (IPv6 literals, a leading or trailing '-' or '.',
# ports), the partition of each `<partition>-global` pseudo region and of
# region names that only resemble a partition's shape (botocore's
# partitions.json regionRegex, a region no shape claims being in "aws"),
# and the signing target's refusals of auth-scheme and header values of the
# wrong JSON kind.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_json import JsonValue, parse_json_value

from komira_aws_core import (
    AwsEndpoint,
    ResolvedEndpoint,
    aws_partition_for_region,
    aws_signing_target,
)


def _https_refused(host: String, want: String) raises:
    try:
        _ = AwsEndpoint.https(host)
    except e:
        assert_equal(String(e), "the endpoint " + want, host)
        return
    raise Error("endpoint host accepted: " + host)


def _parse_refused(url: String, want: String) raises:
    try:
        _ = AwsEndpoint.parse(url, "S")
    except e:
        assert_equal(String(e), "the endpoint URL from S " + want, url)
        return
    raise Error("endpoint URL accepted: " + url)


def test_endpoint_hosts() raises:
    assert_equal(AwsEndpoint.https("[::1]").host, "[::1]")
    assert_true(AwsEndpoint.https("a.b").is_https())
    _https_refused("[::1", "has an unterminated IPv6 literal")
    _https_refused("[]", "has an unterminated IPv6 literal")
    _https_refused("[::g]", "has a malformed IPv6 literal")
    _https_refused("[::1 ]", "has a malformed IPv6 literal")
    _https_refused("-a.example", "has a host starting with '-' or '.'")
    _https_refused(".a.example", "has a host starting with '-' or '.'")
    _https_refused("a.example-", "has a host ending with '-'")
    _parse_refused("http://h:/", "has a malformed port")
    _parse_refused("http://h:123456/", "has a malformed port")
    _parse_refused("http://h:8x/", "has a malformed port")
    _parse_refused("http://[::1]x/", "has text after the IPv6 literal")
    var v6 = AwsEndpoint.parse("http://[::1]:8080/p", "S")
    assert_equal(v6.host, "[::1]")
    assert_equal(v6.port, 8080)
    assert_false(v6.is_https())


def test_partitions_by_region() raises:
    assert_equal(aws_partition_for_region("aws-iso-global").id, "aws-iso")
    assert_equal(aws_partition_for_region("aws-iso-b-global").id, "aws-iso-b")
    assert_equal(aws_partition_for_region("aws-iso-e-global").id, "aws-iso-e")
    assert_equal(aws_partition_for_region("aws-iso-f-global").id, "aws-iso-f")
    assert_equal(aws_partition_for_region("aws-iso-global").dns_suffix, "c2s.ic.gov")
    assert_equal(aws_partition_for_region("us-isof-south-1").id, "aws-iso-f")
    # Four dash-separated parts whose third is not a word or whose fourth is
    # not a number match no partition's shape: "aws".
    assert_equal(aws_partition_for_region("us-gov-west-1").id, "aws-us-gov")
    assert_equal(aws_partition_for_region("us-gov--1").id, "aws")
    assert_equal(aws_partition_for_region("us-gov-we.t-1").id, "aws")
    assert_equal(aws_partition_for_region("us-gov-west-").id, "aws")
    assert_equal(aws_partition_for_region("us-gov-west-1a").id, "aws")
    assert_equal(aws_partition_for_region("cn-north-x").id, "aws")
    assert_equal(aws_partition_for_region("cn-north-1").id, "aws-cn")


def _target_refused(url: String, props: String, headers: String, want: String) raises:
    var r = ResolvedEndpoint(url, parse_json_value(headers), parse_json_value(props))
    try:
        _ = aws_signing_target(r, "us-east-1", "logs")
    except e:
        assert_equal(String(e), want)
        return
    raise Error("signing target accepted: " + props + " " + headers)


comptime _URL = "https://logs.us-east-1.amazonaws.com"


def test_signing_target_kinds() raises:
    # A scheme that is not an object, or whose name is not a string, has no
    # name: it is offered as "(unnamed)" and is not signable.
    _target_refused(
        _URL, '{"authSchemes": ["sigv4"]}', "{}",
        "the endpoint must be signed with the auth scheme(s) (unnamed), and"
        " komira_aws_core signs sigv4 only",
    )
    _target_refused(
        _URL, '{"authSchemes": [{"name": 4}]}', "{}",
        "the endpoint must be signed with the auth scheme(s) (unnamed), and"
        " komira_aws_core signs sigv4 only",
    )
    _target_refused(
        _URL, '{"authSchemes": [{"name": "sigv4", "signingName": 1}]}', "{}",
        "the endpoint's sigv4 auth scheme has a signingName that is not a string",
    )
    _target_refused(
        _URL, '{"authSchemes": [{"name": "sigv4", "signingRegion": true}]}', "{}",
        "the endpoint's sigv4 auth scheme has a signingRegion that is not a string",
    )
    _target_refused(
        _URL, '{"authSchemes": [{"name": "sigv4", "disableDoubleEncoding": "true"}]}',
        "{}",
        "the endpoint's sigv4 auth scheme has a disableDoubleEncoding that is"
        " not a boolean",
    )
    _target_refused(
        _URL, "{}", '{"x-a": "1"}', "the endpoint header x-a is not a list"
    )
    _target_refused(
        _URL, "{}", '{"x-a": ["1", 2]}',
        "the endpoint header x-a has a value that is not a string",
    )


def main() raises:
    var failed = 0
    try:
        test_endpoint_hosts()
    except e:
        print("FAIL test_endpoint_hosts:", e)
        failed += 1
    try:
        test_partitions_by_region()
    except e:
        print("FAIL test_partitions_by_region:", e)
        failed += 1
    try:
        test_signing_target_kinds()
    except e:
        print("FAIL test_signing_target_kinds:", e)
        failed += 1
    if failed > 0:
        raise Error(String(failed) + " test(s) failed")
    print("OK")
