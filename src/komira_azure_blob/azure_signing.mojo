# =============================================================================
# komira_azure_blob/azure_signing.mojo — Azure Storage Shared Key signing
# =============================================================================
#
# Shared Key signing as a pure function, and as an HttpLayer.
#
# Algorithm — Shared Key for Blob, Queue, File (Microsoft docs:
# "Authorize with Shared Key"):
#
#   StringToSign = VERB + "\n" +
#                  Content-Encoding + "\n" +
#                  Content-Language + "\n" +
#                  Content-Length + "\n" +     # empty if 0
#                  Content-MD5 + "\n" +
#                  Content-Type + "\n" +
#                  Date + "\n" +               # empty if x-ms-date present
#                  If-Modified-Since + "\n" +
#                  If-Match + "\n" +
#                  If-None-Match + "\n" +
#                  If-Unmodified-Since + "\n" +
#                  Range + "\n" +
#                  CanonicalizedHeaders +      # already \n-suffixed
#                  CanonicalizedResource
#
# Signature = base64(HMAC-SHA256(base64_decode(account_key), StringToSign))
# Authorization header = "SharedKey {account}:{signature}"
#
# CanonicalizedHeaders: lowercase x-ms-* headers, lex-sorted, ":"-joined,
# values trimmed, lines \n-separated, trailing \n.
# CanonicalizedResource: "/{account}{path}\n{sorted query params}", the
# query parameter names lowercased and their values URL-decoded.
#
# Encapsulation discipline:
#   * ZERO UnsafePointer in any public signature.
#   * ZERO wildcard origins.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_azure_core import AzureSharedKey
from komira_clock import now_unix_ms
from komira_crypto import hmac_sha256_string
from komira_datetime import format_http_date
from komira_encoding import base64_decode, base64_encode

from komira_http_client.body import EmptyBody, RequestBody
from komira_http_client.header_map import (
    HeaderMap,
    ci_byte_eq_sab_static,
    sab_to_string,
    sab_to_string_lower,
)
from komira_http_client.request_writer import serialize_request_head
from komira_http_client.response_body import BufferedResponseBody
from komira_http_client.service import (
    ClientRequest,
    HttpLayer,
    HttpService,
)
from komira_http_client.state_machine import ClientResponse
from komira_http_core.transport.io_stream import Connector


# -----------------------------------------------------------------------------
# Header — local (signing-time only) name/value pair
# -----------------------------------------------------------------------------


@fieldwise_init
struct Header(ImplicitlyCopyable, Copyable, Movable, Deinitable):
    var name: String
    var value: String


# -----------------------------------------------------------------------------
# Signing context + result
# -----------------------------------------------------------------------------


@fieldwise_init
struct AzureSharedKeySigningContext(Copyable, Movable, Deinitable):
    """All inputs to the Shared Key signing computation.

    Field layout:
      var cred: AzureSharedKey  — the account name + base64 account key
      var verb: String          — "GET", "HEAD", "PUT", "DELETE", ...
      var account: String       — usually same as cred.account (kept
                                   separate for canonicalized-resource
                                   build; allows DNS-rerouted setups)
      var resource_path: String — "/{container}/{blob}" — absolute path
                                   AFTER the host
      var query_params: List[Header]
                                — (name, value) pairs in the URL query
                                   (use empty List for none)
      var content_encoding: String
      var content_language: String
      var content_length: String      — empty if 0
      var content_md5: String
      var content_type: String
      var if_modified_since: String
      var if_match: String
      var if_none_match: String
      var if_unmodified_since: String
      var range_header: String        — empty if no Range header
      var x_ms_headers: List[Header]  — all x-ms-* headers (incl. x-ms-date)
                                          — caller is responsible for
                                          synthesizing x-ms-date.

    NOTE: the `Date` header is intentionally empty when `x-ms-date` is
    present (per Azure docs — they are alternatives, not both). The
    standard pattern is "use x-ms-date and leave Date empty".
    """

    var cred: AzureSharedKey
    var verb: String
    var account: String
    var resource_path: String
    var query_params: List[Header]
    var content_encoding: String
    var content_language: String
    var content_length: String
    var content_md5: String
    var content_type: String
    var if_modified_since: String
    var if_match: String
    var if_none_match: String
    var if_unmodified_since: String
    var range_header: String
    var x_ms_headers: List[Header]

    @staticmethod
    def for_get(
        cred: AzureSharedKey,
        resource_path: String,
        var x_ms_headers: List[Header],
    ) -> AzureSharedKeySigningContext:
        """Convenience factory for the common GET case."""
        return AzureSharedKeySigningContext(
            cred,
            String("GET"),
            cred.account,
            resource_path,
            List[Header](),
            String(""),
            String(""),
            String(""),
            String(""),
            String(""),
            String(""),
            String(""),
            String(""),
            String(""),
            String(""),
            x_ms_headers^,
        )


@fieldwise_init
struct AzureSharedKeyResult(Copyable, Movable, Deinitable):
    """The signing output.

    Field layout:
      var string_to_sign: String   — for debugging / vector validation
      var signature_b64: String    — base64(HMAC-SHA256(key, sts))
      var authorization: String    — "SharedKey {account}:{signature}"
    """

    var string_to_sign: String
    var signature_b64: String
    var authorization: String


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------


def _ascii_lower(s: String) -> String:
    var out = String()
    var bs = s.as_bytes()
    for i in range(len(bs)):
        var c = Int(bs[i])
        if c >= 0x41 and c <= 0x5A:
            c += 0x20
        out += chr(c)
    return out


def _trim_ws(s: String) -> String:
    var bs = s.as_bytes()
    var i = 0
    var j = len(bs)
    while i < j and (bs[i] == UInt8(0x20) or bs[i] == UInt8(0x09)):
        i += 1
    while j > i and (bs[j - 1] == UInt8(0x20) or bs[j - 1] == UInt8(0x09)):
        j -= 1
    var sub_span = bs[i:j]
    return String(StringSlice(unsafe_from_utf8=sub_span))


# -----------------------------------------------------------------------------
# canonicalize_headers — lowercase + sort + ":"-join the x-ms-* headers
# -----------------------------------------------------------------------------


def canonicalize_headers(x_ms_headers: List[Header]) raises -> String:
    """Per Azure Shared Key: lowercase x-ms-* header names; trim
    values; lex-sort by lowercase name; emit "name:value\n" lines,
    PRESERVING the trailing \n on the last line.
    """
    if len(x_ms_headers) == 0:
        return String("")
    # Lowercase + trim.
    var pairs = List[Header]()
    for i in range(len(x_ms_headers)):
        var h = x_ms_headers[i]
        var ln = _ascii_lower(_trim_ws(h.name))
        # Only x-ms-* names participate.
        if not ln.startswith(String("x-ms-")):
            continue
        var v = _trim_ws(h.value)
        pairs.append(Header(ln, v))

    if len(pairs) == 0:
        return String("")

    # Insertion sort by name.
    var n = len(pairs)
    for i in range(1, n):
        var key_h = pairs[i]
        var j = i - 1
        while j >= 0 and pairs[j].name > key_h.name:
            pairs[j + 1] = pairs[j]
            j -= 1
        pairs[j + 1] = key_h

    # Merge duplicates with ",".
    var merged = List[Header]()
    var k = 0
    while k < n:
        var name = pairs[k].name
        var combined = pairs[k].value
        var m = k + 1
        while m < n and pairs[m].name == name:
            combined += ","
            combined += pairs[m].value
            m += 1
        merged.append(Header(name, combined))
        k = m

    var out = String()
    for i in range(len(merged)):
        out += merged[i].name
        out += ":"
        out += merged[i].value
        out += "\n"
    return out^


# -----------------------------------------------------------------------------
# canonicalize_resource — "/{account}{path}\n{sorted query params}"
# -----------------------------------------------------------------------------


def canonicalize_resource(
    account: String, resource_path: String, query_params: List[Header]
) raises -> String:
    """Per Azure Shared Key: the canonicalized
    resource = "/" + account + path, followed by sorted (lowercase-name)
    query params each on its own line as "name:comma_sorted_values".
    """
    var out = String("/")
    out += account
    if resource_path.byte_length() > 0 and resource_path.as_bytes()[0] != UInt8(0x2F):
        out += "/"
    out += resource_path

    if len(query_params) == 0:
        return out^

    # Lowercase names + trim, group by name, sort values within group,
    # sort groups by name.
    var pairs = List[Header]()
    for i in range(len(query_params)):
        var q = query_params[i]
        pairs.append(
            Header(_ascii_lower(_trim_ws(q.name)), _trim_ws(q.value))
        )
    var n = len(pairs)
    for i in range(1, n):
        var key_h = pairs[i]
        var j = i - 1
        while j >= 0 and pairs[j].name > key_h.name:
            pairs[j + 1] = pairs[j]
            j -= 1
        pairs[j + 1] = key_h

    var k = 0
    while k < n:
        var name = pairs[k].name
        var values = List[String]()
        values.append(pairs[k].value)
        var m = k + 1
        while m < n and pairs[m].name == name:
            values.append(pairs[m].value)
            m += 1
        # Sort values lexicographically (Azure spec requires this).
        var vlen = len(values)
        for i in range(1, vlen):
            var key_v = values[i]
            var j = i - 1
            while j >= 0 and values[j] > key_v:
                values[j + 1] = values[j]
                j -= 1
            values[j + 1] = key_v
        out += "\n"
        out += name
        out += ":"
        for i in range(vlen):
            if i > 0:
                out += ","
            out += values[i]
        k = m
    return out^


# -----------------------------------------------------------------------------
# shared_key_content_length — the Content-Length slot's value
# -----------------------------------------------------------------------------

comptime SHARED_KEY_EMPTY_ZERO_LENGTH_VERSION: StaticString = "2015-02-21"
"""The first x-ms-version at which Shared Key signs a zero Content-Length as
the empty string ("Authorize with Shared Key": "In version 2014-02-14 and
earlier, the content length was included even if zero")."""


def shared_key_content_length(content_length: Int, x_ms_version: String) -> String:
    """The Content-Length slot of the string-to-sign for a request whose body
    is `content_length` bytes, sent at `x_ms_version`.

    A non-zero length is its decimal form. A zero length is "" at version
    2015-02-21 and later, and "0" at 2014-02-14 and earlier. Versions are
    `YYYY-MM-DD`, so byte order is date order; an absent version reads as
    current ("")."""
    if content_length != 0:
        return String(content_length)
    if (
        x_ms_version.byte_length() > 0
        and x_ms_version < String(SHARED_KEY_EMPTY_ZERO_LENGTH_VERSION)
    ):
        return String("0")
    return String("")


# -----------------------------------------------------------------------------
# build_string_to_sign — the 13-field algorithm
# -----------------------------------------------------------------------------


def build_string_to_sign(
    ctx: AzureSharedKeySigningContext,
) raises -> String:
    """Per Microsoft's "Authorize with Shared Key" — the
    13-field StringToSign for Blob/Queue/File services.
    """
    var sts = String()
    sts += ctx.verb;                       sts += "\n"
    sts += ctx.content_encoding;           sts += "\n"
    sts += ctx.content_language;           sts += "\n"
    sts += ctx.content_length;             sts += "\n"
    sts += ctx.content_md5;                sts += "\n"
    sts += ctx.content_type;               sts += "\n"
    # Date: empty when x-ms-date is present (standard pattern).
    sts += String("");                     sts += "\n"
    sts += ctx.if_modified_since;          sts += "\n"
    sts += ctx.if_match;                   sts += "\n"
    sts += ctx.if_none_match;              sts += "\n"
    sts += ctx.if_unmodified_since;        sts += "\n"
    sts += ctx.range_header;               sts += "\n"
    sts += canonicalize_headers(ctx.x_ms_headers)
    sts += canonicalize_resource(
        ctx.account, ctx.resource_path, ctx.query_params
    )
    return sts^


# -----------------------------------------------------------------------------
# azure_shared_key_sign — the public surface
# -----------------------------------------------------------------------------


def azure_shared_key_sign(
    ctx: AzureSharedKeySigningContext,
) raises -> AzureSharedKeyResult:
    """Compute the Shared Key Authorization header.

    Steps:
      1. Build the 13-field StringToSign.
      2. base64-decode the account key.
      3. HMAC-SHA256(key_bytes, sts).
      4. base64-encode the resulting MAC.
      5. Format "SharedKey {account}:{base64_signature}".

    Raises: on malformed base64 in the account key.
    """
    var sts = build_string_to_sign(ctx)
    var key_bytes = base64_decode(ctx.cred.key_b64)
    var mac = hmac_sha256_string(key_bytes, sts)

    # Convert InlineArray[UInt8, 32] -> Span for base64_encode.
    # NOTE: base64_encode takes Span[UInt8, _]; expose mac as a Span.
    var mac_list = List[UInt8](capacity=32)
    for i in range(32):
        mac_list.append(mac[i])
    var sig_b64 = base64_encode(mac_list)

    var auth = String("SharedKey ")
    auth += ctx.cred.account
    auth += ":"
    auth += sig_b64
    return AzureSharedKeyResult(sts^, sig_b64^, auth^)


# -----------------------------------------------------------------------------
# query_params_from — a request's query string as the signing context's pairs
# -----------------------------------------------------------------------------


def _hex_value(c: UInt8) -> Int:
    if c >= UInt8(0x30) and c <= UInt8(0x39):
        return Int(c) - 0x30
    if c >= UInt8(0x41) and c <= UInt8(0x46):
        return Int(c) - 0x41 + 10
    if c >= UInt8(0x61) and c <= UInt8(0x66):
        return Int(c) - 0x61 + 10
    return -1


def _is_valid_utf8(b: Span[UInt8, _]) -> Bool:
    """RFC 3629 well-formedness: no overlong form, no surrogate, nothing
    above U+10FFFF, no truncated sequence."""
    var i = 0
    var n = len(b)
    while i < n:
        var c = Int(b[i])
        if c < 0x80:
            i += 1
            continue
        if c < 0xC2 or c > 0xF4:
            return False  # a continuation byte, an overlong lead, > U+10FFFF
        var need = 1
        var lo = 0x80
        var hi = 0xBF
        if c == 0xE0:
            need = 2
            lo = 0xA0
        elif c == 0xED:
            need = 2
            hi = 0x9F  # no UTF-16 surrogates
        elif c >= 0xE1 and c <= 0xEF:
            need = 2
        elif c == 0xF0:
            need = 3
            lo = 0x90
        elif c == 0xF4:
            need = 3
            hi = 0x8F
        elif c >= 0xF1 and c <= 0xF3:
            need = 3
        if i + need >= n:  # the sequence needs bytes i+1 .. i+need
            return False
        var c1 = Int(b[i + 1])
        if c1 < lo or c1 > hi:
            return False
        for k in range(2, need + 1):
            var ck = Int(b[i + k])
            if ck < 0x80 or ck > 0xBF:
                return False
        i += need + 1
    return True


def _percent_decode(bs: Span[UInt8, _], lo: Int, hi: Int) raises -> String:
    """Bytes `[lo, hi)` of `bs` with each `%XX` decoded, as a String. A `%`
    not followed by two hex digits is refused, and so is a decoded value
    that is not UTF-8: a URL this package builds never carries either, and
    a value decoded wrongly signs a different resource."""
    var out = List[UInt8]()
    var i = lo
    while i < hi:
        var c = bs[i]
        if c == UInt8(0x25):  # '%'
            if i + 2 >= hi:
                raise Error("azure signing: truncated percent-escape in query")
            var h = _hex_value(bs[i + 1])
            var l = _hex_value(bs[i + 2])
            if h < 0 or l < 0:
                raise Error("azure signing: bad percent-escape in query")
            out.append(UInt8(h * 16 + l))
            i += 3
            continue
        out.append(c)
        i += 1
    if not _is_valid_utf8(Span(out)):
        raise Error("azure signing: decoded query value is not valid UTF-8")
    return String(unsafe_from_utf8=Span(out))


def query_params_from(query: String) raises -> List[Header]:
    """The `name=value` pairs of a URL query string (no leading `?`), each
    URL-decoded, in order: the canonicalized resource signs the DECODED
    values. A pair with no `=` has an empty value; empty pairs are skipped."""
    var out = List[Header]()
    var bs = query.as_bytes()
    var n = len(bs)
    var start = 0
    while start <= n:
        var end = start
        while end < n and bs[end] != UInt8(0x26):  # '&'
            end += 1
        if end > start:
            var eq = start
            while eq < end and bs[eq] != UInt8(0x3D):  # '='
                eq += 1
            var name = _percent_decode(bs, start, eq)
            var value = String("")
            if eq < end:
                value = _percent_decode(bs, eq + 1, end)
            out.append(Header(name^, value^))
        start = end + 1
    return out^


def _body_offset(request_bytes: List[UInt8]) raises -> Int:
    """The offset just past the head's blank line (the first CRLF CRLF) in
    serialized request bytes: where the body starts. 0 for empty bytes (a
    request built without a head). A head never contains CRLF CRLF before
    its end, so the first one is the terminator."""
    var n = len(request_bytes)
    if n == 0:
        return 0
    var i = 0
    while i + 3 < n:
        if (
            request_bytes[i] == UInt8(0x0D)
            and request_bytes[i + 1] == UInt8(0x0A)
            and request_bytes[i + 2] == UInt8(0x0D)
            and request_bytes[i + 3] == UInt8(0x0A)
        ):
            return i + 4
        i += 1
    raise Error("azure signing: request_bytes carries no end of head (CRLF CRLF)")


# =============================================================================
# AzureSharedKeyProvider — the credential-source trait for the signing layer
# =============================================================================
#
# The single seam every Shared-Key source conforms
# to. `credential()` is synchronous and returns the currently-resolved
# AzureSharedKey. The trait lives WITH the Storage signing, not in
# komira_azure_core: Shared Key is Storage-specific.
#
# Encapsulation: ZERO UnsafePointer / wildcard origins in the surface.


trait AzureSharedKeyProvider(Movable, Deinitable):
    """A source of Azure Storage AzureSharedKey credentials. `credential()`
    returns the currently-resolved account name + key. Conformers are
    runtime-free; the layer reads the credential synchronously on each
    `call`."""

    def credential(self) raises -> AzureSharedKey:
        ...


@fieldwise_init
struct StaticSharedKeyProvider(
    AzureSharedKeyProvider, Copyable, Movable, Deinitable
):
    """An AzureSharedKeyProvider whose `credential()` returns the same
    AzureSharedKey every call. The production path for caller-supplied
    account keys (pasted from the Azure portal / `az storage account keys
    list`)."""

    var _cred: AzureSharedKey

    @staticmethod
    def make(account: String, key_b64: String) -> StaticSharedKeyProvider:
        return StaticSharedKeyProvider(AzureSharedKey(account, key_b64))

    @always_inline
    def credential(self) raises -> AzureSharedKey:
        return self._cred


# =============================================================================
# SharedKeySigningLayer — HttpService/HttpLayer conformer (Azure Shared Key)
# =============================================================================
#
# Wraps an inner
# HttpService and, on each `call`, signs the request with the Azure
# Shared Key algorithm:
#
#   1. Read the current AzureSharedKey from the provider.
#   2. Stamp the `x-ms-date` header: a pinned date if the layer has one
#      (a test's), else the wall clock's, as an HTTP-date, at sign time.
#      Then extract the canonical-request inputs from `req` — verb, the
#      resource path, the query parameters (URL-decoded), the standard
#      header slots, the body's length, and the x-ms-* headers on
#      `req.headers` (incl. the just-stamped x-ms-date and the
#      AzureStore-stamped `x-ms-version`).
#   3. Build the 13-field StringToSign + compute the Authorization header
#      via `azure_shared_key_sign` (pure compute, no network).
#   4. Inject `Authorization: SharedKey <account>:<sig>` into req.headers.
#   5. Re-serialize the head of req.request_bytes via
#      serialize_request_head so the on-wire bytes carry the Authorization
#      header (request_bytes is pre-serialized at builder time), keeping
#      any body bytes after it.
#   6. Delegate to inner.call.
#
# Anonymous (public-container) reads: if the provider's credential has an
# empty account AND empty key, the layer SKIPS signing — the request goes
# unauthenticated (Azure serves blobs with public read access without an
# Authorization header).
#
# Bodies: the twelve standard slots come from the request. VERB, then
# Content-Encoding, Content-Language, Content-MD5, Content-Type,
# If-Modified-Since, If-Match, If-None-Match, If-Unmodified-Since and Range
# are each the value of that header on `req` ("" when absent); Date is ""
# because x-ms-date is always stamped. Content-Length is the BODY's length
# (`req.body`'s `content_length()`, 0 when there is no body), through
# `shared_key_content_length` (empty for 0 at version 2015-02-21 and later).
# Shared Key signs no body bytes, so the body is never read. A body of
# unknown length (chunked) is refused: Azure requires Content-Length on a
# write, and its slot could not be filled. A Content-Length header on `req`
# that disagrees with the body is refused too.
#
# Re-serialization keeps the body: request_bytes is the old head followed by
# the body bytes when the body was drained into it (BytesBody through
# `build_request_with_body`), or the head alone when the body is streamed
# (`build_streaming_request`). The layer replaces everything up to and
# including the head's blank line with the new head (Authorization added,
# Content-Length the body's length) and keeps the bytes after it.
#
# No UnsafePointer in any signature, no wildcard origin, no
# unsafe_from_address, no take_pointee.


struct SharedKeySigningLayer[Inner: HttpService, P: AzureSharedKeyProvider](
    HttpService, HttpLayer, Movable, Deinitable,
):
    """Azure Shared Key signing layer — wraps an inner
    HttpService and injects an `Authorization: SharedKey <account>:<sig>`
    header computed per-request.

    Construction:
      `SharedKeySigningLayer.wrap(inner, provider)`.

    On `call`:
      1. Read the current AzureSharedKey from the provider.
      2. If account+key are both empty, SKIP signing (anonymous read).
      3. Otherwise stamp the `x-ms-date` header (the pinned date, else the
         wall clock's) so it participates in the signature, build the
         StringToSign from verb / path / query / standard headers / body
         length / x-ms-* headers on req, compute the Authorization header,
         inject it, re-serialize the head of request_bytes, and delegate.

    The standard header slots are signed from `req`'s headers and
    Content-Length from its body's length (see the section comment above);
    a body of unknown length is refused.

    Diagnostic fields `_last_authorization` and `_last_string_to_sign`
    expose the Authorization header value and the string it signed from the
    most recent call (both empty for anonymous)."""

    var _inner: Self.Inner
    var _provider: Self.P
    var _x_ms_date_override: String
    var _last_authorization: String
    var _last_string_to_sign: String

    @staticmethod
    def wrap(
        var inner: Self.Inner,
        var provider: Self.P,
        var x_ms_date: String = String(""),
    ) -> SharedKeySigningLayer[Self.Inner, Self.P]:
        """Standard constructor.

        `x_ms_date` pins the HTTP-date (e.g. "Thu, 01 Oct 2026 12:00:00
        GMT") stamped as `x-ms-date` on every signed request, for a test
        that asserts a stable signature. Empty (the default, and what
        production uses) stamps the wall clock's date at sign time; a
        request that already carries `x-ms-date` keeps it. Azure Shared Key
        REQUIRES x-ms-date, and refuses one more than 15 minutes from its
        own clock, so the date is read per request, never once."""
        return SharedKeySigningLayer[Self.Inner, Self.P](
            _inner=inner^,
            _provider=provider^,
            _x_ms_date_override=x_ms_date^,
            _last_authorization=String(""),
        )

    def __init__(
        out self,
        var _inner: Self.Inner,
        var _provider: Self.P,
        var _x_ms_date_override: String,
        var _last_authorization: String,
    ):
        self._inner = _inner^
        self._provider = _provider^
        self._x_ms_date_override = _x_ms_date_override^
        self._last_authorization = _last_authorization^
        self._last_string_to_sign = String("")

    def layer_name(self) -> String:
        return String("azure-shared-key")

    @always_inline
    def last_authorization(self) -> String:
        """Diagnostic: Authorization header value from the most recent
        call (empty if the credential was empty / skipped)."""
        return self._last_authorization

    def last_string_to_sign(self) -> String:
        """Diagnostic: the string-to-sign of the most recent call (empty
        if the credential was empty / skipped)."""
        return self._last_string_to_sign

    def set_clock_override(mut self, rfc1123_date: String):
        """Test-injection: pin the `x-ms-date` (an HTTP-date, e.g.
        "Thu, 01 Oct 2026 12:00:00 GMT") so a test can assert a stable
        signature. An empty string returns to the wall clock."""
        self._x_ms_date_override = rfc1123_date

    def call[RT: Runtime, C: Connector, B: RequestBody](
        mut self,
        var req: ClientRequest[B],
        mut connector: C,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[BufferedResponseBody]:
        """HttpService.call: sign req with Shared Key, then delegate to
        inner. Anonymous (empty-credential) requests are passed through
        unsigned."""
        # 1. Read current credential.
        var cred = self._provider.credential()

        # 2. Anonymous path: empty account + empty key => no signing.
        if cred.account.byte_length() == 0 and cred.key_b64.byte_length() == 0:
            self._last_authorization = String("")
            self._last_string_to_sign = String("")
            return self._inner.call[RT, C, B](req^, connector, reactor)

        # 3. Stamp the mandatory `x-ms-date` header BEFORE collecting the
        # x-ms-* headers, so it participates in the canonicalized-header
        # signature string (Azure Shared Key REQUIRES x-ms-date; the
        # standard `Date` field is left empty). A pinned date wins; else a
        # date the caller already put on the request is kept; else the
        # wall clock's, read now.
        if self._x_ms_date_override.byte_length() > 0:
            req.headers.insert(
                String("x-ms-date"), self._x_ms_date_override
            )
        elif not req.headers.get(String("x-ms-date")):
            req.headers.insert(
                String("x-ms-date"),
                format_http_date(Int(now_unix_ms() // 1000)),
            )

        # 4. The body's length is what Content-Length signs and frames.
        var body_len = 0
        if req.body:
            body_len = req.body.value().content_length()
        if body_len < 0:
            raise Error(
                "azure signing: refusing a request body of unknown length:"
                " Shared Key signs Content-Length, so a chunked body cannot be"
                " signed"
            )

        # 5. Build the signing context from the request: the standard slots
        # from their headers, the x-ms-* headers (incl. the just-stamped
        # x-ms-date) for canonicalize_headers, which keeps only x-ms-*.
        var verb = String(req.method.name())
        var resource_path = String(req.url.path)
        var content_encoding = String("")
        var content_language = String("")
        var content_md5 = String("")
        var content_type = String("")
        var if_modified_since = String("")
        var if_match = String("")
        var if_none_match = String("")
        var if_unmodified_since = String("")
        var range_header = String("")
        var x_ms_version = String("")
        var x_ms_headers = List[Header]()
        var n_entries = req.headers.len()
        var hi = 0
        while hi < n_entries:
            var entry_view = req.headers.entry_at_view(hi)
            if ci_byte_eq_sab_static(entry_view.name, "range"):
                range_header = sab_to_string(entry_view.value)
            elif ci_byte_eq_sab_static(entry_view.name, "content-encoding"):
                content_encoding = sab_to_string(entry_view.value)
            elif ci_byte_eq_sab_static(entry_view.name, "content-language"):
                content_language = sab_to_string(entry_view.value)
            elif ci_byte_eq_sab_static(entry_view.name, "content-md5"):
                content_md5 = sab_to_string(entry_view.value)
            elif ci_byte_eq_sab_static(entry_view.name, "content-type"):
                content_type = sab_to_string(entry_view.value)
            elif ci_byte_eq_sab_static(entry_view.name, "if-modified-since"):
                if_modified_since = sab_to_string(entry_view.value)
            elif ci_byte_eq_sab_static(entry_view.name, "if-match"):
                if_match = sab_to_string(entry_view.value)
            elif ci_byte_eq_sab_static(entry_view.name, "if-none-match"):
                if_none_match = sab_to_string(entry_view.value)
            elif ci_byte_eq_sab_static(entry_view.name, "if-unmodified-since"):
                if_unmodified_since = sab_to_string(entry_view.value)
            elif ci_byte_eq_sab_static(entry_view.name, "content-length"):
                var declared = sab_to_string(entry_view.value)
                if declared != String(body_len):
                    raise Error(
                        "azure signing: the request's Content-Length header says "
                        + declared
                        + " but its body is "
                        + String(body_len)
                        + " bytes"
                    )
            elif ci_byte_eq_sab_static(entry_view.name, "authorization"):
                # Skip any pre-existing Authorization (idempotent on a
                # recycled req object).
                pass
            else:
                if ci_byte_eq_sab_static(entry_view.name, "x-ms-version"):
                    x_ms_version = sab_to_string(entry_view.value)
                x_ms_headers.append(
                    Header(
                        sab_to_string_lower(entry_view.name),
                        sab_to_string(entry_view.value),
                    )
                )
            hi = hi + 1

        var ctx = AzureSharedKeySigningContext(
            cred=cred,
            verb=verb,
            account=cred.account,
            resource_path=resource_path,
            query_params=query_params_from(req.url.query),
            content_encoding=content_encoding^,
            content_language=content_language^,
            content_length=shared_key_content_length(body_len, x_ms_version),
            content_md5=content_md5^,
            content_type=content_type^,
            if_modified_since=if_modified_since^,
            if_match=if_match^,
            if_none_match=if_none_match^,
            if_unmodified_since=if_unmodified_since^,
            range_header=range_header^,
            x_ms_headers=x_ms_headers^,
        )

        # 6. Compute the signature + inject the Authorization header.
        var result = azure_shared_key_sign(ctx)
        req.headers.insert(String("authorization"), result.authorization)
        self._last_authorization = result.authorization
        self._last_string_to_sign = result.string_to_sign

        # 7. Re-serialize the head so the on-wire bytes carry the
        # Authorization header, and keep the body bytes that followed the
        # old head (none for EmptyBody or a streamed body).
        var new_bytes = List[UInt8]()
        serialize_request_head(
            req.method, req.url, req.headers, body_len, new_bytes
        )
        var tail_at = _body_offset(req.request_bytes)
        var tail_len = len(req.request_bytes) - tail_at
        if tail_len != 0 and tail_len != body_len:
            raise Error(
                "azure signing: request_bytes carries "
                + String(tail_len)
                + " body bytes but the body is "
                + String(body_len)
                + " bytes"
            )
        if tail_len > 0:
            new_bytes.extend(Span(req.request_bytes)[tail_at:])
        req.request_bytes = new_bytes^

        # 8. Delegate.
        return self._inner.call[RT, C, B](req^, connector, reactor)
