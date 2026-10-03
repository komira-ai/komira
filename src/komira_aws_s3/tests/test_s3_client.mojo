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
# Rows: a conditional PutObject that loses the race (412), and one not
# resent after a 500 though the plain verb states no precondition, a ranged
# GetObject (206), two ListObjectsV2 pages, CreateMultipartUpload,
# UploadPart and CompleteMultipartUpload, an AbortMultipartUpload of an
# upload that is gone (404 NoSuchUpload), and a HeadObject 404 (no body).
# None of those answers is retried, so no row waits.
#
# Then each verb's request as it reached the wire: the client is given
# komira_aws_core's AwsEchoConnector, whose answer is an S3 error naming
# the request head, so a row asserts the request line (the path-style
# target, the bucket once), the Host, the signing scope and the headers
# the verb sends, through the generated client and its endpoint ruleset.
#
# The retries are test_s3_retry's: it drives the same send with a sleeper
# that records, so no row here waits a real backoff. The last row drives the
# verbs over injected seams (`<op>_with`): a transport over one scripted
# connector, a fixed signing clock and a retry loop whose sleeper records,
# the raw response answered, and a conditional PutObject not resent after a
# 500 that an unconditional one is.
from komira_aws_s3.komira_aws_s3 import (
    S3AbortMultipartUploadRequest,
    S3DeleteObjectRequest,
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
    AWS_ECHO_CODE,
    AwsCredential,
    AwsEchoConnector,
    StaticCredsSource,
    s3_content_range_total,
    s3_copy_source,
)
from komira_aws_core import AwsConnectorTransport, FixedClock
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_retry import (
    Backoff,
    Jitter,
    ManualClock,
    NoBudget,
    RecordingSleeper,
    RetryLoop,
    RetryPolicy,
    SplitMix64Rng,
)
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


def _mk_500_then_412() raises -> ScriptedConnector:
    var c = ScriptedConnector.with_stream(
        _answer(
            500,
            "Internal Server Error",
            "<Error><Code>InternalError</Code></Error>",
            "Content-Type: application/xml\r\n",
        )
    )
    c.arm_next(
        _answer(
            412,
            "Precondition Failed",
            "<Error><Code>PreconditionFailed</Code></Error>",
            "Content-Type: application/xml\r\n",
        )
    )
    return c^


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


def test_plain_conditional_put_is_not_resent_after_a_500() raises:
    # The plain verb states nothing about its precondition: the send reads
    # the If-Match off the request, so a 500 that S3 may have answered
    # having applied the write is returned as it is. Resent, the write
    # would come back 412 and read as a lost race.
    var client = _client(_mk_500_then_412, _creds())
    var input = S3PutObjectRequest(String("lake"), String("manifest.json"))
    input.set_body(_bytes(String('{"v":2}')))
    input.set_if_match(String('"e1"'))
    with assert_raises(contains="PutObject failed: HTTP 500 InternalError"):
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


# ---- the requests on the wire ----------------------------------------------------


comptime _Echo = S3S3Client[AwsEchoConnector, StaticCredsSource]


def _mk_echo() raises -> AwsEchoConnector:
    return AwsEchoConnector.xml()


def _echo() raises -> _Echo:
    return _Echo(_mk_echo, _creds(), String("us-east-1"), _config())


def _wire(e: Error) raises -> String:
    """The request head an echo answered with, lower-cased."""
    var text = String(e)
    var marker = String("failed: HTTP 400 ") + AWS_ECHO_CODE + " "
    var at = text.find(marker)
    if at < 0:
        raise Error("not the echo's answer: " + text)
    return String(text[byte = at + marker.byte_length() : text.byte_length()]).lower()


def _check(wire: String, line: String, *wants: String) raises:
    """`wire` starts with the request line `line` and holds every header
    line of `wants`, and what every S3 request carries: the endpoint's
    Host and a SigV4 signature scoped to us-east-1 and s3."""
    assert_true(wire.startswith(line.lower() + " | "), line + " is not the start of " + wire)
    var all = List[String]()
    for w in wants:
        all.append(w)
    all.append(String("host: 127.0.0.1:9000"))
    all.append(String("/us-east-1/s3/aws4_request, signedheaders="))
    all.append(String("x-amz-content-sha256: "))
    for i in range(len(all)):
        assert_true(wire.find(all[i].lower()) >= 0, all[i] + " is not in " + wire)


def test_put_object_on_the_wire() raises:
    var client = _echo()
    var input = S3PutObjectRequest(String("lake"), String("manifest.json"))
    input.set_body(_bytes(String('{"v":2}')))
    input.set_if_none_match(String("*"))
    try:
        _ = client.put_object(input)
        raise Error("the echo answered PutObject with a success")
    except e:
        _check(
            _wire(e),
            "PUT /lake/manifest.json HTTP/1.1",
            "if-none-match: *",
            "x-amz-checksum-crc32: ",
            "content-length: 7",
        )


def test_get_object_on_the_wire() raises:
    var client = _echo()
    var input = S3GetObjectRequest(String("lake"), String("data/a.parquet"))
    input.set_range_(String("bytes=0-9"))
    try:
        _ = client.get_object(input)
        raise Error("the echo answered GetObject with a success")
    except e:
        _check(_wire(e), "GET /lake/data/a.parquet HTTP/1.1", "range: bytes=0-9")


def test_list_objects_v2_on_the_wire() raises:
    var client = _echo()
    var input = S3ListObjectsV2Request(String("lake"))
    input.set_prefix(String("data/"))
    try:
        _ = client.list_objects_v2(input)
        raise Error("the echo answered ListObjectsV2 with a success")
    except e:
        _check(_wire(e), "GET /lake?list-type=2&prefix=data%2F HTTP/1.1")


def test_multipart_on_the_wire() raises:
    var client = _echo()
    try:
        _ = client.create_multipart_upload(
            S3CreateMultipartUploadRequest(String("lake"), String("big.bin"))
        )
        raise Error("the echo answered CreateMultipartUpload with a success")
    except e:
        _check(_wire(e), "POST /lake/big.bin?uploads HTTP/1.1")
    var part = S3UploadPartRequest(String("lake"), String("big.bin"), Int32(1), String("u1"))
    part.set_body(_bytes(String("part one")))
    try:
        _ = client.upload_part(part)
        raise Error("the echo answered UploadPart with a success")
    except e:
        _check(
            _wire(e),
            "PUT /lake/big.bin?partNumber=1&uploadId=u1 HTTP/1.1",
            "x-amz-checksum-crc32: ",
        )
    try:
        _ = client.complete_multipart_upload(
            S3CompleteMultipartUploadRequest(String("lake"), String("big.bin"), String("u1"))
        )
        raise Error("the echo answered CompleteMultipartUpload with a success")
    except e:
        _check(_wire(e), "POST /lake/big.bin?uploadId=u1 HTTP/1.1")
    try:
        _ = client.abort_multipart_upload(
            S3AbortMultipartUploadRequest(String("lake"), String("big.bin"), String("u1"))
        )
        raise Error("the echo answered AbortMultipartUpload with a success")
    except e:
        _check(_wire(e), "DELETE /lake/big.bin?uploadId=u1 HTTP/1.1")


def test_copy_and_delete_on_the_wire() raises:
    var client = _echo()
    try:
        _ = client.copy_object(
            S3CopyObjectRequest(
                String("lake"), s3_copy_source(String("lake"), String("a")), String("b")
            )
        )
        raise Error("the echo answered CopyObject with a success")
    except e:
        _check(_wire(e), "PUT /lake/b HTTP/1.1", "x-amz-copy-source: lake/a")
    try:
        _ = client.delete_object(S3DeleteObjectRequest(String("lake"), String("b")))
        raise Error("the echo answered DeleteObject with a success")
    except e:
        _check(_wire(e), "DELETE /lake/b HTTP/1.1")


def _never() raises -> ScriptedConnector:
    raise Error("a verb over injected seams dialed through the factory")


def _loop() raises -> RetryLoop[ManualClock, RecordingSleeper, SplitMix64Rng]:
    return RetryLoop[ManualClock, RecordingSleeper, SplitMix64Rng](
        RetryPolicy(
            Backoff(initial_ms=1000, multiplier=2.0, max_ms=20_000, jitter=Jitter.full()),
            max_attempts=3,
            deadline_ms=Int64(600_000),
        ),
        ManualClock(),
        RecordingSleeper(),
        SplitMix64Rng(7),
    )


def test_verbs_over_injected_seams() raises:
    # `<op>_with` sends over the transport, signing clock and retry loop it
    # is given, never through the client's connector factory, and answers
    # the response as it came, so a caller reads a 206 or a 412 itself.
    var script = ScriptedConnector.with_stream(
        _answer(
            500,
            "Internal Server Error",
            "<Error><Code>InternalError</Code></Error>",
        )
    )
    script.arm_next(_answer(200, "OK", "", 'ETag: "e2"\r\n'))
    script.arm_next(
        _answer(206, "Partial Content", "0123", "Content-Range: bytes 4-7/8\r\n")
    )
    var transport = AwsConnectorTransport[ScriptedConnector](script^)
    var clock = FixedClock(1790000000)
    var budget = NoBudget()
    var client = _client(_never, _creds())
    # A conditional PutObject that met a 500 is not sent again: had S3
    # applied it, the resend would be answered 412.
    var put = S3PutObjectRequest(String("lake"), String("manifest.json"))
    put.set_body(_bytes(String("{}")))
    put.set_if_match(String('"e1"'))
    var loop = _loop()
    var res = client.put_object_with(put, transport, clock, loop, budget)
    assert_equal(res.status, 500)
    assert_equal(len(loop.sleeper().slept), 0)
    # Unconditional, the same 500 is retried (the next answer is the 200).
    var put2 = S3PutObjectRequest(String("lake"), String("other.json"))
    put2.set_body(_bytes(String("{}")))
    var loop2 = _loop()
    var res2 = client.put_object_with(put2, transport, clock, loop2, budget)
    assert_equal(res2.status, 200)
    assert_equal(res2.header(String("etag")), '"e2"')
    # A ranged GetObject answers the raw 206, which the parser reads.
    var get = S3GetObjectRequest(String("lake"), String("data/a.parquet"))
    get.set_range_(String("bytes=4-7"))
    var loop3 = _loop()
    var res3 = client.get_object_with(get, transport, clock, loop3, budget)
    assert_equal(res3.status, 206)
    assert_equal(res3.header(String("content-range")), "bytes 4-7/8")
    assert_equal(len(res3.body), 4)


def main() raises:
    test_conditional_put_loses_the_race()
    test_plain_conditional_put_is_not_resent_after_a_500()
    test_verbs_over_injected_seams()
    test_ranged_get_206()
    test_list_two_pages()
    test_multipart_create_upload_complete()
    test_abort_of_a_gone_upload_is_404()
    test_head_404_has_no_body()
    test_put_object_on_the_wire()
    test_get_object_on_the_wire()
    test_list_objects_v2_on_the_wire()
    test_multipart_on_the_wire()
    test_copy_and_delete_on_the_wire()
    print("OK")
