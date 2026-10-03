# S3Store verb by verb against S3's answers, through the generated client,
# komira_aws_core's send and komira_http_client, over komira_http_core's
# ScriptedConnector: each row's connector is armed with the answers S3 gives
# (the S3 API reference's), one stream per request. No socket.
#
# Rows: HeadObject (200, 404 without a body, 403); GetObject whole; a ranged
# GetObject (206 checked against the range asked for, a 206 that starts or
# ends elsewhere, a 206 without a Content-Range, a 200 cut to the window,
# an object that ends first); a suffix GetObject (206 and 200, a suffix
# longer than the object, a 206 that starts before the suffix); a listing of
# two pages with common prefixes and URL-encoded keys decoded, and the
# continuation guards (a truncated page without a token, a token repeated);
# DeleteObject (204, an absent key, a missing bucket, a refusal); a
# multipart upload (create, a part, complete; an abort of an upload that is
# gone and of one in a missing bucket; part number and part order refused;
# a CompleteMultipartUpload answered 200 with an <Error>, not resent); a
# conditional PutObject (412, 409 race, an answer without an ETag, a 500 not
# resent while an unconditional one is, If-None-Match with an ETag refused);
# and a 503 SlowDown retried. Retries wait 1 ms (the config's
# policy), so no row waits long.
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_aws_core import AwsCredential, FixedClock, StaticCredsSource
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_objectstore.types import WritePrecondition
from komira_objectstore_s3 import (
    AddressingStyle,
    S3Config,
    S3Store,
    S3UploadedPart,
)
from komira_retry import Backoff, Jitter, RetryPolicy


# S3's XML namespace: a fixed protocol constant, named in every S3 response.
comptime _NS = 'xmlns="http://s3.amazonaws.com/doc/2006-03-01/"'
comptime _Store = S3Store[ScriptedConnector, StaticCredsSource, FixedClock]


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _text(b: List[UInt8]) -> String:
    return String(unsafe_from_utf8=Span(b))


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


def _error(status: Int, reason: String, code: String, message: String = "m") -> ScriptedStream:
    return _answer(
        status,
        reason,
        String("<Error><Code>") + code + "</Code><Message>" + message + "</Message></Error>",
        "Content-Type: application/xml\r\n",
    )


def _store(
    mk: def () raises thin -> ScriptedConnector,
    endpoint: String = "http://127.0.0.1:9000",
) raises -> _Store:
    var config = S3Config(
        "us-east-1",
        endpoint=endpoint,
        addressing=AddressingStyle.path(),
        retry=RetryPolicy(
            Backoff(initial_ms=1, multiplier=2.0, max_ms=2, jitter=Jitter.full()),
            max_attempts=3,
            deadline_ms=Int64(60_000),
        ),
    )
    return _Store(
        config^,
        mk,
        StaticCredsSource(
            AwsCredential(
                String("AKIDEXAMPLE"),
                String("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
                String(""),
            )
        ),
        FixedClock(1790000000),
    )


def _one(var s: ScriptedStream) -> ScriptedConnector:
    return ScriptedConnector.with_stream(s^)


# ---- HeadObject -------------------------------------------------------------


def _mk_head() raises -> ScriptedConnector:
    return _one(
        ScriptedStream.from_read_script(
            _bytes(
                "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n"
                'ETag: "e1"\r\nx-amz-meta-x: y\r\n'
                "Last-Modified: Thu, 01 Oct 2026 12:00:00 GMT\r\n\r\n"
            )
        )
    )


def _mk_head_404() raises -> ScriptedConnector:
    return _one(_answer(404, "Not Found", ""))


def _mk_head_403() raises -> ScriptedConnector:
    return _one(_answer(403, "Forbidden", ""))


def test_head() raises:
    var s = _store(_mk_head)
    var m = s.head("lake", "data/a.parquet")
    assert_equal(m.location, "data/a.parquet")
    assert_equal(m.etag, '"e1"')
    assert_equal(m.version, '"e1"')
    assert_equal(m.last_modified_unix_ms, Int64(1790856000) * 1000)
    var a = _store(_mk_head_404)
    with assert_raises(contains="StoreError[NOT_FOUND] HeadObject s3://lake/k status=404"):
        _ = a.head("lake", "k")
    var d = _store(_mk_head_403)
    with assert_raises(contains="StoreError[PERMISSION_DENIED] HeadObject s3://lake/k status=403"):
        _ = d.head("lake", "k")


# ---- GetObject ----------------------------------------------------------------


def _mk_get() raises -> ScriptedConnector:
    return _one(_answer(200, "OK", "0123456789", 'ETag: "e1"\r\n'))


def _mk_206() raises -> ScriptedConnector:
    return _one(_answer(206, "Partial Content", "2345", "Content-Range: bytes 2-5/10\r\n"))


def _mk_206_elsewhere() raises -> ScriptedConnector:
    return _one(_answer(206, "Partial Content", "1234", "Content-Range: bytes 1-4/10\r\n"))


def _mk_206_bare() raises -> ScriptedConnector:
    return _one(_answer(206, "Partial Content", "2345"))


def _mk_206_tail() raises -> ScriptedConnector:
    return _one(_answer(206, "Partial Content", "89", "Content-Range: bytes 8-9/10\r\n"))


def _mk_404_key() raises -> ScriptedConnector:
    return _one(_error(404, "Not Found", "NoSuchKey", "The specified key does not exist."))


def _mk_416() raises -> ScriptedConnector:
    return _one(_error(416, "Requested Range Not Satisfiable", "InvalidRange"))


def test_get() raises:
    var s = _store(_mk_get)
    assert_equal(_text(s.get("lake", "k")), "0123456789")
    var n = _store(_mk_404_key)
    with assert_raises(contains="StoreError[NOT_FOUND] GetObject s3://lake/k status=404 s3_code=NoSuchKey"):
        _ = n.get("lake", "k")


def test_get_range() raises:
    # [2, 6) is asked as bytes=2-5 and answered as such.
    var s = _store(_mk_206)
    assert_equal(_text(s.get_range("lake", "k", 2, 4)), "2345")
    var e = _store(_mk_206_elsewhere)
    with assert_raises(contains="the 206 starts at byte 1, not the 2 asked for"):
        _ = e.get_range("lake", "k", 2, 4)
    var b = _store(_mk_206_bare)
    with assert_raises(contains="a 206 without a Content-Range"):
        _ = b.get_range("lake", "k", 2, 4)
    # A server that ignored the Range: the window is cut from the object.
    var w = _store(_mk_get)
    assert_equal(_text(w.get_range("lake", "k", 2, 4)), "2345")
    # The object ends first: fewer bytes, the 206 ending at its last byte.
    var t = _store(_mk_206_tail)
    assert_equal(_text(t.get_range("lake", "k", 8, 4)), "89")
    var r = _store(_mk_416)
    with assert_raises(contains="StoreError[MALFORMED] GetObject s3://lake/k status=416 s3_code=InvalidRange"):
        _ = r.get_range("lake", "k", 100, 4)
    # A zero length sends nothing (the connector has no answer armed).
    var z = _store(_mk_head_404)
    assert_equal(len(z.get_range("lake", "k", 5, 0)), 0)
    with assert_raises(contains="at least one byte"):
        _ = z.get_range("lake", "k", 5, -1)


def _mk_suffix() raises -> ScriptedConnector:
    return _one(_answer(206, "Partial Content", "789", "Content-Range: bytes 7-9/10\r\n"))


def _mk_suffix_too_early() raises -> ScriptedConnector:
    return _one(_answer(206, "Partial Content", "0123456789", "Content-Range: bytes 0-9/10\r\n"))


def test_get_suffix() raises:
    # A 206 that ends at the object's last byte but starts before the
    # suffix asked for is not the suffix.
    var early = _store(_mk_suffix_too_early)
    with assert_raises(contains="a suffix 206 that is not the object's tail: bytes 0-9/10"):
        _ = early.get_suffix("lake", "k", 3)
    # A suffix longer than the object is the whole object.
    var whole = _store(_mk_suffix_too_early)
    var w10 = whole.get_suffix("lake", "k", 20)
    assert_equal(_text(w10.bytes), "0123456789")
    assert_equal(w10.offset, 0)
    var s = _store(_mk_suffix)
    var tail = s.get_suffix("lake", "k", 3)
    assert_equal(_text(tail.bytes), "789")
    assert_equal(tail.offset, 7)
    assert_equal(tail.total, 10)
    # A 200: the whole object, whose last bytes are cut.
    var w = _store(_mk_get)
    var all = w.get_suffix("lake", "k", 3)
    assert_equal(_text(all.bytes), "789")
    assert_equal(all.offset, 7)
    assert_equal(all.total, 10)


# ---- ListObjectsV2 --------------------------------------------------------------


def _mk_pages() raises -> ScriptedConnector:
    var c = _one(
        _answer(
            200,
            "OK",
            String("<ListBucketResult ")
            + _NS
            + "><Name>lake</Name><Prefix>data%2F</Prefix><Delimiter>%2F</Delimiter>"
            + "<EncodingType>url</EncodingType><KeyCount>2</KeyCount><MaxKeys>2</MaxKeys>"
            + "<IsTruncated>true</IsTruncated>"
            + "<Contents><Key>data/a%20b+c.parquet</Key><Size>10</Size>"
            + "<ETag>&quot;e1&quot;</ETag><LastModified>2026-10-01T12:00:00.000Z</LastModified></Contents>"
            + "<CommonPrefixes><Prefix>data/year%3D2026/</Prefix></CommonPrefixes>"
            + "<NextContinuationToken>tok1</NextContinuationToken></ListBucketResult>",
        )
    )
    c.arm_next(
        _answer(
            200,
            "OK",
            String("<ListBucketResult ")
            + _NS
            + "><Name>lake</Name><Prefix>data%2F</Prefix><EncodingType>url</EncodingType>"
            + "<KeyCount>1</KeyCount><MaxKeys>2</MaxKeys><IsTruncated>false</IsTruncated>"
            + "<Contents><Key>data/%01ctl</Key><Size>20</Size></Contents>"
            + "<ContinuationToken>tok1</ContinuationToken></ListBucketResult>",
        )
    )
    return c^


def _page(truncated: Bool, token: String) -> ScriptedStream:
    var body = (
        String("<ListBucketResult ")
        + _NS
        + "><Name>lake</Name><KeyCount>1</KeyCount><IsTruncated>"
        + ("true" if truncated else "false")
        + "</IsTruncated><Contents><Key>k</Key><Size>1</Size></Contents>"
    )
    if token.byte_length() > 0:
        body += "<NextContinuationToken>" + token + "</NextContinuationToken>"
    body += "</ListBucketResult>"
    return _answer(200, "OK", body)


def _mk_truncated_no_token() raises -> ScriptedConnector:
    return _one(_page(True, ""))


def _mk_token_repeats() raises -> ScriptedConnector:
    var c = _one(_page(True, "t1"))
    c.arm_next(_page(True, "t1"))
    return c^


def test_list_pages() raises:
    var s = _store(_mk_pages)
    var r = s.list("lake", "data/", "/")
    assert_equal(len(r.objects), 2)
    # Names come back URL-encoded (encoding-type=url) and are decoded.
    assert_equal(r.objects[0].location, "data/a b c.parquet")
    assert_equal(r.objects[0].size, 10)
    assert_equal(r.objects[0].etag, '"e1"')
    assert_equal(r.objects[0].last_modified_unix_ms, Int64(1790856000) * 1000)
    assert_equal(r.objects[1].location, "data/\x01ctl")
    assert_equal(len(r.common_prefixes), 1)
    assert_equal(r.common_prefixes[0], "data/year=2026/")


def test_list_guards() raises:
    var a = _store(_mk_truncated_no_token)
    with assert_raises(contains="a truncated page without a NextContinuationToken"):
        _ = a.list("lake", "", "")
    var b = _store(_mk_token_repeats)
    with assert_raises(contains="NextContinuationToken is the token it was asked with"):
        _ = b.list("lake", "", "")


# ---- DeleteObject -----------------------------------------------------------------


def _mk_204() raises -> ScriptedConnector:
    return _one(_answer(204, "No Content", ""))


def _mk_404_bucket() raises -> ScriptedConnector:
    return _one(_error(404, "Not Found", "NoSuchBucket", "The specified bucket does not exist"))


def _mk_404_bare() raises -> ScriptedConnector:
    return _one(_answer(404, "Not Found", ""))


def _mk_403_delete() raises -> ScriptedConnector:
    return _one(_error(403, "Forbidden", "AccessDenied", "Access Denied"))


def test_delete() raises:
    var s = _store(_mk_204)
    s.delete("lake", "k")
    var a = _store(_mk_404_key)
    a.delete("lake", "k")
    var bare = _store(_mk_404_bare)
    bare.delete("lake", "k")
    # A missing bucket is not a deleted key: a wrong bucket or endpoint.
    var nb = _store(_mk_404_bucket)
    with assert_raises(contains="StoreError[NOT_FOUND] DeleteObject s3://lake/k status=404 s3_code=NoSuchBucket"):
        nb.delete("lake", "k")
    var d = _store(_mk_403_delete)
    with assert_raises(contains="StoreError[PERMISSION_DENIED] DeleteObject s3://lake/k status=403 s3_code=AccessDenied"):
        d.delete("lake", "k")


# ---- multipart -------------------------------------------------------------------


def _mk_multipart() raises -> ScriptedConnector:
    var c = _one(
        _answer(
            200,
            "OK",
            String("<InitiateMultipartUploadResult ")
            + _NS
            + "><Bucket>lake</Bucket><Key>big.bin</Key><UploadId>u-1</UploadId>"
            + "</InitiateMultipartUploadResult>",
        )
    )
    c.arm_next(_answer(200, "OK", "", 'ETag: "p1"\r\n'))
    c.arm_next(_answer(200, "OK", "", 'ETag: "p2"\r\n'))
    c.arm_next(
        _answer(
            200,
            "OK",
            String("<CompleteMultipartUploadResult ")
            + _NS
            + "><Bucket>lake</Bucket><Key>big.bin</Key>"
            + "<ETag>&quot;whole-2&quot;</ETag></CompleteMultipartUploadResult>",
        )
    )
    return c^


def _mk_abort_gone() raises -> ScriptedConnector:
    return _one(_error(404, "Not Found", "NoSuchUpload", "The specified upload does not exist."))


def _mk_complete_200_error() raises -> ScriptedConnector:
    # S3 can fail the assembly after its 200: the body is an <Error>. The
    # send reads it as a 500. CompleteMultipartUpload is a POST, so it is not
    # sent again: the second answer, a success, is never read.
    var body = String("<Error><Code>InternalError</Code><Message>We encountered an internal error.</Message></Error>")
    var c = _one(_answer(200, "OK", body))
    c.arm_next(
        _answer(
            200,
            "OK",
            String("<CompleteMultipartUploadResult ")
            + _NS
            + "><Bucket>lake</Bucket><Key>big.bin</Key>"
            + "<ETag>&quot;whole-2&quot;</ETag></CompleteMultipartUploadResult>",
        )
    )
    return c^


def _mk_abort_no_bucket() raises -> ScriptedConnector:
    return _one(_error(404, "Not Found", "NoSuchBucket", "The specified bucket does not exist"))


def test_multipart() raises:
    var s = _store(_mk_multipart)
    var id = s.create_multipart_upload("lake", "big.bin")
    assert_equal(id, "u-1")
    var parts = List[S3UploadedPart]()
    parts.append(s.upload_part("lake", "big.bin", id, 1, _bytes("one")))
    parts.append(s.upload_part("lake", "big.bin", id, 2, _bytes("two")))
    assert_equal(parts[1].etag, '"p2"')
    var done = s.complete_multipart_upload("lake", "big.bin", id, parts)
    assert_equal(done.etag, '"whole-2"')
    var a = _store(_mk_abort_gone)
    a.abort_multipart_upload("lake", "big.bin", "u-1")
    var nb = _store(_mk_abort_no_bucket)
    with assert_raises(contains="StoreError[NOT_FOUND] AbortMultipartUpload s3://lake/big.bin status=404 s3_code=NoSuchBucket"):
        nb.abort_multipart_upload("lake", "big.bin", "u-1")
    with assert_raises(contains="part numbers are 1 to 10000, got 0"):
        _ = a.upload_part("lake", "big.bin", "u-1", 0, _bytes("x"))
    with assert_raises(contains="part numbers are 1 to 10000, got 10001"):
        _ = a.upload_part("lake", "big.bin", "u-1", 10001, _bytes("x"))
    var backwards = List[S3UploadedPart]()
    backwards.append(S3UploadedPart(2, String('"p2"')))
    backwards.append(S3UploadedPart(1, String('"p1"')))
    with assert_raises(contains="ascending part number"):
        _ = a.complete_multipart_upload("lake", "big.bin", "u-1", backwards)
    with assert_raises(contains="no parts"):
        _ = a.complete_multipart_upload("lake", "big.bin", "u-1", List[S3UploadedPart]())
    var e = _store(_mk_complete_200_error)
    with assert_raises(contains="StoreError[TRANSPORT] CompleteMultipartUpload s3://lake/big.bin status=500 s3_code=InternalError"):
        _ = e.complete_multipart_upload("lake", "big.bin", "u-1", parts)


# ---- the conditional PUT --------------------------------------------------------------


def _mk_put() raises -> ScriptedConnector:
    return _one(_answer(200, "OK", "", 'ETag: "e2"\r\n'))


def _mk_412() raises -> ScriptedConnector:
    return _one(_error(412, "Precondition Failed", "PreconditionFailed", "At least one of the pre-conditions you specified did not hold"))


def _mk_409() raises -> ScriptedConnector:
    return _one(
        _error(
            409,
            "Conflict",
            "ConditionalRequestConflict",
            "A conflicting conditional operation is currently in progress against this resource. Please try again.",
        )
    )


def _mk_500_then_412() raises -> ScriptedConnector:
    var c = _one(_error(500, "Internal Server Error", "InternalError", "We encountered an internal error."))
    c.arm_next(_error(412, "Precondition Failed", "PreconditionFailed", "At least one of the pre-conditions you specified did not hold"))
    return c^


def _mk_500_then_put() raises -> ScriptedConnector:
    var c = _one(_error(500, "Internal Server Error", "InternalError", "We encountered an internal error."))
    c.arm_next(_answer(200, "OK", "", 'ETag: "e2"\r\n'))
    return c^


def _mk_put_no_etag() raises -> ScriptedConnector:
    return _one(_answer(200, "OK", ""))


def test_conditional_put() raises:
    var s = _store(_mk_put)
    var m = s.conditional_put("lake", "m.json", _bytes("{}"), WritePrecondition.if_match('"e1"'))
    assert_equal(m.etag, '"e2"')
    assert_equal(m.version, '"e2"')
    assert_equal(m.size, 2)
    var p = _store(_mk_412)
    with assert_raises(contains="StoreError[PRECONDITION] PutObject s3://lake/m.json status=412 s3_code=PreconditionFailed"):
        _ = p.conditional_put("lake", "m.json", _bytes("{}"), WritePrecondition.if_none_match_star())
    var c = _store(_mk_409)
    with assert_raises(contains="StoreError[PRECONDITION] PutObject s3://lake/m.json status=409 s3_code=ConditionalRequestConflict"):
        _ = c.conditional_put("lake", "m.json", _bytes("{}"), WritePrecondition.if_match('"e1"'))
    var n = _store(_mk_put_no_etag)
    with assert_raises(contains="a success without an ETag"):
        _ = n.conditional_put("lake", "m.json", _bytes("{}"), WritePrecondition.none())
    with assert_raises(contains="If-Match with an empty ETag"):
        _ = n.conditional_put("lake", "m.json", _bytes("{}"), WritePrecondition.if_match(""))
    # AWS's S3 takes If-None-Match on a PUT only as *: to its own endpoint
    # an ETag is refused before anything is sent (the connector has no
    # answer armed). test_s3_wire sends one to a custom endpoint.
    var z = _store(_mk_head_404, endpoint="")
    with assert_raises(contains="StoreError[MALFORMED] PutObject s3://lake/m.json: S3 takes If-None-Match on PutObject only as *"):
        _ = z.conditional_put("lake", "m.json", _bytes("{}"), WritePrecondition.if_none_match('"e1"'))


def test_a_conditional_put_is_not_resent_after_a_500() raises:
    # S3 may have applied the write before its 500: sent again, it would be
    # answered 412 and read as a lost race. So the 500 is the answer, and
    # the 412 armed after it is never read.
    var c = _store(_mk_500_then_412)
    with assert_raises(contains="StoreError[TRANSPORT] PutObject s3://lake/m.json status=500 s3_code=InternalError"):
        _ = c.conditional_put("lake", "m.json", _bytes("{}"), WritePrecondition.if_match('"e1"'))
    var star = _store(_mk_500_then_412)
    with assert_raises(contains="StoreError[TRANSPORT] PutObject s3://lake/m.json status=500 s3_code=InternalError"):
        _ = star.conditional_put("lake", "m.json", _bytes("{}"), WritePrecondition.if_none_match_star())
    # Unconditional, the PUT is resent and the second answer is the result.
    var u = _store(_mk_500_then_put)
    var m = u.conditional_put("lake", "m.json", _bytes("{}"), WritePrecondition.none())
    assert_equal(m.etag, '"e2"')


# ---- retries ---------------------------------------------------------------------


def _mk_slow_down() raises -> ScriptedConnector:
    var c = _one(_error(503, "Slow Down", "SlowDown", "Please reduce your request rate."))
    c.arm_next(_answer(200, "OK", "abc"))
    return c^


def _mk_slow_down_always() raises -> ScriptedConnector:
    var c = _one(_error(503, "Slow Down", "SlowDown", "Please reduce your request rate."))
    c.arm_next(_error(503, "Slow Down", "SlowDown", "Please reduce your request rate."))
    c.arm_next(_error(503, "Slow Down", "SlowDown", "Please reduce your request rate."))
    return c^


def test_retries() raises:
    var s = _store(_mk_slow_down)
    assert_equal(_text(s.get("lake", "k")), "abc")
    var t = _store(_mk_slow_down_always)
    with assert_raises(contains="StoreError[THROTTLED] GetObject s3://lake/k status=503 s3_code=SlowDown"):
        _ = t.get("lake", "k")


def main() raises:
    test_head()
    test_get()
    test_get_range()
    test_get_suffix()
    test_list_pages()
    test_list_guards()
    test_delete()
    test_multipart()
    test_conditional_put()
    test_a_conditional_put_is_not_resent_after_a_500()
    test_retries()
    print("OK")
