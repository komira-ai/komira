# Each S3Store verb's request as it reached the wire. The store sends over
# komira_aws_core's AwsEchoConnector, whose answer is an S3 error (400,
# code Echo) carrying the request head; the store raises it as a MALFORMED
# StoreError whose s3_message is that head. So a row asserts the request
# line (path-style: the bucket once, the key as the generated builder
# encodes it), the query, the headers the verb sends (Range, a ranged
# read's If-Match, If-None-Match, If-Match) and the signature, through the generated client,
# S3's endpoint ruleset and komira_aws_core's signer. No socket.
#
# The signing clock is the store's `K` parameter, a FixedClock here; nothing
# reads the date from the environment. Two stores on two fixed clocks sign
# at the two dates and no other.
from std.testing import assert_equal, assert_true

from komira_aws_core import AwsCredential, AwsEchoConnector, FixedClock, StaticCredsSource
from komira_http_client.client import HttpClientConfig
from komira_objectstore.types import WritePrecondition
from komira_objectstore_s3 import AddressingStyle, S3Config, S3Store
from komira_retry import Backoff, Jitter, RetryPolicy


comptime _Store = S3Store[AwsEchoConnector, StaticCredsSource, FixedClock]


def _mk_echo() raises -> AwsEchoConnector:
    return AwsEchoConnector.xml()


def _store(unix_seconds: Int = 1790000000) raises -> _Store:
    var config = S3Config(
        "us-east-1",
        endpoint="http://127.0.0.1:9000",
        addressing=AddressingStyle.path(),
        retry=RetryPolicy(
            Backoff(initial_ms=1, multiplier=2.0, max_ms=2, jitter=Jitter.full()),
            max_attempts=1,
            deadline_ms=Int64(60_000),
        ),
    )
    return _Store(
        config^,
        _mk_echo,
        HttpClientConfig.defaults(),
        StaticCredsSource(
            AwsCredential(
                String("AKIDEXAMPLE"),
                String("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
                String(""),
            )
        ),
        FixedClock(unix_seconds),
    )


def _wire(e: Error) raises -> String:
    """The request head the echo answered with, lower-cased."""
    var text = String(e)
    assert_true(text.startswith("StoreError[MALFORMED] "), text)
    var marker = String("status=400 s3_code=Echo s3_message=")
    var at = text.find(marker)
    if at < 0:
        raise Error("not the echo's answer: " + text)
    return String(text[byte = at + marker.byte_length() : text.byte_length()]).lower()


def _check(wire: String, line: String, *wants: String) raises:
    """`wire` starts with `line` and holds each of `wants`, and what every
    request carries: the endpoint's Host and a signature scoped to
    us-east-1 and s3, at the fixed clock's date."""
    assert_true(wire.startswith(line.lower() + " | "), line + " is not the start of " + wire)
    var all = List[String]()
    for w in wants:
        all.append(w)
    all.append(String("host: 127.0.0.1:9000"))
    all.append(String("credential=akidexample/20260921/us-east-1/s3/aws4_request, signedheaders="))
    all.append(String("x-amz-date: 20260921t141320z"))
    all.append(String("x-amz-content-sha256: "))
    for i in range(len(all)):
        assert_true(wire.find(all[i].lower()) >= 0, all[i] + " is not in " + wire)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def test_reads() raises:
    var s = _store()
    try:
        _ = s.get_range("lake", "data/a.parquet", 2, 4)
        raise Error("the echo answered with a success")
    except e:
        _check(_wire(e), "GET /lake/data/a.parquet HTTP/1.1", "range: bytes=2-5")
    try:
        _ = s.get_range("lake", "data/a.parquet", 2, 4, if_match='"e1"')
        raise Error("the echo answered with a success")
    except e:
        _check(
            _wire(e), "GET /lake/data/a.parquet HTTP/1.1", "range: bytes=2-5", 'if-match: "e1"'
        )
    try:
        _ = s.get_suffix("lake", "data/a.parquet", 8)
        raise Error("the echo answered with a success")
    except e:
        _check(_wire(e), "GET /lake/data/a.parquet HTTP/1.1", "range: bytes=-8")
    try:
        _ = s.get("lake", "a b/c")
        raise Error("the echo answered with a success")
    except e:
        # The key is percent-encoded once, '/' kept: S3's path is not
        # normalized or encoded twice.
        _check(_wire(e), "GET /lake/a%20b/c HTTP/1.1")


def test_listing() raises:
    var s = _store()
    try:
        _ = s.list_page("lake", "data/", "/", "tok-1")
        raise Error("the echo answered with a success")
    except e:
        var w = _wire(e)
        # The query in the generated builder's order; every value encoded.
        _check(
            w,
            "GET /lake?list-type=2&delimiter=%2F&encoding-type=url&max-keys=1000"
            "&prefix=data%2F&continuation-token=tok-1 HTTP/1.1",
        )


def test_writes() raises:
    var s = _store()
    try:
        _ = s.conditional_put("lake", "m.json", _bytes("{}"), WritePrecondition.if_none_match_star())
        raise Error("the echo answered with a success")
    except e:
        _check(_wire(e), "PUT /lake/m.json HTTP/1.1", "if-none-match: *", "content-length: 2")
    try:
        _ = s.conditional_put("lake", "m.json", _bytes("{}"), WritePrecondition.if_match('"e1"'))
        raise Error("the echo answered with a success")
    except e:
        _check(_wire(e), "PUT /lake/m.json HTTP/1.1", 'if-match: "e1"')
    try:
        # To a custom endpoint, the create-if-absent form of servers that
        # do not take `*`.
        _ = s.conditional_put("lake", "m.json", _bytes("{}"), WritePrecondition.if_none_match('"e1"'))
        raise Error("the echo answered with a success")
    except e:
        _check(_wire(e), "PUT /lake/m.json HTTP/1.1", 'if-none-match: "e1"')
    try:
        _ = s.conditional_put("lake", "m.json", _bytes("{}"), WritePrecondition.none())
        raise Error("the echo answered with a success")
    except e:
        var w = _wire(e)
        _check(w, "PUT /lake/m.json HTTP/1.1")
        assert_true(w.find("if-match") < 0 and w.find("if-none-match") < 0, w)
    try:
        s.delete("lake", "k")
        raise Error("the echo answered with a success")
    except e:
        _check(_wire(e), "DELETE /lake/k HTTP/1.1")


def test_multipart() raises:
    var s = _store()
    try:
        _ = s.create_multipart_upload("lake", "big.bin")
        raise Error("the echo answered with a success")
    except e:
        _check(_wire(e), "POST /lake/big.bin?uploads HTTP/1.1")
    try:
        _ = s.upload_part("lake", "big.bin", "u1", 3, _bytes("part"))
        raise Error("the echo answered with a success")
    except e:
        _check(_wire(e), "PUT /lake/big.bin?partNumber=3&uploadId=u1 HTTP/1.1")
    try:
        s.abort_multipart_upload("lake", "big.bin", "u1")
        raise Error("the echo answered with a success")
    except e:
        _check(_wire(e), "DELETE /lake/big.bin?uploadId=u1 HTTP/1.1")


def test_the_clock_is_the_parameter() raises:
    var later = _store(1790003600)
    try:
        _ = later.get("lake", "k")
        raise Error("the echo answered with a success")
    except e:
        var w = _wire(e)
        assert_true(w.find("x-amz-date: 20260921t151320z") >= 0, w)
        assert_true(w.find("20260921t141320z") < 0, w)


def main() raises:
    test_reads()
    test_listing()
    test_writes()
    test_multipart()
    test_the_clock_is_the_parameter()
    print("OK")
