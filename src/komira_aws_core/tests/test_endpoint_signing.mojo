# A resolved endpoint as the signer takes it (endpoint_signing.mojo).
#
# The scheme choice is botocore's with no scheme requested
# (`auth_schemes_to_signing_ctx`, botocore/regions.py): the first scheme of
# the list that can be signed, which here is `sigv4` alone, and a refusal
# naming the offered schemes when there is none. The `authSchemes` values
# below are the shapes S3's published ruleset answers with: plain S3, a
# Multi-Region Access Point (`sigv4a`), an Outposts bucket (`sigv4a` then
# `sigv4` under `s3-outposts`) and an S3 Express bucket (`sigv4-s3express`).

from std.testing import assert_equal, assert_true

from komira_json import JsonValue, parse_json_value

from komira_aws_core import ResolvedEndpoint, aws_signing_target


def _endpoint(url: String, properties: String) raises -> ResolvedEndpoint:
    return ResolvedEndpoint(
        url, JsonValue.empty_object(), parse_json_value(properties)
    )


def _refused(r: ResolvedEndpoint, want: String) raises:
    try:
        _ = aws_signing_target(r, "us-east-1", "s3")
    except e:
        if String(e).find(want) < 0:
            raise Error("refused with '" + String(e) + "', not '" + want + "'")
        return
    raise Error("not refused; expected '" + want + "'")


def test_no_auth_schemes_signs_as_the_client() raises:
    var r = _endpoint("https://logs.us-east-1.amazonaws.com", "{}")
    var t = aws_signing_target(r, "us-east-1", "logs")
    assert_equal(t.signing_name, "logs")
    assert_equal(t.signing_region, "us-east-1")
    assert_equal(t.endpoint.host, "logs.us-east-1.amazonaws.com")
    assert_equal(t.endpoint.port, 443)
    assert_equal(len(t.header_names), 0)


def test_sigv4_scheme_names_the_signer() raises:
    var r = _endpoint(
        "https://bucket-name.s3.us-west-2.amazonaws.com",
        '{"authSchemes": [{"name": "sigv4", "signingName": "s3",'
        ' "signingRegion": "us-west-2", "disableDoubleEncoding": true}]}',
    )
    # The scheme's region and name win over the client's.
    var t = aws_signing_target(r, "us-east-1", "s3")
    assert_equal(t.signing_name, "s3")
    assert_equal(t.signing_region, "us-west-2")
    assert_equal(t.endpoint.host, "bucket-name.s3.us-west-2.amazonaws.com")
    assert_equal(t.endpoint.target_for("/key"), "/key")


def test_path_style_url_is_the_base_path() raises:
    var r = _endpoint(
        "http://127.0.0.1:9000/bucket-name",
        '{"authSchemes": [{"name": "sigv4", "signingName": "s3",'
        ' "signingRegion": "us-east-1", "disableDoubleEncoding": true}]}',
    )
    var t = aws_signing_target(r, "us-east-1", "s3")
    assert_equal(t.endpoint.scheme, "http")
    assert_equal(t.endpoint.host, "127.0.0.1")
    assert_equal(t.endpoint.port, 9000)
    assert_equal(t.endpoint.target_for("/a/b.txt"), "/bucket-name/a/b.txt")


def test_first_signable_scheme_is_chosen() raises:
    # A list offering sigv4a first: sigv4 is the one that can be signed.
    var r = _endpoint(
        "https://bucket-name.s3.us-east-1.amazonaws.com",
        '{"authSchemes": [{"name": "sigv4a", "signingName": "s3",'
        ' "signingRegionSet": ["*"], "disableDoubleEncoding": true},'
        ' {"name": "sigv4", "signingName": "s3", "signingRegion": "us-east-1",'
        ' "disableDoubleEncoding": true}]}',
    )
    var t = aws_signing_target(r, "us-east-1", "s3")
    assert_equal(t.signing_name, "s3")
    assert_equal(t.signing_region, "us-east-1")
    # A namespaced name is the same scheme.
    var n = _endpoint(
        "https://logs.us-east-1.amazonaws.com",
        '{"authSchemes": [{"name": "aws.auth#sigv4", "signingName": "logs"}]}',
    )
    assert_equal(aws_signing_target(n, "us-east-1", "logs").signing_name, "logs")


def test_unsignable_schemes_are_refused_by_name() raises:
    _refused(
        _endpoint(
            "https://mfzwi23gnjvgw.mrap.accesspoint.s3-global.amazonaws.com",
            '{"authSchemes": [{"name": "sigv4a", "signingName": "s3",'
            ' "signingRegionSet": ["*"], "disableDoubleEncoding": true}]}',
        ),
        "auth scheme(s) sigv4a, and komira_aws_core signs sigv4 only",
    )
    _refused(
        _endpoint(
            "https://mybucket--usw2-az1--x-s3.s3express-usw2-az1.us-west-2.amazonaws.com",
            '{"authSchemes": [{"name": "sigv4-s3express", "signingName":'
            ' "s3express", "signingRegion": "us-west-2",'
            ' "disableDoubleEncoding": true}]}',
        ),
        "auth scheme(s) sigv4-s3express,",
    )


def test_double_encoding_mismatch_is_refused() raises:
    # sigv4 under `s3-outposts` without double encoding: the signer encodes
    # twice for any name but s3, so it is refused rather than signed wrongly.
    _refused(
        _endpoint(
            "https://op-01234567890123456.s3-outposts.us-west-2.amazonaws.com",
            '{"authSchemes": [{"name": "sigv4a", "signingName": "s3-outposts",'
            ' "signingRegionSet": ["*"], "disableDoubleEncoding": true},'
            ' {"name": "sigv4", "signingName": "s3-outposts",'
            ' "signingRegion": "us-west-2", "disableDoubleEncoding": true}]}',
        ),
        "disableDoubleEncoding to true for the signing name s3-outposts",
    )
    # And s3 with double encoding left on.
    _refused(
        _endpoint(
            "https://s3.us-east-1.amazonaws.com",
            '{"authSchemes": [{"name": "sigv4", "signingName": "s3"}]}',
        ),
        "disableDoubleEncoding to false for the signing name s3",
    )


def test_headers_are_carried() raises:
    var headers = parse_json_value('{"x-amz-a": ["1", "2"], "x-amz-b": ["3"]}')
    var r = ResolvedEndpoint(
        String("https://logs.us-east-1.amazonaws.com"),
        headers^,
        JsonValue.empty_object(),
    )
    var t = aws_signing_target(r, "us-east-1", "logs")
    assert_equal(len(t.header_names), 3)
    assert_equal(t.header_names[0], "x-amz-a")
    assert_equal(t.header_values[1], "2")
    assert_equal(t.header_names[2], "x-amz-b")
    assert_equal(t.header_values[2], "3")


def test_no_region_is_refused() raises:
    var r = _endpoint("https://logs.example.com", "{}")
    try:
        _ = aws_signing_target(r, "", "logs")
    except e:
        assert_true(String(e).find("no signing region") >= 0)
        return
    raise Error("an endpoint with no signing region was accepted")


def main() raises:
    test_no_auth_schemes_signs_as_the_client()
    test_sigv4_scheme_names_the_signer()
    test_path_style_url_is_the_base_path()
    test_first_signable_scheme_is_chosen()
    test_unsignable_schemes_are_refused_by_name()
    test_double_encoding_mismatch_is_refused()
    test_headers_are_carried()
    test_no_region_is_refused()
    print("OK")
