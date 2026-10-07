# =============================================================================
# fake_blob_service.mojo -- a Blob service on loopback, from the REST docs
# =============================================================================
#
# `FakeBlobService` is a `komira_http_server` `RequestDispatcher` that answers
# the Blob REST operations AzureFs issues, path-style, for one account and one
# container, the way the service documents them:
#
#   * every request is authenticated first: the fake recomputes the Shared
#     Key signature with its own canonicalizer (shared_key_oracle.mojo) and
#     the account's key, and answers 403 `AuthenticationFailed` (with the
#     string it signed in the message, as the service does) on a mismatch;
#   * Get Blob: 200 with the whole blob, or, with `Range: bytes=a-b` or
#     `bytes=a-`, 206 with `Content-Range: bytes a-e/size` where `e` is
#     clamped to the last byte (a range running past the end is answered
#     short, not refused); a start at or past the end is 416 `InvalidRange`;
#   * Get Blob Properties (HEAD): 200 with `Content-Length`, `ETag` and
#     `x-ms-blob-type`, no body;
#   * a missing blob is 404 `BlobNotFound` (an XML error body on GET, the
#     `x-ms-error-code` header alone on HEAD); a missing container is 404
#     `ContainerNotFound`;
#   * List Blobs (`restype=container&comp=list`): `prefix`, `delimiter` (each
#     name past the prefix that holds the delimiter folds into one
#     `<BlobPrefix>`), `marker`, at most `page_size` entries a page (blobs and
#     prefixes both count, as `maxresults` does), an opaque `<NextMarker>`
#     while more remain and `<NextMarker />` on the last page.
#
# The marker is opaque to the client but carries `!`, `/` and `=`, so the
# client must percent-encode it on the next request and the signature must
# cover its DECODED value; a marker that does not parse as `2!mk=N/p` with N
# inside the listing is 400 (the fake does not remember which N it issued;
# the test's request log pins those).
#
# Every request that reaches `dispatch` is logged (method, path, query,
# Range, status) for the test to read after the join. If answering it raises
# (a malformed Range, a bad percent-escape), the fake answers 500
# `InternalError` with the raised message and logs that 500, so the request
# that explains a failure is never missing from the log. Blob names are
# ASCII; XML text is escaped (`&`, `<`, `>`).
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime
from komira_http_core.codec.types import (
    HTTP_METHOD_GET,
    HTTP_METHOD_HEAD,
    HttpRequest,
    HttpResponse,
)
from komira_http_server.dispatch import RequestDispatcher

from .shared_key_oracle import (
    parse_query,
    percent_decode,
    query_value,
    shared_key_authorization,
    shared_key_string_to_sign,
)


comptime _LAST_MODIFIED: StaticString = "Thu, 01 Oct 2026 12:00:00 GMT"
comptime _MARKER_HEAD: StaticString = "2!mk="
comptime _MARKER_TAIL: StaticString = "/p"


@fieldwise_init
struct FakeBlob(Copyable, Movable, Deinitable):
    var name: String
    var data: List[UInt8]
    var etag: String


@fieldwise_init
struct RequestRecord(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """What one request carried, as the server parsed it."""

    var method: String
    var path: String
    var query: String
    var range_header: String
    var status: Int


@fieldwise_init
struct _ListEntry(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    var name: String
    var is_prefix: Bool
    var blob_index: Int


def _xml_escape(s: String) -> String:
    var out = String()
    for b in s.as_bytes():
        if b == UInt8(0x26):
            out += "&amp;"
        elif b == UInt8(0x3C):
            out += "&lt;"
        elif b == UInt8(0x3E):
            out += "&gt;"
        else:
            out += chr(Int(b))
    return out^


def _parse_decimal(s: String) raises -> Int:
    if s.byte_length() == 0 or s.byte_length() > 18:
        raise Error("fake: not a decimal: '" + s + "'")
    var v = 0
    for b in s.as_bytes():
        if b < UInt8(0x30) or b > UInt8(0x39):
            raise Error("fake: not a decimal: '" + s + "'")
        v = v * 10 + Int(b) - 0x30
    return v


def _bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


struct FakeBlobService(RequestDispatcher):
    """The fake Blob service for one account and one container."""

    var account: String
    var key_b64: String
    var container: String
    var page_size: Int
    # Kept sorted by name (byte order), as the service lists.
    var blobs: List[FakeBlob]
    var log: List[RequestRecord]
    var auth_failures: Int
    # The string the fake signed for each request it refused, in order: the
    # 403 message carries it, and it holds the request's x-ms-date, so a test
    # asserting that message exactly takes it from here.
    var refused_strings_to_sign: List[String]

    def __init__(
        out self,
        var account: String,
        var key_b64: String,
        var container: String,
        page_size: Int,
    ):
        self.account = account^
        self.key_b64 = key_b64^
        self.container = container^
        self.page_size = page_size
        self.blobs = List[FakeBlob]()
        self.log = List[RequestRecord]()
        self.auth_failures = 0
        self.refused_strings_to_sign = List[String]()

    def put(mut self, name: String, var data: List[UInt8]):
        """Store a blob, keeping the list sorted by name."""
        var etag = "\"0x8DC" + String(len(self.blobs) + 1000) + "\""
        var blob = FakeBlob(name, data^, etag^)
        var at = len(self.blobs)
        for i in range(len(self.blobs)):
            if self.blobs[i].name > name:
                at = i
                break
        self.blobs.insert(at, blob^)

    def _find(self, name: String) -> Int:
        for i in range(len(self.blobs)):
            if self.blobs[i].name == name:
                return i
        return -1

    # ---- responses --------------------------------------------------------

    @staticmethod
    def _error(
        status: Int, code: String, message: String, is_head: Bool
    ) -> HttpResponse:
        var resp = HttpResponse(Int32(status))
        resp.headers[String("x-ms-error-code")] = code
        if is_head:
            resp.headers[String("content-length")] = String("0")
            return resp^
        var body = String('<?xml version="1.0" encoding="utf-8"?><Error><Code>')
        body += code
        body += "</Code><Message>"
        body += _xml_escape(message)
        body += "</Message></Error>"
        resp.body = _bytes_of(body)
        resp.headers[String("content-type")] = String("application/xml")
        resp.headers[String("content-length")] = String(len(resp.body))
        return resp^

    def _get_blob(self, idx: Int, range_hdr: String, is_head: Bool) raises -> HttpResponse:
        ref blob = self.blobs[idx]
        var size = len(blob.data)
        if is_head:
            var resp = HttpResponse(Int32(200))
            resp.headers[String("content-length")] = String(size)
            resp.headers[String("etag")] = blob.etag
            resp.headers[String("x-ms-blob-type")] = String("BlockBlob")
            resp.headers[String("last-modified")] = String(_LAST_MODIFIED)
            return resp^
        var start = 0
        var end = size - 1
        var status = 200
        if range_hdr.byte_length() > 0:
            if not range_hdr.startswith("bytes="):
                return Self._error(400, "InvalidHeaderValue", "Range: " + range_hdr, False)
            var spec = String(range_hdr[byte = 6 : range_hdr.byte_length()])
            var dash = spec.find("-")
            if dash <= 0:
                return Self._error(400, "InvalidHeaderValue", "Range: " + range_hdr, False)
            start = _parse_decimal(String(spec[byte=0:dash]))
            var tail = String(spec[byte = dash + 1 : spec.byte_length()])
            if tail.byte_length() > 0:
                end = _parse_decimal(tail)
                if end < start:
                    return Self._error(400, "InvalidHeaderValue", "Range: " + range_hdr, False)
            if start >= size:
                return Self._error(
                    416, "InvalidRange",
                    "The range specified is invalid for the current size of the resource.",
                    False,
                )
            if end > size - 1:
                end = size - 1
            status = 206
        var resp = HttpResponse(Int32(status))
        var body = List[UInt8](capacity=end - start + 1)
        for i in range(start, end + 1):
            body.append(blob.data[i])
        resp.headers[String("content-length")] = String(len(body))
        resp.headers[String("content-type")] = String("application/octet-stream")
        resp.headers[String("etag")] = blob.etag
        resp.headers[String("x-ms-blob-type")] = String("BlockBlob")
        if status == 206:
            resp.headers[String("content-range")] = (
                "bytes " + String(start) + "-" + String(end) + "/" + String(size)
            )
        resp.body = body^
        return resp^

    def _list_blobs(self, prefix: String, delimiter: String, marker: String) raises -> HttpResponse:
        # Every entry the listing holds, in name order, with delimiter folds.
        var entries = List[_ListEntry]()
        for i in range(len(self.blobs)):
            ref name = self.blobs[i].name
            if not name.startswith(prefix):
                continue
            if delimiter.byte_length() > 0:
                var rest = String(name[byte = prefix.byte_length() : name.byte_length()])
                var at = rest.find(delimiter)
                if at >= 0:
                    var folded = prefix + String(rest[byte = 0 : at + delimiter.byte_length()])
                    var n = len(entries)
                    if n > 0 and entries[n - 1].is_prefix and entries[n - 1].name == folded:
                        continue
                    entries.append(_ListEntry(folded^, True, -1))
                    continue
            entries.append(_ListEntry(name.copy(), False, i))

        var start = 0
        if marker.byte_length() > 0:
            if not marker.startswith(_MARKER_HEAD) or not marker.endswith(_MARKER_TAIL):
                return Self._error(400, "OutOfRangeInput", "marker: " + marker, False)
            var digits = String(
                marker[byte = _MARKER_HEAD.byte_length() : marker.byte_length() - _MARKER_TAIL.byte_length()]
            )
            start = _parse_decimal(digits)
            if start <= 0 or start >= len(entries):
                return Self._error(400, "OutOfRangeInput", "marker: " + marker, False)
        var stop = start + self.page_size
        if stop > len(entries):
            stop = len(entries)

        var x = String('<?xml version="1.0" encoding="utf-8"?>')
        x += '<EnumerationResults ServiceEndpoint="http://127.0.0.1/'
        x += self.account
        x += '/" ContainerName="'
        x += _xml_escape(self.container)
        x += '">'
        if prefix.byte_length() > 0:
            x += "<Prefix>" + _xml_escape(prefix) + "</Prefix>"
        if marker.byte_length() > 0:
            x += "<Marker>" + _xml_escape(marker) + "</Marker>"
        x += "<MaxResults>" + String(self.page_size) + "</MaxResults>"
        if delimiter.byte_length() > 0:
            x += "<Delimiter>" + _xml_escape(delimiter) + "</Delimiter>"
        x += "<Blobs>"
        for k in range(start, stop):
            ref e = entries[k]
            if e.is_prefix:
                x += "<BlobPrefix><Name>" + _xml_escape(e.name) + "</Name></BlobPrefix>"
                continue
            ref blob = self.blobs[e.blob_index]
            x += "<Blob><Name>" + _xml_escape(blob.name) + "</Name><Properties>"
            x += "<Last-Modified>" + String(_LAST_MODIFIED) + "</Last-Modified>"
            x += "<Etag>" + _xml_escape(blob.etag) + "</Etag>"
            x += "<Content-Length>" + String(len(blob.data)) + "</Content-Length>"
            x += "<Content-Type>application/octet-stream</Content-Type>"
            x += "<BlobType>BlockBlob</BlobType>"
            x += "</Properties></Blob>"
        x += "</Blobs>"
        if stop < len(entries):
            x += "<NextMarker>"
            x += _xml_escape(String(_MARKER_HEAD) + String(stop) + String(_MARKER_TAIL))
            x += "</NextMarker>"
        else:
            x += "<NextMarker />"
        x += "</EnumerationResults>"

        var resp = HttpResponse(Int32(200))
        resp.body = _bytes_of(x)
        resp.headers[String("content-type")] = String("application/xml")
        resp.headers[String("content-length")] = String(len(resp.body))
        return resp^

    # ---- RequestDispatcher ------------------------------------------------

    def _answer(mut self, req: HttpRequest) raises -> HttpResponse:
        var is_head = req.method.code == HTTP_METHOD_HEAD
        var verb = req.method.name()

        # 1. Authenticate: the service's own string-to-sign, the account key.
        var sts = shared_key_string_to_sign(
            verb, req.headers, req.path, req.query_string, self.account
        )
        var want = shared_key_authorization(self.account, self.key_b64, sts)
        var got = req.headers.get(String("authorization"))
        var has_date = req.headers.get(String("x-ms-date"))
        if not got or got.value() != want or not has_date:
            self.auth_failures += 1
            self.refused_strings_to_sign.append(sts)
            return Self._error(
                403, "AuthenticationFailed",
                "Server failed to authenticate the request. The MAC signature"
                " found in the HTTP request is not the same as any computed"
                " signature. Server used following string to sign: '"
                + sts + "'.",
                is_head,
            )
        if not req.headers.get(String("x-ms-version")):
            return Self._error(400, "MissingRequiredHeader", "x-ms-version", is_head)

        # 2. Route: /<account>/<container>[/<blob>].
        var head = "/" + self.account + "/"
        if not req.path.startswith(head):
            return Self._error(400, "InvalidUri", req.path, is_head)
        var rest = String(req.path[byte = head.byte_length() : req.path.byte_length()])
        var slash = rest.find("/")
        var container = rest.copy()
        var blob = String("")
        if slash >= 0:
            container = String(rest[byte=0:slash])
            blob = percent_decode(String(rest[byte = slash + 1 : rest.byte_length()]))
        if container != self.container:
            return Self._error(
                404, "ContainerNotFound", "The specified container does not exist.", is_head
            )

        var params = parse_query(req.query_string)
        if blob.byte_length() == 0:
            if (
                req.method.code == HTTP_METHOD_GET
                and query_value(params, "restype") == "container"
                and query_value(params, "comp") == "list"
            ):
                return self._list_blobs(
                    query_value(params, "prefix"),
                    query_value(params, "delimiter"),
                    query_value(params, "marker"),
                )
            return Self._error(400, "UnsupportedQueryParameter", req.query_string, is_head)

        if req.method.code != HTTP_METHOD_GET and not is_head:
            return Self._error(405, "UnsupportedHttpVerb", verb, is_head)
        var idx = self._find(blob)
        if idx < 0:
            return Self._error(
                404, "BlobNotFound", "The specified blob does not exist.", is_head
            )
        var range_hdr = String("")
        var r = req.headers.get(String("range"))
        if r:
            range_hdr = r.value()
        return self._get_blob(idx, range_hdr, is_head)

    def dispatch[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
        var range_hdr = String("")
        var r = req.headers.get(String("range"))
        if r:
            range_hdr = r.value()
        var resp: HttpResponse
        try:
            resp = self._answer(req)
        except e:
            resp = Self._error(
                500, "InternalError", "fake: " + String(e),
                req.method.code == HTTP_METHOD_HEAD,
            )
        self.log.append(
            RequestRecord(
                req.method.name(),
                req.path.copy(),
                req.query_string.copy(),
                range_hdr^,
                Int(resp.status),
            )
        )
        _ = req^
        return resp^
