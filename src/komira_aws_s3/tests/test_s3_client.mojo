# The generated S3 client (`S3S3Client`), verb by verb, end to end: the
# request built, resolved through S3's endpoint ruleset to a local
# endpoint (path style), signed and sent by komira_aws_core over
# komira_http_client, and the answer parsed or raised. The connector is
# komira_http_core's ScriptedConnector, armed with the responses S3 gives
# (the S3 API reference's examples): no socket, no network.
#
# A client is given a connector FACTORY, a function that makes one
# connector per call, so each row's answer is one factory below. A
# sequence of calls (two list pages, a multipart upload) uses one client
# per call, threading the one credential source through them with
# `into_creds_source`, as a bootstrap threads one through several clients.
#
# Rows: a conditional PutObject that loses the race (412), a ranged
# GetObject (206), two ListObjectsV2 pages, CreateMultipartUpload,
# UploadPart and CompleteMultipartUpload, an AbortMultipartUpload of an
# upload that is gone (404 NoSuchUpload), a HeadObject 404 (no body), and
# the client's retries: a 503 SlowDown and a CopyObject 200-with-<Error>,
# each answered on the second attempt. Those two wait the standard mode's
# first backoff for real (at most 1 s); test_s3_retry drives the same
# send with a recording sleeper.
from komira_aws_s3.komira_aws_s3 import (
    S3AbortMultipartUploadRequest,
    S3CompleteMultipartUploadRequest,
    S3CompletedMultipartUpload,
    S3CompletedPart,
    S3CopyObjectRequest,
    S3CreateMultipartUploadRequest,
    S3EndpointConfig,
    S3GetObjectRequest,
    S3HeadObjectRequest,
    S3ListObjectsV2Request,
    S3PutObjectRequest,
    S3S3Client,
    S3UploadPartRequest,
)
from komira_aws_core import (
    AwsCredential,
    StaticCredsSource,
    s3_content_range_total,
    s3_copy_source,
)
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from std.testing import assert_equal, assert_false, assert_raises, assert_true


comptime _NS = 'xmlns="http://s3.amazonaws.com/doc/2006-03-01/"'
comptime _UPLOAD_ID = "VXBsb2FkIElEIGZvciA2aWWpbmcncyBteS1tb3ZpZS5tMnRzIHVwbG9hZA"


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _answer(status: Int, reason: String, body: String, headers: String = "") -> ScriptedStream:
    """S3's answer, closing the connection after it."""
    return ScriptedStream.from_read_script(
        _bytes(
            String("HTTP/1.1 ")
            + String(status)
            + " "
            + reason
            + "\r\nContent-Length: "
            + String(body.byte_length())
            + "\r\nConnection: close\r\nx-amz-request-id: 4442587FB7D0A2F9\r\n"
            + headers
            + "\r\n"
            + body
        )
    )


def _config() -> S3EndpointConfig:
    var config = S3EndpointConfig()
    config.endpoint = Optional[String](String("http://127.0.0.1:9000"))
    config.force_path_style = Optional[Bool](True)
    return config^


def _creds() -> StaticCredsSource:
    return StaticCredsSource(
        AwsCredential(
            String("AKIDEXAMPLE"),
            String("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
            String(""),
        )
    )


comptime _Client = S3S3Client[ScriptedConnector, StaticCredsSource]


def _client(
    mk: def () raises thin -> ScriptedConnector, var creds: StaticCredsSource
) raises -> _Client:
    return _Client(mk, creds^, String("us-east-1"), _config())


# ---- the answers, one factory each ---------------------------------------------


def _mk_412() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            412,
            "Precondition Failed",
            "<Error><Code>PreconditionFailed</Code><Message>At least one of the"
            " pre-conditions you specified did not hold</Message>"
            "<Condition>If-None-Match</Condition></Error>",
            "Content-Type: application/xml\r\n",
        )
    )


def _mk_206() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            206,
            "Partial Content",
            "0123456789",
            "Content-Range: bytes 0-9/52428800\r\nAccept-Ranges: bytes\r\n"
            'ETag: "9b2cf535f27731c974343645a3985328"\r\n'
            "Content-Type: application/octet-stream\r\n",
        )
    )


def _mk_page_1() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            200,
            "OK",
            String("<ListBucketResult ")
            + _NS
            + "><Name>lake</Name><Prefix>data/</Prefix><KeyCount>1</KeyCount>"
            + "<MaxKeys>1</MaxKeys><IsTruncated>true</IsTruncated>"
            + "<Contents><Key>data/a.parquet</Key><Size>10</Size></Contents>"
            + "<NextContinuationToken>1ueGcxLPRx1Tr</NextContinuationToken>"
            + "</ListBucketResult>",
        )
    )


def _mk_page_2() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            200,
            "OK",
            String("<ListBucketResult ")
            + _NS
            + "><Name>lake</Name><Prefix>data/</Prefix><KeyCount>1</KeyCount>"
            + "<MaxKeys>1</MaxKeys><IsTruncated>false</IsTruncated>"
            + "<Contents><Key>data/b.parquet</Key><Size>20</Size></Contents>"
            + "<ContinuationToken>1ueGcxLPRx1Tr</ContinuationToken>"
            + "</ListBucketResult>",
        )
    )


def _mk_create() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            200,
            "OK",
            String("<InitiateMultipartUploadResult ")
            + _NS
            + "><Bucket>lake</Bucket><Key>big.bin</Key><UploadId>"
            + _UPLOAD_ID
            + "</UploadId></InitiateMultipartUploadResult>",
        )
    )


def _mk_part() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(200, "OK", "", 'ETag: "b54357faf0632cce46e942fa68356b38"\r\n')
    )


def _mk_complete() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            200,
            "OK",
            String("<CompleteMultipartUploadResult ")
            + _NS
            + "><Location>http://127.0.0.1:9000/lake/big.bin</Location>"
            + "<Bucket>lake</Bucket><Key>big.bin</Key>"
            + "<ETag>&quot;3858f62230ac3c915f300c664312c11f-1&quot;</ETag>"
            + "</CompleteMultipartUploadResult>",
        )
    )


def _mk_abort_404() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            404,
            "Not Found",
            "<Error><Code>NoSuchUpload</Code><Message>The specified upload does"
            " not exist.</Message><UploadId>"
            + String(_UPLOAD_ID)
            + "</UploadId></Error>",
        )
    )


def _mk_head_404() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(_answer(404, "Not Found", ""))


def _mk_503_then_ok() raises -> ScriptedConnector:
    var c = ScriptedConnector.with_stream(
        _answer(
            503,
            "Slow Down",
            "<Error><Code>SlowDown</Code><Message>Please reduce your request"
            " rate.</Message></Error>",
        )
    )
    c.arm_next(_answer(200, "OK", "hello", "Content-Type: text/plain\r\n"))
    return c^


def _mk_copy_200_error_then_ok() raises -> ScriptedConnector:
    var c = ScriptedConnector.with_stream(
        _answer(
            200,
            "OK",
            '<?xml version="1.0" encoding="UTF-8"?>\n<Error><Code>InternalError'
            "</Code><Message>We encountered an internal error. Please try"
            " again.</Message></Error>",
        )
    )
    c.arm_next(
        _answer(
            200,
            "OK",
            String("<CopyObjectResult ")
            + _NS
            + "><LastModified>2026-10-01T12:00:00.000Z</LastModified>"
            + "<ETag>&quot;9b2cf535f27731c974343645a3985328&quot;</ETag>"
            + "</CopyObjectResult>",
        )
    )
    return c^


# ---- the rows --------------------------------------------------------------------


def test_conditional_put_loses_the_race() raises:
    var client = _client(_mk_412, _creds())
    var input = S3PutObjectRequest(String("lake"), String("manifest.json"))
    input.set_body(_bytes(String('{"v":2}')))
    input.set_if_none_match(String("*"))
    # A 412 is the answer, not a fault: raised once, never retried, with
    # its code for the caller that turns it into "already exists".
    with assert_raises(contains="PutObject failed: HTTP 412 PreconditionFailed"):
        _ = client.put_object(input)


def test_ranged_get_206() raises:
    var client = _client(_mk_206, _creds())
    var input = S3GetObjectRequest(String("lake"), String("data/a.parquet"))
    input.set_range_(String("bytes=0-9"))
    var out = client.get_object(input)
    assert_equal(out.content_range.value(), "bytes 0-9/52428800")
    assert_equal(out.content_length.value(), Int64(10))
    assert_equal(out.e_tag.value(), '"9b2cf535f27731c974343645a3985328"')
    assert_equal(
        s3_content_range_total(out.content_range.value()).value(), 52428800
    )
    assert_equal(len(out.body.value()), 10)
    assert_equal(out.body.value()[0], UInt8(0x30))


def test_list_two_pages() raises:
    var first = _client(_mk_page_1, _creds())
    var input = S3ListObjectsV2Request(String("lake"))
    input.set_prefix(String("data/"))
    var page = first.list_objects_v2(input)
    assert_true(page.is_truncated.value())
    assert_equal(page.contents.value()[0].key.value(), "data/a.parquet")
    var token = page.next_continuation_token.value().copy()
    assert_equal(token, "1ueGcxLPRx1Tr")
    # The next page, asked for with the token the first one gave.
    var second = _client(_mk_page_2, first^.into_creds_source())
    input.set_continuation_token(token)
    var last = second.list_objects_v2(input)
    assert_false(last.is_truncated.value())
    assert_false(Bool(last.next_continuation_token))
    assert_equal(last.contents.value()[0].key.value(), "data/b.parquet")
    assert_equal(last.contents.value()[0].size.value(), Int64(20))


def test_multipart_create_upload_complete() raises:
    var create = _client(_mk_create, _creds())
    var started = create.create_multipart_upload(
        S3CreateMultipartUploadRequest(String("lake"), String("big.bin"))
    )
    var upload_id = started.upload_id.value().copy()
    assert_equal(upload_id, _UPLOAD_ID)
    var part = _client(_mk_part, create^.into_creds_source())
    var part_input = S3UploadPartRequest(
        String("lake"), String("big.bin"), Int32(1), upload_id
    )
    part_input.set_body(_bytes(String("part one")))
    var uploaded = part.upload_part(part_input)
    assert_equal(uploaded.e_tag.value(), '"b54357faf0632cce46e942fa68356b38"')
    var parts = List[S3CompletedPart]()
    var p = S3CompletedPart()
    p.set_part_number(Int32(1))
    p.set_e_tag(uploaded.e_tag.value().copy())
    parts.append(p^)
    var doc = S3CompletedMultipartUpload()
    doc.set_parts(parts^)
    var complete_input = S3CompleteMultipartUploadRequest(
        String("lake"), String("big.bin"), upload_id
    )
    complete_input.set_multipart_upload(doc^)
    var complete = _client(_mk_complete, part^.into_creds_source())
    var done = complete.complete_multipart_upload(complete_input)
    assert_equal(done.e_tag.value(), '"3858f62230ac3c915f300c664312c11f-1"')
    assert_equal(done.key.value(), "big.bin")


def test_abort_of_a_gone_upload_is_404() raises:
    var client = _client(_mk_abort_404, _creds())
    with assert_raises(contains="AbortMultipartUpload failed: HTTP 404 NoSuchUpload"):
        _ = client.abort_multipart_upload(
            S3AbortMultipartUploadRequest(
                String("lake"), String("big.bin"), String(_UPLOAD_ID)
            )
        )


def test_head_404_has_no_body() raises:
    var client = _client(_mk_head_404, _creds())
    with assert_raises(contains="HeadObject failed: HTTP 404 404"):
        _ = client.head_object(
            S3HeadObjectRequest(String("lake"), String("missing"))
        )


def test_503_slow_down_is_retried() raises:
    var client = _client(_mk_503_then_ok, _creds())
    var out = client.get_object(S3GetObjectRequest(String("lake"), String("k")))
    assert_equal(String(unsafe_from_utf8=Span(out.body.value())), "hello")


def test_copy_200_with_error_is_retried() raises:
    var client = _client(_mk_copy_200_error_then_ok, _creds())
    var input = S3CopyObjectRequest(
        String("lake"), s3_copy_source(String("lake"), String("a")), String("b")
    )
    var out = client.copy_object(input)
    assert_equal(
        out.copy_object_result.value().e_tag.value(),
        '"9b2cf535f27731c974343645a3985328"',
    )


def main() raises:
    test_conditional_put_loses_the_race()
    test_ranged_get_206()
    test_list_two_pages()
    test_multipart_create_upload_complete()
    test_abort_of_a_gone_upload_is_404()
    test_head_404_has_no_body()
    test_503_slow_down_is_retried()
    test_copy_200_with_error_is_retried()
    print("OK")
