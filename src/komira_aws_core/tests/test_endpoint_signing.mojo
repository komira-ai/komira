# A resolved endpoint as the signer takes it (endpoint_signing.mojo).
#
# The scheme choice is botocore's with no scheme requested and without its
# CRT extra (`auth_schemes_to_signing_ctx`, botocore/regions.py): the first
# scheme of the list botocore has a signer for, by its exact name, which
# must be `sigv4`; otherwise a refusal naming the offered schemes. The
# `authSchemes` values below are the shapes S3's published ruleset answers
# with: plain S3, a Multi-Region Access Point (`sigv4a`), an Outposts
# bucket (`sigv4a` then `sigv4` under `s3-outposts`), an S3 Express bucket
# (`sigv4-s3express`, or `sigv4` under `s3express` with session auth
# disabled) and an Object Lambda access point (`s3-object-lambda`).

from std.testing import assert_equal, assert_true

from komira_json import JsonValue, parse_json_value

from komira_aws_core import ResolvedEndpoint, aws_signing_target, is_s3_signing_name


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
    # A list offering sigv4a first: botocore has no sigv4a signer without
    # its CRT extra, so sigv4 is the first it can sign.
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
    # botocore signs the first of sigv4-s3express and sigv4 it meets, so a
    # sigv4 after a sigv4-s3express is not reached.
    _refused(
        _endpoint(
            "https://mybucket--usw2-az1--x-s3.s3express-usw2-az1.us-west-2.amazonaws.com",
            '{"authSchemes": [{"name": "sigv4-s3express", "signingName":'
            ' "s3express", "signingRegion": "us-west-2"},'
            ' {"name": "sigv4", "signingName": "s3express",'
            ' "signingRegion": "us-west-2"}]}',
        ),
        "auth scheme(s) sigv4-s3express, sigv4, and",
    )
    # A namespaced name is not botocore's `sigv4`.
    _refused(
        _endpoint(
            "https://logs.us-east-1.amazonaws.com",
            '{"authSchemes": [{"name": "aws.auth#sigv4", "signingName": "logs"}]}',
        ),
        "auth scheme(s) aws.auth#sigv4, and",
    )


def test_s3_signing_names_sign_once() raises:
    # sigv4 under each S3 signing name is signed, as botocore signs it with
    # S3SigV4Auth: the name and region are the scheme's.
    var cases: List[String] = [
        "s3-outposts",
        "s3express",
        "s3-object-lambda",
    ]
    for i in range(len(cases)):
        var r = _endpoint(
            "https://bucket.example.us-west-2.amazonaws.com",
            '{"authSchemes": [{"name": "sigv4a", "signingName": "'
            + cases[i]
            + '", "signingRegionSet": ["*"], "disableDoubleEncoding": true},'
            + ' {"name": "sigv4", "signingName": "'
            + cases[i]
            + '", "signingRegion": "us-west-2", "disableDoubleEncoding": true}]}',
        )
        var t = aws_signing_target(r, "us-east-1", "s3")
        assert_equal(t.signing_name, cases[i])
        assert_equal(t.signing_region, "us-west-2")
        assert_true(is_s3_signing_name(t.signing_name))
    # An absent disableDoubleEncoding is the signer's own rule for the name,
    # as botocore never reads the flag: s3 signs once, logs twice.
    var s3 = aws_signing_target(
        _endpoint(
            "https://s3.us-east-1.amazonaws.com",
            '{"authSchemes": [{"name": "sigv4", "signingName": "s3"}]}',
        ),
        "us-east-1",
        "s3",
    )
    assert_equal(s3.signing_name, "s3")
    assert_true(not is_s3_signing_name("logs"))


def test_double_encoding_against_the_signer_is_refused() raises:
    # A flag stating the other encoding than the signer's for the name.
    _refused(
        _endpoint(
            "https://s3.us-east-1.amazonaws.com",
            '{"authSchemes": [{"name": "sigv4", "signingName": "s3",'
            ' "disableDoubleEncoding": false}]}',
        ),
        "disableDoubleEncoding to false for the signing name s3,",
    )
    _refused(
        _endpoint(
            "https://logs.us-east-1.amazonaws.com",
            '{"authSchemes": [{"name": "sigv4", "signingName": "logs",'
            ' "disableDoubleEncoding": true}]}',
        ),
        "disableDoubleEncoding to true for the signing name logs,",
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
    test_s3_signing_names_sign_once()
    test_double_encoding_against_the_signer_is_refused()
    test_headers_are_carried()
    test_no_region_is_refused()
    print("OK")
