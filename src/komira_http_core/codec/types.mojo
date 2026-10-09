# =============================================================================
# src/komira_http_core/codec/types.mojo — HTTP/1.1 core types
# =============================================================================
#
# The shared types every L2-L6 layer consumes:
#   - HttpMethod  — the 7 standard methods + UNKNOWN
#   - HttpRequest — method + path + query + headers + body + path_params
#   - HttpResponse — status + headers + body
#
# "L2 HTTP/1.1 codec". Hardening + chunked-transfer +
# parser is out of scope here; This version ships the type surface only.
# =============================================================================

from std.collections.dict import Dict


# =============================================================================
# §1 — HttpMethod enum (as UInt8 with named constants).
# =============================================================================
# Use UInt8 constants rather than a struct enum to keep HttpMethod
# Copyable + trivially comparable without trait gymnastics on Mojo
# 1.0.0b1. Naming convention matches RFC 9110 §9.

comptime HTTP_METHOD_UNKNOWN: UInt8 = 0
comptime HTTP_METHOD_GET: UInt8 = 1
comptime HTTP_METHOD_POST: UInt8 = 2
comptime HTTP_METHOD_PUT: UInt8 = 3
comptime HTTP_METHOD_DELETE: UInt8 = 4
comptime HTTP_METHOD_PATCH: UInt8 = 5
comptime HTTP_METHOD_HEAD: UInt8 = 6
comptime HTTP_METHOD_OPTIONS: UInt8 = 7

# -----------------------------------------------------------------------------
# WebDAV / CalDAV method extension (RFC 4918 §9 + RFC 4791 §5.3.1).
# -----------------------------------------------------------------------------
# These are ADDITIVE method codes (8..14) that admit the DAV verbs the H1
# parser previously rejected as PARSE_ERR_METHOD_UNKNOWN. They are pure
# extensions to the existing 7-method set: no standard verb changed its code,
# so HTTP/1.1 routing of the original 7 methods is byte-for-byte unchanged.
# The parser's request-line validation only rejects a method when
# `HttpMethod.parse` returns UNKNOWN; once these arms are admitted here the
# parser accepts them and the Router matches by (method, path) as usual.
#
# All seven are valid RFC 9110 §9.1 tokens (uppercase tchar-only), so they
# pass the request-line method-token validation (`_is_tchar` + no-lowercase)
# unchanged — admitting them required NO change to the parser's byte scanner,
# only the recognition table here.
comptime HTTP_METHOD_PROPFIND: UInt8 = 8     # RFC 4918 §9.1 — read properties
comptime HTTP_METHOD_PROPPATCH: UInt8 = 9    # RFC 4918 §9.2 — set/remove properties
comptime HTTP_METHOD_MKCOL: UInt8 = 10       # RFC 4918 §9.3 — create a collection
comptime HTTP_METHOD_COPY: UInt8 = 11        # RFC 4918 §9.8 — copy a resource
comptime HTTP_METHOD_MOVE: UInt8 = 12        # RFC 4918 §9.9 — move a resource
comptime HTTP_METHOD_REPORT: UInt8 = 13      # RFC 3253 §3.6 / RFC 4791 §7 — report
comptime HTTP_METHOD_MKCALENDAR: UInt8 = 14  # RFC 4791 §5.3.1 — create a calendar


@fieldwise_init
struct HttpMethod(
    Copyable, ImplicitlyCopyable, Movable, Deinitable,
):
    """Wrapper around a UInt8 method code with parse + name helpers.

    Copyable + ImplicitlyCopyable + Movable: small POD so callers can
    pass by value freely.
    """

    var code: UInt8

    @staticmethod
    def get() -> HttpMethod:
        return HttpMethod(code=HTTP_METHOD_GET)

    @staticmethod
    def post() -> HttpMethod:
        return HttpMethod(code=HTTP_METHOD_POST)

    @staticmethod
    def put() -> HttpMethod:
        return HttpMethod(code=HTTP_METHOD_PUT)

    @staticmethod
    def delete() -> HttpMethod:
        return HttpMethod(code=HTTP_METHOD_DELETE)

    @staticmethod
    def patch() -> HttpMethod:
        return HttpMethod(code=HTTP_METHOD_PATCH)

    @staticmethod
    def head() -> HttpMethod:
        return HttpMethod(code=HTTP_METHOD_HEAD)

    @staticmethod
    def options() -> HttpMethod:
        return HttpMethod(code=HTTP_METHOD_OPTIONS)

    # WebDAV / CalDAV verbs (additive — see the HTTP_METHOD_* aliases above).
    @staticmethod
    def propfind() -> HttpMethod:
        return HttpMethod(code=HTTP_METHOD_PROPFIND)

    @staticmethod
    def proppatch() -> HttpMethod:
        return HttpMethod(code=HTTP_METHOD_PROPPATCH)

    @staticmethod
    def mkcol() -> HttpMethod:
        return HttpMethod(code=HTTP_METHOD_MKCOL)

    @staticmethod
    def copy() -> HttpMethod:
        return HttpMethod(code=HTTP_METHOD_COPY)

    @staticmethod
    def move() -> HttpMethod:
        return HttpMethod(code=HTTP_METHOD_MOVE)

    @staticmethod
    def report() -> HttpMethod:
        return HttpMethod(code=HTTP_METHOD_REPORT)

    @staticmethod
    def mkcalendar() -> HttpMethod:
        return HttpMethod(code=HTTP_METHOD_MKCALENDAR)

    @staticmethod
    def unknown() -> HttpMethod:
        return HttpMethod(code=HTTP_METHOD_UNKNOWN)

    @staticmethod
    def parse(name: String) -> HttpMethod:
        """Parse a method name. Empty / unrecognized → UNKNOWN.

        Per RFC 9110 §9.1 method names are case-sensitive; we match
        uppercase exactly. Caller is responsible for any normalization.
        """
        if name == "GET":
            return HttpMethod.get()
        if name == "POST":
            return HttpMethod.post()
        if name == "PUT":
            return HttpMethod.put()
        if name == "DELETE":
            return HttpMethod.delete()
        if name == "PATCH":
            return HttpMethod.patch()
        if name == "HEAD":
            return HttpMethod.head()
        if name == "OPTIONS":
            return HttpMethod.options()
        # WebDAV / CalDAV verbs (RFC 4918 / RFC 4791).
        if name == "PROPFIND":
            return HttpMethod.propfind()
        if name == "PROPPATCH":
            return HttpMethod.proppatch()
        if name == "MKCOL":
            return HttpMethod.mkcol()
        if name == "COPY":
            return HttpMethod.copy()
        if name == "MOVE":
            return HttpMethod.move()
        if name == "REPORT":
            return HttpMethod.report()
        if name == "MKCALENDAR":
            return HttpMethod.mkcalendar()
        return HttpMethod.unknown()

    def _write_name[W: Writer](self, mut writer: W):
        """WRITE what `name` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

        The arms live here so no string constant is ever SELECTED and
        returned. A literal-returning ladder lowers to two parallel
        (pointer, length) constant arrays whose two call-site references
        an `--emit shared-lib` link binds INDEPENDENTLY, and a pair bound
        CROSSED takes the process down with it."""
        if self.code == HTTP_METHOD_GET:
            writer.write("GET")
            return
        if self.code == HTTP_METHOD_POST:
            writer.write("POST")
            return
        if self.code == HTTP_METHOD_PUT:
            writer.write("PUT")
            return
        if self.code == HTTP_METHOD_DELETE:
            writer.write("DELETE")
            return
        if self.code == HTTP_METHOD_PATCH:
            writer.write("PATCH")
            return
        if self.code == HTTP_METHOD_HEAD:
            writer.write("HEAD")
            return
        if self.code == HTTP_METHOD_OPTIONS:
            writer.write("OPTIONS")
            return
        # WebDAV / CalDAV verbs (RFC 4918 / RFC 4791).
        if self.code == HTTP_METHOD_PROPFIND:
            writer.write("PROPFIND")
            return
        if self.code == HTTP_METHOD_PROPPATCH:
            writer.write("PROPPATCH")
            return
        if self.code == HTTP_METHOD_MKCOL:
            writer.write("MKCOL")
            return
        if self.code == HTTP_METHOD_COPY:
            writer.write("COPY")
            return
        if self.code == HTTP_METHOD_MOVE:
            writer.write("MOVE")
            return
        if self.code == HTTP_METHOD_REPORT:
            writer.write("REPORT")
            return
        if self.code == HTTP_METHOD_MKCALENDAR:
            writer.write("MKCALENDAR")
            return
        writer.write("UNKNOWN")
        return

    def name(self) -> String:
        var out = String()
        self._write_name(out)
        return out^

    def __eq__(self, other: HttpMethod) -> Bool:
        return self.code == other.code

    def __ne__(self, other: HttpMethod) -> Bool:
        return self.code != other.code

    def is_unknown(self) -> Bool:
        return self.code == HTTP_METHOD_UNKNOWN


# =============================================================================
# §2 — HttpRequest.
# =============================================================================


struct HttpRequest(Movable, Deinitable):
    """Parsed HTTP/1.1 request.

    Movable but NOT Copyable — body + headers own heap allocations and
    duplicating them silently would be a performance footgun.

    :
      method        — parsed verb
      path          — request-target path component ("/api/v1/jobs/42")
      query_string  — request-target query component, NO leading "?"
      headers       — header map (case-INSENSITIVE keys; canonicalized lowercase)
      body          — raw bytes; chunked-transfer decode is out of scope here
      path_params   — filled by Router.match_route() after pattern match
                      (e.g. {"id": "42"} for pattern "/users/:id")
    """

    var method: HttpMethod
    var path: String
    var query_string: String
    var headers: Dict[String, String]
    var body: List[UInt8]
    var path_params: Dict[String, String]

    def __init__(out self):
        self.method = HttpMethod.unknown()
        self.path = String("")
        self.query_string = String("")
        self.headers = Dict[String, String]()
        self.body = List[UInt8]()
        self.path_params = Dict[String, String]()

    def __init__(
        out self,
        var method: HttpMethod,
        var path: String,
    ):
        self.method = method
        self.path = path^
        self.query_string = String("")
        self.headers = Dict[String, String]()
        self.body = List[UInt8]()
        self.path_params = Dict[String, String]()


# =============================================================================
# §3 — HttpResponse.
# =============================================================================

# -----------------------------------------------------------------------------
# Body framing (RFC 9112 §6.1-6.3) — how the RECEIVER learns where the body ends.
# -----------------------------------------------------------------------------
#
# ★ WHY A RESPONSE CARRIES A FRAMING FIELD AT ALL. Cloud Run caps an HTTP/1
# response at 32 MiB *"if not using `Transfer-Encoding: chunked` or streaming
# mechanisms"* (https://docs.cloud.google.com/run/quotas). A `git clone` is a
# large response, so a repo whose history exceeds 32 MiB was un-clonable —
# regardless of commit size — purely because every response we emit is
# `Content-Length` framed. This field is the handler's way of ASKING for the
# other framing; whether it GETS it is decided by the transport, which is the
# only layer that knows the client's HTTP version and request method (see
# `response_may_be_chunked` in `codec/response_framing.mojo`).
#
# ⚠ THIS IS FRAMING, NOT STREAMING. `body` is still a whole `List[UInt8]`;
# marking a response chunked changes the bytes on the wire and NOTHING about
# peak resident memory. Do not cite this field as a memory fix.
comptime RESPONSE_FRAMING_CONTENT_LENGTH: UInt8 = 0
comptime RESPONSE_FRAMING_CHUNKED: UInt8 = 1


struct HttpResponse(Movable, Deinitable):
    """HTTP/1.1 response.

    Movable but NOT Copyable — same rationale as HttpRequest.

    :
      status   — RFC 9110 status code (200, 404, 500, ...)
      headers  — response header map (case-INSENSITIVE keys; lowercase canon)
      body     — response payload bytes

    body_framing — `RESPONSE_FRAMING_CONTENT_LENGTH` (the default, and what
      what a framing-unaware response uses) or
      `RESPONSE_FRAMING_CHUNKED`. It is a REQUEST from the handler, not a
      guarantee: `serialize_response` (the framing-unaware entry point) honours
      it not at all, and `serialize_response_framed` honours it only when the
      transport says the client can receive it. Set it via `mark_chunked()`,
      never by assigning the field, so the mutually-exclusive `content-length`
      header is removed at the same instant.

    Pointer safety: all four fields are either POD (`status`, `body_framing`) or plainly
    heap-owning containers on a struct that is passed BY VALUE and never stored
    in a byte-backed slab, so the byte-slab + wildcard-origin trap does not
    apply. Adding `body_framing` (a `UInt8`) introduces no heap-owning field.
    """

    var status: Int32
    var headers: Dict[String, String]
    var body: List[UInt8]
    var body_framing: UInt8

    def __init__(out self):
        self.status = Int32(200)
        self.headers = Dict[String, String]()
        self.body = List[UInt8]()
        self.body_framing = RESPONSE_FRAMING_CONTENT_LENGTH

    def __init__(out self, status: Int32):
        self.status = status
        self.headers = Dict[String, String]()
        self.body = List[UInt8]()
        self.body_framing = RESPONSE_FRAMING_CONTENT_LENGTH

    def mark_chunked(mut self):
        """ASK for `Transfer-Encoding: chunked` framing on this response.

        Also DELETES any `content-length` header, because the two are mutually
        exclusive (RFC 9112 §6.2: *"A sender MUST NOT send a Content-Length
        header field in any message that contains a Transfer-Encoding header
        field"*) and a message carrying both is the request-smuggling shape that
        intermediaries reject or, worse, mis-frame. Doing the deletion HERE
        means a caller cannot leave the two inconsistent by ordering its
        statements differently.

        ⚠ Asking is not getting. The transport DOWNGRADES this back to
        content-length for an HTTP/1.0 client, for a HEAD request, and for any
        status that cannot carry a body — see `response_may_be_chunked`. The
        downgrade is always safe here precisely because `body` is already whole.
        """
        self.body_framing = RESPONSE_FRAMING_CHUNKED
        try:
            _ = self.headers.pop(String("content-length"))
        except e:
            # Not present — the common case; nothing to remove.
            _ = e

    def wants_chunked(self) -> Bool:
        """True iff this response ASKED for chunked framing (`mark_chunked`)."""
        return self.body_framing == RESPONSE_FRAMING_CHUNKED

    @staticmethod
    def ok(var body_str: String) -> HttpResponse:
        """200 OK with `text/plain` body."""
        var r = HttpResponse(status=Int32(200))
        r.headers[String("content-type")] = String("text/plain")
        var bytes_ref = body_str.as_bytes()
        var n = len(bytes_ref)
        var i = 0
        while i < n:
            r.body.append(bytes_ref[i])
            i = i + 1
        r.headers[String("content-length")] = String(n)
        return r^

    @staticmethod
    def not_found() -> HttpResponse:
        """404 Not Found with empty body."""
        var r = HttpResponse(status=Int32(404))
        r.headers[String("content-type")] = String("text/plain")
        r.headers[String("content-length")] = String("0")
        return r^

    @staticmethod
    def method_not_allowed() -> HttpResponse:
        """405 Method Not Allowed with empty body and no `Allow` header. RFC
        9110 §15.5.6 requires `Allow` on a 405: prefer the overload taking
        the allowed methods."""
        var r = HttpResponse(status=Int32(405))
        r.headers[String("content-type")] = String("text/plain")
        r.headers[String("content-length")] = String("0")
        return r^

    @staticmethod
    def method_not_allowed(allowed: List[HttpMethod]) -> HttpResponse:
        """405 Method Not Allowed with empty body and an `Allow` header
        (RFC 9110 §10.2.1) naming `allowed`: each method once, sorted by name,
        separated by ", ". An empty list gives an empty `Allow` (the resource
        allows no method)."""
        var names = List[String]()
        for i in range(len(allowed)):
            var name = allowed[i].name()
            var at = len(names)
            var duplicate = False
            for j in range(len(names)):
                if names[j] == name:
                    duplicate = True
                    break
                if name < names[j]:
                    at = j
                    break
            if not duplicate:
                names.insert(at, name^)
        var allow = String("")
        for i in range(len(names)):
            if i > 0:
                allow += ", "
            allow += names[i]
        var r = HttpResponse.method_not_allowed()
        r.headers[String("allow")] = allow^
        return r^

    @staticmethod
    def bad_request() -> HttpResponse:
        """400 Bad Request with empty body."""
        var r = HttpResponse(status=Int32(400))
        r.headers[String("content-type")] = String("text/plain")
        r.headers[String("content-length")] = String("0")
        return r^

    @staticmethod
    def internal_error() -> HttpResponse:
        """500 Internal Server Error with empty body."""
        var r = HttpResponse(status=Int32(500))
        r.headers[String("content-type")] = String("text/plain")
        r.headers[String("content-length")] = String("0")
        return r^


# =============================================================================
# §4 — HTTP status helpers.
# =============================================================================


def serialize_response_head(
    response: HttpResponse,
    emit_chunked: Bool,
    mut out: List[UInt8],
):
    """Serialize the status line + header section + the blank-line terminator
    (everything BEFORE the body) into `out`.

    `emit_chunked` selects the body framing this message will use, and the
    header section MUST agree with the bytes that follow — that agreement is
    the entire contract of this function:

      * `emit_chunked == True`  — emit `transfer-encoding: chunked` and SUPPRESS
        any `content-length` the caller left in the map. Both together is
        forbidden by RFC 9112 §6.2 and is the request-smuggling shape; the
        suppression is unconditional here so no caller can produce it.
      * `emit_chunked == False` — emit the caller's headers verbatim (the
        content-length behaviour, byte-for-byte), EXCEPT that a response which
        ASKED for chunked (`mark_chunked`, which deleted its content-length) but
        is not getting it has `content-length: len(body)` injected. Without that
        injection the message would carry NO framing header at all, and a
        receiver would have to fall back to connection-close delimiting —
        silently killing keep-alive and, on a pipelined connection, mis-framing
        the next response.

    Header keys are emitted as-is (callers are responsible for lowercase canon;
    the wire is case-insensitive).
    """
    # Status line.
    var status_line = String("HTTP/1.1 ")
    status_line = status_line + String(Int(response.status))
    status_line = status_line + String(" ")
    status_line = status_line + status_text(response.status)
    status_line = status_line + String("\r\n")
    var sl_bytes = status_line.as_bytes()
    var i = 0
    while i < len(sl_bytes):
        out.append(sl_bytes[i])
        i = i + 1
    # Headers.
    for kv in response.headers.items():
        if emit_chunked and String(kv.key) == String("content-length"):
            # Mutually exclusive with transfer-encoding (RFC 9112 §6.2).
            continue
        var hdr = String(kv.key) + String(": ") + String(kv.value) + String("\r\n")
        var hb = hdr.as_bytes()
        var j = 0
        while j < len(hb):
            out.append(hb[j])
            j = j + 1
    if emit_chunked:
        var te = String("transfer-encoding: chunked\r\n")
        var tb = te.as_bytes()
        var t = 0
        while t < len(tb):
            out.append(tb[t])
            t = t + 1
    elif response.wants_chunked():
        # Downgraded: `mark_chunked` removed the content-length, so re-derive it
        # rather than emit an unframed message. Safe precisely because the body
        # is already whole — this is the property that makes the transport's
        # HTTP/1.0 / HEAD downgrade a no-risk operation.
        var cl = String("content-length: ") + String(len(response.body)) + String("\r\n")
        var cb = cl.as_bytes()
        var c = 0
        while c < len(cb):
            out.append(cb[c])
            c = c + 1
    # Terminator CRLF.
    out.append(UInt8(0x0D))
    out.append(UInt8(0x0A))


def serialize_response(
    response: HttpResponse,
    mut out: List[UInt8],
):
    """Serialize an HttpResponse to wire bytes (HTTP/1.1 status-line +
    headers + body) into `out`. Appends in place — caller pre-clears
    or reserves.

    Format (RFC 9112 §3):
        HTTP/1.1 <status> <reason>\r\n
        <header1>: <value1>\r\n
        ...
        \r\n
        <body bytes>

    Header keys are emitted as-is (callers responsible for lowercase
    canon; though the wire is case-insensitive). The Content-Length
    header is NOT auto-injected — the caller (or HttpResponse.ok
    factories) is responsible for setting it.

    ★ THIS ENTRY POINT NEVER EMITS CHUNKED FRAMING, BY DESIGN. It has no way to
    know the client's HTTP version or request method, and `Transfer-Encoding` is
    illegal towards an HTTP/1.0 client (RFC 9112 §7.1) and towards a HEAD
    request. A response that asked for chunked framing here is DOWNGRADED to
    content-length — correct HTTP, just not cap-lifting. The call sites that DO
    know the request context call `serialize_response_framed` instead; see
    `codec/response_framing.mojo`.
    """
    serialize_response_head(response, False, out)
    # Body.
    var k = 0
    while k < len(response.body):
        out.append(response.body[k])
        k = k + 1


def _write_status_text[W: Writer](mut writer: W, status: Int32):
    """WRITE what `status_text` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link binds INDEPENDENTLY, and a pair bound
    CROSSED takes the process down with it."""
    var s = Int(status)
    if s == 200:
        writer.write("OK")
        return
    if s == 201:
        writer.write("Created")
        return
    # 202 — the usual success of a route that accepts work to do later. Without
    # this arm every such accept would go out as `HTTP/1.1 202 Unknown`. A reason
    # phrase is advisory (RFC 9110 §15: a client SHOULD ignore it) so that would be
    # cosmetic — but `Unknown` on a status the server deliberately returns reads
    # as a fault.
    if s == 202:
        writer.write("Accepted")
        return
    if s == 204:
        writer.write("No Content")
        return
    if s == 207:
        writer.write("Multi-Status")  # RFC 4918 §11.1 — WebDAV multistatus body.
        return
    if s == 301:
        writer.write("Moved Permanently")
        return
    if s == 302:
        writer.write("Found")
        return
    if s == 304:
        writer.write("Not Modified")
        return
    if s == 400:
        writer.write("Bad Request")
        return
    if s == 401:
        writer.write("Unauthorized")
        return
    if s == 403:
        writer.write("Forbidden")
        return
    if s == 404:
        writer.write("Not Found")
        return
    if s == 405:
        writer.write("Method Not Allowed")
        return
    if s == 409:
        writer.write("Conflict")  # RFC 4918 §9.3.1 — MKCOL/PUT missing parent.
        return
    if s == 411:
        writer.write("Length Required")
        return
    if s == 412:
        writer.write("Precondition Failed")  # RFC 7232 §4.2 — If-Match/If-None-Match.
        return
    if s == 413:
        writer.write("Payload Too Large")
        return
    if s == 415:
        writer.write("Unsupported Media Type")
        return
    if s == 431:
        writer.write("Request Header Fields Too Large")
        return
    if s == 500:
        writer.write("Internal Server Error")
        return
    if s == 501:
        writer.write("Not Implemented")
        return
    if s == 502:
        writer.write("Bad Gateway")
        return
    if s == 503:
        writer.write("Service Unavailable")
        return
    writer.write("Unknown")
    return


def status_text(status: Int32) -> String:
    """Map status code to the canonical RFC 9110 reason phrase.

    ships the common ones used by L0/L4; adds the long tail.
    """
    var out = String()
    _write_status_text(out, status)
    return out^
