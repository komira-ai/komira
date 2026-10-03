# Where komira_aws_s3 sends a request: S3's published endpoint ruleset,
# embedded in the generated module, chooses the URL (the bucket in the host
# or in the path), and the request target is the operation's path joined to
# it. Rows: virtual-host addressing by default, path style for a bucket that
# cannot be a host name under TLS and when `force_path_style` is set, a
# custom endpoint (LocalStack, MinIO, a path behind a proxy), the ruleset's
# refusals, and the whole send-side chain -- built, resolved, signed --
# checked against the signatures AWS publishes for its SigV4 examples
# ("Signature Calculations for the Authorization Header: Transferring
# Payload in a Single Chunk": GET Object, PUT Object, GET Bucket Lifecycle
# and GET Bucket (List Objects)).
#
# The other signed rows (path style, PutObject as the client sends it,
# HEAD, DELETE, POST ?uploads and DeleteObjects' POST ?delete) have no
# published example. Their signatures were computed with an independent
# SigV4 implementation that reproduces all four published examples, at the
# examples' time and with their credentials; each row states the canonical
# request it signs.
from komira_aws_s3.komira_aws_s3 import (
    S3_STORAGE_CLASS_REDUCED_REDUNDANCY,
    S3CreateMultipartUploadRequest,
    S3Delete,
    S3DeleteObjectRequest,
    S3DeleteObjectsRequest,
    S3EndpointConfig,
    S3GetObjectRequest,
    S3HeadObjectRequest,
    S3ListBucketsRequest,
    S3ListObjectsRequest,
    S3ListObjectsV2Request,
    S3ObjectIdentifier,
    S3PutObjectRequest,
    build_create_multipart_upload_request,
    build_delete_object_request,
    build_delete_objects_request,
    build_get_object_request,
    build_head_object_request,
    build_list_buckets_request,
    build_list_objects_request,
    build_list_objects_v2_request,
    build_put_object_request,
    komira_aws_s3_endpoint_rules,
    resolve_create_multipart_upload_endpoint,
    resolve_delete_object_endpoint,
    resolve_delete_objects_endpoint,
    resolve_get_object_endpoint,
    resolve_head_object_endpoint,
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


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


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


def test_signed_put_object_example() raises:
    # PUT /test$file.text, x-amz-storage-class: REDUCED_REDUNDANCY, a Date
    # header, body "Welcome to Amazon S3.". The example predates default
    # request checksums and sends no Content-Type, so this row drops the
    # three headers the client adds that it lacks (Content-Type and the two
    # checksum headers, checked in test_signed_put_object_as_sent) and adds
    # its Date. Everything else is the client's: the '$' encoded in the
    # target, the storage-class header and the body's hash.
    var input = S3PutObjectRequest(String("examplebucket"), String("test$file.text"))
    input.set_body(_bytes(String("Welcome to Amazon S3.")))
    input.set_storage_class(String(S3_STORAGE_CLASS_REDUCED_REDUNDANCY))
    var resolved = resolve_put_object_endpoint(
        komira_aws_s3_endpoint_rules(), _example_config(), input
    )
    var built = build_put_object_request(input)
    var req = AwsRequest(built.method, built.uri)
    req.body = built.body.copy()
    var dropped = 0
    for i in range(len(built.header_names)):
        var name = built.header_names[i]
        if (
            name == "Content-Type"
            or name == "x-amz-sdk-checksum-algorithm"
            or name == "x-amz-checksum-crc32"
        ):
            dropped += 1
        else:
            req.set_header(name, built.header_values[i])
    assert_equal(dropped, 3)
    req.set_header(String("Date"), String("Fri, 24 May 2013 00:00:00 GMT"))
    var signed = _signed(req, resolved)
    assert_equal(signed.target, "/test%24file.text")
    assert_equal(
        signed.header("x-amz-content-sha256"),
        "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072",
    )
    _expect(
        signed,
        String("date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class"),
        String("98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"),
    )


def test_signed_put_object_as_sent() raises:
    # The same object as the client sends it. Canonical request:
    #   PUT
    #   /test%24file.text
    #
    #   content-type:application/octet-stream
    #   host:examplebucket.s3.amazonaws.com
    #   x-amz-checksum-crc32:Ox7nCg==
    #   x-amz-content-sha256:44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072
    #   x-amz-date:20130524T000000Z
    #   x-amz-sdk-checksum-algorithm:CRC32
    #   x-amz-storage-class:REDUCED_REDUNDANCY
    #
    #   <signed headers>
    #   44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072
    var input = S3PutObjectRequest(String("examplebucket"), String("test$file.text"))
    input.set_body(_bytes(String("Welcome to Amazon S3.")))
    input.set_storage_class(String(S3_STORAGE_CLASS_REDUCED_REDUNDANCY))
    var resolved = resolve_put_object_endpoint(
        komira_aws_s3_endpoint_rules(), _example_config(), input
    )
    var req = _signed(build_put_object_request(input), resolved)
    assert_equal(req.header("x-amz-checksum-crc32"), "Ox7nCg==")
    assert_equal(req.header("Content-Length"), "21")
    _expect(
        req,
        String(
            "content-type;host;x-amz-checksum-crc32;x-amz-content-sha256;"
            + "x-amz-date;x-amz-sdk-checksum-algorithm;x-amz-storage-class"
        ),
        String("f24b18f7f6b884ca3368c3f97eb63b744cdd21c2b7210faaff806c4b60d1bef2"),
    )


def test_signed_get_bucket_lifecycle_example() raises:
    # GET /?lifecycle: a query-only root with a key that has no value,
    # joined to the bucket's virtual host and signed as `lifecycle=`. The
    # client does not build GetBucketLifecycleConfiguration; the request is
    # written out, and resolved as a bucket-level operation is.
    var resolved = resolve_list_objects_endpoint(
        komira_aws_s3_endpoint_rules(),
        _example_config(),
        S3ListObjectsRequest(String("examplebucket")),
    )
    var req = _signed(AwsRequest(String("GET"), String("/?lifecycle")), resolved)
    assert_equal(req.host, "examplebucket.s3.amazonaws.com")
    assert_equal(req.target, "/?lifecycle")
    _expect(
        req,
        String("host;x-amz-content-sha256;x-amz-date"),
        String("fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543"),
    )


def test_signed_path_style() raises:
    # The GET Object example path style: the bucket moves into the target,
    # and the signature with it. Canonical request:
    #   GET
    #   /examplebucket/test.txt
    #
    #   host:s3.amazonaws.com
    #   range:bytes=0-9
    #   x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    #   x-amz-date:20130524T000000Z
    #
    #   host;range;x-amz-content-sha256;x-amz-date
    #   e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
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
    assert_equal(req.header("Host"), "s3.amazonaws.com")
    _expect(
        req,
        String("host;range;x-amz-content-sha256;x-amz-date"),
        String("819484c483cfb97d16522b1ac156f87e61677cc8f1f2545c799650ef178f4aa8"),
    )


# Each of these signs host, x-amz-content-sha256 (the empty body's hash)
# and x-amz-date only; the canonical request is
#   <method>
#   <path>
#   <query>
#   host:examplebucket.s3.amazonaws.com
#   x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
#   x-amz-date:20130524T000000Z
#
#   host;x-amz-content-sha256;x-amz-date
#   e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
comptime _BARE_SIGNED = "host;x-amz-content-sha256;x-amz-date"


def test_signed_head_object() raises:
    # HEAD, /test.txt, no query.
    var input = S3HeadObjectRequest(String("examplebucket"), String("test.txt"))
    var resolved = resolve_head_object_endpoint(
        komira_aws_s3_endpoint_rules(), _example_config(), input
    )
    var req = _signed(build_head_object_request(input), resolved)
    assert_equal(req.method, "HEAD")
    assert_equal(req.target, "/test.txt")
    assert_equal(req.header("Content-Length"), "")
    _expect(
        req,
        String(_BARE_SIGNED),
        String("69463d8f0bf59cfd12d6fc9f45cd84a5323d7bf3c5bd316736a2f8e50c8959a7"),
    )


def test_signed_delete_object() raises:
    # DELETE, /test.txt, no query.
    var input = S3DeleteObjectRequest(String("examplebucket"), String("test.txt"))
    var resolved = resolve_delete_object_endpoint(
        komira_aws_s3_endpoint_rules(), _example_config(), input
    )
    var req = _signed(build_delete_object_request(input), resolved)
    assert_equal(req.method, "DELETE")
    assert_equal(req.target, "/test.txt")
    _expect(
        req,
        String(_BARE_SIGNED),
        String("6c438fd8462d72c52c853c21024341c13138927b9fa4d2863a4f639bc99f25fe"),
    )


def test_signed_create_multipart_upload() raises:
    # POST, /big.bin, query `uploads=`: a key with no value. Content-Length
    # 0 is sent and, as botocore adds it after signing, not signed.
    var input = S3CreateMultipartUploadRequest(
        String("examplebucket"), String("big.bin")
    )
    var resolved = resolve_create_multipart_upload_endpoint(
        komira_aws_s3_endpoint_rules(), _example_config(), input
    )
    var req = _signed(build_create_multipart_upload_request(input), resolved)
    assert_equal(req.method, "POST")
    assert_equal(req.target, "/big.bin?uploads")
    assert_equal(req.header("Content-Length"), "0")
    _expect(
        req,
        String(_BARE_SIGNED),
        String("6a9dc15573136adb32da8f9902d1847b03075aa8a9a53d50f955dfa6dac92c0c"),
    )


def test_signed_delete_objects() raises:
    # POST /?delete with its <Delete> document and the required checksum,
    # all signed. Canonical request:
    #   POST
    #   /
    #   delete=
    #   content-type:application/xml
    #   host:examplebucket.s3.amazonaws.com
    #   x-amz-checksum-crc32:rdR1yA==
    #   x-amz-content-sha256:f804874c0f2a7b5f75baf7a57f460e9c9f6b35f051142ddc5caa4d5c1b2c629c
    #   x-amz-date:20130524T000000Z
    #   x-amz-sdk-checksum-algorithm:CRC32
    #
    #   <signed headers>
    #   f804874c0f2a7b5f75baf7a57f460e9c9f6b35f051142ddc5caa4d5c1b2c629c
    var objects = List[S3ObjectIdentifier]()
    objects.append(S3ObjectIdentifier(String("sample1.txt")))
    objects.append(S3ObjectIdentifier(String("sample2.txt")))
    var delete = S3Delete(objects^)
    delete.set_quiet(True)
    var input = S3DeleteObjectsRequest(String("examplebucket"), delete^)
    var resolved = resolve_delete_objects_endpoint(
        komira_aws_s3_endpoint_rules(), _example_config(), input
    )
    assert_equal(resolved.url, "https://examplebucket.s3.amazonaws.com")
    var req = _signed(build_delete_objects_request(input), resolved)
    assert_equal(req.method, "POST")
    assert_equal(req.host, "examplebucket.s3.amazonaws.com")
    assert_equal(req.target, "/?delete")
    assert_equal(req.header("Content-Length"), "162")
    assert_equal(req.header("x-amz-checksum-crc32"), "rdR1yA==")
    assert_equal(
        req.header("x-amz-content-sha256"),
        "f804874c0f2a7b5f75baf7a57f460e9c9f6b35f051142ddc5caa4d5c1b2c629c",
    )
    _expect(
        req,
        String(
            "content-type;host;x-amz-checksum-crc32;x-amz-content-sha256;"
            + "x-amz-date;x-amz-sdk-checksum-algorithm"
        ),
        String("787daa3db4b8e911f8388a8384f47b22ccd18ca92892cdd542b9e72590f1c76d"),
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
    test_signed_put_object_example()
    test_signed_put_object_as_sent()
    test_signed_get_bucket_lifecycle_example()
    test_signed_path_style()
    test_signed_head_object()
    test_signed_delete_object()
    test_signed_create_multipart_upload()
    test_signed_delete_objects()
    print("OK")
