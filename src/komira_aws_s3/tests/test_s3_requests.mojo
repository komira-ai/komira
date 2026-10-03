# The requests komira_aws_s3 builds for the operations an object store
# needs, each compared exactly with the wire form the Amazon S3 API
# Reference states for it: method, request target, headers and body.
#
# The bucket is not in any target here: the client resolves its endpoint
# through S3's endpoint ruleset, which puts the bucket in the host (virtual
# host) or in the endpoint's path (path style), so the request target
# starts at the key. test_s3_endpoints joins the two.
#
# Checksums: PutObject and UploadPart carry the CRC32 request checksum
# current AWS SDKs send by default: `x-amz-sdk-checksum-algorithm: CRC32`
# and `x-amz-checksum-crc32`, the base64 of the body's CRC-32, big-endian
# (the PutObject and UploadPart API references). Each expected value was
# computed with zlib's crc32, an independent implementation.
#
# Content-Type: a blob payload with no ContentType member set is sent as
# `application/octet-stream`. That is the generator's choice, and differs
# from botocore, which sends no Content-Type then; S3 accepts either and
# stores the type it is given.
from komira_aws_s3.komira_aws_s3 import (
    S3_CHECKSUM_ALGORITHM_SHA256,
    S3_ENCODING_TYPE_URL,
    S3_METADATA_DIRECTIVE_REPLACE,
    S3AbortMultipartUploadRequest,
    S3CompleteMultipartUploadRequest,
    S3CompletedMultipartUpload,
    S3CompletedPart,
    S3CopyObjectRequest,
    S3CreateMultipartUploadRequest,
    S3DeleteObjectRequest,
    S3GetObjectRequest,
    S3HeadObjectRequest,
    S3ListObjectsV2Request,
    S3PutObjectRequest,
    S3UploadPartRequest,
    build_abort_multipart_upload_request,
    build_complete_multipart_upload_request,
    build_copy_object_request,
    build_create_multipart_upload_request,
    build_delete_object_request,
    build_get_object_request,
    build_head_object_request,
    build_list_objects_v2_request,
    build_put_object_request,
    build_upload_part_request,
)
from komira_aws_core import AwsRequest, s3_copy_source
from std.testing import assert_equal, assert_false, assert_raises, assert_true


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _crc32_checksum(req: AwsRequest, expected: String) raises:
    assert_equal(req.header(String("x-amz-sdk-checksum-algorithm")), "CRC32")
    assert_equal(req.header(String("x-amz-checksum-crc32")), expected)
    var others: List[String] = [
        "x-amz-checksum-crc32c",
        "x-amz-checksum-crc64nvme",
        "x-amz-checksum-sha1",
        "x-amz-checksum-sha256",
        "Content-MD5",
    ]
    for i in range(len(others)):
        assert_false(req.has_header(others[i]), others[i])


def _header_count(req: AwsRequest) -> Int:
    return len(req.header_names)


# ---- GetObject / HeadObject --------------------------------------------------


def test_get_object_closed_range() raises:
    var input = S3GetObjectRequest(
        String("lake"), String("data/part-00000.parquet")
    )
    input.set_range_(String("bytes=0-1023"))
    var req = build_get_object_request(input)
    assert_equal(req.method, "GET")
    assert_equal(req.uri, "/data/part-00000.parquet")
    assert_equal(req.header(String("Range")), "bytes=0-1023")
    assert_equal(_header_count(req), 1)
    assert_equal(len(req.body), 0)


def test_get_object_suffix_range() raises:
    # The last 8 bytes (a Parquet footer's length and magic): RFC 9110
    # suffix form, which S3 answers with 206 and the object's last bytes.
    var input = S3GetObjectRequest(String("lake"), String("t/f.parquet"))
    input.set_range_(String("bytes=-8"))
    var req = build_get_object_request(input)
    assert_equal(req.uri, "/t/f.parquet")
    assert_equal(req.header(String("Range")), "bytes=-8")


def test_get_object_conditional_and_version() raises:
    var input = S3GetObjectRequest(String("lake"), String("k"))
    input.set_if_match(String('"9b2cf535f27731c974343645a3985328"'))
    input.set_version_id(String("3/L4kqtJlcpXroDTDmJ+rmSpXd3dIbrHY"))
    var req = build_get_object_request(input)
    # The version id is a query value: '/' and '+' are encoded.
    assert_equal(
        req.uri, "/k?versionId=3%2FL4kqtJlcpXroDTDmJ%2BrmSpXd3dIbrHY"
    )
    assert_equal(
        req.header(String("If-Match")), '"9b2cf535f27731c974343645a3985328"'
    )


def test_head_object() raises:
    var input = S3HeadObjectRequest(String("lake"), String("a/b.txt"))
    input.set_if_none_match(String('"abc"'))
    var req = build_head_object_request(input)
    assert_equal(req.method, "HEAD")
    assert_equal(req.uri, "/a/b.txt")
    assert_equal(req.header(String("If-None-Match")), '"abc"')
    assert_equal(_header_count(req), 1)
    assert_equal(len(req.body), 0)


# ---- PutObject -----------------------------------------------------------------


def test_put_object_if_none_match_star() raises:
    # A conditional write: create only if no object has the key. One
    # request; S3 answers 412 PreconditionFailed when one exists.
    var input = S3PutObjectRequest(String("lake"), String("manifest.json"))
    input.set_body(_bytes(String('{"v":1}')))
    input.set_if_none_match(String("*"))
    var req = build_put_object_request(input)
    assert_equal(req.method, "PUT")
    assert_equal(req.uri, "/manifest.json")
    assert_equal(req.header(String("If-None-Match")), "*")
    assert_equal(req.body_text(), '{"v":1}')
    # A blob payload with no Content-Type member set goes as octet-stream
    # (botocore sends none; see the file header).
    assert_equal(
        req.header(String("Content-Type")), "application/octet-stream"
    )
    _crc32_checksum(req, String("hNvnPQ=="))
    assert_equal(_header_count(req), 4)


def test_put_object_if_match_and_metadata() raises:
    var input = S3PutObjectRequest(String("lake"), String("manifest.json"))
    input.set_body(_bytes(String("x")))
    input.set_if_match(String('"d41d8cd98f00b204e9800998ecf8427e"'))
    input.set_content_type(String("application/json"))
    var meta = Dict[String, String]()
    meta[String("writer")] = String("engine-7")
    input.set_metadata(meta^)
    var req = build_put_object_request(input)
    assert_equal(
        req.header(String("If-Match")), '"d41d8cd98f00b204e9800998ecf8427e"'
    )
    # The member wins over the payload's default content type.
    assert_equal(req.header(String("Content-Type")), "application/json")
    # A user-defined metadata entry is one x-amz-meta-<name> header.
    assert_equal(req.header(String("x-amz-meta-writer")), "engine-7")
    _crc32_checksum(req, String("jNwWgw=="))


def test_put_object_with_no_body() raises:
    # An empty object: no body, and so no Content-Type.
    var req = build_put_object_request(
        S3PutObjectRequest(String("lake"), String("dir/"))
    )
    assert_equal(req.uri, "/dir/")
    assert_equal(len(req.body), 0)
    assert_false(req.has_header(String("Content-Type")))
    # The checksum of the empty body.
    _crc32_checksum(req, String("AAAAAA=="))
    assert_equal(_header_count(req), 2)


def test_put_object_checksum_supplied() raises:
    # A checksum the caller computed (the SHA-256 of "x") is sent as given,
    # and no CRC32 is added: the client computes one only when none is set.
    var input = S3PutObjectRequest(String("lake"), String("k"))
    input.set_body(_bytes(String("x")))
    input.set_checksum_algorithm(String(S3_CHECKSUM_ALGORITHM_SHA256))
    input.set_checksum_sha256(
        String("LXEWQrcmsEQBYnyp+6wy9chTD7GQPMTbAiWHF5IaSIE=")
    )
    var req = build_put_object_request(input)
    assert_equal(req.header(String("x-amz-sdk-checksum-algorithm")), "SHA256")
    assert_equal(
        req.header(String("x-amz-checksum-sha256")),
        "LXEWQrcmsEQBYnyp+6wy9chTD7GQPMTbAiWHF5IaSIE=",
    )
    assert_false(req.has_header(String("x-amz-checksum-crc32")))


def test_put_object_other_algorithm_refused() raises:
    # An algorithm this client does not compute, with no checksum given.
    var input = S3PutObjectRequest(String("lake"), String("k"))
    input.set_body(_bytes(String("x")))
    input.set_checksum_algorithm(String(S3_CHECKSUM_ALGORITHM_SHA256))
    with assert_raises(contains="'SHA256' is not computed by this client"):
        _ = build_put_object_request(input)


def test_put_object_refuses_an_empty_key() raises:
    # The model's Key has min length 1.
    with assert_raises(contains="S3PutObjectRequest.Key"):
        _ = build_put_object_request(S3PutObjectRequest(String("b"), String("")))


# ---- key escaping ----------------------------------------------------------------


def test_key_escaping_and_dot_segments() raises:
    # The key is a greedy label: every '/' is kept, every byte outside the
    # RFC 3986 unreserved set is percent-encoded as UTF-8, and nothing is
    # normalized: '.' and '..' segments and repeated '/' reach S3 as keyed.
    var rows: List[List[String]] = [
        ["a b/c+d.txt", "/a%20b/c%2Bd.txt"],
        ["100%/x", "/100%25/x"],
        ["café", "/caf%C3%A9"],
        ["q?a=1#f", "/q%3Fa%3D1%23f"],
        ["a/./b/../c", "/a/./b/../c"],
        ["a//b", "/a//b"],
        ["/lead", "//lead"],
        ["~user_-.x", "/~user_-.x"],
        ["k:v;w,z@h", "/k%3Av%3Bw%2Cz%40h"],
    ]
    for i in range(len(rows)):
        var row = rows[i].copy()
        var req = build_get_object_request(S3GetObjectRequest(String("b"), row[0]))
        assert_equal(req.uri, row[1], row[0])


# ---- ListObjectsV2 -------------------------------------------------------------


def test_list_objects_v2_first_page() raises:
    var input = S3ListObjectsV2Request(String("lake"))
    input.set_prefix(String("data/year=2026/"))
    input.set_delimiter(String("/"))
    input.set_encoding_type(String(S3_ENCODING_TYPE_URL))
    input.set_max_keys(Int32(1000))
    var req = build_list_objects_v2_request(input)
    assert_equal(req.method, "GET")
    # `list-type=2` first, as the operation's literal query, then the
    # members in the model's order, each key and value encoded.
    assert_equal(
        req.uri,
        "/?list-type=2&delimiter=%2F&encoding-type=url&max-keys=1000"
        + "&prefix=data%2Fyear%3D2026%2F",
    )
    assert_equal(_header_count(req), 0)
    assert_equal(len(req.body), 0)


def test_list_objects_v2_continuation() raises:
    var input = S3ListObjectsV2Request(String("lake"))
    input.set_continuation_token(
        String("1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM=")
    )
    input.set_start_after(String("data/a"))
    var req = build_list_objects_v2_request(input)
    assert_equal(
        req.uri,
        "/?list-type=2"
        + "&continuation-token=1ueGcxLPRx1Tr%2FXYExHnhbYLgveDs2J%2Fwm36Hy4vbOwM%3D"
        + "&start-after=data%2Fa",
    )


def test_list_objects_v2_bare() raises:
    var req = build_list_objects_v2_request(S3ListObjectsV2Request(String("lake")))
    assert_equal(req.uri, "/?list-type=2")


# ---- DeleteObject / CopyObject ---------------------------------------------------


def test_delete_object() raises:
    var req = build_delete_object_request(
        S3DeleteObjectRequest(String("lake"), String("tmp/x.bin"))
    )
    assert_equal(req.method, "DELETE")
    assert_equal(req.uri, "/tmp/x.bin")
    assert_equal(_header_count(req), 0)
    var input = S3DeleteObjectRequest(String("lake"), String("tmp/x.bin"))
    input.set_version_id(String("UIORUnfnd89493jJFJ"))
    assert_equal(
        build_delete_object_request(input).uri,
        "/tmp/x.bin?versionId=UIORUnfnd89493jJFJ",
    )


def test_copy_object() raises:
    # x-amz-copy-source names the source as `<bucket>/<key>`, URL-encoded
    # with '/' kept (komira_aws_core.s3_copy_source); the target is the
    # destination key.
    var source = s3_copy_source(String("src-bucket"), String("in/a b+c.txt"))
    assert_equal(source, "src-bucket/in/a%20b%2Bc.txt")
    var input = S3CopyObjectRequest(String("dst-bucket"), source, String("out/c.txt"))
    input.set_metadata_directive(String(S3_METADATA_DIRECTIVE_REPLACE))
    input.set_if_none_match(String("*"))
    var req = build_copy_object_request(input)
    assert_equal(req.method, "PUT")
    assert_equal(req.uri, "/out/c.txt")
    assert_equal(
        req.header(String("x-amz-copy-source")), "src-bucket/in/a%20b%2Bc.txt"
    )
    assert_equal(req.header(String("x-amz-metadata-directive")), "REPLACE")
    assert_equal(req.header(String("If-None-Match")), "*")
    assert_equal(len(req.body), 0)
    # A version of the source.
    var versioned = s3_copy_source(
        String("src-bucket"), String("k"), Optional[String](String("v1"))
    )
    assert_equal(versioned, "src-bucket/k?versionId=v1")


# ---- multipart upload ------------------------------------------------------------


def test_create_multipart_upload() raises:
    var input = S3CreateMultipartUploadRequest(String("lake"), String("big.bin"))
    input.set_content_type(String("application/octet-stream"))
    var req = build_create_multipart_upload_request(input)
    assert_equal(req.method, "POST")
    # `uploads` is a query key with no value.
    assert_equal(req.uri, "/big.bin?uploads")
    assert_equal(
        req.header(String("Content-Type")), "application/octet-stream"
    )
    assert_equal(len(req.body), 0)


def test_upload_part() raises:
    var input = S3UploadPartRequest(
        String("lake"),
        String("big.bin"),
        Int32(3),
        String("VXBsb2FkIElEIGZvciA2aWWpbmcncyBteS1tb3ZpZS5tMnRzIHVwbG9hZA"),
    )
    input.set_body(_bytes(String("part three")))
    var req = build_upload_part_request(input)
    assert_equal(req.method, "PUT")
    assert_equal(
        req.uri,
        "/big.bin?partNumber=3"
        + "&uploadId=VXBsb2FkIElEIGZvciA2aWWpbmcncyBteS1tb3ZpZS5tMnRzIHVwbG9hZA",
    )
    assert_equal(req.body_text(), "part three")
    _crc32_checksum(req, String("L8IwAg=="))
    assert_equal(_header_count(req), 3)


def test_complete_multipart_upload() raises:
    var parts = List[S3CompletedPart]()
    var etags: List[String] = [
        '"a54357aff0632cce46d942af68356b38"',
        '"0c78aef83f66abc1fa1e8477f296d394"',
    ]
    for i in range(len(etags)):
        var p = S3CompletedPart()
        p.set_part_number(Int32(i + 1))
        p.set_e_tag(etags[i])
        parts.append(p^)
    var upload = S3CompletedMultipartUpload()
    upload.set_parts(parts^)
    var input = S3CompleteMultipartUploadRequest(
        String("lake"), String("big.bin"), String("abc")
    )
    input.set_multipart_upload(upload^)
    var req = build_complete_multipart_upload_request(input)
    assert_equal(req.method, "POST")
    assert_equal(req.uri, "/big.bin?uploadId=abc")
    assert_equal(req.header(String("Content-Type")), "application/xml")
    # The document of the API reference: a flattened list of <Part>, each
    # its ETag then its PartNumber; a '"' in text is not escaped.
    assert_equal(
        req.body_text(),
        '<CompleteMultipartUpload xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
        + '<Part><ETag>"a54357aff0632cce46d942af68356b38"</ETag>'
        + "<PartNumber>1</PartNumber></Part>"
        + '<Part><ETag>"0c78aef83f66abc1fa1e8477f296d394"</ETag>'
        + "<PartNumber>2</PartNumber></Part>"
        + "</CompleteMultipartUpload>",
    )


def test_abort_multipart_upload() raises:
    var req = build_abort_multipart_upload_request(
        S3AbortMultipartUploadRequest(String("lake"), String("big.bin"), String("a/b+c"))
    )
    assert_equal(req.method, "DELETE")
    assert_equal(req.uri, "/big.bin?uploadId=a%2Fb%2Bc")
    assert_equal(len(req.body), 0)


def main() raises:
    test_get_object_closed_range()
    test_get_object_suffix_range()
    test_get_object_conditional_and_version()
    test_head_object()
    test_put_object_if_none_match_star()
    test_put_object_if_match_and_metadata()
    test_put_object_with_no_body()
    test_put_object_checksum_supplied()
    test_put_object_other_algorithm_refused()
    test_put_object_refuses_an_empty_key()
    test_key_escaping_and_dot_segments()
    test_list_objects_v2_first_page()
    test_list_objects_v2_continuation()
    test_list_objects_v2_bare()
    test_delete_object()
    test_copy_object()
    test_create_multipart_upload()
    test_upload_part()
    test_complete_multipart_upload()
    test_abort_multipart_upload()
    print("OK")
