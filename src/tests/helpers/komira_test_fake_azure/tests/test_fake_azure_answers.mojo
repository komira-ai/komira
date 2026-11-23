# The fake Blob service's answer to each request's bytes, as the Azure
# readers of the tests that use it see it.
#
# Rows: a HEAD gives the blob's size in Content-Length and no body; a GET
# with no range gives the whole blob; a closed and an open range give 206 with
# the bytes and their Content-Range; a percent-encoded blob name is the
# decoded one; a missing blob is 404 BlobNotFound (with its XML body for a
# GET, none for a HEAD); the trapped blob is 403; a verb other than GET and
# HEAD is 405; a range starting past the end, and a suffix range Azure has
# no grammar for, are 416; bytes with no complete request head, and a path
# with a bad escape, are refused.
from std.testing import assert_equal, assert_raises, assert_true

from komira_test_fake_azure import (
    FakeAzureState,
    fake_azure_answer,
    fake_azure_unquote,
)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _state(trap: String = "") -> FakeAzureState:
    var st = FakeAzureState(trap)
    st.put("box/t/a.bin", _bytes("0123456789"))
    st.put("box/a b.bin", _bytes("xy"))
    return st^


def _ask(mut st: FakeAzureState, method: String, path: String, range_: String = "") raises -> String:
    var req = method + " " + path + " HTTP/1.1\r\nHost: 127.0.0.1:10000\r\n"
    if range_.byte_length() > 0:
        req += "Range: " + range_ + "\r\n"
    req += "\r\n"
    var answer = fake_azure_answer(st, _bytes(req))
    return String(unsafe_from_utf8=Span(answer))


def test_a_head_gives_the_size_and_no_body() raises:
    var st = _state()
    var a = _ask(st, "HEAD", "/devstoreaccount1/box/t/a.bin")
    assert_true(a.startswith("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n"), a)
    assert_true(a.endswith("\r\n\r\n"), a)


def test_a_get_gives_the_whole_blob() raises:
    var st = _state()
    var a = _ask(st, "GET", "/devstoreaccount1/box/t/a.bin?timeout=30")
    assert_true(a.startswith("HTTP/1.1 200 OK\r\n"), a)
    assert_true(a.endswith("\r\n\r\n0123456789"), a)


def test_ranges_give_their_bytes() raises:
    var st = _state()
    var closed = _ask(st, "GET", "/devstoreaccount1/box/t/a.bin", "bytes=2-4")
    assert_true(closed.startswith("HTTP/1.1 206 Partial Content\r\nContent-Length: 3\r\n"), closed)
    assert_true("Content-Range: bytes 2-4/10\r\n" in closed, closed)
    assert_true(closed.endswith("\r\n\r\n234"), closed)
    var open_ended = _ask(st, "GET", "/devstoreaccount1/box/t/a.bin", "bytes=7-")
    assert_true("Content-Range: bytes 7-9/10\r\n" in open_ended, open_ended)
    assert_true(open_ended.endswith("\r\n\r\n789"), open_ended)
    # A last byte past the end is cut to the end.
    var past = _ask(st, "GET", "/devstoreaccount1/box/t/a.bin", "bytes=8-40")
    assert_true(past.endswith("\r\n\r\n89"), past)


def test_an_encoded_name_is_the_decoded_one() raises:
    var st = _state()
    var a = _ask(st, "GET", "/devstoreaccount1/box/a%20b.bin")
    assert_true(a.endswith("\r\n\r\nxy"), a)
    assert_equal(fake_azure_unquote("a%2Fb%20c"), "a/b c")


def test_a_missing_blob_is_404() raises:
    var st = _state()
    var get = _ask(st, "GET", "/devstoreaccount1/box/t/missing.bin")
    assert_true(get.startswith("HTTP/1.1 404 "), get)
    assert_true("<Code>BlobNotFound</Code>" in get, get)
    var head = _ask(st, "HEAD", "/devstoreaccount1/box/t/missing.bin")
    assert_true(head.startswith("HTTP/1.1 404 "), head)
    assert_true(head.endswith("\r\n\r\n"), head)
    # A path that names no blob (a container alone) is not found either.
    var container = _ask(st, "GET", "/devstoreaccount1/box/")
    assert_true(container.startswith("HTTP/1.1 404 "), container)


def test_the_trapped_blob_is_403() raises:
    var st = _state(trap="t/a.bin")
    var a = _ask(st, "GET", "/devstoreaccount1/box/t/a.bin", "bytes=0-1")
    assert_true(a.startswith("HTTP/1.1 403 Forbidden\r\n"), a)
    assert_true("<Code>AuthorizationPermissionMismatch</Code>" in a, a)
    var other = _ask(st, "GET", "/devstoreaccount1/box/a%20b.bin")
    assert_true(other.startswith("HTTP/1.1 200 OK\r\n"), other)


def test_another_verb_is_405() raises:
    var st = _state()
    var a = _ask(st, "PUT", "/devstoreaccount1/box/t/a.bin")
    assert_true(a.startswith("HTTP/1.1 405 "), a)
    assert_true("<Code>UnsupportedHttpVerb</Code>" in a, a)


def test_a_range_azure_cannot_serve_is_416() raises:
    var st = _state()
    var past = _ask(st, "GET", "/devstoreaccount1/box/t/a.bin", "bytes=10-12")
    assert_true(past.startswith("HTTP/1.1 416 "), past)
    var suffix = _ask(st, "GET", "/devstoreaccount1/box/t/a.bin", "bytes=-3")
    assert_true(suffix.startswith("HTTP/1.1 416 "), suffix)
    var unit = _ask(st, "GET", "/devstoreaccount1/box/t/a.bin", "items=0-1")
    assert_true(unit.startswith("HTTP/1.1 416 "), unit)
    assert_equal(st.requests, 3)


def test_bytes_that_are_no_request_are_refused() raises:
    var st = _state()
    with assert_raises(contains="no complete request head"):
        _ = fake_azure_answer(st, _bytes("GET /devstoreaccount1/box/t/a.bin HTTP/1.1\r\n"))
    with assert_raises(contains="a bad escape"):
        _ = _ask(st, "GET", "/devstoreaccount1/box/a%zz.bin")
    with assert_raises(contains="ends inside an escape"):
        _ = _ask(st, "GET", "/devstoreaccount1/box/a%4")


def main() raises:
    test_a_head_gives_the_size_and_no_body()
    test_a_get_gives_the_whole_blob()
    test_ranges_give_their_bytes()
    test_an_encoded_name_is_the_decoded_one()
    test_a_missing_blob_is_404()
    test_the_trapped_blob_is_403()
    test_another_verb_is_405()
    test_a_range_azure_cannot_serve_is_416()
    test_bytes_that_are_no_request_are_refused()
    print("OK")
