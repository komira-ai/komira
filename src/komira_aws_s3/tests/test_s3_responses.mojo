# The responses komira_aws_s3 reads for the operations an object store
# needs, written as the Amazon S3 API Reference shows them, each field
# compared exactly (DeleteObjects' per-key <Error> results among them);
# S3's 200-with-<Error> (raised as an HTTP 500 is, which
# a caller retries); and the error forms a caller classifies by
# komira_aws_core.aws_rest_xml_error: a code in the body, a bare <Error>,
# and a HEAD error, which has no body and so is named by its status.
from komira_aws_s3.komira_aws_s3 import (
    parse_abort_multipart_upload_response,
    parse_complete_multipart_upload_response,
    parse_copy_object_response,
    parse_create_multipart_upload_response,
    parse_delete_object_response,
    parse_delete_objects_response,
    parse_get_object_head,
    parse_get_object_response,
    parse_head_object_response,
    parse_list_objects_v2_response,
    parse_put_object_response,
    parse_upload_part_response,
)
from komira_aws_core import AwsResponse, aws_rest_xml_error, s3_content_range_total
from std.testing import assert_equal, assert_false, assert_raises, assert_true


comptime _NS = 'xmlns="http://s3.amazonaws.com/doc/2006-03-01/"'
# Thu, 01 Oct 2026 12:00:00 GMT
comptime _T = Float64(1790856000.0)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


# ---- GetObject / HeadObject --------------------------------------------------


def test_get_object_206() raises:
    var resp = AwsResponse(206, _bytes(String("0123456789")))
    resp.add_header(String("Content-Range"), String("bytes 0-9/52428800"))
    resp.add_header(String("Content-Length"), String("10"))
    resp.add_header(String("Accept-Ranges"), String("bytes"))
    resp.add_header(String("ETag"), String('"9b2cf535f27731c974343645a3985328"'))
    resp.add_header(String("Last-Modified"), String("Thu, 01 Oct 2026 12:00:00 GMT"))
    resp.add_header(String("Content-Type"), String("application/octet-stream"))
    resp.add_header(String("x-amz-meta-writer"), String("engine-7"))
    resp.add_header(String("x-amz-version-id"), String("v1"))
    # The head parser reads no body, so it can run before the body arrives.
    var head = parse_get_object_head(resp)
    assert_equal(head.content_range.value(), "bytes 0-9/52428800")
    assert_equal(head.content_length.value(), Int64(10))
    assert_equal(head.accept_ranges.value(), "bytes")
    assert_equal(head.e_tag.value(), '"9b2cf535f27731c974343645a3985328"')
    assert_equal(head.last_modified.value(), _T)
    assert_equal(head.content_type.value(), "application/octet-stream")
    assert_equal(head.version_id.value(), "v1")
    assert_equal(head.metadata.value()[String("writer")], "engine-7")
    assert_false(Bool(head.body))
    # The object's size is the Content-Range's complete length.
    assert_equal(
        s3_content_range_total(head.content_range.value()).value(), 52428800
    )
    var full = parse_get_object_response(resp)
    assert_equal(len(full.body.value()), 10)
    assert_equal(full.body.value()[9], UInt8(0x39))


def test_get_object_body_is_never_an_error_body() raises:
    # An object may hold an <Error> document: a blob payload is the object.
    var body = String("<Error><Code>InternalError</Code></Error>")
    var out = parse_get_object_response(AwsResponse.of_text(200, body))
    assert_equal(len(out.body.value()), body.byte_length())


def test_head_object() raises:
    var resp = AwsResponse(200, List[UInt8]())
    resp.add_header(String("Content-Length"), String("5368709120"))
    resp.add_header(String("ETag"), String('"3858f62230ac3c915f300c664312c11f-9"'))
    resp.add_header(String("Last-Modified"), String("Thu, 01 Oct 2026 12:00:00 GMT"))
    resp.add_header(String("x-amz-mp-parts-count"), String("9"))
    resp.add_header(String("x-amz-storage-class"), String("STANDARD_IA"))
    resp.add_header(String("X-Amz-Meta-Origin"), String("upload"))
    var out = parse_head_object_response(resp)
    # A size past 2^32.
    assert_equal(out.content_length.value(), Int64(5368709120))
    assert_equal(out.e_tag.value(), '"3858f62230ac3c915f300c664312c11f-9"')
    assert_equal(out.last_modified.value(), _T)
    assert_equal(out.parts_count.value(), Int32(9))
    assert_equal(out.storage_class.value(), "STANDARD_IA")
    # The metadata key keeps the case it arrived in.
    assert_equal(out.metadata.value()[String("Origin")], "upload")
    assert_false(Bool(out.expires))


def test_an_expires_that_is_not_a_date_is_left_unset() raises:
    # S3 returns an object's stored Expires as written; one that is not an
    # HTTP date leaves the member unset, and the rest still parses.
    var rows: List[String] = ["0", "-1", "never", "2026-10-01"]
    for i in range(len(rows)):
        var resp = AwsResponse(200, List[UInt8]())
        resp.add_header(String("Expires"), rows[i])
        resp.add_header(String("Content-Length"), String("3"))
        var out = parse_head_object_response(resp)
        assert_false(Bool(out.expires), rows[i])
        assert_equal(out.content_length.value(), Int64(3), rows[i])
        var got = parse_get_object_head(resp)
        assert_false(Bool(got.expires), rows[i])
    var ok = AwsResponse(200, List[UInt8]())
    ok.add_header(String("Expires"), String("Thu, 01 Oct 2026 12:00:00 GMT"))
    assert_equal(parse_head_object_response(ok).expires.value(), _T)


# ---- ListObjectsV2 -------------------------------------------------------------


def test_list_objects_v2_page() raises:
    var body = String(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        + "<ListBucketResult "
        + _NS
        + ">\n"
        + "  <Name>lake</Name>\n"
        + "  <Prefix>data%2F</Prefix>\n"
        + "  <KeyCount>2</KeyCount>\n"
        + "  <MaxKeys>2</MaxKeys>\n"
        + "  <Delimiter>%2F</Delimiter>\n"
        + "  <EncodingType>url</EncodingType>\n"
        + "  <IsTruncated>true</IsTruncated>\n"
        + "  <Contents>\n"
        + "    <Key>data%2Fa%20b.parquet</Key>\n"
        + "    <LastModified>2026-10-01T12:00:00.000Z</LastModified>\n"
        + "    <ETag>&quot;599bab3ed2c697f1d26842727561fd94&quot;</ETag>\n"
        + "    <Size>5368709120</Size>\n"
        + "    <StorageClass>STANDARD</StorageClass>\n"
        + "  </Contents>\n"
        + "  <Contents>\n"
        + "    <Key>data%2Fb.parquet</Key>\n"
        + "    <LastModified>2026-10-01T12:00:00.000Z</LastModified>\n"
        + '    <ETag>"0c78aef83f66abc1fa1e8477f296d394"</ETag>\n'
        + "    <Size>0</Size>\n"
        + "    <StorageClass>STANDARD</StorageClass>\n"
        + "  </Contents>\n"
        + "  <CommonPrefixes><Prefix>data%2Fyear%3D2026%2F</Prefix></CommonPrefixes>\n"
        + "  <CommonPrefixes><Prefix>data%2Fyear%3D2027%2F</Prefix></CommonPrefixes>\n"
        + "  <ContinuationToken>1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM=</ContinuationToken>\n"
        + "  <NextContinuationToken>2ueGcxLPRx1Tr</NextContinuationToken>\n"
        + "</ListBucketResult>"
    )
    var out = parse_list_objects_v2_response(AwsResponse.of_text(200, body))
    assert_equal(out.name.value(), "lake")
    assert_equal(out.key_count.value(), Int32(2))
    assert_equal(out.max_keys.value(), Int32(2))
    assert_true(out.is_truncated.value())
    assert_equal(out.encoding_type.value(), "url")
    # With encoding-type=url the keys, prefixes and delimiter arrive
    # URL-encoded, and are read as sent: decoding them is the caller's.
    assert_equal(out.prefix.value(), "data%2F")
    assert_equal(out.delimiter.value(), "%2F")
    assert_equal(
        out.continuation_token.value(),
        "1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM=",
    )
    assert_equal(out.next_continuation_token.value(), "2ueGcxLPRx1Tr")
    var contents = out.contents.value().copy()
    assert_equal(len(contents), 2)
    assert_equal(contents[0].key.value(), "data%2Fa%20b.parquet")
    assert_equal(contents[0].size.value(), Int64(5368709120))
    assert_equal(contents[0].e_tag.value(), '"599bab3ed2c697f1d26842727561fd94"')
    assert_equal(contents[0].last_modified.value(), _T)
    assert_equal(contents[0].storage_class.value(), "STANDARD")
    assert_equal(contents[1].key.value(), "data%2Fb.parquet")
    assert_equal(contents[1].size.value(), Int64(0))
    var prefixes = out.common_prefixes.value().copy()
    assert_equal(len(prefixes), 2)
    assert_equal(prefixes[0].prefix.value(), "data%2Fyear%3D2026%2F")
    assert_equal(prefixes[1].prefix.value(), "data%2Fyear%3D2027%2F")


def test_list_objects_v2_last_page() raises:
    var body = String(
        "<ListBucketResult "
        + _NS
        + "><Name>lake</Name><Prefix></Prefix><KeyCount>0</KeyCount>"
        + "<MaxKeys>1000</MaxKeys><IsTruncated>false</IsTruncated>"
        + "</ListBucketResult>"
    )
    var out = parse_list_objects_v2_response(AwsResponse.of_text(200, body))
    assert_false(out.is_truncated.value())
    assert_equal(out.key_count.value(), Int32(0))
    assert_false(Bool(out.next_continuation_token))
    assert_false(Bool(out.contents))
    assert_false(Bool(out.common_prefixes))
    assert_equal(out.prefix.value(), "")


# ---- PutObject / CopyObject / DeleteObject -----------------------------------------


def test_put_object() raises:
    var resp = AwsResponse(200, List[UInt8]())
    resp.add_header(String("ETag"), String('"1b2cf535f27731c974343645a3985328"'))
    resp.add_header(String("x-amz-version-id"), String("v2"))
    resp.add_header(String("x-amz-checksum-crc32"), String("i9aeUg=="))
    resp.add_header(String("x-amz-server-side-encryption"), String("AES256"))
    var out = parse_put_object_response(resp)
    assert_equal(out.e_tag.value(), '"1b2cf535f27731c974343645a3985328"')
    assert_equal(out.version_id.value(), "v2")
    assert_equal(out.checksum_crc32.value(), "i9aeUg==")
    assert_equal(out.server_side_encryption.value(), "AES256")


def test_copy_object() raises:
    var body = String(
        "<CopyObjectResult>"
        + "<LastModified>2026-10-01T12:00:00.000Z</LastModified>"
        + "<ETag>&quot;9b2cf535f27731c974343645a3985328&quot;</ETag>"
        + "</CopyObjectResult>"
    )
    var resp = AwsResponse.of_text(200, body)
    resp.add_header(String("x-amz-copy-source-version-id"), String("v0"))
    var out = parse_copy_object_response(resp)
    var result = out.copy_object_result.value().copy()
    assert_equal(result.e_tag.value(), '"9b2cf535f27731c974343645a3985328"')
    assert_equal(result.last_modified.value(), _T)
    assert_equal(out.copy_source_version_id.value(), "v0")


def test_delete_object_204() raises:
    var resp = AwsResponse(204, List[UInt8]())
    resp.add_header(String("x-amz-delete-marker"), String("true"))
    resp.add_header(String("x-amz-version-id"), String("dm1"))
    var out = parse_delete_object_response(resp)
    assert_true(out.delete_marker.value())
    assert_equal(out.version_id.value(), "dm1")
    # And with no header at all.
    var bare = parse_delete_object_response(AwsResponse(204, List[UInt8]()))
    assert_false(Bool(bare.delete_marker))


# ---- multipart upload ------------------------------------------------------------


def test_create_multipart_upload() raises:
    var body = String(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        + "<InitiateMultipartUploadResult "
        + _NS
        + ">"
        + "<Bucket>lake</Bucket><Key>big.bin</Key>"
        + "<UploadId>VXBsb2FkIElEIGZvciA2aWWpbmcncyBteS1tb3ZpZS5tMnRzIHVwbG9hZA</UploadId>"
        + "</InitiateMultipartUploadResult>"
    )
    var out = parse_create_multipart_upload_response(AwsResponse.of_text(200, body))
    assert_equal(out.bucket.value(), "lake")
    assert_equal(out.key.value(), "big.bin")
    assert_equal(
        out.upload_id.value(),
        "VXBsb2FkIElEIGZvciA2aWWpbmcncyBteS1tb3ZpZS5tMnRzIHVwbG9hZA",
    )


def test_upload_part() raises:
    var resp = AwsResponse(200, List[UInt8]())
    resp.add_header(String("ETag"), String('"b54357faf0632cce46e942fa68356b38"'))
    var out = parse_upload_part_response(resp)
    assert_equal(out.e_tag.value(), '"b54357faf0632cce46e942fa68356b38"')


def test_complete_multipart_upload() raises:
    var body = String(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        + "<CompleteMultipartUploadResult "
        + _NS
        + ">"
        + "<Location>https://lake.s3.us-west-2.amazonaws.com/big.bin</Location>"
        + "<Bucket>lake</Bucket><Key>big.bin</Key>"
        + "<ETag>&quot;3858f62230ac3c915f300c664312c11f-9&quot;</ETag>"
        + "</CompleteMultipartUploadResult>"
    )
    var resp = AwsResponse.of_text(200, body)
    resp.add_header(String("x-amz-version-id"), String("v9"))
    var out = parse_complete_multipart_upload_response(resp)
    assert_equal(
        out.location.value(), "https://lake.s3.us-west-2.amazonaws.com/big.bin"
    )
    assert_equal(out.bucket.value(), "lake")
    assert_equal(out.key.value(), "big.bin")
    assert_equal(out.e_tag.value(), '"3858f62230ac3c915f300c664312c11f-9"')
    assert_equal(out.version_id.value(), "v9")


def test_abort_multipart_upload_204() raises:
    var resp = AwsResponse(204, List[UInt8]())
    resp.add_header(String("x-amz-request-charged"), String("requester"))
    var out = parse_abort_multipart_upload_response(resp)
    assert_equal(out.request_charged.value(), "requester")


# ---- 200 with <Error> --------------------------------------------------------------


comptime _INTERNAL = (
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    "<Error><Code>InternalError</Code>"
    "<Message>We encountered an internal error. Please try again.</Message>"
    "<RequestId>656c76696e6727732072657175657374</RequestId>"
    "<HostId>Uuag1LuByRx9e6j5Onimru9pO4ZVKnJ2Qz7/C1NPcfTWAtRPfTaOFg==</HostId>"
    "</Error>"
)


def test_complete_multipart_upload_200_error_is_raised() raises:
    # CompleteMultipartUpload can fail after S3 has answered 200 and begun
    # its body: the error is the body. It is raised as an HTTP 500 is, the
    # class a caller retries.
    with assert_raises(
        contains=(
            "CompleteMultipartUpload failed: HTTP 500 InternalError"
            " We encountered an internal error. Please try again."
        )
    ):
        _ = parse_complete_multipart_upload_response(
            AwsResponse.of_text(200, String(_INTERNAL))
        )
    # The same response, classified: the code, the message, the request id.
    var info = aws_rest_xml_error(AwsResponse.of_text(200, String(_INTERNAL)))
    assert_equal(info.code, "InternalError")
    assert_equal(info.request_id, "656c76696e6727732072657175657374")


def test_copy_object_200_error_is_raised() raises:
    var body = String(
        "<Error><Code>SlowDown</Code><Message>Please reduce your request rate."
        + "</Message></Error>"
    )
    with assert_raises(contains="CopyObject failed: HTTP 500 SlowDown"):
        _ = parse_copy_object_response(AwsResponse.of_text(200, body))


def test_a_200_body_cut_short_is_raised() raises:
    # A body that is not XML (the connection closed mid-document) is raised
    # too, rather than read as an empty result.
    with assert_raises(contains="ListObjectsV2 failed: HTTP 500 "):
        _ = parse_list_objects_v2_response(
            AwsResponse.of_text(200, String("<ListBucketResult><Name>la"))
        )
    with assert_raises(contains="CompleteMultipartUpload failed: HTTP 500 "):
        _ = parse_complete_multipart_upload_response(
            AwsResponse.of_text(200, String("<?xml version="))
        )


def test_an_error_root_in_a_namespace_is_a_result() raises:
    # Only <Error> in no namespace is the error document; a result element
    # in S3's namespace is never one, whatever its children.
    var body = String(
        "<ListBucketResult " + _NS + "><Name>Error</Name></ListBucketResult>"
    )
    var out = parse_list_objects_v2_response(AwsResponse.of_text(200, body))
    assert_equal(out.name.value(), "Error")


# ---- error responses -----------------------------------------------------------------


def _error(status: Int, body: String) -> AwsResponse:
    return AwsResponse.of_text(status, body)


def test_error_codes() raises:
    # (status, code) of the errors an object store acts on, each in the
    # document form S3 sends.
    var statuses: List[Int] = [404, 404, 404, 412, 409, 503, 403, 400]
    var rows: List[List[String]] = [
        ["NoSuchKey", "The specified key does not exist."],
        ["NoSuchUpload", "The specified multipart upload does not exist."],
        ["NoSuchBucket", "The specified bucket does not exist."],
        ["PreconditionFailed", "At least one of the pre-conditions you specified did not hold"],
        ["ConditionalRequestConflict", "A conflicting conditional operation is currently in progress against this resource."],
        ["SlowDown", "Please reduce your request rate."],
        ["AccessDenied", "Access Denied"],
        ["InvalidPart", "One or more of the specified parts could not be found."],
    ]
    assert_equal(len(statuses), len(rows))
    for i in range(len(rows)):
        var row = rows[i].copy()
        var status = statuses[i]
        var resp = _error(
            status,
            '<?xml version="1.0" encoding="UTF-8"?>\n<Error><Code>'
            + row[0]
            + "</Code><Message>"
            + row[1]
            + "</Message><RequestId>4442587FB7D0A2F9</RequestId></Error>",
        )
        var info = aws_rest_xml_error(resp)
        assert_equal(info.status, status, row[0])
        assert_equal(info.code, row[0])
        assert_equal(info.message, row[1], row[0])
        assert_equal(info.request_id, "4442587FB7D0A2F9", row[0])


def test_request_id_header_wins() raises:
    var resp = _error(
        404,
        "<Error><Code>NoSuchKey</Code><RequestId>BODY</RequestId></Error>",
    )
    resp.add_header(String("x-amz-request-id"), String("HEADER1"))
    assert_equal(aws_rest_xml_error(resp).request_id, "HEADER1")


def test_head_error_has_no_body() raises:
    # A HEAD response has no body, so its error is named by its status.
    var rows: List[Int] = [404, 403, 412, 304]
    for i in range(len(rows)):
        var info = aws_rest_xml_error(AwsResponse(rows[i], List[UInt8]()))
        assert_equal(info.code, String(rows[i]))
        assert_equal(info.message, "")


def test_redirect_names_its_code() raises:
    # A bucket in another region: 301 PermanentRedirect, and the region in
    # the x-amz-bucket-region header, which a caller reads to retry there.
    var resp = _error(
        301,
        "<Error><Code>PermanentRedirect</Code><Message>The bucket you are"
        + " attempting to access must be addressed using the specified"
        + " endpoint.</Message><Endpoint>lake.s3.eu-west-1.amazonaws.com"
        + "</Endpoint><Bucket>lake</Bucket></Error>",
    )
    resp.add_header(String("x-amz-bucket-region"), String("eu-west-1"))
    var info = aws_rest_xml_error(resp)
    assert_equal(info.status, 301)
    assert_equal(info.code, "PermanentRedirect")
    assert_equal(resp.header(String("x-amz-bucket-region")), "eu-west-1")


# ---- DeleteObjects -----------------------------------------------------------------


def test_delete_objects_result() raises:
    # A 200 <DeleteResult>: what was deleted and, per key, what was not.
    # An <Error> child is a key's failure, not the request's: only an
    # <Error> ROOT is an error document.
    var body = String(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        + "<DeleteResult "
        + _NS
        + ">"
        + "<Deleted><Key>data/part-0.parquet</Key></Deleted>"
        + "<Deleted><Key>data/part-1.parquet</Key>"
        + "<DeleteMarker>true</DeleteMarker>"
        + "<DeleteMarkerVersionId>A._w1z6EFiCF5uhtQMDal9JDkID9tQ7F</DeleteMarkerVersionId>"
        + "</Deleted>"
        + "<Error><Key>locked/a.parquet</Key>"
        + "<VersionId>3/L4kqtJlcpXroDTDmJ+rmSpXd3dIbrHY</VersionId>"
        + "<Code>AccessDenied</Code><Message>Access Denied</Message></Error>"
        + "<Error><Key>a&amp;b.txt</Key><Code>InternalError</Code>"
        + "<Message>We encountered an internal error. Please try again.</Message>"
        + "</Error>"
        + "</DeleteResult>"
    )
    var resp = AwsResponse.of_text(200, body)
    resp.add_header(String("x-amz-request-charged"), String("requester"))
    var out = parse_delete_objects_response(resp)
    # Read in place. A List.copy() of these lists has corrupted the heap of
    # this test binary under the pinned Mojo compiler (List[T] where T has
    # the generated explicit __deinit__), so the rows here do not copy.
    ref deleted = out.deleted.value()
    assert_equal(len(deleted), 2)
    assert_equal(deleted[0].key.value(), "data/part-0.parquet")
    assert_false(Bool(deleted[0].delete_marker))
    assert_false(Bool(deleted[0].version_id))
    assert_equal(deleted[1].key.value(), "data/part-1.parquet")
    assert_true(deleted[1].delete_marker.value())
    assert_equal(
        deleted[1].delete_marker_version_id.value(),
        "A._w1z6EFiCF5uhtQMDal9JDkID9tQ7F",
    )
    ref errors = out.errors.value()
    assert_equal(len(errors), 2)
    assert_equal(errors[0].key.value(), "locked/a.parquet")
    assert_equal(errors[0].version_id.value(), "3/L4kqtJlcpXroDTDmJ+rmSpXd3dIbrHY")
    assert_equal(errors[0].code.value(), "AccessDenied")
    assert_equal(errors[0].message.value(), "Access Denied")
    assert_equal(errors[1].key.value(), "a&b.txt")
    assert_equal(errors[1].code.value(), "InternalError")
    assert_false(Bool(errors[1].version_id))
    assert_equal(out.request_charged.value(), "requester")


def test_delete_objects_quiet_result() raises:
    # Quiet mode: only failures are listed, and with none the result is
    # empty. Neither list is set, rather than set empty.
    var out = parse_delete_objects_response(
        AwsResponse.of_text(200, String("<DeleteResult " + _NS + "/>"))
    )
    assert_false(Bool(out.deleted))
    assert_false(Bool(out.errors))
    assert_false(Bool(out.request_charged))
    # Failures only.
    var some = parse_delete_objects_response(
        AwsResponse.of_text(
            200,
            String(
                "<DeleteResult "
                + _NS
                + "><Error><Key>k</Key><Code>AccessDenied</Code>"
                + "<Message>Access Denied</Message></Error></DeleteResult>"
            ),
        )
    )
    assert_false(Bool(some.deleted))
    assert_equal(len(some.errors.value()), 1)
    assert_equal(some.errors.value()[0].key.value(), "k")


def test_delete_objects_200_error_is_raised() raises:
    # The whole request failing after a 200: an <Error> root, raised as an
    # HTTP 500 is.
    with assert_raises(contains="DeleteObjects failed: HTTP 500 InternalError"):
        _ = parse_delete_objects_response(AwsResponse.of_text(200, String(_INTERNAL)))


def main() raises:
    test_get_object_206()
    test_get_object_body_is_never_an_error_body()
    test_head_object()
    test_an_expires_that_is_not_a_date_is_left_unset()
    test_list_objects_v2_page()
    test_list_objects_v2_last_page()
    test_put_object()
    test_copy_object()
    test_delete_object_204()
    test_create_multipart_upload()
    test_upload_part()
    test_complete_multipart_upload()
    test_abort_multipart_upload_204()
    test_complete_multipart_upload_200_error_is_raised()
    test_copy_object_200_error_is_raised()
    test_a_200_body_cut_short_is_raised()
    test_an_error_root_in_a_namespace_is_a_result()
    test_error_codes()
    test_request_id_header_wins()
    test_head_error_has_no_body()
    test_redirect_names_its_code()
    test_delete_objects_result()
    test_delete_objects_quiet_result()
    test_delete_objects_200_error_is_raised()
    print("OK")
