# Where komira_aws_s3 sends a request: S3's published endpoint ruleset,
# embedded in the generated module, chooses the URL (the bucket in the host
# or in the path), and the request target is the operation's path joined to
# it. Rows: virtual-host addressing by default, path style for a bucket that
# cannot be a host name under TLS and when `force_path_style` is set, a
# custom endpoint (LocalStack, MinIO, a path behind a proxy), the ruleset's
# refusals, and the whole send-side chain -- built, resolved, signed --
# checked against the signatures AWS publishes for its SigV4 examples
# ("Signature Calculations for the Authorization Header: Transferring
# Payload in a Single Chunk": GET Object, and GET Bucket (List Objects)).
from komira_aws_s3.komira_aws_s3 import (
    S3EndpointConfig,
    S3GetObjectRequest,
    S3ListBucketsRequest,
    S3ListObjectsRequest,
    S3ListObjectsV2Request,
    S3PutObjectRequest,
    build_get_object_request,
    build_list_buckets_request,
    build_list_objects_request,
    build_list_objects_v2_request,
    build_put_object_request,
    komira_aws_s3_endpoint_rules,
    resolve_get_object_endpoint,
    resolve_list_buckets_endpoint,
    resolve_list_objects_endpoint,
    resolve_list_objects_v2_endpoint,
    resolve_put_object_endpoint,
)
from komira_aws_core import (
    AwsCredential,
    AwsRequest,
    CredentialHttpRequest,
    EndpointRuleSet,
    FixedClock,
    Header,
    ResolvedEndpoint,
    aws_signing_target,
    build_sigv4_signed_request,
)
from std.testing import assert_equal, assert_raises, assert_true


def _config(region: String) -> S3EndpointConfig:
    return S3EndpointConfig(region)


def _get(
    rules: EndpointRuleSet, config: S3EndpointConfig, bucket: String
) raises -> String:
    return resolve_get_object_endpoint(
        rules, config, S3GetObjectRequest(bucket, String("k"))
    ).url


def _url(resolved: ResolvedEndpoint, req: AwsRequest) raises -> String:
    """The URL the request goes to: the resolved endpoint with the request
    target joined to it, as the signer joins them."""
    var t = aws_signing_target(resolved, String("us-east-1"), String("s3"))
    return t.endpoint.url_for(req.uri)


# ---- addressing ------------------------------------------------------------------


def test_virtual_host_by_default() raises:
    var rules = komira_aws_s3_endpoint_rules()
    var config = _config(String("us-west-2"))
    var input = S3GetObjectRequest(String("lake"), String("data/a.parquet"))
    var resolved = resolve_get_object_endpoint(rules, config, input)
    assert_equal(resolved.url, "https://lake.s3.us-west-2.amazonaws.com")
    var t = aws_signing_target(resolved, String("us-east-1"), String("s3"))
    # Signed for the bucket's region, under `s3`.
    assert_equal(t.signing_name, "s3")
    assert_equal(t.signing_region, "us-west-2")
    var req = build_get_object_request(input)
    assert_equal(
        t.endpoint.url_for(req.uri),
        "https://lake.s3.us-west-2.amazonaws.com/data/a.parquet",
    )


def test_force_path_style() raises:
    var rules = komira_aws_s3_endpoint_rules()
    var config = _config(String("us-west-2"))
    config.force_path_style = Optional[Bool](True)
    var input = S3GetObjectRequest(String("lake"), String("data/a.parquet"))
    var resolved = resolve_get_object_endpoint(rules, config, input)
    assert_equal(resolved.url, "https://s3.us-west-2.amazonaws.com/lake")
    assert_equal(
        _url(resolved, build_get_object_request(input)),
        "https://s3.us-west-2.amazonaws.com/lake/data/a.parquet",
    )
    # A bucket-level operation: the root with a query keeps the bucket path
    # with no '/' after it.
    var list_input = S3ListObjectsV2Request(String("lake"))
    list_input.set_prefix(String("data/"))
    var list_resolved = resolve_list_objects_v2_endpoint(rules, config, list_input)
    assert_equal(
        _url(list_resolved, build_list_objects_v2_request(list_input)),
        "https://s3.us-west-2.amazonaws.com/lake?list-type=2&prefix=data%2F",
    )


def test_a_bucket_that_cannot_be_a_host_name_is_path_style() raises:
    var rules = komira_aws_s3_endpoint_rules()
    var config = _config(String("us-west-2"))
    # Dots would not match the wildcard TLS certificate.
    assert_equal(
        _get(rules, config, String("my.lake")),
        "https://s3.us-west-2.amazonaws.com/my.lake",
    )
    # Upper case and '_' are not DNS-compatible.
    assert_equal(
        _get(rules, config, String("Lake_Upper")),
        "https://s3.us-west-2.amazonaws.com/Lake_Upper",
    )


def test_us_east_1_global_endpoint() raises:
    var rules = komira_aws_s3_endpoint_rules()
    var config = _config(String("us-east-1"))
    assert_equal(
        _get(rules, config, String("lake")), "https://lake.s3.us-east-1.amazonaws.com"
    )
    config.use_global_endpoint = Optional[Bool](True)
    assert_equal(_get(rules, config, String("lake")), "https://lake.s3.amazonaws.com")


def test_an_operation_without_a_bucket() raises:
    var rules = komira_aws_s3_endpoint_rules()
    var input = S3ListBucketsRequest()
    var resolved = resolve_list_buckets_endpoint(
        rules, _config(String("us-west-2")), input
    )
    assert_equal(resolved.url, "https://s3.us-west-2.amazonaws.com")
    assert_equal(
        _url(resolved, build_list_buckets_request(input)),
        "https://s3.us-west-2.amazonaws.com/",
    )


# ---- custom endpoints ------------------------------------------------------------


def test_localstack_path_style() raises:
    var rules = komira_aws_s3_endpoint_rules()
    var config = _config(String("us-east-1"))
    config.endpoint = Optional[String](String("http://localhost:4566"))
    config.force_path_style = Optional[Bool](True)
    var put = S3PutObjectRequest(String("lake"), String("a/b.txt"))
    var resolved = resolve_put_object_endpoint(rules, config, put)
    assert_equal(resolved.url, "http://localhost:4566/lake")
    var t = aws_signing_target(resolved, String("us-east-1"), String("s3"))
    assert_equal(t.endpoint.host_header(), "localhost:4566")
    assert_equal(
        t.endpoint.url_for(build_put_object_request(put).uri),
        "http://localhost:4566/lake/a/b.txt",
    )
    var list_input = S3ListObjectsV2Request(String("lake"))
    var list_resolved = resolve_list_objects_v2_endpoint(rules, config, list_input)
    assert_equal(
        _url(list_resolved, build_list_objects_v2_request(list_input)),
        "http://localhost:4566/lake?list-type=2",
    )


def test_custom_endpoint_keeps_the_rulesets_addressing() raises:
    # With `force_path_style` unset, a bucket that can be a host name is
    # addressed by virtual host on a custom endpoint too: a caller of an
    # endpoint that serves only path style sets it.
    var rules = komira_aws_s3_endpoint_rules()
    var config = _config(String("us-east-1"))
    config.endpoint = Optional[String](String("http://localhost:4566"))
    assert_equal(_get(rules, config, String("lake")), "http://lake.localhost:4566")
    # Over plain HTTP a dotted bucket is a host name as well.
    assert_equal(
        _get(rules, config, String("my.lake")), "http://my.lake.localhost:4566"
    )


def test_minio_ip_endpoint_is_path_style() raises:
    # An IP-literal endpoint cannot take the bucket as a host label.
    var rules = komira_aws_s3_endpoint_rules()
    var config = _config(String("us-east-1"))
    config.endpoint = Optional[String](String("http://127.0.0.1:9000"))
    var input = S3GetObjectRequest(String("lake"), String("x.bin"))
    var resolved = resolve_get_object_endpoint(rules, config, input)
    assert_equal(resolved.url, "http://127.0.0.1:9000/lake")
    assert_equal(
        _url(resolved, build_get_object_request(input)),
        "http://127.0.0.1:9000/lake/x.bin",
    )


def test_custom_endpoint_with_a_path() raises:
    var rules = komira_aws_s3_endpoint_rules()
    var config = _config(String("us-east-1"))
    config.endpoint = Optional[String](String("https://objects.example.com/s3"))
    config.force_path_style = Optional[Bool](True)
    var input = S3GetObjectRequest(String("lake"), String("k"))
    var resolved = resolve_get_object_endpoint(rules, config, input)
    assert_equal(resolved.url, "https://objects.example.com/s3/lake")
    assert_equal(
        _url(resolved, build_get_object_request(input)),
        "https://objects.example.com/s3/lake/k",
    )


def test_ruleset_refusals_are_raised() raises:
    var rules = komira_aws_s3_endpoint_rules()
    var config = _config(String("us-east-1"))
    config.endpoint = Optional[String](String("http://localhost:4566"))
    config.use_fips = Optional[Bool](True)
    with assert_raises(contains="A custom endpoint cannot be combined with FIPS"):
        _ = _get(rules, config, String("lake"))
    var dual = _config(String("us-east-1"))
    dual.endpoint = Optional[String](String("http://localhost:4566"))
    dual.use_dual_stack = Optional[Bool](True)
    with assert_raises(contains="dual-stack"):
        _ = _get(rules, dual, String("lake"))


# ---- signed, against AWS's published examples ----------------------------------

comptime _KEY = "AKIAIOSFODNN7EXAMPLE"
comptime _SECRET = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
# The examples' x-amz-date, in Unix seconds.
comptime _NOW = 1369353600


def _signed(req: AwsRequest, resolved: ResolvedEndpoint) raises -> CredentialHttpRequest:
    """`req` signed for `resolved` at the examples' time and with their
    credentials: the endpoint's headers, then the operation's, as extra
    headers; Content-Type in its own argument."""
    var t = aws_signing_target(resolved, String("us-east-1"), String("s3"))
    var extra = List[Header]()
    for i in range(len(t.header_names)):
        extra.append(Header(t.header_names[i], t.header_values[i]))
    var content_type = String("")
    for i in range(len(req.header_names)):
        if req.header_names[i] == "Content-Type":
            content_type = req.header_values[i]
        else:
            extra.append(Header(req.header_names[i], req.header_values[i]))
    var clock = FixedClock(_NOW)
    return build_sigv4_signed_request(
        req.method,
        AwsCredential(String(_KEY), String(_SECRET), String("")),
        t.signing_region,
        t.signing_name,
        t.endpoint,
        req.uri,
        content_type,
        Span(req.body),
        extra,
        clock,
    )


def _example_config() -> S3EndpointConfig:
    # The examples' host is examplebucket.s3.amazonaws.com: us-east-1 on
    # the global endpoint.
    var config = _config(String("us-east-1"))
    config.use_global_endpoint = Optional[Bool](True)
    return config^


def _expect(req: CredentialHttpRequest, signed_headers: String, signature: String) raises:
    var auth = req.header("Authorization")
    assert_true(
        auth.startswith("AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/"), auth
    )
    assert_true(auth.find("/us-east-1/s3/aws4_request,") > 0, auth)
    assert_true(auth.find("SignedHeaders=" + signed_headers + ",") > 0, auth)
    assert_true(auth.endswith("Signature=" + signature), auth)


def test_signed_get_object_example() raises:
    # GET /test.txt, Range: bytes=0-9.
    var input = S3GetObjectRequest(String("examplebucket"), String("test.txt"))
    input.set_range_(String("bytes=0-9"))
    var resolved = resolve_get_object_endpoint(
        komira_aws_s3_endpoint_rules(), _example_config(), input
    )
    assert_equal(resolved.url, "https://examplebucket.s3.amazonaws.com")
    var req = _signed(build_get_object_request(input), resolved)
    assert_equal(req.method, "GET")
    assert_equal(req.scheme, "https")
    assert_equal(req.host, "examplebucket.s3.amazonaws.com")
    assert_equal(req.target, "/test.txt")
    assert_equal(req.header("Host"), "examplebucket.s3.amazonaws.com")
    assert_equal(req.header("Range"), "bytes=0-9")
    assert_equal(
        req.header("x-amz-content-sha256"),
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    )
    _expect(
        req,
        String("host;range;x-amz-content-sha256;x-amz-date"),
        String("f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"),
    )


def test_signed_list_objects_example() raises:
    # GET /?max-keys=2&prefix=J: a bucket-level request, its target the
    # root with the query.
    var input = S3ListObjectsRequest(String("examplebucket"))
    input.set_max_keys(Int32(2))
    input.set_prefix(String("J"))
    var resolved = resolve_list_objects_endpoint(
        komira_aws_s3_endpoint_rules(), _example_config(), input
    )
    var req = _signed(build_list_objects_request(input), resolved)
    assert_equal(req.target, "/?max-keys=2&prefix=J")
    assert_equal(req.header("Host"), "examplebucket.s3.amazonaws.com")
    _expect(
        req,
        String("host;x-amz-content-sha256;x-amz-date"),
        String("34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7"),
    )


def test_signed_path_style() raises:
    # The same object path style: the bucket moves into the target, and the
    # signature with it.
    var input = S3GetObjectRequest(String("examplebucket"), String("test.txt"))
    input.set_range_(String("bytes=0-9"))
    var config = _example_config()
    config.force_path_style = Optional[Bool](True)
    var resolved = resolve_get_object_endpoint(
        komira_aws_s3_endpoint_rules(), config, input
    )
    var req = _signed(build_get_object_request(input), resolved)
    assert_equal(req.host, "s3.amazonaws.com")
    assert_equal(req.target, "/examplebucket/test.txt")
    assert_true(
        not req.header("Authorization").endswith(
            "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
        )
    )


def main() raises:
    test_virtual_host_by_default()
    test_force_path_style()
    test_a_bucket_that_cannot_be_a_host_name_is_path_style()
    test_us_east_1_global_endpoint()
    test_an_operation_without_a_bucket()
    test_localstack_path_style()
    test_custom_endpoint_keeps_the_rulesets_addressing()
    test_minio_ip_endpoint_is_path_style()
    test_custom_endpoint_with_a_path()
    test_ruleset_refusals_are_raised()
    test_signed_get_object_example()
    test_signed_list_objects_example()
    test_signed_path_style()
    print("OK")
